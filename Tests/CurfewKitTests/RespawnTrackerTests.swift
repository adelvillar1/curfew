import Foundation
import Testing
@testable import CurfewKit

/// KI-040 — the respawn-rate tracker. The crash-loop rule cannot see a job that loops *while it is
/// running*; this compares `runs` between scans instead, so a fast loop shows up as a rate.
@Suite("Respawn rate")
struct RespawnTrackerTests {

    func tempState() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("curfew-runs-\(UUID().uuidString).json")
    }

    func record(
        _ id: String, runs: UInt64?, state: JobState = .running,
        exit: Int32? = 1, keepAlive: KeepAliveMode = .always
    ) -> ServiceRecord {
        ServiceRecord(
            id: id, domain: "gui/501", plistPath: "/tmp/\(id).plist", state: state, pid: 1,
            runs: runs, lastExitCode: exit, program: "/bin/true", keepAlive: keepAlive,
            tier: .thirdParty, kind: .agent, supervised: .launchd
        )
    }

    func tracker(_ url: URL, at date: Date) -> RespawnTracker {
        RespawnTracker(url: url, now: { date })
    }

    // MARK: Baseline

    @Test("the first scan only sets a baseline — nothing is flagged")
    func firstScanIsABaseline() throws {
        let url = tempState()
        defer { try? FileManager.default.removeItem(at: url) }
        let (deltas, samples) = tracker(url, at: Date()).scan([record("a", runs: 27_010)])
        #expect(deltas.isEmpty)
        #expect(samples["a"]?.runs == 27_010)
    }

    @Test("the samples are what persist, and they survive a new instance")
    func statePersists() throws {
        let url = tempState()
        defer { try? FileManager.default.removeItem(at: url) }
        let t0 = Date()
        let first = tracker(url, at: t0)
        let (_, samples) = first.scan([record("a", runs: 100)])
        try first.save(samples)

        let second = tracker(url, at: t0.addingTimeInterval(600))
        #expect(second.load()["a"]?.runs == 100)
    }

    // MARK: The rule

    @Test("a fast loop while the job is RUNNING is caught — the case the crash-loop rule misses")
    func catchesRanWhileRunning() throws {
        let url = tempState()
        defer { try? FileManager.default.removeItem(at: url) }
        let t0 = Date()
        let first = tracker(url, at: t0)
        try first.save(first.scan([record("looper", runs: 27_000)]).samples)

        // 100 restarts in 30 minutes = 200/h, observed running the whole time
        let second = tracker(url, at: t0.addingTimeInterval(1800))
        let (deltas, _) = second.scan([record("looper", runs: 27_100, state: .running)])

        #expect(deltas.count == 1)
        #expect(deltas.first?.delta == 100)
        #expect(abs((deltas.first?.ratePerHour ?? 0) - 200) < 1, "≈200/h")
    }

    @Test("a restart or two is not a loop")
    func smallDeltaIgnored() throws {
        let url = tempState()
        defer { try? FileManager.default.removeItem(at: url) }
        let t0 = Date()
        let first = tracker(url, at: t0)
        try first.save(first.scan([record("a", runs: 10)]).samples)

        let second = tracker(url, at: t0.addingTimeInterval(3600))
        // 2 restarts in an hour: below the floor of 3
        let (deltas, _) = second.scan([record("a", runs: 12)])
        #expect(deltas.isEmpty)
    }

    @Test("a job launchd does not supervise is never flagged — its runs are activations")
    func unsupervisedExcluded() throws {
        let url = tempState()
        defer { try? FileManager.default.removeItem(at: url) }
        let t0 = Date()
        let first = tracker(url, at: t0)
        // the shape measured on this machine: keepAlive never, hundreds of "runs", no exit code
        try first.save(first.scan([record("xpc", runs: 400, exit: nil, keepAlive: .never)]).samples)
        let (deltas, _) = tracker(url, at: t0.addingTimeInterval(1800))
            .scan([record("xpc", runs: 1_200, exit: nil, keepAlive: .never)])
        #expect(deltas.isEmpty)
    }

    @Test("a job with no exit code is not a crash loop")
    func noExitCodeExcluded() throws {
        let url = tempState()
        defer { try? FileManager.default.removeItem(at: url) }
        let t0 = Date()
        let first = tracker(url, at: t0)
        try first.save(first.scan([record("a", runs: 100, exit: nil)]).samples)
        let (deltas, _) = tracker(url, at: t0.addingTimeInterval(1800))
            .scan([record("a", runs: 500, exit: nil)])
        #expect(deltas.isEmpty)
    }

    @Test("churn above launchd's throttle ceiling is activations, not a loop")
    func activationChurnExcluded() throws {
        let url = tempState()
        defer { try? FileManager.default.removeItem(at: url) }
        let t0 = Date()
        let first = tracker(url, at: t0)
        try first.save(first.scan([record("busy", runs: 700)]).samples)
        // +800 in 10 minutes = 4,800/h — far above the ~360/h a throttled loop can manage
        let (deltas, _) = tracker(url, at: t0.addingTimeInterval(600))
            .scan([record("busy", runs: 1_500)])
        #expect(deltas.isEmpty)
    }

    @Test("a sample taken seconds ago is not a rate")
    func tooSoonExcluded() throws {
        let url = tempState()
        defer { try? FileManager.default.removeItem(at: url) }
        let t0 = Date()
        let first = tracker(url, at: t0)
        try first.save(first.scan([record("a", runs: 100)]).samples)
        let (deltas, _) = tracker(url, at: t0.addingTimeInterval(20))
            .scan([record("a", runs: 400)])
        #expect(deltas.isEmpty, "20 seconds of runs is noise, not a rate")
    }

    @Test("many restarts spread over days are not a loop")
    func lowRateIgnored() throws {
        let url = tempState()
        defer { try? FileManager.default.removeItem(at: url) }
        let t0 = Date()
        let first = tracker(url, at: t0)
        try first.save(first.scan([record("a", runs: 100)]).samples)

        // 20 restarts over 5 days = 0.17/h
        let second = tracker(url, at: t0.addingTimeInterval(5 * 24 * 3600))
        let (deltas, _) = second.scan([record("a", runs: 120)])
        #expect(deltas.isEmpty)
    }

    @Test("runs that did not advance produce nothing, even with a stale sample")
    func unchangedRuns() throws {
        let url = tempState()
        defer { try? FileManager.default.removeItem(at: url) }
        let t0 = Date()
        let first = tracker(url, at: t0)
        try first.save(first.scan([record("a", runs: 500)]).samples)
        let (deltas, _) = tracker(url, at: t0.addingTimeInterval(600)).scan([record("a", runs: 500)])
        #expect(deltas.isEmpty)
    }

    @Test("a job with no runs recorded is skipped, not assumed")
    func noRunsSkipped() throws {
        let url = tempState()
        defer { try? FileManager.default.removeItem(at: url) }
        let (deltas, samples) = tracker(url, at: Date()).scan([record("a", runs: nil)])
        #expect(deltas.isEmpty)
        #expect(samples.isEmpty)
    }

    // MARK: The finding

    @Test("the finding says the rate and names the state, so a running loop is legible")
    func findingText() {
        let delta = RespawnDelta(label: "com.example.looper", delta: 100, hours: 1.0 / 6,
                                 runs: 27_100, state: .running)
        let finding = RespawnTracker.finding(for: delta)
        #expect(finding.id == .respawnRate)
        #expect(finding.severity == .defect)
        #expect(finding.summary.contains("100×"))
        #expect(finding.summary.contains("600/h"))
        #expect(finding.summary.contains("even while it runs"))
        #expect(finding.evidence.contains("state running"))
    }
}
