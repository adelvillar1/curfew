# dev-mode — feasibility assessment

**Verdict: yes, it is possible, and it is more possible than you probably expect — but not in the form you described.** The mechanism works, the OS gives you a legitimate path, and there is no shipping product that does this. The design needs two corrections, both of which change what the app is.

Assessed against this Mac on 2026-11-24 (macOS 26.5.2, arm64, 16 GB, SIP enabled, 33 days uptime).

---

## 1. What is actually running here

Measured, not estimated:

| Thing | Count |
|---|---|
| Loaded services in your user (`gui/501`) domain | **281** |
| …of those, Apple / app-bound | 246 |
| …of those, third-party | **35** (17 running, 18 loaded-but-idle) |
| `/Library/LaunchAgents` (system-wide, per-user) | 7 — all vendor |
| `/Library/LaunchDaemons` (system-wide, root) | 11 — all vendor |
| `~/Library/LaunchAgents` | 30 — your dev stack |
| Apple jobs shipped on disk | 465 agents + 422 daemons |
| Listening TCP sockets | 40+ (postgres×2, kiri :443/:80, ollama, gvproxy, 3× gitea-runner, tailscale, cliproxy, kanzo, 2× python) |
| Swap in use | **5.4 GB of 7.1 GB** |
| Compressor (compressed RAM) | **~4.2 GB** (271,818 × 16 KB pages) |
| Free RAM | 45% (mostly reclaimable *inactive*) |
| Swapins / swapouts since boot | 217 M / 234 M pages |

The striking number is the classification, not the total: **roughly 30 of your 35 third-party user-domain services are vendor updaters, sync agents, and app launchers** — Google Keystone (×2), Microsoft AutoUpdate + OneDrive (×5) + Office licensing (×2) + Teams + Defender tracer, Zoom (×3), Steam clean, Docker helper, podman helper, four Sparkle-style `*.ShipIt` updaters, Perplexity, OpenAI chat helper. Not one of them is needed to compile a project or run an agent overnight.

Your actual dev stack is a much smaller set: two Postgres instances plus a third on :5439, `mlx_lm.server` (KeepAlive), cliproxyapi, three gitea runners, kanzo, Kiri daemon, Ollama, watchman, three model routers, `dev.dsh.bridge`, fleet GUI, `second-brain-pg`/`-tower`, `sem1-llama`, `blend1-service`. That set is what "dev mode" actually has to *protect*.

So the real product is not "suspend everything that isn't macOS." It is: **suspend the third-party layer, and be smart enough to keep the 10 things your build needs.** That is a much smaller, much safer, much more tractable problem — and it is the thing nobody has built.

---

## 2. Correction 1: "suspend" and "reclaim" are different levers

This is the design fork that decides everything. There are four levers, and they buy different things:

| Lever | Command | CPU / energy | RAM | Resume | Risk |
|---|---|---|---|---|---|
| **Freeze** | `kill -STOP` (or `launchctl kill SIGSTOP`) | → 0 | **retained** | instant, `SIGCONT` | held locks, hung clients, stale sockets |
| **Stop** | `launchctl bootout gui/501/<label>` | → 0 | **freed** | re-bootstrap, cold start | lost in-memory state, corruption if mid-write |
| **Prevent relaunch** | `launchctl disable gui/501/<label>` | — | — | `enable` | persists across reboots |
| **Throttle** | `taskpolicy -b -p <pid>`, `renice` | reduced | retained | nothing to undo | none — fully reversible |

I proved the freeze primitive on this machine:

```
running: 3 ticks / after SIGSTOP: before=3 after_4s=3 frozen=YES
after SIGCONT: now=6 resumed=YES
```

Zero CPU while frozen, memory still resident, resume is a single signal. That is what every "quiet mode" utility on the market actually does, and it is the *wrong* lever for your stated pain: at 5.4 GB of swap on a 16 GB machine, you don't need processes to stop burning CPU — you need their memory back. **Freezing Postgres reclaims nothing.** Stopping it reclaims hundreds of MB, plus the shared memory segment, plus its page cache pressure.

So "unattended development mode" really needs both, picked per-service: freeze the apps you want to come back instantly, *stop* the daemons whose memory you want, throttle the ones that are too dangerous to touch.

Also: `SIGSTOP` on anything holding a socket is a trap. Clients don't get "connection refused," they get a hang, and most clients have no timeout. Freeze Postgres and every `psql` and every app connection blocks forever rather than failing cleanly. Freeze an on-demand XPC service (`MachServices` key in its plist) and the calling app hangs with a beachball. This is why an "easy mode that suspends everything" as literally described will make your Mac feel *worse*, not better.

## 3. Correction 2: "not required by macOS" is the wrong boundary

System Integrity Protection is enabled, and it protects `/System/Library/LaunchDaemons`. You cannot unload Apple's system daemons — not as admin, not as root. `launchctl bootout system/com.apple.<anything>` on a protected job fails with `Operation not permitted`. That half of the idea is simply not available to anyone, including Apple's own tools.

But there is a genuinely useful slice underneath that boundary, and it's the one that matters for overnight work:

- **Apple's per-user agents in `gui/501` are mostly fair game.** They're loaded dynamically into your session, so `launchctl bootout gui/501/<label>` and `launchctl disable gui/501/<label>` work even though SIP protects the files. `SiriTTSTrainingAgent`, `mediaanalysisd`, `photoanalysisd`, `chronod`, `sirittsd` and friends are exactly the background chatter that eats a machine overnight. Not all of them are safe to disable — some break features and some get re-enabled by OS updates — but they are reachable, which is a real product surface.
- **Third-party root daemons need root.** `/Library/LaunchDaemons` is root-owned; booting those out requires an admin-authorised privileged helper, not just `sudo` on demand.

So the boundary is not "OS vs non-OS." It is three tiers:
1. **Protected** — Apple system daemons. Untouchable. Never list them.
2. **Apple per-user agents** — touchable, high value, needs a curated safe list.
3. **Third-party** — touchable (user domain without root, system domain with root). This is where 90% of the win is.

---

## 4. What the app must be, technically

**It cannot be sandboxed, and it cannot ship on the Mac App Store.** Two independent reasons: a sandboxed app cannot drive `launchctl` against arbitrary services, and App Review rejects daemons with this kind of reach. Distribution is Developer ID + notarisation + Homebrew, direct download. That is a normal, workable path (LaunchControl, App Tamer, and every utility in this category ship that way).

**It needs a privileged helper, and macOS 13+ gives you the sanctioned way to do it:** `SMAppService.daemon(plistName:)`, with a plist in `Contents/Library/LaunchDaemons`, sharing the app's Team ID and Hardened Runtime, and an explicit user approval at first register. The helper does the root-level work (system daemons, `tmutil`, `mdutil`, `pmset`) over XPC; the user-facing app never runs as root. The older `SMJobBless` path still works but there is no reason to choose it. Two real constraints from Apple's forums and shipping templates: registration is a one-time user consent that can re-prompt after some upgrades, and `SMAuthorizedClients` in the plist is *not* consulted under `SMAppService` — you must validate the calling code signature yourself with `SecCodeCheckValidity` inside XPC handlers.

**The helper must be the state owner, not the UI.** If the menu bar app crashes with 20 services stopped, something has to put them back. Design: helper owns a journal (`/Library/Application Support/dev-mode/journal.json`), appends intent *before* acting, and on start reconciles — if the journal says "quiet mode was active," it either restores everything (fail open, recommended default) or re-enters quiet mode (opt-in), never leaves the machine in an unexplained half state.

---

## 5. Don't build it in Electron

Electron is the wrong choice here for a specific reason: a 300–600 MB resident Electron app is self-defeating in a tool whose product claim is "your Mac is quieter and has more memory." It also adds a second runtime between you and the privileged helper without removing any work.

The shape that fits:

```
devmode-helper (privileged daemon, SMAppService)   ← owns state, does root work, written in Swift
      ▲ XPC
      ├── devmode (CLI + TUI)        ← fastest to build, scriptable, the thing you'll actually use
      └── dev-mode.app (menu bar)    ← one-click toggle + ambient "quiet mode is ON" indicator
```

One shared engine package (Swift): `ServiceCatalog` (discovery + classification), `PolicyEngine` (bundles → actions), `Executor` (freeze/stop/disable/throttle with quiesce checks), `Journal`. The CLI and the menu bar app are two front-ends over the same engine — so the TUI-first build is not throwaway work.

The menu bar app is not optional cosmetics: a mode that suspends services **must** have a persistent, impossible-to-miss indicator, or you will spend a morning debugging a "broken" Postgres that you yourself suspended six days ago.

A TUI can be Bubble Tea or SwiftTUI, but note the privilege split pushes you toward Swift for the helper anyway; a Go TUI + Swift helper is fine (same Team ID, both signed), just more signing surface.

---

## 6. The part that makes it good: a service knowledge base

This is the difference between a toy and a tool, and it is where the actual IP is.

`launchctl bootout` is the right lever for a stateless updater and the *wrong* lever for Postgres — a clean `SIGTERM` with the service's own `ExitTimeOut` (120 s for your `postgresql@18`), or better `pg_ctl stop -m fast`, avoids a crash-recovery cycle. Docker/Podman need `machine stop`, not a VM-process kill. Time Machine is not a launchd job at all (`tmutil disable` / `stopbackup`). Spotlight is `mdutil`. Ollama should unload models, not be frozen mid-inference.

So ship a curated catalog — app/service → {discovery, safe-stop recipe, safe-start recipe, quiesce probe, lever, hazard class} — for the ~40 things developers actually run: postgres (14/17/18), redis, mysql, mongodb, elasticsearch, kafka, minio, nginx, caddy, docker/podman/colima, ollama, mlx-lm, llama.cpp, watchman, tailscale, syncthing, dropbox, onedrive, icloudd, plus the updater families (Sparkle `ShipIt`, Keystone, MS AutoUpdate, Zoom, Steam).

That catalog is also your moat. LaunchControl gives you every plist key with no opinions; App Tamer does per-app throttling with no notion of *services*. Nobody ships "these 40 things, each stopped the right way, in named bundles."

## 7. Bundles, concretely, for this machine

The bundle model is right, and discovery should be mechanical: enumerate launchd jobs in the three tiers, classify by label vendor + `/Applications` ownership + whether the plist has `MachServices`, then let the user override.

- **`vendor-noise`** (safe, default-on in quiet mode): Keystone ×2, GoogleUpdater ×2, MS AutoUpdate, OneDrive ×5, Office licensing ×2, Zoom ×3, Steam clean, Docker helper, ShipIt ×4, Perplexity, OpenAI, Teams agent.
- **`dev-idle`** (stopped during quiet mode, restored after): gitea runners ×3, model routers ×3, `sem1-llama`, `blend1-service`, `second-brain-tower`, `kanzo`, `ux-drift`.
- **`data-services`** (clean stop only, never freeze): `postgresql@18`, `postgresql@14`, `second-brain-pg` (:5439).
- **`never — remote path`**: **Tailscale.** If you reach this Mac over Tailscale (you do: `100.x.y.z:8443` is listening), suspending it during "unattended mode" severs the exact remote access that makes unattended mode useful. This one hazard alone justifies an explicit never-list rather than "everything not OS."
- **`never — self`**: the DSH process tree, your terminal, `sshd`, `ssh-agent`, `WindowServer`, `loginwindow`. Whitelist by **ancestry** (walk the parent chain), not by name — otherwise the app suspends whatever terminal it was launched from.
- **`never — mid-write`**: Time Machine, backup agents, FileVault/keychain, iCloud sync, and anything whose `ExitTimeOut` suggests it does real work on exit.

## 8. If it goes wrong, this is how

1. **Alternative**: `App Tamer` (throttle/suspend frontmost-inactive apps, auto-resume) and `LaunchControl` (the full launchd vocabulary) cover the pieces, but neither composes "profile → safe per-service action → verified restore." Your whitespace is real but narrow, and it sits next to two mature paid apps. Differentiation has to be the catalog and the restore guarantee, not the toggle.
2. **Costs**: Developer ID ($99/yr), notarisation in CI, and a per-macOS-release maintenance burden — Apple reshuffles per-user agents every year, so a hardcoded Apple safe-list rots on a 12-month cycle.
3. **The failure that kills trust**: one incident where the tool stops a database mid-write and corrupts it, or leaves 20 services down after a crash. Trust here is binary. Budget real effort on journal + fail-open restore + dry-run preview before you add a single convenience feature.
4. **Loss of the mental model**: after three weeks nobody remembers which services are suspended. Needs a diff view ("quiet mode has 22 stopped, 4 of them since before you installed this") and the "was already stopped before I started" rule — never resurrect something the user had off.

---

## 9. Recommended build order (2 weeks to a defensible MVP)

**Days 1–3 — engine spike, no UI.** `devmode list/diff/toggle --dry-run`. Catalog discovery, classification, ancestors whitelist, journal. Acceptance: dry-run correctly names all 35 third-party jobs here and refuses the never-list.
**Days 4–6 — executor.** Freeze, stop, disable, throttle; quiesce probes; per-service stop recipes for the four data services. Acceptance: quiet mode stops Postgres via `pg_ctl stop -m fast` (not SIGSTOP), resumes clean, no crash-recovery log entry.
**Days 7–8 — crash safety.** Acceptance: `kill -9` the CLI while 20 services are stopped; relaunch restores all of them and reports what it did. Then: reboot while quiet mode is on → behaves according to an explicit, stated policy.
**Days 9–11 — TUI.** Bundle picker, live state, the "quiet mode is ON, 22 suspended" banner, `resume --all`.
**Days 12–14 — helper + notarisation.** `SMAppService.daemon`, XPC with `SecCodeCheckValidity`, root path for `/Library/LaunchDaemons` and `tmutil`/`mdutil`. Menu bar shell after that.

Skip until after the MVP: Apple per-user agents (needs a maintenance commitment), idle-trigger automation (detect unattended via `CGEventSource` idle time or `ioreg -c IOHIDSystem | grep HIDIdleTime`), and scheduled windows.

---

## 10. What I could not verify here, and how to close it

- **`launchctl bootstrap` from this session** returned `Bootstrap failed: 5: Input/output error` even for a minimal two-line plist, from both `/tmp` and the project directory. That is the sandboxed tool environment refusing service-management, not a macOS limitation — `launchctl print` and `lsof` read fine, and the stop half of the lever table is ordinary documented behaviour used by every `brew services` command. Confirm in one minute from your own terminal:
  ```sh
  cat > /tmp/p.plist <<'P'
  <?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
  <plist version="1.0"><dict><key>Label</key><string>dev.mode.probe</string>
  <key>ProgramArguments</key><array><string>/usr/bin/yes</string></array>
  <key>KeepAlive</key><true/></dict></plist>
  P
  launchctl bootstrap gui/$(id -u) /tmp/p.plist && echo LOADED
  launchctl kill SIGSTOP gui/$(id -u)/dev.mode.probe && echo FROZEN   # verify launchctl kill accepts SIGSTOP
  launchctl kill SIGCONT gui/$(id -u)/dev.mode.probe && echo RESUMED
  launchctl bootout  gui/$(id -u)/dev.mode.probe && echo UNLOADED
  ```
  That single block tests the entire primitive set the app depends on, and answers the one open question (`launchctl kill SIGSTOP` vs plain `kill -STOP` on the pid).
- **Memory reclaim per service** is unmeasurable from here (`ps` and `top` are blocked by the tool sandbox). Before you write the first line of UI, measure it: `footprint -p <pid>` or Activity Monitor against the `dev-idle` + `data-services` set. If that set is 2 GB, the product has a real number to show; if it's 400 MB, the pitch has to be energy and determinism instead, and that changes the marketing.
- **Whether disabling Apple per-user agents survives an OS update** — unknown, per-service. Spike it on `mediaanalysisd` first; it's the least able to break anything.

---

## Bottom line

Possible, with a legitimate API path and no platform blocker — but build **"quiet mode for the third-party layer, with per-service recipes and a guaranteed restore,"** not "suspend everything that isn't macOS." The first is a real product with a defensible catalog and a clear user (developers who leave agents running overnight on a 16 GB Mac that is already swapping 5.4 GB). The second will hang your Postgres, cut your Tailscale link, and teach you that `SIGSTOP` doesn't free a byte.
