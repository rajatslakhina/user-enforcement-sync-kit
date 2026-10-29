# UserEnforcement

**When your AI provider restricts one of your users, does your iOS app find out from a push, a 403, or a support ticket?**

`UserEnforcement` is the client half of per-end-user AI enforcement. Your backend learns that the provider has restricted or suspended one end user. This library turns that news into one consistent decision on every device the user owns: **cloud**, **on-device fallback**, or **off**, for each AI feature. It stays correct when pushes arrive out of order, duplicated or after a relaunch, when the backend is down, and when the phone's clock is wrong (given a server time on snapshots — see decision 5).

> **Demo app:** [`user-enforcement-sync-demo-app`](https://github.com/rajatslakhina/user-enforcement-sync-demo-app) is a separate Xcode project that pulls this package from GitHub as a pinned remote dependency. Its README has screenshots from an iOS Simulator run and an eight-step walkthrough.

---

## Why this matters

AI providers are moving enforcement down from the organisation to the end user. The Claude Platform, for example, now has [user profiles](https://platform.claude.com/docs/en/manage-claude/user-profiles) for your end users and [organization webhooks](https://platform.claude.com/docs/en/manage-claude/organization-webhooks) that tell your backend when something changes. One abusive user no longer has to take your whole app down. That only helps if the client can act on it. Most apps can't today, so in practice one of two things happens:

- **Org-wide outage by accident.** The app keeps sending a restricted user's requests, the provider keeps refusing them, retries pile up, and the account's error budget goes on one person.
- **Silent wrong answers.** The push handler applies whatever arrives last. An APNs-delayed "restricted" from yesterday lands after today's "lifted", and a paying user loses features nobody can explain.

This is a distributed-systems problem on a phone. Several unreliable channels carry versioned state to replicas (devices). The replicas must converge, degrade safely when they can't confirm, and not turn one user's restriction into a burst of traffic against your backend. That is what this package implements and tests.

## Architecture

```
 provider webhook ─▶ your backend ─┬─▶ APNs push ───────────────┐ (delayed, duplicated, unordered)
                                    ├─▶ enforcement fields on   │
                                    │   every API response ─────┤
                                    └─▶ GET /enforcement ◀──────┼── EnforcementReconciler
                                        (snapshot)              │   single-flight, budgeted backoff
                                                                ▼
                                              EnforcementLedger (actor, single writer)
                                              EnforcementMerge  (pure, tested for convergence)
                                              EnforcementStore  (persisted revision floor)
                                                                │
                                                                ▼
                                   EnforcementGate.decide(state, capability, policy, now)
                                   → .cloud | .onDevice | .unavailable  + reason
```

| Type | Role |
|---|---|
| `EnforcementSignal` | One observation: user, server-assigned `revision`, `Restriction`, optional `expiresAt`, and `Source` (`push`, `responseHeader`, `snapshot`). |
| `Restriction` | `none` / `restricted(Set<id>)` / `suspended`: a join-semilattice with a commutative, associative, idempotent `joined(with:)`. |
| `EnforcementMerge` | The pure merge function. Newer revision wins, older is ignored, an equal-revision conflict joins to the more restrictive payload. |
| `ConvergenceCheck` | Applies a set of signals in **every** delivery order (up to 7! = 5,040) and reports whether they all reach the same state. It takes the merge function as a parameter so the tests can prove it catches broken ones. |
| `EnforcementLedger` | Actor around the merge. It persists the revision floor, caps tracked users with LRU eviction and keeps a bounded audit log. `snapshot(...)` returns state, decisions and audit read at one instant. `ingest` has no `await` inside, so there is no reentrancy window. |
| `EnforcementGate` | Pure decision. A known restriction means fallback or off. Otherwise the gate asks whether this exact state was confirmed, and how recently, per risk tier (`read` / `generate` / `act`). Each tier fails open or closed. |
| `EnforcementReconciler` | On-demand snapshots. Single-flight per user (50 concurrent callers make 1 fetch), a per-user throttle after success (30 s by default), capped exponential backoff with full jitter, and `cancelRefresh(userID:)`. |
| `UserEnforcementUI` | `EnforcementConsoleView`, a SwiftUI console that drives the real ledger, reconciler and gate against a scripted backend. Used by the demo app. |

## Design decisions and trade-offs

**1. Order by server revision, never by arrival or timestamps.** APNs reorders and redelivers. Server wall-clock timestamps would make correctness depend on clock sync between your fleet and the phone. A per-user revision the backend increments is cheap and exact.
*Rejected:* last-writer-wins (the default push handler; `ConvergenceCheck` shows it diverges). Vector clocks are rejected too, because there is exactly one writer (your backend) per user, so a scalar revision carries the same information.

**2. Equal revisions join instead of replacing.** Two different payloads at the same revision means a backend bug or a racing writer. Replacing makes the outcome depend on delivery order. Joining to the least upper bound (union of restricted ids, suspension dominates, a permanent restriction outranks an expiring one) keeps it order-independent and errs toward caution.
*Trade-off:* a buggy backend over-restricts until the next revision. That is visible and self-healing; the alternative fails silently.

**3. A push is applied at once but never counts as a confirmation.** A newer push is applied immediately, whether it tightens or loosens. Only a `snapshot` or a live `responseHeader` confirms, because only they describe the server *now*. Each state records `confirmedRevision`, and the gate reports `.clear` only when that equals the current revision. A pushed lift of a suspension therefore shows `.awaitingConfirmation` (or `.unverified` if the user was never confirmed): fail-open tiers proceed and fail-closed tiers stay on the fallback until a snapshot or response confirms. A twelve-hour-old push can never say "this user was fine a moment ago".

**4. Staleness can only make the gate stricter.** A *known* restriction is honoured however stale it is. Confirmation and freshness are only asked about users we believe are clear. Then each risk tier decides: `read` fails open for 24 h (summarising your own mail is low-harm), `generate` fails closed after 1 h, and `act` (an agent that sends or buys) fails closed after 10 min. A tier missing from the policy falls back to "fail closed immediately", so forgetting to configure one can only make the app more careful.

**5. Wall clock, corrected by server time, with guards in both directions.** Freshness has to survive reboots, and a monotonic clock doesn't. The cost is that the phone's clock can be wrong, or be moved. Ages are measured on the local clock, because both ends of an age are local. But `expiresAt` is *server* time. So snapshots and live responses carry `serverTime`, each confirmation stores `serverOffsetMillis = serverTime − localNow`, and expiry is evaluated as `localNow + offset`.
- **Back:** more than the tolerance (5 min by default) is reported as `.clockAnomaly` and treated as stale.
- **Fast at confirmation time:** the measured offset cancels it, so a phone 30 minutes fast does not lift a 20-minute restriction early (tested).
- **Moved forward after confirmation:** this ages every confirmation, which is stricter. It can also push the estimated server time past an `expiresAt`. The restriction then lifts locally, but the confirmation (in server time) came before the expiry, so it no longer counts and fail-closed tiers wait for a fresh one. Only fail-open (`read`) tiers can be loosened early this way, and they were going to proceed anyway.
- **Limit:** if your backend sends no `serverTime`, the offset is unknown and the phone's clock is trusted. A forward-skewed clock then lifts a temporary restriction early on every tier once a snapshot arrives (also tested, as the documented limit). The server still refuses the calls (decision 7).

**6. The persisted revision floor is what makes relaunch safe.** Without persistence, a revision-2 push delivered after a relaunch overwrites revision 4. The tests include the control case (an ephemeral ledger *accepts* that replay), so the property is shown to come from the store and not from luck.

**7. The client is not the security boundary.** A jailbroken device can edit the store. The server still refuses restricted calls. The client's job is UX and blast radius: degrade the right feature, explain why, and stop sending requests that will be refused.

**8. Single-flight refresh.** When the provider starts refusing a user, every in-flight request wants a snapshot at once. Coalescing per user turns that burst into one call. The in-flight task is registered before the first suspension point, and only its creator clears the slot.
*Trade-off:* cancelling one caller's task doesn't cancel the shared fetch, because other callers are waiting on it. `cancelRefresh(userID:)` cancels it for everyone (for example on sign-out).

**9. Bounded everything, and cheap on the hot path.** Tracked users are capped (16 by default) and so is the audit log (64 by default).
- **Eviction is exact LRU within a launch.** The store keeps states rather than touch order, so after a relaunch recency is approximated by confirmation time (never-confirmed first).
- **Evicting a user forgets their revision floor.** On a shared iPad cycling through more than 16 accounts, an evicted user's next stale push could be accepted. A snapshot corrects it, and fail-closed tiers stay closed until one arrives.
- **Disk writes are throttled.** Live responses confirm on every API call. A *re-confirmation* (same revision, already confirmed at that revision) is written at most once a minute per user. Anything else is written immediately, including the first confirmation of a revision. A crash can lose at most a minute of re-confirmation time, and that only makes the gate stricter. Re-confirmations from live responses are also left out of the bounded audit log, so they can't push out the entries that matter.
- **An unreadable store is never overwritten.** On iOS a push can wake the app before first unlock, when a protected file can't be read. Saving then would replace every user's revision floor with just this launch's. So a read failure holds all saves (`.storeSaveDeferred`) and retries the read before each one. When it succeeds, the on-disk states are folded in (higher revision wins) before writing. A file that reads but doesn't decode is reported as `.storeCorrupt` and overwritten, since nothing in it can be recovered.

**10. Retry without herding.** One provider webhook fans out to every device a user owns, and to every user in a bulk action. Full jitter (`0...exponential`, through an injectable RNG) keeps retries from staying in step. The per-user throttle means a screen that gets five 403s in a row costs one snapshot.

**Rejected alternatives at the system level:** polling only (costs battery, and the latency is the poll interval); push only (no way to tell "fine" from "never heard"); making enforcement a server-only concern (correct, but the app then can't degrade to on-device or explain anything to the user).

## Requirements and running the tests

- Swift 6 toolchain (Xcode 16+ on macOS, or `swift:6.0` on Linux). The package uses Swift 6 language mode.
- iOS 17+ / macOS 14+. `UserEnforcement` is platform-agnostic and builds on Linux. `UserEnforcementUI` is SwiftUI and compiles only on Apple platforms.

```bash
git clone https://github.com/rajatslakhina/user-enforcement-sync-kit.git
cd user-enforcement-sync-kit
swift build -Xswiftc -warnings-as-errors
swift test
```

## Use it

```swift
.package(url: "https://github.com/rajatslakhina/user-enforcement-sync-kit.git", from: "1.0.1")
```

```swift
import UserEnforcement

let ledger = EnforcementLedger(store: FileEnforcementStore(url: enforcementFileURL))
let reconciler = EnforcementReconciler(ledger: ledger, source: MyBackendSnapshotSource())

// Push handler and network layer: feed every observation in.
await ledger.ingest(EnforcementSignal(userID: id, revision: rev, restriction: .restricted(["agent-send"]), source: .push))

// Before each AI call.
let decision = await ledger.decide(userID: id, capability: agentSend, policy: .standard)
switch decision.route {
case .cloud: callClaude()
case .onDevice: runLocalModel()
case .unavailable: showExplanation(decision.reason)
}

// On a 403 carrying an enforcement marker, or when the app becomes active.
_ = await reconciler.refresh(userID: id)
```

## Crash safety

- No force-unwraps or implicitly unwrapped optionals in `Sources/`.
- Every time and backoff computation uses `Int64` milliseconds through `Saturating` (add, subtract, multiply, shift, Double→Int64, ms→ns). Nothing reachable from the public API can trap, and the tests drive `Int64.min`/`.max`, NaN and infinity through it.
- Collection access is bounds-checked (`EnforcementScenario.push(at:)` returns `nil` for out-of-range indices). Configuration values (`maxTrackedUsers`, `auditCapacity`, `maxAttempts`, delays, windows) are clamped to sane minimums.

## Tests

78 XCTest cases, including:

- **Lattice laws, exhaustively:** commutativity, associativity and idempotence of `joined(with:)` over every pair and triple of a 7-element universe, plus "a join never unblocks anything".
- **Convergence over every order:** 5 tricky signals (an equal-revision conflict, a duplicate, an expiring restriction) converge over all 120 orders. A 7-signal set with two equal-revision conflicts, expiring and permanent sides and a duplicate converges over all 5,040, and last-writer-wins diverges on it.
- **Broken implementations are caught:** last-writer-wins and replace-on-equal both come back `.diverged`, and the test shows only the equal-revision pair exposes the second one.
- **Relaunch replay:** a persisted ledger rejects a stale push after relaunch, and the control test shows an ephemeral ledger accepts it.
- **Single-flight under real concurrency:** 50 concurrent `refresh` calls against a source that blocks until all 49 joiners are counted make exactly 1 fetch. If coalescing breaks, the test still releases the source and fails on the fetch count instead of hanging.
- **Confirmation, not just freshness:** a loosening push is applied but reads `.awaitingConfirmation` until a live response confirms. Moving the clock forward past an expiry doesn't loosen a fail-closed tier, and a phone 30 minutes fast is corrected by the snapshot's server time. A source that returns a `.push`-tagged signal unchanged proves the reconciler re-tags fetched signals as snapshots.
- **Herd control:** the throttle skips fetches inside the window only (and never when the clock moved back), failures don't start the window, jitter is clamped whatever the RNG returns, and the sleeper sees the jittered delays. `cancelRefresh` ends a 60-second backoff for both callers, stops a fetch that ignores cancellation without retrying, and a refresh started right after it doesn't join the cancelled one.
- **The demo README, as a test:** `DemoWalkthroughTests` replays the demo app's eight-step walkthrough (the script is mirrored from `Demo/DemoApp.swift`, since the two live in separate repos) against the real ledger, reconciler and gate, and asserts the route and reason text of every feature at each step, including after the relaunch.
- **Gate boundaries:** the staleness window is inclusive, `window + 1` closes, clock skew at exactly the tolerance is fresh and one ms beyond is an anomaly, expiry lifts at exactly `expiresAt`, and extreme `Instant` values don't trap.
- **Failure modes:** retry exhaustion leaves state untouched, with un-jittered delays `[100, 200, 300, 300]` (capped, and no sleep after the last attempt). Also covered: recovery on the third attempt, a snapshot for the wrong user being rejected, a sleeper that throws, a corrupt store reported and overwritten, an unreadable store that defers saves and then folds the on-disk floors back in, a failing save that still enforces, LRU eviction, recency restored by confirmation time, throttled confirmation-only writes, and trimming an oversized store.

## Verification

- **CI, on every push to `main`** ([Actions tab](https://github.com/rajatslakhina/user-enforcement-sync-kit/actions)). Two jobs:
  - **Linux:** the `swift:6.0` container does a clean `swift build -Xswiftc -warnings-as-errors`, then `swift test -Xswiftc -warnings-as-errors`.
  - **macOS 15:** Xcode 16.4 / Swift 6.1.2 runs `swift test`, then `xcodebuild build` of both `UserEnforcement` and `UserEnforcementUI` for a generic iOS Simulator destination.
  - On the commits tagged `v1.0.0` and `v1.0.1`, both jobs passed. Each `swift test` ran 78 tests with 0 failures, and both iOS Simulator builds succeeded.
- **On a Mac with Xcode 27.1 (Swift 6.4):** `swift build -Xswiftc -warnings-as-errors` built both modules, including the SwiftUI one. `swift test` ran 78 tests with 0 failures, and both products built for the iOS Simulator.
- **Linux, Swift 6.0.3, during development:** a clean build with warnings as errors, and 78 tests with 0 failures. The concurrency tests were re-run several times with no flakes.
- **Mutation checks, run by hand on a scratch copy:** the suite fails when single-flight coalescing is removed (50 fetches instead of 1). It also fails when a known restriction is checked only for never-confirmed users, when the reconciler stops re-tagging fetched signals as snapshots, when the confirmation check in the gate is removed, and when the first confirmation of a revision is throttled away.
- **Run on an iOS Simulator:** the companion demo app was built against this package from GitHub and run on an iOS 27.0 Simulator (iPhone 18 Pro). All eight steps of its walkthrough behaved as documented, without a crash. Screenshots are in the [demo README](https://github.com/rajatslakhina/user-enforcement-sync-demo-app#screenshots). The run against 1.0.0 turned up one wrong line in the console (see Releases), and the walkthrough was repeated on 1.0.1.

## Releases

- **1.0.1:** console fix. After "Relaunch app (keep store)" the audit log is empty, because it lives in memory. The console used to say the user was unknown, even though the state shown above it had been restored from the store. The empty-log text now depends on whether a state exists, and the last-refresh line resets with the simulated process. No change to `UserEnforcement`.
- **1.0.0:** first release.

## License

MIT
