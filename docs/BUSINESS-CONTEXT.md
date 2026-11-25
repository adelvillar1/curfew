# Business Context

## Founder context

<add-when-implemented>
- Solo developer, macOS, runs long unattended builds and AI agent sessions overnight.
- The originating pain: a 16 GB Mac that swaps 5.4 GB while agents run, with ~30 vendor updater agents competing for CPU and attention.
</add-when-implemented>

## Target user

<add-when-implemented>
- Primary: developers running unattended agent/build workloads on memory-constrained Apple Silicon.
- Secondary: anyone who wants a reversible "quiet machine" for battery or focus reasons.
- Explicit non-user: managed corporate fleets (MDM policy conflicts, support burden).
</add-when-implemented>

## Revenue model

<add-when-implemented>
- Working assumption: one-time licence, direct download + Homebrew cask. The category (LaunchControl, App Tamer) supports $10–35.
- Not on the Mac App Store: sandbox restrictions and daemon review make it impossible.
</add-when-implemented>

## Alternatives and positioning

| Alternative | What it does | What it does not |
|---|---|---|
| `launchctl` by hand | exact control | no recipes, no restore guarantee, no undo |
| LaunchControl | full launchd vocabulary, GUI | no opinions about *safe* stop, no bundles, no journal |
| App Tamer | throttles/suspends apps | no notion of services or daemons |
| CleanMyMac / "optimizers" | kills processes | no restore, no safety model |

<add-when-implemented>
- The differentiator: per-service verified recipes + journal-backed restore. The product is trust, not the toggle.
</add-when-implemented>

## Risks

<add-when-implemented>
- A single data-corruption incident ends trust in the product permanently.
- Apple moves per-user agent labels every OS release; a hardcoded Apple list rots.
- Adjacent to two mature paid apps; the whitespace is real but narrow.
</add-when-implemented>
