import Foundation
import Testing
@testable import CurfewKit

/// KI-049 — quarantining debris a removed app left behind. The judgement is the whole design: of six
/// dangling programs on this machine only one was litter, so the test that matters most is the one that
/// refuses the other five.
@Suite("Quarantine")
struct QuarantineTests {

    let home = "/Users/x"

    func exists(_ set: Set<String>) -> (String) -> Bool { { set.contains($0) } }

    // MARK: Eligibility

    @Test("a removed app's stale plist is eligible")
    func steamStyle() {
        // the shape measured on this machine: Application Support names the app, no bundle remains
        let verdict = QuarantineEligibility.judge(
            program: "\(home)/Library/Application Support/Steam/SteamApps/steamclean",
            plistPath: "\(home)/Library/LaunchAgents/com.valvesoftware.steamclean.plist",
            fileExists: exists(["\(home)/Library/LaunchAgents/com.valvesoftware.steamclean.plist"]),
            home: home)
        #expect(verdict == .eligible(owner: "Steam (no app bundle on this machine)"))
    }

    @Test("a live project's job is refused — its program is missing, but the app is not gone")
    func projectVenv() {
        // `~/Projects/codebuddy2openai/.venv/bin/python`: no .app and no Application Support, so the
        // owner cannot be established and Curfew does not guess.
        let verdict = QuarantineEligibility.judge(
            program: "\(home)/Projects/codebuddy2openai/.venv/bin/python",
            plistPath: "\(home)/Library/LaunchAgents/com.workbuddy.converter.plist",
            fileExists: exists(["\(home)/Library/LaunchAgents/com.workbuddy.converter.plist"]),
            home: home)
        if case .refuse(let why) = verdict {
            #expect(why.contains("names no app"))
        } else {
            Issue.record("expected a refusal, got \(verdict)")
        }
    }

    @Test("a platform path is never eligible")
    func systemPath() {
        let verdict = QuarantineEligibility.judge(
            program: "/System/Library/CoreServices/PosterBoard.app/Contents/MacOS/PosterBoard",
            plistPath: "/System/Library/LaunchAgents/com.apple.PosterBoard.plist",
            fileExists: exists([]), home: home)
        if case .refuse(let why) = verdict {
            #expect(why.contains("SIP"))
        } else {
            Issue.record("expected a refusal, got \(verdict)")
        }
    }

    @Test("an app still installed is refused, named")
    func appStillInstalled() {
        let bundle = "/Applications/Zoom.app"
        let verdict = QuarantineEligibility.judge(
            program: "\(bundle)/Contents/MacOS/zoom",
            plistPath: "\(home)/Library/LaunchAgents/us.zoom.updater.plist",
            fileExists: exists([bundle, "\(home)/Library/LaunchAgents/us.zoom.updater.plist"]),
            home: home)
        if case .refuse(let why) = verdict {
            #expect(why.contains("still installed"))
        } else {
            Issue.record("expected a refusal, got \(verdict)")
        }
    }

    @Test("a program that exists means no debris at all")
    func programAlive() {
        let verdict = QuarantineEligibility.judge(
            program: "/usr/bin/true", plistPath: "\(home)/x.plist",
            fileExists: { $0 == "/usr/bin/true" || $0 == "\(home)/x.plist" }, home: home)
        if case .refuse(let why) = verdict {
            #expect(why.contains("still installed"))
        } else {
            Issue.record("expected a refusal, got \(verdict)")
        }
    }

    @Test("path parsing: .app wins over a support folder")
    func pathParsing() {
        #expect(QuarantineEligibility.appBundle(in: "/Applications/Zoom.app/Contents/MacOS/zoom")
                == "/Applications/Zoom.app")
        #expect(QuarantineEligibility.supportFolderOwner(
            in: "\(home)/Library/Application Support/Steam/SteamApps/steamclean") == "Steam")
        #expect(QuarantineEligibility.appBundle(in: "/usr/bin/true") == nil)
    }

    // MARK: The move

    @Test("quarantine moves the plist, journals it, and resume puts it back")
    func moveAndRestore() throws {
        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent("curfew-quarantine-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        let plist = work.appendingPathComponent("com.example.gone.plist")
        try "<?xml version=\"1.0\"?><plist><dict/></plist>".write(to: plist, atomically: true, encoding: .utf8)
        let journalURL = work.appendingPathComponent("journal.jsonl")
        let journal = Journal(url: journalURL)
        let store = QuarantineStore(root: work.appendingPathComponent("quarantine"))

        let outcome = try store.quarantine(plistPath: plist.path, label: "com.example.gone", journal: journal)
        #expect(outcome.result == .executed(verified: true))
        #expect(!FileManager.default.fileExists(atPath: plist.path), "the original is gone from its place")
        #expect(journal.held().count == 1, "and it is held, so it can be undone")

        // the quarantined copy keeps the path shape
        let held = try #require(journal.held().first)
        let moved = try #require(held.argv?.first)
        #expect(FileManager.default.fileExists(atPath: moved[1]))

        // resume moves it back
        let outcomes = Executor(journal: journal).resume(
            context: ExecutionContext(domain: "gui/501"), catalog: Catalog(entries: [], bundles: [], files: []))
        #expect(outcomes.first?.result == .executed(verified: true))
        #expect(FileManager.default.fileExists(atPath: plist.path), "restored to where it was")
        #expect(journal.held().isEmpty)
    }
}
