#if canImport(SwiftData)
import Foundation
import SwiftData

/// The real, on-device implementation of `ActionQueueStore`, backed by
/// SwiftData so the write-ahead queue survives app relaunches and device
/// reboots — the whole point of a write-ahead queue is that it outlives the
/// process that created it.
///
/// This file is compiled out entirely on platforms without SwiftData (e.g.
/// this package's headless Linux CI target), which is why `SyncEngine`'s
/// core logic is tested exclusively against `InMemoryActionQueueStore`
/// instead — see `ActionQueueStore.swift` for that split.
@available(iOS 17, macOS 14, *)
@Model
public final class PersistedSyncAction {
    @Attribute(.unique) public var id: UUID
    public var entityID: String
    public var kindRaw: String
    public var payloadData: Data
    public var deviceID: String
    public var createdAt: Date
    public var clockData: Data
    public var attemptCount: Int

    public init(action: SyncAction) throws {
        self.id = action.id
        self.entityID = action.entityID
        self.kindRaw = action.kind.rawValue
        self.payloadData = try JSONEncoder().encode(action.payload)
        self.deviceID = action.deviceID
        self.createdAt = action.createdAt
        self.clockData = try JSONEncoder().encode(action.clock)
        self.attemptCount = action.attemptCount
    }

    /// Reconstructs the value-type `SyncAction` this row represents.
    /// Throws rather than force-unwrapping/crashing if a row was somehow
    /// persisted with a `kindRaw` that no longer matches `SyncAction.Kind` —
    /// e.g. after a future migration removes a case.
    public func toSyncAction() throws -> SyncAction {
        guard let kind = SyncAction.Kind(rawValue: kindRaw) else {
            throw SwiftDataActionQueueStore.StoreError.corruptRecord(id: id)
        }
        let payload = try JSONDecoder().decode([String: String].self, from: payloadData)
        let clock = try JSONDecoder().decode(VectorClock.self, from: clockData)
        return SyncAction(
            id: id,
            entityID: entityID,
            kind: kind,
            payload: payload,
            deviceID: deviceID,
            createdAt: createdAt,
            clock: clock,
            attemptCount: attemptCount
        )
    }
}

@available(iOS 17, macOS 14, *)
public final class SwiftDataActionQueueStore: ActionQueueStore, @unchecked Sendable {

    public enum StoreError: Error {
        case corruptRecord(id: UUID)
    }

    private let modelContainer: ModelContainer
    /// Every access is funneled through this actor to serialize
    /// ModelContext use — ModelContext is not thread-safe, and the engine
    /// may be driven from multiple concurrent Tasks.
    private let executor = SwiftDataExecutor()

    public init(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
    }

    public func enqueue(_ action: SyncAction) async {
        await executor.run(modelContainer) { context in
            if let row = try? PersistedSyncAction(action: action) {
                context.insert(row)
            }
        }
    }

    public func all() async -> [SyncAction] {
        await executor.run(modelContainer) { context in
            let descriptor = FetchDescriptor<PersistedSyncAction>(
                sortBy: [SortDescriptor(\.createdAt, order: .forward)]
            )
            let rows = (try? context.fetch(descriptor)) ?? []
            return rows.compactMap { try? $0.toSyncAction() }
        } ?? []
    }

    public func remove(id: UUID) async {
        await executor.run(modelContainer) { context in
            let descriptor = FetchDescriptor<PersistedSyncAction>(
                predicate: #Predicate { $0.id == id }
            )
            if let row = try? context.fetch(descriptor).first {
                context.delete(row)
            }
        }
    }

    public func replace(_ action: SyncAction) async {
        await executor.run(modelContainer) { context in
            let id = action.id
            let descriptor = FetchDescriptor<PersistedSyncAction>(
                predicate: #Predicate { $0.id == id }
            )
            guard let row = try? context.fetch(descriptor).first else { return }
            row.attemptCount = action.attemptCount
            row.payloadData = (try? JSONEncoder().encode(action.payload)) ?? row.payloadData
            row.clockData = (try? JSONEncoder().encode(action.clock)) ?? row.clockData
        }
    }

    public func removeAll(forEntityID entityID: String) async {
        await executor.run(modelContainer) { context in
            let descriptor = FetchDescriptor<PersistedSyncAction>(
                predicate: #Predicate { $0.entityID == entityID }
            )
            let rows = (try? context.fetch(descriptor)) ?? []
            for row in rows { context.delete(row) }
        }
    }
}

/// Serializes all ModelContext work onto a single actor so concurrent
/// callers (e.g. a UI-triggered enqueue racing the background sync loop's
/// drain) can't corrupt SwiftData's non-thread-safe context.
@available(iOS 17, macOS 14, *)
private actor SwiftDataExecutor {
    @discardableResult
    func run<T>(_ container: ModelContainer, _ work: @escaping (ModelContext) -> T) async -> T {
        let context = ModelContext(container)
        return work(context)
    }
}
#endif
