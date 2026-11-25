# Jev — what the patterns buy Curfew

Deep dive 2026-11-25, against <https://docs.typesafe.ai> (v1.14 era) and the measurements taken on this
machine the same day. The September knowledge file (`jev-and-gliner-decide-knowledge`) covers what Jev
*is*; this one covers what its **patterns** change about how Curfew decides.

## What changed since September

- The model is **`jev-1.14`** (the local knowledge pinned `jev-1.13.0`).
- The docs grew a **Patterns** section — six named architectures, where before there were only
  primitives. That is the substance of this dive.
- A new primitive, **`box`** (bounding box in an image), and **structured `instructions`/`criteria`**
  (any field that takes a string also takes JSON).
- `vision_qc`-style image questions are now first-class.

## The primitives, restated in Curfew's terms

| Primitive | Answer | Curfew question it can answer |
|---|---|---|
| `choice` | winner + full distribution + confidence | which disposition does this service get |
| `noul` | one probability, no separate confidence | is anything using this *right now* |
| `score` | position on an ordered scale + distribution + legend | how disruptive would stopping this be |
| `box` | rectangle | only if we verify the menu-bar UI from a screenshot |

Confidence is a **distribution-shape** metric, not max-probability: `(N × p_max − 1) / (N − 1)`. For a
two-option question it collapses to the top probability; for three or more it diverges — which is why a
0.46 on a three-way `stop/protect/never` is not the same claim as a 0.46 on a yes/no.

## The six patterns, and which ones matter here

### 1. Companion noul — *valuable, but only when the question names a concrete property*

**Measured, both ways, on this machine.** First attempt asked the meta-question — *"do these three
dispositions genuinely fit this service?"* — and it was useless: 0.43 / 0.39 / 0.57 for an MCP server, a
VM daemon **and** an updater. It read "none of these fits" for everything, including the case it had
classified correctly. A question about label fit has no grounding in the service's state.

Second attempt asked a concrete property — *"is this infrastructure other software depends on, or
something that only serves the person using the machine?"* — with `false` naming what a no looks like
("an updater, telemetry reporter, login launcher"). **5 of 6 correct:** updaters 0.07 and 0.11,
embedding endpoint 0.78, CI runner 0.82, VM daemon 0.57; the miss was `blend1-service` at 0.39 —
a label that says nothing about being an MCP server. Adding its listening socket flipped that same
service to `protect` (p=0.68) in the earlier test.

The lesson is the pattern's own: **a noul needs a concrete `false` criterion *and* a state that carries
the facts that criterion depends on.** Neither half works alone.

A `choice` always picks something, even when nothing fits: ask "which team owns this?" and a message
about none of them still gets routed to whichever is closest. The fix is a second question in the same
request — a `noul` asking whether any option fits — and the code consumes the choice only when the noul
is a clear yes.

**Curfew gain:** the triage question currently forces every service into `stop | protect | never`. The
first two drafts for this machine were exactly that mistake in miniature — `blend1-service` and
`kiri.daemon` were pushed to `stop` because nothing offered "this is infrastructure we added". A
companion noul ("does any of stop/protect/never fit, or is this something else?") makes "none of these"
an answerable state instead of a silent misclassification, and the fallthrough can be `draft` +
human review — which is already the catalogue's safe default.

### 2. Noul screen — *the quiesce gate*

Ask one cheap yes/no first, and run the expensive step only on a clear yes; unclear gets its own exit.

**Curfew gain:** before any stop, a single `noul` over the live evidence — "is anything actively using
this service right now?" — with three exits that map onto behaviour Curfew already has:

| answer | Curfew action |
|---|---|
| clear yes (in use) | refuse, journal `busy` — no change |
| unclear | ask the human, journal `unknown` |
| clear no | proceed to the deterministic checks, then act |

It **narrows only**. A "no" never bypasses the hard rules; it only avoids a pointless stop attempt.

### 3. Confidence routing — *the honesty valve*

Route on confidence first, then on the answer. Low confidence goes to a person.

**Curfew gain:** this is what makes the measured 94% acceptable. In the triage test the single label
error came back at **p=0.25** — the model was unsure and said so. A floor (propose ≥ 0.60, otherwise
hand it to the owner) converts "94% accurate" into "never confidently wrong on this sample".

### 4. Speculative fan-out — *one request per service, not four*

Because all questions in one request evaluate in parallel, ask everything the system might need and let
code discard what it does not.

**Curfew gain:** for a service under triage, one call can carry `disposition` (choice), `in_use_now`
(noul), `disruption` (score), and `removal_candidate` (noul) — four answers for roughly the latency of
one. Curfew's add-a-service flow wants all four anyway.

### 5. Probability routing — *use the distribution, not the argmax*

**Curfew gain:** the gap between the top two options is a better escalation signal than the top
probability alone: `stop 0.46 / protect 0.42` is a coin-flip that p=0.46 conceals. Route on the margin.

### 6. Composite scoring

Several `score` questions combined into one ranking.

**Curfew gain:** ranking the 17 findings `doctor` reports — "how much does this actually hurt?" —
instead of presenting them flat. Lower priority: the findings are mechanical and mostly already
severity-tagged.

## Structured fields — the accuracy lever, measured

`instructions`, choice option descriptions, score levels and noul criteria all accept **JSON**, not just
strings. That matters because of the experiment run the same day:

| state given to jev | result |
|---|---|
| label + kind + supervised + hazards | 17/18 agreement with the owner's verdicts |
| same, on the 12 uncatalogued services | **2 dangerous errors** (`stop` for an MCP server, `stop` for a VM daemon) |
| those three plus `listening=…` socket facts | **3/3 corrected to `protect`** |

jev's blind spot is *a service that serves other services* — it looks exactly like an updater to a
label-and-kind filter. Curfew already knows the difference (ListenerScan, `MachServices`, ancestry) and
currently feeds none of it to anything that decides. Structured state is how that knowledge reaches the
model.

## What is worth building, in order

1. **`curfew catalog propose <label>`** — read-only. Structured state from the live `ServiceRecord`
   (listeners, MachServices, ancestry, runs, findings) → companion-noul triage → confidence floor →
   emits a `draft` entry with `evidence: "proposed by jev-1.14, <date>, needs a verified recipe"`.
   Nothing acts; rule 5 still governs. *Value: the owner moves from classify to confirm.*
2. **Quiesce noul-screen** in the executor, before the deterministic checks. Narrows only.
3. **Findings ranking** via `score` — cosmetic, do last.
4. **Batch triage** of the uncatalogued services (fan-out heads, one call each).

## What must not be built

- **Jev in the refuse path.** Never-list, port conflicts, ancestry, draft/verified, root-requiring —
  those stay deterministic, offline, and auditable. A model there would make the journal's evidence
  unreviewable, which is the opposite of why the journal exists.
- **Jev as a verifier.** A recipe is verified by running it, dated, on this machine. No model opinion
  substitutes for that (rule 5).
- **Uncached calls on a hot path.** The proxy pattern already established applies: cache by
  `(model, state-hash, questions-hash)`, so a re-run of the same triage is free and reproducible.

## Open questions worth measuring before trusting it

1. **Calibration on our data.** Does 0.9 mean 90% here? The triage sample is 30 points — enough to
   spot a broken floor, not enough to set one. Needs the owner's corrections on the uncatalogued
   services to become a real set.
2. **Structured vs flattened state**, head-to-head on the same 18 — the socket test suggests structured
   wins, but it changed one variable (adding facts) and not the other (how they were presented).
3. **Whether 1.14 differs from 1.13** on these questions. Both are available; nobody has compared.
4. **The `deliverable` question.** `disposition` is a 3-way choice today. If a companion noul fires
   often, the honest shape is a 4th label (`review`), and that is a schema change to weigh.

## Local wiring

`sys1` provider `jev` → `https://opencode.ai/inference/go/systemone/v1/systemone`, model `jev-1.14`,
key `OPENCODE_GO_API_KEY` (see `sys1-jev-provider-is-opencode-go`). Calls made from Curfew would go
through the same sys1 endpoint rather than straight to TypeSafe, so one provider config governs both.

## Sources read for this dive

- `/introduction`, `/patterns`, `/patterns/noul-screen`, `/patterns/companion-noul`,
  `/patterns/confidence-routing`, `/patterns/fan-out`, `/primitives/advanced`, `/primitives/box`
  (fetched 2026-11-25). `/patterns/probability-routing` and `/patterns/composite-scoring` are described
  here from their pattern-index summaries only — not read in full.
