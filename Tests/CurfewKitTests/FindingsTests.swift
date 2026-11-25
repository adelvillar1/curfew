import Foundation
import Testing
@testable import CurfewKit

@Suite("Findings")
struct FindingsTests {

    /// A job that looks like the 2026-11-24 crash loop: 255k runs, EX_CONFIG, no live pid.
    func looping(
        label: String = "com.example.loop",
        program: String = "/Users/x/.local/bin/node",
        runs: UInt64 = 255_645,
        exit: Int32? = 78
    ) -> JobDetail {
        JobDetail(
            label: label, domain: .currentUser, state: .spawnScheduled,
            pid: nil, runs: runs, lastExitCode: exit, program: program,
            plistPath: "/tmp/\(label).plist", keepAlive: .always
        )
    }

    func engine(
        uptime: TimeInterval = 33 * 86_400,
        exists: @escaping @Sendable (String) -> Bool = { _ in true },
        symlink: @escaping @Sendable (String) -> String? = { _ in nil },
        files: @escaping @Sendable (String) -> Bool = { _ in true },
        disabled: Set<String> = []
    ) -> FindingsEngine {
        FindingsEngine(
            systemUptime: uptime,
            executableExists: exists,
            symlinkTarget: symlink,
            fileExists: files,
            disabledLabels: disabled
        )
    }

    // MARK: Crash loop — D7's three clauses

    @Test("flags a real loop")
    func crashLoopPositive() {
        let finding = engine().crashLoop(looping())
        #expect(finding?.id == .crashLoop)
        #expect(finding?.severity == .defect)
        #expect(finding?.evidence.contains("255645") == true)
    }

    @Test("does not flag a job with a clean exit history, however many times it ran")
    func crashLoopNeedsNonZeroExit() {
        #expect(engine().crashLoop(looping(exit: 0)) == nil)
        #expect(engine().crashLoop(looping(exit: nil)) == nil, "an unseen exit code is unknown, not a failure")
    }

    @Test("does not flag a young machine")
    func crashLoopNeedsUptime() {
        #expect(engine(uptime: 60).crashLoop(looping()) == nil)
    }

    @Test("does not flag a job that has barely run")
    func crashLoopNeedsRuns() {
        #expect(engine().crashLoop(looping(runs: 10)) == nil)
    }

    // MARK: exec failure

    @Test("EX_CONFIG is its own finding")
    func execFailure() {
        let finding = engine().execFailure(looping())
        #expect(finding?.id == .execFailure)
        #expect(finding?.evidence.contains("78") == true)
    }

    // MARK: dangling program — the rule that explains the loop

    @Test("a dangling symlink names the missing target")
    func danglingNamesTarget() {
        let engine = engine(
            exists: { _ in false },
            symlink: { _ in "/Users/x/.hermes/node/bin/node" }
        )
        let finding = engine.danglingProgram(looping())
        #expect(finding?.id == .danglingProgram)
        #expect(finding?.evidence.contains("/Users/x/.hermes/node/bin/node") == true)
        #expect(finding?.evidence.contains("target missing") == true)
    }

    @Test("a program that simply is not there is still a finding")
    func danglingNoSymlink() {
        let engine = engine(exists: { _ in false })
        let finding = engine.danglingProgram(looping())
        #expect(finding?.evidence.contains("does not exist") == true)
    }

    @Test("a working program is not flagged")
    func danglingNegative() {
        #expect(engine(exists: { _ in true }).danglingProgram(looping()) == nil)
    }

    // MARK: the quieter rules

    @Test("a loaded job whose plist vanished is a gap")
    func stalePlist() {
        let detail = looping()
        let finding = engine(files: { _ in false }).stalePlist(detail)
        #expect(finding?.id == .stalePlist)
        #expect(engine(files: { _ in true }).stalePlist(detail) == nil)
    }

    @Test("a disabled label is reported")
    func disabledButExpected() {
        let detail = JobDetail(label: "com.example.off", domain: .currentUser, state: .notLoaded)
        let finding = engine(disabled: ["com.example.off"]).disabledButExpected(detail)
        #expect(finding?.id == .disabledButExpected)
    }

    @Test("a missing field is not a clean bill of health")
    func missingFieldsIsNotClean() {
        let detail = JobDetail(
            label: "com.example.partial", domain: .currentUser, state: .running,
            missingFields: ["runs", "path"]
        )
        let finding = engine().missingFields(detail)
        #expect(finding?.id == .fieldUnavailable)
        #expect(finding?.confirmsScan == false, "a field we could not read must never let a scan call itself clean")
    }

    @Test("a process running from / or /tmp is worth flagging")
    func suspiciousWorkingDirectory() {
        let process = ProcessFacts(
            pid: 1, exe: "/bin/x", workingDir: "/tmp", gitRepo: nil, gitBranch: nil,
            listeningPorts: [], ancestry: [], sourceType: "launchd", sourceName: nil,
            warnings: [], cpuPercent: nil, memoryRSS: nil
        )
        let finding = engine().runsFromTmpOrRoot(looping(), process: process)
        #expect(finding?.id == .runsFromTmpOrRoot)

        let clean = ProcessFacts(
            pid: 1, exe: "/bin/x", workingDir: "/Users/x/project", gitRepo: nil, gitBranch: nil,
            listeningPorts: [], ancestry: [], sourceType: "launchd", sourceName: nil,
            warnings: [], cpuPercent: nil, memoryRSS: nil
        )
        #expect(engine().runsFromTmpOrRoot(looping(), process: clean) == nil)
    }

    @Test("evaluate returns every applicable rule at once")
    func evaluateAggregates() {
        let findings = engine(exists: { _ in false }, files: { _ in false }).evaluate(looping())
        let ids = Set(findings.map(\.id))
        #expect(ids.contains(.crashLoop))
        #expect(ids.contains(.execFailure))
        #expect(ids.contains(.danglingProgram))
        #expect(ids.contains(.stalePlist))
    }
}
