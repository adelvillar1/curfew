---
status: active
created: 2026-11-25
updated: 2026-11-25
slug: jev-assisted-decisions
---

# Plan — Jev-assisted decisions (propose, quiesce-screen, findings ranking)

## Context

`docs/research/tooling-jev.md` measured what a decision model can and cannot do for Curfew, on this
machine, against the owner's own verdicts:

- **17/18 agreement** with the catalogue's dispositions from metadata alone.
- **2 dangerous errors** on the uncatalogued services — `stop` proposed for an MCP server and for a VM
  daemon — because to a label-and-kind filter they look like updaters.
- **3/3 corrected** once the listening sockets were included in the state.
- A **companion noul** phrased as a meta-question ("do the labels fit?") produced no signal at all
  (0.43 / 0.39 / 0.57 for three different things). Rephrased as a concrete property ("infrastructure
  other software depends on?") it scored **5/6**, and its single miss was the label carrying no
  information — fixed by the socket fact, not by wording.

Three features follow from that, and they share one client, one cache and one audit log — building them
separately would mean three HTTP clients and three confidence policies.

## The rule this plan is built around

**The model proposes; the catalogue and the owner dispose.** Nothing in the safety path becomes a model
call. `NeverList`, port conflicts, ancestry, draft-vs-verified, root-requiring — all stay deterministic,
offline and auditable (rule 1, rule 5, and the reason the journal exists). Every model answer lands in
an audit log and, where it becomes a catalogue entry, as `draft` with the model named in `evidence:`.

## Foundation (built first, used by all three)

### `JevClient` — Sources/CurfewKit/JevClient.swift

```swift
struct JevQuestion { id, kind (.choice/.noul/.score), task: String, labels/criteria, descriptions }
enum JevAnswer { case choice(label, probabilities, confidence), noul(Double), score(Double, probabilities) , malformed }
protocol JevTransport { func post(_ body: Data) -> (status: Int, body: Data) }   // injected for tests
JevClient(transport: JevTransport, model: String) -> ask(questions:state:) throws -> [String: JevAnswer]
```

- **Bearer auth from a file, never a flag or the environment of a shell** — `~/.config/curfew/jev.key`,
  0600. No key on disk in the repo, no key in the journal (rule 8).
- **`User-Agent: curfew`** on every request. Non-negotiable: Cloudflare answers 403 (error 1010) to
  urllib-shaped clients — verified twice on this machine.
- **Endpoint is OpenCode Go directly** (owner ruling 2026-11-25):
  `https://opencode.ai/inference/go/systemone/v1/systemone`, overridable by `CURFEW_JEV_URL`. One hop,
  no MCP in the path. Model pinned by `CURFEW_JEV_MODEL` (default `jev-1.14`) so a provider-side upgrade
  cannot silently change behaviour.
- **Everything is injected** — transport, clock, cache — so the whole surface is testable with
  fixtures and no network, exactly like the executor's runner.

### `DecisionLog` — Sources/CurfewKit/DecisionLog.swift

`~/Library/Application Support/Curfew/decisions.jsonl`, append-only, one row per model answer:

```json
{"v":1,"ts":"…","model":"jev-1.14","surface":"propose","subject":"dev.kiri.daemon",
 "stateSha":"…","questionsSha":"…","answers":{…},"decision":"protect","confidence":0.70}
```

The journal says what Curfew *did*; this says *why a model proposed it*. Without it, a `draft` entry
that cites a model is unreviewable six months later.

### `DecisionCache`

Keyed by `(model, sha256(state), sha256(questions))`, stored beside the log. A re-run of the same
triage is free and byte-identical — the same property the embedding proxy needed.

### `ConfidencePolicy`

```swift
enum Confidence { case confident, marginal, unknown }
// confident: p >= floor && top-two margin >= marginFloor   (defaults 0.70 / 0.20)
// marginal:  anything computed but under either threshold — goes to a human, never to action
// unknown:   transport failure, 402, malformed answer — never silently treated as confident
```

**Owner ruling 2026-11-25: 0.70 / 0.20.** Stricter than the measurement suggested (0.60/0.15), which is
the right way round — the one label error in the sample came back at p=0.25, so a tighter floor costs a
few more human reviews and buys a wider margin against the failure that matters.

## Feature 1 — `curfew catalog propose <label>` (read-only)

**What it does.** Builds a **structured** state from the live `ServiceRecord` — label, kind, supervision,
tier, listener ports, `MachServices` count, ancestry, runs, last exit, findings — and asks four questions
in one request (speculative fan-out):

| id | primitive | question |
|---|---|---|
| `disposition` | choice | stop / protect / never |
| `is_infrastructure` | noul | does other software depend on it? (`false` names updaters/launchers/telemetry) |
| `has_state_to_lose` | noul | would stopping it lose work, data or an open connection? |
| `disruption` | score | 1–5, how much work does a stop cost right now |

**How the decision is made** (deterministic code over the answers, so the rule is reviewable):

1. `is_infrastructure >= 0.5` **or** `has_state_to_lose >= 0.5` → **protect**, regardless of disposition.
   This is what the socket test proved: the model's disposition under-protects infrastructure, but its
   nouls do not.
2. Otherwise take `disposition`, but only when `ConfidencePolicy` says `confident`.
3. `marginal` or `unknown` → emit `review`, with all four answers printed so the human decides.

**Output.** A YAML snippet on stdout (**never a file**), `status: active`, no recipes, and an `evidence:`
line naming the model, date, all four answers and the floor applied:

```
evidence: "proposed by jev-1.14 on 2026-11-25: disposition=protect p=0.62, is_infrastructure=0.78,
           has_state_to_lose=0.41, disruption=4 · draft — no recipe verified"
```

`--write` appends it to a named catalogue file, still `draft`. Rule 5 is untouched: a draft cannot be
applied, so the worst a bad proposal can do is waste the owner's review time.

**Acceptance criteria**

- [x] *(L7.1 done; L7.2 pending)* With a fake transport returning the measured answers, `propose` emits `protect` for
      `blend1-service` and `kiri.daemon` and `stop` for `zoom.updater` — the three cases in the research
      doc, as a regression test.
- [x] A disposition at p=0.25 emits `review`, and the output shows the confidence and the floor.
- [x] State is JSON, and contains the listener ports — asserted on the captured request body.
- [ ] No file is written without `--write`; a written entry is `status: active` with no recipes.
- [x] A 402/500/timeout emits `unknown` → `review`; nothing is proposed as confident.
- [x] The decision log gains exactly one row per call, carrying `stateSha` and `questionsSha`.

## Feature 2 — quiesce noul-screen in the executor

**What it does.** Before a stop recipe runs, and **after** every deterministic refusal has passed, ask
one `noul`: *"is anything actively using this service right now?"* with the live evidence (established
connections on its ports, recent client processes, runs in the last minute).

| noul | action |
|---|---|
| ≥ 0.65 (in use) | refuse, journal `busy` — nothing changes |
| 0.35–0.65 (unsettled) | refuse with `unknown` and name the evidence, or proceed **only** with `--allow-unsettled` |
| ≤ 0.35 (idle) | proceed to the recipe |

**It runs on `--execute` only**, so the dry run stays offline (rule 3 and D29 both hold). It narrows only: it runs after `NeverList`, port, ancestry and draft checks — it can never make
something stoppable that those rules refuse.

**When it runs: `auto` — if and only if the entry declares a `quiesce:` probe** (owner ruling
2026-11-25, after the count showed **0 of 18 entries declare one**). The catalog already contains the
author's statement of risk; the gate checks that statement live rather than inventing a trial period.
Today it therefore never runs, which is correct: the 11 acting entries are updaters and launchers with no
clients, and a model call per entry would add latency for an answer that is always "idle". It arms
itself the moment an entry is catalogued that holds state and is not on the never-list.

**The question was measured before shipping it** (2026-11-25, live via the Go endpoint):

| state given to the model | `in_use` |
|---|---|
| idle updater, no ports, no connections | **0.05** → idle |
| postgres **with 3 established connections** | **0.92** → busy |
| the *same* postgres, nobody connected | **0.07** → idle |

The two postgres rows are the point: the answer tracks **live use**, not the service's identity. That is
what distinguishes this from the triage question, which asks about the service in general.

**Acceptance criteria**

- [ ] The gate runs after the deterministic refusals — asserted by ordering in the injected log (the
      same technique as intent-before-action).
- [ ] `busy` writes a journal outcome and touches nothing.
- [ ] With the gate off, behaviour is byte-identical to today (a golden test on the existing suite).
- [ ] A network failure is `unknown` → refuse, never "assume idle".
- [ ] The gate can never flip a refusal to an allow: a never-list entry stays refused with the gate on.

## Feature 3 — `curfew doctor --rank`

Scores each finding's real impact 1–5 and sorts by it. **Does not change severity labels** — those are
mechanical and stay so; only the order changes. Lowest risk of the three, built last.

**Acceptance criteria**

- [x] Ordering comes from the score; ties keep the mechanical severity order.
- [x] `--rank` off leaves the current output unchanged.
- [x] A failed call leaves the unranked list, not an empty one.

## Lifecycle — each surface declares how it earns its place

Per the standing rule that a surface needs a lifecycle or it only grows:

| Surface | Default | Measured by | Retired if |
|---|---|---|---|
| `catalog propose` | available | proposals accepted vs corrected by the owner | correction rate stays above ~25% over 20 services |
| quiesce gate | **off** | false `busy` (a stop that would have been fine) and missed `busy` (a client dropped) | either count is non-zero in normal use |
| `doctor --rank` | flag | whether the ordering is read at all | nobody uses the flag after a month |

The gate is the one with a **trial window** and a kill switch, because it is the only feature that can
stop a run.

## Files

```
Sources/CurfewKit/JevClient.swift          transport, wire shapes, confidence policy
Sources/CurfewKit/DecisionLog.swift        append-only audit + cache
Sources/CurfewKit/Propose.swift            state construction + the deterministic decision rule
Sources/CurfewKit/Executor.swift           the quiesce gate, after the refusals
Sources/CurfewKit/Findings.swift           optional ranking
Sources/curfew/main.swift                  `catalog propose`, `doctor --rank`
Tests/CurfewKitTests/{JevClientTests,ProposeTests,QuiesceGateTests}.swift
docs/plans/CURFEW-CONTRACTS.md             C15 (JevClient), C16 (DecisionLog)
```

## Out of scope

- Any model call inside the refuse path, the journal write, or the verification of a recipe.
- Automatic catalogue writing without a human (`--write` exists, but the entry is `draft`).
- Vision (`box`) — only relevant if we ever verify the menu-bar UI from a screenshot.
- Bundle composition by model. The bundles are policy; that stays human.

## Open questions for the owner

1. **Floor and margin.** 0.60/0.15 come from one 30-point sample. Keep them, or start stricter
   (0.75/0.20) for the first twenty proposals and loosen after?
2. **Which endpoint** — direct OpenCode Go (`inference/go/systemone`) or through sys1's MCP? Direct is
   one hop; through sys1 gives one provider config and the existing telemetry.
3. **Does the quiesce gate ever turn on by default**, and after how many clean runs?
4. **Should `propose` be able to run over a whole inventory** (`curfew catalog propose --all`), emitting
   a review list? That is the batch fan-out case, and it is where the 12 uncatalogued services are.

## Verification

```bash
swift test                                  # everything below is fixture-driven, no network
curfew catalog propose dev.kiri.daemon       # prints a draft, writes nothing
curfew catalog propose us.zoom.updater --json
curfew doctor --rank | head -20
CURFEW_QUIESCE_GATE=always curfew apply --bundle vendor-noise --execute --yes   # the gate runs here
```

## Linked artifacts

- `docs/research/tooling-jev.md` — the measurements this plan is built on
- `docs/plans/CURFEW-DESIGN-DECISIONS.md` D20 (the model proposes, the catalogue disposes), D27
- `CLAUDE.md` hard rules 1, 5, 8 — untouched by anything here, asserted by tests
