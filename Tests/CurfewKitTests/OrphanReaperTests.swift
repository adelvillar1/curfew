import Foundation
import Testing
@testable import CurfewKit

/// D46: the window may reap, so the refusal paths are the interesting ones.
@Suite("Orphan reaper")
struct OrphanReaperTests {

    static func orphan(_ pid: Int, ppid: Int = 1, uid: Int = 501,
                       command: String = "tail -f /dev/null", rss: Int = 1024) -> OrphanProcess {
        OrphanProcess(pid: pid, parentPID: ppid, uid: uid, rssKB: rss, command: command)
    }

    @Test("a matched orphan is signalled and counted")
    func reaps() {
        // The Result is the observable: only a delivered signal is counted as reaped.
        let reaper = OrphanReaper(isAlive: { _ in true }, signal: { _ in true })
        let result = reaper.reap([Self.orphan(10), Self.orphan(11)], uid: 501)
        #expect(result.reaped.map(\.pid) == [10, 11])
        #expect(result.freedKB == 2048)
        #expect(result.summary.contains("2 processes"))
    }

    @Test("a process whose parent is alive is refused even if the caller asks")
    func liveParentRefused() {
        // A signal that would always succeed: if the guard were missing, reaped would not be empty.
        let reaper = OrphanReaper(isAlive: { _ in true }, signal: { _ in true })
        let result = reaper.reap([Self.orphan(20, ppid: 900)], uid: 501)
        #expect(result.reaped.isEmpty)
        #expect(result.refused.first?.reason.contains("parent is alive") == true)
    }

    @Test("another user's process is refused")
    func otherUserRefused() {
        let reaper = OrphanReaper(isAlive: { _ in true }, signal: { _ in true })
        let result = reaper.reap([Self.orphan(30, uid: 502)], uid: 501)
        #expect(result.reaped.isEmpty)
        #expect(result.refused.first?.reason.contains("another user") == true)
    }

    @Test("a near-match command is refused")
    func nearMatchRefused() {
        let reaper = OrphanReaper(isAlive: { _ in true }, signal: { _ in true })
        let result = reaper.reap([Self.orphan(40, command: "tail -f /dev/null --follow")], uid: 501)
        #expect(result.reaped.isEmpty)
        #expect(result.refused.first?.reason.contains("known keep-alive") == true)
    }

    @Test("a process that is already gone is not counted as reaped")
    func alreadyGone() {
        let reaper = OrphanReaper(isAlive: { _ in false }, signal: { _ in true })
        let result = reaper.reap([Self.orphan(50)], uid: 501)
        #expect(result.reaped.isEmpty)
        #expect(result.refused.first?.reason == "already gone")
    }

    @Test("a refused signal is reported, not counted")
    func signalRefused() {
        let reaper = OrphanReaper(isAlive: { _ in true }, signal: { _ in false })
        let result = reaper.reap([Self.orphan(60)], uid: 501)
        #expect(result.reaped.isEmpty)
        #expect(result.summary.contains("refused"))
    }
}
