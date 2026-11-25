import Foundation

/// Findings ranking (L7.4): one `score` per finding, one request, ordering only.
///
/// **Severity labels are not touched.** Those are mechanical rules and stay so (D27); this only reorders
/// what `doctor` prints, so the thing that actually matters to the machine surfaces first. If the model
/// cannot be asked, the order is the one it would have had — never an empty list.
public struct RankedFinding: Sendable, Equatable {
    public var finding: FindingReport
    /// 1–5 from the score head; nil when the model gave nothing usable for this one.
    public var impact: Double?
    /// Its position before ranking, so ties keep the order the findings engine produced.
    public var original: Int
}

public enum FindingsRanker {

    /// The rubric, lowest first — a `score`'s criteria is an ordered array of level descriptions.
    public static let levels = [
        "cosmetic: nobody notices, nothing changes behaviour",
        "housekeeping: a stale or dead entry that only matters when someone looks",
        "degraded: something is not working as intended but work continues",
        "costly: it wastes real time, memory or disk on every use",
        "harmful: it can break work, lose data, or mislead about the machine's state",
    ]

    public static let perRequest = 20

    /// One score head per finding. Asked together: all questions in a request evaluate in parallel.
    public static func questions(range: Range<Int>) -> [JevQuestion] {
        range.map { index in
            JevQuestion(
                id: "f\(index)", kind: .score,
                task: "How much does finding f\(index) actually hurt this machine? Judge the consequence, not how it sounds.",
                labels: levels
            )
        }
    }

    /// The findings, as JSON — the evidence and the summary, because a finding's weight is in its detail.
    public static func state(_ findings: [FindingReport]) -> String {
        let items: [[String: Any]] = findings.enumerated().map { index, finding in
            var one: [String: Any] = [
                "key": "f\(index)",
                "label": finding.label ?? "?",
                "kind": finding.id,
                "severity": finding.severity,
                "summary": finding.summary,
                "evidence": finding.evidence,
            ]
            if let domain = finding.domain { one["domain"] = domain }
            return one
        }
        guard let data = try? JSONSerialization.data(withJSONObject: items, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return text
    }

    /// Order by impact, ties by the engine's own order, unscored last in their original order.
    public static func order(_ findings: [FindingReport], impacts: [Int: Double]) -> [RankedFinding] {
        findings.enumerated()
            .map { RankedFinding(finding: $0.element, impact: impacts[$0.offset], original: $0.offset) }
            .sorted { left, right in
                switch (left.impact, right.impact) {
                case let (l?, r?) where l != r: return l > r
                case (nil, _?): return false      // unscored sorts after every scored finding
                case (_?, nil): return true
                default: return left.original < right.original
                }
            }
    }
}

public struct FindingsRunner: Sendable {
    public var client: JevClient
    public var log: DecisionLog

    public init(client: JevClient, log: DecisionLog = DecisionLog()) {
        self.client = client
        self.log = log
    }

    /// Ranks what it can. A model failure leaves the caller's order intact rather than returning
    /// nothing — `doctor` must still report when the network is down (D29).
    public func rank(_ findings: [FindingReport]) -> (ranked: [RankedFinding], note: String?) {
        guard !findings.isEmpty else { return ([], nil) }
        let state = FindingsRanker.state(findings)
        var impacts: [Int: Double] = [:]
        var firstFailure: String?

        var start = 0
        while start < findings.count {
            let end = min(start + FindingsRanker.perRequest, findings.count)
            let range = start..<end
            do {
                let answers = try client.ask(FindingsRanker.questions(range: range), state: state)
                for index in range {
                    if case .score(let position, _)? = answers["f\(index)"] { impacts[index] = position }
                }
                try? log.append(log.makeRow(
                    model: client.model, surface: "rank", subject: nil, state: state,
                    questions: FindingsRanker.questions(range: range), answers: answers,
                    decision: "ranked \(range.count)", confidence: .confident))
            } catch {
                // Keep whatever earlier chunks scored; the rest stay unranked and visible.
                firstFailure = firstFailure ?? String(describing: error)
                try? log.append(log.makeRow(
                    model: client.model, surface: "rank", subject: nil, state: state,
                    questions: FindingsRanker.questions(range: range), answers: [:],
                    decision: "unavailable", confidence: .unknown))
            }
            start = end
        }

        let ranked = FindingsRanker.order(findings, impacts: impacts)
        if let firstFailure {
            return (ranked, "ranking unavailable (\(firstFailure)) — the order is the usual one")
        }
        let unscored = ranked.filter { $0.impact == nil }.count
        if unscored > 0 {
            return (ranked, "\(unscored) finding(s) came back unscored — shown last")
        }
        // Report the observed range instead of guessing whether the ranking "means" anything. Two
        // runs of the same 17 findings scored the top one 1.9 and then 2.1 — a threshold tuned to one
        // sample would be a lie, and the reader can judge a range far better than a heuristic can.
        let scored = ranked.compactMap(\.impact)
        if let low = scored.min(), let high = scored.max() {
            return (ranked, String(format: "impact range %.1f–%.1f of 5 across %d findings", low, high, scored.count))
        }
        return (ranked, nil)
    }
}
