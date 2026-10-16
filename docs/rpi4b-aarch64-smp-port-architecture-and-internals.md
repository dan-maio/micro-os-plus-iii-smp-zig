# µOS++ IIIe Zig Port: AArch64 SMP Architecture, Internals & Hardware Particularities

---

## 1. Executive Summary & Architectural Overview

### 1.1 Purpose & Scope
**µOS++ IIIe** is a real-time micro-kernel designed by Liviu Ionescu, architected for embedded systems requiring strict deterministic scheduling, zero hidden allocations, and formal architectural separation between portable kernel abstractions and target hardware ports.

This document serves as the authoritative technical reference for the **64-bit Arm (AArch64 / ARMv8-A) SMP architecture port** implemented in idiomatic **Zig (0.17.0)**. The primary target hardware platform is the **Raspberry Pi 4 Model B**, powered by the **Broadcom BCM2711 SoC with four ARM Cortex-A72 cores**.

The port runs the 16 tests of the C++ `micro-os-plus-iii-aarch64` rpi4b board (`test/rpi4b/`), as faithful Zig ports: the same banners and lines, the same structure and verdict; the deviations are stated in each test's `main.zig` and in §6. All 16 pass on a physical Raspberry Pi 4 B, over OpenOCD and a CMSIS-DAP probe on JTAG (§6, §7):

1. `smp-test0` — core 0 bring-up: the PL011 console, the MMU, the 1 kHz generic timer tick, one thread sleeping (10 heartbeats).
2. `smp-test1` — semaphore ping-pong between cores 0 and 1, a logger on core 2.
3. `smp-test2` — lock coherency: one worker per core, a counter under one mutex (8000 updates).
4. `smp-test3` — message queue producer (core 0) and consumer (core 1), the rpi4b `g_running` stop.
5. `smp-test4` — load balancing: 8 workers without affinity spread over the 4 cores.
6. `smp-mat-test` — a 10-worker thread pool demo and the parallel block solver ($N=120, B=20$) against a classical solve.
7. `smp-pro-cons-test` — producers and consumers over every kernel object.
8. `mutex-stress`, `rtos-apis`, `cmsis-os-validator` — the kernel's harness suites, run as the C++ rpi4b harness platform runs them (4 cores, an 8192-element main stack).
9. `sd_test`, `smp-num-test`, `smp-pipeline-test`, `smp-mat-sdcard-test` — the SD card (EMMC2) and FatFs on its existing FAT32 volume, files in `/tests` (§5.11).
10. `smp-mem-test`, `smp-mem-inter-test` — 20 threads allocating, writing and checking blocks of up to 512 MB in the RAM above 1 GB, with MMU guard pages and canaries.

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

In `src/mmu.zig` (`buildTables()`), the 4 GB identity map uses the 4 KB granule:
- **TCR_EL1**: `T0SZ = 32` (4 GB virtual address space, the walk starts at level 1), `TG0 = 0` (4 KB granule), Normal WB/WA cacheable walks, Inner Shareable.
- **MAIR_EL1**:
  - Attribute Index 0 (`0xFF`): Normal Memory, Outer/Inner Write-Back Non-Transient, Read/Write Allocate.
  - Attribute Index 1 (`0x04`): Device-nGnRnE (Device non-gathering, non-reordering, no early write acknowledgment).
- **Level 1**: four 1 GB entries, each pointing to a level-2 table of 2 MB entries:
  - `l1[0]` → `l2_low`: `0x00000000 .. 0x3B3FFFFF` Normal RAM blocks (Inner Shareable); `0x3B400000 .. 0x3FFFFFFF` (the VideoCore's memory) invalid.
  - `l1[1]`, `l1[2]` → `l2_hi`: `0x40000000 .. 0xBFFFFFFF`, every 2 MB entry a level-3 table whose 4 KB pages start **invalid** (the high-memory region of §5.7).
  - `l1[3]` → `l2_high`: `0xC0000000 .. 0xFBFFFFFF` the rest of the high-memory region (level-3 tables, as above), `0xFC000000 .. 0xFFFFFFFF` Device blocks (`AttrIndx = 1`, `PXN = UXN = 1`).

```zig
// First GB: RAM up to the VideoCore memory
var i: usize = 0;
while (i < RAM_ENTRIES) : (i += 1) {
    l2_low[i] = makeBlock(@as(u64, i) * BLOCK_2M, ATTR_IDX_NORMAL, PTE_SH_IS);
}
// Last GB: devices from 0xFC000000
i = 0;
while (i < 512) : (i += 1) {
    const pa = HIGH_GB + @as(u64, i) * BLOCK_2M;
    if (pa >= DEVICE_START) l2_high[i] = makeBlock(pa, ATTR_IDX_DEVICE, PTE_SH_NONE) | PTE_PXN | PTE_UXN;
}
// High memory: 1504 level-3 tables, all pages invalid until mmu_hi_map()
...
l1[0] = @intFromPtr(&l2_low[0]) | PTE_VALID | PTE_TABLE;
l1[1] = @intFromPtr(&l2_hi[0][0]) | PTE_VALID | PTE_TABLE;
l1[2] = @intFromPtr(&l2_hi[1][0]) | PTE_VALID | PTE_TABLE;
l1[3] = @intFromPtr(&l2_high[0]) | PTE_VALID | PTE_TABLE;
```

---

## 4. Low-Level Internals & Context Switching

### 4.1 The 800-Byte AAPCS64 Context Frame
A preempted thread can be interrupted anywhere and resumed on another core, so the frame holds the whole register file: the general-purpose registers `x0` through `x30`, the exception state, and the SIMD/FP registers `q0` through `q31` (each 128-bit). The layout is `Frame` in `src/port.zig`, checked at compile time against `boards/rpi4b/startup.S`:

```
Stack Offset     Saved Register      Size / Description
-------------------------------------------------------------------------
[sp + 288..799]  q0 - q31            512 bytes (32 × 128-bit NEON/FP registers)
[sp + 280]       Alignment Padding   8 bytes (16-byte alignment of the q block)
[sp + 272]       FPCR                8 bytes (Floating-point Control Register)
[sp + 264]       FPSR                8 bytes (Floating-point Status Register)
[sp + 256]       ELR_EL1             8 bytes (Exception Link Register / PC)
[sp + 248]       SPSR_EL1            8 bytes (Saved Program Status Register)
[sp + 240]       x30 (LR)            8 bytes (Link Register)
[sp + 0..239]    x0 - x29            240 bytes (General-purpose registers, x29 the frame pointer)
-------------------------------------------------------------------------
Total Frame Size: 800 bytes (800 % 16 == 0: 16-byte aligned)
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

### 5.5 Thread Stack Sizing (`smp-mat-test`, `smp-mat-sdcard-test`)
#### The phenomenon
`smp-mat-test` hung on the board right after its thread pool demo: all 20 tasks ran, "Thread Pool demo finished" never came, and all four cores were idle in their idle threads.

#### Root cause
Halted over JTAG, the system clock was still counting, but the only node in its timeout list (main's 10 ms sleep) was garbage: its `next` pointed into `pool_stacks[0]`, its timestamp 400 s in the future. `main_thread_storage` ends exactly where `pool_stacks` begins. A pool worker, on the C++ test's 512-element stack (4 KiB on AArch64), overflowed downward into the top of main's stack while printing: Zig's `std.fmt` in safe mode needs far more stack than C++'s `vsnprintf()`. Main's sleeping timeout node was overwritten while linked, so main never woke.

#### The fix
The pool and solver stacks of both matrix tests are 2048 elements (16 KiB), not C++'s 512 and 1024: a stated deviation. The solvers' block workspaces are module-level statics, as in C++ (a local `[B][B]f32` workspace on a thread stack overflowed it in an earlier version of the port, with $B=50$).

### 5.6 `c_printf.c` Format Parser & Arm CMSIS-RTOS Validator
The Arm CMSIS-RTOS Validator prints test assertion lines with `PRINT(("TEST %02d: %-32s ", num, fn));`. The initial minimal `c_printf.c` implementation lacked support for flags (`-`, `0`, `+`, `#`) and numeric field widths (`32`, `2`). This caused format strings to emit `%02d` and `%-32s` literally and misaligned `va_arg` stack reads.
A complete `vsnprintf` engine was implemented in `src/c_printf.c`, handling all standard C11 width, precision, flag, and length modifiers (`hh`, `h`, `l`, `ll`, `z`), enabling the CMSIS-RTOS Validator suite to execute seamlessly with perfectly formatted tabular reporting.

### 5.7 Dynamic High-Memory Mapping (`mmu_hi`), L3 Page Tables, and `at s1e1r` Probe Checks
The Raspberry Pi 4 Model B exposes up to 3008 MB of RAM above the first 1 GB boundary (`0x40000000 .. 0xFC000000`).
1. **Dynamic Page Management**: At boot, Level-1 and Level-2 translation tables map the high-memory region through 1,504 Level-3 page tables, with all 4 KB pages marked **invalid**.
2. **On-Demand Mapping & Invalidation**:
   - `mmu_hi_map(va, bytes, 1)` dynamically maps allocated pages with Inner-Shareable, Cacheable, Non-Executable attributes (`PTE_VALID | PTE_L3_PAGE | PTE_AF | ATTR_IDX_NORMAL | PTE_SH_IS | PTE_PXN | PTE_UXN`).
   - `mmu_hi_map(va, bytes, 0)` unmaps pages on free and executes inner-shareable TLB invalidation (`dsb ishst; tlbi vmalle1is; dsb ish; isb`).
3. **Non-Faulting Address Translation Probes**:
   To verify guard pages without taking data aborts, `mmu_hi_probe(va)` executes the AArch64 Stage-1 EL1 Read translation instruction:
   ```zig
   asm volatile (
       \\mrs %[daif], daif
       \\msr daifset, #3
       \\at s1e1r, %[va]
       \\isb
       \\mrs %[par], par_el1
       \\msr daif, %[daif]
   );
   ```
   If `PAR_EL1` bit 0 is 1, the translation faulted (unmapped page); if 0, the page is valid.

### 5.8 Hardware ARMv8-A CRC32 Acceleration (`crc32x` / `crc32b`)
In `smp-mem-inter-test`, 20 threads exchange large memory blocks across 4 cores in a ring and verify data integrity via CRC32 checksums. Rather than software bit-loop algorithms, the implementation leverages dedicated Cortex-A72 hardware instructions:
- `crc32x %[res:w], %[crc:w], %[data]` (64-bit word accumulator)
- `crc32b %[res:w], %[crc:w], %[data:w]` (8-bit byte accumulator)
This accelerates checksum computation by over $25\times$, allowing 100+ megabytes of RAM to be checksummed in milliseconds.

### 5.9 Dynamic Memory Heap Sizing (`dynamic_memory_size_bytes`)
The free store is a static 8 MB buffer (`dynamic_memory_size_bytes = 8 * 1024 * 1024`): the tests allocate their pattern files (`sd_test`, up to 300 KB), queues and pool threads from it.

### 5.10 The Semihosting Console: Verdict Lines Only
As the C++ rpi4b hardware build (`test/boards/rpi4b/include/uart.hpp`, `mirror_verdict()`), the console goes to the UART, and only a line holding `RESULT`, `FAIL` or `FATAL` (with the rest of that line when it is printed in pieces) is mirrored to semihosting, which is what the runner reads. Two reasons, both measured in C++: a semihosting call costs seconds with this probe, and OpenOCD 0.12 does not resume cores 1–3 after a semihosting call on this board. A line mirrored from core 1–3 stops that core: with every line mirrored, `smp-test2` deadlocked as soon as a worker on core 2 printed while holding the counter mutex. The full console is the UART's.

### 5.11 The SD Card: EMMC2 and FatFs
`drivers/sd.zig` is the C++ `drivers/src/sd.cpp` for this board: a polled SDHCI driver on EMMC2 (0xFE340000), PIO through the buffer data port, no DMA and no interrupts (CMD0, CMD8, ACMD41, CMD2, CMD3, CMD9, CMD7, ACMD6; single and multi-block transfers with CMD12). As the C++ `HW_BUILD` tests, the card is the Pi's boot card and is never formatted: `drivers/fatfs.zig` (the C++ `diskio_sd.cpp` and `fatfs_hw.cpp`, shared with the AArch32 port) mounts its existing FAT32 volume with FatFs R0.15a (the C `ff.c`, unchanged, `FF_USE_MKFS 0`) and keeps every test file in `/tests`.

---

## 6. Hardware Test Results

All 16 tests, run on 2026-10-16 on a Raspberry Pi 4 Model B, Raspberry Pi Debug Probe (CMSIS-DAP) on JTAG, `test/run-all.sh`, with the `exit()` / `_Exit()` end of run. The time is the whole run: the OpenOCD watchdog reset, 10 s of boot, the load and the test.

| Test | From (C++ `test/rpi4b/`) | Result | Time |
|---|---|---|---|
| `smp-test0` | `smp_test0` | **PASS** | 23 s |
| `smp-test1` | `smp_test1` | **PASS** | 24 s |
| `smp-test2` | `smp_test2` | **PASS** | 14 s |
| `smp-test3` | `smp_test3` | **PASS** | 25 s |
| `smp-test4` | `smp_test4` (load balancing) | **PASS** | 23 s |
| `smp-mat-test` | `smp-mat-test` ($N=120, B=20$) | **PASS** | 15 s |
| `smp-pro-cons-test` | `smp-pro-cons-test` | **PASS** | 20 s |
| `mutex-stress` | harness suite (30 s) | **PASS** | 44 s |
| `rtos-apis` | harness suite | **PASS** | 23 s |
| `cmsis-os-validator` | harness suite | **PASS** | 28 s |
| `sd_test` | `sd_test` (FatFs, `/tests`) | **PASS** | 19 s |
| `smp-num-test` | `smp-num-test` (FatFs, `tests/num.txt`) | **PASS** | 82 s |
| `smp-pipeline-test` | `smp-pipeline-test` (FatFs, `tests/pipe.dat`) | **PASS** | 46 s |
| `smp-mat-sdcard-test` | `smp-mat-sdcard-test` ($N=200, B=20$) | **PASS** | 16 s |
| `smp-mem-test` | `smp_mem_test` | **PASS** | 48 s |
| `smp-mem-inter-test` | `smp_mem_inter_test` (15 operations per thread, C++ 30) | **PASS** | 106 s |

Deviations from C++, each stated in its test: the matrix tests' pool and solver stacks (§5.5); `smp-mem-inter-test`'s operation count (every run must end within 3 minutes); `smp-num-test` formats its floating-point line with `std.fmt` (the kernel's `printf` has no floating point); the kernel prints its startup banner and creates the secondary cores' idle threads itself.

The OpenOCD logs (`zig-out/hw-logs/rpi4b/<test>.log`) hold the verdict line only (§5.10); the console of a run is on the UART.

---

## 7. The Hardware Test Runner (`test/hw.sh`, `test/run-all.sh`)

```bash
bash test/hw.sh rpi4b zig-out/firmware/rpi4b/smp-test2.elf 180   # one test
test/run-all.sh                                                   # all, with a verdict table
test/run-all.sh smp-test2 sd_test                                 # some
```

### Script Execution Flow
1. **Watchdog reset**: OpenOCD with `boards/rpi4b/reset.cfg` reboots the BCM2711 (no reset line on the debug header).
2. **Boot window**: 10 seconds for the firmware to boot from the SD card and mux GPIO 22–27 to JTAG; cores 1–3 wait in the armstub8 spin table.
3. **Connect and halt**: core 0 halts at `0x200` in EL2h.
4. **Semihosting and HDE**: semihosting enabled on the 4 cores, `EDSCR[14]` (halting debug enable) set.
5. **Load**: `load_image` of the ELF.
6. **Run**: core 0 resumes at `0x80000`; the runner follows the semihosting log until `RESULT: PASS` or `RESULT: FAIL`, at most 180 s per test.

---

## 8. Build Instructions & Repository Structure

### 8.1 Repository Layout
- **Kernel**: `../micro-os-plus-iii/`.
- **AArch64 port**: `micro-os-plus-iii-aarch64/`
  - `boards/rpi4b/`: `board.zig` (PL011, LED, secondary release), `startup.S` (EL drop, vectors, context switch, IRQ entry), `linker.ld`, `openocd.cfg`, `reset.cfg`
  - `src/`: `arch.zig`, `gic.zig`, `mmu.zig` (the identity map and the high-memory mapper), `port.zig` (the port contract), `semihosting.zig`, `faults.zig`, `c_printf.c` (the `printf` family for the C sources)
  - `drivers/`: `sd.zig` (EMMC2), `fatfs.zig`, `ff_api.h` and `fatfs/` (FatFs R0.15a)
  - `test/`: the 16 tests, `board.zig`, `start.zig`, `hw.sh`, `run-all.sh`

### 8.2 Build Commands
```bash
cd micro-os-plus-iii-aarch64
zig build                      # every test for the Raspberry Pi 4 B
zig build -Dtest=smp-mat-test  # one test
```
