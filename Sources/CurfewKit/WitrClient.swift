import Foundation

/// What witr gives us, decoded into our own types. `Env` and `Cmdline` are **not** decoded
/// fields at all: nothing that reaches `ServiceRecord` or the log can carry them (D18).
public struct WitrReport: Sendable, Equatable {
    public var targetType: String?
    public var targetValue: String?
    public var process: ProcessFacts?
    public var sourceType: String
    public var sourceName: String?
    public var sourceUnitFile: String?
    public var warnings: [String]
}

public enum WitrFailure: Error, Sendable, Equatable {
    case notInstalled
    case incompatible(String?)
    case unreadable(String)
    case malformed(String)

    public var message: String {
        switch self {
        case .notInstalled:
            return "witr is not installed — `brew install witr` (the inventory still works without it)"
        case .incompatible(let version):
            return "witr \(version ?? "unknown") is older than 0.3.4 — upgrade it for causality"
        case .unreadable(let detail):
            return "witr could not read the process: \(detail)"
        case .malformed(let detail):
            return "witr returned something that is not a report: \(detail)"
        }
    }
}

/// The optional causality engine (D2, D5).
///
/// Three rules live here, not in the caller: argv-only invocation (never a shell string), parse
/// the JSON and check `Error` rather than trusting the exit code (KI-005), and treat a missing
/// or incompatible binary as degradation rather than failure.
public struct WitrClient: Sendable {
    public typealias Runner = @Sendable ([String]) -> CommandResult

    public let binary: String?
    private let runner: Runner

    public init(binary: String? = WitrClient.locate(), runner: @escaping Runner = WitrClient.systemRunner) {
        self.binary = binary
        self.runner = runner
    }

    // MARK: Discovery

    public static func locate(environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        // An explicit override wins, including an empty one — which is how the degradation path
        // is tested and how the future app pins a specific binary.
        if let override = environment["CURFEW_WITR_PATH"] {
            return override.isEmpty ? nil : override
        }
        let candidates = [
            "/opt/homebrew/bin/witr",
            "/usr/local/bin/witr",
            NSHomeDirectory() + "/.local/bin/witr",
        ]
        for candidate in candidates where FileManager.default.isExecutableFile(atPath: candidate) {
            return candidate
        }
        let path = environment["PATH"] ?? ""
        for directory in path.split(separator: ":") {
            let candidate = String(directory) + "/witr"
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    public static let systemRunner: Runner = { arguments in
        let process = Process()
        process.executableURL = URL(fileURLWithPath: arguments[0])
        process.arguments = Array(arguments.dropFirst())
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        do {
            try process.run()
        } catch {
            return CommandResult(standardOutput: "", standardError: "\(error)", status: -1)
        }
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return CommandResult(
            standardOutput: String(decoding: outData, as: UTF8.self),
            standardError: String(decoding: errData, as: UTF8.self),
            status: process.terminationStatus
        )
    }

    private func run(_ arguments: [String]) -> CommandResult? {
        guard let binary else { return nil }
        return runner([binary] + arguments)
    }

    // MARK: Version

    public func version() -> String? {
        guard let result = run(["--version"]) else { return nil }
        return Self.parseVersion(result.standardOutput + result.standardError)
    }

    /// Minimum only (D5): upstream's JSON contract is additive, and Homebrew moves the binary
    /// under us, so the mitigation is parse-time validation, not an upper pin.
    public func isCompatible() -> Bool {
        guard let version = version() else { return binary != nil }
        return Self.compare(version, to: "0.3.4") != .orderedAscending
    }

    static func parseVersion(_ text: String) -> String? {
        guard let range = text.range(of: #"v?(\d+)\.(\d+)\.(\d+)"#, options: .regularExpression) else {
            return nil
        }
        return String(text[range]).replacingOccurrences(of: "v", with: "")
    }

    static func compare(_ lhs: String, to rhs: String) -> ComparisonResult {
        let l = lhs.split(separator: ".").compactMap { Int($0) }
        let r = rhs.split(separator: ".").compactMap { Int($0) }
        for index in 0..<max(l.count, r.count) {
            let a = index < l.count ? l[index] : 0
            let b = index < r.count ? r[index] : 0
            if a != b { return a < b ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }

    // MARK: Probes

    public func probe(port: UInt16) -> Result<WitrReport, WitrFailure> {
        probe(arguments: ["--json", "--port", String(port)])
    }

    public func probe(pid: Int32) -> Result<WitrReport, WitrFailure> {
        probe(arguments: ["--json", "--pid", String(pid)])
    }

    public func probe(name: String) -> Result<WitrReport, WitrFailure> {
        probe(arguments: ["--json", "--exact", name])
    }

    private func probe(arguments: [String]) -> Result<WitrReport, WitrFailure> {
        guard binary != nil else { return .failure(.notInstalled) }
        guard let result = run(arguments) else { return .failure(.notInstalled) }

        // Never branch on the exit code (KI-005): witr exits 0 through a pipe when it cannot
        // read a process. The JSON is the answer; its absence is the failure.
        guard let decoded = try? JSONDecoder().decode(RawReport.self, from: Data(result.standardOutput.utf8))
        else {
            let detail = result.standardOutput.isEmpty ? result.standardError : result.standardOutput
            return .failure(.malformed(String(detail.prefix(200))))
        }
        if let error = decoded.Error, !error.isEmpty {
            return .failure(.unreadable(error))
        }
        return .success(decoded.report)
    }
}

// MARK: - Decoding

/// Only the fields we use are declared. `Env` and `Cmdline` exist in witr's JSON and are
/// deliberately absent here, so they cannot reach a record or a log line.
struct RawReport: Decodable {
    var Target: RawTarget?
    var Error: String?
    var Process: RawProcess?
    var Ancestry: [RawNode]?
    var Source: RawSource?
    var Warnings: [String]?

    struct RawTarget: Decodable {
        var kind: String?
        var Value: String?

        enum CodingKeys: String, CodingKey {
            case kind = "Type"
            case Value
        }
    }

    struct RawNode: Decodable {
        var PID: Int32?
        var Command: String?
    }

    struct RawSource: Decodable {
        var kind: String?
        var Name: String?
        var UnitFile: String?

        enum CodingKeys: String, CodingKey {
            case kind = "Type"
            case Name
            case UnitFile
        }
    }

    struct RawSocket: Decodable {
        var Port: Int?
        var Address: String?
        var State: String?
    }

    struct RawProcess: Decodable {
        var PID: Int32?
        var Command: String?
        var Exe: String?
        var WorkingDir: String?
        var GitRepo: String?
        var GitBranch: String?
        var CPUPercent: Double?
        var MemoryRSS: UInt64?
        var Sockets: [RawSocket]?
    }

    var report: WitrReport {
        let ancestry = (Ancestry ?? []).compactMap { node -> AncestryNode? in
            guard let pid = node.PID else { return nil }
            return AncestryNode(pid: pid, command: node.Command ?? "")
        }
        let facts: ProcessFacts? = Process.map { raw in
            ProcessFacts(
                pid: raw.PID ?? 0,
                exe: Self.nonEmpty(raw.Exe) ?? raw.Command ?? "",
                workingDir: Self.nonEmpty(raw.WorkingDir),
                gitRepo: Self.nonEmpty(raw.GitRepo),
                gitBranch: Self.nonEmpty(raw.GitBranch),
                listeningPorts: (raw.Sockets ?? []).compactMap { socket in
                    guard let port = socket.Port, socket.State?.uppercased() == "LISTEN", port > 0, port < 65_536
                    else { return nil }
                    return UInt16(port)
                },
                ancestry: ancestry,
                sourceType: Source?.kind ?? "unknown",
                sourceName: Self.nonEmpty(Source?.Name),
                warnings: Warnings ?? [],
                cpuPercent: raw.CPUPercent,
                memoryRSS: raw.MemoryRSS
            )
        }
        return WitrReport(
            targetType: Target?.kind,
            targetValue: Target?.Value,
            process: facts,
            sourceType: Source?.kind ?? "unknown",
            sourceName: Self.nonEmpty(Source?.Name),
            sourceUnitFile: Self.nonEmpty(Source?.UnitFile),
            warnings: Warnings ?? []
        )
    }

    static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return value
    }
}

// MARK: - Enrichment and disagreement detection

public enum WitrEnricher {

    /// Merge a report into a record, and name any disagreement it produced (D8).
    ///
    /// The safe path is always taken: launchd's pid wins, both executables are kept, and the
    /// record is marked degraded rather than resolved.
    public static func enrich(
        _ record: ServiceRecord,
        report: WitrReport
    ) -> (record: ServiceRecord, events: [DisagreementEvent]) {
        var record = record
        var events: [DisagreementEvent] = []
        record.process = report.process
        record.enrichment = .ok

        let launchd = LaunchdEvidence(
            program: record.program,
            state: record.state.rawValue,
            runs: record.runs,
            lastExit: record.lastExitCode
        )
        let witr = WitrEvidence(
            exe: report.process?.exe,
            sourceType: report.sourceType,
            pid: report.process?.pid
        )

        // D-3: two different pids. launchd's wins; the record is flagged and nothing acts on it.
        if let launchdPid = record.pid, let witrPid = report.process?.pid, launchdPid != witrPid {
            record.enrichment = .degraded
            events.append(
                DisagreementEvent(
                    kind: .identityConflict,
                    target: DisagreementTarget(label: record.id, pid: launchdPid),
                    launchd: launchd,
                    witr: witr,
                    verdict: Verdict(state: record.state.rawValue, enrichment: "degraded"),
                    note: "launchd reports pid \(launchdPid), witr reports \(witrPid); launchd wins"
                )
            )
        }

        // D-5: the declared program and the running executable differ. Keep both.
        // Only compare like with like: witr falls back to the command name when it cannot
        // resolve the executable path, and a bare name is not a path.
        if let declared = record.program, let actual = report.process?.exe,
           declared.hasPrefix("/"), actual.hasPrefix("/"),
           URL(fileURLWithPath: declared).resolvingSymlinksInPath().path
            != URL(fileURLWithPath: actual).resolvingSymlinksInPath().path {
            events.append(
                DisagreementEvent(
                    kind: .execPathConflict,
                    target: DisagreementTarget(label: record.id, pid: record.pid),
                    launchd: launchd,
                    witr: witr,
                    verdict: Verdict(state: record.state.rawValue, enrichment: "ok"),
                    note: "program = \(declared), Exe = \(actual)"
                )
            )
        }

        return (record, events)
    }

    /// launchd says the job is running, witr cannot see it (D-1).
    public static func missingReport(
        _ record: ServiceRecord,
        failure: WitrFailure
    ) -> (record: ServiceRecord, events: [DisagreementEvent]) {
        var record = record
        record.enrichment = .degraded
        let kind: DisagreementKind = {
            switch failure {
            case .unreadable, .malformed: return .witrinvalid
            case .notInstalled, .incompatible: return .enrichMissing
            }
        }()
        let event = DisagreementEvent(
            kind: kind,
            target: DisagreementTarget(label: record.id, pid: record.pid),
            launchd: LaunchdEvidence(
                program: record.program, state: record.state.rawValue,
                runs: record.runs, lastExit: record.lastExitCode
            ),
            witr: WitrEvidence(),
            verdict: Verdict(state: record.state.rawValue, enrichment: "degraded"),
            note: failure.message
        )
        return (record, kind == .witrinvalid ? [event] : [])
    }
}
