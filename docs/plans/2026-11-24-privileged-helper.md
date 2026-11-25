---
status: active
created: 2026-11-24
updated: 2026-11-24
slug: privileged-helper
---

# Plan — the privileged helper (L4.1, L4.2)

## Context

Half the catalog cannot run. Every root-requiring recipe — `mdutil -a -i off` for Spotlight,
`tmutil stopbackup`, system daemons in `/Library/LaunchDaemons` — is refused by the executor with
"needs the privileged helper (L4)". This plan builds that helper.

**The design rule came first (D20): the helper is a catalog executor, not a command executor.** It
accepts `{entryId, action, intentSeq}` and never argv. A helper that runs client-supplied argv is a
root shell with extra steps, and every client-identity bug then becomes a privilege-escalation bug.
With D20, a compromised client can only ask for operations that were already reviewed, dated, and
recorded in the catalog.

**What can be proven from here, and what cannot.** The policy — every rule the boundary applies — is
pure and now has 9 tests. The plumbing (XPC listener, `SMAppService` registration, code-signature
validation of the peer) needs a **signed app bundle with a Team ID**; it cannot be registered or
exercised in this environment. This plan therefore splits cleanly:

| Piece | Status |
|---|---|
| `HelperPolicy` — the authorization decisions | **done, tested** (`HelperPolicyTests`, 9) |
| Wire types (`HelperRequest` / `HelperResponse`) | **done, tested** (no argv on the wire) |
| `curfew-helper` executable + XPC listener | to build |
| `SecCodeCheckValidity` caller validation | to build |
| `SMAppService.daemon` registration | blocked on a signing identity |
| The unprivileged executor delegating root recipes to it | to build |

## Approach

### The helper executable

A second executable target, `curfew-helper`, launched by launchd as root from
`Curfew.app/Contents/Library/LaunchDaemons/dev.curfew.helper.plist`. It owns an `NSXPCListener` on the
mach service name, and does exactly four things per request:

1. Read the peer's audit token and validate its code signature (`SecCodeCheckValidity` against a
   requirement built from the expected Team ID). This is the helper's own check — `SMAuthorizedClients`
   in the plist is **not** consulted under `SMAppService`.
2. Load the catalog from the app bundle's resources (not from a client-supplied path).
3. Ask `HelperPolicy.decide`.
4. On `allow`: run the argv, evaluate the verification, append to **its own** journal, return the
   response. On `refuse`: return the refusal with the intent echoed.

The helper owns a journal separate from the user's (`/Library/Application Support/Curfew/journal.jsonl`)
because it is the only process that knows what *it* did as root; the user's journal records the intent
that caused it.

### The executor's side

`Executor` gains a `PrivilegedTransport` — a closure `(HelperRequest) -> HelperResponse` — so the
delegation path is testable without XPC:

```swift
if recipe.needsRoot, let transport = privilegedTransport {
    // journal the intent first (rule 2), then ask the helper
    let response = transport(HelperRequest(entryId: entry.id, action: .stop, intentSeq: seq))
    // a refusal is an outcome, not an exception
}
```

The real transport wraps `NSXPCConnection(machServiceName:)`. A test transport returns canned responses,
so the delegation, the journal ordering, and the refusal handling are all proven without root.

### Registration

`SMAppService.daemon(plistName: "dev.curfew.helper.plist").register()` from the app, which prompts for
admin approval once. Re-registration after an app upgrade may re-prompt. A `curfew doctor` check
reports whether the helper is registered, running, and whether its signature matches the app's.

## Acceptance criteria

- [x] `HelperPolicy` refuses: an unsigned caller, a foreign Team ID, a draft entry, a never-list label,
      a non-root recipe, an unknown entry, a missing recipe.
- [x] `HelperPolicy` allows a verified root-requiring entry and returns the catalog's argv, not the
      client's.
- [x] The wire shape carries no `argv` and no `run` — asserted against the encoded JSON.
- [x] A refusal echoes `intentSeq`, so a result can never be attributed to the wrong journal entry.
- [ ] `curfew-helper` registers via `SMAppService.daemon` and answers a request from the signed app.
- [ ] The helper refuses a request from a copied, re-signed binary (different Team ID).
- [x] `Executor` delegates a `needsRoot` entry through an injected transport, journaling the intent
      before the request and the outcome after (`ExecutorDelegationTests`, 5).
- [ ] With no helper registered, a `needsRoot` entry is refused with a message naming the helper — the
      current behaviour, kept as a test.

## Files to be touched

```
Sources/curfew-helper/main.swift          XPC listener, peer validation, catalog load, dispatch
Sources/curfew-helper/Info.plist          (embedded in the app bundle at build time)
Sources/CurfewKit/HelperProtocol.swift    done: policy, wire types
Sources/CurfewKit/PrivilegedTransport.swift  the closure seam + the NSXPCConnection implementation
Sources/CurfewKit/Executor.swift          delegate needsRoot recipes
Sources/curfew/main.swift                 doctor: helper status
Tests/CurfewKitTests/ExecutorDelegationTests.swift
docs/plans/CURFEW-CONTRACTS.md            C12
```

## Out of scope

- Freezing (`SIGSTOP`) as root — rule 4 keeps it out of the catalog for now.
- Container levers (`kiri stop`) — KI-004 is still open.
- The menu bar and TUI (L5).

## Open questions for the owner

1. **Does the helper get its own journal, or write into the user's?** My recommendation: its own, under
   `/Library/Application Support/Curfew/`, because root's actions and the user's intent are different
   records and merging them invites a permissions bug.
2. **Should `curfew apply` refuse to run *any* bundle containing a root recipe when no helper is
   registered**, or skip those entries and plan the rest? Recommendation: refuse the bundle — a partial
   quiet mode is harder to reason about than a refused one.

## Verification

```bash
swift test                                   # policy + delegation
curfew doctor                                # helper status line, "not registered" today
# with a signed build:
sudo launchctl print system/dev.curfew.helper
```

## Linked artifacts

- `docs/plans/CURFEW-DESIGN-DECISIONS.md` D17 (signing), D20 (catalog executor)
- `docs/architecture/overview.md` (the helper owns journal state)
- `docs/known-issues.md` KI-002 (`launchctl bootstrap` EIO in a sandboxed session — the reason the root
  half cannot be exercised here)
