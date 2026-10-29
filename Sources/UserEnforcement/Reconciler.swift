import Foundation

/// Where authoritative snapshots come from: your backend, which proxies the provider's per-user
/// enforcement status so the app never holds provider credentials.
public protocol EnforcementSnapshotSource: Sendable {
    func fetchSnapshot(userID: String) async throws -> EnforcementSignal
}

public protocol EnforcementSleeper: Sendable {
    func sleep(millis: Int64) async throws
}

public struct TaskSleeper: EnforcementSleeper {
    public init() {}
    public func sleep(millis: Int64) async throws {
        try await Task.sleep(nanoseconds: Saturating.nanoseconds(fromMillis: millis))
    }
}

public struct RetryPolicy: Hashable, Sendable {
    public enum Jitter: Hashable, Sendable {
        /// Exact exponential delays. Deterministic; used by tests and the demo.
        case none
        /// "Full jitter": a uniform delay in `0...exponential`. One provider webhook fans out to
        /// many devices at once; without jitter their retries stay synchronised.
        case full
    }

    public let maxAttempts: Int
    public let baseDelayMillis: Int64
    public let maxDelayMillis: Int64
    public let jitter: Jitter
    public init(maxAttempts: Int = 4, baseDelayMillis: Int64 = 500, maxDelayMillis: Int64 = 8_000, jitter: Jitter = .full) {
        self.maxAttempts = max(1, maxAttempts)
        self.baseDelayMillis = max(0, baseDelayMillis)
        self.maxDelayMillis = max(0, maxDelayMillis)
        self.jitter = jitter
    }

    /// The un-jittered delay before retry number `retry` (0-based).
    public func delay(beforeRetry retry: Int) -> Int64 {
        Saturating.exponentialBackoff(baseMillis: baseDelayMillis, attempt: retry, capMillis: maxDelayMillis)
    }

    /// The delay actually slept: `random` picks from `0...delay` under full jitter. The result is
    /// clamped to that range whatever `random` returns.
    public func jitteredDelay(beforeRetry retry: Int, random: (ClosedRange<Int64>) -> Int64) -> Int64 {
        let ceiling = delay(beforeRetry: retry)  // >= 0 by construction
        switch jitter {
        case .none: return ceiling
        case .full: return min(max(random(0...ceiling), 0), ceiling)
        }
    }
}

public enum RefreshOutcome: Hashable, Sendable {
    case refreshed(MergeOutcome, attempts: Int)
    /// Every attempt failed. Local state is untouched; staleness keeps growing, so fail-closed
    /// tiers will close on their own schedule. That is the intended degradation path.
    case failed(attempts: Int)
    /// The backend answered for a different user. Never applied.
    case rejectedUserMismatch
    case cancelled
    /// A refresh for this user succeeded less than `minimumRefreshIntervalMillis` ago, so no
    /// fetch was made: a run of 403s from one screen costs one snapshot, not one each.
    case throttled
}

public struct ReconcilerStats: Hashable, Sendable {
    /// Refreshes that started a fetch loop.
    public internal(set) var started = 0
    /// Callers that found a refresh already in flight and waited on it instead.
    public internal(set) var joined = 0
    /// Individual network attempts, including retries.
    public internal(set) var fetchAttempts = 0
    /// Refreshes answered `.throttled` without a fetch.
    public internal(set) var throttled = 0
}

/// Pulls snapshots on demand, single-flight per user, with budgeted exponential backoff.
///
/// Single-flight matters at scale: on a 401/403 with an enforcement marker, every in-flight
/// request in the app wants to refresh at once. Without coalescing, one restricted user's phone
/// turns into a burst of identical snapshot calls against your backend.
public actor EnforcementReconciler {
    private let ledger: EnforcementLedger
    private let source: any EnforcementSnapshotSource
    private let retry: RetryPolicy
    private let sleeper: any EnforcementSleeper
    private let clock: any EnforcementClock
    private let minimumRefreshIntervalMillis: Int64
    private let random: @Sendable (ClosedRange<Int64>) -> Int64
    private var inFlight: [String: (token: UInt64, task: Task<RefreshOutcome, Never>)] = [:]
    private var lastSuccess: [String: Instant] = [:]
    private var nextToken: UInt64 = 0
    public private(set) var stats = ReconcilerStats()

    /// Bound on `lastSuccess`; the oldest entry is dropped beyond it.
    static let maxRememberedUsers = 64

    public init(
        ledger: EnforcementLedger,
        source: any EnforcementSnapshotSource,
        retry: RetryPolicy = RetryPolicy(),
        sleeper: any EnforcementSleeper = TaskSleeper(),
        clock: any EnforcementClock = SystemClock(),
        minimumRefreshIntervalMillis: Int64 = 30_000,
        random: @escaping @Sendable (ClosedRange<Int64>) -> Int64 = { Int64.random(in: $0) }
    ) {
        self.ledger = ledger
        self.source = source
        self.retry = retry
        self.sleeper = sleeper
        self.clock = clock
        self.minimumRefreshIntervalMillis = max(0, minimumRefreshIntervalMillis)
        self.random = random
    }

    /// Cancels the shared refresh for `userID`, if one is running. Every caller waiting on it
    /// gets `.cancelled`. (Cancelling one caller's own task does not do this: the fetch is shared.)
    public func cancelRefresh(userID: String) {
        inFlight[userID]?.task.cancel()
        // Clear the slot now so a refresh started right after this one does not join the
        // cancelled task. The creator's token check keeps it from clearing a newer slot.
        inFlight[userID] = nil
    }

    public func refresh(userID: String) async -> RefreshOutcome {
        if let last = lastSuccess[userID], minimumRefreshIntervalMillis > 0 {
            let age = clock.now().millis(since: last)
            // A negative age (clock moved back) does not throttle: better one extra fetch.
            if age >= 0 && age < minimumRefreshIntervalMillis {
                stats.throttled = saturatingIncrement(stats.throttled)
                return .throttled
            }
        }
        if let existing = inFlight[userID] {
            stats.joined = saturatingIncrement(stats.joined)
            return await existing.task.value
        }
        nextToken &+= 1
        let token = nextToken
        stats.started = saturatingIncrement(stats.started)
        // Registered *before* the first suspension point, so any caller arriving while we wait
        // joins this task rather than starting a second fetch.
        let task = Task { await self.runRefresh(userID: userID) }
        inFlight[userID] = (token, task)
        let outcome = await task.value
        // Only the creator clears the slot, and only if it still owns it.
        if inFlight[userID]?.token == token { inFlight[userID] = nil }
        if case .refreshed = outcome { rememberSuccess(userID) }
        return outcome
    }

    /// Size of the throttle table (diagnostics; bounded by `maxRememberedUsers`).
    public func rememberedUserCount() -> Int { lastSuccess.count }

    private func rememberSuccess(_ userID: String) {
        lastSuccess[userID] = clock.now()
        while lastSuccess.count > Self.maxRememberedUsers,
              let oldest = lastSuccess.min(by: { $0.value < $1.value })?.key {
            lastSuccess[oldest] = nil
        }
    }

    private func runRefresh(userID: String) async -> RefreshOutcome {
        var attempt = 0
        while attempt < retry.maxAttempts {
            if Task.isCancelled { return .cancelled }
            attempt += 1
            stats.fetchAttempts = saturatingIncrement(stats.fetchAttempts)
            do {
                let snapshot = try await source.fetchSnapshot(userID: userID)
                guard snapshot.userID == userID else { return .rejectedUserMismatch }
                // Re-tagged as a snapshot whatever the source claimed: we asked, it answered.
                let outcome = await ledger.ingest(snapshot.withSource(.snapshot))
                return .refreshed(outcome, attempts: attempt)
            } catch {
                if Task.isCancelled { return .cancelled }
                guard attempt < retry.maxAttempts else { break }
                let delay = retry.jitteredDelay(beforeRetry: attempt - 1, random: random)
                do {
                    try await sleeper.sleep(millis: delay)
                } catch {
                    return .cancelled
                }
            }
        }
        return .failed(attempts: attempt)
    }

    private func saturatingIncrement(_ value: Int) -> Int { value == .max ? value : value + 1 }
}

/// A scriptable backend for the demo and tests: holds the authoritative head per user and can be
/// told to fail.
public actor ScriptedSnapshotSource: EnforcementSnapshotSource {
    public struct Outage: Error {}

    private var heads: [String: EnforcementSignal]
    private let serverClock: (any EnforcementClock)?
    private var outage = false
    private var failuresRemaining = 0
    public private(set) var requests = 0

    /// `serverClock`, when given, stamps each snapshot with the server's time.
    public init(heads: [EnforcementSignal] = [], serverClock: (any EnforcementClock)? = nil) {
        var map: [String: EnforcementSignal] = [:]
        for head in heads { map[head.userID] = head }
        self.heads = map
        self.serverClock = serverClock
    }

    public func setHead(_ signal: EnforcementSignal) { heads[signal.userID] = signal }
    public func setOutage(_ on: Bool) { outage = on }
    public func isInOutage() -> Bool { outage }
    public func failNext(_ count: Int) { failuresRemaining = max(0, count) }

    public func fetchSnapshot(userID: String) async throws -> EnforcementSignal {
        requests = requests == .max ? requests : requests + 1
        if outage { throw Outage() }
        if failuresRemaining > 0 {
            failuresRemaining -= 1
            throw Outage()
        }
        let stamp = serverClock?.now()
        guard let head = heads[userID] else {
            // Unknown to the backend: in good standing at revision 0.
            return EnforcementSignal(userID: userID, revision: 0, restriction: .none, source: .snapshot, serverTime: stamp)
        }
        return head.withSource(.snapshot).withServerTime(stamp)
    }
}
