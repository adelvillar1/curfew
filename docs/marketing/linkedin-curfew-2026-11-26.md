# Your Mac has been partying hard, fast and loose

*LinkedIn article — draft 2026-11-26. Numbers are measured on one Mac (macOS 26.5.2, 16 GB, 33 days uptime) and
recorded in the repo; nothing here is estimated.*

---

I checked my own machine on a Tuesday and found it had been living like an unruly teenager.

Uptime: 33 days. Swap in use: **5,438 MB of 7,168**. Compressed memory: **4.16 GB**. Swap-ins and swap-outs
since boot: **217 million and 233 million pages**. And 282 background services loaded in my user session alone
— **35 of them third-party**, of which roughly **30 were updaters, sync agents and app launchers** I never
installed on purpose and had never once used.

None of that was my work. My work needs a compiler, git, node, and about four Apple daemons. Everything else
was a house party I hadn't been invited to.

## The part that should worry you: it was invisible

I write and run tooling for a living, so I started where anyone would — `ps`, `top`, Activity Monitor. All of
them said my machine was busy but fine. All of them were wrong in the same way.

**Crash loops have no PID.** Three launchd jobs on this machine had been failing and being restarted, over and
over, for weeks:

- `com.zcode.model-router` — **255,645 runs**
- `com.agnostic-router.model-router` — **255,646 runs**
- `sh.brew.postgresql@14` — **82,103 runs**

A quarter of a million executions of the same failing command. No process to find, because a crash loop is a
*rate*, not a resident process. Every process viewer I owned showed nothing, because there was nothing to show.

**Orphans don't show up either.** Keep-alive processes — the `tail -f /dev/null` that keeps a session or a
pipeline alive — outlive their parent when the parent dies. When I finally counted:

> **1,232 orphaned keep-alives**, parent = 1, holding **580 MB of RAM**, at **46% of the per-user process
> limit**, accumulated over roughly **55 days**.

Nothing was waiting on any of them. They were pure cost, running until the next reboot, and no tool was going to
tell me.

**And then there was the dead weight.** I retired a large Rust agent project, wound the service down, and moved
on. The repository stayed: 543 MB of source I still needed, sitting inside a directory that had quietly grown a
**15 GB `target/` build cache** and **5.2 GB of session checkpoints**. Build output is regenerable; nobody
prunes what they don't look at. Deleting both, carefully, took the host from **60 GB free to 79 GB**.

That's the shape of the problem. Not one dramatic failure — a slow accumulation of things that were individually
reasonable and collectively absurd.

## What I built about it

I wrote a small macOS tool called **Curfew**. It has one job: put the machine into a quiet,
unattended-development state — stop exactly the things a build does not need — and then put every one of them
back, the way it found them, when you ask.

The interesting part is not the stopping. It's the discipline around it, because "just kill things" is how you
lose a database:

- **Every stop is a plan first.** Dry run, then a confirmation, then the work. No exceptions, including mine.
- **The journal is written *before* the act, never after.** If the machine dies between intent and outcome, the
  next start restores it. A crash cannot leave you guessing what changed.
- **No service is stoppable without a verified recipe** — a real stop, a real start, a probe, and a dated
  evidence line from a real machine. Everything else stays `draft` and cannot be applied.
- **Freezing is only for GUI apps.** Of 887 system job definitions, **733 register a MachServices port** — freeze
  a server and you don't fail its clients, you *hang* them. The tool refuses.
- **A never-list lives in code**, guarded by a test, not in configuration, not overridable by a flag.
- **Debris is moved, never deleted.** Removed-app leftovers go to quarantine where the owner is verifiably gone.
- **It reads before it decides.** Process ancestry, sockets, ownership — that's what makes stop-vs-freeze
  evidence rather than a guess.

The same discipline covers the housekeeping. A hygiene pass prunes build artifacts only from a **closed list**,
only when the repo is stale **and** the artifact is cold — both guards — and *names* anything it doesn't
recognise instead of removing it. A second pass reaps orphaned keep-alives only when the command matches
exactly, the parent is gone, and the process is yours.

## What I'd tell anyone building internal tools

1. **The expensive things are invisible to the tools built for the visible ones.** Crash loops, orphaned
   keep-alives, cold build caches — none of them appear where you're looking. You have to go looking on purpose.
2. **Regenerable is not free.** A 15 GB `target/` costs you nothing to produce and everything to keep.
3. **Every irreversible action needs a plan, a record, and a dry run** — not because you're careless, but
   because the day you're tired is the day it matters.
4. **Measure, then decide.** "The machine feels slow" is not a finding. "5,438 MB of swap and 1,232 orphans" is.

The party wasn't malicious. It was thirty startup agents doing their jobs, three jobs failing politely forever,
and one build cache nobody was ever going to look at again.

Curfew is the parent that shows up at 11pm and turns the lights on.

**Code, diagrams and a signed-by-nobody installer:** https://github.com/adelvillar1/curfew

---

## Post copy (feed)

> Checked my own Mac on a Tuesday. 33 days uptime, **5.4 GB of swap**, 282 background services — 30 of them
> updaters I never installed.
>
> Then the parts that should worry you, because no tool shows them:
>
> — three launchd jobs crash-looping at **255,645 / 255,646 / 82,103 runs**. No PID to find.
> — **1,232 orphaned keep-alives**, 580 MB of RAM, 46% of the per-user process limit, ~55 days old. Nothing
> waiting on them.
> — and in a repo I'd retired: a **15 GB `target/`** and 5.2 GB of checkpoints. Deleting both took the machine
> from 60 → 79 GB free.
>
> So I built Curfew: a macOS tool that stops what a build doesn't need and puts it all back — journal written
> *before* the act, verified recipes only, never-list in code, dry run before anything live.
>
> The party wasn't malicious. It was thirty agents doing their jobs and one build cache nobody ever looked at
> again.
>
> Article below — the numbers, and what fixing it taught me 👇
>
> https://github.com/adelvillar1/curfew

## Tags

**Primary (use all five):**
`#macOS` `#DeveloperTools` `#PlatformEngineering` `#Swift` `#OpenSource`

**Extended (pick 3–5 if you want more reach):**
`#DevOps` `#launchd` `#ResourceManagement` `#Rust` `#TechnicalDebt` `#BuildInPublic`

**People/org tags, only if true:** tag the Archify and witr maintainers when crediting them — they're credited in
the README, and tagging a maintainer you actually thanked reads well; tagging for reach does not.
