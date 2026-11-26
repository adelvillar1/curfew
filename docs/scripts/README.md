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

## `repo-hygiene.sh` — prune what a build regenerates

Curfew's copy of fleet's projects-wide habit. The artifact list is **closed** — `.build`, `build`,
`.swiftpm`, the three directories SwiftPM and `make app` write — and anything else found is *named*, never
removed. A directory is prunable only when the repo's last commit is older than 21 days **and** the
artifact's mtime is older than 14 days, so an active repo keeps its warm build. Uncommitted work is never
touched.

```bash
scripts/repo-hygiene.sh --report     # the survey (default)
scripts/repo-hygiene.sh --dry-run    # what --live would do, named
scripts/repo-hygiene.sh --live       # apply, logging each action with its size
scripts/repo-hygiene.sh --purge build
```

Log: `~/Library/Logs/curfew-repo-hygiene.log`.

## `reap-orphans.sh` — stop keep-alives whose parent is gone

From the 2026-11-21 incident: 1,232 orphaned `tail -f /dev/null` keep-alives (ppid 1, 580 MB RSS, 46% of
`maxprocperuid`) accumulated over ~55 days. The rules are deliberately narrow: the command must match
**exactly**, the parent must be gone (`ppid == 1`), and the process must be yours. A process with a live
parent is never touched — its owner may be about to read from it.

```bash
scripts/reap-orphans.sh                 # report
scripts/reap-orphans.sh --live          # SIGTERM the matches
scripts/reap-orphans.sh --command 'cmd' # match a different exact command
```

Log: `~/Library/Logs/curfew-reap-orphans.log`.

`make hygiene` runs both in report mode; `make hygiene-live` applies them.

