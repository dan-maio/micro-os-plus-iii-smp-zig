# Lesson 06 (Zig) — Priority inversion, and the mutex protocols that bound it

## 1. Theory

### Priorities and a shared lock

A priority-based scheduler promises that the most urgent ready thread runs.
A mutex adds a second rule: a thread that needs a locked mutex waits for its
owner, whatever their priorities. The two rules meet when a **high**-priority
thread needs a mutex held by a **low**-priority one: the high thread must
wait for the low one to finish its critical section. That wait is expected,
and short — one critical section.

### Priority inversion

The trouble starts with a third thread of **medium** priority that does not
use the mutex at all. While the high thread is blocked, the scheduler looks
at who is ready: the low thread (holding the mutex) and the medium thread.
The medium one has the higher priority, so it runs — and the low thread,
which the high thread is waiting for, does not. The high thread now waits
for the medium thread's whole work, which has nothing to do with it, and if
there are several medium threads, for all of them: an unbounded wait. The
high thread effectively runs at a priority below the medium one: the
priorities are **inverted**.

This is not a theoretical problem: it is what reset the Mars Pathfinder
lander in 1997 — a high-priority bus task waiting on a mutex held by a
low-priority meteorological task, while medium-priority communications
work ran.

### The protocols

A mutex can be made to fix this itself, with a **protocol**:

| Protocol | What the owner's priority is | The high thread waits |
|---|---|---|
| **none** | its own | the critical section, plus whatever medium work runs meanwhile: unbounded |
| **priority inheritance** | raised to the highest priority of the threads waiting for the mutex, for as long as it holds it | at most the rest of one critical section |
| **priority ceiling** (protect) | raised to the mutex's *ceiling* — the priority of its most urgent user, fixed in advance — as soon as it locks | at most one critical section; the medium threads never get in |

Inheritance raises the priority only when there is contention; the ceiling
raises it every time, but never needs to change it while waiting threads
come and go, and it also prevents some deadlocks between two mutexes.

### Several CPUs

Priorities order the threads **of one core** (lesson 03). If the medium
thread runs on another core than the low one, it does not take the low
thread's CPU, and there is no inversion even without a protocol: the high
thread waits one critical section. On several cores, inversion needs the
threads involved to share a core — which a real system does not always
control, so the protocols remain the defence.

## 2. In µOS++ (Zig)

- `rtos.Mutex.initWith("name", .{ .protocol = .none, .priority_ceiling =
  rtos.priority.high })` (or `.inherit`, `.protect`); the default protocol
  is `.inherit` — lesson 05's mutexes inherited.
- `thread.priority()` is the *effective* priority (the inherited or ceiling
  one included); `priorityInherited()` the boost alone.
- `micro-os-plus-iii/src/rtos/mutex.zig`: the boost of the owner when a
  higher thread blocks (inherit) or when it locks (protect), and its undoing
  at unlock.

## 3. The lesson

The data is lesson 05's: one shared list (here 72 samples in the data
segment), one mutex. Three threads around it:

- **L** (`low`) locks the mutex and stays 20 ms (of the System Timer, wall
  time) in its critical section, sorting the shared list again and again
  and recording the highest priority it ran at;
- **H** (`high`) asks for the mutex once L holds it, and records how long it
  waited;
- **M** (`normal`) computes 100 ms without touching the mutex.

The main thread, at `realtime`, creates L, waits until L holds the mutex,
then creates H and M together and waits for the three on a semaphore.
`run()` does this once per protocol, with a fresh mutex each time.

**`1cpu/main.zig`** runs the three protocols:

- `none`: H blocks, M runs its 100 ms, then L finishes and H gets the
  mutex — H waited over 100 ms. (L's 20 ms are wall time, so after M it
  hardly sorts any more.)
- `inherit`: when H blocks, L runs at `high`; M waits; H gets the mutex
  within the rest of L's section.
- `protect` (ceiling `high`): L runs at `high` from its lock on; the same.

**`4cpu/main.zig`** first releases cores 1–3, then runs the same three
with L, H and M all pinned to core 1 (the same results as with one CPU),
and a fourth time with `none` and M on core 2: L keeps core 1, and H waits
one section although nothing protects it. The main thread stays on core 0.

The checks: H's wait (≥ 100 ms with `none` on one core; ≤ 20 ms plus a
slack of 2 ms on the board, 20 ms under QEMU, otherwise), L's priority
while holding (low, high, high), and the shared list intact afterwards
(72 samples, its sorted checksum equal to the reference).

### Files in the build

The same files as lesson 01 (see `../01-bring-up/README.md`, *Files in the
build*), with this lesson's own source in place of lesson 01's:

- `micro-os-plus-iii-aarch64/test/tutor/06-priority-inversion/1cpu/main.zig` (or `4cpu/main.zig`)
- `micro-os-plus-iii-aarch64/test/tutor/common/tutor.zig` (`second_timer.nowUs()`, `onHardware()`)
- the port (`micro-os-plus-iii-aarch64/src/port.zig`), the board (`micro-os-plus-iii-aarch64/boards/rpi4b/startup.S`, `board.zig`, `linker.ld` — the per-core stacks and the guard line before the heap) and the kernel (`micro-os-plus-iii/src/rtos/mutex.zig` — the protocols; `thread.zig` — the effective priority; and the rest of `micro-os-plus-iii/src/`)
- `micro-os-plus-iii-aarch64/build.zig` — the entries `tutor-06-priority-inversion-1cpu` and `-4cpu`

## 4. The test

PASS when:

- `none` (one CPU, or the three on one core): H waited at least M's 100 ms;
- `inherit` and `protect`: H waited at most one critical section (20 ms +
  slack);
- (4 CPUs) `none` with M on another core: H waited at most one critical
  section;
- L ran at `low` with `none`, at `high` with `inherit` and `protect`;
- the shared list is intact; the heap is back to its level; (4 CPUs) cores
  1–3 joined.

## 5. Running it

As lesson 01 (see `../01-bring-up/README.md`, *Running it*); from
`micro-os-plus-iii-aarch64`:

```sh
cd micro-os-plus-iii-aarch64
export PATH=$HOME/zig-x86_64-linux-0.17.0:$PATH
zig build -Dtest=tutor-06-priority-inversion-1cpu
zig build -Dtest=tutor-06-priority-inversion-4cpu
zig build -Dtest=tutor-06-priority-inversion-1cpu run    # QEMU
zig build -Dtest=tutor-06-priority-inversion-4cpu run
test/run-all.sh tutor-06-priority-inversion-1cpu          # the board
test/run-all.sh tutor-06-priority-inversion-4cpu
```

## 6. Results

Both versions PASS under QEMU and on the board (2026-10-22), 14–15 s on
the board, three times each, the four-CPU run every time straight after the
one-CPU one. The waits are the C++ lesson's: with `none` 100 ms, with
`inherit` and `protect` the rest of L's 20 ms section, with M on another
core one section. The first four-CPU board run found the cause of core 3's
intermittent failures (lessons 04 and 05): a cache line shared between core
3's stack and the heap, fixed in `boards/rpi4b/linker.ld`; see
[`RESULTS.md`](RESULTS.md).
