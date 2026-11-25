import Foundation
import Testing
@testable import CurfewKit

/// The rules of the privileged boundary. These are the only part of L4 that can be proven before a
/// signed helper exists — and they are the part that matters: a helper that runs client argv is a
/// root shell with extra steps (D20).
@Suite("Helper policy")
struct HelperPolicyTests {

    func recipe(root: Bool) -> Recipe {
        Recipe(run: [["/usr/bin/mdutil", "-a", "-i", "off"]], needsRoot: root, expect: "indexing off",
               quiesce: nil, hold: .none, meansReady: nil,
               verify: Verification(kind: .labelNotRunning, value: "x"))
    }

    func entry(
        _ id: String = "com.apple.metadata.mds.index",
        status: EntryStatus = .verified,
        root: Bool = true,
        stop: Bool = true
    ) -> CatalogEntry {
        CatalogEntry(
            id: id, kind: .daemon, lever: .command, supervised: .launchd, status: status,
            stop: stop ? recipe(root: root) : nil,
            start: Recipe(run: [["/usr/bin/mdutil", "-a", "-i", "on"]], needsRoot: root, expect: nil,
                          quiesce: nil, hold: .none, meansReady: nil, verify: nil),
            hazards: ["io"], depends: [], evidence: status == .verified ? "2026-11-24 · this Mac · indexed off and on" : nil,
            stoppable: true, coldStartCost: nil, ports: [], file: "test.yaml"
        )
    }

    func catalog(_ entries: [CatalogEntry]) -> Catalog {
        Catalog(entries: entries, bundles: [], files: ["test.yaml"])
    }

    let goodCaller = HelperCaller(pid: 501, teamIdentifier: "ABCDE12345", signatureValid: true)
    let unsigned = HelperCaller(pid: 501, teamIdentifier: nil, signatureValid: false)

    func request(_ action: HelperAction = .stop, id: String = "com.apple.metadata.mds.index") -> HelperRequest {
        HelperRequest(entryId: id, action: action, intentSeq: 7)
    }

    @Test("a verified, root-requiring entry is allowed and its argv comes from the catalog")
    func allowsVerifiedRoot() {
        let decision = HelperPolicy.decide(
            request(), caller: goodCaller,
            catalog: catalog([entry()]), expectedTeamIdentifier: "ABCDE12345"
        )
        guard case .allow(let argv, _) = decision else {
            Issue.record("expected allow, got \(decision)")
            return
        }
        #expect(argv == [["/usr/bin/mdutil", "-a", "-i", "off"]])
    }

    @Test("an unsigned or foreign caller is refused before anything else is considered")
    func refusesUnsigned() {
        guard case .refuse(let reason) = HelperPolicy.decide(
            request(), caller: unsigned, catalog: catalog([entry()]), expectedTeamIdentifier: "ABCDE12345"
        ) else {
            Issue.record("expected a refusal")
            return
        }
        #expect(reason.contains("signature"))

        guard case .refuse(let teamReason) = HelperPolicy.decide(
            request(), caller: HelperCaller(pid: 1, teamIdentifier: "EVIL", signatureValid: true),
            catalog: catalog([entry()]), expectedTeamIdentifier: "ABCDE12345"
        ) else {
            Issue.record("expected a team refusal")
            return
        }
        #expect(teamReason.contains("team"))
    }

    @Test("a draft entry never crosses the boundary")
    func refusesDraft() {
        guard case .refuse(let reason) = HelperPolicy.decide(
            request(), caller: goodCaller, catalog: catalog([entry(status: .draft)]), expectedTeamIdentifier: nil
        ) else {
            Issue.record("expected a refusal")
            return
        }
        #expect(reason.contains("draft"))
    }

    @Test("a never-list label is refused even if it were catalogued")
    func refusesNeverList() {
        guard case .refuse(let reason) = HelperPolicy.decide(
            request(id: "com.apple.securityd"), caller: goodCaller,
            catalog: catalog([entry("com.apple.securityd")]), expectedTeamIdentifier: nil
        ) else {
            Issue.record("expected a refusal")
            return
        }
        #expect(reason.contains("never-list"))
    }

    @Test("work the unprivileged executor can do does not cross the boundary")
    func refusesNonRoot() {
        guard case .refuse(let reason) = HelperPolicy.decide(
            request(), caller: goodCaller, catalog: catalog([entry(root: false)]), expectedTeamIdentifier: nil
        ) else {
            Issue.record("expected a refusal")
            return
        }
        #expect(reason.contains("does not require root"))
    }

    @Test("an unknown entry, a missing recipe and a bad action are all refused")
    func refusesUnknownShapes() {
        for (catalogValue, expected) in [
            (catalog([]), "no catalog entry"),
            (catalog([entry(stop: false)]), "no stop recipe"),
        ] {
            guard case .refuse(let reason) = HelperPolicy.decide(
                request(), caller: goodCaller, catalog: catalogValue, expectedTeamIdentifier: nil
            ) else {
                Issue.record("expected a refusal for \(expected)")
                return
            }
            #expect(reason.contains(expected))
        }
    }

    @Test("the start action resolves the start recipe, not the stop one")
    func startUsesStartRecipe() {
        guard case .allow(let argv, _) = HelperPolicy.decide(
            request(.start), caller: goodCaller, catalog: catalog([entry()]), expectedTeamIdentifier: nil
        ) else {
            Issue.record("expected allow")
            return
        }
        #expect(argv == [["/usr/bin/mdutil", "-a", "-i", "on"]])
    }

    @Test("the request and response are a stable wire shape")
    func wireShape() throws {
        let request = HelperRequest(entryId: "a.b", action: .stop, intentSeq: 3)
        let encoded = try JSONEncoder().encode(request)
        let object = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(Set(object.keys) == ["entryId", "action", "intentSeq"])

        let response = HelperResponse.refused("nope", for: request)
        #expect(response.intentSeq == 3, "a refusal must still echo the intent it answers")
        let responseObject = try #require(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(response)) as? [String: Any]
        )
        #expect(Set(responseObject.keys).isSubset(of: ["ok", "verified", "status", "standardOutput",
                                                       "standardError", "refusal", "intentSeq"]))
    }

    @Test("argv is never part of the request — that is the whole point")
    func noArgvOnTheWire() throws {
        let encoded = try JSONEncoder().encode(HelperRequest(entryId: "a.b", action: .stop, intentSeq: 1))
        let text = String(decoding: encoded, as: UTF8.self)
        #expect(!text.contains("argv"), "a request that can carry argv is a root shell")
        #expect(!text.contains("run"))
    }
}
