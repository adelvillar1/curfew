---
status: completed
created: 2026-11-24
updated: 2026-11-24
slug: listener-scan
---

# Plan — L1.10, the listener scan (`orphanPort`, `noSupervisor`)

## Context

`curfew doctor` sees launchd, and launchd cannot tell it about a process that holds a port without
owning a job. The case that motivated this atom: `postgres@14`'s launchd job crashed 82,103 times
because a stray `postgres` from a previous run was squatting on `:5434` — the port commissiontracker's
own container maps. The job was in the inventory; the squatter was not.

The atom was deferred from `2026-11-24-inventory-and-why.md` ("not done, deliberately") and is the last
open piece of the read-only slice.

## Approach

One new module, one new contract, no new dependency: parse `lsof -nP -iTCP -sTCP:LISTEN`, then compare
listeners against the record set by pid, and by executable basename as a fallback.

Two findings, deliberately different in shape:

- **`orphanPort`** — *per instance*, severity `defect`. A listener whose pid is not a running job's pid,
  but whose command matches a job's program basename. That job exists and is not the process holding the
  port: a leftover from a previous run. Actionable, so it gets its own row naming both pids.
- **`noSupervisor`** — *aggregated into one finding*, severity `gap`. Listeners matching no job at all.
  These are overwhelmingly legitimate (`ControlCenter` on AirPlay's 5000/7000, an app-spawned child), and
  we cannot tell an app child from a hand-started server without witr. One finding naming all of them
  keeps the information honest without crying wolf twelve times a run.

The safe path (D8): a listener we cannot attribute is reported as a visibility gap, never as a defect,
and never as "nothing here".

## Acceptance criteria

- [x] `ListenerParser.parse` reads the captured macOS 26.5.2 `lsof` fixture and returns one `Listener`
      per (pid, port), deduplicating the IPv4/IPv6 pair for a dual-stack listener.
- [x] A synthetic orphan — job `com.example.orphan` not running, a listener `postgres` (pid 999) holding
      `:5434` while the job's program is `/opt/pg/bin/postgres` — produces an `orphanPort` finding naming
      both the port, the squatter's pid, and the job's own pid or "not running".
- [x] A listener whose pid belongs to a running job produces no finding.
- [x] Listeners belonging to no job aggregate into exactly **one** `noSupervisor` finding whose evidence
      names each `command:port`, and the finding's `confirmsScan` is true.
- [x] `curfew doctor` on this machine reports the aggregate `noSupervisor` finding and exits 1; with
      `--json`, the finding appears in `findings[]` with `label: null`.
- [x] The read-only guarantee still holds: the scan invokes `lsof` only, and the shimmed-mutation test
      stays green with `lsof` added to the shim set as a pass-through.

## Files to be touched

```
Sources/CurfewKit/ListenerScan.swift
Sources/CurfewKit/Contracts.swift        (FindingReport already supports a nil label)
Sources/curfew/main.swift                (doctor composes the scan)
Tests/CurfewKitTests/ListenerScanTests.swift
Tests/Fixtures/lsof-listen-macos-26.5.2.txt
docs/plans/CURFEW-CONTRACTS.md           (C8)
docs/plans/CURFEW-DECOMPOSITION.md       (L1.10 → done, with evidence)
```

## Out of scope

- UDP listeners (the orphan case is TCP).
- Attributing a listener to a **container** (Kiri is not visible to `lsof` as the container's owner).
- Using witr to refine attribution — that is a later refinement of the same atom.

## Verification

```bash
swift test
curfew doctor
curfew doctor --json | python3 -c 'import json,sys; d=json.load(sys.stdin); print([f["id"] for f in d["findings"]])'
```

## Linked artifacts

- `docs/plans/CURFEW-DESIGN-DECISIONS.md` D8 (safe path + log), D12 (supervision)
- `docs/known-issues.md` KI-012 (the PG14 orphan this atom would have caught)
