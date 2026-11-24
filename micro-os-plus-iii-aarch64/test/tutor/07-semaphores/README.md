# Lesson 07 (Zig) — Semaphores: counting resources, a bounded buffer, a post from an interrupt

## 1. Theory

### A counter that threads can wait on

A **semaphore** is a counter with two operations: **post** adds one, and
**wait** takes one — or, when the counter is zero, blocks the thread until
somebody posts. Unlike a mutex it has **no owner**: any thread may post it,
and so may an interrupt handler, because post never blocks. That makes it
the natural way to *signal* — "something happened", "a slot is free", "data
is ready" — rather than to protect.

- A **counting** semaphore counts resources: its value is how many are
  available, up to a maximum.
- A **binary** semaphore is one with a maximum of 1: a flag, set by a post,
  cleared by a wait. A second post before a wait is lost (refused).

### The bounded buffer

The classic producer/consumer: a producer makes items, a consumer uses them,
and a buffer of **N** slots lies between them, so that each can run at its
own pace without losing items and without unbounded memory. Two counting
semaphores make it work:

- `slots`, starting at N: the producer waits on it before filling a slot,
  the consumer posts it after emptying one;
- `items`, starting at 0: the consumer waits on it before emptying a slot,
  the producer posts it after filling one.

When the buffer is full the producer blocks on `slots` — **back-pressure**:
a fast producer is slowed down to the consumer's pace, never more than N
items are in flight. When it is empty the consumer blocks on `items`. The
ring's two indices are shared data; a binary semaphore used as a lock (or a
mutex) guards them.

### Waiting with a limit, and the errors

`try_wait` takes it only if the counter is above zero (otherwise
`EWOULDBLOCK` at once); `timed_wait (t)` waits at most `t` ticks
(`ETIMEDOUT`); a post at the maximum is refused (`EAGAIN`).

### From an interrupt

An ISR must not block, so it cannot take a mutex — but it can post a
semaphore. This is the standard way an interrupt hands work to a thread
(lesson 03 used it): the ISR posts, a thread waiting on the semaphore runs
the work. A counting semaphore keeps every post, even when the thread falls
behind; a binary one would merge posts that come before the thread waits.

### Several CPUs

The producer and the consumer on two cores run **at the same time**: every
post wakes a thread on the other core (the cross-core IPI of lesson 04). The
buffer then rarely fills: the consumer is not waiting for the CPU, only for
data.

## 2. In µOS++ (Zig)

- `rtos.Semaphore`: `.counting("name", max, initial)`, `.binary("name",
  initial)`.
- `sem.post()` (allowed in an ISR; `error.Again` at the maximum),
  `sem.wait()`, `sem.tryWait()` (`error.WouldBlock`), `sem.timedWait(ticks)`
  (`error.TimedOut`), `sem.value()`; the lesson prints the C++ names
  (`EAGAIN`, `EWOULDBLOCK`, `ETIMEDOUT`).
- `micro-os-plus-iii/src/rtos/semaphore.zig`.

## 3. The lesson

**`1cpu/main.zig`.**

- *Part A, the pipeline.* `producer` (`above_normal`) builds 400 samples
  (ids 0 .. 399, `g_items[]` in the data segment) and passes a pointer to
  each through `g_ring[8]`, with `g_slots` (counting, 8), `g_full` (counting,
  starting at 0) and `g_ring_lock` (binary) around the indices; it counts
  the times it found the buffer full (a `try_wait` that failed before the
  `wait`) and the most items ever in flight. `consumer` (`normal`) takes
  them, checks each id is the next one and its seal intact, and pushes it on
  its own list. Because the producer runs above the consumer, it fills the
  buffer until it blocks: exactly 8 in flight.
- *Part B, the semantics.* A counting semaphore of maximum 3: 3 posts, a 4th
  `EAGAIN`, value 3; 3 `try_wait`s, a 4th `EWOULDBLOCK`; `timedWait(10)`
  `ETIMEDOUT` after 10 ticks. A binary semaphore: post, then a second post
  `EAGAIN`.
- *Part C, from an interrupt.* The second timer (`tutor.second_timer`,
  lesson 03) posts `g_irq_sem` 50 times, every 2 ms, from its ISR; a `high`
  waiter takes the 50 and measures each from its interrupt.

**`4cpu/main.zig`** first releases cores 1–3, then runs the producer on
core 1 and the consumer on core 2 (part A), and in part C the waiter on
core 2 while the ISR runs on core 0 (the main thread starts the timer on
its own core): every wake-up crosses cores.

### Files in the build

The same files as lesson 01 (see `../01-bring-up/README.md`, *Files in the
build*), with this lesson's own source in place of lesson 01's:

- `micro-os-plus-iii-aarch64/test/tutor/07-semaphores/1cpu/main.zig` (or `4cpu/main.zig`)
- `micro-os-plus-iii-aarch64/test/tutor/common/tutor.zig` (`second_timer`, `onHardware()`)
- `micro-os-plus-iii-aarch64/test/start.zig` (the `uos_external_irq` forwarder, for part C)
- the port (`micro-os-plus-iii-aarch64/src/port.zig` — the dispatcher, the reschedule from an ISR), the board (`micro-os-plus-iii-aarch64/boards/rpi4b/startup.S`, `board.zig`, `linker.ld`) and the kernel (`micro-os-plus-iii/src/rtos/semaphore.zig`; `thread.zig` — `resume()` and its cross-core IPI; and the rest of `micro-os-plus-iii/src/`)
- `micro-os-plus-iii-aarch64/build.zig` — the entries `tutor-07-semaphores-1cpu` and `-4cpu`

## 4. The test

PASS when, in both versions:

- all 400 samples were consumed, in order, their seals intact, and the
  consumed list's sorted checksum equals `reference(seed, 0, 400)`;
- (1 CPU) the buffer filled to exactly 8 and the producer had to wait;
  (4 CPUs) never more than 8 in flight;
- the counting semaphore refused a post beyond 3 (`EAGAIN`) and a
  `try_wait` at zero (`EWOULDBLOCK`); `timedWait(10)` timed out after 10
  ticks; the binary semaphore refused a second post;
- every one of the 50 posts from the ISR was taken, each within 1 ms on the
  board (20 ms under QEMU); the ISR ran on core 0 (4 CPUs: the waiter on
  core 2);
- the heap is back to its level; (4 CPUs) cores 1–3 joined.

## 5. Running it

As lesson 01 (see `../01-bring-up/README.md`, *Running it*); from
`micro-os-plus-iii-aarch64`:

```sh
cd micro-os-plus-iii-aarch64
export PATH=$HOME/zig-x86_64-linux-0.17.0:$PATH
zig build -Dtest=tutor-07-semaphores-1cpu
zig build -Dtest=tutor-07-semaphores-4cpu
zig build -Dtest=tutor-07-semaphores-1cpu run    # QEMU
zig build -Dtest=tutor-07-semaphores-4cpu run
test/run-all.sh tutor-07-semaphores-1cpu          # the board
test/run-all.sh tutor-07-semaphores-4cpu
```

## 6. Results

Both versions PASS under QEMU and on the board (2026-10-23): 15 s and 14 s
on the board, the four-CPU run straight after the one-CPU one (no core-3
fault since lesson 06's linker fix). Under QEMU the one-CPU numbers are the
C++ lesson's to the unit: 8 in flight, the buffer found full 392 times. See
[`RESULTS.md`](RESULTS.md).
