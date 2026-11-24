# Lesson 16 (Zig) — Results

| Version | QEMU (`raspi4b`) | Board (Raspberry Pi 4 B, `test/run-all.sh`) |
|---|---|---|
| `tutor-16-sd-card-1cpu` | PASS (no card) | PASS, 17 s |
| `tutor-16-sd-card-4cpu` | PASS (no card) | PASS, 18 s |

Run on 2026-10-24. The board's verdict lines:

```
RESULT: PASS (the SD log verified)
RESULT: PASS (the SD log verified)
```

On the board the Zig images send only the verdict lines to semihosting;
the console is on the UART. The full consoles below are the QEMU runs (the
burst lines shortened here).

| | 1 CPU, QEMU | 4 CPUs, QEMU |
|---|---|---|
| part A: lines taken before `say()` returned | 40 of 40 | 40 of 40 |
| part A: one `say()` | 44 µs | 43 µs |
| part B: queued without waiting / waited | 64 / 236 | 64 / 236 |
| part B: one `say()`, queued / waited | 11 / 31 µs | 11 / 34 µs |
| quiet write-outs | 1 | 1 |
| part C: lines, out of order, producer switches | — | 300, 0, 200 |
| part C: lines that waited, cores 1 / 2 / 3 | — | 47 / 55 / 53 |
| written out: full / quiet / sync | 1 / 1 / 4 | 2 / 1 / 6 |

## One CPU (QEMU)

```
+== RPi 4 B µOS++ tutorial (Zig) : 16 sd card (1 CPU) ==+

Lesson 16, one CPU: one logger thread owns the SD card; the other threads send it lines.
  .data   0009e1d0 .. 000a02b0
  heap    0091e000 .. 3b400000
  stack   000a7210 .. 000b7208 (thread main)

-- the card: none in this image (QEMU): the lines go to the UART only
  every line from now on goes through the logger, to the UART

-- part A: the logger (above_normal) above the producer: 40 lines
A 00 value  +781
A 01 value +9208
A 02 value +7316
… (35 more lines)
A 38 value  +631
A 39 value +2884
  40 of 40 lines printed before say () returned, 0 waited for a slot; say () took 44 us each
  [ok] above the producer, the logger takes each line at once

-- part B: the logger lowered to below_normal; a burst of 300 lines into a queue of 64
B 000 value  +992
B 001 value +3564
B 002 value +7527
… (295 more lines)
B 298 value +8590
B 299 value +7017
  64 lines queued without waiting (11 us each), the logger had taken 0 of them;
  then 236 waited for a slot (31 us each), from line 64
  [ok] below the producer, the queue takes 64 lines; then each line waits for a slot
  one line, then 1200 ms quiet
  the buffer was written out 1 time(s) while quiet
  [ok] half a second without a line writes out the buffer, once

-- the log read back
  the parts, again: A 40 of 40 lines printed before say () returned (44 us each), 0 waited;
  B 64 queued at once (11 us each, 0 taken meanwhile), then 236 waited (31 us each) from line 64; 1 quiet write-out
  352 say () calls, 355 lines, 6841 B; written out 6 times: 1 full, 1 quiet, 4 sync; 0 write errors
  [ok] the buffer was written out when full and on every sync
  no card in this image: the read-back is skipped
  heap: 0 B before the card, 0 B after
  [ok] the heap is back to its level
RESULT: PASS (no SD card in this image)
```

## Four CPUs (QEMU)

```
+== RPi 4 B µOS++ tutorial (Zig) : 16 sd card (4 CPU) ==+

Lesson 16, four CPUs: one logger thread owns the SD card; the other threads send it lines.
  .data   000a1ad8 .. 000a3ef0
  heap    0092d000 .. 3b400000
  stack   000b6530 .. 000c6520 (thread main)
core 0: releasing core 1...
core 0: releasing core 2...
core 0: releasing core 3...
  cores joined after 0 ms: c1=3 c2=3 c3=3
  [ok] cores 1-3 joined the scheduler

-- the card: none in this image (QEMU): the lines go to the UART only
  every line from now on goes through the logger, to the UART

-- part A: the logger (above_normal, core 0) above the producer: 40 lines
A 00 value  +781
A 01 value +9208
A 02 value +7316
… (35 more lines)
A 38 value  +631
A 39 value +2884
  40 of 40 lines printed before say () returned, 0 waited for a slot; say () took 43 us each
  [ok] above the producer, the logger takes each line at once

-- part B: the logger lowered to below_normal; a burst of 300 lines into a queue of 64
B 000 value  +992
B 001 value +3564
B 002 value +7527
… (295 more lines)
B 298 value +8590
B 299 value +7017
  64 lines queued without waiting (11 us each), the logger had taken 0 of them;
  then 236 waited for a slot (34 us each), from line 64
  [ok] below the producer, the queue takes 64 lines; then each line waits for a slot
  one line, then 1200 ms quiet
  the buffer was written out 1 time(s) while quiet
  [ok] half a second without a line writes out the buffer, once

-- part C: three producers on cores 1-3, 100 lines each, at once; the logger on core 0
C c3 000 value +4328
C c1 000 value  +118
C c2 000 value +9455
… (295 more lines)
C c2 098 value +4505
C c2 099 value +6758
  producer 1: ran on core 1, 100 lines taken, 47 waited for a slot
  producer 2: ran on core 2, 100 lines taken, 55 waited for a slot
  producer 3: ran on core 3, 100 lines taken, 53 waited for a slot
  300 lines; out of their producer's order: 0; the logger switched producer 200 times
  [ok] each producer ran on its core
  [ok] every line arrived, each producer's in its order
  [ok] the lines of the three cores arrived mixed
  [ok] three producers outran the one logger: they waited for slots
  [ok] the logger ran only on core 0

-- the log read back
  the parts, again: A 40 of 40 lines printed before say () returned (43 us each), 0 waited;
  B 64 queued at once (11 us each, 0 taken meanwhile), then 236 waited (34 us each) from line 64; 1 quiet write-out
  C 300 lines, 0 out of order, 200 producer switches; waited 47 / 55 / 53 on cores 1 / 2 / 3
  662 say () calls, 666 lines, 13772 B; written out 9 times: 2 full, 1 quiet, 6 sync; 0 write errors
  [ok] the buffer was written out when full and on every sync
  no card in this image: the read-back is skipped
  heap: 0 B before the card, 0 B after
  [ok] the heap is back to its level
RESULT: PASS (no SD card in this image)
```
