import Foundation

/// GUI apps, and the resources they hold (KI-050).
///
/// Measured on this machine: fifty-one apps hold **4,156 MB** — Firefox alone 1,899 MB — while the whole
/// vendor-noise bundle holds 20 MB. The daemons were never where the memory was; the apps are.
///
/// The design follows from one fact: **"related to development" is not knowable.** Firefox may be holding
/// docs, the harness *is* the development environment, a cloud client may be mid-sync. So Curfew shows
/// observable facts and never pre-selects; the owner decides.
public struct AppRecord: Sendable, Equatable, Identifiable {
    public var name: String
    public var bundlePath: String
    public var pids: [Int32]
    public var memoryBytes: UInt64
    public var isFrozen: Bool
    public var isFrontmost: Bool

    public var id: String { bundlePath }
    public var memoryMB: Double { Double(memoryBytes) / (1024 * 1024) }
}

public enum AppsScanner {

    /// Everything Curfew must never freeze or quit, and why. The shell is the machine's own UI; the
    /// harness and Curfew are the tools doing the work — freeing 1.5 GB by stopping the thing that is
    /// talking to you is not a saving.
    public static let neverTouch: Set<String> = [
        "Finder", "Dock", "SystemUIServer", "ControlCenter", "NotificationCenter", "loginwindow",
        "WindowManager", "WallpaperAgent", "Spotlight", "UserNotificationCenter", "universalAccessAuthWarn",
        "CoreServicesUIAgent", "TextInputMenuAgent", "WiFiAgent", "AirPlayUIAgent", "ControlStrip",
        // the harness hosting this session, and the tool itself
        "DSH Fleet", "DSH Fleet Helper", "DSH Fleet Helper (Renderer)", "Curfew",
        // security and the login path
        "SecurityAgent", "com.apple.SecurityAgent", "XProtect",
        // rule 7: the remote-access path is never suspended. Freezing Tailscale would cut the only way
        // into this machine from outside — the one thing an unattended developer most needs intact.
        "Tailscale", "Tailscale IPN", "WireGuard", "ZeroTier",
    ]

    /// Shell processes live in CoreServices; an app there is the system's, not the user's.
    static func isShellBundle(_ path: String) -> Bool {
        path.hasPrefix("/System/Library/CoreServices/")
    }

    /// Parse `ps -ww -eo pid=,rss=,command=`. Public so the parsing is testable without a machine.
    ///
    /// **Three fields, not four.** macOS `ps` truncates the command column the moment another column is
    /// requested — even with `-ww` — so a four-field format silently yields no app paths at all. The
    /// process state therefore comes from a second call, joined by pid.
    public static func parse(
        _ text: String, states: [Int32: String] = [:], frontmost: String? = nil
    ) -> [AppRecord] {
        var byBundle: [String: AppRecord] = [:]
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard parts.count >= 3,
                  let pid = Int32(parts[0]), let rssKB = UInt64(parts[1]) else { continue }
            // The command is the whole argv; only the bundle prefix matters, and taking it up to `.app`
            // survives spaces in the path (`DSH Fleet.app`) and nested helpers (`plugin-container.app`).
            guard let bundlePath = QuarantineEligibility.appBundle(in: String(parts[2])) else { continue }
            let name = (bundlePath as NSString).lastPathComponent.replacingOccurrences(of: ".app", with: "")
            guard !neverTouch.contains(name), !isShellBundle(bundlePath) else { continue }
            let frozen = (states[pid] ?? "").hasPrefix("T")

            if var existing = byBundle[bundlePath] {
                existing.pids.append(pid)
                existing.memoryBytes += rssKB * 1024
                existing.isFrozen = existing.isFrozen || frozen
                byBundle[bundlePath] = existing
            } else {
                byBundle[bundlePath] = AppRecord(
                    name: name, bundlePath: bundlePath, pids: [pid],
                    memoryBytes: rssKB * 1024, isFrozen: frozen,
                    isFrontmost: frontmost == bundlePath)
            }
        }
        return byBundle.values.sorted { $0.memoryBytes > $1.memoryBytes }
    }

    public static func parseStates(_ text: String) -> [Int32: String] {
        var states: [Int32: String] = [:]
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 2, let pid = Int32(parts[0]) else { continue }
            states[pid] = String(parts[1])
        }
        return states
    }

    public static func scan(frontmost: String? = nil) -> [AppRecord] {
        let listing = run(["-ww", "-eo", "pid=,rss=,command="])
        let states = parseStates(run(["-ww", "-eo", "pid=,state="]))
        return parse(listing, states: states, frontmost: frontmost)
    }

    private static func run(_ arguments: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}

/// The two verbs. Freeze is the default because it is instant and exactly reversible; quit is the
/// deliberate one, because an app can lose unsaved work.
public struct AppControl: Sendable {
    private let journal: Journal
    private let now: @Sendable () -> Date

    public init(journal: Journal, now: @escaping @Sendable () -> Date = { Date() }) {
        self.journal = journal
        self.now = now
    }

    /// SIGSTOP every process of the app. Journaled before the signal, and `resume` sends SIGCONT.
    public func freeze(_ app: AppRecord) throws -> StepOutcome {
        let argv = [app.pids.map(String.init)]
        let seq = try journal.appendIntent(entryId: app.bundlePath, action: "freeze", argv: argv)
        var failed: String?
        for pid in app.pids where kill(pid, SIGSTOP) != 0 {
            failed = "could not stop pid \(pid): \(String(cString: strerror(errno)))"
        }
        try journal.appendOutcome(intent: seq, result: failed == nil ? "ok" : "failed",
                                  verified: failed == nil, error: failed)
        return StepOutcome(entryId: app.bundlePath, action: "freeze",
                           result: failed.map { .failed($0) } ?? .executed(verified: true))
    }

    /// Quit gracefully (SIGTERM). Deliberately not the default: an app may have unsaved work.
    public func quit(_ app: AppRecord) throws -> StepOutcome {
        let seq = try journal.appendIntent(entryId: app.bundlePath, action: "quit",
                                           argv: [app.pids.map(String.init)])
        var failed: String?
        for pid in app.pids where kill(pid, SIGTERM) != 0 && errno != ESRCH {
            failed = "could not ask pid \(pid) to quit: \(String(cString: strerror(errno)))"
        }
        try journal.appendOutcome(intent: seq, result: failed == nil ? "ok" : "failed",
                                  verified: failed == nil, error: failed)
        return StepOutcome(entryId: app.bundlePath, action: "quit",
                           result: failed.map { .failed($0) } ?? .executed(verified: true))
    }

    /// Undo a freeze: SIGCONT. Reads the pids from the intent so it works even if the app gained
    /// processes since.
    public static func thaw(_ intent: JournalRecord) -> StepOutcome {
        guard let pids = intent.argv?.first?.compactMap(Int32.init), !pids.isEmpty else {
            return StepOutcome(entryId: intent.entryId ?? "?", action: "resume",
                               result: .refused("freeze intent names no pids"))
        }
        var failed: String?
        for pid in pids where kill(pid, SIGCONT) != 0 && errno != ESRCH {
            failed = "could not resume pid \(pid): \(String(cString: strerror(errno)))"
        }
        return StepOutcome(entryId: intent.entryId ?? "?", action: "resume",
                           result: failed.map { .failed($0) } ?? .executed(verified: true))
    }
}
