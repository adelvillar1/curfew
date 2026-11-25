import Foundation
import Testing
@testable import CurfewKit

/// The completeness test the plan's acceptance criteria demand: the compiled never-list must
/// contain every label the research document lists. If the document and the code drift, this
/// fails — which is the only thing standing between "28 labels" and "27 labels and a hole".
@Suite("NeverList")
struct NeverListTests {

    static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // CurfewKitTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo root
    }

    @Test("compiled list has the documented shape")
    func counts() {
        #expect(NeverList.labels.count >= 28)
        #expect(NeverList.processNames.count >= 26)
        #expect(Set(NeverList.labels).count == NeverList.labels.count, "duplicate label")
        #expect(Set(NeverList.processNames).count == NeverList.processNames.count, "duplicate process name")
    }

    @Test("every label the research document lists is compiled in")
    func completenessAgainstResearch() throws {
        let url = Self.repoRoot.appendingPathComponent("docs/research/core-os-services.md")
        let doc = try String(contentsOf: url, encoding: .utf8)
        guard let start = doc.range(of: "## 4. Never list"),
              let end = doc.range(of: "## 5.", range: start.upperBound..<doc.endIndex)
        else {
            Issue.record("could not find §4 of core-os-services.md")
            return
        }
        let section = String(doc[start.upperBound..<end.lowerBound])

        // The ledger's unit is the first column of each row. Later columns name Mach services
        // and file paths (`com.apple.unblock`, `CLAUDE.local.md`) that are not never-list units.
        var tokens: [String] = []
        for line in section.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("|"), trimmed.hasPrefix("| ") else { continue }
            let fields = trimmed.split(separator: "|", omittingEmptySubsequences: false)
            guard fields.count >= 3, Int(fields[1].trimmingCharacters(in: .whitespaces)) != nil else { continue }
            tokens.append(contentsOf: Self.backtickedTokens(in: String(fields[2])))
        }
        // The prose "process-name net" is part of §4 too.
        if let netStart = section.range(of: "Process-name net"),
           let netEnd = section.range(of: "\n---", range: netStart.upperBound..<section.endIndex) {
            tokens.append(contentsOf: Self.backtickedTokens(in: String(section[netStart.upperBound..<netEnd.lowerBound])))
        }

        var checked = 0
        for token in tokens {
            if token.hasPrefix("com.") || token.hasPrefix("io.") || token.hasPrefix("dev.") {
                #expect(NeverList.isProtected(label: token), "label \(token) from the research doc is not in NeverList")
                checked += 1
            } else if !token.contains("."), !token.contains(" "), token.count > 2,
                      token.rangeOfCharacter(from: .uppercaseLetters) == nil {
                #expect(
                    NeverList.isProtected(processName: token),
                    "process name \(token) from the research doc is not in NeverList"
                )
                checked += 1
            }
        }
        #expect(checked >= 20, "expected to check at least 20 tokens, checked \(checked)")
        #expect(tokens.contains("com.apple.unblock") == false, "Mach service names must not leak into the label check")
    }

    @Test("the tier-1 labels that matter most are present")
    func spotChecks() {
        for label in ["com.apple.securityd", "com.apple.opendirectoryd", "com.apple.fseventsd",
                      "com.apple.WindowServer", "com.apple.loginwindow", "com.openssh.sshd"] {
            #expect(NeverList.isProtected(label: label), "\(label) must be protected")
        }
        #expect(NeverList.isProtected(processName: "sshd"))
        #expect(NeverList.isProtected(processName: "/usr/sbin/sshd"), "basename must match too")
    }

    @Test("ordinary third-party labels are not protected")
    func falsePositives() {
        #expect(!NeverList.isProtected(label: "com.google.keystone.agent"))
        #expect(!NeverList.isProtected(label: "sh.brew.postgresql@18"))
        #expect(!NeverList.isProtected(processName: "postgres"))
    }

    static func backtickedTokens(in text: String) -> [String] {
        var out: [String] = []
        var scanner = Substring(text)[...]
        while let open = scanner.firstIndex(of: "`") {
            let after = scanner.index(after: open)
            guard let close = scanner[after...].firstIndex(of: "`") else { break }
            let token = String(scanner[after..<close]).trimmingCharacters(in: .whitespaces)
            if !token.isEmpty { out.append(token) }
            scanner = scanner[scanner.index(after: close)...]
        }
        return out
    }
}
