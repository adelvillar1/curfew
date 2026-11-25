import Foundation

/// What the executor knows about the machine at the moment it runs.
public struct ExecutionContext: Sendable {
    public var domain: String
    public var records: [ServiceRecord]
    public var listeners: [Listener]
    public var protectedPorts: Set<UInt16>
    /// Pids of this process and its ancestors. Rule 7: never suspend your own tree.
    public var ownAncestry: Set<Int32>

    public init(
        domain: String,
        records: [ServiceRecord] = [],
        listeners: [Listener] = [],
        protectedPorts: Set<UInt16> = [],
        ownAncestry: Set<Int32> = ProcessAncestry.chain()
    ) {
        self.domain = domain
        self.records = records
        self.listeners = listeners
        self.protectedPorts = protectedPorts
        self.ownAncestry = ownAncestry
    }

    public func record(_ id: String) -> ServiceRecord? { records.first { $0.id == id } }
}

/// The three post-condition probes, injected so the executor is testable without a machine.
public struct Probes: Sendable {
    public var portIsOpen: @Sendable (UInt16) -> Bool
    public var pidExists: @Sendable (Int32) -> Bool
    public var labelIsRunning: @Sendable (String) -> Bool

    public init(
        portIsOpen: @escaping @Sendable (UInt16) -> Bool,
        pidExists: @escaping @Sendable (Int32) -> Bool,
        labelIsRunning: @escaping @Sendable (String) -> Bool
    ) {
        self.portIsOpen = portIsOpen
        self.pidExists = pidExists
        self.labelIsRunning = labelIsRunning
    }

    public static let live = Probes(
        portIsOpen: { port in
            ListenerScanner().scan().contains { $0.port == port }
        },
        pidExists: { pid in
            // Signal 0 asks the kernel "does this exist and may I signal it" without signalling.
            kill(pid, 0) == 0
        },
        labelIsRunning: { label in
            guard let detail = LaunchdInventory().detail(label: label, domain: .currentUser) else { return false }
            return detail.state == .running
        }
    )
}

public enum StepResult: Sendable, Equatable {
    case planned
    case refused(String)
    case executed(verified: Bool)
    case failed(String)
    /// The service was already in that state before Curfew ran; recorded, never reversed (rule 6).
    case preExisting(String)
}

public struct StepOutcome: Sendable, Equatable {
    public var entryId: String
    public var action: String
    public var result: StepResult
}

/// Applies a bundle: refuse, quiesce, journal the intent, act, verify, journal the outcome.
///
/// The order is the whole design. Every step that could touch the machine is preceded by a durable
/// intent, and a refusal happens before the first intent is written so it leaves no trace.
/// The privileged seam: one closure, so delegation is testable without XPC, root or a signature.
public typealias PrivilegedTransport = @Sendable (HelperRequest) -> HelperResponse

public struct Executor: Sendable {
    public typealias Runner = @Sendable ([String]) -> CommandResult

    private let runner: Runner
    private let journal: Journal
    private let probes: Probes
    /// Nil for an internal, single-user install: privilege comes from running under sudo, not from a
    /// signed daemon (D21). Kept as a seam for anything that later wants a helper.
    private let privileged: PrivilegedTransport?
    /// True when this process already is root.
    private let isRoot: Bool

    public init(
        runner: @escaping Runner = Executor.systemRunner,
        journal: Journal,
        probes: Probes = .live,
        privileged: PrivilegedTransport? = nil,
        isRoot: Bool = geteuid() == 0
    ) {
        self.runner = runner
        self.journal = journal
        self.probes = probes
        self.privileged = privileged
        self.isRoot = isRoot
    }

    public static let systemRunner: Runner = { argv in
        guard let executable = argv.first else {
            return CommandResult(standardOutput: "", standardError: "empty argv", status: -1)
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = Array(argv.dropFirst())
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        do {
            try process.run()
        } catch {
            // A launch failure is not an exit code: say what happened, or the next person debugs -1.
            return CommandResult(
                standardOutput: "",
                standardError: "could not launch \(executable): \(error.localizedDescription)",
                status: -1
            )
        }
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return CommandResult(
            standardOutput: String(decoding: outData, as: UTF8.self),
            standardError: String(decoding: errData, as: UTF8.self),
            status: process.terminationStatus
        )
    }

    // MARK: Apply

    public func apply(
        bundle name: String,
        catalog: Catalog,
        context: ExecutionContext,
        execute: Bool
    ) -> [StepOutcome] {
        let plan = CatalogPlanner.plan(bundle: name, in: catalog, privilegedAvailable: isRoot || privileged != nil)
        var outcomes: [StepOutcome] = []

        // A planner refusal is already a decision: report it and touch nothing.
        for refusal in plan.refusals {
            outcomes.append(StepOutcome(entryId: refusal.id, action: "refuse", result: .refused(refusal.reason)))
        }
        guard execute else {
            for step in plan.steps {
                outcomes.append(StepOutcome(entryId: step.id, action: step.action, result: .planned))
            }
            return outcomes
        }

        for step in plan.steps {
            guard let entry = catalog.entry(step.id) else {
                outcomes.append(StepOutcome(entryId: step.id, action: step.action, result: .refused("no catalog entry")))
                continue
            }
            outcomes.append(run(entry: entry, context: context))
            // A failure or unverified stop stops the run: the next entry may depend on this one.
            if case .failed = outcomes.last?.result { break }
            if case .executed(let verified) = outcomes.last?.result, verified == false { break }
        }
        return outcomes
    }

    private func run(entry: CatalogEntry, context: ExecutionContext) -> StepOutcome {
        let action = entry.lever.rawValue

        if let refusal = refusal(for: entry, context: context) {
            return StepOutcome(entryId: entry.id, action: action, result: .refused(refusal))
        }

        // Already in the state we would create: record it, do not act, so `resume` leaves it alone.
        if let record = context.record(entry.id), record.state != .running {
            return StepOutcome(
                entryId: entry.id, action: action,
                result: .preExisting("already \(record.state.rawValue) before Curfew ran")
            )
        }

        guard let recipe = entry.stop else {
            return StepOutcome(entryId: entry.id, action: action, result: .refused("no stop recipe"))
        }

        // A root recipe never runs here: it goes to the helper, which will re-decide everything
        // itself (D20). Without a helper it stays refused.
        if recipe.needsRoot {
            // Under sudo the executor *is* the privileged process; the catalog rules still apply,
            // which is what keeps "as root, only reviewed recipes" true without a daemon (D21).
            if isRoot {
                // fall through and run it locally
            } else if let privileged {
                return runPrivileged(entry: entry, action: action, recipe: recipe, transport: privileged)
            } else {
                return StepOutcome(
                    entryId: entry.id, action: action,
                    result: .refused("recipe needs root — run \(suggestion())")
                )
            }
        }

        guard let argv = substitute(recipe.run, domain: context.domain, plist: context.record(entry.id)?.plistPath) else {
            return StepOutcome(entryId: entry.id, action: action, result: .refused("unknown substitution token"))
        }

        // Rule 2: if the intent cannot be written, nothing happens.
        let seq: Int
        do {
            seq = try journal.appendIntent(
                entryId: entry.id, action: action, argv: argv,
                preExisting: nil
            )
        } catch {
            return StepOutcome(entryId: entry.id, action: action, result: .refused("journal unwritable — \(error)"))
        }

        for step in argv {
            let result = runner(step)
            guard result.status == 0 else {
                try? journal.appendOutcome(intent: seq, result: "failed", verified: false, error: result.standardError)
                let detail = result.status == -1
                    ? result.standardError
                    : "\(step.first ?? "?") exited \(result.status): \(result.standardError.prefix(200))"
                return StepOutcome(entryId: entry.id, action: action, result: .failed(detail))
            }
        }

        var verified: Bool? = nil
        if let verification = recipe.verify {
            verified = passes(verification, context: context)
        }
        try? journal.appendOutcome(intent: seq, result: "ok", verified: verified)

        if recipe.hold == .bootoutIfRespawned, probes.labelIsRunning(entry.id) {
            // pg_ctl stopped the server but launchd brought the job back: hold it with a bootout.
            let bootout = [["/bin/launchctl", "bootout", "\(context.domain)/\(entry.id)"]]
            if let holdSeq = try? journal.appendIntent(entryId: entry.id, action: "bootout-hold", argv: bootout) {
                let result = runner(bootout[0])
                try? journal.appendOutcome(
                    intent: holdSeq, result: result.status == 0 ? "ok" : "failed",
                    verified: probes.labelIsRunning(entry.id) == false
                )
                if result.status != 0 {
                    return StepOutcome(entryId: entry.id, action: action, result: .failed("hold bootout exited \(result.status)"))
                }
            }
        }

        return StepOutcome(entryId: entry.id, action: action, result: .executed(verified: verified ?? true))
    }

    /// Delegate one root action. The intent is journaled **before** the request, for the same reason
    /// it is journaled before a local action: the machine can be left holding it either way.
    private func runPrivileged(
        entry: CatalogEntry, action: String, recipe: Recipe, transport: PrivilegedTransport
    ) -> StepOutcome {
        let seq: Int
        do {
            seq = try journal.appendIntent(entryId: entry.id, action: action, argv: recipe.run)
        } catch {
            return StepOutcome(entryId: entry.id, action: action, result: .refused("journal unwritable — \(error)"))
        }

        let helperAction: HelperAction = action == "disable" || action == "stop" || action == "command"
            ? .stop : .start
        let response = transport(HelperRequest(entryId: entry.id, action: helperAction, intentSeq: seq))

        if let refusal = response.refusal {
            try? journal.appendOutcome(intent: seq, result: "refused-by-helper", verified: false, error: refusal)
            return StepOutcome(entryId: entry.id, action: action, result: .refused("helper: \(refusal)"))
        }
        guard response.ok else {
            try? journal.appendOutcome(intent: seq, result: "failed", verified: false, error: response.standardError)
            return StepOutcome(
                entryId: entry.id, action: action,
                result: .failed("helper exited \(response.status ?? -1): \(response.standardError.prefix(200))")
            )
        }
        try? journal.appendOutcome(intent: seq, result: "ok", verified: response.verified)
        return StepOutcome(entryId: entry.id, action: action, result: .executed(verified: response.verified ?? true))
    }

    /// What the operator should type. A refusal that does not say the next step is a dead end.
    private func suggestion() -> String {
        "`sudo curfew apply --bundle <name> --execute --yes`"
    }

    // MARK: Resume

    public func resume(context: ExecutionContext, catalog: Catalog) -> [StepOutcome] {
        var outcomes: [StepOutcome] = []
        for intent in journal.restorePlan() {
            guard let entryId = intent.entryId else { continue }
            // Rule 6: an entry we found already stopped is not ours to start.
            if let preExisting = intent.preExisting, !preExisting.isEmpty {
                outcomes.append(StepOutcome(entryId: entryId, action: "resume", result: .preExisting(preExisting)))
                continue
            }
            guard let entry = catalog.entry(entryId), let start = entry.start else {
                outcomes.append(StepOutcome(entryId: entryId, action: "resume", result: .refused("no start recipe")))
                continue
            }
            guard let argv = substitute(start.run, domain: context.domain, plist: context.record(entryId)?.plistPath) else {
                outcomes.append(StepOutcome(entryId: entryId, action: "resume", result: .refused("unknown substitution token")))
                continue
            }
            let seq: Int
            do {
                seq = try journal.appendIntent(entryId: entryId, action: "resume", argv: argv)
            } catch {
                outcomes.append(StepOutcome(entryId: entryId, action: "resume", result: .refused("journal unwritable — \(error)")))
                continue
            }
            var failed: String?
            for step in argv {
                let result = runner(step)
                if result.status != 0 {
                    failed = "\(step.first ?? "?") exited \(result.status)"
                    break
                }
            }
            try? journal.appendOutcome(intent: seq, result: failed == nil ? "ok" : "failed", verified: failed == nil)

            // Close the original stop intent. Without this the journal keeps claiming the machine is
            // holding that stop, and a second `resume` runs the start recipe again — a real bug the
            // crash test caught. A *failed* resume leaves the original open so a retry still happens.
            if failed == nil {
                try? journal.appendOutcome(intent: intent.seq, result: "resumed", verified: true)
            }

            outcomes.append(StepOutcome(
                entryId: entryId, action: "resume",
                result: failed.map { .failed($0) } ?? .executed(verified: true)
            ))
        }
        return outcomes
    }

    // MARK: Refusals (checked before any intent is written)

    func refusal(for entry: CatalogEntry, context: ExecutionContext) -> String? {
        if NeverList.isProtected(label: entry.id) {
            return "on the never-list"
        }
        if entry.status == .draft {
            return "status is draft — a recipe must be verified before it can be applied"
        }
        if !entry.stoppable, entry.supervised == .none {
            return "no supervisor and stoppable false — a stop would be one-way"
        }
        let conflicting = Set(entry.ports).intersection(context.protectedPorts)
        if let port = conflicting.sorted().first {
            return "port \(port) is protected by a bundle"
        }
        if let pid = context.record(entry.id)?.pid, context.ownAncestry.contains(pid) {
            return "that pid is in Curfew's own process tree"
        }
        return nil
    }

    // MARK: Helpers

    /// `{domain}` and `{plist}` come from the machine, never from the catalog author's guess.
    ///
    /// `{plist}` exists because a hand-written path is a landmine: a bootstrap recipe recorded
    /// `~/Library/LaunchAgents/us.zoom.updater.plist` and the job actually lives in
    /// `/Library/LaunchAgents/` — the bootstrap failed and left the service down. `launchctl print`
    /// reports `path =`, so that is where it comes from.
    func substitute(_ steps: [[String]], domain: String, plist: String?) -> [[String]]? {
        var out: [[String]] = []
        for step in steps {
            var resolved: [String] = []
            for argument in step {
                guard argument.contains("{") else {
                    resolved.append(argument)
                    continue
                }
                if argument.contains("{plist}") {
                    guard let plist else { return nil }
                    resolved.append(argument.replacingOccurrences(of: "{plist}", with: plist))
                    continue
                }
                guard argument.contains("{domain}") else { return nil }
                resolved.append(argument.replacingOccurrences(of: "{domain}", with: domain))
            }
            out.append(resolved)
        }
        return out
    }

    func passes(_ verification: Verification, context: ExecutionContext) -> Bool {
        switch verification.kind {
        case .portClosed:
            guard let port = UInt16(verification.value) else { return false }
            return !probes.portIsOpen(port)
        case .processGone:
            guard let pid = Int32(verification.value) else { return false }
            return !probes.pidExists(pid)
        case .labelNotRunning:
            return !probes.labelIsRunning(verification.value)
        }
    }
}

/// Rule 7's machinery: the pids of this process and everything above it.
public enum ProcessAncestry {

    public static func chain(startingAt pid: Int32 = getpid()) -> Set<Int32> {
        var chain: Set<Int32> = []
        var current = pid
        var guardCount = 0
        while current > 1, guardCount < 64 {
            chain.insert(current)
            guard let parent = parentOf(current) else { break }
            current = parent
            guardCount += 1
        }
        chain.insert(1)
        return chain
    }

    static func parentOf(_ pid: Int32) -> Int32? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        let result = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size)
        guard result == size else { return nil }
        return Int32(info.pbi_ppid)
    }
}
