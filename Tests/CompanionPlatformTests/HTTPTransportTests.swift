import CompanionCore
import Foundation
import XCTest
@testable import CompanionPlatform

@MainActor
final class HTTPTransportTests: XCTestCase {
    private func request(_ path: String, limit: Int = 100) -> HTTPRequest {
        HTTPRequest(method: "GET", url: URL(string: "https://fixture.invalid\(path)")!,
                    headers: ["X-Fixture": "test"], timeout: .seconds(2), maximumBodyBytes: limit)
    }

    func testEphemeralRequestAndResponse() async throws {
        let response = try await HTTPTransportSession.send(request("/ok"), protocolClasses: [LocalHTTPStub.self])
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(response.body, Data("hello".utf8))
        XCTAssertEqual(response.finalURL.path, "/ok")
        XCTAssertEqual(response.headers["X-Stub"], "local")
        let outgoing = try XCTUnwrap(LocalHTTPStub.requests.value.last)
        XCTAssertFalse(outgoing.httpShouldHandleCookies)
        XCTAssertEqual(outgoing.cachePolicy, .reloadIgnoringLocalCacheData)
        XCTAssertEqual(outgoing.timeoutInterval, 2)
        XCTAssertEqual(outgoing.value(forHTTPHeaderField: "X-Fixture"), "test")
    }

    func testRefusesRedirectResponsesAndRedirectDelegateNeverFollows() async {
        for path in ["/redirect-response", "/redirect-callback"] {
            do {
                _ = try await HTTPTransportSession.send(request(path), protocolClasses: [LocalHTTPStub.self])
                XCTFail("Redirect was accepted")
            } catch { XCTAssertEqual(error as? HTTPTransportError, .redirected) }
        }
        XCTAssertFalse(LocalHTTPStub.requests.value.contains { $0.url?.path == "/redirect-target" })
    }

    func testSizeCapWithAndWithoutContentLengthAndExactBoundary() async throws {
        for path in ["/large-header", "/chunked"] {
            do {
                _ = try await HTTPTransportSession.send(request(path, limit: 5), protocolClasses: [LocalHTTPStub.self])
                XCTFail("Oversized body was accepted")
            } catch { XCTAssertEqual(error as? HTTPTransportError, .bodyTooLarge) }
        }
        let response = try await HTTPTransportSession.send(request("/ok", limit: 5), protocolClasses: [LocalHTTPStub.self])
        XCTAssertEqual(response.body.count, 5)
    }

    func testTimeoutAndTransportErrorMapping() async {
        for (path, expected) in [("/timeout", HTTPTransportError.timedOut), ("/error", .transportFailed)] {
            do {
                _ = try await HTTPTransportSession.send(request(path), protocolClasses: [LocalHTTPStub.self])
                XCTFail("Expected error")
            } catch { XCTAssertEqual(error as? HTTPTransportError, expected) }
        }
    }

    func testCancellationBeforeStart() async {
        let task = Task {
            return try await HTTPTransportSession.send(request("/ok"), protocolClasses: [LocalHTTPStub.self])
        }
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
    }

    func testCancellationOfAnActiveRequest() async throws {
        let task = Task { try await HTTPTransportSession.send(request("/hang"), protocolClasses: [LocalHTTPStub.self]) }
        defer { task.cancel() }
        for _ in 0..<100 {
            if LocalHTTPStub.requests.value.contains(where: { $0.url?.path == "/hang" }) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(LocalHTTPStub.requests.value.contains { $0.url?.path == "/hang" })
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
    }

    func testFixturePathsMissingFilesAndSizeCap() async throws {
        let directory = try PlatformTestDirectory()
        defer { directory.remove() }
        let file = directory.root.appendingPathComponent("fixtures/http/api/account.json")
        try AtomicFile.write(Data("{\"fixture\":true}".utf8), to: file)
        let transport = FixtureHTTPTransport(root: directory.root)
        let response = try await transport.send(request("/api/account?ignored=yes"))
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(response.body, try Data(contentsOf: file))
        let missing = try await transport.send(request("/unknown"))
        XCTAssertEqual(missing.statusCode, 404)
        do { _ = try await transport.send(request("/api/account", limit: 1)); XCTFail() }
        catch { XCTAssertEqual(error as? HTTPTransportError, .bodyTooLarge) }
        let escape = directory.root.appendingPathComponent("fixtures/http/api/escape.json")
        try FileManager.default.createSymbolicLink(at: escape, withDestinationURL: directory.root.appendingPathComponent("outside.json"))
        do { _ = try await transport.send(request("/api/escape")); XCTFail() }
        catch { XCTAssertEqual(error as? HTTPTransportError, .transportFailed) }
    }
}

private final class RequestLog: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [URLRequest] = []
    var value: [URLRequest] { lock.withLock { requests } }
    func append(_ request: URLRequest) { lock.withLock { requests.append(request) } }
}

private final class LocalHTTPStub: URLProtocol, @unchecked Sendable {
    static let requests = RequestLog()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requests.append(request)
        let url = request.url!
        let path = url.path
        if path == "/hang" { return }
        if ["/timeout", "/error"].contains(path) {
            client?.urlProtocol(self, didFailWithError: URLError(path == "/timeout" ? .timedOut : .cannotConnectToHost))
            return
        }
        let redirected = path.hasPrefix("/redirect-")
        var headers = ["X-Stub": "local"]
        if redirected { headers["Location"] = "https://fixture.invalid/redirect-target" }
        if path == "/large-header" { headers["Content-Length"] = "6" }
        let response = HTTPURLResponse(url: url, statusCode: redirected ? 302 : 200,
                                       httpVersion: "HTTP/1.1", headerFields: headers)!
        if path == "/redirect-callback" {
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: URL(string: headers["Location"]!)!), redirectResponse: response)
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if ["/chunked", "/large-header"].contains(path) {
            client?.urlProtocol(self, didLoad: Data([1, 2, 3]))
            client?.urlProtocol(self, didLoad: Data([4, 5, 6]))
        } else { client?.urlProtocol(self, didLoad: Data("hello".utf8)) }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
