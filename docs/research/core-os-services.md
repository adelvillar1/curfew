# Core OS Services — Safety Boundary for "Unattended Development" Mode

**Machine:** macOS 26.5.2 (25F84), arm64, 16 GiB, uptime 33 days. Measured 2026-11-24. Read-only: no
service was booted out, disabled, killed, or signalled. Anything settlable only by mutating is marked
**UNVERIFIED** with a safe test in §5.

**How measured.** `ls …/*.plist | wc -l` → 422 daemons, 465 agents, 11 `/Library` daemons, 7
`/Library` agents. All 887 system plists converted via `plutil -convert json` and parsed with python3.
`launchctl print system` → `service count 438, active service count 154`; `launchctl print gui/501` →
476 service lines, 52 non-Apple; `launchctl print <domain>/<label>` → `pid`/`state` for liveness. `ps`
is sandbox-blocked (`bash: /bin/ps: Operation not permitted`), so liveness came from `launchctl` and
PID 1 identity from `creator = launchd[1]`.

**Drift vs. the brief, reconciled 2026-11-24.** `active count` now reads **956** (brief: 957). For
gui/501, the two counts in play are a *filter* difference, not a population difference: the tightened
row pattern `^\s+[0-9]+\s+[0-9-]+\s+\S+` against the `services = {` table gives **282 rows = 230
`com.apple.*` + 17 `application.*` + 35 other**, while a looser line pattern sweeps sub-blocks of the
same output and yields 476 / 52. **282 / 230 / 17 / 35 is the number to quote**, because it names its
filter; the 476 figure is retired. `docs/STATE-SNAPSHOT.md` has been corrected to match. Any count
this project publishes must state the grep that produced it.

---

## 1. Tier table

**Legend — safe to suspend?** `never` = do not signal, boot out, or disable. `freeze-only` = SIGSTOP
is the only survivable lever (keeps state and the Mach port; bootout destroys clients), and it is **out
of scope** because it holds a `MachServices` key — documented so the exclusion is evidence-based, not
accidental. `stop-with-care` = bootout/disable works and the job self-heals on demand, but something
visible degrades. `safe` = on-demand, no user-visible loss, relaunches on next demand; **the only class
a first release may act on**.

> **Rule 4 reconciliation.** `CLAUDE.md` rule 4 forbids freezing any job with a listening socket,
> on-disk database, or `MachServices` key, "a frozen server hangs its clients instead of failing them."
> R6 is the mechanism: the port stays registered, so callers block forever with no error and no
> timeout. Every `freeze-only` row is therefore **not** a candidate — the loudest services on this box
> (`mds`, `mds.index`, `corespotlightd`, `corespeechd`, `sharingd`, `biomed`, `trustd`,
> `nsurlsessiond`, `rapportd`) are day-one out of scope for exactly this reason.

> **Not every quiet target has a signal-based recipe.** The loudest background costs on this box are
> Spotlight indexing and Time Machine, and **neither should be addressed with a signal or a bootout**:
> `mdutil -a -i off` (root, reversible with `-i on`) is the sanctioned way to quiesce indexing, and
> `tmutil stopbackup` / `disable` is the sanctioned way to quiesce backups. Both binaries exist here
> (`/usr/bin/mdutil`, `/usr/bin/tmutil`). This is the catalog thesis in one line: the correct lever for
> a service is the one its vendor designed, not the one launchd happens to expose. A catalog entry may
> therefore be *neither* freeze nor stop.

### Tier 0 — kernel / init: loss = panic or unbootable
| Label | What it does | Safe? | Consequence |
|---|---|---|---|
| `launchd` (PID 1) | PID 1; owns every domain, reaps, respawns | never | Signalling it or booting out `system` = panic / dead box |
| `kernel_task` (PID 0) | XNU's own task; memory/IO pressure relief | never | Not a launchd job; freezing stops all kernel threads |
| `com.apple.watchdogd` | Userspace watchdog; `ExitTimeOut 15`, `KeepAlive{SuccessfulExit:false}` | never | Loses `com.apple.unblock` escalation path |
| `com.apple.thermalmonitord` | SMC/thermal sensors → thermal pressure; `EnablePressuredExit false` | never | Thermal management goes blind; panic-adjacent on Apple silicon |

### Tier 1 — core system: loss = broken login/GUI/disk/security
| Label | What it does | Safe? | Consequence |
|---|---|---|---|
| `com.apple.WindowServer` | Compositor + graphics conclave (`CARenderServer`, CoreDisplay, iohideventsystem) | never | Every window freezes; GUI unrecoverable without logout |
| `com.apple.loginwindow` | Owns gui/501 (`creator = loginwindow[414]`) | never | Tearing it down kills the user domain — including the tool |
| `com.apple.configd` | Network configuration | never | VPN/DHCP/route changes stall |
| `com.apple.securityd` | Keychain | never | All TLS and password reads block |
| `com.apple.opendirectoryd` | Identity/directory lookups (`KeepAlive true`) | never | login, sudo, group resolution hang; new processes cannot resolve users |
| `com.apple.runningboardd` | Process lifecycle / assertion broker | never | No app launches |
| `com.apple.dasd` (plist `com.apple.dasd-OSX`) | DuetActivityScheduler, `KeepAlive true`, `PublishesEvents com.apple.bg.system.task` | never | It is the scheduler every Tier-2 job calls — suspend its clients, never it |
| `com.apple.logd` | Unified logging collector | never | Every `os_log` write blocks |
| `com.apple.notifyd` | `notify(3)` hub | never | Every notify waiter stalls |
| `com.apple.distnoted.xpc.daemon` | Distributed notifications (`@0v3`/`@1v3`), `KeepAlive true` | never | UI state desyncs silently |
| `com.apple.powerd` | Sleep/battery; `JetsamPriority -100` | never | Sleep/wake and low-power handling break; the -100 is the strongest protection signal in the corpus |
| `com.apple.diskarbitrationd` | Mount/eject/attach | never | New volumes never mount |
| `com.apple.fseventsd` | Filesystem events | never | Build tools and editors stop noticing changes |
| `com.apple.syslogd` | BSD syslog socket | never | Legacy writers block on a full socket |
| `com.apple.MobileFileIntegrity` | Hosts `amfid` (`com.apple.amfi.xpc`, `RunAtLoad true`) | never | Code-signature validation stops; nothing new launches |
| `com.apple.tccd` | Privacy consent (camera/mic/screen/FDA) | never | Privacy-gated calls block or deny |
| `com.apple.trustd` | Certificate trust (`com.apple.trustd`) | never (§4) | TLS validation stalls — hangs, not fails |
| `com.apple.sandboxd` | Sandbox profile enforcement | never | Sandboxed processes cannot start |
| `com.apple.nehelper` | Network Extension helper | never | VPN/firewall/filter providers cannot attach |
| `com.apple.nsurlsessiond` | Background HTTP broker for all agents (`QueueDirectories ~/Library/com.apple.nsurlsessiond`) | freeze-only | Every background transfer stalls at once |
| `com.apple.security.xprotectd` | XProtect scanning (`KeepAlive true`, `EnablePressuredExit false`, 0 Mach services) | never | Malware enforcement stops, for zero idle-cost upside |
| `com.apple.sysdiagnose` / `com.apple.spindump` | On-demand diagnostic capture / stack sampling | never (§4) | Only breaks diagnostics, and it is the lifeline when a quiet mode misbehaves |

### Tier 2 — Apple background agents: the real quiet-mode targets
| Label | What it does | Safe? | Consequence |
|---|---|---|---|
| `com.apple.metadata.mds` | Spotlight coordinator; `RunAtLoad/KeepAlive true`, `ProcessType Interactive`, 4 ports | freeze-only | Spotlight queries hang (clients block on its port) |
| `com.apple.metadata.mds.index` (`mds_stores`) | Content indexer; `LowPriorityBackgroundIO true`, 2 ports | freeze-only | Results go stale; biggest background disk-IO source |
| `com.apple.corespotlightd` | App/Settings index (`JetsamPriority -49`, limit 4000, 5 ports) | freeze-only | App-launch and Settings search degrade/hang |
| `com.apple.searchtoold` | Spotlight tooling (`-49`, limit 4000) | safe | No visible loss; relaunches on demand |
| `com.apple.mediaanalysisd` | Photo/video ML: faces, scenes, OCR; `RunAtLoad false`, `Adaptive`, 10 ports | safe | No new tagging; heaviest ANE/GPU consumer among agents |
| `com.apple.photoanalysisd` | Photo graph: people, memories, curation; `Interactive` | safe | Memories stop updating; no data loss |
| `com.apple.bird` | iCloud Drive sync, 5 ports | stop-with-care | Sync stops; local edits queue and reconcile later |
| `com.apple.cloudd` | CloudKit daemon | stop-with-care | App data stops syncing; apps retry-loop on a dead port |
| `com.apple.assistantd` | Siri backend, **30 ports**, `Adaptive` | stop-with-care | Siri/dictation/Shortcuts actions fail |
| `com.apple.siriinferenced` | On-device Siri inference (Biome-subscribed), 4 ports | stop-with-care | Suggestions degrade; broad Biome fan-out |
| `com.apple.corespeechd` | Speech recognition (`RunAtLoad/KeepAlive true`, 15 ports) | freeze-only | "Hey Siri"/dictation hang; 15 ports make bootout destructive |
| `com.apple.sirittsd` | Siri TTS, `Adaptive` | safe | Voice replies fail until next demand |
| `com.apple.SiriTTSTrainingAgent` | Trains on-device TTS voices | safe | Training never progresses; zero idle cost |
| `com.apple.chronod` | Widget timeline (`KeepAlive{Crashed:true}`, `Aqua`, 6 ports) | safe | Widgets freeze at last render |
| `com.apple.routined` | Location/behaviour learning (`RunAtLoad true`, 6 ports) | safe | Location suggestions stop |
| `com.apple.duetexpertd` | App prediction, **25 ports**, `Adaptive` | stop-with-care | Suggestions/Handoff hints go stale |
| `com.apple.knowledgeconstructiond` | IntelligencePlatform knowledge graph, `Adaptive` | safe | Graph stops growing; nothing interactive blocks |
| `com.apple.biomed` | Biome event store, 3 ports | freeze-only | Stalls most Tier-2 *publishers*; wide hidden fan-out |
| `com.apple.backgroundtaskmanagementd` / `.agent` | Login/background-item registry (`RunAtLoad false`) | safe | Login Items pane may hang while frozen |
| `com.apple.softwareupdated` | Software Update (no KeepAlive; notifyd-triggered; 3 ports) | stop-with-care | Updates stop progressing; fine for a session, not weeks |
| `com.apple.mobileassetd` | Asset downloads (`KeepAlive{PathState}` on `/System/Library/PreinstalledAssets`) | stop-with-care | Asset updates stop; see the PathState hazard in R5 |
| `com.apple.modelmanagerd` | Apple Intelligence model host (`Adaptive`, user `_modelmanagerd`) | safe | On-device model requests fail until demand |
| `com.apple.mlruntimed` | ML runtime host (`RunAtLoad false`) | safe | ML features fall back |
| `com.apple.parsecd` | Safari/Spotlight web suggestions (`LaunchEvents com.apple.nsurlsessiond-events`) | safe | Address-bar suggestions slower/empty |
| `com.apple.appstorecomponentsd` | App Store UI data (`RunAtLoad false`) | safe | Product pages load slower |
| `com.apple.GameController.gamecontrolleragentd` | Per-user controller agent (daemon sibling stays) | safe | Controller overlays stop |
| `com.apple.mediacontinuityd` | Continuity media handoff | safe | Handoff between devices stops |
| `com.apple.rapportd` | Proximity/Handoff/AirDrop discovery (`--system`, 11 ports) | freeze-only | That discovery dies; 11 ports put it out of scope |
| `com.apple.sharingd` | AirDrop/sharing (`RunAtLoad/KeepAlive true`, 14 ports) | freeze-only | Sharing sheets hang |

**Labels in the brief that do not exist on this machine** (`ls | grep -i` verified): `mds`,
`mds_stores`, `XProtect`, `continuityd`, `wifiProxyd`, `autorecovery`; plus three wrong spellings —
`dasd` → `com.apple.dasd-OSX`, `backgroundtaskmanagementagent` →
`com.apple.backgroundtaskmanagement.agent`, `gamecontrollerd` →
`com.apple.GameController.gamecontrollerd`. A tool hardcoding the brief's names silently no-ops on 9
targets.

### Tier 3 — third-party
11 daemons in `/Library/LaunchDaemons` (podman helper; Google updater + keystone; 4× Microsoft
OneDrive/Office/Defender; Zoom) and 7 agents in `/Library/LaunchAgents` (keystone ×2, Microsoft ×3,
Zoom ×2), plus 52 non-Apple gui/501 entries. **stop-with-care**, per label never per class: a dropped
Microsoft licensing helper can deactivate Office, a dropped updater only delays updates.

---

## 2. Rules of reachability

**R1 — SIP protects files, not domains. VERIFIED.** `/` is `apfs, sealed, local, read-only` (`mount`);
`csrutil authenticated-root status` → `enabled`; system plists carry the `restricted` flag
(`-rw-r--r-- root wheel restricted,compressed …/com.apple.metadata.mds.plist`, dirs `restricted`);
`test -w` on `/System/Library/LaunchDaemons` and `/Library/LaunchDaemons` → **not-writable** as uid 501.
You cannot add, edit, or delete a system plist.

**R2 — Why `gui/501/com.apple.X` is manageable and `system/com.apple.X` is not. VERIFIED (doc),
mechanism UNVERIFIED.** `man launchctl` (lines 25-27): *"The system domain manages the root Mach
bootstrap and is considered a privileged execution context. Anyone may read or query the system
domain, but root privileges are required to make modifications."* uid 501 is in `admin`/`_developer`
but is **not root** (`id`), so `bootout system/…` returns *Operation not permitted* before SIP is even
consulted. For the gui half the plist's location is irrelevant: `/System/Library/LaunchAgents/*.plist`
are bootstrapped into the per-user login domain, so the job is the user's. Proof they live there:
`launchctl print gui/501` lists live PIDs for `chronod` (711), `assistantd` (60766),
`siriinferenced` (939), while `launchctl print system/com.apple.chronod` does not resolve. Ownership of
the domain — not the path — is what makes the bootout legal; SIP protects the file you never touch.

**R3 — Root vs admin vs neither. VERIFIED.** *needs root*: any `system/…` mutation (`bootout`,
`disable`, `enable`, `kickstart`) — and `man launchctl` says `enable|disable` "may only target services
within the system domain or user and user-login domains", making system-domain disable root by
construction. *needs admin*: nothing in the launchctl path — `admin` membership does not grant the
system domain, it only enables `sudo`. *needs neither*: all `gui/501`/`user/501` mutations, and every
read (`print`, `print-disabled`, `plutil`, `csrutil`).

**R4 — What `disable` persists. VERIFIED for the file, UNVERIFIED for survival.** `man launchctl`:
*"Once a service is disabled, it cannot be loaded in the specified domain until it is once again
enabled. This state persists across boots of the device."* A legacy-`-w` note adds that the state
*"is stored elsewhere on-disk in a location that may not be directly manipulated by any process other
than launchd"* — that location, read directly:
`/var/db/com.apple.xpc.launchd/disabled.plist` (system, 838 B) and `disabled.501.plist` (gui/501,
1703 B), both `root:wheel`, `label => bool`. Reboot survival is documented; **survival across OS
updates is UNVERIFIED** — never let the db be the tool's only record.

**R5 — KeepAlive vs SIGSTOP. UNVERIFIED (no signalling permitted).** `man launchd.plist` (165-175)
defines KeepAlive entirely in terms of the job *exiting* ("kept continuously running", "jobs that exit
quickly and frequently … will be throttled"). Restart is exit-driven, not liveness-sampled, so a
SIGSTOPped process — same pid, still holding its ports, no exit event — should not be respawned. The
man page never says so. Practical rule: after a freeze, re-read the pid instead of assuming. Note the
inverse trap: `KeepAlive{PathState}` jobs (e.g. `mobileassetd` on `/System/Library/PreinstalledAssets`)
restart when a *path* appears, so an unrelated file event can resurrect a job you believed frozen.

**R6 — Why a frozen `MachServices` job hangs clients instead of failing them. UNVERIFIED (documented
mechanism, untested).** 733/887 plists register at least one name. `man launchd.plist` (463): the port
is registered "with the Mach bootstrap namespace", and `ResetAtClose` defaults false so "clients …
remain oblivious to the demand nature of the job". A frozen server keeps its receive right, so
`bootstrap_look_up` succeeds and `mach_msg` queues into a dead-but-registered port: the client blocks
in an interruptible wait, no error, no timeout. **Freeze ⇒ hangs; bootout ⇒ failures**
(`MACH_SEND_INVALID_DEST` / on-demand relaunch). This is the mechanism behind hard rule 4.

**R7 — The yield keys. VERIFIED by prevalence.** `EnablePressuredExit true` 556/887 — the job already
told launchd the kernel may pressure it out; the best citizens. `ProcessType` 394 declared: Adaptive
216, Interactive 93, App 40, Background 33, Standard 12 — `man launchd.plist` (414-424) says
`Background` limits are "intended to prevent them from disrupting the user experience"; Interactive is
a red flag (`mds`, `corespeechd`, `dasd`, `xprotectd` are all Interactive). `LowPriorityBackgroundIO
true` only 5/887 (`mds.index`, `mds.index.readonly`, `mdworker.sizing`, `SubmitDiagInfo`, `warmd`) —
it marks I/O the OS already treats as discretionary. `JetsamProperties` 8/887, negative = important:
`powerd -100`; `corespotlightd`/`searchtoold`/`coreimportd`/`timed`/`tzlinkd` `-49` with limits
2500-5000. **Treat any negative-JetsamPriority job as Tier 1** however cosmetic it looks.

**R8 — Size off services, not "active count". VERIFIED.** `launchctl print system` reports
`service count 438` / `active service count 154` while `active count 956` includes non-service objects.
And 346/887 carry `LaunchEvents` (event-driven), so a booted-out job relaunches the moment its
notify/Biome/IOKit trigger fires.

---

## 3. Measured inventory

**Counts.** 422 + 465 = 887 system plists; 438 system services (154 active); gui/501 **282 service
rows** = 230 `com.apple.*` + 17 `application.*` + 35 other; `/Library` 11 + 7 third-party; 32 plists
ship `Disabled true`; 179 declare `LimitLoadToSessionType`.
**Prevalence across 887:** `MachServices` 733 · `EnablePressuredExit` 556 · `ProcessType` 394 ·
`LaunchEvents` 346 · `KeepAlive` dict 89 · `RunAtLoad true` 79 · `KeepAlive true` 44 · `Disabled true`
32 · `JetsamProperties` 8 · `LowPriorityBackgroundIO` 5.

**Liveness at snapshot** (`launchctl print <domain>/<label>`) — the running set is the cost ranking:
`metadata.mds` 361 · `mediaanalysisd` 42923 · `photoanalysisd` 42918 · `biomed` 7021 · `dasd` 384 ·
`duetexpertd` 22457 · `routined` 22484 · `bird` 34313 · `cloudd` 12198 · `assistantd` 60766 ·
`corespeechd` 842 · `siriinferenced` 939 · `chronod` 711 · `corespotlightd` 714 · `nsurlsessiond` 634 ·
`parsecd` 60779 · `appstorecomponentsd` 67181 · `sharingd` 662 · `softwareupdated` 22908 ·
`mobileassetd` 33139 · `modelmanagerd` 533 · `trustd` 19261 · `xprotectd` 372. Not running:
`metadata.mds.index`, `sirittsd`, `SiriTTSTrainingAgent`, `knowledgeconstructiond`,
`GameController.gamecontrolleragentd`, `mediacontinuityd`, `mlruntimed`, `rapportd`, `spindump`,
`sysdiagnose`, `backgroundtaskmanagement.agent`.

**Representative plist values** (`plutil -p`, all from `/System/Library/LaunchDaemons|LaunchAgents`):

| Label | Keys that decide the tier |
|---|---|
| `metadata.mds` | `RunAtLoad true`, `KeepAlive true`, `ProcessType Interactive`, `LowPriorityBackgroundIO false`, 4 ports, `…/Metadata.framework/…/Support/mds` → Interactive + KeepAlive = freeze-only |
| `metadata.mds.index` | `ProcessType Interactive`, `LowPriorityBackgroundIO true`, `…/Support/mds_stores`, no RunAtLoad → the single best freeze target if freezes were allowed |
| `mediaanalysisd` | `RunAtLoad false`, `Adaptive`, `EnablePressuredExit/Transactions true`, 10 ports (`…analysis`, `…computeservice`) → event-driven and pre-yielding = safe |
| `photoanalysisd` | `ProcessType Interactive`, `EnablePressuredExit true`, 1 port, `…/PhotoAnalysis.framework/…/photoanalysisd` |
| `corespeechd` | `RunAtLoad true`, `KeepAlive true`, `Interactive`, **15 ports** → freeze-only |
| `assistantd` | `Adaptive`, `EnablePressuredExit true`, **30 ports**, daily `bg.system.task` events with `RequiresExternalPower true` → much of its work only runs plugged in |
| `chronod` | `RunAtLoad false`, `KeepAlive{Crashed:true}`, `LimitLoadToSessionType [Aqua]`, `ThrottleInterval 3`, 6 ports → freeze not respawned, crash is |
| `bird` | `Disabled false`, `DrainMessagesOnFailedInit true`, `EnablePressuredExit true`, 5 ports |
| `powerd` | `KeepAlive true`, `JetsamPriority -100`, `…/powerd.bundle/powerd` → never |
| `security.xprotectd` | `RunAtLoad/KeepAlive true`, `EnablePressuredExit false`, `Interactive`, **0 ports** → never; no idle cost, no upside |
| `softwareupdated` | no `KeepAlive`; `LaunchEvents com.apple.notifyd.matching{CheckForCatalogChange}`; 3 ports → pure on-demand |
| `mobileassetd` | `KeepAlive{PathState{/System/Library/PreinstalledAssets:true}}`, `EnablePressuredExit true`, 6 ports → the R5 PathState hazard |
| `modelmanagerd` | `UserName _modelmanagerd`, `Adaptive`, `EnablePressuredExit {#IfFeatureFlagEnabled ModelManager/idle_exit}`, `ThrottleInterval 1` → note feature-flag-conditional keys |
| `WindowServer` | **no `RunAtLoad`**, `_Conclave com.apple.backboardd.conclave`, ports `windowserver`, `CARenderServer`, `CoreDisplay.master` (`HideUntilCheckIn`), `iohideventsystem` (`ResetAtClose`) → never |
| `watchdogd` | `EnablePressuredExit false`, `ExitTimeOut 15`, `KeepAlive{SuccessfulExit:false}`, ports `com.apple.unblock`, `…optin.registration` |
| `thermalmonitord` | `KeepAlive{SuccessfulExit:false}`, `EnablePressuredExit/Transactions false`, weekly `Maintenance` event (604800 s) |
| `dasd-OSX` | `Label com.apple.dasd`, `RunAtLoad/KeepAlive true`, `Interactive`, `PublishesEvents com.apple.bg.system.task` → the scheduler itself |
| `MobileFileIntegrity` | hosts `amfid` via `com.apple.amfi.xpc`/`.lockdown`/`.nsxpc`, `RunAtLoad true`, fsevents trigger on `…CodeRequirementPrefsChanged` → there is no `com.apple.amfid` plist |
| `distnoted.xpc.daemon` | `KeepAlive true`, ports `com.apple.distributed_notifications@0v3/@1v3`, session gated by flag `UserManagement/SystemSessionD1` → there is no `com.apple.distnoted` plist |

---

## 4. Never list (hardcode as untouchable)

| # | Label / process | Reason |
|---|---|---|
| 1 | `launchd` (PID 1) | It performs the suspending; signalling it is a panic |
| 2 | `kernel_task` (PID 0) | Kernel's own task; freezing hangs the machine |
| 3 | `com.apple.WindowServer` | Compositor + graphics conclave; dead GUI |
| 4 | `com.apple.loginwindow` | Owns gui/501; booting it out kills the tool's own domain |
| 5 | `com.apple.watchdogd` | Watchdog / `com.apple.unblock` path |
| 6 | `com.apple.thermalmonitord` | Thermal safety |
| 7 | `com.apple.powerd` | `JetsamPriority -100`; sleep/battery |
| 8 | `com.apple.configd` | Networking state changes |
| 9 | `com.apple.securityd` | Keychain → all TLS/password reads |
| 10 | `com.apple.opendirectoryd` | Identity resolution for every new process |
| 11 | `com.apple.runningboardd` | No app can launch |
| 12 | `com.apple.dasd` | The background-task scheduler itself |
| 13 | `com.apple.logd` | Unified logging sink |
| 14 | `com.apple.notifyd` | notify(3) hub |
| 15 | `com.apple.distnoted.xpc.daemon` | Distributed-notification hub |
| 16 | `com.apple.diskarbitrationd` | Mount/eject |
| 17 | `com.apple.fseventsd` | File-change events build tools watch |
| 18 | `com.apple.syslogd` | Syslog socket |
| 19 | `com.apple.MobileFileIntegrity` (`amfid`) | Code-signature validation |
| 20 | `com.apple.tccd` | Privacy consent |
| 21 | `com.apple.sandboxd` | Sandbox enforcement |
| 22 | `com.apple.trustd` | Cert trust; freeze hangs all TLS |
| 23 | `com.apple.nehelper` | Network Extension attach |
| 24 | `com.apple.security.xprotectd` | Malware defence, no idle cost |
| 25 | `com.apple.sysdiagnose` | Diagnostic lifeline when quiet mode misbehaves |
| 26 | `sshd` / `com.openssh.sshd` | Remote access; locks a human out |
| 27 | `io.tailscale.ipn.macsys` (+ `.login-item-helper`) | Remote path to this box (`CLAUDE.local.md`); cuts DSH Fleet :8443/:8444 |
| 28 | Curfew's own process ancestry | Rule 7: walk the parent chain, never match own app/terminal by name |

Process-name net (second check): `launchd`, `kernel_task`, `WindowServer`, `loginwindow`, `watchdogd`,
`thermalmonitord`, `powerd`, `configd`, `securityd`, `opendirectoryd`, `runningboardd`, `dasd`, `logd`,
`notifyd`, `distnoted`, `diskarbitrationd`, `fseventsd`, `syslogd`, `amfid`, `tccd`, `sandboxd`,
`trustd`, `nehelper`, `xprotectd`, `sysdiagnosed`, `sshd`.

---

## 5. UNVERIFIED and the safe test for each

1. **`bootout gui/501/com.apple.<agent>` succeeds for Apple agents.** Test: `launchctl bootout
   gui/501/com.apple.parsecd`; expect exit 0, `print` → "Could not find service"; restore with
   `launchctl bootstrap gui/501 /System/Library/LaunchAgents/com.apple.parsecd.plist`.
2. **`bootout system/…` fails as uid 501.** Test as the user (not root) and capture the literal error.
3. **launchd does not respawn a SIGSTOPped KeepAlive job** (R5). Test: `kill -STOP <pid>` on a
   non-user-facing label, wait 30 s, compare `launchctl print <domain>/<label> | grep pid`, then
   `kill -CONT`. Never on Tier 0/1.
4. **A frozen MachServices server blocks clients** (R6). Test: freeze `com.apple.parsecd`, type in
   Safari's address bar, `sample <client pid>` and look for `mach_msg2_trap`; `kill -CONT` after.
5. **`disable` survives an OS update** (R4). Test: disable a Tier-3 label
   (`launchctl disable gui/501/us.zoom.updater`), re-read `disabled.501.plist` after the next macOS
   upgrade, and only then trust the db as durable state.
6. **Freezing `biomed` stalls the Biome-fed fleet.** Test: freeze it, watch whether
   `duetexpertd`/`routined`/`siriinferenced` stop receiving events, `kill -CONT` after 60 s.
7. **Real per-job CPU/wakeup cost.** Not measurable read-only here (`/bin/ps` blocked). A human should
   run `sudo powermetrics --samplers tasks -i 5s -n 12` or `ps -Ao pid,pcpu,comm | sort -k2 -rn | head`
   to rank targets by measured cost rather than liveness.
8. ~~**Whether gui/501 is 35 or 52 non-Apple services.**~~ **RESOLVED 2026-11-24**: 35 under the
   tightened filter (282 rows = 230 `com.apple.*` + 17 `application.*` + 35 other). The 52 counted
   `application.*` GUI instances. Curfew's scope decision: `application.*` is **out** — freezing a
   running GUI app is a user-facing action, not a quiet-mode one.
