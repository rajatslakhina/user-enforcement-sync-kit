#if canImport(SwiftUI)
import SwiftUI
import UserEnforcement

/// Drives the console: a scripted backend, a manual clock, an in-memory store that survives a
/// simulated relaunch, and the real ledger + reconciler + gate from `UserEnforcement`.
@MainActor
public final class EnforcementConsoleModel: ObservableObject {
    public struct Row: Identifiable, Equatable {
        public let id: String
        public let name: String
        public let risk: Risk
        public let decision: GateDecision
    }

    public struct LogLine: Identifiable, Equatable {
        public let id: UInt64
        public let text: String
    }

    @Published public private(set) var rows: [Row] = []
    @Published public private(set) var state: UserEnforcementState?
    @Published public private(set) var log: [LogLine] = []
    @Published public private(set) var lastRefresh: String = "Not refreshed yet"
    @Published public private(set) var isRefreshing = false
    /// Bound to the console's toggle; `syncOutage()` pushes the value to the scripted backend.
    @Published public var serverOutage = false
    @Published public private(set) var nextPushIndex = 0
    @Published public private(set) var minutesElapsed: Int64 = 0
    @Published public private(set) var launchCount = 1

    public let scenario: EnforcementScenario
    private let clock: ManualClock
    private let server: ScriptedSnapshotSource
    private var store: InMemoryEnforcementStore
    private var ledger: EnforcementLedger
    private var reconciler: EnforcementReconciler

    public init(scenario: EnforcementScenario) {
        self.scenario = scenario
        let clock = ManualClock(start: scenario.startsAt)
        let store = InMemoryEnforcementStore()
        let server = ScriptedSnapshotSource(heads: [scenario.serverHead], serverClock: clock)
        let ledger = EnforcementLedger(clock: clock, store: store)
        self.clock = clock
        self.store = store
        self.server = server
        self.ledger = ledger
        self.reconciler = EnforcementConsoleModel.makeReconciler(ledger: ledger, server: server, clock: clock)
    }

    private static func makeReconciler(ledger: EnforcementLedger, server: ScriptedSnapshotSource, clock: ManualClock) -> EnforcementReconciler {
        // Short, un-jittered delays so the retry loop is visible but quick, and no throttle so
        // every tap on Refresh really fetches. Production defaults: full jitter, 30 s throttle.
        EnforcementReconciler(ledger: ledger, source: server,
                              retry: RetryPolicy(maxAttempts: 3, baseDelayMillis: 250, maxDelayMillis: 1_000, jitter: .none),
                              clock: clock, minimumRefreshIntervalMillis: 0)
    }

    /// Ledger-touching actions in flight. Relaunch and Reset wait for zero so nothing lands in a
    /// ledger that is being swapped out.
    @Published public private(set) var pendingActions = 0
    public var canSwapLedger: Bool { pendingActions == 0 && !isRefreshing }

    public var hasPendingPush: Bool { scenario.push(at: nextPushIndex) != nil }

    public func deliverNextPush() async {
        guard let push = scenario.push(at: nextPushIndex) else { return }
        nextPushIndex += 1
        pendingActions += 1
        await ledger.ingest(push)
        pendingActions -= 1
        await reload()
    }

    /// Re-delivers the lowest-revision push: what APNs does after a relaunch more often than
    /// you would like.
    public func replayOldestPush() async {
        guard let oldest = scenario.pushDeliveryOrder.min(by: { $0.revision < $1.revision }) else { return }
        pendingActions += 1
        await ledger.ingest(oldest)
        pendingActions -= 1
        await reload()
    }

    public func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        // The toggle's onChange syncs asynchronously; make sure the backend sees the current
        // outage setting before this fetch.
        await syncOutage()
        let outcome = await reconciler.refresh(userID: scenario.userID)
        switch outcome {
        case .refreshed(let merge, let attempts):
            lastRefresh = "Snapshot \(merge.rawValue) after \(attempts) attempt(s)"
        case .failed(let attempts):
            lastRefresh = "Refresh failed after \(attempts) attempts — state left untouched"
        case .rejectedUserMismatch:
            lastRefresh = "Rejected: snapshot was for another user"
        case .cancelled:
            lastRefresh = "Refresh cancelled"
        case .throttled:
            lastRefresh = "Throttled: refreshed moments ago"
        }
        isRefreshing = false
        await reload()
    }

    public func syncOutage() async {
        await server.setOutage(serverOutage)
    }

    public func advance15Minutes() async {
        clock.advance(byMillis: 15 * 60_000)
        minutesElapsed += 15
        await reload()
    }

    /// Throws away the ledger and reconciler and builds new ones from the same store, as a
    /// relaunch would. The revision floor survives; in-memory state does not.
    public func relaunch() async {
        // Disabled in the UI while a refresh runs: the old reconciler would otherwise write into
        // the old ledger (and the shared store) after the swap.
        guard canSwapLedger else { return }
        ledger = EnforcementLedger(clock: clock, store: store)
        reconciler = EnforcementConsoleModel.makeReconciler(ledger: ledger, server: server, clock: clock)
        launchCount += 1
        await reload()
    }

    public func reset() async {
        guard canSwapLedger else { return }
        store = InMemoryEnforcementStore()
        clock.set(scenario.startsAt)
        ledger = EnforcementLedger(clock: clock, store: store)
        reconciler = EnforcementConsoleModel.makeReconciler(ledger: ledger, server: server, clock: clock)
        nextPushIndex = 0
        minutesElapsed = 0
        launchCount = 1
        lastRefresh = "Not refreshed yet"
        serverOutage = false
        await syncOutage()
        await reload()
    }

    /// Bumped by every reload; a reload whose result arrives after a newer one started is dropped,
    /// so fast taps can't leave older rows on screen.
    private var reloadGeneration: UInt64 = 0

    func reload() async {
        reloadGeneration &+= 1
        let generation = reloadGeneration
        let snapshot = await ledger.snapshot(userID: scenario.userID, capabilities: scenario.capabilities, policy: scenario.policy)
        guard generation == reloadGeneration else { return }
        state = snapshot.state
        rows = snapshot.decisions.map {
            Row(id: $0.capability.id, name: $0.capability.displayName, risk: $0.capability.risk, decision: $0.decision)
        }
        log = snapshot.audit.reversed().map { LogLine(id: $0.id, text: EnforcementConsoleModel.describe($0)) }
    }

    static func describe(_ entry: AuditEntry) -> String {
        switch entry.event {
        case let .merged(outcome, revision, source):
            return "rev \(revision) via \(source.rawValue) → \(outcome.rawValue)"
        case .evicted: return "\(entry.userID) evicted"
        case .storeLoadFailed: return "store unreadable — saves held until it reads"
        case .storeCorrupt: return "store corrupt — starting empty"
        case .storeSaveDeferred: return "save deferred — store not read yet"
        case .storeSaveFailed: return "store save failed"
        }
    }
}

public struct EnforcementConsoleView: View {
    @StateObject private var model: EnforcementConsoleModel

    public init(scenario: EnforcementScenario) {
        _model = StateObject(wrappedValue: EnforcementConsoleModel(scenario: scenario))
    }

    public var body: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent("Revision", value: model.state.map { String($0.revision) } ?? "unknown")
                    LabeledContent("Restriction", value: model.state?.restriction.summary ?? "unknown")
                    LabeledContent("Clock", value: "+\(model.minutesElapsed) min · launch #\(model.launchCount)")
                    Text(model.lastRefresh).font(.footnote).foregroundStyle(.secondary)
                } header: {
                    Text("User \(model.scenario.userID)")
                }

                Section("What each AI feature may do") {
                    ForEach(model.rows) { row in
                        HStack(spacing: 12) {
                            Image(systemName: Self.icon(for: row.decision.route))
                                .foregroundStyle(Self.color(for: row.decision.route))
                                .frame(width: 28)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(row.name).font(.body)
                                Text(row.decision.reason.summary).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(Self.label(for: row.decision.route)).font(.caption.bold())
                        }
                        .accessibilityElement(children: .combine)
                    }
                }

                Section("Simulate") {
                    Button(model.hasPendingPush ? "Deliver next push (#\(model.nextPushIndex + 1) of \(model.scenario.pushDeliveryOrder.count))" : "All pushes delivered") {
                        Task { await model.deliverNextPush() }
                    }
                    .disabled(!model.hasPendingPush)
                    Button(model.isRefreshing ? "Refreshing…" : "Refresh snapshot from backend") {
                        Task { await model.refresh() }
                    }
                    .disabled(model.isRefreshing)
                    Toggle("Backend outage", isOn: $model.serverOutage)
                        .onChange(of: model.serverOutage) { _, _ in
                            Task { await model.syncOutage() }
                        }
                    Button("Advance clock 15 minutes") { Task { await model.advance15Minutes() } }
                    Button("Relaunch app (keep store)") { Task { await model.relaunch() } }
                        .disabled(!model.canSwapLedger)
                    Button("Replay oldest push") { Task { await model.replayOldestPush() } }
                    Button("Reset", role: .destructive) { Task { await model.reset() } }
                        .disabled(!model.canSwapLedger)
                }

                Section("Ledger audit, newest first") {
                    if model.log.isEmpty {
                        Text("No signals yet. The user is unknown, so fail-closed features are closed.")
                            .font(.footnote).foregroundStyle(.secondary)
                    } else {
                        ForEach(model.log) { line in
                            Text(line.text).font(.caption.monospaced())
                        }
                    }
                }
            }
            .navigationTitle("Enforcement")
            .task { await model.reload() }
        }
    }

    static func icon(for route: GateRoute) -> String {
        switch route {
        case .cloud: return "cloud.fill"
        case .onDevice: return "iphone"
        case .unavailable: return "xmark.octagon.fill"
        }
    }

    static func color(for route: GateRoute) -> Color {
        switch route {
        case .cloud: return .blue
        case .onDevice: return .orange
        case .unavailable: return .red
        }
    }

    static func label(for route: GateRoute) -> String {
        switch route {
        case .cloud: return "Cloud"
        case .onDevice: return "On-device"
        case .unavailable: return "Off"
        }
    }
}
#endif
