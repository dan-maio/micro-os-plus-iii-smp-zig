# Lesson 14 (Zig) — Interrupts: handlers, what they may call, latency

## 1. Theory

### An interrupt handler is not a thread

A device raises an interrupt; the core stops the running thread wherever
it is, saves just enough, and runs the **interrupt service routine** (ISR).
The ISR has no stack of its own to wait on, no priority among the threads,
and the thread it interrupted cannot run until it returns. That gives the
rules:

- **never block**: no `mutex::lock`, no `sleep_for`, no `wait`, no `join` —
  in µOS++ these assert in a debug build (`EPERM` in a release one);
- **be short**: other interrupts of the same priority, and every thread of
  that core, wait;
- **hand the work over**: the ISR does the minimum (read the device, record
  the time), then wakes a thread with an **ISR-safe** call —
  `semaphore::post`, `message_queue::try_send`, `event_flags::raise`, a
  thread's `flags_raise` — and that thread does the rest at its own
  priority (lessons 07, 10, 11 used each of them).

A software timer's callback (lesson 13) is an ISR too: it runs in the tick
interrupt, under the same rules.

### Data shared with an ISR

A variable written by an ISR and by a thread — or by two ISRs — is shared
data, and the protection is the **interrupt** critical section of lesson
08: the scheduler lock does not stop an ISR. On one CPU a handler cannot be
interrupted by the thread it races; on several, the thread may run on
another core at the same instant, so the handler takes the section too —
and on an SMP kernel that section also holds the **kernel spinlock**.

### Latency

The **interrupt latency** is the time from the moment an interrupt is due
to the moment its handler runs. It is near zero — unless interrupts are
masked when it falls due: then it waits for the end of the masked stretch.
So every interrupt critical section adds its length to the worst-case
interrupt latency of its core. The **thread latency** follows: the time from
the handler's post to the woken thread running.

### Several CPUs: one core's mask, everyone's spinlock

Masking is per core: core 0's interrupt section does not mask core 1's
interrupts. But the section also holds the kernel spinlock, and the other
cores need it too — not only their handlers that take the section, but
their **schedulers**: every reschedule takes the kernel spinlock. A core
reschedules at its tick, and an idle core after every interrupt that wakes
it. So while core 0 holds an interrupt section:

- a busy thread on core 1 keeps running, and core 1's interrupts are
  served — until core 1's next tick, when its scheduler waits for the lock
  with its interrupts masked;
- a handler on core 1 that takes the interrupt section waits at once;
- an idle core 1 stops at the first interrupt.

A long interrupt section on one core is therefore felt on every core, within
a tick. Keep them a few microseconds long.

## 2. In µOS++ (Zig)

- `rtos.interrupts.inHandlerMode()` — true in an ISR or a timer callback.
- ISR-safe: `Semaphore.post()`, `MessageQueue.trySend()`,
  `EventFlags.raise()`, `Thread.flagsRaise()`, `MemoryPool.tryAlloc()` /
  `free()`; never a call that may wait.
- `const cs = rtos.interrupts.CriticalSection.enter(); defer cs.exit();`
  (lesson 08): IRQs masked on the core and the kernel spinlock held.
- The port: `micro-os-plus-iii-aarch64/src/port.zig` (the IRQ entry, the
  external-interrupt hook `uos_external_irq`, the switch that takes the
  kernel spinlock).
- The second interrupt: `tutor.second_timer` (lesson 03), the core's CNTV
  timer, PPI 27 — armed on, and interrupting, the core that calls
  `start()`. (The plan named the System Timer's C1, an interrupt the GIC
  could route to any core; QEMU's raspi4b does not wire it, so the lesson
  routes CNTV instead, by arming it from a thread pinned to each core.)

## 3. The lesson

**`1cpu/main.zig`.**

- *Part A, two interrupt sources and one counter.* A periodic software timer
  of 2 ticks (100 calls, in the tick interrupt) and the second timer every
  1.5 ms (130 calls) each add one to `g_counter` inside an interrupt critical
  section, count their own adds, note whether they run in handler mode, and
  post their own counting semaphore; a `high` waiter takes each semaphore's
  posts. Meanwhile the main thread adds 2000, each in an interrupt critical
  section, 50 µs apart.
- *Part B, the latency.* The second timer every 1 ms, 50 times; its handler
  records the System Timer's microseconds and posts a `high` waiter, which
  records its own. The first interrupt is the reference: the *i*-th is due
  `i` ms after it, and its latency is its time minus that. Once free; once
  with the main thread holding an interrupt critical section from 0.5 ms to
  1.3 ms after each interrupt — over the next due time, by 0.3 ms.

**`4cpu/main.zig`** first releases cores 1–3; in part A the interrupts run
on core 0, the 2000 adds in a thread on core 3, the waiters on cores 1 and
2; in part B the waiter on core 2. And **part C**:

- the second timer armed, 20 ms each, by a `router` thread pinned to core
  1, 2 and 3 in turn: the handler counts its runs and the cores it ran on;
- on core 1, every 100 µs, while core 0 holds an interrupt critical section
  that starts 0.3 ms after a tick: 0.5 ms long, with a plain handler (it
  takes no lock); 2.5 ms long, the same; 0.5 ms, with a handler that takes
  the interrupt critical section itself. The router **waits busy** meanwhile,
  so that core 1 is not idle (idle, it would reschedule after its first
  interrupt and stall there).

### Files in the build

The same files as lesson 01 (see `../01-bring-up/README.md`, *Files in the
build*), with this lesson's own source in place of lesson 01's:

- `micro-os-plus-iii-aarch64/test/tutor/14-interrupts/1cpu/main.zig` (or `4cpu/main.zig`)
- `micro-os-plus-iii-aarch64/test/tutor/common/tutor.zig` (`second_timer`, `onHardware()`)
- `micro-os-plus-iii-aarch64/test/start.zig` (the `uos_external_irq` forwarder)
- the port (`micro-os-plus-iii-aarch64/src/port.zig`), the board (`micro-os-plus-iii-aarch64/boards/rpi4b/startup.S`, `board.zig`, `linker.ld`) and the kernel (`micro-os-plus-iii/src/rtos/timer.zig`, `semaphore.zig`, `interrupts.zig`, and the rest of `micro-os-plus-iii/src/`)
- `micro-os-plus-iii-aarch64/build.zig` — the entries `tutor-14-interrupts-1cpu` and `-4cpu`

## 4. The test

PASS when, in both versions:

- the counter equals 100 + 130 + 2000 = 2230; every timer callback and
  every second-timer handler ran in handler mode; every post was taken;
  (4 CPUs) the interrupts on core 0, the adder on core 3, the waiters on
  cores 1 and 2;
- free, every interrupt within 30 µs of its due time and its thread within
  30 µs of it on the board (20 ms under QEMU); held, the interrupt late by
  250 … 330 µs — the rest of the critical section — and its thread still
  within 30 µs of it;
- (4 CPUs) the handler ran on core 1, 2 and 3 as armed; with core 0 in a 0.5
  ms interrupt section, core 1's plain handler ran inside it, while one that
  takes the section ran 0 times inside and resumed after; on the board,
  during a 2.5 ms section the plain handler ran fewer than 20 of its 25
  times — core 1 stalled at its tick;
- the heap is back to its level; (4 CPUs) cores 1–3 joined.

## 5. Running it

As lesson 01 (see `../01-bring-up/README.md`, *Running it*); from
`micro-os-plus-iii-aarch64`:

```sh
cd micro-os-plus-iii-aarch64
export PATH=$HOME/zig-x86_64-linux-0.17.0:$PATH
zig build -Dtest=tutor-14-interrupts-1cpu
zig build -Dtest=tutor-14-interrupts-4cpu
zig build -Dtest=tutor-14-interrupts-1cpu run    # QEMU
zig build -Dtest=tutor-14-interrupts-4cpu run
test/run-all.sh tutor-14-interrupts-1cpu          # the board
test/run-all.sh tutor-14-interrupts-4cpu
```

## 6. Results

Both versions PASS under QEMU and on the board (2026-10-23): 14 s and 14 s
on the board. Under QEMU the numbers are the C++ lesson's: 2230 counted,
the interrupt about 400 µs late behind the section (0.3 ms on the board, see
the C++ results), core 1's plain handler 4–6 runs inside the short section,
the one taking the section 0 inside and 23 after. See
[`RESULTS.md`](RESULTS.md).

### What this lesson found

The first four-CPU version (in C++; the Zig one followed it) claimed that core 0's interrupt section leaves
core 1's interrupts free. On the board core 1's handler did not run at all:
core 1 was idle, its idle thread rescheduled after the first interrupt, and
rescheduling waits for the kernel spinlock core 0 held. Even a busy core 1
stops at its next tick, for the same reason. The lesson now shows all three
cases, and the router stays busy so that the first can be seen.
