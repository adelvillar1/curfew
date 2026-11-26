# Product

<!-- impeccable:product-schema 1 -->

## Platform

macos

Native SwiftUI/AppKit app. Not web, not iOS; there is no second platform and no plan for one.

## Stack

Swift 6 + SwiftPM, zero third-party dependencies. `CurfewKit` holds the model; `curfew` is the CLI and
TUI; `Curfew.app` is the menu bar app this work extends into a windowed app. Recorded from the existing
codebase, not chosen here.

## Users

**One user: the owner, a solo developer on a 16 GB Apple Silicon laptop, running long unattended builds
and AI agent sessions.** Deterministic, hand-operated, single-machine use.

He is in one of two situations when he reaches for Curfew:

1. **Beginning an unattended run** — he wants the machine to stop competing with his build, with no
   chance of a half-applied state he cannot undo.
2. **Something is wrong or wasteful** — a service is looping, a plist is stale, a vendor updater is
   waking the machine, and he wants to see what and act on it.

Not a managed fleet. Not a product for other people (D21: internal tool, no distribution).

## Product Purpose

Put a Mac into a quiet, unattended-development state — suspending or stopping every background service a
build or agent run does not need — and always be able to put it back.

Success looks like: the machine is quieter, nothing he needed was stopped, and the undo is one press
away with the exact list in front of him.

## Positioning

Adjacent tools give control or aggression; none give a *guarantee*:

| Alternative | Does | Does not |
|---|---|---|
| `launchctl` by hand | exact control | no recipes, no restore guarantee, no undo |
| LaunchControl | full launchd vocabulary, GUI | no opinion about a *safe* stop, no journal, no bundles |
| App Tamer | throttles apps | no notion of services or daemons |
| CleanMyMac & co. | kills processes | no restore, no safety model |

**The product is trust, not the toggle.** Per-service verified recipes plus a journal-backed restore is
the differentiator; the switch is the commodity.

## Constraints

- **The never-list is code, not configuration.** Some services are untouchable, with no override.
- **Journal before acting.** No state change without a write-ahead record; an unreadable journal means
  restore-and-exit rather than guessing.
- **A dry run precedes any live change**, and the plan is shown before it is applied.
- **Never resurrect what Curfew did not stop.**
- **No secrets in the catalogue, journal or logs.** The app never asks for a password.
- A single machine, `main` branch only, ad-hoc signing. Offline by default; the diagnostic path must
  work with no key and no network.

## Current state

- The read-only slice and the catalogue layer ship: inventory, findings, `doctor`, bundle planning.
- The mutating half is built and now proven on a scratch catalogue (apply → held → restore → no-op).
- The menu bar app lives at `~/Applications/Curfew.app` with a login opener.
- **This surface (a window) is new.** The menu bar can start quiet mode but cannot show what it holds.

## Voice

Plain, specific, unexcited. A finding says what it is and what it costs; a refusal says why and what to
type instead. No exclamation marks, no reassurance language, no marketing verbs.

## Open decisions

- Whether `kanzo` (an unsupervised daemon with no launchd job) may ever be stopped — unresolved.
- Memory is not the pitch: a measured quiet mode frees ~20 MB. The value is wakeups and crash loops.
