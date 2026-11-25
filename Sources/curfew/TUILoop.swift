import Foundation
import Darwin
import CurfewKit

/// The terminal loop: raw mode, read a key, redraw. All the decisions live in `TUIState` and
/// `TUIRenderer`; this file only moves bytes.
enum TUILoop {

    static func run() -> Never {
        var state = buildState()
        var original = termios()

        // Raw mode: no echo, no line buffering, so a keypress lands immediately.
        if tcgetattr(STDIN_FILENO, &original) == 0 {
            var raw = original
            raw.c_lflag &= ~tcflag_t(ECHO | ICANON | ISIG)
            raw.c_cc.16 = 1  // VMIN
            raw.c_cc.17 = 0  // VTIME
            tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw)
        }
        defer {
            tcsetattr(STDIN_FILENO, TCSAFLUSH, &original)
            print("\u{1B}[?25h", terminator: "")   // restore the cursor
        }

        print("\u{1B}[?25l", terminator: "")       // hide the cursor
        redraw(state)

        var buffer = [UInt8](repeating: 0, count: 8)
        while true {
            let count = read(STDIN_FILENO, &buffer, buffer.count)
            guard count > 0 else { break }
            let key = TUIKeys.parse(Array(buffer[0..<count]))
            switch key {
            case .quit:
                print("\u{1B}[2J\u{1B}[H", terminator: "")
                exit(ExitCode.clean.rawValue)
            case .up: state.move(by: -1)
            case .down: state.move(by: 1)
            case .toggle: state.toggle()
            case .nextBundle:
                state.nextBundle()
                if let bundle = state.currentBundle, let definition = catalogBundle(bundle) {
                    state.markBundleMembers(Set(definition.members))
                }
            case .preview:
                state.message = previewMessage(state)
            case .refresh:
                state = buildState(selectedBundle: state.currentBundle)
                state.message = "refreshed"
            case .help:
                state.message = "space toggles a selection · b cycles bundles · a previews the bundle · q quits"
            case .unknown, nil:
                break
            }
            redraw(state)
        }
        exit(ExitCode.clean.rawValue)
    }

    private static func buildState(selectedBundle: String? = nil) -> TUIState {
        let records = LaunchdInventory().records(in: Domain.effective(), findings: FindingsEngine()).records
        let catalog = catalog()
        return TUIBuilder.state(
            records: records, catalog: catalog,
            quietMode: !Journal().unresolved().isEmpty,
            title: "curfew \(curfewVersion) · \(Domain.effective().target)",
            selectedBundle: selectedBundle
        )
    }

    private static func catalog() -> Catalog {
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("catalog", isDirectory: true)
        return (try? CatalogLoader.load(directory: directory))
            ?? Catalog(entries: [], bundles: [], files: [])
    }

    private static func catalogBundle(_ name: String) -> CatalogBundle? {
        catalog().bundle(name)
    }

    private static func previewMessage(_ state: TUIState) -> String {
        let members = state.bundlePreview
        guard !members.isEmpty else { return "this bundle has no members in the list" }
        let fresh = members.filter { !$0.selected }.count
        return "\(state.currentBundle ?? "?"): \(members.count) member(s) — `curfew catalog plan --bundle \(state.currentBundle ?? "")` shows the argv"
            + (fresh > 0 ? "" : "")
    }

    private static func redraw(_ state: TUIState) {
        var width = 100
        var size = winsize()
        if ioctl(STDOUT_FILENO, TIOCGWINSZ, &size) == 0, size.ws_col > 0 { width = Int(size.ws_col) }
        print("\u{1B}[2J\u{1B}[H", terminator: "")   // clear + home
        print(TUIRenderer.render(state, width: width, height: 30), terminator: "")
        fflush(stdout)
    }
}
