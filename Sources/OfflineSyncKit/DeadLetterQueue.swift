import Foundation

/// Where actions go once `RetryPolicy` has exhausted their attempts. Kept
/// as its own actor (rather than a flag on the main queue) so a caller can
/// surface "these writes need your attention" UI without scanning the live
/// queue for high attempt counts.
public actor DeadLetterQueue {

    public struct Entry: Sendable, Equatable {
        public let action: SyncAction
        public let lastError: String
        public let failedAt: Date
    }

    private var entries: [Entry] = []

    public init() {}

    public func record(_ action: SyncAction, error: String) {
        entries.append(Entry(action: action, lastError: error, failedAt: Date()))
    }

    public func all() -> [Entry] {
        entries
    }

    /// Removes and returns an entry so the caller can attempt a manual,
    /// user-initiated retry outside the normal backoff schedule.
    public func take(id: UUID) -> Entry? {
        guard let index = entries.firstIndex(where: { $0.action.id == id }) else { return nil }
        return entries.remove(at: index)
    }

    public func clear() {
        entries.removeAll()
    }
}
