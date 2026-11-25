import Foundation
import Testing
@testable import CurfewKit

/// The published shapes are a contract (C7): field names are stable, changes are additive only.
/// These tests fail on a rename, which is the point — a consumer's script breaks silently otherwise.
@Suite("JSON contract")
struct ContractShapeTests {

    var sources: Sources { Sources(witr: "0.3.4", macos: "26.5.2", curfew: "0.1.0") }

    var record: ServiceRecord {
        ServiceRecord(
            id: "com.example.job", domain: "gui/501", plistPath: "/tmp/x.plist",
            state: .running, pid: 42, runs: 3, lastExitCode: nil, program: "/bin/x",
            keepAlive: .always, tier: .thirdParty, kind: .agent, vendor: "Example",
            supervised: .launchd, process: nil, findings: [], enrichment: .unavailable
        )
    }

    func keys<T: Encodable>(_ value: T) throws -> Set<String> {
        let data = try JSONEncoder().encode(value)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return Set(object.map { Array($0.keys) } ?? [])
    }

    @Test("list output carries exactly the documented top-level keys")
    func listShape() throws {
        let output = ListOutput(sources: sources, records: [record], scan: ScanState())
        #expect(try keys(output) == ["v", "sources", "records", "scan"])
        let scan = try JSONSerialization.jsonObject(with: JSONEncoder().encode(ScanState())) as? [String: Any]
        #expect(Set(scan.map { Array($0.keys) } ?? []) == ["complete", "incompleteReasons"])
    }

    @Test("doctor output carries exactly the documented top-level keys")
    func doctorShape() throws {
        let output = DoctorOutput(
            sources: sources,
            findings: [FindingReport(label: "x", domain: "gui/501", id: "crashLoop", severity: "defect", summary: "s", evidence: "e")],
            scan: ScanState(),
            disagreements: []
        )
        #expect(try keys(output) == ["v", "sources", "findings", "scan", "disagreements"])
    }

    @Test("why output carries exactly the documented top-level keys")
    func whyShape() throws {
        let output = WhyOutput(
            sources: sources, record: record,
            ancestry: [AncestryNode(pid: 1, command: "launchd")],
            source: SourceSummary(type: "launchd", name: "com.example.job", plistPath: "/tmp/x.plist"),
            warnings: [], scan: ScanState()
        )
        #expect(try keys(output) == ["v", "sources", "record", "ancestry", "source", "warnings", "scan"])
    }

    @Test("a record's fields are the contract")
    func recordShape() throws {
        let expected: Set<String> = [
            "id", "domain", "plistPath", "state", "pid", "runs", "lastExitCode", "program",
            "keepAlive", "tier", "kind", "vendor", "supervised", "process", "findings", "enrichment",
        ]
        let encoded = try JSONEncoder().encode(record)
        let object = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        // The contract: every field is named here; a field with no value is *omitted*, never
        // null. Consumers must tolerate a missing key for an optional field.
        #expect(Set(object.keys).isSubset(of: expected), "unexpected field in the record")
        for required in ["id", "domain", "state", "keepAlive", "tier", "kind", "supervised", "enrichment"] {
            #expect(object[required] != nil, "\(required) must always be present")
        }
        #expect(object["lastExitCode"] == nil, "a never-exited job omits the exit code rather than sending null")
        #expect(object["state"] as? String == "running")
        #expect(object["tier"] as? String == "thirdParty")
    }

    @Test("a disagreement line's fields are the contract")
    func disagreementShape() throws {
        let record = DisagreementRecord(
            v: 1, ts: "2026-11-24T21:40:12.301Z", curfew: "0.1.0", macos: "26.5.2", witrVersion: "0.3.4",
            kind: .identityConflict, fingerprint: "sha1:abc",
            target: DisagreementTarget(label: "x", pid: 1, port: nil),
            launchd: LaunchdEvidence(program: "/a", state: "running", runs: 1, lastExit: nil),
            witrEvidence: WitrEvidence(exe: "/b", sourceType: "launchd", pid: 2),
            verdict: Verdict(state: "running", enrichment: "degraded"),
            suppressed: nil, note: nil
        )
        let expected: Set<String> = [
            "v", "ts", "curfew", "macos", "witrVersion", "kind", "fingerprint", "target",
            "launchd", "witrEvidence", "verdict",
        ]
        let encoded = try JSONEncoder().encode(record)
        let object = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(Set(object.keys) == expected)
    }
}

/// D29 replaced the "no network path" ban — a model call is a feature now, not a violation. What
/// survives is the property that ban stood for: the diagnostic path needs no network and no key.
@Suite("Offline by default")
struct OfflineTests {

    static var sourcesRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources")
    }

    @Test("the diagnostic core has no dependency on the decision-model layer")
    func coreIsIndependentOfTheModel() throws {
        let core = [
            "LaunchdInventory.swift", "LaunchdParser.swift", "Findings.swift", "Classification.swift",
            "ListenerScan.swift", "NeverList.swift", "WitrClient.swift", "Catalog.swift",
            "Journal.swift", "Executor.swift", "TUI.swift", "MenuBarModel.swift",
        ]
        let modelTokens = ["JevClient", "JevHTTPTransport", "JevQuestion", "DecisionLog"]
        var checked = 0
        for name in core {
            let url = Self.sourcesRoot.appendingPathComponent("CurfewKit").appendingPathComponent(name)
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            checked += 1
            for token in modelTokens {
                #expect(!text.contains(token),
                        "\(name) references \(token) — the diagnostic path must work with no network and no key (D29)")
            }
        }
        #expect(checked >= 10, "expected to scan the diagnostic core, scanned \(checked)")
    }

    @Test("with no key, the model client refuses by name and sends nothing")
    func noKeyIsANamedRefusal() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("no-such-key-\(UUID().uuidString)")
        setenv("CURFEW_JEV_KEY", missing.path, 1)
        defer { unsetenv("CURFEW_JEV_KEY") }
        #expect(throws: JevError.self) { try JevClient.liveClient() }
    }
}
