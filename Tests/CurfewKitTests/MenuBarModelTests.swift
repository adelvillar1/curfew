import Foundation
import Testing
@testable import CurfewKit

@Suite("Menu bar model")
struct MenuBarModelTests {

    func off() -> MenuBarModel {
        MenuBarModel.build(quiet: false, unresolvedCount: 0, runningCount: 225,
                           findingCount: 11, bundleCount: 5, version: "0.1.0")
    }

    func on(_ unresolved: Int = 3) -> MenuBarModel {
        MenuBarModel.build(quiet: true, unresolvedCount: unresolved, runningCount: 225,
                           findingCount: 11, bundleCount: 5, version: "0.1.0")
    }

    func item(_ model: MenuBarModel, kind: MenuItemKind) -> MenuItem? {
        model.sections.flatMap(\.items).first { $0.kind == kind }
    }

    @Test("the status item says quiet mode in one glyph")
    func statusGlyph() {
        #expect(MenuBarModel.statusTitle(quiet: false, unresolved: 0) == "○")
        #expect(MenuBarModel.statusTitle(quiet: true, unresolved: 3) == "◐ 3")
        #expect(off().statusTitle == "○")
        #expect(on(2).statusTitle == "◐ 2")
    }

    @Test("restore is offered only when there is something to restore")
    func restoreOnlyWhenNeeded() throws {
        let quietOff = try #require(item(off(), kind: .restore))
        #expect(quietOff.enabled == false)
        #expect(quietOff.title == "Nothing to restore")

        let quietOn = try #require(item(on(), kind: .restore))
        #expect(quietOn.enabled == true)
        #expect(quietOn.title.contains("Restore"))
    }

    @Test("the state line is always present and never claims a mode it is not in")
    func stateLine() {
        #expect(off().sections[0].items[0].title == "Quiet mode is off")
        #expect(on(3).sections[0].items[0].title.contains("Quiet mode is ON"))
        #expect(on(3).sections[0].items[0].title.contains("3 unresolved"))
    }

    @Test("informational rows cannot be clicked")
    func infoRowsDisabled() {
        for model in [off(), on()] {
            for section in model.sections {
                for row in section.items where row.kind == .info {
                    #expect(row.enabled == false, "\(row.title) is information, not an action")
                }
            }
        }
    }

    @Test("dashboard and quit are always available")
    func alwaysAvailable() {
        for model in [off(), on()] {
            #expect(item(model, kind: .dashboard)?.enabled == true)
            #expect(item(model, kind: .quit)?.enabled == true)
        }
    }

    @Test("the dump reads like the menu")
    func dump() {
        let text = on(3).dump()
        #expect(text.hasPrefix("[◐ 3]"))
        #expect(text.contains("Restore everything…"))
        #expect(text.contains("225 services running · 11 findings"))
        #expect(text.contains("Quit"))
    }

    // MARK: Bundles (KI-043)

    @Test("a stop bundle is previewable, and says how many of its members act")
    func stopBundleItem() {
        let model = MenuBarModel.build(
            quiet: false, unresolvedCount: 0, runningCount: 1, findingCount: 0,
            bundleCount: 5, version: "0.1.0",
            bundles: [MenuBundle(name: "vendor-noise", members: 13, acting: 13)])
        let item = model.sections.flatMap(\.items).first { $0.kind == .bundle("vendor-noise") }
        #expect(item?.title.contains("13 of 13") == true)
        #expect(item?.enabled == true)
    }

    @Test("a bundle whose members all refuse is not offered as an action")
    func inertBundleDisabled() {
        let model = MenuBarModel.build(
            quiet: false, unresolvedCount: 0, runningCount: 1, findingCount: 0,
            bundleCount: 5, version: "0.1.0",
            bundles: [MenuBundle(name: "data-services", members: 0, acting: 0)])
        let item = model.sections.flatMap(\.items).first { $0.kind == .bundle("data-services") }
        #expect(item?.enabled == false)
    }

    @Test("quiet mode disables previews — the machine is already quiet")
    func quietDisablesPreviews() {
        let model = MenuBarModel.build(
            quiet: true, unresolvedCount: 2, runningCount: 1, findingCount: 0,
            bundleCount: 5, version: "0.1.0",
            bundles: [MenuBundle(name: "vendor-noise", members: 13, acting: 13)])
        #expect(model.sections.flatMap(\.items).allSatisfy { item in
            if case .bundle = item.kind { return !item.enabled }
            return true
        })
    }

    @Test("protected bundles are named, not silently dropped")
    func protectedNamed() {
        let model = MenuBarModel.build(
            quiet: false, unresolvedCount: 0, runningCount: 1, findingCount: 0,
            bundleCount: 5, version: "0.1.0",
            bundles: [MenuBundle(name: "vendor-noise", members: 13, acting: 13)],
            protectedBundles: ["never-cold", "dev-tools"])
        let info = model.sections.flatMap(\.items).first {
            if case .info = $0.kind { return $0.title.contains("protected") }
            return false
        }
        #expect(info?.title.contains("dev-tools") == true)
        #expect(info?.title.contains("never-cold") == true)
    }

    @Test("with no bundles at all the old count line is kept")
    func noBundles() {
        let model = MenuBarModel.build(
            quiet: false, unresolvedCount: 0, runningCount: 1, findingCount: 0,
            bundleCount: 5, version: "0.1.0")
        #expect(model.sections.flatMap(\.items).contains { $0.title == "5 bundles in the catalog" })
    }
}
