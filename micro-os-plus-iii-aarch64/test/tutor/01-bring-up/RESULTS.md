# Lesson 01 (Zig) — Results

| Version | QEMU (`raspi4b`) | Board (Raspberry Pi 4 B, `test/run-all.sh`) |
|---|---|---|
| `tutor-01-bring-up-1cpu` | PASS | PASS, 14 s |
| `tutor-01-bring-up-4cpu` | PASS | PASS, 15 s |

Run on 2026-10-22, the Zig workspace, Zig 0.17.0, `zig build` (safe mode).
The board's verdict lines, from the runner's OpenOCD log:

```
RESULT: PASS (24 samples in 3 regions, sorted, max and checksum exact, one CPU)
RESULT: PASS (24 samples in 3 regions, sorted, max and checksum exact, four CPUs)
```

**One unexplained failure.** The very first board run of the four-CPU
version ended with `RESULT: FAIL (1 failed checks)`. The failing line went
to the UART only (failed checks print `[BAD]`, which is not mirrored to
semihosting), so which check failed is not known. It was not reproduced:
the four-CPU version then passed eight times in a row on the board (five
alone, and twice after the one-CPU version, as in the failing run), with a
temporary build that mirrored failed checks to semihosting, and once more
with the final build. The one-CPU version passed every time.

On the board the console is the UART; only the verdict reaches
semihosting. The full consoles below are the QEMU runs. The addresses
differ between the two versions (the SMP kernel is larger) and from the C++
lesson's (another kernel); the results do not.

## One CPU (QEMU)

```
+== RPi 4 B µOS++ tutorial (Zig) : 01 bring-up (1 CPU) ==+

Lesson 01, one CPU: 24 samples in 3 regions, one list, sort and max.
  .data   000921d0 .. 00092550
  heap    00915230 .. 3b400000
  stack   0009f210 .. 000af208 (thread main)

-- the list
  [ok] 24 samples in the list
  [ok] 8 on the stack, 8 in .data, 8 on the heap
  [ok] every sample lies in the region it claims, seal intact

-- sorted (value id region)
  +552  #9  .data
  +729  #20 heap
  +892  #23 heap
  +1659  #18 heap
  +1755  #5  stack
  +2522  #0  stack
  +2685  #3  stack
  +2862  #14 .data
  +4197  #7  stack
  +4327  #2  stack
  +4624  #21 heap
  +4707  #1  stack
  +5097  #12 .data
  +5342  #19 heap
  +5366  #15 .data
  +5814  #10 .data
  +5839  #6  stack
  +7576  #17 heap
  +7600  #13 .data
  +8048  #8  .data
  +8073  #4  stack
  +8318  #11 .data
  +8707  #22 heap
  +9217  #16 heap
  [ok] the list is in ascending order
  [ok] checksum 7bb976a9, expected 7bb976a9
  [ok] max 9217 (#16), expected 9217 (#16)
  [ok] heap back to 0 B
RESULT: PASS (24 samples in 3 regions, sorted, max and checksum exact, one CPU)
```

## Four CPUs (QEMU)

```
+== RPi 4 B µOS++ tutorial (Zig) : 01 bring-up (4 CPU) ==+

Lesson 01, four CPUs: 24 samples in 3 regions, one list, sort and max.
  .data   00093410 .. 00093ac8
  heap    009225f0 .. 3b400000
  stack   000ac530 .. 000bc520 (thread main)

-- SMP bring-up
  main thread on core 0
core 0: releasing core 1...
core 0: releasing core 2...
core 0: releasing core 3...
  cores joined after 0 ms: c1=3 c2=3 c3=3
  [ok] cores 1-3 joined the scheduler
  core 0 idle thread: idle
  core 1 idle thread: idle1
  core 2 idle thread: idle2
  core 3 idle thread: idle3
  [ok] every core has its idle thread

-- the list (built on core 0)
  [ok] 24 samples in the list
  [ok] 8 on the stack, 8 in .data, 8 on the heap
  [ok] every sample lies in the region it claims, seal intact

-- sorted (value id region)
  +552  #9  .data
  +729  #20 heap
  +892  #23 heap
  +1659  #18 heap
  +1755  #5  stack
  +2522  #0  stack
  +2685  #3  stack
  +2862  #14 .data
  +4197  #7  stack
  +4327  #2  stack
  +4624  #21 heap
  +4707  #1  stack
  +5097  #12 .data
  +5342  #19 heap
  +5366  #15 .data
  +5814  #10 .data
  +5839  #6  stack
  +7576  #17 heap
  +7600  #13 .data
  +8048  #8  .data
  +8073  #4  stack
  +8318  #11 .data
  +8707  #22 heap
  +9217  #16 heap
  [ok] the list is in ascending order
  [ok] checksum 7bb976a9, expected 7bb976a9
  [ok] max 9217 (#16), expected 9217 (#16)
  [ok] heap back to 0 B
RESULT: PASS (24 samples in 3 regions, sorted, max and checksum exact, four CPUs)
```

## What the numbers show

- The sorted order, the checksum (`7bb976a9`) and the maximum (9217, sample
  #16) are the same in both versions, equal the array reference, and equal
  the C++ lesson's: the two languages' bases compute the same thing.
- The samples from the three regions interleave freely in the sorted list:
  the intrusive list does not care where a node lives.
- The heap returns to its starting level (0 B in use) once the 8 heap
  samples are destroyed. Here the heap is the RAM after the image (from
  about 0x915000 to 0x3B400000), not a fixed section as in the C++ port.
- With four CPUs the port prints each core's release, the cores join at
  once, and every core has its idle thread, while the work stays on core 0.
