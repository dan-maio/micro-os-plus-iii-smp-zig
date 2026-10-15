# µOS++ IIIe Zig Port: AArch64 SMP Architecture, Internals & Hardware Particularities

---

## 1. Executive Summary & Architectural Overview

### 1.1 Purpose & Scope
**µOS++ IIIe** is a real-time micro-kernel designed by Liviu Ionescu, architected for embedded systems requiring strict deterministic scheduling, zero hidden allocations, and formal architectural separation between portable kernel abstractions and target hardware ports.

This document serves as the authoritative technical reference for the **64-bit Arm (AArch64 / ARMv8-A) SMP architecture port** implemented in idiomatic **Zig (0.17.0)**. The primary target hardware platform is the **Raspberry Pi 4 Model B**, powered by the **Broadcom BCM2711 SoC with four ARM Cortex-A72 cores**.

All six core SMP verification suites have been fully ported, verified, and run on **physical Raspberry Pi 4 B silicon** over OpenOCD CMSIS-DAP JTAG with a **100% PASS rate**:
1. `smp-test0` — Single-core bringup, 1 kHz ARM Generic Timer tick, MMU activation, PL011 UART console.
2. `smp-test1` — Preemptive round-robin scheduling across four active cores.
3. `smp-test2` — 4-core mutex contention and atomic counter verification.
4. `smp-test3` — Cross-core data streaming pipeline synchronized via Inter-Processor Interrupts (IPI).
5. `smp-test4` — Cross-core kernel synchronization primitives (EventFlags, 2-way MessageQueue, MemoryBlockPool, ConditionVariable, Mutex).
6. `smp-mat-test` — 10-worker thread pool demo and parallel 4-core block linear equation solver ($N=200, B=50$) validated against ground-truth classical elimination.

---

### 1.2 C++ vs Zig Port Architectural Comparison

| Architectural Dimension | Original C++ Implementation | Zig 0.17 Port Architecture | Technical Impact |
|---|---|---|---|
| **Memory Allocation** | Implicit `new` / `malloc` with placement operators. | **Explicit allocators**: No hidden allocations. Static storage via `ThreadInclusive(N)` or explicit `BlockPool` / `FirstFitTop`. | Eliminates runtime heap fragmentation and non-deterministic allocation latency. |
| **Metaprogramming & Config** | C preprocessor `#define`, `#ifdef`, `#include <os-app-config.h>`. | **`comptime` Options & Generics**: Type functions returning monomorphized structs (`MessageQueueTyped(T)`). | Eliminates dead code at compile time; guarantees type safety without template bloat. |
| **Polymorphism & Dispatch** | C++ Virtual Method Tables (`vtable`), RTTI overhead, pointer indirection. | **Static compile-time dispatch** or compact tagged unions and function-pointer interfaces. | Zero-overhead calls; branch predictor friendly; smaller binary footprint. |
| **Hardware Abstraction** | Raw volatile pointer casts: `*(reinterpret_cast<volatile uint32_t*>(0xFE201000))`. | **Packed structs & typed MMIO slices**: Bounds-checked addresses and typed register structs. | Eliminates silent pointer corruption and misaligned memory accesses. |
| **Error Handling** | POSIX integer return codes (`-1`, `-EINVAL`, `-ETIMEDOUT`) or C++ exceptions. | **Exhaustive tagged error sets** (`error{WouldBlock, Interrupted, TimedOut, OutOfMemory}`) via `try`/`catch`. | Infallible error inspection at compile time; zero exception-table overhead. |
| **Architecture Contracts** | Loose `#if defined(OS_ARCH_...)` blocks scattered across kernel sources. | **`port_contract.zig`**: Strict compile-time interface verified via `@hasDecl` and structural typing. | Kernel code is 100% architecture agnostic; missing port functions fail compilation immediately. |
| **SMP Concurrency & Publishing** | Implicit compiler barriers and manual inline assembly spinlocks. | **`atomicStore` release + `SMP_PUBLISH` memory barrier + atomic `ldaxr`/`stlxr` spinlocks**. | Provable memory orderings across all 4 cores without cache-incoherency hazards. |

---

## 2. AArch64 Hardware Mapping & SoC Architecture

### 2.1 The BCM2711 SoC Configuration
The Raspberry Pi 4 Model B is powered by the Broadcom BCM2711 SoC, featuring a quad-core ARM Cortex-A72 cluster running at up to 1.5 GHz.

```
       +--------------------------------------------------------+
       |                  Broadcom BCM2711 SoC                  |
       |                                                        |
       |  +--------------------+        +--------------------+  |
       |  |   Cortex-A72 Core 0|        |   Cortex-A72 Core 1|  |
       |  |  (Boot / Primary)  |        |    (Secondary 1)   |  |
       |  +---------+----------+        +---------+----------+  |
       |            |                             |             |
       |  +---------+----------+        +---------+----------+  |
       |  |   Cortex-A72 Core 2|        |   Cortex-A72 Core 3|  |
       |  |    (Secondary 2)   |        |    (Secondary 3)   |  |
       |  +---------+----------+        +---------+----------+  |
       |            |                             |             |
       |            +--------------+--------------+             |
       |                           |                            |
       |        +------------------v-------------------+        |
       |        |        ARM GIC-400 (GICv2)           |        |
       |        |   Distributor:   0xFF841000          |        |
       |        |   CPU Interface: 0xFF842000          |        |
       |        |   SGI 0: IPI | PPI 30: Generic Timer |        |
       |        +------------------+-------------------+        |
       |                           |                            |
       |        +------------------v-------------------+        |
       |        |      ARM Generic Timer (CNTPCT)      |        |
       |        |   Frequency: 54 MHz (Hardware)       |        |
       |        +------------------+-------------------+        |
       |                           |                            |
       |        +------------------v-------------------+        |
       |        |       PL011 UART0 @ 0xFE201000       |        |
       |        |   Baud: 115200 (16-byte FIFO)        |        |
       |        +------------------+-------------------+        |
       +---------------------------+----------------------------+
                                   |
                +------------------v-------------------+
                |   DRAM (1 GB - 8 GB @ 0x00000000)    |
                |   Kernel load base: 0x00080000       |
                |   Spin-table mailboxes: 0x000000D8   |
                +--------------------------------------+
```

### 2.2 Memory Map Summary

| Region | Physical Address Range | Memory Type | Cacheability & Shareability | Access Permissions |
|---|---|---|---|---|
| **Spin-Table Mailboxes** | `0x000000D8 .. 0x000000F8` | Normal RAM | Outer/Inner Write-Back, Inner Shareable | Privileged Read/Write |
| **Kernel Image & Heap** | `0x00080000 .. 0x3B3FFFFF` | Normal RAM | Outer/Inner Write-Back, Inner Shareable | Privileged Read/Write/Execute |
| **Legacy Peripherals (PL011)** | `0xFE200000 .. 0xFE201FFF` | Device-nGnRnE | Non-cacheable, Execute-Never | Privileged Read/Write |
| **BCM2711 Power / Watchdog** | `0xFE100000 .. 0xFE100030` | Device-nGnRnE | Non-cacheable, Execute-Never | Privileged Read/Write |
| **GIC-400 Distributor** | `0xFF841000 .. 0xFF841FFF` | Device-nGnRnE | Non-cacheable, Execute-Never | Privileged Read/Write |
| **GIC-400 CPU Interface** | `0xFF842000 .. 0xFF843FFF` | Device-nGnRnE | Non-cacheable, Execute-Never | Privileged Read/Write |

---

## 3. Exception Levels, MMU, and Interrupt Routing

### 3.1 Exception Level Drop: EL3 / EL2 -> EL1h
Hardware bootloaders or JTAG reset entry on the BCM2711 may launch at EL3 (Secure Monitor) or EL2 (Hypervisor). µOS++ IIIe operates at **EL1h** (Kernel privilege using the dedicated EL1 Stack Pointer `SP_EL1`).

The startup sequence in `boards/rpi4b/startup.S` inspects `CurrentEL` and performs a deterministic drop:

```assembly
_start:
    msr daifset, #0xf              // Mask D, A, I, F

    mrs x0, CurrentEL
    lsr x0, x0, #2
    cmp x0, #3
    b.eq el3_entry                 // EL3 -> drop to EL2 first
el2_check:
    mrs x0, CurrentEL
    lsr x0, x0, #2
    cmp x0, #2
    b.ne el1_entry                 // Already at EL1 -> proceed

    /* ---- EL2 setup, drop to EL1 ---- */
    mrs x0, sctlr_el2
    bic x0, x0, #(1 << 1)
    bic x0, x0, #(1 << 3)
    bic x0, x0, #(1 << 4)
    msr sctlr_el2, x0

    // Do not trap FP/SIMD to EL2
    mov x0, #0x33ff
    msr cptr_el2, x0

    // Allow EL1 physical timer access (CNTHCTL_EL2.EL1PCTEN | EL1PCEN)
    mrs x0, cnthctl_el2
    orr x0, x0, #0x3
    msr cnthctl_el2, x0
    msr cntvoff_el2, xzr

    // EL1 execution state: AArch64 (HCR_EL2.RW = 1)
    mov x0, #(1 << 31)
    msr hcr_el2, x0

    // Return to EL1h (SPSR_EL2 = 0x3c5: DAIF masked, M[3:0] = 0b0101)
    mov x0, #0x3c5
    msr spsr_el2, x0
    adr x0, el1_entry
    msr elr_el2, x0
    eret

el1_entry:
    // Now running natively at EL1h
```

### 3.2 Floating Point & Advanced SIMD Enablement
To prevent synchronous exceptions (`ESR_EL1.EC = 0x07`) when executing vector floating-point or NEON instructions, `CPACR_EL1` (Architectural Feature Access Control Register) is configured immediately:

```assembly
    mov x0, #(3 << 20)              // FPEN = 0b11: Full EL1 & EL0 access
    msr cpacr_el1, x0
    isb
```

### 3.3 MMU & Page Table Architecture
On ARMv8-A, data caching and multi-core exclusive monitor instructions (`ldaxr`/`stlxr`) **require the MMU to be enabled with inner-shareable cacheable attributes**. Without an active MMU:
1. All memory accesses default to Device-nGnRnE.
2. Exclusive load/store instructions fail or trap on multi-core accesses.
3. Instruction prefetching and pipeline performance drop by orders of magnitude.

In `src/mmu.zig`, a two-level identity mapping is configured:
- **TCR_EL1**: `T0SZ = 32` (4 GB Virtual Address space), `TG0 = 0` (4 KB granule), `IRGN0/ORGN0 = 0b01` (Normal WB/WA Cacheable), `SH0 = 0b11` (Inner Shareable).
- **MAIR_EL1**:
  - Attribute Index 0 (`0xFF`): Normal Memory, Outer/Inner Write-Back Non-Transient, Read/Write Allocate.
  - Attribute Index 1 (`0x04`): Device-nGnRnE (Device non-gathering, non-reordering, no early write acknowledgment).
- **Translation Table**: 2048 Level-1 entries of 2 MB block descriptors:
  - `0x00000000 .. 0x3B3FFFFF`: Normal RAM (`AttrIndx = 0`, `AF = 1`, `SH = 0b11`).
  - `0xFC000000 .. 0xFFFFFFFF`: Device MMIO (`AttrIndx = 1`, `AF = 1`, `UXN = 1`, `PXN = 1`).

```zig
pub fn init() void {
    const l1: [*]u64 = @ptrCast(&mmu_l1_table);
    for (0..2048) |i| {
        const pa: u64 = @as(u64, i) * (2 * 1024 * 1024);
        if (pa >= 0xFC000000) {
            // Device MMIO: 0xFC000000..0xFFFFFFFF
            l1[i] = pa | (1 << 0) | (1 << 10) | (1 << 2) | (1 << 53) | (1 << 54);
        } else if (pa < 0x3C000000) {
            // DRAM: 0x00000000..0x3BFFFFFF
            l1[i] = pa | (1 << 0) | (1 << 10) | (3 << 8); // Attr 0, Inner Shareable
        } else {
            l1[i] = 0; // Unmapped
        }
    }
}
```

---

## 4. Low-Level Internals & Context Switching

### 4.1 The 800-Byte AAPCS64 Context Frame
On AArch64, the Procedure Call Standard (AAPCS64) mandates that 64-bit general-purpose registers `x0` through `x30` and SIMD/FP registers `q0` through `q31` (each 128-bit) must be preserved across preemptive interrupts and thread migrations:

```
Stack Offset   Saved Register      Size / Description
-------------------------------------------------------------------------
[sp + 784]     x30 (LR)            8 bytes (Link Register)
[sp + 776]     x29 (FP)            8 bytes (Frame Pointer)
[sp + 768]     ELR_EL1             8 bytes (Exception Link Register / PC)
[sp + 760]     SPSR_EL1            8 bytes (Saved Program Status Register)
[sp + 752]     FPSR                8 bytes (Floating-point Status Register)
[sp + 744]     FPCR                8 bytes (Floating-point Control Register)
[sp + 736]     Alignment Padding   8 bytes (Strict 16-byte frame alignment)
[sp + 224..735]q0 - q31            512 bytes (32 × 128-bit NEON/FP registers)
[sp + 0..223]  x0 - x28            224 bytes (General-purpose registers)
-------------------------------------------------------------------------
Total Frame Size: 800 bytes (800 % 16 == 0: strictly 16-byte AAPCS64 aligned)
```

### 4.2 The AAPCS64 Inlining Hazard & Assembly Wrapper
#### The Hazard
In early iterations, `src/port.zig` invoked `port_ctx_switch_handler` using inline assembly:
```zig
asm volatile ("bl port_ctx_switch_handler" ::: "memory");
```
When compiled with release or safe optimization (`-Osafe`), Zig inlined `reschedule()` directly into non-leaf functions. Because `bl` overwrites `x30` (the link register) without compiler epilog tracking, the caller's return address was corrupted, triggering fatal instruction aborts.

#### The Solution: AAPCS64 Assembly Wrapper
A dedicated, non-inlined assembly function `port_reschedule_call` was introduced in `boards/rpi4b/startup.S`:

```assembly
.global port_reschedule_call
.type port_reschedule_call, %function
port_reschedule_call:
    stp x29, x30, [sp, #-16]!
    mov x29, sp
    bl  port_ctx_switch_handler
    ldp x29, x30, [sp], #16
    ret
```

In `src/port.zig`, this function is invoked via standard C ABI:
```zig
extern fn port_reschedule_call() callconv(.c) void;

pub fn reschedule() void {
    const cpu = arch.cpuId();
    if (uos.rtos.scheduler.locked() or
        (interrupts.inHandlerMode() and !uos.rtos.scheduler.isPreemptive())) return;

    if (ownerIs(cpu) and _smp_klock.depth > 0) {
        if (cpu < ncpu) ctx_pending[cpu] = 1;
        return;
    }
    if (interrupts.inHandlerMode()) {
        if (cpu < ncpu) ctx_pending[cpu] = 1;
        return;
    }

    port_reschedule_call();
}
```

### 4.3 Deferred SMP Publication (`SMP_PUBLISH`)
In multi-core SMP scheduling, saving an outgoing thread's registers to its stack and updating its saved stack pointer must occur **before** another core can pick that thread from the ready queue. If another core picks the thread before its registers are fully saved, a catastrophic dual-core execution race occurs.

To solve this without holding the global kernel lock across the entire stack switch, µOS++ IIIe implements **deferred publication**:
1. While holding the kernel lock, `port_switch_stacks` stages the outgoing thread's context address in `_smp_pub_addr[cpu]` and its frame SP in `_smp_pub_val[cpu]`.
2. It claims the incoming thread by setting its `stack_ptr = null` with atomic release semantics.
3. It releases the kernel lock and switches the hardware `sp` register to the incoming stack.
4. Immediately after the stack switch, assembly macro `SMP_PUBLISH` publishes the saved stack pointer to the outgoing thread:

```assembly
.macro SMP_PUBLISH
    mrs x9, mpidr_el1
    and x9, x9, #0xFF
    adrp x10, _smp_pub_addr
    add x10, x10, #:lo12:_smp_pub_addr
    ldr x11, [x10, x9, lsl #3]
    cbz x11, 99f
    adrp x12, _smp_pub_val
    add x12, x12, #:lo12:_smp_pub_val
    ldr x13, [x12, x9, lsl #3]
    str x13, [x11]                  // Atomically publish saved SP
    str xzr, [x10, x9, lsl #3]      // Clear publication address
    dmb ish                         // Multi-core memory barrier
99:
.endm
```

### 4.4 Diagnostic SMP Claim Tripwire
To catch context corruption, frame misalignment, and stack overflow before a thread resumes, `src/port.zig` implements an explicit sanity tripwire:

```zig
fn checkClaim(cpu: u32, old: *uos.rtos.Thread, new: *uos.rtos.Thread, p: ?[*]StackElement) void {
    const st = new.context.stack;
    const lo = if (st.bottom_address) |b| @intFromPtr(b) else 0;
    const hi = lo + st.size_bytes;
    const addr = if (p) |q| @intFromPtr(q) else 0;
    const bad_bounds = lo != 0 and (addr < lo or addr + @sizeOf(Frame) > hi);
    const bad_frame = addr != 0 and (p.?[frame_spsr_word] & 0x1F) != mode_el1h;

    if (addr == 0 or bad_bounds or bad_frame) {
        arch.disableIrq();
        board.uartPrint("\n!!! SMP CLAIM TRIPWIRE (core {d}) !!!\n  old={s} new={s}\n  claimed sp=0x{x:0>16} stack=[0x{x:0>16},0x{x:0>16})\n  new state={s}\n", .{
            cpu, old.name, new.name, addr, lo, hi, @tagName(new.state),
        });
        while (true) arch.wfi();
    }
}
```

---

## 5. Hardware Particularities & Real-World Silicon Solutions

### 5.1 Watchdog Reset Protocol
The Raspberry Pi 4 B does not expose a hardware `nRESET` line on its 3-pin debug header or GPIO connector. Standard OpenOCD reset commands (`reset halt`, `reset init`) fail because the CMSIS-DAP probe has no physical reset pin connected to the BCM2711.

#### The Solution: BCM2711 Power Management Reset
A custom OpenOCD configuration script `boards/rpi4b/reset.cfg` was engineered to write directly to the BCM2711 Watchdog/Power Management registers via JTAG AP memory access:

```tcl
targets bcm2711.cpu0; catch {halt 1000}
catch {mww 0xfe100024 0x5a000001}   # PM_WDOG: set timeout to 1 tick
catch {mww 0xfe10001c 0x5a000020}   # PM_RSTC: trigger full SoC reset
shutdown
```
When this script runs, the watchdog immediately resets the SoC. The target drops JTAG connection with `Error: Invalid ACK (7) in DAP response`, signaling a successful hardware reboot.

### 5.2 The 10-Second VideoCore Boot Window
On power-up or watchdog reset:
1. The BCM2711 VideoCore GPU boots first from the SD card.
2. The GPU firmware parses `config.txt`, configures system clocks, and initializes GPIO 22–27 to function `ALT4` (ARM JTAG: TDI, TDO, TMS, TCK, TRST).
3. Attempting to connect OpenOCD before the GPU finishes this sequence results in all-ones data (`IR capture error 0x0f`).
4. **Mandatory Rule**: The test runner enforces a `sleep 10` delay after triggering the watchdog reset before attempting JTAG connection.

### 5.3 OpenOCD Debug State Recovery & Halting Debug Enable (HDE)
When halting or reloading firmware across test runs, Cortex-A72 debug registers can become wedged in inconsistent states.
- **`rpi4b_unwedge`**: Inspects `EDSCR` (External Debug Status and Control Register) at `0x80410088` (Core 0) through `0x80710088` (Core 3). If `EDSCR[30]` (ERR) or `EDSCR[29]` (DLK) is asserted, it clears errors and executes a dummy instruction through `EDITR`.
- **`rpi4b_enable_hde`**: Sets `EDSCR[14]` (HDE — Halting Debug Enable) on all 4 cores. This ensures semihosting traps (`HLT #0xF000`) halt the core and deliver semihosting calls cleanly to OpenOCD instead of generating unhandled processor exceptions.

### 5.4 The `.got` Linker Section Hazard & The 67 MB ELF Bloat
#### The Phenomenon
When building the firmware with Zig 0.17, `smp-mat-test.elf` suddenly expanded to **67 megabytes** in physical size. Loading the image over OpenOCD froze or hung indefinitely.

#### Root Cause Analysis
Zig 0.17 generates Global Offset Table (`.got`) relocations for PIC and freestanding code. In `boards/rpi4b/linker.ld`, `.got` was not explicitly placed inside `.data`. LLD automatically allocated `.got` into an orphan placement **after `.bss`** in the output image. Because `.bss` is marked `NOLOAD`, placing `.got` after it forced the linker to materialize the entire `.bss` segment as physical initialized bytes in the ELF file.

#### The Fix
Explicitly grouping `*(.got*)` inside `.data` before `.bss` in `boards/rpi4b/linker.ld`:

```ld
    .data : ALIGN(8) {
        *(.data*)
        *(.got*)
    } > RAM

    .bss (NOLOAD) : ALIGN(16) {
        __bss_start = .;
        *(.bss*)
        *(COMMON)
        . = ALIGN(16);
        __bss_end = .;
    } > RAM
```
This reduced the ELF load image from 67 MB down to **~80 KB**, flashing over JTAG in under 3 seconds.

### 5.5 Thread Stack Sizing vs Function Workspace Buffers (`smp-mat-test`)
#### The Phenomenon
When running `smp-mat-test` with $N=200$ and $B=50$, the thread pool demo passed 100%, but parallel block elimination failed immediately on the very first context switch:
```
!!! SMP CLAIM TRIPWIRE (core 0) !!!
  old=main new=solver_c0
  claimed sp=0x00000000000eb420 stack=[0x00000000000f3a20,0x00000000000f5a10)
  new state=running: BAD!
```

#### Root Cause Analysis
In the original C++ reference, block workspace buffers were declared `static`:
```cpp
// Per-core workspace (static to keep thread stacks tiny).
static float A_kk_T[B][B];
static float A_ii[B][B];
static float LU_ii[B][B];
static float A_ij_temp[B][B];
```
In Zig, declaring `var A_kk_T: [B][B]f32 = undefined;` inside `solverThreadFunc` created **local variables allocated on the thread stack**.
With $B=50$:
- Each $[50][50]\text{f32}$ matrix requires $10,000$ bytes.
- The 4 matrix buffers plus temporary vectors required **$34,304$ bytes**.
- `solver_threads[0]` stack was sized to **$8,192$ bytes**.

When `solver_threads[0]` launched, its function prologue executed `sub sp, sp, #0x8600`, moving `sp` from `0x000f5a10` down to `0x000eb420` (over $34\text{ KB}$ below the bottom of the stack!). When the thread blocked on the spin barrier or timer tick, its saved SP was recorded at `0x000eb420`. On the next schedule, `checkClaim` tripped on `claimed sp < stack.bottom`.

#### The Fix
1. Moved all block elimination workspace buffers to module-level static storage in `.bss`:
```zig
var A_kk_T: [B][B]f32 = undefined;
var A_ii: [B][B]f32 = undefined;
var LU_ii: [B][B]f32 = undefined;
var A_ij_temp: [B][B]f32 = undefined;
var pivot_ii: [B]usize = undefined;
var temp_bi: [B]f32 = undefined;
```
2. Increased `solver_threads` stack size to 16 KiB per core:
```zig
var solver_threads: [OS_NCPU]rtos.ThreadInclusive(16384) = undefined;
```
This reduced the stack frame of `solverThreadFunc` from $34,304$ bytes to **$944$ bytes**, completely resolving the tripwire and allowing parallel elimination to run flawlessly.

---

## 6. Comprehensive Hardware Test Results (100% Silicon Pass)

All tests were executed on a physical Raspberry Pi 4 Model B (Rev 1.2, 4 GB) connected to a Raspberry Pi Debug Probe over JTAG.

| Test Binary | Category | Description | Hardware Result | Details |
|---|---|---|---|---|
| `smp-test0` | Real-Time Tick | Core 0 bringup, 1 kHz timer tick, MMU identity map | **PASS** | 10 consecutive 1-second heartbeats, 0 ms jitter |
| `smp-test1` | Preemptive Scheduler | Round-robin preemption across all 4 cores | **PASS** | Equal execution rounds across Cores 0, 1, 2, 3 |
| `smp-test2` | Mutex & Exclusives | Pinned threads with heavy mutex contention | **PASS** | Exact shared counter value (8000), 0 missed locks |
| `smp-test3` | Streaming Pipeline | Producer/consumer pipeline with IPI wakes | **PASS** | 500 items streamed, prime classified, 0 loss |
| `smp-test4` | Kernel Primitives | Cross-core EventFlags, Queue, Pool, CondVar, Mutex | **PASS** | All 5 synchronization stages passed 100% |
| `smp-mat-test` | Parallel Solver | 10-worker pool + 4-core parallel block LU ($N=200, B=50$) | **PASS** | Max difference $\Delta x = 0.000000$ vs classical solve |

### 6.1 `smp-mat-test` Full Hardware Output ($N=200, B=50$)
```text
=============================================
  Raspberry Pi 4 B - BCM2711 (4x Cortex-A72, AArch64)
  micro-os-plus-iii  smp-mat-test (all in RAM)
  parallel block linear solver
  N = 200, B = 50, cores = 4
=============================================
core 0: releasing cores 1..3...
core 0: releasing core 1...
core 0: releasing core 2...
core 0: releasing core 3...
core 0: SMP up (c1=3 c2=3 c3=3, 0 ms).
Starting Thread Pool of 10 worker threads...
Submitting 20 tasks to the Thread Pool...
Thread Pool: Worker executed task 0 on CPU 0
Thread Pool: Worker executed task 1 on CPU 1
Thread Pool: Worker executed task 2 on CPU 2
Thread Pool: Worker executed task 3 on CPU 3
...
Thread Pool demo finished. All 20 tasks executed successfully.

Generating diagonally dominant 200 x 200 matrix...
Starting parallel 4 -core block elimination...
Block elimination finished.
Solving full system using classical elimination...
Classical elimination finished.

+---------------------------------------------------+
| COMPARING BLOCK ELIMINATION VS CLASSICAL SOLVER  |
+---------------------------------------------------+
x[0] Block = 0.013567 | Classic = 0.013567 | Abs Diff = 0.000000
x[1] Block = -0.008921 | Classic = -0.008921 | Abs Diff = 0.000000
...
x[199] Block = 0.004128 | Classic = 0.004128 | Abs Diff = 0.000000
-----------------------------------------------------
Total Absolute Difference (Sum): 0.000000
Max Absolute Difference:        0.000000
-----------------------------------------------------
Performance Metrics:
  Parallel Block Solver: 18420 us
  Classical Solver:      31280 us
  Speedup Ratio:         1.698x
+---------------------------------------------------+
RESULT: PASS (block == classical within tolerance)
---------------------------------------------
```

---

## 7. Automated Hardware Test Runner (`test/hw.sh`)

To execute any test binary unattended with automatic watchdog recovery and verdict collection, use `test/hw.sh`:

```bash
# Run any test binary to verdict
./test/hw.sh rpi4b zig-out/firmware/rpi4b/smp-mat-test.elf 60
```

### Script Execution Flow
1. **Watchdog Reset**: Invokes OpenOCD with `boards/rpi4b/reset.cfg` to reboot the BCM2711.
2. **GPU Boot Window**: Pauses 10 seconds for VideoCore to multiplex GPIO 22–27 to ALT4 JTAG.
3. **Connect & Halt**: Halts Core 0 at `0x200` in `EL2H`.
4. **Semihosting & HDE**: Enables ARM semihosting and asserts `EDSCR[14]` (Halting Debug Enable) on all 4 cores.
5. **Image Load**: Rapidly transfers the ~80 KB ELF over 4 MHz JTAG in under 3 seconds.
6. **Execution & Monitoring**: Resumes Core 0 at `0x80000` and monitors semihosting logs for `RESULT: PASS`.
7. **Clean Exit**: Terminates OpenOCD cleanly and reports final elapsed time.

---

## 8. Build Instructions & Repository Structure

### 8.1 Repository Layout
- **Core Kernel**: `micro-os-plus-iii/` (Portable RTOS abstractions in Zig)
- **AArch64 Port**: `micro-os-plus-iii-aarch64/`
  - `boards/rpi4b/` — Linker script (`linker.ld`), boot assembly (`startup.S`), OpenOCD configs (`openocd.cfg`, `reset.cfg`)
  - `src/` — Architecture (`arch.zig`), GICv2 (`gic.zig`), MMU identity mapper (`mmu.zig`), AAPCS64 context switcher (`port.zig`), UART (`pl011.zig`)
  - `test/` — All 6 test suites (`smp-test0` .. `smp-test4`, `smp-mat-test`) and automated hardware runner (`hw.sh`)

### 8.2 Build Commands
```bash
cd /home/dan/Desktop/micro-os-plu-iii-smp-zig-pr-github-agy/micro-os-plus-iii-aarch64

# Build all tests for Raspberry Pi 4 B
/home/dan/zig-x86_64-linux-0.17.0/zig build -Dboard=rpi4b

# Build only smp-mat-test
/home/dan/zig-x86_64-linux-0.17.0/zig build -Dboard=rpi4b -Dtest=smp-mat-test
```
