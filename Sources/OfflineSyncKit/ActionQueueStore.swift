import Foundation

/// Persistence boundary for the write-ahead queue.
///
/// Design decision: this is a protocol, not a concrete SwiftData type,
/// specifically so the core sync/conflict/retry logic in `SyncEngine` can be
/// unit-tested against `InMemoryActionQueueStore` without touching disk or
/// requiring an Apple platform — the actual on-device store
/// (`SwiftDataActionQueueStore`) lives behind the same interface and is only
/// compiled on platforms where SwiftData exists. This mirrors how the real
/// production code would be structured: swap the store, keep the engine.
public protocol ActionQueueStore: Sendable {
    /// Appends an action to the tail of the queue. Must preserve FIFO order
    /// per `entityID` — the engine relies on this for its ordering guarantee.
    func enqueue(_ action: SyncAction) async

    /// Returns actions in FIFO order (oldest first), without removing them.
    func all() async -> [SyncAction]

    /// Removes a specific action by id (e.g. after a successful sync).
    func remove(id: UUID) async

    /// Replaces an existing action (e.g. after bumping its attempt count for
    /// a retry). If no action with a matching id exists, this is a no-op —
    /// callers must not assume the replace always succeeds silently.
    func replace(_ action: SyncAction) async

    /// Removes every action for a given entity. Used when a `.delete`
    /// action makes earlier queued `.update`s for the same entity moot
    /// (coalescing).
    func removeAll(forEntityID entityID: String) async
}

/// A simple, deterministic in-memory implementation. This is what the test
/// suite exercises directly, and what a headless (non-Apple, non-Xcode)
/// environment can compile and run without SwiftData.
public actor InMemoryActionQueueStore: ActionQueueStore {

    private var storage: [SyncAction] = []

    public init() {}

    public func enqueue(_ action: SyncAction) async {
        storage.append(action)
    }

    public func all() async -> [SyncAction] {
        storage
    }

    public func remove(id: UUID) async {
        storage.removeAll { $0.id == id }
    }

    public func replace(_ action: SyncAction) async {
        guard let index = storage.firstIndex(where: { $0.id == action.id }) else { return }
        storage[index] = action
    }

    public func removeAll(forEntityID entityID: String) async {
        storage.removeAll { $0.entityID == entityID }
    }
}
