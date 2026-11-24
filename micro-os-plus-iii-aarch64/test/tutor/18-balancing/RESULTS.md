# Lesson 18 (Zig) — Results

| Version | QEMU (`raspi4b`) | Board (Raspberry Pi 4 B, `test/run-all.sh`) |
|---|---|---|
| `tutor-18-balancing-1cpu` | PASS | PASS, 15 s |
| `tutor-18-balancing-4cpu` | PASS | PASS, 15 s |

Run on 2026-10-24. The board's verdict lines:

```
RESULT: PASS (eight workers time-sliced on one CPU, fair shares; one CPU)
RESULT: PASS (eight floating workers over four cores, fair shares; a thread moved at run time; four CPUs)
```

On the board the Zig images send only the verdict lines to semihosting;
the console is on the UART. The full consoles below are the QEMU runs.

| | 1 CPU, QEMU | 4 CPUs, QEMU |
|---|---|---|
| a chunk (calibrated) | 76628 iterations | 82304 iterations |
| A: 80 ms of work took | 73.84 ms (1.08×) | 21.60 ms (3.70×) |
| A: time slices / migrations | 75 / — | — / 1 |
| B: chunks per worker in 400 ms | 557 … 564 | 2049 … 2094 |
| C: pinned to core 2 / 3, there after | — | 701 / 909 µs |
| C: chunks elsewhere after | — | 0 |

## One CPU (QEMU)

```
+== RPi 4 B µOS++ tutorial (Zig) : 18 balancing (1 CPU) ==+

Lesson 18, one CPU: threads without affinity, where they run, and moving one.
  .data   00092ed0 .. 00093160
  heap    0090f000 .. 3b400000
  stack   00098210 .. 000a8208 (thread main)
  a chunk: 76628 loop iterations, about 100 us

-- part A: 8 workers of 100 chunks of 100 us, no affinity, one CPU
  worker 0: 100 chunks, ran   849 .. 72805 us, on cores 0, 0 migrations
  worker 1: 100 chunks, ran   980 .. 72887 us, on cores 0, 0 migrations
  worker 2: 100 chunks, ran  1932 .. 72891 us, on cores 0, 0 migrations
  worker 3: 100 chunks, ran  2935 .. 67904 us, on cores 0, 0 migrations
  worker 4: 100 chunks, ran  3934 .. 68877 us, on cores 0, 0 migrations
  worker 5: 100 chunks, ran  4935 .. 73027 us, on cores 0, 0 migrations
  worker 6: 100 chunks, ran  5932 .. 70886 us, on cores 0, 0 migrations
  worker 7: 100 chunks, ran  6931 .. 72960 us, on cores 0, 0 migrations
  80000 us of work in 73839 us: 1.08 x; 75 time slices
  [ok] every worker did its 100 chunks
  [ok] all 8 were under way before the first one ended
  [ok] the CPU went round the eight in time slices (at least 32)
  [ok] one CPU: the work took its own time

-- part B: fairness: the 8 count chunks for 400 ms
  chunks: 557 561 563 564 564 563 562 563
  chunks per worker: 557 .. 564, 4497 in all (1 cores x 400 ms = 4000 chunks of 100 us)
  [ok] each got its share: the fewest at least 50 % of the most

  heap: 0 B before, 0 B after
  [ok] the heap is back to its level
RESULT: PASS (eight workers time-sliced on one CPU, fair shares; one CPU)
```

## Four CPUs (QEMU)

```
+== RPi 4 B µOS++ tutorial (Zig) : 18 balancing (4 CPU) ==+

Lesson 18, four CPUs: threads without affinity, where they run, and moving one.
  .data   00096cd0 .. 00097298
  heap    00929000 .. 3b400000
  stack   000b2530 .. 000c2520 (thread main)
core 0: releasing core 1...
core 0: releasing core 2...
core 0: releasing core 3...
  cores joined after 0 ms: c1=3 c2=3 c3=3
  [ok] cores 1-3 joined the scheduler
  a chunk: 82304 loop iterations, about 100 us

-- part A: 8 workers of 100 chunks of 100 us, no affinity, four CPUs
  worker 0: 100 chunks, ran   817 .. 20663 us, on cores 0, 0 migrations
  worker 1: 100 chunks, ran   924 .. 20347 us, on cores 01, 1 migrations
  worker 2: 100 chunks, ran   934 .. 19758 us, on cores 2, 0 migrations
  worker 3: 100 chunks, ran  1095 .. 19881 us, on cores 3, 0 migrations
  worker 4: 100 chunks, ran  1180 .. 19958 us, on cores 0, 0 migrations
  worker 5: 100 chunks, ran  1772 .. 20491 us, on cores 1, 0 migrations
  worker 6: 100 chunks, ran  1876 .. 20639 us, on cores 2, 0 migrations
  worker 7: 100 chunks, ran  2041 .. 20758 us, on cores 3, 0 migrations
  80000 us of work in 21600 us: 3.70 x; cores used 0123; 1 migrations
  [ok] every worker did its 100 chunks
  [ok] all 8 were under way before the first one ended
  [ok] the eight floating workers ran on all four cores
  [ok] floating workers moved between cores
  [ok] four cores did the work at least 1.50x as fast as one

-- part B: fairness: the 8 count chunks for 400 ms
  chunks: 2079 2094 2085 2086 2049 2085 2080 2082
  chunks per worker: 2049 .. 2094, 16640 in all (4 cores x 400 ms = 16000 chunks of 100 us)
  [ok] each got its share: the fewest at least 50 % of the most

-- part C: a floating mover among 4 floating workers; pinned to core 2, then 3, then free
  free, 100 ms: 826 chunks, on cores 0123
  [ok] free, the mover ran on more than one core
  pinned to core 2: first chunk there 701 us after the change; then 521 chunks there, 0 elsewhere (cores 12)
  pinned to core 3: first chunk there 909 us after the change; then 516 chunks there, 0 elsewhere (cores 3)
  free again: first chunk there 28 us after the change; then 830 chunks there, 0 elsewhere (cores 0123)
  [ok] pinned to core 2: there within 50000 us, and nowhere else after
  [ok] pinned to core 3: there within 50000 us, and nowhere else after
  [ok] freed again, it left core 3

  heap: 0 B before, 0 B after
  [ok] the heap is back to its level
RESULT: PASS (eight floating workers over four cores, fair shares; a thread moved at run time; four CPUs)
```
