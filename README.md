# µOS++ IIIe for Zig — the AArch64 port

The ARMv8-A (AArch64) port of the Zig µOS++ IIIe kernel
(`../micro-os-plus-iii`), the Zig counterpart of the C++
`micro-os-plus-iii-aarch64`, for the Raspberry Pi 4 B (BCM2711, 4× Cortex-A72,
GIC-400, generic timer, PL011 UART). Threads run at EL1h with a full AAPCS64
frame (x0–x30, ELR, SPSR, FPSR, FPCR, q0–q31, 800 bytes); the tick is each
core's generic timer, the IPI a GIC SGI, the kernel lock an `ldaxr`/`stlxr`
spin lock; a switched-out context becomes claimable by another core only
once the stack pointer has left it.

The design, the board's particularities and the test results are in
[docs/rpi4b-aarch64-smp-port-architecture-and-internals.md](docs/rpi4b-aarch64-smp-port-architecture-and-internals.md)
(also as a PDF).

## Requirements

- Zig 0.17.0.
- The kernel, `../micro-os-plus-iii`.
- OpenOCD (the xPack) and a CMSIS-DAP probe on the Pi's JTAG pins (GPIO
  22–27), e.g. the Raspberry Pi Debug Probe (`2e8a:000c`).
- An SD card in the Pi with its firmware and a `config.txt` that enables
  the UART and JTAG and leaves cores 1–3 in the armstub8 spin table (the
  C++ port's `test/boards/rpi4b/config.txt`). The SD tests mount its EXISTING
  FAT32 volume and write only in `/tests`; it is never formatted.
- For `cmsis-os-validator`: the `@xpacks/arm-cmsis-rtos-validator` xPack
  (`~/.local/xPacks/...` or `-Dcmsis_rv=<folder>`).

## Build and run

```sh
zig build                                     # every test
zig build -Dtest=smp-test2                    # one test
bash test/hw.sh rpi4b zig-out/firmware/rpi4b/smp-test2.elf 180   # run it
test/run-all.sh                               # all of them, with a verdict table
test/run-all.sh smp-test2 sd_test             # some of them
```

The images land in `zig-out/firmware/rpi4b/<test>.elf` (and `.img`). Each
run resets the Pi through its watchdog (OpenOCD), waits 10 s for it to boot,
halts core 0, loads the ELF and resumes it at 0x80000, then follows the
semihosting log until `RESULT: PASS` or `RESULT: FAIL`, at most 180 s. No
power cycle is needed between tests.

As the C++ rpi4b hardware build, only the verdict lines (`RESULT`, `FAIL`,
`FATAL`) go through semihosting: a semihosting call costs seconds with this
probe, and OpenOCD 0.12 does not resume cores 1–3 after one on this board.
The whole console is on the UART (115200 8N1, GPIO 14/15). The logs are
`zig-out/hw-logs/rpi4b/<test>.log`.

## Tests

Faithful ports of the C++ `test/rpi4b/` tests (the same banners and lines,
structure and verdict); the deviations are stated in each `main.zig`. All
pass on the board (2026-10-16, with the `exit()` / `_Exit()` end of run):

| Test | From (C++) | Raspberry Pi 4 B |
| --- | --- | --- |
| `smp-test0` | `smp_test0` | PASS |
| `smp-test1` | `smp_test1` | PASS |
| `smp-test2` | `smp_test2` | PASS |
| `smp-test3` | `smp_test3` | PASS |
| `smp-test4` | `smp_test4` (load balancing) | PASS |
| `smp-mat-test` | `smp-mat-test` (N = 120, B = 20) | PASS |
| `smp-pro-cons-test` | `smp-pro-cons-test` | PASS |
| `mutex-stress` | harness suite | PASS |
| `rtos-apis` | harness suite | PASS |
| `cmsis-os-validator` | harness suite | PASS |
| `sd_test` | `sd_test` (FatFs in `/tests`) | PASS |
| `smp-num-test` | `smp-num-test` (FatFs, `tests/num.txt`) | PASS |
| `smp-pipeline-test` | `smp-pipeline-test` (FatFs, `tests/pipe.dat`) | PASS |
| `smp-mat-sdcard-test` | `smp-mat-sdcard-test` (N = 200, B = 20) | PASS |
| `smp-mem-test` | `smp_mem_test` | PASS |
| `smp-mem-inter-test` | `smp_mem_inter_test` (15 operations per thread; C++ 30) | PASS |
| `smp-shapes-test` | none: Zig only (the interfaces example) | PASS (2026-10-22) |
| `smp-list-storage-test` | none: Zig only (the interfaces example's list) | PASS (2026-10-22) |

The harness suites run as the C++ rpi4b harness platform runs them: 4
cores (1–3 released first), an 8192-element main stack.

`smp-shapes-test` has no C++ counterpart: it puts the interfaces example
(a generic intrusive list, vtable polymorphism, threads) on the RTOS. 40
shapes (10 circles, triangles, ellipses and rects) are built and checked by
one thread per kind on its own CPU, in one list under an RTOS mutex; then
20 rounds of 8 worker threads and a scanner create, scale, search and
destroy shapes, and the threads themselves are created, joined and
destroyed every round, the list and the heap checked after each. One
logger thread on CPU 0 prints every line on the UART and appends it to
`tests/shapes.log` on the SD card, which is read back and CRC-checked.

`smp-list-storage-test`, Zig only too, is the example's generic intrusive
list with its nodes in the three storage regions: a thread's stack, the
data segment and the heap. Four threads (one per CPU) put records and text
nodes in all three on shared lists under one mutex, and every node is
checked to lie in the region it claims; then 10 rounds of 8 workers and a
scanner push, unlink, change and search nodes of all three regions, the
threads created and destroyed every round. Console on the UART only.

`test/tutor/` is a µOS++ tutorial, the Zig version of the one in the C++
golden workspace: one small application (samples in an intrusive list on
the stack, in `.data` and on the heap; sort, max, checksum) growing one RTOS
feature per lesson, every lesson in a one-CPU (`board.options(1)`) and a
four-CPU version, every lesson README opening with the theory (README.md
and PDF; `test/tutor/README.md` is the plan and the index). Lesson 01,
bring-up, passes both versions under QEMU and on the board.

## Layout

| Path | Contents |
| --- | --- |
| `src/port.zig` | the port contract: frame, context switch, kernel lock, GIC tick and IPI, secondaries, clocks, trace, termination |
| `src/arch.zig`, `src/gic.zig`, `src/mmu.zig` | system registers and barriers; the GIC-400; the identity map and the high-memory mapper |
| `src/semihosting.zig`, `src/faults.zig`, `src/c_printf.c` | `hlt #0xF000` semihosting; the exception reports; the `printf` family for C code |
| `boards/rpi4b/` | `board.zig`, `startup.S`, `linker.ld`, `openocd.cfg`, `reset.cfg` |
| `drivers/` | `sd.zig` (EMMC2 SDHCI), `fatfs.zig` and `fatfs/` (FatFs R0.15a, C, unchanged) |
| `test/` | the tests, `board.zig`, `start.zig`, `hw.sh`, `run-all.sh` |

## Licence

MIT, as µOS++; see `LICENSE`. FatFs (`drivers/fatfs/`) has its own licence,
`drivers/fatfs/LICENSE.txt`.
