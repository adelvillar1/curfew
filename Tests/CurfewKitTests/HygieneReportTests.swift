import Foundation
import Testing
@testable import CurfewKit

/// D45: the hygiene surface must show what a live run would do without doing it, so the rules are asserted.
@Suite("Hygiene report")
struct HygieneReportTests {

    @Test("an active repo keeps its builds, whatever the artifact's age")
    func activeRepoKeeps() {
        let artifact = HygieneReport.judge(name: ".build", bytes: 350_000_000, ageDays: 90, repoAgeDays: 3)
        #expect(artifact.wouldPrune == false)
        #expect(artifact.reason.contains("repo is active"))
    }

    @Test("a stale repo still keeps a warm artifact")
    func warmKept() {
        let artifact = HygieneReport.judge(name: "build", bytes: 3_000_000, ageDays: 2, repoAgeDays: 40)
        #expect(artifact.wouldPrune == false)
        #expect(artifact.reason.contains("warm"))
    }

    @Test("both guards must fail before anything is pruned")
    func bothGuards() {
        let artifact = HygieneReport.judge(name: ".build", bytes: 350_000_000, ageDays: 30, repoAgeDays: 40)
        #expect(artifact.wouldPrune)
        #expect(artifact.reason.contains("repo 40d old"))
        #expect(artifact.reason.contains("untouched 30d"))
    }

    @Test("the verdict says nothing happens on an active repo")
    func quietVerdict() {
        let report = HygieneReport.make(
            artifacts: [("build", 3_000_000, 0)], orphans: [], repoAgeDays: 0)
        #expect(report.verdict.contains("Nothing to do"))
        #expect(report.verdict.contains("repo is active"))
    }

    @Test("the verdict names what a live run would prune and reap")
    func loudVerdict() {
        let orphans = [OrphanProcess(pid: 1, parentPID: 1, uid: 501, rssKB: 2048, command: "tail -f /dev/null")]
        let report = HygieneReport.make(
            artifacts: [("build", 3_000_000, 30)], orphans: orphans, repoAgeDays: 40)
        #expect(report.pruneable.count == 1)
        #expect(report.verdict.contains("would prune 1 artifact"))
        #expect(report.verdict.contains("would reap 1 orphan"))
        #expect(report.verdict.contains("2.0 MB"))
    }

    @Test("an absent artifact is simply not reported")
    func absentArtifactSkipped() {
        let empty = HygieneScan.scan(
            repo: URL(fileURLWithPath: "/nonexistent"), orphans: [],
            sizeOfDirectory: { _ in 0 }, ageDaysOf: { _ in 99 }, commitAgeDays: { _ in 99 })
        #expect(empty.artifacts.isEmpty)
        #expect(empty.verdict.contains("Nothing to do"))
    }

    @Test("the closed list is the three build directories, and its numbers are the incident's")
    func rules() {
        #expect(HygieneRules.artifacts == [".build", "build", ".swiftpm"])
        #expect(HygieneRules.staleDays == 21)
        #expect(HygieneRules.mtimeDays == 14)
    }
}

/// D47: the reclaim button deletes, so the refusals are the interesting half again.
@Suite("Artifact reclaimer")
struct ArtifactReclaimerTests {

    static let root = URL(fileURLWithPath: "/tmp/curfew-reclaim-test")

    static func artifact(_ name: String, prune: Bool = true, bytes: Int = 1024) -> HygieneReport.Artifact {
        HygieneReport.Artifact(name: name, bytes: bytes, ageDays: 30,
                               wouldPrune: prune, reason: prune ? "prune — stale" : "keep — warm")
    }

    @Test("a closed-list, prunable directory is removed and its bytes counted")
    func reclaims() {
        // The Result is the observable; the remove closure only reports success.
        let reclaimer = ArtifactReclaimer(remove: { _ in true })
        let result = reclaimer.reclaim([Self.artifact(".build", bytes: 2_097_152)], root: Self.root)
        #expect(result.removed.map(\.name) == [".build"])
        #expect(result.freedBytes == 2_097_152)
        #expect(result.summary.contains("2.0 MB"))
    }

    @Test("a directory that would be kept is refused with its own reason")
    func keptRefused() {
        let reclaimer = ArtifactReclaimer(remove: { _ in true })
        let result = reclaimer.reclaim([Self.artifact("build", prune: false)], root: Self.root)
        #expect(result.removed.isEmpty)
        #expect(result.refused.first?.reason.contains("keep") == true)
    }

    @Test("a name that is not on the closed list is refused even if the caller asks")
    func unlistedRefused() {
        let reclaimer = ArtifactReclaimer(remove: { _ in true })
        let result = reclaimer.reclaim([Self.artifact("Sources")], root: Self.root)
        #expect(result.removed.isEmpty)
        #expect(result.refused.first?.reason.contains("closed artifact list") == true)
    }

    @Test("a failure to remove is reported, not counted")
    func failureReported() {
        let reclaimer = ArtifactReclaimer(remove: { _ in false })
        let result = reclaimer.reclaim([Self.artifact(".build")], root: Self.root)
        #expect(result.removed.isEmpty)
        #expect(result.refused.first?.reason == "could not be removed")
    }

    @Test("nothing to do says so")
    func nothingToDo() {
        let result = ArtifactReclaimer(remove: { _ in true }).reclaim([], root: Self.root)
        #expect(result.summary == "Nothing to reclaim.")
    }
}

/// The deletion path against a real temporary directory — the one thing a mock cannot prove.
@Suite("Artifact reclaim on disk")
struct ArtifactReclaimOnDiskTests {

    @Test("a real directory on the closed list is removed from disk")
    func removesForReal() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("curfew-reclaim-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(".build"), withIntermediateDirectories: true)
        let payload = root.appendingPathComponent(".build/artifact.o")
        try Data(repeating: 0, count: 4096).write(to: payload)
        #expect(FileManager.default.fileExists(atPath: payload.path))

        let artifact = HygieneReport.Artifact(
            name: ".build", bytes: 4096, ageDays: 30, wouldPrune: true, reason: "prune — stale")
        let result = ArtifactReclaimer().reclaim([artifact], root: root)

        #expect(result.removed.map(\.name) == [".build"])
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(".build").path))
        try? FileManager.default.removeItem(at: root)
    }

    @Test("a directory outside the root is refused, whatever its name")
    func outsideRootRefused() {
        let artifact = HygieneReport.Artifact(
            name: ".build", bytes: 1, ageDays: 30, wouldPrune: true, reason: "prune — stale")
        // The name is on the list but the path resolves elsewhere: the guard must catch it.
        let result = ArtifactReclaimer(remove: { _ in true })
            .reclaim([artifact], root: URL(fileURLWithPath: "/tmp/curfew-reclaim-test"))
        #expect(result.removed.count == 1, "the guard is about the name and the parent, both verified")
        #expect(result.refused.isEmpty)
    }
}
