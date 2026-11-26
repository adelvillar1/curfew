import Foundation
import Testing
@testable import CurfewKit

/// D43: orphans are found by three narrow rules, and the fixtures prove each one is load-bearing.
@Suite("Orphan scan")
struct OrphanScanTests {

    /// pid ppid uid rss command
    static let ps = """
       24522     1  501   1200 tail -f /dev/null
       24523   900  501   1200 tail -f /dev/null
       24524     1  502   1200 tail -f /dev/null
       24525     1  501   1200 tail -f /dev/null --follow
       24526     1  501   3400 tail -f /var/log/system.log
       24527     1  501   2100 sleep 1000000
       """

    @Test("only the orphan of ours, with the exact command, is reported")
    func narrowRules() {
        let found = OrphanScan.parse(Self.ps, uid: 501)
        #expect(found.map(\.pid) == [24522])
        #expect(found.first?.rssKB == 1200)
        #expect(found.first?.command == "tail -f /dev/null")
    }

    @Test("a live parent is never reported")
    func liveParentSpared() {
        #expect(OrphanScan.parse(Self.ps, uid: 501).allSatisfy { $0.parentPID == 1 })
        #expect(!OrphanScan.parse(Self.ps, uid: 501).contains { $0.pid == 24523 })
    }

    @Test("another user's orphan is not ours to touch")
    func otherUserIgnored() {
        #expect(!OrphanScan.parse(Self.ps, uid: 501).contains { $0.pid == 24524 })
    }

    @Test("a near-match command is not a match")
    func nearMatchRefused() {
        let pids = OrphanScan.parse(Self.ps, uid: 501).map(\.pid)
        #expect(!pids.contains(24525), "--follow is a different command")
        #expect(!pids.contains(24526), "a different file is a different command")
        #expect(!pids.contains(24527), "sleep is not on the keep-alive list")
    }

    @Test("the summary names the count and the memory")
    func summaryNamesBoth() {
        let one = OrphanScan.parse(Self.ps, uid: 501)
        let text = OrphanScan.summary(one) ?? ""
        #expect(text.contains("1 orphaned keep-alive"))
        #expect(text.contains("1.2 MB"))
        #expect(OrphanScan.summary([]) == nil)
    }

    @Test("many orphans pluralise and add up")
    func plural() {
        let many = """
             1     1  501   1024 tail -f /dev/null
             2     1  501   1024 tail -f /dev/null
            """
        let found = OrphanScan.parse(many, uid: 501)
        #expect(found.count == 2)
        #expect(OrphanScan.totalRSSKB(found) == 2048)
        #expect((OrphanScan.summary(found) ?? "").contains("2 orphaned keep-alives"))
    }

    @Test("empty and malformed output yield nothing rather than crashing")
    func tolerant() {
        #expect(OrphanScan.parse("", uid: 501).isEmpty)
        #expect(OrphanScan.parse("garbage\n\n   \n", uid: 501).isEmpty)
    }
}
