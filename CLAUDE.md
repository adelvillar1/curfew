# Curfew

> A macOS tool that puts the machine into a quiet, unattended-development state: suspend or stop every background service a build or agent run does not need, then restore them safely.
> Repo: https://gitea-gitea.opsh.io/synapticmomentum/curfew

**Machine-local facts, credentials, and the Gitea token live in `CLAUDE.local.md` (gitignored, auto-loaded alongside this file).** Read it before any operation that touches a live service, a credential, or a release.

---

## Hard rules (non-negotiable)

These are the rules that keep the tool from corrupting a database or stranding a machine. They are load-bearing; breaking one is a bug, not a style choice.

1. **Tier 0/1 services are untouchable.** The never-list lives in code (`Sources/CurfewKit/NeverList.swift`) and is guarded by a test. It is never configuration, never user-editable, never overridable by a flag. A change to it requires a plan and an explicit user decision.
2. **Journal before acting.** Every state change is written to the journal *before* the action runs, and the helper restores on start. No action without a journal entry. If the journal is unreadable, restore-and-exit beats guessing.
3. **Dry-run before any live change.** A bundle or mode that has never been applied on this machine must be previewed (`curfew apply --dry-run`) and its output read. "Easy mode" is not exempt.
4. **`SIGSTOP` is for GUI apps only.** Never freeze a service that holds a listening socket, an on-disk database, or a `MachServices` key — a frozen server hangs its clients instead of failing them. Databases get a clean stop recipe; on-demand XPC jobs are never touched.
5. **No catalog entry without a verified recipe.** Every service ships with a stop recipe, a start recipe, a quiesce probe, and an `evidence:` field recording when it was verified on a real machine. Unverified entries are `draft` and cannot be applied.
6. **Never resurrect what we did not stop.** Pre-existing state is recorded at apply time and preserved at restore time. A service the user had off stays off.
7. **Whitelist by ancestry, not by name.** The tool must never suspend its own process tree, the calling terminal, `sshd`, or the remote-access path (Tailscale). Walk the parent chain.
8. **No secrets in the catalog, the journal, or the logs.** No `sudo` inside a long-lived watcher; privileged work goes through the helper over XPC.
9. **Apple per-user agents are opt-in per label and never part of "easy mode."** They rot with every OS release. A label enters that list only with a dated verification note.
10. **`main` is the only branch, and there is no release pipeline.** This is an internal tool for one user (D21): no notarisation, no Homebrew cask, no distribution. `make install` puts the binary on PATH. Privilege comes from `sudo`, and even as root the executor runs only verified, cataloged, root-requiring recipes.

---

## Branch → environment topology

| Branch | Environment | Auto-deploy | Notes |
|--------|-------------|-------------|-------|
| `main` | local machine / release | no | Single-branch. Every release is a notarised DMG + Homebrew cask, published by hand. |

There is no production server. "Production" is the copy installed on the user's Mac and the machines of anyone who trusts it with their databases. Treat release quality accordingly.

---

## Where to find things

**Ledgers — read before building anything, append before finishing anything**
- Known issues → `docs/known-issues.md` (`KI-n`; every defect, gap, risk, environmental item, *including* "not my code")
- Design decisions → `docs/plans/CURFEW-DESIGN-DECISIONS.md` (`D0–D26`; a plan that contradicts a settled `D` is wrong by construction)
- Contracts → `docs/plans/CURFEW-CONTRACTS.md` (`C0–C14`; offers/expects/consumed-by + the external JSON and exit-code shapes)
- Decomposition → `docs/plans/CURFEW-DECOMPOSITION.md` (`L0.1–L6.3`, 27 atoms; the build map and critical path)
- Police all four with `python3 scripts/ledger_check.py`

**Architecture**
- **Design synthesis — read this first when building** → `docs/architecture/blueprint.md`
- Tech stack, module layout, privilege model → `docs/architecture/overview.md`
- Service catalog design and the full entry inventory → `docs/features/service-catalog.md`
- Safety model and tiers → `docs/research/core-os-services.md`

**Research (dated, evidence-backed, the basis for the catalog)**
- Feasibility assessment on this machine → `docs/research/feasibility-assessment.md`
- macOS core-service tiers and what is reachable → `docs/research/core-os-services.md`
- What TS/JS/Python/Rust development actually needs running → `docs/research/dev-toolchains.md`
- DSH Fleet + Zcode MCP dependency graph → `docs/research/harness-mcp-deps.md`
- Containers, VMs and local inference engines (Kiri, OpenBot, embeddinggemma-2, Laya) → `docs/research/containers-and-engines.md`

**Features**
- Per-feature behaviour and edge cases → `docs/features/`

**Pipeline / scripts**
- Probe and measurement scripts (footprint sampling, service inventory) → `docs/scripts/README.md`
- Catalog generation runs → `docs/pipeline/README.md`

**Reference**
- Business context → `docs/BUSINESS-CONTEXT.md`
- Troubleshooting → `docs/TROUBLESHOOTING.md`
- State snapshot (machine counts, measured reclaim) → `docs/STATE-SNAPSHOT.md`
- Recent sessions → `docs/recaps/`

---

## Contracts (the artifacts we treat as commitments)

| Contract | Location | Cadence | Purpose |
|----------|----------|---------|---------|
| **Plans** | `docs/plans/YYYY-MM-DD-<slug>.md` | Per feature | Pre-work contract: what we're building, acceptance criteria |
| **Recaps** | `docs/recaps/SESSION-RECAP-YYYY-MM-DD.md` | Per session | Post-work journal: what shipped, criteria status |
| **Technical reference** | `TECHNICAL-DOCUMENTATION.md` | Per feature | Developer onboarding: modules, catalog format, privilege model |
| **Functional reference** | `FUNCTIONAL-SPECIFICATIONS.md` | Per feature | User-flow contract: modes, bundles, apply/restore behaviour, edge cases |
| **Catalog evidence** | `catalog/*.yaml` `evidence:` fields | Per service | The stop/start recipe was verified on a real machine, dated |

**The cycle is**: draft a plan → implement → write a recap → update the technical and functional contracts. For trivial changes the cycle compresses: skip the plan, brief recap, no contract updates.

One addition specific to this project: **a catalog entry is a contract too.** Changing a stop recipe for a service that can lose data (any database, any sync agent) requires the same care as a schema migration — plan, dry-run, and a recorded verification.

---

## Common commands

```bash
swift build                      # normal terminal
swift test                       # normal terminal
# From a sandboxed agent session SwiftPM cannot build: add these (KI-019).
#   export CLANG_MODULE_CACHE_PATH="$PWD/.build/modulecache"
#   swift build --disable-sandbox --cache-path .build/spm-cache --config-path .build/spm-config
python3 scripts/ledger_check.py  # police the four ledgers (run before committing any ledger change)
swift run curfew list            # enumerate services with tier + findings (read-only)
swift run curfew list --json     # machine-readable inventory
swift run curfew doctor          # aggregated findings + scan completeness
swift run curfew why <label>     # ancestry, source, sockets, warnings (needs witr)
swift run curfew catalog validate           # schema + policy over catalog/*.yaml (read-only)
swift run curfew catalog list                # entries, levers, bundles, protected ports
swift run curfew catalog plan --bundle data-services   # what WOULD run; nothing executes
swift run curfew status                     # unresolved journal intents (writes nothing)
swift run curfew apply --bundle vendor-noise            # dry run: refusals, nothing touched
swift run curfew apply --bundle vendor-noise --execute  # needs --yes when not a TTY
swift run curfew resume                     # preview the restore plan
swift run curfew tui --frame                # one dashboard frame, from live data
swift run curfew                            # the dashboard (needs a terminal)
make check                                  # every gate: tests, ledgers, catalog, crash test
make install                                # put curfew on PATH (~/.local/bin)
make app                                    # build Curfew.app (menu bar); `make run-app` opens it
./scripts/crash-test.sh                     # SIGKILL mid-action, then assert recovery
```

---

## Today's state

- **The read-only slice and the catalog layer shipped 2026-11-24.** `curfew 0.1.0`: `list` (472 jobs in 1.19 s), `why`, `doctor` (17 real findings), `catalog validate|list|plan` over `catalog/*.yaml`, `status` over the write-ahead journal. **165 tests in 24 suites, green. 23 of 27 atoms done, 4 dropped by scope. No atom left.**
- **The mutating half is built but has never run.** `apply` refuses draft entries, root recipes, protected ports and our own pid; `--execute` needs `--yes` off a TTY. The executor's pipeline is refuse → journal intent → act → verify → journal outcome, with the runner injected so the ordering is tested, not asserted. The recovery path is proven two ways: unit tests over a post-crash journal artifact, and `scripts/crash-test.sh`, which SIGKILLs a real apply between intent and outcome and asserts `resume` restores it. Recipes use `{plist}`, resolved from what `launchctl print` reports — a hand-written path in a restore recipe left a live updater unloaded once (KI-030).
- **The reframe that came out of the research:** the measured waste is not only vendor updaters. Crash loops are invisible to every process tool because they have no PID. Three were found and **all are now resolved (2026-11-24)**: `com.zcode.model-router` (255,645 runs) and `com.agnostic-router.model-router` (255,646) were respawning on a dangling `~/.local/bin/node` symlink and were removed with the dead router PoC; `sh.brew.postgresql@14` (82,103 runs) was retired outright after a stray `postgres@14` was found squatting on `:5434` — the port commissiontracker's own container maps. **No crash loops remain on the machine.** The detector is still the right first product: it found all three, and nothing else would have.
- **Key safety number:** 733 of 887 system plists register a `MachServices` port, so freezing is dangerous by default; 453 of 887 have `LaunchEvents`, so `bootout` alone is not quiet mode.
- **The viability fact:** a build needs node/git/rustc/uv plus four Apple daemons. The user-domain launchd layer contributes almost nothing to `pnpm build`, which is why quiet mode on `~/Library/LaunchAgents` is safe by construction.
- **The largest footprints are not launchd services, and most are now gone.** With the owner's approval on 2026-11-24: OpenBot Desktop was uninstalled entirely (app, `~/OpenBot`, its podman machine — 4 CPU / 6 GiB / 60 GiB — and every container); **LayerFS is gone as a runtime** (worker, image, volumes, source repos, `~/dsh-layerfs`, `~/.fleet/layerfs-home`, `~/.cache/layerfs-worktrees`, and the `layerfs` section of `~/.fleet/config.json`, backed up); the layerfs repos' uncommitted work was archived to `docs/archive/layerfs-work-2026-11-24/` first; the mlx-lm weights (4.7 GB) were deleted with the service stopped; and `pampa-dev-postgres` was stopped with its volume and 4 databases intact. Host free space went 60 → **79 GB**; swap 5.36 → 4.72 GB; free RAM 33% → 42%. **fleet is unaffected** — `fleet doctor` reports the feature `off` by design and `fleet memories` still lists 93 facts.
- **fleet is retired, but its repo is still load-bearing.** The owner has wound the agent down ("the salvage lives in dsh-salvage" is its own HEAD commit), but DSH's five MCP servers are Python entrypoints *inside* `~/Projects/fleet/services/*/service/mcp_server.py`, and the five MCP servers still run from `~/.fleet/venvs/*` (laya's venv is gone, D25). The retired agent's dead weight was removed — `target/` (15 GB Rust build output) and `~/.fleet/checkpoints` (5.2 GB) — leaving the repo at 543 MB with `services/` intact. **Verified after deletion:** `sem1_probe` answers through the embedding proxy at 1024 dims (D26). The remaining layerfs *code* inside fleet was left alone by the owner's decision.
- **Kiri-side deletions do not return host space.** Its VM disk is a 23 GB sparse `data.img` that refuses discard (`fstrim` → "discard operation is not supported"), so the 17 GB BuildKit cache pruned there shows as VM headroom only. Any future "reclaim" plan must say which side of the VM it is counting.
- **Embeddings run on qwen3-embedding-8b through a local proxy (D26).** `127.0.0.1:8901/v1/embeddings` is served by `~/.fleet/bin/qwen-embed-proxy.py` forwarding to OpenCode Go at **1024 dims**; the 1.4 GB gemma model and its launchd job are gone. The index rebuilds lazily and incrementally — a model change behind an unchanged URL is invisible to an embedder-keyed cache, so the caches had to be cleared.
- **laya is gone (D25).** Removed 2026-11-25 for memory pressure: the launchd job, the 822 MB venv, the model cache and the sys1 provider registration. sys1 now runs on its paid providers — `glide`, `drex`, `jev` in the default chain, verified live at 1.6 s.
- **Open decisions** (`blueprint.md` §8): memory-vs-determinism pitch; Apple Tier-2 agents in or out of v1; whether unsupervised daemons (`kanzo`, no launchd job) may be stopped at all.
- **Not yet verified:** `launchctl bootstrap` from a sandboxed agent session (EIO); per-service memory reclaim (`footprint -p` needs a normal shell); whether `disable` survives an OS update.

---

## Housekeeping protocol — keeps the docs tree from rotting

**You are responsible for keeping the docs tree current.** After every session that changes something material, do the following before the user wraps up:

1. **Identify which doc(s) the change touched.** Changes to a feature → `docs/features/*.md`. New script → `docs/scripts/README.md`. New or changed catalog entry → that entry's `evidence:` field *and* `docs/features/service-catalog.md`. Safety-tier change → `docs/research/core-os-services.md`. Machine-level counts → `docs/STATE-SNAPSHOT.md`. **A choice you made → a new `D` in the design-decisions ledger; a defect, gap or risk you hit → a new `KI`; a new interface or a changed signature → the contracts ledger; a new build increment or a status change → the decomposition ledger.**
2. **Update the relevant doc inline.** Recaps are journal entries; topical docs are the source of truth.
3. **Stat tables go in `docs/STATE-SNAPSHOT.md`, not topical docs.** Replace it, don't append.
4. **`CLAUDE.md` only changes when** a hard rule changes, a new top-level docs area appears, the topology changes, or "Today's state" needs a refresh. No changelogs, no "updated" markers, no deep dives here.
5. **`CLAUDE.local.md` changes leave no git trace.** Mention any credential or URL change in the session recap.
6. **Contract docs must stay in sync with code.** Never declare a feature done while `TECHNICAL-DOCUMENTATION.md` or `FUNCTIONAL-SPECIFICATIONS.md` is stale; track the gap as a debt in the recap if you must defer.
7. **Drift check before ending a session:** `wc -l CLAUDE.md` (≤ ~300), `git status` (no `CLAUDE.local.md`), every `docs/` path named here exists.
8. **Quarterly:** re-snapshot `STATE-SNAPSHOT.md`, archive recaps older than 90 days, strip `Updated YYYY-MM-DD` markers, and re-verify the Apple-agent labels (macOS releases move them).

---

## Session protocol

**At the start** of any non-trivial session, run `/warmup`: it loads this file, the latest recap, active plans, and the relevant research/feature docs before answering.

**At the end** of any session that touched anything, run `/wrapup`: recap exists, "Today's state" fresh, uncommitted changes dispositioned, plan statuses transitioned, deferred doc debts surfaced.

For trivial sessions, skip warmup and the recap but **still run `/wrapup`**.

1. Read this file (auto-loaded).
2. Read `CLAUDE.local.md` for any credential, host, or machine-specific path.
3. Read the relevant `docs/` file from the map above.
4. Follow the housekeeping protocol after changes.

**The six-stage cycle**: `warmup → plan → build → recap → wrapup → next session`.
