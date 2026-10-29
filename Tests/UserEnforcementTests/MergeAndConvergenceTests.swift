import XCTest
@testable import UserEnforcement

private func sig(_ rev: UInt64, _ r: Restriction, expires: Int64? = nil, _ source: EnforcementSignal.Source = .push, user: String = "u") -> EnforcementSignal {
    EnforcementSignal(userID: user, revision: rev, restriction: r, expiresAt: expires.map { Instant(millis: $0) }, source: source)
}

final class MergeTests: XCTestCase {
    let t0 = Instant(millis: 1_000)

    func testFirstSignalIsApplied() {
        let (state, outcome) = EnforcementMerge.merge(nil, sig(3, .suspended), now: t0)
        XCTAssertEqual(outcome, .applied)
        XCTAssertEqual(state.revision, 3)
        XCTAssertEqual(state.restriction, .suspended)
    }

    func testNewerReplacesOlderIsIgnored() {
        let s1 = EnforcementMerge.merge(nil, sig(2, .restricted(["a"])), now: t0).state
        let (s2, o2) = EnforcementMerge.merge(s1, sig(4, .none), now: t0)
        XCTAssertEqual(o2, .applied)
        XCTAssertEqual(s2.restriction, .none)
        let (s3, o3) = EnforcementMerge.merge(s2, sig(3, .suspended), now: t0)
        XCTAssertEqual(o3, .stale)
        XCTAssertEqual(s3, s2, "a stale signal must change nothing, not even freshness")
    }

    func testConfirmedRevisionTracksOnlyFreshSources() {
        let snap = EnforcementMerge.merge(nil, sig(1, .none, .snapshot), now: t0).state
        XCTAssertEqual(snap.confirmedRevision, 1)
        let pushed = EnforcementMerge.merge(snap, sig(2, .suspended), now: t0).state
        XCTAssertEqual(pushed.confirmedRevision, 1)
        XCTAssertFalse(pushed.isConfirmed(at: t0))
        let header = EnforcementMerge.merge(pushed, sig(2, .suspended, .responseHeader), now: t0).state
        XCTAssertEqual(header.confirmedRevision, 2)
        XCTAssertTrue(header.isConfirmed(at: t0))
    }

    func testPushNeverConfirmsFreshnessButSnapshotDoes() {
        let pushed = EnforcementMerge.merge(nil, sig(1, .none, .push), now: t0).state
        XCTAssertNil(pushed.lastConfirmedAt)
        let later = t0.advanced(byMillis: 60_000)
        let (confirmed, outcome) = EnforcementMerge.merge(pushed, sig(1, .none, .snapshot), now: later)
        XCTAssertEqual(outcome, .confirmed)
        XCTAssertEqual(confirmed.lastConfirmedAt, later)
        let (afterPush, _) = EnforcementMerge.merge(confirmed, sig(1, .none, .push), now: later.advanced(byMillis: 600_000))
        XCTAssertEqual(afterPush.lastConfirmedAt, later, "a duplicate push must not extend trust")
    }

    func testNewerPushKeepsPreviousConfirmationTime() {
        let snap = EnforcementMerge.merge(nil, sig(1, .none, .snapshot), now: t0).state
        let (s, _) = EnforcementMerge.merge(snap, sig(2, .suspended, .push), now: t0.advanced(byMillis: 5_000))
        XCTAssertEqual(s.lastConfirmedAt, t0)
        XCTAssertEqual(s.restriction, .suspended)
    }

    func testEqualRevisionConflictJoinsToMoreRestrictive() {
        let a = EnforcementMerge.merge(nil, sig(5, .restricted(["a"]), expires: 100), now: t0).state
        let (j, outcome) = EnforcementMerge.merge(a, sig(5, .restricted(["b"]), expires: 200), now: t0)
        XCTAssertEqual(outcome, .joined)
        XCTAssertEqual(j.restriction, .restricted(["a", "b"]))
        XCTAssertEqual(j.expiresAt, Instant(millis: 200))
    }

    func testEqualRevisionConflictResolvedBySnapshotConfirms() {
        let pushed = EnforcementMerge.merge(nil, sig(5, .restricted(["a"])), now: t0).state
        XCTAssertNil(pushed.confirmedRevision)
        let later = t0.advanced(byMillis: 9)
        let (j, outcome) = EnforcementMerge.merge(pushed, sig(5, .restricted(["b"]), .snapshot), now: later)
        XCTAssertEqual(outcome, .joined)
        XCTAssertEqual(j.confirmedRevision, 5)
        XCTAssertEqual(j.lastConfirmedAt, later)
    }

    func testExpiryLiftsAtExactlyExpiresAtAndStaleReplayStillIgnored() {
        let s = EnforcementMerge.merge(nil, sig(7, .suspended, expires: 5_000), now: t0).state
        XCTAssertEqual(s.effectiveRestriction(at: Instant(millis: 4_999)), .suspended)
        XCTAssertEqual(s.effectiveRestriction(at: Instant(millis: 5_000)), .none)
        // After the local lift, an old push must not re-impose an older revision.
        let (after, outcome) = EnforcementMerge.merge(s, sig(6, .suspended), now: Instant(millis: 6_000))
        XCTAssertEqual(outcome, .stale)
        XCTAssertEqual(after.effectiveRestriction(at: Instant(millis: 6_000)), .none)
    }
}

final class ConvergenceTests: XCTestCase {
    /// Includes an equal-revision conflict (rev 3 twice with different payloads) and a duplicate.
    let tricky: [EnforcementSignal] = [
        sig(1, .none),
        sig(2, .restricted(["send"]), expires: 9_000),
        sig(3, .restricted(["draft"])),
        sig(3, .restricted(["send"]), expires: 4_000, .snapshot),
        sig(2, .restricted(["send"]), expires: 9_000),
    ]

    func testShippingMergeConvergesOverEveryOrder() {
        let report = ConvergenceCheck.verify(tricky)
        guard case .converged(let key?, let orders) = report else {
            return XCTFail("expected convergence, got \(report)")
        }
        XCTAssertEqual(orders, 120)
        XCTAssertEqual(key.revision, 3)
        XCTAssertEqual(key.restriction, .restricted(["draft", "send"]))
        XCTAssertNil(key.expiresAt, "the permanent 'draft' side makes the join permanent")
    }

    /// The check must be able to fail. Last-writer-wins is the bug every naive push handler has.
    func testLastWriterWinsIsCaughtAsDivergent() {
        let lastWriterWins: ConvergenceCheck.Merge = { _, signal, now in
            UserEnforcementState(revision: signal.revision, restriction: signal.restriction,
                                 expiresAt: signal.expiresAt, lastConfirmedAt: now)
        }
        guard case .diverged = ConvergenceCheck.verify(tricky, merge: lastWriterWins) else {
            return XCTFail("a last-writer-wins merge must be reported as divergent")
        }
    }

    /// Subtler bug: correct revision ordering, but "replace on equal" instead of join.
    func testReplaceOnEqualRevisionIsCaughtAsDivergent() {
        let replaceOnEqual: ConvergenceCheck.Merge = { current, signal, now in
            if let current, signal.revision < current.revision { return current }
            return UserEnforcementState(revision: signal.revision, restriction: signal.restriction,
                                        expiresAt: signal.expiresAt, lastConfirmedAt: now)
        }
        guard case .diverged = ConvergenceCheck.verify(tricky, merge: replaceOnEqual) else {
            return XCTFail("replace-on-equal must be reported as divergent")
        }
        // ...and it is only the equal-revision pair that exposes it.
        let noConflict = tricky.filter { !($0.revision == 3 && $0.source == .snapshot) }
        guard case .converged = ConvergenceCheck.verify(noConflict, merge: replaceOnEqual) else {
            return XCTFail("without an equal-revision conflict, replace-on-equal happens to converge")
        }
    }

    func testEdgeSizes() {
        XCTAssertEqual(ConvergenceCheck.verify([]), .converged(nil, ordersChecked: 1))
        guard case .converged(_, 1) = ConvergenceCheck.verify([sig(1, .suspended)]) else { return XCTFail() }
        let eight = (1...8).map { sig(UInt64($0), .none) }
        XCTAssertEqual(ConvergenceCheck.verify(eight), .tooManySignals(8))
        // Seven signals with two equal-revision conflicts, expiring and permanent sides and a
        // duplicate: all 5,040 orders must agree, and last-writer-wins must not.
        let seven = [
            sig(1, .none),
            sig(2, .restricted(["a"]), expires: 100),
            sig(2, .restricted(["b"]), expires: 300, .snapshot),
            sig(4, .restricted(["c"]), expires: 50),
            sig(4, .suspended, expires: 80, .responseHeader),
            sig(4, .restricted(["c"]), expires: 50),
            sig(3, .none),
        ]
        guard case .converged(let key?, 5_040) = ConvergenceCheck.verify(seven) else { return XCTFail() }
        XCTAssertEqual(key, ConvergenceKey(revision: 4, restriction: .suspended, expiresAt: Instant(millis: 80)))
        let lastWriterWins: ConvergenceCheck.Merge = { _, signal, now in
            UserEnforcementState(revision: signal.revision, restriction: signal.restriction, expiresAt: signal.expiresAt, lastConfirmedAt: now)
        }
        guard case .diverged = ConvergenceCheck.verify(seven, merge: lastWriterWins) else { return XCTFail() }
    }

    func testPermutationGeneratorVisitsEveryOrderExactlyOnce() {
        var seen = Set<[Int]>()
        var count = 0
        ConvergenceCheck.forEachPermutation(of: [0, 1, 2, 3]) { order in
            seen.insert(order); count += 1; return true
        }
        XCTAssertEqual(count, 24)
        XCTAssertEqual(seen.count, 24)
    }
}
