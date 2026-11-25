import Foundation
import Testing
@testable import CurfewKit

@Suite("Journal")
struct JournalTests {

    func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("curfew-journal-\(UUID().uuidString).jsonl")
    }

    @Test("an intent is on disk before the caller can act on it")
    func intentIsDurable() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let journal = Journal(url: url)

        let seq = try journal.appendIntent(
            entryId: "com.example.job", action: "disable",
            argv: [["/bin/launchctl", "disable", "gui/501/com.example.job"]]
        )

        // Read the file back immediately: the durability the rule requires is that a *new* reader
        // sees the intent, not that the object remembers it.
        let onDisk = Journal(url: url).unresolved()
        #expect(onDisk.count == 1)
        #expect(onDisk.first?.seq == seq)
        #expect(onDisk.first?.entryId == "com.example.job")
        #expect(onDisk.first?.argv == [["/bin/launchctl", "disable", "gui/501/com.example.job"]])
    }

    @Test("an outcome resolves its intent")
    func outcomeResolves() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let journal = Journal(url: url)
        let seq = try journal.appendIntent(entryId: "a.b", action: "stop", argv: [["/bin/true"]])
        try journal.appendOutcome(intent: seq, result: "ok", verified: true)

        #expect(journal.unresolved().isEmpty)
        #expect(journal.records().count == 2)
    }

    @Test("the restore plan is the unresolved intents, in reverse order")
    func restoreIsReversed() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let journal = Journal(url: url)
        _ = try journal.appendIntent(entryId: "first", action: "stop", argv: [["/bin/a"]])
        let middle = try journal.appendIntent(entryId: "middle", action: "stop", argv: [["/bin/b"]])
        _ = try journal.appendIntent(entryId: "last", action: "stop", argv: [["/bin/c"]])
        try journal.appendOutcome(intent: middle, result: "ok", verified: true)

        let plan = journal.restorePlan()
        #expect(plan.map(\.entryId) == ["last", "first"], "the last thing started is the first thing undone")
    }

    @Test("a truncated final line is ignored, not fatal")
    func truncatedLine() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let journal = Journal(url: url)
        let seq = try journal.appendIntent(entryId: "a.b", action: "stop", argv: [["/bin/true"]])

        // Simulate a crash mid-write: a valid record, then half a record.
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"v\":1,\"seq\":99,\"ts\":\"x\",\"kind\":\"inte".utf8))
        try handle.close()

        let reread = Journal(url: url)
        #expect(reread.records().count == 1)
        #expect(reread.unresolved().map(\.seq) == [seq])
    }

    @Test("a sequence continues across instances so an outcome can cite it")
    func sequenceContinues() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let first = Journal(url: url)
        let a = try first.appendIntent(entryId: "a", action: "stop", argv: [["/bin/a"]])

        let second = Journal(url: url)
        let b = try second.appendIntent(entryId: "b", action: "stop", argv: [["/bin/b"]])
        #expect(b > a, "a new process must not reuse a sequence number")
    }

    @Test("an unwritable journal refuses instead of acting silently")
    func unwritable() {
        // A path under a file, not a directory: creating the parent must fail.
        let blocker = FileManager.default.temporaryDirectory
            .appendingPathComponent("curfew-blocker-\(UUID().uuidString)")
        try? "not a directory".write(to: blocker, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: blocker) }

        let journal = Journal(url: blocker.appendingPathComponent("journal.jsonl"))
        #expect(throws: JournalError.self) {
            try journal.appendIntent(entryId: "a", action: "stop", argv: [["/bin/true"]])
        }
    }

    @Test("timestamps round-trip")
    func timestamps() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let journal = Journal(url: url)
        try journal.appendIntent(entryId: "a", action: "stop", argv: [["/bin/true"]])
        let record = try #require(journal.records().first)
        #expect(parseJournalTimestamp(record.ts) != nil)
    }
}

@Suite("Verify block")
struct VerifyBlockTests {

    func recipe(_ verify: Verification?) -> Recipe {
        Recipe(run: [["/bin/true"]], needsRoot: false, expect: "x", quiesce: nil, hold: .none, meansReady: nil, verify: verify)
    }

    func entry(_ status: EntryStatus, stop: Recipe?) -> CatalogEntry {
        CatalogEntry(
            id: "a.b", kind: .agent, lever: .stop, supervised: .launchd, status: status,
            stop: stop, start: nil, hazards: [], depends: [], evidence: "dated",
            stoppable: true, coldStartCost: nil, ports: [], file: "x.yaml"
        )
    }

    @Test("a verified entry without a post-condition is refused")
    func verifiedNeedsVerify() {
        let catalog = Catalog(entries: [entry(.verified, stop: recipe(nil))], bundles: [], files: ["x"])
        #expect(CatalogValidator.validate(catalog).contains { $0.kind == .verifiedWithoutPostcondition })
    }

    @Test("a verified entry with a post-condition passes")
    func verifiedWithVerify() {
        let catalog = Catalog(
            entries: [entry(.verified, stop: recipe(Verification(kind: .portClosed, value: "5432")))],
            bundles: [], files: ["x"]
        )
        #expect(CatalogValidator.validate(catalog).isEmpty)
    }

    @Test("a verified stop target carries a post-condition")
    func verifiedTargetHasVerify() throws {
        let dir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("catalog")
        let catalog = try CatalogLoader.load(directory: dir)
        let verify = try #require(catalog.entry("com.microsoft.SyncReporter")?.stop?.verify)
        #expect(verify.kind == .labelNotRunning)
        #expect(verify.value == "com.microsoft.SyncReporter")

        // an always-on entry has no post-condition because it has no stop
        #expect(catalog.entry("sh.brew.postgresql@18")?.stop == nil)
    }

    @Test("an unknown verify kind is a load error")
    func unknownVerifyKind() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("curfew-verify-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try """
        entries:
          - id: a.b
            kind: agent
            lever: stop
            supervised: launchd
            status: draft
            stop:
              run: [/bin/true]
              verify:
                kind: vibes
                value: "1"
        """.write(to: dir.appendingPathComponent("x.yaml"), atomically: true, encoding: .utf8)

        #expect(throws: CatalogError.self) { try CatalogLoader.load(directory: dir) }
    }
}
