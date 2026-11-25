import Foundation
import Testing
@testable import CurfewKit

@Suite("ListenerScan")
struct ListenerScanTests {

    static var fixtures: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
    }

    static func fixture(_ name: String) throws -> String {
        try String(contentsOf: fixtures.appendingPathComponent(name), encoding: .utf8)
    }

    func job(
        id: String = "com.example.orphan",
        program: String? = "/opt/homebrew/opt/postgresql@14/bin/postgres",
        state: JobState = .notLoaded,
        pid: Int32? = nil,
        runs: UInt64? = 82_103,
        exit: Int32? = 1
    ) -> ServiceRecord {
        ServiceRecord(
            id: id, domain: "gui/501", plistPath: "/tmp/\(id).plist",
            state: state, pid: pid, runs: runs, lastExitCode: exit, program: program,
            tier: .thirdParty, kind: .agent, vendor: "Homebrew", supervised: .launchd
        )
    }

    func listener(_ command: String, _ pid: Int32, _ port: UInt16, address: String = "*") -> Listener {
        Listener(command: command, pid: pid, address: address, port: port)
    }

    /// Every running pid resolves to `exe`; an unmapped pid resolves to nil.
    func resolver(_ exe: String?, for pid: Int32) -> ExecutableResolver {
        ExecutableResolver { asked in asked == pid ? exe : nil }
    }

    // MARK: Parsing

    @Test("parses the real lsof fixture and deduplicates dual-stack listeners")
    func parsesFixture() throws {
        let listeners = ListenerParser.parse(try Self.fixture("lsof-listen-macos-26.5.2.txt"))
        #expect(listeners.count > 10, "expected a real listener table, got \(listeners.count)")
        // A dual-stack listener appears as two rows in lsof but one Listener here.
        let ports = listeners.map(\.port)
        #expect(ports.count == Set(ports).count, "port list must be deduplicated per pid+port")
        #expect(listeners.allSatisfy { $0.pid > 0 && $0.port > 0 })
    }

    @Test("parses IPv6 and wildcard addresses")
    func parsesAddresses() {
        let text = """
        COMMAND     PID USER   FD   TYPE  DEVICE SIZE/OFF NODE NAME
        node      12345  me   10u  IPv4 0x1      0t0  TCP *:8901 (LISTEN)
        node      12345  me   11u  IPv6 0x2      0t0  TCP [fd7a:115c:a1e0::1]:8443 (LISTEN)
        """
        let listeners = ListenerParser.parse(text)
        #expect(listeners.count == 2)
        #expect(listeners.contains { $0.port == 8901 && $0.address == "*" })
        #expect(listeners.contains { $0.port == 8443 && $0.address.hasPrefix("[fd7a") })
    }

    // MARK: orphanPort — the PG14 case

    @Test("a squatter holding the job's port is a defect naming both sides")
    func orphanPort() {
        let findings = ListenerFindings.orphanPorts(
            listeners: [listener("postgres", 999, 5434)],
            records: [job()],
            executableForPid: resolver("/opt/homebrew/opt/postgresql@14/bin/postgres", for: 999)
        )
        #expect(findings.count == 1)
        let finding = try? #require(findings.first)
        #expect(finding?.id == .orphanPort)
        #expect(finding?.severity == .defect)
        #expect(finding?.evidence.contains("pid 999") == true)
        #expect(finding?.evidence.contains("not running") == true)
        #expect(finding?.evidence.contains("5434") == true)
    }

    @Test("a second process of a live job's executable is not a leftover")
    func secondInstanceIsNotOrphan() {
        // Live, 2026-11-24: Google Drive and DSH Fleet each run a second process of the same
        // executable alongside their supervised one. That is an instance, not a defect.
        let findings = ListenerFindings.orphanPorts(
            listeners: [listener("postgres", 999, 5434)],
            records: [job(state: .running, pid: 39307)],
            executableForPid: resolver("/opt/homebrew/opt/postgresql@14/bin/postgres", for: 999)
        )
        #expect(findings.isEmpty)
    }

    @Test("a dead job whose executable still holds the port is the defect")
    func deadJobLeftover() {
        let findings = ListenerFindings.orphanPorts(
            listeners: [listener("postgres", 999, 5434)],
            records: [job(state: .spawnScheduled, pid: nil)],
            executableForPid: resolver("/opt/homebrew/opt/postgresql@14/bin/postgres", for: 999)
        )
        #expect(findings.count == 1)
        #expect(findings.first?.evidence.contains("is not running") == true)
        #expect(findings.first?.evidence.contains("last exit 1") == true)
    }

    @Test("a listener owned by its own job produces nothing")
    func healthyListener() {
        let findings = ListenerFindings.orphanPorts(
            listeners: [listener("postgres", 39307, 5432)],
            records: [job(state: .running, pid: 39307)],
            executableForPid: resolver("/opt/homebrew/opt/postgresql@14/bin/postgres", for: 39307)
        )
        #expect(findings.isEmpty)
    }

    @Test("a listener whose command no job declares is not an orphan — it is unattributed")
    func unknownCommandIsNotOrphan() {
        let findings = ListenerFindings.orphanPorts(
            listeners: [listener("python3", 555, 8787)],
            records: [job()],
            executableForPid: resolver("/usr/local/bin/python3", for: 555)
        )
        #expect(findings.isEmpty)
    }

    @Test("sharing an interpreter name is not sharing a job — the live false positive")
    func interpreterNameIsNotIdentity() {
        // 2026-11-24: a `node` on :3999 (an unrelated /tmp script) was accused of being
        // dev.dsh.bridge's leftover, because both are called `node`.
        let bridge = ServiceRecord(
            id: "dev.dsh.bridge", domain: "gui/501", plistPath: "/tmp/bridge.plist",
            state: .running, pid: 28157, runs: 2, lastExitCode: nil,
            program: "/opt/homebrew/bin/node", tier: .thirdParty, kind: .agent, supervised: .launchd
        )
        let findings = ListenerFindings.orphanPorts(
            listeners: [listener("node", 18514, 3999)],
            records: [bridge],
            executableForPid: resolver("/usr/local/bin/node", for: 18514)
        )
        #expect(findings.isEmpty, "a different node binary is a different program")
    }

    @Test("a symlinked program path still matches the executable it points at")
    func symlinkPathMatches() throws {
        // Built here rather than borrowed from brew: an earlier version of this test used a
        // postgresql@14 path that stopped existing the day the package was retired.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("curfew-symlink-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let real = dir.appendingPathComponent("postgres")
        try "#!/bin/sh\n".write(to: real, atomically: true, encoding: .utf8)
        let link = dir.appendingPathComponent("pg-link")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: real.path)

        let findings = ListenerFindings.orphanPorts(
            listeners: [listener("postgres", 999, 5434)],
            records: [job(program: link.path)],
            executableForPid: resolver(real.path, for: 999)
        )
        #expect(findings.count == 1, "canonical paths compare equal even when the strings differ")
    }

    // MARK: noSupervisor — aggregated, never a per-row defect

    @Test("unattributed listeners collapse into one gap naming each one")
    func unattributedAggregates() {
        let finding = ListenerFindings.unattributed(
            listeners: [
                listener("ControlCe", 675, 7000),
                listener("ControlCe", 675, 5000),
                listener("rapportd", 626, 57289),
            ],
            records: [job(state: .running, pid: 39307)],
            executableForPid: ExecutableResolver { _ in nil }
        )
        #expect(finding?.id == .noSupervisor)
        #expect(finding?.severity == .gap, "an app-spawned listener is legitimate; not-knowing is a gap")
        #expect(finding?.confirmsScan == true)
        #expect(finding?.evidence.contains("ControlCe:7000") == true)
        #expect(finding?.evidence.contains("rapportd:57289") == true)
    }

    @Test("listeners a job owns are not counted as unattributed")
    func unattributedExcludesOwned() {
        let finding = ListenerFindings.unattributed(
            listeners: [
                listener("postgres", 39307, 5432),
                listener("llama-server", 27468, 8901),
            ],
            records: [
                job(id: "pg", program: "/opt/pg/bin/postgres", state: .running, pid: 39307),
                job(id: "llama", program: "/opt/llama/llama-server", state: .running, pid: 27468),
            ],
            executableForPid: ExecutableResolver { _ in nil }
        )
        #expect(finding == nil)
    }

    @Test("a job known by name but not by pid does not count as unattributed")
    func nameMatchExcludes() {
        let finding = ListenerFindings.unattributed(
            listeners: [listener("postgres", 999, 5434)],
            records: [job()],
            executableForPid: resolver("/opt/homebrew/opt/postgresql@14/bin/postgres", for: 999)
        )
        #expect(finding == nil, "the orphan rule owns this case, not the aggregate")
    }

    @Test("evidence is bounded so one busy machine cannot flood a finding")
    func evidenceBounded() {
        let many = (0..<40).map { listener("svc\($0)", Int32(1000 + $0), UInt16(20_000 + $0)) }
        let finding = ListenerFindings.unattributed(
            listeners: many, records: [], executableForPid: ExecutableResolver { _ in nil }
        )
        #expect(finding?.summary.contains("40") == true)
        #expect(finding?.evidence.contains("more)") == true)
    }
}
