import Foundation
import Testing
@testable import CurfewKit

// MARK: - The parser

@Suite("MiniYAML")
struct MiniYAMLTests {

    @Test("parses the shapes the catalog uses")
    func parsesCatalogShapes() throws {
        let text = """
        # a comment
        entries:
          - id: com.example.job
            lever: stop
            hazards: [socket, data]
            stop:
              run:
                - [/bin/launchctl, bootout, {domain}/com.example.job]
              expect: port released
        """
        let document = try MiniYAML.parse(text)
        let entries = try #require(document["entries"]?.stringList ?? { if case .list(let l) = document["entries"]! { return l.compactMap(\.scalar) } ; return nil }())
        _ = entries
        guard case .list(let items) = document["entries"], case .map(let pairs) = items[0] else {
            Issue.record("expected a list of maps")
            return
        }
        let map = Dictionary(uniqueKeysWithValues: pairs)
        #expect(map["id"]?.scalar == "com.example.job")
        #expect(map["hazards"]?.stringList == ["socket", "data"])
        #expect(map["stop"]?["run"]?.steps?.first?.count == 3)
    }

    @Test("a single argv and a multi-step recipe both decode")
    func recipeForms() throws {
        let single = try MiniYAML.parse("run: [/bin/a, b]")
        #expect(single["run"]?.steps == [["/bin/a", "b"]])

        let multi = try MiniYAML.parse("""
        run:
          - [/bin/a]
          - [/bin/b, c]
        """)
        #expect(multi["run"]?.steps == [["/bin/a"], ["/bin/b", "c"]])
    }

    @Test("rejects a tab, a duplicate key and a block scalar")
    func rejectsUnsafeShapes() {
        #expect(throws: YAMLError.self) { try MiniYAML.parse("\tkey: value") }
        #expect(throws: YAMLError.self) { try MiniYAML.parse("a: 1\na: 2") }
        #expect(throws: YAMLError.self) { try MiniYAML.parse("a: |\n  block") }
        #expect(throws: YAMLError.self) { try MiniYAML.parse("a: {inline: map}") }
        #expect(throws: YAMLError.self) { try MiniYAML.parse("---\na: 1") }
    }

    @Test("a comment inside a value is not stripped when quoted")
    func quotedHash() throws {
        let document = try MiniYAML.parse("""
        note: "a # b"
        other: c # trailing
        """)
        #expect(document["note"]?.scalar == "a # b")
        #expect(document["other"]?.scalar == "c")
    }
}

// MARK: - The catalog

@Suite("Catalog")
struct CatalogTests {

    static var repoCatalog: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("catalog")
    }

    func entry(
        _ id: String,
        lever: Lever = .stop,
        supervised: Supervision = .launchd,
        status: EntryStatus = .draft,
        hazards: [String] = [],
        evidence: String? = nil,
        stoppable: Bool = true,
        coldStartCost: String? = nil,
        depends: [String] = [],
        stop: Recipe? = nil,
        start: Recipe? = nil
    ) -> CatalogEntry {
        CatalogEntry(
            id: id, kind: .agent, lever: lever, supervised: supervised, status: status,
            stop: stop, start: start, hazards: hazards, depends: depends,
            evidence: evidence, stoppable: stoppable, coldStartCost: coldStartCost, ports: [], file: "test.yaml"
        )
    }

    func recipe(_ argv: [String] = ["/bin/true"], root: Bool = false) -> Recipe {
        Recipe(run: [argv], needsRoot: root, expect: nil, quiesce: nil, hold: .none, meansReady: nil)
    }

    // MARK: Loading

    @Test("loads the repository's own catalog")
    func loadsRepoCatalog() throws {
        let catalog = try CatalogLoader.load(directory: Self.repoCatalog)
        // Counts rot on every catalog change and prove nothing; these are the invariants instead.
        #expect(!catalog.entries.isEmpty)
        #expect(!catalog.bundles.isEmpty)
        for bundle in catalog.bundles {
            for member in bundle.members {
                #expect(catalog.entry(member) != nil, "\(bundle.name) names \(member), which no entry defines")
            }
        }
        // A bundle that acts must not include an entry that says it cannot be stopped.
        for bundle in catalog.bundles where bundle.kind == .stop {
            for member in bundle.members {
                #expect(catalog.entry(member)?.stoppable != false,
                        "\(bundle.name) includes \(member), which is marked unstoppable")
            }
        }
        #expect(catalog.entry("sh.brew.postgresql@18")?.lever == Lever.none,
                "the database is always-on by owner decision, not a stop target")
        #expect(catalog.entry("laya")?.lever == Lever.none, "Lever.none, not Optional.none — `== .none` on an optional reads as nil")
        #expect(catalog.bundle("harness-core")?.kind == .protect)
        #expect(catalog.bundle("harness-core")?.protectPorts.contains(8901) == true)
        #expect(CatalogValidator.validate(catalog).isEmpty, "the shipped catalog must be valid")
    }

    @Test("an always-on entry carries no recipe and says so")
    func alwaysOnHasNoRecipe() throws {
        let catalog = try CatalogLoader.load(directory: Self.repoCatalog)
        let postgres = try #require(catalog.entry("sh.brew.postgresql@18"))
        #expect(postgres.stoppable == false)
        #expect(postgres.stop == nil, "there is nothing to verify: the decision is not to stop it")
        #expect(postgres.evidence?.contains("owner decision") == true)

        // and no bundle that acts may include it
        for bundle in catalog.bundles where bundle.kind == .stop {
            #expect(!bundle.members.contains(postgres.id))
        }
    }

    @Test("an unknown key is a load error, not a silent drop")
    func unknownKey() throws {
        let dir = try tempCatalog("""
        entries:
          - id: com.example.job
            lever: stop
            kind: agent
            supervised: launchd
            status: draft
            stpo:
              run: [/bin/true]
        """)
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(throws: CatalogError.self) { try CatalogLoader.load(directory: dir) }
    }

    // MARK: Validation — one test per rule

    @Test("a never-list label cannot be catalogued")
    func neverListRefused() {
        let catalog = Catalog(entries: [entry("com.apple.securityd")], bundles: [], files: ["x"])
        let violations = CatalogValidator.validate(catalog)
        #expect(violations.contains { $0.kind == .neverListLabel })
    }

    @Test("freeze is illegal on anything with a socket")
    func freezeWithSocket() {
        let catalog = Catalog(
            entries: [entry("com.example.srv", lever: .freeze, hazards: ["socket"])],
            bundles: [], files: ["x"]
        )
        #expect(CatalogValidator.validate(catalog).contains { $0.kind == .freezeWithSocket })
    }

    @Test("freeze is legal on a GUI app with no socket")
    func freezeWithoutSocket() {
        let catalog = Catalog(entries: [entry("com.example.app", lever: .freeze, hazards: ["ui"])], bundles: [], files: ["x"])
        #expect(CatalogValidator.validate(catalog).isEmpty)
    }

    @Test("verified without evidence is refused")
    func verifiedNeedsEvidence() {
        let without = Catalog(entries: [entry("a.b", status: .verified)], bundles: [], files: ["x"])
        #expect(CatalogValidator.validate(without).contains { $0.kind == .verifiedWithoutEvidence })

        let with = Catalog(
            entries: [entry("a.b", status: .verified, evidence: "2026-11-24 · this Mac · stopped and restarted clean")],
            bundles: [], files: ["x"]
        )
        #expect(CatalogValidator.validate(with).isEmpty)
    }

    @Test("an unsupervised stop needs a start recipe or an explicit one-way flag")
    func unsupervisedDoor() {
        let bare = Catalog(entries: [entry("unmanaged:x@1", supervised: .none)], bundles: [], files: ["x"])
        #expect(CatalogValidator.validate(bare).contains { $0.kind == .unsupervisedWithoutStart })

        let declared = Catalog(entries: [entry("unmanaged:x@1", supervised: .none, stoppable: false)], bundles: [], files: ["x"])
        #expect(CatalogValidator.validate(declared).isEmpty)

        let restartable = Catalog(
            entries: [entry("unmanaged:x@1", supervised: .none, start: recipe(["/bin/true"]))],
            bundles: [], files: ["x"]
        )
        #expect(CatalogValidator.validate(restartable).isEmpty)
    }

    @Test("lever none is only for never-cold entries")
    func noneLever() {
        let bare = Catalog(entries: [entry("laya", lever: .none, supervised: .none, stoppable: false)], bundles: [], files: ["x"])
        #expect(CatalogValidator.validate(bare).contains { $0.kind == .noneLeverOutsideNeverCold })

        let cold = Catalog(
            entries: [entry("laya", lever: .none, supervised: .none, stoppable: false, coldStartCost: "180 s")],
            bundles: [], files: ["x"]
        )
        #expect(CatalogValidator.validate(cold).isEmpty)
    }

    @Test("a dependency must exist")
    func missingDependency() {
        let catalog = Catalog(entries: [entry("a.b", depends: ["nope"])], bundles: [], files: ["x"])
        #expect(CatalogValidator.validate(catalog).contains { $0.kind == .missingDependency })
    }

    @Test("an acting bundle may not contain a lever-less entry")
    func actingBundleExcludesNone() {
        let catalog = Catalog(
            entries: [entry("laya", lever: .none, supervised: .none, stoppable: false, coldStartCost: "180 s")],
            bundles: [CatalogBundle(name: "quiet", kind: .stop, summary: "", protectPorts: [], members: ["laya"], file: "x")],
            files: ["x"]
        )
        #expect(CatalogValidator.validate(catalog).contains { $0.kind == .bundleProtectsProtectedEntry })
    }

    @Test("a protecting bundle may list a lever-less entry")
    func protectBundleAllowsNone() {
        let catalog = Catalog(
            entries: [entry("laya", lever: .none, supervised: .none, stoppable: false, coldStartCost: "180 s")],
            bundles: [CatalogBundle(name: "never-cold", kind: .protect, summary: "", protectPorts: [], members: ["laya"], file: "x")],
            files: ["x"]
        )
        #expect(CatalogValidator.validate(catalog).isEmpty)
    }

    @Test("an unknown substitution token is refused")
    func unknownToken() {
        let bad = entry("a.b", stop: recipe(["/bin/kill", "{pid}"]))
        let catalog = Catalog(entries: [bad], bundles: [], files: ["x"])
        #expect(CatalogValidator.validate(catalog).contains { $0.kind == .malformed })

        // A bootout needs a restorable start recipe, or it is a one-way door (and that is a
        // different rule than the one under test here).
        var good = entry("a.b", stop: recipe(["/bin/launchctl", "bootout", "{domain}/a.b"]))
        good.start = Recipe(run: [["/bin/launchctl", "bootstrap", "{domain}", "{plist}"]], needsRoot: false,
                            expect: nil, quiesce: nil, hold: .none, meansReady: nil, verify: nil)
        let ok = Catalog(entries: [good], bundles: [], files: ["x"])
        #expect(CatalogValidator.validate(ok).isEmpty)
    }

    // MARK: Planning

    @Test("a draft entry is refused, not planned")
    func draftRefused() {
        let catalog = Catalog(
            entries: [entry("a.b", stop: recipe())],
            bundles: [CatalogBundle(name: "b", kind: .stop, summary: "", protectPorts: [], members: ["a.b"], file: "x")],
            files: ["x"]
        )
        let plan = CatalogPlanner.plan(bundle: "b", in: catalog)
        #expect(plan.steps.isEmpty)
        #expect(plan.refusals.first?.id == "a.b")
        #expect(plan.refusals.first?.reason.contains("draft") == true)
    }

    @Test("a verified entry plans its argv in order")
    func verifiedPlans() {
        let catalog = Catalog(
            entries: [
                entry("a.b", status: .verified, evidence: "dated", stop: recipe(["/bin/a"])),
                entry("c.d", status: .verified, evidence: "dated", stop: recipe(["/bin/c"])),
            ],
            bundles: [CatalogBundle(name: "b", kind: .stop, summary: "", protectPorts: [], members: ["c.d", "a.b"], file: "x")],
            files: ["x"]
        )
        let plan = CatalogPlanner.plan(bundle: "b", in: catalog)
        #expect(plan.steps.map(\.id) == ["c.d", "a.b"])
        #expect(plan.steps.first?.argv == [["/bin/c"]])
    }

    @Test("a protect bundle is never actioned")
    func protectNeverActs() throws {
        let catalog = try CatalogLoader.load(directory: Self.repoCatalog)
        let plan = CatalogPlanner.plan(bundle: "harness-core", in: catalog)
        #expect(plan.steps.isEmpty)
        #expect(plan.refusals.first?.reason.contains("never actioned") == true)
        #expect(plan.protectedPorts.contains(8901), "a protect bundle still reports the ports it guards")
    }

    @Test("a cycle is a refusal, not a hang")
    func cycleRefused() {
        let catalog = Catalog(
            entries: [
                entry("a.b", status: .verified, evidence: "d", depends: ["c.d"], stop: recipe()),
                entry("c.d", status: .verified, evidence: "d", depends: ["a.b"], stop: recipe()),
            ],
            bundles: [CatalogBundle(name: "b", kind: .stop, summary: "", protectPorts: [], members: ["a.b"], file: "x")],
            files: ["x"]
        )
        let plan = CatalogPlanner.plan(bundle: "b", in: catalog)
        #expect(plan.refusals.contains { $0.reason == "dependency cycle" })
    }

    // MARK: Helpers

    func tempCatalog(_ text: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("curfew-catalog-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try text.write(to: dir.appendingPathComponent("test.yaml"), atomically: true, encoding: .utf8)
        return dir
    }
}

/// The catalog path must not be able to run anything, even by accident.
@Suite("Catalog is read-only")
struct CatalogReadOnlyTests {

    static var sourcesRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/CurfewKit")
    }

    @Test("no catalog source spawns a process")
    func noSpawn() throws {
        for name in ["Catalog.swift", "MiniYAML.swift"] {
            let text = try String(contentsOf: Self.sourcesRoot.appendingPathComponent(name), encoding: .utf8)
            #expect(!text.contains("Process("), "\(name) must not spawn anything — planning is arithmetic")
            #expect(!text.contains("executableURL"))
        }
    }
}

@Suite("One-way doors")
struct OneWayBootoutTests {

    func entry(stop: [[String]], start: [[String]]?) -> CatalogEntry {
        CatalogEntry(
            id: "a.b", kind: .agent, lever: .disable, supervised: .launchd, status: .draft,
            stop: Recipe(run: stop, needsRoot: false, expect: nil, quiesce: nil, hold: .none, meansReady: nil, verify: nil),
            start: start.map {
                Recipe(run: $0, needsRoot: false, expect: nil, quiesce: nil, hold: .none, meansReady: nil, verify: nil)
            },
            hazards: [], depends: [], evidence: nil as String?,
            stoppable: true, coldStartCost: nil, ports: [], file: "x.yaml"
        )
    }

    @Test("a bootout with no bootstrap is refused")
    func bootoutWithoutBootstrap() {
        let catalog = Catalog(
            entries: [entry(stop: [["/bin/launchctl", "bootout", "{domain}/a.b"]], start: nil)],
            bundles: [], files: ["x"]
        )
        #expect(CatalogValidator.validate(catalog).contains { $0.kind == .oneWayBootout })
    }

    @Test("a bootout with no plist to restore from is refused")
    func bootoutWithoutPlist() {
        let catalog = Catalog(
            entries: [entry(
                stop: [["/bin/launchctl", "bootout", "{domain}/a.b"]],
                start: [["/bin/launchctl", "bootstrap", "{domain}"]]
            )],
            bundles: [], files: ["x"]
        )
        #expect(CatalogValidator.validate(catalog).contains { $0.kind == .oneWayBootout },
                "bootstrap without a plist names no job to load")
    }

    @Test("bootout with a plist-backed bootstrap passes")
    func bootoutWithBootstrap() {
        let catalog = Catalog(
            entries: [entry(
                stop: [["/bin/launchctl", "bootout", "{domain}/a.b"]],
                start: [["/bin/launchctl", "bootstrap", "{domain}", "{plist}"]]
            )],
            bundles: [], files: ["x"]
        )
        #expect(CatalogValidator.validate(catalog).isEmpty)
    }

    @Test("a disable-only recipe passes — that is the reversible shape")
    func disableOnly() {
        let catalog = Catalog(
            entries: [entry(stop: [["/bin/launchctl", "disable", "{domain}/a.b"]],
                            start: [["/bin/launchctl", "enable", "{domain}/a.b"]])],
            bundles: [], files: ["x"]
        )
        #expect(CatalogValidator.validate(catalog).isEmpty)
    }
}
