import Foundation
import Testing
@testable import CurfewKit

@Suite("Executor")
struct ExecutorTests {

    /// Records every argv the executor runs, and can read the journal *at call time* — which is how
    /// "intent before action" becomes a test rather than a review note.
    final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var calls: [[String]] = []
        var journalURL: URL?
        private(set) var journalAtCall: [JournalRecord] = []
        var status: Int32 = 0

        func run(_ argv: [String]) -> CommandResult {
            lock.lock()
            calls.append(argv)
            if let url = journalURL { journalAtCall = Journal(url: url).records() }
            lock.unlock()
            return CommandResult(standardOutput: "", standardError: "", status: status)
        }
    }

    func tempJournal() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("curfew-exec-\(UUID().uuidString).jsonl")
    }

    func entry(
        _ id: String = "com.example.job",
        status: EntryStatus = .verified,
        lever: Lever = .disable,
        supervised: Supervision = .launchd,
        stoppable: Bool = true,
        ports: [UInt16] = [],
        root: Bool = false,
        argv: [[String]] = [["/bin/launchctl", "disable", "{domain}/com.example.job"]],
        verify: Verification? = nil,
        hold: Hold = .none,
        start: Recipe? = nil,
        depends: [String] = []
    ) -> CatalogEntry {
        CatalogEntry(
            id: id, kind: .agent, lever: lever, supervised: supervised, status: status,
            stop: Recipe(run: argv, needsRoot: root, expect: nil, quiesce: nil, hold: hold, meansReady: nil, verify: verify),
            start: start, hazards: [], depends: depends,
            evidence: status == .verified ? "2026-11-24 · this Mac · observed" : nil,
            stoppable: stoppable, coldStartCost: nil, ports: ports, file: "test.yaml"
        )
    }

    func catalog(_ entries: [CatalogEntry], bundle: [String]? = nil, kind: BundleKind = .stop, protect: [UInt16] = []) -> Catalog {
        let members = bundle ?? entries.map(\.id)
        return Catalog(
            entries: entries,
            bundles: [CatalogBundle(name: "b", kind: kind, summary: "", protectPorts: protect, members: members, file: "test.yaml")],
            files: ["test.yaml"]
        )
    }

    func probes(
        portOpen: Bool = false, running: Bool = false, pidExists: Bool = false,
        disabled: Bool = false
    ) -> Probes {
        Probes(
            portIsOpen: { _ in portOpen },
            pidExists: { _ in pidExists },
            labelIsRunning: { _ in running },
            labelIsDisabled: { _ in disabled }
        )
    }

    func idleRecord(_ id: String = "com.example.job", state: JobState = .spawnScheduled) -> ServiceRecord {
        ServiceRecord(
            id: id, domain: "gui/501", plistPath: "/tmp/\(id).plist", state: state, pid: nil,
            program: "/bin/true", tier: .thirdParty, kind: .agent, supervised: .launchd
        )
    }

    func context(records: [ServiceRecord] = [], ancestry: Set<Int32> = [999], protect: Set<UInt16> = []) -> ExecutionContext {
        ExecutionContext(domain: "gui/501", records: records, listeners: [], protectedPorts: protect, ownAncestry: ancestry)
    }

    func running(_ id: String, pid: Int32 = 4242) -> ServiceRecord {
        ServiceRecord(
            id: id, domain: "gui/501", plistPath: "/tmp/\(id).plist", state: .running, pid: pid,
            runs: 1, lastExitCode: nil, program: "/bin/true", tier: .thirdParty, kind: .agent, supervised: .launchd
        )
    }

    func stopped(_ id: String) -> ServiceRecord {
        ServiceRecord(
            id: id, domain: "gui/501", plistPath: "/tmp/\(id).plist", state: .notLoaded, pid: nil,
            runs: 1, lastExitCode: 0, program: "/bin/true", tier: .thirdParty, kind: .agent, supervised: .launchd
        )
    }

    // MARK: The ordering guarantees

    @Test("the intent is on disk before the runner is called")
    func intentBeforeAction() throws {
        let url = tempJournal()
        defer { try? FileManager.default.removeItem(at: url) }
        let recorder = Recorder()
        recorder.journalURL = url
        let journal = Journal(url: url)

        let outcomes = Executor(runner: recorder.run, journal: journal, probes: probes())
            .apply(bundle: "b", catalog: catalog([entry()]), context: context(), execute: true)

        #expect(outcomes.first?.result == .executed(verified: true))
        #expect(recorder.calls.count == 1)
        let atCallTime = try #require(recorder.journalAtCall.first)
        #expect(atCallTime.kind == .intent, "the runner ran before the journal recorded the intent")
        #expect(atCallTime.entryId == "com.example.job")
    }

    @Test("an unwritable journal means nothing runs")
    func journalUnwritable() throws {
        let blocker = FileManager.default.temporaryDirectory
            .appendingPathComponent("curfew-block-\(UUID().uuidString)")
        try "x".write(to: blocker, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: blocker) }

        let recorder = Recorder()
        let journal = Journal(url: blocker.appendingPathComponent("journal.jsonl"))
        let outcomes = Executor(runner: recorder.run, journal: journal, probes: probes())
            .apply(bundle: "b", catalog: catalog([entry()]), context: context(), execute: true)

        #expect(recorder.calls.isEmpty, "no journal, no action")
        if case .refused(let reason) = outcomes.first?.result {
            #expect(reason.contains("journal"))
        } else {
            Issue.record("expected a refusal, got \(String(describing: outcomes.first?.result))")
        }
    }

    @Test("a dry run plans without writing or running")
    func dryRun() throws {
        let url = tempJournal()
        defer { try? FileManager.default.removeItem(at: url) }
        let recorder = Recorder()
        let outcomes = Executor(runner: recorder.run, journal: Journal(url: url), probes: probes())
            .apply(bundle: "b", catalog: catalog([entry()]), context: context(), execute: false)

        #expect(outcomes.map(\.result) == [.planned])
        #expect(recorder.calls.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: url.path), "a dry run must leave no journal trace")
    }

    // MARK: Refusals happen before anything is written

    @Test("a draft entry is refused with no journal file created")
    func draftRefused() {
        let url = tempJournal()
        defer { try? FileManager.default.removeItem(at: url) }
        let recorder = Recorder()
        let outcomes = Executor(runner: recorder.run, journal: Journal(url: url), probes: probes())
            .apply(bundle: "b", catalog: catalog([entry(status: .draft)]), context: context(), execute: true)

        #expect(recorder.calls.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        if case .refused = outcomes.first?.result {} else { Issue.record("expected refusal") }
    }

    @Test("a root-requiring recipe is refused and names sudo")
    func rootRefused() {
        let url = tempJournal()
        defer { try? FileManager.default.removeItem(at: url) }
        let recorder = Recorder()
        let outcomes = Executor(runner: recorder.run, journal: Journal(url: url), probes: probes())
            .apply(bundle: "b", catalog: catalog([entry(root: true)]), context: context(), execute: true)

        #expect(recorder.calls.isEmpty)
        if case .refused(let reason) = outcomes.first?.result {
            #expect(reason.contains("sudo"))
        } else {
            Issue.record("expected a refusal naming sudo")
        }
    }

    @Test("a protected port is refused")
    func protectedPortRefused() {
        let url = tempJournal()
        defer { try? FileManager.default.removeItem(at: url) }
        let recorder = Recorder()
        let outcomes = Executor(runner: recorder.run, journal: Journal(url: url), probes: probes())
            .apply(
                bundle: "b", catalog: catalog([entry(ports: [8901])]),
                context: context(protect: [8901]), execute: true
            )

        #expect(recorder.calls.isEmpty)
        if case .refused(let reason) = outcomes.first?.result {
            #expect(reason.contains("8901"))
        } else {
            Issue.record("expected a port refusal")
        }
    }

    @Test("our own process tree is refused")
    func ownAncestryRefused() {
        let url = tempJournal()
        defer { try? FileManager.default.removeItem(at: url) }
        let recorder = Recorder()
        let outcomes = Executor(runner: recorder.run, journal: Journal(url: url), probes: probes())
            .apply(
                bundle: "b", catalog: catalog([entry()]),
                context: context(records: [running("com.example.job", pid: 777)], ancestry: [777]),
                execute: true
            )

        #expect(recorder.calls.isEmpty)
        if case .refused(let reason) = outcomes.first?.result {
            #expect(reason.contains("own process tree"))
        } else {
            Issue.record("expected an ancestry refusal")
        }
    }

    // MARK: Rule 6 — never resurrect what we did not stop

    @Test("a service already stopped is recorded, not acted on")
    func preExisting() {
        let url = tempJournal()
        defer { try? FileManager.default.removeItem(at: url) }
        let recorder = Recorder()
        // A `stop` is what this rule is about: stopping something already stopped changes nothing.
        // A `disable` is different — see disableActsOnIdleJob (KI-048).
        let outcomes = Executor(runner: recorder.run, journal: Journal(url: url), probes: probes())
            .apply(
                bundle: "b", catalog: catalog([entry("com.example.job", lever: .stop)]),
                context: context(records: [stopped("com.example.job")]), execute: true
            )

        #expect(recorder.calls.isEmpty)
        if case .preExisting(let reason) = outcomes.first?.result {
            #expect(reason.contains("before Curfew ran"))
        } else {
            Issue.record("expected pre-existing, got \(String(describing: outcomes.first?.result))")
        }
    }

    // MARK: Verification and hold

    @Test("a failed post-condition marks the entry unverified and lets the run continue")
    func verifyFailsContinues() {
        let url = tempJournal()
        defer { try? FileManager.default.removeItem(at: url) }
        let recorder = Recorder()
        let first = entry("com.example.first", verify: Verification(kind: .portClosed, value: "5432"))
        let second = entry("com.example.second")
        let outcomes = Executor(runner: recorder.run, journal: Journal(url: url), probes: probes(portOpen: true))
            .apply(bundle: "b", catalog: catalog([first, second]), context: context(), execute: true)

        // A bundle of independent entries must not be abandoned because one recipe verifies the wrong
        // thing — that is how thirteen vendor updaters became one (KI-044).
        #expect(outcomes.count == 2, "the run continues past a failed check")
        #expect(outcomes.first?.result == .executed(verified: false))
        #expect(recorder.calls.count == 2)
        #expect(outcomes.last?.entryId == "com.example.second")
    }

    @Test("a passing post-condition verifies")
    func verifyPasses() {
        let url = tempJournal()
        defer { try? FileManager.default.removeItem(at: url) }
        let outcomes = Executor(runner: Recorder().run, journal: Journal(url: url), probes: probes(portOpen: false))
            .apply(
                bundle: "b",
                catalog: catalog([entry(verify: Verification(kind: .portClosed, value: "5432"))]),
                context: context(), execute: true
            )
        #expect(outcomes.first?.result == .executed(verified: true))
    }

    @Test("a respawned job gets a hold bootout, journaled as its own intent")
    func holdBootout() {
        let url = tempJournal()
        defer { try? FileManager.default.removeItem(at: url) }
        let recorder = Recorder()
        let journal = Journal(url: url)
        _ = Executor(runner: recorder.run, journal: journal, probes: probes(running: true))
            .apply(
                bundle: "b",
                catalog: catalog([entry(hold: .bootoutIfRespawned)]),
                context: context(), execute: true
            )

        #expect(recorder.calls.count == 2, "one stop, one hold")
        #expect(recorder.calls.last?.contains("bootout") == true)
        let holdIntents = journal.records().filter { $0.action == "bootout-hold" }
        #expect(holdIntents.count == 1)
    }

    @Test("a job that stays stopped gets no hold")
    func noHold() {
        let url = tempJournal()
        defer { try? FileManager.default.removeItem(at: url) }
        let recorder = Recorder()
        _ = Executor(runner: recorder.run, journal: Journal(url: url), probes: probes(running: false))
            .apply(
                bundle: "b",
                catalog: catalog([entry(hold: .bootoutIfRespawned)]),
                context: context(), execute: true
            )
        #expect(recorder.calls.count == 1)
    }

    // MARK: No shell

    @Test("argv reaches the runner as one array, never a shell string")
    func noShell() {
        let url = tempJournal()
        defer { try? FileManager.default.removeItem(at: url) }
        let recorder = Recorder()
        let nasty = ["/bin/echo", "a; rm -rf /", "b\\c", "$(whoami)"]
        _ = Executor(runner: recorder.run, journal: Journal(url: url), probes: probes())
            .apply(bundle: "b", catalog: catalog([entry(argv: [nasty])]), context: context(), execute: true)

        #expect(recorder.calls.first == nasty, "the metacharacters must arrive as literal arguments")
    }

    @Test("{domain} is substituted and nothing else is")
    func substitution() {
        let executor = Executor(runner: Recorder().run, journal: Journal(url: tempJournal()), probes: probes())
        let ok = executor.substitute([["/bin/launchctl", "bootout", "{domain}/x"]], domain: "gui/501", plist: nil)
        #expect(ok == [["/bin/launchctl", "bootout", "gui/501/x"]])

        let withPlist = executor.substitute(
            [["/bin/launchctl", "bootstrap", "{domain}", "{plist}"]],
            domain: "gui/501", plist: "/Library/LaunchAgents/x.plist"
        )
        #expect(withPlist == [["/bin/launchctl", "bootstrap", "gui/501", "/Library/LaunchAgents/x.plist"]])

        // a recipe that needs the plist cannot be resolved from a guess
        #expect(executor.substitute([["/bin/launchctl", "bootstrap", "{plist}"]], domain: "gui/501", plist: nil) == nil)
        #expect(executor.substitute([["/bin/kill", "{pid}"]], domain: "gui/501", plist: nil) == nil)
    }

    // MARK: Resume

    @Test("resume replays unresolved intents in reverse and skips pre-existing stops")
    func resumeOrder() throws {
        let url = tempJournal()
        defer { try? FileManager.default.removeItem(at: url) }
        let journal = Journal(url: url)
        _ = try journal.appendIntent(entryId: "com.example.a", action: "stop", argv: [["/bin/a"]])
        _ = try journal.appendIntent(
            entryId: "com.example.b", action: "stop", argv: [["/bin/b"]],
            preExisting: "already notLoaded before Curfew ran"
        )
        let recorder = Recorder()
        let catalog = self.catalog([
            entry("com.example.a", start: Recipe(run: [["/bin/a-start"]], needsRoot: false, expect: nil, quiesce: nil, hold: .none, meansReady: nil, verify: nil)),
            entry("com.example.b", start: Recipe(run: [["/bin/b-start"]], needsRoot: false, expect: nil, quiesce: nil, hold: .none, meansReady: nil, verify: nil)),
        ])
        let outcomes = Executor(runner: recorder.run, journal: journal, probes: probes())
            .resume(context: context(), catalog: catalog)

        #expect(recorder.calls == [["/bin/a-start"]], "the pre-existing stop must not be started")
        #expect(outcomes.count == 2)
        #expect(outcomes.contains { $0.entryId == "com.example.b" && $0.result == .preExisting("already notLoaded before Curfew ran") })
    }

    @Test("resume refuses an entry with no start recipe")
    func resumeWithoutStart() throws {
        let url = tempJournal()
        defer { try? FileManager.default.removeItem(at: url) }
        let journal = Journal(url: url)
        _ = try journal.appendIntent(entryId: "com.example.a", action: "stop", argv: [["/bin/a"]])
        let recorder = Recorder()
        let outcomes = Executor(runner: recorder.run, journal: journal, probes: probes())
            .resume(context: context(), catalog: catalog([entry("com.example.a")]))

        #expect(recorder.calls.isEmpty)
        if case .refused(let reason) = outcomes.first?.result {
            #expect(reason.contains("no start recipe"))
        } else {
            Issue.record("expected a refusal")
        }
    }

    @Test("resume with a label restores that service and leaves the others held")
    func resumeOneLabel() throws {
        let url = tempJournal()
        defer { try? FileManager.default.removeItem(at: url) }
        let journal = Journal(url: url)
        for (id, argv) in [("com.example.a", "/bin/a"), ("com.example.b", "/bin/b")] {
            let intent = try journal.appendIntent(entryId: id, action: "stop", argv: [[argv]])
            try journal.appendOutcome(intent: intent, result: "ok", verified: true)
        }
        let recorder = Recorder()
        let catalog = self.catalog([
            entry("com.example.a", start: Recipe(run: [["/bin/a-start"]], needsRoot: false, expect: nil, quiesce: nil, hold: .none, meansReady: nil, verify: nil)),
            entry("com.example.b", start: Recipe(run: [["/bin/b-start"]], needsRoot: false, expect: nil, quiesce: nil, hold: .none, meansReady: nil, verify: nil)),
        ])
        let outcomes = Executor(runner: recorder.run, journal: journal, probes: probes())
            .resume(context: context(), catalog: catalog, labels: ["com.example.a"])

        #expect(recorder.calls == [["/bin/a-start"]], "only the requested service is started")
        #expect(outcomes.count == 1)
        #expect(journal.held().map(\.entryId) == ["com.example.b"], "the other stays held")
    }

    // MARK: The pre-existing guard asks what the lever changes (KI-048)

    @Test("a disable on an idle job acts — idle is exactly what disable is for")
    func disableActsOnIdleJob() throws {
        let url = tempJournal()
        defer { try? FileManager.default.removeItem(at: url) }
        let recorder = Recorder()
        let journal = Journal(url: url)
        let outcomes = Executor(runner: recorder.run, journal: journal,
                                probes: probes(running: false, disabled: false))
            .apply(bundle: "b", catalog: catalog([entry("com.example.job", lever: .disable)]),
                   context: context(records: [idleRecord()]), execute: true)

        #expect(outcomes.first?.result == .executed(verified: true), "not preExisting")
        #expect(recorder.calls.count == 1)
        #expect(journal.held().count == 1, "so it can be started again")
    }

    @Test("a disable on a job that is already disabled is left alone")
    func disableSkipsAlreadyDisabled() throws {
        let url = tempJournal()
        defer { try? FileManager.default.removeItem(at: url) }
        let recorder = Recorder()
        let outcomes = Executor(runner: recorder.run, journal: Journal(url: url),
                                probes: probes(running: false, disabled: true))
            .apply(bundle: "b", catalog: catalog([entry("com.example.job", lever: .disable)]),
                   context: context(records: [idleRecord()]), execute: true)

        if case .preExisting(let note) = outcomes.first?.result {
            #expect(note.contains("disabled"))
        } else {
            Issue.record("expected preExisting, got \(String(describing: outcomes.first?.result))")
        }
        #expect(recorder.calls.isEmpty)
    }

    @Test("a stop on an already-stopped job is still left alone")
    func stopStillRespectsPreExisting() throws {
        let url = tempJournal()
        defer { try? FileManager.default.removeItem(at: url) }
        let recorder = Recorder()
        let outcomes = Executor(runner: recorder.run, journal: Journal(url: url),
                                probes: probes(running: false, disabled: false))
            .apply(bundle: "b", catalog: catalog([entry("com.example.job", lever: .stop)]),
                   context: context(records: [idleRecord(state: .notLoaded)]), execute: true)

        if case .preExisting = outcomes.first?.result {
            #expect(recorder.calls.isEmpty, "rule 6 still holds for a real stop")
        } else {
            Issue.record("expected preExisting, got \(String(describing: outcomes.first?.result))")
        }
    }

    @Test("each step is reported as it lands, so a sheet can tick rows")
    func stepsAreReported() {
        let url = tempJournal()
        defer { try? FileManager.default.removeItem(at: url) }
        let recorder = Recorder()
        final class Seen: @unchecked Sendable {
            private let lock = NSLock(); private(set) var labels: [String] = []
            func add(_ s: String) { lock.lock(); labels.append(s); lock.unlock() }
        }
        let seen = Seen()
        _ = Executor(runner: recorder.run, journal: Journal(url: url), probes: probes())
            .apply(bundle: "b",
                   catalog: catalog([entry("com.example.a"), entry("com.example.b")]),
                   context: context(), execute: true) { outcome in seen.add(outcome.entryId) }

        #expect(seen.labels == ["com.example.a", "com.example.b"])
    }
}
