# µOS++ IIIe for Zig — the portable kernel

A port of [µOS++ IIIe](https://micro-os-plus.github.io/) (the
`micro-os-plus-iii` C++ project, SMP branch) to **Zig 0.17**, written in
idiomatic Zig: explicit allocators, error unions instead of `result_t`,
comptime configuration, and the new `std.Io` interface.

This repository is the **portable part** only, as in C++. An application
also needs exactly one architecture port, a sibling repository:

```text
micro-os-plu-iii-smp-zig-pr-github/
├── micro-os-plus-iii/              ← this repository (the kernel, module `uos`)
├── micro-os-plus-iii-cortexm/      ← the Cortex-M port (Pico 2, WeAct F411, ...)
├── micro-os-plus-iii-aarch32/      ← the ARMv7-A port (Luckfox Lyra B, 3× Cortex-A7)
├── micro-os-plus-iii-aarch64/      ← the ARMv8-A port (Raspberry Pi 4 B, 4× Cortex-A72)
└── micro-os-plus-iii-posix-arch/   ← the synthetic POSIX port (GNU/Linux host)
```

## What is in it

| Folder / file | Contents | C++ counterpart |
| --- | --- | --- |
| `src/uos.zig` | The module root: `uos.rtos`, `uos.memory`, `uos.trace`, `uos.Io`, `uos.io.devices` | `cmsis-plus/rtos/os.h` |
| `src/rtos/` | Scheduler (single core and SMP), threads, mutexes, condition variables, semaphores, event flags, message queues, memory pools, timers, clocks | `src/rtos/` |
| `src/memory/` | `FirstFitTop` (the system heap) and `BlockPool` allocators | `src/memory/` |
| `src/io/Io.zig` | A `std.Io` implementation on the RTOS (threads, mutexes, conditions, clocks, sleep, cancellation) | `estd/` (ISO C++ threads) |
| `src/io/devices.zig` | Char and block devices, partitions, locked devices, file descriptors, RAM disk | `posix-io/` |
| `src/c_api.zig`, `src/c_storage.zig` | The µOS++ C API (`os_thread_construct()`, `os_mutex_lock()`, ... — the 196 functions of `os-c-api.h`) | `src/rtos/os-c-wrapper.cpp` |
| `src/cmsis_os.zig` | The CMSIS-RTOS v1 API (`osThreadCreate()`, `osSignalWait()`, `osMailPut()`, ...) | `os-c-wrapper.cpp`, legacy part |
| `src/libc.zig` | A minimal C runtime for freestanding C code: `printf` & co., string functions, `assert`, `trace_printf` | newlib + `src/diag/` |
| `src/config.zig` | `uos.Options`, the configuration | `os-app-config.h` |
| `src/port_contract.zig` | What a port must provide, checked at compile time | `rtos/port/*.h` |
| `include/` | The C headers: `cmsis-plus/rtos/os-c-api.h`, `os-c-decls.h`, `cmsis-plus/legacy/cmsis_os.h`, `cmsis-plus/diag/trace.h`, and `c/` (the minimal C runtime) | `include/` |
| `tests/suites/` | Test suites shared by the ports | `tests/sources/` |
| `docs/` | Architecture and internals, porting guides | |

## Configuration

An application declares `pub const uos_options: uos.Options = .{ ... };`
in its root file. The fields mirror the C++ `OS_INTEGER_*`, `OS_INCLUDE_*`
and `OS_USE_*` macros, for example:

| Option | Default | C++ |
| --- | --- | --- |
| `ncpu`, `smp` | `1`, `false` | `OS_NCPU`, `OS_USE_SMP_SCHEDULER` |
| `systick_frequency_hz` | `1000` | `OS_INTEGER_SYSTICK_FREQUENCY_HZ` |
| `main_stack_size_bytes`, `default_stack_size_bytes`, `idle_stack_size_bytes` | `4096`, `2048`, `1024` | `OS_INTEGER_RTOS_*_STACK_SIZE_BYTES` |
| `critical_section_interrupt_priority` | `null` (PRIMASK) | `OS_INTEGER_RTOS_CRITICAL_SECTION_INTERRUPT_PRIORITY` |
| `dynamic_memory_size_bytes` | 16 KiB | `OS_INTEGER_RTOS_DYNAMIC_MEMORY_SIZE_BYTES` |
| `statistics_context_switches`, `statistics_cpu_cycles` | `false` | `OS_INCLUDE_RTOS_STATISTICS_THREAD_*` |
| `c_api` | `false` | Export the µOS++ C API |
| `cmsis_os` | `false` | Export the CMSIS-RTOS v1 API |
| `c_runtime` | `false` | Export the minimal C runtime (freestanding only) |

## C code

C sources can be linked with the kernel and call it through the same C API
as in C++. There is still one kernel: the C functions are thin wrappers that
convert their arguments and call the Zig objects.

- Enable `c_api` (and `cmsis_os` for the CMSIS-RTOS v1 API). On a
  freestanding target, enable `c_runtime` too: it provides the few libc
  functions such code needs, with the output on the trace channel.
- Add the include folders with `addCIncludes()` from this `build.zig`.
- The headers are the C++ ones, except `os-c-decls.h`: its types, enums and
  attributes are the C++ ones, but the objects (`os_thread_t`,
  `os_mutex_t`, ...) are opaque storage sized for the Zig objects. C code
  allocates them and passes pointers; it never reads their members. The
  sizes are in `src/c_storage.zig` too: the build fails when a Zig object
  outgrows its storage, and a host test fails when the header disagrees. A
  port may raise them (`cmsis-plus/rtos/port/os-c-storage.h` and
  `c_storage_words` in its module; the POSIX port does, for its ucontexts).
- Not available: `os_thread_get_user_storage()` and the C startup hooks
  (`os-hooks.h`); `os_thread_attr_t.th_cpu_affinity` is always present.

The original `test-c-api.c` of the C++ rtos-apis suite and the Arm
CMSIS-RTOS validator (60/60) run this way on the boards; see the Cortex-M
port.

## Running the tests

There are three levels: the host unit tests of this repository, and the
test applications of each port, on the boards or on the host.

### The kernel's host unit tests

```sh
cd micro-os-plus-iii
zig build test                  # lists, flags, allocators, C storage sizes
zig build test --summary all    # the same, with the count of tests
```

### On the boards (the Cortex-M port)

```sh
cd micro-os-plus-iii-cortexm
zig build -Dboard=pico2                              # build every test of a board
test/run-all.sh pico2                                # run all of them, one after the other
zig build run -Dboard=pico2 -Dtest=smp-test2         # build one test, and run it
bash test/hw.sh weactf411 zig-out/firmware/weactf411/rtos-apis.elf 120   # run an image
```

`-Dboard` is `pico2`, `weactf411` (tested), `nucleof411`, `weactf412` or
`pico` (built only); `-Dtest=<name>` builds that test only. The runner
programs the board with OpenOCD and follows the semihosting output until
`RESULT: PASS` or `RESULT: FAIL`; the logs are in
`zig-out/hw-logs/<board>/<test>.log`. The UART carries the same output, for
a terminal. Reset the Pico 2 between tests (it keeps USB and SIO state
across a debugger reset).

### On the Luckfox Lyra (the AArch32 port)

```sh
cd micro-os-plus-iii-aarch32
zig build                                            # build every test
zig build run -Dtest=smp-test2                       # build one test, and run it
bash test/hw.sh luckfox-lyra zig-out/firmware/luckfox-lyra/smp-test2.elf 120   # run an image
```

The runner loads the image into DRAM with OpenOCD (halt core 0, MMU and
caches off, `load_image`, resume at 0x00200000) and follows the semihosting
output; the logs are in `zig-out/hw-logs/luckfox-lyra/<test>.log`. Power
cycle the Lyra between tests: CPUs 1 and 2 (and the Cortex-M0) stay running
once a test released them. The SD tests mount the card's existing FAT32
volume and write only in `/tests`.

### On the Raspberry Pi 4 B (the AArch64 port)

```sh
cd micro-os-plus-iii-aarch64
zig build                                            # build every test
test/run-all.sh                                      # run all of them, with a verdict table
bash test/hw.sh rpi4b zig-out/firmware/rpi4b/smp-test2.elf 180   # run an image
```

Each run resets the Pi through its watchdog (OpenOCD), waits 10 s for it to
boot from its SD card, loads the image and runs it to its verdict, at most
3 minutes. Only the verdict lines go through semihosting (OpenOCD does not
resume cores 1–3 after a semihosting call on this board); the console is on
the UART. The SD tests write only in the card's `/tests`.

### On the host (the POSIX port)

```sh
cd micro-os-plus-iii-posix-arch
zig build                                 # build every test
test/run-all.sh                           # run all of them, with a verdict table
test/run-all.sh smp-test1 flatfs-test     # run some of them
./zig-out/bin/smp-test1                   # run one directly
zig build run -Dtest=smp-test1            # build only that one, and run it
```

A host test's verdict is its exit code. See each port's README for the list
of tests and their C++ origin.

## Adding a new architecture

A port is a separate repository (`micro-os-plus-iii-<arch>`), as in C++. It
provides one Zig module, imported by the kernel as `uos_port`, which declares
what `src/port_contract.zig` lists; the kernel checks it at compile time and
names any missing piece. The scheduler, the threads, the lists and the
synchronisation objects stay the kernel's.

### 1. The package

`build.zig.zon` depends on this repository:

```zig
.dependencies = .{
    .micro_os_plus_iii = .{ .path = "../micro-os-plus-iii" },
},
```

and `build.zig` wires the two modules together with this repository's
helpers:

```zig
const uos_build = @import("micro_os_plus_iii");

const kernel_dep = b.dependency("micro_os_plus_iii", .{});
const port_mod = b.createModule(.{ .root_source_file = b.path("src/port.zig"), ... });
const uos_mod = uos_build.createModule(b, kernel_dep, .{
    .target = target,
    .optimize = optimize,
    .port = port_mod,                     // linkPort(): uos <-> uos_port
});
exe.root_module.addImport("uos", uos_mod);
// Optional: the shared test suites, and the C headers for C sources.
exe.root_module.addImport("uos_suites", uos_build.createSuitesModule(b, kernel_dep, uos_mod));
uos_build.addCIncludes(kernel_dep, exe.root_module, freestanding);
```

### 2. The port module

```zig
const uos = @import("uos");

// Stacks and contexts.
pub const StackElement = u32;                // the stack word
pub const stack_alignment: usize = 8;
pub const Context = struct {
    // The saved stack pointer; null while the context is live in a CPU
    // (the SMP scheduler never picks a thread whose stack_ptr is null).
    stack_ptr: ?[*]StackElement = null,
};
pub fn contextCreate(ctx: *Context, stack: []StackElement,
    entry: *const fn (?*anyopaque) callconv(.c) noreturn, arg: ?*anyopaque) void { ... }

pub const interrupts = struct {
    pub const State = u32;                   // whatever the masks need
    pub fn criticalEnter() State { ... }     // mask (and, on SMP, take the kernel lock)
    pub fn criticalExit(state: State) void { ... }
    pub fn uncriticalEnter() State { ... }
    pub fn uncriticalExit(state: State) void { ... }
    pub fn inHandlerMode() bool { ... }
    pub fn isPriorityValid() bool { ... }    // may this interrupt call the RTOS?
};

pub const scheduler = struct {
    pub fn initialize() void { ... }         // the hardware up, interrupts masked
    pub fn start() noreturn { ... }          // internalPrepareCpu(0), tick, first switch
    pub fn setLocked(locked: bool) bool { ... }
    pub fn isLocked() bool { ... }
    pub fn reschedule() void { ... }         // request a context switch (PendSV, ...)
    pub fn waitForInterrupt() void { ... }   // WFI, sigsuspend(), ...
    pub fn cpuId() u32 { ... }               // 0 on a single-CPU build
    pub fn ipi(cpu: u32) void { ... }        // cross-CPU reschedule request
    pub fn prepareSuspend() void {}
    pub fn greeting(w: *std.Io.Writer) std.Io.Writer.Error!void { ... }
};

pub const clock_systick = struct { pub fn start() void { ... } };
pub const clock_highres = struct { ... };    // see port_contract.zig
pub const trace = struct { pub fn write(bytes: []const u8) void { ... } };

// Optional: terminate(code), freeRam(), interruptStack(), stack_magic,
// c_storage_words, a port Options struct (root `uos_port_options`).
```

The two duties that matter most:

- **The context switch** saves the outgoing context, calls
  `uos.rtos.scheduler.internalSwitchThreads()` with the interrupts masked
  (and the kernel lock held, on SMP), and restores
  `scheduler.current_thread[cpu]`. On SMP it publishes the outgoing
  `stack_ptr` only once the context is fully saved, and clears the incoming
  one before it resumes it (the Cortex-M port in PendSV, the POSIX port after
  `swapcontext()`).
- **The tick** calls `uos.rtos.clocks.sysTickHandler()` (on CPU 0 only, on
  SMP); the kernel then asks for a reschedule.

Bring up the other CPUs of an SMP target from the port (or let the
application do it, as `launchCore1()` and `startSecondaryCpus()`): each makes
its boot pseudo-thread current with
`uos.rtos.scheduler.internalPrepareCpu(cpu)`, starts its tick and asks for
its first switch.

### 3. The order of work

1. A port that builds: `zig build` fails with a message naming each missing
   piece of the contract until the module is complete.
2. `smp-test0`: the trace, the tick, one thread sleeping (10 heartbeats).
3. Two threads and a context switch in each direction (`smp-test1`).
4. The harness suites: `rtos-apis` (every object, the C API), `mutex-stress`,
   `fp-switch` on an FPU, `cmsis-os-validator`.
5. On SMP: the other CPUs, the IPI, then `smp-test2`..`smp-test4` and the
   stress tests.

The Cortex-M port (`micro-os-plus-iii-cortexm/src/port.zig`), the AArch32
and AArch64 ports (`micro-os-plus-iii-aarch32/src/port.zig`,
`micro-os-plus-iii-aarch64/src/port.zig`) and the POSIX port
(`micro-os-plus-iii-posix-arch/src/port.zig`) are the worked examples:
hardware registers and assembly in three (an M-profile PendSV, A-profile
exception returns with a deferred SMP publish), signals and ucontexts in the
last, behind the same contract. `docs/aarch32-aarch64-smp-amp-porting-guide.md`
discusses further targets.

## Licence

MIT, as µOS++; see `LICENSE`.
