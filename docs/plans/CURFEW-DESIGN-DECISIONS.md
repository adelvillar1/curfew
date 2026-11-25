# Curfew — the design-decisions ledger

**The awareness backbone.** Every plan **reads the choices settled below it** (citing their `D` ids) and **appends its own** when drafted. A plan that contradicts a settled choice is wrong by construction — this ledger is what keeps the stack from diverging when plans are drafted in fresh sessions.

Its three siblings complete the picture: [`CURFEW-DECOMPOSITION.md`](CURFEW-DECOMPOSITION.md) records the **atoms** (the build map), [`CURFEW-CONTRACTS.md`](CURFEW-CONTRACTS.md) records the **interfaces** (what each module offers/expects), and [`../known-issues.md`](../known-issues.md) records what is broken.

Rules:
- `D` ids are **stable and never reused or reordered**; upper layers cite them. A choice is superseded only by a new `D` that names the old one and says why.
- A choice is **settled** when its plan is approved by the owner. Until then it is *proposed*.
- Each entry states the decision, the rationale, and **what it constrains**.

---

## Product boundary

- **D0 — Curfew's surface is the third-party service layer, plus opt-in Apple Tier-2 agents. Tier 0/1 is unreachable and unlisted.**
  Rationale: SIP protects the system plists, so "suspend everything that is not macOS" is not an available product; and the measured value is in the 35 third-party jobs, ~30 of which are vendor updaters. *Constrains:* every catalog, every bundle, the TUI vocabulary.

- **D1 — v1 is read-only: inventory, causality, diagnosis. Mutation ships only after the read-only slice is trusted.**
  Rationale: trust here is binary — one database stopped mid-write ends the product. The read-only slice is also independently useful and independently sellable (it finds crash loops). *Constrains:* L1/L2 atoms; the absence of any mutating call in the v1 binary; the read-only guarantee test.

## Sources of truth

- **D2 — Two sources, split by competence: launchd is the truth for job state, witr is the truth for process causality, and Curfew owns the join.**
  Rationale: measured, not assumed — `witr` reports "not found" for a job at 255,645 runs (no PID), while `launchctl print` has no process ancestry, sockets, cwd or git context. Neither alone answers the question. *Constrains:* `LaunchdInventory`, `WitrClient`, the `ServiceRecord` merge, the `why` command's fallback path.

- **D3 — Tolerant parse of `launchctl print`, strict on field presence; a missing field is never reported as healthy.**
  Rationale: a strict parser makes the diagnostic tool unusable exactly when the machine misbehaves; a fully tolerant one lets `runs = nil` read as "0 loops", which is a false clean — the one outcome this product must never produce. *Constrains:* parser, findings verdicts, `doctor`'s "scan incomplete" output, the per-version fixture gate.

- **D4 — The `system` domain is included, read-only; enrichment of root-owned jobs degrades and is reported as a visibility gap, never as a finding.**
  Rationale: measured — `launchctl print system/com.apple.securityd` as uid 501 returns `state`, `runs`, `pid`, `last exit`. Job state needs no privilege; only witr's enrichment does. Excluding the domain would hide 11 vendor daemons and 7 agents. *Constrains:* enumeration scope, the `enrichmentUnavailable` state, `doctor`'s reporting vocabulary.

- **D5 — `witr` is an optional external dependency: floor `>= 0.3.4`, no upper pin, runtime shape validation, and its exit code is never trusted alone.**
  Rationale: upstream's JSON contract is additive and field-pinned by their own tests, so pinning would break on every release for nothing; but Homebrew can upgrade it silently, and it exits **0** through a pipe when it cannot read a process (KI-005). *Constrains:* `WitrClient`'s parse path, the degraded mode, the version echoed in `--json` and `doctor`.

## Identity and classification

- **D6 — The launchd label is the canonical identity; the process name is a display attribute. Unmanaged processes get a synthesized id.**
  Rationale: three processes named `postgres` listen here under two labels plus a container (KI-013); every future action addresses a label, never a name; witr's own name matching is substring-based by design. *Constrains:* `ServiceRecord.id`, CLI arguments (accept many, emit one), the TUI's display rule.

- **D9 — The never-list is compiled code, not configuration.**
  Rationale: a config file implies "power users may edit it", and that is how a tool bricks a machine. *Constrains:* `NeverList.swift`, the test that every label in the research doc resolves, the absence of a `--force` escape hatch.

## Verdicts

- **D7 — A crash loop requires all three: `runs > 1000`, `lastExit != 0`, and loaded for more than one hour.**
  Rationale: 453 of 887 system plists are `LaunchEvents`-driven and accumulate `runs` legitimately (KI-007); without the exit-code clause the detector reports ~200 false positives on day one, and a detector that cries wolf is worse than none. *Constrains:* the findings rule, its fixtures, `doctor` severity mapping.

- **D8 — On disagreement between sources, conclude the safe reading (never "nothing here") and log the evidence from both sources for later triage.**
  Rationale: owner instruction, 2026-11-24. The failure mode is a false clean; a disagreement is also the only signal that one of the two sources is wrong, so it must be attributable to launchd, witr, or Curfew without re-running anything. *Constrains:* the seven disagreement kinds, the JSONL log schema, "a scan that logged a disagreement is incomplete", rate-limiting by fingerprint.

## Levers (mutation, later layers)

- **D10 — `SIGSTOP` is for GUI apps with no listening socket. A frozen server is a hang, not an error.**
  Rationale: 733 of 887 system plists register a `MachServices` port; a frozen server keeps its port, so clients block with no timeout. The bridge's `kanzoPost` has no timeout at all — a frozen Kanzo is indistinguishable from a slow one. *Constrains:* hard rule 4, the catalog's lever validation, the executor's refusal path.

- **D11 — The lever is a property of the service, not a user preference: `freeze | stop | disable | throttle | command`.**
  Rationale: Spotlight's correct lever is `mdutil`, Time Machine's is `tmutil`, Postgres's is `pg_ctl stop -m fast` — none of which is a launchd verb. *Constrains:* the catalog schema, the executor, the dry-run preview's vocabulary.

- **D12 — Reversibility is a property of the supervisor (`launchd | app-parent | none`), not of the service.**
  Rationale: `kanzo` has no launchd job, so a stop is a one-way door until a human restarts it; the five MCP servers are children of the harness and must never be signalled individually. A `none` entry without a recorded restart command is invalid. *Constrains:* catalog validation, the executor's refusal for unsupervised entries, the dry-run's warnings.

- **D13 — A container-engine deletion is a VM-side win; host and VM reclaim are reported separately and never summed.**
  Rationale: measured — pruning 17 GB inside Kiri left `data.img` at 23 GB because its disk refuses discard (KI-009). Claiming host space for a container prune is a lie the user can check with `df`. *Constrains:* the reclaim report, the `containers-idle` bundle's description, any "GB reclaimed" headline.

- **D14 — In-process engines are `never-cold`, not suspend candidates.**
  Rationale: Laya has no port and no process to signal; its cost is a **180 s** reload on the next sys1 call. A quiet mode that frees 2 GB and adds three minutes is a net loss the user must be told about before choosing it. *Constrains:* the `never-cold` anti-bundle, the catalog's `in-process` kind, the cold-start field.

## Engineering

- **D15 — Swift 6 + Swift Package Manager; one engine (`CurfewKit`) with thin front ends. No Electron.**
  Rationale: a memory-reclaiming tool cannot park 300–600 MB of Chromium; the native helper exists either way, so Electron adds a boundary without removing work. *Constrains:* package layout, the CLI/TUI/menu-bar split, the dependency budget.

- **D16 — The helper owns journal state; front ends are stateless views.**
  Rationale: if the process that stopped twenty services is also the process that dies, nothing restores them. *Constrains:* L4 atoms, the `status` command reading from the helper, fail-open restore.

- **D17 — Not sandboxed, not on the Mac App Store; Developer ID + notarisation.**
  Rationale: a sandboxed app cannot drive `launchctl` against arbitrary services, and App Review rejects daemons with this reach. *Constrains:* signing, the cask, the release checklist.

- **D18 — No argv and no environment values in any log; v1 has no network path at all.**
  Rationale: `--api-key=…` in argv is the obvious leak, and a diagnostic tool that reads every plist on the machine is exactly the wrong place to be sloppy. "Nothing leaves the machine" is enforceable only if there is no networking code. *Constrains:* the disagreement log's fields, the redaction test, the no-network assertion.

- **D19 — The ledgers are the record: a plan that contradicts a settled `D` is wrong by construction, and a ledger change is policed before it is committed.**
  Rationale: `/skill:project-methodology`'s ledger discipline — stable ids, append don't rewrite, close with evidence, one home per fact. *Constrains:* every plan's citation duty, `scripts/ledger_check.py` in the recap loop.
