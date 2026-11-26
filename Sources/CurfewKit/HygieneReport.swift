import Foundation

/// The hygiene pass, as a report the window can show (D45).
///
/// The rules are the script's rules, and they are the incident's: a build artifact is prunable when the
/// repo's last commit is older than 21 days **and** the artifact's mtime is older than 14 days — both,
/// so an active repo keeps its warm build. The artifact list is **closed**; anything else is named, never
/// removed. Everything here is pure, so "what would a run do?" is an assertion, not a guess.
public struct HygieneReport: Sendable, Equatable {

    public struct Artifact: Sendable, Equatable, Identifiable {
        public var name: String
        public var bytes: Int
        public var ageDays: Int
        public var wouldPrune: Bool
        /// Why it is kept, or why it would go — the sentence the pane prints.
        public var reason: String
        public var id: String { name }

        public init(name: String, bytes: Int, ageDays: Int, wouldPrune: Bool, reason: String) {
            self.name = name; self.bytes = bytes; self.ageDays = ageDays
            self.wouldPrune = wouldPrune; self.reason = reason
        }
    }

    /// A directory that is *not* on the closed list but is large enough to be worth naming.
    public struct Named: Sendable, Equatable, Identifiable {
        public var name: String
        public var bytes: Int
        public var reason: String
        public var id: String { name }

        public init(name: String, bytes: Int, reason: String) {
            self.name = name; self.bytes = bytes; self.reason = reason
        }
    }

    public var artifacts: [Artifact]
    public var named: [Named]
    public var orphans: [OrphanProcess]
    public var repoAgeDays: Int
    /// The closed list this report was produced against, so the surface can show its boundaries.
    public var artifactList: [String]

    public init(
        artifacts: [Artifact], named: [Named] = [], orphans: [OrphanProcess] = [],
        repoAgeDays: Int = 0, artifactList: [String] = HygieneRules.artifacts
    ) {
        self.artifacts = artifacts; self.named = named; self.orphans = orphans
        self.repoAgeDays = repoAgeDays; self.artifactList = artifactList
    }

    public var pruneable: [Artifact] { artifacts.filter(\.wouldPrune) }
    public var pruneableBytes: Int { pruneable.reduce(0) { $0 + $1.bytes } }
    public var orphanBytes: Int { OrphanScan.totalRSSKB(orphans) * 1024 }
    public var totalBytes: Int { artifacts.reduce(0) { $0 + $1.bytes } }

    /// One sentence: what a live run would change, or that it would change nothing and why.
    public var verdict: String {
        if pruneable.isEmpty && orphans.isEmpty {
            return repoAgeDays < HygieneRules.staleDays
                ? "Nothing to do — the repo is active (last commit \(repoAgeDays)d ago), so its builds are kept."
                : "Nothing to do — no artifact is older than \(HygieneRules.mtimeDays) days."
        }
        var parts: [String] = []
        if !pruneable.isEmpty {
            parts.append("would prune \(pruneable.count) artifact\(pruneable.count == 1 ? "" : "s") — \(HygieneRules.megabytes(pruneableBytes))")
        }
        if !orphans.isEmpty {
            parts.append("would reap \(orphans.count) orphan\(orphans.count == 1 ? "" : "s") — \(HygieneRules.megabytes(orphanBytes)) RSS")
        }
        return "A live run " + parts.joined(separator: ", and ") + "."
    }

    /// The per-artifact rules, verbatim.
    public static func judge(
        name: String, bytes: Int, ageDays: Int, repoAgeDays: Int
    ) -> Artifact {
        if repoAgeDays < HygieneRules.staleDays {
            return Artifact(name: name, bytes: bytes, ageDays: ageDays, wouldPrune: false,
                            reason: "keep — the repo is active (last commit \(repoAgeDays)d < \(HygieneRules.staleDays)d)")
        }
        if ageDays < HygieneRules.mtimeDays {
            return Artifact(name: name, bytes: bytes, ageDays: ageDays, wouldPrune: false,
                            reason: "keep — warm (\(ageDays)d < \(HygieneRules.mtimeDays)d)")
        }
        return Artifact(name: name, bytes: bytes, ageDays: ageDays, wouldPrune: true,
                        reason: "prune — repo \(repoAgeDays)d old, artifact untouched \(ageDays)d")
    }

    public static func make(
        artifacts: [(name: String, bytes: Int, ageDays: Int)],
        named: [Named] = [],
        orphans: [OrphanProcess] = [],
        repoAgeDays: Int
    ) -> HygieneReport {
        HygieneReport(
            artifacts: artifacts.map {
                judge(name: $0.name, bytes: $0.bytes, ageDays: $0.ageDays, repoAgeDays: repoAgeDays)
            },
            named: named, orphans: orphans, repoAgeDays: repoAgeDays)
    }
}

/// The numbers, in one place, so the script and the surface cannot drift apart silently.
public enum HygieneRules {
    public static let staleDays = 21
    public static let mtimeDays = 14
    /// The closed list. Extending it is a plan decision, not a whim.
    public static let artifacts = [".build", "build", ".swiftpm"]

    public static func megabytes(_ bytes: Int) -> String {
        String(format: "%.1f MB", Double(bytes) / 1_048_576)
    }
}

/// Reads the machine into a `HygieneReport`. Every side effect is injected, so the rules stay testable.
public enum HygieneScan {

    public static func scan(
        repo: URL,
        orphans: [OrphanProcess] = OrphanScan.scan(),
        sizeOfDirectory: @Sendable (URL) -> Int = HygieneScan.directoryBytes,
        ageDaysOf: @Sendable (URL) -> Int = HygieneScan.ageInDays,
        commitAgeDays: @Sendable (URL) -> Int = HygieneScan.commitAgeInDays
    ) -> HygieneReport {
        var artifacts: [(name: String, bytes: Int, ageDays: Int)] = []
        for name in HygieneRules.artifacts {
            let url = repo.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            artifacts.append((name: name, bytes: sizeOfDirectory(url), ageDays: ageDaysOf(url)))
        }
        return HygieneReport.make(
            artifacts: artifacts, named: [], orphans: orphans, repoAgeDays: commitAgeDays(repo))
    }

    public static let directoryBytes: @Sendable (URL) -> Int = { url in
        guard let enumerator = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey])
        else { return 0 }
        var total = 0
        for case let file as URL in enumerator {
            let values = try? file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            if values?.isRegularFile == true { total += values?.fileSize ?? 0 }
        }
        return total
    }

    public static let ageInDays: @Sendable (URL) -> Int = { url in
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        guard let modified = attributes?[.modificationDate] as? Date else { return 0 }
        return Int(-modified.timeIntervalSinceNow / 86_400)
    }

    public static let commitAgeInDays: @Sendable (URL) -> Int = { repo in
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", repo.path, "log", "-1", "--format=%ct"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  let epoch = Double(text) else { return 0 }
            return Int(-Date(timeIntervalSince1970: epoch).timeIntervalSinceNow / 86_400)
        } catch {
            return 0
        }
    }
}

/// Deletes the build directories a report named as prunable (D47).
///
/// Two guards are re-checked here rather than trusted from the caller: the directory must be **on the closed
/// list**, and it must sit directly under the repo root. Anything else is refused by name. The directories are
/// regenerated by the next build, which is the whole reason they are allowed to go.
public struct ArtifactReclaimer: Sendable {

    public struct Result: Sendable {
        public var removed: [HygieneReport.Artifact]
        public var refused: [(name: String, reason: String)]
        public var freedBytes: Int

        public init(removed: [HygieneReport.Artifact] = [], refused: [(name: String, reason: String)] = [], freedBytes: Int = 0) {
            self.removed = removed; self.refused = refused; self.freedBytes = freedBytes
        }

        public var summary: String {
            guard !removed.isEmpty else {
                return refused.isEmpty ? "Nothing to reclaim." : "Nothing was reclaimed — \(refused.count) refused."
            }
            var text = "Reclaimed \(HygieneRules.megabytes(freedBytes)) from \(removed.count) director"
                + (removed.count == 1 ? "y." : "ies.")
            if !refused.isEmpty { text += " \(refused.count) refused." }
            return text
        }
    }

    /// Injected so tests never delete a real build: `remove` returns whether it succeeded.
    public var remove: @Sendable (URL) -> Bool

    public init(remove: @escaping @Sendable (URL) -> Bool = ArtifactReclaimer.defaultRemove) {
        self.remove = remove
    }

    public func reclaim(_ artifacts: [HygieneReport.Artifact], root: URL) -> Result {
        let rootPath = root.standardizedFileURL.path
        var removed: [HygieneReport.Artifact] = []
        var refused: [(name: String, reason: String)] = []
        for artifact in artifacts {
            guard HygieneRules.artifacts.contains(artifact.name) else {
                refused.append((artifact.name, "not on the closed artifact list")); continue
            }
            guard artifact.wouldPrune else {
                refused.append((artifact.name, artifact.reason)); continue
            }
            let url = root.appendingPathComponent(artifact.name).standardizedFileURL
            guard url.deletingLastPathComponent().path == rootPath else {
                refused.append((artifact.name, "outside \(rootPath)")); continue
            }
            if remove(url) { removed.append(artifact) }
            else { refused.append((artifact.name, "could not be removed")) }
        }
        return Result(removed: removed, refused: refused, freedBytes: removed.reduce(0) { $0 + $1.bytes })
    }

    public static let defaultRemove: @Sendable (URL) -> Bool = { url in
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        do {
            try FileManager.default.removeItem(at: url)
            return true
        } catch {
            return false
        }
    }
}
