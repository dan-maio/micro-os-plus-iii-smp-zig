# Lesson 14 (Zig) — Results

| Version | QEMU (`raspi4b`) | Board (Raspberry Pi 4 B, `test/run-all.sh`) |
|---|---|---|
| `tutor-14-interrupts-1cpu` | PASS | PASS, 14 s |
| `tutor-14-interrupts-4cpu` | PASS | PASS, 14 s (straight after the one-CPU run) |

Run on 2026-10-23. The board's verdict lines:

```
RESULT: PASS (the tick and a second interrupt update one counter, nothing lost, every post taken; interrupt latency longer by the critical section held; one CPU)
RESULT: PASS (two interrupts and a thread on another core: no update lost; latency longer by the section held; routed to each core; one core's lock does not mask another's interrupts; four CPUs)
```

On the board the Zig images send only the verdict lines to semihosting;
the console is on the UART. The board's numbers are in the C++ lesson's
results (the interrupt 302 µs late behind the section; core 1's plain
handler 3–5 runs inside core 0's section, the one taking it 0). The four-CPU
summary was shortened: the first one, 254 characters, overflowed the
console's line buffer and cut the verdict line.

The full consoles below are the QEMU runs.

## One CPU (QEMU)

```
+== RPi 4 B µOS++ tutorial (Zig) : 14 interrupts (1 CPU) ==+
Lesson 14, one CPU: interrupt handlers, what they may call, the latency they see.
-- part A: the tick (a 2-tick timer, 100 calls) and the second timer (1500 us, 130 calls) update one counter, the main thread adds 2000
  counter 2230 (expected 2230: tick 100 + second timer 130 + thread 2000); in handler mode 100 and 130; posts taken 100 and 130
  [ok] no update lost (2230)
  [ok] both callbacks ran in handler mode: the timer's in the tick interrupt
  [ok] every post from both interrupts woke its waiter
-- part B: the second timer every 1000 us, 50 times; its latency against exact due times
  free: interrupt late by at most 0 us, thread 17 us after it; a 0.8 ms interrupt section covering each due time by 0.3 ms: interrupt late by 413 us, thread 16 us after it
  [ok] free: the interrupt on time and the thread right after it (within 20000 us)
  [ok] held: the interrupt late by the rest of the critical section (about 300 us)
  [ok] held: the thread still right after its interrupt
  [ok] heap back to 0 B
RESULT: PASS (the tick and a second interrupt update one counter, nothing lost, every post taken; interrupt latency longer by the critical section held; one CPU)
```

## Four CPUs (QEMU)

```
+== RPi 4 B µOS++ tutorial (Zig) : 14 interrupts (4 CPU) ==+
Lesson 14, four CPUs: interrupt handlers, what they may call, the latency they see.
  cores joined after 0 ms: c1=3 c2=3 c3=3
  [ok] cores 1-3 joined the scheduler
-- part A: the tick (a 2-tick timer, 100 calls) and the second timer (1500 us, 130 calls) update one counter, a thread on core 3 adds 2000
  counter 2230 (expected 2230: tick 100 + second timer 130 + thread 2000); in handler mode 100 and 130; posts taken 100 and 130
  [ok] no update lost (2230)
  [ok] both callbacks ran in handler mode: the timer's in the tick interrupt
  [ok] every post from both interrupts woke its waiter
  [ok] the interrupts on core 0, the adder on core 3, the waiters on cores 1 and 2
-- part B: the second timer every 1000 us, 50 times; its latency against exact due times
  free: interrupt late by at most 0 us, thread 51 us after it; a 0.8 ms interrupt section covering each due time by 0.3 ms: interrupt late by 401 us, thread 46 us after it
  [ok] free: the interrupt on time and the thread right after it (within 20000 us)
  [ok] held: the interrupt late by the rest of the critical section (about 300 us)
  [ok] held: the thread (on core 2) still right after its interrupt
-- part C: the second timer routed to cores 1, 2, 3; core 0's interrupt section and core 1's handler
  armed on core 1: 41 interrupts, core mask 2; on core 2: 39, 4; on core 3: 39, 8
  [ok] the handler ran on the core that armed the timer, each in turn
  core 0 in an interrupt section, core 1's handler every 100 us: plain, 0.5 ms section: 5 runs inside; plain, 2.5 ms: 6 inside (of 25); taking the section itself, 0.5 ms: 0 inside, 23 after
  [ok] core 0's interrupt lock does not mask core 1's interrupts
  [ok] but a handler on core 1 that takes the section waits for core 0's (the kernel spinlock)
  [ok] heap back to 0 B
RESULT: PASS (two interrupts and a thread on another core: no update lost; latency longer by the section held; routed to each core; one core's lock does not mask another's interrupts; four CPUs)
```
