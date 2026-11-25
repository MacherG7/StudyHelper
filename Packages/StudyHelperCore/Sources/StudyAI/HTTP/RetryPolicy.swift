import Foundation

/// Automatic retries for transient provider errors (rate limit, overload, network, 5xx).
public struct RetryPolicy: Sendable {
    public var maxRetries: Int
    public var baseDelay: TimeInterval
    public var maxDelay: TimeInterval
    /// Injectable so tests do not wait.
    public var sleep: @Sendable (TimeInterval) async throws -> Void
    /// Random factor in 0...1 added as jitter (injectable for deterministic tests).
    public var jitter: @Sendable () -> Double

    public init(
        maxRetries: Int = 2, baseDelay: TimeInterval = 1, maxDelay: TimeInterval = 30,
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { seconds in
            try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
        },
        jitter: @escaping @Sendable () -> Double = { Double.random(in: 0...1) }
    ) {
        self.maxRetries = maxRetries
        self.baseDelay = baseDelay
        self.maxDelay = maxDelay
        self.sleep = sleep
        self.jitter = jitter
    }

    /// Wait before retry number `attempt` (0 = first retry). Honors `retryAfter` (never above `maxDelay`: longer waits are not retried, see `exceedsCap`).
    public func delay(forRetry attempt: Int, error: ProviderError) -> TimeInterval {
        if case .rateLimited(let retryAfter?) = error { return min(retryAfter, maxDelay) }
        let exponential = baseDelay * pow(2, Double(attempt))
        return min(exponential * (1 + 0.25 * jitter()), maxDelay)
    }

    /// The server asked for a longer pause than `maxDelay`: retrying earlier would only be refused again, so the
    /// error is passed on (`rateLimited`) and the caller decides.
    func exceedsCap(_ error: ProviderError) -> Bool {
        if case .rateLimited(let retryAfter?) = error { return retryAfter > maxDelay }
        return false
    }

    /// Runs `operation`, retrying retryable `ProviderError`s. Cancellation and other errors pass through at once.
    public func run<T: Sendable>(_ operation: @Sendable () async throws -> T) async throws -> T {
        var attempt = 0
        while true {
            try Task.checkCancellation()
            do {
                return try await operation()
            } catch let error as ProviderError where error.isRetryable && attempt < maxRetries && !exceedsCap(error) {
                try await sleep(delay(forRetry: attempt, error: error))
                attempt += 1
            }
        }
    }
}
