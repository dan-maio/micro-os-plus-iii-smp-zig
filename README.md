# µOS++ IIIe for Zig — the AArch64 port

The 64-bit Arm (AArch64 / ARMv8-A) architecture port of the Zig µOS++ IIIe RTOS kernel (`../micro-os-plus-iii`), targeting the Raspberry Pi 4 B (BCM2711, 4× Cortex-A72 cores, GIC-400 / GICv2, Arm Generic Timer, PL011 UART).

Tested on QEMU `raspi4b` (QEMU 9.2.4) and compatible with bare-metal SD boot / U-Boot.

## Overview & Architecture

- **Execution Level**: EL1h (Kernel/OS privilege, dedicated EL1 SP). Drops cleanly from EL3 or EL2 if entered via firmware/QEMU boot.
- **MMU & Caching**: Identity-mapped 4 GB address space with 2 MB Level-1 block descriptors (TCR_EL1, TTBR0_EL1, MAIR_EL1).
  - DRAM (`0x00080000 .. 0x3B3FFFFF`): Normal memory, Inner/Outer Write-Back Cacheable, Inner-Shareable (`MAIR_ATTR0 = 0xFF`).
  - Device MMIO (`0xFC000000 .. 0xFFFFFFFF`): Device-nGnRnE memory, Execute-Never (`MAIR_ATTR1 = 0x04`).
- **Context Frame**: 800-byte full AAPCS64 context frame saving `x0`–`x30`, `ELR_EL1`, `SPSR_EL1`, `FPSR`, `FPCR`, and 128-bit SIMD/FP registers `q0`–`q31`.
- **SMP Concurrency & Locking**:
  - Spinlock using exclusive load/store (`ldaxr` / `stlxr`) with `wfe` / `sev`.
  - Secondary core boot via spin-table release (`0xD8 + 8 * core`, cache cleaned via `dc cvac`, woken via `sev`).
  - Deferred SMP publish mechanism (`SMP_PUBLISH`) guaranteeing memory barrier ordering before core state transitions.
- **Interrupts & Timer**:
  - ARM Generic Timer physical timer (`CNTP_CTL_EL0`, `CNTP_TVAL_EL0`, `CNTPCT_EL0`) delivering 1 kHz system ticks via GIC PPI 30.
  - GIC-400 distributor & CPU interface (`GICD` @ `0xFF841000`, `GICC` @ `0xFF842000`).
  - Inter-Processor Interrupts (IPI) via GIC SGI 0 (`GICD_SGIR`) for cross-core rescheduling and thread resumption.
- **Semihosting & Console**:
  - AArch64 semihosting trap (`hlt #0xF000`) for test termination (`SYS_EXIT` = `0x18`) with exit code passing (`ADP_Stopped_ApplicationExit`).
  - Dual-output UART0 / PL011 @ `0xFE201000` for console trace.

## Requirements

- **Zig**: 0.17.0 (`/home/dan/zig-x86_64-linux-0.17.0/zig`).
- **Kernel**: `../micro-os-plus-iii`.
- **QEMU**: `qemu-system-aarch64` (v9.x+ with `-M raspi4b -smp 4`).

## Build and Run

To build all firmware images or a specific test:

```sh
# Build a specific test
zig build -Dtest=smp-test0
zig build -Dtest=smp-test1
zig build -Dtest=smp-test2
zig build -Dtest=smp-test3
zig build -Dtest=smp-test4
zig build -Dtest=smp-mat-test

# Output files land in:
#   zig-out/firmware/rpi4b/<test>.elf
#   zig-out/firmware/rpi4b/<test>.img
```

To run with QEMU:

```sh
qemu-system-aarch64 \
  -M raspi4b \
  -smp 4 \
  -nographic \
  -monitor none \
  -serial stdio \
  -semihosting-config enable=on,target=native \
  -kernel zig-out/firmware/rpi4b/smp-test1.elf
```

## Test Suite Status

| Test | Description | Result |
| --- | --- | --- |
| `smp-test0` | Single-core heartbeat (1 kHz tick, generic timer, MMU, PL011 UART) | **PASS** (10 exact 1-second heartbeats on Core 0) |
| `smp-test1` | 4-core SMP bringup & cross-core semaphore ping-pong (Core 0 <-> Core 1 with Core 2 logger) | **PASS** (650,000+ rounds across cores) |
| `smp-test2` | 4-core lock coherency & atomic counter under mutex contention | **PASS** (Exact 8000 increments across 4 cores) |
| `smp-test3` | Cross-core pipeline & IPI thread wakeup (producer on Core 0, prime filter on Core 1, logger on Core 2) | **PASS** (500 items processed & classified) |
| `smp-test4` | Multi-primitive cross-core stress (EventFlags, two-way MessageQueue, MemoryPool, CondVar, Mutex) | **PASS** (50 rounds per primitive across cores) |
| `smp-mat-test` | Parallel block Gaussian elimination solver (Core 0 + Core 1 helper) vs serial ground truth | **PASS** (`max \|dx\| = 0e0`) |

## Repository Structure

```
.
├── boards/
│   └── rpi4b/
│       ├── board.zig       # BCM2711 peripheral map, PL011, secondary core release
│       ├── linker.ld       # Memory sections, 64-bit alignments, EL1 stack tops
│       └── startup.S       # Drop from EL3/EL2 -> EL1h, vector table, context switch, IRQ
├── src/
│   ├── arch.zig            # AArch64 system registers, barrier instructions, spinlocks
│   ├── faults.zig          # ESR_EL1, ELR_EL1, FAR_EL1 fault decoder & register dumper
│   ├── gic.zig             # GIC-400 distributor & CPU interface drivers, SGI/PPI config
│   ├── mmu.zig             # 4 GB identity-mapping MMU page tables (Level 1 2MB blocks)
│   ├── port.zig            # Implementation of kernel's port_contract.zig
│   └── semihosting.zig     # HLT #0xF000 AArch64 semihosting trap & SYS_EXIT
└── test/
    ├── board.zig           # Board test configuration & memory parameters
    ├── start.zig           # Test startup trampoline
    ├── smp-test0/          # Test 0 entry point
    ├── smp-test1/          # Test 1 entry point
    ├── smp-test2/          # Test 2 entry point
    ├── smp-test3/          # Test 3 entry point
    ├── smp-test4/          # Test 4 entry point
    └── smp-mat-test/       # Parallel matrix solver entry point
```
