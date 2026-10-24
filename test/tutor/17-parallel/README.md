# Lesson 17 (Zig) — Parallel work: split, merge, measure

## 1. Theory

### Splitting the work

A job runs in parallel when it can be cut into parts that do not depend on
each other. Sorting can: sort each quarter of the data on its own, then
**merge** the sorted quarters — the merge takes the smallest of the four
heads, n times, so it costs O(n). Finding the maximum can too: each part
finds its own, then the four are **reduced** to one. The pattern —
*partition, compute, combine* — is the base of every parallel program.

The combine step must give exactly the result of the whole job. Here it
does by construction: the order is total (value, then id), so the merge of
four sorted lists is the one sorted list; of equal maxima the reduction
keeps the lowest id, as the maximum of the sorted list does.

### Two different speed-ups

Splitting changes the work before it changes the CPUs. The course's sort is
an insertion sort, O(n²): four sorts of n/4 cost 4 × (n/4)² = n²/4, a
quarter of one sort of n — **four times faster on the same core**, before a
second core is used. Whoever measures only "split versus whole" on four
cores credits the CPUs with what the algorithm did. So the lesson measures
three things:

- **A**, the whole job on one core: the reference time;
- **B**, the split job, all its parts on **one** core: the algorithm's gain
  (and the memory's, see below);
- **C**, the split job, one part per core: against B, the speed-up of
  running in parallel — at most the number of cores.

### Amdahl's law

The merge runs on one core after the parts, whatever the core count. If a
fraction *s* of the time is serial, *N* cores give at most
1 / (s + (1 − s) / N). With B's sorts taking *S* and its merge *M*, the
bound for C is (S + M) / (S / 4 + M). The serial part decides how far the
parallel part can go.

### What else costs

- **Creating and joining threads** costs microseconds, every time. For work
  of a millisecond it is not small: the lesson creates the workers first,
  lets them wait for a start signal, and times the work from that signal,
  apart from the creation and the join.
- **The cache.** A 4096-sample list is 128 KiB; a quarter is 32 KiB — the
  Cortex-A72's L1 data cache. The whole list's sort walks memory that does
  not fit in L1; a quarter's does. On the board this makes the split far
  more than 4 times faster; QEMU has no cache model.
- **Who runs when, on a core.** A thread that makes another thread of its
  own priority ready on its own core gives it the CPU, as a yield does. A
  dispatcher at the workers' priority would hand its core to the first
  worker it starts. The main thread therefore runs above the workers: it
  creates and signals all four, and they run when it waits.

## 2. In µOS++ (Zig)

- `rtos.Thread.create(gpa, name, f, arg, .{ .cpu_affinity = ..., .priority = ... })`
  for the placement (lesson 02); `join()`, `destroy()`.
- `rtos.Semaphore.counting(name, 4, 0)` — the start signal: four `post()`s,
  one per worker.
- The work: `tutor.sortList()`, `maxOf()`, `checksum()`, `reference()`
  (`test/tutor/common/tutor.zig`); the merge and the reduction are the
  lesson's.
- `tutor.second_timer.nowUs()` — the BCM2711 System Timer, one clock for
  every core.

## 3. The lesson

**`1cpu/main.zig`.** 4096 samples (seed 17, ids 1..4096) are made on the
heap, and the reference is computed on an array.

- *Part A.* The whole set as one list: sorted, maximum found, timed.
- *Part B.* Four workers (`below_normal`), each with a quarter (1024
  samples): link it into its own list, sort it, take its maximum. The main
  thread creates them, posts the start signal four times, joins them; then
  merges the four lists into one by relinking and reduces the four maxima.
  The workers share the one CPU (they time-slice at the tick).

**`4cpu/main.zig`** first releases cores 1–3; parts A and B run on core 0.
And **part C**: the same four workers, worker *k* pinned to core *k*.

### Files in the build

The same files as lesson 01 (see `../01-bring-up/README.md`, *Files in the
build*), with this lesson's own source in place of lesson 01's:

- `micro-os-plus-iii-aarch64/test/tutor/17-parallel/1cpu/main.zig` (or `4cpu/main.zig`)
- `micro-os-plus-iii-aarch64/test/tutor/common/tutor.zig` (`sortList()`, `maxOf()`, `checksum()`, `reference()`, `second_timer.nowUs()`, `onHardware()`)
- `micro-os-plus-iii-aarch64/test/board.zig` (`options()`, `cpuSlot()`, the SMP start)
- the port (`micro-os-plus-iii-aarch64/src/port.zig`), the board (`micro-os-plus-iii-aarch64/boards/rpi4b/startup.S`, `board.zig`, `linker.ld`, `openocd.cfg`) and the kernel (`micro-os-plus-iii/src/rtos/thread.zig`, `semaphore.zig`, and the rest of `micro-os-plus-iii/src/`)
- `micro-os-plus-iii-aarch64/build.zig` — the entries `tutor-17-parallel-1cpu` and `-4cpu`

## 4. The test

PASS when, in both versions:

- every sample is on the heap, sealed;
- parts A and B (and C) give the reference's sorted order (checksum
  `80cee5e8`) and maximum (9999, id 3966), the merged list holding all 4096;
- part B is at least 3× faster than part A on the board (1.5× under QEMU):
  the O(n²) sort split in four;
- (4 CPUs) the four workers ran on core 0 in part B, worker *k* on core *k*
  in part C; part C's sorts at least 3× faster than part B's on the board
  (1.2× under QEMU);
- the heap is back to its level; (4 CPUs) cores 1–3 joined.

## 5. Running it

As lesson 01 (see `../01-bring-up/README.md`, *Running it*); from
`micro-os-plus-iii-aarch64`:

```sh
cd micro-os-plus-iii-aarch64
export PATH=$HOME/zig-x86_64-linux-0.17.0:$PATH
zig build -Dtest=tutor-17-parallel-1cpu
zig build -Dtest=tutor-17-parallel-4cpu
zig build -Dtest=tutor-17-parallel-1cpu run    # QEMU
zig build -Dtest=tutor-17-parallel-4cpu run
test/run-all.sh tutor-17-parallel-1cpu          # the board
test/run-all.sh tutor-17-parallel-4cpu
```

With more than one CMSIS-DAP probe on the host, name the Pi's by its
serial: `UOS_HW_ADAPTER_SERIAL=<serial> test/run-all.sh ...`
(`boards/rpi4b/openocd.cfg`).

## 6. Results

Both versions PASS under QEMU and on the board (2026-10-24): 14 s and 14 s
on the board. Under QEMU every part gave the reference's order and maximum
(checksum `80cee5e8`, max 9999, id 3966, as in C++); the split was 4.0×
faster than the whole on one core, and part C's sorts 4.3× faster than part
B's (QEMU's figures; on the board the check of at least 3× passed). See
[`RESULTS.md`](RESULTS.md).

### What this lesson found

- **A dispatcher at its workers' priority.** At first the workers ran at the
  main thread's priority. In Zig a thread that makes one of its own priority
  ready on its own core gives it that core at once (C++ defers the switch:
  its `post` wakes inside the kernel lock). On the board the first post
  handed core 0 to worker 0 for its whole sort before workers 1–3 were
  signalled, and part C's sorts were only 2× faster ("at least 3.00x" failed).
  The workers now run below the main thread.
- **Two probes on one host.** OpenOCD took the Pico 2's Debug Probe, which
  has no JTAG; `boards/rpi4b/openocd.cfg` now takes the probe's serial from
  `UOS_HW_ADAPTER_SERIAL` when it is set.
