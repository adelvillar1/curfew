# Curfew — Blueprint

> The design synthesis. Three research passes (`core-os-services.md`, `dev-toolchains.md`,
> `harness-mcp-deps.md`) plus the feasibility assessment, reduced to the decisions code must follow.
> Where this document and a research doc disagree, this document wins and the research doc gets fixed.

---

## 1. What the machine actually told us

| Finding | Number | Why it changes the design |
|---|---|---|
| System plists that register a `MachServices` port | **733 of 887 (83%)** | Freezing is dangerous *by default*. The safe lever has to be per-service, not the default action. |
| System plists with `EnablePressuredExit true` | **556 of 887** | Two thirds of the system has already told launchd "you may take me under pressure". Those are the tool's best citizens. |
| System plists with `LaunchEvents` | **453 of 887 (51%)** | Half of everything relaunches itself after a successful `bootout`, on an event you did not cause. `bootout` alone is not a quiet mode. |
| Third-party services in `gui/501` | **35** of 282 rows | The product's whole surface is 35 things, ~30 of which are vendor up**daters**. |
| What the user-domain launchd layer contributes to `pnpm build` / `uv sync` / `cargo build` | **effectively zero** | A build is node/git/rustc/uv (plain processes) plus four Apple daemons. Aggressive quiet mode on `~/Library/LaunchAgents` is *safe by construction* — the asymmetry that makes the product viable. |
| Two launchd jobs respawning forever | **255,645 and 255,646 runs**, exit `78: EX_CONFIG` | The single biggest measured waste on the box is not a vendor updater. It is a crash loop the user does not know about. |
| `sh.brew.postgresql@14` | **81,570 runs**, exit 1, orphan still holding `:5434` | Same class, plus a zombie: the job is dead but a hand-started postgres survives it. |
| Swap / compressor / free disk | 5.4 GB of 7.1 GB / ~4.2 GB / 60 GB of 460 GB (86% used) | Memory is the pressure, so **stop beats freeze**. Disk is fine; caches are 20+ GB and are an asset (offline builds work). |

**The reframe.** The product was conceived as "suspend vendor background noise." The machine says the
two things worth building are (a) a *safe, reversible* quiet mode for the 35-service third-party layer,
and (b) a **crash-loop and zombie detector** that finds jobs spawning tens of thousands of times. (b) is
free to compute, impossible to get wrong, and immediately valuable — and nobody ships it.

**And the biggest footprints are not launchd services at all** (`docs/research/containers-and-engines.md`,
survey before the 2026-11-24 cleanup — see that document's status banner for what has since been removed):

| Footprint | Verified then | What it hosted |
|---|---|---|
| **Kiri** VM, 4 CPU / **5,120 MiB** | `dev.kiri.daemon`, Server `27.5.1`, `OS: Kiri` | `pampa-dev-postgres` (`:5438`), a layerfs worker, an HTTPS dev router on `:443`/`:80` — **now only pampa remains** |
| **OpenBot Desktop** stack in a podman VM | app v1.1.2 on `:59954` + 5 containers | server, agent-computer, langgraph harness, pgvector Postgres, **a k3s control plane** — **removed entirely 2026-11-24** |
| ~~mlx-lm~~ `:8080` | `mlx_lm.server` | `Ornith-1.5-9B-MLX-4bit` + `Qwen3.5-0.8B` — **weights deleted, service stopped** |
| **llama-server** `:8901` | launchd `sem1-llama` | `embeddinggemma-2-BF16` — backs sem1, brain, select, blend1; **untouched** |

The lesson the cleanup paid for: **a container-engine deletion is a VM-side win, not a host-side one.**
Kiri's `data.img` refuses discard, so pruning 17 GB inside the VM returned zero host bytes. Curfew must
report which side of a VM a reclaim happens on, and never claim host space from a container prune.

Both container stacks were idle with respect to DSH Fleet and Zcode. Neither was reachable with a
launchd verb: the levers were `kiri stop` + daemon bootout, and
`/opt/podman/bin/podman machine stop` (the `podman` binary is **not on `PATH`**).

## 2. Three surfaces, not one

| Surface | What it is | Count here | Default |
|---|---|---|---|
| **Vendor noise** | Updaters, sync agents, app launchers | ~30 | suspend on apply |
| **Dev infrastructure** | Postgres, model servers, runners, proxies, the harness | ~15 | **protect** |
| **Apple weight** | Tier-2 agents: media analysis, photo analysis, widgets, Siri inference | 29 classified | opt-in per label only |

And one surface that is never touched: the **remote path** (Tailscale `IPNExtension`, `sshd`, the DSH
bridge, and Curfew's own ancestry).

## 3. The lever is a property of the service

The catalog is not a list of labels with a global strategy. Every entry names its own recipe:

| Lever | When it is correct | Where it fails |
|---|---|---|
| `freeze` (`SIGSTOP`) | GUI app, no socket, no port | any server: clients hang with no timeout |
| `stop` (`bootout`) | stateless agent, app launcher, no in-memory state | anything mid-write; anything with `LaunchEvents` comes back |
| `disable` (+`bootout`) | vendor agent that re-registers on app launch | persisting a decision the user forgot |
| `throttle` (`taskpolicy -b`, `renice`) | too risky to stop, but competing for CPU | nothing — fully reversible |
| **`command`** | the vendor shipped the correct off switch | anything without one |

`command` is the addition the research forced, and it is the most important row:

- **Spotlight** → `mdutil -a -i off` / `-i on` (root). Not a freeze: freezing `mds` hangs every
  Spotlight query, and `mds` holds four Mach ports.
- **Time Machine** → `tmutil stopbackup` / `disable`. Not a launchd job at all.
- **Postgres** → `pg_ctl stop -m fast` (or the service's own `ExitTimeOut`), never `SIGSTOP`, never
  `SIGKILL`.
- **Podman/Docker** → `machine stop`, not a kill of `gvproxy`/`krunkit`.
- **Ollama / llama-server** → let them finish the current request; a freeze mid-inference is a hang.

So the catalog entry is: `{ discovery, lever, stop, start, quiesce, hazards, supervision, evidence }`.

## 4. Reversibility is a property of the supervisor, not the service

This is the second thing the research changed. **A service Curfew can stop may be one it cannot start.**

| Service | Supervisor | Consequence |
|---|---|---|
| `sh.brew.postgresql@18`, `sem1-llama`, `dev.dsh.bridge`, `second-brain-*` | launchd job with a plist | `bootout` → `bootstrap` is exact and safe |
| `kanzo` (:4242) | **none** — hand-started, `~/kanzo/kanzo.db`, cwd `/private/tmp` | **a stop is one-way.** Curfew must either refuse to stop it, or record the exact command line and own the restart |
| `opencode` (:4096), `python http.server` (:8099), `/tmp/omni-capture-server.mjs` (:3999) | none | same — and they are running from `/tmp`, so they are already fragile |
| the five lane MCP servers (sys1/sdm1/sem1/gen1/blend1) | **children of the DSH app** | signalling one individually is a bug; the parent owns them |
| `com.zcode.model-router`, `com.agnostic-router.model-router` | launchd, but crash-looping | stopping them is *correct* — this is the health feature, not quiet mode |

Therefore: `supervised: launchd | app-parent | none`, and a policy that `none` may only be stopped
with an explicit recorded restart command and a user confirmation.

## 5. Bundles for this machine

**`vendor-noise`** (default on for easy mode) — Keystone ×2, GoogleUpdater ×2, MS AutoUpdate,
OneDrive ×5, Office licensing ×2, Teams agent, Defender tracer, Zoom ×3, Steam clean, Docker helper,
podman helper, Sparkle `ShipIt` ×4, Perplexity, OpenAI helper, WorkBuddy. All stateless or
launcher-shaped → `stop` + `disable`.

**`dev-idle`** — 3 gitea runners, 3 model routers (2 of which are crash loops), `kanzo`, `kiri`,
`cliproxyapi`, `opencodex`, ollama, mlx-lm, `workbuddy`, `blend1-service`, `second-brain-tower`.
Lazily restartable → `stop`; supervised ones only.

**`data-services`** — `postgresql@18` (:5432), `postgresql@14` (:5434, zombie), `second-brain-pg`
(:5439). `command` lever (`pg_ctl stop -m fast`), never `freeze`, never `SIGKILL`.

**`harness-core`** (never suspended) — DSH Fleet app + its 5 lane children + `sem1-llama` (:8901) +
`kanzo` (:4242) + Tailscale (:8443/:8444) when the run is remote + network egress. Note there is **no
Postgres on the MCP critical path** — kanzo is SQLite.

**`containers-idle`** — Kiri's two containers (stop them first, then the daemon) and OpenBot's five
(podman stack). The largest single reclaim on the machine, and nothing DSH or Zcode needs. Requires
absolute `/opt/podman/bin/podman`; a launchd-context recipe using bare `podman` will fail on PATH.

**`inference-local`** — `stop` llama-server (:8901) and mlx-lm (:8080), stop Ollama (:11434, zero models
loaded). Reversible, but each pays a reload.

**`never-cold`** (the anti-bundle) — entries whose *absence* costs minutes, not whose presence costs
memory. **Laya** (in-process vega engine, `~/.fleet/venvs/laya`, up to **180 s** to reload on first
call after a restart) and mlx-lm's 9B model. A user choosing quiet mode must be shown what it will cost
them later, not only what it frees now.

**`apple-quiet`** (opt-in, per label, dated evidence) — the 16 Tier-2 agents classified `safe`:
`mediaanalysisd`, `photoanalysisd`, `siriinferenced`, `routined`, `chronod`, `knowledgeconstructiond`,
`modelmanagerd`, `mlruntimed`, `parsecd`, `appstorecomponentsd`, `SiriTTSTrainingAgent`, `sirittsd`,
`searchtoold`, `backgroundtaskmanagement.agent`, `mediacontinuityd`, `gamecontrolleragentd`.
**Excluded by hard rule 4** (they hold ports, so freezing hangs their clients): `mds`, `mds.index`,
`corespotlightd`, `corespeechd`, `sharingd`, `rapportd`, `biomed`, `trustd`, `nsurlsessiond`.

**`never`** — Tier 0/1 never-list (28 labels), `sshd`, Tailscale, the DSH ancestry, and
`sysdiagnose`/`spindump` (the diagnostic lifeline for when quiet mode misbehaves).

## 6. Hazards the code must encode

1. **A frozen socket is a hang, not an error.** The bridge's `kanzoPost` has no request timeout
   (`bridge-mcp.mjs:48-92`), so a frozen Kanzo looks like a slow one *forever*. Rule 4 exists for this.
2. **`freeze` Tailscale is worse than `stop`.** MagicDNS is resolver #1 (`100.100.100.100`, order
   100000). Stopped → lookups fall through to `192.168.1.254`. Frozen → every lookup burns its
   timeout and every package manager crawls. Never freeze it; if quieted, stop it and accept the loss
   of remote access.
3. **Half the system relaunches on `LaunchEvents`.** A `bootout` is not a quiet mode without `disable`.
4. **`KeepAlive{PathState}`** (e.g. `mobileassetd` on `/System/Library/PreinstalledAssets`) resurrects a
   job on an unrelated file event.
5. **Unsupervised daemons are a one-way door.** See §4.
6. **App children must never be signalled individually** — the lane servers die with their parent.
7. **Apple labels move between OS releases.** `mds` is `com.apple.metadata.mds`; `dasd` is
   `com.apple.dasd-OSX`; nine plausible spellings do not exist. Discovery by label must be verified
   against the plist, not assumed from a name.
8. **Crash loops look like activity.** A job at `runs=255645` is indistinguishable from a busy job
   unless you read `runs` and `last exit code`. Sample both.
9. **Secrets are in plists and configs Curfew reads.** `com.fleet.gui.plist` has two `FLEET_*_JOIN_SECRET`
   strings at mode 0644; `~/.zcode/cli/config.json` has an inline `apiKey`; `~/.fleet/mcp.json` has a
   key in a URL query. Any log line or journal entry that dumps a plist leaks them. Redact by key name.
10. **The two remote profiles are not equivalent.** `:8444` terminates in the `web` profile
    (`dsh-base` + `dsh-web-app` only) — no lanes, no kanzo, no brain/select. A remotely driven
    unattended run is a tool-poorer harness than the same run at `:57730`. Do not assume parity.
11. **Two container engines share nothing but look alike.** `/var/run/docker.sock` → podman; Kiri has
    its own runtime and reports `OS: Kiri`. `kiri images` lists `ghcr.io/copilotkit/*`, so image names
    cannot tell you which engine owns a container. Never infer ownership from an image.
12. **Kiri is `KeepAlive{SuccessfulExit:false}`** — a bootout that is not followed by `disable` comes
    back the next time anything touches it, VM and containers included.
13. **An in-process engine cannot be suspended, only made cold.** Laya has no port and no process to
    signal; the cost of "quieting" it is a 180 s reload. Reporting "suspended: nothing" while adding
    three minutes to the next sys1 call is worse than doing nothing.
14. **Five Postgres instances, not one class.** `:5432` (main), `:5434` (crash-looping + orphan),
    `:5438` (Kiri container, Pampa), `:5439` (second brain), `:60373` (OpenBot pgvector). A "stop
    Postgres" class action breaks three unrelated things at once.
15. **A retired project can still hold a live dependency.** The `fleet` agent is retired, but the DSH
    harness's five MCP servers are Python entrypoints inside its repo
    (`~/Projects/fleet/services/*/service/mcp_server.py`), and `~/.fleet/venvs/laya` is referenced by
    sys1's config. Curfew's `harness-core` bundle must pin those paths by file, not by the project's
    reputation — and a "delete unused projects" sweep would silently remove the harness's own tools.

## 7. Consequences for the code

- `ServiceCatalog`: entry requires `lever` ∈ {freeze, stop, disable, throttle, command},
  `supervised` ∈ {launchd, app-parent, none, container-engine}, and `kind` ∈ {daemon, app-child,
  container, in-process, command}. A `none` entry without a `restartCommand` is invalid. An
  `in-process` entry (Laya) has no lever at all and carries `coldStartCost` instead.
- `ServiceCatalog` also carries `coldStartCost` and the `never-cold` flag, because a mode that frees
  2 GB and adds three minutes to the next model call is a net loss the user must be told about before
  they choose it.
- `PolicyEngine`: never-list is compiled; Tier 2 requires `apple-quiet` to be explicitly enabled; the
  remote path and Curfew's own ancestry are resolved by walking parent chains, not by name matching.
- `HealthScanner` (new target, and the cheapest product win): reads `runs` and `last exit code` for
  every supervised job, flags `runs > 1000 && exit != 0` and "job dead but its port still bound"
  (the `postgresql@14` pattern). Runs read-only; suggests; never acts unasked.
- `Executor`: journal → quiesce probe → act → verify → report. Verification means re-reading the state
  it just changed, not trusting the exit code.
- `Doctor`: SIP status, helper health, journal integrity, catalog drift from `STATE-SNAPSHOT`, and the
  health scan above.

## 8. Open decisions

1. **Memory or determinism?** Still open. Memory (5.4 GB swap, 4.2 GB compressor) argues stop-first and
   a "reclaimed X MB" headline that needs `footprint` measurement from a normal shell. Determinism
   argues throttle-first and a "nothing competed with your build" headline that needs no measurement.
   The crash-loop finding is a third, cheaper story that sells itself.
2. **Are Apple Tier-2 agents in v1?** They are the loudest targets and the least durable knowledge.
   Recommendation: ship without them, expose the list read-only, enable per label later.
3. **Do we stop unsupervised daemons at all?** Recommendation: no in v1 — report them, refuse to touch
   them, and let `doctor` say "kanzo has no supervisor; stopping it needs a manual restart."

## 9. Plans

1. **`docs/plans/2026-11-24-inventory-and-why.md` (completed 2026-11-24 — 14 of 26 atoms)** — read-only CLI: `list`,
   `why`, `doctor`. Implements this document's §3/§6/§7 with **witr as an optional causality engine**:
   launchd is the truth for job state (`runs`, `last exit`, `disabled`), witr is the truth for process
   ancestry and context, and Curfew owns the join, the classification and the crash-loop verdicts. Ships
   before any mutation exists, guarded by a mechanical read-only test, with a **disagreement policy** that
   always concludes the safe reading (never "nothing here") and logs the evidence from both sources for
   later triage.
2. **`docs/plans/2026-11-24-catalog-schema.md` (draft)** — the YAML schema, loader and a read-only
   `curfew catalog` command. Encodes rule 4 and rule 5 mechanically: `freeze` is illegal on anything
   with a socket, `verified` requires dated evidence, and a never-list label cannot load at all.
   **Execution is explicitly out of scope** — that is L3.3, after the catalog itself is approved.
3. **Journal and restore** — write-ahead journal, fail-open restore, crash test. The first plan that
   mutates, and it must not start before (1) ships.
