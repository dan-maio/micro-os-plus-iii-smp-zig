# Lesson 13 (Zig) — Software timers: one-shot, periodic, callbacks

## 1. Theory

### Time as an event

So far threads have waited *for* time (`sleep_for`, `timed_wait`). A
**software timer** turns time into an event: after a delay, it **calls a
function** — the callback — once (**one-shot**) or every period
(**periodic**). Hundreds of timers can share the one hardware tick: the
kernel keeps them in a list ordered by expiry and checks the head at every
tick.

### Exact, not drifting

A periodic timer re-arms itself from its *previous expiry*, not from the
moment its callback ran: the *n*-th call is due at `start + n · period`,
exactly. A loop that sleeps for one period after doing its work drifts — it
adds its own run time every turn (lesson 04 measured that drift); a periodic
timer does not.

### Where the callback runs

In µOS++ the callback runs **in the tick interrupt**, on the core that
processes the clock (core 0). That fixes its rules:

- it must be **short** — every other interrupt of that core waits;
- it must **never block**: no `mutex::lock`, no `sleep`, no `wait`; only the
  calls allowed in an ISR — `semaphore::post`, `message_queue::try_send`,
  `event_flags::raise`, a thread's `flags_raise`.

So a timer does not do the work; it *starts* it: the callback hands a token
— a sample id, an event — to a thread, which does the heavy part at its own
priority.

### One-shot, stop, restart

A one-shot calls back once and is then finished. A running timer can be
**stopped** before it expires (then it never calls back), and restarted,
with the same or another period.

### Several CPUs

The callbacks run on core 0, but the threads they feed can run anywhere:
three workers on cores 1, 2 and 3 waiting on one queue share the work,
each token crossing a core.

## 2. In µOS++ (Zig)

- `rtos.Timer.init("name", function, arg, .once)` (or `.periodic`) —
  `t.start(ticks)`, `t.stop()` (`error.Again` when the timer is not
  running), `t.getState()`. `start` and `stop` may not be called from an
  ISR (`error.NotPermitted`). The lesson prints the C++ names.
- The callback: `fn (arg: ?*anyopaque) void`, called from the tick
  interrupt (`rtos.interrupts.inHandlerMode()` is true inside).
- `micro-os-plus-iii/src/rtos/timer.zig` (the re-arm from the previous
  timestamp, then the call), `micro-os-plus-iii/src/rtos/clocks.zig`.

## 3. The lesson

**`1cpu/main.zig`.**

- *Part A, sampling driven by a periodic timer.* A periodic timer of 5
  ticks; its callback records `sysclock.now()` and the System Timer's
  microseconds, notes whether it runs in handler mode, and `trySend`s the
  next sample id (0 … 39), as a `usize`, to an `rtos.MessageQueue` of 8. A `worker`
  (`normal`) receives the ids and builds the samples. The main thread waits
  for 40 calls, stops the timer, and sends each worker a stop id.
- *Part C, the cost* (from the same run): every period's length in
  microseconds, against 5000.
- *Part B, one-shot, stop, restart.* A one-shot of 10 ticks, then
  `stop ()`; the same one-shot started again and stopped after 3 ticks; a
  periodic timer of 4 ticks for 14 ticks, stopped, restarted with 7 for 22.

**`4cpu/main.zig`** first releases cores 1–3, then runs three workers, on
cores 1, 2 and 3, on the same queue; the callbacks stay on core 0.

### Files in the build

The same files as lesson 01 (see `../01-bring-up/README.md`, *Files in the
build*), with this lesson's own source in place of lesson 01's:

- `micro-os-plus-iii-aarch64/test/tutor/13-timers/1cpu/main.zig` (or `4cpu/main.zig`)
- `micro-os-plus-iii-aarch64/test/tutor/common/tutor.zig` (`second_timer.nowUs()`)
- the port (`micro-os-plus-iii-aarch64/src/port.zig`), the board (`micro-os-plus-iii-aarch64/boards/rpi4b/startup.S`, `board.zig`, `linker.ld`) and the kernel (`micro-os-plus-iii/src/rtos/timer.zig`, `clocks.zig`, `mqueue.zig`, and the rest of `micro-os-plus-iii/src/`)
- `micro-os-plus-iii-aarch64/build.zig` — the entries `tutor-13-timers-1cpu` and `-4cpu`

## 4. The test

PASS when, in both versions:

- 40 callbacks, each exactly 5 ticks after the last, 200 ticks in all from
  the start; every one in handler mode, none of its sends refused; every
  sample built once, the sorted checksum equal to `reference(seed, 0, 40)`;
  (4 CPUs) the callbacks on core 0, the workers on cores 1, 2 and 3, each
  with a share;
- every period within 100 µs of 5 ms on the board (20 ms under QEMU);
- the one-shot called back once, 10 ticks after its start, and `stop ()`
  then returned `EAGAIN`; stopped after 3 ticks it returned `ok` and never
  called back; the periodic timer called back 3 times in 14 ticks at 4, and
  3 times in 22 at 7;
- the heap is back to its level; (4 CPUs) cores 1–3 joined.

## 5. Running it

As lesson 01 (see `../01-bring-up/README.md`, *Running it*); from
`micro-os-plus-iii-aarch64`:

```sh
cd micro-os-plus-iii-aarch64
export PATH=$HOME/zig-x86_64-linux-0.17.0:$PATH
zig build -Dtest=tutor-13-timers-1cpu
zig build -Dtest=tutor-13-timers-4cpu
zig build -Dtest=tutor-13-timers-1cpu run    # QEMU
zig build -Dtest=tutor-13-timers-4cpu run
test/run-all.sh tutor-13-timers-1cpu          # the board
test/run-all.sh tutor-13-timers-4cpu
```

## 6. Results

Both versions PASS under QEMU and on the board (2026-10-23): 14 s and 14 s
on the board. Under QEMU the numbers are the C++ lesson's: 40 callbacks in
200 ticks, the one-shot at +10, the 40 samples split 14 / 13 / 13 over cores
1–3. See [`RESULTS.md`](RESULTS.md).
