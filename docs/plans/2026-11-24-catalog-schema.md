---
status: completed
created: 2026-11-24
updated: 2026-11-24
slug: catalog-schema
---

# Plan — the service catalog: schema, loader, validator

## Context

Rule 5 says *no catalog entry without a verified recipe*, and D11 says *the lever is a property of the
service*. Neither is enforceable without a data model. This atom (`L3.1`) builds that model and nothing
else: **a schema, a loader, a validator, and a read-only `curfew catalog` command.** No execution. The
executor is L3.3, and it starts only after this is approved.

The reason to separate them: a catalog is the first artifact a person can read and disagree with. It
says *what would be stopped and exactly how* — `pg_ctl stop -m fast`, not `SIGTERM to postgres`; `mdutil
-a -i off`, not `SIGSTOP to mds`. Getting that reviewed is cheaper than getting it wrong in an executor.

## Approach

### Where it lives

```
catalog/vendor.yaml       updaters, sync agents, launchers   (~30 entries on this machine)
catalog/dev-stack.yaml    postgres, model servers, runners
catalog/harness.yaml      the DSH/Zcode path and what must never be stopped
catalog/never-cold.yaml   entries whose absence costs minutes (Laya, mlx-lm's 9B model)
```

One file per area, so a diff is a reviewable unit and a merge conflict is confined.

### The entry

```yaml
- id: sh.brew.postgresql@18          # the launchd label, or unmanaged:<exe>@<port>
  kind: agent                        # daemon | agent | appChild | container | inProcess | command
  lever: command                     # freeze | stop | disable | throttle | command | none
  supervised: launchd                # launchd | appParent | none   (D12)
  status: verified                   # draft | verified  (rule 5)

  stop:                              # the exact recipe, argv only — never a shell string
    run: ["/opt/homebrew/opt/postgresql@18/bin/pg_ctl", "-D", "/opt/homebrew/var/postgresql@18", "stop", "-m", "fast"]
    needsRoot: false
    expect: clean-exit               # clean-exit | signal 78 | port 5432 released
    quiesce: port 5432 has no ESTABLISHED connections
  start:
    run: ["/opt/homebrew/opt/postgresql@18/bin/pg_ctl", "-D", "/opt/homebrew/var/postgresql@18", "start"]
    meansReady: port 5432 accepts a connection

  hazards: [data-loss-if-mid-write]  # never frozen: it holds a socket
  depends: []                        # entry ids that must be up first
  evidence: "2026-11-24 · this Mac · stopped at 21:40, port released in 1.2 s, restarted clean"
  bundles: [data-services]
```

Four properties are deliberate:

1. **`run` is an argv array.** No shell, so no interpolation, no quoting, no injection from a label
   into a command line. The same rule the witr client already follows.
2. **`supervised: none` requires a `start` recipe.** A stop with no restart recipe is a one-way door
   (`kanzo`), and the validator refuses it unless the entry says so explicitly with
   `stoppable: false`.
3. **`status: completed` cannot be applied**, and `verified` requires `evidence` naming a date, this host,
   and what was observed. The loader enforces both; a test proves it.
4. **`freeze` is only legal with `hazard: no-socket`.** Any entry declaring a listening port, a
   `MachServices` key or an on-disk database cannot be frozen — that is hard rule 4 made mechanical.

### The command (read-only)

```
curfew catalog list     [--bundle NAME] [--json]   # every entry with lever, status and evidence age
curfew catalog validate [--json]                   # schema + policy; exit 1 on any violation
curfew catalog plan      --bundle NAME             # what WOULD happen, ordered, with refusals shown
```

`catalog plan` is the dry-run preview from the functional spec, without an executor behind it. It prints
the ordered recipe list, the entries it refuses and why, and the never-list collisions it would have
created. Nothing runs.

### Policy the validator enforces

| Rule | Why | Refusal |
|---|---|---|
| No entry whose `id` is in `NeverList.labels` | D9 | hard error, the catalog does not load |
| `freeze` only with `no-socket` | rule 4 / D10 | hard error |
| `verified` requires `evidence` with a date | rule 5 | hard error |
| `supervised: none` requires `stoppable: false` or a `start` recipe | D12 | hard error |
| `lever: none` is legal only for `never-cold` entries | D14 | hard error |
| A bundle may not contain a `protected` tier entry | D0 | hard error |
| Any entry citing another must cite one that exists | decomposition discipline | hard error |

## Acceptance criteria

- [x] `catalog/*.yaml` parses into `CatalogEntry` values through a loader with no execution code path.
- [x] `curfew catalog validate` on a catalog containing an entry for a never-list label exits 1 and names
      the label and the file.
- [x] An entry with `lever: freeze` and a declared port fails validation with a message quoting rule 4.
- [x] An entry with `status: verified` and no `evidence` fails; with evidence it passes.
- [x] An entry with `supervised: none` and no `start` recipe fails unless `stoppable: false`.
- [x] `curfew catalog plan --bundle data-services` prints the ordered recipes and changes nothing —
      the read-only guarantee suite covers it with `catalog` added to the shims.
- [x] The never-list test still passes, and a new test asserts no catalog file names a protected label.
- [x] `curfew catalog list --json` shape is documented in `TECHNICAL-DOCUMENTATION.md` §4.

## Files to be touched

```
catalog/vendor.yaml                  (a starter set, all status: completed)
catalog/dev-stack.yaml
catalog/harness.yaml
catalog/never-cold.yaml
Sources/CurfewKit/Catalog.swift      CatalogEntry, Loader, Validator, Rule violations
Sources/curfew/main.swift            the `catalog` subcommand
Sources/CurfewKit/Contracts.swift    CatalogListOutput / CatalogPlanOutput
Tests/CurfewKitTests/CatalogTests.swift
Tests/Fixtures/catalog-*.yaml        one valid, one invalid per rule
docs/plans/CURFEW-CONTRACTS.md       C9
```

## Out of scope

- **Executing anything.** No process is started, stopped or signalled by this atom (D1).
- Container entries — `kiri stop` needs the engine story that KI-004 left open.
- Root-requiring recipes (`mdutil`, `tmutil`, system daemons) stay `status: completed` until L4 gives them a
  privileged helper; the validator accepts them but `plan` reports them as `needs-helper`.
- Apple Tier-2 agents — the `apple-quiet` bundle is written but empty pending the owner's decision (D0).

## Open questions for the owner

1. **`pg_ctl stop -m fast` or `brew services stop postgresql@18`?** The first leaves launchd supervising a
   stopped server (it may restart it); the second removes the job and needs `brew services start` to
   come back. Which is the behaviour you want in a bundle?
2. **Bundles as first-class files or as tags on entries?** Tags are simpler; files let a bundle carry a
   description and a default order.
3. **Does `harness-core` protect by label or by port?** The DSH app, its five children, `sem1-llama` and
   `kanzo` are movements of the same dependency chain — protecting the *ports* (8901, 4242, 7426) may be
   more robust than protecting labels that move.
4. **How much evidence is enough for `verified`?** One dated line per entry, or a structured
   `{date, host, command, observed}` triple?
5. **Should `plan` show entries it cannot act on** (drafts, helper-needing, `stoppable: false`) as a
   separate section, or hide them?

## Verification

```bash
swift test
curfew catalog validate
curfew catalog plan --bundle data-services
curfew catalog list --json | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["entries"]))'
python3 scripts/ledger_check.py
```

## Linked artifacts

- `docs/architecture/blueprint.md` §3 (the lever is a property of the service), §5 (bundles)
- `docs/plans/CURFEW-DESIGN-DECISIONS.md` D10, D11, D12, D14 — the constraints this schema encodes
- `docs/research/core-os-services.md` §4 — the never-list the validator checks against
- `docs/known-issues.md` KI-004 (Kiri containers), KI-012 (the orphan case a recipe would have prevented)
