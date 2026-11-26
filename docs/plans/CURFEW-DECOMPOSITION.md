# Curfew — the decomposition ledger (the build map)

**The atoms.** One row per smallest coherent, buildable, verifiable increment — each with its own surface and its own test. An atom that needs two surfaces or two unrelated tests is two atoms.

Every atom traces four ways: **atom → plan** (where it is built), **atom → contract** (the interface it implements, `C` ids), **atom → choices** (the `D` ids that bind it), **atom → atoms** (its dependencies). Status: `planned → drafted → building → done`.

Siblings: [`CURFEW-DESIGN-DECISIONS.md`](CURFEW-DESIGN-DECISIONS.md) (the choices), [`CURFEW-CONTRACTS.md`](CURFEW-CONTRACTS.md) (the seams), [`../known-issues.md`](../known-issues.md) (what is broken).

**27 atoms across 7 layers: 21 done, 4 dropped by D21, 2 planned.** L0 + L1 + L2 shipped 2026-11-24 (read-only slice, 57 tests); L3–L6 are the map, not a commitment.

---

## L0 — Bedrock (4 atoms)

Everything above depends on these; they have no dependencies themselves.

| Atom | Builds | Depends | Choices | Status | Evidence |
|---|---|---|---|---|---|
| L0.1 | Package skeleton, `ServiceRecord`, the six enums, `SystemVersion` | — | D15 | done | `Package.swift`, `Sources/CurfewKit/ServiceRecord.swift` |
| L0.2 | `NeverList` compiled from the 28 research labels + process-name net, with the completeness test | L0.1 | D9 | done | `NeverList.swift`; `NeverListTests.completenessAgainstResearch` |
| L0.3 | Format fixture gate: `SystemVersion.formatFixture()` + the checked-in `launchctl print` fixtures | L0.1 | D3 | done | `LaunchdParser.swift`; `Tests/Fixtures/launchctl-*-macos-26.5.2.txt` |

## L1 — Read (the first shippable slice)

Plan: [`2026-11-24-inventory-and-why.md`](2026-11-24-inventory-and-why.md).

| Atom | Builds | Depends | Choices | Status | Evidence |
|---|---|---|---|---|---|
| L1.1 | Domain enumeration: tolerant scan of the `services = {` table, `gui/$UID` + `system` | L0.1, L0.3 | D3, D4 | done | `LaunchdParser.domainTable`; `domainTableFromFixture` |
| L1.2 | Per-label strict extraction: `runs`, `lastExitCode`, `pid`, `state`, `path`, `program`; absent → `nil` + `fieldUnavailable` | L1.1 | D3 | done | `LaunchdParser.jobDetail`; `detailFromFixture` |
| L1.3 | Classification: tier, kind, vendor, supervision, from label + plist + program path | L0.2, L1.2 | D0, D6, D12 | done | `Classification.swift`; `ClassificationTests` (5 tests) |
| L1.4 | Findings engine: seven rules as pure functions with injected clock and path resolver | L1.2, L0.2 | D3, D7 | done | `Findings.swift`; `FindingsTests` (13 tests) |
| L1.5 | `curfew list` + `--json` (the first command that runs live) | L1.1, L1.3 | D6 | done | `curfew list`; `ContractShapeTests.listShape` |
| L1.6 | `WitrClient`: spawn, parse, version gate, degrade; never trusts exit code | L2.1 | D2, D5 | done | `WitrClient.swift`; `WitrClientTests` (8 tests) |
| L1.7 | `curfew why`: accepts label/pid/port/name, resolves to one record, falls back to launchd for a dead job | L1.2, L1.6 | D2, D6 | done | `curfew why`; verified on `com.adelvillar1.sem1-llama` (ancestry 1 → 27468) |
| L1.8 | `curfew doctor` + `--disagreements`; scan completeness is part of the output | L1.4, L1.6, L2.1 | D3, D7, D8 | done | `curfew doctor`; 16 findings on 2026-11-24, scan marked incomplete |
| L1.9 | Read-only guarantee test (shimmed `PATH`) + no-network assertion | L1.5, L1.7, L1.8 | D1, D18 | done | `ReadOnlyGuaranteeTests`, `NoNetworkTests` |
| L1.10 | Listener scan: `orphanPort` (a port bound by a dead job's executable) and `noSupervisor` (aggregated) | L1.4, L1.2 | D2, D12 | done | `ListenerScan.swift`; `ListenerScanTests` (11); `curfew doctor` reports one aggregate on this machine |

## L2 — Record (the log and the published shapes)

| Atom | Builds | Depends | Choices | Status | Evidence |
|---|---|---|---|---|---|
| L2.1 | `DisagreementLog`: seven kinds, fingerprint rate-limit, 5 MB × 3 rotation, redaction | L0.1 | D8, D18 | done | `DisagreementLog.swift`; `DisagreementLogTests` (6 tests) |
| L2.2 | JSON contract: shape tests pinning `list`/`doctor` output and the exit-code table | L1.5, L1.8 | D19 | done | `Contracts.swift`; `ContractShapeTests` |

## L3 — Mutate (the first layer that changes the machine)

Plan 3 (executor + journal) is next; entries are verified *through* it.

> **Build-order correction, 2026-11-24.** The first draft of this layer had the order wrong, and the
> error is exactly what hard rule 2 exists to prevent: it put the journal *after* the executor, and it
> made the executor depend on catalog entries that can only be verified by running recipes. The
> corrected order is journal → executor → entries. Ids are identities and were not renumbered; their
> dependencies moved.

| Atom | Builds | Depends | Choices | Status | Evidence |
|---|---|---|---|---|---|
| L3.1 | Catalog schema (`catalog/*.yaml`) + loader + validation (lever, supervision, `evidence:`) | L1.3 | D11, D12 | done | `Catalog.swift`, `MiniYAML.swift`; `CatalogTests` (20); `curfew catalog validate` |
| L3.4 | Journal: write-ahead append, fail-open restore. **Before anything acts** (rule 2) | L0.1 | D16 | done | `Journal.swift`; `JournalTests` (7); `curfew status` reads it |
| L3.3 | Executor: freeze, stop, disable, throttle, command — dry-run first, journal before each action, quiesce probes, refusals. Root recipes delegate through `PrivilegedTransport`, and are refused when none is registered | L3.4, L3.1, L4.2 | D10, D11, D12, D20 | done | `Executor.swift`; `ExecutorTests` (16); `curfew apply` dry-run refuses every draft |
| L3.2 | Catalog entries for this machine: vendor-noise, dev-idle, data-services, harness-core, never-cold — each verified and dated | L3.3 | D11, D12, D14 | done | **19 entries, every one with a verdict, zero `draft`.** 13 acting (7 full-cycle, 6 disable-only, all dated on this host); 6 always-on by owner decision (D22, D24: postgres, sem1-llama, the Kanzo bridge, laya, watchman, ollama). `vendor-noise` plans 13 steps and refuses nothing |
| L3.5 | Crash test: `kill -9` mid-action; assert full restore | L3.3, L3.4 | D16 | done | `scripts/crash-test.sh` (SIGKILL between intent and outcome, resume restores, second resume is a no-op); `CrashRecoveryTests` (4) |

## L4 — Control (the privileged half)

| Atom | Builds | Depends | Choices | Status | Evidence |
|---|---|---|---|---|---|
| L4.1 | ~~Helper daemon via `SMAppService`~~ — **dropped by D21** | — | D21 | dropped | not built, deliberately: an internal tool takes root from `sudo`. The policy it was going to enforce is tested and still applies in-process |
| L4.2 | ~~XPC protocol + `SecCodeCheckValidity`~~ — **replaced by the in-process gate** | L4.1 | D21 | dropped | `HelperPolicy` survives as the gate; `SudoPrivilegeTests` proves root still refuses drafts and never-list labels |

## L5 — Faces (thin, stateless)

| Atom | Builds | Depends | Choices | Status | Evidence |
|---|---|---|---|---|---|
| L5.1 | TUI: list, bundle picker, preview, the persistent "quiet mode is ON" banner | L1.8 | D15, D0 | done | `TUI.swift`, `TUILoop.swift`; `TUITests` (11); `curfew tui --frame` renders live data |
| L5.2 | Menu bar: status item, quiet-mode indicator, restore, window | L1.8 | D15, D23, D30, D31 | done | `MenuBarModel.swift`, `curfew-menubar/`; `MenuBarModelTests` (11); `make app` builds a signed Curfew.app that launches. status item verified visually via cua-driver (A/B: glyph present while running, gone when quit; `○` clean, `◐ 1` with an intent). **Lives at `~/Applications/Curfew.app` with a login opener** (`make install-app`), catalogue sealed inside the bundle — it now survives a logout and starts correctly with `/` as its cwd (KI-037/038/039). **It can act:** `Start quiet mode…` leads the menu, previews a bundle per row, and names the protect sets (KI-043, D30) |

## L6 — Release

| Atom | Builds | Depends | Choices | Status | Evidence |
|---|---|---|---|---|---|
| L6.1 | ~~Signing, notarisation, DMG~~ — **dropped by D21** | — | D21 | dropped | nothing to distribute |
| L6.2 | ~~Homebrew cask~~ — **dropped by D21** | — | D21 | dropped | replaced by L6.3 |
| L6.3 | Install target: `make install` copies the release binary to `~/.local/bin`, `make test` and `make check` run the gates | L0.1 | D21 | done | `Makefile` |

---

## Build order and critical path

```
L0.1 → L0.3 → L1.1 → L1.2 → L1.4 → L1.5 → L1.8 → L1.9
                 ↘ L2.1 → L1.6 → L1.7 ↗
L3.1 → L3.2 → L3.3 → L3.4 → L3.5      (after L4.1/L4.2)
L4.1 → L4.2                            (parallel with L1; blocks L3.3)
```

## L7 — Model-assisted decisions

Plan `2026-11-25-jev-assisted-decisions.md`. The model proposes; the catalogue and the owner dispose
(D27). None of these atoms touches the refuse path.

| Atom | Builds | Depends | Choices | Status | Evidence |
|---|---|---|---|---|---|
| L7.1 | `JevClient` + `DecisionLog` + `ConfidencePolicy`: injected transport, the UA fix, the audit row, the decision cache | L6.3 | D27, D28 | done | `JevClient.swift`, `JevHTTPTransport.swift`, `DecisionLog.swift`; `JevClientTests` (14); the no-network invariant amended to one named file |
| L7.2 | `curfew catalog propose <label>`: structured state from the live record, companion nouls, floor, a draft entry that acts on nothing | L7.1, L3.1 | D27, D29 | done | `Propose.swift`, `curfew catalog propose [--all]`; `ProposeTests` (10). **Live on all 12 uncatalogued services: 8 infrastructure → protect, 2 stop, 2 review, 0 dangerous** (metadata alone had 2 dangerous) |
| L7.3 | Quiesce noul-screen in the executor, after every deterministic refusal, narrowing only, off by default | L7.1, L3.3 | D27, D29 | done | `QuiesceGate.swift`, the executor's gate block; `QuiesceGateTests` (11). Bands 0.65/0.35; `auto` means nobody is asked today (no entry declares a quiesce probe) |
| L7.4 | `curfew doctor --rank`: score ordering, labels untouched | L7.1, L1.4 | D27, D29 | done | `FindingsRanker.swift`; `FindingsRankerTests` (8). Live on 17 findings; isolated probe separates a crash loop (3.6) from a benign gap (1.0), but today's machine has nothing severe so the range is 0.6–2.1 and the tool prints that range rather than pretending |

**Critical path (longest dependency chain):**

`L0.1 → L0.3 → L1.1 → L1.2 → L1.4 → L1.8 → L1.9 → L3.1 → L3.2 → L3.3 → L3.4 → L3.5 → L6.1`

The bottleneck is **L1.2 → L1.4**: the parser's field extraction feeds every finding, so a parser that
reports `nil` where it should report a value silently disables the whole detector. That is why D3 makes
"unknown" a first-class outcome and why L1.2's test is the strictest in the slice.

## What is deliberately not an atom

- **The `system` domain's Apple daemons as suspend targets** — reported, never acted on (D0).
- **Container-engine support** (Kiri, podman) — vitr's container lookup is blind to Kiri (KI-004), and
  container levers are VM-side wins only (D13). Out of v1.
- **Apple Tier-2 agent enabling** — `apple-quiet` is opt-in per label with dated verification, and needs
  no atom of its own: it is a catalog file, not a code path.
- **Automatic/idle triggers** — a face-level feature (L5), not bedrock.

## Consistency

`Depends` names only defined atoms; `Choices` names only existing `D` ids; the atom count matches the plan set. Policed by `scripts/ledger_check.py`.

---

## L8 — The window, made readable (7 atoms · plan `2026-11-26-app-window-usability.md`)

The plan is the contract; each atom closes one of its criteria, and the criterion is the atom's evidence.
Status starts `planned`; an atom becomes `done` only when its criterion is verified from a capture.

| Atom | What it delivers | Depends on | Decisions | Status | Evidence |
|---|---|---|---|---|---|
| L8.1 | `Vocabulary.displayName(for:)` — a namespaced launchd label rendered as a name a person recognises, raw label kept on the detail line | — | D38 | done | closes C0 — `VocabularyTests.displayNames`, and the Services render shows names |
| L8.2 | Services: a header row naming the columns, and rows grouped by kind with counts | L8.1 | D31 | done | closes C1 — header row and `Agents · 443` grouping captured |
| L8.3 | Services: a search field inside the pane (not `.searchable`, which never renders here) filtering on name or raw label | L8.1, L8.2 | D31 | planned | closes C2 |
| L8.4 | Sort controls: Services by name, Apps by memory and by name, the choice held for the session | L8.2 | D31 | planned | closes C3 |
| L8.5 | Bundles: a quiet-mode banner with Restore; no disabled control without a visible reason | L8.4 | D30, D31 | done | closes C4 — banner with Restore captured while quiet is on |
| L8.6 | Landing pane fitted to a two-row Held list (≤40 pt above the footer) | L8.5 | D31 | done | closes C5 — window 292 pt, gap above the footer ≈33 pt |
| L8.7 | Help sheet (⌘?) defining held, protected and each finding kind; ⌘F focuses the pane's search | L8.6 | D31, D37 | planned | closes C6 and C7 |

