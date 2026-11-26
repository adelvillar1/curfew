import AppKit
import CurfewKit
import SwiftUI

/// The window's state and its actions. Everything that changes a service goes through the same
/// `Executor` and `Journal` the CLI uses — the window is a surface, never a second implementation.
@MainActor
final class AppModel: ObservableObject {
    enum Pane: String, CaseIterable, Identifiable {
        case quiet = "Quiet mode"
        case bundles = "Bundles"
        case findings = "Findings"
        case services = "Services"
        case apps = "Apps"
        var id: String { rawValue }

        /// The sidebar is built from `allCases`, so adding a pane can never leave it unreachable —
        /// which is exactly how the Apps pane shipped without a row to select it (KI-052).
        var section: String {
            switch self {
            case .quiet: return "Mode"
            case .bundles: return "Bundles"
            case .findings, .services, .apps: return "This machine"
            }
        }

        static let sections = ["Mode", "Bundles", "This machine"]

        var symbol: String {
            switch self {
            case .quiet: return "moon.zzz"
            case .bundles: return "square.stack.3d.up"
            case .findings: return "stethoscope"
            case .services: return "list.bullet.rectangle"
            case .apps: return "square.grid.2x2"
            }
        }
    }

    /// What a confirmed plan will do. Carried as data rather than a closure so the work can run off the
    /// main actor and report each step as it lands (the critique's P2: a synchronous apply froze the
    /// window with no progress).
    enum PlanAction: Sendable {
        case bundle(String)
        case entries([String])
        case restore(labels: Set<String>?)
        case quarantine(label: String, plist: String)
        case quitApp(bundle: String, pids: [Int32], name: String)
    }

    /// A plan the window is showing before it applies anything.
    struct Plan: Identifiable {
        let id = UUID()
        var title: String
        var detail: String
        var steps: [String]
        var action: PlanAction
    }

    /// Rows ticked while a plan runs.
    @Published var progress: [String] = []

    enum ServiceSort: String, CaseIterable, Identifiable {
        case name = "Name", state = "State", findings = "Findings"
        var id: String { rawValue }
        var asListSort: ServiceList.Sort {
            switch self {
            case .name: return .name
            case .state: return .state
            case .findings: return .findings
            }
        }
    }

    enum AppSort: String, CaseIterable, Identifiable {
        case memory = "Memory", name = "Name"
        var id: String { rawValue }
    }

    /// One sheet at a time, as SwiftUI requires — three `.sheet` modifiers on one view meant only the
    /// first ever presented, so Help was unreachable (KI-063).
    enum Sheet: Identifiable {
        case plan(Plan)
        case note(Note)
        case help

        var id: String {
            switch self {
            case .plan(let plan): return "plan-\(plan.id)"
            case .note(let note): return "note-\(note.id)"
            case .help: return "help"
            }
        }

        var planValue: Plan? { if case .plan(let plan) = self { return plan }; return nil }
    }

    /// Whichever is set, presented through a single binding.
    var activeSheet: Sheet? {
        if showingHelp { return .help }
        if let plan { return .plan(plan) }
        if let note { return .note(note) }
        return nil
    }

    var sheetBinding: Binding<Sheet?> {
        Binding(
            get: { [weak self] in self?.activeSheet },
            set: { [weak self] newValue in
                guard let self, newValue == nil else { return }
                self.showingHelp = false
                self.plan = nil
                self.note = nil
            }
        )
    }

    struct Note: Identifiable {
        let id = UUID()
        var title: String
        var body: String
    }

    @Published private(set) var snapshot = AppSnapshot(quiet: false)
    @Published var pane: Pane = .quiet
    /// Held in the model, not the view: a sort must survive switching panes.
    @Published var serviceSort: ServiceSort = .name
    @Published var appSort: AppSort = .memory
    /// Bumped by ⌘F; a pane watches it and focuses its search field.
    @Published var focusSearch = 0
    @Published var showingHelp = false

    /// C5: with a two-row Held list the window should not leave a void above its footer. Height is
    /// derived from what the landing pane will actually draw, clamped to sane bounds.
    var preferredWindowHeight: CGFloat {
        let rows = snapshot.quiet ? max(snapshot.held.count, 1) : 0
        let header: CGFloat = 90           // state line, sentence, padding
        let memory: CGFloat = snapshot.quiet || snapshot.lastSession == nil ? 0 : 22
        let list: CGFloat = rows == 0 ? 210 : CGFloat(rows) * 30 + 34
        let footer: CGFloat = 30
        return min(max(header + memory + list + footer + 8, 260), 640)
    }
    @Published var plan: Plan?
    @Published var note: Note?
    @Published var busy = false

    private let catalogDirectory: URL
    private let journal = Journal()

    init(catalogDirectory: URL) {
        self.catalogDirectory = catalogDirectory
        refresh()
    }

    func refresh() {
        let frontmost = NSWorkspace.shared.frontmostApplication?.bundleURL?.path
        snapshot = AppSnapshotProvider.load(
            catalogDirectory: catalogDirectory, journal: journal, frontmost: frontmost)
    }

    /// Freeze an app: instant, reversible, and the app never knows. The default verb.
    func freeze(_ app: AppRecord) {
        do {
            let outcome = try AppControl(journal: journal).freeze(app)
            refresh()
            note = Note(title: seen(outcome), body: "\(app.name) · \(Int(app.memoryMB)) MB. Freeze is reversible: Restore puts it back where it was.")
        } catch {
            note = Note(title: "Could not freeze \(app.name)", body: error.localizedDescription)
        }
    }

    /// Resume a frozen app: SIGCONT, instant and safe, so it needs no confirmation.
    func thaw(_ app: AppRecord) {
        let pending = journal.restorePlan().filter {
            $0.entryId == app.bundlePath && $0.action == "freeze"
        }
        guard !pending.isEmpty else {
            note = Note(title: "Not frozen by Curfew",
                        body: "\(app.name) is not something Curfew stopped, so there is nothing to resume.")
            return
        }
        let outcomes = Executor(journal: journal)
            .resume(context: context, catalog: catalog, labels: [app.bundlePath])
        refresh()
        let lines = outcomes.map { "\(Self.mark($0.result))  \($0.entryId)  \(Self.describe($0.result))" }
        let title = outcomes.first.map { seen($0) } ?? "Nothing to resume"
        note = Note(title: title, body: lines.isEmpty ? "No change was needed." : lines.joined(separator: "\n"))
    }

    /// Quit asks first: an app can lose unsaved work.
    func askToQuit(_ app: AppRecord) {
        plan = Plan(
            title: "Quit \(app.name)?",
            detail: "This asks the app to quit and it may prompt to save. Freezing is reversible; quitting is not.",
            steps: ["\(app.bundlePath)", "  \(app.pids.count) process\(app.pids.count == 1 ? "" : "s") · \(Int(app.memoryMB)) MB"],
            action: .quitApp(bundle: app.bundlePath, pids: app.pids, name: app.name))
    }

    private func seen(_ outcome: StepOutcome) -> String {
        switch outcome.result {
        case .executed: return "Frozen"
        case .failed(let why): return why
        default: return "Done"
        }
    }

    private var catalog: Catalog {
        (try? CatalogLoader.load(directory: catalogDirectory))
            ?? Catalog(entries: [], bundles: [], files: [])
    }

    private var context: ExecutionContext {
        let records = LaunchdInventory().records(in: Domain.effective(), findings: FindingsEngine()).records
        let listeners = ListenerScanner().scan()
        return ExecutionContext(
            domain: Domain.effective().target, records: records, listeners: listeners,
            protectedPorts: Set(CatalogPlanner.plan(bundle: "", in: catalog).protectedPorts))
    }

    // MARK: Bundles

    /// Preview a bundle: a dry run, shown, then applied only on confirmation (D30).
    func preview(bundle name: String) {
        let plan = Executor(journal: journal).apply(
            bundle: name, catalog: catalog, context: context, execute: false)
        let lines = plan.map { "\(Self.mark($0.result))  \($0.entryId)  \(Self.describe($0.result))" }
        guard !lines.isEmpty else {
            note = Note(title: "Nothing to do", body: "The bundle planned no changes.")
            return
        }
        self.plan = Plan(
            title: "Preview — \(name)",
            detail: "Nothing has been touched. Applying runs these changes and records them.",
            steps: lines,
            action: .bundle(name))
    }

    /// A result as one short line — the same vocabulary the CLI prints, so the two never disagree.
    nonisolated static func mark(_ result: StepResult) -> String {
        switch result {
        case .planned: return "·"
        case .refused: return "✕"
        case .executed(let verified): return verified ? "✓" : "!"
        case .failed: return "✗"
        case .preExisting: return "–"
        }
    }

    nonisolated static func describe(_ result: StepResult) -> String {
        switch result {
        case .planned: return "would change"
        case .refused(let why): return why
        case .executed(let verified): return verified ? "changed and verified" : "changed, could not verify"
        case .failed(let why): return why
        case .preExisting(let note): return note
        }
    }

    // MARK: Start / restore

    func startDefault() {
        preview(bundle: MenuBarModel.defaultQuietBundle)
    }

    func restoreAll() {
        let pending = journal.restorePlan()
        guard !pending.isEmpty else {
            note = Note(title: "Nothing to restore", body: "Curfew is not holding any change.")
            return
        }
        plan = Plan(
            title: "Restore \(pending.count) change\(pending.count == 1 ? "" : "s")?",
            detail: "These go back the way they were. Nothing else is touched.",
            steps: pending.map { "\($0.entryId ?? "?")  \(Vocabulary.action($0.action ?? "?"))" },
            action: .restore(labels: nil))
    }

    // MARK: One service

    func stop(label: String) {
        let plan = Executor(journal: journal).apply(
            entryIds: [label], catalog: catalog, context: context, execute: false)
        let lines = plan.map { "\(Self.mark($0.result))  \($0.entryId)  \(Self.describe($0.result))" }
        guard !lines.isEmpty else {
            note = Note(title: "Cannot stop \(label)",
                        body: "No verified stop recipe applies to it. `curfew why \(label)` shows what it is.")
            return
        }
        self.plan = Plan(
            title: "Stop \(label)?",
            detail: "Nothing has been touched yet.",
            steps: lines,
            action: .entries([label]))
    }

    /// Put back one service — the per-finding Start. Undoes exactly this label and nothing else.
    func start(label: String) {
        let pending = journal.restorePlan().filter { $0.entryId == label }
        guard !pending.isEmpty else {
            note = Note(title: "Nothing to start", body: "Curfew is not holding \(label).")
            return
        }
        plan = Plan(
            title: "Start \(label)?",
            detail: "This undoes Curfew's stop. Nothing else is touched.",
            steps: pending.map { "\($0.entryId ?? "?")  \(Vocabulary.action($0.action ?? "?"))" },
            action: .restore(labels: [label]))
    }

    /// Move a stale plist to quarantine — offered only where the owning app is verifiably gone.
    /// Never deletes: `resume` puts the file back.
    func quarantine(label: String) {
        let records = LaunchdInventory().records(in: Domain.effective(), findings: FindingsEngine()).records
        guard let record = records.first(where: { $0.id == label }), let plist = record.plistPath else {
            note = Note(title: "Cannot quarantine \(label)", body: "Its plist could not be located.")
            return
        }
        switch QuarantineEligibility.judge(program: record.program, plistPath: plist) {
        case .refuse(let why):
            note = Note(title: "Cannot quarantine \(label)", body: why)
        case .eligible(let owner):
            plan = Plan(
                title: "Quarantine \(label)?",
                detail: "\(owner) is gone. The stale plist moves to Curfew's quarantine — it is not deleted, and Restore puts it back.",
                steps: ["\(plist)", "  → Application Support/Curfew/quarantine/…"],
                action: .quarantine(label: label, plist: plist))
        }
    }

    /// Run a confirmed plan off the main actor, ticking rows as each step lands.
    func applyPlan() {
        guard let plan else { return }
        busy = true
        progress = []
        let action = plan.action
        let journal = self.journal
        let catalog = self.catalog
        let context = self.context

        Task.detached(priority: .userInitiated) { [weak self] in
            let report: @Sendable (StepOutcome) -> Void = { outcome in
                let line = "\(Self.mark(outcome.result))  \(outcome.entryId)  \(Self.describe(outcome.result))"
                Task { @MainActor in self?.progress.append(line) }
            }
            let executor = Executor(journal: journal)
            var extra: [String] = []
            switch action {
            case .bundle(let name):
                _ = executor.apply(bundle: name, catalog: catalog, context: context,
                                   execute: true, onStep: report)
            case .entries(let ids):
                _ = executor.apply(entryIds: ids, catalog: catalog, context: context,
                                   execute: true, onStep: report)
            case .restore(let labels):
                _ = executor.resume(context: context, catalog: catalog, labels: labels, onStep: report)
            case .quarantine(let label, let plist):
                do {
                    let outcome = try QuarantineStore().quarantine(
                        plistPath: plist, label: label, journal: journal)
                    report(outcome)
                } catch {
                    extra.append("✗  \(label)  \(error.localizedDescription)")
                }
            case .quitApp(let bundle, let pids, let name):
                do {
                    let outcome = try AppControl(journal: journal)
                        .quit(AppRecord(name: name, bundlePath: bundle, pids: pids,
                                        memoryBytes: 0, isFrozen: false, isFrontmost: false))
                    report(outcome)
                } catch {
                    extra.append("✗  \(name)  \(error.localizedDescription)")
                }
            }
            let lines = await MainActor.run { self?.progress ?? [] }
            await MainActor.run {
                guard let self else { return }
                self.busy = false
                self.plan = nil
                self.refresh()
                let body = (lines + extra)
                self.note = Note(title: body.allSatisfy { $0.hasPrefix("✓") } ? "Done" : "Finished",
                                 body: body.isEmpty ? "No change was needed." : body.joined(separator: "\n"))
            }
        }
    }
}

// MARK: - The window

struct CurfewWindow: View {
    @ObservedObject var model: AppModel

    var body: some View {
        NavigationSplitView {
            Sidebar(model: model)
                .navigationSplitViewColumnWidth(min: 190, ideal: 200, max: 240)
        } detail: {
            Detail(model: model)
        }
        .frame(minWidth: 720, minHeight: 260)
        .sheet(item: model.sheetBinding) { sheet in
            switch sheet {
            case .plan(let plan): ConfirmationSheet(model: model, plan: plan)
            case .note(let note): ResultSheet(note: note)
            case .help: HelpSheet()
            }
        }
    }
}

private struct Sidebar: View {
    @ObservedObject var model: AppModel

    var body: some View {
        List(selection: $model.pane) {
            ForEach(AppModel.Pane.sections, id: \.self) { section in
                Section(section) {
                    ForEach(AppModel.Pane.allCases.filter { $0.section == section }) { pane in
                        Label(pane.rawValue, systemImage: pane.symbol)
                            .badge(badge(for: pane))
                            .tag(pane)
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }

    /// Only a count that means something carries a badge; the rest stay quiet.
    private func badge(for pane: AppModel.Pane) -> Int {
        switch pane {
        case .findings: return model.snapshot.findings.count
        case .apps: return model.snapshot.apps.count
        default: return 0
        }
    }
}

/// What build is running, read from the bundle the app was installed as.
enum BuildIdentity {
    /// The title bar is chrome the eye lands on; the build belongs there so "is this the new one?"
    /// never needs a command line again.
    static var windowTitle: String { "Curfew — " + shortBuild }

    static var shortBuild: String {
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unversioned"
        return build.components(separatedBy: " built ").first ?? build
    }

    static var text: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? curfewVersion
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unversioned"
        return "Curfew \(version) · \(build)"
    }
}

private struct Detail: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
        Group {
            if let problem = model.snapshot.problem {
                EmptyState(title: "Curfew is not ready", message: problem)
            } else {
                switch model.pane {
                case .quiet: QuietPane(model: model)
                case .bundles: BundlesPane(model: model)
                case .findings: FindingsPane(model: model)
                case .services: ServicesPane(model: model)
                case .apps: AppsPane(model: model)
                }
            }
        }

        Divider()
        HStack(spacing: 8) {
            Text(BuildIdentity.text)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Help") { model.showingHelp = true }
                .buttonStyle(.borderless)
                .font(.caption)
                .keyboardShortcut("/", modifiers: [.command, .shift])
                .help("What held, protected, quiesce and the finding kinds mean (⌘?)")
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 6)
        }
    }
}

// MARK: - Quiet mode (the first thing seen)

private struct QuietPane: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // The answer, at the top, in the largest type on the surface, with the one action
                // that reverses or creates it on the same line.
                HStack(alignment: .firstTextBaseline, spacing: 16) {
                    Text(model.snapshot.stateLine)
                        .font(.system(.title2, weight: .semibold))
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 12)
                    Button(model.snapshot.quiet ? "Restore all" : "Start quiet mode…") {
                        model.snapshot.quiet ? model.restoreAll() : model.startDefault()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .tint(.accentColor)
                }
                .padding(.horizontal, 24)
                .padding(.top, 22)

                Text(model.snapshot.quiet
                     ? "Restoring puts each of these back the way it was. Nothing else is touched."
                     : "Quiet mode stops the vendor services a build does not need. You will see the plan before anything changes.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 24)
                    .padding(.top, 5)

                // The app's own memory: the last completed session, read from the journal.
                if !model.snapshot.quiet, let last = model.snapshot.lastSession {
                    Text("Last quiet mode ended \(whenText(last.ended)) — \(last.changes) service\(last.changes == 1 ? "" : "s") restored.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .padding(.horizontal, 24)
                        .padding(.top, 8)
                }

                Divider().padding(.top, 18)

                if model.snapshot.quiet {
                    HeldList(model: model)
                } else {
                    IdleSummary(model: model)
                }
            }
        }
    }
}

/// "today at 6:16 AM", "yesterday at 11:10 PM", or a dated fallback — a person's phrasing, not a
/// locale dump.
func whenText(_ date: Date) -> String {
    let calendar = Calendar.current
    let time = date.formatted(date: .omitted, time: .shortened)
    if calendar.isDateInToday(date) { return "today at \(time)" }
    if calendar.isDateInYesterday(date) { return "yesterday at \(time)" }
    return "\(date.formatted(date: .abbreviated, time: .omitted)) at \(time)"
}

private struct HeldList: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Held")
                .font(.headline)
                .padding(.horizontal, 24)

            // A short list sizes to its rows so the window can size to it (C5); a long one scrolls.
            if model.snapshot.held.count > 6 {
                ScrollView { rows }
                    .frame(minHeight: 160)
            } else {
                rows
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var rows: some View {
        LazyVStack(spacing: 0) {
            ForEach(model.snapshot.held) { held in
                HStack(spacing: 12) {
                    Image(systemName: "pause.circle")
                        .foregroundStyle(.secondary)
                    Text(held.label)
                        .font(.system(.body, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Text(held.action)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(held.when.prefix(16).replacingOccurrences(of: "T", with: " "))
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 7)
                .padding(.horizontal, 24)
                Divider().padding(.leading, 24)
            }
        }
    }
}

private struct IdleSummary: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("What quiet mode would stop")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 24)
                .padding(.top, 16)

            if let bundle = model.snapshot.stopBundles.first(where: {
                $0.name == MenuBarModel.defaultQuietBundle
            }) ?? model.snapshot.stopBundles.first {
                VStack(alignment: .leading, spacing: 3) {
                    Text(bundle.name)
                        .font(.system(.body, design: .monospaced))
                    Text(bundle.summary)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("\(bundle.acting) of \(bundle.members) services would change")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 24)
                .padding(.top, 8)

                Button("Preview the plan") { model.preview(bundle: bundle.name) }
                    .buttonStyle(.link)
                    .padding(.horizontal, 24)
                    .padding(.top, 6)
            } else {
                Text("No stop bundle in the catalogue.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 24)
                    .padding(.top, 8)
            }

            if !model.snapshot.protectBundles.isEmpty {
                Text("Never touched: \(model.snapshot.protectBundles.map(\.name).joined(separator: ", "))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 24)
                    .padding(.top, 14)
            }

            Divider().padding(.top, 18)

            HStack(spacing: 6) {
                Text("\(model.snapshot.findings.count) finding\(model.snapshot.findings.count == 1 ? "" : "s") · \(model.snapshot.services.count) services on this machine")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button("Review what is wrong") { model.pane = .findings }
                    .buttonStyle(.link)
                    .disabled(model.snapshot.findings.isEmpty)
                Spacer()
            }
            .padding(.horizontal, 24)
            .padding(.top, 14)
        }
    }
}


// MARK: - Bundles

private struct BundlesPane: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // C4: a pane of disabled buttons is indistinguishable from a broken one — say why, once,
            // with the action that changes it.
            if model.snapshot.quiet {
                HStack(spacing: 10) {
                    Image(systemName: "moon.zzz").foregroundStyle(.secondary)
                    Text("Quiet mode is on — restore first to preview or change a bundle.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Restore all") { model.restoreAll() }
                        .controlSize(.small)
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 10)
                .background(.quaternary.opacity(0.3))
                Divider()
            }

        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                SectionHeader("Stop")
                ForEach(model.snapshot.stopBundles) { bundle in
                    BundleRow(model: model, bundle: bundle)
                        .padding(.horizontal, 24)
                    Divider().padding(.leading, 24)
                }
                if !model.snapshot.protectBundles.isEmpty {
                    SectionHeader("Protected — never actioned")
                    ForEach(model.snapshot.protectBundles) { bundle in
                        BundleRow(model: model, bundle: bundle)
                            .padding(.horizontal, 24)
                        Divider().padding(.leading, 24)
                    }
                }
            }
            .padding(.top, 8)
        }
        }
    }
}

private struct BundleRow: View {
    @ObservedObject var model: AppModel
    let bundle: AppSnapshot.Bundle

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(bundle.name)
                    .font(.system(.body, design: .monospaced, weight: .medium))
                Text(bundle.summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(bundle.isProtect
                     ? "\(bundle.members) member\(bundle.members == 1 ? "" : "s") · protected"
                     : "\(bundle.acting) of \(bundle.members) would change")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if !bundle.isProtect {
                Button("Preview") { model.preview(bundle: bundle.name) }
                    .disabled(bundle.acting == 0 || model.snapshot.quiet)
                    .help(model.snapshot.quiet
                          ? "Restore first — the machine is already quiet."
                          : bundle.acting == 0 ? "Nothing in this bundle would change." : "")
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Findings

private struct FindingsPane: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Group {
            if model.snapshot.findings.isEmpty {
                EmptyState(
                    title: "No findings",
                    message: "Nothing on this machine looks wrong right now. Curfew checks for crash "
                        + "loops, dead programs, stale plists and unsupervised services.")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        SectionHeader(findingsHeader(model.snapshot))
                        ForEach(model.snapshot.findings) { finding in
                            FindingRow(model: model, finding: finding)
                            Divider().padding(.leading, 24)
                        }
                    }
                }
            }
        }
    }
}

/// The findings count, plus the orphans that are not launchd jobs at all (D43).
private func findingsHeader(_ snapshot: AppSnapshot) -> String {
    let base = "\(snapshot.findings.count) findings, most serious first"
    guard let orphans = OrphanScan.summary(snapshot.orphans) else { return base }
    return base + " · " + orphans
}

private struct FindingRow: View {
    @ObservedObject var model: AppModel
    let finding: AppSnapshot.Finding

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            SeverityDot(severity: finding.severity)
            VStack(alignment: .leading, spacing: 3) {
                Text(finding.summary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    Text(finding.severity)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    Text("·").font(.caption).foregroundStyle(.secondary)
                    Text("\(finding.label) · \(finding.kind)")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if finding.isHeld {
                        Text("· held by Curfew")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                    } else if finding.serviceState != "running" {
                        Text("· \(finding.serviceState)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Spacer()
            Button("Investigate") {
                model.note = AppModel.Note(
                    title: "\(finding.label) — \(finding.kind)",
                    body: finding.evidence)
            }
            .buttonStyle(.link)
            // State-aware: the same row offers Stop before and Start after, and says which it is.
            if finding.isHeld {
                Button("Start") { model.start(label: finding.label) }
                    .help("Put \(finding.label) back the way it was.")
            } else if finding.canStop {
                Button("Stop") { model.stop(label: finding.label) }
                    .help("Stop \(finding.label) and record it, so it can be put back.")
            }
            if finding.canQuarantine {
                // Destructive: it asks in a sheet, and a link is the weight such a verb earns.
                Button("Quarantine…") { model.quarantine(label: finding.label) }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help(finding.quarantineNote)
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 24)
    }
}

private struct SeverityDot: View {
    let severity: String
    var body: some View {
        Circle()
            .fill(colour)
            .frame(width: 8, height: 8)
            .padding(.top, 6)
            .accessibilityLabel(severity)
    }

    private var colour: Color {
        switch severity {
        case "blocker": return .red
        case "defect": return .orange
        case "gap": return .yellow
        case "risk": return .purple
        case "improvement": return .blue
        default: return .secondary
        }
    }
}

// MARK: - Services

private struct ServicesPane: View {
    @ObservedObject var model: AppModel
    @State private var query = ""
    @FocusState private var searchFocused: Bool

    /// Grouped, sorted and filtered by the tested list logic, not by the view (C2, C3).
    private var groups: [(name: String, rows: [AppSnapshot.Service])] {
        ServiceList.present(model.snapshot.services, query: query, sort: model.serviceSort.asListSort)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // The controls and the column names live in the pane, not behind `.searchable`, which does
            // not render in this window.
            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Filter by name or label", text: $query)
                        .textFieldStyle(.plain)
                        .focused($searchFocused)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 6))
                // A field that takes focus must show it: this one carried none at all.
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(searchFocused ? Color.accentColor : .clear, lineWidth: 2)
                )
                .frame(maxWidth: 320)

                Spacer()

                Picker("Sort", selection: $model.serviceSort) {
                    ForEach(AppModel.ServiceSort.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(width: 120)
            }
            .padding(.horizontal, 24)
            .padding(.top, 12)
            .padding(.bottom, 8)

            HStack(spacing: 12) {
                Text("NAME").frame(maxWidth: .infinity, alignment: .leading)
                Text("STATE").frame(width: 110, alignment: .leading)
                Text("TIER").frame(width: 80, alignment: .leading)
                Text("FINDINGS").frame(width: 66, alignment: .trailing)
            }
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 24)
            .padding(.bottom, 6)

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(groups, id: \.name) { group in
                        Text("\(group.name) · \(group.rows.count)")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 24)
                            .padding(.top, 14)
                            .padding(.bottom, 4)
                        ForEach(group.rows) { service in
                            ServiceRow(service: service)
                            Divider().padding(.leading, 24)
                        }
                    }
                    if groups.isEmpty {
                        Text("Nothing matches “\(query)”.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 24)
                            .padding(.top, 18)
                    }
                }
            }
        }
        .onChange(of: model.focusSearch) { _ in searchFocused = true }
    }
}

private struct ServiceRow: View {
    let service: AppSnapshot.Service

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text(service.displayName)
                    .lineLimit(1)
                    .truncationMode(.tail)
                // The identifier stays, demoted: the display name is for recognition, this is for the CLI.
                Text(service.label)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(service.state)
                .font(.caption)
                .foregroundStyle(service.state == "running" ? .primary : .secondary)
                .frame(width: 110, alignment: .leading)
            Text(Vocabulary.tier(service.tier))
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 80, alignment: .leading)
            Text(service.findingCount > 0 ? "\(service.findingCount)" : "—")
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(service.findingCount > 0 ? .primary : .secondary)
                .frame(width: 66, alignment: .trailing)
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 24)
    }
}

// MARK: - Help

struct HelpSheet: View {
    @Environment(\.dismiss) private var dismiss

    private let entries: [(String, String)] = [
        ("Held", "Something Curfew stopped, disabled or moved, and can still put back. Restore undoes it."),
        ("Protected bundle", "A set Curfew never actions: the harness, developer tooling, and services whose "
            + "absence costs minutes rather than bytes. It exists so those can never be stopped by accident."),
        ("Quiesce", "A check made immediately before a stop: is anything using this service right now? A busy "
            + "answer refuses the stop."),
        ("Program missing", "The job points at something that no longer exists on disk — often an app that was "
            + "removed and left its launcher behind."),
        ("Could not read its config", "launchd reports the job but some of its fields could not be read, so "
            + "Curfew cannot fully describe it."),
        ("Waiting to start", "The job is loaded and idle; launchd will run it on demand or on its schedule."),
        ("Frozen", "The app's processes are suspended with SIGSTOP. It resumes exactly where it stopped."),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("What the words mean").font(.title3.weight(.semibold))
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(entries, id: \.0) { term, meaning in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(term).font(.callout.weight(.semibold))
                            Text(meaning)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 560, height: 460)
    }
}

// MARK: - Shared pieces

// MARK: - Apps

private struct AppsPane: View {
    @ObservedObject var model: AppModel

    /// The sort choice lives in the model, so ⌘5 → ⌘1 → ⌘5 comes back in the same order (C3).
    private var apps: [AppRecord] {
        let rows = model.snapshot.apps
        switch model.appSort {
        case .memory: return rows.sorted { $0.memoryBytes > $1.memoryBytes }
        case .name: return rows.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
    }

    var body: some View {
        let apps = apps
        Group {
            if apps.isEmpty {
                EmptyState(title: "No apps to show",
                           message: "Curfew lists the apps that are running, biggest first. The shell and the harness are never listed.")
            } else {
                VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Spacer()
                    Picker("Sort", selection: $model.appSort) {
                        ForEach(AppModel.AppSort.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .frame(width: 120)
                }
                .padding(.horizontal, 24)
                .padding(.top, 10)

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        SectionHeader("\(apps.count) apps · \(Int(apps.reduce(0) { $0 + $1.memoryMB })) MB")
                        ForEach(apps) { app in
                            AppRow(model: model, app: app)
                            Divider().padding(.leading, 24)
                        }
                    }
                }
                }
            }
        }
    }
}

private struct AppRow: View {
    @ObservedObject var model: AppModel
    let app: AppRecord

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(app.name)
                    if app.isFrontmost {
                        Text("· in front").font(.caption).foregroundStyle(.secondary)
                    }
                    if app.isFrozen {
                        Text("· frozen").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                    }
                }
                Text("\(app.pids.count) process\(app.pids.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text("\(Int(app.memoryMB)) MB")
                .font(.callout)
                .monospacedDigit()
                .foregroundStyle(.secondary)
            // State-aware: the same row offers Freeze before and Resume after (KI-053).
            if app.isFrozen {
                Button("Resume") { model.thaw(app) }
                    .buttonStyle(.bordered)
                    .help("Let \(app.name) run again — it continues exactly where it stopped.")
            } else {
                Button("Freeze") { model.freeze(app) }
                    .buttonStyle(.bordered)
                    .help("Suspend the app's processes. Resume continues it exactly where it was.")
            }
            Button("Quit…") { model.askToQuit(app) }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Ask the app to quit. It may prompt to save, and it cannot be undone.")
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 24)
    }
}

private struct SectionHeader: View {
    let title: String
    init(_ title: String) { self.title = title }
    var body: some View {
        Text(title)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 24)
            .padding(.top, 18)
            .padding(.bottom, 6)
    }
}

private struct EmptyState: View {
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 8) {
            Text(title).font(.headline)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}

private struct ConfirmationSheet: View {
    @ObservedObject var model: AppModel
    let plan: AppModel.Plan

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(plan.title).font(.title3.weight(.semibold))
            Text(plan.detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    if model.progress.isEmpty {
                        ForEach(plan.steps, id: \.self) { step in
                            Text(step)
                                .font(.system(.callout, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    } else {
                        // Rows tick as each step lands, so the window never looks hung.
                        ForEach(model.progress, id: \.self) { line in
                            Text(line)
                                .font(.system(.callout, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        ProgressView().controlSize(.small).padding(.top, 6)
                    }
                }
                .padding(10)
            }
            .frame(height: 180)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))

            HStack {
                Spacer()
                Button("Cancel") { model.plan = nil }
                    .keyboardShortcut(.cancelAction)
                Button("Apply") { model.applyPlan() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.busy)
            }
        }
        .padding(24)
        .frame(width: 560)
    }
}

private struct ResultSheet: View {
    let note: AppModel.Note

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(note.title).font(.title3.weight(.semibold))
            ScrollView {
                Text(note.body)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 160)
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 560)
    }

    @Environment(\.dismiss) private var dismiss
}

/// What `--render-window` draws: one detail pane on the window background. `NavigationSplitView` and
/// `List` are AppKit-backed and cannot render outside a hosting window, while these panes are pure
/// SwiftUI — so this is the part that can be looked at offscreen, and it is the part with the design.
struct PanePreview: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color(nsColor: .windowBackgroundColor)
            switch model.pane {
            case .quiet: QuietPane(model: model)
            case .bundles: BundlesPane(model: model)
            case .findings: FindingsPane(model: model)
            case .services: ServicesPane(model: model)
            case .apps: AppsPane(model: model)
            }
        }
        .frame(width: 860, height: 560)
    }
}

