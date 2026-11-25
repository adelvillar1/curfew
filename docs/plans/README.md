# Plans

This directory holds **plan-as-contract** files. Each plan describes what is about to be built, how we will know it is done, and which contract docs will need updating.

## Filename format

```
YYYY-MM-DD-<short-slug>.md
```

Examples:
- `2026-11-25-service-catalog-schema.md`
- `2026-12-02-journal-restore-guarantee.md`
- `2026-12-09-menu-bar-indicator.md`

The ISO date prefix is non-negotiable — it makes the directory self-sorting and doubles as the plan's identifier in recaps. The slug describes the *thing being built*, not the action.

## Plan structure

- **Frontmatter**: `status`, `created`, `updated`, `slug`
- **Context**: why this work is happening, what problem it solves
- **Approach**: one recommended path, not a menu
- **Acceptance criteria**: a checkbox list of single-sentence verifiable assertions — this is the contract
- **Files to be touched**: explicit paths
- **Out of scope**: what people might assume but we are not doing
- **Verification**: how to confirm each criterion (commands, manual steps, what to observe)
- **Linked artifacts**: which `docs/features/<name>.md`, `TECHNICAL-DOCUMENTATION.md` section, and `FUNCTIONAL-SPECIFICATIONS.md` section need updating

## Plan status lifecycle

```
draft → active → completed
                ↘ abandoned
```

| Status | Meaning |
|--------|---------|
| `draft` | Being written, not started |
| `active` | Implementation in progress |
| `completed` | All criteria met, contract docs updated |
| `abandoned` | Decided not to do this, with the reason in the plan |

```bash
grep -l 'status: active' docs/plans/*.md
```

## How plans connect to recaps

Each recap references the plan(s) it touched by filename. When a session completes the last criterion, the recap flips the plan to `completed`.

- plan → recaps: `grep -l '2026-11-25-service-catalog-schema' docs/recaps/*.md`
- recap → plan: the "Plan link" line at the top

## When NOT to draft a plan

- Typo fixes, one-line fixes with no behaviour change, dependency bumps, pure refactors, hot fixes (write a retroactive plan after).

## Two rules specific to this project

1. **A plan touching the never-list, the journal format, or a data-service recipe is never skipped.** Those are the surfaces where a mistake corrupts a database or strands a machine.
2. **Acceptance criteria must be observable from outside the process** — a command output, a service state, a file. "The code handles it" is not a criterion.
