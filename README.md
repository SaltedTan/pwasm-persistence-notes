# PWasm Persistence Notes

Private research notes and diagrams for Persistent Wasm persistence primitives,
transaction-region backends, and WAL-oriented durability semantics. Maintained
alongside — but separate from — the Wizard engine `pwregions` branch; source
references are pinned to Wizard commit
`8b262f4c24497bd2c5abe37c4b84c40dd4a97bf8` (2026-07-02).

**Purpose:** working material for the honours thesis on *a unifying interface
for multiple persistence backends supporting a persistent region allocator*.

## Thesis notes (`notes/`)

Start with the framing, then the interface; the rest hang off those.

- [`thesis-framing.md`](notes/thesis-framing.md) — thesis statement, research
  questions (RQ1–RQ5), contributions, scope, evaluation plan, related-work leads
- [`interface.md`](notes/interface.md) — **the unifying interface**
  (`BackendRegion` / `TxnRegionBackend`): contract, design rationale, what it
  unifies, where it still leaks
- [`backends.md`](notes/backends.md) — how volatile / file / PMEM each realise
  the interface; capability matrix; media models
- [`consumers.md`](notes/consumers.md) — how the WAL and allocator consume the
  interface backend-agnostically; the single `checkpointCost()` seam
- [`durability-and-recovery.md`](notes/durability-and-recovery.md) — the
  durability contract (two persist paths), the recovery state machine, the
  replay-equivalence invariant, and a crash-window analysis
- [`open-problems.md`](notes/open-problems.md) — unresolved tensions framed as
  research questions, mapped to the RQs; status snapshot

## Main questions (README-level, expanded in `notes/`)

- What should the persistence backend interface expose? → [`interface.md`](notes/interface.md) (RQ1)
- Which durability operations belong in the region abstraction? → [`durability-and-recovery.md`](notes/durability-and-recovery.md) (RQ2)
- How should WAL ordering be represented in the API? → [`durability-and-recovery.md`](notes/durability-and-recovery.md) (RQ2)
- Where does the current class hierarchy force downcasting or backend-specific leakage? → [`consumers.md`](notes/consumers.md), [`open-problems.md`](notes/open-problems.md) (RQ3)
- What crash/recovery states must the abstraction make explicit? → [`durability-and-recovery.md`](notes/durability-and-recovery.md) (RQ4)

## Diagram index (`diagrams/` → rendered to `rendered/`)

- [`current-backend-hierarchy`](diagrams/current-backend-hierarchy.puml) — class
  structure of the interface + backends ([SVG](rendered/current-backend-hierarchy.svg))
- [`backend-capabilities`](diagrams/backend-capabilities.puml) — per-backend
  capability matrix ([SVG](rendered/backend-capabilities.svg))
- [`wal-write-path`](diagrams/wal-write-path.puml) — `MultiTxnWal` commit
  pipeline ([SVG](rendered/wal-write-path.svg))
- [`recovery-states`](diagrams/recovery-states.puml) — `MultiTxnWal.recover()`
  state machine ([SVG](rendered/recovery-states.svg))

## Rendering

Diagrams are PlantUML. Rendered SVGs live in `rendered/`.

```bash
scripts/render-diagrams.sh          # needs `plantuml` on PATH
# or, with Docker and no local plantuml:
docker run --rm -v "$PWD":/work -w /work plantuml/plantuml -tsvg -o /work/rendered "diagrams/*.puml"
```
