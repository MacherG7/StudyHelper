import Foundation
@testable import StudyAI

/// Test double for `HTTPTransport`: records requests, answers with canned responses. No network.
final class StubTransport: HTTPTransport, @unchecked Sendable {
    struct Canned {
        var status: Int = 200
        var headers: [String: String] = [:]
        var body: Data = Data()
        var lines: [String] = []
        var error: Error?
    }

    private let lock = NSLock()
    private var queue: [Canned]
    private(set) var requests: [URLRequest] = []

    init(_ responses: [Canned] = []) { queue = responses }

    func enqueue(_ canned: Canned) { lock.withLock { queue.append(canned) } }

    private func next(_ request: URLRequest) -> Canned {
        lock.withLock {
            requests.append(request)
            return queue.isEmpty ? Canned() : queue.removeFirst()
        }
    }

    private func response(_ request: URLRequest, _ canned: Canned) -> HTTPURLResponse {
        HTTPURLResponse(
            url: request.url ?? URL(string: "https://stub.invalid")!, statusCode: canned.status,
            httpVersion: "HTTP/1.1", headerFields: canned.headers)!
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let canned = next(request)
        if let error = canned.error { throw error }
        return (canned.body, response(request, canned))
    }

    func stream(_ request: URLRequest) async throws -> (AsyncThrowingStream<String, Error>, HTTPURLResponse) {
        let canned = next(request)
        if let error = canned.error { throw error }
        let lines = AsyncThrowingStream<String, Error> { continuation in
            for line in canned.lines { continuation.yield(line) }
            continuation.finish()
        }
        return (lines, response(request, canned))
    }
}
