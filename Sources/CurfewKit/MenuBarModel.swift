import Foundation

/// The menu bar's content, as data. Pure, so "quiet mode is visible from the menu bar" and "restore
/// is offered only when there is something to restore" are tests rather than screenshots.
///
/// **The menu bar never applies.** It shows state and offers restore — the direction that puts the
/// machine back (D23). Applying stays a deliberate CLI act with `--execute --yes`.
public enum MenuItemKind: Equatable, Sendable {
    case info
    case restore
    case dashboard
    case quit
}

public struct MenuItem: Equatable, Sendable {
    public var title: String
    public var enabled: Bool
    public var kind: MenuItemKind

    public init(title: String, enabled: Bool, kind: MenuItemKind) {
        self.title = title
        self.enabled = enabled
        self.kind = kind
    }
}

public struct MenuSection: Equatable, Sendable {
    public var title: String?
    public var items: [MenuItem]

    public init(title: String?, items: [MenuItem]) {
        self.title = title
        self.items = items
    }
}

public struct MenuBarModel: Equatable, Sendable {
    public var sections: [MenuSection]
    public var statusTitle: String

    public init(sections: [MenuSection], statusTitle: String) {
        self.sections = sections
        self.statusTitle = statusTitle
    }

    /// What the status item itself shows. Short: the menu bar is not a dashboard.
    public static func statusTitle(quiet: Bool, unresolved: Int) -> String {
        quiet ? "◐ \(unresolved)" : "○"
    }

    public static func build(
        quiet: Bool,
        unresolvedCount: Int,
        runningCount: Int,
        findingCount: Int,
        bundleCount: Int,
        version: String
    ) -> MenuBarModel {
        let state = quiet
            ? "Quiet mode is ON — \(unresolvedCount) unresolved"
            : "Quiet mode is off"

        var sections: [MenuSection] = [
            MenuSection(title: nil, items: [
                MenuItem(title: state, enabled: false, kind: .info),
                MenuItem(title: "\(runningCount) services running · \(findingCount) findings",
                         enabled: false, kind: .info),
            ]),
            MenuSection(title: nil, items: [
                MenuItem(
                    title: quiet ? "Restore everything…" : "Nothing to restore",
                    enabled: quiet,
                    kind: .restore
                ),
            ]),
            MenuSection(title: nil, items: [
                MenuItem(title: "Open dashboard…", enabled: true, kind: .dashboard),
                MenuItem(title: "\(bundleCount) bundles in the catalog", enabled: false, kind: .info),
            ]),
            MenuSection(title: nil, items: [
                MenuItem(title: "Curfew \(version)", enabled: false, kind: .info),
                MenuItem(title: "Quit", enabled: true, kind: .quit),
            ]),
        ]

        // A menu that offers an action it cannot perform is worse than one that says why.
        if quiet {
            sections[1].items[0].title = "Restore everything…"
        }

        return MenuBarModel(
            sections: sections,
            statusTitle: statusTitle(quiet: quiet, unresolved: unresolvedCount)
        )
    }

    /// Flat rendering, for `--dump-menu` and for tests.
    public func dump() -> String {
        var lines = ["[\(statusTitle)]"]
        for section in sections {
            if let title = section.title { lines.append("  \(title)") }
            for item in section.items {
                lines.append("  \(item.enabled ? "•" : "·") \(item.title)")
            }
        }
        return lines.joined(separator: "\n")
    }
}
