# Pipeline

Not a data pipeline — the only "pipeline" this project has is **catalog generation and validation**, which runs at build time and on demand.

## Intended flow

```
catalog/*.yaml  ──▶ decode + schema validate ──▶ codegen (typed catalog) ──▶ tests
       ▲
       └── generated-from: a machine inventory snapshot (scripts/inventory.sh --json)
```

## Rules

1. **Generation never writes a recipe.** It can propose a *draft* entry (discovery rules, label, plist keys, inferred lever). Stop/start recipes and `evidence:` are authored by a human and verified on a machine.
2. **A draft cannot be applied.** The executor refuses anything without `evidence:`.
3. **The never-list is not generated.** It is code.
4. **Deterministic output.** Same inventory in → same catalog out, so a diff is always a real change.

## Status

Not implemented. The first step is the inventory script (`docs/scripts/README.md`), not the generator — a generator over an inventory we cannot yet trust would launder guesses into code.
