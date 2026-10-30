import CompanionCore
import Foundation

public struct SandboxVersionReader: Sendable {
    private let root: URL
    public init(root: URL) { self.root = root }
    public func versions() throws -> ClaudeVersions {
        let bundle = AppPaths.sandbox(root: root).claudeAppURL
        for relative in ["Contents/Info.plist", "Contents/Frameworks/Electron Framework.framework/Resources/Info.plist",
                         "Contents/Frameworks/Electron Framework.framework/Versions/A/Resources/Info.plist"] {
            try SandboxBoundary(root: root).check(bundle.appendingPathComponent(relative))
        }
        return ClaudeVersionReader.readBundle(bundle)
    }
}

/// Records the reveal request inside the sandbox instead of contacting Finder.
public struct SandboxFileRevealer: FileRevealing {
    private let root: URL
    public init(root: URL) { self.root = root }
    public func reveal(_ url: URL) async throws {
        let boundary = SandboxBoundary(root: root)
        let record = root.appendingPathComponent("revealed.json")
        try boundary.check(url)
        try boundary.check(record)
        try AtomicFile.write(JSONEncoder().encode(url.path), to: record)
    }
}

/// The decrypted fixture cookie selects a profile's independent HTTP responses.
public struct SandboxHTTPTransport: HTTPTransport {
    private let root: URL
    public init(root: URL) { self.root = root }
    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        try Task.checkCancellation()
        let prefix = "sessionKey=sandbox-"
        guard request.method == "GET", request.url.host == "claude.ai",
              let cookie = request.headers["Cookie"], cookie.hasPrefix(prefix),
              let folder = try? ProfileFolder(String(cookie.dropFirst(prefix.count))) else {
            throw HTTPTransportError.transportFailed
        }
        let components = request.url.path.split(separator: "/").map(String.init)
        guard !components.isEmpty, !components.contains(where: { $0 == "." || $0 == ".." || $0.contains("\\") }) else {
            throw HTTPTransportError.transportFailed
        }
        let file = root.appendingPathComponent("fixtures/http/\(folder.name)/" + components.joined(separator: "/") + ".json")
        do {
            try SandboxBoundary(root: root).check(file)
            let body = try Data(contentsOf: file)
            guard body.count <= request.maximumBodyBytes else { throw HTTPTransportError.bodyTooLarge }
            return HTTPResponse(statusCode: 200, body: body, finalURL: request.url)
        } catch CocoaError.fileReadNoSuchFile {
            return HTTPResponse(statusCode: 404, body: Data(), finalURL: request.url)
        }
    }
}
