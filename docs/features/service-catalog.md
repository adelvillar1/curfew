# The service catalog

What it is, what it refuses, and what every entry on this machine means.

**Status: complete for this machine.** 19 entries, every one with a verdict, zero `draft`. The catalog
lives in `catalog/*.yaml` and is loaded by `CatalogLoader`; `curfew catalog validate` is the gate.

## Two kinds of entry, and why the distinction matters

| Kind | Shape | Meaning |
|---|---|---|
| **Acting** (13) | `lever: disable` + stop/start recipes + `status: verified` | Curfew may change it, and must be able to put it back |
| **Always-on** (6) | `lever: none`, `stoppable: false`, **no recipe** | A decision not to stop it. There is nothing to verify because it is not a target |

An always-on entry with a recipe would be a lie about intent, so the validator refuses one
(`alwaysOnHasNoRecipe`), and no bundle that acts may include it.

## The 13 acting entries

All verified on this host, 2026-11-24/25.

**Full cycle** — disable → `print-disabled` says disabled → bootout → label unloaded → enable +
`bootstrap {plist}` → loaded:

- `us.zoom.updater`
- `com.microsoft.OneDriveStandaloneUpdater`
- `com.microsoft.update.agent` (Microsoft AutoUpdate)
- `com.microsoft.SyncReporter` (OneDrive telemetry)
- `us.zoom.updater.login.check`

**Disable-only** — reversible with `enable`, no plist involved:

- `com.google.GoogleUpdater.wake`, `com.valvesoftware.steamclean` — the plists live in
  `~/Library/LaunchAgents`, and a bootout there did not come back on the first try (KI-033, cause
  unverified). Disable cannot be a one-way door.
- `com.docker.helper`, `com.microsoft.OneDriveLauncher`, `com.microsoft.VSCode.ShipIt`,
  `com.deepseek.dsh.ShipIt`, `dev.zcode.app.ShipIt`, `com.microsoft.teams2.agent` — **submitted by
  their parent app**, so they have no plist to bootstrap from. Disable-only by construction.

## The 6 always-on entries

| Entry | Why |
|---|---|
| `sh.brew.postgresql@18` | the dev database (D22) |
| `com.adelvillar1.sem1-llama` | the embedding server every semantic tool needs (D22) |
| `dev.dsh.bridge` | the agent's path to the Kanzo board — 119 requests in its log (D24) |
| `laya` | the decision model; keeping it warm is the point (D24). Served by `com.adelvillar1.laya-serve` on `:8454` and loaded in-process by sys1 |
| `com.github.facebook.watchman` | file watcher behind HMR and watch mode |
| `com.ollama.ollama` | local model server on `:11434` |

## Bundles

| Bundle | Kind | Members |
|---|---|---|
| `vendor-noise` | stop | the 13 acting entries |
| `harness-core` | protect | sem1-llama, the Kanzo bridge; protects ports 8901/4242/7426/57730/57801 |
| `never-cold` | protect | laya, watchman, ollama |
| `dev-tools` | protect | watchman, ollama; protects `:11434` |
| `data-services` | stop | **empty by decision** — the only data service is always-on (D22) |

## Invariants the validator enforces

1. A never-list label cannot load at all (rule 1).
2. `freeze` is illegal on anything holding a socket or a `MachServices` port (rule 4).
3. `verified` requires dated evidence (rule 5).
4. `verified` requires a `verify:` post-condition on its stop recipe — `expect:` is prose, this is a
   check.
5. **A bootout without a `bootstrap {plist}` is refused** — a one-way door.
6. An always-on entry carries no recipe, and no acting bundle may include one.
7. Unknown keys, tokens and malformed YAML are load errors, never silent drops.

## Adding an entry

1. Write it `draft` with the recipe you believe, argv only, no shell.
2. Run the recipe **by hand** on this machine — stop half *and* start half.
3. Record what you saw in `evidence:`, dated, with the host.
4. Flip to `verified`. If it needs root, it is only runnable under `sudo` (D21).

An entry whose start half has not been run is not verified, no matter how obvious it looks. That rule
cost a live Zoom updater once (KI-030).
