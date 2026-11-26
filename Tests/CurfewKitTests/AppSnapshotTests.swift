import Foundation
import Testing
@testable import CurfewKit

/// The window renders an `AppSnapshot` and nothing else, so these are the tests that matter: the
/// snapshot must answer "is my machine quiet, and what is it holding?" from the journal, and offer a
/// stop only where a stop would be honest.
@Suite("App snapshot")
struct AppSnapshotTests {

    func tempJournal() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("curfew-snapshot-\(UUID().uuidString).jsonl")
    }

    @Test("the state line answers the question in one sentence")
    func stateLine() {
        #expect(AppSnapshot(quiet: false).stateLine == "Quiet mode is off")
        let one = AppSnapshot(quiet: true, held: [.init(seq: 1, label: "a", action: "disable", when: "")])
        #expect(one.stateLine == "Quiet mode is on — 1 change held")
        let two = AppSnapshot(quiet: true, held: [
            .init(seq: 1, label: "a", action: "disable", when: ""),
            .init(seq: 2, label: "b", action: "disable", when: ""),
        ])
        #expect(two.stateLine == "Quiet mode is on — 2 changes held")
    }

    @Test("quiet follows what the journal holds, not what is unresolved")
    func quietFollowsHeld() throws {
        let url = tempJournal()
        defer { try? FileManager.default.removeItem(at: url) }
        let journal = Journal(url: url)
        let intent = try journal.appendIntent(entryId: "com.example.a", action: "disable", argv: [["/bin/x"]])
        try journal.appendOutcome(intent: intent, result: "ok", verified: true)

        // an empty catalogue would hide the rows, but the quiet flag is journal truth
        let snapshot = AppSnapshotProvider.load(
            catalogDirectory: URL(fileURLWithPath: "/nonexistent"), journal: journal)
        #expect(snapshot.quiet)
        #expect(snapshot.held.count == 1)
        #expect(snapshot.held.first?.label == "com.example.a")
    }

    @Test("no catalogue is a stated problem, not an empty window")
    func missingCatalogIsExplained() throws {
        let url = tempJournal()
        defer { try? FileManager.default.removeItem(at: url) }
        let snapshot = AppSnapshotProvider.load(
            catalogDirectory: URL(fileURLWithPath: "/nonexistent"), journal: Journal(url: url))
        #expect(snapshot.problem?.contains("No catalogue") == true)
        #expect(!snapshot.quiet)
    }

    @Test("protect bundles are separated from the ones that can be started")
    func bundleSplit() {
        let snapshot = AppSnapshot(quiet: false, bundles: [
            .init(name: "vendor-noise", summary: "", isProtect: false, members: 13, acting: 13),
            .init(name: "never-cold", summary: "", isProtect: true, members: 2, acting: 2),
        ])
        #expect(snapshot.stopBundles.map(\.name) == ["vendor-noise"])
        #expect(snapshot.protectBundles.map(\.name) == ["never-cold"])
    }

    @Test("an uncatalogued finding cannot be stopped from the window")
    func canStopIsEarned() {
        let uncatalogued = AppSnapshot.Finding(
            label: "com.example.unknown", kind: "danglingProgram", severity: "defect",
            summary: "x", evidence: "y", canStop: false, isHeld: false, serviceState: "running")
        #expect(!uncatalogued.canStop)
    }

    @Test("the live machine produces a snapshot with real rows")
    func liveSnapshot() throws {
        let url = tempJournal()
        defer { try? FileManager.default.removeItem(at: url) }
        let catalog = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("catalog")
        let snapshot = AppSnapshotProvider.load(catalogDirectory: catalog, journal: Journal(url: url))

        #expect(snapshot.problem == nil)
        #expect(!snapshot.services.isEmpty, "the inventory is never empty on a running Mac")
        #expect(snapshot.bundles.count >= 5)
        #expect(!snapshot.quiet, "a fresh journal holds nothing")
        // and no finding may claim a stop it cannot make
        #expect(snapshot.findings.allSatisfy { !$0.canStop || !NeverList.isProtected(label: $0.label) })
    }

    @Test("a held label is named, so a row can offer Start instead of Stop")
    func heldLabels() throws {
        let url = tempJournal()
        defer { try? FileManager.default.removeItem(at: url) }
        let journal = Journal(url: url)
        let intent = try journal.appendIntent(entryId: "us.zoom.updater", action: "disable", argv: [["/bin/x"]])
        try journal.appendOutcome(intent: intent, result: "ok", verified: true)

        let catalog = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("catalog")
        let snapshot = AppSnapshotProvider.load(catalogDirectory: catalog, journal: journal)

        #expect(snapshot.heldLabels == ["us.zoom.updater"])
        // and any finding that happens to sit on that label agrees with it
        for finding in snapshot.findings where finding.label == "us.zoom.updater" {
            #expect(finding.isHeld)
        }
        // nothing else claims to be held
        #expect(snapshot.findings.allSatisfy { $0.isHeld == ($0.label == "us.zoom.updater") })
    }
}
