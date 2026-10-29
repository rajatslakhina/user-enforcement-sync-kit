import Foundation

/// Saturating arithmetic for every time and backoff computation in the library.
///
/// All time values are `Int64` milliseconds rather than `Int`, so the ceilings are the same on
/// every platform (`Int` is 32-bit on watchOS). Nothing in this file can trap.
public enum Saturating {
    public static func add(_ a: Int64, _ b: Int64) -> Int64 {
        let (result, overflow) = a.addingReportingOverflow(b)
        guard overflow else { return result }
        return b > 0 ? .max : .min
    }

    public static func subtract(_ a: Int64, _ b: Int64) -> Int64 {
        let (result, overflow) = a.subtractingReportingOverflow(b)
        guard overflow else { return result }
        return b < 0 ? .max : .min
    }

    public static func multiply(_ a: Int64, _ b: Int64) -> Int64 {
        let (result, overflow) = a.multipliedReportingOverflow(by: b)
        guard overflow else { return result }
        return (a < 0) == (b < 0) ? .max : .min
    }

    /// `base * 2^attempt`, clamped to `[0, cap]`. Non-positive base or cap yields 0; negative
    /// attempts are treated as 0; very large attempts saturate instead of shifting out of range.
    public static func exponentialBackoff(baseMillis: Int64, attempt: Int, capMillis: Int64) -> Int64 {
        guard baseMillis > 0, capMillis > 0 else { return 0 }
        let exponent = min(max(attempt, 0), 62)
        // Safe: exponent is clamped to 0...62, so the shift cannot exceed Int64's 63 value bits.
        let factor = Int64(1) << Int64(exponent)
        return min(multiply(baseMillis, factor), capMillis)
    }

    /// Milliseconds to nanoseconds for `Task.sleep`, saturating at `UInt64.max`; non-positive is 0.
    public static func nanoseconds(fromMillis millis: Int64) -> UInt64 {
        guard millis > 0 else { return 0 }
        let (result, overflow) = UInt64(millis).multipliedReportingOverflow(by: 1_000_000)
        return overflow ? .max : result
    }

    /// Converts a floating-point millisecond value without trapping on NaN, infinity or range.
    public static func int64(_ value: Double) -> Int64? {
        guard value.isFinite else { return nil }
        // Double(Int64.max) rounds up to 2^63, so a strict `<` keeps the conversion in range.
        guard value < Double(Int64.max), value >= Double(Int64.min) else { return nil }
        return Int64(value)
    }
}

/// A wall-clock instant in milliseconds since 1970.
///
/// Wall clock, not a monotonic clock, on purpose: freshness has to survive relaunches and
/// reboots, and a monotonic clock resets on reboot. The cost is that the user can move the clock;
/// `GatePolicy.clockSkewToleranceMillis` bounds what moving it backwards can buy.
public struct Instant: Comparable, Hashable, Sendable, Codable, CustomStringConvertible {
    public let millis: Int64

    public init(millis: Int64) { self.millis = millis }

    public func advanced(byMillis delta: Int64) -> Instant {
        Instant(millis: Saturating.add(millis, delta))
    }

    /// Signed distance from `earlier` to `self`, saturating.
    public func millis(since earlier: Instant) -> Int64 {
        Saturating.subtract(millis, earlier.millis)
    }

    public static func < (lhs: Instant, rhs: Instant) -> Bool { lhs.millis < rhs.millis }

    public var description: String { "t+\(millis)ms" }
}

public protocol EnforcementClock: Sendable {
    func now() -> Instant
}

public struct SystemClock: EnforcementClock {
    public init() {}
    public func now() -> Instant {
        // A non-finite or out-of-range reading is not reachable on a real device; fall back to 0
        // (which reads as "very stale") rather than trapping.
        Instant(millis: Saturating.int64(Date().timeIntervalSince1970 * 1000) ?? 0)
    }
}

/// A clock you move by hand: used by the tests and by the demo's "+15 min" button.
public final class ManualClock: EnforcementClock, @unchecked Sendable {
    // @unchecked: every access to `current` goes through `lock`.
    private let lock = NSLock()
    private var current: Instant

    public init(start: Instant = Instant(millis: 0)) { current = start }

    public func now() -> Instant {
        lock.lock(); defer { lock.unlock() }
        return current
    }

    public func advance(byMillis delta: Int64) {
        lock.lock(); defer { lock.unlock() }
        current = current.advanced(byMillis: delta)
    }

    public func set(_ instant: Instant) {
        lock.lock(); defer { lock.unlock() }
        current = instant
    }
}
