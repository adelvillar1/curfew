# Curfew — Technical Documentation

> **For:** Developer onboarding and reference
> **Repo:** https://gitea-gitea.opsh.io/synapticmomentum/curfew
> **Production:** none — this is a local macOS application

This is the developer-onboarding contract. It is summary-style and links into `docs/` for depth. When a feature ships, update the relevant `docs/` file **and** the matching section here.

---

## Table of Contents

1. [Project Overview](#1-project-overview)
2. [Tech Stack](#2-tech-stack)
3. [Architecture](#3-architecture)
4. [Service Catalog](#4-service-catalog)
5. [CLI & XPC Interface](#5-cli--xpc-interface)
6. [Privilege, Signing & Permissions](#6-privilege-signing--permissions)
7. [Front Ends (TUI, Menu Bar)](#7-front-ends-tui-menu-bar)
8. [Automation & Triggers](#8-automation--triggers)
9. [Distribution & Release](#9-distribution--release)
10. [Development Workflow](#10-development-workflow)
11. [Scripts Reference](#11-scripts-reference)
12. [Observability](#12-observability)

---

## 1. Project Overview

A macOS tool that puts the machine into a quiet state for unattended development: it suspends, stops, or throttles the background services a build or agent run does not need, and restores them safely.

<add-when-implemented>
- The two-sentence product statement, once the memory-vs-determinism decision is made (see `docs/research/feasibility-assessment.md` §10).
- Who it is for: developers who run long builds or AI agents unattended on a memory-constrained Mac.
- Key differentiator: per-service verified stop/start recipes and a journal-backed restore guarantee — not a blanket `SIGSTOP`.
</add-when-implemented>

## 2. Tech Stack

| Layer | Technology |
|-------|------------|
| Language | Swift 6, strict concurrency |
| Build | Swift Package Manager (single package, multiple targets) |
| CLI/TUI | `swift-argument-parser` + ANSI TUI (no external TUI dependency until proven necessary) |
| Privileged work | `SMAppService.daemon` helper, XPC |
| Menu bar (later) | SwiftUI `MenuBarExtra` |
| Catalog format | YAML, validated at build time by a decoder + schema test |
| Tests | Swift Testing for unit/policy; a fixture-driven integration harness against fake plists |
| Distribution | Developer ID + notarised DMG, Homebrew cask |

Rationale for not using Electron: a memory-reclaiming tool that parks 300–600 MB of Chromium undermines its own claim, and it adds a runtime between the UI and the helper without removing work. See `docs/architecture/overview.md`.

## 3. Architecture

<add-when-implemented>
- Module graph: `CurfewKit` (catalog, policy, executor, journal) → `curfew` (CLI/TUI) and `curfew-helper` (root, XPC) and `Curfew.app` (menu bar).
- The helper owns journal state, not the UI. Why: a crashed front end must not strand suspended services.
- Data flow for `apply`: read journal → resolve bundle → quiesce probe → plan actions → journal intent → execute → verify → report.
- Data flow for `resume`: read journal → reverse only the entries we wrote → verify → clear journal.
</add-when-implemented>

Detailed architecture: [`docs/architecture/overview.md`](docs/architecture/overview.md)

## 4. Service Catalog

**Implemented (v0.1.0, read-only).** `catalog/*.yaml`, loaded by `CatalogLoader`, checked by
`CatalogValidator`, planned by `CatalogPlanner`. **No entry can be executed** — `curfew catalog` prints,
and the planner is arithmetic.

```yaml
entries:
  - id: sh.brew.postgresql@18      # the launchd label, or unmanaged:<exe>@<port>
    kind: agent                    # daemon agent appChild container inProcess command unmanaged
    lever: command                 # freeze stop disable throttle command none
    supervised: launchd            # launchd appParent none
    status: draft                  # draft | verified  (rule 5)
    hazards: [socket, data]
    stop:
      run: [/opt/homebrew/opt/postgresql@18/bin/pg_ctl, -D, ..., stop, -m, fast]
      expect: port 5432 released and no postmaster process remains
      quiesce: no ESTABLISHED clients on 5432
      hold: bootoutIfRespawned     # pg_ctl leaves launchd supervising the job
    start:
      run: [...]
      meansReady: port 5432 accepts a connection
    depends: []
```

**`run` is argv, never a shell string** — a list of steps, each its own argv. The only substitution is
`{domain}`; any other `{token}` is a validation failure. Unknown keys are a load error, not a silent
drop: a typo in a stop recipe must not be ignored.

**Bundles** live in `catalog/bundles.yaml` and carry a role: `stop` (a mode that acts) or `protect` (a
set that is never actioned). A protecting bundle may assert `protectPorts` — the harness is guarded by
8901/4242/7426/57730/57801 rather than by labels a reinstall can rename.

**Validation rules** (each has a test, each names its file):

| Rule | Refusal |
|---|---|
| A never-list label cannot be catalogued at all | rule 4 / D9 |
| `freeze` is illegal with a `socket` or `port` hazard | rule 4 / D10 |
| `verified` without `evidence` | rule 5 |
| `supervised: none` needs a start recipe or `stoppable: false` | D12 |
| `lever: none` only with `coldStartCost` | D14 |
| A `stop` bundle may not contain a lever-less entry | D0 |
| `depends` must name an existing entry | decomposition discipline |
| Only `{domain}` may appear in a recipe | argv purity |

Raw YAML is parsed by `MiniYAML`, a deliberately strict subset: block maps and lists, inline scalar
lists, comments. Tabs, block scalars, anchors, inline maps, quoted keys and multi-document files are
**errors** — a permissive parser reading stop recipes is a safety defect, not a convenience.

## 5. CLI & XPC Interface

**Implemented (v0.1.0, read-only slice).** Three verbs, one contract. There is no XPC surface yet —
that is L4, and it arrives with the first mutating layer.

```
curfew list    [--domain gui|system|all] [--json]
curfew why     <label> | --pid N | --port N | --name S [--json]
curfew doctor  [--json] [--disagreements]
curfew catalog validate | list [--bundle N] | plan --bundle N   [--json] [--dir PATH]
curfew status  [--json]                                  # unresolved journal intents
curfew apply   --bundle N [--execute [--yes]] [--json]   # dry run unless --execute
curfew resume  [--execute [--yes]] [--json]              # restore what the journal holds
```

**`apply` is a dry run by default.** `--execute` additionally requires `--yes` when stdout is not a
terminal, so a pipe or a script cannot stop services by accident. `curfew status` reads the
write-ahead journal at `~/Library/Application Support/Curfew/journal.jsonl` (`CURFEW_JOURNAL`
overrides it); an intent is flushed before the action it describes, and `resume` replays unresolved
intents in reverse.

**Exit codes** (stable; scripts may branch on them):

| Code | Meaning |
|---|---|
| 0 | clean — nothing found, scan complete |
| 1 | warnings — findings present, or a scan was incomplete |
| 2 | not found — the target does not exist (a dead job exits here with its `runs`/exit code on stderr) |
| 3 | dependency missing — witr absent or incompatible; the inventory still worked |
| 4 | bad input — unknown command or ambiguous target |
| 5 | internal error |
| 6 | read-only violated — never expected; `ReadOnlyGuaranteeTests` forbids it |

**`--json` shapes** live in `Sources/CurfewKit/Contracts.swift` and are pinned by
`ContractShapeTests`. Rules: field names and meanings are stable, changes are additive only, and
**a field with no value is omitted, never `null`** — a missing optional key means "not read", the
same distinction the tool makes internally (D3).

```
list   → { v, sources{witr,macos,curfew}, records[ServiceRecord], scan{complete,incompleteReasons} }
why    → { v, sources, record?, ancestry[], source{type,name,plistPath}?, warnings[], scan }
doctor → { v, sources, findings[{label,domain,id,severity,summary,evidence}], scan, disagreements[] }
```

**Read-only by construction.** The binary has no mutating code path: `LaunchdInventory` invokes
`launchctl print` and `print-disabled` only, and `ReadOnlyGuaranteeTests` proves it by putting shims
for `launchctl bootout`, `kill`, `tmutil`, `mdutil`, `brew`, `kiri` and `podman` on `PATH` and
failing if any is called.

**Optional dependency.** `witr` (>= 0.3.4) supplies process causality. Absent or incompatible, the
inventory still works and `why` exits 3 with the install command. `CURFEW_WITR_PATH` pins a binary;
an empty value disables it.

## 6. Privilege, Signing & Permissions

This is the auth-equivalent section for a local tool.

<add-when-implemented>
- What requires root (system daemons, `tmutil`, `mdutil`, `pmset`), what requires admin, what requires neither.
- `SMAppService.daemon` registration flow, the user-approval prompt, and re-registration after upgrades.
- Why `SMAuthorizedClients` is not consulted under `SMAppService` and where the code-signature check actually lives.
- TCC: what Curfew must never need (Accessibility, Full Disk Access) and what it genuinely does need, if anything.
- Why the app cannot be sandboxed and cannot ship on the Mac App Store.
</add-when-implemented>

## 7. Front Ends (TUI, Menu Bar)

<add-when-implemented>
- TUI layout: service list with tier/lever/state, bundle picker, dry-run preview pane, the persistent "quiet mode is ON" banner.
- Menu bar: one-click toggle, a count of suspended services, and the always-visible indicator (never a silent mode).
- Both front ends are thin over `CurfewKit`; no policy lives in a view.
</add-when-implemented>

## 8. Automation & Triggers

<add-when-implemented>
- Idle detection (`CGEventSource` idle time), and why the trigger is opt-in rather than default.
- Scheduled windows, if any.
- What "unattended" is allowed to mean: no keyboard input, no active TTY build, no agent CPU activity.
- The rule that an automatic apply must be indistinguishable from a manual one in the journal.
</add-when-implemented>

## 9. Distribution & Release

| Branch | Environment | Auto-deploy | Notes |
|--------|-------------|-------------|-------|
| `main` | local / release | no | Notarised DMG + Homebrew cask, published by hand |

<add-when-implemented>
- Build → sign → notarise → staple → package order.
- The helper is signed *before* the outer bundle is sealed.
- Homebrew cask in a tap; version bump procedure.
- What the release checklist verifies on a clean machine (helper registers, dry-run works, resume restores).
</add-when-implemented>

Signing credentials live in `CLAUDE.local.md` (gitignored).

## 10. Development Workflow

1. **Plan** — `docs/plans/YYYY-MM-DD-<slug>.md` with verifiable acceptance criteria. See [`docs/plans/README.md`](docs/plans/README.md).
2. **Build** — implement on `main`, validate locally. Anything that mutates a live service is tested against fixtures first.
3. **Recap** — `docs/recaps/SESSION-RECAP-YYYY-MM-DD.md` with criteria status.
4. **Document** — update this file and `FUNCTIONAL-SPECIFICATIONS.md`.

The cycle compresses for trivial work. It does not compress for catalog recipe changes or anything touching the never-list.

## 11. Scripts Reference

<add-when-implemented>
- Probe scripts: service inventory, `footprint -p` sampling, swap/compressor measurement.
- Catalog validation and generation runs.
</add-when-implemented>

Full catalog: [`docs/scripts/README.md`](docs/scripts/README.md)

## 12. Observability

<add-when-implemented>
- Journal format and rotation; why it is append-only.
- Log destination and levels; what is deliberately never logged (secrets, env values).
- The `doctor` command: SIP status, helper health, journal integrity, catalog version, drift from last snapshot.
</add-when-implemented>

## Vocabulary and display names

`CurfewKit/Vocabulary.swift` is the boundary where launchd and the judgement engine stop and English starts:
`action`, `jobState`, `findingKind`, `heldPhrase`, `tier`, `serviceGroup`, and `displayName(for:)`. It is pure
string mapping with no I/O, covered by `VocabularyTests` (13 tests), and the raw identifier is always preserved
in the JSON and on the row's detail line.

`AppSnapshot.Service` carries both `label` (verbatim) and `displayName` + `group`, so a view never derives a name
itself and the CLI's JSON keeps the truth.

## ServiceList

`CurfewKit/ServiceList.swift` holds the Services list's filtering, sorting and grouping as pure functions
(`filter`, `sort`, `group`, `present`). The view delegates to it, so list behaviour is tested rather than driven.

## OrphanScan

`CurfewKit/OrphanScan.swift` parses `ps -Axo pid=,ppid=,uid=,rss=,command=` and applies the keep-alive rules
(exact command match, `ppid == 1`, caller's uid). `parse` is pure and covered by `OrphanScanTests` (7 tests);
`scan` injects the `ps` runner so no test reads a real process table. `AppSnapshot.orphans` carries the result
and `AppSnapshotProvider.load` scans by default.

