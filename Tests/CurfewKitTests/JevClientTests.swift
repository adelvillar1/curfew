import Foundation
import Testing
@testable import CurfewKit

@Suite("JevClient")
struct JevClientTests {

    /// A transport that records what was sent and answers from a script — no network, ever.
    final class Recorder: JevTransport, @unchecked Sendable {
        private let lock = NSLock()
        private(set) var requests: [Data] = []
        var status = 200
        var response: [String: Any] = [:]
        var failure: Error?

        func post(_ body: Data) throws -> (status: Int, body: Data) {
            lock.lock(); requests.append(body); lock.unlock()
            if let failure { throw failure }
            let data = try JSONSerialization.data(withJSONObject: ["answers": response])
            return (status, data)
        }

        var lastRequest: [String: Any]? {
            guard let body = requests.last else { return nil }
            return try? JSONSerialization.jsonObject(with: body) as? [String: Any]
        }
    }

    func client(_ recorder: Recorder, policy: ConfidencePolicy = .default) -> JevClient {
        JevClient(transport: recorder, model: "jev-1.14", policy: policy)
    }

    let disposition = JevQuestion(
        id: "disposition", kind: .choice,
        task: "Should Curfew stop this service?",
        labels: ["stop", "protect", "never"],
        descriptions: ["stop": "an updater nobody needs", "protect": "holds state", "never": "OS critical"]
    )

    // MARK: The wire

    @Test("the request carries the model, the state and every typed question")
    func requestShape() throws {
        let recorder = Recorder()
        recorder.response = ["disposition": ["type": "choice", "label": "protect",
                                             "probabilities": ["stop": 0.2, "protect": 0.7, "never": 0.1],
                                             "confidence": 0.72]]
        _ = try client(recorder).ask([disposition], state: "label=x kind=agent")

        let sent = try #require(recorder.lastRequest)
        #expect(sent["model"] as? String == "jev-1.14")
        #expect(sent["state"] as? String == "label=x kind=agent")
        let questions = try #require(sent["questions"] as? [String: Any])
        let one = try #require(questions["disposition"] as? [String: Any])
        #expect(one["type"] as? String == "choice")
        #expect(one["instructions"] as? String == "Should Curfew stop this service?")
        #expect((one["criteria"] as? [String: String])?["protect"] == "holds state")
    }

    @Test("a noul sends its true/false criteria — the pattern's requirement that a no says what it means")
    func noulCriteria() throws {
        let recorder = Recorder()
        recorder.response = ["infra": ["type": "noul", "noul": 0.78]]
        let question = JevQuestion(id: "infra", kind: .noul, task: "Is it infrastructure?",
                                   descriptions: ["true": "other software calls it",
                                                  "false": "an updater for the human"])
        _ = try client(recorder).ask([question], state: "s")
        let one = try #require((recorder.lastRequest?["questions"] as? [String: Any])?["infra"] as? [String: Any])
        let criteria = try #require(one["criteria"] as? [String: String])
        #expect(criteria["false"] == "an updater for the human")
    }

    // MARK: Parsing

    @Test("a choice parses into a label, its full distribution and a confidence")
    func parseChoice() throws {
        let recorder = Recorder()
        recorder.response = ["q": ["type": "choice", "label": "stop",
                                   "probabilities": ["stop": 0.91, "protect": 0.09], "confidence": 0.82]]
        let answers = try client(recorder).ask(
            [JevQuestion(id: "q", kind: .choice, task: "t", labels: ["stop", "protect"])], state: "s")
        guard case .choice(let label, let probabilities, let confidence) = answers["q"] else {
            Issue.record("expected a choice, got \(String(describing: answers["q"]))")
            return
        }
        #expect(label == "stop")
        #expect(probabilities["stop"] == 0.91)
        #expect(confidence == 0.82)
    }

    @Test("a noul parses to its probability and nothing else")
    func parseNoul() throws {
        let recorder = Recorder()
        recorder.response = ["q": ["type": "noul", "noul": 0.62]]
        let answers = try client(recorder).ask([JevQuestion(id: "q", kind: .noul, task: "t")], state: "s")
        #expect(answers["q"]?.noul == 0.62)
    }

    @Test("a missing answer is malformed, never invented")
    func missingAnswer() throws {
        let recorder = Recorder()
        recorder.response = [:]
        let answers = try client(recorder).ask([JevQuestion(id: "q", kind: .noul, task: "t")], state: "s")
        guard case .malformed = answers["q"] else {
            Issue.record("a missing answer must be malformed")
            return
        }
    }

    // MARK: Failure is unknown, never confidence

    @Test("a refusing server throws instead of returning an answer")
    func refusal() {
        let recorder = Recorder()
        recorder.status = 402
        recorder.response = [:]
        #expect(throws: JevError.self) {
            try client(recorder).ask([JevQuestion(id: "q", kind: .noul, task: "t")], state: "s")
        }
    }

    @Test("a transport failure throws")
    func transportFailure() {
        struct Boom: Error {}
        let recorder = Recorder()
        recorder.failure = Boom()
        #expect(throws: JevError.self) {
            try client(recorder).ask([JevQuestion(id: "q", kind: .noul, task: "t")], state: "s")
        }
    }

    // MARK: Confidence policy

    @Test("the default floor is 0.70 / 0.20")
    func defaults() {
        #expect(ConfidencePolicy.default.floor == 0.70)
        #expect(ConfidencePolicy.default.marginFloor == 0.20)
    }

    @Test("a confident choice needs both the floor and the margin")
    func choiceConfidence() {
        let policy = ConfidencePolicy.default
        #expect(policy.classify(.choice(label: "a", probabilities: ["a": 0.9, "b": 0.1], confidence: 0.9)) == .confident)
        // under the floor, however clean the margin
        #expect(policy.classify(.choice(label: "a", probabilities: ["a": 0.9, "b": 0.1], confidence: 0.65)) == .marginal)
        // over the floor, but a coin-flip between the top two
        #expect(policy.classify(.choice(label: "a", probabilities: ["a": 0.51, "b": 0.49], confidence: 0.51)) == .marginal)
    }

    @Test("a noul is judged by its distance from a coin-flip")
    func noulConfidence() {
        let policy = ConfidencePolicy.default
        #expect(policy.classify(.noul(0.78)) == .confident)   // |0.78-0.5|*2 = 0.56
        #expect(policy.classify(.noul(0.57)) == .marginal)    // 0.14 < 0.20 — the kiri.daemon case
        #expect(policy.classify(.noul(0.45)) == .marginal)    // 0.10 from a coin-flip
        #expect(policy.classify(.noul(0.39)) == .confident)   // 0.22 — over the margin, barely
    }

    @Test("a malformed answer is unknown")
    func malformedConfidence() {
        #expect(ConfidencePolicy.default.classify(.malformed("x")) == .unknown)
    }
}

@Suite("DecisionLog")
struct DecisionLogTests {

    func tempLog() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("curfew-decisions-\(UUID().uuidString).jsonl")
    }

    let question = JevQuestion(id: "q", kind: .noul, task: "is it in use?")

    @Test("a row records the model, the hashes and the decision taken")
    func appendAndRead() throws {
        let url = tempLog()
        defer { try? FileManager.default.removeItem(at: url) }
        let log = DecisionLog(url: url)
        let answers: [String: JevAnswer] = ["q": .noul(0.8)]
        let row = log.makeRow(model: "jev-1.14", surface: "propose", subject: "a.b",
                              state: "label=a.b", questions: [question],
                              answers: answers, decision: "protect", confidence: .confident)
        try log.append(row)

        let back = try #require(DecisionLog(url: url).rows().first)
        #expect(back.model == "jev-1.14")
        #expect(back.subject == "a.b")
        #expect(back.decision == "protect")
        #expect(back.confidence == "confident")
        #expect(back.stateSha.count == 40)
        #expect(back.answers["q"] == "noul:0.80")
    }

    @Test("the same state and questions hit the cache; different ones miss")
    func cache() throws {
        let url = tempLog()
        defer { try? FileManager.default.removeItem(at: url) }
        let log = DecisionLog(url: url)
        try log.append(log.makeRow(model: "jev-1.14", surface: "propose", subject: "a.b",
                                   state: "label=a.b", questions: [question],
                                   answers: ["q": .noul(0.8)], decision: "protect", confidence: .confident))

        #expect(log.cached(model: "jev-1.14", state: "label=a.b", questions: [question])?.decision == "protect")
        #expect(log.cached(model: "jev-1.14", state: "label=other", questions: [question]) == nil)
        #expect(log.cached(model: "jev-2.0", state: "label=a.b", questions: [question]) == nil)
        // the same state with a different question is a different request
        let other = JevQuestion(id: "q", kind: .noul, task: "something else?")
        #expect(log.cached(model: "jev-1.14", state: "label=a.b", questions: [other]) == nil)
    }

    @Test("a truncated row is skipped, not fatal")
    func truncated() throws {
        let url = tempLog()
        defer { try? FileManager.default.removeItem(at: url) }
        let log = DecisionLog(url: url)
        try log.append(log.makeRow(model: "m", surface: "s", subject: nil, state: "x",
                                   questions: [question], answers: [:], decision: "d", confidence: .marginal))
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"v\":1,\"ts\":\"half".utf8))
        try handle.close()
        #expect(DecisionLog(url: url).rows().count == 1)
    }
}
