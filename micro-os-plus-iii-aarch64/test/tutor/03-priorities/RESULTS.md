# Lesson 03 (Zig) — Results

| Version | QEMU (`raspi4b`) | Board (Raspberry Pi 4 B, `test/run-all.sh`) |
|---|---|---|
| `tutor-03-priorities-1cpu` | PASS | PASS, 15 s |
| `tutor-03-priorities-4cpu` | PASS | PASS, 15 s |

Run on 2026-10-22. Under QEMU the four-CPU version passed six runs in a
row. The board's verdict lines:

```
RESULT: PASS (priorities run highest first; a timer interrupt preempts a busy thread; one CPU)
RESULT: PASS (priorities run in parallel on separate cores; a timer interrupt preempts a busy thread on core 1; four CPUs)
```

On the board the Zig images send only the verdict line to semihosting; the
console (the workers' order, the latencies) is on the UART. The C++ lesson,
built with `SEMI_PRINTS=1`, recorded the board's consoles: a maximum
latency of 2 µs (one CPU) and 3 µs (four CPUs), against the 1 ms bound
both languages check on the board.

The lesson was written after the C++ one and met none of its problems: it
takes the second interrupt from CNTV from the start (QEMU does not wire
the System Timer to the GIC), the responder signals `done` instead of
being joined while the busy thread computes (the idle thread, which wakes
a joiner, would starve — the Zig kernel has the same reaper as the C++
one), and the timing bounds are strict only on the board. The one new
piece is `tutor.onHardware()`: the same image runs under QEMU and on the
board, so it is told at run time from the timer's frequency (62.5 MHz
under QEMU, printed by a probe; 54 MHz on the Pi 4).

The full consoles below are the QEMU runs.

## One CPU (QEMU)

```
+== RPi 4 B µOS++ tutorial (Zig) : 03 priorities (1 CPU) ==+

Lesson 03, one CPU: priorities, and preemption by a second interrupt.
  .data   00093b58 .. 00093e38
  heap    009165e0 .. 3b400000
  stack   000a0210 .. 000b0208 (thread main)

-- part A: three workers, created low, normal, high; main at realtime
  low    started #4, finished #5, ran 867 us .. 1062 us (195 us), 0 bad rounds
  normal started #2, finished #3, ran 681 us .. 859 us (178 us), 0 bad rounds
  high   started #0, finished #1, ran 0 us .. 458 us (458 us), 0 bad rounds
  [ok] every worker's 400 rounds exact
  [ok] one CPU: high ran to its end, then normal, then low (no overlap)

-- part B: a busy thread at low, a responder at high, the virtual timer every 5000 us
  100 interrupts in 500061 us (ISR count 100, on cores mask 1)
  latency ISR -> responder: max 405 us, mean 7 us
  busy thread: 1052424 rounds, 0 bad; at the responder's wakes: 9837, 19266, ..., 1052423
  [ok] the second interrupt fired 100 times
  [ok] every interrupt ran on core 0
  [ok] every interrupt handled by the responder within 20000 us (max 405 us)
  [ok] the busy thread progressed between 99 of 99 pairs of interrupts (preempted, then resumed)
  [ok] every busy round exact
  [ok] heap back to 0 B
RESULT: PASS (priorities run highest first; a timer interrupt preempts a busy thread; one CPU)
```

## Four CPUs (QEMU)

```
+== RPi 4 B µOS++ tutorial (Zig) : 03 priorities (4 CPU) ==+

Lesson 03, four CPUs: priorities, and preemption by a second interrupt.
  .data   00095a38 .. 00096050
  heap    009259c0 .. 3b400000
  stack   000af530 .. 000bf520 (thread main)
core 0: releasing core 1...
core 0: releasing core 2...
core 0: releasing core 3...
  cores joined after 0 ms: c1=3 c2=3 c3=3
  [ok] cores 1-3 joined the scheduler

-- part A: three workers, low on core 1, normal on core 2, high on core 3
  low    core 1, started #2, finished #4, ran 3 us .. 740 us (737 us), 0 bad rounds
  normal core 2, started #0, finished #3, ran 0 us .. 714 us (714 us), 0 bad rounds
  high   core 3, started #1, finished #5, ran 12 us .. 796 us (784 us), 0 bad rounds
  [ok] every worker's 400 rounds exact
  [ok] each worker ran on its own core (low 1, normal 2, high 3)
  [ok] four CPUs: the three priorities ran at the same time (all started before any finished)

-- part B: on core 1, a busy thread at low, a responder at high, the virtual timer every 5000 us
  100 interrupts in 500074 us (ISR count 100, on cores mask 2)
  latency ISR -> responder: max 371 us, mean 6 us
  busy thread: 868472 rounds, 0 bad; at the responder's wakes: 7965, 15872, ..., 868458
  [ok] the second interrupt fired 100 times
  [ok] the responder and every interrupt ran on core 1
  [ok] every interrupt handled by the responder within 20000 us (max 371 us)
  [ok] the busy thread progressed between 99 of 99 pairs of interrupts (preempted, then resumed)
  [ok] every busy round exact
  [ok] heap back to 0 B
RESULT: PASS (priorities run in parallel on separate cores; a timer interrupt preempts a busy thread on core 1; four CPUs)
```
