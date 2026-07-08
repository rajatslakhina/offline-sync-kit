import Foundation

/// Result of attempting to push a single action to the server.
public enum SyncPushResult: Sendable, Equatable {
    /// The server accepted the action outright.
    case accepted
    /// The server rejected it because its own record has moved on — carries
    /// the current authoritative record so the engine can run conflict
    /// resolution and retry with a merged/adjusted action.
    case conflict(RemoteRecord)
    /// Transient failure (timeout, 5xx, offline) — safe to retry per
    /// `RetryPolicy`.
    case transientFailure(Error)
}

/// Network boundary the engine talks to. Kept minimal and protocol-based so
/// tests can inject deterministic and chaotic implementations without any
/// real networking.
public protocol SyncNetworkClient: Sendable {
    func push(_ action: SyncAction) async -> SyncPushResult
}

/// A network client that deliberately misbehaves — drops requests, times
/// out, and occasionally reports conflicts — so `SyncEngine`'s retry/backoff
/// and conflict-handling paths can be exercised deterministically in tests
/// instead of hoping a real flaky network shows up during CI.
public final class MockFlakyNetworkClient: SyncNetworkClient, @unchecked Sendable {

    public struct Configuration: Sendable {
        /// Probability (0...1) that a call fails transiently.
        public var failureRate: Double
        /// Fixed sequence of `RemoteRecord`s to report as conflicts, keyed
        /// by entityID — lets a test force a specific conflict scenario
        /// deterministically rather than relying on randomness for it.
        public var forcedConflicts: [String: RemoteRecord]
        /// Injectable randomness source so tests are deterministic even
        /// when exercising `failureRate`.
        public var randomSource: () -> Double

        public init(
            failureRate: Double = 0,
            forcedConflicts: [String: RemoteRecord] = [:],
            randomSource: @escaping () -> Double = { Double.random(in: 0...1) }
        ) {
            self.failureRate = max(0, min(1, failureRate))
            self.forcedConflicts = forcedConflicts
            self.randomSource = randomSource
        }
    }

    public struct TransientNetworkError: Error, Sendable {}

    private let configuration: Configuration
    /// Every accepted/attempted action, in call order — lets tests assert
    /// on exactly what was sent and in what order without the engine
    /// exposing internal state.
    public private(set) var attemptedActionIDs: [UUID] = []

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    public func push(_ action: SyncAction) async -> SyncPushResult {
        attemptedActionIDs.append(action.id)

        if let forced = configuration.forcedConflicts[action.entityID] {
            return .conflict(forced)
        }

        if configuration.randomSource() < configuration.failureRate {
            return .transientFailure(TransientNetworkError())
        }

        return .accepted
    }
}

/// A real client would wrap `URLSession`; sketched here to show the seam a
/// production implementation would fill in, without pulling in networking
/// concerns this package doesn't need to actually demonstrate.
public final class URLSessionSyncNetworkClient: SyncNetworkClient, @unchecked Sendable {

    private let endpoint: URL
    private let session: URLSession

    public init(endpoint: URL, session: URLSession = .shared) {
        self.endpoint = endpoint
        self.session = session
    }

    public func push(_ action: SyncAction) async -> SyncPushResult {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        do {
            request.httpBody = try JSONEncoder().encode(action)
            let (_, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .transientFailure(URLError(.badServerResponse))
            }
            switch http.statusCode {
            case 200..<300:
                return .accepted
            case 409:
                // A real server would return the conflicting record's body;
                // omitted here since this class exists to show the seam,
                // not to be a complete server integration.
                return .transientFailure(URLError(.badServerResponse))
            default:
                return .transientFailure(URLError(.badServerResponse))
            }
        } catch {
            return .transientFailure(error)
        }
    }
}
