import Foundation

/// What the provider currently enforces against one end user.
///
/// The cases form a join-semilattice ordered by severity (`none` < `restricted` < `suspended`,
/// with `restricted` sets ordered by inclusion). `joined(with:)` is the least upper bound, which is
/// what makes merging order-independent when two signals claim the same revision.
public enum Restriction: Hashable, Sendable, Codable {
    /// Nothing is restricted.
    case none
    /// Only the listed capability ids are blocked for this user.
    case restricted(Set<String>)
    /// Every cloud AI capability is blocked for this user.
    case suspended

    /// `.restricted([])` means the same thing as `.none`; normalising keeps equality structural.
    public var normalized: Restriction {
        if case .restricted(let ids) = self, ids.isEmpty { return .none }
        return self
    }

    public func blocks(_ capabilityID: String) -> Bool {
        switch self {
        case .none: return false
        case .restricted(let ids): return ids.contains(capabilityID)
        case .suspended: return true
        }
    }

    /// Least upper bound. Commutative, associative and idempotent (tested exhaustively).
    public func joined(with other: Restriction) -> Restriction {
        switch (normalized, other.normalized) {
        case (.suspended, _), (_, .suspended):
            return .suspended
        case let (.restricted(a), .restricted(b)):
            return .restricted(a.union(b))
        case (.restricted(let a), .none), (.none, .restricted(let a)):
            return .restricted(a)
        case (.none, .none):
            return .none
        }
    }
}

/// One observation of the provider's enforcement state for a user.
///
/// `revision` is assigned by the server and strictly increases per user. It is the only ordering
/// the client trusts: push delivery order, receive time and server wall-clock time are all
/// unreliable across APNs, retries and relaunches.
public struct EnforcementSignal: Hashable, Sendable, Codable {
    public enum Source: String, Hashable, Sendable, Codable {
        /// A push (APNs or a websocket) forwarded from the provider's webhook. Delivery is delayed,
        /// duplicated and unordered, so it is applied (tightening or loosening) but never counts
        /// as a confirmation of what the server thinks now.
        case push
        /// Enforcement fields read off a live API response to a request this client just made.
        case responseHeader
        /// The answer to an explicit snapshot request this client just made.
        case snapshot

        /// Whether this observation tells us what the server thinks *now*.
        public var confirmsFreshness: Bool {
            switch self {
            case .push: return false
            case .responseHeader, .snapshot: return true
            }
        }
    }

    public let userID: String
    public let revision: UInt64
    public let restriction: Restriction
    /// When the restriction lifts on its own. `nil` means it stays until a newer revision lifts it.
    public let expiresAt: Instant?
    public let source: Source
    /// The server's clock when it produced a snapshot or response. `expiresAt` is server time, so
    /// the client needs this to compare it against a phone clock that may be wrong. Pushes leave
    /// it `nil` (their delivery time says nothing about server time).
    public let serverTime: Instant?

    public init(userID: String, revision: UInt64, restriction: Restriction, expiresAt: Instant? = nil, source: Source, serverTime: Instant? = nil) {
        let normalized = restriction.normalized
        self.userID = userID
        self.revision = revision
        self.restriction = normalized
        // An expiry on "nothing restricted" means nothing; dropping it keeps payload equality honest.
        self.expiresAt = normalized == .none ? nil : expiresAt
        self.source = source
        self.serverTime = source.confirmsFreshness ? serverTime : nil
    }

    private enum CodingKeys: String, CodingKey { case userID, revision, restriction, expiresAt, source, serverTime }

    /// Decoding goes through the normalising initialiser: a payload from a backend or push must
    /// not smuggle in `.restricted([])` or an expiry on `.none`.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(userID: try c.decode(String.self, forKey: .userID),
                  revision: try c.decode(UInt64.self, forKey: .revision),
                  restriction: try c.decode(Restriction.self, forKey: .restriction),
                  expiresAt: try c.decodeIfPresent(Instant.self, forKey: .expiresAt),
                  source: try c.decode(Source.self, forKey: .source),
                  serverTime: try c.decodeIfPresent(Instant.self, forKey: .serverTime))
    }

    public func withSource(_ source: Source) -> EnforcementSignal {
        EnforcementSignal(userID: userID, revision: revision, restriction: restriction, expiresAt: expiresAt, source: source, serverTime: serverTime)
    }

    public func withServerTime(_ serverTime: Instant?) -> EnforcementSignal {
        EnforcementSignal(userID: userID, revision: revision, restriction: restriction, expiresAt: expiresAt, source: source, serverTime: serverTime)
    }
}

/// The client's local belief about one user.
public struct UserEnforcementState: Hashable, Sendable, Codable {
    public internal(set) var revision: UInt64
    public internal(set) var restriction: Restriction
    public internal(set) var expiresAt: Instant?
    /// The last time a fresh-confirming source (snapshot or live response) answered.
    /// `nil` means the state has only ever been learned from pushes.
    public internal(set) var lastConfirmedAt: Instant?
    /// The revision that confirmation was for. When it is behind `revision`, the current state
    /// came from a push and nobody has vouched for it yet.
    public internal(set) var confirmedRevision: UInt64?
    /// `serverTime - localTime`, measured at the last confirmation that carried a server time.
    /// `nil` means unknown and is treated as 0 (the phone's clock is trusted).
    public internal(set) var serverOffsetMillis: Int64?

    public init(revision: UInt64, restriction: Restriction, expiresAt: Instant?, lastConfirmedAt: Instant?, confirmedRevision: UInt64? = nil, serverOffsetMillis: Int64? = nil) {
        let normalized = restriction.normalized
        self.revision = revision
        self.restriction = normalized
        self.expiresAt = normalized == .none ? nil : expiresAt
        self.lastConfirmedAt = lastConfirmedAt
        // A confirmation time without a revision means "confirmed at this revision".
        self.confirmedRevision = confirmedRevision ?? (lastConfirmedAt == nil ? nil : revision)
        self.serverOffsetMillis = serverOffsetMillis
    }

    /// The local instant translated to the server's clock.
    public func serverTime(atLocal now: Instant) -> Instant {
        now.advanced(byMillis: serverOffsetMillis ?? 0)
    }

    private enum CodingKeys: String, CodingKey { case revision, restriction, expiresAt, lastConfirmedAt, confirmedRevision, serverOffsetMillis }

    /// Decoding goes through the normalising initialiser, so a hand-edited or older file gets the
    /// same invariants as a merged state.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(revision: try c.decode(UInt64.self, forKey: .revision),
                  restriction: try c.decode(Restriction.self, forKey: .restriction),
                  expiresAt: try c.decodeIfPresent(Instant.self, forKey: .expiresAt),
                  lastConfirmedAt: try c.decodeIfPresent(Instant.self, forKey: .lastConfirmedAt),
                  confirmedRevision: try c.decodeIfPresent(UInt64.self, forKey: .confirmedRevision),
                  serverOffsetMillis: try c.decodeIfPresent(Int64.self, forKey: .serverOffsetMillis))
    }

    /// Whether a confirmation covers the state as it stands at `now`: it must be for the current
    /// revision, and if a temporary restriction has lifted locally, the confirmation must have
    /// come after the lift. Otherwise moving the clock forward could loosen the gate on its own.
    public func isConfirmed(at now: Instant) -> Bool {
        guard let confirmedRevision, confirmedRevision == revision, let lastConfirmedAt else { return false }
        // Both sides in server time: the offset was measured at that confirmation.
        if let expiresAt, expiresAt <= serverTime(atLocal: now), serverTime(atLocal: lastConfirmedAt) < expiresAt { return false }
        return true
    }

    /// The restriction in force at local `now`. `expiresAt` is server time, so it is compared with
    /// `now` corrected by the measured server offset; it lifts at exactly `expiresAt`.
    public func effectiveRestriction(at now: Instant) -> Restriction {
        if let expiresAt, expiresAt <= serverTime(atLocal: now) { return .none }
        return restriction
    }

    /// Everything that must converge regardless of delivery order. Excludes `lastConfirmedAt`,
    /// which legitimately depends on when things arrived.
    public var convergenceKey: ConvergenceKey {
        ConvergenceKey(revision: revision, restriction: restriction, expiresAt: expiresAt)
    }
}

public struct ConvergenceKey: Hashable, Sendable {
    public let revision: UInt64
    public let restriction: Restriction
    public let expiresAt: Instant?
}

public enum MergeOutcome: String, Hashable, Sendable, Codable {
    /// A newer revision replaced the local state.
    case applied
    /// Same revision, different payload (a server-side bug or a racing writer): payloads joined to
    /// the more restrictive of the two so the result does not depend on arrival order.
    case joined
    /// Same revision, same payload. Freshness may be refreshed; nothing else changes.
    case confirmed
    /// Older than what we already hold. Ignored entirely, including for freshness.
    case stale
}

/// The pure merge function. The ledger is a thin actor around this, and `ConvergenceCheck` proves
/// properties about it, so the logic under test is exactly the logic that ships.
public enum EnforcementMerge {
    public static func merge(
        _ current: UserEnforcementState?,
        _ signal: EnforcementSignal,
        now: Instant
    ) -> (state: UserEnforcementState, outcome: MergeOutcome) {
        let confirms = signal.source.confirmsFreshness
        let confirmedAt: Instant? = confirms ? now : nil
        let measuredOffset: Int64? = signal.serverTime.map { Saturating.subtract($0.millis, now.millis) }

        guard let current else {
            let state = UserEnforcementState(
                revision: signal.revision, restriction: signal.restriction,
                expiresAt: signal.expiresAt, lastConfirmedAt: confirmedAt,
                confirmedRevision: confirms ? signal.revision : nil,
                serverOffsetMillis: measuredOffset)
            return (state, .applied)
        }

        if signal.revision > current.revision {
            // Applied immediately whichever way it moves. A push keeps the previous confirmation
            // (time and revision), which now lags `revision`, so the gate treats the new state as
            // unconfirmed until a snapshot or live response catches up.
            let state = UserEnforcementState(
                revision: signal.revision, restriction: signal.restriction,
                expiresAt: signal.expiresAt,
                lastConfirmedAt: confirmedAt ?? current.lastConfirmedAt,
                confirmedRevision: confirms ? signal.revision : current.confirmedRevision,
                serverOffsetMillis: measuredOffset ?? current.serverOffsetMillis)
            return (state, .applied)
        }

        if signal.revision < current.revision {
            return (current, .stale)
        }

        // Equal revisions.
        let refreshed = latest(current.lastConfirmedAt, confirmedAt)
        let confirmedRevision = confirms ? current.revision : current.confirmedRevision
        if signal.restriction == current.restriction && signal.expiresAt == current.expiresAt {
            var state = current
            state.lastConfirmedAt = refreshed
            state.confirmedRevision = confirmedRevision
            state.serverOffsetMillis = measuredOffset ?? current.serverOffsetMillis
            return (state, .confirmed)
        }
        let joined = current.restriction.joined(with: signal.restriction)
        let expiry = joinedExpiry((current.restriction, current.expiresAt), (signal.restriction, signal.expiresAt))
        let state = UserEnforcementState(
            revision: current.revision, restriction: joined, expiresAt: expiry,
            lastConfirmedAt: refreshed, confirmedRevision: confirmedRevision,
            serverOffsetMillis: measuredOffset ?? current.serverOffsetMillis)
        return (state, .joined)
    }

    /// Expiry of a joined restriction: only non-`none` sides count; any permanent side makes the
    /// join permanent; otherwise the later expiry wins. Commutative and associative.
    static func joinedExpiry(_ a: (Restriction, Instant?), _ b: (Restriction, Instant?)) -> Instant? {
        let sides = [a, b].filter { $0.0.normalized != .none }
        guard !sides.isEmpty else { return nil }
        if sides.contains(where: { $0.1 == nil }) { return nil }
        return sides.compactMap(\.1).max()
    }

    private static func latest(_ a: Instant?, _ b: Instant?) -> Instant? {
        switch (a, b) {
        case let (x?, y?): return max(x, y)
        case let (x?, nil): return x
        case let (nil, y?): return y
        case (nil, nil): return nil
        }
    }
}
