# Lesson 05 (Zig) — Mutex: mutual exclusion, its types, and waiting with a limit

## 1. Theory

### Shared data and the race

Two threads that change the same data at the same time can each undo the
other's work. A push on a linked list looks like one step — `node->next =
head; head = node;` — but the processor does it in several: load `head`,
store it into the node, store the node into `head`. If a second thread runs
between the load and the last store, and pushes its own node, the first
thread's store then writes `head` back from the value it loaded before:
the second thread's node is no longer reachable. Nothing crashes; a node is
simply **lost**, silently. This is a **race condition**, and the
instructions that must not interleave are the **critical section**.

With one CPU a race needs a preemption inside the critical section — rare,
which is what makes it dangerous: a program can pass every test and fail in
the field. With several CPUs no preemption is needed: two cores run the
critical section at the same time, and the race happens as soon as there is
contention.

### Mutual exclusion

A **mutex** (mutual exclusion lock) has one owner at a time. A thread
**locks** it before the critical section and **unlocks** it after; a second
thread that tries to lock it meanwhile **blocks** — it is suspended, uses no
CPU, and is made ready when the owner unlocks. Every access to the shared
data must take the same mutex; then the critical sections of different
threads run one after the other, whatever the scheduling, on one CPU or on
several.

A mutex is a *thread* object: it has an owner, only the owner may unlock it,
and it can not be used from an interrupt handler (an ISR cannot block). It
is also the object the kernel builds priority-inheritance on (lesson 06).

### Three behaviours for the owner locking again

What happens when the owner locks a mutex it already holds is the mutex's
**type**:

| Type | The owner locks again | The owner unlocks one time too many |
|---|---|---|
| **normal** | deadlock: the thread waits for itself, for ever | undefined |
| **errorcheck** | refused, `EDEADLK` | refused, `EPERM` |
| **recursive** | allowed: a count goes up; the mutex is free when it is back at zero | refused, `EPERM` |

A recursive mutex lets a function that takes the lock call another that
takes it too; an errorcheck mutex turns a programming error into an error
code; a normal mutex is the cheapest and assumes the program is right.

### Waiting with a limit

Blocking without a limit is not always acceptable in a real-time system: a
thread with a deadline may prefer to do something else than wait for a lock
held too long. So a mutex also offers

- **`try_lock`** — take it if it is free, otherwise return at once
  (`EWOULDBLOCK`);
- **`timed_lock (t)`** — wait at most `t` ticks, then give up (`ETIMEDOUT`).

### Several CPUs

The mutex itself must be safe across cores: its owner and its list of
waiters are shared data too, protected inside the kernel by the kernel's own
spinlock. A thread blocked on a mutex held on another core is woken there
when the owner unlocks — by the cross-core IPI of lesson 04.

## 2. In µOS++ (Zig)

- `rtos.Mutex`: `.initWith("name", .{})` — normal by default; `.{ .type =
  .errorcheck }` or `.recursive`; `.initRecursive("name")`.
- `mx.lock()`, `mx.unlock()`, `mx.tryLock()`, `mx.timedLock(ticks)`; each
  returns `rtos.Error!void`: `error.WouldBlock` (C++ `EWOULDBLOCK`),
  `error.TimedOut` (`ETIMEDOUT`), `error.Deadlock` (`EDEADLK`),
  `error.NotPermitted` (`EPERM`), ...; the lesson prints the C++ names.
- `micro-os-plus-iii/src/rtos/mutex.zig`: the types, the owner and the
  recursion count, the waiters' list.

## 3. The lesson

New against lesson 04: **one** data structure shared by several threads.

**`1cpu/main.zig`.**

- *Part A, the race.* Four workers push 200 samples each (ids 0 .. 799,
  `g_nodes[4][200]` in the data segment) on one shared intrusive list,
  `g_list`, with no lock. `pushSlow()` reads the head, calls `window()`,
  then writes the node and the head; with one CPU `window()` is a
  `this_thread.yield()` — the unlucky preemption, made certain — so the
  other workers push in between and the write-back throws their nodes away.
  The main thread counts the list.
- *Part B, the fix.* The same pushes, each between `g_list_mx.lock()` and
  `unlock()`; the yield inside the critical section is still there, but a
  worker that yields while holding the mutex keeps the others out. All 800
  nodes must be in the list, each exactly once (a `seen[]` array), and the
  sorted list's checksum must equal `reference(seed, 0, 800)`.
- *Part C, the types.* A normal mutex: the owner's `try_lock ()` returns
  `EWOULDBLOCK` (a `lock ()` would deadlock). An errorcheck mutex: a second
  `lock ()` returns `EDEADLK`, an extra `unlock ()` `EPERM`. A recursive
  mutex: 5 `lock ()`s and 5 `unlock ()`s succeed, another thread's
  `try_lock ()` meanwhile returns `EWOULDBLOCK`, and a 6th `unlock ()`
  returns `EPERM`.
- *Part D, waiting.* A `holder` thread (above the main thread's priority,
  so it takes the mutex first) holds `g_held_mx` for 50 ticks. The main
  thread's `try_lock ()` returns `EWOULDBLOCK` at once, `timed_lock (10)`
  `ETIMEDOUT` after exactly 10 ticks, and `timed_lock (200)` the mutex in
  the tick the holder releases it.

**`4cpu/main.zig`** first releases cores 1–3, then does the same with the
four workers pinned one per core, so they run at the same time:
`window()` is a short spin instead of a yield, and the losses of part A
come from real contention — how many depends on timing, so that check only
requires the count not to exceed 800. The other thread of part C runs on
core 2, the holder of part D on core 1 while the main thread waits on core 0.

### Files in the build

The same files as lesson 01 (see `../01-bring-up/README.md`, *Files in the
build*), with this lesson's own source in place of lesson 01's:

- `micro-os-plus-iii-aarch64/test/tutor/05-mutex/1cpu/main.zig` (or `4cpu/main.zig`)
- `micro-os-plus-iii-aarch64/test/tutor/common/tutor.zig`
- the port (`micro-os-plus-iii-aarch64/src/port.zig` — the kernel lock, `src/faults.zig` — the fault report), the board (`micro-os-plus-iii-aarch64/boards/rpi4b/startup.S`, `board.zig`, `linker.ld`) and the kernel (`micro-os-plus-iii/src/rtos/mutex.zig` — the mutex; `thread.zig`; and the rest of `micro-os-plus-iii/src/`)
- `micro-os-plus-iii-aarch64/build.zig` — the entries `tutor-05-mutex-1cpu` and `-4cpu`

## 4. The test

PASS when, in both versions:

- (1 CPU) without the lock, nodes are lost; (4 CPUs) the unprotected count
  does not exceed 800 (the losses are printed);
- with the mutex, all 800 nodes are in the list, each once, and the sorted
  checksum equals the reference;
- normal: the owner's `try_lock` returns `EWOULDBLOCK`; errorcheck: relock
  `EDEADLK`, extra unlock `EPERM`; recursive: 5 deep, busy for another
  thread, a 6th unlock `EPERM`;
- `try_lock` on the held mutex returns `EWOULDBLOCK`, `timed_lock (10)`
  `ETIMEDOUT` after 10 ticks (11 at most), `timed_lock (200)` succeeds at
  most a tick after the release;
- (4 CPUs) cores 1–3 joined;
- the heap is back to its level.

## 5. Running it

As lesson 01 (see `../01-bring-up/README.md`, *Running it*); from
`micro-os-plus-iii-aarch64`:

```sh
cd micro-os-plus-iii-aarch64
export PATH=$HOME/zig-x86_64-linux-0.17.0:$PATH
zig build -Dtest=tutor-05-mutex-1cpu
zig build -Dtest=tutor-05-mutex-4cpu
zig build -Dtest=tutor-05-mutex-1cpu run    # QEMU
zig build -Dtest=tutor-05-mutex-4cpu run
test/run-all.sh tutor-05-mutex-1cpu          # the board
test/run-all.sh tutor-05-mutex-4cpu
```

## 6. Results

Both versions PASS under QEMU and on the board (2026-10-22): 15 s each on
the board. The results are the C++ lesson's: with one CPU the same 596
nodes lost under QEMU, with four a different number on every run; with the
mutex all 800, each once, checksum exact; the types and the waits as
specified. One open point: in one four-CPU board run, core 3 faulted while
it was starting and never joined; see [`RESULTS.md`](RESULTS.md).
