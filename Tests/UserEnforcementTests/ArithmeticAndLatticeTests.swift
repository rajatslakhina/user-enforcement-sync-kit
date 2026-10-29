import XCTest
@testable import UserEnforcement

final class SaturatingTests: XCTestCase {
    func testAddSaturatesInBothDirections() {
        XCTAssertEqual(Saturating.add(.max, 1), .max)
        XCTAssertEqual(Saturating.add(.min, -1), .min)
        XCTAssertEqual(Saturating.add(40, 2), 42)
    }

    func testSubtractSaturatesInBothDirections() {
        XCTAssertEqual(Saturating.subtract(.min, 1), .min)
        XCTAssertEqual(Saturating.subtract(.max, -1), .max)
        XCTAssertEqual(Saturating.subtract(0, .min), .max)
        XCTAssertEqual(Saturating.subtract(10, 3), 7)
    }

    func testMultiplySaturatesBySign() {
        XCTAssertEqual(Saturating.multiply(.max, 2), .max)
        XCTAssertEqual(Saturating.multiply(.max, -2), .min)
        XCTAssertEqual(Saturating.multiply(.min, -1), .max)
        XCTAssertEqual(Saturating.multiply(-3, 4), -12)
    }

    func testBackoffEdges() {
        XCTAssertEqual(Saturating.exponentialBackoff(baseMillis: 100, attempt: 0, capMillis: 10_000), 100)
        XCTAssertEqual(Saturating.exponentialBackoff(baseMillis: 100, attempt: 3, capMillis: 10_000), 800)
        XCTAssertEqual(Saturating.exponentialBackoff(baseMillis: 100, attempt: 1_000, capMillis: 10_000), 10_000)
        XCTAssertEqual(Saturating.exponentialBackoff(baseMillis: 100, attempt: .max, capMillis: 10_000), 10_000)
        XCTAssertEqual(Saturating.exponentialBackoff(baseMillis: .max, attempt: 62, capMillis: .max), .max)
        XCTAssertEqual(Saturating.exponentialBackoff(baseMillis: 100, attempt: -5, capMillis: 10_000), 100)
        XCTAssertEqual(Saturating.exponentialBackoff(baseMillis: 0, attempt: 3, capMillis: 10_000), 0)
        XCTAssertEqual(Saturating.exponentialBackoff(baseMillis: -100, attempt: 3, capMillis: 10_000), 0)
        XCTAssertEqual(Saturating.exponentialBackoff(baseMillis: 100, attempt: 3, capMillis: -1), 0)
    }

    func testNanosecondConversion() {
        XCTAssertEqual(Saturating.nanoseconds(fromMillis: 2), 2_000_000)
        XCTAssertEqual(Saturating.nanoseconds(fromMillis: .max), .max)
        XCTAssertEqual(Saturating.nanoseconds(fromMillis: 0), 0)
        XCTAssertEqual(Saturating.nanoseconds(fromMillis: -10), 0)
    }

    func testDoubleConversionRejectsNonFiniteAndOutOfRange() {
        XCTAssertNil(Saturating.int64(.nan))
        XCTAssertNil(Saturating.int64(.infinity))
        XCTAssertNil(Saturating.int64(-.infinity))
        XCTAssertNil(Saturating.int64(Double(Int64.max)))  // rounds to 2^63: out of range
        XCTAssertNil(Saturating.int64(-1e19))
        XCTAssertEqual(Saturating.int64(Double(Int64.min)), .min)
        XCTAssertEqual(Saturating.int64(1234.9), 1234)
    }

    func testInstantArithmeticSaturates() {
        XCTAssertEqual(Instant(millis: .max).advanced(byMillis: 1).millis, .max)
        XCTAssertEqual(Instant(millis: .min).millis(since: Instant(millis: .max)), .min)
        XCTAssertEqual(Instant(millis: .max).millis(since: Instant(millis: .min)), .max)
    }
}

final class RestrictionLatticeTests: XCTestCase {
    /// Every combination of a small but representative universe, so the algebraic laws are
    /// checked exhaustively rather than on one hand-picked example.
    private let universe: [Restriction] = [
        .none, .suspended, .restricted([]),
        .restricted(["a"]), .restricted(["b"]), .restricted(["a", "b"]), .restricted(["c"]),
    ]

    func testJoinIsCommutative() {
        for x in universe { for y in universe {
            XCTAssertEqual(x.joined(with: y), y.joined(with: x), "\(x) ⊔ \(y)")
        } }
    }

    func testJoinIsAssociative() {
        for x in universe { for y in universe { for z in universe {
            XCTAssertEqual(x.joined(with: y).joined(with: z), x.joined(with: y.joined(with: z)))
        } } }
    }

    func testJoinIsIdempotentAndNeverLoosens() {
        for x in universe {
            XCTAssertEqual(x.joined(with: x), x.normalized)
            for y in universe {
                let j = x.joined(with: y)
                for id in ["a", "b", "c", "zzz"] where x.blocks(id) || y.blocks(id) {
                    XCTAssertTrue(j.blocks(id), "join of \(x) and \(y) unblocked \(id)")
                }
            }
        }
    }

    func testEmptyRestrictedNormalisesToNone() {
        XCTAssertEqual(Restriction.restricted([]).normalized, .none)
        let signal = EnforcementSignal(userID: "u", revision: 1, restriction: .restricted([]), expiresAt: Instant(millis: 5), source: .push)
        XCTAssertEqual(signal.restriction, .none)
        XCTAssertNil(signal.expiresAt, "an expiry on 'nothing restricted' must be dropped")
    }

    func testJoinedExpiryRules() {
        let t5 = Instant(millis: 5), t9 = Instant(millis: 9)
        XCTAssertEqual(EnforcementMerge.joinedExpiry((.suspended, t5), (.suspended, t9)), t9)
        XCTAssertNil(EnforcementMerge.joinedExpiry((.suspended, t5), (.restricted(["a"]), nil)), "permanent side wins")
        XCTAssertEqual(EnforcementMerge.joinedExpiry((.suspended, t5), (.none, nil)), t5, "a 'none' side has no say")
        XCTAssertNil(EnforcementMerge.joinedExpiry((.none, nil), (.none, nil)))
    }
}
