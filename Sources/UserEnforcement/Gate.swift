import Foundation

/// How much damage a capability can do if it runs for a user the provider has restricted.
public enum Risk: Int, Hashable, Sendable, Codable, CaseIterable, Comparable {
    /// Reads or summarises the user's own content.
    case read
    /// Generates content the user will see and may send.
    case generate
    /// Takes an action with side effects (sends, buys, books) through an agent.
    case act

    public static func < (lhs: Risk, rhs: Risk) -> Bool { lhs.rawValue < rhs.rawValue }
}

public struct Capability: Hashable, Sendable, Codable, Identifiable {
    public let id: String
    public let displayName: String
    public let risk: Risk
    /// Whether an on-device model can serve a degraded version when the cloud path is closed.
    public let hasOnDeviceFallback: Bool

    public init(id: String, displayName: String, risk: Risk, hasOnDeviceFallback: Bool) {
        self.id = id
        self.displayName = displayName
        self.risk = risk
        self.hasOnDeviceFallback = hasOnDeviceFallback
    }
}

public enum StaleBehavior: String, Hashable, Sendable, Codable {
    /// Keep using the cloud when we can't confirm the user is in good standing.
    case failOpen
    /// Stop using the cloud until a fresh confirmation arrives.
    case failClosed
}

public struct GatePolicy: Hashable, Sendable {
    public struct Tier: Hashable, Sendable {
        public let maxStalenessMillis: Int64
        public let onStale: StaleBehavior
        public init(maxStalenessMillis: Int64, onStale: StaleBehavior) {
            self.maxStalenessMillis = max(0, maxStalenessMillis)
            self.onStale = onStale
        }
    }

    public let tiers: [Risk: Tier]
    /// How far "now" may sit *before* the last confirmation (clock moved back, or skew between
    /// two clocks) before the gate stops trusting the age calculation.
    public let clockSkewToleranceMillis: Int64

    public init(tiers: [Risk: Tier], clockSkewToleranceMillis: Int64 = 5 * 60_000) {
        self.tiers = tiers
        self.clockSkewToleranceMillis = max(0, clockSkewToleranceMillis)
    }

    /// A tier missing from the policy is treated as the strictest possible one, so forgetting to
    /// configure a new risk level can only make the app more careful.
    public func tier(for risk: Risk) -> Tier {
        tiers[risk] ?? Tier(maxStalenessMillis: 0, onStale: .failClosed)
    }

    public static let standard = GatePolicy(tiers: [
        .read: Tier(maxStalenessMillis: 24 * 3_600_000, onStale: .failOpen),
        .generate: Tier(maxStalenessMillis: 3_600_000, onStale: .failClosed),
        .act: Tier(maxStalenessMillis: 10 * 60_000, onStale: .failClosed),
    ])
}

public enum GateRoute: String, Hashable, Sendable {
    case cloud
    case onDevice
    case unavailable
}

public enum GateReason: Hashable, Sendable {
    /// Confirmed fresh and not restricted.
    case clear
    case suspended
    case restricted
    /// Not confirmed within the tier's window and the tier fails closed. `nil` age: never confirmed.
    case unverified(ageMillis: Int64?)
    /// Not confirmed within the window, but the tier fails open.
    case staleTolerated(ageMillis: Int64?)
    /// "Now" is earlier than the last confirmation by more than the skew tolerance.
    case clockAnomaly
    /// The state changed since the last confirmation: a push delivered a newer revision, or a
    /// temporary restriction lifted locally. Treated like staleness until a snapshot or live
    /// response confirms it. Carries the age of the last (older) confirmation.
    case awaitingConfirmation(ageMillis: Int64)
}

public struct GateDecision: Hashable, Sendable {
    public let route: GateRoute
    public let reason: GateReason
    public let revision: UInt64?
}

/// The pure decision function: what may this capability do for this user, right now.
///
/// Order matters and is the core design decision: a *known* restriction is always honoured, even
/// when stale. Staleness can only make the gate stricter. Only a user we believe is clear is
/// asked the freshness question, and "clear" only counts as confirmed when a snapshot or live
/// response vouched for this exact revision after any local expiry.
public enum EnforcementGate {
    public static func decide(
        state: UserEnforcementState?,
        capability: Capability,
        policy: GatePolicy,
        now: Instant
    ) -> GateDecision {
        let closed: GateRoute = capability.hasOnDeviceFallback ? .onDevice : .unavailable
        let revision = state?.revision

        if let state {
            switch state.effectiveRestriction(at: now) {
            case .suspended:
                return GateDecision(route: closed, reason: .suspended, revision: revision)
            case .restricted(let ids) where ids.contains(capability.id):
                return GateDecision(route: closed, reason: .restricted, revision: revision)
            case .restricted, .none:
                break
            }
        }

        let tier = policy.tier(for: capability.risk)
        let failOpen = tier.onStale == .failOpen

        guard let state, let confirmed = state.lastConfirmedAt else {
            return failOpen
                ? GateDecision(route: .cloud, reason: .staleTolerated(ageMillis: nil), revision: revision)
                : GateDecision(route: closed, reason: .unverified(ageMillis: nil), revision: revision)
        }

        let age = now.millis(since: confirmed)
        if age < -policy.clockSkewToleranceMillis {
            return GateDecision(route: failOpen ? .cloud : closed, reason: .clockAnomaly, revision: revision)
        }
        // Small negative ages (within tolerance) count as zero: just confirmed.
        let effectiveAge = max(age, 0)
        if !state.isConfirmed(at: now) {
            return GateDecision(route: failOpen ? .cloud : closed, reason: .awaitingConfirmation(ageMillis: effectiveAge), revision: revision)
        }
        if effectiveAge <= tier.maxStalenessMillis {
            return GateDecision(route: .cloud, reason: .clear, revision: revision)
        }
        return failOpen
            ? GateDecision(route: .cloud, reason: .staleTolerated(ageMillis: effectiveAge), revision: revision)
            : GateDecision(route: closed, reason: .unverified(ageMillis: effectiveAge), revision: revision)
    }
}
