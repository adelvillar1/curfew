import Foundation
import Testing
@testable import CurfewKit

@Suite("DisagreementLog")
struct DisagreementLogTests {

    /// A mutable clock for the injected `now` closure.
    final class Clock: @unchecked Sendable {
        var now = Date(timeIntervalSince1970: 1_000_000)
        func advance(_ seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }
    }

    func tempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("curfew-log-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func event(
        _ kind: DisagreementKind = .execPathConflict,
        label: String = "com.example.job",
        port: UInt16? = nil
    ) -> DisagreementEvent {
        DisagreementEvent(
            kind: kind,
            target: DisagreementTarget(label: label, pid: 42, port: port),
            launchd: LaunchdEvidence(program: "/usr/bin/a", state: "running", runs: 1, lastExit: nil),
            witr: WitrEvidence(exe: "/opt/a", sourceType: "launchd", pid: 42),
            verdict: Verdict(state: "running", enrichment: "ok"),
            note: "program vs exe"
        )
    }

    @Test("writes one JSONL line per event group")
    func writes() throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = DisagreementLog(options: .init(directory: dir), macos: "26.5.2", witrVersion: "0.3.4")

        #expect(log.record(event()))
        let text = try String(contentsOf: log.fileURL, encoding: .utf8)
        let lines = text.split(separator: "\n")
        #expect(lines.count == 1)

        let decoded = try JSONDecoder().decode(DisagreementRecord.self, from: Data(lines[0].utf8))
        #expect(decoded.kind == .execPathConflict)
        #expect(decoded.witrVersion == "0.3.4")
        #expect(decoded.macos == "26.5.2")
        #expect(decoded.fingerprint.hasPrefix("sha1:"))
    }

    @Test("the same disagreement inside the window is suppressed and counted, not re-written")
    func rateLimit() throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let clock = Clock()
        let log = DisagreementLog(
            options: .init(directory: dir),
            now: { clock.now },
            macos: "26.5.2"
        )

        #expect(log.record(event()) == true)
        for _ in 0..<99 {
            #expect(log.record(event()) == false)
            clock.advance(1)
        }
        let firstPass = try String(contentsOf: log.fileURL, encoding: .utf8)
        #expect(firstPass.split(separator: "\n").count == 1, "100 identical events must not write 100 lines")

        // past the window: one more line, carrying the suppressed count
        clock.advance(1_000)
        #expect(log.record(event()) == true)
        let lines = try String(contentsOf: log.fileURL, encoding: .utf8).split(separator: "\n")
        #expect(lines.count == 2)
        let second = try JSONDecoder().decode(DisagreementRecord.self, from: Data(lines[1].utf8))
        #expect(second.suppressed == 99)
    }

    @Test("different fingerprints are not suppressed against each other")
    func distinctFingerprints() throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = DisagreementLog(options: .init(directory: dir), macos: "26.5.2")
        #expect(log.record(event(label: "a")))
        #expect(log.record(event(label: "b")))
        #expect(log.record(event(.identityConflict, label: "a")))
        #expect(log.summarize().count == 3)
    }

    @Test("rotates and keeps exactly three files")
    func rotation() throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = DisagreementLog(
            options: .init(directory: dir, rateLimit: 0, maxBytes: 400, keepFiles: 3),
            macos: "26.5.2"
        )
        for index in 0..<40 {
            log.record(event(label: "com.example.job\(index)"))
        }
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasPrefix("disagreements.jsonl") }
        #expect(files.count == 4, "the live file plus three rotations, got \(files.sorted())")
        #expect(files.contains("disagreements.jsonl.3"))
        #expect(!files.contains("disagreements.jsonl.4"), "rotation must not grow without bound")
    }

    @Test("no field can carry argv or an environment value")
    func noArgvNoEnv() throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = DisagreementLog(options: .init(directory: dir), macos: "26.5.2", witrVersion: "0.3.4")
        log.record(event())
        let text = try String(contentsOf: log.fileURL, encoding: .utf8).lowercased()
        #expect(!text.contains("\"argv\""))
        #expect(!text.contains("\"env\""))
        #expect(!text.contains("\"cmdline\""))
        #expect(!text.contains("--api-key"))
    }

    @Test("summarize groups by fingerprint with first and last seen")
    func summarize() throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let clock = Clock()
        let log = DisagreementLog(options: .init(directory: dir, rateLimit: 0), now: { clock.now }, macos: "26.5.2")
        log.record(event(label: "a"))
        clock.advance(60)
        log.record(event(label: "a"))
        let counts = log.summarize()
        #expect(counts.count == 1)
        #expect(counts.first?.count == 2)
        #expect(counts.first?.firstSeen != counts.first?.lastSeen)
    }
}
