import Foundation
import Testing
@testable import CurfewKit

/// L4's delegation seam: a root recipe goes to the helper, and the intent is journaled before the
/// request for the same reason it is journaled before a local action — the machine can be left
/// holding it either way.
@Suite("Executor delegation")
struct ExecutorDelegationTests {

    final class Transport: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var requests: [HelperRequest] = []
        private(set) var journalAtRequest: [JournalRecord] = []
        var journalURL: URL?
        var response: HelperResponse?

        func send(_ request: HelperRequest) -> HelperResponse {
            lock.lock()
            requests.append(request)
            if let url = journalURL { journalAtRequest = Journal(url: url).records() }
            lock.unlock()
            return response ?? HelperResponse(ok: true, verified: true, status: 0, intentSeq: request.intentSeq)
        }
    }

    func tempJournal() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("curfew-deleg-\(UUID().uuidString).jsonl")
    }

    func rootEntry(_ id: String = "com.apple.metadata.mds.index") -> CatalogEntry {
        CatalogEntry(
            id: id, kind: .daemon, lever: .command, supervised: .launchd, status: .verified,
            stop: Recipe(run: [["/usr/bin/mdutil", "-a", "-i", "off"]], needsRoot: true, expect: "indexing off",
                         quiesce: nil, hold: .none, meansReady: nil,
                         verify: Verification(kind: .labelNotRunning, value: id)),
            start: nil, hazards: ["io"], depends: [],
            evidence: "2026-11-24 · this Mac · indexed off and on",
            stoppable: true, coldStartCost: nil, ports: [], file: "test.yaml"
        )
    }

    func catalog(_ entries: [CatalogEntry]) -> Catalog {
        Catalog(
            entries: entries,
            bundles: [CatalogBundle(name: "b", kind: .stop, summary: "", protectPorts: [],
                                    members: entries.map(\.id), file: "test.yaml")],
            files: ["test.yaml"]
        )
    }

    func context() -> ExecutionContext {
        ExecutionContext(domain: "gui/501", records: [], listeners: [], protectedPorts: [], ownAncestry: [])
    }

    @Test("without a helper a root recipe is refused, naming L4")
    func noHelperRefuses() {
        let recorder = ExecutorTests.Recorder()
        let outcomes = Executor(runner: recorder.run, journal: Journal(url: tempJournal()), probes: .live)
            .apply(bundle: "b", catalog: catalog([rootEntry()]), context: context(), execute: true)

        #expect(recorder.calls.isEmpty)
        if case .refused(let reason) = outcomes.first?.result {
            #expect(reason.contains("L4"))
        } else {
            Issue.record("expected a refusal naming L4")
        }
    }

    @Test("with a helper the request carries an entry id, never argv, and the intent is already on disk")
    func delegatesWithIntentFirst() throws {
        let url = tempJournal()
        defer { try? FileManager.default.removeItem(at: url) }
        let transport = Transport()
        transport.journalURL = url

        let outcomes = Executor(
            runner: ExecutorTests.Recorder().run,
            journal: Journal(url: url),
            probes: .live,
            privileged: transport.send
        ).apply(bundle: "b", catalog: catalog([rootEntry()]), context: context(), execute: true)

        #expect(outcomes.first?.result == .executed(verified: true))
        let request = try #require(transport.requests.first)
        #expect(request.entryId == "com.apple.metadata.mds.index")
        #expect(request.intentSeq > 0)
        #expect(transport.journalAtRequest.first?.kind == .intent, "the intent must be durable before the request")
        #expect(transport.journalAtRequest.first?.seq == request.intentSeq)
    }

    @Test("a helper refusal is an outcome, not an exception, and closes the intent")
    func helperRefusal() throws {
        let url = tempJournal()
        defer { try? FileManager.default.removeItem(at: url) }
        let transport = Transport()
        transport.response = HelperResponse(
            ok: false, verified: nil, status: nil, refusal: "caller team ABC does not match DEF", intentSeq: 0
        )
        let journal = Journal(url: url)
        let outcomes = Executor(runner: ExecutorTests.Recorder().run, journal: journal, probes: .live,
                                privileged: transport.send)
            .apply(bundle: "b", catalog: catalog([rootEntry()]), context: context(), execute: true)

        if case .refused(let reason) = outcomes.first?.result {
            #expect(reason.contains("helper:"))
            #expect(reason.contains("team"))
        } else {
            Issue.record("expected a refusal from the helper")
        }
        #expect(journal.unresolved().isEmpty, "a refused delegation must not leave the journal holding it")
    }

    @Test("a helper failure reports the exit and stops the run")
    func helperFailure() throws {
        let url = tempJournal()
        defer { try? FileManager.default.removeItem(at: url) }
        let transport = Transport()
        transport.response = HelperResponse(ok: false, verified: nil, status: 1,
                                            standardError: "mdutil: Operation not permitted", intentSeq: 0)
        let journal = Journal(url: url)
        let outcomes = Executor(runner: ExecutorTests.Recorder().run, journal: journal, probes: .live,
                                privileged: transport.send)
            .apply(bundle: "b", catalog: catalog([rootEntry()]), context: context(), execute: true)

        if case .failed(let reason) = outcomes.first?.result {
            #expect(reason.contains("helper exited 1"))
            #expect(reason.contains("not permitted"))
        } else {
            Issue.record("expected a failure")
        }
        #expect(journal.unresolved().isEmpty)
    }

    @Test("a dry run never contacts the helper")
    func dryRunDoesNotDelegate() {
        let transport = Transport()
        _ = Executor(runner: ExecutorTests.Recorder().run, journal: Journal(url: tempJournal()), probes: .live,
                     privileged: transport.send)
            .apply(bundle: "b", catalog: catalog([rootEntry()]), context: context(), execute: false)
        #expect(transport.requests.isEmpty)
    }
}
