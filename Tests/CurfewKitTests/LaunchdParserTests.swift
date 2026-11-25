import Foundation
import Testing
@testable import CurfewKit

@Suite("LaunchdParser")
struct LaunchdParserTests {

    static var fixtures: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
    }

    static func fixture(_ name: String) throws -> String {
        try String(contentsOf: fixtures.appendingPathComponent(name), encoding: .utf8)
    }

    // MARK: Domain table

    @Test("parses the real domain table without dropping the table itself")
    func domainTableFromFixture() throws {
        let text = try Self.fixture("launchctl-gui-501-macos-26.5.2.txt")
        let table = LaunchdParser.domainTable(text)
        #expect(table.labels.count > 200, "expected hundreds of jobs, got \(table.labels.count)")
        #expect(table.labels.contains("com.adelvillar1.sem1-llama"))
        #expect(table.labels.contains { $0.hasPrefix("com.apple.") })
    }

    @Test("skips a malformed row and counts it instead of failing")
    func domainTableTolerance() {
        let text = """
        gui/501 = {
        \tservices = {
        \t\t   80856      - \tcom.example.good
        \t\tthis row is nonsense
        \t\t       0      0 \tcom.example.never-ran
        \t}
        }
        """
        let table = LaunchdParser.domainTable(text)
        #expect(table.labels == ["com.example.good", "com.example.never-ran"])
        #expect(table.skipped == 1)
    }

    @Test("stops at the end of the services table")
    func domainTableStops() {
        let text = """
        gui/501 = {
        \tservices = {
        \t\t   1      - \tcom.example.one
        \t}
        \tendpoints = {
        \t\t   2      - \tcom.example.not-a-service
        \t}
        }
        """
        let table = LaunchdParser.domainTable(text)
        #expect(table.labels == ["com.example.one"])
    }

    // MARK: Job detail

    @Test("reads a real running job")
    func detailFromFixture() throws {
        let text = try Self.fixture("launchctl-job-healthy-macos-26.5.2.txt")
        let detail = try #require(LaunchdParser.jobDetail(text, label: "com.adelvillar1.sem1-llama", domain: .gui(501)))
        #expect(detail.state == .running)
        #expect(detail.pid == 27468)
        #expect(detail.runs == 11)
        #expect(detail.lastExitCode == nil, "a job that never exited has no exit code")
        #expect(detail.program?.hasSuffix("llama-server") == true)
        #expect(detail.plistPath?.contains("com.adelvillar1.sem1-llama.plist") == true)
        #expect(detail.keepAlive == .always)
        #expect(detail.missingFields.isEmpty)
    }

    @Test("reads a root-owned system job without privilege")
    func systemDetail() throws {
        let text = try Self.fixture("launchctl-job-system-root-macos-26.5.2.txt")
        let detail = try #require(LaunchdParser.jobDetail(text, label: "com.apple.securityd", domain: .system))
        #expect(detail.state == .running)
        #expect(detail.runs != nil)
    }

    @Test("parses EX_CONFIG and never-exited exit codes")
    func exitCodes() {
        #expect(LaunchdParser.parseExitCode("78: EX_CONFIG") == 78)
        #expect(LaunchdParser.parseExitCode("0") == 0)
        #expect(LaunchdParser.parseExitCode("(never exited)") == nil)
        #expect(LaunchdParser.parseExitCode(nil) == nil)
    }

    @Test("a missing field is recorded, not defaulted to zero")
    func missingFields() {
        let text = """
        gui/501/com.example.bare = {
        \tstate = spawn scheduled
        \tpath = /tmp/com.example.bare.plist
        \truns = 255645
        \tlast exit code = 78: EX_CONFIG
        }
        """
        let detail = LaunchdParser.jobDetail(text, label: "com.example.bare", domain: .gui(501))
        #expect(detail?.runs == 255_645)
        #expect(detail?.lastExitCode == 78)
        #expect(detail?.program == nil)
        #expect(detail?.missingFields.contains("program") == true)
    }

    @Test("ignores nested state lines (they are not the job's state)")
    func nestedStateIsIgnored() {
        let text = """
        gui/501/com.example.nested = {
        \tstate = spawn scheduled
        \tpath = /tmp/x.plist
        \truns = 4
        \tresource coalition = {
        \t\tstate = active
        \t}
        }
        """
        let detail = LaunchdParser.jobDetail(text, label: "com.example.nested", domain: .gui(501))
        #expect(detail?.state == .spawnScheduled)
    }

    @Test("returns nil for a job that does not resolve")
    func noSuchJob() {
        let text = "Bad request.\nCould not find service \"com.example\" in domain for user gui: 501"
        #expect(LaunchdParser.jobDetail(text, label: "com.example", domain: .gui(501)) == nil)
    }

    // MARK: Disabled database

    @Test("reads the disabled database")
    func disabled() throws {
        let text = try Self.fixture("launchctl-print-disabled-gui-501.txt")
        let labels = LaunchdParser.disabledLabels(text)
        #expect(!labels.isEmpty)
        #expect(labels.allSatisfy { !$0.isEmpty })
    }
}
