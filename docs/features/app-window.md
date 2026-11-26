# The window

`Curfew.app` is a windowed menu bar app. The window is the main surface; the status item is a shortcut.

## Panes

| Pane | Shows | Actions |
|---|---|---|
| **Quiet mode** | the state line, what quiet mode would stop (or what it is holding), the last completed session | Start quiet mode…, Restore all, Preview the plan / Restore |
| **Bundles** | every stop bundle with its summary and `n of m would change`; the protect bundles under *Protected — never actioned* | Preview (disabled while quiet, with a banner explaining why and offering Restore) |
| **Findings** | one row per finding: severity word and dot, the summary, `severity · label · kind · state` | Investigate, Stop / Start (state-aware), Quarantine… when the owning app is verifiably gone |
| **Services** | the launchd inventory, grouped by kind with counts, under a column header (name · state · tier · findings) | — (read-only) |
| **Apps** | GUI apps by memory, with process count and frozen/front-of-screen state | Freeze / Resume, Quit… |

## Display names

A launchd label is not a name a person recognises. `Vocabulary.displayName(for:)` renders
`application.com.apple.ActivityMonitor.1152921500311908412.1152921500311908417` as **Activity Monitor**, while the
raw label stays on the row's monospace detail line and in `--json` output. Rules, in order:

1. strip the `application.` prefix; drop trailing numeric and UUID components;
2. drop the TLD, drop `apple` as a vendor, drop platform words (`macos`, `osx`, `desktop`, `client`, `app`);
3. a capitalised first component is the product name (`AddressBook.AssistantService` → *Address Book*);
4. otherwise join the remaining components, splitting camelCase and hyphens, upper-casing known acronyms
   (`ipn` → IPN) and capitalising the rest;
5. a name longer than 28 characters falls back to its most specific component.

Names can collide — three Address Book jobs share a display name. The raw label on the line below is the
disambiguator, which is why it never leaves the row.

## Filtering and sorting (Services, Apps)

The Services list filters on the display name **or** the raw label, sorts by name, state or findings, and groups
by kind in a fixed order (Apps, Agents, Daemons). That logic lives in `CurfewKit/ServiceList.swift` as pure
functions and is covered by `ServiceListTests`, so the behaviour is provable without a mouse. The sort choice is
held by the window's model, not by the view, which is what makes it survive a pane switch.

## States

Every pane has loaded, empty (a sentence naming what to do next), disabled (with the reason on the pane, not
only in a tooltip) and error states. A window with no catalogue says so rather than rendering blank.

## Seeing a sheet without an input device

The cua driver can read this window's accessibility tree and pixels but refuses every input route to it
(`ax_unresolved`). Sheets are therefore provable by asking for them at launch: `--open-help` sets the same flag
the footer button sets, and the capture shows the sheet presented.

## The window's own identity

The title carries the build (`Curfew — 05cc6d2`) and the footer prints `Curfew 0.1.0 · <commit> built <time>`, so
"is this the new build?" is answered by the app rather than by a shell command.
