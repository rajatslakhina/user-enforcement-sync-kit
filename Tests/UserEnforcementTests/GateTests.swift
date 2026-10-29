import XCTest
@testable import UserEnforcement

final class GateTests: XCTestCase {
    let summarize = Capability(id: "summarize", displayName: "Summarize", risk: .read, hasOnDeviceFallback: true)
    let draft = Capability(id: "draft", displayName: "Draft", risk: .generate, hasOnDeviceFallback: true)
    let send = Capability(id: "send", displayName: "Agent send", risk: .act, hasOnDeviceFallback: false)
    let policy = GatePolicy.standard
    let t0 = Instant(millis: 10_000_000)

    private func confirmed(_ r: Restriction = .none, at: Instant, expires: Instant? = nil) -> UserEnforcementState {
        UserEnforcementState(revision: 1, restriction: r, expiresAt: expires, lastConfirmedAt: at)
    }

    func testUnknownUserFollowsEachTiersStaleBehavior() {
        XCTAssertEqual(EnforcementGate.decide(state: nil, capability: summarize, policy: policy, now: t0).route, .cloud)
        let d = EnforcementGate.decide(state: nil, capability: draft, policy: policy, now: t0)
        XCTAssertEqual(d.route, .onDevice)
        XCTAssertEqual(d.reason, .unverified(ageMillis: nil))
        XCTAssertEqual(EnforcementGate.decide(state: nil, capability: send, policy: policy, now: t0).route, .unavailable)
    }

    func testFreshAndClearRoutesToCloud() {
        let d = EnforcementGate.decide(state: confirmed(at: t0), capability: send, policy: policy, now: t0)
        XCTAssertEqual(d, GateDecision(route: .cloud, reason: .clear, revision: 1))
    }

    func testStalenessBoundaryIsInclusive() {
        let window = policy.tier(for: .act).maxStalenessMillis
        let state = confirmed(at: t0)
        XCTAssertEqual(EnforcementGate.decide(state: state, capability: send, policy: policy, now: t0.advanced(byMillis: window)).route, .cloud)
        let past = EnforcementGate.decide(state: state, capability: send, policy: policy, now: t0.advanced(byMillis: window + 1))
        XCTAssertEqual(past.route, .unavailable)
        XCTAssertEqual(past.reason, .unverified(ageMillis: window + 1))
    }

    func testStaleFailOpenTierStaysOnCloud() {
        let d = EnforcementGate.decide(state: confirmed(at: t0), capability: summarize, policy: policy, now: t0.advanced(byMillis: 48 * 3_600_000))
        XCTAssertEqual(d.route, .cloud)
        XCTAssertEqual(d.reason, .staleTolerated(ageMillis: 48 * 3_600_000))
    }

    /// The core rule: staleness never loosens a known restriction, even for a fail-open tier.
    func testKnownRestrictionIsHonouredEvenWhenStale() {
        let state = confirmed(.restricted(["summarize"]), at: t0)
        let d = EnforcementGate.decide(state: state, capability: summarize, policy: policy, now: t0.advanced(byMillis: 365 * 86_400_000))
        XCTAssertEqual(d.route, .onDevice)
        XCTAssertEqual(d.reason, .restricted)
        let s = EnforcementGate.decide(state: confirmed(.suspended, at: t0), capability: send, policy: policy, now: t0)
        XCTAssertEqual(s, GateDecision(route: .unavailable, reason: .suspended, revision: 1))
    }

    func testRestrictionOnOtherCapabilityDoesNotLeak() {
        let state = confirmed(.restricted(["send"]), at: t0)
        XCTAssertEqual(EnforcementGate.decide(state: state, capability: draft, policy: policy, now: t0).route, .cloud)
        XCTAssertEqual(EnforcementGate.decide(state: state, capability: send, policy: policy, now: t0).route, .unavailable)
    }

    func testTemporaryRestrictionLiftsAtExpiry() {
        let expiry = t0.advanced(byMillis: 1_000)
        let state = confirmed(.suspended, at: t0, expires: expiry)
        XCTAssertEqual(EnforcementGate.decide(state: state, capability: draft, policy: policy, now: expiry.advanced(byMillis: -1)).reason, .suspended)
        // At exactly expiresAt the suspension is lifted locally...
        XCTAssertEqual(state.effectiveRestriction(at: expiry), .none)
        // ...but a fail-closed tier waits for a confirmation from after the lift.
        XCTAssertEqual(EnforcementGate.decide(state: state, capability: draft, policy: policy, now: expiry).reason, .awaitingConfirmation(ageMillis: 1_000))
    }

    func testClockSkewWithinToleranceIsFreshBeyondIsAnomaly() {
        let state = confirmed(at: t0)
        let tolerance = policy.clockSkewToleranceMillis
        XCTAssertEqual(EnforcementGate.decide(state: state, capability: send, policy: policy, now: t0.advanced(byMillis: -tolerance)).reason, .clear)
        let back = EnforcementGate.decide(state: state, capability: send, policy: policy, now: t0.advanced(byMillis: -tolerance - 1))
        XCTAssertEqual(back, GateDecision(route: .unavailable, reason: .clockAnomaly, revision: 1))
        XCTAssertEqual(EnforcementGate.decide(state: state, capability: summarize, policy: policy, now: t0.advanced(byMillis: -tolerance - 1)).route, .cloud)
    }

    func testExtremeClockValuesDoNotTrap() {
        let state = confirmed(at: Instant(millis: .min))
        XCTAssertEqual(EnforcementGate.decide(state: state, capability: send, policy: policy, now: Instant(millis: .max)).reason, .unverified(ageMillis: .max))
        let future = confirmed(at: Instant(millis: .max))
        XCTAssertEqual(EnforcementGate.decide(state: future, capability: send, policy: policy, now: Instant(millis: .min)).reason, .clockAnomaly)
    }

    /// Review finding: moving the clock forward past a local expiry must not loosen a fail-closed
    /// tier on its own. It needs a confirmation from after the expiry.
    func testForwardClockPastExpiryDoesNotLoosenFailClosedTier() {
        let expiry = t0.advanced(byMillis: 20 * 60_000)
        let state = confirmed(.restricted(["draft"]), at: t0, expires: expiry)
        let jumped = EnforcementGate.decide(state: state, capability: draft, policy: policy, now: t0.advanced(byMillis: 30 * 60_000))
        XCTAssertEqual(jumped.route, .onDevice)
        XCTAssertEqual(jumped.reason, .awaitingConfirmation(ageMillis: 30 * 60_000))
        // A fail-open tier may lift on the local expiry.
        let readState = confirmed(.restricted(["summarize"]), at: t0, expires: expiry)
        XCTAssertEqual(EnforcementGate.decide(state: readState, capability: summarize, policy: policy, now: expiry).route, .cloud)
        // A snapshot after the expiry confirms the lift.
        let (reconfirmed, _) = EnforcementMerge.merge(state, EnforcementSignal(userID: "u", revision: 1, restriction: .restricted(["draft"]), expiresAt: expiry, source: .snapshot), now: expiry.advanced(byMillis: 1))
        XCTAssertEqual(EnforcementGate.decide(state: reconfirmed, capability: draft, policy: policy, now: expiry.advanced(byMillis: 2)).reason, .clear)
    }

    /// Review finding: a newer push that *loosens* is applied, but must not read as confirmed.
    func testLooseningPushIsAppliedButNotConfirmed() {
        let suspended = EnforcementMerge.merge(nil, EnforcementSignal(userID: "u", revision: 3, restriction: .suspended, source: .snapshot), now: t0).state
        let (lifted, outcome) = EnforcementMerge.merge(suspended, EnforcementSignal(userID: "u", revision: 4, restriction: .none, source: .push), now: t0)
        XCTAssertEqual(outcome, .applied)
        XCTAssertEqual(lifted.restriction, .none)
        XCTAssertEqual(lifted.confirmedRevision, 3)
        let d = EnforcementGate.decide(state: lifted, capability: draft, policy: policy, now: t0)
        XCTAssertEqual(d, GateDecision(route: .onDevice, reason: .awaitingConfirmation(ageMillis: 0), revision: 4))
        XCTAssertEqual(EnforcementGate.decide(state: lifted, capability: summarize, policy: policy, now: t0).route, .cloud, "fail-open tier proceeds")
        let (confirmedNow, _) = EnforcementMerge.merge(lifted, EnforcementSignal(userID: "u", revision: 4, restriction: .none, source: .responseHeader), now: t0)
        XCTAssertEqual(EnforcementGate.decide(state: confirmedNow, capability: draft, policy: policy, now: t0).reason, .clear)
    }

    /// Review finding: a phone clock 30 minutes fast must not lift a server-side expiry early
    /// once a snapshot carrying the server's time arrives.
    func testFastPhoneClockIsCorrectedByServerTime() {
        let serverNow = t0
        let localNow = t0.advanced(byMillis: 30 * 60_000)  // phone is 30 min fast
        let restriction = EnforcementSignal(userID: "u", revision: 1, restriction: .restricted(["send"]),
                                            expiresAt: serverNow.advanced(byMillis: 20 * 60_000), source: .snapshot, serverTime: serverNow)
        let state = EnforcementMerge.merge(nil, restriction, now: localNow).state
        XCTAssertEqual(state.serverOffsetMillis, -30 * 60_000)
        let d = EnforcementGate.decide(state: state, capability: send, policy: policy, now: localNow)
        XCTAssertEqual(d, GateDecision(route: .unavailable, reason: .restricted, revision: 1))
        // 20 real minutes later the restriction lifts and the gate needs a fresh confirmation...
        let later = localNow.advanced(byMillis: 20 * 60_000)
        XCTAssertEqual(EnforcementGate.decide(state: state, capability: send, policy: policy, now: later).reason, .awaitingConfirmation(ageMillis: 20 * 60_000))
        // ...and the next snapshot (same revision, server time after the expiry) confirms the lift.
        let reconfirm = restriction.withServerTime(serverNow.advanced(byMillis: 20 * 60_000))
        let confirmed = EnforcementMerge.merge(state, reconfirm, now: later).state
        XCTAssertEqual(EnforcementGate.decide(state: confirmed, capability: send, policy: policy, now: later).reason, .clear)
    }

    /// The documented limit: without a server time, a forward-skewed phone clock lifts a
    /// temporary restriction early. This is why snapshots should carry `serverTime`.
    func testWithoutServerTimeTheDeviceClockIsTrusted() {
        let localNow = t0.advanced(byMillis: 30 * 60_000)
        let restriction = EnforcementSignal(userID: "u", revision: 1, restriction: .restricted(["send"]),
                                            expiresAt: t0.advanced(byMillis: 20 * 60_000), source: .snapshot)
        let state = EnforcementMerge.merge(nil, restriction, now: localNow).state
        XCTAssertNil(state.serverOffsetMillis)
        XCTAssertEqual(EnforcementGate.decide(state: state, capability: send, policy: policy, now: localNow).route, .cloud)
    }

    func testPushesNeverCarryServerTime() {
        let push = EnforcementSignal(userID: "u", revision: 1, restriction: .none, source: .push, serverTime: t0)
        XCTAssertNil(push.serverTime)
    }

    func testMissingTierFailsClosedImmediately() {
        let sparse = GatePolicy(tiers: [.read: .init(maxStalenessMillis: 1_000, onStale: .failOpen)])
        let d = EnforcementGate.decide(state: confirmed(at: t0), capability: draft, policy: sparse, now: t0.advanced(byMillis: 1))
        XCTAssertEqual(d.route, .onDevice)
        XCTAssertEqual(d.reason, .unverified(ageMillis: 1))
    }

    func testNegativeConfigurationIsClamped() {
        let p = GatePolicy(tiers: [.act: .init(maxStalenessMillis: -5, onStale: .failClosed)], clockSkewToleranceMillis: -9)
        XCTAssertEqual(p.tier(for: .act).maxStalenessMillis, 0)
        XCTAssertEqual(p.clockSkewToleranceMillis, 0)
    }
}
