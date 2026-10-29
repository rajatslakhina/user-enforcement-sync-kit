import Foundation

/// Persistence for the ledger. Persisting is what makes monotonicity survive a relaunch: without
/// it, a push for revision 2 that APNs delivers after a relaunch would overwrite revision 4.
public protocol EnforcementStore: Sendable {
    func load() throws -> [String: UserEnforcementState]
    func save(_ states: [String: UserEnforcementState]) throws
}

public final class InMemoryEnforcementStore: EnforcementStore, @unchecked Sendable {
    // @unchecked: `states` and `failSaves` are only touched under `lock`.
    private let lock = NSLock()
    private var states: [String: UserEnforcementState] = [:]
    private var failSaves = false
    private var failLoads = false
    private var saves = 0

    public struct SaveFailed: Error {}

    public init(initial: [String: UserEnforcementState] = [:]) { states = initial }

    public struct LoadFailed: Error {}

    public func load() throws -> [String: UserEnforcementState] {
        lock.lock(); defer { lock.unlock() }
        if failLoads { throw LoadFailed() }
        return states
    }

    /// Test hook: make loads throw, as an iOS file-protection read before first unlock would.
    public func setFailLoads(_ fail: Bool) {
        lock.lock(); defer { lock.unlock() }
        failLoads = fail
    }

    public func save(_ newStates: [String: UserEnforcementState]) throws {
        lock.lock(); defer { lock.unlock() }
        if failSaves { throw SaveFailed() }
        states = newStates
        saves = saves == .max ? saves : saves + 1
    }

    /// Successful saves so far (test hook for write throttling).
    public var saveCount: Int {
        lock.lock(); defer { lock.unlock() }
        return saves
    }

    /// Test hook: make subsequent saves throw.
    public func setFailSaves(_ fail: Bool) {
        lock.lock(); defer { lock.unlock() }
        failSaves = fail
    }
}

/// JSON file store, written atomically so a crash mid-write leaves the previous file intact.
public struct FileEnforcementStore: EnforcementStore {
    public let url: URL
    public init(url: URL) { self.url = url }

    public func load() throws -> [String: UserEnforcementState] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        return try JSONDecoder().decode([String: UserEnforcementState].self, from: Data(contentsOf: url))
    }

    public func save(_ states: [String: UserEnforcementState]) throws {
        try JSONEncoder().encode(states).write(to: url, options: .atomic)
    }
}

public struct AuditEntry: Hashable, Sendable, Identifiable {
    public enum Event: Hashable, Sendable {
        case merged(MergeOutcome, revision: UInt64, source: EnforcementSignal.Source)
        case evicted
        /// The file could not be read (not corrupt: e.g. protected before first unlock).
        case storeLoadFailed
        /// The file exists but does not decode. It will be overwritten on the next save.
        case storeCorrupt
        case storeSaveFailed
        /// A save was held back because the file has not been read yet; writing now would erase
        /// every other user's revision floor.
        case storeSaveDeferred
    }
    public let id: UInt64
    public let at: Instant
    public let userID: String
    public let event: Event
}

/// The single writer for enforcement state on this device.
///
/// Every source (push handler, network layer, reconciler) funnels through `ingest`, which is
/// synchronous inside the actor: there is no `await` between reading the current state and
/// writing the merged one, so there is no reentrancy window in which two signals can interleave.
public actor EnforcementLedger {
    public struct Configuration: Sendable {
        /// Accounts tracked on one device. Bounded so a shared iPad cycling through users cannot
        /// grow the file forever. Evicting a user forgets their revision floor — see README.
        public let maxTrackedUsers: Int
        public let auditCapacity: Int
        /// A re-confirmation (same revision, same payload, already confirmed at this revision)
        /// moves only the confirmation time. Live responses confirm on every API call, so writing
        /// the file each time would put a disk write on the hot path; such merges are persisted at
        /// most this often per user. Anything else, including the *first* confirmation of a
        /// revision, is written immediately.
        public let confirmationPersistIntervalMillis: Int64
        public init(maxTrackedUsers: Int = 16, auditCapacity: Int = 64, confirmationPersistIntervalMillis: Int64 = 60_000) {
            self.maxTrackedUsers = max(1, maxTrackedUsers)
            self.auditCapacity = max(1, auditCapacity)
            self.confirmationPersistIntervalMillis = max(0, confirmationPersistIntervalMillis)
        }
    }

    private let clock: any EnforcementClock
    private let store: (any EnforcementStore)?
    private let configuration: Configuration
    private var states: [String: UserEnforcementState]
    /// Least-recently-touched first.
    private var recency: [String]
    private var audit: [AuditEntry] = []
    private var nextAuditID: UInt64 = 0
    /// When each user's state was last written, for throttling confirmation-only writes.
    private var lastPersistedAt: [String: Instant] = [:]
    /// The store failed to *read* (not decode). Until a read succeeds, saving would replace the
    /// file with only what this launch has seen.
    private var storeUnread = false

    public init(clock: any EnforcementClock = SystemClock(), store: (any EnforcementStore)? = nil, configuration: Configuration = Configuration()) {
        self.clock = clock
        self.store = store
        self.configuration = configuration
        var loaded: [String: UserEnforcementState] = [:]
        var loadEvent: AuditEntry.Event?
        var unread = false
        if let store {
            do {
                loaded = try store.load()
            } catch is DecodingError {
                loadEvent = .storeCorrupt
            } catch {
                loadEvent = .storeLoadFailed
                unread = true
            }
        }
        // The store keeps states, not touch order, so recency across a relaunch is approximated
        // by confirmation time (never-confirmed first, then oldest), with the id as a tiebreak.
        // Within a launch it is exact LRU. Trim to the cap if the file grew under an older,
        // larger configuration.
        var order = loaded.keys.sorted { a, b in
            let ta = loaded[a]?.lastConfirmedAt?.millis ?? .min
            let tb = loaded[b]?.lastConfirmedAt?.millis ?? .min
            return ta != tb ? ta < tb : a < b
        }
        while order.count > configuration.maxTrackedUsers, let first = order.first {
            loaded[first] = nil
            order.removeFirst()
        }
        self.states = loaded
        self.recency = order
        self.storeUnread = unread
        if let loadEvent {
            // Start empty: every user reads as never-confirmed, so fail-closed tiers stay closed
            // until a snapshot arrives. Safer than guessing.
            let entry = AuditEntry(id: 0, at: clock.now(), userID: "*", event: loadEvent)
            self.audit = [entry]
            self.nextAuditID = 1
        }
    }

    @discardableResult
    public func ingest(_ signal: EnforcementSignal) -> MergeOutcome {
        let now = clock.now()
        let current = states[signal.userID]
        let (merged, outcome) = EnforcementMerge.merge(current, signal, now: now)
        // Live responses confirm on every API call; logging each would push the entries that
        // matter (evictions, store failures, stale replays) out of the bounded log.
        if !(outcome == .confirmed && signal.source == .responseHeader) {
            record(signal.userID, .merged(outcome, revision: signal.revision, source: signal.source), at: now)
        }
        guard outcome != .stale else { return outcome }

        if current == nil { evictIfNeeded(makingRoomAt: now) }
        states[signal.userID] = merged
        touch(signal.userID)
        let onlyTimeMoved = outcome == .confirmed
            && current?.lastConfirmedAt != nil
            && current?.confirmedRevision == merged.confirmedRevision
        if onlyTimeMoved, let last = lastPersistedAt[signal.userID],
           now.millis(since: last) < configuration.confirmationPersistIntervalMillis {
            return outcome
        }
        persist(for: signal.userID, at: now)
        return outcome
    }

    public func state(for userID: String) -> UserEnforcementState? { states[userID] }

    /// State, decisions and audit read at one instant inside one actor turn, so a UI never shows
    /// a state from one moment next to decisions from another.
    public struct Snapshot: Sendable {
        public let now: Instant
        public let state: UserEnforcementState?
        public let decisions: [(capability: Capability, decision: GateDecision)]
        public let audit: [AuditEntry]
    }

    public func snapshot(userID: String, capabilities: [Capability], policy: GatePolicy) -> Snapshot {
        let now = clock.now()
        let state = states[userID]
        let decisions = capabilities.map {
            (capability: $0, decision: EnforcementGate.decide(state: state, capability: $0, policy: policy, now: now))
        }
        return Snapshot(now: now, state: state, decisions: decisions, audit: audit)
    }

    public func decide(userID: String, capability: Capability, policy: GatePolicy) -> GateDecision {
        EnforcementGate.decide(state: states[userID], capability: capability, policy: policy, now: clock.now())
    }

    public func auditLog() -> [AuditEntry] { audit }

    public func trackedUsers() -> [String] { recency }

    /// Size of the write-throttle table (diagnostics; bounded by `maxTrackedUsers`).
    public func persistedTimestampCount() -> Int { lastPersistedAt.count }

    // MARK: - Private

    private func touch(_ userID: String) {
        recency.removeAll { $0 == userID }
        recency.append(userID)
    }

    private func evictIfNeeded(makingRoomAt now: Instant) {
        while states.count >= configuration.maxTrackedUsers, let victim = recency.first {
            recency.removeFirst()
            states[victim] = nil
            lastPersistedAt[victim] = nil
            record(victim, .evicted, at: now)
        }
    }

    private func persist(for userID: String, at now: Instant) {
        guard let store else { return }
        if storeUnread {
            // Retry the read first. If it works, fold what was on disk into memory (higher
            // revision wins per user) so the save that follows loses nobody's floor.
            guard let onDisk = try? store.load() else {
                record(userID, .storeSaveDeferred, at: now)
                return
            }
            storeUnread = false
            for (user, saved) in onDisk {
                if let live = states[user], live.revision >= saved.revision { continue }
                // Never evict a live user to make room for one from disk; beyond the cap the
                // on-disk user is dropped, exactly as eviction would have dropped them.
                if states[user] == nil && states.count >= configuration.maxTrackedUsers { continue }
                states[user] = saved
                if !recency.contains(user) { recency.insert(user, at: 0) }
            }
        }
        do {
            try store.save(states)
            lastPersistedAt[userID] = now
        } catch {
            record(userID, .storeSaveFailed, at: now)
        }
    }

    private func record(_ userID: String, _ event: AuditEntry.Event, at now: Instant) {
        audit.append(AuditEntry(id: nextAuditID, at: now, userID: userID, event: event))
        nextAuditID &+= 1  // Wrapping is harmless: ids only need to be unique within the window.
        let overflow = audit.count - configuration.auditCapacity
        if overflow > 0 { audit.removeFirst(overflow) }
    }
}
