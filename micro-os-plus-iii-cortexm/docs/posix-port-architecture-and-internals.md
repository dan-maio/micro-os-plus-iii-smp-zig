# µOS++ IIIe Zig Port: The Synthetic POSIX Port — Architecture and Internals

---

## 1. Purpose

The synthetic POSIX port runs the Zig µOS++ IIIe kernel as an ordinary GNU/Linux process. It is the Zig counterpart of the C++ `micro-os-plus-iii-posix-arch` (`smp` branch), and it serves the same purposes:

- running the kernel's test suites and the SMP tests on a development machine, without a board or an emulator;
- developing and debugging application code with the host's tools (a debugger, sanitizers, `strace`);
- exercising the SMP scheduler on many "CPUs" (host threads), with real parallelism and real races.

It implements the same port contract as the Cortex-M port (`micro-os-plus-iii/src/port_contract.zig`), so the kernel is unchanged: the same `uos` module runs on a Pico 2, a WeAct Black Pill and a PC.

---

## 2. The Machine Model

| Concept | Cortex-M port | POSIX port |
| --- | --- | --- |
| CPU | a core | a host thread (CPU 0 = the process' main thread) |
| CPU index | `SIO.CPUID` | a thread-local, read out of line |
| µOS++ thread context | registers stacked on the PSP | a glibc `ucontext_t` |
| Context switch | PendSV | `swapcontext()` |
| Tick | SysTick | a `timer_create()` timer per CPU, `SIGEV_THREAD_ID`, `SIGRTMIN` |
| Cross-CPU request (IPI) | SIO FIFO interrupt | `pthread_kill(…, SIGRTMIN + 1)` |
| Interrupts masked | PRIMASK / BASEPRI | the two signals blocked (`pthread_sigmask()`) |
| Handler mode | `IPSR != 0` | a per-CPU flag set by the handlers (and `signal_nesting`) |
| Kernel lock | SIO spinlock, recursive | an atomic spin lock, recursive, per-CPU owner |
| Interrupt stack | MSP | none: handlers run on the interrupted thread's stack |
| Faults | HardFault reporter | `SIGSEGV`/`SIGBUS`/`SIGFPE`/`SIGILL` on a per-CPU `sigaltstack()` |
| Trace | UART + semihosting | `write(1, …)` (or 2) |
| Verdict | semihosting `SYS_EXIT` | the process exit code (`_exit()`) |
| Free store | the board's RAM | a 32 MiB static array (the C++ native board's heap) |

The port is one file, `src/port.zig`; the glibc declarations come from `src/host.h` through the build's translate-c step (module `host_c`), so `ucontext_t`, `sigset_t` and `struct sigevent` are the host's own definitions, never copied by hand.

GNU/Linux only: the per-thread tick needs `SIGEV_THREAD_ID`. The fault reporter knows the program counter on x86_64 and AArch64.

---

## 3. Threads as ucontexts

### 3.1 Creating a context

`contextCreate()` prepares a glibc ucontext on the thread's µOS++ stack:

```zig
pub fn contextCreate(ctx: *Context, stack: []StackElement, entry: Entry, arg: ?*anyopaque) void {
    ctx.* = .{};
    const uc = &ctx.ucontext;
    if (c.getcontext(uc) != 0) fatal("getcontext");
    uc.uc_link = null;
    uc.uc_stack.ss_sp = @ptrCast(stack.ptr);
    uc.uc_stack.ss_size = stack.len * @sizeOf(StackElement);
    // The thread starts with the interrupts masked; the trampoline unmasks
    // them once the switch is complete.
    _ = c.sigemptyset(&uc.uc_sigmask);
    _ = c.sigaddset(&uc.uc_sigmask, tickSignal());
    _ = c.sigaddset(&uc.uc_sigmask, ipiSignal());
    c.makecontext(uc, @ptrCast(&trampoline), 2, entry, arg);
    ctx.stack_ptr = @ptrCast(@alignCast(&ctx.ucontext));
}
```

The context struct keeps `stack_ptr` first, as the kernel's SMP scheduler expects: `null` means "live in some CPU", anything else means "saved, may be picked". Here the non-null value is the address of the ucontext.

### 3.2 The context switch

`switchStacks()` is the port's PendSV:

1. block the interrupt signals (the mask in effect is saved on the outgoing thread's stack: it belongs to the µOS++ thread);
2. take the kernel lock;
3. clear the outgoing thread's `stack_ptr` (its registers are about to be saved);
4. let the kernel pick the next thread (`internalSwitchThreads()`);
5. claim the incoming thread (`stack_ptr = null`);
6. leave the outgoing context's publication **pending** (`deferPublish()`);
7. release the kernel lock;
8. `swapcontext(old, new)`;
9. back in this thread, possibly on another CPU: publish whatever the previous switch on this CPU left pending, and restore the saved mask.

The deferred publication is the subtle part. A ucontext is fully saved only when `swapcontext()` has switched away; if the outgoing context were published at step 3, another CPU could pick and resume it while its registers are still being written. So the publish is done by the next code that runs on this CPU after the switch: the end of `switchStacks()` in the resumed thread, or the trampoline of a new thread.

```text
CPU n, thread A                         CPU n, thread B (resumed)
------------------------------------    ------------------------------------
block signals, take kernel lock
A.stack_ptr = null
kernel picks B; B.stack_ptr = null
publish_slot[n] = (A.stack_ptr, &A.uc)
release kernel lock
swapcontext(&A.uc, &B.uc)  ───────────▶ returns inside switchStacks()
                                         publishPending(): A.stack_ptr = &A.uc
                                         restore B's signal mask
```

### 3.3 The CPU index

A µOS++ thread may be switched out on one host thread and resumed on another. The CPU index is a `threadlocal`, and its address must therefore be computed after every switch: the function that reads it is `noinline` with a compiler barrier (as the C++ `port_cpu_id()`), so the compiler cannot keep a stale thread-local address across a `swapcontext()`.

---

## 4. Interrupts as Signals

### 4.1 The tick

Each CPU arms its own `CLOCK_MONOTONIC` timer, aimed at its host thread:

```zig
var sev: c.struct_sigevent = std.mem.zeroes(c.struct_sigevent);
sev.sigev_notify = c.SIGEV_THREAD_ID;
sev._sigev_un._tid = @intCast(std.os.linux.gettid());
sev.sigev_signo = tickSignal();          // SIGRTMIN, not the process-wide SIGALRM
```

Every CPU ticks; only CPU 0 drives the clocks (`uos.rtos.clocks.sysTickHandler()`), as on the Pico 2. Each tick marks a context switch pending on its CPU.

### 4.2 The handlers

```zig
fn tickHandler(_: c_int, _: ?*c.siginfo_t, _: ?*anyopaque) callconv(.c) void {
    const saved = errnoPtr().*;            // errno belongs to the interrupted thread
    defer errnoPtr().* = saved;
    const cpu = readCpu();
    in_isr[cpu] = true;
    if (cpu == 0) uos.rtos.clocks.sysTickHandler();
    ctx_pending[cpu] = 1;
    in_isr[cpu] = false;
    irqEpilogue(cpu);                      // the "PendSV": switch now, if allowed
}
```

The handlers run on the interrupted µOS++ thread's own stack (no `SA_ONSTACK`), so the frame of a preempted thread travels with its context. `irqEpilogue()` switches context from inside the handler unless the scheduler is locked or the kernel lock is held on this CPU; then the switch stays pending for the next interrupt.

### 4.3 Critical sections and the kernel lock

An interrupts critical section blocks the two signals and takes the recursive kernel lock; it returns whether the signals were already blocked:

```zig
pub fn criticalEnter() State {
    var old: c.sigset_t = undefined;
    blockIrqs(&old);
    klockTake(readCpu());
    return c.sigismember(&old, tickSignal()) != 0;
}
```

The scheduler lock (`setLocked()`) does the same and records the state per CPU, as in the C++ `port::scheduler::locked()`. `reschedule()` called while this CPU holds the kernel lock, or from a handler, only marks the switch pending.

### 4.4 The IPI

`ipi(cpu)` sends `SIGRTMIN + 1` to that CPU's host thread; its handler just marks a switch pending and runs the epilogue. The kernel sends it when it resumes a thread whose affinity excludes the current CPU.

### 4.5 Handler mode and the validator

`inHandlerMode()` is true inside the two handlers, and also while `signal_nesting` is non-zero: the Arm CMSIS-RTOS validator's host shim raises its test interrupt with `SIGUSR1` and counts it in that variable, which the port exports.

---

## 5. CPUs

CPU 0 is the process' main thread. CPUs 1..n are host threads started by `uos.port.startSecondaryCpus()`, called by the application (as `smp::start_secondary_cores()` in the C++ tests). Each secondary blocks the signals, makes its boot pseudo-thread current, starts its tick, records its stage (3 = scheduler entered) and asks for its first context switch; the kernel's idle thread of that CPU then takes over.

The CPU count is the application's `uos_options.ncpu`; the native board's tests use 4, the harness suites 1.

---

## 6. Faults, Trace and Verdict

`SIGSEGV`, `SIGBUS`, `SIGFPE` and `SIGILL` are handled on a per-CPU alternate stack (a stack overflow would otherwise have nowhere to run the handler). The report is the C++ one: the signal, the address, the program counter and its static (load-bias corrected) value, the current thread of every CPU, the kernel lock, and a backtrace; then the signal is re-raised with its default action.

The trace is unbuffered `write()` on the standard output, or on the standard error with `uos_port_options.trace_stderr` (the C++ `OS_USE_TRACE_POSIX_STDERR`). The C standard output is made unbuffered too, so C code that prints with `printf()` stays in program order with the Zig trace.

`terminate(code)` flushes the C stdio buffers and `_exit()`s with the verdict.

---

## 7. The C API on the Host

C code links with the kernel on the host libc (`c_api`, `cmsis_os`; no `c_runtime`). The trace C API (`trace_printf()`, …) is exported with the C API. A thread carries a whole `ucontext_t` (signal mask and FPU state included, 1256 bytes on x86_64), so the port raises the `os_thread_t` storage to 192 words: `include/cmsis-plus/rtos/port/os-c-storage.h`, included by the kernel's `os-c-decls.h`, and `c_storage_words` in `src/port.zig`.

---

## 8. The Native Board and its Drivers

`test/board.zig` is the C++ `test/boards/native/`: the console (`uart`, the standard output), the LED (a line printed when it changes), the banner texts, the secondary CPUs and their stages, the join helpers of `test-smp-boot.cpp`, `console()`/`reportPerCore()` (`test-console.hpp`), `hw_result` and the board's kernel options (`options(ncpu)`: the port's 32 KiB minimum and 64 KiB default stacks, main's 8192-element stack, the 32 MiB free store).

`drivers/sd.zig` is the SD card on a host file (`disk.img`, or `$UOS_SD_IMAGE`; `$UOS_SD_SECTORS` sectors, default 65536), `drivers/flatfs.zig` the flat file system of the C++ `drivers/src/flatfs.cpp`, with the same on-disk layout: the image `flatfs-test` leaves is byte-identical to the C++ one.

---

## 9. Tests

| Test | What | CPUs |
| --- | --- | --- |
| `smp-test0` | 10 heartbeats on CPU 0 | 4 |
| `smp-test1` | semaphore ping-pong across CPUs | 4 |
| `smp-test2` | mutex coherency, one worker per CPU | 4 |
| `smp-test3` | message queue producer/consumer across CPUs | 4 |
| `smp-test4` | load balancing without affinity | 4 |
| `smp-mat-test` | parallel block linear solver, N = 500 | 4 |
| `smp-mutex-stress` | mutex-stress pinned on 4 CPUs, per-core checks | 4 |
| `smp-pro-cons-test` | producers and consumers over every kernel object | 4 |
| `smp-rtos-apis` | the rtos-apis sequence once per CPU | 4 |
| `smp-num-test` | concurrent workers and file I/O on flatfs | 4 |
| `smp-pipeline-test` | 13-thread pipeline, flatfs persistence and audit | 4 |
| `mutex-ceiling-test` | a refused protect lock leaves nothing behind | 4 |
| `flatfs-test` | append to a file created empty | 4 |
| `rtos-apis` | the kernel's harness suite (C++, C, ISO, POSIX I/O parts) | 1 |
| `mutex-stress` | the kernel's harness suite | 1 |
| `cmsis-os-validator` | the Arm CMSIS-RTOS validator, 60/60 | 1 |
| `trace-stdout`, `trace-stderr` | the trace on each stream | – |

All pass. They are faithful ports of the C++ `test/native/` tests, compared with the C++ native builds: identical where the output is deterministic, the same totals where it depends on timing. The math of `smp-num-test` is Zig's own, so a value may differ from C++ in the last digit.

Running them:

```sh
zig build                              # build every test
./zig-out/bin/smp-test1                # run one
zig build run -Dtest=smp-test1         # build only that one, and run it
test/run-all.sh                        # all of them, with a verdict table
test/run-all.sh smp-test1 flatfs-test  # some of them
```

`run-all.sh` runs each test in its own folder under `zig-out/run/` (the SD tests create their `disk.img` there) and keeps each output in `zig-out/run/<test>.log`.

---

## 10. What the Port Found

Running the SMP tests on four host threads, with real parallelism and many more context switches per second than a board, found a race in the kernel's timers: a periodic timer stopped on one CPU while its callback ran on another was re-armed after `stop()` returned (`smp-rtos-apis`, a stack-allocated timer firing thousands of times after its scope, then a corrupted clock list). The fix is in the kernel (`src/rtos/timer.zig`); the C++ timer has the same window. See the kernel's `docs/port-architecture-and-internals.md`, "Timers on SMP".

---

## 11. Limitations

- GNU/Linux only (`SIGEV_THREAD_ID`); the fault reporter's program counter for x86_64 and AArch64.
- A blocking host call (a `read()` of the terminal, a long `sleep()`) blocks the whole CPU it runs on, as an interrupt-less loop would on a board.
- More CPUs than host cores only slow the run down; the tick then drifts (the C++ port warns above 16).
