# State Snapshot

> Dated, measured counts for the machine Curfew targets. **Replace this file; do not append.** Refreshed from live data at each snapshot (see `CLAUDE.md` housekeeping §3).

**Snapshot: 2026-11-24** · macOS 26.5.2 (25F84) · arm64 · 16 GB · SIP enabled · uptime 33 d

## Service inventory

| Measure | Value |
|---|---|
| Loaded services in `gui/501` (row pattern `^\s+[0-9]+\s+[0-9-]+\s+\S+`) | 282 |
| — `com.apple.*` | 230 |
| — `application.*` GUI instances | 17 |
| — third-party (the product's surface) | 35 |
| — third-party currently running | 17 |
| — third-party loaded but idle | 18 |
| `/Library/LaunchAgents` (all vendor) | 7 |
| `/Library/LaunchDaemons` (all vendor) | 11 |
| `~/Library/LaunchAgents` | 30 |
| Apple jobs on disk | 465 agents + 422 daemons |
| `launchctl print system` active count | 956 (of 438 registered system services, 154 active) |

## Memory pressure

| Measure | Value |
|---|---|
| Swap in use | 5,438 MB of 7,168 MB |
| Compressed RAM (compressor) | ~4.16 GB (271,818 pages × 16 KB) |
| Pages active / inactive / wired | 227,533 / 226,417 / 279,285 |
| Free percentage (incl. reclaimable inactive) | 45% |
| Swapins / swapouts since boot | 217,299,321 / 233,923,621 pages |

## Classification of the 35 third-party user-domain services

Roughly 30 are vendor updaters, sync agents, or app launchers — none needed to compile a project or run an agent:

Keystone ×2 · GoogleUpdater wake ×2 · Microsoft AutoUpdate · OneDrive ×5 · Office licensing ×2 · Teams agent · Defender tracer · Zoom ×3 · Steam clean · Docker helper · podman helper · Sparkle `ShipIt` ×4 · Perplexity · OpenAI chat helper · WorkBuddy converter.

The dev set that quiet mode must protect instead:

`postgresql@18` · `postgresql@14` (error state) · `second-brain-pg` (:5439) · `mlx-lm` server · `ollama` · `watchman` · `cliproxyapi` (:8317) · 3× gitea runner · `kanzo` (:4242) · `kiri` daemon (:443/:80) · 3× model router · `dev.dsh.bridge` · fleet GUI · `sem1-llama` · `blend1-service` · `second-brain-tower` · `ux-drift`.

## Remote-access path (never suspend)

| Endpoint | Owner |
|---|---|
| `100.115.120.43:8443`, `:8444` (Tailscale) | `IPNExtension` pid 97831 |
| `127.0.0.1:57730`, `:57801` | DSH Fleet |
| `127.0.0.1:54766` | Tailscale local API |

## Containers and VMs

| Engine | Allocation | Containers |
|---|---|---|
| **Kiri** (`dev.kiri.daemon`, Server 27.5.1) | **4 CPU / 5,120 MiB** (`~/.kiri/vm.json`), VM usage **5.1 GB of 62.4 GB** after cleanup | `pampa-dev-postgres` (postgres:18-alpine, `:5438`) — **stopped 2026-11-24, volume + 4 DBs kept** |
| **Podman machine** | **removed 2026-11-24** (`podman machine rm openbot` — was 4 CPU / 6 GiB / 60 GiB) | none; the docker socket is dead |

OpenBot Desktop is **uninstalled** (app, `~/OpenBot`, images, k3d stack, pgvector container all removed).
LayerFS worker/image/volumes are **removed**; its repos are deleted, with uncommitted work archived at
`docs/archive/layerfs-work-2026-11-24/`.

## Postgres instances

| Port | Instance | Supervisor |
|---|---|---|
| 5432 | postgresql@18 (18.7) | launchd `sh.brew.postgresql@18` — verified answering |
| ~~5434~~ | ~~postgresql@14~~ | **retired 2026-11-24** — formula uninstalled, 52 MB data dir removed, `jobhound` dumped to `docs/archive/pg14-jobhound-2026-11-24/`; the port is now free for commissiontracker's own `postgres:18-alpine` container |
| 5438 | pampa-dev-postgres (18-alpine) | **Kiri container — stopped 2026-11-24**; volume + 4 DBs kept, start on demand |
| 5439 | second-brain-pg (17.11) | launchd `…second-brain-pg` — verified answering |

`psql` on `PATH` was symlinked to the 14 cellar; it now resolves to **18.7**.

## Local inference engines

| Engine | Endpoint | Model | Note |
|---|---|---|---|
| llama-server | `127.0.0.1:8901` | `embeddinggemma-2-BF16` | launchd `com.adelvillar1.sem1-llama`; backs sem1, brain_recall, select_skills, blend1 |
| Ollama | `127.0.0.1:11434` | **none loaded** | idle weight |
| **Laya (vega)** | no endpoint | 0.8B frozen reader | **in-process**, `~/.fleet/venvs/laya` (815 MB); first call up to **180 s**; fallback URL `:8454` listens to nothing |
| ~~mlx-lm~~ | ~~`127.0.0.1:8080`~~ | **removed 2026-11-24** | weights deleted (4.7 GB), `brew services stop mlx-lm` done |

## Health — crash loops and zombies

| Job | Runs | Last exit | Note |
|---|---|---|---|
| `com.alejandrodelvillar.second-brain-pg` | 27,010 | `1` | running now (pid 6563); high restart history, worth watching |

**No crash loops remain on the machine as of 2026-11-24.**

**Removed 2026-11-24:** `com.zcode.model-router` (255,645 runs) and `com.agnostic-router.model-router`
(255,646) were both crash-looping on a **dangling `~/.local/bin/node` symlink** (target
`~/.hermes/node/bin/node` no longer exists → `EX_CONFIG`). Two duplicates of a dead router PoC; all three
router jobs were booted out, disabled and deleted. See `docs/TROUBLESHOOTING.md`.

## Disk and caches

| Measure | Value |
|---|---|
| `/System/Volumes/Data` | **98 GB free of 460 GB (77%)** — was 60 GB free before the 2026-11-24 cleanup |
| `~/.cache/uv` | 15 GB (archive-v0 14 GB) |
| `~/Library/pnpm` | 3.5 GB (store 3.0 GB) |
| `~/.npm` | 3.0 GB |
| `~/.cargo/registry` | 1.3 GB |
| `~/.rustup` | 870 MB |
| `fleet/target` | 15 GB |
| 6 × `node_modules` | ~5.1 GB |
| `sccache` cache | **absent** (cold; every Rust build pays the full cost) |

The caches are an asset, not clutter: `uv sync`, `pnpm install --offline`, and `cargo build --offline`
all work from them, which is what lets an overnight build survive a network wobble.

## Gaps in this snapshot

- Per-service memory is **not** measured (`ps`/`top` blocked in the measuring session). Needs `footprint -p` from a normal shell — this is the open decision input in `docs/research/feasibility-assessment.md` §10.
- `sfltool dumpbtm` requires root; the Background Task Management (Login Items) store is unenumerated here.
- Exact CPU cost of Apple Tier-2 agents is unmeasured.
