# Lesson 12 (Zig) — Results

| Version | QEMU (`raspi4b`) | Board (Raspberry Pi 4 B, `test/run-all.sh`) |
|---|---|---|
| `tutor-12-memory-1cpu` | PASS | PASS, 15 s |
| `tutor-12-memory-4cpu` | PASS | PASS, 14 s (straight after the one-CPU run) |

Run on 2026-10-23. The board's verdict lines:

```
RESULT: PASS (samples from a shared pool, never over capacity, all freed; first_fit_top, lifo, block_pool, out-of-memory handler; every resource back to zero; one CPU)
RESULT: PASS (samples from a pool shared by four cores, never over capacity, all freed; first_fit_top, lifo, block_pool, out-of-memory handler; every resource back to zero; four CPUs)
```

On the board the Zig images send only the verdict lines to semihosting;
the console is on the UART. Under QEMU 22 (1 CPU) and 20 (4 CPUs)
allocations of 320 waited for a block; the byte counts differ slightly from
the C++ lesson's (another chunk header size), the chunk counts do not.

The full consoles below are the QEMU runs.

## One CPU (QEMU)

```
+== RPi 4 B µOS++ tutorial (Zig) : 12 memory (1 CPU) ==+
Lesson 12, one CPU: memory pools and memory resources, their statistics.
-- part A: 4 workers x 20 rounds x 4 samples from a pool of 13 blocks (32 B each)
  320 allocations, 22 found the pool empty and waited; at most 13 of 13 in use; 0 outside the pool, 0 bad rounds; now 0 in use (pool count 0)
  [ok] 320 samples allocated, filled and checked
  [ok] never more than 13 blocks, all inside the pool
  [ok] the pool ran dry and allocations waited for a free block
  [ok] the pool ends with nothing in use
-- part B: memory resources over static arenas, and their statistics
  first_fit_top, 3 blocks:     allocated  632 B in 3 chunks, free 1416 B in 1 chunks, max  632 B
  first_fit_top, middle freed: allocated  424 B in 2 chunks, free 1624 B in 2 chunks, max  632 B
  first_fit_top, all freed:    allocated    0 B in 0 chunks, free 2048 B in 1 chunks, max  632 B
  [ok] first_fit_top: freeing the middle block leaves a hole (one more free chunk)
  [ok] first_fit_top: all freed, the arena is one free chunk again
  lifo, 4 blocks:              allocated  672 B in 4 chunks, free 1376 B in 1 chunks, max  672 B
  lifo, freed in reverse:      allocated    0 B in 0 chunks, free 2048 B in 1 chunks, max  672 B
  [ok] lifo: freed in reverse order the arena never fragments (one free chunk throughout)
  block_pool, 9 asked of 8:    8 given, the 9th refused; 8 in use
  block_pool, all freed:       0 in use (most at once 8)
  [ok] block_pool: 8 blocks given, the 9th refused (nullptr)
  [ok] block_pool: all back
  out of memory: 500 B with a 600 B reserve held -> ok after 1 handler call; 4096 B -> nullptr after 1 calls
  [ok] the handler freed the reserve and the allocation succeeded
  [ok] an allocation larger than the arena fails (nullptr)
  [ok] the handler's arena back to zero
  memory_pool of 2: two taken, try_alloc nullptr, timed_alloc(10) nullptr after 10 ticks
  [ok] an empty pool: try_alloc nullptr, timed_alloc nullptr after 10 ticks
  [ok] the small pool back to zero
  [ok] heap back to 0 B (no `new` behind the pools)
RESULT: PASS (samples from a shared pool, never over capacity, all freed; first_fit_top, lifo, block_pool, out-of-memory handler; every resource back to zero; one CPU)
```

## Four CPUs (QEMU)

```
+== RPi 4 B µOS++ tutorial (Zig) : 12 memory (4 CPU) ==+
Lesson 12, four CPUs: memory pools and memory resources, their statistics.
  cores joined after 0 ms: c1=3 c2=3 c3=3
  [ok] cores 1-3 joined the scheduler
-- part A: 4 workers (cores 0-3) x 20 rounds x 4 samples from a pool of 13 blocks (32 B each)
  320 allocations, 20 found the pool empty and waited; at most 13 of 13 in use; 0 outside the pool, 0 bad rounds; now 0 in use (pool count 0)
  [ok] 320 samples allocated, filled and checked
  [ok] never more than 13 blocks, all inside the pool
  [ok] the pool ran dry and allocations waited for a free block
  [ok] the pool ends with nothing in use
  [ok] the pool shared by four cores (workers on cores 0, 1, 2, 3)
-- part B: memory resources over static arenas, and their statistics
  first_fit_top, 3 blocks:     allocated  632 B in 3 chunks, free 1416 B in 1 chunks, max  632 B
  first_fit_top, middle freed: allocated  424 B in 2 chunks, free 1624 B in 2 chunks, max  632 B
  first_fit_top, all freed:    allocated    0 B in 0 chunks, free 2048 B in 1 chunks, max  632 B
  [ok] first_fit_top: freeing the middle block leaves a hole (one more free chunk)
  [ok] first_fit_top: all freed, the arena is one free chunk again
  lifo, 4 blocks:              allocated  672 B in 4 chunks, free 1376 B in 1 chunks, max  672 B
  lifo, freed in reverse:      allocated    0 B in 0 chunks, free 2048 B in 1 chunks, max  672 B
  [ok] lifo: freed in reverse order the arena never fragments (one free chunk throughout)
  block_pool, 9 asked of 8:    8 given, the 9th refused; 8 in use
  block_pool, all freed:       0 in use (most at once 8)
  [ok] block_pool: 8 blocks given, the 9th refused (nullptr)
  [ok] block_pool: all back
  out of memory: 500 B with a 600 B reserve held -> ok after 1 handler call; 4096 B -> nullptr after 1 calls
  [ok] the handler freed the reserve and the allocation succeeded
  [ok] an allocation larger than the arena fails (nullptr)
  [ok] the handler's arena back to zero
  memory_pool of 2: two taken, try_alloc nullptr, timed_alloc(10) nullptr after 10 ticks
  [ok] an empty pool: try_alloc nullptr, timed_alloc nullptr after 10 ticks
  [ok] the small pool back to zero
  [ok] heap back to 0 B (no `new` behind the pools)
RESULT: PASS (samples from a pool shared by four cores, never over capacity, all freed; first_fit_top, lifo, block_pool, out-of-memory handler; every resource back to zero; four CPUs)
```
