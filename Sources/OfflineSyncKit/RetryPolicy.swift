import Foundation

/// Exponential backoff with jitter and a hard retry ceiling.
///
/// Design decision: retry exhaustion routes to a dead-letter queue instead
/// of retrying forever or silently dropping the action — losing a user's
/// write silently is worse than surfacing it, and retrying forever risks
/// the write-ahead queue growing unbounded while the device is offline for
/// an extended period.
public struct RetryPolicy: Sendable {

    public let maxAttempts: Int
    public let baseDelay: TimeInterval
    public let maxDelay: TimeInterval
    /// Injectable so tests can assert exact backoff values without
    /// depending on real randomness.
    public let jitterSource: @Sendable () -> Double

    public init(
        maxAttempts: Int = 5,
        baseDelay: TimeInterval = 1.0,
        maxDelay: TimeInterval = 60.0,
        jitterSource: @escaping @Sendable () -> Double = { Double.random(in: 0.5...1.5) }
    ) {
        // Guard against a nonsensical policy rather than silently accepting
        // zero/negative values that would make `shouldRetry` misbehave.
        self.maxAttempts = Swift.max(1, maxAttempts)
        self.baseDelay = Swift.max(0, baseDelay)
        self.maxDelay = Swift.max(self.baseDelay, maxDelay)
        self.jitterSource = jitterSource
    }

    public func shouldRetry(attemptCount: Int) -> Bool {
        attemptCount < maxAttempts
    }

    /// Delay before the *next* attempt, given how many attempts have
    /// already happened. `attemptCount` is 0-indexed (0 = about to make the
    /// first retry after the initial failed attempt).
    public func delay(forAttemptCount attemptCount: Int) -> TimeInterval {
        let exponential = baseDelay * pow(2.0, Double(Swift.max(0, attemptCount)))
        let capped = Swift.min(exponential, maxDelay)
        return capped * jitterSource()
    }
}
