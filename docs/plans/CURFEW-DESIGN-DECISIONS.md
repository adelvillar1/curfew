# Curfew — the design-decisions ledger

**The awareness backbone.** Every plan **reads the choices settled below it** (citing their `D` ids) and **appends its own** when drafted. A plan that contradicts a settled choice is wrong by construction — this ledger is what keeps the stack from diverging when plans are drafted in fresh sessions.

Its three siblings complete the picture: [`CURFEW-DECOMPOSITION.md`](CURFEW-DECOMPOSITION.md) records the **atoms** (the build map), [`CURFEW-CONTRACTS.md`](CURFEW-CONTRACTS.md) records the **interfaces** (what each module offers/expects), and [`../known-issues.md`](../known-issues.md) records what is broken.

Rules:
- `D` ids are **stable and never reused or reordered**; upper layers cite them. A choice is superseded only by a new `D` that names the old one and says why.
- A choice is **settled** when its plan is approved by the owner. Until then it is *proposed*.
- Each entry states the decision, the rationale, and **what it constrains**.

---

## Product boundary

- **D0 — Curfew's surface is the third-party service layer, plus opt-in Apple Tier-2 agents. Tier 0/1 is unreachable and unlisted.**
  Rationale: SIP protects the system plists, so "suspend everything that is not macOS" is not an available product; and the measured value is in the 35 third-party jobs, ~30 of which are vendor updaters. *Constrains:* every catalog, every bundle, the TUI vocabulary.

- **D1 — v1 is read-only: inventory, causality, diagnosis. Mutation ships only after the read-only slice is trusted.**
  Rationale: trust here is binary — one database stopped mid-write ends the product. The read-only slice is also independently useful and independently sellable (it finds crash loops). *Constrains:* L1/L2 atoms; the absence of any mutating call in the v1 binary; the read-only guarantee test.

## Sources of truth

- **D2 — Two sources, split by competence: launchd is the truth for job state, witr is the truth for process causality, and Curfew owns the join.**
  Rationale: measured, not assumed — `witr` reports "not found" for a job at 255,645 runs (no PID), while `launchctl print` has no process ancestry, sockets, cwd or git context. Neither alone answers the question. *Constrains:* `LaunchdInventory`, `WitrClient`, the `ServiceRecord` merge, the `why` command's fallback path.

- **D3 — Tolerant parse of `launchctl print`, strict on field presence; a missing field is never reported as healthy.**
  Rationale: a strict parser makes the diagnostic tool unusable exactly when the machine misbehaves; a fully tolerant one lets `runs = nil` read as "0 loops", which is a false clean — the one outcome this product must never produce. *Constrains:* parser, findings verdicts, `doctor`'s "scan incomplete" output, the per-version fixture gate.

- **D4 — The `system` domain is included, read-only; enrichment of root-owned jobs degrades and is reported as a visibility gap, never as a finding.**
  Rationale: measured — `launchctl print system/com.apple.securityd` as uid 501 returns `state`, `runs`, `pid`, `last exit`. Job state needs no privilege; only witr's enrichment does. Excluding the domain would hide 11 vendor daemons and 7 agents. *Constrains:* enumeration scope, the `enrichmentUnavailable` state, `doctor`'s reporting vocabulary.

- **D5 — `witr` is an optional external dependency: floor `>= 0.3.4`, no upper pin, runtime shape validation, and its exit code is never trusted alone.**
  Rationale: upstream's JSON contract is additive and field-pinned by their own tests, so pinning would break on every release for nothing; but Homebrew can upgrade it silently, and it exits **0** through a pipe when it cannot read a process (KI-005). *Constrains:* `WitrClient`'s parse path, the degraded mode, the version echoed in `--json` and `doctor`.

## Identity and classification

- **D6 — The launchd label is the canonical identity; the process name is a display attribute. Unmanaged processes get a synthesized id.**
  Rationale: three processes named `postgres` listen here under two labels plus a container (KI-013); every future action addresses a label, never a name; witr's own name matching is substring-based by design. *Constrains:* `ServiceRecord.id`, CLI arguments (accept many, emit one), the TUI's display rule.

- **D9 — The never-list is compiled code, not configuration.**
  Rationale: a config file implies "power users may edit it", and that is how a tool bricks a machine. *Constrains:* `NeverList.swift`, the test that every label in the research doc resolves, the absence of a `--force` escape hatch.

## Verdicts

- **D7 — A crash loop requires all three: `runs > 1000`, `lastExit != 0`, and loaded for more than one hour.**
  Rationale: 453 of 887 system plists are `LaunchEvents`-driven and accumulate `runs` legitimately (KI-007); without the exit-code clause the detector reports ~200 false positives on day one, and a detector that cries wolf is worse than none. *Constrains:* the findings rule, its fixtures, `doctor` severity mapping.

- **D8 — On disagreement between sources, conclude the safe reading (never "nothing here") and log the evidence from both sources for later triage.**
  Rationale: owner instruction, 2026-11-24. The failure mode is a false clean; a disagreement is also the only signal that one of the two sources is wrong, so it must be attributable to launchd, witr, or Curfew without re-running anything. *Constrains:* the seven disagreement kinds, the JSONL log schema, "a scan that logged a disagreement is incomplete", rate-limiting by fingerprint.

## Levers (mutation, later layers)

- **D10 — `SIGSTOP` is for GUI apps with no listening socket. A frozen server is a hang, not an error.**
  Rationale: 733 of 887 system plists register a `MachServices` port; a frozen server keeps its port, so clients block with no timeout. The bridge's `kanzoPost` has no timeout at all — a frozen Kanzo is indistinguishable from a slow one. *Constrains:* hard rule 4, the catalog's lever validation, the executor's refusal path.

- **D11 — The lever is a property of the service, not a user preference: `freeze | stop | disable | throttle | command`.**
  Rationale: Spotlight's correct lever is `mdutil`, Time Machine's is `tmutil`, Postgres's is `pg_ctl stop -m fast` — none of which is a launchd verb. *Constrains:* the catalog schema, the executor, the dry-run preview's vocabulary.

- **D12 — Reversibility is a property of the supervisor (`launchd | app-parent | none`), not of the service.**
  Rationale: `kanzo` has no launchd job, so a stop is a one-way door until a human restarts it; the five MCP servers are children of the harness and must never be signalled individually. A `none` entry without a recorded restart command is invalid. *Constrains:* catalog validation, the executor's refusal for unsupervised entries, the dry-run's warnings.

- **D13 — A container-engine deletion is a VM-side win; host and VM reclaim are reported separately and never summed.**
  Rationale: measured — pruning 17 GB inside Kiri left `data.img` at 23 GB because its disk refuses discard (KI-009). Claiming host space for a container prune is a lie the user can check with `df`. *Constrains:* the reclaim report, the `containers-idle` bundle's description, any "GB reclaimed" headline.

- **D14 — In-process engines are `never-cold`, not suspend candidates.**
  Rationale: Laya has no port and no process to signal; its cost is a **180 s** reload on the next sys1 call. A quiet mode that frees 2 GB and adds three minutes is a net loss the user must be told about before choosing it. *Constrains:* the `never-cold` anti-bundle, the catalog's `in-process` kind, the cold-start field.

## What must never be stopped

- **D22 — `sh.brew.postgresql@18` and `com.adelvillar1.sem1-llama` are always-on: Curfew never stops
  them.**
  Rationale: owner decision 2026-11-24 — *"postgress@18 needs to stay up, same as sem1-llama"*. Both
  were previously `draft` stop targets with verified-looking recipes (the pg recipe had been exercised
  during research); that work is superseded, not deleted, because it records what stopping them
  actually costs. A quiet mode that breaks the database and the embedding server is not quiet, it is
  broken — the machine is 16 GB and these two are the reason the rest of the catalog exists.
  *Constrains:* both are `lever: none` + `stoppable: false` with **no recipe** — an
  always-on entry needs no stop recipe and no post-condition, and the validator refuses a bundle that
  acts from containing one (`alwaysOnHasNoRecipe`). `data-services` is now empty as a result.

- **D24 — The Kanzo bridge stays; it is not a stop target.** *(Its laya half is superseded by D25.)*
  Rationale: owner decision 2026-11-25 — *"the kanzo bridge should stay"*. It is the agent path to the
  board (119 requests in its log, 111 of them in one day), so it is `lever: none`, `stoppable: false`,
  with no recipe: the decision is not to stop it, so there is nothing to verify. *Constrains:*
  `harness-core` is a protect bundle and the validator's `alwaysOnHasNoRecipe` test refuses any acting
  bundle that includes it.

- **D25 — laya is removed; the machine uses sys1's paid providers. Supersedes D24's laya half.**
  Rationale: owner decision 2026-11-25 — laya's engine put real memory pressure on a 16 GB machine,
  and sys1 already defaults to `glide,drex,jev` (paid, hosted). The local path bought offline inference
  at a cost the machine could not carry. Removed: the launchd job, 822 MB venv, the model cache, and the
  provider registration. *Constrains:* `never-cold` no longer lists it, and no catalog entry remains for
  a service that does not exist.

## Front ends

- **D23 — The menu bar shows state and restores; it never applies.**
  Rationale: a status item is one click away at all times, so it is the wrong place for a command that
  changes what is running — the click that quiets the machine should be the deliberate one with
  `--execute --yes` in it. Restore is offered because restore returns the machine to how the owner left
  it, which is the direction a one-click surface should point. *Constrains:* `MenuBarModel` has no
  apply action, `curfew-menubar` only calls `Executor.resume`, and the TUI follows the same split.

## Model-assisted decisions

- **D27 — A decision model may propose; it may never gate.** Jev may shape what the catalogue *offers*
  (a draft entry, a suggested disposition) and may *narrow* an action (the quiesce screen). It is
  forbidden from the refuse path, the journal write, and recipe verification.
  Rationale: measured 2026-11-25 — 17/18 agreement with the owner's own verdicts, but **two dangerous
  errors** on uncatalogued services (`stop` proposed for an MCP server and for a VM daemon) until the
  listening sockets were fed in, and a companion noul phrased as a meta-question produced no signal at
  all (0.43 / 0.39 / 0.57 across three different kinds of service) while a concrete one scored 5/6. A
  model that is right 94% of the time is a good colleague and an unacceptable gate; the safety floor
  must stay deterministic, offline and auditable or the journal's evidence stops being reviewable.
  *Constrains:* `JevClient` sits behind an injected transport, every answer lands in `decisions.jsonl`,
  a proposal is always `draft`, the quiesce gate runs **after** every deterministic refusal and can only
  narrow, `unknown` is a first-class outcome, and the default floor is 0.60/0.15.

## Model-assisted decisions

- **D28 — *(superseded by D29)* — Exactly one file may make an outbound network call.**
  Rationale: the project's standing invariant was "no network path" (asserted by
  `ContractShapeTests` over every source file), and D27 puts a model call in the tool. Pretending the
  call is not a network call would be worse than an honest exception. So `JevHTTPTransport.swift` is
  the single allowed file, the test names it, and a *second* file containing any network token still
  fails — the carve-out cannot spread. *Constrains:* the transport stays a separate injected seam (tests
  still never touch the network), the key is read from a 0600 file, and the invariant test asserts
  `networkFiles == [JevHTTPTransport.swift]` rather than merely skipping it.

## Model-assisted decisions

- **D29 — There is no no-network rule; the diagnostic path is offline-capable instead.**
  Rationale: owner ruling 2026-11-25 — *"change the invariant, this is a tool for me, not something I'm
  going to put out on an app store"*. The old ban (D18's second half) existed because "nothing leaves
  the machine" was enforceable only by having no networking code; that stopped being the right trade the
  moment a decision model became a feature. What replaces it is the property the ban was a proxy for:
  **every diagnostic surface works with no network and no key** — `list`, `why`, `doctor`, `catalog
  validate|list|plan`, `status`, the TUI and the menu bar. Model-assisted surfaces may call out, and
  must fail *visibly* (a named error, an `unknown` confidence) rather than by guessing.
  *Constrains:* `JevClient.liveClient()` throws `missingKey` with the path it looked at; a transport
  failure is `unknown`, never a confident answer; and the diagnostic modules must not depend on the Jev
  layer at all — asserted structurally, so the core cannot quietly grow a dependency on the model.

## Privilege

- **D20 — The privileged helper is not a command executor; it is a catalog executor.**
  Rationale: a helper that runs argv from a client is a root shell with extra steps, and every XPC
  client-identity bug becomes a privilege-escalation bug. The helper therefore accepts only
  `{entryId, action}`, loads the catalog itself, resolves the recipe, and refuses anything that is not
  a `verified` entry whose recipe declares `needsRoot: true`. A compromised client can then only ask
  for operations that were already reviewed and recorded. *Constrains:* the XPC protocol shape, the
  helper's authorization function, and the fact that non-root recipes never cross the boundary at all.

- **D21 — Curfew is an internal, single-user tool: privilege comes from `sudo`, not from a signed
  daemon. Supersedes the distribution half of D17 and the daemon half of the L4 plan.**
  Rationale: `SMAppService`, XPC and code-signature validation exist so a *distributed* app can be
  trusted with root. For one person on one machine, `sudo` does that — and it deletes a $99/year
  membership, a certificate, a daemon, a wire protocol and a registration prompt. The property worth
  keeping survives in-process: **as root, the executor still runs only verified, cataloged,
  root-requiring recipes** (`SudoPrivilegeTests`), so root is never a licence to run anything the
  catalog has not reviewed. *Constrains:* `Domain.effective` (under sudo the domain is the invoking
  user's, `gui/$SUDO_UID`, not `gui/0`), the refusal that names `sudo`, and the absence of any
  signing, notarisation or cask work.

## Engineering

- **D15 — Swift 6 + Swift Package Manager; one engine (`CurfewKit`) with thin front ends. No Electron.**
  Rationale: a memory-reclaiming tool cannot park 300–600 MB of Chromium; the native helper exists either way, so Electron adds a boundary without removing work. *Constrains:* package layout, the CLI/TUI/menu-bar split, the dependency budget.

- **D16 — The helper owns journal state; front ends are stateless views.**
  Rationale: if the process that stopped twenty services is also the process that dies, nothing restores them. *Constrains:* L4 atoms, the `status` command reading from the helper, fail-open restore.

- **D17 — Not sandboxed, not on the Mac App Store.** *(The Developer ID + notarisation half is
  superseded by D21: there is nothing to distribute.)*
  Rationale: a sandboxed app cannot drive `launchctl` against arbitrary services. *Constrains:* the
  binary runs as a plain CLI from PATH.

- **D18 — No argv and no environment values in any log.** *(The "no network path at all" half is
  retired by D29.)*
  Rationale: `--api-key=…` in argv is the obvious leak, and a diagnostic tool that reads every plist on
  the machine is exactly the wrong place to be sloppy. *Constrains:* the disagreement log's fields and
  the redaction test. This half does not move: a model call is a new outbound path, not a licence to
  start writing argv or environment values into logs.

- **D19 — The ledgers are the record: a plan that contradicts a settled `D` is wrong by construction, and a ledger change is policed before it is committed.**
  Rationale: `/skill:project-methodology`'s ledger discipline — stable ids, append don't rewrite, close with evidence, one home per fact. *Constrains:* every plan's citation duty, `scripts/ledger_check.py` in the recap loop.

- **D30 — The menu's "Start quiet mode" runs the dry run inside its own confirmation.**
  Rationale: rule 3 says a dry run comes before the first live change, and a menu item cannot show you a
  journal afterwards. So the action is two steps inside one click — `apply --bundle vendor-noise` without
  `--execute` first, its plan shown in the confirmation dialog, and `--execute --yes` only if the operator
  presses Apply. Cancel and nothing happens. `--yes` is passed explicitly because a menu is not a TTY and
  the CLI refuses `--execute` without it; that refusal is the safety it was built with, so the menu states
  the intent rather than the CLI learning to trust a GUI. When quiet is on the same row becomes
  `Restore everything…`: a greyed-out "Nothing to restore" reads as a broken button (KI-043).
  Constrains: `MenuItemKind.startQuiet` · `DashboardLauncher.quietCommand` · the menu bar's only mutating
  action. **The first live apply on this machine is still unperformed — the menu can now do it, and doing
  it is the owner's click.**

- **D31 — Curfew.app becomes a windowed app, and the window is the main surface.**
  Rationale: a menu item cannot show state, a plan, or what is being held — the owner's own words were
  "we need a real interface beyond the menu in the Finder". The app now has a Dock presence
  (`LSUIElement` false), a sidebar over Quiet mode / Bundles / Findings / Services, and the same
  `Executor`/`Journal` the CLI uses: the window is a surface, never a second implementation. Closing the
  window leaves the app running so the status item survives; the login opener passes `--background` so a
  window does not appear over the owner's work at startup. Every action that can change a service keeps
  the two-step discipline — the plan is shown, then applied on confirmation (D30 extended to the window).
  Constrains: `AppSnapshot` (C23) · `Window.swift` · `PRODUCT.md` and `DESIGN.md`, which now carry the
  product truth and the visual system for this surface.

- **D32 — "Already in that state" is judged per lever.**
  Rationale: rule 6 ("never resurrect what we did not stop") asks whether Curfew created the state it is
  about to change. For a `stop`/`bootout` that state is "not running". For a **`disable`** it is
  "disabled" — and an idle, enabled job is precisely what a disable is for. Keying the guard on the
  running state alone made disable a silent no-op on every on-demand agent (KI-048), which surfaced as a
  Stop button that appeared to do nothing.
  Constrains: `Executor::run`'s pre-existing guard · what a recipe's `verify:` checks (C20's
  `labelDisabled` is the matching verification).

- **D33 — The app's own code path is driveable from the command line.**
  Rationale: KI-042, KI-047 and KI-048 were each found by *pressing* something and none by reading the
  code; a path that cannot be driven without a mouse cannot be checked at all. `--render-window` looks at
  a pane; `--drive-stop` / `--drive-start` run the window's exact model path and print what it recorded.
  Constrains: `curfew-menubar`'s debug entry points.

- **D34 — Debris is quarantined, never deleted.**
  Rationale: a removed app can leave a plist whose program is gone, and on this machine one of six such
  findings is exactly that — `com.valvesoftware.steamclean`, still spawn-scheduled with a 60-second
  throttle, failing with `EX_CONFIG` forever. Deleting would be the first irreversible thing Curfew does
  and would break the one promise the product is built on. So the plist **moves** into
  `~/Library/Application Support/Curfew/quarantine/<timestamp>/`, keeping its path shape, journaled
  before the move, and `resume` moves it back.
  Constrains: `QuarantineStore` (C25) · `Executor::resume`'s quarantine branch · `Journal.held`.

- **D35 — "Dangling program" is three different findings, and only one is actionable.**
  Rationale: of six dangling programs on this machine, four are platform artifacts under `/System` (SIP
  owns them; `Battery.menu` does not exist on Apple Silicon), one belongs to a live project whose
  virtualenv was deleted, and one is litter. A blanket cleanup would have been wrong about five. So a
  missing program under `/System` or `/usr` is reported as `environmental` with "nothing to do" in its
  summary, and quarantine is offered **only** when the program is missing *and* the owning app is
  verifiably absent (`QuarantineEligibility`), never under `/System`, and never for a path that names no
  app.
  Constrains: `Findings::danglingProgram` · `QuarantineEligibility::judge` · the finding list's severity mix.

- **D36 — GUI apps are surfaced, never pre-selected, and freeze is the default verb.**
  Rationale: measured on this machine, fifty-one apps hold **4,156 MB** — Firefox alone 1,899 MB — while
  the entire vendor-noise bundle holds **20 MB**. The daemons were never where the memory was. But
  "related to development" is not knowable: Firefox may be holding docs, the harness *is* the development
  environment, a cloud client may be mid-sync. So Curfew lists apps with observable facts (memory,
  process count, frontmost, frozen) sorted biggest first and selects nothing. **Freeze** (`SIGSTOP`) is
  the verb — instant, exactly reversible, and the app never knows; **Quit** is the deliberate, quieter
  choice because it can lose unsaved work. The shell, this harness and Curfew itself are excluded, and so
  is the remote-access path (rule 7): freezing Tailscale would cut the only way into the machine.
  Constrains: `AppsScanner::neverTouch` · `AppControl` (C26) · the window's Apps pane.

- **D37 — The sidebar derives from the pane enum.**
  Rationale: the Apps pane was built complete — case, view, switch, tests — and shipped unreachable
  because the sidebar was a hand-written list I forgot to extend (KI-052). A surface whose navigation is
  maintained by hand drifts from the set of surfaces that exist. `Pane.allCases` grouped by `section` makes
  a pane impossible to add without a row, and `--dump-panes` prints what the sidebar is built from.
  Constrains: `AppModel.Pane` · `Sidebar` · the `--dump-panes` entry point.

- **D38 — The app speaks English at the row boundary; identifiers stay in the detail.**
  Rationale: the row is the recognition surface. `disable`, `spawnScheduled`, `danglingProgram` are the
  tool's vocabulary, not the person's, and five of them at one weight per row forced parsing. `Vocabulary`
  translates (`disabled`, `waiting to start`, `program missing`); the raw identifier moves into the
  Investigate sheet, where detail belongs. An unknown value passes through rather than being swallowed.
  Constrains: `Vocabulary` (C27) · every row in the window.

- **D39 — A plan carries an action, not a closure, so it can run off the main actor.**
  Rationale: a closure plans and applies in one step, which is why applying blocked the window. A
  `PlanAction` (bundle / entries / restore / quarantine / quit) can be executed detached while the
  executor reports each step through `onStep`, so the sheet ticks rows as they land and the window never
  looks hung.
  Constrains: `AppModel.PlanAction` · `Executor.apply(…, onStep:)` and `Executor.resume(…, onStep:)` (C2).

- **D40 — One instance, and an install shows a window.**
  Rationale: the login opener `exec`s the binary directly, so LaunchServices never deduplicated it against
  a later `open -a` (KI-061) — two status items, two windows. An exclusive `flock` before the GUI runs
  makes single-instance deterministic, and it sits **after** the early-exit flag paths so the driveable
  entry points still work while the app is live. And because the opener passes `--background`, an install
  left no window on screen at all and looked like a no-op (KI-060); `make install-app` now finishes with
  `open -a` so the result is visible.
  Constrains: `curfew-menubar`'s main entry · `make install-app`.

