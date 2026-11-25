import Foundation

/// One listening TCP socket, as `lsof` reports it.
public struct Listener: Sendable, Equatable, Hashable {
    public var command: String
    public var pid: Int32
    public var address: String
    public var port: UInt16

    public init(command: String, pid: Int32, address: String, port: UInt16) {
        self.command = command
        self.pid = pid
        self.address = address
        self.port = port
    }

    /// `kanzo:4242` — how the aggregate finding names a listener.
    public var short: String { "\(command):\(port)" }
}

/// Parses `lsof -nP -iTCP -sTCP:LISTEN`.
///
/// `lsof` prints one row per address family, so a dual-stack listener appears twice. The
/// parser deduplicates on (pid, port), keeping the first address seen (usually IPv4).
public enum ListenerParser {
    public static func parse(_ text: String) -> [Listener] {
        var seen: Set<String> = []
        var out: [Listener] = []

        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.hasPrefix("COMMAND"), !trimmed.hasPrefix("#") else { continue }

            let fields = trimmed.split(separator: " ", omittingEmptySubsequences: true)
            // COMMAND PID USER FD TYPE DEVICE SIZE/OFF NODE NAME [ (LISTEN) ]
            guard fields.count >= 9,
                  let pid = Int32(fields[1]),
                  let addressPort = fields.dropFirst(8).first
            else { continue }

            let text = String(addressPort)
            guard let colon = text.lastIndex(of: ":") else { continue }
            let address = String(text[text.startIndex..<colon])
            let portText = String(text[text.index(after: colon)...])
            guard let port = UInt16(portText), port > 0 else { continue }

            let key = "\(pid):\(port)"
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            out.append(Listener(command: String(fields[0]), pid: pid, address: address, port: port))
        }
        return out.sorted { ($0.port, $0.command) < ($1.port, $1.command) }
    }
}

/// Reads the live listener table. Read-only: `lsof` with a listen filter, nothing else.
public struct ListenerScanner: Sendable {
    public typealias Runner = @Sendable ([String]) -> CommandResult
    private let runner: Runner

    public init(runner: @escaping Runner = ListenerScanner.systemRunner) {
        self.runner = runner
    }

    public static let systemRunner: Runner = { arguments in
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = arguments
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

    public func scan() -> [Listener] {
        ListenerParser.parse(runner(["-nP", "-iTCP", "-sTCP:LISTEN"]).standardOutput)
    }
}

/// Resolves a running pid to the executable it is actually running.
///
/// `lsof`'s COMMAND column is truncated to nine characters and shared by every process of the same
/// interpreter (`node`, `python3`), so a name can never identity a listener (D6). The executable's
/// path can — and `lsof -p <pid>` reports it in the `txt` row.
public struct ExecutableResolver: Sendable {
    public typealias Resolve = @Sendable (Int32) -> String?
    private let resolve: Resolve

    public init(resolve: @escaping Resolve) { self.resolve = resolve }

    public static let live = ExecutableResolver { pid in
        let result = ListenerScanner.systemRunner(["-p", String(pid), "-a", "-d", "txt", "-Fn"])
        for line in result.standardOutput.split(separator: "\n") where line.hasPrefix("n/") {
            return String(line.dropFirst())
        }
        return nil
    }

    public func callAsFunction(_ pid: Int32) -> String? { resolve(pid) }

    /// Both rules ask the same question of the same pids; resolve each pid once per run.
    public static func memoized(_ base: ExecutableResolver = .live) -> ExecutableResolver {
        final class Cache: @unchecked Sendable {
            private let lock = NSLock()
            private var values: [Int32: String?] = [:]
            func value(for pid: Int32, using base: ExecutableResolver) -> String? {
                lock.lock()
                defer { lock.unlock() }
                if let cached = values[pid] { return cached }
                let resolved = base(pid)
                values[pid] = resolved
                return resolved
            }
        }
        let cache = Cache()
        return ExecutableResolver { pid in cache.value(for: pid, using: base) }
    }
}

/// The two listener findings. Split on purpose: a leftover is a defect, an unattributable
/// listener is a visibility gap (D8 — never report not-knowing as broken).
public enum ListenerFindings {

    /// A listener whose pid is not the job's pid, but which is running **the same executable** as a
    /// job whose own process is gone. That is a leftover from a previous run.
    ///
    /// Identity is the resolved executable path, never the command name: the first live run of this
    /// rule accused `dev.dsh.bridge` of owning a port held by an unrelated `node` script, because
    /// both are called `node`.
    public static func orphanPorts(
        listeners: [Listener],
        records: [ServiceRecord],
        executableForPid: ExecutableResolver = .live
    ) -> [Finding] {
        let runningPids = Set(records.compactMap { $0.state == .running ? $0.pid : nil })

        // job executable → the job, keyed by the canonical path
        var byExecutable: [String: ServiceRecord] = [:]
        for record in records {
            guard let program = record.program else { continue }
            byExecutable[canonical(program)] = record
        }

        var findings: [Finding] = []
        for listener in listeners where !runningPids.contains(listener.pid) {
            guard let exe = executableForPid(listener.pid) else { continue }
            guard let owner = byExecutable[canonical(exe)] else { continue }
            // The job must be *dead* for this to be a leftover. A running job that happens to have
            // another process of the same executable (Google Drive, DSH Fleet) is a second instance,
            // and calling that a defect is how a detector teaches people to ignore it (D8).
            guard owner.state != .running else { continue }

            findings.append(
                Finding(
                    id: .orphanPort,
                    severity: .defect,
                    summary: "port \(listener.port) is held by a leftover \(listener.command) (pid \(listener.pid))",
                    evidence: "\(listener.command):\(listener.port) pid \(listener.pid) runs \(exe); "
                        + "its job \(owner.id) is not running"
                        + (owner.lastExitCode.map { ", last exit \($0)" } ?? ""),
                    confirmsScan: true
                )
            )
        }
        return findings
    }

    /// Listeners belonging to no job at all, aggregated into one finding.
    ///
    /// One row, not twelve: this class is mostly legitimate (AirPlay ports held by ControlCenter, an
    /// app-spawned child) and we cannot tell an app child from a hand-started server without witr.
    /// Reporting the set is honest; reporting each as a defect would train the user to ignore us.
    public static func unattributed(
        listeners: [Listener],
        records: [ServiceRecord],
        executableForPid: ExecutableResolver = .live
    ) -> Finding? {
        let knownPids = Set(records.compactMap(\.pid))
        let knownExecutables = Set(records.compactMap { $0.program.map(canonical) })

        let leftovers = listeners.filter { listener in
            guard !knownPids.contains(listener.pid) else { return false }
            guard let exe = executableForPid(listener.pid) else { return true }
            return !knownExecutables.contains(canonical(exe))
        }
        guard !leftovers.isEmpty else { return nil }

        let shown = leftovers.prefix(12).map(\.short).joined(separator: ", ")
        let more = leftovers.count > 12 ? " (+\(leftovers.count - 12) more)" : ""
        return Finding(
            id: .noSupervisor,
            severity: .gap,
            summary: "\(leftovers.count) listening port(s) have no launchd job",
            evidence: shown + more,
            confirmsScan: true
        )
    }

    /// Symlink-resolved, so `/opt/homebrew/opt/postgresql@14/bin/postgres` and the Cellar path it
    /// points at compare equal.
    static func canonical(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }
}
