# Open Problems and Design Tensions

The honest list of what is unresolved, framed as research questions rather than
bug tickets. Derived from the Wizard repo's `docs/CRITIQUE.md` (tensions) and
`docs/ROADMAP.md` (status), re-read through the thesis lens. Each maps to an RQ
in [thesis-framing.md](thesis-framing.md).

---

## Blocking for a *correct* result

### O1 — PMEM durability is stubbed (blocks RQ2/RQ5 for PMEM)
`MmapRegionUtils.flushCacheLine` / `storeFence` are no-op placeholders pending
Virgil inline-asm (or a native stub) that emits `CLWB`/`CLFLUSHOPT` + `SFENCE`.
Until then the PMEM backend maps memory but does **not** actually flush — any
PMEM durability claim or measurement before this is invalid. Highest-priority
item if PMEM is in the thesis eval. (Wizard ROADMAP Next Steps §2; `CRITIQUE`
n/a — it's an impl gap.)

### O2 — Durability ordering equality across backends (RQ2, core contribution)
The WAL treats file and PMEM `persistRange`/`persistChanges` as interchangeable,
but their ordering semantics differ (eager PMEM flush vs. deferred file sync).
Need: a precise statement of the happens-before the WAL requires, and a proof or
argument that each backend's primitives satisfy it. This is the intellectual
core, not a cleanup. (Wizard `CRITIQUE.md` §3; see
[durability-and-recovery.md](durability-and-recovery.md).)

### O3 — Replay-equivalence vs. aligned-only cache (RQ2)
Mixed-width overlapping accesses silently miss the address-keyed cache and can
feed stale values into logged writes, breaking replay-equivalence. Currently a
documented caller obligation, not enforced. Decide: enforce in the cache /
interface, or state as a thesis precondition with justification. (Wizard
`CRITIQUE.md` §6.)

---

## Interface-shape questions (RQ1/RQ3)

### O4 — Is the interface minimal *and* sufficient? (RQ1)
Five region methods + three factory methods carry the whole contract. Argue
minimality (can any be removed/merged?) and sufficiency (is anything the WAL
needs smuggled in out-of-band?). Candidate smuggling: page-size assumptions in
`persistRange` (hardcoded 4096), and the aligned-access assumption (O3).

### O5 — Is `checkpointCost()` the right and only cost seam? (RQ3)
Today it is the single backend-aware input, a 3-value enum, consumed only by the
checkpoint policy. Questions: is a 3-point ordinal enough, or is a richer cost
model (relative fence vs. sync latency) needed? Does any *other* decision in the
stack secretly depend on backend identity? (If not, that is a clean RQ3 result.)

### O6 — Factory naming / role
`TxnRegionBackend` is really a `RegionManager`/factory + capability reporter.
Settle naming before thesis prose fixes it. Minor, but affects how the interface
is described.

---

## Scope-boundary questions (candidate future work)

### O7 — Transaction granularity: one WAL txn per alloc/free (RQ scope)
A multi-alloc logical operation is not atomic as a unit; a mid-sequence crash is
allocator-consistent but maybe not program-coherent. `RegionTransaction` could
batch multiple ops into one record, but `performCommit()` at each alloc/free
prevents it. Decide whether multi-operation transactions are in scope or framed
as future work. (Wizard `CRITIQUE.md` §1.)

### O8 — Concurrency: the WAL is multi-txn but clients are serial
`MultiTxnWal` supports many outstanding committed records, but
`RegionTransaction` exposes one active transaction, so allocator clients
serialise. No isolation/ordering story for concurrent WASM threads. Almost
certainly future work, but the multi-txn WAL was built partly to enable it —
worth stating the gap explicitly. (Wizard `CRITIQUE.md` §2.)

### O9 — Immix line marks bypass the WAL (not crash-consistent)
`resetAllLineMarks()` writes memory directly, so after a crash line marks may not
match object liveness. Safe only if the GC rebuilds marks from a full heap scan
on remount — not currently specified. Immix cannot be called crash-consistent
until resolved. Likely out of thesis scope; note as a limitation. (Wizard
`CRITIQUE.md` §7.)

### O10 — No WASM execution integration
The allocator has no `Memory`/`Instance` hook; no WASM instruction triggers a
transactional alloc and no trap rolls one back. The stretch contribution
(thesis-framing §5). Without it the allocator is evaluated in isolation, which is
fine for RQ1–RQ4 but limits the end-to-end story. (Wizard `CRITIQUE.md` §8.)

---

## Minor / hygiene (non-thesis, track only)

- Page size hardcoded 4096 (should query `sysconf(_SC_PAGESIZE)`) — feeds O4.
- `ImmixLineSize` hardcoded 256 B; line-mark field not linked in `createChunk()`.
- `getHeader()` allocates a fresh `Array<byte>` per call (minor GC pressure).
- `Backends.getMmap()` declared, not implemented.

---

## Status snapshot (from Wizard ROADMAP, commit 8b262f4c)

**Done:** storage abstraction + three backends; `MultiTxnWal` (superblock
selection, epoch fencing, contiguous-prefix replay, hybrid per-backend
checkpoint policy); commit-failure propagation; `RegionFileIO` open/create
split; `logChunk` in the header; in-place cache clear; extensive unit tests
(`MultiTxnWalTest`, `WALCacheTest`, `TxnPWRegionTest`).

**Open:** O1 (PMEM intrinsics) is the only item blocking a *correct* PMEM
result; O2/O3 are the correctness-argument work; O4/O5 are the interface-thesis
work; O7–O10 are scope decisions.
