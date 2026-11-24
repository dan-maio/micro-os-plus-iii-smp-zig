# Lesson 08 (Zig) — Critical sections: the scheduler lock and the interrupt lock

## 1. Theory

### Who can come in

A **critical section** is a stretch of code that must run without
somebody else touching the same data halfway through. Lesson 05 locked a
mutex for that, but a mutex is a kernel object that blocks, and an
interrupt handler cannot wait on it. Below the mutex there are two simpler
locks, and the difference between them is *who* they keep out:

- the **scheduler lock** keeps out the other **threads** of this core: while
  it is held, the scheduler does not switch away from the running thread,
  even if a higher-priority one becomes ready; that one runs when the lock
  is released. **Interrupts keep running.**
- the **interrupt lock** keeps out the **interrupts** of this core: they are
  masked; one that falls due waits, and runs as the lock is released. With
  the interrupts off nothing can take the CPU away either (a switch comes
  from an interrupt or from the thread's own call), so on one CPU it keeps
  out everything.

So the question to ask about shared data is: *who else writes it?* Only
threads → the scheduler lock is enough (or a mutex). An interrupt handler
too → only the interrupt lock protects it, because the handler does not
care about the scheduler.

### The read-modify-write

`counter = counter + 1` is three steps: read, add, write. If an interrupt
handler adds one between the thread's read and its write, the thread writes
back the old value plus one and the handler's update is **lost**. Nothing
crashes; a count is simply wrong — the worst kind of bug, because it
depends on timing.

### What each costs

A lock is paid for by the ones it keeps out:

- a scheduler section of length *T* delays a high thread made ready inside
  it by up to *T* (its **thread latency**), and no interrupt;
- an interrupt section of length *T* delays every interrupt that falls due
  inside it by up to *T* (the **interrupt latency**) — the tick, the UART,
  everything.

Both must therefore be short. The interrupt lock is the stronger and the
more expensive one: use it only around what an ISR shares, and only for a
few instructions.

### Uncritical sections

Sometimes code inside a section must briefly let the others in — to wait,
or to let a high thread run. An **uncritical section** does the opposite
of its critical section, for its own extent, and restores the lock at its
end: a scheduler uncritical section allows switching again, an interrupt
uncritical section unmasks the interrupts.

### Several CPUs

Both locks act on **one core**. On four cores that changes their meaning:

- core 0's scheduler lock does not stop the threads of cores 1–3: a thread
  made ready on core 1 runs at once. The scheduler lock is **not** a mutual
  exclusion between cores; two threads on two cores update the counter at
  the same time whatever it says.
- masking core 0's interrupts does not stop the other cores either. So the
  interrupt lock of an SMP kernel also takes a **spinlock**: a word that one
  core at a time can own, the others spinning until it is free. Every core
  that enters an interrupt section — threads and ISRs alike — waits for the
  one inside. Code that does not enter it is not stopped: a spinlock only
  excludes the ones that take it.
- an ISR on another core is like another thread: it must take the lock
  too. On one CPU an ISR cannot be interrupted by the thread it races; on
  four, the thread may run on another core at the same instant.

### And the kernel itself

The kernel also has data to protect — its ready lists, the waiting lists,
the heap — and it runs from threads and from ISRs (a post) on every core.
µOS++ protects them with its own **kernel critical section**, the
interrupt lock (and so the spinlock) plus a flag that tells the scheduler
not to switch inside; the application's scheduler lock stays what it is
above, a per-core switch lock that leaves interrupts on.

## 2. In µOS++ (Zig)

- `rtos.scheduler.CriticalSection`: `const scs = scheduler.CriticalSection.enter(); defer scs.exit();`
  (the C++ RAII object becomes a value with an explicit `exit()`);
  `scheduler.UncriticalSection`; `scheduler.locked()`; `scheduler.lock()` /
  `unlock()` / `setLocked(state)`.
- `rtos.interrupts.CriticalSection`, `interrupts.UncriticalSection`, the
  same way. On this port the interrupt section masks IRQs and takes the
  kernel spinlock (recursive on its owner core); the uncritical section
  only unmasks the IRQs — **the spinlock is kept**.
- `micro-os-plus-iii/src/rtos/scheduler.zig` (the sections, and the
  kernel's own `KernelCriticalSection`), `micro-os-plus-iii/src/rtos/interrupts.zig`,
  `micro-os-plus-iii-aarch64/src/port.zig` (`criticalEnter`/`criticalExit`,
  the spinlock; `setLocked`: the scheduler lock, and the switch it runs at
  unlock if one was asked for meanwhile; `setKernelLocked`: the kernel's
  section).

## 3. The lesson

The second timer (`tutor.second_timer`, lesson 03) is the interrupt;
`spinUs(t)` busy-waits on the System Timer.

**`1cpu/main.zig`.**

- *Part A, lost updates.* The main thread adds one to `g_counter` 400
  times — read, 30 µs window, write, then a gap of 13–35 µs (varied, so the
  window does not lock to the timer's period) — while the ISR adds one
  every 100 µs. Once with no lock, once under the scheduler lock, once
  under the interrupt lock; the ISR also counts its own adds in
  `g_isr_adds`, so the expected total is known: 400 + `g_isr_adds`.
- *Part B, what each excludes.* A `high` thread waits on a semaphore. In a
  2 ms scheduler section the main thread posts it and counts: the ISR's
  runs, and the high thread's (inside, and after the section);
  `scheduler.locked()` inside and after. Then a post inside a scheduler
  uncritical section nested in a scheduler section. In a 2 ms interrupt
  section: the ISR's runs inside and just after; then 1 ms of interrupt
  uncritical section inside an interrupt section.
- *Part C, what each costs.* The ISR (period 100 µs) records the longest
  gap between two of its runs while the main thread spends 20 ms in 1 ms
  sections: none, scheduler, interrupt. Then a `high` thread woken by the
  ISR (period 2 ms) records its latency from the ISR's post: with no lock;
  under a scheduler section held from just after the interrupt for 1 ms;
  under a 2.5 ms interrupt section, longer than the period, so that an
  interrupt falls due inside (and the ISR's delay from the section's end is
  measured too).

**`4cpu/main.zig`** first releases cores 1–3, then:

- *Part A*: two threads on cores 1 and 2 make 200 updates each, the ISR
  runs on core 0 and takes an interrupt section itself;
- *Part B*: the scheduler section on core 0 with high threads on cores 0
  and 1; the interrupt section on core 0 with a loop on core 1 that enters
  an interrupt section to count, and one on core 2 that counts without a
  lock; then the interrupt uncritical section, with the same two loops;
- *Part C*: the ISR's gap on core 0 as with one CPU; the woken thread on
  core 2, the ISR and the sections on core 0.

### Files in the build

The same files as lesson 01 (see `../01-bring-up/README.md`, *Files in the
build*), with this lesson's own source in place of lesson 01's:

- `micro-os-plus-iii-aarch64/test/tutor/08-critical-sections/1cpu/main.zig` (or `4cpu/main.zig`)
- `micro-os-plus-iii-aarch64/test/tutor/common/tutor.zig` (`second_timer`, `onHardware()`)
- `micro-os-plus-iii-aarch64/test/start.zig` (the `uos_external_irq` forwarder)
- the port (`micro-os-plus-iii-aarch64/src/port.zig`), the board (`micro-os-plus-iii-aarch64/boards/rpi4b/startup.S`, `board.zig`, `linker.ld`) and the kernel (`micro-os-plus-iii/src/rtos/scheduler.zig`, `interrupts.zig`, `semaphore.zig`, and the rest of `micro-os-plus-iii/src/`)
- `micro-os-plus-iii-aarch64/build.zig` — the entries `tutor-08-critical-sections-1cpu` and `-4cpu`

## 4. The test

PASS when, in both versions:

- updates are lost with no lock and under the scheduler lock, none under
  the interrupt lock;
- (1 CPU) in a scheduler section the ISR runs, the high thread made ready
  does not, and runs as it ends; `locked()` is true inside, false after;
  in a scheduler uncritical section it runs at once. In an interrupt
  section the ISR does not run, and runs as it ends; in an interrupt
  uncritical section it runs;
- (4 CPUs) in core 0's scheduler section core 0's ISR and the high thread
  on core 1 run, the one on core 0 only as it ends; in core 0's interrupt
  section core 0's ISR and core 1's locked loop stop, core 2's free loop
  runs, and core 1 enters as it ends; in an interrupt uncritical section
  core 0's ISR runs and core 1 still waits;
- the ISR's longest gap is at least 900 µs under the 1 ms interrupt
  sections and, on the board, at most 150 µs with no lock and under the
  scheduler sections;
- the woken thread's latency is within 100 µs on the board (20 ms under
  QEMU) with no lock and after an interrupt section, whose ISR also runs
  within that of its end; (1 CPU) under the scheduler section it is at
  least 1000 µs; (4 CPUs) core 0's scheduler section does not delay the
  thread on core 2;
- the heap is back to its level; (4 CPUs) cores 1–3 joined.

## 5. Running it

As lesson 01 (see `../01-bring-up/README.md`, *Running it*); from
`micro-os-plus-iii-aarch64`:

```sh
cd micro-os-plus-iii-aarch64
export PATH=$HOME/zig-x86_64-linux-0.17.0:$PATH
zig build -Dtest=tutor-08-critical-sections-1cpu
zig build -Dtest=tutor-08-critical-sections-4cpu
zig build -Dtest=tutor-08-critical-sections-1cpu run    # QEMU
zig build -Dtest=tutor-08-critical-sections-4cpu run
test/run-all.sh tutor-08-critical-sections-1cpu          # the board
test/run-all.sh tutor-08-critical-sections-4cpu
```

## 6. Results

Both versions PASS under QEMU and on the board (2026-10-23): 15 s and 14 s
on the board. Under QEMU, with one CPU, 111 and 127 updates were lost with
no lock and under the scheduler lock, none under the interrupt lock; the
ISR's longest gap went to 1087 µs under the interrupt sections, a high
thread on the same core waited 1022 µs under the scheduler section — the
C++ lesson's picture. See [`RESULTS.md`](RESULTS.md).
