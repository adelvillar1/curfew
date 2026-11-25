import AppKit
import CurfewKit

/// The menu bar shell. It draws `MenuBarModel` and wires the three things it offers: restore,
/// open the dashboard, quit. It never applies a bundle (D23).
///
/// `--dump-menu` prints the same model without touching AppKit, so the content is verifiable from a
/// script — the only part a session without a GUI can check.

func liveModel() -> MenuBarModel {
    let records = LaunchdInventory().records(in: Domain.effective(), findings: FindingsEngine()).records
    let journal = Journal()
    let catalog = (try? CatalogLoader.load(
        directory: URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("catalog")
    )) ?? Catalog(entries: [], bundles: [], files: [])
    let running = records.filter { $0.state == .running }.count
    let findings = records.reduce(0) { $0 + $1.findings.count }
    return MenuBarModel.build(
        quiet: !journal.unresolved().isEmpty,
        unresolvedCount: journal.unresolved().count,
        runningCount: running,
        findingCount: findings,
        bundleCount: catalog.bundles.count,
        version: curfewVersion
    )
}

if CommandLine.arguments.contains("--dump-menu") {
    print(liveModel().dump())
    exit(0)
}

// MARK: - AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        if let button = statusItem.button {
            button.title = MenuBarModel.statusTitle(quiet: false, unresolved: 0)
        }
        rebuild()
    }

    func rebuild() {
        let model = liveModel()
        statusItem.button?.title = model.statusTitle
        let menu = NSMenu()
        for section in model.sections {
            if !menu.items.isEmpty { menu.addItem(.separator()) }
            for item in section.items {
                let entry = NSMenuItem(title: item.title, action: action(for: item.kind), keyEquivalent: "")
                entry.target = self
                entry.isEnabled = item.enabled
                menu.addItem(entry)
            }
        }
        statusItem.menu = menu
    }

    func action(for kind: MenuItemKind) -> Selector? {
        switch kind {
        case .info: return nil
        case .restore: return #selector(restore)
        case .dashboard: return #selector(openDashboard)
        case .quit: return #selector(quit)
        }
    }

    @objc func restore() {
        let journal = Journal()
        guard !journal.restorePlan().isEmpty else { return }
        let catalog = (try? CatalogLoader.load(
            directory: URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("catalog")
        )) ?? Catalog(entries: [], bundles: [], files: [])
        let context = ExecutionContext(domain: Domain.effective().target)
        _ = Executor(journal: journal).resume(context: context, catalog: catalog)
        rebuild()
    }

    @objc func openDashboard() {
        // The dashboard is a terminal program; hand it to the default terminal via `open`.
        let cli = ProcessInfo.processInfo.environment["CURFEW_CLI"] ?? "/usr/local/bin/curfew"
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = ["-e", "tell application \"Terminal\" to do script \"\(cli)\""]
        try? task.run()
    }

    @objc func quit() { NSApp.terminate(nil) }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
