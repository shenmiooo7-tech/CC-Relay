import CompanionCore
import Foundation

/// `/api/account` maps to `fixtures/http/api/account.json`; query strings do not change the fixture.
public struct FixtureHTTPTransport: HTTPTransport {
    private let root: URL
    private let boundary: SandboxBoundary

    public init(root: URL) {
        self.root = root.appendingPathComponent("fixtures/http", isDirectory: true)
        boundary = SandboxBoundary(root: self.root)
    }

    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        try Task.checkCancellation()
        let parts = request.url.path.split(separator: "/").map(String.init)
        guard !parts.contains(".."), !parts.contains("."), !parts.contains(where: { $0.contains("\\") || $0.contains("\0") }) else {
            throw HTTPTransportError.transportFailed
        }
        let relative = parts.isEmpty ? "index" : parts.joined(separator: "/")
        let file = root.appendingPathComponent(relative).appendingPathExtension("json")
        do { try boundary.check(file) } catch { throw HTTPTransportError.transportFailed }
        let data: Data
        do { data = try Data(contentsOf: file) }
        catch CocoaError.fileReadNoSuchFile {
            return HTTPResponse(statusCode: 404, body: Data(), finalURL: request.url)
        } catch { throw HTTPTransportError.transportFailed }
        guard data.count <= request.maximumBodyBytes else { throw HTTPTransportError.bodyTooLarge }
        return HTTPResponse(statusCode: 200, headers: ["Content-Type": "application/json"], body: data, finalURL: request.url)
    }
}
