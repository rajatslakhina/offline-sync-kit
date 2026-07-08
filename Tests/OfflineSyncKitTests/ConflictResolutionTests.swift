import XCTest
@testable import OfflineSyncKit

final class ConflictResolutionTests: XCTestCase {

    // MARK: - Last Write Wins

    func testLWWNoRemoteAppliesLocal() {
        let strategy = LastWriteWinsStrategy()
        let action = makeAction(entityID: "e1", payload: ["title": "local"], createdAt: Date())
        let result = strategy.resolve(local: action, remote: nil)
        XCTAssertEqual(result, .applyLocal(action))
    }

    func testLWWLocalNewerWins() {
        let strategy = LastWriteWinsStrategy()
        let now = Date()
        let action = makeAction(entityID: "e1", payload: ["title": "local"], createdAt: now)
        let remote = RemoteRecord(
            entityID: "e1", payload: ["title": "remote"],
            updatedAt: now.addingTimeInterval(-10), deviceID: "device-b", clock: VectorClock()
        )
        XCTAssertEqual(strategy.resolve(local: action, remote: remote), .applyLocal(action))
    }

    func testLWWRemoteNewerDiscardsLocal() {
        let strategy = LastWriteWinsStrategy()
        let now = Date()
        let action = makeAction(entityID: "e1", payload: ["title": "local"], createdAt: now)
        let remote = RemoteRecord(
            entityID: "e1", payload: ["title": "remote"],
            updatedAt: now.addingTimeInterval(10), deviceID: "device-b", clock: VectorClock()
        )
        XCTAssertEqual(strategy.resolve(local: action, remote: remote), .discardLocal)
    }

    func testLWWExactTieBreaksDeterministicallyByDeviceID() {
        let strategy = LastWriteWinsStrategy()
        let now = Date()
        let local = makeAction(entityID: "e1", payload: [:], createdAt: now, deviceID: "zzz")
        let remote = RemoteRecord(
            entityID: "e1", payload: [:], updatedAt: now, deviceID: "aaa", clock: VectorClock()
        )
        // "zzz" > "aaa" lexicographically -> local should win the tiebreak.
        XCTAssertEqual(strategy.resolve(local: local, remote: remote), .applyLocal(local))

        let local2 = makeAction(entityID: "e1", payload: [:], createdAt: now, deviceID: "aaa")
        let remote2 = RemoteRecord(
            entityID: "e1", payload: [:], updatedAt: now, deviceID: "zzz", clock: VectorClock()
        )
        XCTAssertEqual(strategy.resolve(local: local2, remote: remote2), .discardLocal)
    }

    // MARK: - Vector Clock Merge

    func testVectorClockLocalAfterRemoteAppliesOutright() {
        let strategy = VectorClockMergeStrategy()
        let remoteClock = VectorClock(counters: ["device-a": 1])
        let localClock = remoteClock.incrementing("device-a")
        let local = makeAction(entityID: "e1", payload: ["title": "v2"], clock: localClock)
        let remote = RemoteRecord(
            entityID: "e1", payload: ["title": "v1"], updatedAt: Date(),
            deviceID: "device-a", clock: remoteClock
        )
        XCTAssertEqual(strategy.resolve(local: local, remote: remote), .applyLocal(local))
    }

    func testVectorClockLocalBeforeRemoteDiscards() {
        let strategy = VectorClockMergeStrategy()
        let localClock = VectorClock(counters: ["device-a": 1])
        let remoteClock = localClock.incrementing("device-a")
        let local = makeAction(entityID: "e1", payload: ["title": "stale"], clock: localClock)
        let remote = RemoteRecord(
            entityID: "e1", payload: ["title": "fresh"], updatedAt: Date(),
            deviceID: "device-a", clock: remoteClock
        )
        XCTAssertEqual(strategy.resolve(local: local, remote: remote), .discardLocal)
    }

    func testVectorClockConcurrentWritesMergeDisjointFields() {
        // Two devices, offline, each edit a *different* field of the same
        // entity. This is the case CRDT-style merge exists to handle better
        // than LWW: both edits should survive.
        let strategy = VectorClockMergeStrategy()
        let localClock = VectorClock(counters: ["device-a": 1, "device-b": 0])
        let remoteClock = VectorClock(counters: ["device-a": 0, "device-b": 1])

        let local = makeAction(
            entityID: "e1", payload: ["title": "new title"], deviceID: "device-a", clock: localClock
        )
        let remote = RemoteRecord(
            entityID: "e1", payload: ["description": "new description"],
            updatedAt: Date(), deviceID: "device-b", clock: remoteClock
        )

        guard case .merged(let merged) = strategy.resolve(local: local, remote: remote) else {
            return XCTFail("expected a merge for concurrent writes")
        }
        XCTAssertEqual(merged.payload["title"], "new title")
        XCTAssertEqual(merged.payload["description"], "new description")
        // Merged clock must dominate both inputs.
        XCTAssertEqual(merged.clock.compare(to: localClock), .after)
        XCTAssertEqual(merged.clock.compare(to: remoteClock), .after)
    }

    func testVectorClockConcurrentSameFieldLocalOverwrites() {
        // Same field touched by both sides concurrently: documented
        // trade-off is local wins for keys it explicitly set.
        let strategy = VectorClockMergeStrategy()
        let localClock = VectorClock(counters: ["device-a": 1, "device-b": 0])
        let remoteClock = VectorClock(counters: ["device-a": 0, "device-b": 1])

        let local = makeAction(entityID: "e1", payload: ["title": "local wins"], clock: localClock)
        let remote = RemoteRecord(
            entityID: "e1", payload: ["title": "remote loses"],
            updatedAt: Date(), deviceID: "device-b", clock: remoteClock
        )

        guard case .merged(let merged) = strategy.resolve(local: local, remote: remote) else {
            return XCTFail("expected a merge for concurrent writes")
        }
        XCTAssertEqual(merged.payload["title"], "local wins")
    }

    // MARK: - helpers

    private func makeAction(
        entityID: String,
        payload: [String: String],
        createdAt: Date = Date(),
        deviceID: String = "device-a",
        clock: VectorClock = VectorClock()
    ) -> SyncAction {
        SyncAction(
            entityID: entityID, kind: .update, payload: payload,
            deviceID: deviceID, createdAt: createdAt, clock: clock
        )
    }
}
