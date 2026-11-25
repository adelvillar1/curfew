# Session recap — 2026-11-24

**Plan link:** `docs/plans/2026-11-24-inventory-and-why.md` (completed this session)

## What shipped

`curfew 0.1.0` — the read-only slice. Three verbs over launchd, with `witr` as an optional
causality engine:

| Verb | What it does |
|---|---|
| `curfew list` | every launchd job in `gui/$UID` and `system`, classified by tier/kind/vendor/supervision, with `runs`, exit code and findings |
| `curfew why` | a label, pid, port or name → ancestry, launchd source, plist, sockets, cwd, warnings; answers from launchd when the job has no pid (the case no process tool can see) |
| `curfew doctor` | aggregated findings, scan completeness, and `--disagreements` |

Supporting modules: `NeverList` (28 labels + 26 process names, compiled), `LaunchdParser`,
`LaunchdInventory` (bounded-concurrency sweep), `Classifier`, `FindingsEngine` (8 rules as pure
functions), `DisagreementLog` (typed JSONL, fingerprint rate-limit, rotation), `WitrClient`.

**Measured on this machine:** 472 records in **1.19 s**; **16 findings**, all verified real
(`com.valvesoftware.steamclean` is a genuinely dead job — Steam is gone, the plist remains, and
launchd has been failing it at `EX_CONFIG`; `us.zoom.ZoomDaemon` and
`org.cups.cupsd` declare binaries that do not exist; `com.workbuddy.converter` points at a deleted
venv; six Apple jobs declare programs absent from macOS 26.5.2).

**Tests:** 57 across 10 suites, green — including the mechanical read-only guarantee (shimmed
`launchctl bootout`/`kill`/`tmutil`/`mdutil`/`brew`/`kiri`/`podman` are never invoked), the
never-list completeness check against the research document, the disagreement log's
rate-limit/rotation/redaction invariants, the JSON contract shapes, and a source scan proving no
networking code exists.

## Round 2 — L1.10, the listener scan

Plan: `docs/plans/2026-11-24-listener-scan.md` (completed). `doctor` now parses
`lsof -nP -iTCP -sTCP:LISTEN`, deduplicates dual-stack rows, and compares each listener against the
record set by **resolved executable path**.

Two findings, deliberately different in shape:

- `orphanPort` (defect, per instance) — a port held by a process whose executable belongs to a job that
  is **dead**. This is the PG14 case.
- `noSupervisor` (gap, one aggregate row) — listeners belonging to no job. On this machine: 12 ports,
  all legitimate (Tailscale, ControlCenter, an app-spawned Ollama, a `/tmp` capture server).

**The live run corrected the rule twice**, both recorded as `KI-025` and `KI-026`:

1. Matching on the command name accused `dev.dsh.bridge` of owning `:3999`, held by an unrelated `node`
   — `lsof` truncates commands to nine characters and interpreters share names. Identity is now the
   executable path.
2. Requiring only "not this job's pid" then flagged Google Drive and DSH Fleet, each of which runs a
   second process of the same binary. An orphan now requires the job to be **dead**.

11 tests for the scan; the read-only suite gained a listener-scan case with `lsof` as a pass-through shim.
`swift test`: **71 tests, 11 suites, green**.

## Round 3 — L3.1, the catalog schema

Plan: `docs/plans/2026-11-24-catalog-schema.md` (completed).

Three owner decisions shaped it: `pg_ctl stop -m fast` for data services **with a `hold: bootoutIfRespawned`
step** (pg_ctl leaves launchd supervising a stopped server, so a KeepAlive job can come straight back);
the harness protected **by port** rather than by label; bundles as **files** with a role.

- `catalog/*.yaml` — 6 entries, all `draft`, 4 bundles. `harness-core` protects 8901/4242/7426/57730/57801.
- `MiniYAML` — a deliberately strict subset parser. Tabs, block scalars, anchors, inline maps, quoted
  keys and multi-document files are **errors**: a permissive parser reading stop recipes is a safety
  defect, not a convenience. Unknown keys are a load error for the same reason.
- `CatalogValidator` — eight rules, each with its own test. `freeze` is illegal with a `socket`/`port`
  hazard; `verified` requires `evidence`; a never-list label cannot load at all.
- `CatalogPlanner` — orders by `depends`, refuses drafts, refuses `protect` bundles, detects cycles.
- `curfew catalog validate|list|plan` — and a test that fails the build if `Process(` ever appears in
  the catalog sources.

**20 new tests; 93 total in 14 suites, green.** A deliberately broken catalog produces four independent
violations in one pass, each naming its file.

One deviation from the plan's wording: the read-only guarantee for the catalog is a **source scan** ("no
`Process(` in Catalog.swift or MiniYAML.swift") rather than a shimmed CLI run — stronger, because it
proves the module cannot spawn at all.

## Round 4 — build-order correction, the journal, and the verify block

**The decomposition had the L3 order wrong** and it was corrected before any code: it put the journal
*after* the executor (violating rule 2) and made the executor depend on entries that can only be verified
by running recipes. Corrected to **journal → executor → entries**. Ids were not renumbered; only their
dependencies moved.

Shipped the journal half of `docs/plans/2026-11-24-executor-and-journal.md` (now `active`):

- `Journal.swift` — append-only JSONL, intent flushed before the caller can act, a truncated final line
  skipped rather than fatal, `restorePlan()` returned in reverse order.
- `curfew status` — reads the journal, prints unresolved intents with their age, exits 1 when any exist.
  Verified against a hand-written journal: intent 1 resolved by its outcome, intent 3 reported at "5 min".
- The catalog gained `verify:` (`port_closed` / `process_gone` / `label_not_running`) plus a validator
  rule: **a `verified` entry whose stop has no post-condition is refused**, because `expect:` is prose.

**11 new tests; 104 total in 16 suites, green.**

**The constraint that shaped the scope:** the executor's `--execute` path cannot be verified from a
sandboxed session — `launchctl bootstrap` returns `5: Input/output error` here (KI-002). So the journal
was built and proven; the executor will be built against an injected runner and verified with fixtures,
and the first real run belongs to the owner.

## Round 5 — L3.3, the executor

Plan `2026-11-24-executor-and-journal.md` is **completed**. The pipeline is: **refuse → journal the
intent → act → verify → journal the outcome.**

- Refusals run **before the first intent is written**, so a refused run leaves no journal trace: draft,
  root-requiring, protected port, never-list, and a pid in Curfew's own ancestry (via `proc_pidinfo`).
- A service that was **already stopped** is recorded as `preExisting` and never started by `resume`
  (rule 6).
- A failed post-condition stops the run — the next entry may depend on the one that did not stop.
- `hold: bootoutIfRespawned` journals a *second* intent when launchd brings the job back.
- `apply` is a dry run unless `--execute`, and `--execute` refuses without `--yes` when stdout is not a
  TTY. Verified live: the piped invocation exits 4 with the reason.

**The runner and all three probes are injected**, which is what made the ordering testable: a fake
runner reads the journal *at call time* and fails the test if the intent is absent.
`noShell` passes `["/bin/echo", "a; rm -rf /", "b\c", "$(whoami)"]` through and asserts it arrives as
four literal arguments.

**16 new tests; 120 total in 17 suites, green.** Nothing mutating has been executed against a live
service — the first `--execute` is the owner's, on `vendor-noise`, with the journal open.

## Round 6 — L3.5, the crash test

Plan-less atom, two levels:

- **`CrashRecoveryTests`** (4): builds the post-crash artefact byte-for-byte — intents with no outcomes,
  finishing mid-record — and drives the real `resume`. Asserts reverse order, idempotency, and that a
  pre-existing stop survives the crash unstarted.
- **`scripts/crash-test.sh`**: SIGKILLs a live `curfew apply --execute` between the intent and its
  outcome, then asserts recovery. Stops nothing real (`/bin/sleep 5`, `/usr/bin/true`).

**It found two real defects**, both fixed:

1. **`resume` never closed the intent it answered** (KI-027). After a successful restore the journal
   still read as "holding that stop", so a second `resume` re-ran the start recipe — a recovery that is
   not idempotent is a recovery you cannot trust.
2. **A failed launch reported `exited -1` with no reason** (KI-028), because the catch branch lost the
   error text.

And one harness bug of my own (KI-029): `/bin/true` does not exist on macOS 26 — the harness assumed it.
A test binary has to be checked, not assumed.

The script also needed fixing: it killed after a fixed one second, but the executor spends ~1.2 s on the
inventory before writing anything, so it was killing before the intent existed. It now polls for the
intent — which means the test asserts the actual window rather than a timing guess.

**4 new unit tests + the live script; 124 total in 18 suites, green.**

## Round 7 — L3.2 begins, and an incident worth recording

Verified two vendor entries end to end by hand, then recorded the result as `verified` with dated
evidence:

- `us.zoom.updater` — disable → `print-disabled` says disabled; bootout → label unloaded;
  enable + bootstrap → loaded, `state not running`.
- `com.microsoft.OneDriveStandaloneUpdater` — the same cycle, same result.

**The incident (KI-030).** My first attempt at the Zoom recipe used a **guessed plist path**
(`~/Library/LaunchAgents/us.zoom.updater.plist`). The stop half worked. The start half could not —
the job actually lives in `/Library/LaunchAgents/` — so a live updater sat unloaded while I worked out
why. It took three probes to find, and the fix was to read the path `launchctl print` reports.

That produced a schema change rather than a note: recipes now take **`{plist}`**, resolved from the
inventory's own `path =`, and a recipe that needs it without one is refused. A restore recipe must not
contain a path the author remembered.

Two smaller findings: `bootout`'s failure was masked by a pipe in my probe (KI-031 — the same trap as
fleet's KI-014), and the catalog named a label that isn't loaded on this machine (KI-032). The
validator also caught the stale bundle member once the entry was replaced, which is the ledger doing
its job.

**`apply --bundle vendor-noise` now plans two real steps instead of refusing two drafts**, and
`catalog plan` prints the exact argv. Nine entries remain `draft`.

## Round 8 — committed, and the privileged boundary designed

**First commit: `a5a5846`**, 86 files, clean tree. After eight rounds of work with no history, that was
the most expensive debt in the project.

Then L4 began, and the first thing it needed was a decision rather than code:

**D20 — the helper is a catalog executor, not a command executor.** It accepts `{entryId, action,
intentSeq}` and never argv; it loads the catalog itself and re-decides everything. A helper that runs
client argv is a root shell with extra steps, and every client-identity bug then becomes a
privilege-escalation bug. With D20 the worst a compromised client can do is ask for an operation that
was already reviewed, dated and recorded — and `noArgvOnTheWire` asserts the wire cannot carry argv.

What is proven without a signing identity:

- `HelperPolicy.decide` — 9 tests: unsigned caller, foreign Team ID, draft entry, never-list label,
  non-root recipe, unknown entry, missing recipe, and the allow case returning **the catalog's argv**.
- `PrivilegedTransport` — the executor delegates a `needsRoot` entry through one closure, so the
  delegation is testable without XPC or root: 5 tests covering intent-before-request, a helper refusal
  closing the journal entry, a helper failure stopping the run, and a dry run never contacting it.
- The planner gained `helperAvailable`, because "what would happen" depends on whether a helper exists —
  without one, a root recipe is exactly as unavailable as a draft one.

What is not built, and cannot be from here: the `curfew-helper` daemon target, the `NSXPCListener`, the
`SecCodeCheckValidity` call, and `SMAppService.daemon` registration. All four need a signed bundle with a
Team ID.

**5 new tests; 138 total in 20 suites, green.** The ledger checker also caught a broken seam on the way
in — C12 expected `Catalog::entry`, which C9 never offered — which is the contract discipline doing
exactly what it is for.

## Round 9 — L5.1, the first face

`curfew tui` — a dashboard over the same engine: services, findings, the current bundle, and the
quiet-mode banner on every frame.

Split three ways so the screen is testable without a terminal: `TUIState` (pure), `TUIRenderer`
(state → text), `TUILoop` (bytes). **The TUI cannot act** — no runner, no transport; `a` previews, and
`apply --execute` stays a CLI act with `--yes`.

**Rendering it against the live machine found three defects in the first frame**, all fixed:

1. The header ran together — `gui/501quiet mode: off` — because the title was truncated but not padded.
2. The list was dominated by `application.*` rows: running GUI instances are not services anyone manages
   (D0). They are now excluded, and both they and protected-tier jobs are *counted* in the footer rather
   than silently dropped.
3. Long ids overflowed their column and pushed the state out of alignment.

`--frame` exists because of that exercise: it prints one screen and exits, and a non-TTY stdin does the
same automatically — so the screen can be read from a script, which is how it was verified.

**11 new tests; 149 total in 21 suites, green.**

## Round 10 — the scope correction that deleted a layer

"An internal tool for my use, not a commercial app." That one sentence removed the largest remaining
blocker and four atoms with it.

**D21 — privilege comes from `sudo`, not from a signed daemon.** `SMAppService`, XPC and
code-signature validation exist so a *distributed* app can be trusted with root. For one person on one
machine, `sudo` does that, and it deletes a $99/year membership, a certificate, a daemon, a wire
protocol and a registration prompt.

The property worth keeping survived: **as root, the executor still runs only verified, cataloged,
root-requiring recipes.** `SudoPrivilegeTests` (6) proves root refuses a draft entry and a never-list
label, so root is never a licence to run something the catalog has not reviewed.

One trap fell out of it, and it would have been silent: under `sudo` the effective uid is 0 and
`gui/0` does not exist — enumerating it reports an empty machine. `Domain.effective` resolves
`gui/$SUDO_UID`, with a test for both branches.

Dropped: L4.1 (daemon), L4.2 (XPC), L6.1 (signing/notarisation), L6.2 (cask). Added: L6.3,
`make install` to `~/.local/bin` plus `make check` as the single gate. Hard rule 10 lost its
"releases are notarised" half.

**6 new tests; 155 total in 22 suites.** `make check` runs tests, ledgers, catalog validation and the
crash test in one command.

**`CLAUDE.local.md` changed and leaves no git trace:** the "Signing and notarisation" section is
replaced by a "Privilege — no signing required" section, and the environment table no longer claims a
notarised release.

## Criteria status

All met except two, **deliberately revised** (recorded in the plan, not silently dropped):

1. *"marks `pampa-dev-postgres`'s supervisor as `container`"* — pampa is a Kiri container, not a
   launchd job, so it never appears in a launchd inventory. The criterion presumed otherwise;
   container-aware inventory is out of v1 scope (KI-004).
2. *"reports `~/.local/bin/node` as `danglingProgram`"* — nothing references that symlink any more,
   because the jobs that did were removed earlier in the same session (KI-001). The rule is proven
   by fixture instead.

## Ledger changes

- **Known issues:** +6 (`KI-019`…`KI-024`) — all found by building, all closed: the sandboxed
  SwiftPM build, app-child `path` descriptions, witr's empty `Exe`, nil-omission in `Codable`, the
  stale exit code on a running job, and the 36 s serial sweep.
- **Decomposition:** L0.1–L2.2 → `done`; one atom added, **L1.10** (listener scan for `orphanPort`
  and `noSupervisor`), still `planned`.
- **Contracts:** C7 gained the omission rule and the exit-code table is now normative; `Contracts.swift`
  moved the JSON shapes into the kit so they are testable.
- **Decisions:** no new `D`; the slice implemented D1–D18 as written.

## Deferred debts

- **L1.10** — the listener scan (`orphanPort`, `noSupervisor`). The PG14 case that motivated it is
  already fixed by hand.
- **`FUNCTIONAL-SPECIFICATIONS.md`** is still scaffolding: §2 Modes, §3 Core Features and §7 Edge
  Cases need the read-only behaviour written in before the mutating plans start.
- **The repo has no commits.** Everything above is untracked. The first commit is the owner's.
- Apple Tier-2 enabling remains a catalog file for a later plan (D0, D9).

## Next session

Start with `/warmup`, then either L1.10 (small, closes the findings table) or draft plan 2 —
catalog schema and never-list — since that is the gate in front of every mutating atom.
