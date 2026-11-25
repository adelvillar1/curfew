import Foundation
import Testing
@testable import CurfewKit

/// L3.5 — what a crash actually leaves behind, and whether the next run puts the machine back.
///
/// The crash artefact is not a metaphor: it is a journal file containing intents with no outcomes,
/// possibly ending mid-record. These tests build exactly that file and drive the real `resume`.
/// The live `kill -9` variant is `scripts/crash-test.sh`, because it needs its own process.
@Suite("Crash recovery")
struct CrashRecoveryTests {

    final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var calls: [[String]] = []
        func run(_ argv: [String]) -> CommandResult {
            lock.lock(); calls.append(argv); lock.unlock()
            return CommandResult(standardOutput: "", standardError: "", status: 0)
        }
    }

    func tempJournal() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("curfew-crash-\(UUID().uuidString).jsonl")
    }

    func entry(_ id: String, start: Bool = true) -> CatalogEntry {
        CatalogEntry(
            id: id, kind: .agent, lever: .disable, supervised: .launchd, status: .verified,
            stop: Recipe(run: [["/bin/true"]], needsRoot: false, expect: nil, quiesce: nil,
                         hold: .none, meansReady: nil,
                         verify: Verification(kind: .labelNotRunning, value: id)),
            start: start ? Recipe(run: [["/bin/start-\(id)"]], needsRoot: false, expect: nil,
                                  quiesce: nil, hold: .none, meansReady: nil, verify: nil) : nil,
            hazards: [], depends: [], evidence: "2026-11-24 · this Mac · observed",
            stoppable: true, coldStartCost: nil, ports: [], file: "crash.yaml"
        )
    }

    func catalog(_ ids: [String]) -> Catalog {
        Catalog(
            entries: ids.map { entry($0) },
            bundles: [CatalogBundle(name: "crash", kind: .stop, summary: "", protectPorts: [], members: ids, file: "crash.yaml")],
            files: ["crash.yaml"]
        )
    }

    /// Write a journal exactly as a crash would leave it: intents, no outcomes, one truncated tail.
    func writeCrashArtifact(_ journal: Journal, ids: [String], preExisting: String? = nil) throws {
        for id in ids {
            _ = try journal.appendIntent(entryId: id, action: "disable", argv: [["/bin/true"]], preExisting: preExisting)
        }
        // a half-written record, as if the process died inside write()
        let handle = try FileHandle(forWritingTo: journal.url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"v\":1,\"seq\":99,\"ts\":\"2026-11-24T".utf8))
        try handle.close()
    }

    @Test("a crash leaves every attempted entry unresolved, and the truncated tail is ignored")
    func crashArtifact() throws {
        let url = tempJournal()
        defer { try? FileManager.default.removeItem(at: url) }
        let journal = Journal(url: url)
        try writeCrashArtifact(journal, ids: ["com.example.a", "com.example.b", "com.example.c"])

        let unresolved = journal.unresolved()
        #expect(unresolved.count == 3, "three intents, no outcomes — that is what a crash looks like")
        #expect(unresolved.allSatisfy { $0.kind == .intent })
    }

    @Test("resume restores the crashed entries in reverse order")
    func resumeAfterCrash() throws {
        let url = tempJournal()
        defer { try? FileManager.default.removeItem(at: url) }
        let journal = Journal(url: url)
        try writeCrashArtifact(journal, ids: ["com.example.a", "com.example.b", "com.example.c"])

        let recorder = Recorder()
        let outcomes = Executor(runner: recorder.run, journal: journal, probes: .live)
            .resume(context: ExecutionContext(domain: "gui/501", ownAncestry: []),
                    catalog: catalog(["com.example.a", "com.example.b", "com.example.c"]))

        #expect(recorder.calls == [
            ["/bin/start-com.example.c"],
            ["/bin/start-com.example.b"],
            ["/bin/start-com.example.a"],
        ], "the last thing stopped is the first thing started")
        #expect(outcomes.count == 3)
        #expect(journal.unresolved().isEmpty, "after a successful resume nothing is left unresolved")
    }

    @Test("a second resume is a no-op — recovery is idempotent")
    func resumeIsIdempotent() throws {
        let url = tempJournal()
        defer { try? FileManager.default.removeItem(at: url) }
        let journal = Journal(url: url)
        try writeCrashArtifact(journal, ids: ["com.example.a"])

        let first = Recorder()
        _ = Executor(runner: first.run, journal: journal, probes: .live)
            .resume(context: ExecutionContext(domain: "gui/501", ownAncestry: []),
                    catalog: catalog(["com.example.a"]))

        let second = Recorder()
        let outcomes = Executor(runner: second.run, journal: journal, probes: .live)
            .resume(context: ExecutionContext(domain: "gui/501", ownAncestry: []),
                    catalog: catalog(["com.example.a"]))

        #expect(second.calls.isEmpty, "nothing left to restore")
        #expect(outcomes.isEmpty)
    }

    @Test("a crashed run does not start what was already stopped before Curfew")
    func preExistingSurvivesCrash() throws {
        let url = tempJournal()
        defer { try? FileManager.default.removeItem(at: url) }
        let journal = Journal(url: url)
        try writeCrashArtifact(journal, ids: ["com.example.a"], preExisting: "already notLoaded before Curfew ran")

        let recorder = Recorder()
        let outcomes = Executor(runner: recorder.run, journal: journal, probes: .live)
            .resume(context: ExecutionContext(domain: "gui/501", ownAncestry: []),
                    catalog: catalog(["com.example.a"]))

        #expect(recorder.calls.isEmpty, "rule 6 survives a crash: that service was never ours")
        #expect(outcomes.first?.result == .preExisting("already notLoaded before Curfew ran"))
    }
}
