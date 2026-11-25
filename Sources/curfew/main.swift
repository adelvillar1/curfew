import Foundation
import Darwin
import CurfewKit

// curfew — read-only inventory, causality and diagnosis for macOS launchd services.
//
// Hard rule 3 and D1: this binary can print, and nothing else. There is no code path here that
// boots out, disables, signals or otherwise mutates a service, and `ReadOnlyGuaranteeTests`
// proves it by shimming every mutating verb on PATH.

let arguments = Array(CommandLine.arguments.dropFirst())

func has(_ flag: String) -> Bool { arguments.contains(flag) }

func value(for flag: String) -> String? {
    guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
    let next = arguments[index + 1]
    return next.hasPrefix("--") ? nil : next
}

func positional() -> String? {
    let flagsWithValues: Set<String> = ["--domain", "--pid", "--port", "--name"]
    var skip = false
    // Drop the command word ("why", "list", …) before looking for a target.
    for argument in arguments.dropFirst() {
        if skip { skip = false; continue }
        if flagsWithValues.contains(argument) { skip = true; continue }
        if argument.hasPrefix("--") { continue }
        return argument
    }
    return nil
}

let encoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    return encoder
}()

func emit<T: Encodable>(_ value: T) {
    guard let data = try? encoder.encode(value),
          let text = String(data: data, encoding: .utf8)
    else {
        FileHandle.standardError.write(Data("{\"error\":\"encoding failed\"}\n".utf8))
        exit(ExitCode.internalError.rawValue)
    }
    print(text)
}

func fail(_ message: String, _ code: ExitCode) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code.rawValue)
}

let macos = SystemVersion.shellVersion().version
let witrClient = WitrClient()
let witrVersion = witrClient.version()

func sources() -> Sources {
    Sources(witr: witrVersion, macos: macos, curfew: curfewVersion)
}

let usage = """
curfew \(curfewVersion) — why is this running, and is anything wrong with it?

usage:
  curfew list   [--domain gui|system|all] [--json]
  curfew why    <label> | --pid N | --port N | --name S [--json]
  curfew doctor [--json] [--disagreements]
  curfew catalog validate | list [--bundle NAME] | plan --bundle NAME   [--json] [--dir PATH]
  curfew catalog propose <label> | --all                 [--json] [--write FILE]
  curfew status                                          [--json]
  curfew tui   [--frame]                                 the dashboard; --frame prints one screen
  curfew apply  --bundle NAME [--execute [--yes]] [--allow-unsettled] [--json]
  curfew resume [--execute [--yes]] [--json]
  curfew --version

read-only: every command inspects; none changes a service.
"""

let domains: [Domain] = {
    switch value(for: "--domain") {
    case "system": return [.system]
    case "all": return [Domain.effective(), .system]
    default: return [Domain.effective()]
    }
}()

func findingsEngine(disabled: Set<String> = []) -> FindingsEngine {
    FindingsEngine(
        executableExists: { path in
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue
            else { return false }
            return FileManager.default.isExecutableFile(atPath: path)
        },
        disabledLabels: disabled
    )
}

func collect(_ domains: [Domain]) -> (records: [ServiceRecord], skipped: Int, disabled: Set<String>) {
    let inventory = LaunchdInventory()
    var all: [ServiceRecord] = []
    var skipped = 0
    var disabled: Set<String> = []
    for domain in domains {
        let set = inventory.disabledLabels(in: domain)
        disabled.formUnion(set)
        let result = inventory.records(in: domain, findings: findingsEngine(disabled: set))
        all.append(contentsOf: result.records)
        skipped += result.skipped
    }
    return (all, skipped, disabled)
}

func findingReports(_ records: [ServiceRecord]) -> [FindingReport] {
    records.flatMap { record in
        record.findings.map { finding in
            FindingReport(
                label: record.id,
                domain: record.domain,
                id: finding.id.rawValue,
                severity: finding.severity.rawValue,
                summary: finding.summary,
                evidence: finding.evidence
            )
        }
    }
}

func disagreementLog() -> DisagreementLog {
    var options = DisagreementLog.Options()
    if let override = ProcessInfo.processInfo.environment["CURFEW_LOG_DIR"] {
        options.directory = URL(fileURLWithPath: override, isDirectory: true)
    }
    return DisagreementLog(options: options, witrVersion: witrVersion)
}

// MARK: - Commands

func runList() -> Never {
    let (records, skipped, _) = collect(domains)
    var scan = ScanState()
    if skipped > 0 { scan.markIncomplete("unparsedRows") }

    let sorted = records.sorted {
        ($0.tier.rawValue, $0.id) < ($1.tier.rawValue, $1.id)
    }

    if has("--json") {
        emit(ListOutput(sources: sources(), records: sorted, scan: scan))
    } else {
        let thirdParty = sorted.filter { $0.tier == .thirdParty }
        let apple = sorted.filter { $0.tier == .appleAgent || $0.tier == .osCore }
        print("curfew \(curfewVersion) · macOS \(macos) · witr \(witrVersion ?? "absent")")
        print("")
        print("third-party (\(thirdParty.count))")
        let rows = thirdParty.map { record in
            [
                record.id,
                Render.state(record),
                record.runs.map(String.init) ?? "?",
                record.lastExitCode.map(String.init) ?? "-",
                record.vendor ?? "-",
                record.findings.isEmpty ? "" : "\(record.findings.count) finding(s)",
            ]
        }
        print(Render.table(rows, headers: ["LABEL", "STATE", "RUNS", "EXIT", "VENDOR", ""]))
        print("")
        print("apple / system (\(apple.count)) — reported only, never acted on")
        print("")
        print("scan: \(scan.complete ? "complete" : "incomplete (\(scan.incompleteReasons.joined(separator: ", ")))")")
    }

    let hasFindings = records.contains { !$0.findings.isEmpty }
    exit((hasFindings || !scan.complete) ? ExitCode.warnings.rawValue : ExitCode.clean.rawValue)
}

func runDoctor() -> Never {
    let (records, skipped, _) = collect([Domain.effective(), .system])
    var scan = ScanState()
    if skipped > 0 { scan.markIncomplete("unparsedRows") }

    let log = disagreementLog()
    var enrichedCount = 0

    // Enrich only what can be enriched cheaply: running third-party jobs. Each witr call is a
    // process; a full sweep of every Apple job would cost more than the answer is worth.
    var enrichedRecords: [ServiceRecord] = []
    for record in records {
        guard record.tier == .thirdParty, let pid = record.pid, enrichedCount < 40 else {
            enrichedRecords.append(record)
            continue
        }
        enrichedCount += 1
        switch witrClient.probe(pid: pid) {
        case .success(let report):
            let (merged, events) = WitrEnricher.enrich(record, report: report)
            for event in events {
                log.record(event)
                scan.markIncomplete(event.kind.rawValue)
            }
            enrichedRecords.append(merged)
        case .failure(let failure):
            let (merged, events) = WitrEnricher.missingReport(record, failure: failure)
            for event in events {
                log.record(event)
                scan.markIncomplete(event.kind.rawValue)
            }
            enrichedRecords.append(merged)
        }
    }

    if witrClient.binary == nil, records.contains(where: { $0.state == .running }) {
        scan.markIncomplete("witrAbsent")
    }

    // The listener scan: launchd cannot see a process holding a port without owning a job.
    let listeners = ListenerScanner().scan()
    var listenerFindings = ListenerFindings.orphanPorts(listeners: listeners, records: enrichedRecords)
    if let aggregate = ListenerFindings.unattributed(listeners: listeners, records: enrichedRecords) {
        listenerFindings.append(aggregate)
    }

    let reports = findingReports(enrichedRecords) + listenerFindings.map { finding in
        FindingReport(
            label: nil, domain: nil,
            id: finding.id.rawValue, severity: finding.severity.rawValue,
            summary: finding.summary, evidence: finding.evidence
        )
    }
    let disagreements = log.summarize()

    if has("--json") {
        emit(DoctorOutput(sources: sources(), findings: reports, scan: scan, disagreements: disagreements))
    } else {
        print("curfew \(curfewVersion) · macOS \(macos) · witr \(witrVersion ?? "absent")")
        print("")
        print(reports.isEmpty ? "findings: none" : "findings (\(reports.count))")
        if !reports.isEmpty { print(Render.findings(reports)) }
        print("")
        if has("--disagreements") || !disagreements.isEmpty {
            print("disagreements (\(disagreements.count) fingerprint(s))")
            for disagreement in disagreements {
                print("  \(disagreement.kind.rawValue)  ×\(disagreement.count)  \(disagreement.fingerprint)")
                print("         first \(disagreement.firstSeen) · last \(disagreement.lastSeen)")
            }
        }
        print("scan: \(scan.complete ? "complete" : "incomplete (\(scan.incompleteReasons.joined(separator: ", ")))")")
    }

    exit((reports.isEmpty && scan.complete) ? ExitCode.clean.rawValue : ExitCode.warnings.rawValue)
}

func runWhy() -> Never {
    // Resolution order: explicit flag, then a positional label.
    if let name = value(for: "--name") {
        return whyByName(name)
    }
    if let port = value(for: "--port").flatMap(UInt16.init) {
        return whyByPort(port)
    }
    if let pid = value(for: "--pid").flatMap(Int32.init) {
        return whyByPid(pid)
    }
    if let label = positional() {
        return whyByLabel(label)
    }
    fail(usage, .badInput)
}

func printWhy(_ record: ServiceRecord?, report: WitrReport?, ancestry: [AncestryNode], warnings: [String], scan: ScanState) {
    if has("--json") {
        emit(WhyOutput(
            sources: sources(),
            record: record,
            ancestry: ancestry,
            source: report.map { SourceSummary(type: $0.sourceType, name: $0.sourceName, plistPath: $0.sourceUnitFile) },
            warnings: warnings,
            scan: scan
        ))
        return
    }
    guard let record else {
        // Port / pid / name probes have no launchd record: render the report itself.
        guard let report, let process = report.process else {
            print("not found")
            return
        }
        print("process     : \(process.exe) (pid \(process.pid))")
        print("source      : \(report.sourceName ?? "unknown") (\(report.sourceType))")
        if !ancestry.isEmpty {
            print("why it exists: " + ancestry.map { "\($0.command) (\($0.pid))" }.joined(separator: " → "))
        }
        if !process.listeningPorts.isEmpty {
            print("sockets     : " + process.listeningPorts.map { "127.0.0.1:\($0)" }.joined(separator: ", "))
        }
        if let dir = process.workingDir { print("working dir : \(dir)") }
        if !warnings.isEmpty {
            print("warnings    :")
            for warning in warnings { print("  • \(warning)") }
        }
        return
    }
    print("label       : \(record.id)")
    print("state       : \(Render.state(record))")
    if let runs = record.runs { print("runs        : \(runs)") }
    if let exit = record.lastExitCode { print("last exit   : \(exit)") }
    if let program = record.program { print("program     : \(program)") }
    if let plist = record.plistPath { print("plist       : \(plist)") }
    print("tier        : \(record.tier.rawValue) · kind \(record.kind.rawValue) · \(record.supervised.rawValue)")
    if !ancestry.isEmpty {
        print("why it exists: " + ancestry.map { "\($0.command) (\($0.pid))" }.joined(separator: " → "))
    }
    if let report, let source = report.sourceName {
        print("source      : \(source) (\(report.sourceType))")
    }
    if let process = record.process {
        if let ports = Optional(process.listeningPorts), !ports.isEmpty {
            print("sockets     : " + ports.map { "127.0.0.1:\($0)" }.joined(separator: ", "))
        }
        if let dir = process.workingDir { print("working dir : \(dir)") }
        if let repo = process.gitRepo { print("git         : \(repo)\(process.gitBranch.map { " (\($0))" } ?? "")") }
    }
    if !warnings.isEmpty {
        print("warnings    :")
        for warning in warnings { print("  • \(warning)") }
    }
    if !record.findings.isEmpty {
        print("findings    :")
        for finding in record.findings { print("  • \(finding.summary)\n    ↳ \(finding.evidence)") }
    }
}

func whyByLabel(_ label: String) -> Never {
    let (records, _, _) = collect([Domain.effective(), .system])
    guard let record = records.first(where: { $0.id == label }) else {
        fail("no launchd job named \(label) in gui/\(getuid()) or system", .notFound)
    }

    guard let pid = record.pid, record.state == .running else {
        // The case every process tool cannot see (KI-003): the job exists and is broken.
        printWhy(record, report: nil, ancestry: [], warnings: [], scan: ScanState())
        FileHandle.standardError.write(Data("""
        \(label) is not running: runs = \(record.runs.map(String.init) ?? "unknown"), \
        last exit = \(record.lastExitCode.map(String.init) ?? "never exited"), state = \(record.state.rawValue)

        """.utf8))
        exit(ExitCode.notFound.rawValue)
    }

    switch witrClient.probe(pid: pid) {
    case .success(let report):
        let (merged, events) = WitrEnricher.enrich(record, report: report)
        let log = disagreementLog()
        for event in events { log.record(event) }
        var scan = ScanState()
        for event in events { scan.markIncomplete(event.kind.rawValue) }
        printWhy(merged, report: report, ancestry: report.process?.ancestry ?? [], warnings: report.warnings, scan: scan)
        exit(scan.complete ? ExitCode.clean.rawValue : ExitCode.warnings.rawValue)
    case .failure(let failure):
        if case .notInstalled = failure {
            printWhy(record, report: nil, ancestry: [], warnings: [], scan: ScanState())
            fail(failure.message, .dependencyMissing)
        }
        let (merged, _) = WitrEnricher.missingReport(record, failure: failure)
        printWhy(merged, report: nil, ancestry: [], warnings: [], scan: ScanState(complete: false, incompleteReasons: ["enrichMissing"]))
        fail(failure.message, .warnings)
    }
}

func whyByPort(_ port: UInt16) -> Never {
    switch witrClient.probe(port: port) {
    case .success(let report):
        printWhy(nil, report: report, ancestry: report.process?.ancestry ?? [], warnings: report.warnings, scan: ScanState())
        exit(ExitCode.clean.rawValue)
    case .failure(let failure):
        fail(failure.message, failure == .notInstalled ? .dependencyMissing : .notFound)
    }
}

func whyByPid(_ pid: Int32) -> Never {
    switch witrClient.probe(pid: pid) {
    case .success(let report):
        printWhy(nil, report: report, ancestry: report.process?.ancestry ?? [], warnings: report.warnings, scan: ScanState())
        exit(ExitCode.clean.rawValue)
    case .failure(let failure):
        fail(failure.message, failure == .notInstalled ? .dependencyMissing : .notFound)
    }
}

func whyByName(_ name: String) -> Never {
    switch witrClient.probe(name: name) {
    case .success(let report):
        printWhy(nil, report: report, ancestry: report.process?.ancestry ?? [], warnings: report.warnings, scan: ScanState())
        exit(ExitCode.clean.rawValue)
    case .failure(let failure):
        fail(failure.message, failure == .notInstalled ? .dependencyMissing : .notFound)
    }
}

// MARK: - the TUI (L5.1): previews only, never acts

func buildTUIState() -> TUIState {
    let inventory = LaunchdInventory()
    let records = inventory.records(in: Domain.effective(), findings: FindingsEngine()).records
    let catalog = (try? CatalogLoader.load(directory: catalogDirectory()))
        ?? Catalog(entries: [], bundles: [], files: [])
    let quiet = !Journal().unresolved().isEmpty
    return TUIBuilder.state(
        records: records,
        catalog: catalog,
        quietMode: quiet,
        title: "curfew \(curfewVersion) · macOS \(macos) · gui/\(getuid())"
    )
}

func runTUI() -> Never {
    // A one-frame render keeps the screen inspectable from a script or a pipe, which is also how
    // this session verifies it. The interactive loop needs a terminal.
    if has("--frame") || isatty(STDIN_FILENO) == 0 {
        print(TUIRenderer.render(buildTUIState()))
        exit(ExitCode.clean.rawValue)
    }
    TUILoop.run()
}


// MARK: - catalog propose (L7.2): the model proposes, the catalogue and the owner dispose

func runPropose(catalog: Catalog) -> Never {
    let client: JevClient
    do {
        client = try JevClient.liveClient()
    } catch {
        // Offline capability is the point (D29): the diagnostic path keeps working, and this one says
        // plainly why it cannot.
        print("catalog propose: \(error)")
        print("  everything else still works — list, why, doctor, catalog validate|list|plan, status")
        exit(ExitCode.warnings.rawValue)
    }

    let runner = ProposeRunner(client: client, log: DecisionLog())
    let inventory = LaunchdInventory()
    let records = inventory.records(in: Domain.effective(), findings: FindingsEngine()).records
    let listeners = ListenerScanner().scan()

    func proposeOne(_ label: String) -> (Proposal, String) {
        let record = records.first { $0.id == label }
        let mine = listeners.filter { listener in
            guard let pid = record?.pid else { return false }
            return listener.pid == pid
        }
        let state = Proposer.state(record: record, label: label, listeners: mine)
        do {
            let proposal = try runner.propose(record: record, label: label, listeners: mine)
            return (proposal, state)
        } catch {
            print("catalog propose: \(label): \(error)")
            exit(ExitCode.warnings.rawValue)
        }
    }

    if has("--all") {
        let known = Set(catalog.entries.map(\.id))
        let candidates = records
            .filter { $0.tier == .thirdParty && $0.kind != .appChild && !known.contains($0.id) }
            .map(\.id)
            .sorted()
        guard !candidates.isEmpty else {
            print("catalog propose: nothing uncatalogued to propose")
            exit(ExitCode.clean.rawValue)
        }
        var proposals: [(Proposal, String)] = []
        for label in candidates { proposals.append(proposeOne(label)) }
        if has("--json") {
            print("[")
            for (index, item) in proposals.enumerated() {
                let proposal = item.0
                let payload: [String: Any] = [
                    "id": proposal.id, "decision": proposal.decision.rawValue,
                    "confidence": Proposer.confidenceName(proposal.confidence),
                    "reasons": proposal.reasons,
                ]
                if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
                   let text = String(data: data, encoding: .utf8) {
                    print("  " + text + (index == proposals.count - 1 ? "" : ","))
                }
            }
            print("]")
        } else {
            print("proposals for \(proposals.count) uncatalogued service(s) — all draft, nothing acts on them\n")
            for (proposal, _) in proposals {
                print("  \(proposal.id)")
                print("    → \(proposal.decision.rawValue) (\(Proposer.confidenceName(proposal.confidence)))  \(proposal.reasons.joined(separator: "; "))")
            }
            let review = proposals.filter { $0.0.decision == .review }.count
            print("\n  \(proposals.count - review) decided, \(review) need your call")
        }
        exit(ExitCode.clean.rawValue)
    }

    guard let label = arguments.dropFirst(2).first(where: { !$0.hasPrefix("-") }) else {
        fail("curfew catalog propose <label> [--all] [--json] [--write FILE]", .badInput)
    }
    let (proposal, state) = proposeOne(label)

    if has("--json") {
        let payload: [String: Any] = [
            "id": proposal.id,
            "decision": proposal.decision.rawValue,
            "confidence": Proposer.confidenceName(proposal.confidence),
            "model": proposal.model,
            "reasons": proposal.reasons,
            "state": state,
            "yaml": Proposer.yaml(proposal, record: records.first { $0.id == label }),
        ]
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys, .prettyPrinted]),
           let text = String(data: data, encoding: .utf8) {
            print(text)
        }
        exit(ExitCode.clean.rawValue)
    }

    print("proposal for \(proposal.id) — \(proposal.decision.rawValue) (\(Proposer.confidenceName(proposal.confidence)))")
    for reason in proposal.reasons { print("  · \(reason)") }
    print("")
    print(Proposer.yaml(proposal, record: records.first { $0.id == label }))

    if let file = value(for: "--write") {
        let url = URL(fileURLWithPath: file)
        let text = Proposer.yaml(proposal, record: records.first { $0.id == label }) + "\n"
        if let handle = try? FileHandle(forWritingTo: url) {
            try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(text.utf8))
            try? handle.close()
            print("\nappended to \(file) as a draft — it cannot be applied until a recipe is verified")
        } else {
            print("\ncould not open \(file) — the proposal was not written")
        }
    }
    exit(ExitCode.clean.rawValue)
}

// MARK: - apply / resume (the first commands that can change a machine)

func requireExecuteConsent(_ what: String) {
    guard has("--execute") else { return }
    guard isatty(STDOUT_FILENO) != 0 || has("--yes") else {
        fail("""
        \(what) would change running services. --execute here needs --yes because stdout is not a
        terminal: a pipe or a script should not be able to stop services by accident.
        """, .badInput)
    }
}

func loadCatalogOrFail() -> Catalog {
    do {
        return try CatalogLoader.load(directory: catalogDirectory())
    } catch {
        fail("catalog: \(error)", .badInput)
    }
}

func executionContext(_ catalog: Catalog) -> ExecutionContext {
    let inventory = LaunchdInventory()
    let records = inventory.records(in: Domain.effective(), findings: FindingsEngine()).records
    let listeners = ListenerScanner().scan()
    let protectedPorts = Set(catalog.bundles.filter { $0.kind == .protect }.flatMap(\.protectPorts))
    return ExecutionContext(
        domain: Domain.effective().target,
        records: records,
        listeners: listeners,
        protectedPorts: protectedPorts
    )
}

func report(_ outcome: StepOutcome) -> StepOutcomeReport {
    switch outcome.result {
    case .planned:
        return .init(entryId: outcome.entryId, action: outcome.action, result: "planned", detail: nil)
    case .refused(let reason):
        return .init(entryId: outcome.entryId, action: outcome.action, result: "refused", detail: reason)
    case .executed(let verified):
        return .init(entryId: outcome.entryId, action: outcome.action,
                     result: verified ? "executed+verified" : "executed+unverified", detail: nil)
    case .failed(let reason):
        return .init(entryId: outcome.entryId, action: outcome.action, result: "failed", detail: reason)
    case .preExisting(let reason):
        return .init(entryId: outcome.entryId, action: outcome.action, result: "pre-existing", detail: reason)
    }
}

func printOutcomes(_ outcomes: [StepOutcomeReport], executed: Bool) {
    print(executed ? "executed" : "dry run — nothing was touched")
    for outcome in outcomes {
        let mark: String
        switch outcome.result {
        case "executed+verified": mark = "✓"
        case "executed+unverified": mark = "~"
        case "planned": mark = "·"
        case "pre-existing": mark = "="
        default: mark = "✗"
        }
        print("  \(mark) \(outcome.entryId)  \(outcome.action)  \(outcome.result)")
        if let detail = outcome.detail { print("      \(detail)") }
    }
}

func runApply() -> Never {
    guard let bundle = value(for: "--bundle") else {
        fail("curfew apply needs --bundle NAME", .badInput)
    }
    requireExecuteConsent("apply")
    let catalog = loadCatalogOrFail()
    let execute = has("--execute")

    // L7.3: the quiesce screen. Off unless the entry declares a quiesce probe (auto), and never
    // built at all when no key is present — the diagnostic path must not need one (D29).
    let gateMode = QuiesceMode.fromEnvironment(ProcessInfo.processInfo.environment["CURFEW_QUIESCE_GATE"])
    var gate: QuiesceGate?
    if gateMode != .off, let client = try? JevClient.liveClient() {
        gate = QuiesceGate.live(client: client)
    }

    let outcomes = Executor(
        journal: Journal(),
        gate: gate,
        gateMode: gateMode,
        allowUnsettled: has("--allow-unsettled")
    )
        .apply(bundle: bundle, catalog: catalog, context: executionContext(catalog), execute: execute)
        .map(report)

    if has("--json") {
        emit(ApplyOutput(sources: sources(), bundle: bundle, executed: execute, outcomes: outcomes))
    } else {
        printOutcomes(outcomes, executed: execute)
    }
    let refused = outcomes.contains { $0.result == "refused" || $0.result == "failed" }
    exit(refused ? ExitCode.warnings.rawValue : ExitCode.clean.rawValue)
}

func runResume() -> Never {
    requireExecuteConsent("resume")
    let catalog = loadCatalogOrFail()
    let journal = Journal()
    guard !journal.restorePlan().isEmpty else {
        if has("--json") {
            emit(ResumeOutput(sources: sources(), executed: has("--execute"), outcomes: []))
        } else {
            print("nothing to restore — the journal has no unresolved intents")
        }
        exit(ExitCode.clean.rawValue)
    }
    let execute = has("--execute")
    let outcomes: [StepOutcomeReport]
    if execute {
        outcomes = Executor(journal: journal)
            .resume(context: executionContext(catalog), catalog: catalog)
            .map(report)
    } else {
        outcomes = journal.restorePlan().map { intent in
            StepOutcomeReport(
                entryId: intent.entryId ?? "?", action: "resume", result: "planned",
                detail: intent.argv?.first?.joined(separator: " ")
            )
        }
    }
    if has("--json") {
        emit(ResumeOutput(sources: sources(), executed: execute, outcomes: outcomes))
    } else {
        printOutcomes(outcomes, executed: execute)
    }
    exit(ExitCode.clean.rawValue)
}

// MARK: - status (reads the journal; writes nothing)

func runStatus() -> Never {
    let journal = Journal()
    let all = journal.records()
    let unresolved = journal.unresolved()
    let now = Date()

    let intents = unresolved.map { record -> UnresolvedIntent in
        var age: Int?
        if let date = parseJournalTimestamp(record.ts) {
            age = Int(now.timeIntervalSince(date))
        }
        return UnresolvedIntent(
            seq: record.seq, ts: record.ts, entryId: record.entryId,
            action: record.action, ageSeconds: age
        )
    }

    if has("--json") {
        emit(StatusOutput(
            sources: sources(), journal: journal.url.path,
            records: all.count, unresolved: intents
        ))
    } else {
        print("journal: \(journal.url.path)")
        print("records: \(all.count)")
        if intents.isEmpty {
            print("unresolved: none — nothing is suspended by Curfew")
        } else {
            print("unresolved: \(intents.count) — these were started and never confirmed finished")
            for intent in intents {
                let age = intent.ageSeconds.map { "\($0 / 60) min ago" } ?? "age unknown"
                print("  #\(intent.seq)  \(intent.entryId ?? "?")  \(intent.action ?? "?")  — \(age)")
            }
        }
    }
    exit(intents.isEmpty ? ExitCode.clean.rawValue : ExitCode.warnings.rawValue)
}

// MARK: - catalog (read-only: loads, validates and plans; never acts)

func catalogDirectory() -> URL {
    if let dir = value(for: "--dir") {
        return URL(fileURLWithPath: dir, isDirectory: true)
    }
    return URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        .appendingPathComponent("catalog", isDirectory: true)
}

func runCatalog() -> Never {
    let subcommand = arguments.dropFirst().first ?? "validate"
    let directory = catalogDirectory()

    let catalog: Catalog
    do {
        catalog = try CatalogLoader.load(directory: directory)
    } catch {
        fail("catalog: \(error)", .badInput)
    }

    let violations = CatalogValidator.validate(catalog)

    switch subcommand {
    case "validate":
        if has("--json") {
            emit(CatalogListOutput(
                sources: sources(), entries: [], bundles: [],
                violations: violations.map(\.description)
            ))
        } else if violations.isEmpty {
            print("catalog: ok — \(catalog.entries.count) entries, \(catalog.bundles.count) bundles, \(catalog.files.count) files")
        } else {
            print("catalog: \(violations.count) violation(s)")
            for violation in violations { print("  ✗ \(violation)") }
        }
        exit(violations.isEmpty ? ExitCode.clean.rawValue : ExitCode.warnings.rawValue)

    case "list":
        let entries = catalog.entries
            .filter { entry in
                guard let bundleName = value(for: "--bundle") else { return true }
                return catalog.bundle(bundleName)?.members.contains(entry.id) ?? false
            }
            .map { entry in
                CatalogEntryReport(
                    id: entry.id, kind: entry.kind.rawValue, lever: entry.lever.rawValue,
                    supervised: entry.supervised.rawValue, status: entry.status.rawValue,
                    hazards: entry.hazards, evidence: entry.evidence, file: entry.file
                )
            }
        let bundles = catalog.bundles.map { bundle in
            CatalogBundleReport(
                name: bundle.name, kind: bundle.kind.rawValue, summary: bundle.summary,
                protectPorts: bundle.protectPorts, members: bundle.members
            )
        }
        if has("--json") {
            emit(CatalogListOutput(
                sources: sources(), entries: entries, bundles: bundles,
                violations: violations.map(\.description)
            ))
        } else {
            let rows = entries.map { entry in
                [entry.id, entry.lever, entry.supervised, entry.status, entry.file]
            }
            print(Render.table(rows, headers: ["ENTRY", "LEVER", "SUPERVISED", "STATUS", "FILE"]))
            print("")
            for bundle in bundles {
                let ports = bundle.protectPorts.isEmpty ? "" : " · protects \(bundle.protectPorts.map(String.init).joined(separator: ", "))"
                print("  \(bundle.name) (\(bundle.kind)) — \(bundle.members.count) member(s)\(ports)")
            }
        }
        exit(violations.isEmpty ? ExitCode.clean.rawValue : ExitCode.warnings.rawValue)

    case "propose":
        runPropose(catalog: catalog)

    case "plan":
        guard let bundleName = value(for: "--bundle") else {
            fail("catalog plan needs --bundle NAME", .badInput)
        }
        let plan = CatalogPlanner.plan(bundle: bundleName, in: catalog, privilegedAvailable: geteuid() == 0)
        if has("--json") {
            emit(CatalogPlanOutput(
                sources: sources(), bundle: bundleName,
                steps: plan.steps, refusals: plan.refusals, protectedPorts: plan.protectedPorts
            ))
        } else {
            print("plan for \(bundleName) — nothing is executed by this command")
            print("")
            if plan.protectedPorts.isEmpty {
                print("protected ports: none")
            } else {
                print("protected ports: \(plan.protectedPorts.map(String.init).joined(separator: ", "))")
            }
            print("")
            if plan.steps.isEmpty {
                print("steps: none")
            } else {
                for (index, step) in plan.steps.enumerated() {
                    print("  \(index + 1). \(step.id) — \(step.action)")
                    for argv in step.argv { print("       \(argv.joined(separator: " "))") }
                    if let expectation = step.expectation { print("       expect: \(expectation)") }
                }
            }
            if !plan.refusals.isEmpty {
                print("")
                print("refused:")
                for refusal in plan.refusals { print("  ✗ \(refusal.id): \(refusal.reason)") }
            }
        }
        exit(plan.refusals.isEmpty ? ExitCode.clean.rawValue : ExitCode.warnings.rawValue)

    default:
        fail("unknown catalog subcommand '\(subcommand)' — try validate, list or plan", .badInput)
    }
}

// MARK: - Dispatch

switch arguments.first {
case "list": runList()
case "doctor": runDoctor()
case "why": runWhy()
case "catalog": runCatalog()
case "status": runStatus()
case "tui": runTUI()
case nil: runTUI()
case "apply": runApply()
case "resume": runResume()
case "--version", "-v", "version":
    print("curfew \(curfewVersion)")
    exit(ExitCode.clean.rawValue)
case "--help", "-h", "help":
    print(usage)
    exit(ExitCode.clean.rawValue)
default:
    fail("unknown command \(arguments.first ?? "")\n\n" + usage, .badInput)
}
