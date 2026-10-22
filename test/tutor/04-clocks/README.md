# Lesson 04 (Zig) — Clocks: sysclock, hrclock, rtclock, and periodic threads

## 1. Theory

### Time in an RTOS

An RTOS keeps time with a periodic interrupt, the **tick**: a hardware
timer interrupts every *T* (here 1 ms) and the kernel adds one to a counter.
Every timed service is expressed in ticks: "sleep for 100 ms" is "make me
ready again 100 ticks from now", "wait at most 5 ms for this semaphore" is a
timeout of 5 ticks. The tick is the kernel's unit of time: nothing that the
kernel schedules can be finer than it.

Two other clocks complete the picture:

- a **high-resolution clock**, the hardware counter behind the tick read
  directly — here the ARM generic timer, 54 MHz on the Pi 4: about 18 ns per
  count, fine enough to *measure* code that lasts microseconds;
- a **real-time clock**, in seconds, for the time of day (here simulated
  from the tick: one second every 1000 ticks).

### What a clock must guarantee

- **Monotonic**: it never goes back. A timestamp taken later is never
  smaller.
- **The right rate**: one second of the clock is one second of real time. A
  tick that loses a little time at every interrupt loses it for ever: a
  timer re-armed "one period from now" inside its interrupt handler adds the
  handler's entry latency to every period, and the clock runs slow. The
  timer must be re-armed on an **absolute** grid: "the next compare is one
  period after the last one", whatever the handler's latency.
- **One origin**: a clock's "now" and the timestamps its sleeps are measured
  against must count from the same zero, or "sleep until now + 100 ms" sleeps
  for some other time.

### Sleeping: relative and absolute

A thread that must run every 100 ms can write either

```
for (;;) { work (); sleep_for (100); }        // relative
for (next = now (); ; ) { sleep_until (next += 100); work (); }   // absolute
```

The relative loop's period is *work + 100*: it drifts by the work's length
(and by every delay before the sleep) at every period, and the error grows
without bound. The absolute loop's period is exactly 100 on average: each
wake is computed from the previous **deadline**, not from the time the
thread got round to sleeping; a late wake is not passed on to the next
one. A periodic task — a control loop, a sampler — is always written the
absolute way.

The cost of the tick is its **resolution**: a sleep ends on a tick, so
"sleep for *n*" lasts between *n−1* and *n* tick periods from the call (the
call can come anywhere inside a tick period); "sleep until the tick *t*"
ends exactly on that tick.

### Measuring with the high-resolution clock

To time a piece of code: read the counter before and after, subtract, and
divide by the counter's frequency. The first run of a piece of code is
usually slower (cold caches, branch predictors); a measurement takes the
best of several runs. Under an emulator the counter follows the host's
clock, and short intervals mean little.

### Several CPUs

The kernel has **one** time: core 0's tick advances the clocks; the other
cores' ticks only make them reschedule. A thread on core 2 that sleeps until
tick *t* is woken by core 0's tick interrupt, which makes it ready and sends
core 2 an inter-processor interrupt. So the wake on another core is as
exact, in ticks, as on core 0, with a few microseconds more of latency.
Every core reads the same counters: the generic timer's count is common to
all cores.

## 2. In µOS++ (Zig)

- `uos.rtos.sysclock`: ticks, `rtos.Clock.frequency_hz` = 1000; `now()`,
  `sleepFor(ticks)`, `sleepUntil(timestamp)`.
- `uos.rtos.hrclock`: cycles of the generic timer,
  `inputClockFrequencyHz()`; `now()` reads the hardware counter
  (`port.clock_highres.hardwareCounter()`), `steadyNow()` the count the
  kernel advances by `cyclesPerTick()` at every tick; its sleeps are
  measured against the latter.
- `uos.rtos.rtclock`: seconds, advanced every 1000 ticks
  (`micro-os-plus-iii/src/rtos/clocks.zig`, `sysTickHandler()`).
- `rtos.Timestamp` (`u64`), `rtos.Duration` (`u32`).
- The tick: `port_isr_handler()` in `src/port.zig` calls
  `uos.rtos.clocks.sysTickHandler()` on core 0 only, and re-arms the timer
  with `rearmTick()`.

### The port fix this lesson brought

The C++ lesson found four faults (see the golden workspace's
`test/rpi4b/tutor/04-clocks/README.md`); two of them were in the Zig port
too, and are fixed in `src/port.zig` and `src/arch.zig`:

1. **The tick lost time.** The interrupt re-armed the timer one period from
   *now* (`setCntpTval`), adding its own latency to every tick. Now
   `rearmTick()` moves the compare one period after the last
   (`setCntpCval(cntpCval() + period)`); a late tick is caught up at once.
2. **`hrclock` had two origins.** `hardwareCounter()` was the raw counter
   (since power-on), while the sleeps are measured against the tick-driven
   count (since the tick started). Now it counts from core 0's tick origin
   (`tick_base`), and at tick *k* both read *k* · `cyclesPerTick()`.

The other two were C++-only: the Zig port takes the frequency from CNTFRQ
(no per-core calibration), and the Zig kernel's `resume()` sends its
cross-core IPI (`config.options.resume_ipi`, on by default).

## 3. The lesson

The unit of work and the samples are the base's; the new subject is time.

**`1cpu/main.zig`.**

- *Part A, the three clocks.* 20000 reads in a row of `sysclock` and
  `hrclock`: neither goes back. A `sysclock.sleepFor(5000)` measured with
  all three counters — `sysclock`, `hrclock` and the BCM2711 System Timer,
  an independent 1 MHz counter (`second_timer.nowUs()`): 5000 ticks, and
  both kernel clocks within 200 µs of the System Timer. `hrclock.sleepUntil(now() + 100 ms)` lasts 100 ms (plus at most one tick), and `now() − steadyNow()` is less than two ticks. From the start of a second
  (`rtclock.sleepFor(1)`), 2500 ticks later `rtclock` has advanced by
  exactly 2.
- *Part B, timing with `hrclock`.* The insertion sort of 18, 72 and 288
  samples (in the data segment, `g_sort[]`), each the best of 5 runs, in
  cycles and µs; every result exact, and the time growing with the size
  (about ×16 for ×4 the samples: the sort is quadratic).
- *Part C, periodic threads.* Two samplers, each doing 2 ms of work per
  period, 20 periods of 100 ticks, both starting on the same tick, over a
  `load` thread at `low` that never blocks: `absolute` (`high`) sleeps until
  `next += 100`, `relative` (`above_normal`) sleeps for 100 after its work.
  The checks: every absolute wake exactly on `start + 100·i`, its 20 wakes
  spanning exactly 1900 ticks, each within 200 µs of an ideal 100 ms grid
  measured with the System Timer; the relative one spanning at least 19 ×
  101 ticks (it drifts, by about the work's 2 ticks every period); the load ran in the gaps. As in lesson 03, main
  waits on a `done` semaphore and stops the load before joining.

**`4cpu/main.zig`** first releases cores 1–3. Part A then also measures
from a thread pinned to core 1 (monotonic there, and `hrclock`'s sleep as
exact); the main thread prints and checks what it measured, since on the
board only core 0's console lines reach the semihosting log.
Part B is unchanged. In part C there are three absolute samplers, pinned to
cores 1, 2 and 3, all on the same grid, the relative one on core 0, and a
load on every core: core 0's tick must wake threads on the three other
cores, and every absolute wake on every core must land on exactly its tick.

Under QEMU (`tutor.onHardware()` false) the time bounds are 20 ms instead of 200 µs
and the "time grows with the size" check of part B is skipped: QEMU's
counter follows the host's clock and cannot resolve a sort of a few
microseconds.

### Files in the build

The same files as lesson 01 (see `../01-bring-up/README.md`, *Files in the
build*), with this lesson's own source in place of lesson 01's:

- `micro-os-plus-iii-aarch64/test/tutor/04-clocks/1cpu/main.zig` (or `4cpu/main.zig`)
- `micro-os-plus-iii-aarch64/test/tutor/common/tutor.zig` (`second_timer.nowUs()`, `onHardware()`)
- the port (`micro-os-plus-iii-aarch64/src/port.zig` — `sysInit()`, the tick, `rearmTick()`, `clock_highres`; `src/arch.zig` — the CNTP registers), the board (`micro-os-plus-iii-aarch64/boards/rpi4b/startup.S`, `board.zig`, `linker.ld`) and the kernel (`micro-os-plus-iii/src/rtos/clocks.zig` — the three clocks and the tick handler, and the rest of `micro-os-plus-iii/src/`)
- `micro-os-plus-iii-aarch64/build.zig` — the entries `tutor-04-clocks-1cpu` and `-4cpu`

## 4. The test

PASS when, in both versions:

- `sysclock` and `hrclock` are monotonic (on core 0; with four CPUs on core
  1 too);
- `sleep_for (5000)` slept 5000 ticks, and `sysclock` and `hrclock` kept the
  System Timer's time within 200 µs (QEMU 20 ms);
- `hrclock.sleep_until (now () + 100 ms)` lasted 100 ms (+1 tick), and
  `hrclock.now ()` is within two ticks of its steady count;
- `rtclock` advanced 2 s in 2.5 s from the start of a second;
- the three sorts are exact (and, on the board, their time grows with the
  size);
- every absolute sampler (one; with four CPUs three, on cores 1–3) woke
  exactly on its ticks (under QEMU at most one tick late), spanning 1900
  ticks, within 200 µs (QEMU 20 ms) of the ideal grid; the relative one
  drifted by at least a tick per period; the load ran;
- the heap is back to its level.

## 5. Running it

As lesson 01 (see `../01-bring-up/README.md`, *Running it*); from
`micro-os-plus-iii-aarch64`:

```sh
cd micro-os-plus-iii-aarch64
export PATH=$HOME/zig-x86_64-linux-0.17.0:$PATH
zig build -Dtest=tutor-04-clocks-1cpu
zig build -Dtest=tutor-04-clocks-4cpu
zig build -Dtest=tutor-04-clocks-1cpu run    # QEMU
zig build -Dtest=tutor-04-clocks-4cpu run
test/run-all.sh tutor-04-clocks-1cpu          # the board
test/run-all.sh tutor-04-clocks-4cpu
```

## 6. Results

Both versions PASS under QEMU and on the board (2026-10-22): 26 s and 25 s
on the board, with the clocks to the microsecond (5000 ticks = 5 000 000 µs
of the System Timer, `hrclock` 4 999 999 µs) and the absolute samplers'
jitter 1–3 µs on cores 1–3. One open point: the four-CPU version hung on
the board in 2 of its first 3 runs, with core 3 running nothing in part C;
the 10 runs after it passed. See [`RESULTS.md`](RESULTS.md).
