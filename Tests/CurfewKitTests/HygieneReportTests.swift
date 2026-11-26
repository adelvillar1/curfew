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
