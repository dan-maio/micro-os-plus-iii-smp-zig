# µOS++ IIIe for Zig — the Cortex-M port

The Cortex-M architecture port of the Zig µOS++ IIIe kernel
(`../micro-os-plus-iii`), on [MicroZig](https://github.com/ZigEmbeddedGroup/microzig)
0.17: context switch (PendSV), SysTick, BASEPRI or PRIMASK critical
sections, FPU lazy stacking, the fault reporter, and SMP on the RP2040 (two
Cortex-M0+) and RP2350 (two Cortex-M33, SIO spinlocks and FIFO IPIs).

## Boards

| `-Dboard=` | Board | CPU | Probe |
| --- | --- | --- | --- |
| `pico2` | Raspberry Pi Pico 2 (RP2350) | 2× Cortex-M33F, SMP | Raspberry Pi Debug Probe (`2e8a:000c`) |
| `pico` | Raspberry Pi Pico (RP2040) | 2× Cortex-M0+, SMP | Raspberry Pi Debug Probe (`2e8a:000c`) |
| `pico2-rp2350b-psram` | WeAct RP2350B core board, 16 MB flash + 8 MB PSRAM | 2× Cortex-M33F, SMP | its CMSIS-DAP (`c251:f001`), SWD at 500 kHz |
| `weactf411` | WeAct Black Pill (STM32F411CE) | Cortex-M4F | WCH-Link in ARM mode (`1a86:8011`) |
| `nucleof411` | ST Nucleo-F411RE (STM32F411RE, HSI 16 MHz) | Cortex-M4F | the integrated ST-Link (`0483:374b`) |
| `weactf412` | WeAct STM32F412RE core board (HSE 8 MHz, 100 MHz) | Cortex-M4F | an ST-Link (SWD, 1000 kHz), as the C++ board |

## Requirements

- Zig 0.17.0.
- MicroZig 0.17.x; `build.zig.zon` points at it with a relative path.
- The kernel, `../micro-os-plus-iii`.
- OpenOCD (the xPack) to run the tests.
- For `cmsis-os-validator`: the `@xpacks/arm-cmsis-rtos-validator` xPack.
  The default is `~/.local/xPacks/@xpacks/arm-cmsis-rtos-validator/1.0.0-4`;
  another location is given with `-Dcmsis_rv=<folder>`. Without it the
  test is skipped.

## Build and run

```sh
zig build -Dboard=pico2                              # every test of the board
zig build -Dboard=pico                               # every test of the Pico (RP2040)
zig build -Dboard=weactf411 -Dtest=rtos-apis         # one test
zig build run -Dboard=pico2 -Dtest=smp-test2         # program it and run it
bash test/hw.sh pico2 zig-out/firmware/pico2/smp-test2.elf 120
```

The images land in `zig-out/firmware/<board>/<test>.elf`. `test/hw.sh`
programs the image with OpenOCD (no GDB) and follows the semihosting
output until `RESULT: PASS` or `RESULT: FAIL`; the log is
`zig-out/hw-logs/<board>/<test>.log`. The trace also goes to the board's
UART, for a terminal; the runner never opens a serial port.

The RP2040/RP2350 keep peripheral state (USB, SIO) across a debugger reset:
power cycle or reset the Pico / Pico 2 between tests, or a test may fail at start
(seen with `smp-test-usb-cdc-acm`). The WCH-Link can drop the connection
under heavy semihosting traffic ("CMSIS-DAP command mismatch", the log cut
short); reset and run again. It also bridges the UART, and drops what it has
not forwarded when OpenOCD disconnects at the end of a run: `terminate()`
drains the UART and waits about 1 s before the semihosting `SYS_EXIT`, so
the terminal gets the whole end.

## Tests

Every test is a faithful port of a C++ test: same banners and lines, same
LED behaviour, same verdict. Deviations are stated in the test's
`main.zig`. Board specific tests are in `test/<board>/<test>/`, the others
in `test/<test>/`.

| Test | From (C++) | Pico 2 | Pico | WeAct F411 | Nucleo F411 | WeAct F412 |
| --- | --- | --- | --- | --- | --- | --- |
| `smp-test0` | `test/pico{,2}/smp-test0` | PASS | PASS | PASS | builds | builds |
| `smp-test1` | `test/pico{,2}/smp-test1` | PASS | PASS | PASS | builds | builds |
| `smp-test2` | `test/pico{,2}/smp-test2` (affinity) | PASS | PASS | SMP only | SMP only | SMP only |
| `smp-test3` | `test/pico{,2}/smp-test3` (resume IPI, kernel and direct) | PASS | PASS | SMP only | SMP only | SMP only |
| `smp-test4` | `test/pico{,2}/smp-test4` | PASS | PASS | SMP only | SMP only | SMP only |
| `smp-test5` | `test/pico{,2}/smp-test5` | PASS | PASS | Pico / Pico 2 only | Pico / Pico 2 only | Pico / Pico 2 only |
| `smp-mat-test` | `test/pico{,2}/smp-mat-test` | PASS, speedup 2.016× | PASS, speedup 1.183× | PASS (one CPU) | builds | builds |
| `sc-test-ko` | `test/pico{,2}/sc-test-ko` (single core) | PASS, 10/10 | PASS, 10/10 | PASS | builds | builds |
| `smp-test-ko` | `test/pico{,2}/smp-test-ko` | PASS, 10/10 | PASS, 10/10 | Pico / Pico 2 only | Pico / Pico 2 only | Pico / Pico 2 only |
| `exc-test` | `test/pico{,2}/exc-test` | PASS | PASS | Pico / Pico 2 only | Pico / Pico 2 only | Pico / Pico 2 only |
| `smp-test-usb-cdc-acm` | `test/pico{,2}/smp-test-usb-cdc-acm` | PASS (after a reset) | PASS | Pico / Pico 2 only | Pico / Pico 2 only | Pico / Pico 2 only |
| `fp-switch` | harness suite `fp-switch` | PASS, 3681 rounds, 0 bad | PASS (no FPU) | PASS, 2474 rounds, 0 bad | builds | builds |
| `mutex-stress` | harness suite `mutex-stress` | PASS | PASS | PASS | PASS | PASS |
| `rtos-apis` | harness suite `rtos-apis` (C++, C, ISO, POSIX I/O parts) | PASS | PASS | PASS | PASS | PASS |
| `cmsis-os-validator` | harness suite `cmsis-os-validator` (Arm CMSIS-RTOS validator) | PASS, 60/60 | PASS, 60/60 | PASS, 60/60 | PASS, 60/60 | PASS, 60/60 |
| `io-test` | the `std.Io` suite (no C++ counterpart) | PASS, 25/25 | PASS, 25/25 | PASS, 25/25 | builds | builds |
| `spi-pipeline` | `test/weactf411/spi-pipeline` | WeAct only | WeAct only | PASS, 8/8 | WeAct only | WeAct F411 only |
| `mos-test1` | `test/{weactf411,nucleof411,weactf412}/mos-test1` | — | — | PASS | PASS | PASS |
| `uart-test1` | `test/weactf412/uart-test1` (RXNE interrupt RX, DMA TX, echo) | — | — | — | — | PASS |

Last full runs (`test/run-all.sh <board>`, 2026-10-16): Pico 2 16/16,
Pico 16/16, WeAct F411 10/10 (and `mos-test1`, added later, PASS), all ending through `exit()` / `_Exit()` with
one `RESULT` line each. On the Nucleo-F411RE and the WeAct F412RE the
tests of the C++ boards ran one by one (2026-10-16); "builds" are the
generic tests those C++ boards do not have.

The Nucleo's console (USART2, the ST-Link's virtual COM port) is
interrupt driven: a polled line takes longer than a tick at 115200 baud,
and `rtos-apis` prints from a 1 ms periodic timer callback. The F412's
console is the C++ board's driver (`src/boards/stm32f4_uart_dma.zig`):
RXNE-interrupt reception and DMA2 Stream7 transmission, with RTOS
semaphores; the trace uses it without ever blocking.

### The WeAct RP2350B PSRAM board

`-Dboard=pico2-rp2350b-psram`, the C++ `test/pico2-rp2350b-psram/` tests
(`test/pico2-rp2350b-psram/<test>/`); console on UART0 GPIO12/13. All pass
on the board (2026-10-16):

| Test | From (C++) | WeAct RP2350B PSRAM |
| --- | --- | --- |
| `smp-test0` … `smp-test5`, `smp-test-ko`, `sc-test-ko`, `exc-test`, `fp-switch` | as the Pico 2's, the board's banner | PASS |
| `smp-mat-test` | N = 300, B = 50, the matrices in the PSRAM | PASS, speedup 9.56× |
| `smp-test-nested` | nested interrupts (UART0 / TIMER0 alarms 2, 3), lock-free trace, handlers in RAM | PASS |
| `smp-test-nested-clock`, `_200`, `_250` | the same with the from-scratch clock table (48..200 / 250 MHz, chosen with the potentiometer on GPIO40 and 'y' on the console, a watchdog reboot into the clock), a block solver in the PSRAM (N = 1000 / 500 / 800) | PASS (interactive; judged on the console after a clock reboot) |

The board's pieces: `src/boards/pico2-rp2350b-psram.zig` (MicroZig's
RP2350B 16 MB target, a run-time clock and baud), `rp2350_psram.zig` (the C++
`psram.cpp`, run from SRAM), `rp2350_clocks.zig` (the C++ `clocks.cpp` table
and reboot), `rp2350_adc.zig`. Deviations: the PSRAM is initialised by the
tests (C++: boot.S), so only the solvers' arrays live in it (C++: all of
`.data`/`.bss`); `smp-test3` and `exc-test` follow the current Pico 2 copies
(the C++ PSRAM ones are the older versions); `hw.sh` runs SWD at 500 kHz (the
C++ 1000 lost the link) and clears the clock-table watchdog scratch before
`reset init` (a row left there boots every reset into that clock, and the
reset then times out). A clock reboot can knock this probe off USB, so after
one the verdict is read on the console.

The harness suites run as in the C++ pico2 harness build: one CPU, with the
suite's `os-app-config.h` values in `uos_options`. Their C parts are the
original C sources: `rtos-apis` links `test-c-api.c`, and
`cmsis-os-validator` compiles the validator xPack, both over the kernel's C
API, CMSIS-RTOS v1 API and minimal C runtime.

Not ported: the C++ `test_chan_fatfs` part of `rtos-apis` (excluded on
these boards in C++ too).

## Adding a test

1. Create `test/<name>/main.zig` (or `test/<board>/<name>/main.zig`).
2. Add `.{ .name = "<name>" }` to `tests` in `build.zig` (and the board
   entry to `board_tests` for a board-specific one). `smp_only`, `only`,
   `c_sources`, `c_flags` and `cmsis_rv` select boards and add C code.

`test/harness.zig` (module `uos_test`) has the common startup, panic
handler and default options.

## Documentation

`docs/port-architecture-and-internals.md` describes the architecture, the
SMP design, how Zig expresses the C++ object model, the context switch and
the tests; `docs/architecture-board-build-and-test-guide.md` is the
reference manual for adding architectures/boards, building, and running
QEMU/OpenOCD hardware tests; `docs/posix-port-architecture-and-internals.md`
the sibling POSIX port (`../micro-os-plus-iii-posix-arch`);
`docs/weact-studio-blackpill-architecture-and-internals.md` the F411 board;
`docs/aarch32-aarch64-smp-amp-porting-guide.md` how to port further.

## Licence

MIT, as µOS++; see `LICENSE`.
