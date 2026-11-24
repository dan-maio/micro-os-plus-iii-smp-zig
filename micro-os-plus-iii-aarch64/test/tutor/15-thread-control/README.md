# Lesson 15 (Zig) — Thread control: states, suspend/resume, interrupt, kill, stack, statistics

## 1. Theory

### The states of a thread

A thread is always in one state:

| State | Meaning | How it gets there |
|---|---|---|
| `ready` | could run, waits for a CPU | created; resumed; its wait ended; preempted |
| `running` | runs on a CPU | picked by the scheduler |
| `suspended` | waits for something | a wait (`lock`, `wait`, `receive`, `sleep_for`, `join`), or `this_thread::suspend ()` |
| `terminated` | returned (or called `exit`), not yet cleaned up | its function returned |
| `destroyed` | its stack released, its joiner woken | the idle thread (the "reaper"), or `kill ()` |

A thread reads only its own state as `running`; anybody else sees it
`ready`, `suspended`, … — on one CPU it cannot be running while another
thread looks.

### Suspend and resume

`this_thread::suspend ()` takes the caller off the CPU until another thread —
or an interrupt — calls `resume ()` on it. It is the primitive under every
wait: a semaphore links the thread into its list and suspends it; `post`
unlinks one and resumes it. Used directly, it is a one-to-one wake-up with
no count: a `resume` sent before the `suspend` is lost.

### Interrupting a wait

`th.interrupt ()` sets the thread's *interrupted* flag and resumes it. A
thread waiting anywhere — a semaphore, a mutex, a queue, a sleep — wakes,
sees the flag, and its call returns `EINTR`. The flag **stays set** until
the thread clears it (`this_thread::thread ().interrupt (false)`): it is the
way to ask a thread to stop what it waits for and look around — for
instance, to shut it down cleanly.

### Kill, and why it is the last resort

`th.kill ()` ends a thread from outside, wherever it is: it is unlinked from
whatever it waited on, its stack is released, its state becomes
`destroyed`. Nothing of the thread's own runs: a mutex it held is released
as *owner dead*, a buffer it was filling stays half-filled. Prefer a request
(a flag, `interrupt ()`) that the thread answers by returning.

### Join and the reaper

A thread that returns is `terminated`; the **idle thread** destroys it —
releases its stack — and only then wakes its joiner. So `join ()` needs the
idle thread to run: a thread that keeps its CPU busy below the joiner (a
`hog`) starves the reaper, and the join never returns. Wait for the work
with a semaphore instead, stop the hog, then join.

### The stack and its high-water mark

Every thread's stack is filled with a magic word when the thread is
created. `stack ().available ()` counts, from the bottom, the words still
holding it — the stack never reached; `size () - available ()` is the
**high-water mark**: the deepest the thread ever went. It counts:

- every function frame (locals, saved registers) on the deepest call chain;
- the frame the thread was started from (its first saved context);
- **every interrupt's frame**: on this port an interrupt saves the
  interrupted thread's registers on that thread's own stack, and runs its
  handler there. So every thread's stack must leave room for the deepest
  interrupt, on top of its own deepest call.

### Statistics

With `OS_INCLUDE_RTOS_STATISTICS_THREAD_CONTEXT_SWITCHES` and
`OS_INCLUDE_RTOS_STATISTICS_THREAD_CPU_CYCLES`, the scheduler counts, for
every thread, the times it was scheduled and the CPU time it ran (in
`hrclock` cycles): at every switch, the time since the previous switch goes
to the thread that leaves. All threads' CPU times add up to the elapsed
time of every CPU — one CPU: the elapsed time; four: four times it.

## 2. In µOS++ (Zig)

- `th.getState()` — `.ready`, `.running`, `.suspended`, `.terminated`,
  `.destroyed`.
- `rtos.this_thread.@"suspend"()`; `th.@"resume"()` (ISR-safe).
- `th.interrupt(true)`, `th.interrupt(false)` (both return the previous
  flag); `th.isInterrupted()`; a wait returns `error.Interrupted`.
- `th.kill()`; not from an ISR. `th.destroy()` frees a thread made by
  `Thread.create()`.
- `th.join()` — waits until `.destroyed`, gives the function's result.
- `th.stack().size()`, `th.stack().available()`.
- `th.statistics.context_switches`, `th.statistics.cpu_cycles`;
  `rtos.scheduler.statistics.cpu_cycles` (all threads);
  `rtos.hrclock.inputClockFrequencyHz()` to turn cycles into time.
- The lesson's root file turns the statistics on:
  `uos_options` = `board.options(n)` with `.statistics_context_switches` and
  `.statistics_cpu_cycles` set.
- The kernel: `micro-os-plus-iii/src/rtos/thread.zig` (`kill()`,
  `internalSuspend()`, `internalDestroy()`), `scheduler.zig`
  (`internalSwitchThreads()`: the statistics, the pick).

## 3. The lesson

**`1cpu/main.zig`.**

- *Part A, states and the calls.* A `worker` (`above_normal`) notes its own
  state, then five times counts a run and suspends itself; the main thread
  checks it is `suspended` each time and resumes it. Then it waits on a
  semaphore nobody posts: `interrupt ()` — the wait returns `EINTR`, the flag
  is set until the worker clears it. Then it sleeps 100 s: after 5 ticks,
  `interrupt ()` — `EINTR`. Then it waits forever: `kill ()`; a post on the
  semaphore afterwards stays (value 1): the dead thread is no longer on its
  list. A `below_normal` thread just created is `ready`, killed before it
  ran; a `high` one that returns at once is `terminated`, then joined
  (`destroyed`, result 42).
- *Part B, the stack.* Threads of 8 KiB recurse 0, 4, 8 and 16 frames of a
  256-byte array, inside an interrupt critical section (so that no interrupt
  frame lands on the deepest one), and read their high-water mark there. A
  depth whose thread saw a tick between its creation and its section is run
  again. A `shallow` thread, interrupted by 20 ticks, reads its own.
- *Part C, statistics.* A `pulse` (`above_normal`) works 2 ms and sleeps 2
  ticks, 50 times — 100 ms of CPU — above a `hog` (`below_normal`) that
  spins. The main thread waits on a semaphore the pulse posts (not on
  `join`: the hog starves the reaper), stops the hog, joins both.

**`4cpu/main.zig`** first releases cores 1–3; the worker runs on core 1, the
diggers on cores 1–3, one pulse and one hog on each of cores 1, 2 and 3.
And **part D**: a `spinner` runs busy on core 2; the main thread, on core 0,
kills it.

### Files in the build

The same files as lesson 01 (see `../01-bring-up/README.md`, *Files in the
build*), with this lesson's own source in place of lesson 01's:

- `micro-os-plus-iii-aarch64/test/tutor/15-thread-control/1cpu/main.zig` (or `4cpu/main.zig`)
- `micro-os-plus-iii-aarch64/test/tutor/common/tutor.zig` (`second_timer.nowUs()`, `onHardware()`)
- `micro-os-plus-iii-aarch64/test/board.zig` (`options()`, `cpuSlot()`, the SMP start)
- the port (`micro-os-plus-iii-aarch64/src/port.zig`), the board (`micro-os-plus-iii-aarch64/boards/rpi4b/startup.S`, `board.zig`, `linker.ld`) and the kernel (`micro-os-plus-iii/src/rtos/thread.zig`, `scheduler.zig`, and the rest of `micro-os-plus-iii/src/`)
- `micro-os-plus-iii-aarch64/build.zig` — the entries `tutor-15-thread-control-1cpu` and `-4cpu`

## 4. The test

PASS when, in both versions:

- the worker saw itself `running`; it was `suspended` after each of its 5
  pauses and ran again only when resumed; (4 CPUs) on core 1;
- the interrupted wait returned `error.Interrupted` with the flag set, cleared after;
  the interrupted 100 s sleep returned `error.Interrupted` after 5–49 ticks;
- the killed waiter is `destroyed` and a later post stays; the new lower
  thread was `ready`, killed with 0 runs; the returned one `terminated` (4
  CPUs: or already `destroyed` by an idle core), joined `destroyed` with 42;
- the high-water mark grows with the depth, below the size; 4 → 8 and 8 →
  16 frames cost the same per frame, 256 … 320 bytes; the interrupted
  shallow thread used more than 200 bytes above the depth-0 one;
- each pulse used 95 … 110 % of its 100 ms on the board (… 150 % under
  QEMU) and was scheduled at least 50 times; pulse + hog ≥ 90 % of the
  elapsed time; all threads' CPU time = 1x (4x) the elapsed time, ± 3 %;
- (4 CPUs) the spinner was `running` on core 2; `kill()` succeeded, it is
  `destroyed`, and it did not spin again;
- the heap is back to its level; (4 CPUs) cores 1–3 joined.

## 5. Running it

As lesson 01 (see `../01-bring-up/README.md`, *Running it*); from
`micro-os-plus-iii-aarch64`:

```sh
cd micro-os-plus-iii-aarch64
export PATH=$HOME/zig-x86_64-linux-0.17.0:$PATH
zig build -Dtest=tutor-15-thread-control-1cpu
zig build -Dtest=tutor-15-thread-control-4cpu
zig build -Dtest=tutor-15-thread-control-1cpu run    # QEMU
zig build -Dtest=tutor-15-thread-control-4cpu run
test/run-all.sh tutor-15-thread-control-1cpu          # the board
test/run-all.sh tutor-15-thread-control-4cpu
```

## 6. Results

Both versions PASS under QEMU and on the board (2026-10-23): 14 s and 15 s
on the board. Under QEMU a frame of the recursion costs 288 bytes (C++:
272), a thread starts with 808 bytes used, and an interrupt adds 1536 bytes
on top of the interrupted frame (C++: 320–384) — the Zig tick path is
deeper. Each pulse used about 100.4 ms of CPU, all threads' CPU time came to
1.00x and 4.00x the elapsed time, and `kill()` stopped the running spinner
in 178 µs. See [`RESULTS.md`](RESULTS.md).

### What this lesson found

Two kernel bugs, both of the SMP scheduler only, found by the C++ lesson
and present in the Zig kernel too; fixed in both (Zig: `scheduler.zig`,
`statistics.switch_timestamp[cpu]`; `thread.zig`, `kill()`):

- **CPU time charged across cores.** The scheduler kept one
  `switch_timestamp_` for all CPUs, so a switch charged the leaving thread
  with the time since the last switch of *any* core. With four cores
  switching every tick, the pulses got 14–56 ms of their 100, and all
  threads together 1.00x the elapsed time instead of 4x. Now one timestamp
  per CPU.
- **`kill ()` of a thread running on another core never returned.** It
  waited, sending that core IPIs, for the thread to leave it; but the
  core's switch re-links a running thread to the ready list and picks it
  again — a busy thread never left. Now `kill ()` marks it suspended, under
  the kernel lock, before the IPI: the switch leaves it off the list.

And one rule of the kernel, now in the theory above: `join ()` waits for the
idle thread to destroy the thread; the first version joined the pulse while
the hog kept the CPU, and never returned.
