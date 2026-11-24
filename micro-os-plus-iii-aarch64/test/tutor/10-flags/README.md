# Lesson 10 (Zig) — Flags: event flags and thread flags

## 1. Theory

### A word of bits to wait on

A semaphore counts, a condition variable waits for a predicate; **flags**
are the simplest signal of all: a word of bits, each meaning "this has
happened". One side **raises** bits, the other **waits** for them:

- for **all** of a set of bits (`a` *and* `b` *and* `c`): a join — "start when
  every input is ready";
- or for **any** of them (`a` *or* `b`): "start when something is ready, and
  look at which".

A wait can **clear** the bits it was waiting for as it returns (*auto-clear*):
then each raise is consumed by exactly one wait, like a binary semaphore per
bit. Without the clear the bits stay set — a *state* that every later wait
sees at once — until someone clears them explicitly.

Raising is non-blocking and never fails for lack of room, so an interrupt
handler can raise flags. A bit raised twice before anyone waits is still one
bit: flags remember *that* something happened, not how many times (count with
a semaphore when that matters).

### Two kinds

- **Event flags** are an object of their own: any number of threads may raise
  them, and any number may wait on them. One raise wakes **every** waiter; each
  re-checks its own condition. With auto-clear the first one to run takes the
  bits and the others find them gone and wait again; without it they all
  return.
- **Thread flags** belong to one thread: anyone may raise them, only that
  thread waits on them. They need no shared object — the thread to start is
  the address — which makes them the lightest way to say "your input is
  ready" to one known thread.

### Phases

A computation in phases — produce, then sort, then reduce — is a chain of
dependencies: a phase may start only when all its inputs exist. Flags express
exactly that. Each producer raises its own bit when done; the next phase
waits for *all* the bits; when it is done it raises the flag of the phase
after it. Nothing polls, and the order holds whatever the priorities and
whichever cores the phases run on.

### Several CPUs

The phases can run on different cores: the producers in parallel, the next
phase on another core, woken by the last bit raised — the raise sends the
cross-core wake-up (lesson 04). The flags make the dependencies explicit, so
running them in parallel does not change the result.

## 2. In µOS++ (Zig)

- `rtos.EventFlags`: `var ef: rtos.EventFlags = .{ .name = "name" };` —
  `ef.raise(mask)` (also from an ISR), `ef.wait(mask, mode)` (returns the
  flags), `ef.tryWait(…)` (`error.WouldBlock`), `ef.timedWait(mask, ticks,
  mode)` (`error.TimedOut`), `ef.get(mask, mode)`, `ef.clear(mask)`.
- Modes: `rtos.flags.Mode`, a packed struct — `.{ .all = true }`,
  `.{ .any = true }`, `.clear`; `Mode.all_clear`, `Mode.any_clear`. The lesson
  prints the C++ names (`EWOULDBLOCK`, `ETIMEDOUT`).
- Thread flags: `th.flagsRaise(mask)` (also from an ISR);
  `rtos.this_thread.flagsWait(mask, mode)`, `flagsTryWait`, `flagsTimedWait`,
  `flagsGet`.
- `micro-os-plus-iii/src/rtos/evflags.zig`, `flags.zig` (the shared mask
  logic), `thread.zig` (thread flags); `raise()` wakes the waiters with
  `WaitingThreadsList.resumeAll()` (`lists.zig`).

## 3. The lesson

**`1cpu/main.zig`.**

- *Part A, phases started by flags.* Four `generate` threads (`normal`)
  each build 18 samples (ids `18·w` … `18·w + 17`, `g_data[]` in the data
  segment) on their own list and raise bit `w` of `g_phases`. `sort`
  (`above_normal`) waits for all four bits (`all | clear`), moves the four
  lists into one and sorts it, then raises thread flag 1 of `max`; `max`
  (`high`) waits on its flag and computes the maximum and the checksum. `max`
  and `sort` are created first and run above the generators, so only the
  flags hold them back. Every phase takes a number from a shared counter when
  it starts and ends, which gives the order.
- *Part B, the semantics.* On one event flags object: `0x1` raised;
  `try_wait (0x3, all)` and `try_wait (0x3, any)`; `get` without clearing;
  `try_wait (0x1, any | clear)`; `timed_wait (0x4, 10)`. Then two waiters
  (`above_normal`) for bit `0x8` and one raise: once with `all | clear`, once
  with `all` only (on a second object), counting how many took the bit and
  what is left. Finally the main thread's own `flags_try_wait (1)`.
- *Part C, from an interrupt.* The second timer (`tutor.second_timer`,
  lesson 03) raises thread flag 1 of a `high` waiter 20 times, every 2 ms; the
  waiter takes each and measures it from its interrupt.

**`4cpu/main.zig`** first releases cores 1–3, then runs the generators on
cores 1, 2, 3 and 0, `sort` on core 2 and `max` on core 3; the two waiters of
part B on cores 1 and 2; the ISR on core 0 and its waiter on core 2.

### Files in the build

The same files as lesson 01 (see `../01-bring-up/README.md`, *Files in the
build*), with this lesson's own source in place of lesson 01's:

- `micro-os-plus-iii-aarch64/test/tutor/10-flags/1cpu/main.zig` (or `4cpu/main.zig`)
- `micro-os-plus-iii-aarch64/test/tutor/common/tutor.zig` (`second_timer`, `onHardware()`)
- `micro-os-plus-iii-aarch64/test/start.zig` (the `uos_external_irq` forwarder, for part C)
- the port (`micro-os-plus-iii-aarch64/src/port.zig`), the board (`micro-os-plus-iii-aarch64/boards/rpi4b/startup.S`, `board.zig`, `linker.ld`) and the kernel (`micro-os-plus-iii/src/rtos/evflags.zig`, `flags.zig`, `thread.zig`, `lists.zig`, and the rest of `micro-os-plus-iii/src/`)
- `micro-os-plus-iii-aarch64/build.zig` — the entries `tutor-10-flags-1cpu` and `-4cpu`

## 4. The test

PASS when, in both versions:

- `sort` started after all four generators had raised their bit, and got
  `0xf`; `max` started after `sort` had ended and raised its flag; the 72
  sorted samples' checksum and maximum equal `reference(seed, 0, 72)`;
  (4 CPUs) each phase ran on its core;
- with `0x1` raised, `try_wait (0x3, all)` returned `EWOULDBLOCK` and
  `try_wait (0x3, any)` returned `0x1`; without clear the bit stayed, with
  clear it was taken; `timed_wait (0x4, 10)` returned `ETIMEDOUT` after 10
  ticks;
- two waiters and one raise: with `clear` one took the bit (the other after
  a second raise) and nothing was left; without `clear` both took it and the
  bit stayed set; the main thread did not see a flag raised for another
  thread;
- every one of the 20 flags raised by the ISR was taken, each within 1 ms on
  the board (20 ms under QEMU); (4 CPUs) the ISR on core 0, the waiter on
  core 2;
- the heap is back to its level; (4 CPUs) cores 1–3 joined.

## 5. Running it

As lesson 01 (see `../01-bring-up/README.md`, *Running it*); from
`micro-os-plus-iii-aarch64`:

```sh
cd micro-os-plus-iii-aarch64
export PATH=$HOME/zig-x86_64-linux-0.17.0:$PATH
zig build -Dtest=tutor-10-flags-1cpu
zig build -Dtest=tutor-10-flags-4cpu
zig build -Dtest=tutor-10-flags-1cpu run    # QEMU
zig build -Dtest=tutor-10-flags-4cpu run
test/run-all.sh tutor-10-flags-1cpu          # the board
test/run-all.sh tutor-10-flags-4cpu
```

## 6. Results

Both versions PASS under QEMU and on the board (2026-10-23): 15 s and 14 s
on the board. Under QEMU the numbers are the C++ lesson's: `sort` at event 5
after the fourth bit, one taker with `clear` and two without, every ISR flag
taken. See [`RESULTS.md`](RESULTS.md).

### What this lesson found in the kernel

The first run hung in part B, at the first raise for two waiters with
`all | clear`: `raise ()` never returned. It wakes the waiters with
`waiting_threads_list::resume_all ()` (Zig: `WaitingThreadsList.resumeAll()`), which was `while (resume_one ())`.
The first waiter, above the raiser, ran at once and took the bit; the second
was woken, found the bit gone, and — correctly — linked itself into the same
list again to wait; `resume_all ()` found the list not empty and woke it
again, for ever. Any two waiters on one event that clear it, running above
the thread that raises it, were enough.

`resume_all ()` now moves the waiters of the moment to a local list, under
the interrupt lock, and wakes only those: a thread that waits again goes back
to the real list, which this call no longer looks at. The same fix is in the
Zig kernel (`WaitingThreadsList.resumeAll`). It also serves the other users
of `resume_all ()`: a condition variable's `broadcast ()`, and the reset
paths (a semaphore's or a mutex's re-initialisation, a memory pool's or a
message queue's `reset ()`).
