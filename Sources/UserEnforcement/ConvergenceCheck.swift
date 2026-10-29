import Foundation

/// Exhaustively checks that a merge function reaches the same state for every delivery order of a
/// set of signals: the property that lets a phone, an iPad and a relaunched app agree without
/// talking to each other.
///
/// It takes the merge function as a parameter so the tests can feed it deliberately broken
/// implementations (last-writer-wins, replace-on-equal) and assert that the check *fails* for
/// them. A check that cannot fail is not evidence of anything.
public enum ConvergenceCheck {
    public typealias Merge = @Sendable (UserEnforcementState?, EnforcementSignal, Instant) -> UserEnforcementState

    /// 7! = 5,040 orders. Above this the check refuses rather than running for minutes.
    public static let maxSignals = 7

    public enum Report: Equatable, Sendable {
        case converged(ConvergenceKey?, ordersChecked: Int)
        /// Two delivery orders (as indices into the input) that produced different states.
        case diverged(firstOrder: [Int], secondOrder: [Int])
        case tooManySignals(Int)
    }

    /// The shipping merge, adapted to the `Merge` signature.
    public static let shippingMerge: Merge = { state, signal, now in
        EnforcementMerge.merge(state, signal, now: now).state
    }

    public static func verify(_ signals: [EnforcementSignal], merge: Merge = shippingMerge, now: Instant = Instant(millis: 0)) -> Report {
        guard signals.count <= maxSignals else { return .tooManySignals(signals.count) }
        guard !signals.isEmpty else { return .converged(nil, ordersChecked: 1) }

        var reference: (order: [Int], key: ConvergenceKey)?
        var checked = 0
        var divergence: Report?

        forEachPermutation(of: Array(signals.indices)) { order in
            var state: UserEnforcementState?
            for index in order {
                // Indices come from `signals.indices`, so they are always in bounds.
                state = merge(state, signals[index], now)
            }
            checked += 1
            // `state` is non-nil: `signals` is non-empty and every merge returns a state.
            guard let key = state?.convergenceKey else { return true }
            if let reference {
                if reference.key != key {
                    divergence = .diverged(firstOrder: reference.order, secondOrder: order)
                    return false
                }
            } else {
                reference = (order, key)
            }
            return true
        }
        if let divergence { return divergence }
        return .converged(reference?.key, ordersChecked: checked)
    }

    /// Heap's algorithm, iterative. `body` returns `false` to stop early.
    static func forEachPermutation(of input: [Int], _ body: ([Int]) -> Bool) {
        var items = input
        let n = items.count
        guard body(items) else { return }
        guard n > 1 else { return }
        var counters = [Int](repeating: 0, count: n)
        var i = 0
        while i < n {
            if counters[i] < i {
                if i % 2 == 0 { items.swapAt(0, i) } else { items.swapAt(counters[i], i) }
                guard body(items) else { return }
                counters[i] += 1
                i = 0
            } else {
                counters[i] = 0
                i += 1
            }
        }
    }
}
