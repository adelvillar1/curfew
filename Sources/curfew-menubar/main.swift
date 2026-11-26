import AppKit
import SwiftUI

// A second launch hands off by signalling the lock holder. That signal can arrive in the window between
// `exec` and the handler being installed, where its default action is to terminate the process — which
// killed an instance mid-launch. Ignore it from the first instruction; the handler replaces this later.
signal(SIGUSR1, SIG_IGN)
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
    let held = journal.held()
    return MenuBarModel.build(
        quiet: !held.isEmpty,
        unresolvedCount: held.count,
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

if let index = CommandLine.arguments.firstIndex(of: "--drive-freeze"),
   CommandLine.arguments.count > index + 1 {
    // Freeze one app, prove the state, then restore it — the window's path, without a click.
    let name = CommandLine.arguments[index + 1]
    let model = AppModel(catalogDirectory: catalogDirectory())
    guard let app = model.snapshot.apps.first(where: { $0.name == name }) else {
        print("no app named \(name)"); exit(1)
    }
    print("before : \(app.name) \(Int(app.memoryMB)) MB · frozen=\(app.isFrozen) · pids=\(app.pids.count)")
    model.freeze(app)
    if let row = model.snapshot.apps.first(where: { $0.name == name }) {
        print("frozen : frozen=\(row.isFrozen)")
    }
    print("note   : \(model.note?.title ?? "-")")
    model.note = nil
    model.thaw(app)
    if let row = model.snapshot.apps.first(where: { $0.name == name }) {
        print("thawed : frozen=\(row.isFrozen)")
    }
    print("result : \(model.note?.body.replacingOccurrences(of: "\n", with: " | ") ?? "-")")
    exit(0)
}

if CommandLine.arguments.contains("--dump-state") {
    // What the window would render, as facts.
    let model = AppModel(catalogDirectory: catalogDirectory())
    let snapshot = model.snapshot
    print("quiet: \(snapshot.quiet) · held: \(snapshot.held.count) · apps: \(snapshot.apps.count)")
    if let last = snapshot.lastSession {
        print("last session: \(last.ended) · \(last.changes) restored")
    } else {
        print("last session: none")
    }
    exit(0)
}

if CommandLine.arguments.contains("--dump-panes") {
    // The sidebar is AppKit and cannot render offscreen, so print what it is built from. It derives
    // from Pane.allCases, which is the point: a pane cannot exist without a row to reach it.
    for section in AppModel.Pane.sections {
        print(section)
        for pane in AppModel.Pane.allCases where pane.section == section {
            print("  · \(pane.rawValue)")
        }
    }
    exit(0)
}

if CommandLine.arguments.contains("--dump-apps") {
    // What the Apps pane would list, printed — the same scan the window runs.
    let apps = AppsScanner.scan()
    print("\(apps.count) apps · \(Int(apps.reduce(0) { $0 + $1.memoryMB })) MB")
    for app in apps.prefix(8) {
        print(String(format: "  %-34s %6d MB  %2d proc%@", (app.name as NSString).utf8String!,
                     Int(app.memoryMB), app.pids.count, app.isFrozen ? "  frozen" : ""))
    }
    exit(0)
}

if let index = CommandLine.arguments.firstIndex(of: "--drive-quarantine"),
   CommandLine.arguments.count > index + 1 {
    // The window's quarantine path, driven: move the plist, then put it back, so both directions are
    // proven on the real file rather than on a fixture.
    let label = CommandLine.arguments[index + 1]
    let model = AppModel(catalogDirectory: catalogDirectory())
    let records = LaunchdInventory().records(in: Domain.effective(), findings: FindingsEngine()).records
    guard let record = records.first(where: { $0.id == label }), let plist = record.plistPath else {
        print("no record with a plist for \(label)"); exit(1)
    }
    print("verdict: \(QuarantineEligibility.judge(program: record.program, plistPath: plist))")
    model.quarantine(label: label)
    guard let plan = model.plan else {
        print("no plan: \(model.note?.title ?? "-") — \(model.note?.body ?? "")"); exit(1)
    }
    print("plan   : \(plan.title)")
    for step in plan.steps { print("         \(step)") }
    model.applyPlan()
    print("result : \(model.note?.body.replacingOccurrences(of: "\n", with: " | ") ?? "-")")
    model.note = nil
    print("moved  : plist present=\(FileManager.default.fileExists(atPath: plist)) held=\(model.snapshot.heldLabels.sorted())")

    // and back
    model.start(label: label)
    if let reverse = model.plan {
        for step in reverse.steps { print("undo   : \(step)") }
        model.applyPlan()
        print("restored: \(model.note?.body.replacingOccurrences(of: "\n", with: " | ") ?? "-")")
        print("back   : plist present=\(FileManager.default.fileExists(atPath: plist)) held=\(model.snapshot.heldLabels.sorted())")
    } else {
        print("undo   : no plan — \(model.note?.title ?? "-")")
    }
    exit(0)
}

if let index = CommandLine.arguments.firstIndex(of: "--drive-start"),
   CommandLine.arguments.count > index + 1 {
    let label = CommandLine.arguments[index + 1]
    let model = AppModel(catalogDirectory: catalogDirectory())
    print("before : held=\(model.snapshot.heldLabels.sorted())")
    model.start(label: label)
    guard let plan = model.plan else {
        print("no plan: \(model.note?.title ?? "-")"); exit(1)
    }
    print("plan   : \(plan.title)")
    model.applyPlan()
    print("result : \(model.note?.body.replacingOccurrences(of: "\n", with: " | ") ?? "-")")
    model.note = nil
    print("after  : held=\(model.snapshot.heldLabels.sorted()) quiet=\(model.snapshot.quiet)")
    if let row = model.snapshot.findings.first(where: { $0.label == label }) {
        print("row    : isHeld=\(row.isHeld)")
    }
    exit(0)
}

if let index = CommandLine.arguments.firstIndex(of: "--drive-stop"),
   CommandLine.arguments.count > index + 1 {
    // Drive the window's own stop/start path without a click: the point is to see what the model
    // actually records, not to trust that it does.
    let label = CommandLine.arguments[index + 1]
    let model = AppModel(catalogDirectory: catalogDirectory())
    print("before : held=\(model.snapshot.heldLabels.sorted()) quiet=\(model.snapshot.quiet)")
    model.stop(label: label)
    guard let plan = model.plan else {
        print("no plan was produced:")
        if let note = model.note { print("  \(note.title): \(note.body)") }
        exit(1)
    }
    print("plan   : \(plan.title)")
    for step in plan.steps { print("         \(step)") }
    model.applyPlan()
    print("result : \(model.note?.body.replacingOccurrences(of: "\n", with: " | ") ?? "-")")
    model.note = nil
    print("after  : held=\(model.snapshot.heldLabels.sorted()) quiet=\(model.snapshot.quiet)")
    if let row = model.snapshot.findings.first(where: { $0.label == label }) {
        print("row    : isHeld=\(row.isHeld) state=\(row.serviceState) canStop=\(row.canStop)")
    } else {
        print("row    : no finding for \(label)")
    }
    exit(0)
}

if let index = CommandLine.arguments.firstIndex(of: "--render-app"),
   CommandLine.arguments.count > index + 1 {
    // The whole window, sidebar included — the surface a person actually sees.
    let path = CommandLine.arguments[index + 1]
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.regular)
    let model = AppModel(catalogDirectory: catalogDirectory())
    if let paneIndex = CommandLine.arguments.firstIndex(of: "--pane"),
       CommandLine.arguments.count > paneIndex + 1,
       let pane = AppModel.Pane(rawValue: CommandLine.arguments[paneIndex + 1]) {
        model.pane = pane
    }
    let hosting = NSHostingController(rootView: CurfewWindow(model: model))
    let window = NSWindow(contentViewController: hosting)
    window.styleMask = [.titled, .closable, .resizable]
    window.title = "Curfew"
    window.setContentSize(NSSize(width: 860, height: model.preferredWindowHeight))
    NSApp.activate(ignoringOtherApps: true)
    window.makeKeyAndOrderFront(nil)
    hosting.view.layoutSubtreeIfNeeded()
    RunLoop.current.run(until: Date().addingTimeInterval(1.0))
    hosting.view.layoutSubtreeIfNeeded()
    hosting.view.displayIfNeeded()
    // NavigationSplitView does not render into a bitmap, but the window's own view hierarchy can be
    // written as a PDF — which does capture it. The PNG is produced from that by `sips`.
    if let view = window.contentView,
       let pdf = view.dataWithPDF(inside: view.bounds) as Data? {
        let pdfPath = path.hasSuffix(".png") ? String(path.dropLast(4)) + ".pdf" : path + ".pdf"
        try? pdf.write(to: URL(fileURLWithPath: pdfPath))
        print("rendered \(pdfPath)")
        window.orderOut(nil)
        exit(0)
    }
    FileHandle.standardError.write(Data("no pdf\n".utf8))
    exit(1)
}

if let index = CommandLine.arguments.firstIndex(of: "--render-window"),
   CommandLine.arguments.count > index + 1 {
    // Render the real window offscreen to a PNG. No screen-recording permission needed, and it is the
    // same view the app shows — so the layout can be looked at rather than assumed.
    let path = CommandLine.arguments[index + 1]
    _ = NSApplication.shared
    let model = AppModel(catalogDirectory: catalogDirectory())
    if let paneIndex = CommandLine.arguments.firstIndex(of: "--pane"),
       CommandLine.arguments.count > paneIndex + 1,
       let pane = AppModel.Pane(rawValue: CommandLine.arguments[paneIndex + 1]) {
        model.pane = pane
    }
    // ImageRenderer cannot lay out a ScrollView (it returns an empty plate), so host the view in a
    // real offscreen window, let a display cycle run, then read the window's own backing store.
    let hosting = NSHostingController(rootView: PanePreview(model: model))
    let window = NSWindow(contentViewController: hosting)
    window.setContentSize(NSSize(width: 860, height: model.preferredWindowHeight))
    window.styleMask = [.titled]
    NSApp.activate(ignoringOtherApps: true)
    window.makeKeyAndOrderFront(nil)
    hosting.view.layoutSubtreeIfNeeded()
    RunLoop.current.run(until: Date().addingTimeInterval(0.6))
    hosting.view.layoutSubtreeIfNeeded()
    hosting.view.displayIfNeeded()

    guard let rep = hosting.view.bitmapImageRepForCachingDisplay(in: hosting.view.bounds) else {
        FileHandle.standardError.write(Data("could not make a bitmap\n".utf8)); exit(1)
    }
    hosting.view.cacheDisplay(in: hosting.view.bounds, to: rep)
    guard let png = rep.representation(using: .png, properties: [:]) else {
        FileHandle.standardError.write(Data("could not encode png\n".utf8)); exit(1)
    }
    try? png.write(to: URL(fileURLWithPath: path))
    window.orderOut(nil)
    print("rendered \(path)")
    exit(0)
}

if CommandLine.arguments.contains("--quiet-command") {
    // Print the two commands the menu item runs, so the split is inspectable without pressing it.
    guard let cli = DashboardLauncher.resolve() else {
        FileHandle.standardError.write(Data((DashboardLauncher.missingMessage() + "\n").utf8))
        exit(1)
    }
    let catalog = DashboardRunner.bundledCatalog
    let bundle = MenuBarModel.defaultQuietBundle
    print("dry run : " + DashboardLauncher.quietPreviewCommand(cli: cli, catalog: catalog, bundle: bundle))
    print("apply   : " + DashboardLauncher.quietCommand(cli: cli, catalog: catalog, bundle: bundle))
    exit(0)
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
        // The login opener starts the app in the background: a status item and a Dock icon, no window
        // appearing over whatever the owner was doing. A Finder or Dock launch opens the window.
        listenForShowRequests()
        buildMainMenu()
        // A way to see a sheet without an input device: the cua driver can read this window but its
        // AX surface refuses every input route, so presentation is proven by asking for it at launch.
        if CommandLine.arguments.contains("--open-help") { model.showingHelp = true }
        if !CommandLine.arguments.contains("--background") { showWindow() }
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
        case .startQuiet: return #selector(startQuiet)
        case .window: return #selector(openWindowAction)
        }
    }

    /// Put back everything quiet mode changed. Same two-step discipline as starting it: the plan is
    /// shown, then applied on confirmation.
    @objc func restore() {
        let journal = Journal()
        let plan = journal.restorePlan()
        guard !plan.isEmpty else {
            alert(title: "Nothing to restore", body: "Curfew is not holding any change.")
            return
        }
        let catalog = (try? CatalogLoader.load(directory: catalogDirectory()))
            ?? Catalog(entries: [], bundles: [], files: [])

        let listing = plan.map { "  · \($0.entryId ?? "?")  (\($0.action ?? "?"))" }.joined(separator: "\n")
        let dialog = NSAlert()
        dialog.messageText = "Restore \(plan.count) change(s)?"
        dialog.informativeText = "These will be put back the way they were:\n\n\(listing)"
        dialog.alertStyle = .warning
        dialog.addButton(withTitle: "Restore")
        dialog.addButton(withTitle: "Cancel")
        guard dialog.runModal() == .alertFirstButtonReturn else { return }

        let outcomes = Executor(journal: journal)
            .resume(context: ExecutionContext(domain: Domain.effective().target), catalog: catalog)
        rebuild()

        let lines = outcomes.map { "  \($0.result)  \($0.entryId)" }.joined(separator: "\n")
        alert(title: journal.held().isEmpty ? "Restored" : "Partly restored", body: lines, monospaced: true)
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

    /// The one action that can change a service. It is deliberately two steps inside one click: the
    /// dry run is shown first, and nothing is applied unless the operator reads it and presses the
    /// apply button. Rule 3 holds — there is no path here that applies an unread plan.
    @objc func startQuiet() {
        let bundle = MenuBarModel.defaultQuietBundle
        guard let cli = DashboardLauncher.resolve() else {
            alert(title: "Cannot start quiet mode", body: DashboardLauncher.missingMessage())
            return
        }
        let catalog = DashboardRunner.bundledCatalog

        let preview = run(shell: DashboardLauncher.quietPreviewCommand(
            cli: cli, catalog: catalog, bundle: bundle))
        guard preview.status == 0 else {
            alert(title: "Quiet mode cancelled", body: preview.output.isEmpty
                ? "The dry run failed (exit \(preview.status))." : preview.output)
            return
        }
        guard let changes = quietChangeCount(preview.output), changes > 0 else {
            alert(title: "Nothing to do", body: "The dry run planned no changes:\n\n\(preview.output)")
            return
        }

        let dialog = NSAlert()
        dialog.messageText = "Start quiet mode?"
        dialog.informativeText = "\(changes) service(s) will be changed on this Mac. "
            + "This is the dry run's plan; review it before applying."
        dialog.alertStyle = .warning
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 520, height: 240))
        let text = NSTextView(frame: scroll.bounds)
        text.isEditable = false
        text.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        text.string = preview.output
        scroll.documentView = text
        scroll.hasVerticalScroller = true
        dialog.accessoryView = scroll
        dialog.addButton(withTitle: "Start quiet mode")
        dialog.addButton(withTitle: "Cancel")

        guard dialog.runModal() == .alertFirstButtonReturn else { return }

        let result = run(shell: DashboardLauncher.quietCommand(cli: cli, catalog: catalog, bundle: bundle))
        rebuild()
        alert(
            title: result.status == 0 ? "Quiet mode is on" : "Quiet mode did not finish",
            body: result.output.isEmpty ? "(no output, exit \(result.status))" : result.output,
            monospaced: true)
    }

    /// "13 planned" from the dry run's own words, so the count in the dialog is the tool's, not a guess.
    func quietChangeCount(_ output: String) -> Int? {
        let lines = output.split(separator: "\n").filter { $0.contains("planned") }
        return lines.isEmpty ? nil : lines.count
    }

    func run(shell line: String) -> (status: Int32, output: String) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", line]
        let out = Pipe(), err = Pipe()
        task.standardOutput = out
        task.standardError = err
        do { try task.run() } catch {
            return (-1, "Could not run: \(error.localizedDescription)")
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        return (task.terminationStatus, String(decoding: data + errData, as: UTF8.self))
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

    private var signalSource: DispatchSourceSignal?

    /// Ask the running instance to show its window. `open -a` cannot do it when the instance was
    /// started by `exec` rather than LaunchServices, and the single-instance guard makes a second
    /// launch exit — so the hand-off is a signal, which always reaches the process that has the lock.
    private func listenForShowRequests() {
        signal(SIGUSR1, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
        source.setEventHandler { [weak self] in self?.showWindow() }
        source.resume()
        signalSource = source
    }

    /// A regular app needs a menu, and the menu is where a keyboard path belongs. Before this the app
    /// had no shortcut at all — not refresh, not start, not a pane switch.
    func buildMainMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Curfew",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Curfew", action: #selector(NSApplication.terminate(_:)),
                        keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let curfewItem = NSMenuItem()
        let curfew = NSMenu(title: "Curfew")

        let start = NSMenuItem(title: "Start Quiet Mode", action: #selector(menuStartQuiet), keyEquivalent: "Q")
        start.keyEquivalentModifierMask = [.command, .shift]
        start.target = self
        start.tag = 1
        curfew.addItem(start)

        let restore = NSMenuItem(title: "Restore Everything", action: #selector(menuRestore), keyEquivalent: "Z")
        restore.keyEquivalentModifierMask = [.command, .shift]
        restore.target = self
        curfew.addItem(restore)

        curfew.addItem(.separator())

        let refresh = NSMenuItem(title: "Refresh", action: #selector(menuRefresh), keyEquivalent: "r")
        refresh.target = self
        curfew.addItem(refresh)

        let find = NSMenuItem(title: "Filter", action: #selector(menuFilter), keyEquivalent: "f")
        find.target = self
        curfew.addItem(find)

        let help = NSMenuItem(title: "What the words mean", action: #selector(menuHelp), keyEquivalent: "/")
        help.keyEquivalentModifierMask = [.command, .shift]
        help.target = self
        curfew.addItem(help)

        curfew.addItem(.separator())
        for (index, pane) in AppModel.Pane.allCases.enumerated() {
            let item = NSMenuItem(title: pane.rawValue, action: #selector(menuPane(_:)),
                                  keyEquivalent: "\(index + 1)")
            item.tag = index
            item.target = self
            curfew.addItem(item)
        }

        curfewItem.submenu = curfew
        main.addItem(curfewItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Curfew", action: #selector(openWindowAction), keyEquivalent: "0")
        windowMenu.items.last?.target = self
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)),
                           keyEquivalent: "m")
        windowItem.submenu = windowMenu
        main.addItem(windowItem)

        NSApp.mainMenu = main
    }

    @objc func menuStartQuiet() {
        showWindow()
        model.pane = .quiet
        model.startDefault()
    }

    @objc func menuRestore() {
        showWindow()
        model.pane = .quiet
        model.restoreAll()
    }

    @objc func menuRefresh() { model.refresh() }

    @objc func menuFilter() {
        showWindow()
        model.focusSearch += 1
    }

    @objc func menuHelp() {
        showWindow()
        model.showingHelp = true
    }

    /// State-aware menu: Start is meaningless while quiet, and Restore while nothing is held.
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(menuStartQuiet): return !model.snapshot.quiet
        case #selector(menuRestore): return model.snapshot.quiet
        default: return true
        }
    }

    @objc func menuPane(_ sender: NSMenuItem) {
        showWindow()
        let panes = AppModel.Pane.allCases
        guard sender.tag >= 0, sender.tag < panes.count else { return }
        model.pane = panes[sender.tag]
    }

    /// The window is the main surface (owner decision, 2026-11-26). The status item stays as a
    /// shortcut; closing the window leaves the app running so the menu bar item survives.
    private var window: NSWindow?
    private lazy var model = AppModel(catalogDirectory: catalogDirectory())

    @objc func openWindowAction() { showWindow() }

    func showWindow() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            model.refresh()
            return
        }
        let hosting = NSHostingController(rootView: CurfewWindow(model: model))
        let created = NSWindow(contentViewController: hosting)
        created.title = BuildIdentity.windowTitle
        created.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        created.titlebarAppearsTransparent = false
        created.setContentSize(NSSize(width: 860, height: model.preferredWindowHeight))
        created.center()
        created.isReleasedWhenClosed = false
        window = created
        created.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Closing the window must not quit: the app is a menu bar utility with a window.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { showWindow() }
        return true
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

// One instance only. The login opener execs this binary directly, so LaunchServices does not
// deduplicate it against a later `open -a` — two instances meant two status items and two windows.
// A lock file makes that deterministic; the early-exit flag paths above never reach here, so they are
// unaffected.
let lockPath = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/Curfew/curfew-app.lock").path
try? FileManager.default.createDirectory(
    atPath: (lockPath as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
let lockFD = open(lockPath, O_CREAT | O_RDWR, 0o644)
if lockFD >= 0, flock(lockFD, LOCK_EX | LOCK_NB) != 0 {
    // Another instance is the app. Instead of sulking, ask it to show its window — this is what makes
    // `open -a`, and a Dock click, bring the window forward even though LaunchServices never registered
    // the instance the login opener `exec`ed.
    if let holder = try? String(contentsOfFile: lockPath, encoding: .utf8),
       let pid = pid_t(holder.trimmingCharacters(in: .whitespacesAndNewlines)) {
        kill(pid, SIGUSR1)
        print("Curfew is already running (pid \(pid)) — asked it to show its window.")
    } else {
        print("Curfew is already running.")
    }
    exit(0)
}
if lockFD >= 0 {
    ftruncate(lockFD, 0)
    let me = "\(ProcessInfo.processInfo.processIdentifier)\n"
    _ = me.withCString { write(lockFD, $0, strlen($0)) }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
