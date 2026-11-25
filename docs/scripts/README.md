# Scripts

Probe and measurement scripts. These are how the project turns "the machine feels slow" into numbers a decision can rest on.

## Existing

| Script | What it does | Status |
|---|---|---|
| `scripts/crash-test.sh` | The live crash test: SIGKILLs `curfew apply --execute` between the journal intent and its outcome, then asserts `resume` restores and that a second `resume` is a no-op. Stops nothing real (`/usr/bin/true`, `/bin/sleep`). | landed 2026-11-24 |
| `scripts/redact_plist.py` | Dumps a plist as text with any key whose name matches `secret|token|key|password|passwd|cookie|credential|auth` redacted. Use it before pasting plist contents anywhere. | landed 2026-11-24 |

## Planned

| Script | What it answers | Status |
|---|---|---|
| `scripts/inventory.sh` | What services are loaded, in which domain, third-party vs Apple | planned |
| `scripts/reclaim.sh` | Per-process memory via `footprint -p`, summed over a bundle | planned — **the open decision input** |
| `scripts/pressure.sh` | Swap, compressor, and pressure samples over time | planned |
| `scripts/verify-plist.sh` | Does a catalog entry's discovery rules match a real plist | planned |
| `scripts/catalog-lint.sh` | Decode + schema-check every `catalog/*.yaml` | planned |

## Rules

- Scripts are read-only by default. A script that mutates services must take `--apply` and print its plan first.
- Scripts never print secrets, env values, or tokens.
- Every script states at the top what it reads and whether it mutates anything.

## Known limitation

`/bin/ps` and `top` were blocked in the sandboxed session that produced the initial measurements. `footprint -p <pid>` and `vmmap` read the same information and are the preferred tools here; confirm both from a normal shell before relying on them.
