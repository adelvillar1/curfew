# dev-toolchains — what a developer on THIS Mac actually needs running

Research for the "minimal required set" that `dev-mode` must let survive quiet/unattended mode.
Measured 2026-11-24 ~19:44–19:50 CST. **Read-only session**: no installs, no `launchctl` mutations,
no service start/stop; every claim carries the command that produced it.

Machine (given, not re-measured): macOS 26.5.2 (25F84, `sw_vers`), arm64, 16 GB
(`sysctl -n hw.memsize`), SIP on, uptime 33 d (`uptime`), swap 5176 MB of 6144 MB (`vm.swapusage`).

**Provenance limits** (see §7): `launchctl list` exits 1 with empty output, `ps -Ao` returns nothing,
`watchman watch-list` is denied on its state dir — my sandbox, not the machine. Service *state* below is
therefore inferred from `lsof` listeners + `pgrep -x` + `plutil -p` on the 30 plists in `~/Library/LaunchAgents`.

---

## 1. Installed toolchain inventory

Versions from `--version`; paths from `which -a` + `ls -l` chain; install source from the symlink
target (`/opt/homebrew/Cellar/...` = Homebrew, `rustup` shim = rustup, `~/.local/bin` loose binary = standalone).

| Tool | Version | Real path | Installed by |
|---|---|---|---|
| node | v26.13.1 | `/opt/homebrew/Cellar/node/26.13.1_4/bin/node` ← `/opt/homebrew/bin/node` | Homebrew |
| node (2nd) | v24.19.0 | `/usr/local/bin/node` (121 MB standalone Mach-O) | unknown pkg — shadowed by brew on PATH |
| npm | 11.20.0 | `/opt/homebrew/lib/node_modules/npm` (prefix `~/.npm-global`) | Homebrew |
| npx | 11.20.0 | `/opt/homebrew/bin/npx` | Homebrew |
| pnpm | 12.23.0 | `/opt/homebrew/lib/node_modules/pnpm/pnpm` ← `~/Library/pnpm/bin/pnpm` (first on PATH) | Homebrew |
| yarn | **unmeasurable** | `/usr/local/bin/yarn` → `../lib/node_modules/corepack/dist/yarn.js` | corepack shim |
| bun | **not installed** | — (`which -a bun` empty; `~/.bun` absent) | — |
| corepack | 0.35.0 | `/usr/local/bin/corepack` | bundled w/ node 24 pkg |
| python3 | 3.15.2 | `/opt/homebrew/Cellar/python@3.15/3.15.2/bin/python3` | Homebrew |
| python3 (also) | 3.14.8, 3.11.x, 3er | `/opt/homebrew/opt/python@{3.11,3.14,3.15}` | Homebrew |
| uv | 0.13.5 (46776a95d 2026-10-21, aarch64-apple-darwin) | `~/.local/bin/uv` (loose 27 MB binary) | standalone installer |
| poetry | **not installed** | — | — |
| pyenv | **not installed** | — | — |
| pipx | 1.17.14 | `/opt/homebrew/bin/pipx` | Homebrew |
| cargo | 1.99.1 (5f94df478 2026-08-27) | `~/.cargo/bin/cargo` → `rustup` shim | rustup |
| rustc | 1.99.1 (58cf8f9c3 2026-10-13) | `~/.cargo/bin/rustc` → `rustup` shim | rustup |
| rustup | 1.29.1 (2026-08-13) | `~/.cargo/bin/rustup` (real 11 MB binary) | rustup |
| rust-analyzer | **BROKEN — no component** | `~/.cargo/bin/rust-analyzer` → shim; `rustup which rust-analyzer` → `error: unknown binary 'rust-analyzer' in toolchain 'stable-aarch64-apple-darwin'` | rustup shim only |
| sccache | 0.19.0 | `/opt/homebrew/bin/sccache` | Homebrew |
| swift / swiftc | Swift 6.3.2, swift-driver 1.148.6, target arm64-apple-macosx26.0 | `/usr/bin/swift`, `/usr/bin/swiftc` | Xcode 26.5 |
| xcrun / xcodebuild | Xcode 26.5 (17F42), SDK macOS 26.5 / iOS 26.5 | `/usr/bin/xcrun`, `/usr/bin/xcodebuild`, developer dir `/Applications/Xcode.app/Contents/Developer` | App Store |
| clang | Apple clang 21.0.0 (clang-2100.1.1.101) | CLT + Xcode | Xcode 26.5 |
| git | 2.56.0 | `/opt/homebrew/bin/git` (Apple's `/usr/bin/git` = 2.50.1, Apple Git-155) | Homebrew |
| git-lfs | 3.8.0 (GitHub; darwin arm64; go 1.27.0) | `/opt/homebrew/bin/git-lfs` | Homebrew |
| gh | 2.102.0 (2026-09-30) | `/opt/homebrew/bin/gh` | Homebrew |
| watchman | 2026.10.12.00 | `/opt/homebrew/bin/watchman` | Homebrew |
| cliproxyapi | 8.0.25 | `/opt/homebrew/Cellar/cliproxyapi/8.0.25/bin/cliproxyapi` | Homebrew |
| postgres | 18.7 / 17.11 / 14.24_1 | `/opt/homebrew/Cellar/postgresql@{18,17,14}/bin/postgres` | Homebrew |
| tsc (project-local only) | 6.0.3 (`deepseek-harness`), 5.9.3 (`cruisingintelligence`) | `node <proj>/node_modules/typescript/bin/tsc` | pnpm/npm dep |
| sourcekit-lsp | Xcode toolchain | `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/sourcekit-lsp` (`xcrun --find`) | Xcode 26.5 |
| clangd / pyright / gopls | **not installed** (`/opt/homebrew/bin`, `~/.local/bin` have none) | — | — |

Absences that change the story: **no bun**, **no global `tsc`/linter** (only per-project deps), **no
rust-analyzer binary** (editor Rust support is broken *today*, independent of dev-mode), **no
nvm/fnm/mise/asdf/volta** (`which -a` empty, no `~/.nvm`) — so Node is whatever Homebrew ships.

`yarn --version` fails before printing: `Error: EPERM: operation not permitted, mkdir
'/Users/alejandrodelvillar/.cache/node/corepack/v1'` — corepack wants to land a download in the cache;
this is my sandbox denying a write, so yarn's *version* is undetermined, not absent. See §7.

---

## 2. Per language: three columns of truth

### 2.1 JavaScript / TypeScript

| Required to build/test offline | Required for the interactive loop | Pure noise during a build |
|---|---|---|
| **Node 26.13.1** (pure user process — no daemon). | `tsserver` — spawned *by the editor*, from `<proj>/node_modules/typescript` (6.0.3 / 5.9.3 present). Not a system service; dies with the editor. | Google Keystone ×2 (`com.google.keystone.agent`, `.xpcservice`) |
| **Network path**: `en0` 192.168.68.60, default gw 192.168.68.1 (`route -n get default`). | **watchman** 2026.10.12.00 — running; used by jest/metro/relay watchers, *not* by `tsc`. | Microsoft AutoUpdate + OneDrive standalones (`/Library/LaunchAgents`) |
| **DNS**: resolver #1 = `100.100.100.100` on `utun4` (Tailscale MagicDNS, order **100000**), resolver #2 = `192.168.1.254` on `en0` (order 200000) — `scutil --dns`. Public names resolve via #2 if #1 is *gone*; they **stall** if #1 is merely *frozen*. | Native **fsevents** path (`fseventsd` pid 336, `pgrep -x fseventsd`) for chokidar/Vite/webpack-watch. | Zoom updaters ×2, Steam clean, Perplexity xpc, WorkBuddy converter |
| **Registry**: no mirror. `pnpm config list` → `"registry": "https://registry.npmjs.org/"`, scopes `@jsr`→`npm.jsr.io`, `npm.pkg.github.com`. `~/.npmrc` sets only `allow-scripts=esbuild`, `ignore-scripts=false`, `prefix=~/.npm-global`. **cliproxyapi on :8317 is NOT a registry proxy** — it is an LLM API proxy (`~/.cli-proxy-api/config.yaml`: `host 127.0.0.1`, `port 8317`, `auth-dir ~/.cli-proxy-api` holding OAuth json; keys redacted). | `eslint`/`vite`/`vitest`/`tsx` resolve from `<proj>/node_modules/.bin` (confirmed in `deepseek-harness`) — a PATH fact, no service. | `sh.brew.mlx-lm`, `com.adelvillar1.sem1-llama`, `.blend1-service`, 3 model routers, kanzo, kiri, DSH bridge — LLM/infra, not JS |
| **Caches**: `~/.npm` 3.0G, `~/Library/pnpm/store` 3.0G, `~/Library/pnpm` 3.5G total (`du -sh`). With those warm, `pnpm install --offline` works with the network down. | Git auth for `pnpm add` from a private registry / `gh` — needs **securityd** (§3). | 3× gitea runners (`sh.brew/s.jobhound/sh.riderscout`) — only when pushing CI |

`git config --global` shows **`core.fsmonitor=false`**, `core.untrackedcache=false`: git is *not* using
watchman/fsmonitor, so `git status` stats the whole tree — a slow-path fact when a build looks "hung".

### 2.2 Python

| Required to build/test offline | Required for the interactive loop | Pure noise during a build |
|---|---|---|
| **uv 0.13.5** as the runtime driver; managed CPython 3.10/3.11/3.12/3.13 on disk (`ls ~/.local/share/uv/python`), plus Homebrew 3.11/3.14/3.15. Live examples: `uv` 3.13.13 on :8787 and :8420, Homebrew 3.14.8 on :4175, 3.15.2 on :8080/:8099 (all via `lsof -p` `txt` entries). | A language server — **none installed**: no pyright/basedpyright in `/opt/homebrew/bin` or `~/.local/bin`. Pylance only exists inside an editor. So Python's interactive loop = editor-owned, nothing to protect here. | OneDrive sync agents (5 jobs in `/Library/LaunchAgents`) — poison for `uv sync` timing |
| **Wheel cache** `~/.cache/uv` **15 G** (14 G in `archive-v0`, 12 M wheels-v6, 648 K wheels-v7) — the single biggest offline asset on this machine. `uv sync` is mostly offline-capable against it. | `~/.local/share/uv/tools` 640 M (`kimi-cli`, `mlx-lm`, `nano-pdf`) — tool envs, not project builds. | Spotify/Steam/Zoom updaters; `local.agent-config-backup` |
| **Postgres** only when tests touch it: `:5432` postgresql@18 18.7, `:5434` postgresql@14 14.24_1, `:5439` postgresql@17 17.11_1 (`lsof -iTCP -sTCP:LISTEN` + `lsof -p <pid>` txt). | | `com.alejandrodelvillar.second-brain-tower`, `com.second-brain.ux-drift` — data pipelines |

`python3 --version` = 3.15.2 (Homebrew). `poetry`/`pyenv` absent, so no implicit interpreter manager
to keep alive. Only one venv exists in `~/Projects` (`second-brain/.venv`, 26 M, Python 3.14.8).

### 2.3 Rust

| Required to build/test offline | Required for the interactive loop | Pure noise during a build |
|---|---|---|
| **rustc/cargo 1.99.1** via rustup shims; toolchain `stable-aarch64-apple-darwin` active + `1.85.1` (`rustup toolchain list`); `~/.rustup` 870 M. | **rust-analyzer: broken.** `rustup which rust-analyzer` errors (`unknown binary`); `rustup component list --installed` shows cargo/clippy/rust-std/rustc/rustfmt only. Editor Rust support currently has no engine on this machine. | ollama (`:11434`) and llama-server (`:8901`) — LLM, not Rust |
| **sccache 0.19.0 is mandatory, not optional**: `~/.cargo/config.toml` sets `[build] rustc-wrapper = "/opt/homebrew/bin/sccache"`. If that path vanishes, **every** `cargo build` fails at wrapper exec. | `<proj>/target` artifacts: `fleet/target` **15 G** (`du -sh`), `layerfs/target` 0 B — incremental state the loop owns. | `sh.brew.mlx-lm` KeepAlive + `sem1-llama` — both hold RAM a release build wants |
| **`~/.cargo/registry` 1.3 G** = crate sources for offline `cargo build --offline`. | | 4 Sparkle `*.ShipIt` updaters |
| Network for crates.io (`static.crates.io` reachable, 0.27 s) when the registry cache misses. | | |

**sccache is cold right now**: `sccache --show-stats` → all counters 0; `ls ~/Library/Caches/sccache` →
*No such file or directory* (the path its own `~/.cargo/config.toml` comment names); no server process.
The "cross-worktree cache" the config promises has never been populated — the 20 m 21 s cold build it
cites is still the expected first build.

### 2.4 Swift / Xcode (present, but no project uses it)

`xcodebuild -showsdks` → macOS 26.5, iOS 26.5; `xcrun simctl list devices` → header only, **zero
simulator devices**; no `Package.swift` anywhere in `~/Projects/*` (manifest scan). Swift is
toolchain-present, workload-absent: nothing in the default bundle needs SourceKit-LSP or CoreSimulator,
so the iOS/RN branch of §3 is *not applicable here today*.

---

## 3. macOS dependencies that break builds when suspended

Each row: what it is, the evidence it exists here, what visibly breaks.

| Dependency | Evidence on this machine | What visibly breaks when suspended/frozen |
|---|---|---|
| **fseventsd** — File System Events daemon, kernel→userspace event delivery | `pgrep -x fseventsd` → pid 336, running | Watchers go blind: Vite/webpack/chokidar and watchman stop seeing writes, so HMR silently serves stale code and `jest --watch` never re-runs. No error is raised — the build looks *quiet*, then you debug a change that did land. Cheapest failure to misdiagnose. |
| **securityd** — keychain daemon | pid 378 running; `security list-keychains` → `~/Library/Keychains/login.keychain-db` + `System.keychain`; `git config --global credential.helper` = `osxkeychain` | `git fetch/push` over HTTPS + private registries fail (helper can't read the item); `codesign` fails with errSecInternalComponent. Note the helper binary ships with *both* toolchains (`/Applications/Xcode.app/Contents/Developer/usr/libexec/git-core/git-credential-osxkeychain` and the CLT copy) — delete one, the other still works. ssh remotes are unaffected (ssh-agent, below). *(error strings: documented, not reproduced here)* |
| **trustd** — cert trust/validation | 4 pids running (`pgrep -x trustd`) | Signature/Notarization checks and `codesign --verify` on downloaded binaries stall; TLS trust evaluation in tools that shell out to `SecTrustEvaluate` blocks. Rarely hit by a plain `tsc`/`pytest` build. |
| **tccd** — TCC privacy decisions | pids 22398, 49806 | Not on the compile path at all. Breaks only what needs a privacy grant: terminal/editor asking for Full Disk Access or Automation, `osascript` control, screen capture. Its real dev-mode cost is *re-prompt storms* after the agent binary's identity changes — a UX hazard, not a build hazard. |
| **nsurlsessiond** — background URLSession transfers | pids 634, 82804 | **Does not touch the CLI path.** `git`, `npm`, `uv`, `cargo` all open their own sockets (verified: `curl` to registry.npmjs.org = 200 in 0.12 s with no daemon involvement). Suspending it breaks the *app* layer: Xcode component/SDK downloads, App Store, iCloud Drive materialization. Do not put it in the "required" set — but do note that freezing it can wedge a running Xcode. |
| **CoreSimulator** — simulator service | `xcrun simctl list devices` → **no devices**; `~/Library/Developer/CoreSimulator` = 4.0K; no `CoreSimulatorService` process | Only bites iOS/React-Native work: `simctl boot`, `expo run:ios`, `xcodebuild -destination 'platform=iOS Simulator'` hang or fail with "Unable to boot device". Zero cost to leave suspended *today* because there are no devices to boot. |
| **SourceKit-LSP** + the Swift build daemon (`swift-frontend`, index store) | `xcrun --find sourcekit-lsp` → Xcode toolchain path; swift 6.3.2 | LSP: jump-to-def/complete in `.swift` die (no crash, just no features). Build daemon: `swift build` gets slower (index/compile cache lost), still correct. No Swift projects here ⇒ deferrable. |
| **Xcode CLT / `xcrun` toolchain** | `/Library/Developer/CommandLineTools` with `SDKs`, `usr`; `xcrun --show-sdk-version` = 26.5; `xcode-select -p` = Xcode.app | The link step of **native modules** breaks: `node-gyp`/`better-sqlite3`/`sharp` rebuilds, `cargo` linking against system frameworks, anything calling `xcrun`. Symptom: `xcrun: error: unable to find utility "clang"` or a `-arch arm64` link failure. Not suspendable (Apple-owned, SIP-protected) — listed because "missing CLT" is the single most common fresh-machine build break. |
| **DNS resolver #1 = Tailscale MagicDNS (`100.100.100.100`, utun4, order 100000)** | `scutil --dns`; `utun4` 100.115.120.43 (`ifconfig`); IPNExtension pid 97831 | The sharpest trap found. **Stopped** tailscaled drops resolver #1 → public DNS falls through to 192.168.1.254, builds fine. **Frozen** tailscaled leaves resolver #1 configured and unreachable → every lookup burns its timeout, so `pnpm install`, `uv sync`, `cargo fetch` and `gh` crawl or fail with ETIMEDOUT. Freeze-vs-stop is not a detail here; it is the difference between slow and broken. |
| **ssh-agent** — launchd socket-activated | pid 1196 (`/usr/bin/ssh-agent -l`); `ssh-add -l` → "The agent has no identities" | Git-over-SSH prompts for a passphrase it cannot get in an unattended run, then fails. Note `~/.ssh/id_ed25519` exists but is not loaded — so overnight SSH pushes currently depend on the key being read from disk, not on the agent. |

---

## 4. Unattended (overnight) build vs interactive session

### Set A — overnight, unattended (`pnpm build` / `uv sync` / `cargo build --release`)

Required, and nothing else:
1. **Network path** en0 + gateway (or fail to an offline build, see caches below).
2. **DNS that answers fast** — resolver #2 is enough; tailscaled may be *stopped* but must not be *frozen*.
3. **securityd + keychain unlocked** — only if the run fetches/pushes. For pure `build`, not needed.
4. **The runtime**: node 26.13.1 / python (uv) / rustc 1.99.1. All user processes, nothing to keep alive.
5. **sccache** (Rust only) — binary present, or cargo fails at the wrapper; server spawns itself.
6. **Postgres** — only if the test phase hits a DB. Otherwise off.
7. **Warm caches**: `~/.npm` 3.0G, `~/Library/pnpm/store` 3.0G, `~/.cargo/registry` 1.3 G, `~/.cache/uv` 15 G. These are what make the run survive a network wobble.

Can be **off** for Set A: watchman, fseventsd delivery for watchers, cliproxyapi, ollama, llama-server,
mlx-lm, sem1-llama, blend1, all 3 model routers, kanzo, kiri (:443/:80), DSH bridge, fleet GUI,
all 3 gitea runners, all four Sparkle updaters, Keystone ×2, MS AutoUpdate/OneDrive, Zoom ×3,
CoreSimulator, SourceKit-LSP, `postgresql@14` (:5434) and — unless tests need it — `second-brain-pg` (:5439).

### Set B — interactive session

Set A **plus**: fseventsd (always — Apple's, leave it alone), watchman (only while a watcher runs), the
editor's tsserver/Pylance (spawned by the editor, needs no service but *does* need `node_modules`),
Postgres :5432, and the keychain unlocked for `gh`/`git`. Still noise while you type: every updater,
every LLM daemon, the gitea runners, kiri's :443/:80.

The asymmetry that matters: **Set A is a strict subset of Set B**, and Set A is satisfied by processes
that are *not services at all* (node/git/rustc/uv) plus four Apple daemons. The user-domain launchd
layer contributes almost nothing to a build — which is exactly why quiet mode can be aggressive on
`~/Library/LaunchAgents` and still never break `pnpm build`.

---

## 5. Measured observations

**Running right now** (lsof listeners + `lsof -p <pid>` txt + `pgrep -x`):

| Service | Port / evidence | Exe |
|---|---|---|
| postgresql@18 | `:5432` (v4+v6), pid 59588 | `/opt/homebrew/Cellar/postgresql@18/18.7/bin/postgres` |
| postgresql@14 | `:5434`, pid 39307 | `.../postgresql@14/14.24_1/bin/postgres` |
| second-brain-pg | `:5439`, pid 6563 | `.../postgresql@17/17.11_1/bin/postgres` |
| kanzo | `:4242`, pid 48402 | `~/.cargo/bin/kanzo` (a **Rust** binary) |
| kiri daemon | `:443`, `:80`, `:5438` + 2 more, pid 74620 | `kiri` |
| cliproxyapi | `:8317`, pid 1161 | `.../cliproxyapi/8.0.25/bin/cliproxyapi` |
| ollama | `:11434`, pid 21839 | `/Applications/Ollama.app/Contents/Resources/ollama` |
| llama-server (sem1) | `:8901`, pid 27468 | `~/.unsloth/llama.cpp/build/bin/llama-server` |
| 3× gitea-runner | `:61604`, `:56575`, `:55096`, pids 47143/61540/76335 | `gitea-runner` |
| podman machine | `gvproxy` pids 25419 (ports 3001/3010/4100/4215/59740…), `krunkit` 25420 | `/opt/podman/bin/{gvproxy,krunkit}` |
| DSH (this session) | `:57730`, `:57801` | DSH Fleet app + node |
| agent/editor tooling | opencode `:4096` (pid 83920); hermes node `:8300` (1144); kiri `:443`,`:80`,`:5438`+2 (74620) | `opencode/1.19.0`, `~/.hermes/node/bin/node`, `kiri` |
| CPython app servers | uv: `:8787`,`:8420` (`cpython-3.13.13`); brew: `:4175` (3.14.8), `:8080`+`:8099` (3.15.2) | `~/.local/share/uv/python/...`, `.../python@3.14`, `.../python@3.15` |
| tailscale | `100.115.120.43:8443/:8444` + utun4, pid 97831 | IPNExtension |
| Apple | fseventsd 336, securityd 378, tccd 22398/49806, nsurlsessiond 634/82804, trustd ×4, cloudd ×2, mds 361 | — |

**Ports that belong to dev tooling**: 5432/5434/5439 (Postgres), 4242 (kanzo), 4096 (opencode),
8300 (hermes node), 8787/8420/4175/8080/8099 (Python app servers), 8901 (llama-server), 11434 (ollama),
61604/56575/55096 (runners). **Not dev tooling**: 443/80/5438 (kiri), 8317 (cliproxyapi — LLM),
8443/8444 (tailscale), 57730/57801 (this session).

**Caches** (`du -sh`): `~/.cache/uv` **15 G** (archive-v0 14 G) · `~/Library/Caches` 17 G total ·
`~/Library/pnpm` 3.5 G (store 3.0 G) · `~/.npm` 3.0 G · `~/.cargo/registry` 1.3 G · `~/.rustup` 870 M ·
`~/.local/share/uv` 876 M (tools 640 M) · `~/Library/Caches/pip` 32 M · `~/.cache/node` 12 K ·
`sccache` **absent** · `~/Library/Developer/Xcode/DerivedData` **absent** · CoreSimulator 4.0 K ·
`.ollama` 384 K. Disk: `/System/Volumes/Data` 359 G used, **60 G free**, 86 %.

**Build artifacts present**: 6 `node_modules` ≈5.1 G (`deepseek-harness-main` 2.3 G, `cruisingintelligence`
1.1 G, `groupworks` 850 M, `deepseek-harness` 794 M, `pampa-wineclub` 323 M, `dsh-layerfs` 12 K);
`fleet/target` 15 G; `second-brain/.venv` 26 M. `dev-mode` itself has none.

**Registry reality**: everything installs from upstream (`registry.npmjs.org`, PyPI, crates.io) — no
mirror, no proxy; cliproxyapi (:8317) answers `200` on `/` but serves LLM completions, not packages.
Reachability: npmjs 200/0.12 s, pypi 200/3.3 s, github 200/0.46 s, static.crates.io 404 on `/` (0.27 s, expected).

---

## 6. Minimum viable dev bundle (shippable default)

| # | Service | Language(s) that need it | Defer until first use? |
|---|---|---|---|
| 1 | Network path: `en0` + gateway 192.168.68.1 | all | **No** — never |
| 2 | DNS: mDNSResponder with resolver #2 (`192.168.1.254`); Tailscale utun4 optional but must never be *frozen* | all | **No** — but tailscaled may be **stopped**, not frozen |
| 3 | `securityd` + unlocked login keychain (+ `trustd`) | all that fetch/push/sign | **No** for pushes/signing; **Yes** for a pure offline build |
| 4 | `ssh-agent` (socket-activated) | git-over-SSH, Rust `git` deps | Yes — launchd starts it on demand |
| 5 | `fseventsd` | JS/TS, Python reload, Rust watch | No for interactive; **Yes** for a one-shot build |
| 6 | `watchman` | JS/TS watchers, Metro | **Yes** — first `--watch` invocation |
| 7 | `postgresql@18` (:5432, 18.7) | Python/JS tests, Prisma | **Yes** — first test that hits a DB |
| 8 | `second-brain-pg` (:5439, 17.11) | agent/eval suites only | **Yes** — and often never |
| 9 | podman machine (`gvproxy`+`krunkit`) | integration tests w/ containers | **Yes** — first container test |
| 10 | `sccache` server | Rust only | **Yes** — first `cargo` run (binary must exist regardless: it is in `rustc-wrapper`) |

Explicitly **outside** the bundle: `postgresql@14` (:5434, duplicate), cliproxyapi (:8317),
ollama (:11434), llama-server (:8901), mlx-lm, sem1-llama, blend1, 3 model routers, kanzo (:4242),
kiri (:443/:80), DSH bridge, fleet GUI, 3 gitea runners (they belong to *pushing*, not building),
Sparkle ×4, Keystone ×2, MS AutoUpdate/OneDrive ×5, Zoom ×3, Steam clean, Perplexity xpc.

Deferral default is *stop*, not *freeze*, for anything holding a socket (rows 7–9): a frozen Postgres
turns every connect into an indefinite hang instead of a clean `ECONNREFUSED`.

---

## 7. Gaps — what this session could not determine

| Gap | What I hit | Command a human should run to close it |
|---|---|---|
| Loaded-vs-idle service state | `launchctl list` exits **1**, empty stdout; `ps -Ao` returns nothing (sandbox). State inferred from listeners + plists only. | `launchctl print gui/$(id -u) \| grep -E '^\s+[0-9-]+\s+[0-9-]+\s+\S+'` or `launchctl list \| grep -v com.apple.` |
| watchman's actual watch set | `watchman watch-list` → `fchmod(.../watchman/...state): Operation not permitted`; the `[]` it printed is *not* a real empty list | `watchman watch-list \| jq '.roots\|length'` |
| yarn's version | `yarn --version` dies at corepack cache mkdir (EPERM in sandbox) | `yarn --version; COREPACK_ENABLE_DOWNLOAD_PROMPT=0 yarn --version` |
| uv's interpreter inventory | `uv python list` → "Could not acquire lock / Could not create temporary file" in `~/.cache/uv/.tmp*` | `uv python list --only-installed` |
| Is a registry mirror ever used (CI, other shells)? | `~/.npmrc`, `pnpm config`, `~/.config/uv/uv.toml` (absent), `~/.cargo/config.toml` (no `[source]` override) show upstream only; shell/CI envs unread | `grep -rIl --exclude-dir=node_modules -E 'registry\s*=|index-url|source\.crates' ~/Projects/*/.npmrc ~/Projects/*/.cargo ~/.config ~/.zshrc 2>/dev/null` |
| pnpm store on another volume? | `pnpm store path` from `dev-mode` (never installed) printed `.../dev-mode/node_modules/.pnpm-store/v11`, yet `~/Library/pnpm/store` exists at 3.0 G and no project has a local `.pnpm-store`. pnpm 12's resolution rule is unresolved. | `cd ~/Projects/cruisingintelligence && pnpm store path && pnpm config get store-dir && ls -d node_modules/.pnpm-store 2>/dev/null` |
| Keychain contents: git items, codesigning identities | `security find-*` / `find-identity` risk an unlock prompt; avoided | `security find-internet-password -s github.com \| head -3` then `security find-identity -v -p codesigning \| tail -3` |
| rust-analyzer: absent, or just not in the active toolchain? | only `stable` and `1.85.1` installed; component list lacks it | `rustup component add rust-analyzer --toolchain 1.85.1 --dry-run 2>&1; ls ~/.rustup/toolchains/*/bin/rust-analyzer` |
| gitea runners: which repos/CI they serve | plists carry only `PATH`/`KeepAlive`; runner config lives elsewhere | `ls ~/.config/gitea-runner* ~/.gitea-runner* 2>/dev/null; grep -rh 'labels' ~/.config/gitea* 2>/dev/null \| head` |
| `postgresql@14` genuinely "in error state" while listening on :5434 | the listener disproves "not running"; can't read `launchctl` exit status | `launchctl print gui/$(id -u)/sh.brew.postgresql@14 \| grep -E 'state|last exit'` |
| Updater families (Sparkle ×4, Keystone ×2) exact bundle owners | plists exist; ownership unverified | `plutil -p ~/Library/LaunchAgents/com.google.keystone.agent.plist; ls ~/Library/Caches/*ShipIt* -d 2>/dev/null` |

*Hygiene note*: `~/Library/LaunchAgents/com.fleet.gui.plist` holds two `FLEET_*_JOIN_SECRET` values in
plaintext `EnvironmentVariables` — redacted here, never reproduced; worth a separate secret-store pass.
