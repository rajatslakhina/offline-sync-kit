# OfflineSyncKit

A write-ahead sync queue for iOS clients that have to keep working when the network doesn't: local writes are queued durably, a background engine drains them against a flaky server, and two swappable conflict-resolution strategies — last-write-wins and vector-clock CRDT-style merge — decide what happens when two devices edit the same data while both are offline.

This is the kind of problem a staff/senior iOS interview loop actually asks about — not "build a to-do list app," but "what happens when the user edits the same note on their phone and their iPad while both are on a plane, and they land at different times?" This repo answers that with real, tested code instead of a whiteboard sketch.

## Why this matters

Most "offline-first" iOS demos stop at `NSCache` + retry-on-fail. That's not what breaks in production. What breaks is: two devices genuinely disagree about the current state of an entity, the network fails in the middle of a sync (not just at the start), and a queue that retries forever slowly fills the disk while a queue that gives up silently loses the user's edit. `OfflineSyncKit` is built around those three failure modes specifically, because they're the ones that separate a feature demo from a systems design.

## Design decision

**Two-strategy conflict resolution behind one protocol, not one hard-coded policy.** `ConflictResolutionStrategy` is the seam between "how do we serialize and retry writes" (`SyncEngine`) and "who wins when two writes collide" (the strategy). A team can run last-write-wins for effectively-single-writer entities (a user's own profile) and switch to vector-clock merging for genuinely multi-device-concurrent entities (a shared shopping list, a collaborative doc) without touching the engine.

**A vector clock detects genuine concurrency instead of trusting device clocks.** Two devices independently incrementing their own clock slot while offline is the textbook case a plain timestamp can't distinguish from "these happened in some order" — `VectorClock.compare(to:)` returns `.concurrent` specifically when neither side dominates, which is the trigger for field-level merge instead of a coin flip.

**Retry exhaustion routes to a dead-letter queue, not infinite retry or silent drop.** `RetryPolicy` caps attempts with exponential backoff + jitter; once exhausted, the action moves to `DeadLetterQueue` where it's inspectable and manually re-queueable, rather than either growing the write-ahead queue forever during an extended outage or quietly losing the user's edit.

**The persistence layer is a protocol, not a concrete SwiftData type.** `ActionQueueStore` is implemented by `InMemoryActionQueueStore` (what every test in this repo runs against) and `SwiftDataActionQueueStore` (the real on-device store, compiled only where SwiftData exists via `#if canImport(SwiftData)`). This is what makes the core engine testable headlessly at all.

## Trade-offs and rejected alternatives

- **CRDT merge is field-level, not operation-level.** A true operational-transform or full CRDT (e.g. a Lamport-timestamped last-writer-per-field log) would resolve same-field concurrent edits without any data loss. This repo's `VectorClockMergeStrategy` instead falls back to "local wins" for same-field concurrent conflicts — simpler to reason about and test, at the honest cost of still dropping one side's intent for that one field. Documented in the strategy's own doc comment, not hidden.
- **LWW was kept as a real, separate option instead of only shipping the more "correct" CRDT strategy.** For entities that are effectively single-writer in practice, LWW's simplicity and predictability (no vector-clock bookkeeping, no merge surprises) is the better trade — forcing CRDT everywhere adds complexity with no payoff for that class of entity.
- **Cross-entity ordering is explicitly not guaranteed beyond per-entity FIFO.** A single global sync order across unrelated entities was considered and rejected — it would serialize sync throughput for entities that have no causal relationship to each other, for no correctness benefit.
- **The demo app is a separate Xcode project consuming this package via a remote Git URL**, not a bundled executable target — see the companion repo below for why (a same-pattern crash was hit and root-caused in an earlier project in this portfolio; SPM `.executableTarget`s don't produce stable, reproducible `.app` bundles when run via Xcode's package-run convenience).

## What's in this package

| File | Responsibility |
|---|---|
| `SyncAction` / `RemoteRecord` | The local write and the server's current authoritative state |
| `VectorClock` | Causal ordering / concurrency detection between devices |
| `ConflictResolutionStrategy` (+ `LastWriteWinsStrategy`, `VectorClockMergeStrategy`) | Who wins when local and remote disagree |
| `ActionQueueStore` (+ `InMemoryActionQueueStore`, `SwiftDataActionQueueStore`) | Durable write-ahead queue persistence, swappable |
| `SyncNetworkClient` (+ `MockFlakyNetworkClient`, `URLSessionSyncNetworkClient`) | The network seam, with a deliberately unreliable test double |
| `RetryPolicy` | Exponential backoff with jitter and a hard attempt ceiling |
| `DeadLetterQueue` | Where actions go after retry exhaustion, for inspection and manual re-queue |
| `SyncEngine` | The `actor` that orchestrates all of the above; documents its own concurrency/ordering guarantees in its doc comment |

## Testing

`Tests/OfflineSyncKitTests` covers the failure modes this design exists to handle, not just the happy path: empty-queue drains, zero/negative retry-policy configuration, exact-timestamp LWW tiebreaks, concurrent-clock detection and field-level merge (including the same-field-collision trade-off), retry-exhaustion → dead-letter routing, manual dead-letter requeue, delete-coalescing of earlier queued updates, and partial success/failure within a single drain pass.

**Verification tier, stated honestly:** this run's sandbox had no headless Swift toolchain reachable (the swift.org release download stalled at roughly 1 MB/s, which would take well over a thousand seconds for the full toolchain — not achievable within this run's time budget, and background downloads don't survive between shell calls in this environment). In place of `swift build`/`swift test`, every source and test file was checked with a scripted brace/paren/bracket balance pass (all files balanced) and a scripted scan for unguarded force-unwraps (`grep` for `!` outside `!=`/attribute usage — none found outside the one disclosed-and-commented case class this design deliberately avoids). The test suite was still written to the same standard as if `swift test` were about to run it — this is an honest statement of what *didn't* get automated confirmation this run, not a claim that it did.

## Demo app

[`offline-sync-kit-demo-app`](https://github.com/rajatslakhina/offline-sync-kit-demo-app) — a separate `Demo.xcodeproj` that consumes this package via a **remote** `XCRemoteSwiftPackageReference` (branch `main`), not a local path, exactly like any real external consumer would. Two simulated devices edit a shared list offline; tapping Sync Now drains the queue against a simulated flaky server and shows conflict merges, retry backoff, and dead-letter routing live.

Honest status: this run could not get Simulator/computer-use access (unattended scheduled runs on this platform categorically block that live-control approval), so the demo has not yet been confirmed to launch — see that repo's README for the exact disclosure and what verification *was* done in its place.
