# Session recap — 2026-11-26

**Curfew, from a read-only tool to a working app with a window.** Twelve commits, from `a5e2513` to
`e066a62`. 261 tests in 34 suites, green. 53 known issues — **zero open**. 37 decisions, 27 contracts.

The shape of this session: every defect was found by *pressing something* and none by reading the code.
That is the sentence to carry forward.

---

## What shipped

### The model-assisted layer finished (L7.1–L7.4)

- `curfew doctor --rank` — one `score` head per finding, ordering only, severity untouched.
- A **runs-delta tracker** (KI-040) because the crash-loop rule stands down on a job observed running, so a
  fast loop could hide. Four conditions, each measured: a supervised job, a non-zero exit, samples ≥5 min
  apart, and a rate in `[10, 600]/h` — 600 being launchd's own throttle ceiling.

### The app became an app (D30, D31)

- The menu can **start quiet mode**: the dry run is shown in its own confirmation dialog, and `--execute`
  runs only after Apply. That is rule 3 satisfied where no journal can be read.
- `Curfew.app` is now **windowed** (D31), with `PRODUCT.md` and `DESIGN.md` at the repo root, designed with
  the impeccable skill. Sidebar over Quiet mode / Bundles / Findings / Services / Apps.
- It installs to `~/Applications` with a login opener, its catalogue sealed inside the bundle, and a Dock
  presence.

### Findings you can act on

- Finding rows are **state-aware**: Stop before, Start after, with `held by Curfew` in the row (KI-047).
- Removed-app **debris can be quarantined** — moved into Curfew's own folder, journaled, restorable by
  `resume`; never deleted (D34). Offered only where the owning app is verifiably gone (D35).
- Platform-path findings (`/System`, `/usr`) report as **environmental**: macOS ships jobs whose program
  does not exist, and Curfew could not touch them anyway.

### Apps pane (D36)

Measured: **51 apps held 4,156 MB** — Firefox alone 1,899 MB — against **20 MB for the entire
vendor-noise bundle**. Quiet mode had been optimising the wrong 1%. The pane lists apps by memory, pre-
selects nothing, and offers **Freeze** (SIGSTOP, journaled, reversible) with **Quit** as the quieter,
deliberate choice. The shell, this harness, Curfew and the remote-access path are excluded.

---

## Defects found by driving, not by reading

Twelve, and the pattern in them is the session's lesson.

| | what looked true | what was true |
|---|---|---|
| KI-044 | the stop ran | a wrong verify kind aborted the bundle at **1 of 13** |
| KI-045 | quiet mode was on | it read "nothing to restore" the instant it succeeded — **the machine was changed and could not be undone** |
| KI-047 | the button said Stop | the row never knew Curfew held the service; no per-label restore existed |
| KI-048 | the button did nothing | the pre-existing guard made **every disable a no-op on an idle service** |
| KI-052 | the Apps pane existed | **no sidebar row** — the pane was unreachable |
| KI-053 | the row offered Freeze | a frozen app could never be resumed |
| KI-051 | the app scan ran | macOS `ps` truncates the command column with four fields — **zero apps returned** |

Three of those (042, 047, 053) are the same shape: **an action with no inverse, or with no way to reach
it.** That is now a written rule in `DESIGN.md` — *every action has its inverse on the same row; the global
Restore is the sweep, never the only way back* — and **D37** makes the sidebar derive from the pane enum so
a surface cannot exist without a way in.

## Two measurements that changed decisions

- **KI-008**: `footprint -p` works under full access; the whole acting bundle holds **20 MB**. Quiet mode
  saves wakeups and crash loops, **not memory**. The memory pitch is dead.
- **KI-050**: the apps hold **4 GB**. The reclaim was always there, in the other half of the system.

## How verification was done

- `--render-window <path> --pane <name>` hosts a pane in an offscreen **key window** and reads its backing
  store. `ImageRenderer` cannot lay out a `ScrollView` (it returns an empty plate), and screen recording is
  not permitted in this session.
- `--drive-stop` / `--drive-start` / `--drive-freeze` / `--drive-quarantine` / `--dump-apps` /
  `--dump-panes` / `--quiet-command` — **D33**: the app's own path is driveable from the command line,
  because a path that cannot be driven without a mouse cannot be checked at all.
- Evidence in `docs/evidence/`: `window-quiet-off.png`, `window-quiet-on.png`, `window-findings.png`,
  `window-findings-held.png`, `window-findings-debris.png`, `window-apps.png`.

## What the design work changed that I would have got wrong

- Three hero numbers (13 / 11 / 469) were the **hero-metric template** the craft floor refuses. Seen in the
  first render, removed.
- Severity was encoded **by colour alone**. Seen in the second render, the word added.
- The Apps pane carried **Tailscale** — the remote-access path rule 7 protects. Seen in the third render,
  excluded.

None of those three were visible in the code.

## Not verified

- The window's **sidebar, sheets and a full click-through** have never been seen on screen — only panes
  rendered offscreen and paths driven. That is the honest gap, and it is what produced KI-052.
- Freezing a **browser with live tabs** has not been tried; Firefox showed 24 processes with 23 stopped,
  because the 24th spawned after the freeze. **Freezing is a snapshot, not a state.**
- Whether `disable` survives an OS update.
- The Harness/Curfew session has not been through `make check`'s crash test against a real bundle.

## Open items, ranked

1. **A UI smoke test that drives the app through its panes** and asserts each becomes visible. Three
   reachability defects in one session is a pattern, not bad luck.
2. **Reconsider Freeze as the default verb for apps that hold network connections** — a frozen sync client
   stalls, a frozen browser may leave a download half-written.
3. `com.workbuddy.converter` runs a Python that no longer exists (its `.venv` was deleted). Re-creating the
   venv is a project decision, not Curfew's.
4. The fleet repo still holds uncommitted jev changes, and its recall index is a stale 768-dim copy.

## Delivery state

**Committed locally; never pushed.** `origin` is `gitea-gitea.opsh.io/synapticmomentum/curfew` and
`git ls-remote origin` returns no refs at all — the remote repository is empty, so none of this session's
twelve commits exist anywhere but this machine. `main` also has no upstream configured. That is a real
exposure and the first thing to fix next session.

Installed to `~/Applications/Curfew.app`, app running, LaunchAgent loaded, `curfew` on PATH at
`~/.local/bin`. Tree clean. Machine state: three things held by Curfew, all the owner's own — Firefox and
News frozen, `com.docker.helper` disabled — each with a Resume or Start row.
