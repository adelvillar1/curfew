import Foundation

// MARK: - The entry

public enum EntryStatus: String, Sendable, Equatable {
    case draft
    case verified
}

/// How a stop is held. `pg_ctl stop` releases the port but leaves launchd supervising the job, so a
/// `KeepAlive` job can come straight back — the recipe says what to do about that rather than
/// pretending the stop is stable.
public enum Hold: String, Sendable, Equatable {
    case none
    case bootoutIfRespawned
}

/// What a stop must actually leave behind. `expect:` is for a human; this is what the executor
/// checks, and what makes `status: verified` mean something the tool can assert.
public enum VerifyKind: String, Sendable, Equatable {
    case portClosed = "port_closed"
    case processGone = "process_gone"
    case labelNotRunning = "label_not_running"
    /// `launchctl disable` marks a label so it will not be loaded again; it does **not** stop an
    /// instance that is already running, and an app-submitted job often has no plist to bootout from.
    /// Verifying such a recipe with `label_not_running` reports a failure for a stop that worked
    /// (KI-044: it aborted a whole bundle after one entry).
    case labelDisabled = "label_disabled"
}

public struct Verification: Sendable, Equatable {
    public var kind: VerifyKind
    public var value: String

    public init(kind: VerifyKind, value: String) {
        self.kind = kind
        self.value = value
    }
}

public struct Recipe: Sendable, Equatable {
    /// argv only, never a shell string: no quoting, no interpolation, no injection from a label.
    /// Several steps run in order; each is its own argv.
    public var run: [[String]]
    public var needsRoot: Bool
    /// What a successful stop looks like, in words the operator can check.
    public var expect: String?
    public var quiesce: String?
    public var hold: Hold
    public var meansReady: String?
    public var verify: Verification?
}

public struct CatalogEntry: Sendable, Equatable {
    public var id: String
    public var kind: Kind
    public var lever: Lever
    public var supervised: Supervision
    public var status: EntryStatus
    public var stop: Recipe?
    public var start: Recipe?
    public var hazards: [String]
    public var depends: [String]
    public var evidence: String?
    /// `false` means "this can be stopped but never started again" — the `kanzo` door.
    public var stoppable: Bool
    public var coldStartCost: String?
    /// Ports this entry's service holds. Declared so `apply` can refuse a conflict with a bundle's
    /// `protectPorts` before it touches anything.
    public var ports: [UInt16]
    public var file: String
}

public enum BundleKind: String, Sendable, Equatable {
    /// A mode that acts on its members.
    case stop
    /// A set that must never be actioned: `harness-core` and `never-cold`.
    case protect
}

public struct CatalogBundle: Sendable, Equatable {
    public var name: String
    public var kind: BundleKind
    public var summary: String
    /// Ports that survive a label rename or a reinstall, so the harness is protected by what it
    /// actually needs rather than by a name that moves.
    public var protectPorts: [UInt16]
    public var members: [String]
    public var file: String
}

public struct Catalog: Sendable, Equatable {
    public var entries: [CatalogEntry]
    public var bundles: [CatalogBundle]
    public var files: [String]

    public init(entries: [CatalogEntry], bundles: [CatalogBundle], files: [String]) {
        self.entries = entries
        self.bundles = bundles
        self.files = files
    }

    public func entry(_ id: String) -> CatalogEntry? { entries.first { $0.id == id } }
    public func bundle(_ name: String) -> CatalogBundle? { bundles.first { $0.name == name } }
}

// MARK: - Violations

public struct CatalogViolation: Sendable, Equatable, CustomStringConvertible {
    public enum Kind: String, Sendable {
        case neverListLabel
        case freezeWithSocket
        case verifiedWithoutEvidence
        case verifiedWithoutPostcondition
        case oneWayBootout
        case unsupervisedWithoutStart
        case noneLeverOutsideNeverCold
        case bundleProtectsProtectedEntry
        case missingDependency
        case malformed
    }

    public var kind: Kind
    public var subject: String
    public var detail: String
    public var file: String

    public var description: String { "\(file): \(subject) — \(detail)" }
}

// MARK: - Loading

public enum CatalogLoader {

    public static func load(directory: URL) throws -> Catalog {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path))?
            .filter { $0.hasSuffix(".yaml") || $0.hasSuffix(".yml") }
            .sorted() ?? []
        guard !names.isEmpty else {
            throw CatalogError.empty("no .yaml files in \(directory.path)")
        }

        var entries: [CatalogEntry] = []
        var bundles: [CatalogBundle] = []
        for name in names {
            let text = try String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8)
            let document = try MiniYAML.parse(text)
            if let list = document["entries"] {
                for case .map(let pairs) in Self.list(list) {
                    entries.append(try decodeEntry(pairs, file: name))
                }
            }
            if let list = document["bundles"] {
                for case .map(let pairs) in Self.list(list) {
                    bundles.append(try decodeBundle(pairs, file: name))
                }
            }
            if document["entries"] == nil, document["bundles"] == nil {
                throw CatalogError.malformed("\(name): expected an 'entries:' or 'bundles:' block")
            }
        }
        return Catalog(entries: entries, bundles: bundles, files: names)
    }

    // MARK: Decoding

    static func decodeEntry(_ pairs: [(String, YAMLValue)], file: String) throws -> CatalogEntry {
        let map = Dictionary(uniqueKeysWithValues: pairs)
        let allowed: Set<String> = [
            "id", "kind", "lever", "supervised", "status", "stop", "start",
            "hazards", "depends", "evidence", "stoppable", "coldStartCost", "ports",
        ]
        for key in map.keys where !allowed.contains(key) {
            throw CatalogError.unknownKey(file: file, key: key, id: map["id"]?.scalar ?? "?")
        }

        guard let id = map["id"]?.scalar, !id.isEmpty else {
            throw CatalogError.malformed("\(file): entry with no id")
        }
        guard let kindRaw = map["kind"]?.scalar, let kind = Kind(rawValue: kindRaw) else {
            throw CatalogError.badValue(file: file, id: id, key: "kind")
        }
        guard let leverRaw = map["lever"]?.scalar, let lever = Lever(rawValue: leverRaw) else {
            throw CatalogError.badValue(file: file, id: id, key: "lever")
        }
        guard let supervisedRaw = map["supervised"]?.scalar, let supervised = Supervision(rawValue: supervisedRaw) else {
            throw CatalogError.badValue(file: file, id: id, key: "supervised")
        }
        guard let statusRaw = map["status"]?.scalar, let status = EntryStatus(rawValue: statusRaw) else {
            throw CatalogError.badValue(file: file, id: id, key: "status")
        }

        return CatalogEntry(
            id: id,
            kind: kind,
            lever: lever,
            supervised: supervised,
            status: status,
            stop: try decodeRecipe(map["stop"], file: file, id: id, side: "stop"),
            start: try decodeRecipe(map["start"], file: file, id: id, side: "start"),
            hazards: map["hazards"]?.stringList ?? [],
            depends: map["depends"]?.stringList ?? [],
            evidence: map["evidence"]?.scalar,
            stoppable: map["stoppable"]?.scalar.map { $0 != "false" } ?? true,
            coldStartCost: map["coldStartCost"]?.scalar,
            ports: (map["ports"]?.stringList ?? []).compactMap(UInt16.init),
            file: file
        )
    }

    static func decodeRecipe(
        _ value: YAMLValue?, file: String, id: String, side: String
    ) throws -> Recipe? {
        guard let value, case .map(let pairs) = value else { return nil }
        let map = Dictionary(uniqueKeysWithValues: pairs)
        let allowed: Set<String> = ["run", "needsRoot", "expect", "quiesce", "hold", "meansReady", "verify"]
        for key in map.keys where !allowed.contains(key) {
            throw CatalogError.unknownKey(file: file, key: "\(side).\(key)", id: id)
        }
        guard let runValue = map["run"], let steps = runValue.steps, !steps.isEmpty, !steps[0].isEmpty else {
            throw CatalogError.malformed("\(file): \(id).\(side) has no run: argv list")
        }
        let holdRaw = map["hold"]?.scalar
        let hold = holdRaw.flatMap(Hold.init(rawValue:)) ?? .none
        if holdRaw != nil, Hold(rawValue: holdRaw ?? "") == nil {
            throw CatalogError.badValue(file: file, id: id, key: "\(side).hold")
        }
        var verification: Verification?
        if let block = map["verify"] {
            guard case .map(let verifyPairs) = block else {
                throw CatalogError.malformed("\(file): \(id).\(side).verify must be a block with kind and value")
            }
            let verifyMap = Dictionary(uniqueKeysWithValues: verifyPairs)
            for key in verifyMap.keys where !["kind", "value"].contains(key) {
                throw CatalogError.unknownKey(file: file, key: "\(side).verify.\(key)", id: id)
            }
            guard let kindRaw = verifyMap["kind"]?.scalar, let kind = VerifyKind(rawValue: kindRaw) else {
                throw CatalogError.badValue(file: file, id: id, key: "\(side).verify.kind")
            }
            guard let value = verifyMap["value"]?.scalar, !value.isEmpty else {
                throw CatalogError.badValue(file: file, id: id, key: "\(side).verify.value")
            }
            verification = Verification(kind: kind, value: value)
        }

        return Recipe(
            run: steps,
            needsRoot: map["needsRoot"]?.scalar == "true",
            expect: map["expect"]?.scalar,
            quiesce: map["quiesce"]?.scalar,
            hold: hold,
            meansReady: map["meansReady"]?.scalar,
            verify: verification
        )
    }

    static func decodeBundle(_ pairs: [(String, YAMLValue)], file: String) throws -> CatalogBundle {
        let map = Dictionary(uniqueKeysWithValues: pairs)
        let allowed: Set<String> = ["name", "kind", "summary", "protectPorts", "members"]
        for key in map.keys where !allowed.contains(key) {
            throw CatalogError.unknownKey(file: file, key: key, id: map["name"]?.scalar ?? "?")
        }
        guard let name = map["name"]?.scalar, !name.isEmpty else {
            throw CatalogError.malformed("\(file): bundle with no name")
        }
        let ports = (map["protectPorts"]?.stringList ?? []).compactMap(UInt16.init)
        let kindRaw = map["kind"]?.scalar ?? "stop"
        guard let kind = BundleKind(rawValue: kindRaw) else {
            throw CatalogError.badValue(file: file, id: name, key: "kind")
        }
        return CatalogBundle(
            name: name,
            kind: kind,
            summary: map["summary"]?.scalar ?? "",
            protectPorts: ports,
            members: map["members"]?.stringList ?? [],
            file: file
        )
    }

    static func list(_ value: YAMLValue) -> [YAMLValue] {
        if case .list(let items) = value { return items }
        return []
    }
}

extension YAMLValue {
    var scalar: String? {
        if case .scalar(let text) = self { return text }
        return nil
    }

    var stringList: [String]? {
        guard case .list(let items) = self else { return nil }
        return items.compactMap(\.scalar)
    }

    /// Either one argv (`[a, b]`) or several steps (`[[a], [b]]`).
    var steps: [[String]]? {
        guard case .list(let items) = self else { return nil }
        if items.allSatisfy({ $0.scalar != nil }) {
            return [items.compactMap(\.scalar)]
        }
        let steps = items.compactMap { $0.stringList }
        return steps.isEmpty ? nil : steps
    }
}

public enum CatalogError: Error, Equatable, CustomStringConvertible {
    case empty(String)
    case malformed(String)
    case unknownKey(file: String, key: String, id: String)
    case badValue(file: String, id: String, key: String)

    public var description: String {
        switch self {
        case .empty(let detail): return detail
        case .malformed(let detail): return detail
        case .unknownKey(let file, let key, let id):
            return "\(file): \(id) has an unknown key '\(key)' — a typo in a recipe must not be ignored"
        case .badValue(let file, let id, let key):
            return "\(file): \(id) has an invalid value for '\(key)'"
        }
    }
}

// MARK: - Validation

public enum CatalogValidator {

    public static func validate(_ catalog: Catalog) -> [CatalogViolation] {
        var violations: [CatalogViolation] = []

        for entry in catalog.entries {
            // D9: the never-list cannot be expressed in a catalog at all.
            if NeverList.isProtected(label: entry.id) {
                violations.append(.init(
                    kind: .neverListLabel, subject: entry.id,
                    detail: "is on the never-list; a catalog entry for it must not exist", file: entry.file
                ))
            }

            // D10 / rule 4: freeze only where there is no socket to hang.
            if entry.lever == .freeze, entry.hazards.contains(where: { $0.contains("socket") || $0.contains("port") }) {
                violations.append(.init(
                    kind: .freezeWithSocket, subject: entry.id,
                    detail: "declares lever freeze but also a socket/port hazard — a frozen server hangs its clients",
                    file: entry.file
                ))
            }

            // Rule 5.
            if entry.status == .verified, (entry.evidence ?? "").isEmpty {
                violations.append(.init(
                    kind: .verifiedWithoutEvidence, subject: entry.id,
                    detail: "is marked verified with no evidence — cite the date, this host, and what was observed",
                    file: entry.file
                ))
            }
            // A bootout without a bootstrap is a one-way door: the job is gone and only relaunching
            // its parent app brings it back. Seven jobs on this machine are submitted by an app and
            // have no plist at all — those may only be disabled, never booted out.
            if let stop = entry.stop,
               stop.run.contains(where: { $0.contains("bootout") }) {
                let canRestore = entry.start?.run.contains(where: { step in
                    step.contains("bootstrap") && step.contains(where: { $0.contains("{plist}") })
                }) ?? false
                if !canRestore {
                    violations.append(.init(
                        kind: .oneWayBootout, subject: entry.id,
                        detail: "boots the job out with no `bootstrap {plist}` to bring it back — that is a one-way door; use the disable lever instead",
                        file: entry.file
                    ))
                }
            }

            // "Verified" must be something the tool can assert, not a word about a return code.
            if entry.status == .verified, let stop = entry.stop, stop.verify == nil {
                violations.append(.init(
                    kind: .verifiedWithoutPostcondition, subject: entry.id,
                    detail: "is verified but its stop has no verify: block — expect: is prose, a post-condition is a check",
                    file: entry.file
                ))
            }

            // D12: an unsupervised stop is a one-way door unless the entry says so.
            if entry.supervised == .none, entry.start == nil, entry.stoppable {
                violations.append(.init(
                    kind: .unsupervisedWithoutStart, subject: entry.id,
                    detail: "has no supervisor and no start recipe — set stoppable: false or provide one",
                    file: entry.file
                ))
            }

            // D14: in-process engines have no lever.
            if entry.lever == .none, entry.coldStartCost == nil {
                violations.append(.init(
                    kind: .noneLeverOutsideNeverCold, subject: entry.id,
                    detail: "uses lever none without coldStartCost — only never-cold entries may do that",
                    file: entry.file
                ))
            }

            // A recipe is argv, so the only substitution allowed is the documented one. An
            // unknown {token} would reach the executor as a literal argument.
            for side in [("stop", entry.stop), ("start", entry.start)] {
                guard let recipe = side.1 else { continue }
                for argument in recipe.run.flatMap({ $0 }) where argument.contains("{") {
                    let allowedTokens = Set(["domain", "plist"])
                    for token in arguments(of: argument) where !allowedTokens.contains(token) {
                        violations.append(.init(
                            kind: .malformed, subject: entry.id,
                            detail: "\(side.0) recipe uses an unsupported token {\(token)}", file: entry.file
                        ))
                    }
                }
            }

            for dependency in entry.depends where catalog.entry(dependency) == nil {
                violations.append(.init(
                    kind: .missingDependency, subject: entry.id,
                    detail: "depends on '\(dependency)', which no entry defines", file: entry.file
                ))
            }
        }

        // D0: a protected job may not enter a bundle.
        for bundle in catalog.bundles {
            for member in bundle.members {
                guard let entry = catalog.entry(member) else {
                    violations.append(.init(
                        kind: .missingDependency, subject: bundle.name,
                        detail: "names '\(member)', which no entry defines", file: bundle.file
                    ))
                    continue
                }
                if bundle.kind == .stop, entry.lever == .none {
                    violations.append(.init(
                        kind: .bundleProtectsProtectedEntry, subject: bundle.name,
                        detail: "contains '\(member)', which has no lever and must not be actioned", file: bundle.file
                    ))
                }
            }
        }

        return violations
    }

    static func arguments(of text: String) -> [String] {
        var out: [String] = []
        var remainder = Substring(text)
        while let open = remainder.firstIndex(of: "{") {
            guard let close = remainder[open...].firstIndex(of: "}") else { break }
            out.append(String(remainder[remainder.index(after: open)..<close]))
            remainder = remainder[remainder.index(after: close)...]
        }
        return out
    }
}


// MARK: - Planning (still read-only: it computes, it does not act)

public enum CatalogPlanner {

    /// Resolve a bundle into an ordered list of steps, refusals and the ports it must not touch.
    ///
    /// Ordering respects `depends`; a cycle is a refusal, not a crash.
    /// `privilegedAvailable` decides whether a root recipe is a step or a refusal: the planner
    /// reports what this invocation can actually do, and a `needsRoot` recipe run without sudo is
    /// exactly as unavailable as a draft one.
    public static func plan(
        bundle name: String,
        in catalog: Catalog,
        privilegedAvailable: Bool = false
    ) -> (steps: [CatalogStep], refusals: [CatalogRefusal], protectedPorts: [UInt16]) {
        guard let bundle = catalog.bundle(name) else {
            return ([], [CatalogRefusal(id: name, reason: "no such bundle")], [])
        }
        let protectedPorts = Set(catalog.bundles.filter { $0.kind == .protect }.flatMap(\.protectPorts))
            .union(bundle.protectPorts).sorted()

        if bundle.kind == .protect {
            return ([], [CatalogRefusal(id: name, reason: "a protect bundle is never actioned")], protectedPorts)
        }

        var refusals: [CatalogRefusal] = []
        var ordered: [CatalogEntry] = []
        var visiting: Set<String> = []
        var done: Set<String> = []

        func visit(_ id: String) {
            if done.contains(id) { return }
            if visiting.contains(id) {
                refusals.append(CatalogRefusal(id: id, reason: "dependency cycle"))
                return
            }
            guard let entry = catalog.entry(id) else {
                refusals.append(CatalogRefusal(id: id, reason: "bundle member has no catalog entry"))
                return
            }
            visiting.insert(id)
            for dependency in entry.depends { visit(dependency) }
            visiting.remove(id)
            done.insert(id)
            ordered.append(entry)
        }
        for member in bundle.members { visit(member) }

        var steps: [CatalogStep] = []
        for entry in ordered {
            if entry.status == .draft {
                refusals.append(CatalogRefusal(id: entry.id, reason: "status is draft — a recipe must be verified before it can be applied"))
                continue
            }
            guard let stop = entry.stop else {
                refusals.append(CatalogRefusal(id: entry.id, reason: "no stop recipe"))
                continue
            }
            if stop.needsRoot, !privilegedAvailable {
                refusals.append(CatalogRefusal(id: entry.id, reason: "recipe needs root — run with sudo"))
                continue
            }
            steps.append(CatalogStep(id: entry.id, action: entry.lever.rawValue, argv: stop.run, expectation: stop.expect))
        }
        return (steps, refusals, protectedPorts)
    }
}
