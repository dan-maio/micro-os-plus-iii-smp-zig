# µOS++ IIIe for Zig — the AArch32 port

The ARMv7-A (AArch32) port of the Zig µOS++ IIIe kernel
(`../micro-os-plus-iii`), the Zig counterpart of the C++
`micro-os-plus-iii-aarch32`, `smp` branch. Threads run in SVC mode with the
full VFP/NEON register file in their frame; the tick is each CPU's generic
timer, the IPI a GIC-400 SGI, the kernel lock a recursive LDREX/STREX spin
lock; a switched-out context becomes claimable by another CPU only once the
stack pointer has left it.

The design is described in
[docs/aarch32-port-architecture-and-internals.md](docs/aarch32-port-architecture-and-internals.md)
(also as a PDF).

## Board

| `-Dboard=` | Board | CPUs | Probe |
| --- | --- | --- | --- |
| `luckfox-lyra` (default) | Luckfox Lyra B (Rockchip RK3506) | 3× Cortex-A7, SMP (and a Cortex-M0, see `smp-test-int5`) | WCH-Link CMSIS-DAP (`1a86:8011`), SWD |

## Requirements

- Zig 0.17.0.
- The kernel, `../micro-os-plus-iii`.
- OpenOCD (the xPack) to run the tests. No MicroZig: the board's
  `startup.S` and `linker.ld` are the C++ ones.
- An SD card in the Lyra for the SD tests: its EXISTING FAT32 volume is
  mounted and every file goes to `/tests`; it is never formatted.

## Build and run

```sh
zig build                                   # every test
zig build -Dtest=smp-test2                  # one test
zig build run -Dtest=smp-test2              # build it, load it, run it
bash test/hw.sh luckfox-lyra zig-out/firmware/luckfox-lyra/smp-test2.elf 120
```

The images land in `zig-out/firmware/luckfox-lyra/<test>.elf`, linked and
entered at 0x00200000 in DRAM. `test/hw.sh` loads one with OpenOCD (no GDB):
it halts core 0, turns its MMU and caches off, `load_image`s the ELF and
resumes it, then follows the semihosting output until `RESULT: PASS`,
`RESULT: FAIL` or `FATAL:`; the log is
`zig-out/hw-logs/luckfox-lyra/<test>.log`. The UART is not touched: it
carries the same console, for a terminal.

**No power cycle is needed between tests.** A test that released CPUs 1
and 2 (or the Cortex-M0) leaves them running, and a debugger load cannot put
them back in the BootROM, so `test/hw.sh` first runs a separate OpenOCD
session that calls `rk3506_reset_full` (`boards/luckfox-lyra/openocd.cfg`):
a physical write of the global soft-reset magic 0xFDB9 to CRU GLB_SRST_FST
(0xFF9A0C08, glb_srstn_1). It then waits 3 s for the board to boot and
attaches as after a power cycle. The reset's SWD errors are expected and go
to `<test>.reset.log`. `RESET_WAIT=<s>` changes the wait; `NO_RESET=1`
skips the reset (then power-cycle by hand).

The WCH-Link can drop the connection under heavy semihosting traffic
("CMSIS-DAP command mismatch"); most runs lose it only after the verdict,
which is harmless. Semihosting is slow on CPUs 1 and 2 (a mirrored line
halts the CPU for seconds): output-heavy threads there throttle a test, the
same as in C++.

## Layout

| Path | Contents |
| --- | --- |
| `src/port.zig` | the port: frame, context switch and IRQ entry (naked asm), kernel lock, GIC tick and IPI, secondaries, clocks, trace, termination |
| `src/arch.zig`, `src/gic.zig` | CP15, barriers, CPSR, generic timer; the GIC-400 |
| `src/semihosting.zig` | the Angel trap (`svc 0x123456`), the per-CPU line-buffered console mirror |
| `src/faults.zig` | undefined / prefetch / data abort reports (UART only), the vector targets |
| `boards/luckfox-lyra/` | `board.zig` (UART1, LED, MMU, secondary release), `startup.S`, `linker.ld`, `openocd.cfg` |
| `drivers/` | `sdmmc.zig` (the RK3506 DW-MMC host), `sd.zig`, `fatfs.zig` (FatFs glue and `tests/` helpers), `fatfs/` (FatFs R0.15a, C, unchanged), `flatfs.zig` |
| `test/board.zig`, `test/start.zig` | the test board API (as the POSIX port's) and the image root |
| `test/<name>/main.zig` | the tests |
| `test/hw.sh` | the runner |

## Tests

Faithful ports of the C++ `test/luckfox-lyra/` tests: same banners and
lines, same verdict. The portable ones share their source with the POSIX
port's; deviations are stated in each `main.zig`.

| Test | From (C++) | Luckfox Lyra B |
| --- | --- | --- |
| `smp-test0` | `smp_test0` | PASS |
| `smp-test1` | `smp_test1` | PASS |
| `smp-test2` | `smp_test2` (lock coherency, 3 cores) | PASS, 6000/6000 |
| `smp-test3` | `smp_test3` (message queue) | PASS (same throughput as C++) |
| `smp-test4` | `smp_test4` (load balancing) | PASS |
| `smp-mat-test` | `smp-mat-test` (N = 120) | PASS, speedup 3.23× |
| `smp-pro-cons-test` | `smp-pro-cons-test` | PASS |
| `smp-num-test` | `smp-num-test` (FatFs, `tests/num.txt`) | PASS |
| `smp-pipeline-test` | `smp-pipeline-test` (FatFs, `tests/pipe.dat`) | PASS, 3283 records audited |
| `sd_test` | `sd_test` (FatFs, 4 files) | PASS |
| `smp-mat-sdcard-test` | `smp-mat-sdcard-test` (N = 200, matrices on SD) | PASS, speedup 4.62× |
| `smp-test-int5` | `smp_test_int5`, `SMP_TEST_INT5_SELFTRIG` (as `tests.cmake`) | A7 side verified (GIC IDs 171/172, doorbells on cores 1 and 2); the run lost the probe at doorbell #31 |
| `smp-test-int5-m0` | `smp_test_int5` with the Cortex-M0 firmware | builds; not run yet |
| `semihosting-test` | no C++ counterpart: every operation of the kernel's `uos.semihosting` | PASS |

The SD tests follow the C++ `HW_BUILD` branch (FatFs on the card's FAT32
volume), not the QEMU one (flatfs, which formats the card).

Not ported yet: `smp_test5`, `smp_test6`, `smp_test7` (C++ FatFs, USB
gadget), `smp_test_int` to `smp_test_int4` (GIC SGI paths, USB and SD
interrupts).

## Licence

MIT, as µOS++; see `LICENSE`. FatFs (`drivers/fatfs/`) has its own licence,
`drivers/fatfs/LICENSE.txt`.
