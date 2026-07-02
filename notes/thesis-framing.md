# Thesis Framing

Working notes toward the honours thesis. Everything here is grounded in the
`pwregions` branch of the Wizard engine, pinned at commit
`8b262f4c24497bd2c5abe37c4b84c40dd4a97bf8` (2026-07-02) unless stated otherwise.
These notes are a private synthesis; the authoritative design docs live in the
Wizard repo under `docs/` (`persistent-backends.md`, `wal-comparison.md`,
`checkpoint-policy.md`, `CRITIQUE.md`, `ROADMAP.md`).

---

## Working thesis statement

> A single, narrow region-persistence interface can unify byte-addressable
> (PMEM/DAX) and block-oriented (file / block-device) storage media behind one
> abstraction, such that a write-ahead-logged, crash-consistent region allocator
> for WebAssembly is written **once** against the interface and runs unmodified
> across all backends — with backend-specific cost, not backend-specific
> correctness code, as the only thing that varies.

The claim has two halves worth defending separately:

1. **Unification is possible** — the same allocator + WAL code path drives
   volatile DRAM, an `msync`/`fdatasync` file backend, and a `clwb`/`sfence`
   PMEM backend without conditionals on the backend type.
2. **Unification is worthwhile** — the interface stays narrow (five region
   methods + a three-method factory), yet expressive enough to carry the
   durability-ordering guarantees the WAL relies on, and the residual
   backend asymmetry is confined to a single cost signal (`checkpointCost()`).

The interesting research tension is that half (1) is only *true* if the
durability contract (see `durability-and-recovery.md`) is specified precisely
enough — the current code makes the two backends *structurally* identical while
their ordering semantics differ (Wizard `CRITIQUE.md` §3). Pinning that contract
down is a core contribution, not a footnote.

---

## Research questions

Refined from the repo README's "Main questions":

- **RQ1 (interface).** What is the minimal set of operations a persistence
  backend must expose to support a WAL-based region allocator, and can it be
  expressed without leaking media-specific concepts (page size, cache lines,
  fences, syncs) into the allocator?
- **RQ2 (durability contract).** What ordering guarantees must
  `prepareChangedRange` / `persistChanges` / `persistRange` provide so that
  "replay the durable WAL tail" reconstructs exactly the pre-crash region state,
  and are those guarantees the *same* across PMEM and file backends or merely
  analogous? (See Wizard `CRITIQUE.md` §3, §6.)
- **RQ3 (cost, not correctness).** Where does backend identity legitimately
  re-enter the design? The current answer is one enum, `CheckpointCost`,
  consumed only by the WAL's checkpoint policy. Is that the right and only
  seam?
- **RQ4 (recovery).** What crash/recovery states must the abstraction make
  explicit, and does the interface expose enough (or too much) to make recovery
  provably idempotent? (Epoch fencing + `durableAppliedSeq` are the current
  mechanism.)
- **RQ5 (evaluation).** How much does the unifying abstraction cost in
  throughput/latency versus a backend-specialised path, and how does commit /
  checkpoint cost scale across the three media?

---

## Candidate contributions

1. A **narrow region-persistence interface** (`BackendRegion` /
   `TxnRegionBackend`) and an argument that it is sufficient for WAL-based
   crash consistency across three dissimilar media.
2. A **precise durability contract** for the two persist paths (two-phase
   write-behind vs. synchronous ordered write) that makes the WAL's commit-point
   and checkpoint-point reasoning backend-independent.
3. A **backend-agnostic multi-transaction WAL** (`MultiTxnWal`) whose only
   backend coupling is a cost hint, demonstrating RQ3.
4. An **evaluation** of the abstraction tax and of commit/checkpoint cost across
   volatile / file / PMEM.
5. (Stretch) Integration into the WASM execution model so the allocator is
   driven by real WASM programs (Wizard `CRITIQUE.md` §8).

---

## Scope and non-goals

- **In scope:** the interface, the three backends, the WAL, the block
  allocator, crash recovery, and the abstraction-tax evaluation.
- **Deferred / non-goals for the thesis (candidate future work):**
  concurrent/multi-client transactions (Wizard `CRITIQUE.md` §2), multi-operation
  atomic transactions (§1), Immix line-mark durability (§7), and full WASM
  execution integration (§8) unless the stretch contribution lands.
- **Known correctness caveat:** PMEM durability is not yet *real* —
  `flushCacheLine`/`storeFence` are no-op stubs pending Virgil inline-asm
  (`X86_64TxnBackend.v3`). Any PMEM measurement before that lands measures the
  abstraction, not durable PMEM. This must be stated plainly in the eval.

---

## Evaluation plan (sketch)

| Axis | What to measure | Backends |
|---|---|---|
| Abstraction tax | allocator op latency through the interface vs. a hand-specialised path | volatile |
| Commit cost | per-`commit()` latency = record write + `persistRange` | file, PMEM |
| Checkpoint cost | `checkpoint()` latency = `persistChanges` + superblock write | file, PMEM |
| Policy sensitivity | throughput vs. `checkpointTxnThreshold` / `checkpointFillPercent` | file, PMEM |
| Recovery time | mount replay time vs. number/size of committed-but-uncheckpointed records | all |
| Ring pressure | commit stalls from lazy ring-full checkpoints vs. proactive policy | file |

Micro-drivers already exist as unit tests (`MultiTxnWalTest.v3`,
`WALCacheTest.v3`, `TxnPWRegionTest.v3`); the eval needs a throughput harness on
top.

---

## Related work to position against

Leads to read and verify — **not** yet summarised from the sources, treat each
as "investigate, then cite precisely":

- **Persistent-memory allocators / heaps:** NV-Heaps, Mnemosyne, Atlas, Makalu,
  PMDK / `libpmemobj`. Relevant to RQ1/RQ3 — how each draws the
  library-vs-media line, and whether any target *both* PMEM and block media.
- **Failure-atomic file durability:** failure-atomic `msync` (FAMS), and the
  general `msync`/`fdatasync` ordering literature. Relevant to RQ2 for the file
  backend.
- **WAL / recovery theory:** ARIES (redo/undo, LSNs, checkpoints). Our
  `durableAppliedSeq` ≈ a redo LSN floor; we are redo-only (no undo, because the
  DRAM cache holds uncommitted state). Position the epoch-fencing trick against
  ARIES log-sequence/anti-double-replay handling.
- **PMEM durability primitives:** the `CLWB`/`CLFLUSHOPT`/`SFENCE` +
  `MAP_SYNC`/DAX model. Relevant to the stub work and to RQ2's PMEM half.

See `open-problems.md` for the design tensions that map onto RQ2–RQ4, and
`interface.md` for the interface itself.
