import Foundation

// MARK: - Version

/// The CLI's own version. The JSON output carries it so a bug report is diagnosable
/// without asking which build produced it (D5, contracts C7).
public let curfewVersion = "0.1.0"

// MARK: - Domain

/// A launchd domain. Only the two this tool can read without privilege escalation.
public enum Domain: Hashable, Sendable, Codable {
    case gui(UInt32)
    case system

    /// The string `launchctl` wants: `gui/501` or `system`.
    public var target: String {
        switch self {
        case .gui(let uid): return "gui/\(uid)"
        case .system: return "system"
        }
    }

    /// The string our JSON carries.
    public var name: String { target }

    public static var currentUser: Domain { .gui(getuid()) }

    public init?(name: String) {
        if name == "system" {
            self = .system
            return
        }
        let parts = name.split(separator: "/")
        guard parts.count == 2, parts[0] == "gui", let uid = UInt32(parts[1]) else { return nil }
        self = .gui(uid)
    }
}

// MARK: - Job state

/// What launchd says about a job. `.running` carries the pid; the rest carry none.
public enum JobState: String, Codable, Sendable, CaseIterable {
    case running
    case spawnScheduled
    case notLoaded
    case disabled
    case unknown
}

public enum KeepAliveMode: String, Codable, Sendable {
    case always
    case conditional
    case never
    case unknown
}

// MARK: - Classification vocabulary

/// Tier 0/1 are unreachable by design (D0). Tier 2 is reported, never acted on.
public enum Tier: String, Codable, Sendable, CaseIterable {
    case protectedTier = "protected"
    case osCore
    case appleAgent
    case thirdParty
}

public enum Kind: String, Codable, Sendable, CaseIterable {
    case daemon
    case agent
    case appChild
    case container
    case inProcess
    case command
    case unmanaged
}

/// Reversibility is a property of the supervisor (D12).
public enum Supervision: String, Codable, Sendable, CaseIterable {
    case launchd
    case appParent
    case none
}

/// The lever is a property of the service (D11).
public enum Lever: String, Codable, Sendable, CaseIterable {
    case freeze
    case stop
    case disable
    case throttle
    case command
    case none
}

/// Whether witr could tell us about the process behind a record (D4, D5).
public enum Enrichment: String, Codable, Sendable {
    case ok
    case unavailable
    case degraded
}

// MARK: - Findings

public enum Severity: String, Codable, Sendable, CaseIterable {
    case blocker
    case defect
    case gap
    case improvement
    case environmental
    case risk
}

/// The seven crash-loop-era rules the first slice ships (plan step 3).
public enum FindingKind: String, Codable, Sendable, CaseIterable {
    case crashLoop
    case execFailure
    case danglingProgram
    case orphanPort
    case stalePlist
    case disabledButExpected
    case noSupervisor
    case runsFromTmpOrRoot
    case fieldUnavailable
}

public struct Finding: Codable, Sendable, Equatable, Hashable {
    public var id: FindingKind
    public var severity: Severity
    public var summary: String
    /// The literal observation that justifies the finding — never a paraphrase.
    public var evidence: String
    /// False when the finding is really "we could not look" (D3): a scan carrying one
    /// of these must never be reported as clean.
    public var confirmsScan: Bool

    public init(id: FindingKind, severity: Severity, summary: String, evidence: String, confirmsScan: Bool = true) {
        self.id = id
        self.severity = severity
        self.summary = summary
        self.evidence = evidence
        self.confirmsScan = confirmsScan
    }
}

// MARK: - The record

public struct AncestryNode: Codable, Sendable, Equatable {
    public var pid: Int32
    public var command: String
}

/// What witr tells us. We store its facts without adding an opinion (contract C0).
public struct ProcessFacts: Codable, Sendable, Equatable {
    public var pid: Int32
    public var exe: String
    public var workingDir: String?
    public var gitRepo: String?
    public var gitBranch: String?
    public var listeningPorts: [UInt16]
    public var ancestry: [AncestryNode]
    public var sourceType: String
    public var sourceName: String?
    public var warnings: [String]
    public var cpuPercent: Double?
    public var memoryRSS: UInt64?
}

/// One launchd job, merged from launchd (state) and optionally witr (causality) — D2.
public struct ServiceRecord: Codable, Sendable, Equatable {
    /// The launchd label, or `unmanaged:<exe>@<port>` (D6).
    public var id: String
    public var domain: String
    public var plistPath: String?
    public var state: JobState
    public var pid: Int32?
    /// `nil` means UNKNOWN, never zero (D3).
    public var runs: UInt64?
    public var lastExitCode: Int32?
    public var program: String?
    public var keepAlive: KeepAliveMode
    public var tier: Tier
    public var kind: Kind
    public var vendor: String?
    public var supervised: Supervision
    public var process: ProcessFacts?
    public var findings: [Finding]
    public var enrichment: Enrichment

    public init(
        id: String,
        domain: String,
        plistPath: String? = nil,
        state: JobState,
        pid: Int32? = nil,
        runs: UInt64? = nil,
        lastExitCode: Int32? = nil,
        program: String? = nil,
        keepAlive: KeepAliveMode = .unknown,
        tier: Tier,
        kind: Kind,
        vendor: String? = nil,
        supervised: Supervision,
        process: ProcessFacts? = nil,
        findings: [Finding] = [],
        enrichment: Enrichment = .unavailable
    ) {
        self.id = id
        self.domain = domain
        self.plistPath = plistPath
        self.state = state
        self.pid = pid
        self.runs = runs
        self.lastExitCode = lastExitCode
        self.program = program
        self.keepAlive = keepAlive
        self.tier = tier
        self.kind = kind
        self.vendor = vendor
        self.supervised = supervised
        self.process = process
        self.findings = findings
        self.enrichment = enrichment
    }
}

// MARK: - Scan completeness

/// A scan that logged a disagreement is incomplete, and an incomplete scan is never
/// reported as clean (D3, D8).
public struct ScanState: Codable, Sendable, Equatable {
    public var complete: Bool
    public var incompleteReasons: [String]

    public init(complete: Bool = true, incompleteReasons: [String] = []) {
        self.complete = complete
        self.incompleteReasons = incompleteReasons
    }

    public mutating func markIncomplete(_ reason: String) {
        complete = false
        if !incompleteReasons.contains(reason) {
            incompleteReasons.append(reason)
        }
    }
}

// MARK: - System version

/// The macOS version that produced a `launchctl print` fixture (D3's per-version gate).
public struct SystemVersion: Sendable, Equatable {
    public let version: String

    public init(version: String) { self.version = version }

    /// Reads `sw_vers -productVersion`. Returns "unknown" rather than throwing: a
    /// diagnostic tool must still work when the OS is the thing that surprised it.
    public static func shellVersion() -> SystemVersion {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sw_vers")
        process.arguments = ["-productVersion"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            return SystemVersion(version: text.isEmpty ? "unknown" : text)
        } catch {
            return SystemVersion(version: "unknown")
        }
    }

    /// `"26.5.2"` → `"26"`. Used to look for a fixture that covers this OS major.
    public var major: String {
        String(version.split(separator: ".").first ?? "unknown")
    }
}
