# Containers and local inference engines

> **STATUS AFTER CLEANUP — 2026-11-24 20:56.** This document is the survey of how things *were* before
> the owner-approved cleanup (`docs/plans/2026-11-24-cleanup-layerfs-pampa-openbot-mlx.md`). What has
> since changed: **OpenBot is gone entirely** (machine removed, app and `~/OpenBot` deleted, images
> pruned); **LayerFS is gone as a runtime** — worker, image, volumes, source repos, `~/dsh-layerfs`,
> `~/.fleet/layerfs-home`, `~/.cache/layerfs-worktrees`, and the `layerfs` section of
> `~/.fleet/config.json` are all removed (fleet now reports the feature `off`); **the mlx-lm models are
> deleted and the service stopped**; the **17 GB BuildKit cache was removed** — inside the VM only,
> because the Kiri disk does not support discard; **`pampa-dev-postgres` was stopped** (container,
> volume and 4 databases kept, start on demand). What remains: the **Kiri daemon**, the **podman
> machine is gone**, `embeddinggemma-2-BF16` on `:8901` is untouched, Ollama `:11434` untouched, and
> Laya untouched. Fleet's *source code* still references layerfs in 26 files — runtime off, code intact.

Addendum to the harness map. These three are the largest live footprints on the machine and were
missing from the first pass: **Kiri**, **OpenBot Desktop**, and the **local inference engines**
(embeddinggemma-2 and Laya, plus mlx-lm and Ollama).

Measured 2026-11-24 ~20:25–20:35 CST, read-only. Nothing was stopped, started, or reconfigured.
Anything that could only be settled by mutating is marked **UNVERIFIED**.

A note on how this was found, because the earlier docs got it wrong: `podman` is **not on `PATH`**
(no shell can run it), so the first pass saw only `gvproxy`/`krunkit` and concluded "podman machine,
no containers". The containers are visible through `/var/run/docker.sock`, which is a symlink to the
podman socket. **Five were running.**

---

## 1. There are two container engines on this box, not one

| Engine | What it is | VM | Why it matters |
|---|---|---|---|
| **Kiri** `0.2.2` (daemon pid 74620, launchd `dev.kiri.daemon`) | A full container runtime — `kiri` reports "docker's commands, on Kiri", Server Version `27.5.1`, `Runtimes: kiri`, `Operating System: Kiri` | **4 CPUs / 5,120 MiB** (`~/.kiri/vm.json`) | Hosts two live containers **and** a local HTTPS router on `:443`/`:80` |
| **Podman machine** (`/opt/podman/bin/{podman,gvproxy,krunkit,vfkit}`, `gvproxy` pid 25419) | Standard podman VM, reachable only via `/var/run/docker.sock` | not found on disk (settings file absent) — **UNVERIFIED** | Hosts OpenBot Desktop's four containers **and a k3s cluster** |

They are independent. Stopping one does nothing to the other. `kiri images` lists the OpenBot images
alongside its own, so the two stores look similar; do not infer ownership from an image name.

## 2. Kiri

`kiri ps` — the containers **this engine** is running:

| Container | Image | Ports | Age |
|---|---|---|---|
| `pampa-dev-postgres` | `postgres:18-alpine` | `0.0.0.0:5438 → 5432` | up 4 hours (created 8 days ago) |
| `dsh-layerfs-worker` | `layerfs-352-runtime:node24` | `127.0.0.1:58219 → 7070` | up 4 hours |

Plus the daemon's own listeners: `*:443`, `*:80` (local HTTPS dev routing), `*:5438`, and two loopback
sockets (`127.0.0.1:47391`, `127.0.0.1:58219`).

- `~/.kiri/build.json` → `{"auto": false, "with": "docker"}`, so it can build Dockerfiles.
- `~/.kiri/daemon.log` shows live container lifecycle: `container start … name=pampa-dev-postgres
  image=postgres:18-alpine`, and one-off builder containers that immediately exit.
- The launchd job is `KeepAlive {SuccessfulExit: false}` — it is meant to stay up, and **a crash
  restarts it, restoring every container with it**.
- Curfew's consequence: `pampa-dev-postgres` is **a fourth dev Postgres** on this machine (see §5).
  Stopping the Kiri daemon stops both containers and reclaims a 5 GB VM — but the containers' data
  lives in `kiri` volumes (`buildx_buildkit_kiri-build0_state`, `layerfs-cargo`, `layerfs-target`,
  `dsh-layerfs-shy-whale-store-*`), so a stop is only safe if the containers are stopped first.
  **UNVERIFIED**: whether `bootout` of `dev.kiri.daemon` stops the VM gracefully or leaves a
  half-dead VM and orphaned container state.

## 3. OpenBot Desktop

`/Applications/OpenBot.app` **v1.1.2** (CopilotKit OpenBot). The Desktop app is pid **25493**, listening
on `127.0.0.1:59954` (its binary is `Contents/Resources/cli-bundle/runtime/node`).

Its compose stack is running under podman — five containers, all up ~3 hours:

| Container | Image | Ports |
|---|---|---|
| `openbot-desktop-server-1` | `ghcr.io/copilotkit/openbot` | `3001`, `3010` |
| `openbot-desktop-agent-computer-1` | `ghcr.io/copilotkit/openbot` | `4100`, `3001` |
| `openbot-desktop-agent-harness-1` | `ghcr.io/copilotkit/openbot-agent-langgraph-ts` | `4215` |
| `openbot-desktop-postgres-1` | `pgvector/pgvector:pg17` | `127.0.0.1:60373 → 5432` |
| `k3d-local-87c536704d8508a06e43c76a-server-0` | `rancher/k3s` | `59951`, `59952`, `59953`, `59955 (6443)` |

- `~/OpenBot/` holds `docker-compose.yml`, `container-images.json` (v1.1.2, pinned digests),
  and `openbot-engine/` containing **`podman-installer-macos-arm64.pkg`**, `podman-default-before.json`,
  `docker-compose-darwin-aarch64`. So OpenBot manages its own podman and deliberately does **not** use
  Kiri as its engine — Kiri only has the images, not the containers.
- The compose file declares a **model gateway** that serves every engine's model calls and injects the
  live key per request, plus engine images (`agent-adk`, `agent-ag2`, `langgraph-ts`) and a supervisor.
- The k3s node carries the label `copilotkit.local-stack` — it is OpenBot's **local evaluation
  harness**, a Kubernetes control plane (6443) inside the podman VM.
- Consequences for Curfew: four containers plus a k3s node is the single largest reclaimable block
  after Kiri's VM, and **none of it is needed by DSH Fleet or Zcode**. The correct lever is
  `podman machine stop` (or `compose down`), not a signal; the podman binary is at
  **`/opt/podman/bin/podman`** and is not on `PATH`, so a catalog entry must record the absolute path.
  **UNVERIFIED**: whether OpenBot Desktop re-spawns its stack when it next launches (expected: yes).

## 4. The local inference engines

### 4.1 embeddinggemma-2 → llama-server `:8901` (a real daemon)

Launchd `com.adelvillar1.sem1-llama`, pid 27468:

```
llama-server -m ~/.cache/huggingface/hub/models--unsloth--embeddinggemma-2-GGUF/…/embeddinggemma-2-BF16.gguf
             --embedding --port 8901 --host 127.0.0.1 --parallel 1 --flash-attn
```

`GET /v1/models` on 8901 returns exactly one model, the GGUF path above. This is the **single most
depended-on local engine on the box**: it backs `sem1` embeddings, `brain_recall`, `select_skills`,
and `blend1`'s semantic leg. Freezing it hangs all four with no timeout (`bridge-mcp.mjs` has none);
stopping it is cleanly reversible via launchd. It is a **socket holder**, so hard rule 4 applies:
`stop`, never `freeze`.

### 4.2 Laya → **not a daemon at all**

This is the finding that changes the catalog model. Laya is a sys1 provider that runs **in-process**:

- `~/.fleet/venvs/laya` — 815 MB venv holding `laya 0.5.2` and `vegaml 0.18.0`.
- sys1 spawns a subprocess into that venv (`_laya_wire`), the same shape as `decide_1b`. No HTTP, no port.
- `laya_model: ""` means `laya.Agent()` — since laya 0.5 the default is the **vega engine**: a frozen
  0.8B reader with a physics decision head. Naming `convaiinnovations/laya` instead loads a 421M encoder.
- `laya_timeout_seconds: 180` — *"the first call loads the reader; later calls are ~0.2 s"*. So the
  first call after a restart is up to **three minutes**; subsequent calls are 200 ms.
- `laya_api_url: http://127.0.0.1:8454/v1/chat/completions` is a served-shape fallback, **not** a live
  service: nothing listens on 8454 today. `LAYA_API_KEY` exists for that shape only.
- HF cache for `convaiinnovations/laya` is only **3.4 MB** — the 0.8B reader is fetched/loaded lazily.

**Consequence for quiet mode:** there is nothing to suspend. But there is a real cost to *eviction*:
a quiet mode that tears down the venv or clears caches turns the next sys1 Laya call into a
three-minute stall. Laya belongs in the protect list not because it is running, but because **making
it cold is expensive**. This is a third kind of entry the schema needs — `mode: in-process`, with
`coldStartCost: 180s` — alongside daemons and app children.

### 4.3 mlx-lm `:8080`

Launchd `sh.brew.mlx-lm` (pid 48721), `mlx_lm.server`, no model argument in the plist. `GET /v1/models`
reports two candidates: **`ornith-ai/Ornith-1.5-9B-MLX-4bit`** (a 9B 4-bit model) and
`Qwen/Qwen3.5-0.8B`. Weights load lazily per request, so the resident cost depends on what was last
served — **UNVERIFIED** which is loaded now. A 9B 4-bit model is on the order of 5 GB resident: this is
the second-largest possible reclaim after the two VMs, and a stop is reversible but pays a multi-minute
reload.

### 4.4 Ollama `:11434`

Running (pid 21839) with **zero models** (`ollama list` empty). It is idle weight; stopping it costs
nothing and loses nothing.

## 5. Five Postgres instances, not three

| Port | Instance | Supervisor | Note |
|---|---|---|---|
| `5432` | `postgresql@18` (18.7) | launchd `sh.brew.postgresql@18` | the main dev DB |
| `5434` | `postgresql@14` (14.24) | launchd, **crash-looping** (81,570 runs) | orphan pid 39307 holds the port |
| `5438` | `pampa-dev-postgres` (postgres:18-alpine) | **Kiri container** | stops when Kiri stops |
| `5439` | `second-brain-pg` (17.11) | launchd `com.alejandrodelvillar.second-brain-pg` | second-brain only |
| `60373` | `openbot-desktop-postgres-1` (**pgvector/pg17**) | **podman container** | OpenBot only |

Four of the five are reclaimable by dev work that does not touch them. The earlier claim that "no
Postgres is on the MCP path" still holds — `kanzo` is SQLite — but the *machine* has five, and a
quiet mode that stops "Postgres" as a class would break Pampa, the second brain, and OpenBot at once.

## 6. Bundles this addendum adds

**`containers-idle`** — stop Kiri's two containers and OpenBot's five, then the VMs. Reclaims the
largest block on the machine; requires the absolute `podman` path and a `kiri stop` step before the
daemon.

**`inference-local`** — `stop` llama-server (`:8901`) and mlx-lm (`:8080`); leave Laya alone (nothing to
stop, 180 s to rebuild); stop Ollama (free).

**`never-cold`** — the anti-bundle, and a genuine design idea: entries whose *absence* costs minutes.
Laya (180 s) and mlx-lm's 9B model belong here. A user choosing "quiet" should see this list and be
told what it will cost them later, not just what it frees now.

## 7. Hazards added

1. **Two engines, one socket.** `/var/run/docker.sock` → podman; `kiri` has its own runtime. Any
   command that assumes "docker" means one of them is wrong, and `kiri images` showing
   `ghcr.io/copilotkit/*` proves the image names cannot be used to infer which engine owns what.
2. **`podman` is not on `PATH`.** Every recipe must use `/opt/podman/bin/podman`. A catalog entry that
   shells out to `podman` will fail in a launchd context (which has a minimal PATH) — the same trap
   `gitea-runner` documents in its own plist.
3. **Kiri is `KeepAlive`.** Booting it out and forgetting it means the next `kiri` command or app
   launch restores five gigabytes of VM and both containers.
4. **The k3s node is a control plane**, not a toy: port 6443 bound inside the VM. Killing it mid-run
   can leave a half-registered cluster that OpenBot's eval harness then fails against.
5. **Laya's cold start is 180 s**, and it is invisible — nothing listens, nothing appears in `ps` as a
   server. A quiet mode that reports "suspended: nothing" and then costs three minutes is worse than
   no quiet mode.
6. **OpenBot re-spawns itself.** Its stack is managed by the Desktop app, so `podman machine stop`
   while OpenBot is open is a race the app wins.

## 8. Gaps

- Podman machine CPU/memory allocation: settings file not found on disk. Close with
  `/opt/podman/bin/podman machine inspect` (a human shell; the CLI is not on `PATH`).
- Whether `bootout dev.kiri.daemon` stops the VM cleanly (**UNVERIFIED**).
- Which mlx-lm model is resident (**UNVERIFIED**).
- Whether OpenBot's stack survives an app quit or is torn down by it (**UNVERIFIED**).
- Why Kiri's `:443`/`:80` router serves — which dev hostnames map where. `~/.kiri/files` holds only
  `nfs.sock`, so the route table is not in plain sight.
