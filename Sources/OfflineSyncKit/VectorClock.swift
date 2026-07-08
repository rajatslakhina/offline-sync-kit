import Foundation

/// A vector clock used to detect causal ordering / concurrency between writes
/// made on different devices while offline.
///
/// Design decision: we key by a stable `deviceID` (not a global sequence
/// number) because devices generate writes independently while offline and
/// have no way to coordinate a shared counter until they reconnect. Each
/// device only ever increments its own slot, which is what makes vector
/// clocks safe to merge without a central coordinator.
public struct VectorClock: Codable, Equatable, Sendable {

    /// deviceID -> monotonically increasing local counter.
    private var counters: [String: Int]

    public init(counters: [String: Int] = [:]) {
        self.counters = counters
    }

    public subscript(deviceID: String) -> Int {
        counters[deviceID, default: 0]
    }

    /// Returns a new clock with `deviceID`'s counter incremented by one.
    /// Pure/non-mutating so callers can't accidentally share clock state
    /// across actions.
    public func incrementing(_ deviceID: String) -> VectorClock {
        var copy = counters
        copy[deviceID, default: 0] += 1
        return VectorClock(counters: copy)
    }

    /// The causal relationship between two clocks.
    public enum Ordering: Sendable, Equatable {
        case before          // self happened-before other
        case after            // self happened-after other
        case equal             // identical
        case concurrent  // neither dominates -> true conflict
    }

    /// Compares `self` against `other` using the standard vector-clock
    /// dominance rule: self <= other iff every counter in self is <= the
    /// matching counter in other.
    public func compare(to other: VectorClock) -> Ordering {
        if self == other { return .equal }

        let allDevices = Set(counters.keys).union(other.counters.keys)
        var selfLessOrEqual = true
        var otherLessOrEqual = true

        for device in allDevices {
            let lhs = self[device]
            let rhs = other[device]
            if lhs > rhs { otherLessOrEqual = false }
            if lhs < rhs { selfLessOrEqual = false }
        }

        switch (selfLessOrEqual, otherLessOrEqual) {
        case (true, false): return .before
        case (false, true): return .after
        case (true, true): return .equal // shouldn't hit given the == check above, kept for safety
        case (false, false): return .concurrent
        }
    }

    /// Element-wise max merge — the standard way to fold two vector clocks
    /// back together once both sides of a conflict have been reconciled.
    public func merged(with other: VectorClock) -> VectorClock {
        var result = counters
        for (device, count) in other.counters {
            result[device] = Swift.max(result[device, default: 0], count)
        }
        return VectorClock(counters: result)
    }
}
