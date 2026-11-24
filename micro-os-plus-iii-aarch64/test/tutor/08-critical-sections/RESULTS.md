# Lesson 08 (Zig) — Results

| Version | QEMU (`raspi4b`) | Board (Raspberry Pi 4 B, `test/run-all.sh`) |
|---|---|---|
| `tutor-08-critical-sections-1cpu` | PASS | PASS, 15 s |
| `tutor-08-critical-sections-4cpu` | PASS | PASS, 14 s (straight after the one-CPU run) |

Run on 2026-10-23. The board's verdict lines:

```
RESULT: PASS (the scheduler lock loses ISR updates and delays threads, the interrupt lock loses none and delays the ISR; one CPU)
RESULT: PASS (updates lost under the per-core scheduler lock, none under the interrupt lock and spinlock; core 0's sections and the other cores; four CPUs)
```

On the board the Zig images send only the verdict lines to semihosting;
the console is on the UART. The C++ lesson's board consoles show the
numbers on real cores: with one CPU 118 / 117 / 0 updates lost, the ISR's
gap 100 µs under the scheduler lock and 1001 µs under the interrupt lock,
a thread on the same core 1002 µs late under the scheduler section, 2 µs
on core 2 with four.

The full consoles below are the QEMU runs.

## One CPU (QEMU)

```
+== RPi 4 B µOS++ tutorial (Zig) : 08 critical sections (1 CPU) ==+
Lesson 08, one CPU: scheduler and interrupt critical sections, what each excludes and costs.
  .data   000945d0 .. 000948e0
  heap    00910000 .. 3b400000
  stack   00099210 .. 000a9208 (thread main)
-- part A: a thread and an ISR (every 100 us) update one counter; 400 updates, a 30 us window each
  no lock       : thread 400 + ISR 221 = 621 expected, counter 510, lost 111
  scheduler lock: thread 400 + ISR 222 = 622 expected, counter 495, lost 127
  interrupt lock: thread 400 + ISR 224 = 624 expected, counter 624, lost 0
  [ok] no lock: the ISR's updates in the window are lost (111)
  [ok] scheduler lock: still lost (127): it does not stop interrupts
  [ok] interrupt lock: none lost
-- part B: inside each section, the ISR (every 100 us) and a high thread made ready
  scheduler section, 2 ms: ISR ran 23 times, high thread 0 times inside, 1 after; locked() true inside, false after; inside an uncritical section the thread ran 1
  [ok] scheduler section: interrupts keep running
  [ok] scheduler section: no switch inside, the high thread runs as it ends
  [ok] scheduler::locked () true inside, false after
  [ok] scheduler uncritical section: the high thread runs at once
  interrupt section, 2 ms: ISR ran 0 times inside, 1 just after; inside an uncritical section of 1 ms it ran 10
  [ok] interrupt section: the ISR waits, and runs as it ends
  [ok] interrupt uncritical section: the ISR runs inside
-- part C: the cost: the ISR's longest gap (period 100 us), main in 1 ms sections
  ISR gap max: no lock 229 us, scheduler lock 112 us, interrupt lock 1087 us
  [ok] the interrupt lock delays it by the section (gap >= 900 us)
-- part C: a high thread woken by the ISR (every 2000 us), 5 times under each
  ISR -> thread max: no lock 121 us, scheduler section (1 ms) 1022 us, interrupt section 18 us (the ISR itself 30 us after the section's end)
  [ok] no lock: the thread within 20000 us
  [ok] scheduler section: the thread waits for its end (>= 1000 us)
  [ok] interrupt section: the ISR waits for its end, then the thread at once
  [ok] heap back to 0 B
RESULT: PASS (the scheduler lock loses ISR updates and delays threads, the interrupt lock loses none and delays the ISR; one CPU)
```

## Four CPUs (QEMU)

```
+== RPi 4 B µOS++ tutorial (Zig) : 08 critical sections (4 CPU) ==+
Lesson 08, four CPUs: scheduler and interrupt critical sections, what each excludes and costs.
  .data   00095858 .. 00095ea0
  heap    0091d000 .. 3b400000
  stack   000a6530 .. 000b6520 (thread main)
  cores joined after 0 ms: c1=3 c2=3 c3=3
  [ok] cores 1-3 joined the scheduler
-- part A: threads on cores 1 and 2 and an ISR on core 0 (every 100 us) update one counter; 2 x 200 updates, a 30 us window each
  no lock       : threads 2 x 200 + ISR 129 = 529 expected, counter 263, lost 266
  scheduler lock: threads 2 x 200 + ISR 116 = 516 expected, counter 252, lost 264
  interrupt lock: threads 2 x 200 + ISR 96 = 496 expected, counter 496, lost 0
  [ok] no lock: updates are lost (266)
  [ok] scheduler lock: still lost (264): it holds one core only
  [ok] interrupt lock (and the kernel spinlock): none lost
-- part B: core 0 in a section; high threads on cores 0 and 1, an interrupt-section loop on core 1, a free loop on core 2
  core 0 scheduler section, 2 ms: core 0's ISR ran 23 times; inside, the high thread on core 1 ran 1, on core 0 0 (1 after)
  [ok] scheduler section: core 0's interrupts keep running
  [ok] scheduler section: core 1 switches at once, core 0 only as the section ends
  core 0 interrupt section, 2 ms: core 0's ISR ran 0, core 1's locked loop 0, core 2's free loop 88 (core 1 36 just after)
  inside an interrupt uncritical section of 1 ms: core 0's ISR ran 10, core 1's locked loop 0
  [ok] interrupt section: core 0's ISR and core 1's locked loop stop, core 2's free loop runs
  [ok] core 1 enters as the section ends
  [ok] interrupt uncritical section: core 0's ISR runs, the spinlock is kept (core 1 still waits)
-- part C: the cost: core 0's ISR's longest gap (period 100 us), main in 1 ms sections on core 0
  ISR gap max: no lock 111 us, scheduler lock 116 us, interrupt lock 1089 us
  [ok] the interrupt lock delays it by the section (gap >= 900 us)
-- part C: a high thread on core 2 woken by core 0's ISR (every 2000 us), 5 times under each
  ISR -> thread max: no lock 74 us, core 0 scheduler section (1 ms) 25 us, interrupt section 60 us (the ISR itself 116 us after the section's end); thread on core 2
  [ok] no lock: the thread within 20000 us
  [ok] core 0's scheduler section does not delay the thread on core 2 (within 20000 us)
  [ok] interrupt section: the ISR waits for its end, then the thread at once
  [ok] heap back to 0 B
RESULT: PASS (updates lost under the per-core scheduler lock, none under the interrupt lock and spinlock; core 0's sections and the other cores; four CPUs)
```
