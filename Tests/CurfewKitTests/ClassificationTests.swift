import Foundation
import Testing
@testable import CurfewKit

@Suite("Classification")
struct ClassificationTests {
    let classifier = Classifier()

    func detail(_ label: String, plist: String?, program: String? = "/bin/true") -> JobDetail {
        JobDetail(
            label: label, domain: .currentUser, state: .running,
            program: program, plistPath: plist
        )
    }

    @Test("the never-list wins over every other tier")
    func protectedWins() {
        let d = detail("com.apple.securityd", plist: "/System/Library/LaunchDaemons/com.apple.securityd.plist")
        #expect(classifier.classification(for: d).tier == .protectedTier)
    }

    @Test("system jobs are reported by their path, not by their name")
    func appleTiers() {
        let daemon = detail("com.apple.foo", plist: "/System/Library/LaunchDaemons/com.apple.foo.plist")
        #expect(classifier.classification(for: daemon).tier == .osCore)
        let agent = detail("com.apple.bar", plist: "/System/Library/LaunchAgents/com.apple.bar.plist")
        #expect(classifier.classification(for: agent).tier == .appleAgent)
    }

    @Test("third-party jobs are the product's surface")
    func thirdParty() {
        let d = detail("sh.brew.postgresql@18", plist: "/Users/x/Library/LaunchAgents/sh.brew.postgresql@18.plist")
        let c = classifier.classification(for: d)
        #expect(c.tier == .thirdParty)
        #expect(c.kind == .agent)
        #expect(c.vendor == "Homebrew")
        #expect(c.supervised == .launchd)
    }

    @Test("app-child labels are their own kind")
    func appChild() {
        let d = detail("application.com.apple.Notes.1152921500311894402", plist: nil)
        #expect(classifier.classification(for: d).kind == .appChild)
    }

    @Test("an unknown vendor stays nil rather than being guessed")
    func unknownVendor() {
        let d = detail("com.example.thing", plist: "/Library/LaunchDaemons/com.example.thing.plist")
        let c = classifier.classification(for: d)
        #expect(c.vendor == nil)
        #expect(c.kind == .daemon)
    }
}
