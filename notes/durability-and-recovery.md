# Durability Contract and Recovery

The correctness core of the thesis (RQ2, RQ4). This is where "the same code runs
on every backend" is either true or merely plausible. Recovery diagram:
[`recovery-states`](../rendered/recovery-states.svg).

---

## The durability contract (RQ2)

The interface exposes two persist paths; the WAL's correctness depends on what
each *guarantees*, not on how each is coded.

### Path A — synchronous ordered write: `persistRange(offset, size)`
Contract the WAL assumes: **when `persistRange` returns true, exactly those
bytes are durable, and this durability is ordered with respect to later
`persistRange` calls.** The WAL uses it as its *commit point* (the transaction
record) and its *publish point* (the superblock). The ordering property is
load-bearing: the record must be durable *before* the superblock that references
it.

- File: page-aligned `msync` — durable on return; `msync` ordering gives the
  before/after relation.
- PMEM: `flushRange` + `storeFence` — durable + fenced on return.
- Volatile: no-op (trivially "durable" in the only memory that exists).

### Path B — two-phase batched write-behind: `prepareChangedRange` + `persistChanges`
Contract: **after `prepare` on a set of ranges and a subsequent
`persistChanges` returning true, all those ranges are durable.** No ordering
*among* prepared ranges is promised — they become durable as a set at the
`persistChanges` barrier. The WAL uses it for bulk region data (the after-images
applied by the cache), then a `persistChanges` at checkpoint time.

- File: `prepare` sets a dirty flag; `persistChanges` = `fdatasync` (batched).
- PMEM: `prepare` = flush *now* (eager); `persistChanges` = fence.
- Volatile: both no-ops.

### The unresolved question (RQ2)
The WAL issues Path A for its own writes and Path B for data, and relies on:

> (record durable via `persistRange`) **happens-before** (data applied) **and**
> the data is made durable (via `persistChanges`) **before** the superblock
> publishes `durableAppliedSeq`.

For the file backend this rests on `msync`/`fdatasync` ordering; for PMEM on
flush/fence ordering. These are *analogous* but not obviously *identical* — e.g.
PMEM's `prepare` already flushed eagerly, so its `persistChanges` fence orders
differently than file's deferred `fdatasync`. The current code treats them as
interchangeable (Wizard `CRITIQUE.md` §3). **Pinning this down — proving the two
orderings both satisfy the WAL's happens-before requirement — is the main
correctness contribution.**

### The replay-equivalence invariant (RQ2/RQ4)
> Replaying the durable committed WAL tail reconstructs exactly the region state
> that existed pre-crash (modulo uncommitted DRAM-cache writes, which are
> intentionally lost).

This holds **only if** callers never do mixed-width overlapping accesses through
the aligned-only cache: a width-8 write then a width-1 read at the same base
misses the cache and returns stale bytes, and a stale-derived value would then
be logged and replayed (Wizard `CRITIQUE.md` §6). The invariant is currently a
*documented caller obligation, not an enforced one* — a candidate to either
enforce in the interface/cache or state as a precondition in the thesis.

---

## On-region WAL layout (recovery substrate)

Block 1: two fixed `WalSuperblock` copies (64 B each) then the record ring.

- **`WalSuperblock`** (dual copy): `magic`, `version`, `generation` (monotonic;
  recovery picks the higher *valid* copy), `logEpoch` (WAL incarnation),
  `durableAppliedSeq` (replay floor), `checksum`.
- **`TxnRecord`** = `TxnRecordHeader` (64 B) + `LogEntry[]` +
  `TxnCommitTrailer` (48 B), 64 B-aligned. Header + trailer carry redundant
  `recordLen`/`entryCount`/`logEpoch`/`txnSeq`; the trailer holds an FNV-style
  checksum over the whole record.
- `LogEntry`: `offset` (region-relative), `value`, `width` (1/2/4/8).

---

## Recovery state machine (RQ4)

`MultiTxnWal.recover()` — see the diagram for the full state graph.

1. **Load superblock** — `loadSuperblock` selects the valid copy with the higher
   `generation` → `durableAppliedSeq`, `logEpoch`.
2. **Scan ring** — `scanCommittedRecords` strides at 64 B; `validateRecord`
   keeps a record only if magic/version/size good, `logEpoch` matches, entry
   widths valid, and checksum good.
3. **Select contiguous prefix** — `selectContiguousPrefix` takes the run whose
   `txnSeq` is contiguous from `durableAppliedSeq + 1`. A gap ends the run.
4. **Redo** — replay each selected record's after-images into `range`;
   `appliedSeqVolatile` advances per record.
5. **Persist replayed data** — `backendRegion.persistChanges()`.
6. **Publish** — `writeSuperblock(recoveredMaxSeq, logEpoch + 1)`; bump
   `logEpoch`; set `durableAppliedSeq = recoveredMaxSeq`.

Branches:
- **Gap-abandon:** valid records exist but none are contiguous from the floor →
  they are intentionally abandoned by bumping the epoch + generation and
  rewriting the superblock; `recover()` returns false. (A committed prefix with
  a hole is treated as if the tail never happened.)
- **Nothing to replay:** no candidates → reset volatile state; return false.
- **Failed:** any `persistChanges`/superblock write fails → abort, return false.

### The two correctness mechanisms
- **`durableAppliedSeq` = a redo floor.** Everything at or below it is already
  durable in the region; recovery only replays strictly above it. (≈ an ARIES
  redo-LSN floor; worth positioning against ARIES in related work.)
- **`logEpoch` = anti-double-replay fence.** Once recovery republishes at
  `logEpoch + 1`, every record written under the old epoch fails
  `validateRecord` on any future mount. This is what makes replay **idempotent
  across repeated crashes** — replay-then-crash-during-publish-then-replay-again
  cannot double-apply, because either the new superblock is durable (old records
  now fail the epoch check) or it is not (old floor still in effect, same replay
  reproduced).

### Contiguity requirement, stated
Recovery applies a **contiguous** `txnSeq` prefix only. Correctness rests on the
commit protocol never marking record *N+1* committed unless *N* is (records get
`txnSeq` in order; each is made durable by its own `persistRange` before the
next is written). A hole therefore can only be a torn tail, which is correctly
abandoned.

---

## Crash-window analysis (thesis material)

Enumerate where a crash can land and what recovery does — this table is the kind
of thing a thesis correctness section needs:

| Crash point | On-media state | Recovery outcome |
|---|---|---|
| Before record `persistRange` returns | record absent or torn | fails checksum → not in prefix → not applied (txn lost, cache was DRAM-only anyway) |
| After record durable, before data applied | record durable, region stale | replayed from record → correct |
| After data applied, before checkpoint | record durable, region has data, `durableAppliedSeq` stale | replayed again (idempotent write of same after-image) → correct |
| After `persistChanges`, before superblock publish | data durable, floor stale | replayed again (idempotent) → correct |
| After superblock publish | floor advanced, records reclaimable | nothing to replay for that txn → correct |
| During recovery, before new superblock | old floor + old epoch records | next mount reproduces the same replay (epoch not yet bumped) → correct |
| During recovery, after new superblock | new floor + bumped epoch | old records fail epoch check → not re-applied → correct |

Every window resolves to the pre-crash-committed state — **provided** the Path
A/Path B ordering guarantees (RQ2) actually hold on each backend. That proviso is
the one thing the crash-window table assumes and the durability contract must
discharge.
