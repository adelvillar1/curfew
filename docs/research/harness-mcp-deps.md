# Harness MCP dependency graph — DSH Fleet + Zcode on this Mac

> **STATUS — 2026-11-24.** The `fleet` *agent* (the Rust CLI, its memories, its 38 modified memory files,
> its `~/.fleet` home) is **retired** by the owner: "forget about fleet; if I ever want to resurface it
> I'll pull it from Gitea." But the **repo is still load-bearing**, and this is the trap worth recording:
> the five DSH MCP servers are Python entrypoints *inside it* —
> `~/Projects/fleet/services/{sys1,sdm1,sem1,gen1,blend1}/service/mcp_server.py`, with a matching
> `*_PYTHONPATH` pointing at each `services/<name>/src`. Delete `~/Projects/fleet` and the harness loses
> sys1/sdm1/sem1/gen1/blend1 — its decision models, embeddings, skill selection and image generation —
> even though the fleet *agent* is dead. `~/.fleet/venvs/laya` is likewise referenced from
> `services/sys1/src/sys1/config.py:194`. **The reclaimable 15 GB is `~/Projects/fleet/target`** (Rust
> build output, gitignored); `services/` is 4.4 MB and must stay.

Measured 2026-11-24 ~19:45 CST (uptime 33 d), uid 501, macOS 26.5.2 arm64, host `alejandros-macbook-air-1`.
Every row traces to a file read, a `launchctl print`, an `lsof` socket, or a process listing. Where a
behaviour could not be proven without mutating state it is marked **UNVERIFIED**.

**Constraints hit during the survey (recorded so the missing evidence is honest):** `/bin/ps` is blocked by
the session sandbox (`Operation not permitted`), so process ancestry comes from `pgrep -fl` / `pgrep -P` /
`lsof -p`; `tailscale` (`/usr/local/bin/tailscale` shim) dies with `Trace/BPT trap: 5` under this sandbox, so
`tailscale serve status` is the one config not read directly — the 8443/8444 mappings below are proven from
accepted/dialled socket pairs and the bridge's own access log instead. All secrets redacted as `<redacted>`.

---

## 1. DSH Fleet — live MCP inventory (6 servers)

The DSH Fleet app (`/Applications/DSH Fleet.app`) runs **two** harness servers from two profiles:

| Role | Process | Profile | Listener |
|---|---|---|---|
| Desktop GUI (this session) | PID **80538**, cwd `~/.dsh/profiles/desktop` | `desktop` | `127.0.0.1:57730` |
| Web/remote instance | PID **42328** `…/dsh/lib/bin.js --profile web --port 57801 --host 127.0.0.1 --no-open --public-url https://alejandros-macbook-air-1.tail9d0d4c.ts.net:8444/ --trusted-host alejandros-macbook-air-1.tail9d0d4c.ts.net:8444` | `web` | `127.0.0.1:57801` |

MCP servers are declared by the profile's *bundles*, not by a single mcp.json:

- `~/.dsh/profiles/desktop/package.json` → `dsh.profile.bundles: [dsh-base, dsh-web-app, …voice/plugin-market/auto-review/forge,
  @local/fleet-lanes, @local/hygiene, @local/brain, @local/decisions, @local/select, @local/second-brain, @local/vault, @local/kanzo]`
- `~/.dsh/profiles/desktop/cordis.patch.yml` — model/providers, `trustedHosts: alejandros-macbook-air-1.tail9d0d4c.ts.net:8444`, and an `insert:` of `@deepseek-ai/dsh-client-remote-connection`
- `~/Projects/dsh-salvage/lanes-mcp/cordis.patch.yml` — the five stdio lane servers
- `~/Projects/dsh-salvage/kanzo/cordis.patch.yml` — the one HTTP server

| # | MCP name | Transport | Exact command / URL | cwd | Env var NAMES | Enabled |
|---|---|---|---|---|---|---|
| 1 | `sys1` | stdio | `python3 -u /Users/alejandrodelvillar/Projects/fleet/services/sys1/service/mcp_server.py` | inherited from server | `SYS1_PYTHONPATH` | yes, `failOnStartupError: true` |
| 2 | `sdm1` | stdio | `python3 -u …/fleet/services/sdm1/service/mcp_server.py` | inherited | `SDM1_PYTHONPATH` | yes, `failOnStartupError: true` |
| 3 | `sem1` | stdio | `python3 -u …/fleet/services/sem1/service/mcp_server.py` | inherited | `SEM1_PYTHONPATH` | yes, `failOnStartupError: true` |
| 4 | `gen1` | stdio | `python3 -u …/fleet/services/gen1/service/mcp_server.py` | inherited | `GEN1_PYTHONPATH` | yes, `failOnStartupError: true` |
| 5 | `blend1` | stdio | `python3 -u …/fleet/services/blend1/service/mcp_server.py` | inherited | `BLEND1_PYTHONPATH` | yes, `failOnStartupError: true` |
| 6 | `kanzo` | streamable-http | `http://127.0.0.1:4242/mcp` | n/a | none | yes, `failOnStartupError: false` |

Live proof of the five stdio children (all `pgrep -P 80538`, i.e. spawned by the desktop server itself):
`80605` sys1, `80616` sdm1, `80627` sem1, `80638` gen1, `80649` blend1 — all
`/opt/homebrew/Cellar/python@3.15/…/Python -u …/services/<lane>/service/mcp_server.py`.

**Disjoint second registry — NOT DSH Fleet.** `~/.fleet/mcp.json` (`{servers:{…}}`, 9 entries) is the **fleet
CLI** harness's own registry (`fleet mcp`, four-harness scan+import — `~/.dsh/memories/fleet-mcp-server-registry-plan-unbuilt.md`,
`…/mcp-registry-live-import-state.md`, which records "*the imported servers are ballast fleet never uses*").
No DSH profile bundle reads it, and its supervisor `com.fleet.gui` is **not loaded** (§4). Rows, for completeness:

| name | transport/command | enabled | probe state in mcp.json |
|---|---|---|---|
| cloudflare | stdio `npx -y mcp-remote@latest https://mcp.cloudflare.com/mcp` | **yes** | ok, 5 tools, 2026-11-24T14:15Z |
| dappier | stdio `npx mcp-remote "https://mcp.dappier.com/mcp?apiKey=<redacted>"` | **yes** | ok, 8 tools — *key is embedded in the URL* |
| filesystem | stdio `npx -y @modelcontextprotocol/server-filesystem ~/Desktop ~/Downloads` | **yes** | ok, 16 tools |
| computer-use | stdio `./Codex Computer Use.app/…/SkyComputerUseClient mcp` | no | fail: `No such file or directory` |
| fli | stdio `/Library/Frameworks/Python.framework/Versions/3.13/bin/fli-mcp` | no | fail: `fastmcp` ImportError (server support not installed) |
| github | stdio `docker run -i --rm -e GITHUB_PERSONAL_ACCESS_TOKEN ghcr.io/github/github-mcp-server` | no | fail: `GITHUB_PERSONAL_ACCESS_TOKEN` resolves to nothing |
| node-code-sandbox-mcp | stdio `npx -y node-code-sandbox-mcp` | no | fail: `FILES_DIR` unset |
| node_repl | stdio `/Applications/Codex.app/…/node_repl` (15 env NAMES incl. `CODEX_HOME`, `SKY_CUA_SERVICE_PATH`) | no | fail: `NODE_REPL_NATIVE_PIPE_CONNECT_TIMEOUT_MS` unset |
| openweather | stdio `docker run -i --rm -e OWM_API_KEY mcp/openweather` | no | fail: `OWM_API_KEY` unset |

---

## 2. Zcode — MCP inventory (3 configured + 15 plugin-provided = 18 names)

Config-level, from `~/.zcode/cli/config.json` → `mcpServers` (`~/.zcode/v2/config.json` has only `provider`):

| MCP name | Transport | Exact command / URL | cwd | Env NAMES | Enabled |
|---|---|---|---|---|---|
| `memory` | stdio | `node /Users/alejandrodelvillar/Projects/agnostic-router-kit/bin/agnostic-router-memory.mjs` | inherited | `MEMORY_FILE_PATH` (`~/.agnostic-router-kit/memory/memory.jsonl`, exists, 274 KB) | yes |
| `openship` | http | `https://app.openship.io/api/mcp` + `Authorization: Bearer <redacted>` | n/a | none | yes |
| `cloudflare` | stdio | `npx -y mcp-remote@latest https://mcp.cloudflare.com/mcp` | inherited | none | yes |

Plugin-provided (`.zcode/cli/plugins/installed_plugins.json`: 17 plugins installed, **all enabled** in
`config.json → plugins.enabledPlugins`; each declares `mcpServers` in `.mcp.json` or `.zcode-plugin/plugin.json`):

Names, all `stdio`, all with `command` resolved from the plugin directory (13 plugins → 15 names):
`autoresearch`, `deckcraft`, `gridcraft`, `wordcraft`, `pdfcraft`, `photocraft`, `soundcraft` — `node …`, no port;
`image_generation`, `video_generation`, `happyhorse_video`, `meshy_3d` — `node …`, remote media API only;
`video-edit` (video-agent-kit) and `runtime` + `video` (video2code) — `python3 …`, no port;
`jev` (jev-decisions) — `npx …`, remote System One/Fastino API. Declared in each plugin's `.mcp.json` or
`.zcode-plugin/plugin.json`.

All plugin servers are **stdio, spawned on demand by the Zcode app**; none binds a port. Zcode itself is a
separate Electron app (`/Applications/ZCode.app`, running) whose model router is §4.

---

## 3. Backing-process map (MCP → binary → port → listener → launchd → plist → state)

| MCP server | Needs at runtime | Port | Listening process (pid) | launchd label | Plist | State |
|---|---|---|---|---|---|---|
| `sem1` | llama-server embeddings at **127.0.0.1:8901** (`sem1/mcp_server.py:9` default `http://127.0.0.1:8901/v1/embeddings`; tool arg `endpoint` overridable) | 8901 | `llama-ser` **27468** (`--embedding --port 8901 --host 127.0.0.1`, embeddinggemma-2-BF16) | `com.adelvillar1.sem1-llama` | `~/Library/LaunchAgents/com.adelvillar1.sem1-llama.plist` | running, pid 27468, runs=11, last exit reason `OS_REASON_CODESIGNING` |
| `blend1` | *semantic lane*: `BLEND1_SEMANTIC_ENDPOINT` default `http://127.0.0.1:8901` (`blend1/src/blend1/env.py:28`); synthesis/escalation over remote APIs (`LIQUID_API_KEY`, `FASTINO_API_KEY`, `DASHSCOPE_API_KEY`, `STEPFUN_API_KEY`, `OLLAMA_API_KEY`) | 8901 | as above (27468) | as above | as above | running |
| `sys1` | no local socket found; providers are remote (`FASTINO_API_KEY`, `NACE_API_KEY`, `DREX_API_KEY`, `LIQUID_API_KEY`, `OPENJEV_API_KEY`, `CLM_API_KEY`, `LAYA_API_KEY`, `KEV_API_KEY`, `CANDIDATE_TOKEN/CORE_TOKEN/ALL_TOKEN`) | — | — | — | — | purpose of each provider **unverified** beyond env names |
| `sdm1` | hosted TabPFN `https://api.priorlabs.ai` / `https://ux.priorlabs.ai` with `TABPFN_API_KEY`; alternative in-context backend needs `SDM1_MODELS_PYTHON`/`SDM1_MODELS_VENV` (`sdm1/src/sdm1/providers/nvidia_sdm.py:134`). **No local port.** | — | — | — | — | n/a |
| `gen1` | remote APIs (`DASHSCOPE_BASE_URL`, `QWEN_BASE_URL`, `QWEN_TTS_WS_URL`, `STEPFUN_BASE_URL`); local assets downloaded from `github.com/thewh1teagle/kokoro-onnx` releases (kokoro-v1.0.onnx + voices-v1.0.bin) | — | — | — | — | no local listener |
| `kanzo` | the Kanzo board daemon, **SQLite** store — *not* Postgres: `~/kanzo/kanzo.db` (86 KB) + `kanzo.lock` + `config.toml`; binary `/Users/alejandrodelvillar/.cargo/bin/kanzo --no-open` | 4242 (v4 `127.0.0.1` + v6 `[::1]`) | `kanzo` **48402** (cwd `/private/tmp`, stdout `/private/tmp/kanzo-board.log`) | **none — no launchd job** | — | running, unmanaged |
| `dev.dsh.bridge` (MCP *server* for external clients) | its own HTTP listener + **kanzo** upstream; memories from `~/.dsh/memories/*.md` | 7426 | `node …/dsh-salvage/bridge/bridge-mcp.mjs` **28157** (cwd `/`) | `dev.dsh.bridge` | `~/Library/LaunchAgents/dev.dsh.bridge.plist` | running, pid 28157, runs=2 |
| fleet CLI `filesystem`/`cloudflare`/`dappier` | `npx`/`docker` from PATH + outbound HTTPS | — | — | — | — | registry only; no DSH consumer |
| Zcode `memory` | `node` + `~/.agnostic-router-kit/memory/memory.jsonl` | — | — | — | — | file-only |
| Zcode `openship`, `cloudflare`, `jev`, 11 craft plugins | outbound HTTPS + vendored `node`/`python3`/`npx` | — | — | — | — | no local listener |

---

## 4. Local harness service inventory (requested labels + what actually backs them)

Chain format: **label → program → port → pid → state**. `launchctl print gui/501/<label>` unless noted.

| Label | Program | Listens | State today | Needed by an unattended DSH run? |
|---|---|---|---|---|
| `dev.dsh.bridge` | `/opt/homebrew/bin/node …/bridge/bridge-mcp.mjs` | `127.0.0.1:7426` | **running**, pid 28157, runs=2 | Only if an external MCP client (OpenBot) calls in. Its `kanzo_*` tools need 4242. |
| `com.fleet.gui` | `~/.fleet/bin/fleet gui --no-open --remote --relay https://fleet.opsh.io --bot-relay https://fleetbot.opsh.io` | — | **not loaded** (`Could not find service "com.fleet.gui"`) | No. Different harness (fleet CLI). |
| `com.alejandrodelvillar.zcode-model-router` | `~/.local/bin/node ~/.zcode/router/server.js` | `127.0.0.1:8300` | **running**, pid 1144, runs=1 | No — Zcode only. |
| `com.zcode.model-router` | same `server.js` | — | **crash-loop**: state `spawn scheduled`, **runs=255645**, last exit `78: EX_CONFIG`, `keepalive=0` | No — but it is a live CPU hazard (§7). |
| `com.agnostic-router.model-router` | same `server.js` | — | **crash-loop**: state `spawn scheduled`, **runs=255646**, exit `78: EX_CONFIG` | No — duplicate of the above. |
| `com.opencodex.proxy` | `/bin/sh -lc … OPENCODEX_API_AUTH_TOKEN=<redacted> …` (bun `opencodex start --port 10100`, pid 1154) | `127.0.0.1:10100` | **running**, pid 1154 | No. |
| `com.adelvillar1.sem1-llama` | `~/.unsloth/llama.cpp/build/bin/llama-server -m …embeddinggemma-2-BF16.gguf --embedding --port 8901` | `127.0.0.1:8901` | **running**, pid 27468 | **Yes** — `sem1` MCP + `brain`/`select` embeddings. |
| `com.adelvillar1.blend1-service` | `Projects/blend1/service/.venv/bin/uvicorn service.main:app --host 127.0.0.1 --port 8420` | `127.0.0.1:8420` | **running**, pid 95539, runs=2 | No proven link to the `blend1` MCP (that child imports `fleet/services/blend1/src` in-process, a different tree). Purpose **unverified**. |
| `com.alejandrodelvillar.second-brain-pg` | `postgres -D /opt/homebrew/var/postgresql@17 -p 5439 -c listen_addresses=127.0.0.1` | `127.0.0.1:5439` | **running**, pid 6563, runs=27010, last exit 1 | Only for `second_brain_*` tools (through the tower). |
| `com.alejandrodelvillar.second-brain-tower` | `~/.second-brain/.venv/bin/python control_tower.py serve 4175` | `127.0.0.1:4175` | **running**, pid 2268, runs=2 | Only for `second_brain_status` / `second_brain_run`. `control_tower.py` references postgres but the DSN was not read — PG 5439 dependency **UNVERIFIED**. |
| `ai.openclaw.gateway` | — | — | **not loaded** | No. |
| `ai.perplexity.xpc` | plist exists → `…/PerplexityXPC.xpc/Contents/MacOS/PerplexityXPC` | — | **not loaded** | No (XPC, on-demand by another app). |
| `com.openai.chat-helper` | no plist in `~/Library/LaunchAgents` | — | **not loaded / not present** | No. |
| `homebrew.mxcl.cliproxyapi` | `/opt/homebrew/opt/cliproxyapi/bin/cliproxyapi` | `127.0.0.1:8317` | **running**, pid 1161 | No (LLM proxy for other CLIs). |

Also observed, not on the requested list: `dev.kiri.daemon` (kiri, `*:443`,`*:80`,`*:5438`, pid 74620);
`sh.brew.postgresql@18` (59588, `127.0.0.1:5432`); `sh.brew.postgresql@14` (**crash-loop**: `spawn scheduled`,
runs=81570, exit 1 — yet pid 39307 still listens on `127.0.0.1:5434` with cwd `/opt/homebrew/var/postgresql@14`,
an orphan from the loop); `sh.brew.mlx-lm` (48721, 8080); `com.workbuddy.converter` (1150, 8787); unmanaged
`opencode serve --port 4096`, `python3 -m http.server 8099` (33721), `node /tmp/omni-capture-server.mjs 3999`
(18514, **running from `/tmp`**), `kimi-webbridge` (1308, 10086), Ollama (11434), podman `gvproxy`
(3001/3010/4100/4215/59740/59951-3/60373), OpenBot CLI (59954).

---

## 5. The remote-access path (highest hazard)

Two Tailscale-served HTTPS authorities terminate in the **IPNExtension** process (pid 97831) and are dialled
into **loopback** — the listen sockets and the accepted/dialled pairs are the proof:

```
IPNExtension 97831  27u  TCP 100.x.y.z:8443 (LISTEN)     29u  TCP 100.x.y.z:8444 (LISTEN)
IPNExtension 97831  28u  TCP [fd7a:115c:a1e0::d92a:782c]:8443 (LISTEN)
IPNExtension 97831  30u  TCP [fd7a:115c:a1e0::d92a:782c]:8444 (LISTEN)
```

**8444 → the DSH *web* server (57801).** Live socket pair:
`IPNExtens 97831 100.x.y.z:8444->100.x.y.z:54400 (ESTABLISHED)` and
`IPNExtens 97831 127.0.0.1:54401->127.0.0.1:57801 (ESTABLISHED)` together with
`DSH Fl 42328 127.0.0.1:57801->127.0.0.1:54401 (ESTABLISHED)`. The desktop window's own network helper also
uses this authority: `DSH Fl 80524 100.x.y.z:51650->100.x.y.z:8444` / `IPNExtens 8444->51650`.

**8443 → the bridge (7426).** No client was connected at sample time, so the mapping is proven from the
bridge's own log instead of a pair: `~/.dsh/bridge-access.log` contains only `peer":"127.0.0.1"` rows whose
`host` is `alejandros-macbook-air-1.tail9d0d4c.ts.net:8443` —
e.g. `{"at":"2026-11-25T01:45:37.65Z","event":"request","peer":"127.0.0.1","host":"…ts.net:8443","method":"tools/call","tool":"kanzo_list_tasks"}`.
The bridge announces itself on start: `~/.dsh/bridge.out.log` → `dsh bridge on http://127.0.0.1:7426/mcp (key configured)`,
and `~/Projects/dsh-salvage/bridge/README.md` records the exact command
`tailscale serve --bg --https=8443 http://127.0.0.1:7426` (and why 8443 and not 443: "Kiri already listens on 443").

Path a remote session traverses: **client → Tailscale (IPNExtension, 8443/8444) → 127.0.0.1 loopback → either
`bridge-mcp.mjs:7426` (401 unless `Authorization: Bearer <key>` matches `~/.dsh/bridge.key`, 0600, 65 bytes)
→ `kanzo:4242`; or `dsh --profile web:57801` → the harness → stdio lane children.**

**What breaks if suspended.** Killing or freezing Tailscale removes *both* 8443 and 8444: the bridge becomes
unreachable from outside and the DSH GUI stops answering on the tailnet; remote sessions in flight drop mid-turn
(the harness keeps running locally but the transport is gone). Freezing IPNExtension instead of stopping it is the
worse failure: the TCP listener stays bound, so clients connect successfully and then wait — a silent hang, not an
error. The bridge and 8444 are **different processes with different profiles** — see hazard §7.1.

---

## 6. The two bundles

### `harness-core` — minimum for an unattended DSH Fleet run to keep working

- **The Electron app + its embedded harness server** — `DSH Fleet` main, pid 80538, `127.0.0.1:57730`
  (cwd `~/.dsh/profiles/desktop`); killing it takes the whole agent tree.
- **The five stdio lane MCP children** — `80605` sys1, `80616` sdm1, `80627` sem1, `80638` gen1, `80649` blend1
  (`python3 -u …/fleet/services/<lane>/service/mcp_server.py`). They are children of 80538 and die with it;
  they must not be signalled individually.
- **`com.adelvillar1.sem1-llama`** — llama-server, `127.0.0.1:8901`, pid 27468. Backs `sem1` *and* the
  `brain`/`select` embedding paths (`embeddingUrl: http://127.0.0.1:8901` in
  `~/Projects/dsh-salvage/{brain,select}/cordis.patch.yml`). Without it: no recall, no skill selection, `sem1_embed` fails.
- **`kanzo` board** — `~/.cargo/bin/kanzo --no-open`, `127.0.0.1:4242`, pid 48402, store `~/kanzo/kanzo.db`.
  No launchd job exists, so a stop is **not reversible by launchctl** — restart recipe must be recorded by hand.
- **`dev.dsh.bridge`** — `127.0.0.1:7426`, pid 28157 + `~/.dsh/bridge.key` — only when an outside MCP client is
  part of the run (it is the only way OpenBot reaches this Mac).
- **Tailscale (`IPNExtension`)** — 8443/8444 — only when the run is driven remotely. Never suspend it. Also
  required for `https://…:8444` links the harness itself prints.
- **Network egress** — every enabled MCP server's model calls go off-box (`api.priorlabs.ai`, Fastino/Liquid/
  StepFun/DashScope, MCP endpoints); no local DB or queue is on the critical path.
- **Explicitly NOT core:** any Postgres (no enabled MCP server uses one — kanzo is SQLite), `second-brain-*`,
  `blend1-service:8420`, `mlx-lm:8080`, `cliproxyapi:8317`, `opencodex:10100`, the Zcode router, gitea runners.

### `harness-optional` — configured but not needed for a typical run

- `com.alejandrodelvillar.second-brain-tower` (4175) + `com.alejandrodelvillar.second-brain-pg` (5439) — needed
  only by `second_brain_run` / `second_brain_status`; safe to lazily start.
- `com.adelvillar1.blend1-service` (8420) — purpose unverified; the `blend1` MCP does not obviously use it.
- `sh.brew.mlx-lm` (8080), `com.workbuddy.converter` (8787), `com.opencodex.proxy` (10100),
  `homebrew.mxcl.cliproxyapi` (8317), `opencode serve` (4096), `kimi-webbridge` (10086), Ollama (11434).
- `com.alejandrodelvillar.zcode-model-router` (8300) and the two crash-looping router labels — Zcode-only.
- All 15 Zcode plugin MCP servers + `memory`/`openship`/`cloudflare` — spawn on demand inside the Zcode app;
  nothing to suspend but the app.
- The fleet CLI registry rows (`cloudflare`, `dappier`, `filesystem`) — disabled by absence of a consumer; the
  `filesystem` row is a live grant over `~/Desktop` and `~/Downloads` if ever used.
- `sh.brew.postgresql@14` / `@18`, gitea runners, Kiri, OpenBot, podman `gvproxy`, ad-hoc listeners on
  3999/8099 — unrelated to any harness MCP call.

---

## 7. Gaps and hazards

1. **The remote session does not get the desktop profile's tools.** 8444 terminates at pid 42328
   (`--profile web`), whose bundle list is only `@deepseek-ai/dsh-base` + `@deepseek-ai/dsh-web-app`
   (`~/.dsh/profiles/web/package.json`) — **no lanes, no kanzo, no brain/select/second-brain**. The `trustedHosts`
   and `remote-connection` insert for `…ts.net:8444` live in the *desktop* profile patch
   (`~/.dsh/profiles/desktop/cordis.patch.yml`). So an unattended run driven over Tailscale is a
   tool-poorer harness than the same run at 57730; the two must not be assumed equivalent.
2. **SIGSTOP on any socket holder is a silent hang, not an error.** Freezing 8901 (llama-server) makes every
   `sem1_embed`, `sem1_search`, `select_skills`, `brain_recall` and `blend1` call block with no timeout in the
   MCP client contract. Freezing 4242 leaves the bridge's `kanzoPost` waiting forever — `bridge-mcp.mjs:48-92`
   has **no request timeout**, only an `error` handler, so a frozen Kanzo is indistinguishable from a slow one.
3. **`kanzo` and the ad-hoc listeners have no supervisor.** 4242 (kanzo), 4096 (opencode), 8099
   (`http.server`), 3999 (`/tmp/omni-capture-server.mjs`) are hand-started; a stop is one-way until a human
   restarts them. Only 7426, 8901, 8420, 4175, 5439, 57730/57801 have a launchd or app owner.
4. **Lane servers fail hard at start, kanzo fails soft.** `lanes-mcp/cordis.patch.yml` sets
   `failOnStartupError: true` for sys1/sdm1/sem1/gen1/blend1 — a missing `python3 -u …mcp_server.py` aborts
   profile startup, taking the session with it; `kanzo/cordis.patch.yml` uses `false` deliberately ("keeps a
   session starting when the board is not running"). Suspending 8901 does **not** trip this (it is a runtime
   dependency), but a stopped `kanzo` silently degrades to "connection refused" per tool call.
5. **Three overlapping router definitions and two hot crash-loops.** `com.zcode.model-router`,
   `com.agnostic-router.model-router` and `com.alejandrodelvillar.zcode-model-router` all run the same
   `~/.zcode/router/server.js`; two are at `runs≈255,645` with exit `78: EX_CONFIG` and
   `sh.brew.postgresql@14` is at `runs=81570` exit 1 while a stray `postgres@14` (pid 39307, port 5434)
   survives outside the job. These will look "busy" in any sampling and will re-spawn if merely signalled.
6. **Secrets sit in world-readable or plaintext places the tool must never echo:** the fleet GUI plist carries
   `FLEET_RELAY_JOIN_SECRET` / `FLEET_BOT_RELAY_JOIN_SECRET` as plain `<string>` values at mode 0644;
   `~/.zcode/cli/config.json` embeds a provider `apiKey` inline; `~/.fleet/mcp.json` carries the dappier key
   inside the URL query. Any journal or log line that copies a plist or an mcp.json will leak them.
7. **Zcode's MCP surface is 18 stdio servers spawned by the app** — there is nothing to suspend at the daemon
   level, and no port to free. Suspending the Zcode app itself stops all 18; nothing else on the machine depends
   on them.
8. **UNVERIFIED:** whether `tailscale serve` 8444 uses `--bg` persistence across a tailscaled restart (CLI
   unusable here); whether the `blend1` MCP ever calls `blend1-service:8420`; the tower's Postgres DSN; the
   purpose of sys1's provider tokens. Each needs a non-sandboxed read or a controlled mutation.
