# µOS++ IIIe on AArch32 & AArch64: Architectural Feasibility, SMP & AMP Design, and Porting Guide

---

## 1. Executive Summary & Problem Formulation

### 1.1 The Core Question
> **"Is this micro-os Zig port capable of porting the SMP and AMP C++ versions of AArch32 and AArch64?"**

**Answer: Yes, unequivocally.** 

The modern Zig port of **µOS++ IIIe** is not only capable of running both **SMP (Symmetric Multi-Processing)** and **AMP (Asymmetric Multi-Processing)** on **AArch32 (ARMv7-A / ARMv8-A 32-bit)** and **AArch64 (ARMv8-A / ARMv9-A 64-bit)**, but its decoupled compile-time architecture makes these ports substantially cleaner, more deterministic, and less error-prone than their C++ precursors.

In the reference C++ repository, both 32-bit and 64-bit multicore platforms are actively supported:
- `micro-os-plus-iii-aarch32`: Targets quad-core Cortex-A53/A7 platforms (e.g. Raspberry Pi 3B in 32-bit mode, Luckfox Lyra, Rockchip RK3506).
- `micro-os-plus-iii-aarch64`: Targets quad-core ARMv8-A platforms (e.g. Raspberry Pi 3B, Pi Zero 2W, Raspberry Pi 4B with BCM2837 and BCM2711 SoCs).

This document presents the detailed architectural blueprint, formal port contracts, memory models, synchronization primitives, interrupt handling, and concrete implementation strategies for both SMP and AMP on AArch32/AArch64 using Zig.

---

## 2. The Architecture-Agnostic Core (`port_contract.zig`)

The fundamental reason the Zig port seamlessly scales from dual Cortex-M33 microcontrollers up to quad-core 64-bit Cortex-A processors lies in the strict separation between the portable kernel and the machine port.

```
       ┌───────────────────────────────────────────────────────────┐
       │               Portable µOS++ IIIe Core                    │
       │  (Thread, Mutex, CondVar, Sem, Queue, Scheduler Logic)    │
       └─────────────────────────────┬─────────────────────────────┘
                                     │ Validated at Comptime via
                                     │ port_contract.validate(Port)
                                     ▼
       ┌───────────────────────────────────────────────────────────┐
       │                 Machine Port (`uos_port`)                 │
       ├─────────────────────────────┬─────────────────────────────┤
       │ Cortex-M Port (RP2350/F411) │ AArch64 Port (BCM2837/2711) │
       │  - StackElement = u32       │  - StackElement = u64       │
       │  - PSP / MSP Stacks         │  - SP_EL0 / SP_EL1 Stacks   │
       │  - SIO Bus Spinlocks        │  - LDAXR / STLXR Spinlocks  │
       │  - NVIC Interrupts          │  - ARM GICv2/v3 (SGIs/PPIs) │
       └─────────────────────────────┴─────────────────────────────┘
```

### 2.1 The Word Size & Machine Context Abstraction
In [`micro-os-plus-iii/src/port_contract.zig`](file:///home/dan/Desktop/micro-os-plu-iii-smp-zig-pr-github-agy/micro-os-plus-iii/src/port_contract.zig), the machine context is completely parameterized:

```zig
pub const StackElement = if (is_64bit) u64 else u32;
pub const stack_alignment: usize = if (is_64bit) 16 else 8;

pub const Context = struct {
    stack_ptr: ?[*]StackElement = null,
};
```

1. **Word Size Scalability**: On Cortex-M and AArch32, `StackElement` is `u32`. On AArch64, `StackElement` transitions to `u64`. All internal pointer offsets, stack frames, and watermark computations scale automatically via Zig's type system.
2. **16-Byte Stack Alignment Enforcement**: The ARMv8-A 64-bit architecture strictly enforces 16-byte stack pointer alignment in hardware when `SP` is used as a base address in load/store instructions (`SP_EL0` and `SP_EL1`). Setting `stack_alignment = 16` causes the Zig compiler to align all statically allocated `ThreadInclusive` stacks to 16 bytes.
3. **Atomic Context Claiming (`stack_ptr = null`)**:
   In SMP mode, a thread live in CPU registers has its `stack_ptr` set to `null` with atomic release semantics:
   ```zig
   @atomicStore(?[*]StackElement, &thread.context.port.stack_ptr, null, .release);
   ```
   If another core searches the global ready queue, it observes `stack_ptr == null` and cannot schedule the thread. This eliminates dual-core and quad-core double-scheduling races across all architectures.

---

## 3. SMP (Symmetric Multi-Processing) on AArch64 (ARMv8-A 64-Bit)

### 3.1 Architectural Execution Model

```
   Exception Level 0 (EL0)                     Exception Level 1 (EL1)
  ┌─────────────────────────┐               ┌─────────────────────────┐
  │ User Application Thread │               │ µOS++ Kernel Scheduler  │
  │ Stack: SP_EL0           │               │ Stack: SP_EL1           │
  │ Unprivileged Execution  │               │ Privileged OS Execution │
  └────────────┬────────────┘               └────────────▲────────────┘
               │                                         │
               │ Synchronous / Asynchronous Exception   │
               └─────────────────────────────────────────┘
```

1. **Exception Levels & Banked Stacks**:
   - Application threads execute at **EL0** using the unprivileged stack pointer **`SP_EL0`**.
   - The µOS++ kernel, interrupt handlers, and scheduler switch routines execute at **EL1** using the kernel stack pointer **`SP_EL1`**.
2. **Deterministic Preemption**:
   Preemption occurs via asynchronous physical interrupts (IRQ) routed to EL1.

---

### 3.2 AArch64 Context Switching Assembly

The AArch64 instruction set provides a large, orthogonal 64-bit register file ($X0..X30$) and 128-bit SIMD/FPU registers ($V0..V31$).
According to the ARM 64-bit AAPCS (Procedure Call Standard):
- **Callee-saved integer registers**: $X19..X28$, $X29$ (Frame Pointer), and $X30$ (Link Register).
- **Callee-saved SIMD/FPU registers**: $D8..D15$ (the lower 64 bits of $V8..V15$).
- **Caller-saved scratch registers**: $X0..X18$ and $V0..V7, V16..V31$ (saved automatically by C call conventions or by hardware exception entry).

```armasm
.globl port_context_switch
.type port_context_switch, %function
port_context_switch:
    // Arguments:
    //   X0: Pointer to outgoing thread's saved stack pointer (*old_sp)
    //   X1: Incoming thread's saved stack pointer (new_sp)

    // 1. Save callee-saved integer registers in pairs (16-byte aligned)
    stp     x19, x20, [sp, #-16]!
    stp     x21, x22, [sp, #-16]!
    stp     x23, x24, [sp, #-16]!
    stp     x25, x26, [sp, #-16]!
    stp     x27, x28, [sp, #-16]!
    stp     x29, x30, [sp, #-16]!

    // 2. Save callee-saved FPU/NEON registers (64-bit D registers)
    stp     d8,  d9,  [sp, #-16]!
    stp     d10, d11, [sp, #-16]!
    stp     d12, d13, [sp, #-16]!
    stp     d14, d15, [sp, #-16]!

    // 3. Atomically publish outgoing stack pointer
    mov     x9, sp
    str     x9, [x0]                // *old_sp = current SP

    // 4. Switch to incoming stack pointer
    mov     sp, x1                  // SP = new_sp

    // 5. Restore callee-saved FPU/NEON registers
    ldp     d14, d15, [sp], #16
    ldp     d12, d13, [sp], #16
    ldp     d10, d11, [sp], #16
    ldp     d8,  d9,  [sp], #16

    // 6. Restore callee-saved integer registers
    ldp     x29, x30, [sp], #16
    ldp     x27, x28, [sp], #16
    ldp     x25, x26, [sp], #16
    ldp     x23, x24, [sp], #16
    ldp     x21, x22, [sp], #16
    ldp     x19, x20, [sp], #16

    ret                             // Jump to incoming thread's X30 (LR)
```

---

### 3.3 Atomic Spinlocks on ARMv8-A / ARMv9-A

Unlike the RP2350 microcontroller which uses dedicated silicon bus registers (`SIO.SPINLOCK0`), AArch64 systems implement spinlocks in normal memory using architectural exclusive-access load/store instructions or Large System Extensions (LSE) atomics.

#### 3.3.1 Load-Acquire & Store-Release (`ldaxr` / `stlxr`)
ARMv8-A introduces one-way memory barrier instructions directly integrated into exclusive accesses:
- **`ldaxr` (Load-Acquire Exclusive Register)**: Ensures no subsequent memory read or write can be reordered before the lock acquisition.
- **`stlxr` (Store-Release Exclusive Register)**: Ensures all prior memory stores are visible to other cores before the lock release commits.

```armasm
// Recursive Kernel Spinlock Acquire (AArch64)
lock_acquire:
    mov     w1, #1
1:
    ldaxr   w2, [x0]                // Read lock with Acquire semantics
    cbnz    w2, 2f                  // If held (w2 != 0), spin
    stxr    w3, w1, [x0]            // Attempt to claim lock
    cbnz    w3, 1b                  // If store failed, retry
    ret
2:
    wfe                             // Wait-For-Event (power-saving spin)
    b       1b

// Recursive Kernel Spinlock Release (AArch64)
lock_release:
    stlr    wzr, [x0]               // Store zero with Release semantics
    sev                             // Send Event to wake sleeping cores
    ret
```

In Zig, this is expressed directly using `@atomicRmw` and `@cmpxchgWeak` with `.acquire` and `.release` ordering:
```zig
pub fn acquire(lock: *Atomic(u32)) void {
    while (lock.swap(1, .acquire) != 0) {
        while (lock.load(.monotonic) != 0) {
            asm volatile ("wfe");
        }
    }
}

pub fn release(lock: *Atomic(u32)) void {
    lock.store(0, .release);
    asm volatile ("sev");
}
```

---

### 3.4 Interrupt Routing: ARM Generic Interrupt Controller (GIC)

On multicore AArch64 platforms (such as BCM2837 or BCM2711), interrupts are arbitrated by the ARM **Generic Interrupt Controller (GIC)** (typically GICv2 or GICv4):

```
       Core 0                  Core 1                  Core 2                  Core 3
 ┌────────────────┐      ┌────────────────┐      ┌────────────────┐      ┌────────────────┐
 │ CPU Interface  │      │ CPU Interface  │      │ CPU Interface  │      │ CPU Interface  │
 │ (GICC / ICC_*) │      │ (GICC / ICC_*) │      │ (GICC / ICC_*) │      │ (GICC / ICC_*) │
 └───────▲────────┘      └───────▲────────┘      └───────▲────────┘      └───────▲────────┘
         │                       │                       │                       │
 ┌───────┴───────────────────────┴───────────────────────┴───────────────────────┴────────┐
 │                      ARM Generic Interrupt Controller (GIC Distributor)                │
 │  - Software Generated Interrupts (SGI 0..15): Inter-Processor Interrupts (IPI)        │
 │  - Private Peripheral Interrupts  (PPI 16..31): Per-Core Generic Timers (CNTV)        │
 │  - Shared Peripheral Interrupts   (SPI 32..1019): UART, DMA, PCIe, Ethernet           │
 └────────────────────────────────────────────────────────────────────────────────────────┘
```

1. **Software Generated Interrupts (SGIs)**:
   - SGI 0..15 are dedicated to inter-processor communication.
   - Core 0 triggers an IPI on Core 1 by writing to `GICD_SGIR` (GICv2) or `ICC_SGI1R_EL1` (GICv3):
     ```zig
     pub fn ipi(target_cpu: u32) void {
         const sgi_filter = @as(u32, 1) << target_cpu;
         GICD_SGIR.* = (sgi_filter << 16) | RESCHEDULE_SGI_ID;
     }
     ```
2. **Private Peripheral Interrupts (PPIs)**:
   - Per-core virtual and physical timers (`CNTV_TVAL_EL0`) fire as PPIs on their respective cores, enabling clock progression without cross-core bus traffic.

---

### 3.5 MMU & Cache Coherency in SMP
On Cortex-A processors, memory is accessed through multi-level caches (L1 Instruction, L1 Data, unified L2 cache).
In multi-core SMP:
1. **MMU Must Be Enabled**: In ARMv8-A, memory attributes (Cacheability and Shareability) are defined in Translation Table descriptors. If the MMU is disabled, all memory is treated as Device-nGnRnE (strongly ordered), which breaks multicore performance.
2. **Inner Shareable Normal Memory**: The entire RTOS RAM space must be mapped as **Inner Shareable, Normal Cacheable** (`AttrIndx = 1` in `MAIR_EL1`).
3. **Hardware Cache Coherency**: The Snoop Control Unit (SCU) or AMBA ACE/CHI interconnect hardware automatically maintains cache coherency across cores for Inner Shareable memory. Atomic instructions (`ldaxr`/`stlxr`) operate seamlessly across all L1/L2 caches.

---

## 4. SMP on AArch32 (ARMv7-A / ARMv8-A 32-Bit)

AArch32 represents 32-bit Cortex-A platforms (e.g. Cortex-A7, Cortex-A9, Cortex-A15, or Cortex-A53 in 32-bit execution mode).

### 4.1 CPU Modes & Register Banking
Unlike Cortex-M (Thread vs Handler mode) or AArch64 (EL0 vs EL1), AArch32 uses legacy ARM operating modes:
- **User / System Mode**: Unprivileged application threads (`R0..R14`, `PC`, `CPSR`).
- **SVC Mode**: Kernel startup and software interrupts (`R13_svc`, `R14_svc`, `SPSR_svc`).
- **IRQ Mode**: Hardware interrupt handling (`R13_irq`, `R14_irq`, `SPSR_irq`).

### 4.2 AArch32 Context Switching
In AArch32, context switching stores callee-saved registers $\{R4..R11, LR\}$ and VFP/NEON registers $\{D8..D15\}$:

```armasm
.globl port_context_switch
.type port_context_switch, %function
port_context_switch:
    // X0 = &old_sp, R1 = new_sp
    push    {r4-r11, lr}            // Save callee-saved integer registers
    vpush   {d8-d15}                // Save callee-saved VFP/NEON registers
    str     sp, [r0]                // Save outgoing SP
    mov     sp, r1                  // Load incoming SP
    vpop    {d8-d15}                // Restore VFP/NEON registers
    pop     {r4-r11, pc}            // Restore integer registers & return
```

### 4.3 Spinlocks via `ldrex` / `strex`
AArch32 uses 32-bit exclusive load-store primitives combined with explicit memory barriers (`dmb`):
```armasm
spin_lock:
    mov     r1, #1
1:
    ldrex   r2, [r0]
    cmp     r2, #0
    strexeq r2, r1, [r0]
    cmpeq   r2, #0
    bne     1b
    dmb     ish                     // Inner-Shareable Data Memory Barrier
    bx      lr
```

---

## 5. AMP (Asymmetric Multi-Processing) on AArch32 & AArch64

In an **AMP** architecture, cores do not share a single operating system instance or global run queue.

### 5.1 The Two AMP Paradigms

```
  Paradigm A: Homogeneous Multi-Instance AMP            Paradigm B: Heterogeneous Master-Worker AMP
 ┌──────────────────────┬──────────────────────┐      ┌──────────────────────┬──────────────────────┐
 │ Core 0 (AArch64)     │ Core 1 (AArch64)     │      │ Core 0 (AArch64)     │ Core 1 (Cortex-M)    │
 │ µOS++ Instance 0     │ µOS++ Instance 1     │      │ Full µOS++ Kernel    │ Bare-Metal / RTOS    │
 │ Private Ready Queue  │ Private Ready Queue  │      │ Linux / RTOS App     │ Real-Time Control    │
 └──────────┬───────────┴──────────┬───────────┘      └──────────┬───────────┴──────────┬───────────┘
            │                      │                             │                      │
            └───────────┬──────────┘                             └───────────┬──────────┘
                        ▼                                                    ▼
       ┌─────────────────────────────────┐                  ┌─────────────────────────────────┐
       │   Shared Memory IPC Region      │                  │   Shared Memory IPC Region      │
       │   - Lockless SPSC Ring Buffers  │                  │   - OpenAMP / RPMsg Protocol    │
       │   - Hardware Mailbox / Doorbell │                  │   - Hardware Mailbox / Doorbell │
       └─────────────────────────────────┘                  └─────────────────────────────────┘
```

### 5.2 Why This Zig Port Excels at AMP

1. **Zero Shared Kernel Locks**:
   In AMP, each core compiles with `uos_options = .{ .ncpu = 1, .smp = false }`. Each core executes its own independent scheduler with zero lock contention, zero spinlocks, and zero cross-core cache invalidation.
2. **Cache-Line Isolated Shared Memory**:
   Shared inter-core ring buffers can be aligned to the CPU's cache-line boundary ($64$ bytes on AArch64) to prevent false sharing:
   ```zig
   pub const IpcRingBuffer = struct {
       head: Atomic(u32) align(64),
       tail: Atomic(u32) align(64),
       storage: [4096]u8 align(64),
   };

   export var g_shared_ipc: IpcRingBuffer linksection(".shared_sram") = undefined;
   ```
3. **Single Build Graph for Heterogeneous Cores**:
   Zig’s build system (`build.zig`) can cross-compile heterogeneous binaries in a single invocation:
   ```zig
   // 1. Build Cortex-M firmware (Core M)
   const m_core_elf = b.addExecutable(.{
       .name = "firmware-cortexm",
       .root_source_file = b.path("src/m_main.zig"),
       .target = b.resolveTargetQuery(.{
           .cpu_arch = .thumb,
           .cpu_model = .{ .explicit = &std.Target.arm.cpu.cortex_m4 },
           .os_tag = .freestanding,
       }),
   });

   // 2. Build AArch64 firmware (Core A)
   const a_core_elf = b.addExecutable(.{
       .name = "firmware-aarch64",
       .root_source_file = b.path("src/a_main.zig"),
       .target = b.resolveTargetQuery(.{
           .cpu_arch = .aarch64,
           .os_tag = .freestanding,
       }),
   });
   ```

---

## 6. Implementation Blueprint & File Layout

To create an AArch64 or AArch32 port in the Zig repository, the required structure mirrors `micro-os-plus-iii-cortexm`:

```text
micro-os-plus-iii-aarch64/
├── build.zig                  # Zig build graph for AArch64 targets
├── build.zig.zon              # Package manifest and dependencies
├── src/
│   ├── port.zig               # Satisfies port_contract.zig (scheduler, IPI, ticks)
│   ├── arch.zig               # AArch64 system register access (EL0/EL1, DAIF, CNTV)
│   ├── context.zig            # Context frame layout and contextCreate()
│   ├── gic.zig                # ARM GICv2/v3 driver (Distributor & CPU Interface)
│   ├── mmu.zig                # Flat identity translation tables (TTBR0_EL1)
│   └── startup.S              # Reset entry, EL3/EL2 drop to EL1, vector table
└── test/
    ├── rpi3b/                 # Raspberry Pi 3B hardware tests
    └── rpi4b/                 # Raspberry Pi 4B hardware tests
```

---

## 7. Comparative Architectural Matrix

| Architectural Feature | Cortex-M Port (RP2350) | Cortex-M Port (STM32F411) | AArch32 Port (Cortex-A7) | AArch64 Port (Cortex-A53) |
|---|---|---|---|---|
| **CPU Architecture** | ARMv8-M (32-bit) | ARMv7E-M (32-bit) | ARMv7-A (32-bit) | ARMv8-A (64-bit) |
| **SMP Support** | Dual-core SMP | Single-core | Quad-core SMP | Quad-core SMP |
| **AMP Support** | Homogeneous AMP | N/A | Homogeneous / Hetero | Homogeneous / Hetero |
| **Pointer Size** | 32-bit (`u32`) | 32-bit (`u32`) | 32-bit (`u32`) | **64-bit (`u64`)** |
| **Stack Alignment** | 8 bytes | 8 bytes | 8 bytes | **16 bytes (Strict)** |
| **Cross-Core Reschedule**| SIO FIFO (IRQ 25) | N/A | GIC SGI (`GICD_SGIR`) | GIC SGI (`ICC_SGI1R_EL1`) |
| **Spinlock Hardware** | RP2350 SIO Spinlock | N/A (BASEPRI lock) | `ldrex` / `strex` | `ldaxr` / `stlxr` / LSE |
| **Interrupt Controller** | Dual Private NVICs | Single NVIC | GICv2 / GIC-400 | GICv2 / GICv3 / GICv4 |
| **MMU Requirement** | None (Physical) | None (Physical) | Required for SMP Caching| Required for SMP Caching |

---

## 8. Conclusion & Recommendations

1. **SMP Feasibility (AArch32 & AArch64)**:
   The existing `micro-os-plus-iii` Zig core is **100% prepared** for AArch32 and AArch64 SMP. Implementing the machine port requires only creating `port.zig`, writing an AArch64/AArch32 context switch, and driving the ARM GIC and Generic Timer.
2. **AMP Feasibility (AArch32 & AArch64)**:
   AMP is already supported out-of-the-box by instantiating `uos_options.smp = false` per core and placing lock-free SPSC queues in shared memory.
3. **Recommendation**:
   Begin with an **AArch64 SMP port for the Raspberry Pi 3B / QEMU `virt` machine**. The clean 64-bit orthogonal register set and LSE atomic instructions make AArch64 faster and simpler to implement than legacy 32-bit ARM modes.
