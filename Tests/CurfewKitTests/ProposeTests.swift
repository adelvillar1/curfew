import Foundation
import Testing
@testable import CurfewKit

@Suite("Catalog propose")
struct ProposeTests {

    /// Answers from a script, no network. The three regression cases come straight from
    /// `docs/research/tooling-jev.md`: metadata alone sent an MCP server and a VM daemon to `stop`.
    final class Answers: JevTransport, @unchecked Sendable {
        private let lock = NSLock()
        private(set) var requests: [Data] = []
        var response: [String: Any] = [:]

        func post(_ body: Data) throws -> (status: Int, body: Data) {
            lock.lock(); requests.append(body); lock.unlock()
            return (200, try JSONSerialization.data(withJSONObject: ["answers": response]))
        }

        var sentState: String? {
            guard let body = requests.last,
                  let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
            else { return nil }
            return object["state"] as? String
        }
    }

    func answer(disposition: String, confidence: Double, infrastructure: Double, stateToLose: Double)
        -> [String: Any] {
        [
            "disposition": ["type": "choice", "choice": disposition,
                            "confidence": confidence,
                            "probabilities": [disposition: confidence, "other": 1 - confidence]],
            "is_infrastructure": ["type": "noul", "noul": infrastructure],
            "has_state_to_lose": ["type": "noul", "noul": stateToLose],
            "disruption": ["type": "score", "score": 4.0],
        ]
    }

    func runner(_ transport: Answers) -> ProposeRunner {
        ProposeRunner(client: JevClient(transport: transport), log: DecisionLog(url: tempLog()))
    }

    func tempLog() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("curfew-propose-\(UUID().uuidString).jsonl")
    }

    func record(_ id: String, pid: Int32? = nil) -> ServiceRecord {
        ServiceRecord(
            id: id, domain: "gui/501", plistPath: "/tmp/\(id).plist", state: .running, pid: pid,
            runs: 3, lastExitCode: 0, program: "/bin/true", tier: .thirdParty, kind: .agent,
            supervised: .launchd
        )
    }

    // MARK: The rule, on the measured cases

    @Test("an MCP server and a VM daemon are protected even when the disposition says stop")
    func infrastructureOverridesDisposition() throws {
        // both were called `stop` from metadata alone; both are infrastructure
        for label in ["com.adelvillar1.blend1-service", "dev.kiri.daemon"] {
            let transport = Answers()
            transport.response = answer(disposition: "stop", confidence: 0.52,
                                        infrastructure: 0.75, stateToLose: 0.40)
            let proposal = try runner(transport).propose(record: record(label), label: label, listeners: [])
            #expect(proposal.decision == .protect, "\(label) must be protected")
            #expect(proposal.reasons.joined().contains("is_infrastructure"))
        }
    }

    @Test("an updater stays stop when the disposition is confident and nothing is at stake")
    func updaterStaysStop() throws {
        let transport = Answers()
        transport.response = answer(disposition: "stop", confidence: 0.96,
                                    infrastructure: 0.07, stateToLose: 0.05)
        let proposal = try runner(transport).propose(
            record: record("us.zoom.updater"), label: "us.zoom.updater", listeners: [])
        #expect(proposal.decision == .stop)
        #expect(proposal.confidence == .confident)
    }

    @Test("a low-confidence disposition becomes review, not a guess")
    func marginalBecomesReview() throws {
        let transport = Answers()
        transport.response = answer(disposition: "stop", confidence: 0.25,
                                    infrastructure: 0.30, stateToLose: 0.20)
        let proposal = try runner(transport).propose(
            record: record("com.workbuddy.converter"), label: "com.workbuddy.converter", listeners: [])
        #expect(proposal.decision == .review)
        #expect(proposal.reasons.joined().contains("marginal"))
    }

    @Test("state to lose protects even when it is not infrastructure")
    func stateToLoseProtects() throws {
        let transport = Answers()
        transport.response = answer(disposition: "stop", confidence: 0.9,
                                    infrastructure: 0.2, stateToLose: 0.8)
        let proposal = try runner(transport).propose(record: record("a.b"), label: "a.b", listeners: [])
        #expect(proposal.decision == .protect)
        #expect(proposal.reasons.joined().contains("has_state_to_lose"))
    }

    // MARK: The evidence reaches the model

    @Test("listening sockets are in the state — the fact that fixed the two errors")
    func socketsReachTheModel() throws {
        let transport = Answers()
        transport.response = answer(disposition: "protect", confidence: 0.8,
                                    infrastructure: 0.8, stateToLose: 0.4)
        let listeners = [
            Listener(command: "node", pid: 4242, address: "127.0.0.1", port: 8420),
            Listener(command: "other", pid: 9999, address: "127.0.0.1", port: 1),
        ]
        _ = try runner(transport).propose(
            record: record("com.adelvillar1.blend1-service", pid: 4242),
            label: "com.adelvillar1.blend1-service", listeners: [listeners[0]])

        let state = try #require(transport.sentState)
        #expect(state.contains("8420"), "the service's own socket must be in the state")
        #expect(!state.contains(":1\""), "another process's socket must not be")
        #expect(state.contains("com.adelvillar1.blend1-service"))
    }

    @Test("a never-list label is answered without asking the model")
    func neverListAsksNothing() throws {
        let transport = Answers()
        let proposal = try runner(transport).propose(
            record: record("com.apple.securityd"), label: "com.apple.securityd", listeners: [])
        #expect(proposal.decision == .never)
        #expect(transport.requests.isEmpty, "no model call for a never-list label")
        #expect(proposal.reasons.joined().contains("never-list"))
    }

    // MARK: The output acts on nothing

    @Test("the emitted entry is a draft with no recipe")
    func yamlIsADraft() throws {
        let transport = Answers()
        transport.response = answer(disposition: "stop", confidence: 0.9,
                                    infrastructure: 0.1, stateToLose: 0.1)
        let proposal = try runner(transport).propose(
            record: record("us.zoom.updater"), label: "us.zoom.updater", listeners: [])
        let yaml = Proposer.yaml(proposal, record: record("us.zoom.updater"))
        #expect(yaml.contains("status: draft"))
        #expect(yaml.contains("proposed by jev-1.14"))
        #expect(!yaml.contains("run:"), "a proposal carries no recipe")
        #expect(!yaml.contains("stop:"), "a proposal carries no recipe")
    }

    @Test("a protected proposal is emitted unstoppable")
    func protectedIsUnstoppable() throws {
        let transport = Answers()
        transport.response = answer(disposition: "protect", confidence: 0.9,
                                    infrastructure: 0.9, stateToLose: 0.5)
        let proposal = try runner(transport).propose(record: record("a.b"), label: "a.b", listeners: [])
        let yaml = Proposer.yaml(proposal, record: record("a.b"))
        #expect(yaml.contains("lever: none"))
        #expect(yaml.contains("stoppable: false"))
    }

    // MARK: The log

    @Test("a proposal is recorded, and the same evidence replays from the log")
    func decisionIsLoggedAndReplayed() throws {
        let url = tempLog()
        defer { try? FileManager.default.removeItem(at: url) }
        let transport = Answers()
        transport.response = answer(disposition: "stop", confidence: 0.9,
                                    infrastructure: 0.05, stateToLose: 0.05)
        let log = DecisionLog(url: url)
        let runner = ProposeRunner(client: JevClient(transport: transport), log: log)

        _ = try runner.propose(record: record("a.b"), label: "a.b", listeners: [])
        #expect(log.rows().count == 1)
        #expect(log.rows().first?.surface == "propose")

        // the same record and the same questions: a replay, so no second call
        let before = transport.requests.count
        let second = try runner.propose(record: record("a.b"), label: "a.b", listeners: [])
        #expect(transport.requests.count == before, "a replay must not call the model")
        #expect(second.reasons.joined().contains("replayed"))
    }
}
