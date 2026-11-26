import Foundation
import Testing
@testable import CurfewKit

/// Plan criteria C2 and C3, proven as logic: the cua driver refuses input to this window (KI-064), so a
/// criterion that depends on typing or clicking has to be testable another way.
@Suite("Service list")
struct ServiceListTests {

    static func service(
        _ label: String, name: String, group: String = "Agents", state: String = "running",
        findings: Int = 0
    ) -> AppSnapshot.Service {
        AppSnapshot.Service(label: label, displayName: name, group: group, state: state,
                            tier: "appleAgent", findingCount: findings)
    }

    static let rows = [
        service("application.com.apple.ActivityMonitor.1.2", name: "Activity Monitor", group: "Apps"),
        service("com.apple.AddressBook.abd", name: "Address Book", state: "not loaded", findings: 2),
        service("com.adelvillar1.blend1-service", name: "Blend1 Service", group: "Daemons", findings: 1),
        service("com.apple.accounts", name: "Accounts", state: "not loaded"),
    ]

    var rows: [AppSnapshot.Service] { Self.rows }

    // MARK: C2 — typing filters

    @Test("an empty query keeps everything, and whitespace is not a query")
    func emptyQuery() {
        #expect(ServiceList.filter(rows, query: "").count == 4)
        #expect(ServiceList.filter(rows, query: "   ").count == 4)
    }

    @Test("the query matches the display name")
    func filtersByDisplayName() {
        let hits = ServiceList.filter(rows, query: "activity")
        #expect(hits.map(\.displayName) == ["Activity Monitor"])
    }

    @Test("the query also matches the raw label, which is what a CLI user knows")
    func filtersByLabel() {
        let hits = ServiceList.filter(rows, query: "blend1-service")
        #expect(hits.map(\.displayName) == ["Blend1 Service"])
    }

    @Test("no match yields nothing rather than everything")
    func noMatch() {
        #expect(ServiceList.filter(rows, query: "zzzz").isEmpty)
    }

    // MARK: C3 — sorting

    @Test("sorting by name is alphabetical and case-insensitive")
    func sortByName() {
        #expect(ServiceList.sort(rows, by: .name).map(\.displayName)
                == ["Accounts", "Activity Monitor", "Address Book", "Blend1 Service"])
    }

    @Test("sorting by findings puts the most findings first")
    func sortByFindings() {
        #expect(ServiceList.sort(rows, by: .findings).map(\.findingCount) == [2, 1, 0, 0])
    }

    @Test("sorting by state groups the states")
    func sortByState() {
        let states = ServiceList.sort(rows, by: .state).map(\.state)
        #expect(states == states.sorted(), "states come back in order")
    }

    // MARK: grouping

    @Test("groups come back in a fixed order, whatever the input order")
    func grouping() {
        let groups = ServiceList.group(rows)
        #expect(groups.map(\.name) == ["Apps", "Agents", "Daemons"])
        #expect(groups.first(where: { $0.name == "Agents" })?.rows.count == 2)
    }

    @Test("the three steps compose in the order the pane applies them")
    func present() {
        let shown = ServiceList.present(rows, query: "address", sort: .name)
        #expect(shown.count == 1)
        #expect(shown.first?.rows.map(\.displayName) == ["Address Book"])
    }
}
