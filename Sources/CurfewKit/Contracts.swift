import Foundation

// The published output shapes (contract C7). These live in the kit, not the executable, so the
// contract can be pinned by tests: field names are stable and changes are additive only.

public struct Sources: Codable, Sendable, Equatable {
    public var witr: String?
    public var macos: String
    public var curfew: String

    public init(witr: String?, macos: String, curfew: String) {
        self.witr = witr
        self.macos = macos
        self.curfew = curfew
    }
}

public struct ListOutput: Codable, Sendable, Equatable {
    public var v: Int
    public var sources: Sources
    public var records: [ServiceRecord]
    public var scan: ScanState

    public init(v: Int = 1, sources: Sources, records: [ServiceRecord], scan: ScanState) {
        self.v = v
        self.sources = sources
        self.records = records
        self.scan = scan
    }
}

public struct FindingReport: Codable, Sendable, Equatable {
    public var label: String?
    public var domain: String?
    public var id: String
    public var severity: String
    public var summary: String
    public var evidence: String

    public init(label: String?, domain: String?, id: String, severity: String, summary: String, evidence: String) {
        self.label = label
        self.domain = domain
        self.id = id
        self.severity = severity
        self.summary = summary
        self.evidence = evidence
    }
}

public struct DoctorOutput: Codable, Sendable, Equatable {
    public var v: Int
    public var sources: Sources
    public var findings: [FindingReport]
    public var scan: ScanState
    public var disagreements: [DisagreementCount]

    public init(
        v: Int = 1, sources: Sources, findings: [FindingReport], scan: ScanState,
        disagreements: [DisagreementCount]
    ) {
        self.v = v
        self.sources = sources
        self.findings = findings
        self.scan = scan
        self.disagreements = disagreements
    }
}

public struct SourceSummary: Codable, Sendable, Equatable {
    public var type: String
    public var name: String?
    public var plistPath: String?

    public init(type: String, name: String?, plistPath: String?) {
        self.type = type
        self.name = name
        self.plistPath = plistPath
    }
}

public struct WhyOutput: Codable, Sendable, Equatable {
    public var v: Int
    public var sources: Sources
    public var record: ServiceRecord?
    public var ancestry: [AncestryNode]
    public var source: SourceSummary?
    public var warnings: [String]
    public var scan: ScanState

    public init(
        v: Int = 1, sources: Sources, record: ServiceRecord?, ancestry: [AncestryNode],
        source: SourceSummary?, warnings: [String], scan: ScanState
    ) {
        self.v = v
        self.sources = sources
        self.record = record
        self.ancestry = ancestry
        self.source = source
        self.warnings = warnings
        self.scan = scan
    }
}

// MARK: - Catalog shapes (C9)

public struct CatalogEntryReport: Codable, Sendable, Equatable {
    public var id: String
    public var kind: String
    public var lever: String
    public var supervised: String
    public var status: String
    public var hazards: [String]
    public var evidence: String?
    public var file: String

    public init(
        id: String, kind: String, lever: String, supervised: String, status: String,
        hazards: [String], evidence: String?, file: String
    ) {
        self.id = id
        self.kind = kind
        self.lever = lever
        self.supervised = supervised
        self.status = status
        self.hazards = hazards
        self.evidence = evidence
        self.file = file
    }
}

public struct CatalogBundleReport: Codable, Sendable, Equatable {
    public var name: String
    public var kind: String
    public var summary: String
    public var protectPorts: [UInt16]
    public var members: [String]

    public init(name: String, kind: String, summary: String, protectPorts: [UInt16], members: [String]) {
        self.name = name
        self.kind = kind
        self.summary = summary
        self.protectPorts = protectPorts
        self.members = members
    }
}

public struct CatalogListOutput: Codable, Sendable, Equatable {
    public var v: Int
    public var sources: Sources
    public var entries: [CatalogEntryReport]
    public var bundles: [CatalogBundleReport]
    public var violations: [String]

    public init(v: Int = 1, sources: Sources, entries: [CatalogEntryReport], bundles: [CatalogBundleReport], violations: [String]) {
        self.v = v
        self.sources = sources
        self.entries = entries
        self.bundles = bundles
        self.violations = violations
    }
}

public struct CatalogStep: Codable, Sendable, Equatable {
    public var id: String
    public var action: String
    public var argv: [[String]]
    public var expectation: String?

    public init(id: String, action: String, argv: [[String]], expectation: String?) {
        self.id = id
        self.action = action
        self.argv = argv
        self.expectation = expectation
    }
}

public struct CatalogRefusal: Codable, Sendable, Equatable {
    public var id: String
    public var reason: String

    public init(id: String, reason: String) {
        self.id = id
        self.reason = reason
    }
}

public struct CatalogPlanOutput: Codable, Sendable, Equatable {
    public var v: Int
    public var sources: Sources
    public var bundle: String
    public var steps: [CatalogStep]
    public var refusals: [CatalogRefusal]
    public var protectedPorts: [UInt16]

    public init(v: Int = 1, sources: Sources, bundle: String, steps: [CatalogStep], refusals: [CatalogRefusal], protectedPorts: [UInt16]) {
        self.v = v
        self.sources = sources
        self.bundle = bundle
        self.steps = steps
        self.refusals = refusals
        self.protectedPorts = protectedPorts
    }
}

// MARK: - Journal status (C10)

public struct UnresolvedIntent: Codable, Sendable, Equatable {
    public var seq: Int
    public var ts: String
    public var entryId: String?
    public var action: String?
    public var ageSeconds: Int?

    public init(seq: Int, ts: String, entryId: String?, action: String?, ageSeconds: Int?) {
        self.seq = seq
        self.ts = ts
        self.entryId = entryId
        self.action = action
        self.ageSeconds = ageSeconds
    }
}

public struct StatusOutput: Codable, Sendable, Equatable {
    public var v: Int
    public var sources: Sources
    public var journal: String
    public var records: Int
    public var unresolved: [UnresolvedIntent]

    public init(v: Int = 1, sources: Sources, journal: String, records: Int, unresolved: [UnresolvedIntent]) {
        self.v = v
        self.sources = sources
        self.journal = journal
        self.records = records
        self.unresolved = unresolved
    }
}

// MARK: - Apply / resume (C11)

public struct StepOutcomeReport: Codable, Sendable, Equatable {
    public var entryId: String
    public var action: String
    public var result: String
    public var detail: String?

    public init(entryId: String, action: String, result: String, detail: String?) {
        self.entryId = entryId
        self.action = action
        self.result = result
        self.detail = detail
    }
}

public struct ApplyOutput: Codable, Sendable, Equatable {
    public var v: Int
    public var sources: Sources
    public var bundle: String
    public var executed: Bool
    public var outcomes: [StepOutcomeReport]

    public init(v: Int = 1, sources: Sources, bundle: String, executed: Bool, outcomes: [StepOutcomeReport]) {
        self.v = v
        self.sources = sources
        self.bundle = bundle
        self.executed = executed
        self.outcomes = outcomes
    }
}

public struct ResumeOutput: Codable, Sendable, Equatable {
    public var v: Int
    public var sources: Sources
    public var executed: Bool
    public var outcomes: [StepOutcomeReport]

    public init(v: Int = 1, sources: Sources, executed: Bool, outcomes: [StepOutcomeReport]) {
        self.v = v
        self.sources = sources
        self.executed = executed
        self.outcomes = outcomes
    }
}
