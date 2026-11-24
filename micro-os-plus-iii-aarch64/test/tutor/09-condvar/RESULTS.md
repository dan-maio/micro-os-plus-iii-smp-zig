# Lesson 09 (Zig) — Results

| Version | QEMU (`raspi4b`) | Board (Raspberry Pi 4 B, `test/run-all.sh`) |
|---|---|---|
| `tutor-09-condvar-1cpu` | PASS | PASS, 14 s |
| `tutor-09-condvar-4cpu` | PASS | PASS, 15 s (straight after the one-CPU run) |

Run on 2026-10-23, with the two kernel fixes this lesson led to (README,
*What this lesson found in the kernel*). The board's verdict lines:

```
RESULT: PASS (400 samples through 8 slots in order with two condition variables; signal one, broadcast all, predicates; one CPU)
RESULT: PASS (400 samples through 8 slots to 3 consumers on 3 cores, done broadcast to all; signal one, broadcast all, predicates; four CPUs)
```

On the board the Zig images send only the verdict lines to semihosting;
the console is on the UART. Under QEMU the one-CPU run gives the C++
lesson's numbers (the producer waited 392 times); with four CPUs the split
between the consumers depends on timing. The C++ lesson's board consoles
show the board's numbers (167 / 113 / 120 samples on cores 2 / 3 / 0).

The full consoles below are the QEMU runs.

## One CPU (QEMU)

```
+== RPi 4 B µOS++ tutorial (Zig) : 09 condvar (1 CPU) ==+
Lesson 09, one CPU: condition variables, predicates, signal and broadcast.
-- part A: a producer passes 400 samples to a consumer through 8 slots: a mutex and two condition variables
  consumed 400, out of order 0; at most 8 in flight; the producer waited 392 times, the consumer 0
  [ok] every sample consumed, in order (400)
  [ok] the consumed samples' sorted checksum equals the reference (6b2e98af)
  [ok] the buffer filled to its 8 slots and the producer waited on not_full
-- part B: 3 waiters wait for a token; signal () with one, broadcast () with two
  3 waiting; signal (): 1 woken, 1 token taken, 0 re-checks; broadcast (): 3 woken, 2 tokens taken, 2 re-checks
  [ok] 3 waiters in wait ()
  [ok] signal () wakes one waiter
  [ok] broadcast () wakes all 3; two take a token
  [ok] a waiter woken with no token left finds its predicate false and waits again
-- part C: a condition variable has no memory; the predicate has
  signal () with nobody waiting, then timed_wait (10): ETIMEDOUT after 10 ticks, mutex locked again; a semaphore posted first: timed_wait ok
  [ok] a signal with nobody waiting is lost (ETIMEDOUT)
  [ok] timed_wait () returns with the mutex locked again
  [ok] a semaphore's post is kept
  the predicate set and signalled before the waiter came: it waited 0 times, owned the mutex: yes
  [ok] a late waiter finds the predicate true and does not wait (no lost wake-up)
  [ok] heap back to 0 B
RESULT: PASS (400 samples through 8 slots in order with two condition variables; signal one, broadcast all, predicates; one CPU)
```

## Four CPUs (QEMU)

```
+== RPi 4 B µOS++ tutorial (Zig) : 09 condvar (4 CPU) ==+
Lesson 09, four CPUs: condition variables, predicates, signal and broadcast.
  cores joined after 0 ms: c1=3 c2=3 c3=3
  [ok] cores 1-3 joined the scheduler
-- part A: a producer on core 1 passes 400 samples through 8 slots to 3 consumers on cores 2, 3 and 0: a mutex and two condition variables
  consumed 400 (107 on core 2, 170 on core 3, 123 on core 0), out of order 0; at most 7 in flight; the producer waited 0 times, the consumers 282
  [ok] every sample consumed once (400), each consumer's in increasing order
  [ok] all 3 consumers joined after the broadcast of `done` (no lost wake-up)
  [ok] the consumed samples' sorted checksum equals the reference (6b2e98af)
  [ok] never more than 8 in flight
-- part B: 3 waiters on cores 1, 2 and 3 wait for a token; signal () with one, broadcast () with two
  3 waiting; signal (): 1 woken, 1 token taken, 0 re-checks; broadcast (): 3 woken, 2 tokens taken, 2 re-checks
  [ok] 3 waiters in wait ()
  [ok] signal () wakes one waiter
  [ok] broadcast () wakes all 3; two take a token
  [ok] a waiter woken with no token left finds its predicate false and waits again
-- part C: a condition variable has no memory; the predicate has
  signal () with nobody waiting, then timed_wait (10): ETIMEDOUT after 10 ticks, mutex locked again; a semaphore posted first: timed_wait ok
  [ok] a signal with nobody waiting is lost (ETIMEDOUT)
  [ok] timed_wait () returns with the mutex locked again
  [ok] a semaphore's post is kept
  the predicate set and signalled before the waiter came: it waited 0 times, owned the mutex: yes
  [ok] a late waiter finds the predicate true and does not wait (no lost wake-up)
  [ok] heap back to 0 B
RESULT: PASS (400 samples through 8 slots to 3 consumers on 3 cores, done broadcast to all; signal one, broadcast all, predicates; four CPUs)
```
