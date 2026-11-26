import Foundation

/// The Services list's ordering, grouping and filtering, as pure functions.
///
/// The view was carrying this logic, which made "typing filters the rows" and "the sort survives a pane
/// switch" testable only by driving a mouse — and the cua driver refuses input to this window (KI-064).
/// Keeping it here makes both criteria provable by test.
public enum ServiceList {

    public enum Sort: String, CaseIterable, Sendable {
        case name = "Name"
        case state = "State"
        case findings = "Findings"
    }

    /// Filter on the display name **or** the raw label, case-insensitively; empty query keeps everything.
    public static func filter(_ services: [AppSnapshot.Service], query: String) -> [AppSnapshot.Service] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return services }
        return services.filter {
            $0.displayName.localizedCaseInsensitiveContains(text)
                || $0.label.localizedCaseInsensitiveContains(text)
        }
    }

    public static func sort(_ services: [AppSnapshot.Service], by order: Sort) -> [AppSnapshot.Service] {
        services.sorted { left, right in
            switch order {
            case .name:
                return left.displayName.localizedCaseInsensitiveCompare(right.displayName) == .orderedAscending
            case .state:
                if left.state != right.state { return left.state < right.state }
                return left.displayName.localizedCaseInsensitiveCompare(right.displayName) == .orderedAscending
            case .findings:
                if left.findingCount != right.findingCount { return left.findingCount > right.findingCount }
                return left.displayName.localizedCaseInsensitiveCompare(right.displayName) == .orderedAscending
            }
        }
    }

    /// Groups in a fixed, meaningful order — Apps, then Agents, then Daemons, then anything new.
    public static func group(
        _ services: [AppSnapshot.Service]
    ) -> [(name: String, rows: [AppSnapshot.Service])] {
        let preference = ["Apps", "Agents", "Daemons"]
        return Dictionary(grouping: services, by: \.group)
            .sorted { (preference.firstIndex(of: $0.key) ?? 99) < (preference.firstIndex(of: $1.key) ?? 99) }
            .map { (name: $0.key, rows: $0.value) }
    }

    /// The three steps in the order the pane applies them.
    public static func present(
        _ services: [AppSnapshot.Service], query: String, sort order: Sort
    ) -> [(name: String, rows: [AppSnapshot.Service])] {
        group(sort(filter(services, query: query), by: order))
    }
}
