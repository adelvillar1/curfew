import Foundation

/// The rules that turn state into a verdict (atom L1.4).
///
/// Pure functions of their inputs plus injected closures and clock, which is what lets every
/// rule be tested against a fixture with no machine. Nothing here reads the filesystem or
/// spawns a process on its own.
public struct FindingsEngine: Sendable {

    /// Uptime stands in for "loaded for more than one hour" (D7): launchd exposes no load
    /// timestamp, and a job cannot have been loaded longer than the machine has been up.
    public var systemUptime: TimeInterval
    /// True when the path resolves to something executable (symlinks followed).
    public var executableExists: @Sendable (String) -> Bool
    /// The immediate symlink target, when the path is a symlink.
    public var symlinkTarget: @Sendable (String) -> String?
    public var fileExists: @Sendable (String) -> Bool
    /// Labels the disabled database knows about.
    public var disabledLabels: Set<String>
    /// Threshold for `runs` before a non-zero exit is called a loop.
    public var crashLoopThreshold: UInt64

    public init(
        systemUptime: TimeInterval = ProcessInfo.processInfo.systemUptime,
        executableExists: @escaping @Sendable (String) -> Bool = FindingsEngine.defaultExecutableExists,
        symlinkTarget: @escaping @Sendable (String) -> String? = FindingsEngine.defaultSymlinkTarget,
        fileExists: @escaping @Sendable (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
        disabledLabels: Set<String> = [],
        crashLoopThreshold: UInt64 = 1000
    ) {
        self.systemUptime = systemUptime
        self.executableExists = executableExists
        self.symlinkTarget = symlinkTarget
        self.fileExists = fileExists
        self.disabledLabels = disabledLabels
        self.crashLoopThreshold = crashLoopThreshold
    }

    public static let defaultExecutableExists: @Sendable (String) -> Bool = { path in
        guard !path.isEmpty else { return false }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            return false
        }
        return FileManager.default.isExecutableFile(atPath: path)
    }

    public static let defaultSymlinkTarget: @Sendable (String) -> String? = { path in
        guard let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: path) else {
            return nil
        }
        if destination.hasPrefix("/") { return destination }
        return (path as NSString).deletingLastPathComponent + "/" + destination
    }

    /// Evaluate one job. `process` is the optional witr enrichment.
    public func evaluate(_ detail: JobDetail, process: ProcessFacts? = nil) -> [Finding] {
        var findings: [Finding] = []

        if let finding = crashLoop(detail) { findings.append(finding) }
        if let finding = execFailure(detail) { findings.append(finding) }
        if let finding = danglingProgram(detail) { findings.append(finding) }
        if let finding = stalePlist(detail) { findings.append(finding) }
        if let finding = disabledButExpected(detail) { findings.append(finding) }
        if let finding = missingFields(detail) { findings.append(finding) }
        if let finding = runsFromTmpOrRoot(detail, process: process) { findings.append(finding) }

        return findings
    }

    // MARK: The rules

    /// D7's three clauses. All three are required: 453 of 887 system plists are
    /// `LaunchEvents`-driven and accumulate `runs` legitimately (KI-007).
    public func crashLoop(_ detail: JobDetail) -> Finding? {
        // A job that is running is not looping, whatever its restart history says: launchd
        // keeps the last exit code from a previous run, so `second-brain-pg` (27k restarts,
        // currently healthy) would otherwise be reported as broken.
        guard detail.state != .running else { return nil }
        guard let runs = detail.runs, runs > crashLoopThreshold,
              let exit = detail.lastExitCode, exit != 0,
              systemUptime > 3600
        else { return nil }
        return Finding(
            id: .crashLoop,
            severity: .defect,
            summary: "\(detail.label) has respawned \(runs) times and keeps exiting non-zero",
            evidence: "runs = \(runs), last exit = \(exit), system uptime \(Self.format(uptime: systemUptime))",
            confirmsScan: true
        )
    }

    /// `EX_CONFIG` means launchd could not `exec` the program at all.
    public func execFailure(_ detail: JobDetail) -> Finding? {
        guard detail.state != .running else { return nil }
        guard detail.lastExitCode == 78 else { return nil }
        return Finding(
            id: .execFailure,
            severity: .defect,
            summary: "\(detail.label) cannot be executed (EX_CONFIG)",
            evidence: "last exit code = 78: EX_CONFIG, program = \(detail.program ?? "(unknown)")",
            confirmsScan: true
        )
    }

    /// The rule that would have caught two of the three loops on 2026-11-24: the declared
    /// program is a symlink whose target no longer exists.
    public func danglingProgram(_ detail: JobDetail) -> Finding? {
        guard let program = detail.program, !program.isEmpty else { return nil }
        guard !executableExists(program) else { return nil }
        let target = symlinkTarget(program)
        let evidence: String
        if let target {
            evidence = "\(program) → \(target) (target missing)"
        } else {
            evidence = "\(program) does not exist"
        }
        return Finding(
            id: .danglingProgram,
            severity: .defect,
            summary: "\(detail.label) declares a program that cannot be run",
            evidence: evidence,
            confirmsScan: true
        )
    }

    public func stalePlist(_ detail: JobDetail) -> Finding? {
        // App-child jobs report a description here — `(submitted by runningboardd.418)` — not a
        // path. Only an absolute path can be checked for existence.
        guard let path = detail.plistPath, path.hasPrefix("/"), !fileExists(path) else { return nil }
        return Finding(
            id: .stalePlist,
            severity: .gap,
            summary: "\(detail.label) is loaded but its plist is gone",
            evidence: "path = \(path) does not exist",
            confirmsScan: true
        )
    }

    public func disabledButExpected(_ detail: JobDetail) -> Finding? {
        guard disabledLabels.contains(detail.label), detail.state == .notLoaded else { return nil }
        return Finding(
            id: .disabledButExpected,
            severity: .gap,
            summary: "\(detail.label) is disabled in the launchd database",
            evidence: "print-disabled lists \(detail.label) => disabled",
            confirmsScan: true
        )
    }

    /// A missing field is a finding about our visibility, not about the machine (D3).
    /// `confirmsScan: false` is what stops a scan from reporting itself clean.
    public func missingFields(_ detail: JobDetail) -> Finding? {
        guard !detail.missingFields.isEmpty else { return nil }
        return Finding(
            id: .fieldUnavailable,
            severity: .risk,
            summary: "\(detail.label): \(detail.missingFields.count) field(s) could not be read",
            evidence: "missing: \(detail.missingFields.joined(separator: ", "))",
            confirmsScan: false
        )
    }

    public func runsFromTmpOrRoot(_ detail: JobDetail, process: ProcessFacts?) -> Finding? {
        guard let workingDir = process?.workingDir else { return nil }
        let suspicious = ["/", "/tmp", "/var/tmp"]
        guard suspicious.contains(workingDir) else { return nil }
        return Finding(
            id: .runsFromTmpOrRoot,
            severity: .risk,
            summary: "\(detail.label) runs from \(workingDir)",
            evidence: "witr reports WorkingDir = \(workingDir)",
            confirmsScan: true
        )
    }

    // MARK: Helpers

    static func format(uptime: TimeInterval) -> String {
        let seconds = Int(uptime)
        let days = seconds / 86_400
        let hours = (seconds % 86_400) / 3_600
        if days > 0 { return "\(days)d \(hours)h" }
        return "\(hours)h"
    }
}
