import Foundation

/// The decisions ledger (C16): one appended row per model answer.
///
/// The journal records what Curfew *did*. This records *why a model proposed it* — so a `draft` entry
/// that cites a model is still reviewable six months later, and so a re-run of the same triage is free
/// and byte-identical (D27).
public struct DecisionRow: Codable, Sendable, Equatable {
    public var v: Int
    public var ts: String
    public var model: String
    /// Which surface asked: `propose`, `quiesce`, `rank`.
    public var surface: String
    /// The service the question was about, when there is one.
    public var subject: String?
    public var stateSha: String
    public var questionsSha: String
    /// The raw answers, flattened to strings for a stable, human-readable row.
    public var answers: [String: String]
    /// What the code decided *after* applying the policy — not necessarily the model's label.
    public var decision: String
    public var confidence: String

    public init(
        v: Int = 1, ts: String, model: String, surface: String, subject: String?,
        stateSha: String, questionsSha: String, answers: [String: String],
        decision: String, confidence: String
    ) {
        self.v = v
        self.ts = ts
        self.model = model
        self.surface = surface
        self.subject = subject
        self.stateSha = stateSha
        self.questionsSha = questionsSha
        self.answers = answers
        self.decision = decision
        self.confidence = confidence
    }
}

public final class DecisionLog: @unchecked Sendable {
    public let url: URL
    private let now: @Sendable () -> Date
    private let lock = NSLock()

    public init(url: URL = DecisionLog.defaultURL, now: @escaping @Sendable () -> Date = { Date() }) {
        self.url = url
        self.now = now
    }

    public static var defaultURL: URL {
        if let override = ProcessInfo.processInfo.environment["CURFEW_DECISIONS"] {
            return URL(fileURLWithPath: override)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Curfew/decisions.jsonl")
    }

    // MARK: Hashing — what the cache keys on

    /// Reuses the fingerprint helper the disagreement log already carries — one hash in the codebase,
    /// not two that could drift.
    public static func sha(_ text: String) -> String { SHA1.hex(text) }

    /// `(stateSha, questionsSha)` together identify a request; a hit on both means the same model was
    /// asked the same thing about the same evidence.
    public static func keys(state: String, questions: [JevQuestion]) -> (state: String, questions: String) {
        let canonical = questions.map {
            "\($0.id)|\($0.kind.rawValue)|\($0.task)|\($0.labels.joined(separator: ","))|"
                + $0.descriptions.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ";")
        }.joined(separator: "\n")
        return (sha(state), sha(canonical))
    }

    // MARK: Writing

    public func append(_ row: DecisionRow) throws {
        lock.lock()
        defer { lock.unlock() }
        let directory = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var line = try encoder.encode(row)
        line.append(0x0A)
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: url) else {
            throw JevError.transport("cannot open \(url.path) for the decision log")
        }
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: line)
    }

    public func makeRow(
        model: String, surface: String, subject: String?, state: String, questions: [JevQuestion],
        answers: [String: JevAnswer], decision: String, confidence: Confidence
    ) -> DecisionRow {
        let keys = Self.keys(state: state, questions: questions)
        return DecisionRow(
            ts: Self.iso(now()), model: model, surface: surface, subject: subject,
            stateSha: keys.state, questionsSha: keys.questions,
            answers: answers.mapValues(Self.describe), decision: decision,
            confidence: Self.name(confidence)
        )
    }

    // MARK: Reading — the cache

    public func rows() -> [DecisionRow] {
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else { return [] }
        let decoder = JSONDecoder()
        return text.split(separator: "\n").compactMap { line in
            try? decoder.decode(DecisionRow.self, from: Data(line.utf8))
        }
    }

    /// A previous row for the same model, state and questions — a cache hit, and the reason a re-run is
    /// free. Returns the decision string the code reached, not the model's raw label.
    public func cached(model: String, state: String, questions: [JevQuestion]) -> DecisionRow? {
        let keys = Self.keys(state: state, questions: questions)
        return rows().last {
            $0.model == model && $0.stateSha == keys.state && $0.questionsSha == keys.questions
        }
    }

    // MARK: Formatting

    static func describe(_ answer: JevAnswer) -> String {
        switch answer {
        case .choice(let label, let probabilities, let confidence):
            let spread = probabilities.sorted { $0.value > $1.value }
                .map { "\($0.key)=\(String(format: "%.2f", $0.value))" }
                .joined(separator: ",")
            return "choice:\(label)@\(String(format: "%.2f", confidence)) [\(spread)]"
        case .noul(let p): return "noul:\(String(format: "%.2f", p))"
        case .score(let position, _): return "score:\(String(format: "%.2f", position))"
        case .malformed(let why): return "malformed:\(why)"
        }
    }

    static func name(_ confidence: Confidence) -> String {
        switch confidence {
        case .confident: return "confident"
        case .marginal: return "marginal"
        case .unknown: return "unknown"
        }
    }

    static func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}
