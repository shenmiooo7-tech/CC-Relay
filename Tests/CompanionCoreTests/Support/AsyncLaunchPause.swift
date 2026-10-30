import Foundation

actor AsyncLaunchPause {
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    private(set) var started = false

    func wait() async {
        started = true
        guard !released else { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}
