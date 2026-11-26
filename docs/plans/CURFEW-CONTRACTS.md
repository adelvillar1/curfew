# Curfew — the contract ledger (what each module offers / expects)

**The interface registry.** [`CURFEW-DECOMPOSITION.md`](CURFEW-DECOMPOSITION.md) records the atoms (the build map); [`CURFEW-DESIGN-DECISIONS.md`](CURFEW-DESIGN-DECISIONS.md) records the choices (`D` ids); this records the **interfaces** — for every module, what it **OFFERS** (the exact calls and types others may use) and what it **EXPECTS** (the offers it consumes, naming the provider).

How to read it:

- **OFFERS** — the module's public contract. Signatures are Swift-flavoured and normative; a change here is a contract change — update the consumers.
- **EXPECTS** — each entry names its provider: `Symbol (C<n>)` for an in-project module, `thing (external)` for something outside (`launchctl`, `witr`, the filesystem).
- **CONSUMED BY** — the reverse index. Touch an offer, check this list.

**The consistency rule:** every `EXPECTS` resolving to `(C<n>)` must name an `OFFERS` symbol that exists in that section. An `EXPECTS` naming no offer is a **broken seam** — fix it before building. `scripts/ledger_check.py` enforces this.

**The contract precedes the code.** Nothing here is implemented yet; these are the seams the first plan builds against. A signature that changes during implementation changes this file in the same commit.

---

## C0 — Shared types (the bedrock)

```text
OFFERS   ServiceRecord · ProcessFacts · Finding · AncestryNode
         Tier · Kind · Lever · JobState · Supervision · Domain · Enrichment · Severity
         SystemVersion::shellVersion() -> String · formatFixture() -> String?
EXPECTS  (nothing — the bedrock defines types and no behaviour)
CONSUMED BY  every module below
```

```swift
// Sources/CurfewKit/ServiceRecord.swift
struct ServiceRecord {
  var id: String              // the launchd label, or "unmanaged:<exe>@<port>"  (D6)
  var domain: Domain          // .gui(uid: UInt32) | .system
  var plistPath: String?
  var state: JobState         // .running(pid: Int32) | .spawnScheduled | .notLoaded | .disabled | .unknown
  var runs: UInt64?           // nil means UNKNOWN, never 0  (D3)
  var lastExitCode: Int32?    // 78 == EX_CONFIG
  var program: String?        // ProgramArguments[0]
  var keepAlive: KeepAliveMode
  var tier: Tier              // .protected | .osCore | .appleAgent | .thirdParty
  var kind: Kind              // .daemon | .agent | .appChild | .container | .inProcess | .command | .unmanaged
  var vendor: String?
  var supervised: Supervision // .launchd | .appParent | .none
  var process: ProcessFacts?  // witr enrichment; nil when not running or witr unavailable
  var findings: [Finding]
  var enrichment: Enrichment // .ok | .unavailable(reason) | .degraded(reason)
}

struct ProcessFacts {           // exactly what witr gives us, no derived opinion
  var pid: Int32
  var exe: String
  var workingDir: String?
  var gitRepo: String?
  var gitBranch: String?
  var listeningPorts: [UInt16]
  var ancestry: [AncestryNode]  // from launchd (pid 1) down to the process
  var sourceType: String        // "launchd" | "ssh" | "cron" | "docker" | "unknown"
  var sourceName: String?
  var warnings: [String]
  var cpuPercent: Double?
  var memoryRSS: UInt64?
}

struct Finding {
  var id: String                // "crashLoop", "danglingProgram", …
  var severity: Severity        // .blocker | .defect | .gap | .improvement | .environmental | .risk
  var summary: String
  var evidence: String          // the literal observation that justifies it
  var confirmsScan: Bool        // false when the finding is "we could not look"
}
```

## C1 — `NeverList` — Sources/CurfewKit/NeverList.swift

```text
OFFERS   NeverList · isProtected(label: String) -> Bool
         isProtected(processName: String) -> Bool   // second net, not a substitute
         all() -> [String]                          // 28 labels + process names
EXPECTS  (nothing — a leaf by design, D9)
CONSUMED BY  Classification (C3) · Findings (C4) · the future Executor
```

## C2 — `LaunchdInventory` — Sources/CurfewKit/LaunchdInventory.swift

```text
OFFERS   enumerate(domain: Domain) -> [ServiceRecord]        // tolerant table scan (D3)
         detail(label: String, domain: Domain) -> ServiceRecord?  // strict field extraction
         listLabels(domain: Domain) -> [String]
EXPECTS  launchctl print (external) · SystemVersion::formatFixture (C0)
CONSUMED BY  curfew list (C7) · curfew why (C7) · Findings (C4) · DisagreementLog (C6)
```

The `formatFixture` offer is what makes D3's per-version gate real: `detail()` refuses to trust a
missing field, and `formatFixture()` returning `nil` for an unseen macOS major is how `doctor` says
"the parser has no fixture for this OS" instead of guessing.

## C3 — `Classification` — Sources/CurfewKit/Classification.swift

```text
OFFERS   classify(_ record: ServiceRecord) -> Classification   // tier, kind, vendor, supervised
         vendor(for label: String) -> String?
EXPECTS  NeverList::isProtected (C1)
CONSUMED BY  curfew list (C7) · the future catalog loader
```

## C4 — `Findings` — Sources/CurfewKit/Findings.swift

```text
OFFERS   FindingsEngine · evaluate(_ record: ServiceRecord) -> [Finding]        // pure; no I/O, no clock beyond a passed Date
         crashLoop(_ record: ServiceRecord, loadedFor: Duration) -> Finding?   // D7's three clauses
         danglingProgram(_ record: ServiceRecord, resolve: (String) -> String?) -> Finding?
EXPECTS  ServiceRecord (C0) · NeverList::isProtected (C1)
CONSUMED BY  curfew doctor (C7) · curfew why (C7) · DisagreementLog (C6)
```

`evaluate` must be a pure function of its inputs plus the injected clock and resolver — that is what makes the seven rules testable against fixtures with no machine.

## C5 — `WitrClient` — Sources/CurfewKit/WitrClient.swift

```text
OFFERS   probe(pid: Int32) -> WitrReport?           // nil when witr is absent or cannot see it
         probe(port: UInt16) -> WitrReport?
         probe(name: String) -> WitrReport?
         version() -> String?                        // nil when absent
         isCompatible() -> Bool                      // >= 0.3.4 (D5)
EXPECTS  witr executable at /opt/homebrew/bin/witr or $PATH (external) ·
         DisagreementLog::append (C6)
CONSUMED BY  curfew why (C7) · Findings (C4, optional enrichment)
```

Rules this module enforces, not the caller: argv-only invocation (never a shell string), JSON parse with `Error` inspection, and **no decision from the exit code** (KI-005).

## C6 — `DisagreementLog` — Sources/CurfewKit/DisagreementLog.swift

```text
OFFERS   append(kind: DisagreementKind, target: Target, launchd: [String: String],
                witr: [String: String], verdict: Verdict)
         summarize() -> [DisagreementCount]          // grouped by fingerprint
         suppressedCount(for fingerprint: String) -> UInt32
EXPECTS  filesystem at ~/Library/Logs/Curfew/ (external) · clock (external)
CONSUMED BY  WitrClient (C5) · LaunchdInventory (C2) · curfew doctor --disagreements (C7)
```

Invariants it owns: the seven kinds from `D8`; fingerprint rate-limiting (one line per 10 minutes, suppressed count flushed on the next write); rotation at 5 MB × 3; and the redaction rule — `argc` and basename only, never argv, never env (D18).

## C15 — `JevClient` — Sources/CurfewKit/JevClient.swift

```text
OFFERS   JevClient(transport:model:policy:) · liveClient() throws -> JevClient
         ask(questions:state:) throws -> [String: JevAnswer]
         ConfidencePolicy::classify(answer) -> Confidence (.confident / .marginal / .unknown)
         JevTransport (the injected seam) · JevHTTPTransport (the one allowed outbound call, D29)
EXPECTS  a JevTransport (injected; the real one is HTTP) · a key file at ~/.config/curfew/jev.key (0600)
CONSUMED BY  Propose (C16) · the executor's quiesce gate · `doctor --rank`
```

Every request sends `User-Agent: curfew` — Cloudflare answers 403/1010 to urllib-shaped clients, measured
twice on this machine. The transport, clock and cache are injected, so the whole surface is testable
without a network. `unknown` is a first-class outcome: a transport failure is never read as confidence.

## C24 — `Journal.held` — Sources/CurfewKit/Journal.swift

```text
OFFERS   held() -> [JournalRecord] · restorePlan() -> [JournalRecord] (held ∪ unresolved, newest first)
EXPECTS  nothing — it reads the journal file
CONSUMED BY  curfew status · curfew resume · AppSnapshot (C23) · the menu bar's quiet state

`Executor.resume(context:catalog:labels:)` narrows a restore to named labels — the window's per-finding
Start, which must undo exactly one service and leave the rest held (C23's `isHeld`).
```

`held()` is what Curfew changed and can undo: intents whose action succeeded and which no `resume` has
closed. `restorePlan()` is the **union of `held()` and `unresolved()`** — normal quiet mode plus a run that
died mid-action. Dropping either strands a state.

## C25 — `QuarantineEligibility` / `QuarantineStore` — Sources/CurfewKit/Quarantine.swift

```text
OFFERS   QuarantineEligibility::judge(program:plistPath:fileExists:home:) -> Verdict (.eligible / .refuse)
         QuarantineStore::quarantine(plistPath:label:journal:) -> StepOutcome · defaultRoot
         QuarantineStore::restore(from:to:)
EXPECTS  Journal (C24) · the inventory's record's `program` and `plistPath`
CONSUMED BY  Curfew.app's findings list · Executor::resume (the quarantine branch)
```

**Moves, never deletes** (D34). Eligible only when the program is missing, the path is not under
`/System`/`/usr`, and the owning app is verifiably absent — established from a `.app` in the path or an
`Application Support/<Name>/` folder, and refused when neither names an app (D35). Every refusal carries
a reason the window shows as the button's tooltip.

## C23 — `AppSnapshot` — Sources/CurfewKit/AppSnapshot.swift

```text
OFFERS   AppSnapshot (quiet · held · bundles · services · findings · problem · stateLine)
         AppSnapshotProvider::load(domain:catalogDirectory:journal:now:)
EXPECTS  Journal::held (C24) · Catalog (C9) · LaunchdInventory · FindingsEngine (C4) · NeverList (C1)
CONSUMED BY  Curfew.app's window — CurfewKit.AppSnapshotTests (6 tests)
```

One value the window renders, gathered from the same model the CLI prints, so the two cannot disagree.
`problem` explains an empty window instead of leaving it blank. A finding carries `canStop` **only**
where a verified, catalogued, non-protected stop recipe exists — the affordance is earned, not assumed.

## C22 — `MenuBarModel` (menu actions) — Sources/CurfewKit/MenuBarModel.swift

```text
OFFERS   MenuBundle(name:members:acting:) · MenuItemKind.bundle(String)
         build(... bundles:protectedBundles:) -> MenuBarModel
         DashboardLauncher::previewCommand(cli:catalog:bundle:) -> String
EXPECTS  Catalog (C9) · CatalogBundle (C9) · DashboardLauncher (C21) · MenuBarModel::defaultQuietBundle
CONSUMED BY  Curfew.app's menu — CurfewKit.MenuBarModelTests (5 tests)
```

A `bundle` item **previews**: `curfew apply --bundle X` with no `--execute`, so selecting it can never
change a service. Disabled when quiet is on or when none of its members act. `protect` bundles are never
offered, but they are named in a row so the catalogue's size stays honest.

`MenuItemKind.startQuiet` is the menu's **only** mutating action (D30): the dry run is shown in its
confirmation dialog and `--execute --yes` runs only after Apply. It becomes `.restore` when quiet is on.
`DashboardLauncher.quietCommand(cli:catalog:bundle:)` builds the apply line;
`quietPreviewCommand` builds the read-only one.

## C21 — `DashboardLauncher` — Sources/CurfewKit/DashboardLauncher.swift

```text
OFFERS   DashboardLauncher::candidates(environment:fileExists:) -> [String] · resolve(...) -> String?
         command(cli:catalog:) -> String · missingMessage(candidates:) -> String
EXPECTS  a CLI produced by `make install` (~/.local/bin/curfew) · osascript/Terminal (the app target)
CONSUMED BY  Curfew.app's "Open dashboard…" item
```

The subcommand comes **first** — `curfew tui --dir X`. `curfew --dir X` reads `X` as the command name
and prints help, which is how a working launcher can still look dead. Resolution order: `CURFEW_CLI`,
`~/.local/bin`, Homebrew, `/usr/local`, then `PATH`. A missing CLI is an error with every path listed,
never a silent no-op.

## C20 — `RespawnTracker` — Sources/CurfewKit/RespawnTracker.swift

```text
OFFERS   scan(_ records:) -> (deltas: [RespawnDelta], samples: [String: RespawnSample])
         load() / save(_:) · finding(for: RespawnDelta) -> Finding
EXPECTS  ~/Library/Application Support/Curfew/runs.json (external; CURFEW_RUNS_STATE overrides)
CONSUMED BY  curfew doctor — which must save the samples even when nothing fires
```

Restarts **per hour** between scans, for the loop the crash-loop rule must stand down on (a job observed
running). Four conditions, each measured against this machine's data: supervised (`keepAlive != never` —
an unsupervised job's `runs` counts activations), a non-zero exit code, samples ≥5 min apart, and a rate
in `[10, 600]/h` — 600 is launchd's throttle ceiling, so above it the number is churn, not looping.

## C19 — `FindingsRanker` / `FindingsRunner` — Sources/CurfewKit/FindingsRanker.swift

```text
OFFERS   FindingsRanker::state(_:) -> String · questions(range:) -> [JevQuestion] (one score head each)
         FindingsRanker::order(_:impacts:) -> [RankedFinding]   // impact desc, ties by input order
         FindingsRunner::rank(_:) -> (ranked, note)             // never throws, never empties
EXPECTS  JevClient (C15) · DecisionLog (C16) · FindingReport (C7 — the doctor JSON shape)
CONSUMED BY  curfew doctor --rank
```

**Ordering only.** Severity labels are mechanical and are printed unchanged. A model failure returns the
input order with a note; an individual unscored finding is shown last rather than dropped. The note
carries the observed impact range, because a threshold that decides whether a ranking "means something"
tuned to one sample is a lie — two runs of the same 17 findings scored the top one 1.9 and then 2.1.

## C18 — `QuiesceGate` — Sources/CurfewKit/QuiesceGate.swift

```text
OFFERS   QuiesceGate::question() -> JevQuestion · state(entry:record:listeners:connections:) -> String
         evaluate(state) -> QuiesceVerdict (.idle / .busy / .unsettled / .unavailable)
         QuiesceMode::applies(to:) · fromEnvironment(_:)
EXPECTS  an injected ask closure (the real one wraps JevClient, C15) · Executor::liveConnections (lsof)
CONSUMED BY  Executor::run — after every deterministic refusal, before any journal intent
```

Bands: `p ≥ 0.65` busy → refuse; `p ≤ 0.35` idle → the ordinary checks proceed; the band between
refuses unless `--allow-unsettled`. **An unreachable model is `unavailable`, which refuses** — never
"assume idle". `QuiesceMode.auto` asks only where the entry declares a `quiesce:` probe, which today is
nowhere, so the gate is dark until a state-holding service is catalogued.

## C17 — `Proposer` / `ProposeRunner` — Sources/CurfewKit/Propose.swift

```text
OFFERS   Proposer::questions() -> [JevQuestion]        // four heads, one request
         Proposer::decide(_:policy:) -> (ProposeDecision, Confidence, [String])
         Proposer::state(record:label:listeners:) -> String      // JSON evidence
         Proposer::yaml(_:record:) -> String                     // always status: draft
         ProposeRunner::propose(record:label:listeners:) throws -> Proposal
EXPECTS  JevClient (C15) · DecisionLog (C16) · NeverList::isProtected (C1) · ServiceRecord (C0)
CONSUMED BY  curfew catalog propose [--all] [--json] [--write FILE]
```

**The disposition is overridden by the nouls**: `is_infrastructure ≥ 0.50` or `has_state_to_lose ≥ 0.50`
→ `protect`, whatever the choice said. That is the measured fix — metadata alone sent an MCP server and
a VM daemon to `stop`. Everything else needs `confident` under the 0.70/0.20 policy, or it becomes
`review`. A never-list label is answered without asking the model at all.

## C16 — `DecisionLog` — Sources/CurfewKit/DecisionLog.swift

```text
OFFERS   DecisionLog::append(row) · makeRow(…) · cached(model:state:questions:) -> DecisionRow?
         rows() -> [DecisionRow]        // the cache, keyed by the state and question hashes
EXPECTS  ~/Library/Application Support/Curfew/decisions.jsonl (external)
CONSUMED BY  Propose · the quiesce gate · `doctor --rank`
```

The journal records what Curfew *did*; this records *why a model proposed it*. One row per answer,
carrying the model, the state and question hashes, the answers and the decision taken. Cached replay is
keyed by those hashes, so the same triage is free and byte-identical.

## C14 — `MenuBarModel` — Sources/CurfewKit/MenuBarModel.swift

```text
OFFERS   MenuBarModel::build(quiet:unresolvedCount:runningCount:findingCount:bundleCount:version:) -> MenuBarModel
         MenuBarModel::statusTitle(quiet:unresolved:) -> String
         MenuBarModel::dump() -> String
EXPECTS  nothing — it is a pure projection of counts the caller already has
CONSUMED BY  curfew-menubar (AppKit shell) · --dump-menu
```

The menu bar shows state and offers restore; **it never applies a bundle** (D23). Pure, so the glyph
and the enabled/disabled states are tests.

## C13 — `TUI` — Sources/CurfewKit/{TUI.swift}, Sources/curfew/TUILoop.swift

```text
OFFERS   TUIBuilder::state(records:catalog:quietMode:title:selectedBundle:) -> TUIState
         TUIRenderer::render(_:width:height:) -> String
         TUIKeys::parse([UInt8]) -> TUIKey?
         TUIState::move / toggle / nextBundle / markBundleMembers
EXPECTS  ServiceRecord (C0) · Catalog::bundle (C9) · terminal (external, TUILoop only)
CONSUMED BY  curfew tui · the bare `curfew` invocation
```

The view model and the renderer are pure, which is what makes "the quiet-mode banner is on every
frame" a test rather than a hope. `TUILoop` only moves bytes. **The TUI cannot act**: it has no runner
and no transport, so previewing is the only thing the screen can do.

## C12 — `HelperPolicy` — Sources/CurfewKit/HelperProtocol.swift

```text
OFFERS   HelperPolicy::decide(HelperRequest, caller: HelperCaller, catalog:, expectedTeamIdentifier:) -> HelperDecision
         HelperRequest / HelperResponse      // wire types: entryId, action, intentSeq — never argv
EXPECTS  Catalog::entry (C9) · NeverList::isProtected (C1) · caller signature (external, SecCodeCheckValidity)
CONSUMED BY  curfew-helper (planned) · Executor::runPrivileged (C11)
```

**The privileged boundary's only rule: the helper is a catalog executor, not a command executor (D20).**
It accepts an entry id and an action, loads the catalog itself, and refuses anything that is not a
verified, root-requiring entry from a validly signed caller. A request that could carry argv would be a
root shell with extra steps; `noArgvOnTheWire` asserts it cannot.

## C11 — `Executor` — Sources/CurfewKit/Executor.swift

```text
OFFERS   apply(bundle:catalog:context:execute:) -> [StepOutcome]
         resume(context:catalog:) -> [StepOutcome]
         substitute(_:domain:plist:) -> [[String]]?  // {domain} and {plist}; nothing else
         refusal(for:context:) -> String?
EXPECTS  Journal::appendIntent (C10) · CatalogPlanner::plan (C9) · NeverList::isProtected (C1) ·
         Probes (portIsOpen / pidExists / labelIsRunning) · runner argv (external) ·
         PrivilegedTransport (C12, optional — absent means root recipes are refused)
CONSUMED BY  curfew apply · curfew resume (C7)
```

The order is the design: **refuse → journal the intent → act → verify → journal the outcome.** A refusal
happens before the first intent is written, so a refused run leaves no journal trace. A failed
post-condition stops the run rather than continuing to the next entry. The runner and the three probes
are injected, so every ordering guarantee is a test rather than a review note.

## C10 — `Journal` — Sources/CurfewKit/Journal.swift

```text
OFFERS   appendIntent(entryId:action:argv:) throws -> Int     // flushed before the caller acts
         appendOutcome(intent:result:verified:error:) throws
         records() -> [JournalRecord]
         unresolved() -> [JournalRecord]
         restorePlan() -> [JournalRecord]                      // reverse order
         parseJournalTimestamp(String) -> Date?
EXPECTS  filesystem at ~/Library/Application Support/Curfew/journal.jsonl (external)
         CURFEW_JOURNAL overrides the path (external)
CONSUMED BY  the executor (C11, planned) · curfew status (C7)
```

Append-only JSONL. A truncated final line is skipped, never fatal — a crash mid-write must not make the
journal unreadable or let a half-written record look like a completed action. If `appendIntent` throws,
**the caller must not act**: that is rule 2's teeth.

## C9 — `Catalog` — Sources/CurfewKit/{Catalog,MiniYAML}.swift

```text
OFFERS   Catalog · CatalogEntry · CatalogBundle
         Catalog::entry(_:) -> CatalogEntry? · Catalog::bundle(_:) -> CatalogBundle?
         CatalogLoader::load(directory:) throws -> Catalog
         CatalogValidator::validate(_:) -> [CatalogViolation]
         CatalogPlanner::plan(bundle:in:) -> (steps: [CatalogStep], refusals: [CatalogRefusal], protectedPorts: [UInt16])
         MiniYAML::parse(String) throws -> YAMLValue
EXPECTS  NeverList::isProtected (C1) · filesystem (external)
CONSUMED BY  curfew catalog (C7)
```

**This module spawns nothing.** It reads files and does arithmetic; `CatalogReadOnlyTests` fails the
build if `Process(` or `executableURL` ever appears in it. Execution is L3.3 and will need its own seam.

## C8 — `ListenerScan` — Sources/CurfewKit/ListenerScan.swift

```text
OFFERS   ListenerParser::parse(String) -> [Listener]
         ListenerScanner::scan() -> [Listener]
         ExecutableResolver::memoized(_:) -> ExecutableResolver
         ListenerFindings::orphanPorts(listeners:records:executableForPid:) -> [Finding]
         ListenerFindings::unattributed(listeners:records:executableForPid:) -> Finding?
EXPECTS  ServiceRecord (C0) · lsof (external)
CONSUMED BY  curfew doctor (C7)
```

Identity is the resolved executable path, never the command name: `lsof` truncates `COMMAND` to nine
characters and every `node` shares it (KI-025). An orphan also requires the job to be **dead** — a
running job with a second process of the same binary is a second instance, not a leftover (KI-026).

## C7 — `curfew` CLI — Sources/curfew/ (the external surface)

```text
OFFERS   FindingReport / DoctorOutput / ListOutput / WhyOutput (the external JSON shapes)
         curfew list   [--domain gui|system|all] [--json]
         curfew why    <label|--pid N|--port N|--name S> [--json]
         curfew doctor [--json] [--disagreements] [--rank]
         exit codes 0..6 (below)
EXPECTS  LaunchdInventory::enumerate (C2) · Classification::classify (C3) ·
         Findings::evaluate (C4) · WitrClient::probe (C5) ·
         DisagreementLog::summarize (C6) · ListenerScanner::scan (C8) · CatalogLoader::load (C9) ·
         Journal::unresolved (C10)
CONSUMED BY  humans · scripts · the future TUI and menu bar
```

### External shapes (the normative part)

```text
curfew list --json
{ "v": 1,
  "sources": { "witr": "0.3.4" | null, "macos": "26.5.2", "curfew": "0.1.0" },
  "records": [ <ServiceRecord> ... ],
  "scan": { "complete": true|false, "incompleteReasons": ["enrichMissing", …] } }

curfew doctor --json
{ "v": 1, "findings": [<Finding>...], "scan": {...},
  "disagreements": [ { "fingerprint": "sha1:…", "kind": "…", "count": 3,
                       "firstSeen": "…", "lastSeen": "…" } ] }

exit codes
  0  clean            — nothing found, scan complete
  1  warnings         — findings present, or a scan was incomplete
  2  not found        — the target does not exist
  3  dependency missing — witr absent or incompatible (degraded, not failed)
  4  bad input        — ambiguous target, bad flag
  5  internal error
  6  read-only violated — never expected; the guarantee test forbids it
```

`--json` is a **contract**: field names and meanings are stable, changes are additive only, and a removal or retype is a breaking change requiring a new `v`. **A field with no value is omitted, never `null`** — so consumers treat a missing optional key as "not read", which is the same distinction D3 makes internally. `ContractShapeTests` pins every key of all three shapes and the disagreement record.

## Consistency check

```bash
python3 scripts/ledger_check.py      # known-issues cells + D ids + this file's seams
```
