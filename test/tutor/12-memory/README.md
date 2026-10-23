# Lesson 12 (Zig) — Memory: pools and memory resources

## 1. Theory

### Why not just `new`

A general-purpose heap (`new`, `malloc`) can satisfy any size, but at a
price that matters in a real-time system: its time is not bounded (it
searches a free list), it **fragments** (enough free bytes in total, no
single piece large enough), and it can fail at any moment, far from where
the memory was wasted. An RTOS offers allocators with fewer powers and
better guarantees, each for a pattern of use:

- a **memory pool** of fixed-size blocks: allocation and release take
  constant time, there is no fragmentation (every block fits every request),
  and the capacity is known in advance. When the pool is empty, a thread can
  **wait** for a block — the pool is a synchronisation object too;
- a **first-fit, top-down** allocator over an **arena** (a static buffer):
  any size, like the heap, but bounded to its own buffer, so one subsystem
  cannot exhaust another's memory;
- a **LIFO** allocator: the same, but deterministic and fragmentation-free
  when blocks are released in reverse order of allocation — ideal for
  objects created at start-up, or created and destroyed in nested order;
- a **block pool** resource: fixed-size blocks behind the generic
  memory-resource interface, usable as an allocator for containers.

Each resource keeps **statistics** — bytes and chunks allocated, free,
the most ever allocated — so the system can be measured, and a test can
prove that everything was given back.

### Waiting, and deadlock

A pool that makes threads wait brings back a classic hazard. A thread that
holds some blocks while waiting for one more (*hold and wait*), with other
threads doing the same, can end with every block held and every thread
waiting: a **deadlock**. With *n* threads each needing *k* blocks at once, a
pool of `n · (k − 1) + 1` blocks is enough to rule it out — at least one
thread can always complete its set and free it. Below that, take all the
blocks at once or none.

### When it runs out

A fixed arena will run out. A resource may be given an **out-of-memory
handler**, called when an allocation fails: it may free something (a cache,
a reserve) and let the allocation be retried, or give up. Without a handler
the allocation simply fails (`nullptr`), and the caller must cope.

### Several CPUs

A pool shared by threads on four cores is allocated from and released to in
parallel; its internal list is protected by the kernel's lock, so no block
is ever given twice. A thread waiting for a block on one core is woken by a
release on another.

## 2. In µOS++ (Zig)

- `rtos.MemoryPool`: `var pool: rtos.MemoryPool = .{};` and
  `pool.init("name", blocks, block_size, &buffer, .{})`, with a static buffer
  of `rtos.mempool.storageSize(blocks, block_size)` bytes; `pool.alloc()`
  (waits), `tryAlloc()` (`error.WouldBlock`), `timedAlloc(ticks)`
  (`error.TimedOut`), `free(p)`, `countUsed()`, `capacity()`, `isEmpty()`.
- `uos.memory.FirstFitTop.init("name", &arena, .first_fit_top)` (or `.lifo`:
  in Zig the LIFO is a policy of the same allocator) — `allocate(bytes,
  align)` (`null` when it does not fit), `deallocate(p, bytes)`, the
  statistics in `.stats` (`allocated_bytes`, `allocated_chunks`,
  `free_bytes`, `free_chunks`, `max_allocated_bytes`), and
  `.out_of_memory_handler`, a `fn () bool` that returns `true` to retry.
- `uos.memory.BlockPool.init("name", block_size, &buffer)` — a
  `std.mem.Allocator` (`.allocator().create(T)`, `destroy(p)`); `.count`,
  `.max_count`.
- `micro-os-plus-iii/src/rtos/mempool.zig`,
  `micro-os-plus-iii/src/memory/FirstFitTop.zig`, `BlockPool.zig`.

## 3. The lesson

**`1cpu/main.zig`.**

- *Part A, samples from a pool instead of `new`.* Four `worker`s
  (`normal`), 20 rounds each. Every round takes 4 samples from
  `g_pool`, a `MemoryPool` of 13 samples — first `tryAlloc()`, and on
  `error.WouldBlock` counts a wait and calls the blocking `alloc()` — yielding
  after each, so the four interleave; fills them, yields once more while
  holding all four, checks them and frees them. 4 × 4 = 16 blocks are asked
  for at once, 13 = 4 × (4 − 1) + 1 exist: the pool runs dry, yet cannot
  deadlock. A mutex-guarded counter records the most blocks in use at once,
  and every block's address is checked to lie in the pool.
- *Part B, resources and their statistics.* A `first_fit_top` over 2 KB:
  allocate 100, 200, 300 B, free the middle one (a hole: one more free
  chunk), then the others (one free chunk again). A `lifo` over 2 KB:
  allocate four blocks, free them in reverse — the free list never has more
  than one chunk. A `block_pool` of 8 samples: ask for 9. An arena of 1 KB
  with a 600 B reserve held and an out-of-memory handler that frees it: ask
  for 500 B, then for 4 KB. Finally a `memory_pool` of 2: take both, then
  `tryAlloc()` and `timedAlloc(10)`.

**`4cpu/main.zig`** first releases cores 1–3, then runs the four workers on
cores 0, 1, 2 and 3, sharing the pool.

### Files in the build

The same files as lesson 01 (see `../01-bring-up/README.md`, *Files in the
build*), with this lesson's own source in place of lesson 01's:

- `micro-os-plus-iii-aarch64/test/tutor/12-memory/1cpu/main.zig` (or `4cpu/main.zig`)
- `micro-os-plus-iii-aarch64/test/tutor/common/tutor.zig`
- the port (`micro-os-plus-iii-aarch64/src/port.zig`), the board (`micro-os-plus-iii-aarch64/boards/rpi4b/startup.S`, `board.zig`, `linker.ld`) and the kernel (`micro-os-plus-iii/src/rtos/mempool.zig`, `micro-os-plus-iii/src/memory/*.zig`, and the rest of `micro-os-plus-iii/src/`)
- `micro-os-plus-iii-aarch64/build.zig` — the entries `tutor-12-memory-1cpu` and `-4cpu`

## 4. The test

PASS when, in both versions:

- all 320 samples were allocated, filled and checked; never more than 13
  blocks in use, all inside the pool; at least one allocation found the pool
  empty and waited; the pool ends with nothing in use; (4 CPUs) the workers
  ran on cores 0–3;
- `first_fit_top`: freeing the middle block left one more free chunk, and
  freeing all left one free chunk; `lifo`: never more than one free chunk
  while freeing in reverse; `block_pool`: 8 given, the 9th refused;
- the out-of-memory handler freed the reserve once and the 500 B allocation
  succeeded; the 4 KB one failed; that arena back to zero;
- the empty `memory_pool`: `tryAlloc()` and `timedAlloc(10)` returned
  `nullptr`, the latter after 10 ticks;
- the heap is back to its level (no `new` behind any of it); (4 CPUs) cores
  1–3 joined.

## 5. Running it

As lesson 01 (see `../01-bring-up/README.md`, *Running it*); from
`micro-os-plus-iii-aarch64`:

```sh
cd micro-os-plus-iii-aarch64
export PATH=$HOME/zig-x86_64-linux-0.17.0:$PATH
zig build -Dtest=tutor-12-memory-1cpu
zig build -Dtest=tutor-12-memory-4cpu
zig build -Dtest=tutor-12-memory-1cpu run    # QEMU
zig build -Dtest=tutor-12-memory-4cpu run
test/run-all.sh tutor-12-memory-1cpu          # the board
test/run-all.sh tutor-12-memory-4cpu
```

## 6. Results

Both versions PASS under QEMU and on the board (2026-10-23): 15 s and 14 s
on the board. Under QEMU 22 (1 CPU) and 20 (4 CPUs) of the 320 allocations
found the pool empty and waited; the resources behave as in the C++ lesson
(a hole of one chunk, one LIFO chunk, the 9th block refused). The byte
counts differ slightly from the C++ ones — the Zig allocator's chunk
header is a different size. See [`RESULTS.md`](RESULTS.md).

### What this lesson found

The C++ library could not link `lifo_inclusive<N>` (a declared, undefined
constructor; fixed there). In Zig the LIFO is a policy of `FirstFitTop`, so
there was nothing to fix. The hold-and-wait deadlock of section 1 was in the
lesson's own first design, as in C++: it uses 4 samples per round and the
`n · (k − 1) + 1` pool.
