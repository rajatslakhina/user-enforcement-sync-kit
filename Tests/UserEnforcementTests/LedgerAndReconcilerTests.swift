import Foundation
import XCTest
@testable import UserEnforcement

private func sig(_ rev: UInt64, _ r: Restriction, _ source: EnforcementSignal.Source = .push, user: String = "u") -> EnforcementSignal {
    EnforcementSignal(userID: user, revision: rev, restriction: r, source: source)
}

final class LedgerTests: XCTestCase {
    func testPersistedRevisionFloorRejectsReplayAfterRelaunch() async {
        let clock = ManualClock()
        let store = InMemoryEnforcementStore()
        let first = EnforcementLedger(clock: clock, store: store)
        await first.ingest(sig(4, .none, .snapshot))

        let relaunched = EnforcementLedger(clock: clock, store: store)
        let outcome = await relaunched.ingest(sig(2, .suspended))
        XCTAssertEqual(outcome, .stale)
        let state = await relaunched.state(for: "u")
        XCTAssertEqual(state?.revision, 4)
        XCTAssertEqual(state?.restriction, Restriction.none)
    }

    /// Control for the test above: the property comes from the store, not from luck.
    func testWithoutPersistenceTheSameReplayWins() async {
        let clock = ManualClock()
        let first = EnforcementLedger(clock: clock, store: nil)
        await first.ingest(sig(4, .none, .snapshot))
        let relaunched = EnforcementLedger(clock: clock, store: nil)
        let outcome = await relaunched.ingest(sig(2, .suspended))
        XCTAssertEqual(outcome, .applied, "an ephemeral ledger has no floor, which is exactly the bug persistence prevents")
    }

    func testFileStoreRoundTripsAndMissingFileIsEmpty() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("enf-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = FileEnforcementStore(url: url)
        XCTAssertEqual(try store.load(), [:])
        let ledger = EnforcementLedger(clock: ManualClock(start: Instant(millis: 77)), store: store)
        await ledger.ingest(EnforcementSignal(userID: "u", revision: 9, restriction: .restricted(["x"]), expiresAt: Instant(millis: 500), source: .snapshot))
        let loaded = try store.load()
        XCTAssertEqual(loaded["u"], UserEnforcementState(revision: 9, restriction: .restricted(["x"]), expiresAt: Instant(millis: 500), lastConfirmedAt: Instant(millis: 77)))
    }

    func testCorruptStoreStartsEmptyAndAudits() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("enf-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("not json".utf8).write(to: url)
        let ledger = EnforcementLedger(clock: ManualClock(), store: FileEnforcementStore(url: url))
        let tracked = await ledger.trackedUsers()
        XCTAssertTrue(tracked.isEmpty)
        let audit = await ledger.auditLog()
        XCTAssertEqual(audit.first?.event, .storeCorrupt)
    }

    func testSaveFailureIsAuditedAndStateStillApplied() async {
        let store = InMemoryEnforcementStore()
        store.setFailSaves(true)
        let ledger = EnforcementLedger(clock: ManualClock(), store: store)
        await ledger.ingest(sig(1, .suspended))
        let state = await ledger.state(for: "u")
        XCTAssertEqual(state?.restriction, .suspended, "enforcement must not wait on disk")
        let events = await ledger.auditLog().map(\.event)
        XCTAssertTrue(events.contains(.storeSaveFailed))
    }

    func testTrackedUsersAreBoundedLeastRecentlyTouchedEvicted() async {
        let ledger = EnforcementLedger(clock: ManualClock(), configuration: .init(maxTrackedUsers: 2))
        await ledger.ingest(sig(1, .none, user: "a"))
        await ledger.ingest(sig(1, .none, user: "b"))
        await ledger.ingest(sig(2, .none, user: "a"))   // touches a
        await ledger.ingest(sig(1, .none, user: "c"))   // evicts b
        let tracked = await ledger.trackedUsers()
        XCTAssertEqual(tracked, ["a", "c"])
        let b = await ledger.state(for: "b")
        XCTAssertNil(b)
        let events = await ledger.auditLog().filter { $0.userID == "b" }.map(\.event)
        XCTAssertTrue(events.contains(.evicted))
        let aEvents = await ledger.auditLog().filter { $0.userID == "a" }.map(\.event)
        XCTAssertFalse(aEvents.contains(.evicted), "re-ingesting a tracked user at the cap must evict nobody")
        await ledger.ingest(sig(3, .none, user: "c"))
        let evictions = await ledger.auditLog().filter { $0.event == .evicted }.count
        XCTAssertEqual(evictions, 1)
    }

    /// Review finding: the first confirmation of a pushed revision must reach disk even inside
    /// the throttle window, or a relaunch forgets it.
    func testFirstConfirmationOfARevisionIsPersistedImmediately() async throws {
        let clock = ManualClock()
        let store = InMemoryEnforcementStore()
        let ledger = EnforcementLedger(clock: clock, store: store)
        await ledger.ingest(sig(4, .suspended, .push))
        clock.advance(byMillis: 1_000)
        await ledger.ingest(sig(4, .suspended, .snapshot))
        let saved = try store.load()["u"]
        XCTAssertEqual(saved?.confirmedRevision, 4)
        XCTAssertEqual(saved?.lastConfirmedAt, Instant(millis: 1_000))
    }

    /// Review finding: confirmed at rev 3, pushed rev 4, snapshot rev 4 inside the window. The
    /// first confirmation of rev 4 must still be written.
    func testFirstConfirmationAfterAnEarlierOneIsPersisted() async throws {
        let clock = ManualClock()
        let store = InMemoryEnforcementStore()
        let ledger = EnforcementLedger(clock: clock, store: store)
        await ledger.ingest(sig(3, .none, .snapshot))
        clock.advance(byMillis: 1_000)
        await ledger.ingest(sig(4, .suspended, .push))
        clock.advance(byMillis: 1_000)
        await ledger.ingest(sig(4, .suspended, .snapshot))
        let saved = try store.load()["u"]
        XCTAssertEqual(saved?.confirmedRevision, 4)
        XCTAssertEqual(saved?.lastConfirmedAt, Instant(millis: 2_000))
    }

    /// Review finding: an unreadable store (e.g. file protection before first unlock) must not be
    /// overwritten by the first save, or every other user's revision floor is lost.
    func testUnreadableStoreDefersSavesThenMergesOnRecovery() async throws {
        let store = InMemoryEnforcementStore(initial: [
            "other": UserEnforcementState(revision: 9, restriction: .suspended, expiresAt: nil, lastConfirmedAt: Instant(millis: 1)),
        ])
        store.setFailLoads(true)
        let ledger = EnforcementLedger(clock: ManualClock(), store: store)
        await ledger.ingest(sig(1, .none, .snapshot))
        XCTAssertEqual(store.saveCount, 0, "nothing written while the file is unread")
        let events = await ledger.auditLog().map(\.event)
        XCTAssertEqual(events.first, .storeLoadFailed)
        XCTAssertTrue(events.contains(.storeSaveDeferred))

        store.setFailLoads(false)
        await ledger.ingest(sig(2, .none, .snapshot))
        let saved = try store.load()
        XCTAssertEqual(saved["other"]?.revision, 9, "the other user's floor survived")
        XCTAssertEqual(saved["u"]?.revision, 2)
        let replay = await ledger.ingest(sig(3, .none, user: "other"))
        XCTAssertEqual(replay, .stale, "and it is enforced again in memory")
    }

    func testCorruptStoreIsReportedAsCorruptAndOverwritten() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("enf-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("{".utf8).write(to: url)
        let ledger = EnforcementLedger(clock: ManualClock(), store: FileEnforcementStore(url: url))
        let first = await ledger.auditLog().first?.event
        XCTAssertEqual(first, .storeCorrupt)
        await ledger.ingest(sig(1, .none, .snapshot))
        XCTAssertEqual(try FileEnforcementStore(url: url).load()["u"]?.revision, 1)
    }

    func testLiveResponseConfirmationsDoNotFloodTheAudit() async {
        let ledger = EnforcementLedger(clock: ManualClock(), configuration: .init(auditCapacity: 4))
        await ledger.ingest(sig(1, .none, .snapshot))
        for _ in 0..<20 { await ledger.ingest(sig(1, .none, .responseHeader)) }
        let audit = await ledger.auditLog()
        XCTAssertEqual(audit.map(\.event), [.merged(.applied, revision: 1, source: .snapshot)])
    }

    func testWriteThrottleTableIsBoundedByEviction() async {
        let ledger = EnforcementLedger(clock: ManualClock(), store: InMemoryEnforcementStore(), configuration: .init(maxTrackedUsers: 3))
        for i in 0..<20 { await ledger.ingest(sig(1, .none, .snapshot, user: "u\(i)")) }
        let count = await ledger.persistedTimestampCount()
        XCTAssertEqual(count, 3)
    }

    func testDecodingNormalisesSignalsAndStates() throws {
        let signalJSON = #"{"userID":"u","revision":2,"restriction":{"restricted":{"_0":[]}},"expiresAt":{"millis":9},"source":"push"}"#
        let signal = try JSONDecoder().decode(EnforcementSignal.self, from: Data(signalJSON.utf8))
        XCTAssertEqual(signal.restriction, .none)
        XCTAssertNil(signal.expiresAt)
        let stateJSON = #"{"revision":3,"restriction":{"none":{}},"expiresAt":{"millis":9},"lastConfirmedAt":{"millis":5}}"#
        let state = try JSONDecoder().decode(UserEnforcementState.self, from: Data(stateJSON.utf8))
        XCTAssertNil(state.expiresAt)
        XCTAssertEqual(state.confirmedRevision, 3)
        let roundTrip = try JSONDecoder().decode(EnforcementSignal.self, from: JSONEncoder().encode(
            EnforcementSignal(userID: "u", revision: 1, restriction: .restricted(["a"]), expiresAt: Instant(millis: 4), source: .snapshot)))
        XCTAssertEqual(roundTrip.restriction, .restricted(["a"]))
        XCTAssertEqual(roundTrip.expiresAt, Instant(millis: 4))
    }

    func testDegenerateConfigurationIsClampedAndAuditIsBounded() async {
        let ledger = EnforcementLedger(clock: ManualClock(), configuration: .init(maxTrackedUsers: 0, auditCapacity: -3))
        for i in 0..<50 { await ledger.ingest(sig(UInt64(i), .none, user: "u\(i % 3)")) }
        let tracked = await ledger.trackedUsers()
        XCTAssertEqual(tracked.count, 1)
        let audit = await ledger.auditLog()
        XCTAssertEqual(audit.count, 1)
    }

    func testRestoredRecencyFollowsConfirmationTime() async {
        let initial: [String: UserEnforcementState] = [
            "a": UserEnforcementState(revision: 1, restriction: .none, expiresAt: nil, lastConfirmedAt: Instant(millis: 300)),
            "b": UserEnforcementState(revision: 1, restriction: .none, expiresAt: nil, lastConfirmedAt: Instant(millis: 100)),
            "c": UserEnforcementState(revision: 1, restriction: .none, expiresAt: nil, lastConfirmedAt: nil),
        ]
        let ledger = EnforcementLedger(clock: ManualClock(), store: InMemoryEnforcementStore(initial: initial), configuration: .init(maxTrackedUsers: 2))
        let tracked = await ledger.trackedUsers()
        XCTAssertEqual(tracked, ["b", "a"], "never-confirmed c goes first, then the oldest confirmation")
    }

    func testConfirmationOnlyWritesAreThrottledButChangesAreNot() async {
        let clock = ManualClock()
        let store = InMemoryEnforcementStore()
        let ledger = EnforcementLedger(clock: clock, store: store, configuration: .init(confirmationPersistIntervalMillis: 60_000))
        await ledger.ingest(sig(1, .none, .snapshot))           // change: written
        XCTAssertEqual(store.saveCount, 1)
        clock.advance(byMillis: 10_000)
        await ledger.ingest(sig(1, .none, .responseHeader))     // confirmation only: skipped
        XCTAssertEqual(store.saveCount, 1)
        let inMemory = await ledger.state(for: "u")
        XCTAssertEqual(inMemory?.lastConfirmedAt, Instant(millis: 10_000), "memory is always current")
        clock.advance(byMillis: 50_000)
        await ledger.ingest(sig(1, .none, .responseHeader))     // 60 s since last write: written
        XCTAssertEqual(store.saveCount, 2)
        await ledger.ingest(sig(2, .suspended))                 // change: written immediately
        XCTAssertEqual(store.saveCount, 3)
    }

    func testSnapshotReadsEverythingAtOneInstant() async {
        let clock = ManualClock()
        let ledger = EnforcementLedger(clock: clock)
        await ledger.ingest(sig(1, .restricted(["b"]), .snapshot))
        let caps = [Capability(id: "a", displayName: "A", risk: .act, hasOnDeviceFallback: false),
                    Capability(id: "b", displayName: "B", risk: .act, hasOnDeviceFallback: true)]
        let snap = await ledger.snapshot(userID: "u", capabilities: caps, policy: .standard)
        XCTAssertEqual(snap.state?.revision, 1)
        XCTAssertEqual(snap.decisions.map(\.decision.route), [.cloud, .onDevice])
        XCTAssertEqual(snap.audit.count, 1)
    }

    func testOversizedStoreIsTrimmedOnLoad() async {
        var initial: [String: UserEnforcementState] = [:]
        for name in ["a", "b", "c", "d"] {
            initial[name] = UserEnforcementState(revision: 1, restriction: .none, expiresAt: nil, lastConfirmedAt: nil)
        }
        let ledger = EnforcementLedger(clock: ManualClock(), store: InMemoryEnforcementStore(initial: initial), configuration: .init(maxTrackedUsers: 2))
        let tracked = await ledger.trackedUsers()
        XCTAssertEqual(tracked, ["c", "d"])
    }

    /// Many concurrent writers through one actor still converge on the highest revision.
    func testConcurrentIngestConvergesOnHighestRevision() async {
        let ledger = EnforcementLedger(clock: ManualClock())
        await withTaskGroup(of: Void.self) { group in
            for rev in (1...200).shuffled() {
                group.addTask { await ledger.ingest(sig(UInt64(rev), rev == 200 ? .suspended : .none)) }
            }
        }
        let state = await ledger.state(for: "u")
        XCTAssertEqual(state?.revision, 200)
        XCTAssertEqual(state?.restriction, .suspended)
    }
}

// MARK: - Reconciler

private final class RecordingSleeper: EnforcementSleeper, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [Int64] = []
    var shouldThrow = false
    struct Cancelled: Error {}
    func sleep(millis: Int64) async throws {
        let fail: Bool = lock.withLockCompat { recorded.append(millis); return shouldThrow }
        if fail { throw Cancelled() }
    }
    var delays: [Int64] { lock.withLockCompat { recorded } }
}

private extension NSLock {
    func withLockCompat<T>(_ body: () -> T) -> T { lock(); defer { unlock() }; return body() }
}

/// Blocks every fetch until released, so concurrent callers genuinely overlap.
private actor GatedSource: EnforcementSnapshotSource {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var released = false
    private(set) var fetches = 0
    let head: EnforcementSignal
    init(head: EnforcementSignal) { self.head = head }

    func fetchSnapshot(userID: String) async throws -> EnforcementSignal {
        fetches += 1
        if !released { await withCheckedContinuation { waiters.append($0) } }
        return head
    }

    func release() {
        released = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}

/// Every fetch waits until released, ignoring cancellation, then throws.
private actor BlockingFailingSource: EnforcementSnapshotSource {
    struct Failure: Error {}
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var released = false
    private(set) var started = 0
    func fetchSnapshot(userID: String) async throws -> EnforcementSignal {
        started += 1
        if !released { await withCheckedContinuation { waiters.append($0) } }
        throw Failure()
    }
    func release() {
        released = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}

final class ReconcilerTests: XCTestCase {
    func testConcurrentRefreshesShareOneFetch() async throws {
        let ledger = EnforcementLedger(clock: ManualClock())
        let source = GatedSource(head: sig(5, .suspended, .snapshot))
        let reconciler = EnforcementReconciler(ledger: ledger, source: source, sleeper: RecordingSleeper())
        let callers = 50

        let results = Task {
            await withTaskGroup(of: RefreshOutcome.self, returning: [RefreshOutcome].self) { group in
                for _ in 0..<callers { group.addTask { await reconciler.refresh(userID: "u") } }
                var all: [RefreshOutcome] = []
                for await r in group { all.append(r) }
                return all
            }
        }
        // Wait (bounded) until every caller is either the starter or has joined it.
        // If coalescing is broken, `joined` never reaches the target: release anyway so the
        // test fails on the fetch count below instead of hanging.
        let deadline = Date().addingTimeInterval(5)
        var overlapped = true
        while await reconciler.stats.joined < callers - 1 {
            if Date() > deadline { overlapped = false; break }
            await Task.yield()
        }
        await source.release()
        let outcomes = await results.value
        XCTAssertTrue(overlapped, "callers never joined an in-flight refresh")

        let fetches = await source.fetches
        XCTAssertEqual(fetches, 1)
        XCTAssertEqual(outcomes.count, callers)
        XCTAssertTrue(outcomes.allSatisfy { $0 == .refreshed(.applied, attempts: 1) })
        let stats = await reconciler.stats
        XCTAssertEqual(stats.started, 1)
        XCTAssertEqual(stats.joined, callers - 1)
    }

    func testSequentialRefreshesEachFetch() async {
        let ledger = EnforcementLedger(clock: ManualClock())
        let source = ScriptedSnapshotSource(heads: [sig(1, .none, .snapshot)])
        let reconciler = EnforcementReconciler(ledger: ledger, source: source, sleeper: RecordingSleeper(), minimumRefreshIntervalMillis: 0)
        let first = await reconciler.refresh(userID: "u")
        let second = await reconciler.refresh(userID: "u")
        XCTAssertEqual(first, .refreshed(.applied, attempts: 1))
        XCTAssertEqual(second, .refreshed(.confirmed, attempts: 1))
        let requests = await source.requests
        XCTAssertEqual(requests, 2, "a finished refresh must not be cached forever")
    }

    func testRetryExhaustionLeavesStateUntouchedWithCappedBackoff() async {
        let clock = ManualClock()
        let ledger = EnforcementLedger(clock: clock)
        await ledger.ingest(sig(3, .restricted(["send"]), .snapshot))
        let source = ScriptedSnapshotSource()
        await source.setOutage(true)
        let sleeper = RecordingSleeper()
        let reconciler = EnforcementReconciler(ledger: ledger, source: source,
                                               retry: RetryPolicy(maxAttempts: 5, baseDelayMillis: 100, maxDelayMillis: 300, jitter: .none), sleeper: sleeper)
        let outcome = await reconciler.refresh(userID: "u")
        XCTAssertEqual(outcome, .failed(attempts: 5))
        XCTAssertEqual(sleeper.delays, [100, 200, 300, 300], "no sleep after the final attempt")
        let state = await ledger.state(for: "u")
        XCTAssertEqual(state?.revision, 3)
        XCTAssertEqual(state?.restriction, .restricted(["send"]))
    }

    func testRecoversOnLaterAttempt() async {
        let ledger = EnforcementLedger(clock: ManualClock())
        let source = ScriptedSnapshotSource(heads: [sig(2, .none, .snapshot)])
        await source.failNext(2)
        let reconciler = EnforcementReconciler(ledger: ledger, source: source, sleeper: RecordingSleeper())
        let outcome = await reconciler.refresh(userID: "u")
        XCTAssertEqual(outcome, .refreshed(.applied, attempts: 3))
    }

    /// The reconciler must re-tag whatever the source returns as `.snapshot`. This source returns
    /// a `.push`-tagged signal *unchanged*, so the test fails if the re-tag is removed.
    func testFetchedSignalConfirmsFreshnessEvenIfTaggedPush() async {
        struct PushTagged: EnforcementSnapshotSource {
            func fetchSnapshot(userID: String) async throws -> EnforcementSignal {
                EnforcementSignal(userID: userID, revision: 2, restriction: .none, source: .push)
            }
        }
        let ledger = EnforcementLedger(clock: ManualClock(start: Instant(millis: 50)))
        let reconciler = EnforcementReconciler(ledger: ledger, source: PushTagged(), sleeper: RecordingSleeper())
        _ = await reconciler.refresh(userID: "u")
        let state = await ledger.state(for: "u")
        XCTAssertEqual(state?.lastConfirmedAt, Instant(millis: 50))
        XCTAssertEqual(state?.confirmedRevision, 2)
    }

    func testThrottleSkipsFetchInsideIntervalOnly() async {
        let clock = ManualClock()
        let ledger = EnforcementLedger(clock: clock)
        let source = ScriptedSnapshotSource()
        let reconciler = EnforcementReconciler(ledger: ledger, source: source, sleeper: RecordingSleeper(),
                                               clock: clock, minimumRefreshIntervalMillis: 30_000)
        _ = await reconciler.refresh(userID: "u")
        clock.advance(byMillis: 29_999)
        let throttled = await reconciler.refresh(userID: "u")
        XCTAssertEqual(throttled, .throttled)
        clock.advance(byMillis: 1)
        let again = await reconciler.refresh(userID: "u")
        XCTAssertEqual(again, .refreshed(.confirmed, attempts: 1))
        clock.advance(byMillis: -60_000)  // clock moved back: never throttles
        let back = await reconciler.refresh(userID: "u")
        XCTAssertEqual(back, .refreshed(.confirmed, attempts: 1))
        let requests = await source.requests
        XCTAssertEqual(requests, 3)
        let stats = await reconciler.stats
        XCTAssertEqual(stats.throttled, 1)
    }

    /// A fetch that ignores cancellation and then fails: the loop must notice and stop, not retry.
    func testCancellationDuringAFetchThatIgnoresItStopsWithoutRetry() async {
        let source = BlockingFailingSource()
        let reconciler = EnforcementReconciler(ledger: EnforcementLedger(clock: ManualClock()), source: source,
                                               retry: RetryPolicy(maxAttempts: 5, jitter: .none), sleeper: RecordingSleeper())
        let caller = Task { await reconciler.refresh(userID: "u") }
        let deadline = Date().addingTimeInterval(5)
        while await source.started < 1, Date() < deadline { await Task.yield() }
        await reconciler.cancelRefresh(userID: "u")
        await source.release()
        let outcome = await caller.value
        XCTAssertEqual(outcome, .cancelled)
        let started = await source.started
        XCTAssertEqual(started, 1)
    }

    func testRefreshAfterCancelStartsFresh() async {
        let source = BlockingFailingSource()
        let reconciler = EnforcementReconciler(ledger: EnforcementLedger(clock: ManualClock()), source: source,
                                               retry: RetryPolicy(maxAttempts: 1, jitter: .none), sleeper: RecordingSleeper())
        let first = Task { await reconciler.refresh(userID: "u") }
        let deadline = Date().addingTimeInterval(5)
        while await source.started < 1, Date() < deadline { await Task.yield() }
        await reconciler.cancelRefresh(userID: "u")
        let second = Task { await reconciler.refresh(userID: "u") }
        while await source.started < 2, Date() < deadline { await Task.yield() }
        await source.release()
        let outcomes = [await first.value, await second.value]
        XCTAssertEqual(outcomes, [.cancelled, .failed(attempts: 1)], "the second refresh did not join the cancelled one")
    }

    func testThrottleTableIsBounded() async {
        let clock = ManualClock()
        let reconciler = EnforcementReconciler(ledger: EnforcementLedger(clock: clock, configuration: .init(maxTrackedUsers: 200)),
                                               source: ScriptedSnapshotSource(), sleeper: RecordingSleeper(), clock: clock)
        for i in 0..<(EnforcementReconciler.maxRememberedUsers + 1) {
            clock.advance(byMillis: 1)
            _ = await reconciler.refresh(userID: "user-\(i)")
        }
        let count = await reconciler.rememberedUserCount()
        XCTAssertEqual(count, EnforcementReconciler.maxRememberedUsers)
        // The oldest was dropped, so it is no longer throttled.
        let first = await reconciler.refresh(userID: "user-0")
        XCTAssertEqual(first, .refreshed(.confirmed, attempts: 1))
    }

    func testFailedRefreshIsNotThrottled() async {
        let clock = ManualClock()
        let source = ScriptedSnapshotSource()
        await source.setOutage(true)
        let reconciler = EnforcementReconciler(ledger: EnforcementLedger(clock: clock), source: source,
                                               retry: RetryPolicy(maxAttempts: 1), sleeper: RecordingSleeper(), clock: clock)
        let first = await reconciler.refresh(userID: "u")
        let second = await reconciler.refresh(userID: "u")
        XCTAssertEqual(first, .failed(attempts: 1))
        XCTAssertEqual(second, .failed(attempts: 1), "only a success starts the throttle window")
    }

    func testFullJitterStaysInRangeWhateverRandomReturns() {
        let policy = RetryPolicy(maxAttempts: 4, baseDelayMillis: 100, maxDelayMillis: 1_000, jitter: .full)
        XCTAssertEqual(policy.jitteredDelay(beforeRetry: 2, random: { $0.upperBound / 2 }), 200)
        XCTAssertEqual(policy.jitteredDelay(beforeRetry: 2, random: { _ in .max }), 400, "clamped to the ceiling")
        XCTAssertEqual(policy.jitteredDelay(beforeRetry: 2, random: { _ in .min }), 0, "clamped to zero")
        XCTAssertEqual(RetryPolicy(jitter: .none).jitteredDelay(beforeRetry: 1, random: { _ in 0 }), 1_000)
    }

    func testJitteredDelaysAreWhatTheSleeperSees() async {
        let source = ScriptedSnapshotSource()
        await source.setOutage(true)
        let sleeper = RecordingSleeper()
        let reconciler = EnforcementReconciler(ledger: EnforcementLedger(clock: ManualClock()), source: source,
                                               retry: RetryPolicy(maxAttempts: 3, baseDelayMillis: 100, maxDelayMillis: 10_000, jitter: .full),
                                               sleeper: sleeper, random: { $0.upperBound / 4 })
        _ = await reconciler.refresh(userID: "u")
        XCTAssertEqual(sleeper.delays, [25, 50])
    }

    func testCancelRefreshCancelsTheSharedFetchForEveryCaller() async {
        let source = ScriptedSnapshotSource()
        await source.setOutage(true)
        // Real TaskSleeper with a long delay: only cancellation can end this quickly.
        let reconciler = EnforcementReconciler(ledger: EnforcementLedger(clock: ManualClock()), source: source,
                                               retry: RetryPolicy(maxAttempts: 3, baseDelayMillis: 60_000, maxDelayMillis: 60_000, jitter: .none))
        let a = Task { await reconciler.refresh(userID: "u") }
        let b = Task { await reconciler.refresh(userID: "u") }
        let deadline = Date().addingTimeInterval(5)
        while await reconciler.stats.joined < 1, Date() < deadline { await Task.yield() }
        while await source.requests < 1, Date() < deadline { await Task.yield() }
        await reconciler.cancelRefresh(userID: "u")
        let outcomes = [await a.value, await b.value]
        XCTAssertEqual(outcomes, [.cancelled, .cancelled])
    }

    func testMismatchedUserIsRejectedAndNotApplied() async {
        struct WrongUser: EnforcementSnapshotSource {
            func fetchSnapshot(userID: String) async throws -> EnforcementSignal {
                EnforcementSignal(userID: "someone-else", revision: 99, restriction: .suspended, source: .snapshot)
            }
        }
        let ledger = EnforcementLedger(clock: ManualClock())
        let reconciler = EnforcementReconciler(ledger: ledger, source: WrongUser(), sleeper: RecordingSleeper())
        let outcome = await reconciler.refresh(userID: "u")
        XCTAssertEqual(outcome, .rejectedUserMismatch)
        let tracked = await ledger.trackedUsers()
        XCTAssertTrue(tracked.isEmpty)
    }

    func testSleeperCancellationStopsTheLoop() async {
        let ledger = EnforcementLedger(clock: ManualClock())
        let source = ScriptedSnapshotSource()
        await source.setOutage(true)
        let sleeper = RecordingSleeper()
        sleeper.shouldThrow = true
        let reconciler = EnforcementReconciler(ledger: ledger, source: source, sleeper: sleeper)
        let outcome = await reconciler.refresh(userID: "u")
        XCTAssertEqual(outcome, .cancelled)
        let requests = await source.requests
        XCTAssertEqual(requests, 1)
    }

    func testRefreshThenGateGoesToCloud() async {
        let clock = ManualClock()
        let ledger = EnforcementLedger(clock: clock)
        let reconciler = EnforcementReconciler(ledger: ledger, source: ScriptedSnapshotSource(), sleeper: RecordingSleeper())
        let send = Capability(id: "send", displayName: "Send", risk: .act, hasOnDeviceFallback: false)
        let before = await ledger.decide(userID: "u", capability: send, policy: .standard)
        XCTAssertEqual(before.route, .unavailable)
        _ = await reconciler.refresh(userID: "u")
        let after = await ledger.decide(userID: "u", capability: send, policy: .standard)
        XCTAssertEqual(after.route, .cloud)
        clock.advance(byMillis: 11 * 60_000)
        let later = await ledger.decide(userID: "u", capability: send, policy: .standard)
        XCTAssertEqual(later.route, .unavailable, "fail-closed tier closes again once the window passes")
    }

    func testScenarioPushLookupIsBoundsChecked() {
        let scenario = EnforcementScenario(userID: "u", capabilities: [], policy: .standard,
                                           serverHead: sig(1, .none, .snapshot), pushDeliveryOrder: [sig(1, .none)])
        XCTAssertNotNil(scenario.push(at: 0))
        XCTAssertNil(scenario.push(at: 1))
        XCTAssertNil(scenario.push(at: -1))
    }
}
