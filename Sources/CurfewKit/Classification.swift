import Foundation

/// Turns a raw job into tier, kind, vendor and supervision (atom L1.3).
///
/// Tier assignment follows D0: the never-list wins over everything, Apple's own jobs are
/// reported by path, and everything else is the product's surface.
public struct Classifier: Sendable {

    public init() {}

    public func classification(for detail: JobDetail) -> (tier: Tier, kind: Kind, vendor: String?, supervised: Supervision) {
        let tier = self.tier(for: detail)
        let kind = self.kind(for: detail)
        return (tier, kind, vendor(for: detail.label), .launchd)
    }

    func tier(for detail: JobDetail) -> Tier {
        if NeverList.isProtected(label: detail.label) { return .protectedTier }
        let path = detail.plistPath ?? ""
        if path.contains("/System/Library/LaunchDaemons") { return .osCore }
        if path.contains("/System/Library/LaunchAgents") { return .appleAgent }
        if detail.label.hasPrefix("com.apple.") { return .appleAgent }
        return .thirdParty
    }

    func kind(for detail: JobDetail) -> Kind {
        if detail.label.hasPrefix("application.") { return .appChild }
        let path = detail.plistPath ?? ""
        if path.contains("/LaunchAgents/") { return .agent }
        if path.contains("/LaunchDaemons/") { return .daemon }
        return .daemon
    }

    /// A small, explicit prefix map. The label is data, so an unknown vendor stays `nil`
    /// rather than being guessed from a domain fragment.
    func vendor(for label: String) -> String? {
        let table: [(String, String)] = [
            ("com.google.", "Google"),
            ("com.microsoft.", "Microsoft"),
            ("us.zoom.", "Zoom"),
            ("com.valvesoftware.", "Valve"),
            ("com.docker.", "Docker"),
            ("com.github.containers.podman", "Podman"),
            ("ai.perplexity.", "Perplexity"),
            ("com.openai.", "OpenAI"),
            ("sh.brew.", "Homebrew"),
            ("homebrew.mxcl.", "Homebrew"),
            ("dev.kiri.", "Kiri"),
            ("com.adelvillar1.", "local"),
            ("com.alejandrodelvillar.", "local"),
            ("com.workbuddy.", "WorkBuddy"),
            ("com.agnostic-router.", "agnostic-router-kit"),
            ("com.zcode.", "zcode-router-kit"),
        ]
        for (prefix, name) in table where label.hasPrefix(prefix) {
            return name
        }
        return nil
    }
}
