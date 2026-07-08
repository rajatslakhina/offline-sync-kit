import XCTest
@testable import OfflineSyncKit

final class VectorClockTests: XCTestCase {

    func testEmptyClocksAreEqual() {
        let a = VectorClock()
        let b = VectorClock()
        XCTAssertEqual(a.compare(to: b), .equal)
    }

    func testIncrementIsPureNotMutating() {
        let original = VectorClock()
        let incremented = original.incrementing("device-a")
        // The original must be untouched — a struct-level guarantee that
        // matters because SyncAction stores a `clock` value and callers
        // must not be able to accidentally share/mutate it across actions.
        XCTAssertEqual(original["device-a"], 0)
        XCTAssertEqual(incremented["device-a"], 1)
    }

    func testStrictlyAfterOtherClock() {
        let base = VectorClock(counters: ["a": 1])
        let ahead = base.incrementing("a")
        XCTAssertEqual(ahead.compare(to: base), .after)
        XCTAssertEqual(base.compare(to: ahead), .before)
    }

    func testConcurrentClocksNeitherDominates() {
        // Two devices each advance only their own slot independently while
        // offline — this is the exact scenario a vector clock exists to
        // detect as a genuine conflict rather than a false ordering.
        let a = VectorClock(counters: ["device-a": 1, "device-b": 0])
        let b = VectorClock(counters: ["device-a": 0, "device-b": 1])
        XCTAssertEqual(a.compare(to: b), .concurrent)
        XCTAssertEqual(b.compare(to: a), .concurrent)
    }

    func testMergeTakesElementwiseMax() {
        let a = VectorClock(counters: ["device-a": 3, "device-b": 1])
        let b = VectorClock(counters: ["device-a": 1, "device-b": 5, "device-c": 2])
        let merged = a.merged(with: b)
        XCTAssertEqual(merged["device-a"], 3)
        XCTAssertEqual(merged["device-b"], 5)
        XCTAssertEqual(merged["device-c"], 2)
    }

    func testMissingDeviceKeyDefaultsToZeroNotCrash() {
        // Bounds-check equivalent for a dictionary-backed clock: querying a
        // device that has never written must not crash or throw, it's a
        // legitimate "hasn't written yet" state.
        let clock = VectorClock(counters: ["device-a": 2])
        XCTAssertEqual(clock["device-never-seen"], 0)
    }
}
