---
status: completed
created: 2026-11-24
updated: 2026-11-24
slug: cleanup-layerfs-pampa-openbot-mlx
---

# Plan — reclaim layerfs, pampa, OpenBot and the mlx-lm models

> **Executed 2026-11-24, owner-approved per item.** Host free space 60 GB → **76 GB**. Swap 5.36 GB →
> 4.72 GB used; free RAM 33% → 42%. See [Actuals](#actuals-2026-11-24) for what differed from the plan.

## Context

Four cleanup proposals from the owner, plus one measured discovery that dwarfs all four.

The owner said: layerfs can go entirely; the pampa container can be stopped and brought up only when working on that project; OpenBot is undecided ("not sure I'm still trying to figure out what's the use case"); the mlx-lm models can be removed because they are "not usable on this machine anyway."

Before acting, everything was measured read-only on 2026-11-24. The result reorders the proposals: **the biggest reclaimable block is not any of the four — it is 17 GB of dormant BuildKit build cache inside Kiri**, which no proposal mentioned and which no service is using.

### The measured ledger

| # | Item | Reclaim | Where | Regenerable |
|---|---|---|---|---|
| **0** | BuildKit `kiri-build0` cache | **17.0 GB** | `buildx_buildkit_kiri-build0_state` volume | yes — a prune only costs the next build's time |
| 3a | OpenBot's podman VM disk | **8.9 GB** actual (60 GB sparse) | `…/podman/machine/libkrun/openbot-arm64.raw` | no — deleting kills container data |
| 3b | OpenBot images (both engine refs) | ~864 MB | Kiri + podman stores | yes, re-pullable |
| 4 | mlx-lm `Ornith-1.5-9B-MLX-4bit` | **4.7 GB** | `~/.cache/huggingface/hub/` | yes, re-downloadable |
| 3c | OpenBot app + `~/OpenBot` | 443 MB | `/Applications`, `~` | yes, re-installable |
| 1a | `layerfs-352-runtime:node24` image | 955 MB | Kiri images | yes, rebuilt from a worktree |
| 1b | `layerfs-cargo` volume | 290 MB | inside Kiri VM | yes (Rust build cache) |
| 1c | layerfs worktree cache | 23 MB | `~/.cache/layerfs-worktrees-v1` | yes |
| 1d | layerfs repos (**keep**) | 294 MB | `~/Projects/layerfs`, `~/Projects/dsh-layerfs`, `~/dsh-layerfs` | research artifacts, not proposed for deletion |
| 2 | pampa container stop | ~0 disk, container RAM only | Kiri container | yes, `kiri start` |
| — | pampa DB volume (**keep**) | 65 MB, 4 databases | Kiri volume | — |
| — | Kiri image blobs | 2.8 GB (some in use) | `~/Library/Application Support/Kiri/blobs` | partially |
| — | Qwen3.5-0.8B partial | 88 KB | HF cache | trivial |

Disk is at **360 GB used / 60 GB free (86%)**. Items 0 + 1 + 4 + 3ab would take it to roughly **90 GB free**.

## Four-question gate (per the destructive-operation rule)

Answers are per item; the plan proposes nothing without the owner naming it.

| Question | 0 — build cache | 1 — layerfs | 2 — pampa | 3 — OpenBot | 4 — mlx models |
|---|---|---|---|---|---|
| What exactly is deleted/invalidated? | 17 GB BuildKit cache for a **stopped** builder | one container, one image, 290 MB cargo volume, 23 MB worktree cache | nothing deleted — container stopped, 65 MB DB kept | (pause) nothing; (remove) VM disk, containers, images, volumes | 4.7 GB of model weights |
| Is current state causing a reported problem? | No — but it is 17 GB for a builder that is off | No; idle worker | No; idle container | Undecided use case | Owner says models are unusable here |
| Cheapest reversible fix | `kiri buildx prune` — fully regenerable | `kiri stop` first, prune later | `kiri stop` (durable: `unless-stopped`) | **pause** (`podman machine stop`) | delete cache only, keep the service |
| User-visible benefit | 17 GB back, zero risk | ~1.3 GB back | one less Postgres competing for RAM | ~10 GB + 1–2 GB RAM | 4.7 GB back |

## Approach

Ordered by value-per-risk, not by the order proposed.

### 0 — Prune the dormant BuildKit cache (recommended first)

`kiri-build0` is **stopped**, yet its state volume holds 17 GB. `kiri buildx prune -af` reclaims it; the only cost is a slower next container build. No running service touches it.

### 1 — LayerFS: stop the worker, keep the repos

What is actually there: one container, `dsh-layerfs-worker`, running `node …/layerfs-worktrees-v1/layerfs-d2e2057f4d96/artifacts/build-linux-…/api/runtime/src/worker/server.js`, `restart: unless-stopped`, listening only on `127.0.0.1:58219` with **no established connections**. Built from a stale worktree artifact (13 hours old).

- `kiri stop dsh-layerfs-worker && kiri rm dsh-layerfs-worker`
- `kiri rmi layerfs-352-runtime:node24` (955 MB)
- Remove the `layerfs-cargo` volume (290 MB) — **after** confirming no rebuild is planned, since it is the Rust build cache that makes a rebuild cheap
- `rm -rf ~/.cache/layerfs-worktrees-v1` (23 MB, regenerable)
- **Do not** touch `~/Projects/layerfs`, `~/Projects/dsh-layerfs`, `~/dsh-layerfs` — those are the research artifacts
- **Do not** remove the `layerfs` block from `~/.fleet/config.json` — fleet has first-class layerfs support (`bundle`, `home`, `image`, `projects`) and removing the config is a different decision from removing the runtime

### 2 — Pampa: stop, don't delete

`kiri stop pampa-dev-postgres`. Its restart policy is `unless-stopped`, so an explicit stop is **durable across Kiri restarts** — exactly the "only when I work on that project" behaviour. Bring it back with `kiri start pampa-dev-postgres`; the 65 MB volume with 4 databases is untouched.

This is also the first real test case for Curfew's `on-demand` bundle kind, so record the stop/start commands rather than treating this as a one-off.

### 3 — OpenBot: pause now, decide later

The owner has not decided. The asymmetric move is to **pause**: `podman machine stop` frees the VM's RAM and the containers' share of it while keeping the disk, the pgvector data and the k3d images intact. Full removal is available later and is the only irreversible option here.

Removal (only after a decision) would be: quit OpenBot Desktop → `podman machine rm openbot-arm64` (deletes the 8.9 GB disk and every container volume) → `rm -rf ~/OpenBot` → move `/Applications/OpenBot.app` to the Trash → prune its images. Nothing else on the machine depends on it: the harnesses reach the machine through Tailscale and the DSH bridge, not through OpenBot.

### 4 — mlx-lm: delete the weights, keep the service

`Ornith-1.5-9B-MLX-4bit` is 4.7 GB. **Nothing references it:** no project `CLAUDE.md`, no DSH/Zcode config mentions `mlx` or `127.0.0.1:8080`, and `:8080` has no client — only the listener. `Qwen3.5-0.8B` is 88 KB (config only).

- `rm -rf ~/.cache/huggingface/hub/models--ornith-ai--Ornith-1.5-9B-MLX-4bit`
- Leave `sh.brew.mlx-lm` running or `brew services stop mlx-lm` — it is lazy and holds no model once the weights are gone. Stopping it is the honest end state, since a server with no models is dead weight.

## Acceptance criteria

- [ ] `df -h /System/Volumes/Data` reports at least 77 GB free (baseline: 60 GB) — **actual 76 GB**: one
      gigabyte short, because the 17 GB BuildKit reclaim never reached the host (see Actuals)
- [x] `kiri images` still lists only images in use, and the 17 GB cache is gone — verified 5.1 GB used
      inside the VM (was 22 GB)
- [x] `kiri ps` no longer lists `dsh-layerfs-worker`
- [x] `kiri ps -a` lists `pampa-dev-postgres` untouched and running; its volume and 4 databases intact
- [x] the docker socket no longer answers at all — the podman machine was removed, so no `openbot-*` or
      `k3d-*` container can exist
- [x] DSH Fleet answers on `127.0.0.1:57730` (HTTP 401, auth required) and `:8901/v1/models` still lists
      `embeddinggemma-2-BF16.gguf`
- [ ] `~/Projects/layerfs` and `~/Projects/dsh-layerfs` still exist — **intentionally not met**: the owner
      chose to delete the repos; their uncommitted work was archived first (see Actuals)
- [x] `du -sh ~/.cache/huggingface/hub/models--ornith-ai--Ornith-1.5-9B-MLX-4bit` fails (path gone)

## Files touched

`docs/research/containers-and-engines.md`, `docs/STATE-SNAPSHOT.md`,
`docs/architecture/blueprint.md` (bundle list gains `on-demand`), `TECHNICAL-DOCUMENTATION.md` §4.

## Out of scope

- Deleting the layerfs source repos, or removing fleet's `layerfs` config block
- Removing the Kiri engine itself (it hosts Pampa; that is a separate decision)
- Postgres on `:5432`, `:5434`, `:5439` — the crash-looping `postgresql@14` is its own plan
- The two crash-looping router jobs (~255k spawns each) — separate plan, higher value
- Removing the podman machine until the OpenBot decision is made

## Verification

Run after each item, not at the end: `df -h`, `kiri ps -a`, `kiri images`, `kiri volume ls`,
`curl -s --unix-socket /var/run/docker.sock http://localhost/containers/json`, `curl :8901/v1/models`,
`launchctl print gui/$(id -u)/dev.kiri.daemon | grep state`.

## Linked artifacts

- `docs/research/containers-and-engines.md` — the evidence this plan rests on
- `docs/architecture/blueprint.md` §5 — `containers-idle` / `inference-local` bundles
- `docs/STATE-SNAPSHOT.md` — containers, VMs, Postgres, engines
- `TECHNICAL-DOCUMENTATION.md` §4 — catalog entry kinds (`on-demand`)

---

## Actuals (2026-11-24)

**What was executed**, in order:

1. **BuildKit cache — freed, but not on the host.** `kiri buildx prune -af` failed with `driver not
   running`, so the builder container `buildx_buildkit_kiri-build0` and then the volume
   `buildx_buildkit_kiri-build0_state` were removed directly. Inside the VM: **22 GB → 5.1 GB used**.
   On the host: **nothing**. `~/Library/Application Support/Kiri/vm/data.img` is still allocated at
   23 GB because the VM's disk does not support discard — `fstrim` inside the guest returns
   *"the discard operation is not supported"*. **Lesson for Curfew: a Kiri-side deletion is a VM-side
   win only.** The 17 GB is real headroom for future builds, not free space today.
2. **mlx-lm** — weights deleted (4.7 GB), `brew services stop mlx-lm` done. `:8080` is closed.
3. **LayerFS runtime** — `kiri stop`/`rm` of `dsh-layerfs-worker`, `rmi layerfs-352-runtime:node24`,
   and the `layerfs-cargo`, `layerfs-target`, `dsh-layerfs-shy-whale-store-mwuqix2f` volumes removed.
   **Repos deleted too** (owner's choice), but only after archiving their uncommitted work to
   `docs/archive/layerfs-work-2026-11-24/`: two patches, a manifest with each HEAD commit, and a 525 KB
   tarball of the untracked `packages/client/src/client/assets/`.
4. **OpenBot** — app quit, `podman machine rm -f openbot` (a **4 CPU / 6 GiB / 60 GiB disk** machine,
   8.9 GB actually allocated), `~/OpenBot` (160 MB), `/Applications/OpenBot.app` (283 MB), and the
   `copilotkit` images removed. The docker socket is now dead — nothing can start a container from it.

**Deliberately not done, and why:**

- **Pampa was not stopped** — the owner did not select it. It is still running on `:5438`.
- **`~/dsh-layerfs` was left alone.** It is *not* a source repo: it holds `profiles/`, `sessions/` and
  `storages/` (432 KB of LayerFS runtime data). Deleting it was not covered by "delete the source repos";
  it is the one layerfs path still on disk and needs its own decision.
- **Fleet's `layerfs` config block was left intact** — and still resolves: `home` points at
  `~/.fleet/layerfs-home` and `bundle` at `~/.cache/layerfs-worktrees/layerfs-study-c159d…`, neither of
  which was deleted. No dangling configuration was created.
- `kiri`'s copies of `node@sha256:3d27e5c…` (fleet's layerfs image), `pgvector/pgvector:pg17`,
  `node:alpine` and `alpine` were left in place — they are small, unused, and removing them would not
  return host space anyway.

**Measured result:** host free 60 → **76 GB**; Kiri VM usage 22 → 5.1 GB; swap 5,361 → 4,720 MB;
free RAM 33% → 42%; DSH Fleet and the embedding server both still healthy.

---

## Round 2 (2026-11-24, 20:55) — the four items deferred from Round 1

The owner then approved each deferred item explicitly.

1. **Pampa stopped.** `kiri stop pampa-dev-postgres` → `Exited (0)`. The container, its volume
   (`55275ce1…`) and all 4 databases are intact. `unless-stopped` makes the stop durable across Kiri
   restarts. Start on demand with `kiri start pampa-dev-postgres`.
2. **`~/dsh-layerfs` removed** (432 KB — `profiles/`, `sessions/`, `storages/`). It was LayerFS runtime
   data, not a source repo, which is why it survived Round 1.
3. **fleet's `layerfs` config section removed** from `~/.fleet/config.json`. Backup at
   `~/.fleet/config.json.bak-20261124T205512`. Verified fleet tolerates its absence by design:
   `fleet doctor` now reports `layerfs ok off (config.json carries no 'layerfs' section)` and
   `layerfs-home ok not provisioned`, and `fleet memories` still lists 93 facts.
4. **The layerfs layer runtime deleted** — `~/.fleet/layerfs-home` (40 MB: the layer store, `staging/pending-*`
   and `traces/`) and `~/.cache/layerfs-worktrees` (46 MB: two built worktrees). Nothing in either was a
   git repo, so no unpushed work was lost; the fleet source itself was already clean (0 unpushed commits,
   remote `gitea-gitea.opsh.io/synapticmomentum/fleet`).

**Host free: 76 → 79 GB.**

**Still standing, deliberately:** fleet's *code* still references layerfs in **26 files / 890 mentions**
(`src/layerfs_tools.rs`, `src/layerfs_view.rs`, and woven through `main.rs`, `route.rs`, `tools.rs`,
`doctor.rs`, `install.rs`, the GUI assets and tests). That is a refactor, not a layer removal, and fleet
now reports the feature "off" without it being present — so the runtime goal is met without touching
source. Removing the code is a separate plan with real regression surface.

**Observation, not a regression:** `fleet doctor` reports `sys1 FAIL no services root found (set
FLEET_SERVICES_ROOT or FLEET_LANE_SYS1_HOME)`. `FLEET_SERVICES_ROOT` is set in neither `~/.fleet/fleet.env`
nor any shell profile, while the root exists at `~/Projects/fleet/services`. That gap predates this work
and is independent of the `layerfs` section removal.

---

## Round 3 (2026-11-24, 21:01) — fleet's dead weight

The owner retired the `fleet` agent outright ("if I ever want to resurface it I'll pull it from Gitea")
but the repo cannot be deleted wholesale, because the DSH harness's five MCP servers are Python
entrypoints inside it (`~/Projects/fleet/services/*/service/mcp_server.py` with matching `*_PYTHONPATH`),
and `services/sys1/src/sys1/config.py:194` reads `~/.fleet/venvs/laya`. Recorded as hazard 15 in
`docs/architecture/blueprint.md`.

Removed, with `services/` and `venvs/` explicitly preserved:

- `~/Projects/fleet/target` — **15 GB**, gitignored Rust build output, regenerable
- `~/.fleet/checkpoints` — **5.2 GB**, the retired agent's session checkpoints

**Result:** the repo went 16 GB → **543 MB**; host free went 79 → **98 GB**. Verified afterwards that the
harness still works: `sem1_probe` returned 768 dims from `embeddinggemma-2-BF16` in 1.4 s. The repo's own
HEAD commit reads *"docs: Fleet is wound down; the salvage lives in dsh-salvage"* — the retirement was
already on the record; this just reclaimed the disk.
