# Architecture

## Shape

```
curfew (CLI + TUI, user)  ─┐
Curfew.app (menu bar, user) ─┼──XPC──▶ curfew-helper (root, SMAppService daemon)
                            │                 │
                            │                 ├─ launchctl  (agents, daemons)
                            │                 ├─ kill(2)    (SIGSTOP/SIGCONT/SIGTERM)
                            │                 └─ tmutil / mdutil / pmset
                            └── CurfewKit (shared engine: catalog, policy, journal)
```

One engine, three front ends. No policy in a view, no state in a UI process.

## Why the helper owns state

If the CLI or menu bar crashes with twenty services stopped, *something* must put them back. That something cannot be the process that just died. So:

- The helper owns the journal and is the only writer.
- Every action is journaled **before** it executes (write-ahead), so a crash mid-action leaves a record of intent, not a mystery.
- On start, the helper reconciles: journal says X was stopped by us → restore X (fail open), unless the journal explicitly recorded "quiet mode should survive restart".
- The front ends are stateless views over `status`.

## The four levers

| Lever | Mechanism | Frees | Reversible | Use for |
|---|---|---|---|---|
| Freeze | `SIGSTOP` / `SIGCONT` | CPU, energy | instantly | GUI apps with no sockets |
| Stop | `launchctl bootout` / `bootstrap` | memory | on demand | stateless agents, app launchers |
| Disable | `launchctl disable` | prevents relaunch | `enable` | vendor agents that re-register |
| Throttle | `taskpolicy -b`, `renice` | CPU pressure | nothing to undo | services too risky to stop |

The lever is a property of the service, not a user preference. Data services get `stop` with a clean recipe; on-demand XPC jobs get nothing at all.

## Tiers

| Tier | Meaning | Curfew |
|---|---|---|
| 0 | kernel / init — loss = panic | never listed, not even parsed |
| 1 | core system (GUI, login, disk, security) | never listed |
| 2 | Apple background agents (Spotlight, media analysis, Siri training) | opt-in per label, dated verification |
| 3 | third-party | the product's surface |

The never-list is compiled in (`CurfewKit/NeverList.swift`) and tested. It is not a config file because a config file is a product feature ("power users can edit it"), and that feature is how a tool bricks a machine.

## Why not Electron

A tool whose claim is "your Mac is quieter and has more memory" cannot ship a 300–600 MB Chromium runtime to make its point. Electron also adds a process boundary between the UI and the helper without removing any work — the native helper exists either way. The menu bar app is ~20 MB in SwiftUI.

## Why not sandboxed / not on the Mac App Store

A sandboxed app cannot drive `launchctl` against arbitrary services, and App Review rejects daemons with this reach. Distribution is Developer ID + notarisation, which is what every utility in this category does.

## Trust boundaries

- The helper validates the caller's code signature (`SecCodeCheckValidity`) on every XPC call. `SMAuthorizedClients` in the plist is not consulted under `SMAppService`.
- The catalog is data, but it is validated at build time and its recipes are reviewed like code — a bad recipe stops a database uncleanly.
- Nothing in the catalog, journal, or logs may contain a secret.
