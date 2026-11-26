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
        public var label: String
        public var state: String
        public var tier: String
        public var findingCount: Int
        public var id: String { label }
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
        public var id: String { "\(label)/\(kind)" }
    }

    public var quiet: Bool
    public var held: [Held]
    public var bundles: [Bundle]
    public var services: [Service]
    public var findings: [Finding]
    /// Why the window has little or nothing to show, when it does.
    public var problem: String?
    public var capturedAt: Date

    public init(
        quiet: Bool, held: [Held] = [], bundles: [Bundle] = [], services: [Service] = [],
        findings: [Finding] = [], problem: String? = nil, capturedAt: Date = Date()
    ) {
        self.quiet = quiet
        self.held = held
        self.bundles = bundles
        self.services = services
        self.findings = findings
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
        domain: Domain = Domain.effective(),
        catalogDirectory: URL,
        journal: Journal = Journal(),
        now: Date = Date()
    ) -> AppSnapshot {
        let held = journal.held().reversed().map { record in
            AppSnapshot.Held(
                seq: record.seq,
                label: record.entryId ?? "?",
                action: record.action ?? "?",
                when: record.ts)
        }

        guard let catalog = try? CatalogLoader.load(directory: catalogDirectory) else {
            return AppSnapshot(
                quiet: !held.isEmpty, held: held,
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
                label: record.id, state: record.state.rawValue, tier: record.tier.rawValue,
                findingCount: record.findings.count)
        }.sorted { $0.label < $1.label }

        let findings: [AppSnapshot.Finding] = records.flatMap { record in
            record.findings.map { finding in
                let entry = entries[record.id]
                // Stop is only offered where a stop would be honest: verified, catalogued, not protected.
                let canStop = entry.map { $0.status == .verified && $0.stop != nil } ?? false
                    && !NeverList.isProtected(label: record.id)
                return AppSnapshot.Finding(
                    label: record.id, kind: finding.id.rawValue,
                    severity: finding.severity.rawValue, summary: finding.summary,
                    evidence: finding.evidence, canStop: canStop)
            }
        }.sorted { left, right in
            if left.severity != right.severity { return left.severity < right.severity }
            return left.label < right.label
        }

        return AppSnapshot(
            quiet: !held.isEmpty, held: held, bundles: bundles, services: services,
            findings: findings, capturedAt: now)
    }
}
