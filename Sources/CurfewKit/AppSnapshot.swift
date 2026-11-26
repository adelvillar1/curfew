import Foundation

/// Everything the window renders, as one `Sendable` value.
///
/// The window is a surface over the same model the CLI uses — it does not gather state of its own, so
/// what it shows and what `curfew status` prints cannot drift apart. Kept free of SwiftUI and AppKit so
/// it is testable without a window.
public struct AppSnapshot: Sendable, Equatable {

    /// One change Curfew is holding, as the Held list shows it.
    public struct Held: Sendable, Equatable, Identifiable {
        public var seq: Int
        public var label: String
        public var action: String
        public var when: String
        public var id: Int { seq }
    }

    /// One row of the service table.
    public struct Service: Sendable, Equatable, Identifiable {
        /// The launchd label, verbatim — the detail line and the JSON keep it.
        public var label: String
        /// What the row reads first: `Activity Monitor`, not `application.com.apple.ActivityMonitor.…`
        public var displayName: String
        /// The folder it belongs in: Agents, Daemons, Apps.
        public var group: String
        public var state: String
        public var tier: String
        public var findingCount: Int
        public var id: String { label }

        public init(
            label: String, displayName: String, group: String, state: String, tier: String,
            findingCount: Int
        ) {
            self.label = label
            self.displayName = displayName
            self.group = group
            self.state = state
            self.tier = tier
            self.findingCount = findingCount
        }
    }

    /// A bundle, and what a preview of it would do.
    public struct Bundle: Sendable, Equatable, Identifiable {
        public var name: String
        public var summary: String
        public var isProtect: Bool
        public var members: Int
        /// How many members would actually change something.
        public var acting: Int
        public var id: String { name }
    }

    /// A finding, with what the window may do about it.
    public struct Finding: Sendable, Equatable, Identifiable {
        public var label: String
        public var kind: String
        public var severity: String
        public var summary: String
        /// The finding's own evidence line, shown when it is investigated.
        public var evidence: String
        /// The label has a verified, non-protected stop recipe — so `Stop` can be offered.
        public var canStop: Bool
        /// Curfew is holding this label right now, so the row offers `Start` instead of `Stop`.
        public var isHeld: Bool
        /// The live launchd state, so the row shows what the stop actually did.
        public var serviceState: String
        /// The stale plist may be moved to quarantine — only when the owning app is verifiably gone.
        public var canQuarantine: Bool
        /// Why quarantine is offered, or why it is not — shown as the button's tooltip.
        public var quarantineNote: String
        public var id: String { "\(label)/\(kind)" }
    }

    /// The last quiet-mode session that ended, so the app has a memory of its own work.
    public struct LastSession: Sendable, Equatable {
        public var ended: Date
        public var changes: Int
    }

    public var quiet: Bool
    public var held: [Held]
    /// Present once a session has been restored: when it ended, and how many services it put back.
    public var lastSession: LastSession?
    /// GUI apps and what they hold — the biggest reclaim on the machine, and never pre-selected.
    public var apps: [AppRecord]
    /// Every label Curfew is holding — the set the rows read to decide Stop or Start.
    public var heldLabels: Set<String>
    public var bundles: [Bundle]
    public var services: [Service]
    public var findings: [Finding]
    /// Why the window has little or nothing to show, when it does.
    public var problem: String?
    public var capturedAt: Date

    /// Orphans are processes, not launchd services, so they are reported beside the findings rather than
    /// inside them (D43) — the executor is label-addressed and will not act on a pid.
    public var orphans: [OrphanProcess] = []
    /// What the hygiene pass would do, computed for the window's Hygiene pane (D45).
    public var hygiene: HygieneReport?

    public init(
        quiet: Bool, held: [Held] = [], lastSession: LastSession? = nil,
        heldLabels: Set<String> = [], apps: [AppRecord] = [],
        bundles: [Bundle] = [], services: [Service] = [], findings: [Finding] = [],
        orphans: [OrphanProcess] = [], hygiene: HygieneReport? = nil,
        problem: String? = nil, capturedAt: Date = Date()
    ) {
        self.quiet = quiet
        self.held = held
        self.lastSession = lastSession
        self.apps = apps
        self.heldLabels = heldLabels
        self.bundles = bundles
        self.services = services
        self.findings = findings
        self.orphans = orphans
        self.hygiene = hygiene
        self.problem = problem
        self.capturedAt = capturedAt
    }

    /// The one sentence the window leads with. It answers "is my machine quiet, and what is it holding?"
    public var stateLine: String {
        guard quiet else { return "Quiet mode is off" }
        let n = held.count
        return "Quiet mode is on — \(n) change\(n == 1 ? "" : "s") held"
    }

    /// The stop bundles, and the protect sets named separately so the catalogue's size stays honest.
    public var stopBundles: [Bundle] { bundles.filter { !$0.isProtect } }
    public var protectBundles: [Bundle] { bundles.filter(\.isProtect) }
}

public enum AppSnapshotProvider {

    /// Gather the whole snapshot. `problem` explains an empty window rather than leaving it blank.
    public static func load(
        orphans: [OrphanProcess] = OrphanScan.scan(),
        hygiene: HygieneReport? = nil,
        domain: Domain = Domain.effective(),
        catalogDirectory: URL,
        journal: Journal = Journal(),
        frontmost: String? = nil,
        now: Date = Date()
    ) -> AppSnapshot {
        let apps = AppsScanner.scan(frontmost: frontmost)
        let held = journal.held().reversed().map { record in
            AppSnapshot.Held(
                seq: record.seq,
                label: record.entryId ?? "?",
                action: Vocabulary.action(record.action ?? "?"),
                when: record.ts)
        }

        let heldLabels = Set(held.map(\.label))
        let lastSession = LastSessionReader.read(from: journal.records())

        guard let catalog = try? CatalogLoader.load(directory: catalogDirectory) else {
            return AppSnapshot(
                quiet: !held.isEmpty, held: held, lastSession: lastSession,
                heldLabels: heldLabels, apps: apps,
                problem: "No catalogue at \(catalogDirectory.path) — install with `make install-app`.",
                capturedAt: now)
        }

        let records = LaunchdInventory().records(in: domain, findings: FindingsEngine()).records
        let entries = Dictionary(uniqueKeysWithValues: catalog.entries.map { ($0.id, $0) })

        let bundles: [AppSnapshot.Bundle] = catalog.bundles.map { bundle in
            let members = bundle.members.compactMap { entries[$0] }
            let acting = members.filter { $0.status == .verified && $0.stop != nil }.count
            return AppSnapshot.Bundle(
                name: bundle.name, summary: bundle.summary, isProtect: bundle.kind == .protect,
                members: bundle.members.count, acting: acting)
        }.sorted { $0.name < $1.name }

        let services = records.map { record in
            AppSnapshot.Service(
                label: record.id,
                displayName: Vocabulary.displayName(for: record.id),
                group: Vocabulary.serviceGroup(record.kind.rawValue),
                state: Vocabulary.jobState(record.state.rawValue),
                tier: record.tier.rawValue,
                findingCount: record.findings.count)
        }.sorted { $0.label < $1.label }

        let findings: [AppSnapshot.Finding] = records.flatMap { record in
            record.findings.map { finding in
                let entry = entries[record.id]
                // Debris a removed app left behind: judged from the program and the plist, never guessed.
                let verdict = QuarantineEligibility.judge(
                    program: record.program, plistPath: record.plistPath)
                let canQuarantine: Bool
                let quarantineNote: String
                switch verdict {
                case .eligible(let owner):
                    canQuarantine = true
                    quarantineNote = "\(owner) is gone — move the stale plist to quarantine"
                case .refuse(let why):
                    canQuarantine = false
                    quarantineNote = why
                }
                // Stop is only offered where a stop would be honest: verified, catalogued, not protected.
                let canStop = entry.map { $0.status == .verified && $0.stop != nil } ?? false
                    && !NeverList.isProtected(label: record.id)
                return AppSnapshot.Finding(
                    label: record.id, kind: Vocabulary.findingKind(finding.id.rawValue),
                    severity: finding.severity.rawValue, summary: finding.summary,
                    evidence: "\(finding.id.rawValue) — \(finding.evidence)", canStop: canStop,
                    isHeld: heldLabels.contains(record.id),
                    serviceState: record.state.rawValue,
                    canQuarantine: canQuarantine, quarantineNote: quarantineNote)
            }
        }.sorted { left, right in
            if left.severity != right.severity { return left.severity < right.severity }
            return left.label < right.label
        }

        return AppSnapshot(
            quiet: !held.isEmpty, held: held, lastSession: lastSession, heldLabels: heldLabels,
            apps: apps, bundles: bundles, services: services, findings: findings,
            orphans: orphans, hygiene: hygiene, capturedAt: now)
    }
}


/// Reads the last completed quiet-mode session out of the journal.
///
/// A restore writes an outcome with `result: "resumed"` against the intent it undid, so the newest such
/// outcome is the moment quiet mode ended, and the outcomes clustered just before it are the session's
/// size. Nothing is inferred that the journal does not already say.
public enum LastSessionReader {
    public static func read(
        from records: [JournalRecord], clusterWindow: TimeInterval = 600
    ) -> AppSnapshot.LastSession? {
        let restores = records.compactMap { record -> (Date, Int)? in
            guard record.kind == .outcome, record.result == "resumed",
                  let date = parseJournalTimestamp(record.ts) else { return nil }
            return (date, record.intent ?? -1)
        }
        guard let newest = restores.map(\.0).max() else { return nil }
        let inRun = restores.filter { newest.timeIntervalSince($0.0) <= clusterWindow }
        return AppSnapshot.LastSession(ended: newest, changes: inRun.count)
    }
}
