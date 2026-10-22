# Lesson 04 (Zig) — Results

| Version | QEMU (`raspi4b`) | Board (Raspberry Pi 4 B, `test/run-all.sh`) |
|---|---|---|
| `tutor-04-clocks-1cpu` | PASS | PASS, 26 s |
| `tutor-04-clocks-4cpu` | PASS | PASS, 25 s (see the open point below) |

Run on 2026-10-22. The board's verdict lines:

```
RESULT: PASS (three clocks consistent, sort timed, sleep_until exact, sleep_for drifts; one CPU)
RESULT: PASS (three clocks consistent on cores 0 and 1, sort timed, sleep_until exact on cores 1-3, sleep_for drifts; four CPUs)
```

On the board the Zig images send only the verdict lines to semihosting;
the console is on the UART. From the UART (four CPUs):

```
  sleep_for(5000): sysclock +5000 ticks = 5000000 us, hrclock 4999999 us, System Timer 5000000 us
  core 0: monotonic sysclock yes, hrclock yes; hrclock.sleep_until(now + 100 ms) 100209 us; now - steady_now = 129 cycles
  core 1: monotonic sysclock yes, hrclock yes; hrclock.sleep_until(now + 100 ms) 100742 us; now - steady_now = 150 cycles
  absolute on core 1: wakes at +0, +100, ..., +1900 ticks; span 1900 ticks; jitter 1 us
  absolute on core 2: wakes at +0, +100, ..., +1900 ticks; span 1900 ticks; jitter 3 us
  absolute on core 3: wakes at +0, +100, ..., +1900 ticks; span 1900 ticks; jitter 2 us
  relative on core 0: wakes at +0, +102, ..., +1938 ticks; span 1938 ticks (drift 38 ticks)
```

**The port fix.** The lesson runs on the Zig port with the two clock fixes
it shares with the C++ port (see `README.md`, section 2): the tick
re-armed on an absolute grid and `hrclock` counted from core 0's tick
origin. The Zig QEMU tests all pass with them (the SD tests need the board).

## Open point: a hang of core 3 on the board

The four-CPU version hung on the board in 2 of its first 3 runs: the
console stopped at the start of part C. A diagnostic (a 10 s timed wait on
the samplers, then each thread's progress and state) caught it once:

```
FAIL: part C stuck at tick +12040: absolute periods 20 20 0 (cores 1 2 99), relative 20; loads 22851774 22856960 22856619 0
FAIL:   absolute 0: state terminated
FAIL:   absolute 1: state terminated
FAIL:   absolute 2: state ready
FAIL:   relative: state terminated; loads ready running running ready
```

Core 3 ran nothing in part C: its sampler and its load stayed ready, never
started, while cores 0–2 ran theirs to the end. Zig lesson 03 (a thread on
core 3) passed on the board with the same port. A second diagnostic, which
also dumped each core's tick count and scheduler state, ran 10 times on the
board and never hung — it adds a counter to every tick, so the timing
changed — and the cause is not found yet. The diagnostics are removed; the
lesson is the same as the C++ one. (The UART also showed bytes dropped in
groups of 10–20 in some Zig runs, passing ones too; not explained either —
possibly the Debug Probe's UART bridge, which shares its USB link with the
JTAG traffic.)

**Update (lesson 06):** the cause was found and fixed — a cache line shared
between core 3's stack and the heap, see `../06-priority-inversion/RESULTS.md`.

The full consoles below are the QEMU runs.

## One CPU (QEMU)

```
+== RPi 4 B µOS++ tutorial (Zig) : 04 clocks (1 CPU) ==+

Lesson 04, one CPU: the three clocks, timing with hrclock, periodic threads.
  .data   000981c8 .. 0009a878
  heap    0091d430 .. 3b400000
  stack   000a7210 .. 000b7208 (thread main)

-- part A: the clocks (sysclock 1000 Hz, hrclock 62500000 Hz, rtclock 1 Hz)
  sleep_for(5000): sysclock +5000 ticks = 5000000 us, hrclock 4999453 us, System Timer 4999477 us
  [ok] sleep_for(5000) slept 5000 ticks
  [ok] sysclock keeps the System Timer's time (within 20000 us in 5 s)
  [ok] hrclock keeps the System Timer's time (within 20000 us in 5 s)
  core 0: monotonic sysclock yes, hrclock yes; hrclock.sleep_until(now + 100 ms) 100879 us; now - steady_now = 8170 cycles
  [ok] sysclock and hrclock monotonic over 20000 reads (core 0)
  [ok] hrclock.sleep_until(now + 100 ms) lasted 100 ms (+1 tick) (core 0)
  [ok] hrclock.now() within two ticks of its steady count (core 0)
  rtclock: 6 s, then 8 s after sysclock.sleep_for(2500)
  [ok] rtclock advanced 2 s in 2.5 s from the start of a second

-- part B: the insertion sort timed with hrclock (the best of 5 runs)
   18 samples:      61 cycles =     0 us, checksum exact
   72 samples:     433 cycles =     6 us, checksum exact
  288 samples:    5009 cycles =    80 us, checksum exact
  [ok] the three sorts exact

-- part C: samplers every 100 ticks, 2000 us of work each, over a load at low
  absolute: wakes at +0, +100, ..., +1900 ticks; span 1900 ticks; jitter 55 us
  relative: wakes at +2, +104, ..., +1940 ticks; span 1938 ticks (drift 38 ticks)
  the load: 4869973 rounds in the gaps
  [ok] sleep_until: every wake exactly on its tick (start + 100 i)
  [ok] sleep_until: 20 wakes span exactly 1900 ticks
  [ok] sleep_until: every wake within 20000 us of the ideal period (55 us)
  [ok] sleep_for: the period grew by the work (span >= 19 x 101 ticks): it drifts
  [ok] the load ran in the gaps
  [ok] heap back to 0 B
RESULT: PASS (three clocks consistent, sort timed, sleep_until exact, sleep_for drifts; one CPU)
```

## Four CPUs (QEMU)

```
+== RPi 4 B µOS++ tutorial (Zig) : 04 clocks (4 CPU) ==+

Lesson 04, four CPUs: the three clocks, timing with hrclock, periodic threads.
  .data   00096e58 .. 00099858
  heap    009289d0 .. 3b400000
  stack   000b2530 .. 000c2520 (thread main)
core 0: releasing core 1...
core 0: releasing core 2...
core 0: releasing core 3...
  cores joined after 0 ms: c1=3 c2=3 c3=3
  [ok] cores 1-3 joined the scheduler

-- part A: the clocks (sysclock 1000 Hz, hrclock 62500000 Hz, rtclock 1 Hz)
  sleep_for(5000): sysclock +5000 ticks = 5000000 us, hrclock 4999655 us, System Timer 4999737 us
  [ok] sleep_for(5000) slept 5000 ticks
  [ok] sysclock keeps the System Timer's time (within 20000 us in 5 s)
  [ok] hrclock keeps the System Timer's time (within 20000 us in 5 s)
  core 0: monotonic sysclock yes, hrclock yes; hrclock.sleep_until(now + 100 ms) 101082 us; now - steady_now = 13166 cycles
  [ok] sysclock and hrclock monotonic over 20000 reads (core 0)
  [ok] hrclock.sleep_until(now + 100 ms) lasted 100 ms (+1 tick) (core 0)
  [ok] hrclock.now() within two ticks of its steady count (core 0)
  rtclock: 6 s, then 8 s after sysclock.sleep_for(2500)
  [ok] rtclock advanced 2 s in 2.5 s from the start of a second
  core 1: monotonic sysclock yes, hrclock yes; hrclock.sleep_until(now + 100 ms) 100754 us; now - steady_now = 8999 cycles
  [ok] sysclock and hrclock monotonic over 20000 reads (core 1)
  [ok] hrclock.sleep_until(now + 100 ms) lasted 100 ms (+1 tick) (core 1)
  [ok] hrclock.now() within two ticks of its steady count (core 1)

-- part B: the insertion sort timed with hrclock (the best of 5 runs)
   18 samples:     146 cycles =     2 us, checksum exact
   72 samples:    1030 cycles =    16 us, checksum exact
  288 samples:   12312 cycles =   196 us, checksum exact
  [ok] the three sorts exact

-- part C: samplers every 100 ticks, 2000 us of work each, over a load at low
  absolute on core 1: wakes at +0, +100, ..., +1900 ticks; span 1900 ticks; jitter 57 us
  absolute on core 2: wakes at +0, +100, ..., +1900 ticks; span 1900 ticks; jitter 59 us
  absolute on core 3: wakes at +0, +100, ..., +1900 ticks; span 1900 ticks; jitter 50 us
  relative on core 0: wakes at +0, +102, ..., +1938 ticks; span 1938 ticks (drift 38 ticks)
  the loads: 4660429, 4724130, 4345436, 4737826 rounds in the gaps (cores 0-3)
  [ok] the absolute samplers ran on cores 1, 2, 3
  [ok] sleep_until: every wake on every core exactly on its tick (start + 100 i): same ticks on all three
  [ok] sleep_until: every wake within 20000 us of the ideal period (worst 59 us)
  [ok] sleep_for: the period grew by the work (span >= 19 x 101 ticks): it drifts
  [ok] every core's load ran in the gaps
  [ok] heap back to 0 B
RESULT: PASS (three clocks consistent on cores 0 and 1, sort timed, sleep_until exact on cores 1-3, sleep_for drifts; four CPUs)
```
