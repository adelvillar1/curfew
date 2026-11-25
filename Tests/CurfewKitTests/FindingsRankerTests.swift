import Foundation
import Testing
@testable import CurfewKit

@Suite("Findings ranking")
struct FindingsRankerTests {

    final class Scores: JevTransport, @unchecked Sendable {
        private let lock = NSLock()
        private(set) var requests: [Data] = []
        /// key ("f0", "f1") → score
        var scores: [String: Double] = [:]
        var failure: Error?

        func post(_ body: Data) throws -> (status: Int, body: Data) {
            lock.lock(); requests.append(body); lock.unlock()
            if let failure { throw failure }
            var answers: [String: Any] = [:]
            let object = try JSONSerialization.jsonObject(with: body) as? [String: Any] ?? [:]
            let questions = object["questions"] as? [String: Any] ?? [:]
            // Only answer what the script knows: an unanswered question is a real case the caller
            // must survive, so the fake must be able to produce it.
            for key in questions.keys where scores[key] != nil {
                answers[key] = ["type": "score", "score": scores[key]!]
            }
            return (200, try JSONSerialization.data(withJSONObject: ["answers": answers]))
        }
    }

    func finding(_ label: String, _ severity: String = "defect", kind: String = "danglingProgram",
                 summary: String = "x") -> FindingReport {
        FindingReport(label: label, domain: "gui/501", id: kind, severity: severity,
                      summary: summary, evidence: "evidence for \(label)")
    }

    func runner(_ transport: Scores) -> FindingsRunner {
        FindingsRunner(client: JevClient(transport: transport),
                       log: DecisionLog(url: FileManager.default.temporaryDirectory
                        .appendingPathComponent("curfew-rank-\(UUID().uuidString).jsonl")))
    }

    @Test("the order follows the impact, not the input order")
    func ordersByImpact() {
        let transport = Scores()
        transport.scores = ["f0": 1.0, "f1": 4.5, "f2": 2.0]
        let findings = [finding("a"), finding("b"), finding("c")]
        let (ranked, note) = runner(transport).rank(findings)

        #expect(ranked.map { $0.finding.label } == ["b", "c", "a"])
        #expect(ranked.first?.impact == 4.5)
        #expect(note?.contains("impact range") == true)
    }

    @Test("ties keep the order the findings engine produced")
    func tiesAreStable() {
        let transport = Scores()
        transport.scores = ["f0": 2.0, "f1": 2.0, "f2": 2.0]
        let (ranked, _) = runner(transport).rank([finding("a"), finding("b"), finding("c")])
        #expect(ranked.map { $0.finding.label } == ["a", "b", "c"])
    }

    @Test("severity labels are printed unchanged — the model only reorders")
    func severityUntouched() {
        let transport = Scores()
        transport.scores = ["f0": 1.0, "f1": 5.0]
        let findings = [finding("a", "gap"), finding("b", "blocker")]
        let (ranked, _) = runner(transport).rank(findings)
        #expect(ranked.map { $0.finding.severity } == ["blocker", "gap"])
        #expect(ranked.allSatisfy { $0.finding.severity == "blocker" || $0.finding.severity == "gap" })
    }

    @Test("a model failure leaves the usual order and says so")
    func failureKeepsOrder() {
        struct Boom: Error {}
        let transport = Scores()
        transport.failure = Boom()
        let findings = [finding("a"), finding("b"), finding("c")]
        let (ranked, note) = runner(transport).rank(findings)

        #expect(ranked.map { $0.finding.label } == ["a", "b", "c"], "the list is never empty and never reordered blindly")
        #expect(note?.contains("unavailable") == true)
        #expect(ranked.allSatisfy { $0.impact == nil })
    }

    @Test("a finding the model did not score is shown last, not dropped")
    func unscoredGoesLast() {
        let transport = Scores()
        transport.scores = ["f0": 1.0, "f1": 3.0]  // f2 deliberately missing
        let findings = [finding("a"), finding("b"), finding("c")]
        let (ranked, note) = runner(transport).rank(findings)
        #expect(ranked.map { $0.finding.label } == ["b", "a", "c"])
        #expect(note?.contains("unscored") == true)
    }

    @Test("the state carries the evidence, not just the summary")
    func stateCarriesEvidence() {
        let state = FindingsRanker.state([finding("a", summary: "declares a program that cannot be run")])
        #expect(state.contains("evidence for a"))
        #expect(state.contains("\"key\":\"f0\""))
        #expect(state.contains("danglingProgram"))
    }

    @Test("one request per chunk of 20, and every finding gets a head")
    func questionsPerFinding() {
        let questions = FindingsRanker.questions(range: 0..<3)
        #expect(questions.map(\.id) == ["f0", "f1", "f2"])
        #expect(questions.allSatisfy { $0.kind == .score })
        #expect(questions.first?.labels.count == 5, "the rubric has five ordered levels")
    }
}
