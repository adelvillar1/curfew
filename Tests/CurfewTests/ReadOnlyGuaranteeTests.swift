import Foundation
import Testing
@testable import CurfewKit

/// L1.9 — the mechanical proof of hard rule 3 and D1.
///
/// Every command is run against a `PATH` whose `launchctl`, `kill`, `tmutil` and friends are
/// shims that record their invocation. If any command reaching for a mutating verb slips in,
/// the marker file appears and this suite fails.
@Suite("Read-only guarantee", .serialized)
struct ReadOnlyGuaranteeTests {

    static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    struct Shims {
        var directory: URL
        var marker: URL

        static func make() throws -> Shims {
            let base = FileManager.default.temporaryDirectory
                .appendingPathComponent("curfew-shims-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            let marker = base.appendingPathComponent("MUTATION")
            // A shim per verb that could change a service. `launchctl` is special: the tool is
            // allowed to call `print` and `print-disabled` only.
            let scripts: [(String, String)] = [
                ("launchctl", """
                #!/bin/sh
                case "$1" in
                  print|print-disabled) exec /bin/launchctl "$@" ;;
                  *) echo "$*" >> "\(marker.path)"; exit 0 ;;
                esac
                """),
                ("kill", "#!/bin/sh\necho \"$*\" >> \"\(marker.path)\"\n"),
                ("pkill", "#!/bin/sh\necho \"$*\" >> \"\(marker.path)\"\n"),
                ("tmutil", "#!/bin/sh\necho \"$*\" >> \"\(marker.path)\"\n"),
                ("mdutil", "#!/bin/sh\necho \"$*\" >> \"\(marker.path)\"\n"),
                ("brew", "#!/bin/sh\necho \"$*\" >> \"\(marker.path)\"\n"),
                ("kiri", "#!/bin/sh\necho \"$*\" >> \"\(marker.path)\"\n"),
                ("podman", "#!/bin/sh\necho \"$*\" >> \"\(marker.path)\"\n"),
                // read-only, and used by the listener scan: pass through untouched
                ("lsof", "#!/bin/sh\nexec /usr/sbin/lsof \"$@\"\n"),
            ]
            for (name, body) in scripts {
                let url = base.appendingPathComponent(name)
                try body.write(to: url, atomically: true, encoding: .utf8)
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            }
            return Shims(directory: base, marker: marker)
        }

        var path: String { directory.path }

        func mutations() -> [String] {
            (try? String(contentsOf: marker, encoding: .utf8))?
                .split(separator: "\n").map(String.init) ?? []
        }
    }

    @Test("a full inventory run never invokes a mutating launchctl verb")
    func inventoryIsReadOnly() throws {
        let shims = try Shims.make()
        defer { try? FileManager.default.removeItem(at: shims.directory) }

        let inventory = LaunchdInventory(runner: { arguments in
            let process = Process()
            process.environment = ["PATH": shims.path]
            process.executableURL = URL(fileURLWithPath: "\(shims.path)/launchctl")
            process.arguments = arguments
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            try? process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return CommandResult(
                standardOutput: String(decoding: data, as: UTF8.self),
                status: process.terminationStatus
            )
        })

        let result = inventory.records(in: .currentUser, findings: FindingsEngine())
        #expect(!result.records.isEmpty, "the inventory should have found jobs")
        #expect(shims.mutations().isEmpty, "read-only violated: \(shims.mutations())")
    }

    @Test("the listener scan is read-only too")
    func listenerScanIsReadOnly() throws {
        let shims = try Shims.make()
        defer { try? FileManager.default.removeItem(at: shims.directory) }

        let scanner = ListenerScanner(runner: { arguments in
            let process = Process()
            process.environment = ["PATH": shims.path]
            process.executableURL = URL(fileURLWithPath: "\(shims.path)/lsof")
            process.arguments = arguments
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            try? process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return CommandResult(standardOutput: String(decoding: data, as: UTF8.self))
        })

        _ = scanner.scan()
        #expect(shims.mutations().isEmpty, "read-only violated: \(shims.mutations())")
    }

    @Test("the shim itself records a mutation, so the test above can fail")
    func shimSanity() throws {
        let shims = try Shims.make()
        defer { try? FileManager.default.removeItem(at: shims.directory) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "\(shims.path)/kill")
        process.arguments = ["-TERM", "1"]
        try? process.run()
        process.waitUntilExit()
        #expect(shims.mutations() == ["-TERM 1"], "the shim must record what it was asked to do")
    }
}
