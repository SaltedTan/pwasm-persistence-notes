# Consumers: WAL and Allocator over the Interface

How the two layers *above* the interface — the multi-transaction WAL and the
block allocator — are written entirely against `BackendRegion`, and where (if
anywhere) backend identity re-enters. This is the "…in order to support the
persistent allocator" half of the thesis.

Write-path diagram: [`wal-write-path`](../rendered/wal-write-path.svg).

---

## The stack

```
Allocator            PWRegion / ImmixPWRegion        block alloc + free lists
Transaction cache    RegionTransaction               write-behind DRAM buffer
Write-ahead log      MultiTxnWal                      circular redo log + recovery
Backend region       BackendRegion                    ← the interface
```

Files: `src/engine/x86-64/X86_64TxnPWRegion.v3` (allocator + cache),
`X86_64MultiTxnWal.v3` (WAL).

**Key fact for the thesis:** the allocator and WAL touch the backend through
exactly the five `BackendRegion` methods plus the one `checkpointCost()` hint.
Grep the allocator/WAL for backend-type tests and you find none — only
`checkpointCost()`.

---

## RegionTransaction — the write-behind cache

Buffers writes in a DRAM `HashMap<u64, CachedUpdate>` keyed by region address;
`addrs` vector preserves write order. Reads hit the cache, else fall through to
the live mapped bytes.

`commit()` pipeline (returns `bool`):

```
if !isDirty() return true                 // clean-txn no-op
appendToWal()                             // per cached addr: wal.append(offset, value, width)
txnSeq = wal.commit()                     // one durable, checksummed record; 0 = failure
if txnSeq == 0 return false               // cache stays dirty — data retained, not lost
applyToRegion()                           // write cached values into the mapped bytes
wal.noteApplied(txnSeq)                   // advance appliedSeqVolatile in order
wal.maybeCheckpoint()                     // best-effort; failure only logged, not fatal
clear()                                   // empty map + vector in place (reuse storage)
```

The cache is the reason the WAL is **redo-only**: uncommitted state lives in
DRAM and is simply dropped on crash, so there is nothing to undo. Only committed
records reach the log.

---

## MultiTxnWal — backend-agnostic durability engine

Lives in block 1 of the region (its bytes *are* part of `range`). It uses the
backend purely for durability ordering:

- `commit()` → `appendCommittedRecord`: write one contiguous
  header+entries+trailer+checksum record into the ring, then
  **`backendRegion.persistRange(record)` — the commit point.** Returns `txnSeq`
  (0 on failure / ring-full-after-checkpoint).
- `applyUpdate` (called by the cache's `applyToRegion`): store the after-image
  into `range`, then `backendRegion.prepareChangedRange(offset, width)`.
- `checkpoint(targetSeq)`: `backendRegion.persistChanges()` (applied data
  durable) → `writeSuperblock(durableAppliedSeq)` via another `persistRange` →
  reclaim now-durable records.
- `recover()`: reads the ring + superblocks straight out of `range`; the only
  backend call is a `persistChanges()` before republishing.

So the WAL uses **`persistRange` for its own ordered writes** (records,
superblocks) and **`prepare`+`persistChanges` for the bulk region data**. That
is precisely why the interface needs both persist paths (see
[interface.md](interface.md)).

### The single backend-aware seam: `checkpointCost()`

`configureCheckpointPolicy()` reads `backendRegion.checkpointCost()` once and
picks a `(txnThreshold, fillPercent)` pair:

| cost | backend | threshold | fill % | intent |
|---|---|---|---|---|
| `FREE` | volatile | 1 | 1% | reclaim on ~every commit |
| `CHEAP` | PMEM | 8 | 25% | low cap; fences are cheap |
| `EXPENSIVE` | file | 64 | 50% | amortise `fdatasync`+`msync` |

`maybeCheckpoint()` then fires on `lag ≥ threshold` **OR**
`activeBytes ≥ fill% of ringBytes` (hybrid count-OR-occupancy; the lazy
ring-full checkpoint in `reserveRecord` remains a backstop). This is the entire
extent to which the allocator/WAL "know" which medium they run on — a single
enum, consumed in one place, affecting **cost not correctness** (a wrong policy
wastes syncs or lets the ring fill; it never corrupts). This is the concrete
evidence for RQ3. Rationale in Wizard `docs/checkpoint-policy.md`.

---

## PWRegion — the allocator

Buddy-style block allocator; all metadata mutations go through
`RegionTransaction`, so every `allocChunk`/`freeChunk` is one WAL transaction
(`performCommit()`). Region layout: block 0 header, block 1 WAL, user data,
metadata tail. The header (`PWRegionHeader`, 80 B) carries `logChunk` — the
region-relative WAL offset — so recovery locates the log from the header rather
than assuming block 1 (closes Wizard `CRITIQUE.md` §4).

Failure propagation (post commit-failure work): a WAL commit failure now
surfaces as `blankChunkHandle` from `allocChunk` / `false` from `freeChunk`,
rather than being swallowed. Propagation only — no auto-split/retry — and
buffered writes are never discarded on failure.

### Cost of the current granularity (thesis caveat)
One WAL txn per alloc/free means a multi-alloc logical WASM operation is not
atomic as a unit: a mid-sequence crash leaves some allocs committed and some
not (allocator-consistent, but maybe not program-coherent). `RegionTransaction`
could support multi-operation transactions but `performCommit()` at every
alloc/free prevents it today (Wizard `CRITIQUE.md` §1). Note this when framing
"crash-consistent" in the thesis — it is allocator-level, not
application-level, consistency.

---

## Why this supports the "unify" claim

- The allocator source is identical across media; only the injected backend
  differs (the `X86_64PW*Region` wrappers differ by one constructor argument).
- The WAL's correctness logic (commit point, checkpoint point, recovery) is
  expressed in interface calls whose *ordering* is the contract, not whose
  *implementation* is known.
- The one place media matters is quarantined to a cost hint.

The residual risk to the claim is entirely in RQ2 (are the ordering guarantees
actually equal across backends?) — tracked in
[durability-and-recovery.md](durability-and-recovery.md) and
[open-problems.md](open-problems.md).
