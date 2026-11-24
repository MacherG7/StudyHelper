import Foundation

/// The only door to the network for providers. Tests inject a stub; nothing else in the AI layer touches URLSession.
public protocol HTTPTransport: Sendable {
    /// A complete response. Non-2xx statuses are returned, not thrown (the caller maps them with `HTTPErrorMapper`).
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
    /// A streamed response as text lines. For a non-2xx status the lines carry the error body.
    func stream(_ request: URLRequest) async throws -> (AsyncThrowingStream<String, Error>, HTTPURLResponse)
}

/// Maps transport failures to `ProviderError`.
func providerError(from error: Error) -> ProviderError {
    if let error = error as? ProviderError { return error }
    if error is CancellationError { return .cancelled }
    if let error = error as? URLError {
        if error.code == .cancelled { return .cancelled }
        return .network(error.localizedDescription)
    }
    return .network(error.localizedDescription)
}

public struct URLSessionTransport: HTTPTransport {
    private let session: URLSession

    public init(session: URLSession = .shared) { self.session = session }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw ProviderError.invalidResponse("Keine HTTP-Antwort.")
            }
            return (data, http)
        } catch {
            throw providerError(from: error)
        }
    }

    public func stream(_ request: URLRequest) async throws -> (AsyncThrowingStream<String, Error>, HTTPURLResponse) {
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw ProviderError.invalidResponse("Keine HTTP-Antwort.")
            }
            let lines = AsyncThrowingStream<String, Error> { continuation in
                let task = Task {
                    do {
                        for try await line in bytes.lines { continuation.yield(line) }
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: providerError(from: error))
                    }
                }
                continuation.onTermination = { _ in task.cancel() }
            }
            return (lines, http)
        } catch {
            throw providerError(from: error)
        }
    }
}
