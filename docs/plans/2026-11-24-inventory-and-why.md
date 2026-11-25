---
status: completed
created: 2026-11-24
updated: 2026-11-24
slug: inventory-and-why
---

# Plan — `curfew list`, `curfew why`, `curfew doctor` (witr as the causality engine)

## Context

Curfew's first shippable slice is the read-only half: enumerate what is running, classify it, say why
it is running, and find the things that are broken but invisible. It performs **no mutation** — no
suspend, no stop, no journal. That is deliberate: it lets the tool earn trust before it is allowed to
touch anything.

Two events shaped this plan:

1. Three crash loops were found on this machine on 2026-11-24 (255,645 / 255,646 / 82,103 runs). All
   three were invisible to every process tool because **a crash-looping job has no PID**.
2. `witr` (Apache-2.0, v0.3.4, 23.4k stars, stable `--json` contract) already answers "why is this
   running" for live processes better than anything we would build — ancestry, launchd source with the
   plist path, trigger, `KeepAlive`, sockets, cwd, git branch, warnings.

So the division is settled by evidence, not preference: **launchd is the truth for job state, witr is
the truth for process causality, and Curfew owns the join, the classification, and the verdicts.**
Neither source can produce the crash-loop finding alone.

## Audit — what already exists

| Thing | State |
|---|---|
| `Package.swift`, `Sources/`, `Tests/` | **do not exist** — greenfield |
| `docs/architecture/blueprint.md` | the design of record; §3 lever model, §6 hazards, §7 code consequences |
| `docs/research/core-os-services.md` | tier classification + 28-label never-list, ready to encode |
| `docs/research/harness-mcp-deps.md` | which services are load-bearing for DSH/Zcode |
| `witr` binary | **installed** at `/opt/homebrew/bin/witr` v0.3.4 — verified on this machine |
| witr JSON shape | **verified live**: `Target`, `ResolvedTarget`, `Process{PID,PPID,Command,Cmdline,Exe,StartedAt,User,CPUPercent,MemoryRSS,MemoryPercent,WorkingDir,GitRepo,GitBranch,Container}`, `RestartCount`, `Ancestry`, `Source{Type,Name}`, `Warnings`, `SocketInfo`, `ResourceContext`, `FileContext` |
| witr's blind spot | **verified**: `witr model-router` → `no running process or service named "model-router"` while launchd showed `runs = 255645` |
| witr container support | **verified broken here**: `witr --container pampa-dev-postgres` → not found (Kiri is not a recognised runtime) |

## What we are doing

- **`curfew list`** — enumerate every launchd job in `gui/$UID` and `system`, merge in the plist
  metadata, and classify each as tier / kind / vendor vs dev / supervised vs unsupervised.
- **`curfew why <target>`** — accept a PID, a port, or a launchd label. For live targets, enrich with
  `witr --json`. For a label with no live process, answer from `launchctl` and say why it is not running
  (crash loop, failed exec, disabled, never started).
- **`curfew doctor`** — the health scan: crash loops, orphans holding a port, dangling program paths,
  loaded jobs whose plist no longer exists, and never-list violations in the catalog-to-be.
- **A disagreement policy with a durable log** — when launchd and witr disagree, resolve to the safe
  reading, never to "nothing here", and append a rate-limited JSONL record so the disagreement can be
  triaged later against both sources and both versions.
- **`--json` on all three**, with a versioned shape and documented exit codes.
- **A read-only guarantee test** that fails if any command invokes a mutating verb.

## What we are NOT doing

- **No mutation of any kind.** No `bootout`, `bootstrap`, `disable`, `kill`, `tmutil`, `mdutil`. The
  binary has no code path that writes to a service.
- No helper, no XPC, no `SMAppService`, no notarisation.
- No menu bar, no TUI yet.
- No catalog recipes (`catalog/*.yaml` with stop/start) — that is the next plan.
- No Apple Tier-2 agent support; the tier is *reported*, never acted on.
- No vendoring or shadowing of witr. It is an optional external binary.
- No container-engine support. Verified that witr cannot see Kiri; we are not going to fix that here.

## Approach

### 1. One record, two sources

```swift
struct ServiceRecord {
  // launchd truth
  var label: String
  var domain: Domain            // .gui(uid), .system
  var plistPath: String?
  var state: JobState           // .running(pid), .spawnScheduled, .notLoaded, .disabled
  var runs: Int?
  var lastExitCode: Int?        // 78 == EX_CONFIG
  var program: String?          // first ProgramArguments element
  var keepAlive: KeepAliveMode  // true / dictionary / false
  // classification
  var tier: Tier                // .protected, .osCore, .appleAgent, .thirdParty
  var kind: Kind                // .daemon, .agent, .appChild, .container, .inProcess, .command
  var vendor: String?
  // witr enrichment (nil when not running, or witr absent)
  var process: ProcessFacts?    // PID, ancestry, sockets, cwd, git, CPU/RSS, warnings
  // findings
  var findings: [Finding]
}
```

`launchctl print gui/$UID` gives label, pid, state, runs, last exit, program, arguments, plist path.
The parser reads the `services = {` table for labels and then `launchctl print <domain>/<label>` **only
for candidates** (third-party + anything with `runs > threshold`), because a full per-job print is
hundreds of subprocess calls.

### 2. Findings are the product, not the listing

| Finding | Rule | Why it matters |
|---|---|---|
| `crashLoop` | `runs > 1000 && lastExit != 0` | the failure class nothing else sees |
| `execFailure` | `lastExit == 78` | `EX_CONFIG` means launchd could not exec the program |
| `danglingProgram` | `program` path does not resolve (symlink target missing) | **the root cause of two loops today** |
| `orphanPort` | a port is bound but its owning job is not running | the PG14 case |
| `stalePlist` | job loaded, `plistPath` gone | edited then deleted |
| `notLoadedButDisabled` | label disabled in the disabled-db | explains a silent no-op |
| `noSupervisor` | third-party process with no launchd job and no known parent | the `kanzo` class |
| `runsFromTmpOrRoot` | cwd is `/`, `/tmp`, `/var/tmp` | from witr's warnings, promoted to a finding |

### 3. witr integration rules

- **Optional, never required.** `list` and `doctor` work without it; `why` degrades with a clear message
  and exit 3. It is a dependency of *value*, not of function.
- **Invoke with argv, never a shell string.** `["/opt/homebrew/bin/witr", "--json", "--pid", "\(pid)"]`.
- **Never trust exit code alone.** Documented behaviour: it exits 0 through a pipe when it cannot read a
  process, and prints `Error` in JSON for a failed lookup. Parse the JSON, check `Error`, and always
  cross-check against `launchctl`.
- **Version gate.** Require `witr >= 0.3.4`; on unknown version, warn and continue (its JSON contract is
  additive).
- **`--why` for a dead label must not call witr.** Verified: witr reports "not found" for a
  crash-looping job. Answer from launchd and say so in the output.

### 4. Read-only guarantee

A test that constructs a `PATH` containing shims for `bootout`, `bootstrap`, `disable`, `enable`,
`kill`, `tmutil`, `mdutil`, each of which writes a marker file, then runs every command against
fixtures and asserts no marker exists. This is the mechanical proof of hard rule 3, and it is cheap.

### 5. Fixture-driven tests, not live-machine tests

Capture real `launchctl print` output and real `witr --json` output into `Tests/Fixtures/` (redacted,
with a header naming the macOS and witr version that produced them). The 2026-11-24 capture already
exists in this session's transcript and can be regenerated on demand by a script. Tests parse fixtures.
Live-machine checks belong in `doctor`, not in the suite.

## Decisions (ratified by the owner, 2026-11-24)

The choices themselves live in the ledger — **D0–D19** in
[`CURFEW-DESIGN-DECISIONS.md`](CURFEW-DESIGN-DECISIONS.md); their limits and the defects behind them live
in [`../known-issues.md`](../known-issues.md). This section keeps only the measurements that settled them
and the consequences specific to this plan.

| Measurement | Value | Decision it settled |
|---|---|---|
| one `launchctl print` | 4.5 ms (20 calls in 89 ms) → 282 jobs ≈ 1.3 s serial, ~200 ms at concurrency 8 | D3: a full sweep, no candidate selection |
| `launchctl print system/com.apple.securityd` as uid 501 | `state`, `runs`, `pid`, `last exit` all readable | D4: include the system domain |
| processes named `postgres` | 3, across two clusters and a container | D6: the label is the identity |
| `LaunchEvents`-driven system plists | 453 of 887 | D7: the crash-loop rule needs all three clauses |
| `witr` on a job at 255,645 runs | "no running process or service named" | D2: launchd owns job state |
| `witr` through a pipe when it cannot read a process | exit **0** | D5: never trust its exit code alone |
| `witr --container pampa-dev-postgres` | not found (Kiri unrecognised) | container support is out of v1 (KI-004) |

Plan-specific consequences: `list --json` carries `scan.complete` because a missing field must never read
as healthy, and `why` must answer a dead label from launchd rather than forwarding it to witr — the case
witr cannot see at all.

## Disagreement policy (owner instruction, 2026-11-24)

> "on disagreement take the safe path and log so that we can do additional triage of the component
> that's causing the disagreement"

**The safe path is always the conclusion that preserves "possibly running / possibly needed".** The
failure mode this product must never produce is a false clean, so no disagreement may ever resolve to
"nothing here".

| # | Disagreement | Safe conclusion | Never conclude | Kind |
|---|---|---|---|---|
| D-1 | launchd has a pid; witr cannot see it | `running`, enrichment unavailable | "not running" | `enrichMissing` |
| D-2 | launchd says stopped; witr sees a matching process | treat as running/unmanaged | "safe to start" | `unmanagedProcess` |
| D-3 | the two sources report different pids | launchd's pid wins; record flagged, no action | act on either | `identityConflict` |
| D-4 | a process exists with no launchd job | `unmanaged`, lever `none` in v1 | "safe to stop" | `unmanagedProcess` |
| D-5 | `program` (launchd) ≠ `Exe` (witr) | keep both, flag for triage | normalize silently | `execPathConflict` |
| D-6 | a port is claimed by only one source | attribute to neither; show both claims | assign it to a job | `portOwnerConflict` |
| D-7 | witr JSON is missing required fields | `degraded`; scan marked incomplete | "clean" | `witrinvalid` |

**Any run that logged a disagreement marks the scan incomplete in its own output**, so `doctor` can never
report "no findings" for a scan that did not fully see.

### The disagreement log

Append-only JSONL at `~/Library/Logs/Curfew/disagreements.jsonl`:

```json
{"v":1,"ts":"2026-11-24T21:40:12.301Z","curfew":"0.1.0","macos":"26.5.2","witr":"0.3.4",
 "kind":"execPathConflict","fingerprint":"sha1:9f2c…",
 "target":{"label":"com.adelvillar1.sem1-llama","pid":27468,"port":8901},
 "launchd":{"program":"/Users/…/llama-server","state":"running","runs":11,"lastExit":null},
 "witr":{"exe":"/Users/…/llama-server","sourceType":"launchd","pid":27468},
 "verdict":{"state":"running","enrichment":"ok","action":"none"},
 "note":"program path differs only by symlink resolution"}
```

Rules:

- **Rate-limited by `fingerprint`** (hash of kind + target + the distinguishing values): at most one line
  per fingerprint per 10 minutes, with a suppressed count flushed on the next write. A persistent mismatch
  must not fill the disk, and the count is the triage signal.
- **Rotate at 5 MB, keep 3 files.** Unbounded logs are how `router.log` reached 94 MB today.
- **No secrets, ever.** Never log env values; never log a full argv — record `argc` and the basename
  only (a `--api-key=…` in argv is the obvious leak); strip credentials from any URL.
- **Local only.** v1 has no network path in the binary at all; there is nothing to opt out of because
  nothing leaves the machine.
- **Surfaced in the terminal, not just the file:** `curfew doctor --disagreements` prints counts by
  fingerprint with first-seen/last-seen, so triage starts where the user is already looking.
- Each line carries both sources' raw answers and both versions — the point is that a disagreement can be
  attributed to **launchd, witr, or Curfew** without re-running anything.

## Acceptance criteria

Verified 2026-11-24 on this machine (`swift test`: **57 tests, 10 suites, green**).

- [x] `swift build` and `swift test` succeed on macOS 26.5.2 with no external state.
- [x] `curfew list --json` emits one record per job in `gui/501` and `system`; on this machine that is
      **472 records** (47 third-party, 424 Apple, 1 protected).
- [x] ~~`curfew list` marks `pampa-dev-postgres`'s supervisor as `container`~~ — **revised**: `pampa` is a
      Kiri *container*, not a launchd job, so it cannot appear in a launchd inventory at all. The
      criterion presumed otherwise. The supervisory distinction it was testing is carried by D12 and
      the `Supervision` enum, and container-aware inventory is out of v1 scope (KI-004).
- [x] `curfew doctor` reports `danglingProgram` with the resolved target in the evidence, verified
      against the live machine (six such jobs, including `com.valvesoftware.steamclean`, whose Steam
      install is gone: `EX_CONFIG` + a program path that no longer exists).
- [x] `curfew doctor` reports **zero** `crashLoop` findings — true on this machine, and the rule keeps
      all three clauses (`runs > 1000`, `lastExit != 0`, uptime > 1h) so the 453 `LaunchEvents`-driven
      jobs cannot produce false positives.
- [x] ~~`doctor` reports `~/.local/bin/node` → `~/.hermes/node/bin/node` as `danglingProgram`~~ —
      **revised**: no launchd job references that symlink any more, because the jobs that did were
      removed earlier in the same session (KI-001). The rule that would have caught them is proven by
      fixture instead (`danglingProgram` names the target).
- [x] A witr `Error` payload on a running job records a `witrinvalid`/`enrichMissing` disagreement and
      marks the scan incomplete, so `doctor` exits 1 rather than reporting clean.
- [x] An `execPathConflict` keeps both paths and logs one line naming both sources and both versions.
- [x] 100 identical disagreements produce **one** line plus `suppressed: 99` (test: `rateLimit`).
- [x] The log contains no `argv`, no `env`, and no `--api-key` — structurally, because the record's
      fields are typed and `Env`/`Cmdline` are never decoded (test: `noArgvNoEnv`).
- [x] The log rotates and keeps exactly three rotated files (test: `rotation`).
- [x] `curfew doctor --disagreements` prints counts grouped by fingerprint with first/last seen.
- [x] No networking anywhere in `Sources/` (test: `NoNetworkTests.noNetworking`).
- [x] `curfew why --port 8901` prints `launchd (1) → llama-server (27468)`, the label, the plist and the
      socket, sourced from witr's `Ancestry` and `Source`.
- [x] `curfew why <label>` for a dead job exits 2 and names `runs` and `last exit` on stderr.
- [x] With `witr` absent (`CURFEW_WITR_PATH=`), `list` still works and `why` exits 3 naming
      `brew install witr`.
- [x] `ReadOnlyGuaranteeTests` passes: shimmed `launchctl bootout`, `kill`, `tmutil`, `mdutil`, `brew`,
      `kiri` and `podman` are never invoked by a full inventory run.
- [x] The CLI and JSON contract are documented in `TECHNICAL-DOCUMENTATION.md` §5 with the stability
      guarantee, including the omission rule for nil fields.

**Not done, deliberately** (recorded as atoms and issues rather than silently dropped):
`orphanPort` / `noSupervisor` need a listener scan and land with L1.10; Apple Tier-2 enabling is a
catalog file, not this slice (D0).

## Files to be touched

```
Package.swift
Sources/CurfewKit/ServiceRecord.swift
Sources/CurfewKit/Domain.swift
Sources/CurfewKit/LaunchdInventory.swift      # parse `launchctl print`, per-job enrichment
Sources/CurfewKit/Classification.swift        # tier, kind, vendor, supervised
Sources/CurfewKit/NeverList.swift             # compiled; 28 labels from core-os-services.md
Sources/CurfewKit/Findings.swift              # the finding rules + verdicts
Sources/CurfewKit/DisagreementLog.swift       # JSONL append, fingerprint rate-limit, rotation
Sources/CurfewKit/WitrClient.swift            # spawn, parse, version gate, degrade
Sources/curfew/main.swift                     # argument parser wiring
Sources/curfew/Commands/List.swift
Sources/curfew/Commands/Why.swift
Sources/curfew/Commands/Doctor.swift
Tests/CurfewKitTests/{LaunchdInventoryTests,ClassificationTests,FindingsTests,WitrClientTests}.swift
Tests/CurfewKitTests/DisagreementLogTests.swift
Tests/CurfewTests/ReadOnlyGuaranteeTests.swift
Tests/Fixtures/launchctl-gui-501-macos-26.5.2.txt
Tests/Fixtures/launchctl-system-macos-26.5.2.txt
Tests/Fixtures/witr-port-8901-macos-26.5.2.json
Tests/Fixtures/witr-crashloop-label.json
docs/architecture/blueprint.md                # §9 plan list updated
TECHNICAL-DOCUMENTATION.md                    # §5 CLI contract, §4 catalog kinds
```

## Rollout order

1. **Skeleton + `ServiceRecord` + launchd parser** against fixtures. No witr, no commands.
2. **Classification** (tier/kind/vendor/supervised) + `NeverList` compiled with a test that it contains
   every label from `docs/research/core-os-services.md` §4.
3. **Findings engine** — crash loop, exec failure, dangling program, orphan port, stale plist, no
   supervisor. Pure functions over `ServiceRecord`.
4. **Disagreement log + policy** — the seven kinds, the safe-path table, fingerprint rate-limiting,
   rotation, redaction. Lands *before* witr because field-level disagreements already exist at the parser
   (a missing `runs` is a disagreement between the parser and reality).
5. **`curfew list`** + `--json`. First command that runs live.
6. **`WitrClient`** — spawn, parse, version gate, degrade, log the D-1/D-3/D-5/D-7 kinds. `curfew why`.
7. **`curfew doctor`** — the findings over the whole machine, plist-path and port cross-checks, and
   `--disagreements` for triage.
8. **Read-only guarantee test**, the no-network assertion, then the CLI contract in
   `TECHNICAL-DOCUMENTATION.md`.

## Open questions

None blocking. Everything above is decided; the remaining gate is the owner's "go".

## Verification

```bash
swift build && swift test
swift run curfew list | head -40
swift run curfew list --json | jq '.[] | select(.tier=="thirdParty") | .label' | wc -l
swift run curfew doctor
swift run curfew why --port 8901
PATH=/usr/bin:/bin swift run curfew list          # must still work with witr absent
```

## Linked artifacts

- `docs/architecture/blueprint.md` §3, §6, §7 — the model this implements
- `docs/research/core-os-services.md` §4 — the never-list source
- `docs/research/harness-mcp-deps.md` — load-bearing services for `harness-core`
- `docs/TROUBLESHOOTING.md` — the three 2026-11-24 crash loops are the test cases
- `TECHNICAL-DOCUMENTATION.md` §5 — CLI/JSON contract to be written on completion
