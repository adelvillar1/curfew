# Design

<!-- impeccable:design-schema 1 -->

## Platform

macos — native SwiftUI + AppKit. The window is the app's main surface; the menu bar item is a shortcut.

## World

**The platform is the world.** A macOS utility that supervises system services earns trust by behaving
like part of the system: the standard window, the standard sidebar, system appearance (light and dark),
SF Pro for prose and SF Mono for identifiers, the system accent for the one primary action, semantic
colours for severity. There is no decorative layer, because a surface that says "your machine was
changed" should not also be making a visual argument.

The surface's own idea, in one line: **the state is the title.** The largest type on the window is the
answer to "is my machine quiet, and what is it holding?", and the action that changes it sits on the
same line.

## Colour

Restrained. Neutrals from the system's own materials (`windowBackgroundColor`, `.primary`, `.secondary`),
one accent (the system accent) reserved for the single primary action and for links, and semantic colour
only where it carries meaning: a severity dot beside a severity word.

Never colour alone. Every severity is spelled out next to its dot, because a dot is a decoration until
it is named.

## Type

- State line: `.title2`, semibold — the only large type on the surface.
- Section headers: `.subheadline`, semibold, secondary — the native settings idiom, never an eyebrow
  above a heading.
- Body: system default at `.body` / `.callout`; secondary copy at `.callout` in `.secondary`.
- Identifiers (service labels, bundle names, argv): `.system(.body, design: .monospaced)`. Mono is earned
  here — these are exact strings the user may need to copy, not a costume for "technical".
- Numerals: `.monospacedDigit()` wherever counts or timestamps change, so columns do not jitter.

## Space and depth

- One spacing scale: 24pt at the window edge, 14–18pt between blocks, 5–8pt inside one.
- **Dividers, never cards.** Rows are separated by a hairline inset to the text, as in a native list. No
  rounded containers, no nested cards, no one-sided border bars.
- No shadows. Depth is the divider and the window's own material.
- Windows breathe: 860×430 default, minimum 720×420.

## Motion

None authored. A settings-like surface changes state in place; the only animated things are the system's
own (button press, sheet presentation). Reduced motion is therefore satisfied by construction.

## States

Every pane has four: loaded, empty (a sentence saying why and what to do), disabled (with a tooltip
explaining the lock rather than a grey control with no reason), and error (the problem named, with the
command that fixes it).

## Voice in the interface

Plain and specific. "Quiet mode is off." "2 changes held." "Restoring puts each of these back the way it
was. Nothing else is touched." A refusal says why and what to type instead. No exclamation marks, no
reassurance, no marketing verbs.

## What this surface refuses

The hero-metric template (three big numbers), cards as page structure, a kicker above the heading,
gradient text, glass for decoration, monospace as a personality, emoji standing in for icons, and any
colour that carries meaning without a word beside it.

## Verification

`curfew-menubar --render-window <path> --pane <name>` renders a pane offscreen through a key window and
its own backing store — the way this surface is looked at without screen-recording permission. The
sidebar and split view are AppKit and are checked by opening the app.
