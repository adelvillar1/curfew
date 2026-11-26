import AppKit
import CurfewKit

/// The menu bar shell. It draws `MenuBarModel` and wires the three things it offers: restore,
/// open the dashboard, quit. It never applies a bundle (D23).
///
/// `--dump-menu` prints the same model without touching AppKit, so the content is verifiable from a
/// script — the only part a session without a GUI can check.

/// Where the catalogue lives when the app was not started from the project.
///
/// launchd starts an app with `/` as the working directory, so a cwd-relative lookup silently gives an
/// empty catalogue — a status item that offers to restore nothing. Resolution order: an explicit env
/// override, then the copy shipped inside the bundle, then the working directory for a dev run.
func catalogDirectory() -> URL {
    if let override = ProcessInfo.processInfo.environment["CURFEW_CATALOG"] {
        return URL(fileURLWithPath: override)
    }
    if let resources = Bundle.main.resourceURL {
        let shipped = resources.appendingPathComponent("catalog")
        if FileManager.default.fileExists(atPath: shipped.path) { return shipped }
    }
    return URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("catalog")
}

func liveModel() -> MenuBarModel {
    let records = LaunchdInventory().records(in: Domain.effective(), findings: FindingsEngine()).records
    let journal = Journal()
    let catalog = (try? CatalogLoader.load(directory: catalogDirectory()))
        ?? Catalog(entries: [], bundles: [], files: [])
    let running = records.filter { $0.state == .running }.count
    let findings = records.reduce(0) { $0 + $1.findings.count }
    return MenuBarModel.build(
        quiet: !journal.unresolved().isEmpty,
        unresolvedCount: journal.unresolved().count,
        runningCount: running,
        findingCount: findings,
        bundleCount: catalog.bundles.count,
        version: curfewVersion,
        bundles: catalog.bundles
            .filter { $0.kind == .stop }
            .map { bundle in
                let entries = bundle.members.compactMap { id in catalog.entries.first { $0.id == id } }
                let acting = entries.filter { $0.stop?.run.isEmpty == false }.count
                return MenuBundle(name: bundle.name, members: bundle.members.count, acting: acting)
            }
            .sorted { $0.name < $1.name },
        protectedBundles: catalog.bundles.filter { $0.kind == .protect }.map(\.name)
    )
}

if let index = CommandLine.arguments.firstIndex(of: "--preview-bundle"),
   CommandLine.arguments.count > index + 1 {
    // The same command and capture the menu item runs, printed instead of shown in a modal.
    let bundle = CommandLine.arguments[index + 1]
    guard let cli = DashboardLauncher.resolve() else {
        FileHandle.standardError.write(Data((DashboardLauncher.missingMessage() + "\n").utf8))
        exit(1)
    }
    let line = DashboardLauncher.previewCommand(cli: cli, catalog: DashboardRunner.bundledCatalog, bundle: bundle)
    print("$ \(line)")
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/bin/sh")
    task.arguments = ["-c", line]
    let out = Pipe(), err = Pipe()
    task.standardOutput = out
    task.standardError = err
    try? task.run()
    let data = out.fileHandleForReading.readDataToEndOfFile()
    let errData = err.fileHandleForReading.readDataToEndOfFile()
    task.waitUntilExit()
    print(String(decoding: data + errData, as: UTF8.self))
    exit(task.terminationStatus)
}

if CommandLine.arguments.contains("--open-dashboard") {
    // The same code path the menu item runs, driveable from a terminal so it can be proven rather
    // than assumed — and so a failure prints its reason instead of being swallowed.
    switch DashboardRunner.open() {
    case .success(let line):
        print("opened: \(line)")
        exit(0)
    case .failure(let error):
        FileHandle.standardError.write(Data((error.message + "\n").utf8))
        exit(1)
    }
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
                if case .bundle(let name) = item.kind { entry.representedObject = name }
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
        case .bundle: return #selector(previewBundle(_:))
        }
    }

    @objc func restore() {
        let journal = Journal()
        guard !journal.restorePlan().isEmpty else { return }
        let catalog = (try? CatalogLoader.load(directory: catalogDirectory()))
            ?? Catalog(entries: [], bundles: [], files: [])
        let context = ExecutionContext(domain: Domain.effective().target)
        _ = Executor(journal: journal).resume(context: context, catalog: catalog)
        rebuild()
    }

    @objc func openDashboard() {
        switch DashboardRunner.open() {
        case .success:
            break
        case .failure(let error):
            // A menu item that does nothing is indistinguishable from a broken one. Say why.
            let alert = NSAlert()
            alert.messageText = "Could not open the dashboard"
            alert.informativeText = error.message
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }

    /// Preview one bundle: a dry run, shown as text. It deliberately cannot mutate — `apply` without
    /// `--execute`, so rule 3 holds in the place where no output can be read.
    @objc func previewBundle(_ sender: NSMenuItem) {
        guard let bundle = sender.representedObject as? String else { return }
        guard let cli = DashboardLauncher.resolve() else {
            alert(title: "Cannot preview", body: DashboardLauncher.missingMessage())
            return
        }
        let catalog = DashboardRunner.bundledCatalog
        let line = DashboardLauncher.previewCommand(cli: cli, catalog: catalog, bundle: bundle)

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", line]
        let out = Pipe(), err = Pipe()
        task.standardOutput = out
        task.standardError = err
        do { try task.run() } catch {
            alert(title: "Cannot preview", body: "Could not run \(cli): \(error.localizedDescription)")
            return
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()

        let text = String(decoding: data, as: UTF8.self)
            + String(decoding: errData, as: UTF8.self)
        alert(title: "Preview — \(bundle)", body: text.isEmpty ? "no output" : text, monospaced: true)
    }

    func alert(title: String, body: String, monospaced: Bool = false) {
        let dialog = NSAlert()
        dialog.messageText = title
        dialog.alertStyle = .informational
        // Output is long: put it in a scroll view rather than letting NSAlert truncate it.
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 520, height: 260))
        let text = NSTextView(frame: scroll.bounds)
        text.isEditable = false
        text.string = body
        if monospaced { text.font = .monospacedSystemFont(ofSize: 11, weight: .regular) }
        scroll.documentView = text
        scroll.hasVerticalScroller = true
        dialog.accessoryView = scroll
        dialog.addButton(withTitle: "Done")
        dialog.runModal()
    }

    @objc func quit() { NSApp.terminate(nil) }
}

/// The thin AppKit/AppleScript half — the decisions live in `CurfewKit.DashboardLauncher`, which is
/// tested; this only calls them and reports.
enum DashboardRunner {
    static var bundledCatalog: String? {
        guard let resources = Bundle.main.resourceURL else { return nil }
        let path = resources.appendingPathComponent("catalog").path
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue
        else { return nil }
        return path
    }

    static func open() -> Result<String, DashboardLauncher.Failure> {
        guard let cli = DashboardLauncher.resolve() else {
            return .failure(DashboardLauncher.Failure(message: DashboardLauncher.missingMessage()))
        }
        let line = DashboardLauncher.command(cli: cli, catalog: bundledCatalog)

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = ["-e", "tell application \"Terminal\" to do script \"\(line)\" activate"]
        let errPipe = Pipe()
        task.standardError = errPipe
        task.standardOutput = Pipe()
        do {
            try task.run()
        } catch {
            return .failure(DashboardLauncher.Failure(
                message: "Could not run osascript: \(error.localizedDescription)"))
        }
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        let stderr = String(decoding: errData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if task.terminationStatus != 0 {
            let automation = stderr.contains("-1743") || stderr.lowercased().contains("not allowed")
            return .failure(DashboardLauncher.Failure(message: automation
                ? """
                  macOS did not allow Curfew to control Terminal.

                  Allow it in System Settings → Privacy & Security → Automation → Curfew → Terminal.
                  \(stderr.isEmpty ? "" : "\n\(stderr)")
                  """
                : "Terminal refused the request (exit \(task.terminationStatus)).\n\(stderr)"))
        }
        return .success(line)
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
