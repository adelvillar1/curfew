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

    /// A plan the window is showing before it applies anything.
    struct Plan: Identifiable {
        let id = UUID()
        var title: String
        var detail: String
        var steps: [String]
        var apply: () -> [String]
    }

    struct Note: Identifiable {
        let id = UUID()
        var title: String
        var body: String
    }

    @Published private(set) var snapshot = AppSnapshot(quiet: false)
    @Published var pane: Pane = .quiet
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

    /// Quit asks first: an app can lose unsaved work.
    func askToQuit(_ app: AppRecord) {
        plan = Plan(
            title: "Quit \(app.name)?",
            detail: "This asks the app to quit and it may prompt to save. Freezing is reversible; quitting is not.",
            steps: ["\(app.bundlePath)", "  \(app.pids.count) process\(app.pids.count == 1 ? "" : "s") · \(Int(app.memoryMB)) MB"],
            apply: { [weak self] in
                guard let self else { return [] }
                do {
                    let outcome = try AppControl(journal: self.journal).quit(app)
                    self.refresh()
                    return ["\(Self.mark(outcome.result))  \(app.name)  \(Self.describe(outcome.result))"]
                } catch {
                    return ["✗  \(app.name)  \(error.localizedDescription)"]
                }
            })
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
            apply: { [weak self] in
                guard let self else { return [] }
                let outcomes = Executor(journal: self.journal).apply(
                    bundle: name, catalog: self.catalog, context: self.context, execute: true)
                self.refresh()
                return outcomes.map { "\(Self.mark($0.result))  \($0.entryId)  \(Self.describe($0.result))" }
            })
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
            steps: pending.map { "\($0.entryId ?? "?")  \($0.action ?? "?")" },
            apply: { [weak self] in
                guard let self else { return [] }
                let outcomes = Executor(journal: self.journal)
                    .resume(context: self.context, catalog: self.catalog)
                self.refresh()
                return outcomes.map { "\(Self.mark($0.result))  \($0.entryId)  \(Self.describe($0.result))" }
            })
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
            apply: { [weak self] in
                guard let self else { return [] }
                let outcomes = Executor(journal: self.journal).apply(
                    entryIds: [label], catalog: self.catalog, context: self.context, execute: true)
                self.refresh()
                return outcomes.map { "\(Self.mark($0.result))  \($0.entryId)  \(Self.describe($0.result))" }
            })
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
            steps: pending.map { "\($0.entryId ?? "?")  \($0.action ?? "?")" },
            apply: { [weak self] in
                guard let self else { return [] }
                let outcomes = Executor(journal: self.journal)
                    .resume(context: self.context, catalog: self.catalog, labels: [label])
                self.refresh()
                return outcomes.map { "\(Self.mark($0.result))  \($0.entryId)  \(Self.describe($0.result))" }
            })
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
                apply: { [weak self] in
                    guard let self else { return [] }
                    do {
                        let outcome = try QuarantineStore()
                            .quarantine(plistPath: plist, label: label, journal: self.journal)
                        self.refresh()
                        return ["\(Self.mark(outcome.result))  \(outcome.entryId)  \(Self.describe(outcome.result))"]
                    } catch {
                        return ["✗  \(label)  \(error.localizedDescription)"]
                    }
                })
        }
    }

    func applyPlan() {
        guard let plan else { return }
        busy = true
        let results = plan.apply()
        busy = false
        self.plan = nil
        refresh()
        note = Note(title: results.isEmpty ? "Nothing changed" : "Done",
                    body: results.isEmpty ? "No change was needed." : results.joined(separator: "\n"))
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
        .frame(minWidth: 720, minHeight: 420)
        .sheet(item: $model.plan) { plan in ConfirmationSheet(model: model, plan: plan) }
        .sheet(item: $model.note) { note in ResultSheet(note: note) }
    }
}

private struct Sidebar: View {
    @ObservedObject var model: AppModel

    var body: some View {
        List(selection: $model.pane) {
            Section {
                Label(AppModel.Pane.quiet.rawValue, systemImage: AppModel.Pane.quiet.symbol)
                    .tag(AppModel.Pane.quiet)
            } header: {
                Text("Mode")
            }
            Section {
                Label(AppModel.Pane.bundles.rawValue, systemImage: AppModel.Pane.bundles.symbol)
                    .tag(AppModel.Pane.bundles)
            }
            Section {
                Label(AppModel.Pane.findings.rawValue, systemImage: AppModel.Pane.findings.symbol)
                    .badge(model.snapshot.findings.count)
                    .tag(AppModel.Pane.findings)
                Label(AppModel.Pane.services.rawValue, systemImage: AppModel.Pane.services.symbol)
                    .tag(AppModel.Pane.services)
            } header: {
                Text("This machine")
            }
        }
        .listStyle(.sidebar)
    }
}

private struct Detail: View {
    @ObservedObject var model: AppModel

    var body: some View {
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

private struct HeldList: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Held")
                .font(.headline)
                .padding(.horizontal, 24)
            ScrollView {
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
            .frame(maxHeight: 260)
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
                        SectionHeader("\(model.snapshot.findings.count) findings, most serious first")
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
                Button("Quarantine…") { model.quarantine(label: finding.label) }
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

    var body: some View {
        let rows = query.isEmpty
            ? model.snapshot.services
            : model.snapshot.services.filter { $0.label.localizedCaseInsensitiveContains(query) }

        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(rows) { service in
                    HStack(spacing: 12) {
                        Text(service.label)
                            .font(.system(.body, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        if service.findingCount > 0 {
                            Text("\(service.findingCount)")
                                .font(.caption)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        Text(service.state)
                            .font(.caption)
                            .foregroundStyle(service.state == "running" ? .primary : .secondary)
                            .frame(width: 90, alignment: .trailing)
                    }
                    .padding(.vertical, 6)
                    .padding(.horizontal, 24)
                    Divider().padding(.leading, 24)
                }
            }
        }
        .searchable(text: $query, placement: .toolbar, prompt: "Filter services")
    }
}

// MARK: - Shared pieces

// MARK: - Apps

private struct AppsPane: View {
    @ObservedObject var model: AppModel

    var body: some View {
        let apps = model.snapshot.apps
        Group {
            if apps.isEmpty {
                EmptyState(title: "No apps to show",
                           message: "Curfew lists the apps that are running, biggest first. The shell and the harness are never listed.")
            } else {
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
            // Freeze is the verb: instant and exactly reversible. Quit is deliberately quieter —
            // it is the one that can lose work.
            Button("Freeze") { model.freeze(app) }
                .buttonStyle(.bordered)
                .disabled(app.isFrozen)
                .help("Suspend the app's processes. Restore resumes it exactly where it was.")
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
                    ForEach(plan.steps, id: \.self) { step in
                        Text(step)
                            .font(.system(.callout, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
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

