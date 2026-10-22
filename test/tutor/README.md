# µOS++ IIIe tutorial (Zig) — the RTOS one step at a time (Raspberry Pi 4 B)

Status: **in progress** (2026-10-22). Lessons 01 (bring-up) and 02 (threads) are done; the plan below
covers every lesson. This is the Zig version of the course written for the
C++ kernel (golden workspace, `micro-os-plus-iii-aarch64/test/rpi4b/tutor/`):
the same idea, the same base, the same lessons and the same data — a lesson
prints the same sorted order, maximum and checksum in both languages.

## 1. The idea

One small application grows through the whole course. It never changes its
subject — a set of samples, kept in an intrusive linked list, sorted, with
their maximum found, the results printed on the UART and, later, written to
the SD card — and each lesson adds **only RTOS behaviour** to it: one more
kernel object, one more way of sharing work, one more core. A reader can
`diff` lesson *N* against lesson *N−1* and see exactly what the new feature
costs and changes; the domain code stays out of the way.

Every lesson is a complete, bootable test that ends with a verdict, so the
course is also a regression suite: if a lesson passes, the feature it
teaches works on this board.

## 2. The shared base (`test/tutor/common/tutor.zig`)

Kept deliberately small, written once, used unchanged by every lesson:

| Piece | What it is | Why it is in the base |
|---|---|---|
| `Sample` | `{ next: ?*Sample, id: u32, value: i32, where: Region, seal_word: u64 }` | One node type for the whole course; the seal detects a node changed behind its owner's back. |
| `IntrusiveList(T)` | `push`, `unlink`, `count` over `next: ?*T` (the interfaces example's list) | No allocation by the list; where a node lives is the owner's choice — the course's thread on storage. |
| Three regions | a static array (`.data`, non-zero default), a local array (the thread's stack), `gpa.create()` (the system heap) | Every lesson places its samples in all three and checks each node lies in the region it claims. |
| Algorithms | `sortList()` (insertion sort on the list, stable), `maxOf()`, `checksum()` | Deterministic work whose result is known in advance, so every lesson has an exact expected value. |
| Data generator | a fixed LCG: `generate(seed, i)` | The same samples on every run, in every lesson, in both languages. |
| Console | `board.console(fmt, args)`, one locked line at a time | Only `RESULT`/`FAIL`/`FATAL` lines reach semihosting (the board's rule). |
| Verdict | `check(cond, fmt, args)`, `finish(summary)` | Counts failed checks; prints `RESULT: PASS|FAIL (...)` and ends the run (`board.hw_result`). |
| SD log (from lesson 15) | a logger thread owning FatFs on the existing FAT32 volume, files in `/tests` | One owner for the card; read back and CRC-checked at the end. |
| A second interrupt (from lesson 03) | the BCM2711 System Timer, compare channel C1 (GIC INTID 97), routed to a chosen core | An interrupt source independent of the 1 ms tick (INTID 30): it makes preemption asynchronous and measurable. |

**The second interrupt.** The kernel's tick is the ARM generic timer
(CNTP, INTID 30). For the preemption lessons the course adds an independent
source: the BCM2711 System Timer (1 MHz free-running counter at
`0xFE003000`), compare channel C1 (C0 and C2 belong to the GPU firmware),
which raises GIC shared interrupt INTID 97, routable to any core. The Zig
port's dispatcher (`src/port.zig`) hands every interrupt it does not own to
the application's `uos_external_irq(iar)` when the test's root declares one,
so the course adds the source without touching the port. If QEMU's
`raspi4b` does not model it, the fallback is the per-core virtual generic
timer (CNTV, INTID 27). The dispatcher takes one interrupt per entry (no
nesting): "preemption" in this course is a thread preempted by a
higher-priority thread an interrupt has woken, and the latency from the
interrupt to that thread running is what is measured.

### 2.1 The shared base in detail

`test/tutor/common/tutor.zig` is one file. Zig does not let a test import a
file outside its own folder, so `build.zig` makes it a module named
`tutor` and gives it to every test marked `.tutor = true`; a lesson writes
`const tutor = @import("tutor");`. The module itself imports `uos` (the
kernel) and `board` (`test/board.zig`, the board bridge of every test).

#### The regions: `Region`, `inData()`, `inHeap()`, `inStackOf()`, `placed()`

```zig
pub const Region = enum(u8) { stack, data, heap };
```

Each sample records where its owner put it; the checks compare that claim
with the address:

| Function | True when the address is in | Bounds |
|---|---|---|
| `inData(p)` | the data segment | `__data_start` .. `__data_end` (symbols the linker script, `boards/rpi4b/linker.ld`, defines around `.data`) |
| `inHeap(p)` | the system heap | `uos.memory.systemHeap().arena`: the RAM after the image, from `port.freeRam()` (`src/port.zig`), up to `board.ram_end` |
| `inStackOf(p, th)` | the stack of thread `th` | `th.context.stack.bottom()` .. `th.context.stack.top()` (the kernel's record of that thread's stack) |

All three are the half-open test `lo <= p < hi` on the addresses as
integers (`inRange()`). `placed(s, owner)` combines them: true when the
sample's seal is intact *and* its address lies in the region it claims — a
stack sample in the stack of `owner`, the thread that made it.
`regionName()` gives `"stack"`, `".data"` or `"heap"`.

The three ranges are disjoint: `.data` is part of the image; the heap is
the RAM after the whole image (`_end`, after `.bss` and the per-core
stacks); a thread's stack is either a static array (in `.bss`) or, when the
kernel allocates it, in the heap — which is why a lesson that checks stack
samples checks them against the thread itself with `inStackOf()`.

#### The node: `Sample`

```zig
pub const Sample = struct {
    next: ?*Sample = null,     // the intrusive link
    id: u32 = 0xD47A,          // not zero: a static array of samples is in .data
    value: i32 = 0,
    where: Region = .data,
    seal_word: u64 = 0,
    pub fn init(s: *Sample, id: u32, value: i32, where: Region) void;
    pub fn seal(s: *Sample) void;
    pub fn valid(s: *const Sample) bool;
};
```

- `next` makes the list intrusive: no memory is allocated to link a sample.
- The non-zero default `id` matters for storage: `var g_data: [8]Sample =
  @splat(.{});` has non-zero initial bytes, so the compiler puts it in
  `.data` (its bytes are in the image), not `.bss` (zeroed at start-up).
- `init()` sets every field (`next` null) and seals.
- `seal()` stores a 64-bit FNV-1a hash of `id`, `value` and `where`;
  `valid()` recomputes and compares. A sample changed without `seal()` — a
  stray write, a use after free, a race — no longer validates.

#### The list: `IntrusiveList(T)`

A generic function returning a type, for any struct with a `next: ?*T`
field (checked at compile time, with a clear `@compileError` otherwise). It
owns nothing and never allocates:

| Member | What it does | Cost |
|---|---|---|
| `head` | the first node, or `null` | |
| `push(node)` | prepends | O(1) |
| `unlink(node)` | walks the list through `*?*T` links (a pointer to the link that points at the current node), so the head and an inner node are unlinked the same way; clears the node's `next`; false when it is not in the list | O(n) |
| `count()` | the number of nodes | O(n) |

`SampleList` is `IntrusiveList(Sample)`. The list has no lock: a lesson
that shares it between threads guards every access with one `rtos.Mutex`,
and a node must be unlinked before its storage goes away.

#### The work: `generate()`, `sortList()`, `maxOf()`, `checksum()`

The same arithmetic as the C++ base, bit for bit (wrapping operators `*%`,
`+%` where C++ relies on unsigned overflow):

- `generate(seed, i)`: the seed mixed with `i *% 0x9E3779B9`, three steps
  of `x = x *% 1664525 +% 1013904223`, then `@rem(x >> 16, 10000)`:
  `0 .. 9999`, deterministic.
- `sortList(&list)`: an insertion sort on the links — nodes taken off one by
  one and inserted at their place in a second, sorted chain; by `value`,
  then by `id` (`before()`), so the order is unique and the sort stable. No
  copy, no allocation.
- `maxOf(list)`: the first node with a strictly larger value; on the sorted
  list, the first of equal maxima (the lowest id).
- `checksum(list)`: an order-sensitive 32-bit FNV-1a over `(id, value)`
  along the list (`mix()`).

#### The reference: `reference()` and `Expected`

The expected results computed independently: `n` samples sorted as
`(value, id)` pairs in two plain static arrays (an array insertion sort, no
list code), then the same `mix()` along that order, and the first strictly
larger value as the maximum. A lesson compares the list's `checksum()` and
`maxOf()` with it.

#### The console and the verdict: `check()`, `failures()`, `finish()`, `heapBytes()`

- The console is `board.console(fmt, args)` (`test/board.zig`): it formats
  into a 256-byte buffer and writes the line under one mutex, so lines from
  several threads or cores never mix. The port's trace (`src/port.zig`)
  writes every line to the UART and copies a line holding `RESULT`, `FAIL`
  or `FATAL` to semihosting — the one line the runner reads. A failed check
  prints `[BAD]` (not mirrored: a semihosting call from cores 1–3 stops that
  core on this board).
- `check(cond, fmt, args)` prints `  [ok] what` or `  [BAD] what` and counts
  a failure (an atomic add, so any thread on any core may call it).
- `finish(summary)` prints `RESULT: PASS (summary)` and calls
  `board.hw_result.ok()`, or `RESULT: FAIL (N failed checks)` and
  `board.hw_result.fail()` (the kernel's `rtos.terminate()`: a semihosting
  exit, which ends the runner's OpenOCD or QEMU).
- `heapBytes()` is `uos.memory.statistics().allocated_bytes`: read before
  and after, every allocation must be returned.
- `printBanner(lesson)` prints the lesson's banner with the CPU count of the
  build (`uos.config.ncpu`); `printRegions()` the three ranges, the stack
  one of the calling thread.

#### The start-up

A Zig test's start-up is the port's (`test/start.zig`, `boards/rpi4b/startup.S`,
`src/port.zig`): reset, the MMU, `.bss` cleared, then the test's
`main()`, which every lesson writes the same way:

```zig
pub const uos_options = board.options(1); // or 4
pub fn main() void {
    board.uart.init();
    uos.rtos.run(osMain);
}
```

`uos_options` is the kernel's configuration, read at compile time: with
`board.options(1)` the kernel is built for one CPU (`ncpu` 1, `smp` false,
the non-SMP scheduler); with `board.options(4)` for four, with the SMP
scheduler. `uos.rtos.run(osMain)` creates the main thread and the idle
threads (one per core) and starts the scheduler, which runs `osMain()` in
the main thread. With four CPUs the lesson itself releases cores 1–3
(`board.smp.startSecondaryCores()`, `board.smp.waitSecondaries()`).

## 3. The lessons: each in two versions, one CPU and four CPUs

Every lesson is written twice, from the same base and the same algorithm:

- **`1cpu`** — `board.options(1)`: the kernel built for one CPU, the
  non-SMP scheduler; cores 1–3 never started.
- **`4cpu`** — `board.options(4)`: the SMP scheduler; cores 1–3 released by
  the test, the work spread over the cores, and what SMP adds or changes
  for that concept.

The two versions of a lesson print the same results, so each lesson also
checks that SMP changes nothing but the timing. Each lesson folder holds
`README.md` and its PDF, `1cpu/main.zig`, `4cpu/main.zig` and `RESULTS.md`
(both versions' board and QEMU runs). Every run ends within 3 minutes. Every
lesson README has the same sections, in this order: **1. Theory** (the RTOS
concept on its own, before any code), **2. In µOS++** (the Zig kernel's
API for it), **3. The lesson** (the diff from the previous lesson, the code
walk-through, the files in the build), **4. The test**, **5. Running it**,
**6. Results**.

The lessons are those of the C++ course (the API names below are generic;
each lesson README names the Zig ones: `uos.rtos.Thread`, `rtos.Mutex`,
`rtos.Semaphore`, `rtos.ConditionVariable`, `rtos.EventFlags`,
`rtos.MessageQueueTyped`, `rtos.MemoryPoolTyped`, `rtos.Timer`,
`sysclock`, `hrclock`, `rtclock`):

| # | Lesson | New RTOS behaviour | `1cpu` | `4cpu` |
|---|---|---|---|---|
| 01 | `bring-up` | `osMain`, the main thread, the console | 3×8 samples (stack, `.data`, heap), one list, sort, max | the same on core 0, cores 1–3 started, their idle threads |
| 02 | `threads` | threads with static and heap stacks, `join()`, return values, `yield()` | 4 workers, round-robin at each yield | 4 workers pinned one per core |
| 03 | `priorities` | priorities, preemption; the second interrupt (C1) | the C1 interrupt wakes a high thread that preempts a busy low one; latency | C1 routed to core 1 |
| 04 | `clocks` | `sysclock.sleepFor/sleepUntil`, `rtclock`, `hrclock` | a 100 ms periodic sampler | a sampler per core |
| 05 | `mutex` | mutexes (normal, recursive), try/timed lock | 4 threads add to one shared list | real contention on 4 cores |
| 06 | `priority-inversion` | mutex protocols none, inherit, protect | low/medium/high around the list | the same, the medium one moved to another core |
| 07 | `semaphores` | binary and counting semaphores | producer → bounded buffer → consumer | across cores |
| 08 | `condvar` | condition variables, predicates, notify one/all | the lesson 07 pipeline | several consumers on several cores |
| 09 | `flags` | event flags, thread flags | phases started by flags | the phases on different cores |
| 10 | `message-queue` | typed queues, priorities, timed send/receive | a 3-stage pipeline | one stage per core |
| 11 | `memory` | memory pools, allocators, statistics | samples from a pool | the pool shared by 4 cores |
| 12 | `timers` | software timers, callbacks | sampling driven by a timer | callbacks feeding workers on other cores |
| 13 | `interrupts` | handlers, critical sections, interrupt-to-thread latency | C1 and the tick update a shared counter | C1 routed to each core in turn |
| 14 | `thread-control` | suspend/resume, interrupt, kill, states, stack usage | a worker paused, resumed, killed | the same on another core |
| 15 | `sd-card` | a logger thread owning the SD card | every line to the UART and the card | lines from all 4 cores through the one logger |
| 16 | `parallel` | splitting work, merging, measuring | the reference time on one core | per-core sort + merge, the speed-up |
| 17 | `balancing` | threads without affinity, migration | 8 workers time-sliced | 8 floating workers over 4 cores |
| 18 | `capstone` | everything, with the SD log | rounds of create/destroy | the same over 4 cores |

## 4. Where it lives and how it is built

```
micro-os-plus-iii-aarch64/test/tutor/
├── README.md            this file (and README.pdf)
├── common/tutor.zig     the shared base (section 2), the `tutor` module
├── 01-bring-up/
│   ├── README.md        the lesson (and README.pdf)
│   ├── 1cpu/main.zig    -> test tutor-01-bring-up-1cpu   (board.options(1))
│   ├── 4cpu/main.zig    -> test tutor-01-bring-up-4cpu   (board.options(4))
│   └── RESULTS.md       (and RESULTS.pdf)
│   ...
```

`build.zig` lists every test. A lesson's two versions are two entries:

```zig
.{ .name = "tutor-01-bring-up-1cpu", .dir = "tutor/01-bring-up/1cpu", .tutor = true },
.{ .name = "tutor-01-bring-up-4cpu", .dir = "tutor/01-bring-up/4cpu", .tutor = true },
```

`.dir` is the source folder under `test/` (when it is not the test's name);
`.tutor = true` gives the test the `tutor` module. The CPU count is not a
build option: each version's `uos_options = board.options(N)` sets it, so
the Zig port needed no change to build with one CPU (the C++ port did:
golden's step 0). The linker script defines `__data_start`/`__data_end`
around `.data` for the region checks.

## 5. Results

On the board the console is on the UART; only the verdict line reaches
semihosting. A lesson's `RESULTS.md` records the board's verdict and time
from the runner, and the full console from the QEMU run. Lessons are
written and run one at a time, in order, both versions; a lesson is only
started once the previous one passes on the board.
