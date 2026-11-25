import Foundation

/// Catalog triage by decision model (L7.2, D27, D29).
///
/// The model proposes a disposition for a service Curfew does not yet know. **The rule that turns its
/// answers into a proposal is deterministic code, not the model's label** — that is the whole point of
/// the measurement in `docs/research/tooling-jev.md`: the disposition under-protects infrastructure,
/// while the two nouls do not.
///
/// Nothing here acts. The output is a `draft` entry, and a draft cannot be applied (rule 5).

public enum ProposeDecision: String, Sendable, Equatable {
    case stop
    case protect
    case never
    /// The answers did not settle it — a human decides. Never silently coerced into a label.
    case review
}

public struct Proposal: Sendable, Equatable {
    public var id: String
    public var decision: ProposeDecision
    public var confidence: Confidence
    public var answers: [String: JevAnswer]
    /// Why the decision came out that way, in the order the rule applied.
    public var reasons: [String]
    public var model: String
    public var timestamp: String

    public var disposition: JevAnswer? { answers["disposition"] }
    public var infrastructure: Double? { answers["is_infrastructure"]?.noul }
    public var stateToLose: Double? { answers["has_state_to_lose"]?.noul }
}

public enum Proposer {

    public static let choiceLabels = ["stop", "protect", "never"]

    /// The four questions, asked in one request. All evaluate in parallel, so this costs about what one
    /// question does (the speculative fan-out the docs recommend).
    public static func questions() -> [JevQuestion] {
        [
            JevQuestion(
                id: "disposition", kind: .choice,
                task: "Should Curfew stop this background service when the machine goes into quiet mode, keep it running, or never touch it?",
                labels: choiceLabels,
                descriptions: [
                    "stop": "quieting it is safe and reversible: an updater, a telemetry reporter, a login launcher nobody is using",
                    "protect": "stopping it costs real work or state: a database, a model server, a file watcher, or an endpoint in-flight work depends on",
                    "never": "operating-system critical: stopping it can break the machine or the session",
                ]
            ),
            JevQuestion(
                id: "is_infrastructure", kind: .noul,
                task: "Is this service infrastructure that other software depends on, rather than something that only serves the person using the machine?",
                descriptions: [
                    "true": "a server, daemon, proxy, model host or VM manager: other programs call it or depend on it running",
                    "false": "an updater, telemetry reporter, login launcher or sync helper: it serves the human user, not other software",
                ]
            ),
            JevQuestion(
                id: "has_state_to_lose", kind: .noul,
                task: "Would stopping this service lose work, data, or an open connection that something is using right now?",
                descriptions: [
                    "true": "an open database, unsaved work, a live session, or clients currently connected",
                    "false": "nothing is in flight that a stop would destroy; it can be started again later",
                ]
            ),
            JevQuestion(
                id: "disruption", kind: .score,
                task: "How disruptive would stopping this service right now be?",
                labels: [
                    "invisible: nothing notices",
                    "minor: a small delay later",
                    "noticeable: someone has to restart something",
                    "costly: minutes of reloading or re-indexing",
                    "disruptive: breaks work in progress or stops the machine working",
                ]
            ),
        ]
    }

    /// The deterministic rule over the model's answers (D27).
    ///
    /// Infrastructure or state-to-lose overrides the disposition, because that is the failure the
    /// measurement actually found: `blend1-service` and `kiri.daemon` were called `stop` from their
    /// labels, and correctly called `protect` once their sockets were visible.
    public static func decide(_ answers: [String: JevAnswer], policy: ConfidencePolicy = .default)
        -> (ProposeDecision, Confidence, [String]) {
        var reasons: [String] = []

        let confidence: Confidence
        if let disposition = answers["disposition"] {
            confidence = policy.classify(disposition)
        } else {
            confidence = .unknown
        }

        if let infrastructure = answers["is_infrastructure"]?.noul, infrastructure >= 0.5 {
            reasons.append("is_infrastructure=\(format(infrastructure)) ≥ 0.50 → protect")
            return (.protect, confidence, reasons)
        }
        if let state = answers["has_state_to_lose"]?.noul, state >= 0.5 {
            reasons.append("has_state_to_lose=\(format(state)) ≥ 0.50 → protect")
            return (.protect, confidence, reasons)
        }

        guard case .choice(let label, _, _)? = answers["disposition"],
              let decision = ProposeDecision(rawValue: label) else {
            reasons.append("no usable disposition → review")
            return (.review, .unknown, reasons)
        }
        guard confidence == .confident else {
            reasons.append("disposition=\(label) but \(name(confidence)) under the floor → review")
            return (.review, confidence, reasons)
        }
        reasons.append("disposition=\(label) at \(name(confidence)) → \(label)")
        return (decision, confidence, reasons)
    }

    // MARK: State

    /// The evidence, as JSON — the docs' structured-state form, and the shape the socket test proved
    /// matters more than any wording.
    public static func state(record: ServiceRecord?, label: String, listeners: [Listener]) -> String {
        var fields: [String: Any] = ["label": label]
        if let record {
            fields["kind"] = record.kind.rawValue
            fields["supervised"] = record.supervised.rawValue
            fields["tier"] = record.tier.rawValue
            fields["state"] = record.state.rawValue
            fields["keep_alive"] = record.keepAlive.rawValue
            if let runs = record.runs { fields["runs"] = runs }
            if let exit = record.lastExitCode { fields["last_exit"] = exit }
            if let vendor = record.vendor { fields["vendor"] = vendor }
            if let program = record.program { fields["program"] = (program as NSString).lastPathComponent }
            if !record.findings.isEmpty {
                fields["findings"] = record.findings.map { "\($0.id.rawValue)/\($0.severity.rawValue)" }
            }
        } else {
            fields["known_to_launchctl"] = false
        }
        let ports = listeners.filter { $0.port > 0 }.map { "\($0.address):\($0.port)" }
        fields["listening"] = ports
        fields["listening_count"] = ports.count

        guard let data = try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys, .prettyPrinted]),
              let text = String(data: data, encoding: .utf8) else {
            return "label=\(label)"
        }
        return text
    }

    // MARK: Rendering

    /// A catalogue snippet, always `draft`. An acting disposition needs a recipe nobody has written, so
    /// it is emitted with the shape and a comment saying exactly that.
    public static func yaml(_ proposal: Proposal, record: ServiceRecord?) -> String {
        let lever = proposal.decision == .stop ? "disable" : "none"
        let stoppable = proposal.decision == .stop ? "" : "\n    stoppable: false"
        let kind = record?.kind.rawValue ?? "agent"
        let supervised = record?.supervised.rawValue ?? "launchd"
        var evidence = "proposed by \(proposal.model) on \(proposal.timestamp): "
        evidence += answersSummary(proposal)
        evidence += " · \(proposal.reasons.joined(separator: "; ")) · draft — no recipe verified, nothing acts on it"

        var hazards: [String] = []
        if let infrastructure = proposal.infrastructure, infrastructure >= 0.5 { hazards.append("socket") }
        if (proposal.stateToLose ?? 0) >= 0.5 { hazards.append("data") }
        if proposal.decision != .stop { hazards.append("always-on") }

        return """
          - id: \(proposal.id)
            kind: \(kind)
            lever: \(lever)
            supervised: \(supervised)
            status: draft\(stoppable)
            hazards: [\(hazards.joined(separator: ", "))]
            evidence: "\(evidence)"
            depends: []
        """
    }

    static func answersSummary(_ proposal: Proposal) -> String {
        let disposition = proposal.disposition?.label ?? "?"
        let confidence: String
        if case .choice(_, _, let value)? = proposal.disposition {
            confidence = format(value)
        } else {
            confidence = "?"
        }
        return "disposition=\(disposition) p=\(confidence), "
            + "is_infrastructure=\(format(proposal.infrastructure)), "
            + "has_state_to_lose=\(format(proposal.stateToLose))"
    }

    static func format(_ value: Double?) -> String {
        guard let value else { return "?" }
        return String(format: "%.2f", value)
    }

    /// For callers outside the module (the CLI prints it).
    public static func confidenceName(_ confidence: Confidence) -> String { name(confidence) }

    static func name(_ confidence: Confidence) -> String {
        switch confidence {
        case .confident: return "confident"
        case .marginal: return "marginal"
        case .unknown: return "unknown"
        }
    }
}

/// Ties the client, the log and the rule together. One call per service.
public struct ProposeRunner: Sendable {
    public var client: JevClient
    public var log: DecisionLog
    public var policy: ConfidencePolicy

    public init(client: JevClient, log: DecisionLog = DecisionLog(), policy: ConfidencePolicy = .default) {
        self.client = client
        self.log = log
        self.policy = policy
    }

    public func propose(record: ServiceRecord?, label: String, listeners: [Listener]) throws -> Proposal {
        // Rule 1 first, and without asking: a never-list label is never a question.
        if NeverList.isProtected(label: label) {
            return Proposal(
                id: label, decision: .never, confidence: .confident, answers: [:],
                reasons: ["on the never-list — no model was asked"], model: client.model,
                timestamp: DecisionLog.iso(Date())
            )
        }

        let state = Proposer.state(record: record, label: label, listeners: listeners)
        let cached = log.cached(model: client.model, state: state, questions: Proposer.questions())
        if let cached, let decision = ProposeDecision(rawValue: cached.decision) {
            return Proposal(
                id: label, decision: decision, confidence: .confident, answers: [:],
                reasons: ["replayed from the decision log — no call was made"],
                model: client.model, timestamp: cached.ts
            )
        }

        let answers = try client.ask(Proposer.questions(), state: state)
        let (decision, confidence, reasons) = Proposer.decide(answers, policy: policy)
        let row = log.makeRow(
            model: client.model, surface: "propose", subject: label, state: state,
            questions: Proposer.questions(), answers: answers,
            decision: decision.rawValue, confidence: confidence
        )
        try? log.append(row)

        return Proposal(
            id: label, decision: decision, confidence: confidence, answers: answers,
            reasons: reasons, model: client.model, timestamp: row.ts
        )
    }
}
