import Foundation

/// The TUI's view model: pure state, no terminal, so every navigation and every rendered line is
/// testable. The terminal layer only draws what this decides.
public struct TUIRow: Equatable, Sendable {
    public var id: String
    public var state: String
    public var tier: String
    public var findings: Int
    public var selected: Bool
    public var inBundle: Bool
}

public struct TUIState: Equatable, Sendable {
    public var title: String
    public var quietMode: Bool
    public var rows: [TUIRow]
    public var cursor: Int
    public var bundles: [String]
    public var bundleIndex: Int
    public var message: String?
    /// Rows deliberately not shown: protected jobs and app-bound GUI instances.
    public var hidden: Int

    public init(
        title: String,
        quietMode: Bool = false,
        rows: [TUIRow] = [],
        cursor: Int = 0,
        bundles: [String] = [],
        bundleIndex: Int = 0,
        message: String? = nil,
        hidden: Int = 0
    ) {
        self.title = title
        self.quietMode = quietMode
        self.rows = rows
        self.cursor = cursor
        self.bundles = bundles
        self.bundleIndex = bundleIndex
        self.message = message
        self.hidden = hidden
    }

    public var currentBundle: String? {
        guard !bundles.isEmpty, bundles.indices.contains(bundleIndex) else { return nil }
        return bundles[bundleIndex]
    }

    public var selectedCount: Int { rows.filter(\.selected).count }

    /// The rows in this bundle, in bundle order — what `a` would preview.
    public var bundlePreview: [TUIRow] { rows.filter(\.inBundle) }

    // MARK: Navigation

    public mutating func move(by delta: Int) {
        guard !rows.isEmpty else { cursor = 0; return }
        cursor = min(max(0, cursor + delta), rows.count - 1)
    }

    public mutating func toggle() {
        guard rows.indices.contains(cursor) else { return }
        rows[cursor].selected.toggle()
    }

    public mutating func nextBundle() {
        guard !bundles.isEmpty else { return }
        bundleIndex = (bundleIndex + 1) % bundles.count
        message = nil
    }

    public mutating func markBundleMembers(_ members: Set<String>) {
        for index in rows.indices {
            rows[index].inBundle = members.contains(rows[index].id)
        }
    }
}

/// Keys, parsed from raw terminal bytes. Separate from the loop so the mapping is testable.
public enum TUIKey: Equatable, Sendable {
    case up, down, toggle, nextBundle, preview, refresh, help, quit, unknown(String)
}

public enum TUIKeys {
    /// Arrow keys arrive as `ESC [ A` / `ESC [ B`, which is why this is a parser and not a switch on
    /// one character.
    public static func parse(_ bytes: [UInt8]) -> TUIKey? {
        guard let first = bytes.first else { return nil }
        switch first {
        case 0x1B: // escape sequence
            guard bytes.count >= 3, bytes[1] == 0x5B else { return .quit }
            switch bytes[2] {
            case 0x41: return .up
            case 0x42: return .down
            default: return .unknown(String(decoding: bytes, as: UTF8.self))
            }
        case 0x6B, 0x4B: return .up          // k
        case 0x6A, 0x4A: return .down        // j
        case 0x20: return .toggle            // space
        case 0x62, 0x42: return .nextBundle  // b
        case 0x61, 0x41: return .preview     // a (dry run only)
        case 0x72, 0x52: return .refresh     // r
        case 0x3F: return .help              // ?
        case 0x71, 0x51: return .quit        // q
        default: return .unknown(String(decoding: [first], as: UTF8.self))
        }
    }
}

/// State → text. Every decision about what the screen says lives here, which is what makes "the
/// quiet-mode banner is always visible" a test rather than a hope.
public enum TUIRenderer {

    public static func render(_ state: TUIState, width: Int = 100, height: Int = 24) -> String {
        let inner = max(40, width)
        var lines: [String] = []

        // Header: the quiet-mode state is always present, on every screen.
        let quiet = state.quietMode ? "QUIET MODE: ON  (unresolved journal intents)" : "quiet mode: off"
        lines.append(pad(fit(state.title, inner - quiet.count - 1), inner - quiet.count) + quiet)
        lines.append(String(repeating: "─", count: inner))

        lines.append("  SERVICES" + pad("", 8) + "FINDINGS")
        let budget = max(4, height - 9)
        let window = visibleWindow(state, budget: budget)
        for (offset, row) in window.enumerated() {
            let index = windowStart(state, budget: budget) + offset
            let pointer = index == state.cursor ? "▸" : " "
            let mark = row.selected ? "[x]" : (row.inBundle ? "[·]" : "[ ]")
            let line = "\(pointer) \(mark) \(pad(fit(row.id, 46), 46)) \(fit(row.state, 12))  \(row.findings > 0 ? "\(row.findings) finding(s)" : "")"
            lines.append(fit(line, inner))
        }
        if state.rows.count > budget {
            lines.append(fit("  … \(state.rows.count - budget) more", inner))
        }

        lines.append(String(repeating: "─", count: inner))
        let bundle = state.currentBundle.map { "\($0)" } ?? "(no bundles)"
        lines.append(fit("bundle: \(bundle)   selected: \(state.selectedCount)   in bundle: \(state.bundlePreview.count)   hidden: \(state.hidden) (protected + app-bound)", inner))
        if let message = state.message {
            lines.append(fit(message, inner))
        }
        lines.append(String(repeating: "─", count: inner))
        lines.append(fit("j/k move · space select · b next bundle · a preview (dry run) · r refresh · q quit", inner))
        lines.append(fit("read-only: this screen previews; only `curfew apply --execute` changes anything", inner))

        return lines.joined(separator: "\n")
    }

    static func windowStart(_ state: TUIState, budget: Int) -> Int {
        guard state.rows.count > budget else { return 0 }
        let half = budget / 2
        return min(max(0, state.cursor - half), state.rows.count - budget)
    }

    static func visibleWindow(_ state: TUIState, budget: Int) -> ArraySlice<TUIRow> {
        let start = windowStart(state, budget: budget)
        return state.rows[start..<min(state.rows.count, start + budget)]
    }

    static func pad(_ text: String, _ width: Int) -> String {
        text.count >= width ? text : text + String(repeating: " ", count: width - text.count)
    }

    /// Truncate to the terminal width without splitting a grapheme.
    static func fit(_ text: String, _ width: Int) -> String {
        guard text.count > width else { return text }
        return String(text.prefix(max(0, width - 1))) + "…"
    }
}

// MARK: - Building the state from real data

public enum TUIBuilder {

    /// Compose the screen from what the machine says. `bundles` come from the catalog so the picker
    /// matches what `apply` would accept.
    public static func state(
        records: [ServiceRecord],
        catalog: Catalog,
        quietMode: Bool,
        title: String,
        selectedBundle: String? = nil
    ) -> TUIState {
        let bundleNames = catalog.bundles.map(\.name)
        let index = selectedBundle.flatMap { bundleNames.firstIndex(of: $0) } ?? 0

        // App-bound entries are running GUI instances, not services anyone manages (D0); a
        // protected-tier job can never be actioned, so it stays out of the picker too. Both are
        // counted so the screen does not pretend they do not exist.
        let rows = records
            .filter { $0.tier == .thirdParty && $0.kind != .appChild }
            .sorted { ($0.tier.rawValue, $0.id) < ($1.tier.rawValue, $1.id) }
            .map { record in
                TUIRow(
                    id: record.id,
                    state: record.state.rawValue,
                    tier: record.tier.rawValue,
                    findings: record.findings.count,
                    selected: false,
                    inBundle: false
                )
            }

        var state = TUIState(
            title: title,
            quietMode: quietMode,
            rows: rows,
            bundles: bundleNames,
            bundleIndex: min(index, max(0, bundleNames.count - 1)),
            hidden: records.filter { $0.tier == .protectedTier || $0.kind == .appChild }.count
        )
        if let bundle = state.currentBundle, let definition = catalog.bundle(bundle) {
            state.markBundleMembers(Set(definition.members))
        }
        return state
    }
}
