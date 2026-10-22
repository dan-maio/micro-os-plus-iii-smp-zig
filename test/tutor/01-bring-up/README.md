# Lesson 01 (Zig) — Bring-up: the kernel, the main thread and the three memory regions

## 1. Theory

### What a real-time operating system is

A *real-time operating system* (RTOS) is a small kernel that lets one
program be written as several independent activities — *threads* — and
runs them on the processor so that each meets its deadline. "Real-time"
does not mean fast; it means **predictable**: the kernel's own operations
take a bounded time, and which thread runs is decided by fixed rules
(priorities) rather than by fairness. µOS++ is such a kernel: it is linked
into the application (there is no separate "OS image"), it starts before
the application code runs, and every kernel object — a thread, a mutex, a
queue — is an ordinary object the application creates.

### From reset to the first thread

On a bare-metal board nothing is running when the processor leaves reset.
The start-up sequence is:

1. **The reset code** (`boards/rpi4b/startup.S`): sets up the CPU's
   exception level, stack pointer and vector table, turns on the MMU and
   caches, and clears `.bss`.
2. **The language run-time**: the data segment holds its initial values (on
   this board the loader has already written them); `.bss` is zero.
3. **The kernel's start-up**: the test's `main()` brings up the UART and
   calls `uos.rtos.run(osMain)`, which initialises the scheduler, creates
   the *idle threads* (one per core) and the *main thread*, and starts the
   scheduler.
4. **The main thread** runs `osMain()` — the application's entry point.
   From here the program is a thread like any other: it can sleep, block,
   create other threads.

The *idle thread* runs only when no other thread can: it is the kernel's
answer to "what does the CPU do when everyone is waiting?" (here, `wfi`:
wait for an interrupt).

### The three storage regions

Every object a program uses lives in one of three places, and an embedded
program must know which, because each has a different lifetime, size limit
and cost:

| Region | Created by | Lifetime | Size known | Cost |
|---|---|---|---|---|
| **Data segment** (`.data`, `.bss`) | a container-level `var` | the whole run | at link time | none at run time |
| **Stack** | a local `var` | the enclosing function call | per thread, fixed when the thread is created | none (moving the stack pointer) |
| **Heap** (the system heap) | `allocator.create()` / `alloc()` | until `destroy()` / `free()` | at run time | an allocator call; fragmentation; must be released |

A real-time design prefers the data segment and the stack, because they
cannot fail or fragment at run time; the heap is used where the number of
objects is only known while running, and every allocation must be matched
by a release. `.data` holds variables with a non-zero initial value (their
bytes are part of the image); `.bss` holds those starting at zero (only
their size is recorded, the start-up code clears them).

### Intrusive lists

A *container* usually allocates a small node for each element it holds. An
*intrusive* list does not: the link (`next`) is a field of the element
itself, so linking an object costs no memory and cannot fail. This is how
RTOS kernels keep their own lists (ready threads, waiting threads, timers),
and it means the list does not care where its nodes live — a node can be on
a stack, in the data segment or on the heap. The price is that the owner
must unlink a node before its storage goes away.

### One CPU or several

With **one CPU** the kernel needs no protection between processors: only
interrupts can run "at the same time" as a thread. With **several CPUs**
(*SMP*, symmetric multiprocessing) every core runs threads truly in
parallel. At reset only one core runs; the others wait in a *spin table*
until the program releases them. Each released core then needs its own
stack, its own idle thread, its own timer interrupt, and the kernel must
protect its shared data (the ready list, the objects' wait lists) with a
lock all cores respect.

## 2. In µOS++ (Zig)

- `pub const uos_options = board.options(N);` is the kernel's configuration,
  read at compile time from the test's root file (`test/board.zig`'s
  `options()`): `N` 1 builds the non-SMP scheduler (`smp` false), `N` 4 the
  SMP one, with one current thread and one idle thread per core
  (`uos.rtos.scheduler.idle_thread_core[]`).
- `uos.rtos.run(osMain)` starts the kernel; `osMain()` runs in the main
  thread.
- `uos.rtos.this_thread.thread()` is the running thread;
  `thread.context.stack.bottom()` / `top()` its stack;
  `thread.setCpuAffinity(mask)` the cores it may run on.
- `uos.memory.allocator()` is the system heap (thread safe); its arena,
  `uos.memory.systemHeap().arena`, is the RAM after the image
  (`port.freeRam()`); `uos.memory.statistics().allocated_bytes` the bytes in
  use.
- On the Raspberry Pi 4 B, cores 1–3 wait in the firmware's spin table;
  `board.smp.startSecondaryCores()` releases them, and each runs the port's
  secondary start-up (`src/port.zig`: its stack, its MMU, its timer, its
  idle thread); `board.smp.waitSecondaries(ms)` waits for them to join.

## 3. The lesson

This is the base every later lesson starts from: `test/tutor/common/tutor.zig`
(the `tutor` module) holds `Sample`, `IntrusiveList(T)`, the region checks,
the data generator, `sortList()`, `maxOf()`, `checksum()`, the independent
`reference()` and the verdict helpers (see `../README.md`, section 2.1).

**`1cpu/main.zig`.** The main thread:

1. prints the banner and the three regions' address ranges (`.data` from
   the linker's `__data_start`/`__data_end`, the heap's arena, its own
   stack from the kernel);
2. builds 24 samples with fixed values: 8 in a local array (its stack), 8 in
   the container-level `g_data` (the data segment), 8 with
   `gpa.create(Sample)` (the heap), and pushes each on one intrusive list;
3. checks each sample lies in the region it claims and its seal is intact;
4. sorts the list, finds the maximum and the checksum of the sorted order,
   and compares them with `reference()`, computed on a plain array without
   any list code;
5. unlinks and destroys the heap samples and checks the heap is back to its
   starting level.

**`4cpu/main.zig`.** The same program, with one new section before the work:
it pins the main thread to core 0, releases cores 1–3, waits for each to
join the scheduler, and lists every core's idle thread. The work is
unchanged and still runs on core 0, so the results must be identical — and
identical to the C++ lesson's (golden workspace,
`test/rpi4b/tutor/01-bring-up/`): checksum `7bb976a9`, maximum 9217 (#16).

### Files in the build

Every path is relative to the workspace (the folder holding
`micro-os-plus-iii` and `micro-os-plus-iii-aarch64`). Both versions build
the same files; only `1cpu/main.zig` or `4cpu/main.zig` differs.

**The lesson and the course's base**

- `micro-os-plus-iii-aarch64/test/tutor/01-bring-up/1cpu/main.zig` (or `4cpu/main.zig`) — the test's application module
- `micro-os-plus-iii-aarch64/test/tutor/common/tutor.zig` — the `tutor` module

**The test bridge**

- `micro-os-plus-iii-aarch64/test/start.zig` — the firmware's root module (the entry from `startup.S`, the panic handler)
- `micro-os-plus-iii-aarch64/test/board.zig` — the `board` module of every test: `options()`, `console()`, `uart`, `smp`, `hw_result`

**The board: Raspberry Pi 4 B** (`boards/rpi4b/`)

- `micro-os-plus-iii-aarch64/boards/rpi4b/startup.S` — reset, exception levels, stacks, `.bss`, the secondary cores' entries
- `micro-os-plus-iii-aarch64/boards/rpi4b/board.zig` — the board's facts: the UART, the LED, the banners, `ram_base`/`ram_end`
- `micro-os-plus-iii-aarch64/boards/rpi4b/linker.ld` — the memory map: `.text`, `.rodata`, `.data` (`__data_start`/`__data_end`), `.bss`, the per-core stacks, `_end`

**The AArch64 port** (`src/`, the `uos_port` module)

- `micro-os-plus-iii-aarch64/src/port.zig` — the port: the kernel lock, the scheduler start, the IRQ dispatch, the secondary bring-up, `freeRam()`, the trace
- `micro-os-plus-iii-aarch64/src/arch.zig` — the AArch64 instructions (`cpuId()`, `wfi`, the system registers)
- `micro-os-plus-iii-aarch64/src/mmu.zig` — the page tables, the MMU and caches
- `micro-os-plus-iii-aarch64/src/gic.zig` — the GIC-400 interrupt controller
- `micro-os-plus-iii-aarch64/src/faults.zig` — the exception reports
- `micro-os-plus-iii-aarch64/src/semihosting.zig` — the semihosting calls (the verdict line, the exit)

**The kernel** (`micro-os-plus-iii/src/`, the `uos` module)

- `micro-os-plus-iii/src/uos.zig`, `config.zig`, `rtos.zig`, `trace.zig`, `semihosting.zig`, `memory.zig`
- `micro-os-plus-iii/src/rtos/`: `startup.zig`, `scheduler.zig`, `thread.zig`, `interrupts.zig`, `clocks.zig`, `lists.zig`, `mutex.zig`, `semaphore.zig`, `condvar.zig`, `evflags.zig`, `flags.zig`, `mqueue.zig`, `mempool.zig`, `timer.zig`, `result.zig`
- `micro-os-plus-iii/src/memory/`: `FirstFitTop.zig` (the system heap's allocator), `BlockPool.zig`

**The build rules**

- `micro-os-plus-iii-aarch64/build.zig` — the test list (`.name`, `.dir`, `.tutor`), the modules, `startup.S` and `linker.ld`, the QEMU `run` step
- `micro-os-plus-iii-aarch64/build.zig.zon` — the kernel dependency
- `micro-os-plus-iii-aarch64/test/hw.sh`, `test/run-all.sh`, `boards/rpi4b/openocd.cfg`, `reset.cfg` — the board runner

## 4. The test

PASS when, in both versions:

- 24 samples are in the list, 8 per region, each in the region it claims;
- the sorted list is ascending, and its checksum and maximum equal the
  reference;
- the heap is back to its level after the destroys;
- (4 CPUs) cores 1–3 joined and every core has its idle thread.

On the UART, look for the three ranges, the sorted list with each sample's
region, and the `[ok]` lines; the 4-CPU version also shows the release of
cores 1–3, `c1=3 c2=3 c3=3` (each core's join stage) and the idle threads.

## 5. Running it

**Zig on the `PATH` first** (the build needs Zig 0.17.0); from
`micro-os-plus-iii-aarch64`:

```sh
cd micro-os-plus-iii-aarch64
export PATH=$HOME/zig-x86_64-linux-0.17.0:$PATH
```

**Build** (the images land in `zig-out/firmware/rpi4b/`):

```sh
zig build -Dtest=tutor-01-bring-up-1cpu
zig build -Dtest=tutor-01-bring-up-4cpu
```

**Run under QEMU** (`raspi4b`; the xPack QEMU, or `-Dqemu=<path>`):

```sh
zig build -Dtest=tutor-01-bring-up-1cpu run
zig build -Dtest=tutor-01-bring-up-4cpu run
```

**Run on the board** (the Raspberry Pi Debug Probe on JTAG, a terminal on
the UART at 115200 8N1 for the console; the runner resets the Pi through its
watchdog, waits for it to boot, loads and runs the image, at most 3 minutes):

```sh
test/run-all.sh tutor-01-bring-up-1cpu
test/run-all.sh tutor-01-bring-up-4cpu
```

## 6. Results

Both versions PASS under QEMU and on the board (2026-10-22): 14 s and 15 s
on the board. Their results are identical, and identical to the C++
lesson's — checksum `7bb976a9`, maximum 9217 (#16). See
[`RESULTS.md`](RESULTS.md), which also records one unexplained four-CPU
failure on the board, not reproduced in eight further runs.
