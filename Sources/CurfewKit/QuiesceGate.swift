import Foundation

/// The quiesce screen (L7.3): one yes/no question before a stop, and it can only narrow (D27).
///
/// It runs **after** every deterministic refusal, never instead of one. Its three exits are the docs'
/// noul-screen pattern: a clear "in use" refuses, an unsettled answer refuses too (a stop that drops a
/// client is worse than a stop that waits), and a clear "idle" simply lets the existing checks proceed.
///
/// It only applies where the catalogue already says a quiesce concern exists — an entry with a
/// `quiesce:` probe. Today that is no entry at all, which is correct: the acting entries are updaters
/// and launchers with no clients, and asking a model about them would add latency for an answer that is
/// always idle.
public enum QuiesceVerdict: Sendable, Equatable {
    /// Nothing is using it; the ordinary checks may proceed.
    case idle(Double)
    /// Something is using it — refuse.
    case busy(Double)
    /// The answer did not settle it — refuse unless the caller allows it.
    case unsettled(Double)
    /// The model could not be asked. Never treated as idle.
    case unavailable(String)

    public var probability: Double? {
        switch self {
        case .idle(let p), .busy(let p), .unsettled(let p): return p
        case .unavailable: return nil
        }
    }
}

public struct QuiesceGate: Sendable {
    /// What counts as "in use" and "clearly idle". 0.65/0.35 leaves a band that refuses.
    public var busyFloor: Double
    public var idleFloor: Double
    private let ask: @Sendable (String) throws -> JevAnswer

    public init(
        busyFloor: Double = 0.65, idleFloor: Double = 0.35,
        ask: @escaping @Sendable (String) throws -> JevAnswer
    ) {
        self.busyFloor = busyFloor
        self.idleFloor = idleFloor
        self.ask = ask
    }

    /// A gate backed by a real client. The state is the service plus what it is *currently* doing — the
    /// evidence that matters and that a label alone cannot carry (the lesson from L7.2).
    public static func live(client: JevClient) -> QuiesceGate {
        QuiesceGate { state in
            let answer = try client.ask([question()], state: state)
            return answer["in_use"] ?? .malformed("no answer")
        }
    }

    public static func question() -> JevQuestion {
        JevQuestion(
            id: "in_use", kind: .noul,
            task: "Is this background service being used right now — would stopping it interrupt work, drop a connection, or cancel something in progress?",
            descriptions: [
                "true": "a client is connected, a build or job is running, or a person is actively using it this minute",
                "false": "nothing is using it: it is an idle updater, a launcher between runs, or a daemon with no clients",
            ]
        )
    }

    /// The evidence string handed to the model. Deliberately concrete: ports, connections, state.
    public static func state(
        entry: CatalogEntry, record: ServiceRecord?, listeners: [Listener], connections: [UInt16: Int]
    ) -> String {
        var fields: [String: Any] = ["label": entry.id, "kind": entry.kind.rawValue,
                                     "supervised": entry.supervised.rawValue]
        if let record {
            fields["state"] = record.state.rawValue
            if let pid = record.pid { fields["pid"] = pid }
            if let runs = record.runs { fields["runs"] = runs }
        }
        let ports = listeners.filter { $0.port > 0 }.map(\.port)
        fields["listening_ports"] = ports.map { Int($0) }
        // JSONSerialization needs string keys; a [UInt16: Int] dictionary is not a JSON object.
        fields["established_connections"] = Dictionary(uniqueKeysWithValues: connections.map { (String($0.key), $0.value) })
        fields["connection_total"] = connections.values.reduce(0, +)
        fields["quiesce_concern"] = entry.stop?.quiesce ?? "none declared"
        guard let data = try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return "label=\(entry.id)"
        }
        return text
    }

    public func evaluate(_ state: String) -> QuiesceVerdict {
        do {
            let answer = try ask(state)
            guard let p = answer.noul else { return .unavailable("answer was not a noul") }
            if p >= busyFloor { return .busy(p) }
            if p <= idleFloor { return .idle(p) }
            return .unsettled(p)
        } catch {
            return .unavailable(String(describing: error))
        }
    }
}

public enum QuiesceMode: String, Sendable {
    /// Ask only where the entry declares a `quiesce:` probe.
    case auto
    /// Never ask.
    case off
    /// Ask everywhere — for a trial, not for daily use.
    case always

    public static func fromEnvironment(_ raw: String?) -> QuiesceMode {
        switch raw?.lowercased() {
        case "1", "on", "true", "always": return .always
        case "0", "off", "false", "never": return .off
        default: return .auto
        }
    }

    public func applies(to entry: CatalogEntry) -> Bool {
        switch self {
        case .off: return false
        case .always: return true
        case .auto: return entry.stop?.quiesce != nil
        }
    }
}
