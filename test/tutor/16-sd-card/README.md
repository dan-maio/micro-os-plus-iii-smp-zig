# Lesson 16 (Zig) — The SD card: one owner, a queue to it, the log read back

## 1. Theory

### A device has one owner

The SD card is a state machine: a command, its response, the data blocks, a
wait while the card programs them. Two threads that drive it at once mix
their commands, and the card answers neither. The FAT file system above it
is the same: FatFs keeps one window of the FAT and of the directory in
memory, and it is built here without its own locking (`FF_FS_REENTRANT 0`).
The rule is therefore the one of lesson 11's pipeline: **one thread owns the
card**, and the others **send it requests through a message queue**. The
owner here is a *logger*: every other thread hands it lines; it prints them
on the UART (which it owns too) and writes them to a file on the card.

The queue gives the order: one producer's lines are taken in the order it
sent them; lines of several producers are mixed as they arrive, but a line
is never cut by another.

### What the producer waits for

`say()` copies the line into the queue and returns: it does not wait for
the UART or the card, as long as there is a free slot. Who runs next
depends on the priorities:

- the logger **above** the producer runs as soon as a line is in the queue:
  it prints it, and only then does the producer go on. On one CPU the
  producer pays for every line's UART time;
- the logger **below** the producer runs only when the producer waits. A
  burst then goes into the queue at full speed, until the queue is full.
  From then on every line waits for a slot, and a slot is freed only when
  the logger has printed a line: **the producer goes at the logger's pace**.

A queue absorbs bursts; it does not make a slow consumer fast. Its depth is
the burst it can take without making the producer wait.

### Buffering, and when the lines reach the card

The card is written in 512-byte sectors, and appending to a file costs a
FAT and directory update besides: milliseconds, whatever the size. So the
logger gathers the lines in a 4 KiB buffer and appends the buffer to the
file:

- when the buffer is **full**;
- after half a second **without a line** (a `timed_receive` timeout), so that
  a quiet program's last lines do not wait in memory;
- on **request**: `sync()` sends a request through the same queue — so it is
  served after every line sent before it — and waits on a semaphore until
  the logger has written the buffer out.

Each append opens the file, writes, and closes it: once it returns, the
lines are on the card, the FAT and the directory updated. A line still in
the queue or in the buffer is lost if the board stops.

### The read-back

A log is only useful if what is on the card is what was written. The
logger keeps a running CRC-32 of every byte it appended; at the end the
file is read back and its size, CRC-32 and newline count compared with
those written.

## 2. In µOS++ (Zig)

- `rtos.MessageQueueTyped(T).Static(n)` — the queue with its storage
  inside (`init(name, .{})`, then `.typed`): `trySend(m, 0)`
  (`error.WouldBlock` when full), `send(m, 0)` (waits for a slot),
  `timedReceive(ms)` (`error.TimedOut`).
- `rtos.Semaphore.binary(name, 0)` — the logger's acknowledgement of a
  `sync`.
- `th.setPriority(p)` — the logger's priority changed at run time.
- The course's SD log, `test/tutor/common/sdlog.zig` (the module `sdlog`,
  shared with lesson 19): `sdlog.start(leaf, priority, core)`,
  `say(fmt, args)` (true when it had to wait), `sync()`, `stop()`,
  `verify()` (`.ok`, `.on_card`, `.lines_on_card`), `stats()` (messages,
  newlines, bytes, write-outs by cause, the longest append), `logger()`,
  `setObserver(fn)` (sees every line before it is printed). While it runs,
  `tutor.check()` prints through it (`tutor.output`).
- The card: `micro-os-plus-iii-aarch64/drivers/sd.zig` (EMMC2,
  `sd.SdCard`), `drivers/fatfs.zig` (`mountVolume`, `ensureTestsDir`,
  `appendFile`, `fileSize`, `loadFile`) over FatFs R0.15a (the C `ff.c`,
  unchanged), 8.3 names, on the card's existing FAT32 partition — never
  formatted; every file under `tests/`. The image is the same for QEMU and
  the board: the card is used only when `tutor.onHardware()`.

## 3. The lesson

**`1cpu/main.zig`.** The card is brought up (init, mount, `tests/`, the old
`tests/tutor16.log` removed), then the logger is started at `above_normal`.
From then on every line of the lesson goes through it.

- *Part A, the owner above.* The main thread (`normal`) says 40 lines; after
  each `say()` it checks the logger has taken that line.
- *Part B, the owner below.* The logger is lowered to `below_normal`; the main
  thread says 300 lines in a burst, and notes which `say()` had to wait.
  Then one line and 1.2 s of quiet: the buffer is written out once.
- *The read-back.* `stop()` (the logger writes out the rest and returns),
  then `verify()`; the parts' results are printed again on the console.

**`4cpu/main.zig`** first releases cores 1–3; the logger and the main thread
stay on core 0, so parts A and B are the same. And **part C**: three
producers, one on each of cores 1–3, wait at a start line, then say 100
lines each at once; an observer in the logger checks each producer's
sequence numbers and counts how often consecutive lines came from different
cores.

### Files in the build

The same files as lesson 01 (see `../01-bring-up/README.md`, *Files in the
build*), with this lesson's own source in place of lesson 01's:

- `micro-os-plus-iii-aarch64/test/tutor/16-sd-card/1cpu/main.zig` (or `4cpu/main.zig`)
- `micro-os-plus-iii-aarch64/test/tutor/common/sdlog.zig` (the logger), `tutor.zig` (`output`, `second_timer.nowUs()`, `onHardware()`)
- `micro-os-plus-iii-aarch64/test/board.zig` (`options()`, `cpuSlot()`, `uart.puts()`/`putsUart()`, the SMP start)
- the card: `micro-os-plus-iii-aarch64/drivers/sd.zig`, `drivers/fatfs.zig`, `drivers/ff_api.h`, `drivers/fatfs/ff.c`, `drivers/fatfs/ffconf.h`
- the port (`micro-os-plus-iii-aarch64/src/port.zig`), the board (`micro-os-plus-iii-aarch64/boards/rpi4b/startup.S`, `board.zig`, `linker.ld`) and the kernel (`micro-os-plus-iii/src/rtos/mqueue.zig`, `semaphore.zig`, and the rest of `micro-os-plus-iii/src/`)
- `micro-os-plus-iii-aarch64/build.zig` — the entries `tutor-16-sd-card-1cpu` and `-4cpu` (`.devices = true`: the SD driver, FatFs and the `sdlog` module)

## 4. The test

PASS when, in both versions:

- the card came up (on the board);
- part A: each of the 40 lines was taken before its `say()` returned, none
  waited;
- part B: the first 64 lines — the queue's depth — went in without waiting,
  the logger having taken none of them; each of the other 236 waited for a
  slot; one quiet half second wrote the buffer out exactly once;
- (4 CPUs) part C: each producer ran on its core; all 300 lines arrived,
  each producer's in its order; they arrived mixed (more than 2 producer
  switches); the producers waited for slots; the logger ran only on core 0;
- the buffer was written out when full and on every sync; on the board, the
  file read back has the size, CRC-32 and newlines written, and no append
  failed;
- the heap is back to its level; (4 CPUs) cores 1–3 joined.

## 5. Running it

As lesson 01 (see `../01-bring-up/README.md`, *Running it*); from
`micro-os-plus-iii-aarch64`:

```sh
cd micro-os-plus-iii-aarch64
export PATH=$HOME/zig-x86_64-linux-0.17.0:$PATH
zig build -Dtest=tutor-16-sd-card-1cpu
zig build -Dtest=tutor-16-sd-card-4cpu
zig build -Dtest=tutor-16-sd-card-1cpu run    # QEMU
zig build -Dtest=tutor-16-sd-card-4cpu run
test/run-all.sh tutor-16-sd-card-1cpu          # the board
test/run-all.sh tutor-16-sd-card-4cpu
```

The board needs its SD card (the boot card: the lesson writes only
`tests/tutor16.log`). On the board the logger's lines go to the UART only.

## 6. Results

Both versions PASS under QEMU and on the board (2026-10-24): 17 s and 18 s
on the board, the log read back intact. Under QEMU, as in C++, the first 64
lines of part B went in without waiting and the other 236 waited; with four
CPUs the three producers' 300 lines arrived in their order, mixed (200
producer switches). See [`RESULTS.md`](RESULTS.md).

### What this lesson found

- **Starting three producers.** Created one after the other, the first
  producer filled the queue at once; the logger, above the main thread on
  core 0, then kept core 0 busy, and the main thread created the next
  producer only when the first one had finished: on the board the lines did
  not mix ("the lines of the three cores arrived mixed" failed). The
  producers now wait at a start line until all three exist.
- The C++ kernel's message queue did not reschedule after a send or a
  receive that succeeded after waiting (part B: 65 lines in without
  waiting); fixed there. The Zig kernel (`mqueue.zig`) already rescheduled
  after every successful wait: part B gave 64 from its first run.
