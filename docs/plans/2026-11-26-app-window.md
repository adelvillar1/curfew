# Curfew.app gets a real window

**Status:** active (built; live verification pending) · 2026-11-26 · owner decision: a SwiftUI window in `Curfew.app`, with findings you can act on

## Context

The menu bar can start quiet mode, but it cannot show what it is holding, what a bundle will do
before it does it, or which services are the ones with findings. The TUI can, but it needs a terminal,
and the owner's words were "we need a real interface beyond the menu in the Finder".

Two defects made this urgent and are fixed (KI-044, KI-045): a bundle aborted after one entry, and quiet
mode could not be undone. The window is the surface that makes both visible instead of silent.

## What the window shows

One window, four regions, all reading the same snapshot:

1. **Header** — quiet mode ON/OFF, how many changes Curfew holds, `Start quiet mode` / `Restore all`.
   Every control is disabled when it cannot act, and says why in its tooltip.
2. **Bundles** — one card per stop bundle: name, summary, how many of its members act. `Preview` shows
   the dry-run plan for that bundle; `Start` runs the same two-step the menu does (plan shown, confirm).
   Protect bundles are listed as protected, never with a start control.
3. **Held** — what Curfew is holding right now: label, action, when. This is the region whose absence
   let quiet mode look like it had reverted. `Restore all` undoes it in reverse order.
4. **Findings** — one row per finding: severity, label, summary. Each row can act:
   - **Investigate** — runs `curfew why <label>` and shows the output in a sheet (read-only).
   - **Stop this service** — offered only with a catalogued, verified, non-protected entry: dry run
     first, plan shown, confirm, then the same executor path the CLI uses.

## Design

- `CurfewKit/AppSnapshot.swift` — a `Sendable` value describing everything the window renders, plus
  `AppSnapshotProvider.load(...)`. Pure and testable: no AppKit, no SwiftUI.
- `curfew-menubar/Window.swift` — SwiftUI views over the snapshot. No business logic.
- The app becomes a **regular app**: `LSUIElement` false, a Dock icon, `applicationShouldHandleReopen`
  brings the window back, closing the window does not quit. The status item stays and gains
  "Open Curfew…".
- Refresh: on window focus and after every action; no polling timer.
- All mutations go through the same two-step confirm and the same `Executor`/`Journal` the CLI uses.
  The window never invents a code path — it is a surface over the CLI's model.

## Acceptance criteria

- [x] Opening the app from the Dock or Finder shows the window; closing it leaves the app running and
      the status item intact; clicking the Dock icon reopens it.
- [x] The header shows quiet mode ON with the count of held changes, and `Restore all` puts them back (rendered both states).
- [x] A bundle's Preview shows the dry run's steps without changing anything (`apply(execute: false)` behind the sheet).
- [x] Start quiet mode shows the plan and applies only on confirmation — the same rule as D30.
- [x] Held lists every change Curfew made, and empties after a restore (journal-backed; `held()`).
- [x] Findings rows show severity, label and summary, and **Investigate** shows the finding's evidence.
      (The plan said `why`; the evidence line is already in the record, so the window does not shell out.)
- [x] **Stop this service** is offered only for a verified, catalogued, non-protected entry, and its
      effect is visible in Held.
- [x] No catalogue shows a stated problem rather than an empty window. No CLI is irrelevant now: the
      window calls `Executor` in-process, so it does not need the command line tool at all.
- [x] `AppSnapshot` has tests: held is empty on a clean journal, the quiet flag tracks `held()`, and
      findings are grouped with their labels.

## Out of scope

- Editing the catalogue from the window.
- A per-service multi-select that composes a custom mode (the owner chose findings instead).
- Charts, history, or a memory view.

## Verification

`swift test` for the snapshot; then launch the installed app, capture the window, and drive
Start → Held → Restore once on a scratch catalogue so nothing on the machine is touched.

## Where this landed

Built 2026-11-26. `CurfewKit/AppSnapshot.swift` gathers the state; `curfew-menubar/Window.swift` renders it;
the app is now a Dock app (`LSUIElement` false) whose login opener passes `--background` so a window does
not appear over the owner's work at login.

Two design decisions came out of *looking* at the render: the three hero numbers were removed (they were
the refused hero-metric template) and severity stopped being encoded by colour alone.

## Not verified

The window has been rendered pane by pane offscreen (`--render-window`), not opened on screen and driven
by hand — screen recording is not permitted in this session, and `System Events` cannot enumerate the
window without Accessibility. The sidebar, the sheets and a real apply pressed in the window remain to be
confirmed by eye.
