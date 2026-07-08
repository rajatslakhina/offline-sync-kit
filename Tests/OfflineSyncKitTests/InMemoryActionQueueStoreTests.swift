import XCTest
@testable import OfflineSyncKit

final class InMemoryActionQueueStoreTests: XCTestCase {

    func testEmptyStoreReturnsEmptyArrayNotCrash() async {
        let store = InMemoryActionQueueStore()
        let all = await store.all()
        XCTAssertTrue(all.isEmpty)
    }

    func testRemovingFromEmptyStoreIsNoOp() async {
        let store = InMemoryActionQueueStore()
        await store.remove(id: UUID())
        let all = await store.all()
        XCTAssertTrue(all.isEmpty)
    }

    func testReplacingNonExistentActionIsNoOp() async {
        let store = InMemoryActionQueueStore()
        let phantom = SyncAction(entityID: "ghost", kind: .update, payload: [:], deviceID: "d", clock: VectorClock())
        await store.replace(phantom)
        let all = await store.all()
        XCTAssertTrue(all.isEmpty)
    }

    func testEnqueuePreservesFIFOOrder() async {
        let store = InMemoryActionQueueStore()
        let first = SyncAction(entityID: "e1", kind: .update, payload: ["n": "1"], deviceID: "d", clock: VectorClock())
        let second = SyncAction(entityID: "e1", kind: .update, payload: ["n": "2"], deviceID: "d", clock: VectorClock())
        await store.enqueue(first)
        await store.enqueue(second)
        let all = await store.all()
        XCTAssertEqual(all.map(\.id), [first.id, second.id])
    }

    func testRemoveAllForEntityIDOnlyAffectsThatEntity() async {
        let store = InMemoryActionQueueStore()
        let a = SyncAction(entityID: "e1", kind: .update, payload: [:], deviceID: "d", clock: VectorClock())
        let b = SyncAction(entityID: "e2", kind: .update, payload: [:], deviceID: "d", clock: VectorClock())
        await store.enqueue(a)
        await store.enqueue(b)
        await store.removeAll(forEntityID: "e1")
        let remaining = await store.all()
        XCTAssertEqual(remaining.map(\.id), [b.id])
    }
}
