# Lesson 02 (Zig) — Results

| Version | QEMU (`raspi4b`) | Board (Raspberry Pi 4 B, `test/run-all.sh`) |
|---|---|---|
| `tutor-02-threads-1cpu` | PASS | PASS, 15 s |
| `tutor-02-threads-4cpu` | PASS | PASS, 14 s |

Run on 2026-10-22, the Zig workspace, Zig 0.17.0. The board's verdict
lines:

```
RESULT: PASS (4 threads, 72 samples in 3 regions, joined, round-robin, results exact, one CPU)
RESULT: PASS (4 threads, 72 samples in 3 regions, joined, one per core, results exact, four CPUs)
```

The full consoles below are the QEMU runs (the board's console is the UART).

## One CPU (QEMU)

```
+== RPi 4 B µOS++ tutorial (Zig) : 02 threads (1 CPU) ==+

Lesson 02, one CPU: 4 worker threads, 18 samples each in 3 regions.
  .data   00092f80 .. 00093560
  heap    00926260 .. 3b400000
  stack   000b0210 .. 000c0208 (thread main)

-- creating the workers (main at above_normal, workers at normal)
  w0: stack 0009c000 .. 000a3ff8 (static, .bss)
  w1: stack 000a4000 .. 000abff8 (static, .bss)
  w2: stack 3b3f7cd0 .. 3b3ffcc8 (allocated, heap)
  w3: stack 3b3efbc0 .. 3b3f7bb0 (allocated, heap)
  [ok] the 4 workers joined
  [ok] each join() returned its worker's result

-- the trace (worker:step)
  w1:0 w2:0 w3:0 w0:0 w1:1 w2:1 w3:1 w0:1 w1:2 w2:2 w3:2 w0:2 w1:3 w2:3 w3:3 w0:3
  [ok] round-robin: every worker finished step k before any started k+1

-- the results
  w0: 18 samples, checksum feb95b71, max 9217 (#16) ok
  w1: 18 samples, checksum faa1c843, max 9711 (#109) ok
  w2: 18 samples, checksum a7ad6c5a, max 8989 (#212) ok
  w3: 18 samples, checksum 8fcc653e, max 9588 (#304) ok
  [ok] every worker's samples placed, sorted, checksum and max exact
  [ok] merged max 9711 (#109), expected 9711 (#109)
  [ok] heap back to 0 B (threads, heap stacks, samples)
RESULT: PASS (4 threads, 72 samples in 3 regions, joined, round-robin, results exact, one CPU)
```

## Four CPUs (QEMU)

```
+== RPi 4 B µOS++ tutorial (Zig) : 02 threads (4 CPU) ==+

Lesson 02, four CPUs: 4 worker threads, 18 samples each in 3 regions.
  .data   000969b8 .. 000972d0
  heap    00936640 .. 3b400000
  stack   000c0530 .. 000d0520 (thread main)
core 0: releasing core 1...
core 0: releasing core 2...
core 0: releasing core 3...
  cores joined after 0 ms: c1=3 c2=3 c3=3
  [ok] cores 1-3 joined the scheduler

-- creating the workers (main at above_normal, workers at normal)
  w0 on core 0: stack 000a0000 .. 000a7ff8 (static, .bss)
  w1 on core 1: stack 000a8000 .. 000afff8 (static, .bss)
  w2 on core 2: stack 3b3f7cd0 .. 3b3ffcc8 (allocated, heap)
  w3 on core 3: stack 3b3efbc0 .. 3b3f7bb0 (allocated, heap)
  [ok] the 4 workers joined
  [ok] each join() returned its worker's result

-- the trace (worker:step@core)
  w3:0@c3 w2:0@c2 w0:0@c0 w1:0@c1 w0:1@c0 w1:1@c1 w2:1@c2 w3:1@c3 w3:2@c3 w0:2@c0 w1:2@c1 w2:2@c2 w3:3@c3 w1:3@c1 w0:3@c0 w2:3@c2
  [ok] every worker ran all its steps on its own core

-- the results
  w0: 18 samples, checksum feb95b71, max 9217 (#16) ok
  w1: 18 samples, checksum faa1c843, max 9711 (#109) ok
  w2: 18 samples, checksum a7ad6c5a, max 8989 (#212) ok
  w3: 18 samples, checksum 8fcc653e, max 9588 (#304) ok
  [ok] every worker's samples placed, sorted, checksum and max exact
  [ok] merged max 9711 (#109), expected 9711 (#109)
  [ok] heap back to 0 B (threads, heap stacks, samples)
RESULT: PASS (4 threads, 72 samples in 3 regions, joined, one per core, results exact, four CPUs)
```

## What the numbers show

- The per-worker checksums (`feb95b71`, `faa1c843`, `a7ad6c5a`, `8fcc653e`),
  the maxima and the merged maximum (9711, #109) are the C++ lesson's, in
  both versions.
- With one CPU the trace is a strict round-robin; here the turn order inside
  every group is `w1 w2 w3 w0` (in the C++ kernel it was `w0 w1 w2 w3`): the
  two kernels place the threads created by the main thread differently in
  the ready list. What the lesson checks — all four finish a step before any
  starts the next — holds in both.
- With four CPUs every step of worker `w` ran on core `w`, in an order that
  changes from run to run.
- The heap returns to its level once the threads are destroyed.
