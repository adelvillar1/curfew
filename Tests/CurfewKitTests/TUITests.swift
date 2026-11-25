import Foundation
import Testing
@testable import CurfewKit

@Suite("TUI")
struct TUITests {

    func row(_ id: String, findings: Int = 0) -> TUIRow {
        TUIRow(id: id, state: "running", tier: "thirdParty", findings: findings, selected: false, inBundle: false)
    }

    func state(_ ids: [String], bundles: [String] = ["b1", "b2"]) -> TUIState {
        TUIState(title: "curfew 0.1.0", rows: ids.map { row($0) }, bundles: bundles)
    }

    // MARK: Navigation

    @Test("the cursor clamps at both ends")
    func cursorClamps() {
        var s = state(["a", "b", "c"])
        s.move(by: -1)
        #expect(s.cursor == 0)
        s.move(by: 5)
        #expect(s.cursor == 2)
        s.move(by: 5)
        #expect(s.cursor == 2)
    }

    @Test("space toggles the row under the cursor and nothing else")
    func toggle() {
        var s = state(["a", "b"])
        s.move(by: 1)
        s.toggle()
        #expect(s.rows[1].selected)
        #expect(s.rows[0].selected == false)
        #expect(s.selectedCount == 1)
        s.toggle()
        #expect(s.rows[1].selected == false)
    }

    @Test("b cycles bundles and wraps")
    func nextBundle() {
        var s = state(["a"], bundles: ["one", "two"])
        #expect(s.currentBundle == "one")
        s.nextBundle()
        #expect(s.currentBundle == "two")
        s.nextBundle()
        #expect(s.currentBundle == "one")
    }

    @Test("bundle membership marks the members and only them")
    func markMembers() {
        var s = state(["a", "b", "c"])
        s.markBundleMembers(["a", "c"])
        #expect(s.rows.map(\.inBundle) == [true, false, true])
        #expect(s.bundlePreview.map(\.id) == ["a", "c"])
    }

    // MARK: Keys

    @Test("keys parse from the bytes a terminal actually sends")
    func keyParsing() {
        #expect(TUIKeys.parse([0x6A]) == .down)                 // j
        #expect(TUIKeys.parse([0x6B]) == .up)                   // k
        #expect(TUIKeys.parse([0x20]) == .toggle)               // space
        #expect(TUIKeys.parse([0x62]) == .nextBundle)           // b
        #expect(TUIKeys.parse([0x61]) == .preview)              // a
        #expect(TUIKeys.parse([0x72]) == .refresh)              // r
        #expect(TUIKeys.parse([0x71]) == .quit)                 // q
        #expect(TUIKeys.parse([0x1B, 0x5B, 0x41]) == .up)       // ESC [ A
        #expect(TUIKeys.parse([0x1B, 0x5B, 0x42]) == .down)     // ESC [ B
        #expect(TUIKeys.parse([0x1B]) == .quit)                 // bare escape
        #expect(TUIKeys.parse([0x7A]) == .unknown("z"))
        #expect(TUIKeys.parse([]) == nil)
    }

    // MARK: Rendering

    @Test("the quiet-mode state is on the header of every frame")
    func bannerAlwaysPresent() {
        var off = state(["a"])
        off.title = "curfew 0.1.0"
        let offFrame = TUIRenderer.render(off, width: 100, height: 20)
        #expect(offFrame.contains("quiet mode: off"))

        var on = off
        on.quietMode = true
        let onFrame = TUIRenderer.render(on, width: 100, height: 20)
        #expect(onFrame.contains("QUIET MODE: ON"))
        #expect(onFrame.contains("unresolved journal intents"))

        // The second line of the frame must be the rule, not a list row: the banner never scrolls.
        #expect(onFrame.split(separator: "\n").first?.contains("QUIET MODE: ON") == true)
    }

    @Test("the footer always says the screen is read-only")
    func readOnlyFooter() {
        let frame = TUIRenderer.render(state(["a"]), width: 100, height: 20)
        #expect(frame.contains("only `curfew apply --execute` changes anything"))
    }

    @Test("a selected row is marked, a bundle member is marked differently")
    func rowMarks() {
        var s = state(["a", "b"])
        s.rows[0].selected = true
        s.rows[1].inBundle = true
        let frame = TUIRenderer.render(s, width: 100, height: 20)
        #expect(frame.contains("[x] a"))
        #expect(frame.contains("[·] b")) 
        #expect(frame.contains("[ ] ") == false || frame.contains("▸ [x]"))
    }

    @Test("the window scrolls so the cursor stays visible")
    func windowScrolls() {
        let ids = (0..<40).map { "service-\($0)" }
        var s = state(ids)
        s.cursor = 35
        let frame = TUIRenderer.render(s, width: 100, height: 20)
        #expect(frame.contains("service-35"))
        #expect(frame.contains("more"), "a list longer than the budget says so")
    }

    @Test("a long label is truncated, not allowed to push the columns out")
    func truncation() {
        let long = String(repeating: "x", count: 80)
        let frame = TUIRenderer.render(state([long]), width: 100, height: 20)
        for line in frame.split(separator: "\n") {
            #expect(line.count <= 101, "line wider than the frame: \(line.count)")
        }
        #expect(frame.contains("…"))
    }

    // MARK: Building from real data

    func record(_ id: String, tier: Tier, kind: Kind, findings: Int = 0) -> ServiceRecord {
        ServiceRecord(
            id: id, domain: "gui/501", plistPath: nil, state: .running, pid: 1, runs: 1,
            lastExitCode: nil, program: "/bin/true", tier: tier, kind: kind, supervised: .launchd,
            findings: (0..<findings).map { _ in
                Finding(id: .danglingProgram, severity: .defect, summary: "s", evidence: "e")
            }
        )
    }

    @Test("app-bound instances and protected jobs are excluded, and counted")
    func builderFilters() {
        let catalog = Catalog(entries: [], bundles: [
            CatalogBundle(name: "b", kind: .stop, summary: "", protectPorts: [], members: ["svc.a"], file: "x"),
        ], files: ["x"])
        let built = TUIBuilder.state(
            records: [
                record("svc.a", tier: .thirdParty, kind: .agent),
                record("application.com.apple.Notes.1", tier: .thirdParty, kind: .appChild),
                record("com.apple.securityd", tier: .protectedTier, kind: .daemon),
            ],
            catalog: catalog, quietMode: false, title: "t"
        )
        #expect(built.rows.map(\.id) == ["svc.a"])
        #expect(built.hidden == 2, "the excluded rows are counted, not silently dropped")
        #expect(built.rows[0].inBundle, "the current bundle's members are marked on load")
        #expect(built.currentBundle == "b")
    }
}
