import Foundation
import Testing
@testable import CurfewKit

/// The critique's P1: rows printed `disable`, `spawnScheduled`, `danglingProgram` at one weight.
/// The boundary is now here, and the raw identifier is kept only where detail belongs.
@Suite("Vocabulary")
struct VocabularyTests {

    @Test("verbs become the past tense a person uses")
    func actions() {
        #expect(Vocabulary.action("disable") == "disabled")
        #expect(Vocabulary.action("freeze") == "frozen")
        #expect(Vocabulary.action("quarantine") == "moved to quarantine")
        #expect(Vocabulary.action("resume") == "restored")
        #expect(Vocabulary.action("something-new") == "something new")
    }

    @Test("launchd states are said plainly")
    func states() {
        #expect(Vocabulary.jobState("spawnScheduled") == "waiting to start")
        #expect(Vocabulary.jobState("notLoaded") == "not loaded")
        #expect(Vocabulary.jobState("running") == "running")
    }

    @Test("finding kinds say what is wrong, not which rule fired")
    func kinds() {
        #expect(Vocabulary.findingKind("danglingProgram") == "program missing")
        #expect(Vocabulary.findingKind("fieldUnavailable") == "could not read its config")
        #expect(Vocabulary.findingKind("execFailure") == "program will not run")
        // an unknown kind is shown as-is rather than swallowed
        #expect(Vocabulary.findingKind("brandNewRule") == "brandNewRule")
    }

    @Test("a held change reads as a phrase")
    func held() {
        #expect(Vocabulary.heldPhrase("disable") == "disabled by Curfew")
        #expect(Vocabulary.heldPhrase("freeze") == "frozen by Curfew")
    }
}

/// The critique's P2: the app had no memory of its own last run.
@Suite("Last session")
struct LastSessionTests {

    func outcome(_ seq: Int, _ intent: Int, _ result: String, at iso: String) -> JournalRecord {
        JournalRecord(seq: seq, ts: iso, kind: .outcome, intent: intent, result: result, verified: true)
    }

    @Test("no restores means no last session")
    func empty() {
        #expect(LastSessionReader.read(from: []) == nil)
    }

    @Test("the newest restore closes the session, and its neighbours are the size")
    func readsTheRun() {
        let records = [
            outcome(1, 10, "resumed", at: "2026-11-26T06:39:00.000Z"),
            outcome(2, 11, "resumed", at: "2026-11-26T06:40:00.000Z"),
            outcome(3, 12, "resumed", at: "2026-11-26T06:40:30.000Z"),
            // a much older run, outside the cluster window
            outcome(4, 13, "resumed", at: "2026-11-25T22:00:00.000Z"),
        ]
        let session = LastSessionReader.read(from: records)
        #expect(session?.changes == 3, "three restores in the same run")
    }

    @Test("an ok outcome is not a restore")
    func okIsNotRestore() {
        let records = [outcome(1, 10, "ok", at: "2026-11-26T06:39:00.000Z")]
        #expect(LastSessionReader.read(from: records) == nil)
    }

    @Test("a journal written by the tool produces a session")
    func fromARealJournal() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("curfew-last-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let journal = Journal(url: url)
        let intent = try journal.appendIntent(entryId: "a", action: "disable", argv: [["/bin/true"]])
        try journal.appendOutcome(intent: intent, result: "ok", verified: true)
        try journal.appendOutcome(intent: intent, result: "resumed", verified: true)

        let records = journal.records()
        #expect(records.contains { $0.result == "resumed" }, "the file really has a restore")
        if let date = records.first(where: { $0.result == "resumed" })?.ts {
            #expect(parseJournalTimestamp(date) != nil, "and its timestamp parses: \(date)")
        }
        #expect(LastSessionReader.read(from: records)?.changes == 1)
    }

    @Test("the provider carries the session through")
    func providerCarriesIt() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("curfew-prov-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let journal = Journal(url: url)
        let intent = try journal.appendIntent(entryId: "a", action: "disable", argv: [["/bin/true"]])
        try journal.appendOutcome(intent: intent, result: "ok", verified: true)
        try journal.appendOutcome(intent: intent, result: "resumed", verified: true)

        let catalog = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("catalog")
        let snapshot = AppSnapshotProvider.load(catalogDirectory: catalog, journal: journal)
        #expect(snapshot.lastSession != nil, "the provider must carry it")
    }
}
