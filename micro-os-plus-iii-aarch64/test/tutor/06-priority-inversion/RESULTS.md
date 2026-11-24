# Lesson 06 (Zig) — Results

| Version | QEMU (`raspi4b`) | Board (Raspberry Pi 4 B, `test/run-all.sh`) |
|---|---|---|
| `tutor-06-priority-inversion-1cpu` | PASS | PASS, 14–15 s (3 runs) |
| `tutor-06-priority-inversion-4cpu` | PASS | PASS, 14 s (3 runs, each after a one-CPU run; the first run before the fix below failed) |

Run on 2026-10-22. The board's verdict lines:

```
RESULT: PASS (none lets M invert H; inherit and protect bound H to one critical section; one CPU)
RESULT: PASS (inversion on one core with none, bounded by inherit and protect, gone with M on another core; four CPUs)
```

From the UART, the four-CPU run (the first one, below): `none` on core 1
100 018 µs, `inherit` 19 086 µs, `protect` 19 806 µs, `none` with M on core
2 19 522 µs — the C++ lesson's numbers (100 015, 19 099, 19 124, 19 074).

## The fault on core 3, and its fix

The first four-CPU board run failed one check: core 3 never joined. With
the fault report fixed in lesson 05 (`src/faults.zig`), the UART now showed
the exception:

```
!!! FATAL EXCEPTION on CPU 3 (vector 0x11) !!!
  ESR_EL1  = 0x000000008a000000 (EC=0x22 ISS=0x0)
  ELR_EL1  = 0xff79ff47ff4eff8a (code 0xffffffff, not readable: PC unaligned or outside RAM)
  FAR_EL1  = 0xff79ff47ff4eff8a
  SPSR_EL1 = 0x00000000000003c5
  cores joined after 3000 ms: c1=3 c2=3 c3=0
```

EC 0x22 is a PC alignment fault, at EL1 with interrupts masked: core 3,
while starting, returned (`ret`) to `0xff79ff47ff4eff8a` — not an address
but leftover data. Core 3's stack top `__stack_top_core3` was `_end`, the
heap's first byte, so the cache line just below `_end` held both core 3's
first frame and the heap's first chunk header. Core 3 starts with its MMU
and caches off: `bl mmu_enable` stores its return address straight to RAM.
Core 0 had written the chunk header with caches on, so it held that line
dirty, with the RAM's older bytes for the stack's part; once core 3 turned
its caches on, the coherent read of its return address got core 0's stale
copy. Only core 3's stack touches the heap; QEMU models no such caches; and
the stale bytes are an earlier run's, which is why it showed after runs
without a power-cycle — the four-CPU runs of lessons 04 and 05 straight
after a one-CPU run (core 3 "running nothing", "faulting while starting").

The fix, in `boards/rpi4b/linker.ld`: every stack top on a cache line, a
guard line after core 3's, and `_end` on a page. After it, three pairs of
runs (one CPU, then four, no power-cycle) all passed.

The full consoles below are the QEMU runs.

## One CPU (QEMU)

```
+== RPi 4 B µOS++ tutorial (Zig) : 06 priority inversion (1 CPU) ==+

Lesson 06, one CPU: priority inversion, and the protocols that bound it.
  .data   00091ca0 .. 00092820
  heap    00915270 .. 3b400000
  stack   0009f210 .. 000af208 (thread main)

-- L (low) holds the mutex 20 ms; H (high) asks for it; M (normal) computes 100 ms
  none                                H waited 100779 us; L at low while holding, 1 sorts; M ran while H waited
  inherit                             H waited  19873 us; L at high while holding, 1934 sorts; M ran after H
  protect                             H waited  18294 us; L at high while holding, 1952 sorts; M ran after H
  [ok] none: H waited M's whole 100 ms (priority inversion)
  [ok] inherit: H waited at most one critical section (20 ms)
  [ok] protect: H waited at most one critical section
  [ok] L ran at low with none, at high with inherit (H's) and with protect (the ceiling)
  [ok] the shared list intact after every scenario (72 samples, checksum exact)
  [ok] heap back to 0 B
RESULT: PASS (none lets M invert H; inherit and protect bound H to one critical section; one CPU)
```

## Four CPUs (QEMU)

```
+== RPi 4 B µOS++ tutorial (Zig) : 06 priority inversion (4 CPU) ==+

Lesson 06, four CPUs: priority inversion, and the protocols that bound it.
  .data   00092bc8 .. 00093a80
  heap    00922630 .. 3b400000
  stack   000ac530 .. 000bc520 (thread main)
core 0: releasing core 1...
core 0: releasing core 2...
core 0: releasing core 3...
  cores joined after 0 ms: c1=3 c2=3 c3=3
  [ok] cores 1-3 joined the scheduler

-- L (low) holds the mutex 20 ms; H (high) asks for it; M (normal) computes 100 ms
  none     (all on core 1)            H waited 100896 us; L at low while holding, 53 sorts; M ran while H waited
  inherit  (all on core 1)            H waited  19420 us; L at high while holding, 1827 sorts; M ran after H
  protect  (all on core 1)            H waited  19778 us; L at high while holding, 1858 sorts; M ran after H
  none     (M on core 2)              H waited  20000 us; L at low while holding, 1651 sorts; M ran while H waited
  [ok] none, one core: H waited M's whole 100 ms (priority inversion)
  [ok] inherit, one core: H waited at most one critical section (20 ms)
  [ok] protect, one core: H waited at most one critical section
  [ok] L ran at low with none, at high with inherit (H's) and with protect (the ceiling)
  [ok] none, M on another core: H waited at most one critical section
  [ok] the shared list intact after every scenario (72 samples, checksum exact)
  [ok] heap back to 0 B
RESULT: PASS (inversion on one core with none, bounded by inherit and protect, gone with M on another core; four CPUs)
```
