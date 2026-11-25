import Foundation
import Testing
@testable import CurfewKit

/// D21: this is an internal, single-user tool, so privilege comes from running under `sudo` — not
/// from a signed daemon and an XPC connection. The checks that mattered are still checks; they just
/// happen in-process.
@Suite("Privilege via sudo")
struct SudoPrivilegeTests {

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
            .appendingPathComponent("curfew-sudo-\(UUID().uuidString).jsonl")
    }

    func rootEntry(_ id: String = "com.apple.metadata.mds.index", status: EntryStatus = .verified) -> CatalogEntry {
        CatalogEntry(
            id: id, kind: .daemon, lever: .command, supervised: .launchd, status: status,
            stop: Recipe(run: [["/usr/bin/mdutil", "-a", "-i", "off"]], needsRoot: true, expect: "indexing off",
                         quiesce: nil, hold: .none, meansReady: nil,
                         verify: Verification(kind: .labelNotRunning, value: id)),
            start: nil, hazards: ["io"], depends: [],
            evidence: status == .verified ? "2026-11-24 · this Mac · mdutil off then on" : nil,
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

    // MARK: The domain trap

    @Test("under sudo the domain is the invoking user's, not root's")
    func sudoDomain() {
        #expect(Domain.effective(environment: ["SUDO_UID": "501"], isRoot: true) == .gui(501))
        #expect(Domain.effective(environment: [:], isRoot: true) == .gui(getuid()),
                "root without SUDO_UID has no gui domain; falling back beats enumerating gui/0")
        #expect(Domain.effective(environment: ["SUDO_UID": "501"], isRoot: false) == .gui(getuid()),
                "SUDO_UID is ignored when we are not root")
    }

    // MARK: Running as root

    @Test("as root, a verified root recipe runs in-process")
    func rootRunsLocally() throws {
        let url = tempJournal()
        defer { try? FileManager.default.removeItem(at: url) }
        let recorder = Recorder()
        let outcomes = Executor(runner: recorder.run, journal: Journal(url: url), probes: .live, isRoot: true)
            .apply(bundle: "b", catalog: catalog([rootEntry()]), context: context(), execute: true)

        #expect(recorder.calls == [["/usr/bin/mdutil", "-a", "-i", "off"]])
        #expect(outcomes.first?.result == .executed(verified: true))
    }

    @Test("as root, the catalog rules still refuse a draft entry")
    func rootStillRefusesDraft() throws {
        let url = tempJournal()
        defer { try? FileManager.default.removeItem(at: url) }
        let recorder = Recorder()
        let outcomes = Executor(runner: recorder.run, journal: Journal(url: url), probes: .live, isRoot: true)
            .apply(bundle: "b", catalog: catalog([rootEntry(status: .draft)]), context: context(), execute: true)

        #expect(recorder.calls.isEmpty, "root is not a licence to run a recipe nobody verified")
        if case .refused(let reason) = outcomes.first?.result {
            #expect(reason.contains("draft"))
        } else {
            Issue.record("expected a draft refusal even as root")
        }
    }

    @Test("as root, a never-list label is still refused")
    func rootStillRefusesNeverList() throws {
        let url = tempJournal()
        defer { try? FileManager.default.removeItem(at: url) }
        let recorder = Recorder()
        let entry = rootEntry("com.apple.securityd")
        _ = Executor(runner: recorder.run, journal: Journal(url: url), probes: .live, isRoot: true)
            .apply(bundle: "b", catalog: catalog([entry]), context: context(), execute: true)
        #expect(recorder.calls.isEmpty)
    }

    // MARK: Not root

    @Test("as a user, a root recipe says what to type")
    func userGetsSudoInstruction() throws {
        let url = tempJournal()
        defer { try? FileManager.default.removeItem(at: url) }
        let recorder = Recorder()
        let outcomes = Executor(runner: recorder.run, journal: Journal(url: url), probes: .live, isRoot: false)
            .apply(bundle: "b", catalog: catalog([rootEntry()]), context: context(), execute: true)

        #expect(recorder.calls.isEmpty)
        if case .refused(let reason) = outcomes.first?.result {
            #expect(reason.contains("sudo"), "a refusal that does not say the next step is a dead end")
        } else {
            Issue.record("expected a refusal naming sudo")
        }
    }

    @Test("the planner refuses a root recipe without root, and plans it with")
    func plannerKnows() {
        let catalog = catalog([rootEntry()])
        let without = CatalogPlanner.plan(bundle: "b", in: catalog, privilegedAvailable: false)
        #expect(without.steps.isEmpty)
        #expect(without.refusals.first?.reason.contains("sudo") == true)

        let with = CatalogPlanner.plan(bundle: "b", in: catalog, privilegedAvailable: true)
        #expect(with.steps.count == 1)
        #expect(with.refusals.isEmpty)
    }
}
