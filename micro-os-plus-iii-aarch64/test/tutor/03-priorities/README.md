# Lesson 03 (Zig) — Priorities, preemption and a second interrupt

## 1. Theory

### Priorities

Every thread has a **priority**, a number saying how urgent its work is. A
real-time scheduler follows one rule: **the CPU runs the highest-priority
thread that is ready**. Not the one that has waited longest, not a fair
share: the most urgent. Threads of equal priority take turns among
themselves (lesson 02's round-robin); a thread of lower priority runs only
when every thread above it is blocked — sleeping, waiting for a lock, an
event, a message.

The consequence is the first thing this lesson shows: three threads at
three priorities that never block run **one after the other**, highest
first, each to its end, whatever order they were created in. The creation
order matters only if the creator lets them start, which is why the main
thread raises itself above them while it creates them.

### Preemption

A scheduler is **preemptive** when it takes the CPU from a running thread
the moment a higher-priority thread becomes ready, without waiting for the
running thread to give it away. The running thread is not asked: it is
stopped between two instructions, its registers saved, and it resumes
later exactly where it was, as if nothing had happened (only time has
passed).

What makes a thread ready while another runs? Either the running thread
itself (it posts a semaphore, unlocks a mutex, raises a priority), or an
**interrupt**: a device signals the CPU, the CPU leaves the thread and runs
an *interrupt service routine* (ISR), and the ISR makes a waiting thread
ready. If that thread outranks the interrupted one, the kernel does not
return to the interrupted thread at the end of the ISR: it switches to the
woken one. This is how an RTOS answers an external event in a bounded time
even while a lower-priority thread computes without ever blocking.

### Deferred work: the ISR wakes, the thread works

An ISR runs in a special context: it borrows the CPU from whatever thread
was running, it cannot block (there is nothing to switch back to while it
waits), and while it runs other interrupts may be held off. So an ISR does
the least possible — acknowledge the device, note the time, wake a thread —
and a **thread** does the work, at the priority the application gives it.
The usual link between the two is a **semaphore**: the ISR posts it (a call
the kernel allows from interrupt context), the thread waits on it.

### Latency

The *latency* of the response is the time from the event to the thread
handling it running. It has two parts: the time to enter the ISR (the CPU
finishing an instruction, interrupts possibly being masked in a kernel
critical section) and the time from the ISR's post to the thread's first
instruction (the scheduler's decision and the context switch). A real-time
system is designed so that this latency is **bounded**, whatever the
lower-priority threads are doing. The lesson measures it on every
interrupt.

### Starvation

The other side of the rule: a thread that never blocks gets the CPU from
**every** thread below it, forever. Lower-priority threads *starve*. In
µOS++ this includes the **idle thread**, which also does a housekeeping
job: a thread that returns from its function is only queued as terminated,
and the idle thread destroys it and wakes the thread waiting in `join()`.
While a thread that never blocks computes, no thread can run below it, the
idle thread neither, and a `join()` on a finished thread never returns. The
first version of the C++ lesson found this out; the lesson has the
responder signal the main thread with a semaphore instead.

### Several CPUs

With several cores the rule holds **per core**: each core runs the
highest-priority ready thread it may run. Two threads of different
priorities on two cores both run, at the same time; priority orders the
threads competing for **one** CPU, it does not serialize threads on
different CPUs. An application that relies on "the high-priority thread
runs first, so the low one cannot be in the middle of something" is correct
on one CPU and wrong on several — the reason for the locks of the next
lessons.

An interrupt, too, is taken by one core. A per-core timer interrupts the
core that armed it; the thread it wakes runs on the core its affinity
allows; and the preemption happens on that core only, the others going on
with their work.

## 2. In µOS++ (Zig)

- `uos.rtos.priority`: `idle`, `lowest`/`low`, `below_normal`, `normal`,
  `above_normal`, `high`, `realtime`, `highest` (higher is more urgent);
  `Thread.Attributes.priority` sets it at creation,
  `this_thread.thread().setPriority(p)` changes it while running.
- The scheduler is preemptive: a thread made ready by a higher-priority
  one, or by an ISR, takes the CPU at once — from an ISR, on the way out of
  the interrupt (`ctx_pending[cpu]`, acted on at the end of
  `port_isr_handler()` in `src/port.zig`).
- `rtos.Semaphore`: `.counting(name, max, initial)`, `.binary(name, 0)`;
  `post()` (allowed in an ISR), `wait()`.
- The idle thread destroys terminated threads
  (`scheduler.terminated_threads_list`, `Thread` destroy in
  `micro-os-plus-iii/src/rtos/thread.zig`) and wakes their joiner.
- The second interrupt: `tutor.second_timer` (`test/tutor/common/tutor.zig`):
  the core's virtual generic timer, PPI 27, armed on the calling core with
  `start(period_us, callback, arg)`, its callback run in interrupt context;
  `nowUs()` the System Timer's 1 MHz counter. The port hands every interrupt
  it does not own to the root module's `uos_external_irq(iar)`
  (`test/start.zig` forwards it to the test), so the lesson declares
  `pub const uos_external_irq = tutor.second_timer.onIrq;`.
- `tutor.onHardware()`: the same image runs under QEMU and on the board, so
  it is told at run time — the Pi 4's generic timer runs at 54 MHz, QEMU's
  `raspi4b` at 62.5 MHz. The timing bounds are strict only on the board.
- With four CPUs: `Thread.Attributes.cpu_affinity` (one bit per core);
  `board.cpuSlot()` is the core a thread or an ISR runs on.

## 3. The lesson

New against lesson 02: threads at **different** priorities, a thread that
**never** blocks, and an **interrupt** that preempts it.

The unit of work is one *round*: lesson 02's steps — 18 samples built on the
thread's own stack, linked, sorted, the checksum taken — in `oneRound()`.
Its result is always the same, so the main thread computes the expected
checksums once, before any thread starts (`reference()` uses static arrays
and is not reentrant), and every round is checked.

**`1cpu/main.zig`.**

- *Part A, priorities.* The main thread raises itself to `realtime`, then
  creates three workers — `low`, `normal`, `high`, in that order — that wait
  for a start flag, then do 400 rounds each without ever yielding, recording
  when they start and end and a sequence number at each. The main thread
  sets the flag and blocks in `join()`. The scheduler runs `high` first, to
  its end, then `normal`, then `low`: the sequence numbers must be high 0,1;
  normal 2,3; low 4,5.
- *Part B, preemption by an interrupt.* A `busy` thread at `low` repeats
  rounds until told to stop, never blocking or yielding, counting its
  rounds. A `responder` at `high` arms the second interrupt on its core (every
  5 ms), then waits 100 times on a counting semaphore; the interrupt's
  callback stamps the time (`nowUs()`) and posts the semaphore. At each
  wake the responder records the latency (now − the interrupt's stamp) and
  the busy thread's round count; after the 100th it stops the timer and
  posts `done`. The main thread, lowered to `normal`, waits on `done`, then
  stops the busy thread and joins both.
- *The checks.* 100 interrupts, all on core 0; every latency within 1 ms on
  the board (20 ms under QEMU, whose cores are not real-time); the busy
  thread's round count grew between every two interrupts (it was preempted
  and resumed each time, and did real work in between); every busy round
  exact; the heap back to its level.

**`4cpu/main.zig`** first releases cores 1–3 (as in lesson 01). Then:

- *Part A.* The workers are pinned: `low` on core 1, `normal` on core 2,
  `high` on core 3. Each is the only thread on its core, so all three run
  at once. After recording its start, each waits at a **barrier** until all
  three are running — a barrier no worker could pass with one CPU. The
  checks: each ran on its own core, and all three started before any
  finished.
- *Part B.* The busy thread and the responder are both pinned to core 1;
  the responder arms the timer there, so the interrupt, the preemption and
  the response all happen on core 1, while the main thread waits on core 0.
  The checks are those of one CPU, with "the responder and every interrupt
  ran on core 1".

### Files in the build

The same files as lesson 01 (see `../01-bring-up/README.md`, *Files in the
build*), with this lesson's own source in place of lesson 01's:

- `micro-os-plus-iii-aarch64/test/tutor/03-priorities/1cpu/main.zig` (or `4cpu/main.zig`)
- `micro-os-plus-iii-aarch64/test/tutor/common/tutor.zig` — now with `second_timer` and `onHardware()`
- `micro-os-plus-iii-aarch64/test/start.zig` (the `uos_external_irq` forwarder), `test/board.zig`
- the board (`micro-os-plus-iii-aarch64/boards/rpi4b/startup.S`, `board.zig`, `linker.ld`), the port (`micro-os-plus-iii-aarch64/src/port.zig` — the dispatcher and the reschedule from an ISR, `src/arch.zig`, `src/gic.zig`, `src/mmu.zig`, ...) and the kernel (`micro-os-plus-iii/src/rtos/thread.zig` — priorities, exit and destroy; `semaphore.zig`; `scheduler.zig` — the idle thread; and the rest of `micro-os-plus-iii/src/`)
- `micro-os-plus-iii-aarch64/build.zig` — the two entries `tutor-03-priorities-1cpu` and `-4cpu`

## 4. The test

PASS when:

- (both) every worker's 400 rounds are exact;
- (1 CPU) `high` ran to its end, then `normal`, then `low`;
- (4 CPUs) cores 1–3 joined; each worker ran on its own core, and all three
  started before any finished;
- (both) the second interrupt fired 100 times, all on core 0 (1 CPU) or all
  on core 1, where the responder ran (4 CPUs);
- (both) every latency from the interrupt to the responder within 1 ms on
  the board (20 ms under QEMU);
- (both) the busy thread progressed between every two interrupts (under
  QEMU 90 % of them), and every busy round was exact;
- (both) the heap is back to its level.

On the UART, look for the workers' sequence numbers and times (one after
the other with one CPU, overlapping with four), the latency (max and mean),
and the busy thread's round counts at the responder's wakes.

## 5. Running it

As lesson 01 (see `../01-bring-up/README.md`, *Running it*); from
`micro-os-plus-iii-aarch64`:

```sh
cd micro-os-plus-iii-aarch64
export PATH=$HOME/zig-x86_64-linux-0.17.0:$PATH
zig build -Dtest=tutor-03-priorities-1cpu
zig build -Dtest=tutor-03-priorities-4cpu
zig build -Dtest=tutor-03-priorities-1cpu run    # QEMU
zig build -Dtest=tutor-03-priorities-4cpu run
test/run-all.sh tutor-03-priorities-1cpu          # the board
test/run-all.sh tutor-03-priorities-4cpu
```

## 6. Results

Both versions PASS under QEMU and on the board (2026-10-22): 15 s each on
the board. With one CPU the workers ran high, normal, low, one after the
other; with four, all three at once. Every one of the 100 interrupts
reached the responder within the bound (1 ms on the board; the C++
lesson measured 2–3 µs there), while the busy thread, preempted 100 times,
kept doing exact rounds. See [`RESULTS.md`](RESULTS.md).
