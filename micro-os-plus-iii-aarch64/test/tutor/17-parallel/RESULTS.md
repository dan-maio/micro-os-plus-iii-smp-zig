# Lesson 17 (Zig) — Results

| Version | QEMU (`raspi4b`) | Board (Raspberry Pi 4 B, `test/run-all.sh`) |
|---|---|---|
| `tutor-17-parallel-1cpu` | PASS | PASS, 14 s |
| `tutor-17-parallel-4cpu` | PASS | PASS, 14 s |

Run on 2026-10-24. The board's verdict lines:

```
RESULT: PASS (4096 samples sorted whole and split, as the reference; one CPU)
RESULT: PASS (4096 samples sorted split and in parallel, as the reference; the speed-ups measured; four CPUs)
```

On the board the Zig images send only the verdict lines to semihosting;
the console is on the UART. The full consoles below are the QEMU runs.

| | 1 CPU, QEMU | 4 CPUs, QEMU |
|---|---|---|
| A: one list of 4096, sort + max | 21.62 ms | 20.98 ms |
| B: four sorts of 1024 on one core / merge + reduction | 4993 / 398 µs | 4878 / 348 µs |
| A / B | 4.01 | 4.01 |
| C: four sorts, one per core / merge + reduction | — | 1138 / 130 µs |
| the sorts, B / C | — | 4.29 |
| with the merge (Amdahl's bound) | — | 4.12 (3.34) |
| A / C | — | 16.55 |

Every part: checksum `80cee5e8`, max 9999 (id 3966), as the reference and
as C++. Under QEMU part B's speed-ups pass Amdahl's bound: the emulated
cores are host threads, not a measurement.

## One CPU (QEMU)

```
+== RPi 4 B µOS++ tutorial (Zig) : 17 parallel (1 CPU) ==+

Lesson 17, one CPU: the work split, merged, measured.
  .data   00092708 .. 000929c0
  heap    00916000 .. 3b400000
  stack   0009f210 .. 000af208 (thread main)

  the reference (an array, no list code): checksum 80cee5e8, max 9999 (id 3966)
  4096 samples on the heap, 4096 in place
  [ok] every sample is on the heap, sealed

-- part A: the reference time: 4096 samples, one list, one thread
  sort + max 21619 us; checksum 80cee5e8, max 9999 (id 3966)
  [ok] one list: sorted order and max are the reference's

-- part B: split in four, the workers all on the one CPU; merged, maxima reduced
  worker 0: samples    1..1024, core 0, ran   3463 ..   4993 us after the start, its max 9980 (id 540)
  worker 1: samples 1025..2048, core 0, ran    561 ..   4742 us after the start, its max 9993 (id 1348)
  worker 2: samples 2049..3072, core 0, ran   1466 ..   4972 us after the start, its max 9992 (id 2456)
  worker 3: samples 3073..4096, core 0, ran   2465 ..   4986 us after the start, its max 9999 (id 3966)
  split: sorts 4993 us, merge + reduction 398 us (the threads' creation and join: 1212 us more);
  4096 samples, checksum 80cee5e8, max 9999 (id 3966)
  part A / part B = 4.01: four sorts of 1024 cost about a quarter of one of 4096 (the algorithm, not the CPUs)
  [ok] split and merged: the reference's order, checksum and max
  [ok] the split alone is at least 1.50x faster (O(n^2) sort)

  heap: 0 B before the set, 0 B after
  [ok] the heap is back to its level
RESULT: PASS (4096 samples sorted whole and split, as the reference; one CPU)
```

## Four CPUs (QEMU)

```
+== RPi 4 B µOS++ tutorial (Zig) : 17 parallel (4 CPU) ==+

Lesson 17, four CPUs: the work split, merged, measured.
  .data   000948c0 .. 00094eb0
  heap    00924000 .. 3b400000
  stack   000ad530 .. 000bd520 (thread main)
core 0: releasing core 1...
core 0: releasing core 2...
core 0: releasing core 3...
  cores joined after 0 ms: c1=3 c2=3 c3=3
  [ok] cores 1-3 joined the scheduler

  the reference (an array, no list code): checksum 80cee5e8, max 9999 (id 3966)
  4096 samples on the heap, 4096 in place
  [ok] every sample is on the heap, sealed

-- part A: the reference time: 4096 samples, one list, one thread
  sort + max 20982 us; checksum 80cee5e8, max 9999 (id 3966)
  [ok] one list: sorted order and max are the reference's

-- part B: split in four, the workers all on core 0; merged, maxima reduced
  worker 0: samples    1..1024, core 0, ran    545 ..   4650 us after the start, its max 9980 (id 540)
  worker 1: samples 1025..2048, core 0, ran   1335 ..   4866 us after the start, its max 9993 (id 1348)
  worker 2: samples 2049..3072, core 0, ran   2332 ..   4878 us after the start, its max 9992 (id 2456)
  worker 3: samples 3073..4096, core 0, ran   3331 ..   4317 us after the start, its max 9999 (id 3966)
  split: sorts 4878 us, merge + reduction 348 us (the threads' creation and join: 1274 us more);
  4096 samples, checksum 80cee5e8, max 9999 (id 3966)
  part A / part B = 4.01: four sorts of 1024 cost about a quarter of one of 4096 (the algorithm, not the CPUs)
  [ok] split and merged: the reference's order, checksum and max
  [ok] the four workers ran on core 0
  [ok] the split alone is at least 1.50x faster (O(n^2) sort)

-- part C: the same four workers, one on each core
  worker 0: samples    1..1024, core 0, ran      7 ..    997 us after the start, its max 9980 (id 540)
  worker 1: samples 1025..2048, core 1, ran    119 ..   1119 us after the start, its max 9993 (id 1348)
  worker 2: samples 2049..3072, core 2, ran     42 ..   1138 us after the start, its max 9992 (id 2456)
  worker 3: samples 3073..4096, core 3, ran     61 ..   1048 us after the start, its max 9999 (id 3966)
  parallel: sorts 1138 us, merge + reduction 130 us (the threads' creation and join: 897 us more);
  4096 samples, checksum 80cee5e8, max 9999 (id 3966)
  the sorts: 4.29 x faster on four cores; with the merge: 4.12 x (Amdahl's bound for this merge: 3.34 x)
  counting the threads' creation and join too: 3.00 x; part A / part C = 16.55
  [ok] in parallel: the reference's order, checksum and max
  [ok] worker k ran on core k
  [ok] the four sorts at least 1.20x faster on four cores

  heap: 0 B before the set, 0 B after
  [ok] the heap is back to its level
RESULT: PASS (4096 samples sorted split and in parallel, as the reference; the speed-ups measured; four CPUs)
```
