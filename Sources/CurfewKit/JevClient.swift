import Foundation

// The decision-model surface (D27): a model may propose and may narrow, never gate.
//
// Everything here is testable without a network: the transport is injected, the clock is passed in, and
// every answer lands in the decision log. The wire shape is TypeSafe's `/v1/systemone` — `state` plus
// typed `questions` — and the types below are the subset Curfew uses.

public enum JevQuestionKind: String, Sendable, Codable {
    case choice
    case noul
    case score
}

/// One typed question. `task` is the wire's `instructions`; `labels` are a choice's options;
/// `descriptions` carries the rubrics (and, for a noul, the `true`/`false` criteria — the pattern's own
/// requirement that a `false` says concretely what a no looks like).
public struct JevQuestion: Sendable, Equatable {
    public var id: String
    public var kind: JevQuestionKind
    public var task: String
    public var labels: [String]
    public var descriptions: [String: String]

    public init(
        id: String, kind: JevQuestionKind, task: String,
        labels: [String] = [], descriptions: [String: String] = [:]
    ) {
        self.id = id
        self.kind = kind
        self.task = task
        self.labels = labels
        self.descriptions = descriptions
    }
}

public enum JevAnswer: Sendable, Equatable {
    case choice(label: String, probabilities: [String: Double], confidence: Double)
    case noul(Double)
    case score(Double, legend: [String: String]?)
    /// The response did not carry what the question asked for. Never silently coerced.
    case malformed(String)

    public var label: String? {
        if case .choice(let label, _, _) = self { return label }
        return nil
    }

    public var noul: Double? {
        if case .noul(let p) = self { return p }
        return nil
    }
}

/// How much to trust one answer. Distribution-shape, not max-probability: for a choice the margin
/// between the top two options is what separates a decision from a coin-flip, and for a `noul` the
/// distance from 0.5 is the only signal there is (a noul carries no separate confidence).
public enum Confidence: Sendable, Equatable {
    case confident
    case marginal
    case unknown
}

public struct ConfidencePolicy: Sendable, Equatable {
    public var floor: Double
    public var marginFloor: Double

    /// Owner ruling 2026-11-25: 0.70 / 0.20 — stricter than the measurement suggested (0.60/0.15),
    /// which is the right way round. A tighter floor costs a few more human reviews and buys margin
    /// against the failure that matters.
    public static let `default` = ConfidencePolicy(floor: 0.70, marginFloor: 0.20)

    public init(floor: Double, marginFloor: Double) {
        self.floor = floor
        self.marginFloor = marginFloor
    }

    public func classify(_ answer: JevAnswer) -> Confidence {
        switch answer {
        case .malformed:
            return .unknown
        case .choice(_, let probabilities, let confidence):
            guard confidence >= floor else { return .marginal }
            return margin(of: Array(probabilities.values)) >= marginFloor ? .confident : .marginal
        case .noul(let p):
            // A noul's value is its own probability; there is no separate confidence to compare to
            // a floor, so the only honest test is distance from a coin-flip.
            return abs(p - 0.5) * 2 >= marginFloor ? .confident : .marginal
        case .score(let position, _):
            // The position is a level, not a probability; treat a whole-number landing as decisive
            // and anything between levels as a close call.
            return abs(position - position.rounded()) <= 0.25 ? .confident : .marginal
        }
    }

    private func margin(of values: [Double]) -> Double {
        let sorted = values.sorted(by: >)
        guard sorted.count >= 2 else { return 1 }
        return sorted[0] - sorted[1]
    }
}

/// One HTTP round-trip, injected so tests never touch the network.
public protocol JevTransport: Sendable {
    /// Returns the status and body. Throwing is a transport failure; a non-200 status is the server
    /// refusing, and both end up as `unknown` rather than as an answer.
    func post(_ body: Data) throws -> (status: Int, body: Data)
}

public enum JevError: Error, Equatable, CustomStringConvertible {
    case missingKey(String)
    case transport(String)
    case refused(status: Int, body: String)
    case malformed(String)

    public var description: String {
        switch self {
        case .missingKey(let path): return "no Jev key at \(path) — nothing was sent"
        case .transport(let message): return "transport failed: \(message)"
        case .refused(let status, let body): return "Jev answered \(status): \(body.prefix(200))"
        case .malformed(let message): return "malformed response: \(message)"
        }
    }
}

public struct JevClient: Sendable {
    public var model: String
    public var policy: ConfidencePolicy
    private let transport: JevTransport

    public init(transport: JevTransport, model: String = "jev-1.14", policy: ConfidencePolicy = .default) {
        self.transport = transport
        self.model = model
        self.policy = policy
    }

    /// The key lives in a 0600 file, never in a flag, an environment variable or the journal (rule 8).
    public static func keyFile() -> URL {
        if let override = ProcessInfo.processInfo.environment["CURFEW_JEV_KEY"] {
            return URL(fileURLWithPath: override)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/curfew/jev.key")
    }

    public static func liveClient() throws -> JevClient {
        let keyURL = keyFile()
        guard let key = try? String(contentsOf: keyURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else {
            throw JevError.missingKey(keyURL.path)
        }
        let raw = ProcessInfo.processInfo.environment["CURFEW_JEV_URL"]
            ?? "https://opencode.ai/inference/go/systemone/v1/systemone"
        guard let url = URL(string: raw) else { throw JevError.transport("bad CURFEW_JEV_URL") }
        let model = ProcessInfo.processInfo.environment["CURFEW_JEV_MODEL"] ?? "jev-1.14"
        return JevClient(transport: JevHTTPTransport(url: url, apiKey: key), model: model)
    }

    /// One request, many typed questions — the speculative fan-out the docs recommend: all questions
    /// evaluate in parallel, so asking four costs about what asking one does.
    public func ask(_ questions: [JevQuestion], state: String) throws -> [String: JevAnswer] {
        let body = try encode(questions: questions, state: state)
        let response: (status: Int, body: Data)
        do {
            response = try transport.post(body)
        } catch {
            throw JevError.transport(String(describing: error))
        }
        guard response.status == 200 else {
            throw JevError.refused(
                status: response.status,
                body: String(decoding: response.body.prefix(400), as: UTF8.self)
            )
        }
        return try decode(response.body, questions: questions)
    }

    // MARK: Wire

    func encode(questions: [JevQuestion], state: String) throws -> Data {
        var wireQuestions: [String: Any] = [:]
        for question in questions {
            var one: [String: Any] = ["type": question.kind.rawValue, "instructions": question.task]
            switch question.kind {
            case .choice:
                if question.descriptions.isEmpty {
                    one["criteria"] = question.labels
                } else {
                    // label → rubric, which is the shape the docs use for option descriptions
                    one["criteria"] = question.labels.reduce(into: [String: String]()) { acc, label in
                        acc[label] = question.descriptions[label] ?? label
                    }
                }
            case .noul:
                one["criteria"] = question.descriptions.isEmpty
                    ? ["true": "yes", "false": "no"]
                    : question.descriptions
            case .score:
                one["criteria"] = question.labels
            }
            wireQuestions[question.id] = one
        }
        let payload: [String: Any] = ["model": model, "state": state, "questions": wireQuestions]
        guard JSONSerialization.isValidJSONObject(payload) else {
            throw JevError.malformed("questions did not serialise")
        }
        return try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
    }

    func decode(_ data: Data, questions: [JevQuestion]) throws -> [String: JevAnswer] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let answers = root["answers"] as? [String: Any] else {
            throw JevError.malformed("no answers object")
        }
        var out: [String: JevAnswer] = [:]
        for question in questions {
            guard let raw = answers[question.id] as? [String: Any] else {
                out[question.id] = .malformed("no answer for \(question.id)")
                continue
            }
            switch question.kind {
            case .choice:
                // The wire calls it `choice`; `label` is accepted too so a variant spelling does not
                // silently turn every answer into malformed — which is exactly how this was found.
                guard let label = (raw["choice"] as? String) ?? (raw["label"] as? String) else {
                    out[question.id] = .malformed("choice answer carries neither 'choice' nor 'label'")
                    continue
                }
                let probabilities = (raw["probabilities"] as? [String: Double]) ?? [:]
                let confidence = (raw["confidence"] as? Double) ?? 0
                out[question.id] = .choice(label: label, probabilities: probabilities, confidence: confidence)
            case .noul:
                guard let value = raw["noul"] as? Double else {
                    out[question.id] = .malformed("noul answer has no value")
                    continue
                }
                out[question.id] = .noul(value)
            case .score:
                guard let position = raw["score"] as? Double else {
                    out[question.id] = .malformed("score answer has no position")
                    continue
                }
                out[question.id] = .score(position, legend: raw["legend"] as? [String: String])
            }
        }
        return out
    }
}
