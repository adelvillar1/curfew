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
    /// A catalog bundle. Selecting it **previews** the run — it never passes `--execute`.
    case bundle(String)
    /// Bring up the app's window: the surface that shows state, the held list and the findings.
    case window
    /// Start quiet mode on the default bundle. The one action that can change a service: it runs the
    /// dry run first, shows the plan, and only applies when the operator confirms in that dialog.
    case startQuiet
}

/// What the menu needs to know about a bundle. `acting` is how many of its members would do something;
/// a bundle whose members are all refused is not offered.
public struct MenuBundle: Equatable, Sendable {
    public var name: String
    public var members: Int
    public var acting: Int

    public init(name: String, members: Int, acting: Int) {
        self.name = name
        self.members = members
        self.acting = acting
    }
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

    /// What "quiet mode with default settings" means. `vendor-noise` is the only stop bundle with
    /// acting members: thirteen verified vendor updaters, none of them needed by a build.
    public static let defaultQuietBundle = "vendor-noise"

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
        version: String,
        bundles: [MenuBundle] = [],
        protectedBundles: [String] = [],
        quietBundleAvailable: Bool = true
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
                // The one action that changes the machine's mode. When off it starts quiet mode (two
                // steps: dry run shown, then applied on confirmation); when on it restores.
                quiet
                    ? MenuItem(title: "Restore everything…", enabled: true, kind: .restore)
                    : MenuItem(title: "Start quiet mode…", enabled: quietBundleAvailable, kind: .startQuiet),
            ]),
            MenuSection(title: "Preview a stop", items: stopItems(
                bundles: bundles, quiet: quiet, bundleCount: bundleCount,
                protectedBundles: protectedBundles)),
            MenuSection(title: nil, items: [
                MenuItem(title: "Open Curfew…", enabled: true, kind: .window),
                MenuItem(title: "Open dashboard in Terminal…", enabled: true, kind: .dashboard),
            ]),
            MenuSection(title: nil, items: [
                MenuItem(title: "Curfew \(version)", enabled: false, kind: .info),
                MenuItem(title: "Quit", enabled: true, kind: .quit),
            ]),
        ]

        return MenuBarModel(
            sections: sections,
            statusTitle: statusTitle(quiet: quiet, unresolved: unresolvedCount)
        )
    }

    /// The stop bundles, as previewable rows, plus one line naming the protected sets. A `protect`
    /// bundle is never actioned by design, so it is not offered — but saying which they are keeps the
    /// count honest instead of appearing to lose them.
    static func stopItems(
        bundles: [MenuBundle], quiet: Bool, bundleCount: Int, protectedBundles: [String]
    ) -> [MenuItem] {
        var items: [MenuItem] = bundles.map { bundle in
            // Quiet mode is a held state: previewing a stop while things are stopped would report on
            // a machine that is already quiet.
            MenuItem(
                title: "\(bundle.name) · \(bundle.acting) of \(bundle.members) act",
                enabled: !quiet && bundle.acting > 0,
                kind: .bundle(bundle.name))
        }
        if !protectedBundles.isEmpty {
            items.append(MenuItem(
                title: "protected: \(protectedBundles.sorted().joined(separator: ", "))",
                enabled: false, kind: .info))
        }
        if items.isEmpty {
            items.append(MenuItem(title: "\(bundleCount) bundles in the catalog",
                                  enabled: false, kind: .info))
        }
        return items
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
