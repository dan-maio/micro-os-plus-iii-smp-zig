# Lesson 18 (Zig) — Balancing: threads without affinity, migration, affinity at run time

## 1. Theory

### Time slices on one CPU

Threads of the same priority are equals: none preempts another. If they
never wait, one of them would keep the CPU forever — unless the kernel
**time-slices** them: at every tick, the running thread goes to the end of
its priority's ready list, and the next one runs. Eight busy threads then
take turns of one tick each, round and round, and each gets an eighth of
the CPU. A higher-priority thread is not affected: it preempts them all, as
always; time slicing only orders equals.

### One ready list, several cores

The SMP scheduler keeps **one ready list for all the cores**. When a core
reschedules — at its tick, when its thread waits, when an interrupt wakes
something — it takes the highest-priority ready thread that it **may** run.
A thread's *affinity* is the set of cores it may run on; by default, all of
them: the thread **floats**. Eight floating workers on four cores keep all
four busy with no plan at all: each core takes the next one. This is
*balancing by a shared queue*: no core idles while a thread it may run is
ready.

A floating thread **may** move between cores — a *migration* — whenever it
is preempted on one and taken by another. It does not have to: when a core
puts its thread back at the end of the list and takes the head, the same
few threads tend to come back to the same core. Migration has a cost (the
thread's data is in the old core's cache), so staying is no loss.

### Fairness

Fair means each equal thread gets the same share of CPU time. On one CPU
time slicing gives it. On four, with the shared list, too: eight threads,
four cores, every thread about half a core.

To *measure* a share, count the work done — but the unit of work must cost
the same on every thread. Two traps, both met by this lesson on the board:
"busy until 100 µs have passed" counts the time a thread was preempted as
its own work; and a loop whose counter lives in memory (on the thread's
stack) runs at different speeds on different threads, as their stacks fall
in memory. The lesson's chunk is a fixed number of iterations of a loop in
registers only.

### Changing affinity at run time

`setCpuAffinity(mask)` only writes the mask. Nothing happens until a core
next decides: the core the thread runs on lets it go at its next switch
(its tick, at the latest), and a core in the new mask takes it at **its**
next switch. The cores' ticks are not in step, so a move takes up to two
ticks. After that the thread never runs outside the new mask.

## 2. In µOS++ (Zig)

- `rtos.Thread.Attributes.cpu_affinity` — the mask at creation; by default
  all cores.
- `th.setCpuAffinity(mask)` — set it at run time.
- The time slices: the kernel's tick (`micro-os-plus-iii/src/rtos/scheduler.zig`,
  `internalSwitchThreads()`: the outgoing thread re-linked at the end of its
  priority); the per-core pick by affinity.
- The lesson's workers run at `rtos.priority.below_normal`, under the main
  thread, which starts them all before any runs on its core (lesson 17).
- The chunk's loop is an `asm volatile` add, in registers, in a `noinline`
  function.

## 3. The lesson

**`1cpu/main.zig`.** A chunk is calibrated first: the iterations of the
loop in 100 µs, measured with the interrupts masked.

- *Part A.* Eight workers of 100 chunks each, all ready at once: the time
  each started and ended, and every change of the running worker (a time
  slice).
- *Part B.* Eight workers count chunks for 400 ms, while the main thread
  sleeps; then it stops them.

**`4cpu/main.zig`** first releases cores 1–3; parts A and B are the same,
with the eight workers floating over the four cores, each recording the
cores it ran on and its migrations. And **part C**: four floating workers and
a floating `mover`, which logs the time and core of every chunk; after 100
ms the main thread pins the mover to core 2, after another 100 ms to core 3,
then sets it free again.

### Files in the build

The same files as lesson 01 (see `../01-bring-up/README.md`, *Files in the
build*), with this lesson's own source in place of lesson 01's:

- `micro-os-plus-iii-aarch64/test/tutor/18-balancing/1cpu/main.zig` (or `4cpu/main.zig`)
- `micro-os-plus-iii-aarch64/test/tutor/common/tutor.zig` (`second_timer.nowUs()`, `onHardware()`)
- `micro-os-plus-iii-aarch64/test/board.zig` (`options()`, `cpuSlot()`, the SMP start)
- the port (`micro-os-plus-iii-aarch64/src/port.zig`), the board (`micro-os-plus-iii-aarch64/boards/rpi4b/startup.S`, `board.zig`, `linker.ld`) and the kernel (`micro-os-plus-iii/src/rtos/scheduler.zig`, `thread.zig`, and the rest of `micro-os-plus-iii/src/`)
- `micro-os-plus-iii-aarch64/build.zig` — the entries `tutor-18-balancing-1cpu` and `-4cpu`

## 4. The test

PASS when, in both versions:

- part A: every worker did its 100 chunks; all eight were under way before
  the first one ended;
  - one CPU: at least 32 time slices; the work took its own time (0.95 …
    1.01× on the board);
  - four CPUs: the workers ran on all four cores and moved between them; the
    work went at least 3.5× as fast as on one core (on the board);
- part B: the fewest chunks at least 90 % of the most (on the board; 50 %
  under QEMU); the cores busy at least 95 % of the window (on the board);
- (4 CPUs) part C: free, the mover ran on more than one core; pinned to core
  2, then 3, it ran there within 3 ms (on the board) and nowhere else after;
  freed again, it left core 3;
- the heap is back to its level; (4 CPUs) cores 1–3 joined.

## 5. Running it

As lesson 01 (see `../01-bring-up/README.md`, *Running it*); from
`micro-os-plus-iii-aarch64`:

```sh
cd micro-os-plus-iii-aarch64
export PATH=$HOME/zig-x86_64-linux-0.17.0:$PATH
zig build -Dtest=tutor-18-balancing-1cpu
zig build -Dtest=tutor-18-balancing-4cpu
zig build -Dtest=tutor-18-balancing-1cpu run    # QEMU
zig build -Dtest=tutor-18-balancing-4cpu run
test/run-all.sh tutor-18-balancing-1cpu          # the board
test/run-all.sh tutor-18-balancing-4cpu
```

(With a second CMSIS-DAP probe on the host: `UOS_HW_ADAPTER_SERIAL=<serial>`,
see lesson 17.)

## 6. Results

Both versions PASS under QEMU and on the board (2026-10-24): 15 s and 15 s
on the board, every check — fair shares within 10 %, a move within 3 ms —
passed there. Under QEMU, eight workers time-sliced 75 times in 74 ms on one
CPU; on four, the work went 3.70× faster, with 1 migration, and each did
2049–2094 chunks in 400 ms; the mover reached core 2 in 0.7 ms and core 3 in
0.9 ms, and never ran elsewhere after. See [`RESULTS.md`](RESULTS.md).

### What this lesson found

The C++ version found it (see the golden workspace's lesson): a chunk must
be a fixed amount of work, in registers, calibrated with the same,
not-inlined code and the interrupts masked. The Zig version was written
that way from the start, and under QEMU only the one-CPU upper bound (1.01×,
the board's) had to be loosened (QEMU's calibration varies: 1.08× there).
