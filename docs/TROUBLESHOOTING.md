# Troubleshooting

Real failures and their actual causes. Add an entry the moment a session burns more than a few minutes on something non-obvious.

## A job respawning 255,000 times because its interpreter binary was deleted

> **RESOLVED 2026-11-24.** The router was a proof of concept that later became part of fleet; the owner
> confirmed it is unused in Zcode. All three router jobs were booted out, `disable`d and their plists
> deleted; `~/.zcode/router` (96 MB, mostly a 94 MB unrotated log) was removed after archiving its config,
> README and plists to `docs/archive/zcode-router-poc-2026-11-24/`. Port `:8300` is free and no client
> referenced it. The PoC source survives in `~/Projects/zcode-router-kit/router/server.js`.
> **Still open:** `~/.local/bin/node` is still a dangling symlink — anything else execing it fails the
> same way.
>
> **Resolved separately, same session:** `sh.brew.postgresql@14` (82,103 runs, exit 1) was retired
> outright — a stray `postgres@14` process was squatting on `:5434`, which is the port commissiontracker's
> own `postgres:18-alpine` container maps. Formula uninstalled, data dir removed, `jobhound` dumped to
> `docs/archive/pg14-jobhound-2026-11-24/` first. `psql` was symlinked into the 14 cellar and was relinked
> to 18.7.

**Symptom.** `launchctl print gui/501/com.zcode.model-router` shows `state = spawn scheduled`, `runs = 255645`, `last exit code = 78: EX_CONFIG`. Same for `com.agnostic-router.model-router` (255,646). Neither holds a PID, so `witr model-router` and every process tool report "not found" — the jobs are invisible to anything that lists live processes.

**Actual cause.** The plists exec `~/.local/bin/node`, which is a symlink to `~/.hermes/node/bin/node`, and **that file no longer exists** (hermes was updated or relocated on 2026-08-04). launchd cannot `exec` a missing binary, reports `EX_CONFIG` (78), and `KeepAlive` respawns it immediately — a quarter of a million times, silently.

**Why one instance still runs.** `com.alejandrodelvillar.zcode-model-router` (pid 1144, `runs = 1`, `last exit code = (never exited)`) started while the binary still existed and is executing the **deleted inode** — `lsof -p 1144` shows `txt REG … /Users/alejandrodelvillar/.hermes/node/bin/node`, a path that no longer resolves. It keeps working only until it exits; the first reboot or crash ends the router for good, because every fresh spawn now fails.

**The lesson for Curfew.** This is the canonical case the product exists for, and it needs *both* halves of the pipeline: `launchctl print` finds `runs`/`last exit` on a job with no PID, and a binary-existence check on the declared program explains *why*. Process-centric tools (witr included) cannot see it at all.

**Fix.** Delete the two redundant duplicate jobs (one router is enough — it binds `:8300`), point the surviving job at a live node (`/opt/homebrew/bin/node`), and reload it so it stops running from a deleted inode.

**Also seen:** `~/.zcode/router/logs/router.log` was 94 MB, growing ~2.5 KB per `judge-warm` heartbeat. Nothing rotates it.

## Formats

**`launchctl bootstrap` fails with `5: Input/output error`**
Observed 2026-11-24 from a sandboxed agent session, even for a minimal two-line plist, from both `/tmp` and a project directory. `launchctl print` and `lsof` read fine in the same session. Suspected cause: the session's sandbox denies the launchd service-management Mach service, and launchctl surfaces the denial as EIO. Not yet confirmed. Verify from a normal terminal before concluding anything about macOS.

**A service reports as loaded but nothing is running (`pid` 0)**
Normal for `RunAtLoad`-false jobs and for one-shot agents that exited successfully. Check the `status` column in `launchctl print`: `0` means clean exit, non-zero is the last exit code, `-` means it never ran or was signalled.

**`postgresql@14` sits in `error 1` state with `launchctl`**
The job is loaded but exits immediately (usually a stale data directory version or a port conflict with `postgresql@18`). Check `/opt/homebrew/var/log/postgresql@14.log`. Curfew must treat an already-failed service as "not ours to start".

**Suspended a daemon and clients hang instead of erroring**
Expected — that is what `SIGSTOP` does to a process holding a listening socket. It is why `CLAUDE.md` hard rule 4 forbids freezing anything with a socket or a `MachServices` key.

**Froze Tailscale and every network command got slow instead of failing**
`scutil --dns` shows resolver #1 = `100.100.100.100` on `utun4` (Tailscale MagicDNS, order 100000), #2 = `192.168.1.254` (order 200000). **Stopped** tailscaled removes resolver #1 and lookups fall through to #2 in milliseconds. **Frozen** tailscaled leaves resolver #1 configured but unreachable, so every lookup burns its timeout: `pnpm install`, `uv sync`, `cargo fetch`, and `gh` all crawl or time out. Never freeze Tailscale; if you must quiet it, stop it — and then the remote DSH path at :8443/:8444 is gone too.
