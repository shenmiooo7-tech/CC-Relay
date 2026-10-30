import CompanionCore
import Foundation

public struct URLSessionHTTPTransport: HTTPTransport {
    public init() {}

    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        try SafetyTripwire.assertLiveActionsAllowed()
        return try await HTTPTransportSession.send(request)
    }
}

enum HTTPTransportSession {
    static func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        try SafetyTripwire.assertLiveActionsAllowed()
        return try await perform(request, protocolClasses: nil)
    }

    /// Only tests supply protocol classes. Production always uses the ephemeral system transport.
    static func send(_ request: HTTPRequest, protocolClasses: [AnyClass]) async throws -> HTTPResponse {
        guard !protocolClasses.isEmpty else { throw HTTPTransportError.transportFailed }
        return try await perform(request, protocolClasses: protocolClasses)
    }

    private static func perform(_ request: HTTPRequest, protocolClasses: [AnyClass]?) async throws -> HTTPResponse {
        guard request.maximumBodyBytes >= 0, request.timeout > .zero,
              ["http", "https"].contains(request.url.scheme?.lowercased() ?? ""), request.url.host != nil else {
            throw HTTPTransportError.transportFailed
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = request.timeout.timeInterval
        configuration.timeoutIntervalForResource = request.timeout.timeInterval
        if let protocolClasses { configuration.protocolClasses = protocolClasses }
        let operation = StreamingHTTPOperation(limit: request.maximumBodyBytes)
        let session = URLSession(configuration: configuration, delegate: operation, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var outgoing = URLRequest(url: request.url, cachePolicy: .reloadIgnoringLocalCacheData,
                                  timeoutInterval: request.timeout.timeInterval)
        outgoing.httpMethod = request.method
        outgoing.httpBody = request.body
        outgoing.allHTTPHeaderFields = request.headers
        outgoing.httpShouldHandleCookies = false
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                operation.start(task: session.dataTask(with: outgoing), continuation: continuation)
            }
        } onCancel: { operation.cancel() }
    }
}

private final class StreamingHTTPOperation: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let limit: Int
    private let lock = NSLock()
    // URLSession delegate callbacks are serial; the lock also covers cancellation from the caller.
    private var body = Data()
    private var response: HTTPURLResponse?
    private var task: URLSessionDataTask?
    private var continuation: CheckedContinuation<HTTPResponse, Error>?
    private var cancelled = false
    private var finished = false

    init(limit: Int) { self.limit = limit }

    func start(task: URLSessionDataTask, continuation: CheckedContinuation<HTTPResponse, Error>) {
        lock.lock()
        if cancelled {
            lock.unlock()
            task.cancel()
            continuation.resume(throwing: CancellationError())
            return
        }
        self.task = task
        self.continuation = continuation
        lock.unlock()
        task.resume()
    }

    func cancel() {
        lock.withLock { cancelled = true }
        finish(.failure(CancellationError()))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
        finish(.failure(HTTPTransportError.redirected))
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            finish(.failure(HTTPTransportError.transportFailed))
            return
        }
        if (300...399).contains(http.statusCode) {
            completionHandler(.cancel)
            finish(.failure(HTTPTransportError.redirected))
        } else if response.expectedContentLength > Int64(limit) {
            completionHandler(.cancel)
            finish(.failure(HTTPTransportError.bodyTooLarge))
        } else {
            lock.withLock { self.response = http }
            completionHandler(.allow)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let overflow = lock.withLock {
            if finished { return false }
            guard data.count <= limit - body.count else { return true }
            body.append(data)
            return false
        }
        if overflow { finish(.failure(HTTPTransportError.bodyTooLarge)) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        if let error {
            let mapped: HTTPTransportError = (error as? URLError)?.code == .timedOut ? .timedOut : .transportFailed
            finish(.failure(mapped))
            return
        }
        let result: Result<HTTPResponse, Error> = lock.withLock {
            guard let response, let url = response.url else { return .failure(HTTPTransportError.transportFailed) }
            let headers = Dictionary(response.allHeaderFields.map { (String(describing: $0.key), String(describing: $0.value)) },
                                     uniquingKeysWith: { _, last in last })
            return .success(HTTPResponse(statusCode: response.statusCode, headers: headers, body: body, finalURL: url))
        }
        finish(result)
    }

    private func finish(_ result: Result<HTTPResponse, Error>) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        let completion = continuation
        continuation = nil
        let task = self.task
        self.task = nil
        lock.unlock()
        if case .failure = result { task?.cancel() }
        completion?.resume(with: result)
    }
}
