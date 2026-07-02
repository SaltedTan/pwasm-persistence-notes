# The Unifying Interface

The central artifact of the thesis. Two abstract classes in
`src/engine/TxnBackend.v3` (portable, media-neutral) define the entire contract
between the persistence media and everything above it. All three backends and
all consumers (WAL, allocator) are written against only these.

See the rendered diagram [`current-backend-hierarchy`](../rendered/current-backend-hierarchy.svg)
for the class structure and [`backend-capabilities`](../rendered/backend-capabilities.svg)
for the per-backend realisation.

---

## The two abstractions

### `BackendRegion` — a mapped span of persistable bytes

```
class BackendRegion {
    range: Range<byte>                          // the mapped bytes; consumers read/write directly
    destroy()                                   // release the underlying storage
    checkpointCost() -> CheckpointCost          // FREE | CHEAP | EXPENSIVE (default EXPENSIVE)
    prepareChangedRange(offset, size) -> bool    // phase 1: note bytes already changed in `range`
    persistChanges() -> bool                     // phase 2: complete durability for all prepared ranges
    persistRange(offset, size) -> bool           // synchronous ordered durability for one range
}
```

The defining move: **the region hands out its bytes directly** (`range:
Range<byte>`). Consumers mutate the mapped memory in place; the region is not a
read/write *channel*, it is a *durability manager* over memory the consumer
already sees. This is what keeps the allocator's hot path free of per-write
virtual calls — it stores into `range` and only calls the region to make those
stores durable.

### `TxnRegionBackend` — a factory + capability reporter

```
class TxnRegionBackend {
    create(size, prot, fresh) -> BackendRegion   // fresh=true zero-inits; false attaches to existing
    isPersistent() -> bool
    name() -> string
}
```

`prot` is `BackendProt` (mirrors Linux `PROT_*`: `NONE/READ/WRITE/EXEC`).
`fresh` threads format-vs-mount intent down from `PWRegion.forceFormat` so a
fresh format zero-initialises the store while a remount attaches to it.

That is the **whole** interface: five region methods, three factory methods.

---

## Why this shape (design rationale)

- **Regions don't retain backend references.** The factory creates a region and
  reports capabilities; the region owns its own lifecycle and durability. There
  is no back-pointer from region to backend. This keeps the object graph acyclic
  and means a region is self-sufficient once created — the consumer holds only a
  `BackendRegion`. (See the note on the hierarchy diagram.)
- **Two persist paths, deliberately.** `prepareChangedRange` + `persistChanges`
  is a *two-phase, batched, write-behind* path: "these bytes already changed,
  make them durable at the next barrier." `persistRange` is a *synchronous,
  ordered, one-shot* path: "make exactly this range durable now, before I
  return." The WAL needs both — see [consumers](consumers.md) and
  [durability](durability-and-recovery.md).
- **Booleans everywhere.** Every durability method returns `bool` so failure can
  propagate without exceptions; this is what lets `commit()` return a status and
  the allocator surface it as `blankChunkHandle`/`false` rather than silently
  losing data.
- **Capability, not query-the-type.** Consumers never `match` on the concrete
  region class. The one place backend identity matters (checkpoint aggressiveness)
  is expressed as data — `checkpointCost()` returning an enum — not as a type
  test. This is the concrete answer to RQ3.

---

## What the interface unifies (and how)

| Concern | How the interface absorbs media differences |
|---|---|
| Where bytes live | `range: Range<byte>` — DRAM array, mapped file, or mapped DAX, all look the same to consumers |
| Making a write durable | two-phase `prepare`+`persist`, or synchronous `persistRange` — each backend implements them with its own primitive (no-op / `msync`+`fdatasync` / `clwb`+`sfence`) |
| Fresh vs. existing store | `create(..., fresh)` — volatile ignores it (new array is zero); file/PMEM map it to `O_TRUNC`+zero-fill vs. attach |
| Cost asymmetry | `checkpointCost()` enum, read only by the WAL policy |
| Failure | `bool` returns |

The realisations are tabulated in [backends.md](backends.md).

---

## Where the interface still leaks (open, thesis-relevant)

These are the honest counterexamples to "fully unified" — each is a live
research question, detailed in [open-problems.md](open-problems.md):

1. **Ordering semantics differ under identical calls (RQ2).** The WAL issues the
   same `persistRange`-then-`persistChanges` sequence to both file and PMEM, but
   what each *guarantees* about ordering between the log write and the data
   write is not the same, and the interface does not currently name that
   guarantee. Structural sameness ≠ semantic sameness. (Wizard `CRITIQUE.md` §3.)
2. **Alignment / width assumptions bleed through (RQ1).** The transaction cache
   above the region is aligned-access-only; a mixed-width overlapping access
   silently misses. That is a consumer constraint, but it exists because the
   interface says nothing about sub-word access. (Wizard `CRITIQUE.md` §6.)
3. **Page size is a hidden media constant.** `persistRange` on the file backend
   is page-aligned (`msync` granularity); the page size is hardcoded 4096 rather
   than surfaced or queried. A backend whose durability granularity differs would
   need the interface to say so.

---

## Naming / evolution notes

- `TxnRegionBackend` reads as a factory; the Wizard `CRITIQUE.md`/open-items
  suggest `RegionManager` as a clearer name. Worth deciding before it is
  cemented in thesis prose.
- The interface is x86-64-agnostic by design (it lives in the portable
  `TxnBackend.v3`); only the mmap realisations are under `x86-64/`. This is a
  selling point for the "unify across media" claim — nothing media-specific is
  in the contract itself.
