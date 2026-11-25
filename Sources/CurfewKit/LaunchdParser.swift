import Foundation

/// One job's raw state as `launchctl print` reports it, before classification.
///
/// Every field except the label is optional because a missing field must stay
/// distinguishable from a zero (D3): `runs == nil` means "we could not see it", and a
/// scan that could not see must never be reported as clean.
public struct JobDetail: Sendable, Equatable {
    public var label: String
    public var domain: Domain
    public var state: JobState
    public var pid: Int32?
    public var runs: UInt64?
    public var lastExitCode: Int32?
    public var program: String?
    public var plistPath: String?
    public var keepAlive: KeepAliveMode
    /// Required fields the parse did not find. Non-empty means the record is degraded.
    public var missingFields: [String]

    public init(
        label: String,
        domain: Domain,
        state: JobState,
        pid: Int32? = nil,
        runs: UInt64? = nil,
        lastExitCode: Int32? = nil,
        program: String? = nil,
        plistPath: String? = nil,
        keepAlive: KeepAliveMode = .unknown,
        missingFields: [String] = []
    ) {
        self.label = label
        self.domain = domain
        self.state = state
        self.pid = pid
        self.runs = runs
        self.lastExitCode = lastExitCode
        self.program = program
        self.plistPath = plistPath
        self.keepAlive = keepAlive
        self.missingFields = missingFields
    }
}

/// Parses `launchctl print` output. Pure string handling, so every rule here is testable
/// against a captured fixture with no machine and no subprocess.
///
/// The format is undocumented (KI-006), so the strategy is D3: be tolerant about the shape,
/// strict about knowing which fields we actually got.
public enum LaunchdParser {

    /// The fields this tool depends on. Their absence is reported, never guessed.
    static let requiredFields = ["state", "path", "program", "runs"]

    // MARK: Domain table

    /// The `services = { … }` table: `<pid> <status> <label>` per row.
    ///
    /// Tolerant by construction — a row that does not match is counted and skipped, so one
    /// odd line never blanks the inventory. Rows are only used to get labels.
    public static func domainTable(_ text: String) -> (labels: [String], skipped: Int) {
        var labels: [String] = []
        var skipped = 0
        var inTable = false

        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#") { continue }
            if trimmed.hasPrefix("services = {") { inTable = true; continue }
            if inTable, trimmed == "}" { break }
            guard inTable else { continue }

            // `<pid> <status> <label>` where status is `-` (not running) or an exit code,
            // optionally followed by a bracket group like `(pe)`.
            let parts = trimmed.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard parts.count == 3,
                  Int(parts[0]) != nil || parts[0] == "-",
                  let label = parts[2].split(separator: " ").first,
                  label.contains(".") || label.contains(":")
            else {
                skipped += 1
                continue
            }
            let name = String(parts[2]).trimmingCharacters(in: .whitespaces)
            // strip a trailing bracket group if the status column bled into the cell
            labels.append(name.split(separator: " ").first.map(String.init) ?? name)
        }
        return (labels, skipped)
    }

    // MARK: Per-job detail

    /// Parse one `launchctl print <domain>/<label>` body.
    ///
    /// Only top-level keys (brace depth 1) are read: nested blocks carry their own `state = active`
    /// lines which would otherwise be mistaken for the job's state.
    public static func jobDetail(_ text: String, label: String, domain: Domain) -> JobDetail? {
        guard text.contains("\(domain.target)/\(label)") else { return nil }

        var values: [String: String] = [:]
        var depth = 0

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#") { continue }

            if trimmed.hasSuffix("{") {
                depth += 1
                continue
            }
            if trimmed == "}" {
                depth = max(0, depth - 1)
                continue
            }
            guard depth == 1, let eq = trimmed.range(of: " = ") else { continue }
            let key = String(trimmed[trimmed.startIndex..<eq.lowerBound])
            let value = String(trimmed[eq.upperBound...])
            // first occurrence wins: the outer key precedes any nested duplicate
            if values[key] == nil { values[key] = value }
        }

        guard let stateText = values["state"] else { return nil }

        let state: JobState
        switch stateText {
        case "running": state = .running
        case "spawn scheduled": state = .spawnScheduled
        case "not running": state = .notLoaded
        default: state = .unknown
        }

        var missing: [String] = []
        for field in requiredFields where values[field] == nil && field != "program" {
            missing.append(field)
        }
        // `program` can be legitimately absent (inferred from arguments); only flag it when
        // there is no argument list either.
        if values["program"] == nil { missing.append("program") }

        return JobDetail(
            label: label,
            domain: domain,
            state: state,
            pid: Int32(values["pid"] ?? ""),
            runs: UInt64(values["runs"] ?? ""),
            lastExitCode: parseExitCode(values["last exit code"]),
            program: values["program"],
            plistPath: values["path"],
            keepAlive: parseKeepAlive(values["properties"]),
            missingFields: missing
        )
    }

    static func parseExitCode(_ text: String?) -> Int32? {
        guard let text, !text.hasPrefix("(") else { return nil }
        let head = text.split(separator: ":").first.map(String.init) ?? text
        return Int32(head.trimmingCharacters(in: .whitespaces))
    }

    static func parseKeepAlive(_ properties: String?) -> KeepAliveMode {
        guard let properties else { return .unknown }
        return properties.contains("keepalive") ? .always : .never
    }

    // MARK: Disabled database

    /// `launchctl print-disabled <domain>`: `"label" => disabled`.
    public static func disabledLabels(_ text: String) -> Set<String> {
        var out: Set<String> = []
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("\""), trimmed.hasSuffix("disabled") else { continue }
            if let close = trimmed.dropFirst().firstIndex(of: "\"") {
                out.insert(String(trimmed[trimmed.index(after: trimmed.startIndex)..<close]))
            }
        }
        return out
    }
}
