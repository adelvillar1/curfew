import Foundation

/// The never-list: services Curfew must never signal, never boot out, never disable (D9).
///
/// This is code, not configuration. A config file implies "power users may edit it", and that
/// is how a tool bricks a machine. The contents come verbatim from
/// `docs/research/core-os-services.md` §4, and `NeverListTests` re-reads that document and fails
/// if any label it lists is missing here — so the two cannot drift.
public enum NeverList {

    /// 28 launchd labels. Includes both the plist filename (`com.apple.dasd-OSX`) and the
    /// loaded label (`com.apple.dasd`), because they differ.
    public static let labels: [String] = [
        "com.apple.WindowServer",
        "com.apple.loginwindow",
        "com.apple.watchdogd",
        "com.apple.thermalmonitord",
        "com.apple.powerd",
        "com.apple.configd",
        "com.apple.securityd",
        "com.apple.opendirectoryd",
        "com.apple.runningboardd",
        "com.apple.dasd",
        "com.apple.dasd-OSX",
        "com.apple.logd",
        "com.apple.notifyd",
        "com.apple.distnoted.xpc.daemon",
        "com.apple.diskarbitrationd",
        "com.apple.fseventsd",
        "com.apple.syslogd",
        "com.apple.MobileFileIntegrity",
        "com.apple.tccd",
        "com.apple.sandboxd",
        "com.apple.trustd",
        "com.apple.nehelper",
        "com.apple.security.xprotectd",
        "com.apple.sysdiagnose",
        "com.apple.spindump",
        "com.openssh.sshd",
        "io.tailscale.ipn.macsys",
        "io.tailscale.ipn.macsys.login-item-helper",
    ]

    /// The second net: process names, for when a label is not the whole story. Names are
    /// weaker than labels (three processes here are called `postgres`), which is why this is a
    /// backstop and never the primary key.
    public static let processNames: [String] = [
        "launchd", "kernel_task", "WindowServer", "loginwindow", "watchdogd", "thermalmonitord",
        "powerd", "configd", "securityd", "opendirectoryd", "runningboardd", "dasd", "logd",
        "notifyd", "distnoted", "diskarbitrationd", "fseventsd", "syslogd", "amfid", "tccd",
        "sandboxd", "trustd", "nehelper", "xprotectd", "sysdiagnosed", "sshd",
    ]

    private static let labelSet = Set(labels)
    private static let nameSet = Set(processNames)

    /// Rule 7's other half — the tool's own ancestry — is enforced by walking parent pids at
    /// action time, not by name matching. This predicate covers the label half only.
    public static func isProtected(label: String) -> Bool {
        labelSet.contains(label)
    }

    public static func isProtected(processName: String) -> Bool {
        // `ps` truncates long names; compare the basename of a path too.
        let base = (processName as NSString).lastPathComponent
        return nameSet.contains(processName) || nameSet.contains(base)
    }

    public static func all() -> [String] { labels + processNames }
}
