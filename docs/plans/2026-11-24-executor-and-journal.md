---
status: completed
created: 2026-11-24
updated: 2026-11-24
slug: executor-and-journal
---

# Plan — the journal, then the executor (L3.4, L3.3)

## Context

This is the layer that changes the machine, and hard rule 2 sets the order: **journal before acting.**
The decomposition originally had it backwards — journal after executor, executor after entries that can
only be verified by running recipes. Corrected on 2026-11-24: **journal → executor → entries.**

Two constraints shape the plan:

1. **The apply path cannot be verified from a sandboxed agent session.** `launchctl bootstrap` returns
   `5: Input/output error` here (KI-002), and every `bootout` needs escalation. So the executor's
   mutation path is built against an injected runner and verified with fixtures; the first real run is
   the owner's, on a bundle of updaters, with the journal open.
2. **`expect:` is prose.** A stop is only *verified* if something asserts a post-condition. This plan adds
   a `verify:` block to the schema so `verified` stops meaning "the recipe returned 0".

## Approach

### The journal (L3.4)

Append-only JSONL at `~/Library/Application Support/Curfew/journal.jsonl` (`CURFEW_JOURNAL` overrides
it for tests).

```json
{"v":1,"seq":7,"ts":"...","kind":"intent","entryId":"com.google.keystone.agent","action":"disable",
 "argv":[["/bin/launchctl","disable","gui/501/com.google.keystone.agent"]]}
{"v":1,"seq":8,"ts":"...","kind":"outcome","intent":7,"result":"ok","verified":"true"}
```

- **Intent before action, always.** The executor writes the intent, flushes, then acts. If the journal
  cannot be written, the action does not happen — that is the whole rule.
- `outcome` carries the intent's `seq` and whether the schema's `verify:` block passed.
- **A truncated final line is ignored, not fatal** — a crash mid-write must not make the journal
  unreadable, and must not be mistaken for a completed action.
- `unresolved()` = intents with no outcome. `restorePlan()` returns them **in reverse order**.
- An unreadable journal means **refuse to act**, never guess (rule 2's second sentence).

### The `verify:` block (a schema addition)

```yaml
stop:
  run: [...]
  verify:
    kind: port_closed       # port_closed | process_gone | label_not_running | command
    value: "8901"
```

`command` runs a check argv and wants exit 0. Anything else is a built-in read the executor already
knows how to do. The validator gains one rule: a `verified` entry must have a `verify:` block on its
stop recipe — otherwise "verified" is a word, not an assertion.

### The executor (L3.3)

```
curfew apply --bundle NAME            # dry run (the default; prints the plan and every refusal)
curfew apply --bundle NAME --execute  # performs it
curfew resume --all                   # restores everything the journal says is unresolved
curfew status                         # what is suspended/stopped right now, and since when
```

Pipeline per entry, in the planner's order:

1. **Refuse** rather than act when: the entry is `draft`; the bundle is `protect`; the recipe needs root
   and L4 does not exist; the entry's port is in a protect bundle; the label is on the never-list; the
   service was **already stopped before we started** (recorded, not resurrected); the executable is the
   harness's own process tree (rule 7, ancestry walk).
2. **Quiesce**: evaluate the recipe's `quiesce:` as a named probe where one exists (`no-clients-on-port`),
   else refuse to claim it happened.
3. **Journal the intent.**
4. **Run** each step's argv through the injected runner — `Process`, argv only, no shell.
5. **Verify** the `verify:` block. A failed verification is an outcome with `verified: false`, and it
   stops the run: no further entries are touched.
6. **Journal the outcome.**

`hold: bootoutIfRespawned` runs after a `command` stop: if the job is running again with a new pid, the
executor boots it out and journals that as a second intent.

### What makes this safe enough to build

- The runner is injected, so the whole pipeline is testable with a fake that records calls and simulates
  job state. **Every ordering guarantee is a test**, not a review note.
- `--execute` is never implied. A bundle cannot be applied without the word in the command line.
- The refusal list is checked *before* the first intent is written, so a refusal leaves no journal trace
  and touches nothing.

## Acceptance criteria

**Both halves implemented.** 23 tests across `JournalTests` and `ExecutorTests`; every ordering guarantee is asserted with an injected runner.

- [x] An intent is written and flushed **before** the runner is called — asserted by a fake runner that
      reads the journal at call time and fails the test if the intent is absent.
- [x] If the journal path is unwritable, `apply --execute` refuses and the runner is never called.
- [x] A truncated final line leaves the earlier records readable and unresolved intents correct.
- [x] `unresolved()` and `restorePlan()` return intents in reverse order; an intent with an outcome is
      resolved.
- [x] A `draft` entry is refused before any intent is written (journal file absent afterwards).
- [x] A root-requiring recipe is refused with a message naming L4.
- [x] A service already stopped before the run is recorded and **not** started by `resume`.
- [x] `verify: port_closed` fails when the fake listener is still up, and the run stops without touching
      the next entry.
- [x] `hold: bootoutIfRespawned` writes a second intent when the fake job respawns, and none when it
      does not.
- [x] `curfew status` prints unresolved intents with their age.
- [x] A `verified` catalog entry without a `verify:` block fails validation.
- [x] No shell anywhere: the executor's argv reaches the runner as an array, asserted by a test whose
      entry contains a value with `;` and `\` in it.

## Files to be touched

```
Sources/CurfewKit/Journal.swift        intent/outcome records, append, resolve, restore plan
Sources/CurfewKit/Executor.swift       refusal checks, quiesce, journal-then-act, verify, hold
Sources/CurfewKit/Catalog.swift        the `verify:` block + its validation rule
Sources/curfew/main.swift              apply / resume / status
Sources/CurfewKit/Contracts.swift      apply/resume/status output shapes
Tests/CurfewKitTests/JournalTests.swift
Tests/CurfewKitTests/ExecutorTests.swift
catalog/*.yaml                          add `verify:` to the entries that have recipes
docs/plans/CURFEW-CONTRACTS.md          C10 (journal), C11 (executor)
```

## Out of scope

- The privileged helper and XPC (L4) — every `needsRoot` recipe stays refused.
- Freeze (`SIGSTOP`) — the catalog has no entry that legally uses it yet, and rule 4 keeps it that way.
- Container levers (`kiri stop`) — KI-004 is still open.
- Scheduling, idle triggers, the TUI and the menu bar (L5).

## Open questions for the owner

1. **`--execute` or an interactive confirmation?** A flag is scriptable and unambiguous; a prompt is
   harder to fire by accident. My recommendation: the flag, plus a refusal if stdout is not a TTY and
   `--execute` was passed without `--yes`.
2. **Where should the journal live?** `~/Library/Application Support/Curfew/` (the conventional place) or
   `~/.local/state/curfew/` (XDG-ish and easier to find in a terminal)? My recommendation: the former,
   with `CURFEW_JOURNAL` to override.
3. **Should `resume --all` also run when the journal is empty**, or say "nothing to restore"? My
   recommendation: say so and exit 0 — silence is indistinguishable from a failure.

## Verification

```bash
swift test
curfew apply --bundle vendor-noise            # dry run: plan + refusals, nothing touched
CURFEW_JOURNAL=/tmp/j.jsonl curfew status
python3 scripts/ledger_check.py
```

The first real `--execute` is the owner's, on `vendor-noise`, with the journal open — and it is the one
step in this plan that cannot be verified from here.

## Linked artifacts

- `docs/architecture/blueprint.md` §7 (executor: journal → quiesce → act → verify → report)
- `docs/plans/CURFEW-DESIGN-DECISIONS.md` D1, D12, D16 — read-only until now, supervision, journal ownership
- `CLAUDE.md` hard rules 2, 3, 4, 6, 7 — each becomes a check in this plan
