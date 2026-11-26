import Foundation

/// The app speaks English; the journal and launchd speak identifiers.
///
/// Every row used to print the raw values — `disable`, `spawnScheduled`, `danglingProgram`,
/// `fieldUnavailable` — five internals at one weight in an eleven-point line. The critique put this at
/// the top of the P1s: this is the recognition surface, and parsing is not recognition. The raw
/// identifier still exists, in the Investigate sheet, where detail belongs.
public enum Vocabulary {

    /// The verb Curfew performed, in the past tense a person would use.
    public static func action(_ raw: String) -> String {
        switch raw {
        case "disable": return "disabled"
        case "stop", "bootout": return "stopped"
        case "freeze": return "frozen"
        case "quarantine": return "moved to quarantine"
        case "resume": return "restored"
        case "command": return "stopped"
        default: return raw.replacingOccurrences(of: "-", with: " ")
        }
    }

    /// What launchd is doing, said plainly.
    public static func jobState(_ raw: String) -> String {
        switch raw {
        case "running": return "running"
        case "notLoaded": return "not loaded"
        case "notRunning": return "not running"
        case "spawnScheduled": return "waiting to start"
        case "loaded": return "loaded"
        case "waiting": return "waiting"
        case "stopped": return "stopped"
        case "unknown": return ""
        default: return raw
        }
    }

    /// What a finding is about, in the fewest words that stay true.
    public static func findingKind(_ raw: String) -> String {
        switch raw {
        case "danglingProgram": return "program missing"
        case "execFailure": return "program will not run"
        case "crashLoop": return "restart loop"
        case "respawnRate": return "restarting repeatedly"
        case "fieldUnavailable": return "could not read its config"
        case "stalePlist": return "plist is gone"
        case "orphanPort": return "port with no job"
        case "disabledButExpected": return "disabled, but expected to run"
        case "noSupervisor": return "no launchd job"
        case "runsFromTmpOrRoot": return "started from a temporary path"
        default: return raw
        }
    }

    /// A short phrase for a held change: "disabled by Curfew", "frozen".
    public static func heldPhrase(_ action: String) -> String {
        switch action {
        case "freeze": return "frozen by Curfew"
        case "quarantine": return "moved to quarantine"
        default: return Vocabulary.action(action) + " by Curfew"
        }
    }

    /// A launchd label said as a name a person recognises (plan C0).
    ///
    /// GUI apps register as `application.<bundle-id>.<pid>.<pid>`; agents as reverse-DNS. The raw label stays
    /// on the row's detail line and in JSON — this only decides what the eye reads first.
    public static func displayName(for label: String) -> String {
        var text = label
        if text.hasPrefix("application.") { text.removeFirst("application.".count) }

        // Trailing components that are numbers or UUIDs are identities, not names.
        var parts = text.split(separator: ".").map(String.init)
        while let last = parts.last {
            let isNumber = last.allSatisfy(\.isNumber)
            let isUUID = last.count >= 16 && last.filter { $0.isHexDigit || $0 == "-" }.count == last.count
            guard isNumber || isUUID else { break }
            parts.removeLast()
        }
        guard !parts.isEmpty else { return label }

        if let first = parts.first, tlds.contains(first.lowercased()) { parts.removeFirst() }
        // Apple's own bundle ids read better without the vendor.
        if let first = parts.first, first.lowercased() == "apple" { parts.removeFirst() }
        parts.removeAll { platformWords.contains($0.lowercased()) }
        guard !parts.isEmpty else { return label }

        func spoken(_ component: String) -> String {
            let spaced = component.replacingOccurrences(of: "-", with: " ")
                .replacingOccurrences(of: "_", with: " ")
            // Break camelCase and acronym runs: "ActivityMonitor" → "Activity Monitor", "IPN" stays.
            var out = ""
            var previous: Character?
            for character in spaced {
                if let previous, character.isUppercase, previous.isLowercase || previous.isNumber {
                    out.append(" ")
                }
                out.append(character)
                previous = character
            }
            return out.split(separator: " ")
                .map { word in
                    let w = String(word)
                    if acronyms.contains(w.lowercased()) { return w.uppercased() }
                    guard let first = w.first else { return w }
                    return first.isLowercase ? first.uppercased() + w.dropFirst() : w
                }
                .joined(separator: " ")
        }

        // A capitalised first component is the product name; the parts after it are sub-identifiers
        // (`com.apple.AddressBook.abd` → "Address Book", not "Address Book Abd").
        if parts.count > 1, let first = parts.first, first.first?.isUppercase == true {
            return spoken(first)
        }
        let full = parts.map(spoken).joined(separator: " ")
        // A long reverse-DNS name is more noise than identity: prefer its most specific component.
        if full.count > 28 { return spoken(parts.last ?? label) }
        return full.isEmpty ? label : full
    }

    /// Where a service comes from, said plainly.
    public static func tier(_ raw: String) -> String {
        switch raw {
        case "appleAgent": return "Apple agent"
        case "appleDaemon": return "Apple daemon"
        case "thirdParty": return "Third party"
        case "system": return "System"
        default: return raw
        }
    }

    /// What kind of thing a service is, as a group heading.
    public static func serviceGroup(_ raw: String) -> String {
        switch raw {
        case "agent": return "Agents"
        case "daemon": return "Daemons"
        case "app": return "Apps"
        default: return raw.prefix(1).uppercased() + raw.dropFirst()
        }
    }

    static let tlds: Set<String> = ["com", "io", "org", "net", "dev", "co", "app", "me", "ai", "sh", "us", "uk"]
    static let platformWords: Set<String> = ["macos", "osx", "mac", "desktop", "client", "app"]
    /// Short words that are acronyms, not words: "Ipn" is not how anyone writes it.
    static let acronyms: Set<String> = ["ipn", "api", "cli", "ui", "mcp", "pg", "db", "os", "ai", "dsh", "ssh"]
}
