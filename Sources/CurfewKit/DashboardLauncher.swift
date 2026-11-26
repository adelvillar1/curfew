import Foundation

/// Opening the terminal dashboard from the menu bar (KI-042).
///
/// Two jobs the old one-liner skipped: **find** the CLI — `make install` puts it in `~/.local/bin`, not
/// `/usr/local/bin` — and **report** a failure instead of swallowing it with `try?`.
///
/// It lives here rather than in the app target so the resolution and the command shape are testable.
public enum DashboardLauncher {
    public struct Failure: Error, Equatable {
        public var message: String
        public init(message: String) { self.message = message }
    }

    /// Environment override first, then the install locations, then whatever is on `PATH`.
    public static func candidates(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileExists: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> [String] {
        var paths: [String] = []
        if let override = environment["CURFEW_CLI"], !override.isEmpty { paths.append(override) }
        let home = environment["HOME"] ?? FileManager.default.homeDirectoryForCurrentUser.path
        paths += [
            "\(home)/.local/bin/curfew",
            "/opt/homebrew/bin/curfew",
            "/usr/local/bin/curfew",
        ]
        for directory in (environment["PATH"] ?? "").split(separator: ":") where !directory.isEmpty {
            paths.append("\(directory)/curfew")
        }
        return paths
    }

    public static func resolve(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileExists: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> String? {
        candidates(environment: environment, fileExists: fileExists).first(where: fileExists)
    }

    /// The command Terminal runs. The subcommand comes **first**: `curfew --dir X` reads `X` as the
    /// command name and prints help instead of opening the dashboard.
    public static func command(cli: String, catalog: String?) -> String {
        guard let catalog, !catalog.isEmpty else { return "\(cli) tui" }
        return "\(cli) tui --dir \(catalog)"
    }

    /// The dry run for one bundle: `apply` without `--execute`. The menu shows its output; it never
    /// passes `--execute`, so selecting a bundle cannot change this machine.
    public static func previewCommand(cli: String, catalog: String?, bundle: String) -> String {
        var parts = [cli, "apply", "--bundle", bundle]
        if let catalog, !catalog.isEmpty { parts += ["--dir", catalog] }
        return parts.joined(separator: " ")
    }

    /// The dry run for the default bundle — what the confirmation dialog shows.
    public static func quietPreviewCommand(cli: String, catalog: String?, bundle: String) -> String {
        previewCommand(cli: cli, catalog: catalog, bundle: bundle)
    }

    /// The real thing. `--yes` is required because the menu is not a TTY: off a terminal the CLI
    /// refuses `--execute` without it, which is the safety it was built with and is kept here.
    public static func quietCommand(cli: String, catalog: String?, bundle: String) -> String {
        var parts = [cli, "apply", "--bundle", bundle, "--execute", "--yes"]
        if let catalog, !catalog.isEmpty { parts += ["--dir", catalog] }
        return parts.joined(separator: " ")
    }

    public static func missingMessage(
        candidates: [String] = DashboardLauncher.candidates()
    ) -> String {
        """
        The curfew command line tool is not installed, so there is no dashboard to open.

        Looked in:
        \(candidates.map { "  " + $0 }.joined(separator: "\n"))

        Install it with:  make install
        Or point at one:  CURFEW_CLI=/path/to/curfew open -a Curfew.app
        """
    }
}
