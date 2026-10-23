# Lesson 11 (Zig) — Message queues: a pipeline, priorities, timeouts

## 1. Theory

### Data, not just a signal

A semaphore says "something is ready"; a **message queue** hands over the
thing itself. It is a bounded FIFO of fixed-size messages, with the
synchronisation built in:

- **send** copies a message into the queue, blocking while it is full;
- **receive** copies the oldest message out, blocking while it is empty.

So a producer and a consumer need nothing else between them — no shared
buffer, no indices, no lock: the queue *is* the bounded buffer of lessons 07
and 09, and the copy means each side owns its own data. The cost is the copy,
so messages are small (an id, a pointer, a handful of fields), never the bulk
data itself.

### A pipeline

Stages connected by queues form a **pipeline**: each stage receives from
the queue before it, does its part, and sends to the queue after it. Each
queue absorbs the difference in speed between its two stages; when the
slowest stage falls behind, the queues before it fill and the faster stages
block on send — back-pressure travels upstream, exactly as far as it must.

### Priorities

Each message carries a **priority**. A receive takes the highest-priority
message in the queue; among equal priorities, the oldest. So an urgent
message sent after a dozen normal ones is taken before them — it
**overtakes** what is still waiting — while messages of one priority keep
their order. (The priority is the message's, not the thread's: it orders the
queue, not the scheduler.)

### Waiting with a limit

`try_send` / `try_receive` never block (`EWOULDBLOCK` on a full / empty
queue); `timed_send` / `timed_receive` wait at most a given time
(`ETIMEDOUT`). The non-blocking send is what an interrupt handler uses: it
cannot wait for room, so it tries, and counts a refusal.

### Several CPUs

With one stage per core the pipeline runs in parallel: every message
crosses a core, and the queues are what makes that safe — the copy in and
out happens under the kernel's lock, and a receiver blocked on another core
is woken by the cross-core interrupt (lesson 04).

## 2. In µOS++ (Zig)

- `rtos.MessageQueue`: `var q: rtos.MessageQueue = .{};` and
  `q.init("name", msgs, msg_size, &buffer, .{})`, with a static buffer of
  `rtos.mqueue.storageSize(msgs, msg_size)` bytes (no heap; `create(gpa, …)`
  takes it from an allocator). `q.send(bytes, prio)`, `q.receive(buf)`
  (returns the message's priority), `trySend`, `tryReceive`
  (`error.WouldBlock`), `timedSend(bytes, ticks, prio)`,
  `timedReceive(buf, ticks)` (`error.TimedOut`), `length()`, `capacity()`,
  `reset()`. The lesson sends `std.mem.asBytes(&msg)` and prints the C++
  names.
- `rtos.MessageQueueTyped(T)` is the typed form; its `receive()` returns the
  message but not its priority, which the lesson's `filter` needs.
- Priorities: `rtos.mqueue.Priority`, 0 (`default_priority`) to 255; higher
  first, FIFO within one priority. `trySend` may be called from an ISR.
- `micro-os-plus-iii/src/rtos/mqueue.zig`.

## 3. The lesson

**`1cpu/main.zig`.**

- *Part A, a three-stage pipeline.* `source` (`above_normal`) sends the ids
  0 … 199 to `g_q1` (4 messages), every 20th one — ids 19, 39, … 199 — with
  priority 1, the rest with 0. `filter` (`normal`) receives each with its
  priority, computes `generate(seed, id)` and sends `{id, value}` on to
  `g_q2` (8 messages) with the same priority. `sink` (`below_normal`), which
  spends 200 µs on each message, takes them in order of arrival and records
  that order. The queues fill behind the sink, so urgent messages find
  normal ones waiting.
- *Part B, the semantics.* On an 8-message queue with no receiver: send ids
  1, 2, 3 (priority 0), 100 (10), 4 (0), 101 (10), 50 (5), then receive all
  seven. Then, on the empty queue, `try_receive` and `timed_receive (10)`;
  fill it to capacity, then `try_send` and `timed_send (10)`.
- *Part C, from an interrupt.* The second timer (`tutor.second_timer`,
  lesson 03) `try_send`s 20 messages (ids 0 … 19) to a 4-message queue, one
  every 2 ms; a `high` waiter receives them and measures each from its
  interrupt.

**`4cpu/main.zig`** first releases cores 1–3, then runs one stage per
core — `source` on core 1, `filter` on core 2, `sink` on core 3 — and in
part C the waiter on core 2 while the ISR runs on core 0.

### Files in the build

The same files as lesson 01 (see `../01-bring-up/README.md`, *Files in the
build*), with this lesson's own source in place of lesson 01's:

- `micro-os-plus-iii-aarch64/test/tutor/11-message-queue/1cpu/main.zig` (or `4cpu/main.zig`)
- `micro-os-plus-iii-aarch64/test/tutor/common/tutor.zig` (`second_timer`, `onHardware()`)
- `micro-os-plus-iii-aarch64/test/start.zig` (the `uos_external_irq` forwarder, for part C)
- the port (`micro-os-plus-iii-aarch64/src/port.zig`), the board (`micro-os-plus-iii-aarch64/boards/rpi4b/startup.S`, `board.zig`, `linker.ld`) and the kernel (`micro-os-plus-iii/src/rtos/mqueue.zig`, and the rest of `micro-os-plus-iii/src/`)
- `micro-os-plus-iii-aarch64/build.zig` — the entries `tutor-11-message-queue-1cpu` and `-4cpu`

## 4. The test

PASS when, in both versions:

- all 200 ids arrived exactly once; the normal ids in increasing order, the
  urgent ids in increasing order; at least one urgent id was taken before a
  smaller normal id still waiting; the values' sorted checksum equals
  `reference(seed, 0, 200)`; (4 CPUs) each stage ran on its core;
- the seven messages came out as 100 101 50 1 2 3 4; `try_receive` on the
  empty queue and `try_send` on the full one returned `EWOULDBLOCK`;
  `timed_receive (10)` and `timed_send (10)` returned `ETIMEDOUT` after 10
  ticks;
- all 20 messages sent by the ISR were taken, in order, each within 1 ms on
  the board (20 ms under QEMU); (4 CPUs) the ISR on core 0, the waiter on
  core 2;
- the heap is back to its level; (4 CPUs) cores 1–3 joined.

## 5. Running it

As lesson 01 (see `../01-bring-up/README.md`, *Running it*); from
`micro-os-plus-iii-aarch64`:

```sh
cd micro-os-plus-iii-aarch64
export PATH=$HOME/zig-x86_64-linux-0.17.0:$PATH
zig build -Dtest=tutor-11-message-queue-1cpu
zig build -Dtest=tutor-11-message-queue-4cpu
zig build -Dtest=tutor-11-message-queue-1cpu run    # QEMU
zig build -Dtest=tutor-11-message-queue-4cpu run
test/run-all.sh tutor-11-message-queue-1cpu          # the board
test/run-all.sh tutor-11-message-queue-4cpu
```

## 6. Results

Both versions PASS under QEMU and on the board (2026-10-23): 15 s and 14 s
on the board. Under QEMU the numbers are the C++ lesson's: all 10 urgent
ids overtook, part B came out as 100 101 50 1 2 3 4, every ISR message was
taken in order. See [`RESULTS.md`](RESULTS.md).
