# µOS++ IIIe (Zig) — User Guide & API Reference

**Author:** Internal Engineering Documentation
**Date:** October 2026
**Target toolchain:** Zig `0.17.x`
**Scope:** The portable kernel (`micro-os-plus-iii`, module `uos`) and its use from Zig applications, on single-core and SMP targets.

---

## Table of Contents

1. [What µOS++ IIIe is](#what-µos-iiie-is)
2. [The module map](#the-module-map)
3. [Getting started](#getting-started)
4. [Worked examples: single-core and multi-core](#worked-examples-single-core-and-multi-core)
5. [Configuration (`uos_options`)](#configuration-uos_options)
6. [Application lifecycle](#application-lifecycle)
7. [Errors and results](#errors-and-results)
8. [Clocks and time](#clocks-and-time)
9. [Threads](#threads)
10. [Priorities](#priorities)
11. [The scheduler and preemption](#the-scheduler-and-preemption)
12. [Locks and critical sections](#locks-and-critical-sections)
13. [SMP: symmetric multi-processing](#smp-symmetric-multi-processing)
14. [Mutexes](#mutexes)
15. [Semaphores](#semaphores)
16. [Condition variables](#condition-variables)
17. [Event flags](#event-flags)
18. [Message queues](#message-queues)
19. [Memory pools](#memory-pools)
20. [Software timers](#software-timers)
21. [Memory allocators](#memory-allocators)
22. [Trace output](#trace-output)
23. [`std.Io` and devices](#std.io-and-devices)
24. [Writing device drivers (UART, SPI, I2C, ADC, DMA)](#writing-device-drivers-uart-spi-i2c-adc-dma)
25. [Interfacing with C](#interfacing-with-c)
26. [Linker scripts and the memory map](#linker-scripts-and-the-memory-map)
27. [Adding a new board](#adding-a-new-board)
28. [Adding a new architecture port](#adding-a-new-architecture-port)
29. [The main parts in code: boot, threads, scheduler, context switch, interrupts](#the-main-parts-in-code-boot-threads-scheduler-context-switch-interrupts)
30. [API quick reference](#api-quick-reference)

---

## 1. What µOS++ IIIe is

µOS++ IIIe is a small, portable, priority-preemptive real-time kernel with an
optional symmetric multi-processing (SMP) scheduler. The `micro-os-plus-iii`
repository is the **portable part** only, written in idiomatic Zig: explicit
allocators, error unions instead of the C++ `result_t`, compile-time
configuration, and the new `std.Io` interface.

A real firmware always links **exactly one architecture port**, a sibling
repository that supplies the `uos_port` module:

```text
micro-os-plu-iii-smp-zig-pr-github/
├── micro-os-plus-iii/              ← the kernel (module `uos`) — this document
├── micro-os-plus-iii-cortexm/      ← Cortex-M port (Pico 2, Pico, WeAct F411/F412, Nucleo-F411RE)
├── micro-os-plus-iii-aarch32/      ← ARMv7-A port (Luckfox Lyra B, 3× Cortex-A7)
├── micro-os-plus-iii-aarch64/      ← ARMv8-A port (Raspberry Pi 4 B, 4× Cortex-A72)
└── micro-os-plus-iii-posix-arch/   ← synthetic POSIX port (GNU/Linux host)
```

The kernel and the port import each other: the kernel provides the scheduler,
the threads, the lists and all the synchronisation objects; the port provides
the machine context, the interrupt masking, the context switch and the clocks.
A compile-time contract (see [§28](#adding-a-new-architecture-port)) checks
that a port declares everything the kernel needs.

**Why use it.** µOS++ IIIe gives you real-time threads, deterministic
synchronisation primitives and, on the right silicon, true SMP across multiple
cores, all from Zig with no C runtime required. It is also binary- and
API-compatible with the original C++ project through the exported C API.

---

## 2. The module map

Everything is reached from `const uos = @import("uos");`. The top-level names
are:

| Name | Contents |
| --- | --- |
| `uos.rtos` | The RTOS API: threads, scheduler, mutexes, semaphores, condition variables, event flags, message queues, memory pools, timers, clocks |
| `uos.memory` | Allocators: `FirstFitTop`, `BlockPool`, `Locked`, and the system heap |
| `uos.trace` | Trace output (`print`, `puts`, `putchar`, `writer`, `logFn`) |
| `uos.Io` | An `std.Io` implementation running on RTOS threads |
| `uos.io.devices` | Char/block devices, partitions, a registry, file descriptors, RAM disk |
| `uos.semihosting` | ARM semihosting (console, host files, exit, …) |
| `uos.Options` / `uos_options` | The compile-time configuration |
| `uos.port` | The architecture port module (`uos_port`) |
| `uos.c_api` | The µOS++ C API (`os_thread_construct()`, `os_mutex_lock()`, …) |
| `uos.cmsis_os` | The CMSIS-RTOS v1 API (`osThreadCreate()`, …) |

The C++ names map onto Zig like this:

| C++ | Zig |
| --- | --- |
| `os::rtos` | `uos.rtos` |
| `os::rtos::port` | the `uos_port` module |
| `os::memory` / `memory_resource` | `uos.memory` / `std.mem.Allocator` |
| `os::trace` | `uos.trace` |
| `os::estd` (ISO threads) | `uos.Io` (`std.Io`) |
| `os::posix` (POSIX I/O) | `uos.io.devices` |
| `os-c-api.h` | `uos.c_api` (exported `os_*`) |
| `exit()` / `_Exit()` | `uos.rtos.exit()` / `uos.rtos.terminate()` |
| `os-app-config.h` macros | `uos_options` in the root file |

---

## 3. Getting started

A complete minimal application looks like this:

```zig
const uos = @import("uos");

// Optional configuration; every field has a default.
pub const uos_options: uos.Options = .{
    .smp = true,          // use the SMP scheduler
    .ncpu = 2,            // two cores
    .trace = .{ .thread = true },
};

pub fn main() void {
    // Runs appMain() in the "main" thread and never returns.
    uos.rtos.run(appMain);
}

fn appMain() !void {
    // The scheduler is already started here.
    uos.trace.print("hello from the main thread\n", .{});
}
```

`uos.rtos.run()` prints a greeting, creates the main and idle threads, starts
the three clocks and switches to the highest-priority ready thread. `appMain`
may return `void`, an integer, or an error union; the return value becomes the
process exit code (0 for `void`/success, 1 for an error).

### Building a firmware

The kernel is not built on its own. Your application's build wires a port and
the kernel together. Inside an architecture port repository (such as the
Cortex-M one) you can build a test out of the box:

```sh
cd micro-os-plus-iii-cortexm
zig build -Dboard=pico2               # build every test of the board
zig build run -Dboard=pico2 -Dtest=smp-test2   # build one test and run it on the board
```

For a standalone application, use the port's `addFirmware()` helper (see
[§27](#adding-a-new-board)) or assemble the module wiring yourself with the
kernel's build helpers `uos_build.createModule()` and `uos_build.linkPort()`.

### Running on the host

The POSIX port runs the same kernel on GNU/Linux, which is the fastest way to
experiment:

```sh
cd micro-os-plus-iii-posix-arch
zig build                    # build every test
./zig-out/bin/smp-test1      # run one directly
```

---

## 4. Worked examples: single-core and multi-core

These two complete programs show the whole shape of a µOS++ application and
make the later sections concrete. Both use the same building blocks; the only
difference is the SMP configuration and CPU affinity.

### 4.1 Single-core: a producer/consumer pair

A producer thread increments a shared counter under a mutex and posts a
counting semaphore; a consumer thread waits on the semaphore and reads the
counter. The two never touch the counter unprotected.

```zig
const uos = @import("uos");

pub const uos_options: uos.Options = .{};   // defaults: 1 CPU, preemptive

var lock: uos.rtos.Mutex = .{ .name = "lock" };
var items: uos.rtos.Semaphore = .counting("items", 8, 0);
var counter: u32 = 0;

pub fn main() void {
    uos.rtos.run(appMain);
}

fn appMain() !void {
    var producer: uos.rtos.ThreadInclusive(1024) = undefined;
    try producer.init("producer", produce, null, .{});

    var consumer: uos.rtos.ThreadInclusive(1024) = undefined;
    try consumer.init("consumer", consume, null, .{});

    // Wait for both to finish, then the run ends.
    try producer.join();
    try consumer.join();
    uos.trace.print("done\n", .{});
}

fn produce(_: ?*anyopaque) ?*anyopaque {
    var i: u32 = 0;
    while (i < 10) : (i += 1) {
        try lock.lock();
        counter += 1;
        lock.unlock() catch {};
        try items.post();                       // wake the consumer
        uos.rtos.this_thread.sleepFor(10) catch {};
    }
    return null;
}

fn consume(_: ?*anyopaque) ?*anyopaque {
    var n: u32 = 0;
    while (n < 10) : (n += 1) {
        try items.wait();                        // block until an item exists
        try lock.lock();
        const v = counter;
        lock.unlock() catch {};
        uos.trace.print("consumed {d}\n", .{v});
    }
    return null;
}
```

Things to notice:

- `join()` blocks until the thread has terminated and been destroyed by the
  idle thread, then returns its exit value.
- The semaphore carries the "there is work" signal; the mutex carries the data.
- `ThreadInclusive(N)` embeds the stack, so no heap is needed at all.

### 4.2 Multi-core: a cross-CPU producer/consumer

The same idea, but now the two threads are **pinned to different CPUs** with
`cpu_affinity`, and the condition is carried by a mutex plus a condition
variable. This is a textbook SMP pattern: the kernel's SMP scheduler picks each
thread only on the CPU its affinity mask allows, and the interrupt critical
sections inside the mutex take the kernel lock, so the two cores never corrupt
the shared state.

```zig
const uos = @import("uos");

pub const uos_options: uos.Options = .{ .ncpu = 2, .smp = true };

var lock: uos.rtos.Mutex = .{ .name = "lock" };
var cv: uos.rtos.ConditionVariable = .{ .name = "cv" };
var item: u32 = 0;
var available = false;

pub fn main() void {
    uos.rtos.run(appMain);
}

fn appMain() !void {
    // Producer pinned to CPU 0, consumer pinned to CPU 1.
    var producer: uos.rtos.ThreadInclusive(1024) = undefined;
    try producer.init("producer", produce, null, .{ .cpu_affinity = 0b01 });

    var consumer: uos.rtos.ThreadInclusive(1024) = undefined;
    try consumer.init("consumer", consume, null, .{ .cpu_affinity = 0b10 });

    try producer.join();
    try consumer.join();
}

fn cpu() u32 {
    return uos.port.scheduler.cpuId();   // 0 or 1 on this target
}

fn produce(_: ?*anyopaque) ?*anyopaque {
    var i: u32 = 0;
    while (i < 20) : (i += 1) {
        try lock.lock();
        item = i;
        available = true;
        cv.signal() catch {};
        lock.unlock() catch {};
        uos.trace.print("cpu{d} produced {d}\n", .{ cpu(), i });
    }
    return null;
}

fn consume(_: ?*anyopaque) ?*anyopaque {
    var n: u32 = 0;
    while (n < 20) : (n += 1) {
        try lock.lock();
        while (!available) cv.wait(&lock) catch {};   // always re-check
        const v = item;
        available = false;
        lock.unlock() catch {};
        uos.trace.print("cpu{d} consumed {d}\n", .{ cpu(), v });
    }
    return null;
}
```

Notes:

- `uos.port.scheduler.cpuId()` reports the CPU the *calling* thread is running
  on, so you can see the threads land on different cores.
- As in POSIX, a condition-variable wait must be a loop: the wake-up does not
  guarantee the predicate.
- The same code runs unmodified with `ncpu = 1` / `smp = false` (then `cpu()`
  always returns 0) — which is a convenient way to smoke-test SMP code on a
  single-core board or on the host.

---

## 5. Configuration (`uos_options`)

The application declares one value in its root source file, the same way
`std_options` works:

```zig
pub const uos_options: uos.Options = .{
    .ncpu = 2,
    .smp = true,
    .trace = .{ .thread = true, .mutex = true },
};
```

Anything not set keeps its default. The fields mirror the C++
`OS_INTEGER_*` / `OS_INCLUDE_*` / `OS_USE_*` macros:

| Option | Default | Meaning (C++ macro) |
| --- | --- | --- |
| `ncpu` | `1` | Number of CPUs the scheduler manages (`OS_NCPU`) |
| `smp` | `false` | Use the SMP scheduler (`OS_USE_SMP_SCHEDULER`) |
| `resume_ipi` | `true` | On SMP, send an IPI to wake a resumed thread at once instead of at the next tick |
| `systick_frequency_hz` | `1000` | SysTick rate (`OS_INTEGER_SYSTICK_FREQUENCY_HZ`) |
| `min_stack_size_bytes` | `256` | Smallest accepted thread stack |
| `default_stack_size_bytes` | `2048` | Default thread stack |
| `main_stack_size_bytes` | `4096` | Stack of the main thread |
| `idle_stack_size_bytes` | `1024` | Stack of each idle thread |
| `preemptive` | `true` | Preemptive scheduler (`OS_BOOL_RTOS_SCHEDULER_PREEMPTIVE`) |
| `critical_section_interrupt_priority` | `null` | When set, single-core ARMv7-M/v8-M critical sections raise BASEPRI to this level instead of masking all interrupts |
| `idle_sleep` | `true` | Put the idle thread to sleep with WFI / `sigsuspend()` |
| `idle_priority_below_idle` | `false` | Run the idle thread one level below `idle` |
| `statistics_context_switches` | `false` | Count context switches |
| `statistics_cpu_cycles` | `false` | Count per-thread CPU cycles |
| `thread_public_flags_clear` | `true` | Clear thread flags on `get` with `.clear` |
| `exclude_dynamic_memory_allocations` | `false` | No heap at all; dynamic objects fail with `error.OutOfMemory` |
| `dynamic_memory_size_bytes` | `16 KiB` | Size of the RTOS system heap |
| `c_api` | `false` | Export the µOS++ C API |
| `cmsis_os` | `false` | Export the CMSIS-RTOS v1 API |
| `c_runtime` | `false` | Export the minimal C runtime (freestanding) |
| `trace` | `.{}` | Per-subsystem trace toggles (see below) |

`trace` is a struct of booleans, one per subsystem: `scheduler`, `thread`,
`thread_context`, `thread_flags`, `mutex`, `semaphore`, `condvar`, `evflags`,
`mqueue`, `mempool`, `timer`, `clocks`, `sysclock_tick`, `rtc_tick`, `lists`,
`lists_clocks`, `memory`.

A few invariants are checked at compile time: `ncpu` must be at least 1,
`ncpu > 1` requires `smp = true`, and `ncpu` must not exceed 32 (the affinity
mask is 32 bits wide).

---

## 6. Application lifecycle

The flow, end to end:

1. The hardware resets and (in a port like the Cortex-M one) the board clocks
   are set up by the port's `scheduler.initialize()`, which also calls the
   board's `init()`.
2. `uos.rtos.run(appMain)` prints the greeting, creates the **main thread** and
   one **idle thread per CPU**, then calls `scheduler.start()` — which starts
   the clocks, latches the preemptive flag and performs the first context
   switch.
3. `appMain` runs inside the main thread. From here you create your own
   threads and synchronisation objects.
4. When `appMain` returns, its value becomes the exit code and `exit()` is
   called, which traces the code and calls `terminate()`.
5. `terminate()` prints the stack usage statistics and ends the run through the
   port (semihosting `SYS_EXIT` on the test boards); a port without
   `terminate()` halts or blocks.

```zig
pub fn main() void {
    uos.rtos.run(appMain);
}

fn appMain() !void {
    // ... create threads, do work ...
}
```

`appMain` may return `void`, an integer, or an error union of those two. An
error is traced (with its stack trace) and maps to exit code 1.

### Idle threads

There is one idle thread per CPU. CPU 0's idle thread is the **reaper**: it
destroys terminated threads (freeing their stacks and waking any joiner) and
runs the power-saving hook. The secondary CPUs' idle threads simply sleep and
yield. An application can install a power-saving hook:

```zig
uos.rtos.startup.idle_power_saving_hook = myPowerSave;   // returns true if it slept
```

### Explicit termination

```zig
uos.rtos.exit(code);        // traces "exit(code)" then terminates
uos.rtos.terminate(code);   // terminates immediately (the _Exit() equivalent)
```

---

## 7. Errors and results

The C++ kernel returns a POSIX `result_t`; Zig uses error unions. Every error
carries a fixed POSIX number, so the C API and any numeric logging stay
compatible.

| Zig error | POSIX | Meaning |
| --- | --- | --- |
| `error.NotPermitted` | EPERM | Called from an ISR, with the scheduler locked, or by a thread that does not own the mutex |
| `error.InvalidArgument` | EINVAL | Bad argument or attribute value |
| `error.WouldBlock` | EWOULDBLOCK | A `try*` call would block |
| `error.Again` | EAGAIN | A recursive mutex reached `max_count`, or a semaphore its maximum |
| `error.TimedOut` | ETIMEDOUT | A timed wait elapsed |
| `error.Interrupted` | EINTR | The waiting thread was interrupted |
| `error.OutOfMemory` | ENOMEM | No memory |
| `error.Deadlock` | EDEADLK | An error-checking mutex is already owned by the caller |
| `error.OwnerDead` | EOWNERDEAD | A robust mutex was acquired but its owner died holding it (the mutex **is** held) |
| `error.NotRecoverable` | ENOTRECOVERABLE | A robust mutex is inconsistent |
| `error.MessageSize` | EMSGSIZE | A message does not fit the queue |
| `error.BadMessage` | EBADMSG | A queue got an invalid message |

Helpers:

```zig
uos.rtos.errno(err);             // the POSIX number of an error
try uos.rtos.result.check(ok, error.InvalidArgument);  // return err unless ok
```

---

## 8. Clocks and time

Three fixed clocks, exactly as in C++:

| Clock | Name | Unit | Use |
| --- | --- | --- | --- |
| `uos.rtos.sysclock` | `sys-clock` | SysTick ticks | default clock of every timed wait |
| `uos.rtos.hrclock` | `hr-clock` | CPU cycles (or a hardware timer) | measurements, statistics |
| `uos.rtos.rtclock` | `rt-clock` | seconds, adjustable | wall-clock time |

The types are `Duration = u32` (ticks), `Timestamp = u64` (absolute ticks) and
`Offset = i64` (adjustable-clock offset). `sysclock`'s unit is
`uos_options.systick_frequency_hz`, available as `uos.rtos.Clock.frequency_hz`.

```zig
const sys = uos.rtos.sysclock;

const t = sys.steadyNow();                 // monotone tick count
try sys.sleepFor(uos.rtos.Clock.msToTicks(50));   // sleep 50 ms (rounded up)
try sys.sleepUntil(t + 100);               // sleep until an absolute tick
try sys.waitFor(100);                      // wait for a resume or a timeout
```

`Clock.ticksCast(us)` and `Clock.msToTicks(ms)` convert real time into
`systick` ticks, rounding up. `now()` is adjusted for adjustable clocks,
`steadyNow()` is the raw monotone count. The real-time clock is adjustable:

```zig
_ = uos.rtos.rtclock.setOffset(seconds_since_epoch);   // returns previous offset
const offset = uos.rtos.rtclock.getOffset();
```

After a low-power sleep without ticks, call `clock.updateForSleptTime(duration)`
to advance the steady count and run any due waiters.

The tick itself is the port's business: its SysTick handler calls
`uos.rtos.clocks.sysTickHandler()` (on CPU 0 only, on SMP). Without a real RTC
driver, the kernel derives whole seconds from the tick and calls
`rtcHandler()` once per second.

---

## 9. Threads

A `Thread` is an **intrusive** object: it is linked into scheduler lists by
address and must never move once initialised. Threads come in three flavours.

### Static threads

```zig
var worker: uos.rtos.ThreadInclusive(2048) = undefined;
try worker.init("worker", workerMain, null, .{ .priority = .high });
```

`ThreadInclusive(N)` embeds the stack inside the object, so nothing is
allocated and no allocator is needed.

### Dynamic threads

```zig
// create(): object and stack come from gpa; release with destroy().
const th = try uos.rtos.Thread.create(gpa, "worker", workerMain, null, .{});

// spawn(): packs typed arguments, like std.Thread.spawn().
const th2 = try uos.rtos.Thread.spawn(gpa, .{}, "worker", work, .{ 1, 2 });
```

`spawn()` runs `work(1, 2)`; an error return is traced, any other value is
discarded. `create()` and `spawn()` set the object free to `destroy()`.

### The thread function

```zig
fn workerMain(args: ?*anyopaque) ?*anyopaque {
    _ = args;
    // ... work ...
    return null;   // becomes the value join() returns
}
```

The `Func` type is `*const fn (?*anyopaque) ?*anyopaque`. When the function
returns, the thread calls `internalExit()` and is placed on the funeral list for
the idle thread to destroy.

### Creation attributes

```zig
pub const Attributes = struct {
    stack: ?[]StackElement = null,   // user-supplied stack
    stack_size_bytes: usize = 0,     // when allocated (0 = default)
    priority: Priority = .normal,
    clock: ?*Clock = null,           // clock for timed waits (null = sysclock)
    cpu_affinity: u32 = 0xFFFF_FFFF, // SMP: one bit per allowed CPU
};
```

### Thread control

```zig
th.priority();                 // effective priority (assigned or inherited)
th.setPriority(.realtime);     // change the assigned priority
th.setPriorityInherited(p);    // used by the mutex inheritance machinery
th.cpuAffinity();              // SMP affinity mask
th.setCpuAffinity(0b0011);     // allow CPUs 0 and 1 only
th.detach();                   // detach from its parent
const result = try th.join();  // wait for termination; returns the exit value
th.interrupt(true);            // set/clear the interrupted flag and resume it
th.kill();                     // force termination and release its resources
th.getState();                 // the thread state
```

A thread may be in one of these states: `undefined`, `ready`, `running`,
`suspended`, `terminated`, `destroyed`, `initializing`, `destroying`.

### The current thread

`uos.rtos.this_thread` groups functions acting on the caller:

```zig
uos.rtos.this_thread.get();        // *Thread or null before any thread exists
uos.rtos.this_thread.thread();     // *Thread (asserts not in an ISR)
uos.rtos.this_thread.yield();      // reschedule to an equal/higher ready thread
uos.rtos.this_thread.suspend();    // suspend until resumed
uos.rtos.this_thread.exit(null);   // terminate this thread
uos.rtos.this_thread.sleepFor(10); // sleep on sysclock
```

### Stacks

A thread's `Stack` is exposed as `th.stack()` and offers `size()`,
`available()` (bytes never written), `checkBottomMagic()` and
`checkTopMagic()`. Stacks are filled with a magic word (`0xEFBE_ADDE`) so the
kernel can detect over/underflow and report usage. The idle thread checks the
bottom magic on every context switch and panics on underflow.

---

## 10. Priorities

Priorities are `u8`. There are named levels spaced 16 values apart (the
`range = 4` gives 16 sub-levels per named step):

| Level | Value | Use |
| --- | --- | --- |
| `none` | 0 | Undefined; the thread does not run |
| `idle` | 16 | Reserved for the idle thread |
| `lowest` / `low` | 32 | |
| `below_normal` | 64 | |
| `normal` | 96 | Default |
| `above_normal` | 128 | |
| `high` | 160 | |
| `realtime` | 192 | |
| `highest` | 223 | |
| `isr` | 239 | Reserved for interrupt service threads |
| `error` | 255 | Error value returned by the getters |

Any value in `(none, error)` is valid, so you can fine-tune within a band. The
scheduler always runs the highest-priority ready thread, and equal priorities
round-robin.

---

## 11. The scheduler and preemption

The scheduler is **priority preemptive** with **round-robin among equal
priorities**. Preemption happens at every tick and every `reschedule()` request:
if a higher-priority thread became ready, the currently running thread is put
back on the ready list and the new one is switched in.

A few controls:

```zig
uos.rtos.scheduler.preemptive(false);   // switch to cooperative mode (returns previous)
uos.rtos.scheduler.isPreemptive();
uos.rtos.scheduler.started();           // true after start()
```

The scheduler lock (`scheduler.CriticalSection`, see the next section) is the
mechanism that temporarily disables thread switching on the calling CPU.

Internally, one scalar code path handles both single-core and SMP: the
`current_thread` array has `ncpu` entries and `port.scheduler.cpuId()` returns
0 on a single-CPU build, so the single-core case compiles to the same scalar
code it would have had in C++.

---

## 12. Locks and critical sections

µOS++ has **two nested locking layers**. Understanding the difference is the
single most important thing for writing correct RTOS code.

### 12.1 Interrupt critical section

```zig
const cs = uos.rtos.interrupts.CriticalSection.enter();
defer cs.exit();
// ... interrupts (below the scheduler priority) are masked here ...
```

- On a single-CPU build the port masks interrupts (PRIMASK `DI/EI`), or raises
  BASEPRI to `critical_section_interrupt_priority` when that is configured.
- On an SMP build it **also** takes the kernel lock, so the section is
  exclusive across CPUs too.
- These sections nest freely.

This is the fundamental mutual-exclusion primitive: anything that must not be
torn by an interrupt, or that touches shared kernel state, runs inside one.
Every kernel object uses it internally.

### 12.2 Scheduler critical section (the scheduler lock)

```zig
const scs = uos.rtos.scheduler.CriticalSection.enter();
defer scs.exit();
// ... thread switching is disabled on this CPU ...
```

This locks the scheduler, disabling context switches **without** masking
interrupts. Interrupts still run (and can post semaphores, raise flags, etc.),
but no other thread runs on this CPU until `exit()`. It nests, and is exposed
directly as:

```zig
uos.rtos.scheduler.lock();      // returns the previous state
uos.rtos.scheduler.unlock();
uos.rtos.scheduler.setLocked(state);
uos.rtos.scheduler.locked();    // true while locked
```

### 12.3 The "uncritical" sections

Both layers offer an `UncriticalSection` that *enables* its resource until
`exit()`, even inside the corresponding critical section. This is used when the
kernel must briefly allow a context switch or interrupts while holding the
other lock.

### 12.4 Which one to use

- Protect a few lines of shared data from interrupts and other CPUs →
  `interrupts.CriticalSection`.
- Prevent preemption across a longer region, while still letting interrupts
  run → `scheduler.CriticalSection`.
- Long regions with the scheduler locked must not block: a thread waiting
  (mutex, semaphore, queue, sleep) while the scheduler is locked is an error
  (`error.NotPermitted`).

The two are often combined, e.g. a mutex `lock()` holds the scheduler lock
while it manipulates its owner and then takes an interrupt critical section
when linking a waiter.

---

## 13. SMP: symmetric multi-processing

With `uos_options.smp = true` (and `ncpu > 1`) the kernel manages several CPUs
from **one shared ready list**. The design, in plain terms:

- **One current thread per CPU**: `scheduler.current_thread[cpu]`, indexed by
  `port.scheduler.cpuId()`.
- **A single ready list** shared by all CPUs, ordered by priority.
- **Affinity-aware picking**: when a CPU needs a thread, it walks the ready
  list and picks the first thread whose `cpu_affinity` bit allows that CPU.
- **Per-CPU idle threads**: each idle thread is pinned to its own CPU.
- **A recursive kernel lock** taken by every interrupt critical section, so a
  critical section is exclusive across CPUs. On the RP2040/RP2350 this is SIO
  hardware spinlock 0; the AArch64/AArch32 ports use their own spinlocks.
- **Inter-processor interrupts (IPI)**: when a thread is resumed from a CPU
  whose affinity does not include the CPU that will run it, the kernel sends an
  IPI so it runs immediately rather than at the next tick (`resume_ipi`).
- **One clock source**: only CPU 0 advances the RTOS clock; the other CPUs'
  ticks just request a reschedule.

### Using SMP from an application

Affinity is set per thread with `cpu_affinity`, a bitmask with one bit per CPU:

```zig
pub const uos_options: uos.Options = .{ .ncpu = 2, .smp = true };

fn appMain() !void {
    // A thread pinned to CPU 1 only.
    var core1_worker: uos.rtos.ThreadInclusive(2048) = undefined;
    try core1_worker.init("core1", workerMain, null, .{ .cpu_affinity = 0b0010 });

    // A thread allowed to run on either CPU.
    var anywhere: uos.rtos.ThreadInclusive(2048) = undefined;
    try anywhere.init("any", workerMain, null, .{ .cpu_affinity = 0b0011 });
}
```

The main thread is created with affinity `1` (CPU 0) when `ncpu > 1`. Each
idle thread is created with its own CPU's bit. See [§4.2](#worked-examples-single-core-and-multi-core)
for a complete cross-CPU producer/consumer.

### How secondary CPUs come up

The port owns CPU bring-up. On the RP2040/RP2350, core 1 is launched with the
bootrom FIFO handshake (`launchCore1()`); on A-profile ports the application or
port calls `startSecondaryCpus()`. Each secondary CPU:

1. masks interrupts, sets up its own PendSV and SysTick,
2. makes its boot pseudo-thread current with
   `uos.rtos.scheduler.internalPrepareCpu(cpu)`,
3. requests its first context switch and enables interrupts.

The application may choose to launch the secondary CPUs itself (for example the
Cortex-M port's `uos_port_options.launch_core1_at_start = false`), but the
kernel-side call is always the same.

### Things to watch on SMP

- An object is protected by the kernel lock only while a critical section is
  held; do not assume single-CPU "mask interrupts" is enough for shared data.
- A thread's saved stack pointer is published as `null` while its context is
  live in a CPU's registers; the picker skips such threads, which is what makes
  the shared ready list safe.
- `this_thread.get()` reads the CPU index and that CPU's current thread inside
  a critical section, so a preemption cannot move the caller to another CPU
  between the two reads.
- `Thread.kill()` and `Thread.join()` on SMP wait (with the lock released) until
  the target is off every CPU before touching it.

---

## 14. Mutexes

Mutexes have POSIX semantics: normal, error-checking and recursive types;
no protocol, priority inheritance or priority ceiling; stalled or robust.

```zig
var mx: uos.rtos.Mutex = .{ .name = "mx1" };           // static, defaults
var rmx: uos.rtos.Mutex = .initRecursive("rmx");

try mx.lock();
defer mx.unlock() catch {};
```

### Types and attributes

```zig
pub const Type       = enum(u8) { normal, errorcheck, recursive };
pub const Protocol   = enum(u8) { none, inherit, protect };
pub const Robustness = enum(u8) { stalled, robust };

pub const Attributes = struct {
    priority_ceiling: Priority = priority.highest,
    protocol: Protocol = .inherit,
    robustness: Robustness = .stalled,
    type: Type = .normal,
    max_count: u16 = max_count,   // recursive only
    clock: ?*Clock = null,
};
```

- **normal**: locking a mutex you already own is a deadlock (`WouldBlock`, by
  POSIX).
- **errorcheck**: self-lock returns `error.Deadlock`.
- **recursive**: the owner may lock again, up to `max_count`.
- **inherit** (default protocol): the owner's priority is boosted to the
  highest waiter's priority while the mutex is contended (priority
  inheritance).
- **protect**: priority-ceiling protocol; no thread above the ceiling may lock.
- **robust**: if the owner dies holding the mutex, the next `lock()` succeeds
  with `error.OwnerDead` (the mutex is held) and must call `consistent()`.

### Operations

```zig
try mx.lock();                    // wait as long as needed
try mx.tryLock();                 // only if free (error.WouldBlock otherwise)
try mx.timedLock(100);            // wait at most 100 ticks
mx.unlock() catch {};

mx.getOwner();                    // ?*Thread
mx.getType();
mx.getPriorityCeiling();
try mx.setPriorityCeiling(.high); // returns the previous ceiling
try mx.consistent();              // re-mark a robust mutex consistent
try mx.reset();                   // back to initial state, waking all waiters
```

`unlock()` of an error-checking, recursive or robust mutex by a non-owner is
`error.NotPermitted`. On `deinit()` the mutex must be free and have no waiters.

---

## 15. Semaphores

Binary or counting, POSIX semantics. `post()` and `tryWait()` may be called
from interrupt handlers.

```zig
var sem: uos.rtos.Semaphore = .counting("beats", 8, 0);
try sem.post();          // from an ISR too
try sem.wait();
```

```zig
const bin  = uos.rtos.Semaphore.binary("lock", 1);
const cnt  = uos.rtos.Semaphore.counting("slots", 16, 16);

try sem.post();          // wake one waiter; error.Again at the maximum
try sem.wait();          // wait as long as needed
try sem.tryWait();       // error.WouldBlock if 0 (ISR-safe)
try sem.timedWait(50);   // wait at most 50 ticks
sem.value();             // current value (0 while threads wait)
try sem.reset();         // back to the initial value, resume all waiters
```

The count is `i16`, maximum value `0x7FFF`.

---

## 16. Condition variables

A condition variable is always paired with a mutex; as in POSIX, wait in a loop
on the predicate.

```zig
try mx.lock();
while (!ready) try cv.wait(&mx);
// ... consume the condition ...
mx.unlock() catch {};
```

```zig
cv.signal();             // wake one waiter
cv.broadcast();          // wake all waiters
try cv.wait(&mx);        // atomically release mx, wait, re-lock mx
try cv.timedWait(&mx, 100);  // error.TimedOut (with mx locked again)
```

The internal wait links the thread first, then releases the mutex, all without
a context switch in between, so a signal between the two cannot be lost.

---

## 17. Event flags

Two kinds: **event flags objects** (shared, with their own wait list) and
**thread event flags** (one 32-bit word per thread). Both use a mask and a
match mode.

```zig
var ev: uos.rtos.EventFlags = .{ .name = "ev" };
_ = try ev.raise(0x3);                 // from an ISR too
const got = try ev.wait(0x1, .all_clear);
```

Masks and modes:

```zig
const flags = uos.rtos.flags;
flags.any;                 // 0: wait for any flag
flags.all;                 // 0xFFFFFFFF: wait for all flags

// Mode: all / any / clear
.{ .all = true }           // all flags of the mask must be raised
.{ .any = true }           // at least one flag of the mask
.{ .all = true, .clear = true }   // also clear the matched flags
flags.Mode.all_clear;
flags.Mode.any_clear;
```

Event flags object operations:

```zig
try ev.raise(mask);                // ISR-safe; wakes all waiters to re-check
try ev.wait(mask, mode);           // returns the matched flags
try ev.tryWait(mask, mode);        // ISR-safe; error.WouldBlock
try ev.timedWait(mask, timeout, mode);
try ev.clear(mask);
ev.get(mask, mode);
ev.waiting();                      // true when threads wait
```

Thread flags (per thread):

```zig
// from another thread / an ISR:
try th.flagsRaise(mask);           // ISR-safe; resumes the thread
try th.flagsClear(mask);

// from the current thread:
try uos.rtos.this_thread.flagsWait(mask, mode);
try uos.rtos.this_thread.flagsTryWait(mask, mode);
try uos.rtos.this_thread.flagsTimedWait(mask, timeout, mode);
uos.rtos.this_thread.flagsGet(mask, mode);
try uos.rtos.this_thread.flagsClear(mask);
```

---

## 18. Message queues

Fixed-size messages ordered by priority (FIFO among equal priorities). Senders
block when the queue is full, receivers when empty; the `try*` calls are
ISR-safe. Storage is one buffer whose size is computed with `storageSize()`.

```zig
var q: uos.rtos.MessageQueueTyped(Event).Static(8) = undefined;
try q.init("events", .{});
try q.queue.send(.{ .code = 1 }, 0);      // value, priority
const ev = try q.queue.receive();
```

The untyped `MessageQueue` works on byte slices:

```zig
var mq: uos.rtos.MessageQueue = .{};
var buf: [128]u8 = undefined;
try mq.init("q", 8, 8, &buf, .{});        // 8 messages of 8 bytes over buf
try mq.send("abcdefgh", 0);               // shorter messages are zero-padded
try mq.receive(dest);
```

Operations (send / receive, each with a blocking, a `try*` and a timed form):

```zig
try q.send(msg, prio);        try q.trySend(msg, prio);       try q.timedSend(msg, timeout, prio);
const p = try q.receive(buf); const p = try q.tryReceive(buf); const p = try q.timedReceive(buf, timeout);
q.length();  q.capacity();  q.msgSize();  q.isEmpty();  q.isFull();  try q.reset();
```

`storageSize(msgs, msg_size_bytes)` returns the bytes of storage for a queue.
`MessageQueueTyped(T).Static(n)` embeds that storage, so no allocator is needed;
`create(gpa, …)` allocates it instead.

---

## 19. Memory pools

Deterministic allocation of equal-sized blocks. `tryAlloc()` and `free()` are
ISR-safe.

```zig
var pool: uos.rtos.MemoryPoolTyped(Packet).Static(16) = .{};
try pool.init("packets", .{});
const p = try pool.pool.alloc();     // *Packet
try pool.pool.free(p);
```

The untyped form returns `*anyopaque`:

```zig
try mp.alloc();         // wait while empty
try mp.tryAlloc();      // error.WouldBlock if empty (ISR-safe)
try mp.timedAlloc(50);
try mp.free(block);     // ISR-safe; wakes one waiter
mp.countUsed();  mp.capacity();  mp.isEmpty();  mp.isFull();  try mp.reset();
```

Blocks are rounded up to a pointer, which also holds the free-list link. As
with message queues, `MemoryPoolTyped(T).Static(n)` embeds the storage, and
`create(gpa, …)` allocates it.

---

## 20. Software timers

One-shot or periodic; the callback runs in the **tick interrupt context**, so it
must not block and should be short.

```zig
var tm: uos.rtos.Timer = .init("blink", blink, null, .periodic);
try tm.start(500);     // first callback after 500 ticks
```

```zig
fn blink(_: ?*anyopaque) void {
    // toggle an LED, raise a flag, post a semaphore, ...
}
```

```zig
tm.init("t", func, null, .once);       // a static initialiser
tm.initWith("t", func, null, .{ .type = .periodic, .clock = &uos.rtos.sysclock });
try tm.start(period);   // (re)start; period 0 becomes 1
try tm.stop();          // error.Again when not running
tm.getState();          // initialized, running, completed, stopped, destroyed
```

A periodic timer re-arms itself before calling back, and on SMP the state is
checked and re-armed under the same lock `stop()` and `deinit()` take, so a
timer stopped by another CPU is never re-armed after the fact.

---

## 21. Memory allocators

The C++ `memory_resource` classes become `std.mem.Allocator` implementations, so
any Zig container or `std` API can use them directly.

| Allocator | Description |
| --- | --- |
| `uos.memory.FirstFitTop` | The system heap: first-fit, top-down. `.first_fit_top` or `.lifo` policy. |
| `uos.memory.BlockPool` | Fixed-size blocks; every allocation must fit one block. |
| `std.mem.Allocator.failing` | The C++ `null` resource: every allocation fails. |

None of them locks. `uos.memory.Locked` wraps any allocator in a scheduler
critical section, making it safe for threads (not for interrupt handlers):

```zig
var raw: uos.memory.FirstFitTop = .init("heap", arena, .first_fit_top);
var locked = uos.memory.Locked.init(raw.allocator());
const gpa = locked.allocator();
```

### The system heap

`uos.memory.allocator()` is the RTOS system heap: a thread-safe (locked)
`FirstFitTop` over the RAM the port leaves free, or over a static buffer of
`uos_options.dynamic_memory_size_bytes`. It is lazily initialised on first use.

```zig
const gpa = uos.memory.allocator();       // thread-safe std.mem.Allocator
uos.memory.systemHeap();                  // the FirstFitTop itself (not thread-safe)
uos.memory.statistics();                  // heap statistics
uos.memory.tracePrintStatistics();        // print them to the trace channel
```

---

## 22. Trace output

`uos.trace` is the printf of the kernel. It writes through an `std.Io.Writer`
whose sink is the port's trace channel (semihosting, a UART, ITM, RTT…). Whole
messages are written inside one interrupt critical section, so on SMP the lines
of two CPUs never mix.

```zig
uos.trace.puts("hello");                 // a line
uos.trace.putchar('.');
uos.trace.print("value {d}\n", .{42});   // the trace::printf() equivalent
```

Plug it into `std.log`:

```zig
pub const std_options: std.Options = .{ .logFn = uos.trace.logFn };
```

`uos.trace.writer()` returns an unbuffered `*std.Io.Writer` for code that wants
one; `uos.trace.dumpArgs(args)` prints program arguments.

---

## 23. `std.Io` and devices

`uos.Io` is a full `std.Io` implementation running on µOS++ threads — the Zig
0.17 "new I/O" interface backed by the RTOS. Generic Zig code written against
`std.Io` runs unchanged:

```zig
var rtos_io: uos.Io = .init(uos.memory.allocator());
const io = rtos_io.io();

var f = try io.concurrent(work, .{ io, 42 });   // an RTOS thread
const r = f.await(io);                          // Thread.join()
try io.sleep(.fromMilliseconds(10), .awake);
```

| `std.Io` | µOS++ |
| --- | --- |
| `concurrent`, `Group.concurrent` | a new `Thread`, stack from the allocator |
| `await`, `Group.await` | `Thread.join()` |
| `cancel` | cancel request + `Thread.interrupt()` |
| `futexWait` / `futexWake` | hashed wait lists in the kernel |
| `sleep`, `Timeout` | `sysclock` ticks |
| `now(.awake/.boot/.cpu_*)` | `hrclock` |
| `now(.real)` | `rtclock` |
| stdout/stderr writes | the trace channel |

### The device layer

`uos.io.devices` provides char and block devices, partitions, a device registry
and a TTY over the trace channel, all with `std.Io.Reader`/`Writer` interfaces:

```zig
var registry: uos.io.devices.Registry(4) = .{};
var tty: uos.io.devices.TraceTty = .{};
try registry.add(tty.device("tty"));
const dev = registry.find("/dev/tty").?;
```

A `CharDevice` is a type-erased pointer plus a vtable with `read`/`write`
(and optional `open`/`close`/`ioctl`); a `BlockDevice` has `read_blocks` /
`write_blocks` / `block_size` / `num_blocks` / `sync`. Ready-made pieces
include `TraceTty` (the trace channel as `/dev/tty`), `RingBuffer` (an
ISR-safe byte FIFO for a UART receive path), `RamDisk`, `Partition`,
`LockedBlockDevice` (a block device serialised by a mutex), `Registry` and
`FileDescriptors`. See [§24](#writing-device-drivers-uart-spi-i2c-adc-dma) for
how to connect your own driver to this layer.

File systems (the C++ FatFS layer) are not part of this layer; a block device is
the place to mount one.

---

## 24. Writing device drivers (UART, SPI, I2C, ADC, DMA)

Device drivers live in the **board** (or in a file it imports) and talk to the
hardware through bare registers. There is no HAL requirement: the pattern is a
`*volatile u32` cast from a fixed address, exactly as the C++ board glue did.
This section shows the real patterns used by the ports.

### 24.1 The register-access idiom

```zig
const RCC_APB2ENR: *volatile u32 = @ptrFromInt(0x4002_3844);
const SPI1_CR1:   *volatile u32 = @ptrFromInt(0x4001_3000);

RCC_APB2ENR.* |= (1 << 12);      // enable the SPI1 clock
SPI1_CR1.* = (1 << 2) | (1 << 6); // master, SPI enable
```

Addresses come from the chip's reference manual; the structs, bit masks and
field offsets are plain `const`s. Polling loops are bounded where a device can
stick, so a driver never hangs the kernel.

### 24.2 Polled UART (the console)

The board contract expects `uartWrite()`/`uartFlush()`, which the port uses for
the trace channel. A minimal polled USART is about forty lines:

```zig
const UsartConfig = struct { base: usize, apb: u2, enable_bit: u5, tx_pin: u5, rx_pin: u5 };

fn Usart(comptime cfg: UsartConfig) type {
    return struct {
        const SR  = @as(*volatile u32, @ptrFromInt(cfg.base + 0x00));
        const DR  = @as(*volatile u32, @ptrFromInt(cfg.base + 0x04));
        const CR1 = @as(*volatile u32, @ptrFromInt(cfg.base + 0x0C));

        pub fn write(bytes: []const u8) void {
            for (bytes) |c| {
                if (c == '\n') put('\r');
                put(c);
            }
        }
        fn put(c: u8) void {
            while (SR.* & (1 << 7) == 0) {}   // wait TXE
            DR.* = c;
        }
        pub fn flush() void {
            while (SR.* & (1 << 6) == 0) {}   // wait TC
        }
    };
}
```

### 24.3 Interrupt-driven UART

A polled console costs a spin per byte. An interrupt-driven transmitter copies
into a ring and lets the TXE interrupt drain it; a full ring sends one byte by
polling first, so `write()` works in any context, a tick handler included:

```zig
fn BufferedUsart(comptime cfg: UsartConfig, comptime irq_number: u32, comptime ring_size: usize) type {
    return struct {
        var ring: [ring_size]u8 = undefined;
        var head: usize = 0;   // next free slot
        var tail: usize = 0;   // next byte to send

        pub fn write(bytes: []const u8) void {
            for (bytes) |c| put(c);
        }
        fn put(c: u8) void {
            const p = mask();                    // PRIMASK, asm cpsid i
            defer unmask(p);
            if ((head + 1) % ring_size == tail) sendOnePolled();
            ring[head] = c;
            head = (head + 1) % ring_size;
            CR1.* |= CR1_TXEIE;                  // ask for the TXE interrupt
        }
        pub fn irq() callconv(.c) void {         // the USART interrupt
            while (SR.* & SR_TXE != 0) {
                if (head == tail) { CR1.* &= ~CR1_TXEIE; return; }
                DR.* = ring[tail];
                tail = (tail + 1) % ring_size;
            }
        }
    };
}
```

The board installs `irq` as the USART's handler by declaring it in
`board.interrupts` (see [§27](#adding-a-new-board)); the port merges that struct
into the MicroZig interrupt vector table. The receive side is the same shape,
feeding `uos.io.devices.RingBuffer` from the interrupt and letting a thread
block on the device.

### 24.4 SPI master + a NOR flash

This is the driver from the WeAct F411 `spi-pipeline` test: SPI1 in master
mode with a software chip select on PA4, talking to a W25Q128. The key part is
the byte exchange — write the data register, wait TXE, wait RXNE, read:

```zig
const SPI1_SR: *volatile u32 = @ptrFromInt(0x4001_3008);
const SPI1_DR: *volatile u32 = @ptrFromInt(0x4001_300C);

fn csAssert() void   { GPIOA_BSRR.* = (1 << (4 + 16)); }  // PA4 low
fn csDeassert() void {
    while ((SPI1_SR.* & (1 << 7)) != 0) {}                // wait BSY clear
    GPIOA_BSRR.* = (1 << 4);                              // PA4 high
}

fn xfer(data: u8) u8 {
    while ((SPI1_SR.* & (1 << 1)) == 0) {}   // TXE
    SPI1_DR.* = data;
    while ((SPI1_SR.* & (1 << 0)) == 0) {}   // RXNE
    return @truncate(SPI1_DR.*);
}
```

On top of `xfer()` you build the flash protocol — `readId()`, `read(addr)`,
`write(addr)`, `erase(addr)` — each one asserting CS, sending the command and
address bytes, transferring the payload, and deasserting CS with the chip's
settling delay. A whole 5-thread pipeline (producer, encoder, writer, monitor,
verifier) is then wired with semaphores exactly as in [§4.1](#worked-examples-single-core-and-multi-core).

### 24.5 I²C (and the general shape)

The repository does not ship an I²C driver, but it is the same pattern as the
USART and SPI drivers above — a register block at a fixed address, clock
enable, pin alternate functions, then byte-level read/write. A master
write-byte on an STM32 would look like this in outline:

```zig
// Illustrative skeleton; the real driver is the same shape as §24.2/§24.4.
fn i2cStart(addr: u8, write: bool) void {   // generate START, send address+R/W
    I2C_CR1.* |= (1 << 8);                  // START
    while ((I2C_SR1.* & (1 << 0)) == 0) {}  // SB
    I2C_DR.* = (addr << 1) | @intFromBool(!write);
    while ((I2C_SR1.* & (1 << 1)) == 0) {}  // ADDR
    _ = I2C_SR2.*;                          // clear ADDR
}
fn i2cWrite(byte: u8) void {
    while ((I2C_SR1.* & (1 << 7)) == 0) {}  // TXE
    I2C_DR.* = byte;
    while ((I2C_SR1.* & (1 << 2)) == 0) {}  // BTF
}
```

The point is not the exact register names (they are chip-specific) but the
shape: enable clocks, configure pins, poll status flags, transfer bytes, and
wrap the whole thing so it is **thread-safe** (below).

### 24.6 ADC and DMA

Polled conversions follow the same shape (from the RP2350 ADC driver):

```zig
pub fn read(channel: u32) u16 {
    reg(b + ADC_CS).* = (reg(b + ADC_CS).* & ~CS_AINSEL_BITS) | CS_EN |
        ((channel << CS_AINSEL_LSB) & CS_AINSEL_BITS) | CS_START_ONCE;
    while (reg(b + ADC_CS).* & CS_READY == 0) {}      // poll READY
    return @intCast(reg(b + ADC_RESULT).* & 0x0FFF);
}
```

For bulk transfers, the F412 board uses a DMA-driven UART (`stm32f4_uart_dma.zig`):
the DMA controller copies a buffer to the peripheral without the CPU, and the
completion interrupt posts a semaphore. The general recipe is the same as the
interrupt UART: a DMA channel descriptor, an ISR that posts a semaphore, and a
thread that waits on it.

### 24.7 Making a driver thread-safe

A register-level driver is not thread-safe on its own — two threads could
interleave a multi-byte transfer. Three options, in increasing order of
complexity:

1. **Serialize with a mutex** at the driver's public entry points. This is the
   simplest and works across CPUs on SMP:

   ```zig
   var spi_lock: uos.rtos.Mutex = .{ .name = "spi" };
   fn flashRead(addr: u32, buf: []u8) !void {
       try spi_lock.lock();
       defer spi_lock.unlock() catch {};
       // ... csAssert, xfer command, xfer data, csDeassert ...
   }
   ```

2. **Restrict the device to one thread** (e.g. a dedicated "driver thread" that
   owns the peripheral and receives requests over a message queue). This is the
   cleanest when the device needs long, blocking sequences and priority
   control.

3. **Keep it ISR-only** (e.g. the receive ring buffer) so a single producer
   (the ISR) and consumer (one thread) never race.

### 24.8 Connecting a driver to the device layer

To expose a driver through the POSIX-style API, implement the `CharDevice`
vtable (or `BlockDevice` for storage) and register it:

```zig
const MyUart = struct {
    fn read(_: *anyopaque, buf: []u8) uos.io.devices.Error!usize { ... }
    fn write(_: *anyopaque, bytes: []const u8) uos.io.devices.Error!usize { ... }
};

var uart: MyUart = .{};
var registry: uos.io.devices.Registry(4) = .{};
try registry.add(.{ .name = "uart0", .kind = .{ .char = .{ .ptr = &uart, .vtable = &.{
    .read = MyUart.read, .write = MyUart.write,
} } } });

const dev = registry.find("/dev/uart0").?;
var buf: [64]u8 = undefined;
var w = dev.char.writer(&buf);
try w.interface.print("hi {d}\n", .{42});
try w.interface.flush();
```

For storage, implement `BlockDevice` and wrap it with `LockedBlockDevice` (which
serialises operations with a mutex) before handing it to a partition or a file
system.

---

## 25. Interfacing with C

C sources can be linked with the kernel and call it through the same C API as
the C++ project. There is still **one** kernel: the C functions are thin
wrappers that convert their arguments and call the Zig objects.

### 25.1 Enable it and add the headers

In `uos_options`:

```zig
pub const uos_options: uos.Options = .{
    .c_api = true,       // the µOS++ C API (os_thread_*, os_mutex_*, ...)
    .cmsis_os = true,    // optional: CMSIS-RTOS v1 (osThread*, ...)
    .c_runtime = true,   // on freestanding targets: printf, string functions
};
```

In `build.zig`, add the include folders and the C source file:

```zig
uos_build.addCIncludes(kernel_dep, exe.root_module, true);   // freestanding
exe.root_module.addCSourceFiles(.{ .files = &.{ "mycode.c" }, .flags = &.{"-std=c11"} });
```

The headers are the C++ ones (`include/cmsis-plus/rtos/os-c-api.h`,
`include/cmsis-plus/legacy/cmsis_os.h`). The object types (`os_thread_t`,
`os_mutex_t`, …) are **opaque storage** sized for the Zig objects: C code
allocates them and passes pointers, and never reads their members. The sizes
are declared in `os-c-decls.h` and checked against the Zig objects at build
time and by a host test; a port may raise them (the POSIX port does, for its
`ucontext`s).

### 25.2 A complete C example

```c
#include <cmsis-plus/rtos/os-c-api.h>
#include <stdio.h>

void* worker(void* args) {
    (void) args;
    printf("hello from a C thread\n");
    return NULL;
}

int run_demo(void) {
    // A mutex (static storage).
    os_mutex_t mx;
    os_mutex_construct(&mx, "mx", NULL);
    os_mutex_lock(&mx);
    os_mutex_unlock(&mx);

    // A binary semaphore, safe to post from an ISR.
    os_semaphore_t sem;
    os_semaphore_binary_construct(&sem, "sem", 0);
    os_semaphore_post(&sem);    // os_ok, or an errno on overflow
    os_semaphore_wait(&sem);

    // A thread with a static stack.
    static char stack[2048];
    os_thread_attr_t attr;
    os_thread_attr_init(&attr);
    attr.th_stack_address = stack;
    attr.th_stack_size_bytes = sizeof(stack);
    attr.th_priority = os_thread_priority_normal;

    os_thread_t th;
    os_thread_construct(&th, "worker", worker, NULL, &attr);
    os_thread_join(&th, NULL);
    os_thread_destruct(&th);

    return 0;
}
```

The C API is the familiar one: `os_thread_construct/new/join/destruct`,
`os_mutex_lock/timed_lock/unlock`, `os_semaphore_post/wait/timed_wait`,
`os_sched_lock`/`os_sched_set_locked`, `os_irq_critical_enter/exit`,
`os_sysclock_sleep_for`, and the message queue / memory pool / event flag /
timer families. Every function returns an `os_result_t` (0 = `os_ok`, or a
POSIX errno).

### 25.3 Calling C from Zig

Declare the C function and call it; the linker resolves the symbol:

```zig
extern fn test_c_api() c_int;

fn appMain() u8 {
    const ret = test_c_api();   // a function in a .c file
    return if (ret == 0) 0 else 1;
}
```

The other direction is automatic: the `os_*` functions are exported symbols
that C calls directly.

### 25.4 The minimal C runtime

On a freestanding target there is no libc. Enabling `c_runtime` provides the
few functions such C code needs, with the output on the trace channel:

- `stdio.h`: `printf`, `vprintf`, `snprintf`, `puts`, `putchar`, `fprintf`
  (stdout and stderr both go to the trace channel),
- `string.h`: `strlen`, `strcmp`, `strncmp`, … (`mem*` come from compiler-rt),
- `stdlib.h` / `assert.h`: `exit`, `_Exit`, `abort`, `assert`.

Do not enable `c_runtime` on hosted targets (they already have a libc).

---

## 26. Linker scripts and the memory map

µOS++ builds on **MicroZig**, which generates the linker script for you from a
small declarative description. Understanding that description is all you need
to place code and data, add a region (external PSRAM/SDRAM), or bring up a new
chip.

### 26.1 Where the script comes from

A MicroZig chip declares two things:

1. **`memory_regions`** — the physical memories: flash and RAM, each with an
   offset, length and access flags. For the RP2040 this is:

   ```zig
   .memory_regions = &.{
       .{ .tag = .flash, .offset = 0x10000000, .length = 2 * 1024 * 1024, .access = .rx },
       .{ .tag = .ram,   .offset = 0x20000000, .length = 256 * 1024,     .access = .rwx },
   },
   ```

   An STM32F411 declares its banked flash and SRAM the same way
   (`BANK_1` at `0x08000000`, `SRAM` at `0x20000000`).

2. **`linker_script.file`** — an optional fragment with chip-specific sections.
   The RP2040's is the 256-byte second-stage bootloader:

   ```ld
   SECTIONS {
     .boot2 : {
       __boot2_start__ = .;
       KEEP (*(.boot2))
       __boot2_end__ = .;
     } > flash0
     ASSERT(__boot2_end__ - __boot2_start__ == 256,
       "ERROR: Pico second stage bootloader must be 256 bytes in size")
   }
   INSERT BEFORE .flash_start;
   ```

At build time MicroZig's `generate_linker_script.zig` emits the full script:
the `MEMORY` block from `memory_regions`, the standard `.text`/`.rodata`/
`.data`/`.bss` sections, and a `.heap` section that spans the whole RAM region,
then **appends** your fragment (which uses `INSERT` to splice in the extra
section).

### 26.2 The symbols the kernel relies on

The generated script exports a fixed set of symbols:

| Symbol | Meaning |
| --- | --- |
| `microzig_heap_start` / `microzig_heap_end` | the whole RAM not taken by static data |
| `microzig_data_start` / `microzig_data_end` | the `.data` image |
| `microzig_bss_start` / `microzig_bss_end` | zeroed `.bss` |
| `microzig_flash_end` | end of the flash image |
| `end_of_stack` | the top of RAM, from `microzig.config.stack` |

The µOS++ Cortex-M port uses two of these directly:

- **`end_of_stack`** becomes the MSP (interrupt) stack base.
- **`microzig_heap_start`** to `end_of_stack` (minus the interrupt stack) is
  handed to the kernel as the RTOS heap arena, via the port's `freeRam()`.

That is why you never see an explicit "heap size" in most µOS++ builds: the RTOS
heap is simply "the rest of RAM" after `.data`, `.bss`, the MSP and (on the RP
chips) the reserved stack are accounted for.

### 26.3 Placing code and data in special sections

Zig's `linksection()` puts a function or variable in a named output section. The
RP2350 PSRAM driver uses it to run time-critical code from RAM instead of flash
XIP:

```zig
pub noinline fn init() linksection(".ram_text") bool { ... }
```

MicroZig's generated script keeps `*(.ram_text)` and copies it to RAM at
start-up. The same trick serves anything that must run while flash is being
reconfigured, or that must not be fetched over XIP.

### 26.4 Changing the memory layout

Three cases, in increasing order of effort:

1. **Different flash/RAM size on a known chip.** Derive a new chip/board target
   with new `memory_regions`. The Cortex-M port already does this for the WeAct
   RP2350B (16 MB flash) by mapping to the Adafruit Metro RP2350 target rather
   than the stock 4 MB Pico 2.

2. **A new region (external PSRAM/SDRAM).** Add the region to `memory_regions`
   (for example a `.{ .tag = .ram, .offset = 0x11000000, .length = 8 * 1024 * 1024,
   .access = .rwx }` for the RP2350's PSRAM XIP window) so the linker knows it
   exists, then place data there with `linksection()` or a custom section
   fragment.

3. **A brand-new chip.** Declare its `memory_regions` and any `linker_script.file`
   fragment in the port's chip table, and MicroZig generates the rest.

You almost never write a full GNU ld script by hand; you describe the memories
and any extra sections, and the generator composes the rest.

---

## 27. Adding a new board

A **board** is a build configuration of one architecture port, not a new
repository. Adding a board to the Cortex-M port (the common case) is a matter of
five steps, illustrated with the existing WeAct F411:

### 1. Add the board id

In the port's `build.zig`, add a variant to `BoardId`:

```zig
pub const BoardId = enum {
    weactf411,
    nucleof411,
    weactf412,
    pico,
    pico2,
    @"pico2-rp2350b-psram",
    myboard,          // ← new
};
```

### 2. Add the board entry

```zig
pub const boards = [_]Board{
    .{ .id = .weactf411, .source = "src/boards/weactf411.zig", .ncpu = 1 },
    .{ .id = .myboard, .source = "src/boards/myboard.zig", .ncpu = 1 },  // ← new
};
```

`ncpu` tells the build whether the board is SMP (it disables SMP-only tests on
single-core boards, and sets the firmware's `single_threaded` correctly).

### 3. Map the board to a MicroZig target

```zig
fn boardTarget(mb: *MicroBuild, id: BoardId) *const microzig.Target {
    return switch (id) {
        .weactf411 => mb.ports.stm32.chips.STM32F411CE,
        .myboard   => mb.ports.stm32.chips.STM32F401RE,   // ← new
        ...
    };
}
```

### 4. Write the board driver

Create `src/boards/myboard.zig` implementing the board contract the port
expects:

```zig
const microzig = @import("microzig");

pub const name = "My Board (STM32F401RE, Cortex-M4F)";
pub const ncpu = 1;

pub fn init() void {
    // set up clocks, LED, console ...
}

pub const led = struct {
    pub fn init() void { ... }
    pub fn set(on: bool) void { ... }
    pub fn toggle() void { ... }
};

pub fn uartWrite(bytes: []const u8) void { ... }   // the console
pub fn uartFlush() void { ... }
pub fn cpuFrequencyHz() u32 { ... }

// Optional: interrupt handlers the port should install.
// pub const interrupts = struct { EXTI0 = .{ .c = myHandler } };
// Optional: extra interrupt stack for the MSP.
// pub const interrupt_stack_size_bytes = 2048;
```

The contract is small and everything else is optional:

| Member | Required | Meaning |
| --- | --- | --- |
| `name: []const u8` | yes | Human-readable board name (printed in the greeting) |
| `ncpu: u8` | yes | Number of cores (also declared in `build.zig`) |
| `init()` | yes | Board bring-up: clocks, LED, console |
| `cpuFrequencyHz()` | yes | System clock, used for SysTick and the greeting |
| `uartWrite(bytes)` | no | Console output used by the trace channel |
| `uartFlush()` | no | Wait for the console to drain (used before `SYS_EXIT`) |
| `led` | no | `init`/`set`/`toggle`, for the LED test |
| `interrupts` | no | Extra interrupt handlers the port installs |
| `interrupt_stack_size_bytes` | no | Extra bytes reserved for the MSP |

### 5. (Optional) board-specific tests

The build looks for a test in `test/<name>/main.zig`, unless it is overridden
by a board-specific one in `test/<board>/<name>/main.zig` (listed in the
`board_tests` table). Add your overrides there when a test needs board-specific
behaviour.

### Build and run

```sh
zig build -Dboard=myboard              # build every test of the board
zig build run -Dboard=myboard -Dtest=smp-test1   # build and run one test
```

The same five-step shape applies to the AArch32/AArch64 ports, where boards map
to their own targets and boot sequences.

---

## 28. Adding a new architecture port

An **architecture port** is a separate repository (`micro-os-plus-iii-<arch>`)
that provides one Zig module imported by the kernel as `uos_port`. The kernel
checks it against a compile-time contract and names any missing piece, so a
port that builds but is incomplete fails with a clear message.

The port must declare, at minimum:

```zig
const uos = @import("uos");

// Stacks and contexts
pub const StackElement = u32;
pub const stack_alignment: usize = 8;
pub const Context = struct { stack_ptr: ?[*]StackElement = null };
pub fn contextCreate(ctx: *Context, stack: []StackElement,
    entry: *const fn (?*anyopaque) callconv(.c) noreturn, arg: ?*anyopaque) void { ... }

// Interrupts
pub const interrupts = struct {
    pub const State = u32;
    pub fn criticalEnter() State { ... }   // mask (and, on SMP, take the kernel lock)
    pub fn criticalExit(state: State) void { ... }
    pub fn uncriticalEnter() State { ... }
    pub fn uncriticalExit(state: State) void { ... }
    pub fn inHandlerMode() bool { ... }
    pub fn isPriorityValid() bool { ... }
};

// Scheduler
pub const scheduler = struct {
    pub fn initialize() void { ... }
    pub fn start() noreturn { ... }
    pub fn setLocked(locked: bool) bool { ... }
    pub fn isLocked() bool { ... }
    pub fn reschedule() void { ... }
    pub fn waitForInterrupt() void { ... }
    pub fn cpuId() u32 { ... }
    pub fn ipi(cpu: u32) void { ... }
    pub fn prepareSuspend() void {}
    pub fn greeting(w: *std.Io.Writer) std.Io.Writer.Error!void { ... }
};

// Clocks and trace
pub const clock_systick = struct { pub fn start() void { ... } };
pub const clock_highres = struct { /* start, has_hardware_counter,
    hardwareCounter, inputClockFrequencyHz, cyclesPerTick, cyclesSinceTick */ };
pub const trace = struct { pub fn write(bytes: []const u8) void { ... } };
```

Optional pieces: `interruptStack()`, `terminate(code)`, `freeRam()`,
`stack_magic`, `c_storage_words`, a port `Options` struct (root
`uos_port_options`), and `semihosting` for `uos.semihosting`.

The two duties that matter most:

1. **The context switch** saves the outgoing context, calls
   `uos.rtos.scheduler.internalSwitchThreads()` with interrupts masked (and the
   kernel lock held on SMP), and restores `scheduler.current_thread[cpu]`. On
   SMP it publishes the outgoing `stack_ptr` only once the context is fully
   saved, and clears the incoming one before resuming it.
2. **The tick** calls `uos.rtos.clocks.sysTickHandler()` (CPU 0 only on SMP);
   the kernel then requests a reschedule.

Bring up the other CPUs of an SMP target from the port, each one making its
boot pseudo-thread current with `uos.rtos.scheduler.internalPrepareCpu(cpu)`,
starting its tick and requesting its first switch. The four ports in this tree
(Cortex-M, AArch32, AArch64, POSIX) are the worked examples; see also
`docs/port-architecture-and-internals.md` and
`docs/aarch32-aarch64-smp-amp-porting-guide.md`.

---

## 29. The main parts in code: boot, threads, scheduler, context switch, interrupts

The API sections above tell you *what to call*; this section shows *how the
kernel actually does it*, with the real code of this tree (the Cortex-M port
for the machine-specific parts). It is the "under the hood" companion, and the
context-switch and interrupt parts are exactly what a port author must
reproduce ([§28](#adding-a-new-architecture-port)).

### 29.1 Boot: from reset to the first thread

The boot is a chain of small, clearly-owned steps. Tracing it end to end:

**1. The reset vector.** The CPU reads the vector table at address 0: word 0 is
the initial stack pointer, word 1 the reset handler. MicroZig generates this
table from the chip's `memory_regions` ([§26](#linker-scripts-and-the-memory-map));
the initial stack pointer is `end_of_stack` (the top of RAM) and the reset
handler is `_start`. On the RP2040/RP2350 a 256-byte **stage-2 bootloader**
(`.boot2`) runs first and then jumps to the same `_start`.

**2. `_start`** (MicroZig, `core/src/cpus/cortex_m.zig`) prepares C and Zig
land and calls your `main`:

```zig
pub fn _start() callconv(.c) noreturn {
    microzig.utilities.initialize_system_memories(.auto); // copy .data, zero .bss
    // ... enable the FPU if present, enable the fault handlers ...
    @call(.never_inline, microzig_main, .{});             // microzig_main is your main()
}
```

**3. Your `main`** hands the real entry to the kernel:

```zig
pub fn main() void {
    uos.rtos.run(appMain);
}
```

**4. `uos.rtos.run`** (kernel, `rtos/startup.zig`) creates the main and idle
threads and starts the scheduler:

```zig
pub fn run(comptime app_main: anytype) noreturn {
    scheduler.initialize() catch unreachable;  // port: mask IRQs, call board.init()
    // ... print the greeting ...
    main_thread_storage.init("main", Main.trampoline, null, .{ ... }); // the main thread
    createIdleThreads();                       // one idle thread per CPU
    scheduler.start();                         // start the clocks, first switch
}
```

**5. `scheduler.start()`** (kernel, `rtos/scheduler.zig`) starts the three
clocks, latches the preemptive flag and defers to the port:

```zig
pub fn start() noreturn {
    clocks.sysclock.start();
    clocks.hrclock.start();
    clocks.rtclock.start();
    is_preemptive = config.options.preemptive;
    is_started = true;
    port.scheduler.start();   // the port performs the first context switch
}
```

**6. `port.scheduler.start()`** (Cortex-M port) is the hand-off to hardware:
thread mode switches to the process stack pointer (PSP), the main stack pointer
(MSP) restarts at the top of RAM as the interrupt stack, PendSV/SysTick are set
to the lowest priority, and a PendSV is pended so the first context switch
happens as soon as interrupts are enabled:

```zig
pub fn start() noreturn {
    arch.disableIrq();
    arch.fpuEnableStacking();
    switchToPsp();                  // thread mode now runs on the PSP
    arch.setMsp(end_of_stack);      // the MSP is now the interrupt stack
    // ... fill the unused interrupt stack with the magic word, for statistics ...
    arch.setPendSvSysTickLowest();  // PendSV and SysTick at the lowest priority
    uos.rtos.scheduler.internalPrepareCpu(0);   // CPU 0 "runs" its boot pseudo-thread
    if (smp) launchCore1();         // bootrom FIFO handshake on the RP chips
    reschedule();                   // set PendSV
    arch.enableIrq();
    while (true) arch.nop();        // the first PendSV fires here
}
```

On SMP, `launchCore1()` releases core 1, whose `secondaryStart()` sets up its
own PendSV/SysTick/IPI, calls `internalPrepareCpu(1)`, and requests its own
first switch — the same sequence, one per core.

### 29.2 Threads: the object and its first frame

A `Thread` is an **intrusive** object: it carries a list node and lives at a
stable address, so the scheduler can link it by pointer and never move it.
`ThreadInclusive(N)` is the convenience wrapper that embeds the stack next to
the object:

```zig
pub fn ThreadInclusive(comptime stack_size_bytes: usize) type {
    return struct {
        thread: Thread,
        stack: [stack_size_bytes / @sizeOf(StackElement)]StackElement align(8),
    };
}
```

The essential `Thread` fields are the function and its arguments, the assigned
and inherited priorities, the state, the CPU affinity, the ready-list node, and
the machine context:

```zig
func: ?Func,           // the thread body
func_args: ?*anyopaque,
func_result: ?*anyopaque,   // what join() returns
prio_assigned: Priority,    // the priority you asked for
prio_inherited: Priority,   // raised by mutex inheritance
state: State,               // ready / running / suspended / terminated / ...
cpu_affinity: u32,          // SMP: one bit per allowed CPU
ready_node: WaitingThreadNode,  // links in the ready list (or the funeral list)
context: Context,           // stack + the port's saved registers
```

Creating a thread builds its **first stack frame**, so the very first context
switch "returns" into the thread body as if it had been running before. The
port does this in `contextCreate()` by writing a fake exception frame at the top
of the stack. On Cortex-M the frame mirrors exactly what PendSV saves, so save
and restore are symmetric:

```zig
pub const Frame = extern struct {
    r4: u32, r5: u32, r6: u32, r7: u32,
    r8: u32, r9: u32, r10: u32, r11: u32,
    exc_return: u32,
    // restored by the exception return:
    r0: u32, r1: u32, r2: u32, r3: u32,
    r12: u32, lr: u32, pc: u32, xpsr: u32,
};

pub fn contextCreate(ctx: *Context, stack: []StackElement,
    entry: *const fn (?*anyopaque) callconv(.c) noreturn, arg: ?*anyopaque) void {
    var p: usize = @intFromPtr(stack.ptr + stack.len) - @sizeOf(Frame);
    p &= ~@as(usize, 3);              // word-align
    if (p & 7 == 0) p -= 4;           // keep the hardware frame 8-byte aligned
    const f: *Frame = @ptrFromInt(p);
    f.* = .{
        .xpsr = 0x0100_0000,          // the Thumb bit
        .pc = @intFromPtr(entry) | 1, // "return" to the entry, in Thumb
        .lr = @intFromPtr(entry) + 2, // never used: the entry does not return
        .r0 = @intFromPtr(arg),       // the thread argument
        .exc_return = 0xFFFF_FFFD,    // thread mode, PSP, basic frame
        // r1..r12 are filled with recognisable canary values for debugging
    };
    ctx.stack_ptr = @ptrFromInt(p);
}
```

The rest of thread creation — in `internalConstruct()` — sets the stack, links
the thread to its parent, fills the stack with the magic word
(`stack.initialize()`), calls `contextCreate()`, and then `resume()`s the
thread, which links it into the ready list and requests a reschedule.

### 29.3 The scheduler: ready list, pick, and preemption

The scheduler's whole state is one **priority-ordered ready list** plus a
current-thread pointer per CPU:

```zig
pub var ready_threads_list: lists.ReadyThreadsList = .{};
pub var current_thread: [ncpu]?*Thread = @splat(null);
```

`linkByPriority()` keeps the list sorted: highest priority first, FIFO among
equals. A thread becomes runnable by `resume()`, which links its `ready_node`
in that order and requests a reschedule.

The core of the scheduler is `internalSwitchThreads()`, called by the port
*from inside the context switch* with the kernel lock held and interrupts
masked. It re-links the outgoing thread and picks the next one. The
single-core path is:

```zig
pub fn internalSwitchThreads() void {
    const cpu = port.scheduler.cpuId();
    // ... (optional) CPU-cycle statistics ...
    if (!locked()) {
        const old_thread = current_thread[cpu].?;
        old_thread.internalRelinkRunning();          // put it back on the ready list
        current_thread[0] = ready_threads_list.unlinkHead();  // highest priority next
    }
}
```

On SMP the pick walks the same shared list but applies the affinity gate — it
skips a thread whose `cpu_affinity` excludes this CPU, and skips one whose saved
stack pointer is `null` (meaning its registers are still live on another CPU):

```zig
var it = ready_threads_list.list.iterator();
while (it.next()) |links| {
    const th = WaitingThreadNode.fromLinks(links).thread;
    if (isThreadAllowedOnCpu(th, cpu) and
        (th == old_thread or (th.state != .running and
            @atomicLoad(..., &th.context.port.stack_ptr, .acquire) != null)))
    {
        next_thread = th;   // found: unlink it and mark it running
        break;
    }
}
```

`preemption` is simply a reschedule request after a higher-priority thread
became ready. The port's `reschedule()` pends PendSV — but only when it is safe
to switch, deferring otherwise:

```zig
pub fn reschedule() void {
    if (isLocked() or (interrupts.inHandlerMode() and !uos.rtos.scheduler.isPreemptive())) return;
    arch.scs.ICSR.* = arch.scs.ICSR_PENDSVSET;   // request PendSV
}
```

Because PendSV runs at the lowest priority, the actual switch waits until any
interrupt handler has finished — the mechanism behind [§29.5](#the-main-parts-in-code-boot-threads-scheduler-context-switch-interrupts).

### 29.4 The context switch: PendSV and stack swapping

The context switch is the PendSV exception, running on the **MSP** so the
thread's own stack (the PSP) is never used by the switch itself. The
ARMv7-M/v8-M handler saves the callee-saved registers onto the outgoing
thread's stack, calls the kernel, then restores the incoming thread's
registers and returns:

```asm
mrs r0, psp              ; r0 = outgoing thread's stack pointer
isb
tst lr, #0x10            ; was the FPU used (extended frame)?
it eq
vstmdbeq r0!, {s16-s31}  ;   if so, save the high FP registers too
stmdb r0!, {r4-r11, lr}  ; save r4-r11 and EXC_RETURN (this becomes the Frame)
bl uos_port_switch_stacks; call the kernel: returns the incoming stack pointer
ldmia r0!, {r4-r11, lr}  ; restore the incoming r4-r11 and EXC_RETURN
tst lr, #0x10
it eq
vldmiaeq r0!, {s16-s31}  ;   restore the high FP registers if needed
msr psp, r0              ; switch the PSP to the incoming thread
isb
bx lr                    ; exception return into the incoming thread
```

The `r4-r11, lr` block is exactly the `Frame` that `contextCreate()` built in
[§29.2](#the-main-parts-in-code-boot-threads-scheduler-context-switch-interrupts) —
save and restore are the same shape.

The C-callable middle, `uos_port_switch_stacks()`, is where the kernel takes
over. It masks interrupts (and takes the kernel lock on SMP), **publishes** the
outgoing stack pointer, asks the scheduler for the next thread, and **claims**
the incoming one by clearing its pointer:

```zig
export fn uos_port_switch_stacks(sp: [*]StackElement) callconv(.c) [*]StackElement {
    const pri = arch.getPrimask();
    arch.disableIrq();
    defer arch.setPrimask(pri);
    if (smp) { /* acquire the kernel lock recursively */ }

    const old_thread = uos.rtos.scheduler.current_thread[cpu].?;
    @atomicStore(?[*]StackElement, &old_thread.context.port.stack_ptr, sp, .release); // publish

    uos.rtos.scheduler.internalSwitchThreads();   // pick the next thread

    const new_thread = uos.rtos.scheduler.current_thread[cpu].?;
    var out_sp: [*]StackElement = sp;
    if (new_thread != old_thread) out_sp = new_thread.context.port.stack_ptr.?;
    if (smp) @atomicStore(?[*]StackElement, &new_thread.context.port.stack_ptr, null, .release); // claim
    return out_sp;   // PendSV restores from here
}
```

The publish/claim dance is what makes the shared SMP ready list safe: a thread
whose `stack_ptr` is `null` is "live in some CPU's registers" and is never
picked by another CPU. On the ARMv6-M (RP2040) the same switch is written with
`stmia`/`ldmia` instead of `stmdb`/`ldmia`, because the M0+ has no push-multiple
and `ldm/stm` reach only `r0-r7` — so `r8-r11` and `EXC_RETURN` travel through
`r3-r7` instead.

### 29.5 Interrupts and the interrupt context switch

An interrupt handler is ordinary code, but it must follow two rules: it may
**only call the ISR-safe operations** (`post()`, `raise()`, `tryWait()`,
`trySend()`, `flagsRaise()` — never a blocking `wait()`/`lock()`), and a
reschedule it asks for is **deferred** until the handler returns.

**The tick.** The SysTick handler advances the clocks and requests a switch;
on SMP only CPU 0 advances the clock, the others just reschedule:

```zig
fn sysTickHandler() callconv(.c) void {
    if (smp and scheduler.cpuId() != 0) { scheduler.reschedule(); return; }
    uos.rtos.clocks.sysTickHandler();   // advance sysclock/hrclock, run due timers
}
```

**The IPI.** A cross-CPU wake uses the SIO inter-core FIFO; its handler just
requests a switch:

```zig
fn sioFifoHandler() callconv(.c) void {
    sio.fifoDrain();
    scheduler.reschedule();
}
```

**A peripheral ISR.** The interrupt-driven UART is a typical example — the
handler refills the transmit register from a ring and stops asking for
interrupts when it empties. It calls no RTOS function at all, which is the
safest kind of ISR:

```zig
pub fn irq() callconv(.c) void {
    while (SR.* & SR_TXE != 0) {          // while the data register is empty
        if (head == tail) { CR1.* &= ~CR1_TXEIE; return; }
        DR.* = ring[tail];
        tail = (tail + 1) % ring_size;
    }
}
```

**The deferred switch.** The reason `reschedule()` pends PendSV rather than
switching immediately is that PendSV is at the *lowest* priority. So this
sequence is race-free:

```text
   thread A ──▶ interrupt (e.g. a UART byte arrives)
                 handler posts a semaphore ──▶ reschedule() pends PendSV
                 handler returns
               PendSV fires (now it is safe) ──▶ switch to thread B
```

The ISR wakes thread B with `semaphore.post()` (which is ISR-safe and internally
wraps its list changes in an interrupt critical section), and the *actual*
register save/restore happens afterwards, in PendSV, exactly as in
[§29.4](#the-main-parts-in-code-boot-threads-scheduler-context-switch-interrupts).

**Critical sections in ISR context.** On a single CPU an interrupt critical
section just masks interrupts; on SMP it also takes the kernel lock, so the
ISR's list changes are exclusive across cores. An interrupt whose priority is
*above* the configured critical-section level must not touch the RTOS at all —
the port exposes this check as `interrupts.isPriorityValid()`, and the ISR-safe
calls assert it.

---

## 30. API quick reference

### Namespaces

| Path | What it is |
| --- | --- |
| `uos.rtos` | Threads, scheduler, synchronisation, clocks |
| `uos.rtos.interrupts` | `CriticalSection`, `UncriticalSection`, `inHandlerMode()`, `isPriorityValid()`, `stack()` |
| `uos.rtos.scheduler` | `CriticalSection`, `UncriticalSection`, `lock/unlock/setLocked/locked`, `preemptive`, `started` |
| `uos.rtos.this_thread` | `get`, `thread`, `yield`, `suspend`, `exit`, `sleepFor`, flags wait |
| `uos.rtos.priority` | named priority levels |
| `uos.rtos.result` | `Error`, `errno`, `check` |
| `uos.memory` | `allocator`, `FirstFitTop`, `BlockPool`, `Locked` |
| `uos.trace` | `print`, `puts`, `putchar`, `writer`, `logFn` |
| `uos.port` | the architecture port (`scheduler.cpuId()`, etc.) |

### Kernel objects at a glance

| Object | Construct | Use |
| --- | --- | --- |
| `Thread` | `ThreadInclusive(N).init` / `create` / `spawn` | `join`, `detach`, `kill`, `interrupt`, `setPriority`, `setCpuAffinity` |
| `Mutex` | `.{ .name = … }` / `initRecursive` | `lock`, `tryLock`, `timedLock`, `unlock`, `consistent` |
| `Semaphore` | `.binary` / `.counting` | `post`, `wait`, `tryWait`, `timedWait`, `reset` |
| `ConditionVariable` | `.{ .name = … }` | `signal`, `broadcast`, `wait(mx)`, `timedWait(mx, t)` |
| `EventFlags` | `.{ .name = … }` | `raise`, `wait`, `tryWait`, `timedWait`, `clear`, `get` |
| `MessageQueue` / `Typed(T)` | `init` / `create` / `Static(n)` | `send`, `trySend`, `timedSend`, `receive`, `tryReceive`, `timedReceive` |
| `MemoryPool` / `Typed(T)` | `init` / `create` / `Static(n)` | `alloc`, `tryAlloc`, `timedAlloc`, `free` |
| `Timer` | `.init` / `.initWith` | `start`, `stop`, `getState` |

### Critical sections at a glance

| Expression | Effect |
| --- | --- |
| `uos.rtos.interrupts.CriticalSection.enter()/exit()` | Mask interrupts (and take the kernel lock on SMP) |
| `uos.rtos.interrupts.UncriticalSection.enter()/exit()` | Enable interrupts |
| `uos.rtos.scheduler.CriticalSection.enter()/exit()` | Disable thread switching on this CPU |
| `uos.rtos.scheduler.UncriticalSection.enter()/exit()` | Enable thread switching |

### Common error reasons

- `error.NotPermitted`: you blocked (waited) while the scheduler was locked, or
  called a thread-context function from an interrupt handler.
- `error.WouldBlock` / `error.Again`: a non-blocking (`try*`) call could not
  complete.
- `error.TimedOut`: a timed wait elapsed.
- `error.Interrupted`: another thread called `interrupt(true)` on the waiter.
- `error.OutOfMemory`: the system heap or an allocator is exhausted.

---

*End of document.*
