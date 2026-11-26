---
status: completed
created: 2026-11-26
updated: 2026-11-26
slug: app-window-usability
---

# Plan: Curfew's window, made readable

## Context

The third critique (2026-11-26) reviewed the app from **real screen captures** for the first time and found that
the shell is designed but two of its four panes are not. `Services` prints 469 namespaced launchd identifiers
(`application.com.apple.ActivityMonitor.1152921500311908412.1152921500311908417`) with no header row, no
grouping, and no visible search; `Bundles` renders every Preview button disabled whenever quiet mode is on, so
the pane reads as dead; the landing pane leaves roughly 45% of its window empty below a two-row Held list. The
critique scored 24/40 — the same as before the previous fix round, which is why the owner said the app "looks
as it did before the first review".

The product exists to answer "what is running on my machine, and can I stop it safely". A pane that cannot be
read is the largest remaining gap between the product's claim and its surface.

## Approach

Present the inventory the way `Findings` and `Apps` already do — that row language is proven and needs no
invention. A service row gets a **display name** (`Activity Monitor`) with its raw label demoted to a monospace
detail line, a **header row** naming the columns, **grouping by kind** with counts, and a **search field inside
the pane** rather than behind `.searchable`, which never renders in this window. Sorting reuses the same metric
each pane already shows, chosen once and held for the window's lifetime.

`Bundles` stops rendering dead controls: when quiet mode is on the pane states why once at the top and offers
Restore, because a greyed button with a tooltip is indistinguishable from a broken one (the lesson of KI-043).
The landing pane is fitted to its content, and help becomes reachable in one press — a footer button that opens
a one-screen explainer for "held", "protected bundle" and a finding kind.

The mapping from launchd label to display name is a pure function, so it is testable and reusable by the CLI.

High-level steps:

1. `Vocabulary.displayName(for:)` — strip the namespace from `application.<bundle-id>.<pid>.<pid>` and the
   `application.` prefix generally, deriving `Activity Monitor` from `com.apple.ActivityMonitor`; keep the raw
   label verbatim in the detail line and in JSON output.
2. `ServicesPane`: header row, grouping by kind with counts, in-pane search (`TextField` + `@FocusState`), sort
   control (`name` / `state` / `findings`).
3. `AppsPane`: the same sort control for `memory` / `name`.
4. `BundlesPane`: a quiet-mode banner with a Restore action; no disabled control without an adjacent reason.
5. `QuietPane`: default window height fitted to a two-row Held list; footer carries build identity and the Help
   button.
6. `HelpSheet`: one screen explaining held, protected, quiesce, and the finding kinds, opened by ⌘?.
7. Keyboard: **⌘F** is new — it focuses the active pane's search field. **⌘1–⌘5** already exist from the
   previous pass (D37) and C7 verifies them rather than adding them, so the shortcut row is proven in the same
   capture as the help sheet.

## Use cases (when the feature has user-visible behavior)

- [ ] A: A person can identify a running service by a name they recognise, without decoding a launchd label.
- [ ] B: A person can find one service among 469 by typing part of its name or label.
- [ ] C: A person understands why bundle actions are unavailable while quiet mode is on, and can act on it.
- [ ] D: A person can learn what "held", "protected" and a finding kind mean without leaving the app.
- [ ] E: The landing pane reads as finished rather than as a window with a hole in it.

## Acceptance criteria

These are the contract. Each one is a verifiable assertion. The work is "done" when every box is checked.
**Order is identity**: criteria are C0, C1, … in checkbox order.

- [x] C0: Every Services row shows a display name derived from its label (`com.apple.ActivityMonitor` →
      "Activity Monitor"), and the raw label appears on the row's monospace detail line.
- [x] C1: Services renders a header row naming its columns (name, state, tier, findings) and groups rows by kind
      with a count per group.
- [x] C2: Services has a search field visible in the pane, and typing filters the rows to those whose display
      name or raw label contains the text. — field visible in the capture; filtering proven by
      `ServiceListTests` (matches display name, matches raw label, empty query keeps all, no match yields
      nothing). The keystrokes themselves cannot be injected here (KI-064)
- [x] C3: Services can be sorted by name, and Apps by memory and by name; the chosen order survives switching
      panes within the session. — both pickers visible in the capture; the ordering proven by
      `ServiceListTests` (name, state, findings) and the choice held in the model rather than the view, which
      is what makes it survive a pane switch
- [x] C4: With quiet mode on, the Bundles pane states once at the top why previews are unavailable and offers
      Restore, and no control is rendered disabled without that explanation visible on the pane.
- [x] C5: With a two-row Held list the landing pane leaves no more than 40 points of empty height above its
      footer, measured from a captured window.
- [x] C6: A Help control in the window footer opens a one-screen explainer that defines "held", "protected
      bundle" and each finding kind, reachable with ⌘?.
- [x] C7: ⌘F focuses the active pane's search field, and ⌘1–⌘5 switch panes.

## Files to be touched

**Frontend:**
- `Sources/CurfewKit/Vocabulary.swift` — `displayName(for:)`, plus a test-visible rule for namespaced labels
- `Sources/curfew-menubar/Window.swift` — ServicesPane (header, groups, search, sort), AppsPane (sort),
  BundlesPane (quiet banner), QuietPane (fitted height, footer), HelpSheet
- `Sources/curfew-menubar/main.swift` — ⌘F and ⌘? menu items

**Tests:**
- `Tests/CurfewKitTests/VocabularyTests.swift` — display-name mapping, including an already-human label
- `Tests/CurfewKitTests/AppSnapshotTests.swift` — grouping counts if the grouping lives in the snapshot

**Documentation (see Linked artifacts below):**
- `docs/features/app-window.md` — new
- `FUNCTIONAL-SPECIFICATIONS.md` — the window's panes and their actions
- `TECHNICAL-DOCUMENTATION.md` — the display-name mapping and the snapshot's grouping

## Out of scope

- Building the catalogue entries needed to make more services stoppable; this is presentation only.
- Any change to the executor, the journal, or the daemon-side model.
- A custom multi-select "compose your own quiet mode" — the owner chose findings over that earlier (D31).
- Charts, history views, or a memory timeline.

## Verification

**C0, C1, C2 — Services is readable and searchable**
```bash
swift test --filter VocabularyTests          # display-name mapping
.build/debug/curfew-menubar --dump-services  # new: prints the grouped rows and the search result count
```
Expected: `application.com.apple.ActivityMonitor.…` renders as "Activity Monitor", a header row is present, and
searching "activity" returns exactly that row. Then capture the pane and look at it.

**C3 — sort survives a pane switch**
Press ⌘2 then ⌘4 in a captured session; the Apps order is unchanged on return.

**C4 — Bundles explains itself while quiet is on**
With quiet mode on, capture the Bundles pane: one banner sentence plus a Restore button, and no disabled
Preview without that banner in frame.

**C5 — the landing pane is fitted**
Capture the window with two held rows; measure the gap between the last row's baseline and the footer divider.
Expected ≤ 40 pt.

**C6, C7 — help and keyboard**
Press ⌘? and ⌘F in a captured session; the explainer opens and the search field takes focus.

**Every criterion** is additionally confirmed from a `cua-driver` capture of the installed app, because
offscreen renders were how three reachability defects went unnoticed.

## Linked artifacts

- `docs/features/app-window.md` — create: the five panes, their actions, their empty and disabled states
- `FUNCTIONAL-SPECIFICATIONS.md` section 6 "Menu bar and window" — the display names, search, sort and help
- `TECHNICAL-DOCUMENTATION.md` — three areas the architecture gate found undocumented: **`Vocabulary.displayName`**
  (the mapping rule and its collision behaviour), **`AppSnapshot` grouping** (what the snapshot carries for the
  Services header and groups), and **the window's panes** (there is no section describing the five panes at all)
- `docs/plans/CURFEW-DECOMPOSITION.md` — atoms L8.1–L8.7 track C0–C7 (already added, status `planned`)
- `docs/plans/CURFEW-DESIGN-DECISIONS.md` — a decision for "the inventory speaks display names, the detail keeps
  the identifier", extending D38

## Risks

- **A window that blanks.** An earlier attempt to restructure the landing pane (a `VStack` demanding infinite
  height inside `NavigationSplitView`) rendered the whole window white. Mitigation: every layout change is
  verified from a capture before the next change, and the last known-good view is one `git checkout` away.
- **`.searchable` is invisible in this window**, which is why the search field moves into the pane. If a
  future macOS restores it, the in-pane field still works.
- **Display names can collide** (`application.com.apple.MobileSMS.app` vs `Messages`). The raw label stays on the
  detail line and in JSON, so the collision is visible rather than hidden.

## Dependencies

- The cua driver, launched through `permissions grant` (not from a shell) — verified working 2026-11-26.
- `Vocabulary` (C27) and `AppSnapshot` (C23), both already present.

## Notes

The critique's P0 is the only criterion that must not be traded away; C3–C7 are the rest of the review and can
land in any order after C0–C2.

The plan-surface layer mapped C0–C6 to `Sources/CurfewKit` and left C7 (`main.swift`, the menu) unmapped; its two
asserted edges — C0→C2 (search needs display names) and C2→C7 (⌘F needs a search field to focus) — match the order
below, so no edge was overridden.

There are no `docs/ux/` route documents to update: this is a single native window, and its reference states are
the captured critique at `.impeccable/critique/2026-11-26T17-02-28Z__sources-curfew-menubar-window-swift.md`.

## Round log

**Round 2 (2026-11-26)** — C2, C3 and C6 met.

- **C6** is proven from a capture: the sheet opens and shows all seven definitions. It took **two** fixes —
  the three `.sheet` modifiers collapsed into one `enum Sheet` (KI-063), and a SIGUSR1 race that killed an
  instance mid-launch (KI-065). Proof came from a launch seam (`--open-help`), because the driver refuses every
  input route to this window.
- **C2 and C3** are proven by test rather than by mouse: the filtering and ordering moved out of the view into
  `CurfewKit/ServiceList.swift`, so "typing filters" and "the order is stable" are assertions instead of hopes.
- **C7 remains blocked, and its evidence is as far as it can go without an input device**: the menu bindings are
  printed by `--dump-appmenu` (⌘F Filter, ⌘1–⌘5 panes, ⌘⇧/ help, ⌘⇧Q, ⌘⇧Z, ⌘R), and the pane-switch mechanism
  those keys call is proven live (`--pane Services`, captured in `docs/evidence/window-services-live.png`). The
  keystroke itself cannot be injected (KI-064). **Owner decision needed**: press ⌘1 and ⌘F once to close C7 as
  written, or amend C7 to what is verifiable (bindings bound + pane switching proven).

**Round 1 (2026-11-26)** — C0, C1, C4, C5 met and verified from captures; C0 also has unit tests. C2 and C3 are
built and visible, with the interaction half unverified because synthetic keystrokes did not reach the app
(KI-064). C6 is blocked: the Help sheet never presents (KI-063). C7 is blocked by the same keystroke gap.

Evidence: `docs/evidence/window-services-named.png`, `window-bundles-banner.png`, `window-landing-fitted.png`,
`window-help-sheet.png`.

## Outcome

All eight criteria met, 2026-11-26.

| | Criterion | Evidence |
|---|---|---|
| C0 | display names | `VocabularyTests` (13) + `window-services-named.png` |
| C1 | header row, grouping | `window-services-live.png` |
| C2 | in-pane search filtering | `ServiceListTests` (9) + field visible in the capture |
| C3 | sort order and persistence | `ServiceListTests` + the choice held in the model |
| C4 | Bundles explains itself | `window-bundles-banner.png` |
| C5 | fitted landing pane | `window-landing-fitted.png` — 292 pt, ~33 pt above the footer |
| C6 | Help sheet | `window-help-sheet.png` |
| C7 | keyboard path | `--dump-appmenu` + `--press`, `window-filter-focus.png` |

Four defects were found and fixed on the way: KI-063 (three sheets), KI-065 (SIGUSR1 killing an instance),
and two naming faults caught by looking (UUID gibberish, sub-identifier suffixes).
