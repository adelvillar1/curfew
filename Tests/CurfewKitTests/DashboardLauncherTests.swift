import Foundation
import Testing
@testable import CurfewKit

/// KI-042 — the "Open dashboard…" menu item did nothing. The launcher is now testable: it must find a
/// CLI that `make install` actually produces, and build a command the CLI actually accepts.
@Suite("Dashboard launcher")
struct DashboardLauncherTests {

    let env = ["HOME": "/Users/x", "PATH": "/usr/bin:/bin"]

    @Test("the install location make install uses is found first")
    func findsLocalBin() {
        let cli = DashboardLauncher.resolve(environment: env, fileExists: { $0 == "/Users/x/.local/bin/curfew" })
        #expect(cli == "/Users/x/.local/bin/curfew")
    }

    @Test("CURFEW_CLI overrides everything")
    func environmentOverride() {
        let cli = DashboardLauncher.resolve(
            environment: ["HOME": "/Users/x", "PATH": "/usr/bin", "CURFEW_CLI": "/tmp/curfew"],
            fileExists: { $0 == "/tmp/curfew" || $0 == "/Users/x/.local/bin/curfew" })
        #expect(cli == "/tmp/curfew")
    }

    @Test("a CLI on PATH is found even outside the known locations")
    func fallsBackToPath() {
        let cli = DashboardLauncher.resolve(
            environment: ["HOME": "/Users/x", "PATH": "/opt/tools/bin"], fileExists: { $0 == "/opt/tools/bin/curfew" })
        #expect(cli == "/opt/tools/bin/curfew")
    }

    @Test("no CLI anywhere resolves to nil, and the message names every place tried")
    func missingCLI() {
        #expect(DashboardLauncher.resolve(environment: env, fileExists: { _ in false }) == nil)
        let message = DashboardLauncher.missingMessage(
            candidates: DashboardLauncher.candidates(environment: env, fileExists: { _ in false }))
        #expect(message.contains("/Users/x/.local/bin/curfew"))
        #expect(message.contains("make install"))
    }

    // MARK: The command shape

    @Test("the subcommand comes first — `--dir` ahead of it is read as the command name")
    func commandShape() {
        let line = DashboardLauncher.command(cli: "/usr/bin/curfew", catalog: "/bundle/catalog")
        #expect(line == "/usr/bin/curfew tui --dir /bundle/catalog")
        #expect(!line.hasPrefix("/usr/bin/curfew --dir"), "the CLI would print help instead of the dashboard")
    }

    @Test("with no catalogue the dashboard still opens, without a dangling flag")
    func noCatalog() {
        #expect(DashboardLauncher.command(cli: "/usr/bin/curfew", catalog: nil) == "/usr/bin/curfew tui")
        #expect(DashboardLauncher.command(cli: "/usr/bin/curfew", catalog: "") == "/usr/bin/curfew tui")
    }
}
