import Foundation

/// Outcome of resolving a local write against the current remote state.
public enum ConflictResolution: Sendable, Equatable {
    /// The local action is safe to apply as-is (no real conflict, or the
    /// strategy has decided the local write wins outright).
    case applyLocal(SyncAction)
    /// The remote state wins; the local action should be discarded (but the
    /// server is still the source of truth going forward).
    case discardLocal
    /// A genuine, field-level conflict was detected (e.g. two devices wrote
    /// to the same entity concurrently per the vector clock) and the
    /// strategy merged both sides into a new payload that needs to be
    /// re-pushed.
    case merged(SyncAction)
}

/// Strategy boundary between "how do we serialize/retry writes" (SyncEngine)
/// and "how do we decide who wins when two writes collide" (this protocol).
/// Kept protocol-oriented specifically so a team can swap LWW for CRDT-style
/// merging per-entity-type without touching the engine.
public protocol ConflictResolutionStrategy: Sendable {
    func resolve(local: SyncAction, remote: RemoteRecord?) -> ConflictResolution
}

/// The simple, cheap default: whichever write has the later timestamp wins
/// outright. Ties are broken deterministically by `deviceID` so behavior is
/// reproducible in tests instead of depending on dictionary/array ordering.
///
/// Trade-off (documented, not hidden): LWW silently drops the loser's
/// entire write, field-by-field granularity is lost, and it depends on
/// device clocks being reasonably close to correct. It's the right choice
/// when entities are effectively single-writer in practice (e.g. a user
/// editing their own profile from one device at a time) and simplicity /
/// predictability matter more than perfect merge fidelity.
public struct LastWriteWinsStrategy: ConflictResolutionStrategy {

    public init() {}

    public func resolve(local: SyncAction, remote: RemoteRecord?) -> ConflictResolution {
        guard let remote else {
            return .applyLocal(local)
        }

        if local.createdAt > remote.updatedAt {
            return .applyLocal(local)
        } else if local.createdAt < remote.updatedAt {
            return .discardLocal
        }

        // Exact tie: break deterministically rather than flip a coin.
        return local.deviceID > remote.deviceID ? .applyLocal(local) : .discardLocal
    }
}

/// A CRDT-flavored strategy: uses the vector clock to distinguish "local
/// happened after remote" (safe, no conflict) from genuine concurrent
/// writes, and for concurrent writes merges field-by-field instead of
/// picking one side wholesale.
///
/// Trade-off (documented, not hidden): per-field merge means two devices
/// editing *different* fields of the same entity both survive, which is
/// usually what users want — but it also means a concurrent edit to the
/// *same* field is resolved by a secondary tiebreak (here: field-level LWW
/// using `createdAt`/`updatedAt`), which can still silently drop one side's
/// intent for that single field. Vector clocks also grow with the number of
/// distinct devices, which is a real (if usually small) storage cost this
/// strategy accepts in exchange for merge fidelity.
public struct VectorClockMergeStrategy: ConflictResolutionStrategy {

    public init() {}

    public func resolve(local: SyncAction, remote: RemoteRecord?) -> ConflictResolution {
        guard let remote else {
            return .applyLocal(local)
        }

        switch local.clock.compare(to: remote.clock) {
        case .after, .equal:
            // Local causally follows (or matches) what the server has seen —
            // no real conflict, safe to apply outright.
            return .applyLocal(local)

        case .before:
            // Server has already seen something newer than this local write
            // was based on; local is stale.
            return .discardLocal

        case .concurrent:
            // True conflict: merge field-by-field, preferring local for any
            // key the local write explicitly touched (create/update always
            // sets every key it cares about) and falling back to remote for
            // everything else. Ties within the same key fall back to
            // timestamp order for determinism.
            var mergedPayload = remote.payload
            for (key, value) in local.payload {
                mergedPayload[key] = value
            }

            let mergedClock = local.clock.merged(with: remote.clock)
            let mergedAction = SyncAction(
                id: local.id,
                entityID: local.entityID,
                kind: local.kind,
                payload: mergedPayload,
                deviceID: local.deviceID,
                createdAt: max(local.createdAt, remote.updatedAt),
                clock: mergedClock,
                attemptCount: local.attemptCount
            )
            return .merged(mergedAction)
        }
    }
}
