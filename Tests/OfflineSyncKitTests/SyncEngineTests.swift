import XCTest
@testable import OfflineSyncKit

final class SyncEngineTests: XCTestCase {

    func testDrainingEmptyQueueDoesNothingAndDoesNotCrash() async {
        let engine = SyncEngine(
            store: InMemoryActionQueueStore(),
            network: MockFlakyNetworkClient(),
            conflictStrategy: LastWriteWinsStrategy()
        )
        let summary = await engine.drain()
        XCTAssertTrue(summary.synced.isEmpty)
        XCTAssertTrue(summary.retried.isEmpty)
        XCTAssertTrue(summary.deadLettered.isEmpty)
    }

    func testSuccessfulPushRemovesActionFromQueue() async {
        let store = InMemoryActionQueueStore()
        let engine = SyncEngine(
            store: store,
            network: MockFlakyNetworkClient(configuration: .init(failureRate: 0)),
            conflictStrategy: LastWriteWinsStrategy()
        )
        let action = SyncAction(entityID: "e1", kind: .create, payload: ["a": "1"], deviceID: "d", clock: VectorClock())
        await engine.enqueue(action)

        let summary = await engine.drain()
        XCTAssertEqual(summary.synced, [action.id])
        let remaining = await store.all()
        XCTAssertTrue(remaining.isEmpty)
    }

    func testTransientFailureReEnqueuesWithBumpedAttemptCount() async {
        let store = InMemoryActionQueueStore()
        let engine = SyncEngine(
            store: store,
            network: MockFlakyNetworkClient(configuration: .init(failureRate: 1.0)), // always fails
            conflictStrategy: LastWriteWinsStrategy(),
            retryPolicy: RetryPolicy(maxAttempts: 5)
        )
        let action = SyncAction(entityID: "e1", kind: .update, payload: [:], deviceID: "d", clock: VectorClock())
        await engine.enqueue(action)

        let summary = await engine.drain()
        XCTAssertEqual(summary.retried, [action.id])
        let remaining = await store.all()
        XCTAssertEqual(remaining.first?.attemptCount, 1)
    }

    func testRetryExhaustionRoutesToDeadLetterQueueNotInfiniteRetry() async {
        // This is the specific failure mode the design doc calls out: a
        // permanently-unreachable server (or a permanently-invalid action)
        // must not retry forever and must not silently vanish.
        let store = InMemoryActionQueueStore()
        let engine = SyncEngine(
            store: store,
            network: MockFlakyNetworkClient(configuration: .init(failureRate: 1.0)),
            conflictStrategy: LastWriteWinsStrategy(),
            retryPolicy: RetryPolicy(maxAttempts: 2)
        )
        let action = SyncAction(entityID: "e1", kind: .update, payload: [:], deviceID: "d", clock: VectorClock())
        await engine.enqueue(action)

        // Attempt 1: attemptCount 0 -> shouldRetry(0 < 2) true -> retried, bumped to 1.
        _ = await engine.drain()
        // Attempt 2: attemptCount 1 -> shouldRetry(1 < 2) true -> retried, bumped to 2.
        _ = await engine.drain()
        // Attempt 3: attemptCount 2 -> shouldRetry(2 < 2) false -> dead-lettered.
        let summary = await engine.drain()

        XCTAssertEqual(summary.deadLettered, [action.id])
        let remaining = await store.all()
        XCTAssertTrue(remaining.isEmpty, "dead-lettered actions must be removed from the live queue")

        let deadLettered = await engine.deadLetteredEntries()
        XCTAssertEqual(deadLettered.count, 1)
        XCTAssertEqual(deadLettered.first?.action.id, action.id)
    }

    func testRequeueFromDeadLetterResetsAttemptCount() async {
        let store = InMemoryActionQueueStore()
        let engine = SyncEngine(
            store: store,
            network: MockFlakyNetworkClient(configuration: .init(failureRate: 1.0)),
            conflictStrategy: LastWriteWinsStrategy(),
            retryPolicy: RetryPolicy(maxAttempts: 1)
        )
        let action = SyncAction(entityID: "e1", kind: .update, payload: [:], deviceID: "d", clock: VectorClock())
        await engine.enqueue(action)
        _ = await engine.drain() // attemptCount 0 -> shouldRetry(0<1) true -> retried to 1
        _ = await engine.drain() // attemptCount 1 -> shouldRetry(1<1) false -> dead-lettered

        var deadLettered = await engine.deadLetteredEntries()
        XCTAssertEqual(deadLettered.count, 1)

        let requeued = await engine.requeueFromDeadLetter(id: action.id)
        XCTAssertTrue(requeued)

        deadLettered = await engine.deadLetteredEntries()
        XCTAssertTrue(deadLettered.isEmpty)

        let liveQueue = await store.all()
        XCTAssertEqual(liveQueue.first?.attemptCount, 0)
    }

    func testRequeueFromDeadLetterWithUnknownIDReturnsFalseNotCrash() async {
        let engine = SyncEngine(
            store: InMemoryActionQueueStore(),
            network: MockFlakyNetworkClient(),
            conflictStrategy: LastWriteWinsStrategy()
        )
        let requeued = await engine.requeueFromDeadLetter(id: UUID())
        XCTAssertFalse(requeued)
    }

    func testConflictWithMergeStrategyReplacesQueuedActionWithMergedVersion() async {
        let store = InMemoryActionQueueStore()
        let localClock = VectorClock(counters: ["device-a": 1, "device-b": 0])
        let remoteClock = VectorClock(counters: ["device-a": 0, "device-b": 1])
        let remote = RemoteRecord(
            entityID: "e1", payload: ["description": "server value"],
            updatedAt: Date(), deviceID: "device-b", clock: remoteClock
        )
        let network = MockFlakyNetworkClient(
            configuration: .init(forcedConflicts: ["e1": remote])
        )
        let engine = SyncEngine(
            store: store,
            network: network,
            conflictStrategy: VectorClockMergeStrategy()
        )
        let action = SyncAction(
            entityID: "e1", kind: .update, payload: ["title": "client value"],
            deviceID: "device-a", clock: localClock
        )
        await engine.enqueue(action)

        let summary = await engine.drain()
        // Merged actions stay in the queue for the *next* drain, not synced
        // immediately in the same pass (documented in SyncEngine to avoid
        // an unbounded resolve-retry loop within one drain call).
        XCTAssertTrue(summary.synced.isEmpty)

        let remaining = await store.all()
        XCTAssertEqual(remaining.count, 1)
        XCTAssertEqual(remaining.first?.payload["title"], "client value")
        XCTAssertEqual(remaining.first?.payload["description"], "server value")
    }

    func testDeleteActionCoalescesEarlierQueuedUpdatesForSameEntity() async {
        let store = InMemoryActionQueueStore()
        let engine = SyncEngine(
            store: store,
            network: MockFlakyNetworkClient(),
            conflictStrategy: LastWriteWinsStrategy()
        )
        let update1 = SyncAction(entityID: "e1", kind: .update, payload: ["n": "1"], deviceID: "d", clock: VectorClock())
        let update2 = SyncAction(entityID: "e1", kind: .update, payload: ["n": "2"], deviceID: "d", clock: VectorClock())
        let unrelated = SyncAction(entityID: "e2", kind: .update, payload: [:], deviceID: "d", clock: VectorClock())
        let delete = SyncAction(entityID: "e1", kind: .delete, payload: [:], deviceID: "d", clock: VectorClock())

        await engine.enqueue(update1)
        await engine.enqueue(update2)
        await engine.enqueue(unrelated)
        await engine.enqueue(delete) // default coalescing: true

        let remaining = await store.all()
        // update1 and update2 should have been dropped; unrelated survives;
        // delete itself is enqueued.
        XCTAssertEqual(remaining.map(\.id).sorted(), [unrelated.id, delete.id].sorted())
    }

    func testDeleteActionWithCoalescingDisabledPreservesEarlierUpdates() async {
        let store = InMemoryActionQueueStore()
        let engine = SyncEngine(
            store: store,
            network: MockFlakyNetworkClient(),
            conflictStrategy: LastWriteWinsStrategy()
        )
        let update = SyncAction(entityID: "e1", kind: .update, payload: [:], deviceID: "d", clock: VectorClock())
        let delete = SyncAction(entityID: "e1", kind: .delete, payload: [:], deviceID: "d", clock: VectorClock())

        await engine.enqueue(update)
        await engine.enqueue(delete, coalescing: false)

        let remaining = await store.all()
        XCTAssertEqual(remaining.count, 2)
    }

    func testMixedSuccessAndFailureInSingleDrainReportsBoth() async {
        // Out-of-order / partial-failure delivery within one drain pass:
        // one action succeeds, another fails transiently. The engine must
        // not let one action's outcome affect another's.
        let store = InMemoryActionQueueStore()
        var callCount = 0
        let network = FlipFlopNetworkClient(shouldFail: { count in
            callCount = count
            return count == 1 // second call fails, first succeeds
        })
        let engine = SyncEngine(store: store, network: network, conflictStrategy: LastWriteWinsStrategy())

        let first = SyncAction(entityID: "e1", kind: .create, payload: [:], deviceID: "d", clock: VectorClock())
        let second = SyncAction(entityID: "e2", kind: .create, payload: [:], deviceID: "d", clock: VectorClock())
        await engine.enqueue(first)
        await engine.enqueue(second)

        let summary = await engine.drain()
        XCTAssertEqual(summary.synced, [first.id])
        XCTAssertEqual(summary.retried, [second.id])
        _ = callCount
    }
}

/// Deterministic client whose N-th call (0-indexed) fails per the supplied
/// predicate — used to test partial-failure-within-one-drain behavior
/// without relying on `MockFlakyNetworkClient`'s randomness.
private final class FlipFlopNetworkClient: SyncNetworkClient, @unchecked Sendable {
    private var count = 0
    private let shouldFail: (Int) -> Bool

    init(shouldFail: @escaping (Int) -> Bool) {
        self.shouldFail = shouldFail
    }

    func push(_ action: SyncAction) async -> SyncPushResult {
        let current = count
        count += 1
        if shouldFail(current) {
            return .transientFailure(MockFlakyNetworkClient.TransientNetworkError())
        }
        return .accepted
    }
}
