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

/// D18: v1 has no network path at all. Enforced by reading the sources, not by trusting intent.
@Suite("No network")
struct NoNetworkTests {

    static var sourcesRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources")
    }

    @Test("no source file imports a networking framework or opens a socket")
    func noNetworking() throws {
        let forbidden = ["import Network", "import CFNetwork", "URLSession", "NWConnection", "socket(", "getaddrinfo"]
        let files = FileManager.default.enumerator(at: Self.sourcesRoot, includingPropertiesForKeys: nil)
        var checked = 0
        while let url = files?.nextObject() as? URL {
            guard url.pathExtension == "swift" else { continue }
            let text = try String(contentsOf: url, encoding: .utf8)
            checked += 1
            for token in forbidden {
                #expect(!text.contains(token), "\(url.lastPathComponent) contains \(token) — v1 must have no network path")
            }
        }
        #expect(checked > 5, "expected to scan the source tree, scanned \(checked) files")
    }
}
