import XCTest
@testable import OfflineSyncKit

final class RetryPolicyTests: XCTestCase {

    func testZeroMaxAttemptsClampsToOne() {
        // A caller passing 0 (or a negative number) must not produce a
        // policy that never retries anything in a way that breaks
        // `shouldRetry`'s invariant — clamp to a sane floor instead of
        // propagating a nonsensical config.
        let policy = RetryPolicy(maxAttempts: 0)
        XCTAssertEqual(policy.maxAttempts, 1)
    }

    func testNegativeMaxAttemptsClampsToOne() {
        let policy = RetryPolicy(maxAttempts: -5)
        XCTAssertEqual(policy.maxAttempts, 1)
    }

    func testShouldRetryRespectsMaxAttempts() {
        let policy = RetryPolicy(maxAttempts: 3)
        XCTAssertTrue(policy.shouldRetry(attemptCount: 0))
        XCTAssertTrue(policy.shouldRetry(attemptCount: 2))
        XCTAssertFalse(policy.shouldRetry(attemptCount: 3))
        XCTAssertFalse(policy.shouldRetry(attemptCount: 100))
    }

    func testDelayGrowsExponentiallyAndRespectsCap() {
        let policy = RetryPolicy(maxAttempts: 10, baseDelay: 1, maxDelay: 10, jitterSource: { 1.0 })
        XCTAssertEqual(policy.delay(forAttemptCount: 0), 1)
        XCTAssertEqual(policy.delay(forAttemptCount: 1), 2)
        XCTAssertEqual(policy.delay(forAttemptCount: 2), 4)
        // 2^5 = 32, but capped at maxDelay = 10.
        XCTAssertEqual(policy.delay(forAttemptCount: 5), 10)
    }

    func testNegativeAttemptCountDoesNotCrashOrGoNegativeDelay() {
        let policy = RetryPolicy(baseDelay: 1, maxDelay: 10, jitterSource: { 1.0 })
        XCTAssertEqual(policy.delay(forAttemptCount: -3), 1)
    }

    func testMaxDelayBelowBaseDelayIsCorrectedUpward() {
        // If a caller misconfigures maxDelay < baseDelay, the policy should
        // not silently produce a cap that's smaller than the first delay.
        let policy = RetryPolicy(baseDelay: 5, maxDelay: 1)
        XCTAssertEqual(policy.maxDelay, 5)
    }
}
