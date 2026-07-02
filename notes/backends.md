# Backend Realisations

How three dissimilar media each satisfy the one interface from
[interface.md](interface.md). Diagram: [`backend-capabilities`](../rendered/backend-capabilities.svg).

Portable region/factory in `src/engine/TxnBackend.v3`; mmap realisations in
`src/engine/x86-64/X86_64TxnBackend.v3`.

---

## Class hierarchy

```
BackendRegion                     (portable, TxnBackend.v3)
  ├── VolatileRegion              (portable — Array<byte>, GC-managed)
  └── FdMmapRegion                (x86-64 — owns Mapping + fd, bounds check, unmap/close)
        ├── FileMmapRegion        (block device / file — msync + fdatasync)
        └── PmemMmapRegion        (PMEM/DAX — clwb + sfence, MAP_SYNC)

TxnRegionBackend                  (factory)
  ├── VolatileBackend             (Backends.getVolatile() singleton)
  ├── FileMmapBackend
  └── PmemMmapBackend
```

`FileMmapRegion` and `PmemMmapRegion` share `FdMmapRegion` for everything except
the durability primitives — which is exactly the part that legitimately differs
per medium.

---

## Capability matrix

| | `VolatileRegion` | `PmemMmapRegion` | `FileMmapRegion` |
|---|---|---|---|
| `name()` | `"volatile"` | `"pmem"` | `"file"` |
| `isPersistent()` | false | true | true |
| `checkpointCost()` | `FREE` | `CHEAP` | `EXPENSIVE` |
| backing store | `Array<byte>` (GC) | `mmap(MAP_SHARED_VALIDATE\|MAP_SYNC)` on DAX | `mmap(MAP_SHARED)` on a file |
| `fresh=true` | new array (zero by construction) | `O_TRUNC` + `ftruncate` zero-fill | `O_TRUNC` + `ftruncate` zero-fill |
| `prepareChangedRange` | no-op → true | `flushRange` (CLWB*), set `hasPendingWriteback` | set `hasDirtyChanges` |
| `persistChanges` | no-op → true | `storeFence` (SFENCE*) if pending | `fdatasync(fd)` if dirty |
| `persistRange` | no-op → true | `flushRange` + `storeFence` | page-aligned `msync` |

\* PMEM `flushRange`/`storeFence` (CLWB/SFENCE) are **no-op stubs** today
(`MmapRegionUtils`), pending Virgil inline-asm. PMEM is not truly durable yet —
see [open-problems.md](open-problems.md) and thesis eval caveats.

---

## The three media models

### Volatile (`VolatileRegion` / `VolatileBackend`)
- Pure DRAM `Array<byte>`, garbage-collected; `destroy()` is a no-op.
- Every durability method is a no-op returning `true`. It is a *correct*
  implementation of the interface with zero durability — which is what makes it
  the ideal control for measuring abstraction tax (no media cost to confound
  the measurement).
- `checkpointCost() = FREE` → the WAL checkpoints on essentially every commit
  (reclaim is free), so ring pressure never builds.

### File / block device (`FileMmapRegion` / `FileMmapBackend`)
- `mmap(MAP_SHARED)` over a regular file; durability via the page cache +
  `msync`/`fdatasync`.
- **Deferred, batched** dirty tracking: `prepareChangedRange` just sets
  `hasDirtyChanges`; the actual sync is deferred to `persistChanges`
  (`fdatasync`) or done synchronously per range via `persistRange` (page-aligned
  `msync`).
- `checkpointCost() = EXPENSIVE` → the WAL amortises: high txn cap (64) and 50%
  fill watermark, so an `fdatasync` + superblock `msync` is paid rarely.

### PMEM / DAX (`PmemMmapRegion` / `PmemMmapBackend`)
- `mmap(MAP_SHARED_VALIDATE | MAP_SYNC)` over a DAX device; durability via
  cache-line flush + store fence, no page cache in the path.
- **Eager, ordering-sensitive:** `prepareChangedRange` flushes cache lines
  *immediately* (side-effectful); `persistChanges` only issues the fence.
- `checkpointCost() = CHEAP` → low txn cap (8) and 25% watermark; fences are
  cheap so reclaim eagerly.

### The crucial asymmetry (RQ2 seed)
`prepareChangedRange` means **"flush now"** for PMEM but **"remember for later"**
for file. `persistChanges` is a *fence* for PMEM but a *sync* for file. The WAL
calls the identical sequence for both, relying on the two being
*interchangeable* — but the ordering guarantee each provides between the WAL
record write and the region data write differs. Making that guarantee explicit
(and equal, or explicitly different) is the heart of RQ2. See
[durability-and-recovery.md](durability-and-recovery.md).

---

## File I/O helper (`RegionFileIO`)

Wraps the raw syscalls the two mmap backends need:

- `open(path)` — attach to existing (`O_RDWR`), `-errno` if absent
- `create(path)` — fresh (`O_RDWR|O_CREAT|O_TRUNC`); `O_TRUNC` + `ensureSize`
  `ftruncate` leaves bytes zero
- `openBacking(path, fresh)` — picks `create` vs `open` (open falls back to
  create if missing)
- `ensureSize` (`ftruncate`+`fdatasync`), `fdatasync`, `close`, `unlink`

This is the boundary where the abstract `fresh` flag becomes a concrete syscall
decision — a clean example of the interface hiding a media detail (how do you
zero a fresh store?) behind one bool.

---

## Platform wrappers (`X86_64PWRegion.v3`)

Convenience subclasses wiring a backend to `PWRegion` / `ImmixPWRegion`:

| Wrapper | Backend |
|---|---|
| `X86_64PWMemRegion` | volatile |
| `X86_64PWBlockDeviceRegion` | file |
| `X86_64PWNVRegion` | PMEM/DAX |
| `X86_64ImmixPWMemRegion` / `X86_64ImmixPWNVRegion` | + Immix line-mark metadata |

That the *only* difference between these is which backend is injected is the
strongest single piece of evidence for the "write the allocator once" claim.
