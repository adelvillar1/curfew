import Foundation
import Testing
@testable import CurfewKit

@Suite("WitrClient")
struct WitrClientTests {

    static var fixtures: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
    }

    static func fixture(_ name: String) throws -> String {
        try String(contentsOf: fixtures.appendingPathComponent(name), encoding: .utf8)
    }

    func client(_ output: String, status: Int32 = 0) -> WitrClient {
        WitrClient(binary: "/fake/witr", runner: { _ in CommandResult(standardOutput: output, status: status) })
    }

    @Test("decodes a real report into our own facts")
    func decodesReport() throws {
        let report = try #require(try client(Self.fixture("witr-port-8901-macos-26.5.2.json")).probe(port: 8901).get())
        #expect(report.process?.pid == 27468)
        #expect(report.process?.listeningPorts == [8901])
        #expect(report.sourceType == "launchd")
        #expect(report.sourceName == "com.adelvillar1.sem1-llama")
        #expect(report.sourceUnitFile?.hasSuffix("com.adelvillar1.sem1-llama.plist") == true)
        #expect(report.process?.ancestry.count == 2)
        #expect(report.process?.ancestry.first?.command == "launchd")
    }

    @Test("falls back to the command name when witr cannot resolve the executable")
    func exeFallback() throws {
        let report = try #require(try client(Self.fixture("witr-port-8901-macos-26.5.2.json")).probe(port: 8901).get())
        // witr reports Exe = "" for this process; the name is in Command.
        #expect(report.process?.exe == "llama-server")
    }

    @Test("an Error payload is a failure even when the process exits 0")
    func errorPayload() throws {
        let result = client(try Self.fixture("witr-error-unreadable.json"), status: 0).probe(port: 8901)
        guard case .failure(let failure) = result else {
            Issue.record("expected a failure")
            return
        }
        if case .unreadable(let message) = failure {
            #expect(message.contains("can't be read") || message.contains("not permitted"))
        } else {
            Issue.record("expected .unreadable, got \(failure)")
        }
    }

    @Test("garbage is malformed, not silently empty")
    func malformed() throws {
        let result = client("not json at all", status: 0).probe(pid: 1)
        guard case .failure(let failure) = result, case .malformed = failure else {
            Issue.record("expected .malformed")
            return
        }
    }

    @Test("version parsing and comparison")
    func versions() {
        #expect(WitrClient.parseVersion("witr v0.3.4 (commit unknown, built unknown)") == "0.3.4")
        #expect(WitrClient.parseVersion("witr v1.0.0") == "1.0.0")
        #expect(WitrClient.compare("0.3.4", to: "0.3.4") == .orderedSame)
        #expect(WitrClient.compare("0.3.3", to: "0.3.4") == .orderedAscending)
        #expect(WitrClient.compare("0.4.0", to: "0.3.4") == .orderedDescending)
        #expect(WitrClient.compare("0.10.0", to: "0.9.9") == .orderedDescending)
    }

    @Test("no binary means notInstalled, and the message names the fix")
    func notInstalled() {
        let result = WitrClient(binary: nil, runner: { _ in CommandResult(standardOutput: "") }).probe(port: 1)
        guard case .failure(let failure) = result, case .notInstalled = failure else {
            Issue.record("expected .notInstalled")
            return
        }
        #expect(failure.message.contains("brew install witr"))
    }

    @Test("an explicit empty override disables witr")
    func overrideDisables() {
        #expect(WitrClient.locate(environment: ["CURFEW_WITR_PATH": ""]) == nil)
        #expect(WitrClient.locate(environment: ["CURFEW_WITR_PATH": "/custom/witr"]) == "/custom/witr")
    }
}

@Suite("WitrEnricher")
struct WitrEnricherTests {

    func record(program: String?, pid: Int32?) -> ServiceRecord {
        ServiceRecord(
            id: "com.example.job", domain: "gui/501", plistPath: "/tmp/x.plist",
            state: .running, pid: pid, runs: 1, lastExitCode: nil, program: program,
            tier: .thirdParty, kind: .agent, supervised: .launchd
        )
    }

    func report(pid: Int32, exe: String) -> WitrReport {
        WitrReport(
            targetType: "pid", targetValue: "\(pid)",
            process: ProcessFacts(
                pid: pid, exe: exe, workingDir: "/tmp", gitRepo: nil, gitBranch: nil,
                listeningPorts: [], ancestry: [], sourceType: "launchd", sourceName: "com.example.job",
                warnings: [], cpuPercent: nil, memoryRSS: nil
            ),
            sourceType: "launchd", sourceName: "com.example.job", sourceUnitFile: nil, warnings: []
        )
    }

    @Test("a pid mismatch is a disagreement, and launchd keeps its pid")
    func identityConflict() {
        let (merged, events) = WitrEnricher.enrich(record(program: nil, pid: 100), report: report(pid: 200, exe: "/bin/x"))
        #expect(merged.pid == 100)
        #expect(merged.enrichment == .degraded)
        #expect(events.map(\.kind) == [.identityConflict])
    }

    @Test("a different executable is kept on both sides, not normalized")
    func execPathConflict() {
        let (_, events) = WitrEnricher.enrich(
            record(program: "/usr/bin/a", pid: 100),
            report: report(pid: 100, exe: "/opt/homebrew/bin/a")
        )
        #expect(events.map(\.kind) == [.execPathConflict])
        #expect(events.first?.note?.contains("/usr/bin/a") == true)
    }

    @Test("a bare command name is not compared to a path")
    func noFalseConflict() {
        let (_, events) = WitrEnricher.enrich(
            record(program: "/opt/homebrew/bin/llama-server", pid: 100),
            report: report(pid: 100, exe: "llama-server")
        )
        #expect(events.isEmpty)
    }

    @Test("a missing report degrades but does not fabricate a disagreement for an absent binary")
    func missingReport() {
        let (absent, events) = WitrEnricher.missingReport(record(program: "/bin/x", pid: 1), failure: .notInstalled)
        #expect(absent.enrichment == .degraded)
        #expect(events.isEmpty, "an absent optional dependency is not a disagreement about the machine")

        let (invalidRecord, invalid) = WitrEnricher.missingReport(
            record(program: "/bin/x", pid: 1), failure: .malformed("junk")
        )
        #expect(invalidRecord.enrichment == .degraded)
        #expect(invalid.map(\.kind) == [.witrinvalid])
    }
}
