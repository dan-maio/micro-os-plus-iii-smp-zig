# Lesson 10 (Zig) — Results

| Version | QEMU (`raspi4b`) | Board (Raspberry Pi 4 B, `test/run-all.sh`) |
|---|---|---|
| `tutor-10-flags-1cpu` | PASS | PASS, 15 s |
| `tutor-10-flags-4cpu` | PASS | PASS, 14 s (straight after the one-CPU run) |

Run on 2026-10-23, with the `resumeAll()` fix this lesson led to (README,
*What this lesson found in the kernel*). The board's verdict lines:

```
RESULT: PASS (generate -> sort -> max in order, started by flags; any/all, clear, timed_wait; ISR flags taken; one CPU)
RESULT: PASS (generate -> sort -> max in order across cores, started by flags; any/all, clear, timed_wait; ISR flags taken across cores; four CPUs)
```

On the board the Zig images send only the verdict lines to semihosting;
the console is on the UART. Under QEMU the one-CPU run gives the C++
lesson's numbers; with four CPUs the generators' order depends on timing
(here 1 3 2 4). The C++ lesson's board consoles show the latencies: ISR →
waiter 1 µs on one core, 2 µs across cores.

The full consoles below are the QEMU runs.

## One CPU (QEMU)

```
+== RPi 4 B µOS++ tutorial (Zig) : 10 flags (1 CPU) ==+
Lesson 10, one CPU: event flags (any/all, auto-clear) and thread flags.
-- part A: 4 generators -> sort -> max, each phase started by flags
  order: generators ended at 1 2 3 4; sort 5..6 (flags 0xf); max 7..8
  72 samples sorted, max 9852 (#34), checksum 0d0fe389
  [ok] sort started after all 4 generators had raised their bit
  [ok] max started after sort had raised its thread flag
  [ok] 72 samples sorted; checksum and max equal the reference
-- part B: any and all, the auto-clear, timed_wait, one raise and two waiters
  0x1 raised: try_wait(0x3, all) EWOULDBLOCK; try_wait(0x3, any) ok, got 0x1, still set 0x1; with clear ok, then 0x0
  [ok] all waits for every bit, any for one of them
  [ok] without clear the flags stay; with clear they are taken
  timed_wait(0x4, 10): ETIMEDOUT after 10 ticks
  [ok] timed_wait: ETIMEDOUT after 10 ticks
  two waiters, one raise: with clear 1 took it (2 after a second raise, 0x0 left); without clear 2 (0x8 left)
  [ok] with clear one raise wakes one taker: the flag is consumed
  [ok] without clear one raise wakes both, and the flag stays set
  thread flags are per thread: main's own try_wait(1) EWOULDBLOCK
  [ok] a thread flag raised for another thread is not seen by main
-- part C: the second timer's ISR raises a thread flag 20 times, every 2000 us
  raised 20, taken 20; ISR on core mask 1, waiter on core 0; ISR -> waiter max 61 us
  [ok] every flag raised by the ISR taken (20)
  [ok] each within 20000 us of its interrupt
  [ok] heap back to 0 B
RESULT: PASS (generate -> sort -> max in order, started by flags; any/all, clear, timed_wait; ISR flags taken; one CPU)
```

## Four CPUs (QEMU)

```
+== RPi 4 B µOS++ tutorial (Zig) : 10 flags (4 CPU) ==+
Lesson 10, four CPUs: event flags (any/all, auto-clear) and thread flags.
  cores joined after 0 ms: c1=3 c2=3 c3=3
  [ok] cores 1-3 joined the scheduler
-- part A: 4 generators (cores 1, 2, 3, 0) -> sort (core 2) -> max (core 3), each phase started by flags
  order: generators ended at 1 3 2 4; sort 5..6 (flags 0xf); max 7..8
  72 samples sorted, max 9852 (#34), checksum 0d0fe389
  [ok] sort started after all 4 generators had raised their bit
  [ok] max started after sort had raised its thread flag
  [ok] the generators on cores 1, 2, 3, 0, sort on core 2, max on core 3
  [ok] 72 samples sorted; checksum and max equal the reference
-- part B: any and all, the auto-clear, timed_wait, one raise and two waiters
  0x1 raised: try_wait(0x3, all) EWOULDBLOCK; try_wait(0x3, any) ok, got 0x1, still set 0x1; with clear ok, then 0x0
  [ok] all waits for every bit, any for one of them
  [ok] without clear the flags stay; with clear they are taken
  timed_wait(0x4, 10): ETIMEDOUT after 10 ticks
  [ok] timed_wait: ETIMEDOUT after 10 ticks
  two waiters, one raise: with clear 1 took it (2 after a second raise, 0x0 left); without clear 2 (0x8 left)
  [ok] with clear one raise wakes one taker: the flag is consumed
  [ok] without clear one raise wakes both, and the flag stays set
  thread flags are per thread: main's own try_wait(1) EWOULDBLOCK
  [ok] a thread flag raised for another thread is not seen by main
-- part C: the second timer's ISR raises a thread flag 20 times, every 2000 us, ISR on core 0, waiter on core 2
  raised 20, taken 20; ISR on core mask 1, waiter on core 2; ISR -> waiter max 267 us
  [ok] every flag raised by the ISR taken (20)
  [ok] each within 20000 us of its interrupt
  [ok] the ISR on core 0, the waiter woken on core 2 (cross-core)
  [ok] heap back to 0 B
RESULT: PASS (generate -> sort -> max in order across cores, started by flags; any/all, clear, timed_wait; ISR flags taken across cores; four CPUs)
```
