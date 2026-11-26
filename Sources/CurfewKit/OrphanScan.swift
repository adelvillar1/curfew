import Foundation

/// A process whose parent is gone and whose only job was to outlive something.
public struct OrphanProcess: Sendable, Equatable, Identifiable {
    public var pid: Int
    public var parentPID: Int
    public var uid: Int
    public var rssKB: Int
    public var command: String
    public var id: Int { pid }

    public init(pid: Int, parentPID: Int, uid: Int, rssKB: Int, command: String) {
        self.pid = pid
        self.parentPID = parentPID
        self.uid = uid
        self.rssKB = rssKB
        self.command = command
    }
}

/// What is holding memory with nothing waiting on it (D43).
///
/// From the 2026-11-21 incident on this machine: 1,232 orphaned `tail -f /dev/null` keep-alives (ppid 1,
/// 580 MB RSS, 46% of `maxprocperuid`) accumulated over ~55 days. A keep-alive exists to outlive its
/// owner; when the owner is gone the keep-alive is litter that costs memory until reboot.
///
/// The rules are deliberately narrow, and they are the reaper script's rules because the two must agree:
/// the command must match **exactly**, the parent must be gone (`ppid == 1`), and the process must be the
/// caller's. A process with a live parent is never reported — its owner may be about to read from it.
/// Parsing is pure so the rules are testable without a machine.
public enum OrphanScan {

    /// Commands that exist only to hold something open. Anything else is not guessed at.
    public static let keepAlives: Set<String> = ["tail -f /dev/null"]

    /// Parse `ps -Axo pid=,ppid=,uid=,rss=,command=` (command last: it contains spaces).
    public static func parse(_ output: String, uid: Int, matching patterns: Set<String> = keepAlives)
        -> [OrphanProcess]
    {
        output.split(separator: "\n").compactMap { line -> OrphanProcess? in
            let text = String(line).trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { return nil }
            // pid ppid uid rss command…
            var fields: [Substring] = []
            var rest = Substring(text)
            while fields.count < 4, let space = rest.firstIndex(where: { $0 == " " || $0 == "\t" }) {
                fields.append(rest[rest.startIndex..<space])
                rest = rest[rest.index(after: space)...]
                while let first = rest.first, first == " " || first == "\t" {
                    rest = rest.dropFirst()
                }
            }
            guard fields.count == 4,
                  let pid = Int(fields[0]), let ppid = Int(fields[1]),
                  let owner = Int(fields[2]), let rss = Int(fields[3]) else { return nil }
            let command = String(rest)
            guard ppid == 1, owner == uid, patterns.contains(command) else { return nil }
            return OrphanProcess(pid: pid, parentPID: ppid, uid: owner, rssKB: rss, command: command)
        }
    }

    public static func totalRSSKB(_ orphans: [OrphanProcess]) -> Int {
        orphans.reduce(0) { $0 + $1.rssKB }
    }

    /// The line `doctor` and the window print. Nil when there is nothing to say.
    public static func summary(_ orphans: [OrphanProcess]) -> String? {
        guard !orphans.isEmpty else { return nil }
        let mb = Double(totalRSSKB(orphans)) / 1024
        let one = orphans.count == 1
        return "\(orphans.count) orphaned keep-alive\(one ? "" : "s") holding "
            + String(format: "%.1f", mb) + " MB — nothing waits on them (reap with make hygiene-live)"
    }

    /// Runs `ps` and applies the rules. Injected so tests never touch a real process table.
    public static func scan(
        uid: Int = Int(getuid()),
        patterns: Set<String> = keepAlives,
        runner: @Sendable ([String]) -> String = OrphanScan.runPS
    ) -> [OrphanProcess] {
        parse(runner(["-Axo", "pid=,ppid=,uid=,rss=,command="]), uid: uid, matching: patterns)
    }

    public static let runPS: @Sendable ([String]) -> String = { arguments in
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return String(decoding: data, as: UTF8.self)
        } catch {
            return ""
        }
    }
}

/// Reaps the orphans the scan named (D46: the window may act, with the same narrow rules and a record).
///
/// Killing is irreversible, so the rules are re-checked here rather than trusted from the caller: each
/// process must still be an orphan of ours with the exact command. A process that no longer matches is
/// reported, not signalled.
public struct OrphanReaper: Sendable {

    public struct Result: Sendable {
        public var reaped: [OrphanProcess]
        public var refused: [(process: OrphanProcess, reason: String)]
        public var freedKB: Int

        public init(reaped: [OrphanProcess] = [], refused: [(process: OrphanProcess, reason: String)] = [], freedKB: Int = 0) {
            self.reaped = reaped; self.refused = refused; self.freedKB = freedKB
        }

        public var summary: String {
            let mb = String(format: "%.1f", Double(freedKB) / 1024)
            guard !reaped.isEmpty else {
                return refused.isEmpty ? "Nothing to reap." : "Nothing was reaped — \(refused.count) refused."
            }
            var text = "Reaped \(reaped.count) process\(reaped.count == 1 ? "" : "es"), \(mb) MB RSS released."
            if !refused.isEmpty { text += " \(refused.count) refused." }
            return text
        }
    }

    /// `isAlive` and `signal` are injected: tests never signal a real process.
    public var isAlive: @Sendable (Int) -> Bool
    public var signal: @Sendable (Int) -> Bool

    public init(
        isAlive: @escaping @Sendable (Int) -> Bool = OrphanReaper.defaultIsAlive,
        signal: @escaping @Sendable (Int) -> Bool = OrphanReaper.defaultSignal
    ) {
        self.isAlive = isAlive
        self.signal = signal
    }

    /// Re-checks each candidate against the rules, then signals the survivors.
    public func reap(_ orphans: [OrphanProcess], uid: Int = Int(getuid())) -> Result {
        var reaped: [OrphanProcess] = []
        var refused: [(process: OrphanProcess, reason: String)] = []
        for orphan in orphans {
            guard orphan.parentPID == 1 else {
                refused.append((orphan, "its parent is alive — not ours to stop")); continue
            }
            guard orphan.uid == uid else {
                refused.append((orphan, "another user's process")); continue
            }
            guard OrphanScan.keepAlives.contains(orphan.command) else {
                refused.append((orphan, "not a known keep-alive")); continue
            }
            guard isAlive(orphan.pid) else {
                refused.append((orphan, "already gone")); continue
            }
            if signal(orphan.pid) { reaped.append(orphan) }
            else { refused.append((orphan, "the signal could not be delivered")) }
        }
        return Result(
            reaped: reaped, refused: refused,
            freedKB: reaped.reduce(0) { $0 + $1.rssKB })
    }

    public static let defaultIsAlive: @Sendable (Int) -> Bool = { pid in
        kill(pid_t(pid), 0) == 0
    }

    public static let defaultSignal: @Sendable (Int) -> Bool = { pid in
        kill(pid_t(pid), SIGTERM) == 0
    }
}
