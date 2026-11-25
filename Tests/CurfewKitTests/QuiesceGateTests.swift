import Foundation
import Testing
@testable import CurfewKit

/// L7.3 — the quiesce screen. It may only narrow: every test here checks that a refusal stays a
/// refusal, and that the gate runs *after* the deterministic checks rather than instead of them.
@Suite("Quiesce screen")
struct QuiesceGateTests {

    final class Order: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var events: [String] = []
        func note(_ event: String) { lock.lock(); events.append(event); lock.unlock() }
    }

    func entry(_ id: String = "com.example.svc", quiesce: String? = "no clients on 5432",
               lever: Lever = .stop, verified: Bool = true) -> CatalogEntry {
        CatalogEntry(
            id: id, kind: .agent, lever: lever, supervised: .launchd,
            status: verified ? .verified : .draft,
            stop: Recipe(
                run: [["/bin/launchctl", "bootout", "{domain}/\\(id)"]], needsRoot: false,
                expect: "gone", quiesce: quiesce, hold: .none, meansReady: nil,
                verify: Verification(kind: .labelNotRunning, value: id)),
            start: nil, hazards: [""].filter { _ in false }, depends: [],
            evidence: verified ? "2026-11-25 · this Mac · observed" : nil,
            stoppable: true, coldStartCost: nil, ports: [], file: "test.yaml"
        )
    }

    func catalog(_ entries: [CatalogEntry]) -> Catalog {
        Catalog(entries: entries,
                bundles: [CatalogBundle(name: "b", kind: .stop, summary: "", protectPorts: [],
                                        members: entries.map(\.id), file: "test.yaml")],
                files: ["test.yaml"])
    }

    func context(listeners: [Listener] = []) -> ExecutionContext {
        ExecutionContext(domain: "gui/501", records: [], listeners: listeners, protectedPorts: [], ownAncestry: [])
    }

    func gate(_ verdict: QuiesceVerdict) -> QuiesceGate {
        QuiesceGate { _ in
            switch verdict {
            case .idle(let p), .busy(let p), .unsettled(let p): return .noul(p)
            case .unavailable: throw JevError.transport("down")
            }
        }
    }

    func tempJournal() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("curfew-quiesce-\(UUID().uuidString).jsonl")
    }

    // MARK: The three exits

    @Test("busy refuses and journals nothing")
    func busyRefuses() throws {
        let url = tempJournal()
        defer { try? FileManager.default.removeItem(at: url) }
        let recorder = ExecutorTests.Recorder()
        let outcomes = Executor(runner: recorder.run, journal: Journal(url: url), probes: .live,
                                gate: gate(.busy(0.82)), gateMode: .always)
            .apply(bundle: "b", catalog: catalog([entry()]), context: context(), execute: true)

        if case .refused(let reason) = outcomes.first?.result {
            #expect(reason.contains("in use"))
        } else {
            Issue.record("expected a refusal, got \(String(describing: outcomes.first?.result))")
        }
        #expect(recorder.calls.isEmpty, "a refused stop runs nothing")
        #expect(!FileManager.default.fileExists(atPath: url.path), "no intent is written for a refusal")
    }

    @Test("unsettled refuses, and proceeds only when the caller allows it")
    func unsettledBand() throws {
        let url = tempJournal()
        defer { try? FileManager.default.removeItem(at: url) }
        let strict = ExecutorTests.Recorder()
        let refused = Executor(runner: strict.run, journal: Journal(url: url), probes: .live,
                               gate: gate(.unsettled(0.5)), gateMode: .always)
            .apply(bundle: "b", catalog: catalog([entry()]), context: context(), execute: true)
        #expect(strict.calls.isEmpty)
        if case .refused(let reason) = refused.first?.result {
            #expect(reason.contains("unsettled"))
        } else {
            Issue.record("expected a refusal in the middle band")
        }

        let lax = ExecutorTests.Recorder()
        let allowed = Executor(runner: lax.run, journal: Journal(url: tempJournal()), probes: .live,
                               gate: gate(.unsettled(0.5)), gateMode: .always, allowUnsettled: true)
            .apply(bundle: "b", catalog: catalog([entry()]), context: context(), execute: true)
        #expect(lax.calls.count == 1, "--allow-unsettled lets the ordinary path run")
        #expect(allowed.first?.result != nil)
    }

    @Test("idle lets the ordinary path proceed unchanged")
    func idleProceeds() throws {
        let url = tempJournal()
        defer { try? FileManager.default.removeItem(at: url) }
        let recorder = ExecutorTests.Recorder()
        _ = Executor(runner: recorder.run, journal: Journal(url: url), probes: .live,
                     gate: gate(.idle(0.1)), gateMode: .always)
            .apply(bundle: "b", catalog: catalog([entry()]), context: context(), execute: true)
        #expect(recorder.calls.count == 1)
    }

    // MARK: It narrows only

    @Test("a model failure refuses rather than assuming idle")
    func failureRefuses() {
        let recorder = ExecutorTests.Recorder()
        let outcomes = Executor(runner: recorder.run, journal: Journal(url: tempJournal()), probes: .live,
                                gate: gate(.unavailable("down")), gateMode: .always)
            .apply(bundle: "b", catalog: catalog([entry()]), context: context(), execute: true)
        #expect(recorder.calls.isEmpty, "an unreachable model must never mean 'idle'")
        if case .refused(let reason) = outcomes.first?.result {
            #expect(reason.contains("unavailable"))
        } else {
            Issue.record("expected a refusal")
        }
    }

    @Test("the gate cannot turn a deterministic refusal into an allow")
    func cannotOverrideARefusal() {
        let recorder = ExecutorTests.Recorder()
        // a draft entry is refused before the gate is ever consulted
        let outcomes = Executor(runner: recorder.run, journal: Journal(url: tempJournal()), probes: .live,
                                gate: gate(.idle(0.0)), gateMode: .always)
            .apply(bundle: "b", catalog: catalog([entry(verified: false)]),
                   context: context(), execute: true)
        #expect(recorder.calls.isEmpty)
        if case .refused(let reason) = outcomes.first?.result {
            #expect(reason.contains("draft"), "the deterministic refusal is the one that fires")
        } else {
            Issue.record("expected the draft refusal")
        }
    }

    @Test("a never-list label is refused with the gate switched on")
    func neverListStillRefused() {
        let recorder = ExecutorTests.Recorder()
        _ = Executor(runner: recorder.run, journal: Journal(url: tempJournal()), probes: .live,
                     gate: gate(.idle(0.0)), gateMode: .always)
            .apply(bundle: "b", catalog: catalog([entry("com.apple.securityd")]),
                   context: context(), execute: true)
        #expect(recorder.calls.isEmpty)
    }

    // MARK: When it applies

    @Test("auto asks only where the entry declares a quiesce probe, and today that is nowhere")
    func autoAppliesOnlyWhereDeclared() {
        #expect(QuiesceMode.auto.applies(to: entry(quiesce: "no clients")))
        #expect(!QuiesceMode.auto.applies(to: entry(quiesce: nil)))
        #expect(!QuiesceMode.off.applies(to: entry(quiesce: "no clients")))
        #expect(QuiesceMode.always.applies(to: entry(quiesce: nil)))
    }

    @Test("the mode reads from the environment, defaulting to auto")
    func modeFromEnvironment() {
        #expect(QuiesceMode.fromEnvironment(nil) == .auto)
        #expect(QuiesceMode.fromEnvironment("1") == .always)
        #expect(QuiesceMode.fromEnvironment("off") == .off)
        #expect(QuiesceMode.fromEnvironment("nonsense") == .auto)
    }

    @Test("with the gate off, behaviour is what it was before")
    func offChangesNothing() throws {
        let url = tempJournal()
        defer { try? FileManager.default.removeItem(at: url) }
        let recorder = ExecutorTests.Recorder()
        // mode .off with a busy verdict must not consult the gate at all
        _ = Executor(runner: recorder.run, journal: Journal(url: url), probes: .live,
                     gate: gate(.busy(0.99)), gateMode: .off)
            .apply(bundle: "b", catalog: catalog([entry(quiesce: nil)]), context: context(), execute: true)
        #expect(recorder.calls.count == 1)
    }

    // MARK: Evidence

    @Test("the state carries the connections that a label cannot")
    func stateCarriesConnections() {
        let listeners = [Listener(command: "postgres", pid: 1, address: "127.0.0.1", port: 5432)]
        let state = QuiesceGate.state(
            entry: entry(), record: nil, listeners: listeners, connections: [5432: 3])
        #expect(state.contains("5432"))
        #expect(state.contains("\"connection_total\":3"))
        #expect(state.contains("quiesce_concern"))
    }

    @Test("the verdict bands are 0.65 and 0.35")
    func bands() {
        let gate = QuiesceGate { state in
            // the probability is encoded in the probe string
            .noul(Double(state) ?? 0)
        }
        #expect(gate.evaluate("0.90") == .busy(0.90))
        #expect(gate.evaluate("0.50") == .unsettled(0.50))
        #expect(gate.evaluate("0.10") == .idle(0.10))
        #expect(gate.evaluate("not a number") == .idle(0.0))
    }
}
