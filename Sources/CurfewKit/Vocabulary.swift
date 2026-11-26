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
}
