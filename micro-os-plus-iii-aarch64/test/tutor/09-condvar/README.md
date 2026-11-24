# Lesson 09 (Zig) — Condition variables: waiting for a predicate

## 1. Theory

### Waiting for a state, not for an event

A semaphore (lesson 07) counts events: every post is kept until a wait
takes it. Often a thread does not wait for an event but for a **state** of
shared data — "the buffer is not full", "there is a token", "the work is
done" — a condition over variables that a mutex protects. A **condition
variable** is the place where threads wait for such a state to change:

- `wait (mx)`: called with the mutex locked; it **atomically** unlocks the
  mutex and blocks the thread, and locks the mutex again before it
  returns;
- `signal ()`: wakes one waiting thread (if any);
- `broadcast ()`: wakes all of them.

The condition itself — the **predicate** — is not in the condition
variable: it is ordinary code over the shared data, evaluated with the
mutex held.

### The loop

Every wait is written as a loop:

```zig
try mx.lock();
while (!predicate)        // not `if`
    try cv.wait(&mx);
// the predicate is true here, and the mutex is held
...
try mx.unlock();
```

Three reasons force the `while`:

- `broadcast ()` wakes every waiter, but the state may satisfy only some of
  them: the first to lock the mutex takes the token, the next find none;
- between the `signal ()` and the moment the woken thread holds the mutex
  again, another thread may get there first and change the state;
- implementations may wake a waiter spuriously (POSIX allows it).

Woken only means "something changed, look again".

### No memory, and the lost wake-up

A condition variable remembers nothing: a `signal ()` with nobody waiting
is simply lost. That is what makes the predicate necessary, and why it must
be changed and tested **under the mutex**:

- the signaller sets the state, then signals — with the mutex held (or just
  after releasing it);
- the waiter tests the state with the mutex held, and `wait ()` releases
  the mutex only once the thread is on the waiting list.

So either the waiter sees the new state and does not wait, or it is already
waiting when the signal comes; there is no gap in which the signal falls
between the test and the wait. That gap is the classic **lost wake-up**:
test without the mutex, get preempted, the signal comes and goes, then wait
— forever.

### Bounded buffer, again

The lesson 07 pipeline with one mutex and two condition variables: the
producer waits on `not_full` while `count == N`, the consumer on
`not_empty` while `count == 0`; each signals the other after changing
`count`. One lock protects the whole ring, the count included — simpler to
reason about than lesson 07's three semaphores.

### Several CPUs

With several consumers on several cores, a single `signal ()` per item is
right (one item, one consumer), but the **end** of the stream concerns all
of them: the producer sets `done` and broadcasts, and every consumer's loop
(`while (count == 0 && !done)`) sees it, wherever it waits. A consumer that
missed that broadcast would wait forever: here a join that never returns.

## 2. In µOS++ (Zig)

- `rtos.ConditionVariable`: `var cv: rtos.ConditionVariable = .{ .name =
  "name" };` — `cv.wait(&mx)`, `cv.timedWait(&mx, ticks)`
  (`error.TimedOut`, the mutex locked again all the same), `cv.signal()`,
  `cv.broadcast()`. Neither wait may be called from an ISR or with the
  scheduler locked (`error.NotPermitted`); the lesson prints the C++ names.
- `mx.owner` — the thread that holds the mutex.
- `micro-os-plus-iii/src/rtos/condvar.zig`: `wait()` links the thread on
  the list and unlocks the mutex in one kernel critical section, then
  switches; on return it locks the mutex again.

## 3. The lesson

**`1cpu/main.zig`.**

- *Part A, the pipeline.* `producer` (`above_normal`) builds 400 samples
  (`g_items[]`, the data segment) and passes a pointer to each through
  `g_ring[8]`, under `g_ring_mx`, waiting on `g_not_full` while the ring is
  full and signalling `g_not_empty`; `consumer` (`normal`) does the
  opposite, checks each id is the next one and its seal intact, and pushes
  it on its list. The producer runs above the consumer: it refills each
  slot as soon as the consumer frees it.
- *Part B, signal and broadcast.* Three `waiter`s (`above_normal`) loop:
  `while (tokens == 0) wait`, then take a token, counting their returns from
  `wait ()` and the **re-checks** (woken, the predicate still false). The
  main thread puts one token and signals, then two tokens and broadcasts.
- *Part C, no memory.* A signal with nobody waiting, then `timedWait(10)`
  on the same condition variable: it times out; a semaphore posted first,
  then waited: it is kept. Then the predicate set (under the mutex) and
  signalled before a `late` waiter exists: the waiter finds it true and
  never waits. `owner` checks that each wait returned with the mutex
  held.

**`4cpu/main.zig`** first releases cores 1–3, then: the producer on core 1
and **three consumers** on cores 2, 3 and 0, the producer broadcasting
`done` at the end (each consumer's ids must increase, all 400 arrive once);
the three waiters on cores 1, 2 and 3; the late waiter on core 2.

### Files in the build

The same files as lesson 01 (see `../01-bring-up/README.md`, *Files in the
build*), with this lesson's own source in place of lesson 01's:

- `micro-os-plus-iii-aarch64/test/tutor/09-condvar/1cpu/main.zig` (or `4cpu/main.zig`)
- `micro-os-plus-iii-aarch64/test/tutor/common/tutor.zig`
- the port (`micro-os-plus-iii-aarch64/src/port.zig`), the board (`micro-os-plus-iii-aarch64/boards/rpi4b/startup.S`, `board.zig`, `linker.ld`) and the kernel (`micro-os-plus-iii/src/rtos/condvar.zig`, `mutex.zig`, `thread.zig`, and the rest of `micro-os-plus-iii/src/`)
- `micro-os-plus-iii-aarch64/build.zig` — the entries `tutor-09-condvar-1cpu` and `-4cpu`

## 4. The test

PASS when, in both versions:

- all 400 samples were consumed, their seals intact, and the sorted
  checksum equals `reference(seed, 0, 400)`; (1 CPU) in order, the buffer
  filled to 8 and the producer waited on `not_full`; (4 CPUs) each
  consumer's ids increasing, never more than 8 in flight, and all three
  consumers joined after the broadcast of `done`;
- the three waiters were all in `wait ()`; `signal ()` woke exactly one,
  which took the token, with no re-check; `broadcast ()` woke all three, two
  took the tokens, at least one re-checked and waited again;
- the signal with nobody waiting was lost (`timedWait(10)`: `ETIMEDOUT`
  after 10 ticks, the mutex held again), the semaphore's post kept; the late
  waiter did not wait and held the mutex;
- the heap is back to its level; (4 CPUs) cores 1–3 joined.

## 5. Running it

As lesson 01 (see `../01-bring-up/README.md`, *Running it*); from
`micro-os-plus-iii-aarch64`:

```sh
cd micro-os-plus-iii-aarch64
export PATH=$HOME/zig-x86_64-linux-0.17.0:$PATH
zig build -Dtest=tutor-09-condvar-1cpu
zig build -Dtest=tutor-09-condvar-4cpu
zig build -Dtest=tutor-09-condvar-1cpu run    # QEMU
zig build -Dtest=tutor-09-condvar-4cpu run
test/run-all.sh tutor-09-condvar-1cpu          # the board
test/run-all.sh tutor-09-condvar-4cpu
```

## 6. Results

Both versions PASS under QEMU and on the board (2026-10-23): 14 s and 15 s
on the board. Under QEMU the one-CPU numbers are the C++ lesson's: the
producer waited 392 times, `signal ()` woke one, `broadcast ()` three, two
re-checked. See [`RESULTS.md`](RESULTS.md).

### What this lesson found in the kernel

The first run passed, but with one CPU the producer waited only 50 times
for 400 items: it refilled the ring only when the consumer had emptied it,
not as each slot was freed (lesson 07's semaphores gave 392). The producer,
woken by `signal ()`, asked for the mutex the consumer held and boosted it
(priority inheritance); when the consumer unlocked, its priority went back
to `normal` — and nothing rescheduled, so the consumer went on running with
a higher-priority thread ready, until it blocked. Two fixes, in the kernel
and the port (both versions, C++ and Zig):

- `Thread.setPriorityInherited()` (C++: `thread::priority_inherited ()`) skipped the reschedule whenever the new
  inherited priority was below the assigned one — also when the
  *effective* priority had just dropped from a boost. It now yields when it
  drops;
- a reschedule asked for under the scheduler lock or inside the kernel's
  critical section was dropped; it is now remembered per core
  (`resched_pending`) and done when the lock is released. (The tick's own
  time-slice request keeps its old rules: honouring it at the end of every
  kernel section would make equal-priority threads switch in the middle of
  a heap allocation — lesson 02's round-robin check caught that.)

With the fixes the producer waits 392 times, as with semaphores.
