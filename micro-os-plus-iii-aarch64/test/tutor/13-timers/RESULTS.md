# Lesson 13 (Zig) — Results

| Version | QEMU (`raspi4b`) | Board (Raspberry Pi 4 B, `test/run-all.sh`) |
|---|---|---|
| `tutor-13-timers-1cpu` | PASS | PASS, 14 s |
| `tutor-13-timers-4cpu` | PASS | PASS, 14 s (straight after the one-CPU run) |

Run on 2026-10-23. The board's verdict lines:

```
RESULT: PASS (a periodic timer, exact to the tick, feeding the worker from its callback; one-shot, stop, restart; one CPU)
RESULT: PASS (a periodic timer, exact to the tick, its callbacks on core 0 feeding workers on cores 1-3; one-shot, stop, restart; four CPUs)
```

On the board the Zig images send only the verdict lines to semihosting;
the console is on the UART. Under QEMU the numbers are the C++ lesson's.
The C++ lesson's board consoles show the period on the board: exactly
5000 µs, every time.

The full consoles below are the QEMU runs.

## One CPU (QEMU)

```
+== RPi 4 B µOS++ tutorial (Zig) : 13 timers (1 CPU) ==+
Lesson 13, one CPU: software timers, one-shot and periodic, their callbacks.
-- part A: a periodic timer of 5 ticks, 40 callbacks, each handing a sample id to 1 worker(s)
  40 callbacks, first at tick +5, last at +200 (40 periods of 5); in handler mode 40; refused sends 0; callbacks on core mask 1
  [ok] 40 callbacks, every one 5 ticks after the last, 200 ticks in all
  [ok] every callback ran in the tick interrupt (handler mode) and never had to wait
  the worker built 40 samples
  [ok] every sample built once; the sorted checksum equals the reference (4189534b)
-- part C: the callbacks' period in microseconds: 5000 -213 .. 59 us
  [ok] the period within 20000 us of 5 ms
-- part B: one-shot, stop, restart
  one-shot of 10 ticks: 1 callback, 10 ticks after start; then stop () EAGAIN (not running)
  [ok] a one-shot calls back once, at its time, and completes
  started, stopped after 3 ticks (stop () ok): 0 callbacks
  [ok] a timer stopped before its time never calls back
  periodic of 4 ticks for 14: 3 callbacks; restarted with 7 for 22: 3
  [ok] a periodic timer restarted with another period keeps the new one
  [ok] heap back to 0 B
RESULT: PASS (a periodic timer, exact to the tick, feeding the worker from its callback; one-shot, stop, restart; one CPU)
```

## Four CPUs (QEMU)

```
+== RPi 4 B µOS++ tutorial (Zig) : 13 timers (4 CPU) ==+
Lesson 13, four CPUs: software timers, one-shot and periodic, their callbacks.
  cores joined after 0 ms: c1=3 c2=3 c3=3
  [ok] cores 1-3 joined the scheduler
-- part A: a periodic timer of 5 ticks, 40 callbacks, each handing a sample id to 3 worker(s)
  40 callbacks, first at tick +5, last at +200 (40 periods of 5); in handler mode 40; refused sends 0; callbacks on core mask 1
  [ok] 40 callbacks, every one 5 ticks after the last, 200 ticks in all
  [ok] every callback ran in the tick interrupt (handler mode) and never had to wait
  the workers built 40 samples: 14 on core 1, 13 on core 2, 13 on core 3
  [ok] the callbacks on core 0 fed the workers on cores 1, 2 and 3, each of them
  [ok] every sample built once; the sorted checksum equals the reference (4189534b)
-- part C: the callbacks' period in microseconds: 5000 -293 .. 189 us
  [ok] the period within 20000 us of 5 ms
-- part B: one-shot, stop, restart
  one-shot of 10 ticks: 1 callback, 10 ticks after start; then stop () EAGAIN (not running)
  [ok] a one-shot calls back once, at its time, and completes
  started, stopped after 3 ticks (stop () ok): 0 callbacks
  [ok] a timer stopped before its time never calls back
  periodic of 4 ticks for 14: 3 callbacks; restarted with 7 for 22: 3
  [ok] a periodic timer restarted with another period keeps the new one
  [ok] heap back to 0 B
RESULT: PASS (a periodic timer, exact to the tick, its callbacks on core 0 feeding workers on cores 1-3; one-shot, stop, restart; four CPUs)
```
