import XCTest
@testable import UserEnforcement

/// Replays the demo app's README walkthrough against the real ledger, reconciler and gate, so the
/// demo README is enforced by CI instead of traced by hand. The script mirrors `Demo/DemoApp.swift`
/// in user-enforcement-sync-demo-app; keep the two in step.
final class DemoWalkthroughTests: XCTestCase {
    let user = "user_8f3a"
    let start = Instant(millis: 1_800_000_000_000)
    let capabilities = [
        Capability(id: "summarize", displayName: "Summarize thread", risk: .read, hasOnDeviceFallback: true),
        Capability(id: "draft-reply", displayName: "Draft reply", risk: .generate, hasOnDeviceFallback: true),
        Capability(id: "agent-send", displayName: "Agent sends for you", risk: .act, hasOnDeviceFallback: false),
    ]

    private func rows(_ ledger: EnforcementLedger) async -> [String] {
        let snap = await ledger.snapshot(userID: user, capabilities: capabilities, policy: .standard)
        return snap.decisions.map { "\($0.decision.route.rawValue): \($0.decision.reason.summary)" }
    }

    func testReadmeWalkthrough() async {
        let rev2 = EnforcementSignal(userID: user, revision: 2, restriction: .restricted(["agent-send"]),
                                     expiresAt: start.advanced(byMillis: 20 * 60_000), source: .push)
        let rev3 = EnforcementSignal(userID: user, revision: 3, restriction: .suspended, source: .push)
        let rev4 = EnforcementSignal(userID: user, revision: 4, restriction: .restricted(["agent-send"]), source: .push)
        let clock = ManualClock(start: start)
        let store = InMemoryEnforcementStore()
        let server = ScriptedSnapshotSource(heads: [rev4.withSource(.snapshot)], serverClock: clock)
        var ledger = EnforcementLedger(clock: clock, store: store)
        let makeReconciler = { (l: EnforcementLedger) in
            EnforcementReconciler(ledger: l, source: server,
                                  retry: RetryPolicy(maxAttempts: 3, baseDelayMillis: 1, maxDelayMillis: 1, jitter: .none),
                                  clock: clock, minimumRefreshIntervalMillis: 0)
        }
        var reconciler = makeReconciler(ledger)

        // 1. Launch: unknown user.
        var r = await rows(ledger)
        XCTAssertEqual(r, ["cloud: Stale, fails open (never confirmed)",
                           "onDevice: Unverified (never confirmed)",
                           "unavailable: Unverified (never confirmed)"])
        // 2. Push #1 (rev 3): suspended.
        await ledger.ingest(rev3)
        r = await rows(ledger)
        XCTAssertEqual(r, ["onDevice: User suspended", "onDevice: User suspended", "unavailable: User suspended"])
        // 3. Push #2 (rev 2): stale.
        let o = await ledger.ingest(rev2)
        XCTAssertEqual(o, .stale)
        var lastEvent = await ledger.auditLog().last?.event
        XCTAssertEqual(lastEvent, .merged(.stale, revision: 2, source: .push), "the log line the demo README promises")
        r = await rows(ledger)
        XCTAssertEqual(r, ["onDevice: User suspended", "onDevice: User suspended", "unavailable: User suspended"])
        // 4. Push #3 (rev 4): suspension lifts, agent restricted, draft still unconfirmed.
        await ledger.ingest(rev4)
        r = await rows(ledger)
        XCTAssertEqual(r, ["cloud: Stale, fails open (never confirmed)",
                           "onDevice: Unverified (never confirmed)",
                           "unavailable: Capability restricted"])
        // 5. Refresh: confirmed rev 4.
        let refreshed = await reconciler.refresh(userID: user)
        XCTAssertEqual(refreshed, .refreshed(.confirmed, attempts: 1))
        r = await rows(ledger)
        XCTAssertEqual(r, ["cloud: Confirmed fresh", "cloud: Confirmed fresh", "unavailable: Capability restricted"])
        // 6. +60 min: still fresh (inclusive window). +75 min: draft drops.
        clock.advance(byMillis: 60 * 60_000)
        r = await rows(ledger)
        XCTAssertEqual(r[1], "cloud: Confirmed fresh")
        clock.advance(byMillis: 15 * 60_000)
        r = await rows(ledger)
        XCTAssertEqual(r, ["cloud: Confirmed fresh",
                           "onDevice: Unverified (confirmed 75 min ago)",
                           "unavailable: Capability restricted"])
        // 7. Outage + refresh: fails after 3 attempts, state untouched.
        await server.setOutage(true)
        let failed = await reconciler.refresh(userID: user)
        XCTAssertEqual(failed, .failed(attempts: 3))
        let stillFour = await ledger.state(for: user)
        XCTAssertEqual(stillFour?.revision, 4)
        r = await rows(ledger)
        XCTAssertEqual(r, ["cloud: Confirmed fresh",
                           "onDevice: Unverified (confirmed 75 min ago)",
                           "unavailable: Capability restricted"])
        // 8. Relaunch from the same store, replay the oldest push: rejected by the floor.
        ledger = EnforcementLedger(clock: clock, store: store)
        reconciler = makeReconciler(ledger)
        let replay = await ledger.ingest(rev2)
        XCTAssertEqual(replay, .stale)
        lastEvent = await ledger.auditLog().last?.event
        XCTAssertEqual(lastEvent, .merged(.stale, revision: 2, source: .push))
        let restored = await ledger.state(for: user)
        XCTAssertEqual(restored?.revision, 4)
        r = await rows(ledger)
        XCTAssertEqual(r, ["cloud: Confirmed fresh",
                           "onDevice: Unverified (confirmed 75 min ago)",
                           "unavailable: Capability restricted"], "the persisted confirmation survives the relaunch")
        _ = reconciler
    }
}
