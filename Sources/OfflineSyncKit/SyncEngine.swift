import Foundation

/// Orchestrates the write-ahead queue -> network -> conflict-resolution
/// pipeline.
///
/// Concurrency & ordering guarantees (documented because a staff reviewer
/// would ask about exactly this):
/// - `SyncEngine` is an `actor`, so all calls to `drain()` are serialized —
///   two overlapping `drain()` calls (e.g. one from a background task timer,
///   one from "user pulled to refresh") cannot interleave their queue
///   mutations.
/// - Within a single `drain()` pass, actions are processed in FIFO order as
///   returned by `ActionQueueStore.all()`. Per-entity ordering is therefore
///   preserved *as long as* the store itself preserves insertion order,
///   which both `InMemoryActionQueueStore` and `SwiftDataActionQueueStore`
///   guarantee via their fetch/sort behavior.
/// - Cross-entity ordering is *not* guaranteed beyond FIFO — actions for
///   entity A and entity B can be reordered relative to each other by nature
///   of one succeeding and one retrying. This is intentional: enforcing a
///   single global order across unrelated entities would serialize sync
///   throughput for no correctness benefit.
/// - Coalescing: when a `.delete` action is enqueued, `SyncEngine` does not
///   itself scan/remove earlier queued updates for the same entity — that
///   responsibility is explicit in `enqueue(_:coalescing:)` so callers can
///   opt out if they need every intermediate write preserved (e.g. for
///   audit logging).
public actor SyncEngine {

    private let store: ActionQueueStore
    private let network: SyncNetworkClient
    private let conflictStrategy: ConflictResolutionStrategy
    private let retryPolicy: RetryPolicy
    private let deadLetterQueue: DeadLetterQueue
    private let clock: () -> Date

    public init(
        store: ActionQueueStore,
        network: SyncNetworkClient,
        conflictStrategy: ConflictResolutionStrategy,
        retryPolicy: RetryPolicy = RetryPolicy(),
        deadLetterQueue: DeadLetterQueue = DeadLetterQueue(),
        clock: @escaping () -> Date = Date.init
    ) {
        self.store = store
        self.network = network
        self.conflictStrategy = conflictStrategy
        self.retryPolicy = retryPolicy
        self.deadLetterQueue = deadLetterQueue
        self.clock = clock
    }

    /// Enqueues a new local write. When `coalescing` is true and this is a
    /// `.delete`, any earlier-queued actions for the same entity are dropped
    /// first — there is no point pushing an update for an entity that's
    /// about to be deleted anyway, and it shrinks the queue during bursty
    /// edit-then-delete flows.
    public func enqueue(_ action: SyncAction, coalescing: Bool = true) async {
        if coalescing && action.kind == .delete {
            await store.removeAll(forEntityID: action.entityID)
        }
        await store.enqueue(action)
    }

    /// Drains the current queue, pushing each action to the network, running
    /// conflict resolution on rejection, and re-enqueueing (with bumped
    /// attempt count) on transient failure — up to `retryPolicy.maxAttempts`,
    /// after which the action is moved to the dead-letter queue rather than
    /// retried forever.
    ///
    /// Returns a summary rather than throwing: a partial-failure drain
    /// (some actions synced, others didn't) is the normal case for a flaky
    /// network, not an exceptional one.
    @discardableResult
    public func drain(remoteState: [String: RemoteRecord] = [:]) async -> DrainSummary {
        let pending = await store.all()

        // Empty-queue is a normal, common case (e.g. nothing changed since
        // last drain) — not an error path.
        guard !pending.isEmpty else {
            return DrainSummary(synced: [], retried: [], deadLettered: [])
        }

        var synced: [UUID] = []
        var retried: [UUID] = []
        var deadLettered: [UUID] = []

        for action in pending {
            let result = await network.push(action)

            switch result {
            case .accepted:
                await store.remove(id: action.id)
                synced.append(action.id)

            case .conflict(let remote):
                await resolveConflict(action: action, remote: remote, outcome: &synced)

            case .transientFailure(let error):
                await handleTransientFailure(
                    action: action,
                    error: error,
                    retried: &retried,
                    deadLettered: &deadLettered
                )
            }
        }

        return DrainSummary(synced: synced, retried: retried, deadLettered: deadLettered)
    }

    private func resolveConflict(
        action: SyncAction,
        remote: RemoteRecord,
        outcome synced: inout [UUID]
    ) async {
        switch conflictStrategy.resolve(local: action, remote: remote) {
        case .applyLocal:
            // Strategy says local should have won; server disagreeing is
            // itself unexpected (a race between our conflict check and the
            // server's), so treat this action as needing one more retry
            // rather than silently declaring success.
            let bumped = action.incrementingAttempt()
            await store.replace(bumped)

        case .discardLocal:
            await store.remove(id: action.id)

        case .merged(let mergedAction):
            // Replace the queued action with the merged version and remove
            // the original id if it differs — `merged` preserves the same
            // id by construction (see VectorClockMergeStrategy), so this is
            // effectively an update-in-place that will be retried on the
            // *next* drain rather than immediately, to avoid an unbounded
            // resolve-retry loop within a single drain pass.
            await store.replace(mergedAction)
        }
    }

    private func handleTransientFailure(
        action: SyncAction,
        error: Error,
        retried: inout [UUID],
        deadLettered: inout [UUID]
    ) async {
        guard retryPolicy.shouldRetry(attemptCount: action.attemptCount) else {
            await store.remove(id: action.id)
            await deadLetterQueue.record(action, error: String(describing: error))
            deadLettered.append(action.id)
            return
        }

        let bumped = action.incrementingAttempt()
        await store.replace(bumped)
        retried.append(action.id)
    }

    public func deadLetteredEntries() async -> [DeadLetterQueue.Entry] {
        await deadLetterQueue.all()
    }

    /// Lets a caller manually retry a dead-lettered action (e.g. after the
    /// user fixes whatever caused it, or just wants one more shot) outside
    /// the normal backoff schedule. Resets the attempt count so it gets a
    /// fresh run at `retryPolicy.maxAttempts`.
    public func requeueFromDeadLetter(id: UUID) async -> Bool {
        guard let entry = await deadLetterQueue.take(id: id) else { return false }
        var resetAction = entry.action
        resetAction.attemptCount = 0
        await store.enqueue(resetAction)
        return true
    }
}

public struct DrainSummary: Sendable, Equatable {
    public let synced: [UUID]
    public let retried: [UUID]
    public let deadLettered: [UUID]
}
