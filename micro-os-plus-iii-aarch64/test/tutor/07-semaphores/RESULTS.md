# Lesson 07 (Zig) — Results

| Version | QEMU (`raspi4b`) | Board (Raspberry Pi 4 B, `test/run-all.sh`) |
|---|---|---|
| `tutor-07-semaphores-1cpu` | PASS | PASS, 15 s |
| `tutor-07-semaphores-4cpu` | PASS | PASS, 14 s (straight after the one-CPU run) |

Run on 2026-10-23. The board's verdict lines:

```
RESULT: PASS (400 samples through 8 slots in order, semaphore semantics, every ISR post taken; one CPU)
RESULT: PASS (400 samples through 8 slots across cores in order, semaphore semantics, every ISR post taken across cores; four CPUs)
```

On the board the Zig images send only the verdict lines to semihosting;
the console is on the UART. Under QEMU the one-CPU run gives the C++
lesson's numbers (8 in flight, the buffer full 392 times); with four CPUs
the counts depend on timing (here 8 in flight, 112 times full: QEMU's cores
are host threads; the C++ board run had at most 2 in flight). The C++
lesson's board consoles show the latencies: ISR → waiter 2 µs on one core,
3 µs across cores.

The full consoles below are the QEMU runs.

## One CPU (QEMU)

```
+== RPi 4 B µOS++ tutorial (Zig) : 07 semaphores (1 CPU) ==+

Lesson 07, one CPU: binary and counting semaphores, a bounded buffer, a post from an ISR.
  .data   00093798 .. 00096cd8
  heap    0091a000 .. 3b400000
  stack   000a3210 .. 000b3208 (thread main)

-- part A: a producer passes 400 samples to a consumer through 8 slots
  consumed 400, out of order 0; at most 8 in flight; the producer found the buffer full 392 times
  [ok] every sample consumed, in order (400)
  [ok] the consumed samples' sorted checksum equals the reference (6b2e98af)
  [ok] back-pressure: the buffer filled to its 8 slots and the producer waited

-- part B: counting (max 3) and binary semaphores
  counting: 3 posts ok, a 4th EAGAIN, value 3; 3 try_waits ok, a 4th EWOULDBLOCK; timed_wait(10) ETIMEDOUT after 10 ticks
  [ok] counting: up to its maximum, then EAGAIN
  [ok] counting: 3 taken, then try_wait EWOULDBLOCK
  [ok] timed_wait(10): ETIMEDOUT after 10 ticks
  binary: post ok, post again EAGAIN (it is a flag: one pending at most)
  [ok] binary: a second post before a wait is refused (EAGAIN)

-- part C: the second timer's ISR posts 50 times, every 2000 us
  posted 50, taken 50; ISR on core mask 1, waiter on core 0; ISR -> waiter max 94 us
  [ok] every post from the ISR taken (50)
  [ok] each within 20000 us of its interrupt
  [ok] the ISR ran on core 0
  [ok] heap back to 0 B
RESULT: PASS (400 samples through 8 slots in order, semaphore semantics, every ISR post taken; one CPU)
```

## Four CPUs (QEMU)

```
+== RPi 4 B µOS++ tutorial (Zig) : 07 semaphores (4 CPU) ==+

Lesson 07, four CPUs: binary and counting semaphores, a bounded buffer, a post from an ISR.
  .data   00094648 .. 00097ec0
  heap    00927000 .. 3b400000
  stack   000b0530 .. 000c0520 (thread main)
core 0: releasing core 1...
core 0: releasing core 2...
core 0: releasing core 3...
  cores joined after 0 ms: c1=3 c2=3 c3=3
  [ok] cores 1-3 joined the scheduler

-- part A: a producer passes 400 samples to a consumer through 8 slots, producer on core 1, consumer on core 2
  consumed 400, out of order 0; at most 8 in flight; the producer found the buffer full 112 times
  [ok] every sample consumed, in order (400)
  [ok] the consumed samples' sorted checksum equals the reference (6b2e98af)
  [ok] never more than 8 in flight

-- part B: counting (max 3) and binary semaphores
  counting: 3 posts ok, a 4th EAGAIN, value 3; 3 try_waits ok, a 4th EWOULDBLOCK; timed_wait(10) ETIMEDOUT after 10 ticks
  [ok] counting: up to its maximum, then EAGAIN
  [ok] counting: 3 taken, then try_wait EWOULDBLOCK
  [ok] timed_wait(10): ETIMEDOUT after 10 ticks
  binary: post ok, post again EAGAIN (it is a flag: one pending at most)
  [ok] binary: a second post before a wait is refused (EAGAIN)

-- part C: the second timer's ISR posts 50 times, every 2000 us, ISR on core 0, waiter on core 2
  posted 50, taken 50; ISR on core mask 1, waiter on core 2; ISR -> waiter max 111 us
  [ok] every post from the ISR taken (50)
  [ok] each within 20000 us of its interrupt
  [ok] the ISR on core 0, the waiter woken on core 2 (cross-core)
  [ok] heap back to 0 B
RESULT: PASS (400 samples through 8 slots across cores in order, semaphore semantics, every ISR post taken across cores; four CPUs)
```
