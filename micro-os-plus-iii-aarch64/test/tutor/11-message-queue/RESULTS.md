# Lesson 11 (Zig) — Results

| Version | QEMU (`raspi4b`) | Board (Raspberry Pi 4 B, `test/run-all.sh`) |
|---|---|---|
| `tutor-11-message-queue-1cpu` | PASS | PASS, 15 s |
| `tutor-11-message-queue-4cpu` | PASS | PASS, 14 s (straight after the one-CPU run) |

Run on 2026-10-23. The board's verdict lines:

```
RESULT: PASS (3-stage pipeline: every id once, in order per priority, urgent ones overtake; priorities, timeouts; ISR messages taken; one CPU)
RESULT: PASS (3-stage pipeline, one stage per core: every id once, in order per priority, urgent ones overtake; priorities, timeouts; ISR messages taken across cores; four CPUs)
```

On the board the Zig images send only the verdict lines to semihosting;
the console is on the UART. Under QEMU the numbers are the C++ lesson's (10
of 10 urgent ids overtook; 100 101 50 1 2 3 4; 20 ISR messages in order).
The C++ lesson's board consoles show the latencies: ISR → waiter 2 µs on one
core, 3 µs across cores.

The full consoles below are the QEMU runs.

## One CPU (QEMU)

```
+== RPi 4 B µOS++ tutorial (Zig) : 11 message queue (1 CPU) ==+
Lesson 11, one CPU: message queues, priorities, timed send and receive, a send from an ISR.
-- part A: source -> q1 (4) -> filter -> q2 (8) -> sink, 200 ids, every 20th urgent
  received 200; urgent ids taken ahead of waiting normal ones: 10 of 10; first ids taken: 0 1 2 3 4 5 6 7
  [ok] every id arrived exactly once (200)
  [ok] normal ids in order, urgent ids in order (FIFO within a priority)
  [ok] urgent messages overtook normal ones sent before them
  [ok] the values' sorted checksum equals the reference (45223666)
-- part B: priorities with no receiver; full, empty, timeouts
  sent 1 2 3 (p0) 100 (p10) 4 (p0) 101 (p10) 50 (p5); 7 queued; received 100 101 50 1 2 3 4
  [ok] highest priority first, FIFO within one priority
  empty: try_receive EWOULDBLOCK, timed_receive(10) ETIMEDOUT after 10 ticks; full (8 of 8): try_send EWOULDBLOCK, timed_send(10) ETIMEDOUT after 10 ticks
  [ok] try_receive on empty and try_send on full: EWOULDBLOCK
  [ok] timed_receive and timed_send: ETIMEDOUT after 10 ticks
-- part C: the second timer's ISR sends 20 messages with try_send, every 2000 us
  sent 20 (refused 0), taken 20, in order 20; ISR on core mask 1, waiter on core 0; ISR -> waiter max 132 us
  [ok] every message sent by the ISR taken, in order (20)
  [ok] each within 20000 us of its interrupt
  [ok] heap back to 0 B
RESULT: PASS (3-stage pipeline: every id once, in order per priority, urgent ones overtake; priorities, timeouts; ISR messages taken; one CPU)
```

## Four CPUs (QEMU)

```
+== RPi 4 B µOS++ tutorial (Zig) : 11 message queue (4 CPU) ==+
Lesson 11, four CPUs: message queues, priorities, timed send and receive, a send from an ISR.
  cores joined after 0 ms: c1=3 c2=3 c3=3
  [ok] cores 1-3 joined the scheduler
-- part A: source (core 1) -> q1 (4) -> filter (core 2) -> q2 (8) -> sink (core 3), 200 ids, every 20th urgent
  received 200; urgent ids taken ahead of waiting normal ones: 10 of 10; first ids taken: 0 1 2 3 4 5 6 7
  [ok] every id arrived exactly once (200)
  [ok] normal ids in order, urgent ids in order (FIFO within a priority)
  [ok] urgent messages overtook normal ones sent before them
  [ok] one stage per core: source 1, filter 2, sink 3
  [ok] the values' sorted checksum equals the reference (45223666)
-- part B: priorities with no receiver; full, empty, timeouts
  sent 1 2 3 (p0) 100 (p10) 4 (p0) 101 (p10) 50 (p5); 7 queued; received 100 101 50 1 2 3 4
  [ok] highest priority first, FIFO within one priority
  empty: try_receive EWOULDBLOCK, timed_receive(10) ETIMEDOUT after 10 ticks; full (8 of 8): try_send EWOULDBLOCK, timed_send(10) ETIMEDOUT after 10 ticks
  [ok] try_receive on empty and try_send on full: EWOULDBLOCK
  [ok] timed_receive and timed_send: ETIMEDOUT after 10 ticks
-- part C: the second timer's ISR sends 20 messages with try_send, every 2000 us, ISR on core 0, waiter on core 2
  sent 20 (refused 0), taken 20, in order 20; ISR on core mask 1, waiter on core 2; ISR -> waiter max 918 us
  [ok] every message sent by the ISR taken, in order (20)
  [ok] each within 20000 us of its interrupt
  [ok] the ISR on core 0, the waiter woken on core 2 (cross-core)
  [ok] heap back to 0 B
RESULT: PASS (3-stage pipeline, one stage per core: every id once, in order per priority, urgent ones overtake; priorities, timeouts; ISR messages taken across cores; four CPUs)
```
