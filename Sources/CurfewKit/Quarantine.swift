import Foundation

/// Cleaning up debris a removed app left behind (KI-049).
///
/// **Quarantine, never delete.** A stale plist is moved into
/// `~/Library/Application Support/Curfew/quarantine/<timestamp>/` keeping its path, journaled like every
/// other Curfew action, so `resume` puts it back. This is the first thing the tool does that is not a
/// launchd verb; keeping it reversible is what lets it exist at all.
///
/// **Only when the owner is verifiably gone.** Of six dangling programs on this machine, one was litter,
/// four were platform artifacts under `/System`, and one belonged to a live project whose virtualenv had
/// been deleted. A blanket sweep would have been wrong about five of them.
public enum QuarantineEligibility {

    public enum Verdict: Sendable, Equatable {
        /// The owning app is gone; the plist may be quarantined.
        case eligible(owner: String)
        /// Named, actionable reason it may not be.
        case refuse(String)
    }

    /// Judge one finding. Every input is a fact the inventory already has, so this is testable without
    /// a machine.
    public static func judge(
        program: String?,
        plistPath: String?,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
        home: String = NSHomeDirectory()
    ) -> Verdict {
        guard let plistPath, !plistPath.isEmpty else {
            return .refuse("this job has no plist to move")
        }
        guard !plistPath.hasPrefix("/System/"), !plistPath.hasPrefix("/usr/") else {
            return .refuse("it lives under \(plistPath.hasPrefix("/System/") ? "/System" : "/usr"), which SIP owns")
        }
        guard fileExists(plistPath) else {
            return .refuse("its plist is already gone")
        }
        guard let program, !program.isEmpty else {
            return .refuse("it declares no program to judge")
        }
        guard !fileExists(program) else {
            return .refuse("its program exists, so the app is still installed")
        }

        // Who owns it? The `.app` in the path is the strongest signal; a support folder names the app
        // too; anything else is a path we cannot attribute, and we do not guess.
        if let bundle = appBundle(in: program) {
            return fileExists(bundle) ? .refuse("\(bundle) is still installed") : .eligible(owner: bundle)
        }
        if let name = supportFolderOwner(in: program) {
            let candidates = ["/Applications/\(name).app", "\(home)/Applications/\(name).app"]
            if let installed = candidates.first(where: fileExists) {
                return .refuse("\(installed) is still installed")
            }
            return .eligible(owner: "\(name) (no app bundle on this machine)")
        }
        return .refuse("it points into a path that names no app, so the owner cannot be established")
    }

    /// `/Applications/Zoom.app/Contents/MacOS/zoom` → `/Applications/Zoom.app`
    static func appBundle(in path: String) -> String? {
        guard let range = path.range(of: ".app/") else { return nil }
        return String(path[path.startIndex..<range.lowerBound]) + ".app"
    }

    /// `~/Library/Application Support/Steam/SteamApps/steamclean` → `Steam`
    static func supportFolderOwner(in path: String) -> String? {
        let marker = "/Library/Application Support/"
        guard let range = path.range(of: marker) else { return nil }
        let rest = path[range.upperBound...]
        guard let first = rest.split(separator: "/").first, !first.isEmpty else { return nil }
        return String(first)
    }
}

/// The quarantine itself: move the file, journal it, and let `resume` move it back.
public struct QuarantineStore: Sendable {
    public var root: URL
    private let now: @Sendable () -> Date

    public init(
        root: URL = QuarantineStore.defaultRoot,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.root = root
        self.now = now
    }

    public static var defaultRoot: URL {
        if let override = ProcessInfo.processInfo.environment["CURFEW_QUARANTINE"] {
            return URL(fileURLWithPath: override)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Curfew/quarantine")
    }

    /// Move `plistPath` into the quarantine. The journal gets an intent naming both paths *before* the
    /// move, so an interrupted run is recoverable in the same way a launchd action is.
    public func quarantine(plistPath: String, label: String, journal: Journal) throws -> StepOutcome {
        let stamp = Self.stamp(now())
        let destination = root
            .appendingPathComponent(stamp)
            .appendingPathComponent(String(plistPath.dropFirst()))   // keep the path shape
        let argv = [[plistPath, destination.path]]

        let seq = try journal.appendIntent(entryId: label, action: "quarantine", argv: argv)

        do {
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.moveItem(atPath: plistPath, toPath: destination.path)
            try journal.appendOutcome(intent: seq, result: "ok", verified: true)
            return StepOutcome(entryId: label, action: "quarantine",
                               result: .executed(verified: true))
        } catch {
            try? journal.appendOutcome(intent: seq, result: "failed", verified: false,
                                       error: "\(error.localizedDescription)")
            return StepOutcome(entryId: label, action: "quarantine",
                               result: .failed("could not move \(plistPath): \(error.localizedDescription)"))
        }
    }

    /// Undo one quarantine: put the file back where it was.
    static func restore(from destination: String, to original: String) throws {
        let parent = (original as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)
        try FileManager.default.moveItem(atPath: destination, toPath: original)
    }

    static func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }
}
