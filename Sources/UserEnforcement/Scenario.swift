import Foundation

/// A compiled-in script for the demo console: the capability catalogue, the gate policy, the
/// server's authoritative head, and the pushes "in flight" in the order APNs will deliver them.
///
/// The app owns this value and hands it to the console view, so the configuration a team would
/// review lives in the app target, not inside the library.
public struct EnforcementScenario: Sendable {
    public let userID: String
    /// Where the demo's manual clock starts; expiries in the script are relative to it.
    public let startsAt: Instant
    public let capabilities: [Capability]
    public let policy: GatePolicy
    /// What a snapshot request returns.
    public let serverHead: EnforcementSignal
    /// Pushes in delivery order (deliberately not revision order).
    public let pushDeliveryOrder: [EnforcementSignal]

    public init(userID: String, startsAt: Instant = Instant(millis: 0), capabilities: [Capability], policy: GatePolicy, serverHead: EnforcementSignal, pushDeliveryOrder: [EnforcementSignal]) {
        self.userID = userID
        self.startsAt = startsAt
        self.capabilities = capabilities
        self.policy = policy
        self.serverHead = serverHead
        self.pushDeliveryOrder = pushDeliveryOrder
    }

    /// The push at `index`, or `nil` once the queue is drained (or for a negative index).
    public func push(at index: Int) -> EnforcementSignal? {
        pushDeliveryOrder.indices.contains(index) ? pushDeliveryOrder[index] : nil
    }
}

public extension Restriction {
    /// Short label for UI and logs.
    var summary: String {
        switch normalized {
        case .none: return "None"
        case .suspended: return "Suspended"
        case .restricted(let ids): return "Restricted: " + ids.sorted().joined(separator: ", ")
        }
    }
}

public extension GateReason {
    var summary: String {
        switch self {
        case .clear: return "Confirmed fresh"
        case .suspended: return "User suspended"
        case .restricted: return "Capability restricted"
        case .unverified(let age): return "Unverified (\(GateReason.ageText(age)))"
        case .staleTolerated(let age): return "Stale, fails open (\(GateReason.ageText(age)))"
        case .clockAnomaly: return "Clock moved backwards"
        case .awaitingConfirmation: return "Changed since last confirmation"
        }
    }

    static func ageText(_ age: Int64?) -> String {
        guard let age else { return "never confirmed" }
        let minutes = age / 60_000
        return minutes < 1 ? "confirmed <1 min ago" : "confirmed \(minutes) min ago"
    }
}
