import Foundation

/// The respawn-rate tracker (KI-040): the crash-loop rule can only see a job that is *not* running at
/// scan time, because launchd keeps a previous run's exit code and a healthy job would otherwise look
/// broken. That guard is right, but it hides a fast loop — a job restarting every few seconds is almost
/// always observed either briefly running (excluded) or between runs.
///
/// The honest answer is not a bigger threshold; it is a **delta**. Sample `runs` per label, compare with
/// the previous sample, and flag a job whose restarts per hour climb, whatever its instant state is.
public struct RespawnSample: Codable, Sendable, Equatable {
    public var runs: UInt64
    public var at: String

    public init(runs: UInt64, at: String) {
        self.runs = runs
        self.at = at
    }
}

public struct RespawnDelta: Sendable, Equatable {
    public var label: String
    /// Restarts between the two samples.
    public var delta: UInt64
    /// Wall time between the two samples, in hours.
    public var hours: Double
    public var runs: UInt64
    public var state: JobState

    public var ratePerHour: Double { hours > 0 ? Double(delta) / hours : Double(delta) }
}

public final class RespawnTracker: @unchecked Sendable {
    public let url: URL
    private let now: @Sendable () -> Date

    /// A single restart in a long gap is not a loop.
    public static let minimumDelta: UInt64 = 3
    /// Ten restarts an hour is already abnormal; a throttled crash loop runs at hundreds.
    public static let minimumRatePerHour: Double = 10
    /// `runs` over a few seconds is noise, not a rate. Measured 2026-11-26: two scans minutes apart made
    /// eight Apple XPC daemons look like 100,000-restarts-an-hour loops.
    public static let minimumIntervalHours: Double = 5.0 / 60
    /// launchd throttles a real crash loop to about one restart per `ThrottleInterval` (10 s), so ~360/h
    /// is its ceiling. Above that, `runs` is counting **activations**, not restarts — the trap KI-007
    /// documents, and the reason this bound exists rather than a bigger threshold.
    public static let maximumRatePerHour: Double = 600

    public init(url: URL = RespawnTracker.defaultURL, now: @escaping @Sendable () -> Date = { Date() }) {
        self.url = url
        self.now = now
    }

    public static var defaultURL: URL {
        if let override = ProcessInfo.processInfo.environment["CURFEW_RUNS_STATE"] {
            return URL(fileURLWithPath: override)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Curfew/runs.json")
    }

    // MARK: State

    public func load() -> [String: RespawnSample] {
        guard let data = try? Data(contentsOf: url),
              let samples = try? JSONDecoder().decode([String: RespawnSample].self, from: data)
        else { return [:] }
        return samples
    }

    public func save(_ samples: [String: RespawnSample]) throws {
        let directory = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(samples)
        try data.write(to: url, options: .atomic)
    }

    // MARK: Scanning

    /// Compare this scan with the previous one. Returns the deltas worth reporting **and** the samples
    /// to persist — the caller must save them even when nothing fired, or the baseline never advances.
    public func scan(
        _ records: [ServiceRecord],
        minimumDelta: UInt64 = RespawnTracker.minimumDelta,
        minimumRatePerHour: Double = RespawnTracker.minimumRatePerHour
    ) -> (deltas: [RespawnDelta], samples: [String: RespawnSample]) {
        let previous = load()
        let moment = now()
        let iso = Self.iso(moment)
        var samples: [String: RespawnSample] = [:]
        var deltas: [RespawnDelta] = []

        for record in records {
            guard let runs = record.runs else { continue }
            samples[record.id] = RespawnSample(runs: runs, at: iso)

            // Only a job launchd actually supervises can be *respawned*: a `KeepAlive: never` job's
            // `runs` counts activations, and every on-demand XPC service on this machine climbs by
            // hundreds. Measured: the four false positives had keepAlive never and no exit code, while
            // the true crash loop had keepAlive always and exit 1.
            guard record.keepAlive != .never else { continue }
            // A crashing job exits non-zero. An activation-counted one has no exit code at all.
            guard let exit = record.lastExitCode, exit != 0 else { continue }

            guard let before = previous[record.id],
                  let previousAt = parseJournalTimestamp(before.at),
                  runs > before.runs
            else { continue }

            let delta = runs - before.runs
            let hours = moment.timeIntervalSince(previousAt) / 3600
            guard hours >= Self.minimumIntervalHours else { continue }
            let rate = Double(delta) / hours
            guard delta >= minimumDelta,
                  rate >= minimumRatePerHour,
                  rate <= Self.maximumRatePerHour
            else { continue }

            deltas.append(RespawnDelta(
                label: record.id, delta: delta, hours: hours, runs: runs, state: record.state))
        }

        return (deltas.sorted { $0.ratePerHour > $1.ratePerHour }, samples)
    }

    public static func finding(for delta: RespawnDelta) -> Finding {
        Finding(
            id: .respawnRate,
            severity: .defect,
            summary: "\(delta.label) restarted \(delta.delta)× in \(format(hours: delta.hours)) "
                + "(\(Int(delta.ratePerHour))/h) — it is looping even while it runs",
            evidence: "runs \(delta.runs), +\(delta.delta) in \(format(hours: delta.hours)), "
                + "state \(delta.state.rawValue), measured against the previous scan",
            confirmsScan: true
        )
    }

    static func format(hours: Double) -> String {
        if hours < 1 { return "\(Int((hours * 60).rounded())) min" }
        if hours < 24 { return String(format: "%.1f h", hours) }
        return String(format: "%.1f d", hours / 24)
    }

    static func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}
