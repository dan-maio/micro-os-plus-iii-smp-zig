# Lesson 02 (Zig) — Threads: creation, stacks, join, return values and yield

## 1. Theory

### What a thread is

A *thread* is one sequential activity of the program: its own flow of
instructions, its own CPU registers and its own **stack**, sharing
everything else (code, static data, heap) with the other threads. The
kernel keeps, for each thread, a *thread control block* (TCB): its state,
its priority, where its stack is, and — while it is not running — the
registers it had when it stopped. Switching from one thread to another (a
*context switch*) is saving the running thread's registers in its TCB and
loading the next thread's.

### A thread's life

| State | Meaning |
|---|---|
| **ready** | could run; waiting only for a CPU |
| **running** | executing on a CPU (with one CPU, exactly one thread at a time) |
| **suspended / waiting** | blocked: sleeping, waiting for a lock, a message, another thread |
| **terminated** | its function has returned; its result is kept until someone *joins* it |
| **destroyed** | its resources released |

A thread is **created** with a function, an argument and attributes (its
stack, its priority); it starts in the ready state. Its function's return
value is its *exit value*. Another thread that calls **join** on it waits
until it has terminated and receives that value — the simplest way to hand a
result back. Only after joining (or detaching) may its object and stack be
freed.

### Stacks

Every thread needs its own stack, sized for the deepest chain of calls it
makes (with their locals). It can come from two places:

- a **static** array the application reserves (in `.bss`): the size is fixed
  at link time and creating the thread cannot fail for lack of memory;
- the **heap**: the kernel allocates it when the thread is created and frees
  it when the thread is destroyed — flexible, but it can fail and it must be
  returned.

A stack too small overflows into whatever is next to it, the classic
embedded crash; RTOS kernels guard it with *magic words* at its ends.

### Who runs: scheduling

An RTOS runs the **highest-priority ready thread**. Threads of the **same**
priority share the CPU in *round-robin*: a thread that calls **yield** gives
the CPU to the next ready thread of its priority and goes to the end of the
line; a kernel may also rotate them on the timer tick (*time slicing*). A
newly created thread is ready at once: if its priority is the creator's, it
takes its turn in the same round-robin as the creator, which is why the
order threads start in depends on who creates them, and at which priority.

### Several CPUs

With several cores, several threads run **at the same time**, one per core.
The kernel still picks, on each core, the highest-priority ready thread it
may run there. A thread's *affinity* is the set of cores it is allowed on:
pinned to one core, it always runs there; with no restriction, the kernel
may run it on any core and move it (*migration*). True parallelism means
the order in which threads on different cores reach a point is no longer
decided by yields — only their results are deterministic, not their
interleaving.

## 2. In µOS++ (Zig)

- `rtos.Thread.create(gpa, name, function, arg, attributes)` creates a thread
  whose object comes from the allocator `gpa` and returns `*Thread`;
  `function` is `fn (?*anyopaque) ?*anyopaque`: its return value is the exit
  value.
- `rtos.Thread.Attributes`: `.stack` gives a static stack (a slice of
  `uos.port.StackElement`); `.stack_size_bytes` alone asks the kernel to
  allocate one from the same allocator; `.priority`
  (`rtos.priority.normal`, `above_normal`, ...); `.cpu_affinity` (one bit per
  core).
- `thread.join()` waits for the thread to terminate and returns its exit
  value; `thread.destroy()` then frees its object and its allocated stack.
- `rtos.this_thread.yield()` hands the CPU to the next ready thread of the
  same priority.
- `rtos.this_thread.thread().setPriority(p)` sets the running thread's
  priority; `setCpuAffinity(mask)` its cores.
- `thread.context.stack.bottom() / top()`: where a thread's stack is.

## 3. The lesson

New against lesson 01: the work moves out of the main thread into **four
worker threads**, each with its own data — the same design, data and checks
as the C++ lesson (golden workspace, `test/rpi4b/tutor/02-threads/`).

**`1cpu/main.zig`.**

- *The data.* Worker `w` owns 18 samples with ids `100·w .. 100·w+17`: 6 in a
  local array (its own stack), 6 in its slice `g_data[w]` of the data
  segment, 6 from `gpa.create(Sample)`. Its list is its own: no lock yet.
- *The stacks.* Workers 0 and 1 get static stacks (`g_stacks[2][4096]`, in
  `.bss`); workers 2 and 3 get 32 KiB stacks the kernel allocates from the
  heap. The console prints each stack's range.
- *The steps.* Each worker builds its samples (step 0), checks each lies in
  its region — its stack samples in **its own** stack — (step 1), sorts its
  list (step 2), takes its maximum and checksum and frees its heap samples
  (step 3), and returns `&g_results[w]`. After each step it records
  `(worker, step)` in a shared trace and calls `rtos.this_thread.yield()`.
- *The creation.* The main thread raises its own priority to `above_normal`
  before creating the workers (at `normal`), so that none runs before all
  four exist (why: see the C++ lesson's first run, in its `RESULTS.md`). It
  then blocks in `join()`.
- *The end.* The main thread joins the four, checks each `join()` returned
  that worker's result, checks the trace is round-robin (all four finish step
  *k* before any starts *k+1*), checks each worker's checksum and maximum
  against `tutor.reference(seed, 100·w, 18)` and the merged maximum,
  destroys the threads and checks the heap is back to its level.

**`4cpu/main.zig`** first releases cores 1–3, pins worker `w` to core `w`
from its creation (`.cpu_affinity = 1 << w`), and records the core of each
step; the round-robin check becomes "every worker ran all its steps on its
own core". The results are the same as with one CPU.

### Files in the build

The same files as lesson 01 (see `../01-bring-up/README.md`, *Files in the
build*), with this lesson's own source:

- `micro-os-plus-iii-aarch64/test/tutor/02-threads/1cpu/main.zig` (or `4cpu/main.zig`)
- `micro-os-plus-iii-aarch64/test/tutor/common/tutor.zig` (the `tutor` module)
- the test bridge (`micro-os-plus-iii-aarch64/test/start.zig`, `test/board.zig`), the board (`micro-os-plus-iii-aarch64/boards/rpi4b/startup.S`, `board.zig`, `linker.ld`), the port (`micro-os-plus-iii-aarch64/src/port.zig`, `arch.zig`, `mmu.zig`, `gic.zig`, ...) and the kernel (`micro-os-plus-iii/src/rtos/thread.zig` — creation, join, yield — and the rest of `micro-os-plus-iii/src/`)
- `micro-os-plus-iii-aarch64/build.zig`: the two entries `tutor-02-threads-1cpu` and `-4cpu`

## 4. The test

PASS when, in both versions: the four workers joined, each `join()` returned
its worker's result; each worker's samples lie in their regions and its
checksum and maximum equal its reference; the merged maximum equals the
reference's; the heap is back to its level once the threads are destroyed;
(1 CPU) the trace is round-robin; (4 CPUs) cores 1–3 joined and every
worker ran all its steps on its own core.

## 5. Running it

```sh
cd micro-os-plus-iii-aarch64
export PATH=$HOME/zig-x86_64-linux-0.17.0:$PATH
zig build -Dtest=tutor-02-threads-1cpu run      # build, then QEMU raspi4b
zig build -Dtest=tutor-02-threads-4cpu run
test/run-all.sh tutor-02-threads-1cpu           # the board (the image built above)
test/run-all.sh tutor-02-threads-4cpu
```

## 6. Results

Both versions PASS under QEMU and on the board (2026-10-22): 15 s and 14 s
on the board. The per-worker checksums and maxima are the C++ lesson's, and
the merged maximum is 9711 (#109). See [`RESULTS.md`](RESULTS.md).
