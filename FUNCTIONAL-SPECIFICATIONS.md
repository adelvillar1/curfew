# Curfew — Functional Specifications

> **For:** Product/UX reference and developer onboarding (user-flow contract)
> **Repo:** https://gitea-gitea.opsh.io/synapticmomentum/curfew
> **Production:** none — local macOS application

This is the user-flow contract: what the product does from the user's perspective, including the rules and edge cases that govern behaviour. When a feature ships, update the relevant `docs/features/<name>.md` **and** the matching section here.

---

## Table of Contents

1. [First Run & Permissions](#1-first-run--permissions)
2. [Modes](#2-modes)
3. [Core Features](#3-core-features)
4. [User Flows](#4-user-flows)
5. [Scripting Surface](#5-scripting-surface)
6. [Indicators & Notifications](#6-indicators--notifications)
7. [Edge Cases & Error States](#7-edge-cases--error-states)
8. [UI Consistency Standards](#8-ui-consistency-standards)

---

## 1. First Run & Permissions

<add-when-implemented>
- What the user sees on first launch, before any helper is installed.
- The admin-approval prompt for the privileged helper and how it is explained in plain language.
- The inventory pass: what Curfew discovers, what it refuses to touch, and what it asks.
- First-run default: nothing is applied. The first action available is a dry run.
</add-when-implemented>

## 2. Modes

<add-when-implemented>
- **Easy mode** — the one-click "quiet now". Precisely which tiers it covers (vendor-noise only, by default) and what it deliberately excludes (Apple per-user agents, data services, the remote-access path).
- **Bundles** — named, composable sets (vendor-noise, dev-idle, data-services, harness-core, harness-optional). A user can create custom bundles.
- **Custom selection** — per-service toggle with the lever shown.
- Every mode states plainly what will be stopped and what will keep running, before it runs.
</add-when-implemented>

## 3. Core Features

**Shipped (read-only, v0.1.0).** The mutating features below it are still scaffolding and are marked so.

### 3.1 Inventory and classification — `curfew list`

- **Entry point:** `curfew list [--domain gui|system|all] [--json]`.
- **Inputs:** none required. `--domain all` adds the `system` domain (read-only, no privilege needed).
- **Behaviour:** enumerates every job in the domain table, reads each job's detail, then assigns tier
  (protected / osCore / appleAgent / thirdParty), kind (daemon / agent / appChild / container /
  inProcess / command / unmanaged), vendor and supervision. A row that will not parse is counted and
  skipped, never fatal.
- **Output:** 472 records on this machine, third-party first, with `runs`, exit code and finding count.
- **Success state:** a table whose third-party section is the operator's work surface and whose Apple
  section is explicitly labelled *reported only, never acted on*.

### 3.2 Causality — `curfew why`

- **Entry point:** `curfew why <label>`, or `--pid N`, `--port N`, `--name S`.
- **Behaviour:** a live target is enriched through `witr` (ancestry, launchd source, plist, sockets,
  working directory, git, warnings). A **label with no live process** is answered from launchd instead —
  `runs`, `last exit`, `state` — because that is the case no process tool can see.
- **Exit codes:** 0 reported, 2 not found (including a dead job, whose `runs`/exit go to stderr),
  3 when `witr` is absent and the answer would need it.

### 3.3 Diagnosis — `curfew doctor`

- **Entry point:** `curfew doctor [--json] [--disagreements]`.
- **Behaviour:** every record's findings, plus a listener cross-check that reports ports held by a dead
  job's executable (`orphanPort`, a defect) and ports belonging to no job at all (`noSupervisor`, one
  aggregate gap). Disagreements between launchd and `witr` are logged and mark the scan **incomplete**.
- **Success state:** findings listed with their evidence, and an explicit `scan: complete | incomplete`.
  "No findings" is only ever printed by a scan that saw everything.

### 3.4 Never-list and protected services

Tier 0/1 jobs are reported, never acted on, and the list is compiled code (`NeverList.swift`). A
protected job appears in `list` with `tier: protected` and can never enter a bundle.

### 3.5 The catalog and its preview — `curfew catalog`

- **Entry point:** `curfew catalog validate | list [--bundle NAME] | plan --bundle NAME`.
- **Behaviour:** loads `catalog/*.yaml`, checks it against the policy rules, and — for `plan` — prints the
  ordered argv it *would* run, the entries it refuses and why, and the protected ports the bundle must
  not touch.
- **Nothing is executed.** There is no code path from the catalog to a process; a test fails the build
  if one appears.
- **Refusals are the point:** a `draft` entry is refused ("a recipe must be verified before it can be
  applied"), a `protect` bundle is refused ("never actioned"), and a recipe needing the helper is
  refused until L4 exists.

### 3.6 Apply, resume and the journal (built; no live service has been stopped by it)

- **Entry point:** `curfew apply --bundle N [--execute [--yes]]`, `curfew resume [--execute]`,
  `curfew status`.
- **Default is a dry run.** It prints what would run and every refusal, and writes no journal.
- **`--execute` off a terminal needs `--yes`** — a pipe or a script cannot stop services by accident.
- **Pipeline:** refuse → journal the intent → act → verify the post-condition → journal the outcome.
  A refusal happens before the first intent is written, so a refused run leaves no trace.
- **Refusals:** draft entry · root-requiring recipe (until L4) · a port a protect bundle guards · a
  never-list label · a pid in Curfew's own ancestry · no stop recipe · no plist path when the recipe
  needs one.
- **Rule 6:** a service already stopped is recorded as `pre-existing` and is **not** started by
  `resume`.
- **Recovery:** `resume` replays unresolved intents in reverse and closes each one; a failed resume
  leaves its intent open so a retry still happens. A second `resume` does nothing.
- **State today:** `vendor-noise` has two `verified` entries (`us.zoom.updater`,
  `com.microsoft.OneDriveStandaloneUpdater`); every other entry is `draft` and refused.

## 4. User Flows

<add-when-implemented>
- Quiet now → run an overnight build/agent → resume in the morning.
- Recovering from a crash that happened while quiet mode was active.
- Adding a new service to a bundle.
- Investigating "why is my database down" (the guard rail against self-inflicted outages).
</add-when-implemented>

## 5. Scripting Surface

<add-when-implemented>
- The `--json` contract and what scripts can rely on.
- Exit codes: success, refusal (protected service), partial apply, journal error.
- Why refusals are distinct exit codes rather than failures.
</add-when-implemented>

## 6. Indicators & Notifications

**Implemented (TUI, v0.1.0).**

- **The quiet-mode state is on the header of every frame**, in words: `quiet mode: off`, or
  `QUIET MODE: ON  (unresolved journal intents)`. It never scrolls away, because a mode that suspends
  services must never be invisible.
- **The footer states the read-only guarantee on every screen**: *"only `curfew apply --execute`
  changes anything"*.
- **Excluded rows are counted, not hidden silently**: `hidden: 18 (protected + app-bound)` tells you
  what the screen is not showing.
- A failed restore is louder than a successful apply — that rule belongs to the mutating path and is
  written when it ships.

### Menu bar (built)

- One status item: `○` when quiet mode is off, `◐ N` when it is on and holding N unresolved intents.
- The menu states the mode in words, the running and finding counts, and the restore affordance —
  **enabled only when there is something to restore**.
- It offers dashboard, restore and quit. **It cannot apply a bundle** (D23); quieting the machine stays
  a deliberate CLI act.
- Verified: the model and its enabled/disabled states (6 tests), the bundle builds and launches, and
  `--dump-menu` shows both states. The status item's appearance is confirmed by the owner — screen
  capture is unavailable to an agent session.

### Not built

Per-action confirmations and notifications.

## 7. Edge Cases & Error States

**Read-only behaviour (implemented).**

| State | What the tool does |
|---|---|
| A job is loaded but not running | `list` shows `spawn scheduled` / `not loaded`; `why` answers from launchd with `runs` and `last exit`, and exits 2 |
| A field cannot be read | The record carries `fieldUnavailable` (`confirmsScan: false`); the scan is marked incomplete, never clean |
| `witr` is absent | `list` and `doctor` work; `why` exits 3 naming `brew install witr`; the scan is marked incomplete |
| `witr` cannot read a process | A `witrinvalid` disagreement is logged; the record is marked `degraded` |
| launchd and `witr` disagree on a pid | launchd wins; an `identityConflict` is logged; the record is `degraded` |
| App-child `path` is a description (`(submitted by runningboardd.418)`) | Not treated as a path; no `stalePlist` |
| Two processes share a command name (`node`) | Identity is the resolved executable path, never the name |
| A dead job's executable still holds a port | `orphanPort`, a defect naming both the port and the job's state |
| A listener belongs to no job | One aggregate `noSupervisor` gap listing them — never a per-row defect |
| A running job with 27k restarts | Not a crash loop: the job is running, so its exit code is history, not a failure |

**Mutating behaviour (not built).** The list that was scaffolded here — crash during quiet mode, reboot
mid-mode, pre-existing stopped services, vendor re-registration, OS updates moving labels, a frozen app
holding a lock, helper revoked, unreadable journal — belongs to L3/L4 and is written with those plans.

## 8. UI Consistency Standards

<add-when-implemented>
- TUI and menu bar share one vocabulary: tier, lever, bundle, apply, resume.
- Numbers are always measured, dated, and attributed ("2.1 GB reclaimed, measured 2026-11-24") — never estimated silently.
- Destructive-looking actions (stop a database) require a confirmation that names the service.
</add-when-implemented>
