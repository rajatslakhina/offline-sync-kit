import Foundation

/// A single locally-recorded write, sitting in the write-ahead queue until a
/// background sync engine gets a chance to ship it to the server.
///
/// `id` is a stable UUID generated at write time (not at send time) so that
/// retries and re-enqueues remain idempotent on the server: replaying the
/// same action twice must be a safe no-op, not a duplicate write. Servers in
/// this design are expected to de-duplicate on `id`.
public struct SyncAction: Codable, Identifiable, Equatable, Sendable {

    public enum Kind: String, Codable, Sendable {
        case create
        case update
        case delete
    }

    public let id: UUID
    public let entityID: String
    public let kind: Kind
    public let payload: [String: String]
    public let deviceID: String
    public let createdAt: Date
    public let clock: VectorClock

    /// How many times this action has already been attempted. Used by
    /// `RetryPolicy` to compute backoff and eventually route to the
    /// dead-letter queue.
    public var attemptCount: Int

    public init(
        id: UUID = UUID(),
        entityID: String,
        kind: Kind,
        payload: [String: String],
        deviceID: String,
        createdAt: Date = Date(),
        clock: VectorClock,
        attemptCount: Int = 0
    ) {
        self.id = id
        self.entityID = entityID
        self.kind = kind
        self.payload = payload
        self.deviceID = deviceID
        self.createdAt = createdAt
        self.clock = clock
        self.attemptCount = attemptCount
    }

    /// Returns a copy with the attempt count bumped — used when the engine
    /// re-enqueues a failed action rather than dropping it.
    func incrementingAttempt() -> SyncAction {
        var copy = self
        copy.attemptCount += 1
        return copy
    }
}

/// The authoritative remote state for an entity, as last observed from the
/// server. Used as the "other side" of conflict resolution.
public struct RemoteRecord: Codable, Equatable, Sendable {
    public let entityID: String
    public let payload: [String: String]
    public let updatedAt: Date
    public let deviceID: String
    public let clock: VectorClock

    public init(
        entityID: String,
        payload: [String: String],
        updatedAt: Date,
        deviceID: String,
        clock: VectorClock
    ) {
        self.entityID = entityID
        self.payload = payload
        self.updatedAt = updatedAt
        self.deviceID = deviceID
        self.clock = clock
    }
}
