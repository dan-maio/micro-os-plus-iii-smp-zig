# µOS++ IIIe (Zig) — Complete Guide to Adding Architectures & Boards, the Build System, and Testing (QEMU, Hardware & OpenOCD)

**Author:** Internal Engineering Documentation  
**Date:** October 2026  
**Target Toolchain:** Zig `0.17.0` (`aarch64`, `arm`, `thumb`, `x86_64`)  
**Scope:** Portable Kernel (`micro-os-plus-iii`) & Architecture Ports (`cortexm`, `aarch32`, `aarch64`, `posix-arch`)

---

## Table of Contents

1. [System Overview & Repository Ecosystem](#1-system-overview--repository-ecosystem)
2. [How to Add a New Architecture Port](#2-how-to-add-a-new-architecture-port)
   - [2.1 Folder Hierarchy of an Architecture Repository](#21-folder-hierarchy-of-an-architecture-repository)
   - [2.2 Files Needed & Their Responsibilities](#22-files-needed--their-responsibilities)
   - [2.3 Implementing the Compile-Time Port Contract (`port_contract.zig`)](#23-implementing-the-compile-time-port-contract-port_contractzig)
   - [2.4 Context Switching & Interrupt Handling Plumbing](#24-context-switching--interrupt-handling-plumbing)
3. [How to Add a Specific Board Within an Architecture](#3-how-to-add-a-specific-board-within-an-architecture)
   - [3.1 Board Folder Hierarchy (`boards/<board_name>/`)](#31-board-folder-hierarchy-boardsboard_name)
   - [3.2 Step 1: Hardware Abstraction (`board.zig`)](#32-step-1-hardware-abstraction-boardzig)
   - [3.3 Step 2: Early Boot & Exception Vectors (`startup.S`)](#33-step-2-early-boot--exception-vectors-startups)
   - [3.4 Step 3: Memory Map & Linker Script (`linker.ld`)](#34-step-3-memory-map--linker-script-linkerld)
   - [3.5 Step 4: OpenOCD Target & Reset Configs (`openocd.cfg`, `reset.cfg`)](#35-step-4-openocd-target--reset-configs-openocdcfg-resetcfg)
   - [3.6 Step 5: Registering the Board in `build.zig` and `test/hw.sh`](#36-step-5-registering-the-board-in-buildzig-and-testhwsh)
   - [3.7 Note on MicroZig-Based Boards (`micro-os-plus-iii-cortexm`)](#37-note-on-microzig-based-boards-micro-os-plus-iii-cortexm)
4. [How the Build System Works in Detail](#4-how-the-build-system-works-in-detail)
   - [4.1 Build Files & Locations](#41-build-files--locations)
   - [4.2 Bidirectional Module Dependency Graph](#42-bidirectional-module-dependency-graph)
   - [4.3 Compile-Time Kernel Configuration (`uos_options`)](#43-compile-time-kernel-configuration-uos_options)
   - [4.4 Build CLI Options (`-D` Flags)](#44-build-cli-options--d-flags)
   - [4.5 Compiler Options, Targets, CPU Models & Linker Settings](#45-compiler-options-targets-cpu-models--linker-settings)
   - [4.6 Libraries, C API, CMSIS-RTOS v1, Freestanding libc & Drivers](#46-libraries-c-api-cmsis-rtos-v1-freestanding-libc--drivers)
   - [4.7 Build Commands in Clear (User CLI & Underlying Compiler Invocations)](#47-build-commands-in-clear-user-cli--underlying-compiler-invocations)
5. [How Tests Are Organized and Executed](#5-how-tests-are-organized-and-executed)
   - [5.1 Two-Tier Test Architecture: `micro-os-plus-iii` vs `<architecture>/test`](#51-two-tier-test-architecture-micro-os-plus-iii-vs-architecturetest)
   - [5.2 Portable Kernel Tests in `micro-os-plus-iii`](#52-portable-kernel-tests-in-micro-os-plus-iii)
   - [5.3 Architecture & Board Tests in `<architecture>/test/`](#53-architecture--board-tests-in-architecturetest)
   - [5.4 Running Tests in Clear: Host & POSIX Native Commands](#54-running-tests-in-clear-host--posix-native-commands)
   - [5.5 Running Tests in Clear: QEMU Emulation Commands](#55-running-tests-in-clear-qemu-emulation-commands)
   - [5.6 Running Tests in Clear: Physical Hardware & OpenOCD Commands](#56-running-tests-in-clear-physical-hardware--openocd-commands)

---

## 1. System Overview & Repository Ecosystem

The Zig port of **µOS++ IIIe** separates the portable, architecture-independent RTOS kernel from the architecture and board support packages. Each architecture lives in its own sibling Git repository alongside the core kernel:

```text
┌────────────────────────────────────────────────────────────────────────────┐
│                           Workspace Ecosystem                              │
├─────────────────────────────┬──────────────────────────────────────────────┤
│ micro-os-plus-iii/          │ Portable RTOS kernel, C/CMSIS-RTOS v1 APIs,  │
│  (Core Kernel Package)      │ memory allocators, and shared test suites    │
├─────────────────────────────┴──────────────────────────────────────────────┤
│                   ▲                                    │                   │
│     @import("uos")│          port_contract.validate()  │@import("uos_port")│
│                   │                                    ▼                   │
├───────────────────┴────────────────────────────────────┴───────────────────┤
│                     Sibling Architecture Repositories                      │
│                                                                            │
│  ┌──────────────────────────┐  ┌────────────────────────────────────────┐  │
│  │ micro-os-plus-iii-       │  │ ARMv6-M / ARMv7-M / ARMv8-M Port       │  │
│  │ cortexm/                 │  │ • RP2350 Pico 2 (2x Cortex-M33 SMP)    │  │
│  │                          │  │ • RP2040 Pico   (2x Cortex-M0+ SMP)    │  │
│  │                          │  │ • STM32F411/412 (Single Cortex-M4F)    │  │
│  └──────────────────────────┘  └────────────────────────────────────────┘  │
│  ┌──────────────────────────┐  ┌────────────────────────────────────────┐  │
│  │ micro-os-plus-iii-       │  │ ARMv7-A (AArch32) SMP Port             │  │
│  │ aarch32/                 │  │ • Luckfox Lyra RK3506 (3x Cortex-A7)   │  │
│  └──────────────────────────┘  └────────────────────────────────────────┘  │
│  ┌──────────────────────────┐  ┌────────────────────────────────────────┐  │
│  │ micro-os-plus-iii-       │  │ ARMv8-A (AArch64) SMP Port             │  │
│  │ aarch64/                 │  │ • Raspberry Pi 4 B BCM2711 (4x A72)    │  │
│  └──────────────────────────┘  └────────────────────────────────────────┘  │
│  ┌──────────────────────────┐  ┌────────────────────────────────────────┐  │
│  │ micro-os-plus-iii-       │  │ Synthetic POSIX SMP Port (Linux Host)  │  │
│  │ posix-arch/              │  │ • pthreads + ucontext + POSIX timers   │  │
│  └──────────────────────────┘  └────────────────────────────────────────┘  │
└────────────────────────────────────────────────────────────────────────────┘
```

Key architectural principles:

1. **The kernel never builds standalone firmware on its own**: Just like the C++ edition, `micro-os-plus-iii` is imported as a Zig package dependency by an architecture port (or user application).
2. **Mutual compile-time binding (`uos` ↔ `uos_port`)**: The kernel imports the architecture port as `@import("uos_port")`, and the port imports the kernel as `@import("uos")`. They are wired together in `build.zig` via `uos_build.createModule()`.
3. **Compile-time contract verification**: The kernel validates every declaration of `uos_port` at compile time via `src/port_contract.zig`.

---

## 2. How to Add a New Architecture Port

To support a new CPU architecture (for example, `riscv64`, `aarch64`, or `xtensa`), you create a new sibling repository named `micro-os-plus-iii-<arch>`.

### 2.1 Folder Hierarchy of an Architecture Repository

Below is the complete, canonical directory hierarchy for a bare-metal architecture port (modeled on `micro-os-plus-iii-aarch64` and `micro-os-plus-iii-aarch32`):

```text
micro-os-plus-iii-<arch>/
├── build.zig.zon              # Package manifest: depends on ../micro-os-plus-iii
├── build.zig                  # Build graph: targets, boards, modules, runners
├── README.md                  # Architecture port overview & quick-start guide
├── LICENSE                    # MIT License
├── include/                   # Optional C headers for C-based test suites
│   └── cmsis-plus/
│       └── os-app-config.h    # C configuration header bridged to C tests
├── src/                       # Architecture port layer (shared across boards)
│   ├── port.zig               # Root of `uos_port` — implements port_contract
│   ├── arch.zig               # Inline asm: barriers, IRQ mask, timer & CPU ID
│   ├── gic.zig                # Interrupt controller driver (GIC / PLIC / NVIC)
│   ├── mmu.zig                # MMU / MPU page tables & cache maintenance
│   ├── semihosting.zig        # Trap interface (SYS_WRITE0, SYS_EXIT)
│   ├── faults.zig             # Exception syndrome decoder & crash register dump
│   └── c_printf.c             # Optional freestanding C11 printf/vsnprintf
├── drivers/                   # Optional storage/peripheral drivers for I/O tests
│   ├── sd.zig                 # SD/MMC block device driver (or RAM-disk)
│   └── flatfs.zig             # FlatFs / FatFs filesystem layer over `sd.zig`
├── boards/                    # One subdirectory per supported hardware board
│   └── <board_name>/          # e.g., rpi4b, luckfox-lyra
│       ├── board.zig          # `uos_board` root: MMIO, UART, LED, SMP release
│       ├── startup.S          # Reset `_start`, EL drop, vectors, switch asm
│       ├── linker.ld          # RAM origin, .text.boot, .data/.got, .bss, stacks
│       ├── openocd.cfg        # OpenOCD JTAG/SWD probe, target & debug hooks
│       └── reset.cfg          # OpenOCD hardware/watchdog reset script
└── test/                      # Test scaffolding and per-test applications
    ├── start.zig              # Firmware root: wires options, panic, app.main()
    ├── board.zig              # `board` helper: console lock, SMP join, hw_result
    ├── hw.sh                  # Automated OpenOCD runner & semihosting monitor
    ├── smp-test0/
    │   └── main.zig           # Test 0: Single-core bringup, UART, MMU, 1kHz tick
    ├── smp-test1/
    │   └── main.zig           # Test 1: Multi-core SMP bringup & preemption
    ├── smp-test2/
    │   └── main.zig           # Test 2: SMP mutex stress & atomic exclusives
    ├── smp-test3/
    │   └── main.zig           # Test 3: Cross-core message queue pipeline
    ├── smp-test4/
    │   └── main.zig           # Test 4: EventFlags, MemPool, CondVar, Semaphores
    └── ...                    # Matrix, SD card, high-memory & validator suites
```

---

### 2.2 Files Needed & Their Responsibilities

| File Path | Module Name | Role & Contents |
|---|---|---|
| `build.zig.zon` | *(manifest)* | Declares package metadata and `.micro_os_plus_iii = .{ .path = "../micro-os-plus-iii" }`. |
| `build.zig` | *(build script)* | Defines `BoardId`, `boards`, `tests`, `addFirmware()`, ELF installation (`zig-out/firmware/<board>/<test>.elf`), raw binary `objcopy` (`.img`), and `run` step. |
| `src/port.zig` | `uos_port` | Implements every symbol required by `micro-os-plus-iii/src/port_contract.zig`. Imports `uos` and `uos_board`. |
| `src/arch.zig` | *(internal)* | Wraps CPU instructions (`dsb`, `dmb`, `isb`, `wfi`, `wfe`, `sev`, IRQ enable/disable, CPU ID read from `MPIDR_EL1` / `mhartid`, hardware counter read). |
| `src/gic.zig` | *(internal)* | Initializes the interrupt controller distributor and per-CPU interfaces; routes the timer PPI and Software Generated Interrupts (SGI) for SMP reschedule IPIs. |
| `src/mmu.zig` | *(internal)* | Builds identity-mapped translation tables (Normal WB/WA Inner-Shareable for RAM, Device-nGnRnE for MMIO) and exports `mmu_init` and `mmu_enable` to `startup.S`. |
| `src/semihosting.zig` | *(internal)* | Implements buffered semihosting output (`SYS_WRITE0`) and target termination (`SYS_EXIT` with `ADP_Stopped_ApplicationExit = 0x20026`) so OpenOCD/QEMU receive test verdicts. |
| `src/faults.zig` | *(internal)* | Exports `uos_fault_handler` called by `startup.S` on unhandled exceptions; prints CPU ID, exception syndrome, faulting PC (`ELR`), fault address (`FAR`), and exits with failure. |
| `test/start.zig` | `root` | Root source file of every firmware executable. Re-exports `pub const uos_options = app.uos_options;`, configures `std_options` logging to `uos.trace.logFn`, defines a frame-unwinding `panic` handler, and invokes `app.main()`. |
| `test/board.zig` | `board` | Imported by tests as `@import("board")`. Provides `board.options(ncpu)`, thread-safe `board.console()`, `board.smp.startSecondaryCores()`, `board.smp.waitSecondaries()`, and `board.hw_result.ok()` / `fail()`. |

---

### 2.3 Implementing the Compile-Time Port Contract (`port_contract.zig`)

The core kernel (`micro-os-plus-iii/src/uos.zig`) calls `port_contract.validate(@import("uos_port"))` at compile time. Your `src/port.zig` **must** expose the following public interface:

```zig
const std = @import("std");
const uos = @import("uos");
const board = @import("uos_board");

// 1. Stack configuration
pub const StackElement = u64;        // u64 on 64-bit arches, u32 on 32-bit arches
pub const stack_alignment: usize = 16; // 16-byte on AArch64/x86_64, 8-byte on ARM32
pub const stack_magic: StackElement = 0xDEAD_BEEF_CAFE_BABE;

// 2. Per-thread saved context
pub const Context = struct {
    /// Saved stack pointer when switched out; `null` while active on a CPU!
    stack_ptr: ?[*]StackElement = null,
};

// 3. Initial stack frame construction for a newly spawned thread
pub fn contextCreate(
    ctx: *Context,
    stack: []StackElement,
    entry: *const fn (?*anyopaque) callconv(.c) noreturn,
    arg: ?*anyopaque,
) void {
    // Carve an initial Frame at the top of `stack`, populate:
    //   - argument register (r0 / x0 / a0) = @intFromPtr(arg)
    //   - return address / PC (ELR_EL1 / LR / mepc) = @intFromPtr(entry)
    //   - processor state (SPSR / xPSR / mstatus) = IRQs enabled, privileged mode
    //   - ctx.stack_ptr = pointer to the constructed frame
}

// 4. Interrupt critical & uncritical sections
pub const interrupts = struct {
    pub const State = u64; // Saved DAIF / CPSR / PRIMASK / mstatus

    pub inline fn criticalEnter() State {
        // Save current IRQ mask state and disable IRQs on this CPU
    }
    pub inline fn criticalExit(state: State) void {
        // Restore previous IRQ mask state on this CPU
    }
    pub inline fn uncriticalEnter() State {
        // Save current IRQ mask state and unconditionally enable IRQs on this CPU
    }
    pub inline fn uncriticalExit(state: State) void {
        // Restore previous IRQ mask state on this CPU
    }
    pub inline fn inHandlerMode() bool {
        // Return true if currently executing inside an ISR on this CPU
    }
    pub inline fn isPriorityValid() bool {
        return true; // Or check BASEPRI vs critical priority on Cortex-M
    }
};

// 5. Scheduler port operations & SMP Kernel Lock
pub const scheduler = struct {
    pub fn initialize() void {}
    pub fn start() noreturn {
        // Initialize GIC/PLIC, start timers, switch Core 0 into the first
        // ready thread, and never return.
    }
    pub fn setLocked(locked: bool) bool {
        // Acquire or release the recursive SMP kernel spinlock
    }
    pub fn isLocked() bool {
        // Return true if the current CPU holds the kernel lock
    }
    pub fn reschedule() void {
        // Trigger a cooperative context switch (if not in ISR and not locked)
    }
    pub inline fn waitForInterrupt() void {
        // Execute WFI (Wait For Interrupt) in the idle thread
    }
    pub inline fn cpuId() u32 {
        // Return 0 .. ncpu-1 for the calling hardware core
    }
    pub fn ipi(target_cpu: u32) void {
        // Send an Inter-Processor Interrupt (SGI) to `target_cpu`
    }
    pub inline fn prepareSuspend() void {}
    pub fn greeting(w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("Scheduler: {s}\n", .{board.port_greeting});
    }
};

// 6. System tick (1 kHz) and high-resolution hardware clock
pub const clock_systick = struct {
    pub fn start() void {
        // Enable 1 ms periodic hardware timer and unmask its interrupt
    }
};

pub const clock_highres = struct {
    pub const has_hardware_counter: bool = true;
    pub fn start() void {}
    pub inline fn hardwareCounter() u64 { ... }
    pub inline fn inputClockFrequencyHz() u32 { ... }
    pub inline fn cyclesPerTick() u32 { ... }
    pub inline fn cyclesSinceTick() u32 { ... }
};

// 7. Diagnostic trace output channel
pub const trace = struct {
    pub fn write(bytes: []const u8) void {
        board.uartWrite(bytes);
    }
};

// 8. Optional dedicated interrupt stack
pub fn interruptStack() ?[]StackElement {
    return null;
}
```

---

### 2.4 Context Switching & Interrupt Handling Plumbing

The portable kernel scheduler (`micro-os-plus-iii/src/rtos/scheduler.zig`) manages ready lists, thread priorities, CPU affinities, and sleeping timers. The port connects to the kernel through two callbacks:

1. **Tick Advancement**: Inside your timer interrupt handler:
   ```zig
   uos.rtos.clocks.sysTickHandler();
   ```
2. **Thread Context Selection**: Inside your cooperative switcher (`uos_switch_context`) and IRQ exit path (`uos_irq_handler`):
   ```zig
   const next_sp = uos.rtos.scheduler.internalSwitchThreads(current_sp);
   ```
   - On entry, `current_sp` is the stack pointer where the outgoing thread's register frame was just pushed.
   - `internalSwitchThreads` saves `current_sp` into the outgoing thread's `context.stack_ptr`, selects the highest-priority ready thread eligible for this CPU, sets its `context.stack_ptr = null` (marking it claimed/active in registers), and returns `next_sp`.
   - On SMP systems, storing `current_sp` into `old.context.stack_ptr` must be **deferred** until *after* the assembly routine has finished reading the outgoing stack and switched `SP` to `next_sp` (via per-CPU `_smp_pub_addr` / `_smp_pub_val` slots in `startup.S`), preventing another CPU from resuming the outgoing thread while the first CPU is still using its stack!

```text
┌────────────────────────────────────────────────────────────────────────────┐
│            SMP Context Switch & Deferred Stack Publication Flow            │
└────────────────────────────────────────────────────────────────────────────┘

  Thread A (Running)      startup.S (Asm)        src/port.zig       Scheduler
  ──────────────────      ───────────────        ────────────       ─────────
          │                      │                     │                │
          │ 1. Yield / Timer IRQ │                     │                │
          │─────────────────────►│                     │                │
          │                      │ 2. Push registers   │                │
          │                      │    (Frame) onto     │                │
          │                      │    Thread A stack   │                │
          │                      │──────────┐          │                │
          │                      │◄─────────┘          │                │
          │                      │                     │                │
          │                      │ 3. uos_switch_context(current_sp)    │
          │                      │────────────────────►│                │
          │                      │                     │ 4. internalSwitchThreads()
          │                      │                     │───────────────►│
          │                      │                     │                │ Select ready
          │                      │                     │                │ Thread B & claim:
          │                      │                     │                │ B.stack_ptr = null
          │                      │                     │◄───────────────│
          │                      │                     │   Return next_sp
          │                      │                     │                │
          │                      │                     │ 5. Stage deferred pub:
          │                      │                     │    _smp_pub_addr[cpu] = &A.stack_ptr
          │                      │                     │    _smp_pub_val[cpu]  = current_sp
          │                      │◄────────────────────│                │
          │                      │   Return next_sp    │                │
          │                      │                     │                │
          │                      │ 6. Switch SP = next_sp               │
          │                      │ 7. Publish *(_smp_pub_addr) = current_sp
          │                      │    + DMB ISH (Thread A stack now safe!)
          │                      │ 8. Pop registers from Thread B stack │
          │                      │    & ERET into Thread B              │
          ▼                      ▼                     ▼                ▼
```

---

## 3. How to Add a Specific Board Within an Architecture

Once an architecture port exists (e.g., `micro-os-plus-iii-aarch64` or `micro-os-plus-iii-aarch32`), adding a new board (for instance, adding `rpi5` or `orangepi5` to `aarch64`, or `stm32mp1` to `aarch32`) requires creating a board directory and registering it in the build script.

### 3.1 Board Folder Hierarchy (`boards/<board_name>/`)

Create a new directory `boards/<board_name>/` containing 5 files:

```text
boards/<board_name>/
├── board.zig       # Board constants, UART console, LED, SMP core bringup
├── startup.S       # Early boot asm, exception vectors, stacks, switch macros
├── linker.ld       # Board DRAM origin, length, and section layout
├── openocd.cfg     # OpenOCD debug probe & SoC target configuration
└── reset.cfg       # OpenOCD board reset script (optional if SRST is wired)
```

---

### 3.2 Step 1: Hardware Abstraction (`board.zig`)

`boards/<board_name>/board.zig` is compiled as the `uos_board` module and imported by `src/port.zig` and `test/board.zig`. It must provide:

```zig
//! boards/<board_name>/board.zig

pub const name = "My Custom Board";
pub const banner_long = "My Custom Board";
pub const banner_short = "MyBoard";
pub const banner_cpu = "SoC Name (4x Cortex-A72, AArch64)";
pub const banner_isa = "AArch64";
pub const port_greeting = "µOS++ My Custom Board (4x Cortex-A72 SMP, 1ms Tick)";

/// Number of hardware CPU cores on this board
pub const ncpu = 4;

/// Software Generated Interrupt (SGI) ID used for cross-core reschedule
pub const ipi_sgi: u32 = 0;

/// Usable DRAM region for kernel/application
pub const ram_base: u64 = 0x0008_0000;
pub const ram_end: u64  = 0x3B40_0000;

/// Interrupt Controller (e.g. GIC-400) MMIO base addresses
pub const gicd_base: usize = 0xFF84_1000;
pub const gicc_base: usize = 0xFF84_2000;

/// Early board hook called before scheduler starts
pub fn init() void {}

/// Console UART hooks (used by kernel trace and test console)
pub fn uartInit() void { ... }
pub fn uartWrite(bytes: []const u8) void { ... }
pub fn uartPrint(comptime fmt: []const u8, args: anytype) void { ... }
pub fn uartFlush() void { ... }

/// On-board status LED hooks
pub const led = struct {
    pub fn init() void { ... }
    pub fn on() void { ... }
    pub fn off() void { ... }
    pub fn set(on_: bool) void { ... }
    pub fn toggle() void { ... }
};

/// SMP Secondary CPU wakeup (Spin-table, PSCI `CPU_ON`, or CRU reset release)
pub fn releaseSecondaries(log: *const fn ([]const u8) void) void {
    // Wake cores 1 .. ncpu-1 and point them to core1_entry, core2_entry, ...
}
```

---

### 3.3 Step 2: Early Boot & Exception Vectors (`startup.S`)

`boards/<board_name>/startup.S` handles bare-metal entry before Zig code can execute:

```text
┌────────────────────────────────────────────────────────────────────────────┐
│                   Multi-Core Reset & Early Boot Sequence                   │
└────────────────────────────────────────────────────────────────────────────┘
                        Hardware Reset / Entry (_start)
                                       │
              1. Mask IRQ/FIQ, Drop EL3/EL2 ──► EL1h (or HYP ──► SVC)
              2. Enable FP/SIMD (CPACR_EL1) & Install VBAR_EL1
              3. Read CPU ID (MPIDR_EL1 & 0xFF)
                                       │
                   ┌───────────────────┴───────────────────┐
                   ▼ (CPU == 0)                            ▼ (CPU 1..N-1)
      ┌─────────────────────────┐             ┌─────────────────────────┐
      │   Core 0 Primary Boot   │             │  Secondary Cores Park   │
      │ • SP = __stack_top      │             │ • Wait on __smp_spin[i] │
      │ • Zero .bss section     │             │   or BootROM/PSCI wake  │
      │ • bl mmu_init           │             └────────────┬────────────┘
      │   (Build L1/L2/L3 tables│                          │
      │    & enable MMU+caches) │      releaseSecondaries()│
      │ • bl uos_core0_main     │─────────────────────────►│
      │   ──► root.main()       │                          ▼
      │   ──► scheduler.start() │             ┌─────────────────────────┐
      └────────────┬────────────┘             │  core1..3_entry         │
                   │                          │ • SP = __stack_top_coreN│
                   │                          │ • bl mmu_enable (shared)│
                   │                          │ • bl boot_core1         │
                   │                          │   (GIC CPU + 1kHz timer)│
                   └─────────────┬────────────┴────────────┘
                                 ▼
              ┌─────────────────────────────────────────────┐
              │     uos_first_thread_restore (SMP Live)     │
              └─────────────────────────────────────────────┘
```

1. **Mask Interrupts**: Disable IRQ/FIQ immediately at `_start`.
2. **Privilege Level Transition**: Drop from EL3/EL2 to EL1h (AArch64) or from HYP to SVC mode (AArch32), enabling FP/SIMD (`CPACR_EL1` / `CPACR` + `FPEXC.EN`) and unaligned access.
3. **Install Vector Table**: Load `VBAR_EL1` / `VBAR` with the address of `vector_table`.
4. **Core Dispatch**: Read CPU ID (`MPIDR_EL1 & 0xFF`). Core 0 proceeds to `core0_start`; secondary cores park in `secondary_park` (waiting on `__smp_spin[core]` or PSCI/BootROM wakeup).
5. **Core 0 Initialization**:
   - Load `sp = __stack_top`.
   - Zero `.bss` (`__bss_start` to `__bss_end`).
   - Call `bl mmu_init` (builds page tables, cleans D-cache lines, enables MMU + L1/L2 caches).
   - Call `bl uos_core0_main` (located in `src/port.zig`, which calls `root.main()`).
6. **Secondary Core Entry (`core1_entry`, `core2_entry`, `core3_entry`)**:
   - Load per-core stack (`__stack_top_core1`, etc.).
   - Call `bl mmu_enable` (uses the shared page tables built by Core 0).
   - Call `bl boot_core1` (initializes per-core GIC CPU interface, starts per-core 1 ms timer, enters first ready thread via `uos_first_thread_restore`).

---

### 3.4 Step 3: Memory Map & Linker Script (`linker.ld`)

`boards/<board_name>/linker.ld` defines the physical load address and memory sections.

> **Important:** Always place `*(.got*)` inside `.data` **before** `.bss (NOLOAD)`. In Zig 0.17, LLD may emit a `.got` section; if `.got` is left as an orphan section after `.bss`, LLD converts the entire `.bss` section into `PROGBITS` initialized zeroes inside the ELF file, bloating the ELF from ~100 KB to >60 MB!

```text
  Physical DRAM Layout (e.g., Raspberry Pi 4 B @ ORIGIN = 0x00080000)
  ┌──────────────────┬────────────────────────┬──────────────────────────────┐
  │ 0x0008_0000      │ .text (.text.boot, *)  │ Entry _start, vectors, code  │
  ├──────────────────┼────────────────────────┼──────────────────────────────┤
  │ ALIGN(8)         │ .rodata                │ Constants, vtables, strings  │
  ├──────────────────┼────────────────────────┼──────────────────────────────┤
  │ ALIGN(8)         │ .data + *(.got*)       │ Initialized data & GOT       │
  ├──────────────────┼────────────────────────┼──────────────────────────────┤
  │ __bss_start      │ .bss (NOLOAD)          │ Zeroed by Core 0 at boot     │
  ├──────────────────┼────────────────────────┼──────────────────────────────┤
  │ __bss_end        │ .stack (NOLOAD)        │ Core 0 (1 MiB) +             │
  │                  │                        │ Cores 1..3 (3 x 512 KiB)     │
  ├──────────────────┼────────────────────────┼──────────────────────────────┤
  │ __heap_start     │ .heap (NOLOAD)         │ 64 MiB free store            │
  │ .. __heap_end    │                        │                              │
  └──────────────────┴────────────────────────┴──────────────────────────────┘
```

```ld
OUTPUT_FORMAT("elf64-littleaarch64")
OUTPUT_ARCH(aarch64)
ENTRY(_start)

STACK_SIZE   = 0x100000;   /* 1 MiB Core 0 stack */
W_STACK_SIZE = 0x80000;    /* 512 KiB per secondary core stack */
HEAP_SIZE    = 0x04000000; /* 64 MiB free store */

MEMORY {
    RAM (rwx) : ORIGIN = 0x00080000, LENGTH = 0x3B380000
}

SECTIONS {
    . = ORIGIN(RAM);
    .text : ALIGN(8) {
        KEEP(*(.text.boot))     /* _start + vector_table placed first */
        *(.text*)
    } > RAM
    .rodata : ALIGN(8) { *(.rodata*) } > RAM
    .data : ALIGN(8) {
        *(.data*)
        *(.got*)                /* CRITICAL: keep .got before .bss (NOLOAD) */
    } > RAM
    .bss (NOLOAD) : ALIGN(16) {
        __bss_start = .;
        *(.bss*) *(COMMON)
        . = ALIGN(16);
        __bss_end = .;
    } > RAM
    .stack (NOLOAD) : ALIGN(16) {
        . = . + STACK_SIZE;   __stack_top = .;
        . = . + W_STACK_SIZE; __stack_top_core1 = .;
        . = . + W_STACK_SIZE; __stack_top_core2 = .;
        . = . + W_STACK_SIZE; __stack_top_core3 = .;
    } > RAM
    .heap (NOLOAD) : ALIGN(16) {
        __heap_start = .;
        . = . + HEAP_SIZE;
        __heap_end = .;
    } > RAM
    _end = .;
}
```

---

### 3.5 Step 4: OpenOCD Target & Reset Configs (`openocd.cfg`, `reset.cfg`)

- `boards/<board_name>/openocd.cfg`: Configures the debug probe (`interface/cmsis-dap.cfg`, `interface/stlink.cfg`, or `interface/ftdi/...`), selects the transport (`jtag` or `swd`), sets `adapter speed`, and defines the SoC DAP and CPU targets.
- `boards/<board_name>/reset.cfg`: On boards without a physical `SRST` pin wired to the debug header (such as the Raspberry Pi 4 B), triggers a clean SoC reboot via memory-mapped Watchdog registers (`PM_WDOG` / `PM_RSTC`).

---

### 3.6 Step 5: Registering the Board in `build.zig` and `test/hw.sh`

1. **In `<arch>/build.zig`**:
   Add the new board identifier to `BoardId` and `boards`:
   ```zig
   const BoardId = enum { rpi4b, myboard };

   const boards = [_]Board{
       .{ .id = .rpi4b,   .cpu = &std.Target.aarch64.cpu.cortex_a72 },
       .{ .id = .myboard, .cpu = &std.Target.aarch64.cpu.cortex_a53 },
   };
   ```
2. **In `<arch>/test/hw.sh`**:
   Add a `case` branch mapping your board name to its OpenOCD primary CPU target name and entry address:
   ```bash
   case "$BOARD" in
     rpi4b)
       TARGET="bcm2711.cpu0"
       ENTRY=0x80000
       ;;
     myboard)
       TARGET="mysoc.cpu0"
       ENTRY=0x40000000
       ;;
   esac
   ```

---

### 3.7 Note on MicroZig-Based Boards (`micro-os-plus-iii-cortexm`)

In `micro-os-plus-iii-cortexm`, startup code, vector tables, and linker scripts are provided automatically by **MicroZig** (`microzig.MicroBuild(.{ .rp2xxx = true, .stm32 = true })`). Therefore, adding a Cortex-M board only requires:

1. Creating `src/boards/<board_name>.zig` (which configures system clocks, SysTick/Timer, LED, and RP2040/RP2350 FIFO multicore launch).
2. Adding the enum tag to `BoardId`, `boards`, and `boardTarget()` in `micro-os-plus-iii-cortexm/build.zig`.
3. Adding the OpenOCD `CFG` and `RUN` commands for the board in `micro-os-plus-iii-cortexm/test/hw.sh`.

---

## 4. How the Build System Works in Detail

### 4.1 Build Files & Locations

Every build involves two pairs of `build.zig` / `build.zig.zon` files:

| File Location | Purpose |
|---|---|
| `micro-os-plus-iii/build.zig.zon` | Core kernel package definition (`.name = .micro_os_plus_iii`, version `7.0.0`, minimum Zig `0.17.0`). |
| `micro-os-plus-iii/build.zig` | Exports helper functions (`createModule`, `createSuitesModule`, `addCIncludes`, `linkPort`) imported by architecture ports via `@import("micro_os_plus_iii")`. Also defines `zig build test` for host-side kernel unit tests. |
| `micro-os-plus-iii-<arch>/build.zig.zon` | Declares `.micro_os_plus_iii = .{ .path = "../micro-os-plus-iii" }` (plus `.microzig` on Cortex-M). |
| `micro-os-plus-iii-<arch>/build.zig` | Iterates over the `tests` array, calls `addFirmware()` (or `addApplication()` on POSIX), wires modules and C sources, emits `.elf` and `.img` files under `zig-out/firmware/<board>/`, and binds the `run` step to QEMU or `test/hw.sh`. |

---

### 4.2 Bidirectional Module Dependency Graph

When `addFirmware()` runs in `<arch>/build.zig`, it constructs a fresh set of Zig modules per firmware executable and links them in a directed graph:

```text
               ┌──────────────────────────────────────────────────┐
               │      root module (test/start.zig + startup.S)    │
               └───────────────────┬──────────────────────────┬───┘
                    imports "app"  │                          │ imports "uos"
                                   ▼                          │
        ┌──────────────────────────────────────────────┐      │
        │    app module (test/<test-name>/main.zig)    │      │
        └──┬────────────────┬──────────────┬───────────┴─┐    │
   "board" │   "uos_suites" │  opt: "sd" / │    "uos"    │    │
           ▼                ▼    "flatfs"  ▼             ▼    ▼
┌────────────────┐  ┌──────────────┐  ┌─────────┐  ┌─────────────────────────┐
│  board module  │  │  uos_suites  │  │ drivers │  │       uos module        │
│(test/board.zig)│  │ (suites.zig) │  │(sd.zig) │  │(micro-os-plus-iii/uos)  │
└──┬──────────┬──┘  └───────┬──────┘  └────┬────┘  └──────────┬──────────▲───┘
   │          │   "uos"     │    "uos"     │  "uos"           │          │
   │          └─────────────┴──────────────┴──────────────────┼─────────►│
   │ "uos_board"                                   "uos_port" │          │ "uos"
   │                                                          ▼          │
   │                                               ┌─────────────────────┴───┐
   │                                               │     uos_port module     │
   │                                               │      (src/port.zig)     │
   │                                               └──────────┬──────────────┘
   │                                                          │ "uos_board"
   ▼                                                          ▼
┌────────────────────────────────────────────────────────────────────────────┐
│                  uos_board module (boards/<board>/board.zig)               │
└────────────────────────────────────────────────────────────────────────────┘
```

The exact code in `<arch>/build.zig` that constructs this graph is:

```zig
const board_mod = b.createModule(.{
    .root_source_file = b.path(
        b.fmt("boards/{s}/board.zig", .{@tagName(options.board)}),
    ),
});

const port_mod = b.createModule(.{
    .root_source_file = b.path("src/port.zig"),
});
port_mod.addImport("uos_board", board_mod);

const uos_mod = uos_build.createModule(b, kernel_dep, .{
    .target = options.target,
    .optimize = options.optimize,
    .port = port_mod, // Calls linkPort(uos_mod, port_mod) internally!
});

const test_board_mod = b.createModule(.{
    .root_source_file = b.path("test/board.zig"),
});
test_board_mod.addImport("uos", uos_mod);
test_board_mod.addImport("uos_board", board_mod);

const app_mod = b.createModule(.{
    .root_source_file = options.app_source_file,
    .imports = &.{
        .{ .name = "uos", .module = uos_mod },
        .{
            .name = "uos_suites",
            .module = uos_build.createSuitesModule(b, kernel_dep, uos_mod),
        },
        .{ .name = "board", .module = test_board_mod },
    },
});

const root_mod = b.createModule(.{
    .root_source_file = b.path("test/start.zig"),
    .target = options.target,
    .optimize = options.optimize,
    .single_threaded = false,
    .imports = &.{
        .{ .name = "uos", .module = uos_mod },
        .{ .name = "app", .module = app_mod },
    },
});
root_mod.addAssemblyFile(
    b.path(b.fmt("boards/{s}/startup.S", .{@tagName(options.board)})),
);
```

---

### 4.3 Compile-Time Kernel Configuration (`uos_options`)

Unlike C++ which uses preprocessor `#define OS_INTEGER_...` macros in `<cmsis-plus/os-app-config.h>`, the Zig kernel reads a single compile-time struct `pub const uos_options: uos.Options` declared in the root module (`test/start.zig` forwards `pub const uos_options = app.uos_options;`).

Every test or application configures the kernel by declaring `pub const uos_options` in its `main.zig`:

```zig
pub const uos_options: uos.Options = .{
    .ncpu = 4,                                    // Number of SMP cores (1..32)
    .smp = true,                                  // Enable SMP scheduler & lock
    .resume_ipi = true,                           // Cross-core IPI on resume
    .systick_frequency_hz = 1000,                 // 1 ms tick rate
    .main_stack_size_bytes = 65536,               // Stack size for osMain thread
    .default_stack_size_bytes = 16384,            // Default thread stack size
    .idle_stack_size_bytes = 16384,               // Per-CPU idle stack size
    .min_stack_size_bytes = 2048,                 // Minimum allowed stack size
    .dynamic_memory_size_bytes = 8 * 1024 * 1024, // 8 MiB system heap (FirstFitTop)
    .c_api = true,                                // Export os_* C API (c_api.zig)
    .cmsis_os = true,                             // Export CMSIS-RTOS v1 API
    .c_runtime = true,                            // Export freestanding libc
    .trace = .{
        .scheduler = false,
        .thread = false,
        .mutex = false,
    },
};
```

---

### 4.4 Build CLI Options (`-D` Flags)

All architecture ports support a consistent set of command-line options passed via `zig build`:

| Option | Type | Default | Description |
|---|---|---|---|
| `-Dboard=<name>` | `BoardId` | Port default (`rpi4b`, `luckfox-lyra`, `pico2`) | Selects the target hardware board to compile for. |
| `-Dtest=<name>` | `[]const u8` | *(all tests)* | Compiles (and runs when paired with `run`) only the specified test binary. |
| `-Doptimize=<mode>` | `OptimizeMode` | `ReleaseSafe` (`.safe`) | Optimization mode (`Debug`, `ReleaseSafe`, `ReleaseFast`, `ReleaseSmall`). |
| `-Dqemu=<path>` | `[]const u8` | xPack QEMU path | Path to `qemu-system-aarch64` / `qemu-system-arm` (when `run` uses QEMU). |
| `-Dcmsis_rv=<path>` | `[]const u8` | `~/.local/xPacks/@xpacks/arm-cmsis-rtos-validator/1.0.0-4` | Path to the Arm CMSIS-RTOS Validator xPack source tree. |
| `-Dtimeout=<sec>` | `u32` | `300` or `600` | Maximum seconds `zig build run` waits for hardware test completion. |

---

### 4.5 Compiler Options, Targets, CPU Models & Linker Settings

Each architecture port configures `b.resolveTargetQuery(...)` and executable properties specifically for its ISA:

| Port & Board | `cpu_arch` | `os_tag` | `abi` | `cpu_model` | `single_threaded` | Entry |
|---|---|---|---|---|---|---|
| **`aarch64`** (RPi 4 B) | `.aarch64` | `.freestanding` | `.none` | `cortex_a72` | `false` (`ncpu=4`) | `_start` |
| **`aarch32`** (Luckfox Lyra) | `.arm` | `.freestanding` | `.eabihf` | `cortex_a7` | `false` (`ncpu=3`) | `_start` |
| **`cortexm`** (RP2350 Pico 2) | `.thumb` | `.freestanding` | `.eabihf` | `cortex_m33` | `false` (`ncpu=2`) | MicroZig |
| **`cortexm`** (RP2040 Pico) | `.thumb` | `.freestanding` | `.eabi` | `cortex_m0plus` | `false` (`ncpu=2`) | MicroZig |
| **`cortexm`** (STM32F411/412) | `.thumb` | `.freestanding` | `.eabihf` | `cortex_m4` | `true` (`ncpu=1`) | MicroZig |
| **`posix-arch`** (Linux Host) | `.x86_64` | `.linux` | `.gnu` | `baseline` | `false` (`ncpu=4`) | C `main` |

Key compiler and linker settings enforced by `build.zig`:

- **`.single_threaded = false`**: Crucial on SMP targets. Ensures Zig/LLVM emits full hardware atomic read-modify-write instructions (`ldaxr`/`stlxr` on AArch64, `ldrex`/`strex` on ARMv7, `dmb ish`) rather than lowering atomics to non-atomic loads/stores.
- **`exe.link_gc_sections = true`**: Enables `--gc-sections` in LLD to strip unused functions and keep firmware binaries compact (49 KB – 212 KB).
- **`b.addObjCopy(exe.getEmittedBin(), .{ .format = .binary })`**: Produces raw binary images (`.img` / `.bin`) alongside `.elf` executables so images can be booted directly from an SD card (`kernel8.img`) or loaded by `qemu-system-aarch64 -kernel`.

---

### 4.6 Libraries, C API, CMSIS-RTOS v1, Freestanding libc & Drivers

1. **Zero External Dependencies for Pure Zig Tests**:
   Pure Zig tests (`smp-test0..4`, `smp-mat-test`, `mutex-stress`, `smp-pro-cons-test`, `smp-mem-test`, `smp-mem-inter-test`) compile with `.link_libc = false` and zero external C libraries.
2. **Mixed Zig + C Tests (`rtos-apis`, `cmsis-os-validator`)**:
   When `Test.c_sources.len > 0` or `Test.cmsis_rv == true`:
   - `uos_build.addCIncludes(kernel_dep, root_mod, true)` adds:
     - `micro-os-plus-iii/include` (provides `<cmsis-plus/rtos/os-c-api.h>` and `<cmsis-plus/rtos/os-c-decls.h>`).
     - `micro-os-plus-iii/include/c` (provides freestanding C standard headers: `<stdio.h>`, `<stdlib.h>`, `<string.h>`, `<stdint.h>`, `<stddef.h>`, `<stdbool.h>`, `<stdarg.h>`, `<assert.h>`, `<limits.h>`, `<inttypes.h>`, `<errno.h>`).
   - `micro-os-plus-iii/src/c_api.zig` exports all `os_thread_*`, `os_mutex_*`, `os_semaphore_*`, `os_condvar_*`, `os_evflags_*`, `os_mqueue_*`, `os_mempool_*`, `os_timer_*`, and `os_clock_*` C functions when `uos_options.c_api = true`.
   - `micro-os-plus-iii/src/cmsis_os.zig` exports the Arm CMSIS-RTOS v1 API (`osKernelStart`, `osThreadCreate`, `osMutexWait`, `osSignalSet`, `osMailAlloc`, etc.) when `uos_options.cmsis_os = true`.
   - `micro-os-plus-iii/src/libc.zig` + `src/c_printf.c` provide `memcpy`, `memset`, `memmove`, `memcmp`, `strlen`, `strcmp`, `strncmp`, `strcpy`, `strncpy`, `snprintf`, `vsnprintf`, `printf`, `puts`, `putchar`, `malloc`, `free`, `calloc`, and `abort` when `uos_options.c_runtime = true`.
3. **Storage Device Drivers (`.devices = true`)**:
   - In `micro-os-plus-iii-aarch64` and `posix-arch`: Links pure-Zig `drivers/sd.zig` and `drivers/flatfs.zig` (`sd` and `flatfs` modules) or FatFs over EMMC2.
   - In `micro-os-plus-iii-aarch32`: Links `drivers/sd.zig`, `drivers/fatfs.zig`, and compiles Elm-Chan FatFs R0.15a (`drivers/fatfs/ff.c` with `-std=c11`) bridged via `b.addTranslateC` on `drivers/ff_api.h`.

---

### 4.7 Build Commands in Clear (User CLI & Underlying Compiler Invocations)

Below are the exact commands to build tests across all repositories. Assuming the Zig 0.17 compiler is at `/home/dan/zig-x86_64-linux-0.17.0/zig` (or `zig` on `PATH`):

#### A. AArch64 (`micro-os-plus-iii-aarch64` — Raspberry Pi 4 B)

```bash
cd /home/dan/Desktop/micro-os-plu-iii-smp-zig-pr-github/micro-os-plus-iii-aarch64

# 1. Build all 16 test firmwares (.elf and .img) for Raspberry Pi 4 B (ReleaseSafe):
/home/dan/zig-x86_64-linux-0.17.0/zig build

# 2. Build a single test firmware (e.g., smp-mem-inter-test):
/home/dan/zig-x86_64-linux-0.17.0/zig build -Dtest=smp-mem-inter-test

# 3. Build in Debug mode (unoptimized, full debug symbols):
/home/dan/zig-x86_64-linux-0.17.0/zig build -Doptimize=debug -Dtest=smp-test0

# 4. Build in ReleaseFast mode (maximum performance):
/home/dan/zig-x86_64-linux-0.17.0/zig build -Doptimize=fast
```

Outputs are installed to:

- `zig-out/firmware/rpi4b/<test>.elf` (ELF64 with symbols, loaded by OpenOCD)
- `zig-out/firmware/rpi4b/<test>.img` (Flat raw binary, loaded by QEMU or SD card bootloader)

#### B. What `zig build` Executes Under the Hood (Exact `zig build-exe` Command in Clear)

When you run `zig build -Dtest=smp-test0` in `micro-os-plus-iii-aarch64`, the Zig build runner constructs and executes the following exact compiler command:

```bash
/home/dan/zig-x86_64-linux-0.17.0/zig build-exe \
  -fentry=_start \
  boards/rpi4b/startup.S \
  -fno-single-threaded \
  -Osafe \
  -target aarch64-freestanding-none \
  -mcpu cortex_a72 \
  --dep uos --dep app \
  -Mroot=test/start.zig \
  -Osafe -target aarch64-freestanding-none -mcpu cortex_a72 \
  --dep uos_port \
  -Muos=../micro-os-plus-iii/src/uos.zig \
  --dep uos --dep uos_suites --dep board \
  -Mapp=test/smp-test0/main.zig \
  --dep uos_board --dep uos \
  -Muos_port=src/port.zig \
  --dep uos \
  -Muos_suites=../micro-os-plus-iii/tests/suites.zig \
  --dep uos --dep uos_board \
  -Mboard=test/board.zig \
  -Muos_board=boards/rpi4b/board.zig \
  --script boards/rpi4b/linker.ld \
  --name smp-test0
```

And for a mixed Zig + C test like `rtos-apis`, it additionally passes the C include paths and C source flags directly to Zig's integrated Clang compiler:

```bash
  -I ../micro-os-plus-iii/include \
  -I ../micro-os-plus-iii/include/c \
  -I include \
  -I test/rtos-apis \
  -cflags -std=c11 -- src/c_printf.c \
  -cflags -std=c11 \
    -DOS_INTEGER_RTOS_DEFAULT_STACK_SIZE_BYTES=16384 \
    -DOS_INTEGER_SYSTICK_FREQUENCY_HZ=1000 \
    -- test/rtos-apis/test-c-api.c
```

#### C. AArch32 (`micro-os-plus-iii-aarch32` — Luckfox Lyra RK3506)

```bash
cd /home/dan/Desktop/micro-os-plu-iii-smp-zig-pr-github/micro-os-plus-iii-aarch32

# Build all 13 tests for Luckfox Lyra (outputs to zig-out/firmware/luckfox-lyra/*.elf):
/home/dan/zig-x86_64-linux-0.17.0/zig build

# Build one specific test:
/home/dan/zig-x86_64-linux-0.17.0/zig build -Dtest=smp-test2
```

#### D. Cortex-M (`micro-os-plus-iii-cortexm` — Pico 2, Pico, BlackPill STM32F411/F412, Nucleo-F411)

```bash
cd /home/dan/Desktop/micro-os-plu-iii-smp-zig-pr-github/micro-os-plus-iii-cortexm

# Build all tests for Raspberry Pi Pico 2 (RP2350, 2x Cortex-M33 SMP):
/home/dan/zig-x86_64-linux-0.17.0/zig build -Dboard=pico2

# Build all tests for Raspberry Pi Pico (RP2040, 2x Cortex-M0+ SMP):
/home/dan/zig-x86_64-linux-0.17.0/zig build -Dboard=pico

# Build all single-core tests for WeAct BlackPill STM32F411CE (Cortex-M4F):
/home/dan/zig-x86_64-linux-0.17.0/zig build -Dboard=weactf411

# Build all single-core tests for ST NUCLEO-F411RE:
/home/dan/zig-x86_64-linux-0.17.0/zig build -Dboard=nucleof411

# Build a single test for a specific board:
/home/dan/zig-x86_64-linux-0.17.0/zig build -Dboard=pico2 -Dtest=cmsis-os-validator
```

#### E. Synthetic POSIX Architecture (`micro-os-plus-iii-posix-arch` — Linux Host)

```bash
cd /home/dan/Desktop/micro-os-plu-iii-smp-zig-pr-github/micro-os-plus-iii-posix-arch

# Build all 18 host-executable tests (outputs to zig-out/bin/*):
/home/dan/zig-x86_64-linux-0.17.0/zig build

# Build one specific test:
/home/dan/zig-x86_64-linux-0.17.0/zig build -Dtest=smp-rtos-apis
```

---

## 5. How Tests Are Organized and Executed

### 5.1 Two-Tier Test Architecture: `micro-os-plus-iii` vs `<architecture>/test`

Testing in µOS++ IIIe is split into two distinct layers:

```text
┌────────────────────────────────────────────────────────────────────────────┐
│ 1. Core Kernel Repository (micro-os-plus-iii)                              │
│                                                                            │
│  ┌────────────────────────────────────┐  ┌──────────────────────────────┐  │
│  │ src/host_tests.zig                 │  │ tests/suites/*.zig           │  │
│  │ • Intrusive lists (Ready/Wait/Clk) │  │  (imported as 'uos_suites')  │  │
│  │ • Event & Thread internal flags    │  │ • check.zig (test assertions)│  │
│  │ • FirstFitTop, BlockPool, Lifo     │  │ • rtos_apis.zig (RTOS suite) │  │
│  │ • c_storage.zig (C ABI sizes)      │  │ • io_apis.zig (POSIX I/O)    │  │
│  └─────────────────┬──────────────────┘  │ • smp.zig (portable SMP)     │  │
│                    │                     └──────────────┬───────────────┘  │
│     zig build test │ (native host)                      │ imported as      │
│                    ▼                                    │ 'uos_suites'     │
└─────────────────────────────────────────────────────────┼──────────────────┘
                                                          │
                                                          ▼
┌────────────────────────────────────────────────────────────────────────────┐
│ 2. Architecture Repository (micro-os-plus-iii-<arch>/test/)                │
│                                                                            │
│  ┌──────────────────────────────────────────────────────────────────────┐  │
│  │ Common Test Scaffolding: test/start.zig + test/board.zig + test/hw.sh│  │
│  └─────────────────┬────────────────────────────────────┬───────────────┘  │
│                    ▼                                    ▼                  │
│  ┌────────────────────────────────────┐  ┌──────────────────────────────┐  │
│  │ Portable Suite Wrappers            │  │ Architecture & Soak Tests    │  │
│  │ • test/rtos-apis/                  │  │ • smp-test0..4 (SMP bringup) │  │
│  │   (runs uos_suites + test-c-api.c) │  │ • mutex-stress, pro-cons     │  │
│  │ • test/cmsis-os-validator/         │  │ • smp-pipeline, smp-num-test │  │
│  │   (Arm CMSIS-RTOS v1 C validator)  │  │ • smp-mat-test (+ sdcard)    │  │
│  │                                    │  │ • sd-test, smp-mem-test,     │  │
│  │                                    │  │   smp-mem-inter-test         │  │
│  └────────────────────────────────────┘  └──────────────────────────────┘  │
└────────────────────────────────────────────────────────────────────────────┘
```

---

### 5.2 Portable Kernel Tests in `micro-os-plus-iii`

Located inside `/home/dan/Desktop/micro-os-plu-iii-smp-zig-pr-github/micro-os-plus-iii/`:

1. **Host-Only Unit Tests (`src/host_tests.zig`)**:
   Tests kernel data structures directly on the build machine without needing a hardware port:
   - `src/rtos/lists.zig`: Intrusive doubly-linked thread waiting lists (priority-ordered insertion, head/tail removal), clock timeout delta/ordered lists.
   - `src/rtos/flags.zig`: Internal event/thread bitflag state machine (wait any/all, auto-clear).
   - `src/memory/first_fit_top.zig`: Free-list heap allocator (`FirstFitTop`), block splitting, coalescing, aligned allocation, statistics.
   - `src/memory/block_pool.zig`: Fixed-size block memory pool (`BlockPool`).
   - `src/memory/lifo.zig`: LIFO deterministic memory allocator (`Lifo`).
   - `src/c_storage.zig`: Parses `include/cmsis-plus/rtos/os-c-decls.h` and verifies at test time that the C struct sizes (`os_thread_t`, `os_mutex_t`, `os_semaphore_t`, `os_condvar_t`, `os_evflags_t`, `os_mqueue_t`, `os_mempool_t`, `os_timer_t`) are large enough and properly aligned to hold the corresponding Zig kernel structs on both 32-bit and 64-bit targets.

2. **Shared On-Target Test Suites (`tests/suites.zig`, imported as `uos_suites`)**:
   Portable RTOS test logic shared across all architectures:
   - `tests/suites/check.zig`: Test assertion framework (`check()`, `checkEq()`, `finish()`) tracking passed/failed checks.
   - `tests/suites/rtos_apis.zig`: Exhaustive Zig RTOS API test suite exercising Thread creation/join/priority/yield, Mutex (normal, errorcheck, recursive, priority inheritance, robustness), Semaphore (binary, counting, timedWait), ConditionVariable, EventFlags, MessageQueue (priority ordering, timed send/receive), MemoryPool, Timer (one-shot and periodic), and Clocks (`sysclock`, `rtclock`, `hrclock`).
   - `tests/suites/io_apis.zig`: POSIX I/O descriptor table, `DeviceCharacter`, `BlockDevice`, and `FileSystem` abstraction tests.
   - `tests/suites/smp.zig`: Portable multi-core test suite (`smp1` parallel thread distribution, `smp2` cross-core mutex contention, `smp3` cross-core queue wakeup, `smp4` affinity migration, `smp5` IPI stress).

---

### 5.3 Architecture & Board Tests in `<architecture>/test/`

Located inside `<architecture>/test/<test-name>/main.zig`, these are complete bootable applications tailored to exercise SMP hardware, peripherals, MMU, caches, and full soak workloads:

| Test Name | Cores | Description & What It Verifies |
|---|---|---|
| **`smp-test0`** | 1 | **Phase-1 Bringup**: Initializes UART0, MMU identity mapping, GIC, and 1 kHz Generic Timer on Core 0. Runs 10 heartbeats via `sysclock.sleepFor(1000)` and verifies tick accuracy. |
| **`smp-test1`** | 4 (or N) | **SMP Bringup & Preemption**: Releases secondary cores (`c1..c3`), spawns worker threads across all cores, and verifies preemptive round-robin time-slicing and per-core execution counters. |
| **`smp-test2`** | 4 (or N) | **SMP Mutex & Atomic Exclusives**: Pinned worker threads hammering a shared counter protected by a `uos.rtos.Mutex` (`ldaxr`/`stlxr` spinlock + wait list). Verifies exact final count with zero lost updates. |
| **`smp-test3`** | 4 (or N) | **Cross-Core Message Queue**: Producer on Core 0 streams integers every 20 ms through a `MessageQueue` to a Consumer on Core 1 (which classifies primes and toggles the LED) and a Logger on Core 2. |
| **`smp-test4`** | 4 (or N) | **Multi-Stage Kernel Primitives**: 5-stage cross-core synchronization verification covering `EventFlags`, `MessageQueue`, `MemoryPool`, `ConditionVariable`, and `Mutex`. |
| **`smp-mat-test`** | 4 (or N) | **Parallel Block LU Linear Solver (RAM)**: Runs a 10-worker thread pool demo (20 tasks), then solves a 200 × 200 diagonally-dominant system (B = 50) in parallel across all cores using generation spin-barriers, comparing against single-core classical Gaussian elimination (Δx < 0.01). |
| **`smp-mat-sdcard-test`** | 4 (or N) | **SD-Backed Parallel Block LU Solver**: Formats a FlatFs/FatFs volume on the SD card, generates A and b matrices, writes `A.mat` (160 KB) and `b.mat` to SD, reloads working sets from SD, runs the parallel 4-core block solver, and writes/verifies the solution vector on SD. |
| **`mutex-stress`** | 4 (or N) | **20-Second High-Contention Mutex Soak**: Spawns 10 worker threads across 4 cores contending on a pool of mutexes with randomized hold/sleep times and checksum verification for 20 seconds. |
| **`smp-pro-cons-test`** | 4 (or N) | **20-Second All-Kernel-Objects Pipeline**: 12 concurrent threads (4 producers, 4 consumers, aggregator, stage worker, pauser suspending/resuming `cons_0`, telemetry, + 200 ms periodic timer) streaming CRC32-verified packets from a `MemoryPool` through a `MessageQueue` with counting/binary semaphores, condition variables, and event flags for 20 seconds. |
| **`smp-pipeline-test`** | 4 (or N) | **20-Second 4-Stage Sensor Pipeline + SD Storage**: 13 concurrent threads across 4 stages (Generator → Moving-Average Filter → √/Trig Compute → Aggregator) persisting records to `pipe.bin` on the SD card and reading back to verify record CRCs for 20 seconds. |
| **`smp-num-test`** | 4 (or N) | **20-Second Multi-Priority I/O & Math Soak**: 5 threads with distinct RTOS priorities (`high` UART ticker, `above_normal` LED blinker pacing passes via counting semaphore, `normal` SD text writer, `below_normal` FP math writer, `low` SD tail reader/verifier) concurrently updating and verifying `num.txt` on SD for 20 seconds. |
| **`sd-test`** | 1 | **SDHCI & FlatFs Verification**: Exercises Phase A (mounting host-seeded volume) and Phase B (formatting volume, writing `hello.txt`, `data1.bin`, `data2.bin`, and 300 KB `big.bin`, reading back and verifying byte-for-byte). |
| **`smp-mem-test`** | 4 | **High-Memory Dynamic Page Mapping Stress**: 20 threads (5 per core) allocating 1..512 MB blocks from the 3008 MB high-RAM region (`0x40000000..0xFC000000`), mapping 4 KB L3 pages on demand (`mmu_hi_map`), checking guard pages with non-faulting `AT S1E1R` (`mmu_hi_probe`), verifying head/tail canaries and 64-bit data patterns, and unmapping on free with `TLBI VMALLE1IS`. |
| **`smp-mem-inter-test`** | 4 | **Ring Inter-Thread High-Memory + Hardware CRC32**: 20 threads in a ring (`w[i] -> w[(i+1)%20]`) allocating 1..512 MB blocks, filling patterns, computing hardware CRC32 (`crc32x`/`crc32b`), lending blocks via per-thread `MessageQueue`s (`OWNED -> LENT -> MODIFYING -> MODIFIED -> OWNED`), XORing with a 64-bit mask on the helper core, XORing back on the owner core, and verifying `crc1 == crc2`. |
| **`rtos-apis`** | 4 (or 1) | **Full Zig + C RTOS API Suite**: Runs the portable Zig `uos_suites.rtos_apis` suite, then invokes the C `test_c_api()` suite (`test-c-api.c` testing every `os_*` C function and static/dynamic object lifecycle), followed by a 20-second multi-core soak loop. |
| **`cmsis-os-validator`** | 1 (SMP) | **Official Arm CMSIS-RTOS v1 Validator**: Compiles the unmodified Arm `arm-cmsis-rtos-validator` xPack C test suite against `cmsis_os.zig` and `validator-glue.c` (mapping a dummy DWT page at `0xE0001000` and routing SGI 1 as the software-triggered test IRQ). |

---

### 5.4 Running Tests in Clear: Host & POSIX Native Commands

#### 1. Core Kernel Host Unit Tests (`micro-os-plus-iii`)

```bash
cd /home/dan/Desktop/micro-os-plu-iii-smp-zig-pr-github/micro-os-plus-iii

# Run all portable kernel unit tests on the Linux host:
/home/dan/zig-x86_64-linux-0.17.0/zig build test --summary all
```

#### 2. Synthetic POSIX SMP Port (`micro-os-plus-iii-posix-arch`)

```bash
cd /home/dan/Desktop/micro-os-plu-iii-smp-zig-pr-github/micro-os-plus-iii-posix-arch

# Build and run a single test via zig build:
/home/dan/zig-x86_64-linux-0.17.0/zig build run -Dtest=smp-test4

# Or run any compiled binary directly in clear:
./zig-out/bin/smp-test0
./zig-out/bin/smp-rtos-apis
./zig-out/bin/cmsis-os-validator
```

---

### 5.5 Running Tests in Clear: QEMU Emulation Commands

#### 1. Via `zig build run` (AArch64 Raspberry Pi 4 B)

In `micro-os-plus-iii-aarch64`, `zig build run -Dtest=<name>` automatically invokes `qemu-system-aarch64`:

```bash
cd /home/dan/Desktop/micro-os-plu-iii-smp-zig-pr-github/micro-os-plus-iii-aarch64

/home/dan/zig-x86_64-linux-0.17.0/zig build run -Dtest=smp-test0
/home/dan/zig-x86_64-linux-0.17.0/zig build run -Dtest=smp-test4
/home/dan/zig-x86_64-linux-0.17.0/zig build run -Dtest=cmsis-os-validator
```

#### 2. Direct QEMU Command in Clear (AArch64 `raspi4b`)

You can execute any built `.img` or `.elf` directly under QEMU in clear:

```bash
/home/dan/.local/xPacks/@xpack-dev-tools/qemu-arm/9.2.4-1.1/.content/bin/qemu-system-aarch64 \
  -M raspi4b \
  -smp 4 \
  -nographic \
  -serial stdio \
  -semihosting-config enable=on,target=native \
  -kernel zig-out/firmware/rpi4b/smp-test4.img
```

**Explanation of every QEMU flag:**

- `-M raspi4b`: Emulates the Raspberry Pi 4 Model B machine (BCM2711 SoC, 2 GB RAM, GIC-400 at `0xFF840000`, PL011 UART0 at `0xFE201000`, ARM Generic Timer).
- `-smp 4`: Instantiates all 4 Cortex-A72 CPU cores (Core 0 enters at `0x80000`; Cores 1–3 wait in the spin-table at `0xE0`, `0xE8`, `0xF0`).
- `-nographic`: Disables GUI video output and keeps execution in the terminal.
- `-serial stdio`: Routes PL011 UART0 (`0xFE201000`) directly to your terminal's standard input/output.
- `-semihosting-config enable=on,target=native`: Traps `HLT #0xF000` semihosting instructions so `board.hw_result.ok()` (`SYS_EXIT`) cleanly terminates the QEMU process with exit code `0` on `PASS` or `1` on `FAIL`.
- `-kernel zig-out/firmware/rpi4b/<test>.img`: Loads the raw binary image at physical address `0x80000` and starts Core 0 in EL2.

---

### 5.6 Running Tests in Clear: Physical Hardware & OpenOCD Commands

All physical hardware tests use **OpenOCD** over JTAG or SWD with **ARM Semihosting** enabled:

- **No GDB is needed**: OpenOCD loads the `.elf` directly into RAM/Flash and resumes the target.
- **No serial port capture is needed for verdicts**: When a test finishes, `board.hw_result.ok()` executes `semihosting.write0("\nRESULT: PASS\n")` followed by `semihosting.exit(0)` (`SYS_EXIT`), which prints `RESULT: PASS` directly on OpenOCD's stdout/stderr log.

```text
┌────────────────────────────────────────────────────────────────────────────┐
│             Physical Hardware Execution & Semihosting Pipeline             │
└────────────────────────────────────────────────────────────────────────────┘
  ┌──────────────────────────┐    USB     ┌───────────────────────────────┐
  │ Linux Host (`test/hw.sh`)│───────────►│ Debug Probe                   │
  │ • Launches xPack OpenOCD │            │ • RPi Debug Probe (2e8a:000c) │
  │ • Streams OpenOCD log to │◄───────────│ • WCH-Link / ST-Link V2       │
  │   zig-out/hw-logs/*.log  │            └───────┬───────────────┬───────┘
  │ • Polls for RESULT: PASS │                    │ JTAG / SWD    │ UART TX/RX
  └──────────────────────────┘                    ▼               ▼
                                          ┌───────────────────────────────┐
                                          │ Physical Target Board         │
                                          │ • RPi 4 B (4x Cortex-A72)     │
                                          │ • Luckfox Lyra (3x Cortex-A7) │
                                          │ • Pico 2 / Pico / STM32F4     │
                                          │                               │
                                          │ Semihosting Trap:             │
                                          │   HLT #0xF000 / BKPT 0xAB     │
                                          │   ──► SYS_WRITE0 ("RESULT..") │
                                          │   ──► SYS_EXIT (0x20026)      │
                                          └───────────────────────────────┘
```

---

#### A. Automated Wrapper Commands (`test/hw.sh`)

```bash
# 1. Raspberry Pi 4 B (AArch64, 4x Cortex-A72 over JTAG):
cd /home/dan/Desktop/micro-os-plu-iii-smp-zig-pr-github/micro-os-plus-iii-aarch64
./test/hw.sh rpi4b zig-out/firmware/rpi4b/smp-test4.elf 90
./test/hw.sh rpi4b zig-out/firmware/rpi4b/smp-mem-inter-test.elf 120

# Skip the 10-second watchdog reset if the board was just power-cycled:
SKIP_RESET=1 ./test/hw.sh rpi4b zig-out/firmware/rpi4b/sd-test.elf 60

# 2. Luckfox Lyra B (AArch32, RK3506 3x Cortex-A7 over SWD):
cd /home/dan/Desktop/micro-os-plu-iii-smp-zig-pr-github/micro-os-plus-iii-aarch32
./test/hw.sh luckfox-lyra zig-out/firmware/luckfox-lyra/smp-test2.elf 120
# Or via zig build run:
/home/dan/zig-x86_64-linux-0.17.0/zig build run -Dtest=smp-test2

# 3. Cortex-M Boards (Pico 2, Pico, BlackPill STM32F411/F412, Nucleo-F411 over SWD):
cd /home/dan/Desktop/micro-os-plu-iii-smp-zig-pr-github/micro-os-plus-iii-cortexm
./test/hw.sh pico2 zig-out/firmware/pico2/smp-test2.elf 120
./test/hw.sh pico zig-out/firmware/pico/smp-test2.elf 120
./test/hw.sh weactf411 zig-out/firmware/weactf411/rtos-apis.elf 120
# Or via zig build run:
/home/dan/zig-x86_64-linux-0.17.0/zig build run -Dboard=pico2 -Dtest=smp-test2
/home/dan/zig-x86_64-linux-0.17.0/zig build run -Dboard=pico -Dtest=smp-test2
```

All hardware logs are saved to `zig-out/hw-logs/<board>/<test>.log`.

---

#### B. OpenOCD Commands in Clear (Exact Underlying Invocations)

Below are the exact, unadorned OpenOCD commands executed on each platform so you can run or debug OpenOCD manually in a terminal.

Assuming the xPack OpenOCD binary and scripts path:

```bash
OCD="$HOME/.local/xPacks/@xpack-dev-tools/openocd/0.12.0-7.1/.content/bin/openocd"
OCD_SCRIPTS="$HOME/.local/xPacks/@xpack-dev-tools/openocd/0.12.0-7.1/.content/openocd/scripts"
```

##### 1. Raspberry Pi 4 B (BCM2711, 4x Cortex-A72 — JTAG via Raspberry Pi Debug Probe)

Running a test on the Raspberry Pi 4 B consists of two OpenOCD phases because the Pi 4 B has no physical `nRESET` pin on its JTAG header:

**Step 1 — Trigger BCM2711 Watchdog SoC Reset (`boards/rpi4b/reset.cfg`):**

```bash
"$OCD" \
  -s boards/rpi4b \
  -s "$OCD_SCRIPTS" \
  -f boards/rpi4b/openocd.cfg \
  -c "init" \
  -c "targets bcm2711.cpu0; catch {halt 1000}" \
  -c "catch {mww 0xfe100024 0x5a000001}" \
  -c "catch {mww 0xfe10001c 0x5a000020}" \
  -c "shutdown"
```

- `mww 0xfe100024 0x5a000001`: Writes password `0x5A000000` + timeout `1` to `PM_WDOG`.
- `mww 0xfe10001c 0x5a000020`: Writes password `0x5A000000` + `WRCFG_FULL_RESET` to `PM_RSTC`, immediately resetting all 4 Cortex-A72 cores back to the VideoCore bootrom.

**Step 2 — Wait 10 Seconds for VideoCore GPU Boot:**

```bash
sleep 10
```

*(Allows the VideoCore GPU to read `config.txt` with `enable_jtag_gpio=1`, configure GPIO 22–27 to ALT4 JTAG, and park Core 0 at `0x200` and Cores 1–3 in the spin-table with MMU/caches off).*

**Step 3 — Connect, Enable Semihosting & HDE on All 4 Cores, Load ELF into DRAM, and Resume:**

```bash
"$OCD" \
  -s boards/rpi4b \
  -s "$OCD_SCRIPTS" \
  -f boards/rpi4b/openocd.cfg \
  -c "init" \
  -c "targets bcm2711.cpu0" \
  -c "halt" \
  -c "arm semihosting enable" \
  -c "targets bcm2711.cpu1; arm semihosting enable" \
  -c "targets bcm2711.cpu2; arm semihosting enable" \
  -c "targets bcm2711.cpu3; arm semihosting enable" \
  -c "targets bcm2711.cpu0" \
  -c "rpi4b_enable_hde" \
  -c "load_image zig-out/firmware/rpi4b/smp-test4.elf" \
  -c "reg pc 0x80000" \
  -c "resume" \
  -c "sleep 300000"
```

**What each OpenOCD command does:**

- `-f boards/rpi4b/openocd.cfg`: Selects `cmsis-dap` (`0x2e8a:0x000c`), `transport select jtag`, `adapter speed 4000`, defines `bcm2711.cpu0..cpu3`, and attaches `examine-start` (`rpi4b_unwedge`) and `examine-end` (`rpi4b_enable_core_hde`) hooks.
- `targets bcm2711.cpu0; halt`: Halts Core 0 in `EL2H`.
- `arm semihosting enable` (on `cpu0..cpu3`): Tells OpenOCD to service `HLT #0xF000` semihosting traps on whichever core calls `board.hw_result.ok()`.
- `rpi4b_enable_hde`: Sets bit 14 (`HDE`, Halting Debug Enable) in each core's `EDSCR` (`0x80410088`, `0x80510088`, `0x80610088`, `0x80710088`) via the APB-AP so `HLT #0xF000` enters debug halt state instead of throwing a synchronous exception.
- `load_image zig-out/firmware/rpi4b/smp-test4.elf`: Writes the ELF `PT_LOAD` segments (`.text`, `.rodata`, `.data`) directly into DRAM starting at `0x80000`.
- `reg pc 0x80000; resume`: Sets Core 0's program counter to `_start` (`0x80000`) and resumes execution.

---

##### 2. Luckfox Lyra B (RK3506, 3x Cortex-A7 — SWD via CMSIS-DAP)

```bash
"$OCD" \
  -s boards/luckfox-lyra \
  -s "$OCD_SCRIPTS" \
  -f boards/luckfox-lyra/openocd.cfg \
  -c "targets rk3506.a7.0" \
  -c "halt" \
  -c "arm semihosting enable" \
  -c "set _s [rk3506.a7.0 arm mrc 15 0 1 0 0]" \
  -c "rk3506.a7.0 arm mcr 15 0 1 0 0 [expr {\$_s & ~0x1005}]" \
  -c "rk3506.a7.0 arm mcr 15 0 7 5 0 0" \
  -c "rk3506.a7.0 arm mcr 15 0 7 5 6 0" \
  -c "rk3506.a7.0 arm mcr 15 0 8 7 0 0" \
  -c "load_image zig-out/firmware/luckfox-lyra/smp-test2.elf" \
  -c "resume 0x00200000"
```

**What each OpenOCD command does:**

- `arm mrc 15 0 1 0 0` / `arm mcr 15 0 1 0 0`: Reads CP15 `SCTLR` and clears bits `M` (bit 0, MMU), `C` (bit 2, D-cache), and `I` (bit 12, I-cache) so loading a new ELF into DRAM does not collide with stale virtual mappings.
- `arm mcr 15 0 7 5 0 0` (`ICIALLU`), `7 5 6 0` (`BPIALL`), `8 7 0 0` (`TLBIALL`): Invalidates I-cache, branch predictor, and unified TLB before `load_image`.
- `load_image ...` & `resume 0x00200000`: Loads the ELF at `0x00200000` in DRAM and starts Core 0.

---

##### 3. Raspberry Pi Pico 2 (RP2350, 2x Cortex-M33 — SWD via Raspberry Pi Debug Probe)

```bash
"$OCD" \
  -s "$OCD_SCRIPTS" \
  -f interface/cmsis-dap.cfg \
  -c "cmsis-dap vid_pid 0x2e8a 0x000c" \
  -c "adapter speed 5000" \
  -c "set USE_CORE { cm0 cm1 }" \
  -c "set USE_SMP 0" \
  -f target/rp2350.cfg \
  -c "gdb port disabled" -c "tcl port disabled" -c "telnet port disabled" \
  -c "init" \
  -c "reset init" \
  -c "program zig-out/firmware/pico2/smp-test2.elf verify" \
  -c "reset init" \
  -c "targets rp2350.cm1" -c "arm semihosting enable" -c "resume" \
  -c "targets rp2350.cm0" -c "arm semihosting enable" -c "resume"
```

**What each OpenOCD command does:**

- `set USE_CORE { cm0 cm1 }; set USE_SMP 0`: Exposes both Cortex-M33 cores (`rp2350.cm0` and `rp2350.cm1`) independently so they can be resumed in sequence.
- `program ... verify`: Flashes the ELF into QSPI XIP flash and verifies the checksum.
- `reset init`: Re-initializes XIP flash and parks `cm1` in the BootROM FIFO wait loop.
- `targets rp2350.cm1; arm semihosting enable; resume` followed by `cm0`: Resumes Core 1 first so it is waiting in the BootROM when Core 0 boots and sends the multicore FIFO launch handshake.

---

##### 4. Raspberry Pi Pico (RP2040, 2x Cortex-M0+ — SWD via Raspberry Pi Debug Probe)

```bash
"$OCD" \
  -s "$OCD_SCRIPTS" \
  -f interface/cmsis-dap.cfg \
  -c "cmsis-dap vid_pid 0x2e8a 0x000c" \
  -c "transport select swd" \
  -c "adapter speed 15000" \
  -c "set FLASHSIZE 0x200000" \
  -c "set USE_CORE BOTH" \
  -f target/rp2040.cfg \
  -c "gdb port disabled" -c "tcl port disabled" -c "telnet port disabled" \
  -c "init" \
  -c "reset init" \
  -c "program zig-out/firmware/pico/smp-test2.elf verify" \
  -c "reset init" \
  -c "targets rp2040.core1" -c "arm semihosting enable" -c "resume" \
  -c "targets rp2040.core0" -c "arm semihosting enable" -c "resume"
```

**What each OpenOCD command does:**

- `set FLASHSIZE 0x200000; set USE_CORE BOTH`: Sets the 2 MiB QSPI flash size and instructs `target/rp2040.cfg` to expose `rp2040.core0` and `rp2040.core1` as separate targets rather than a hardware-thread SMP group.
- `reset init`: Runs the RP2040 ROM `CX` flash setup so XIP is mapped and both cores are halted cleanly.
- `targets rp2040.core1; arm semihosting enable; resume` before `rp2040.core0`: Resumes Core 1 into the BootROM FIFO launch loop before Core 0 starts, and keeps OpenOCD attached with semihosting enabled on both cores (essential on ARMv6-M Cortex-M0+, where `DHCSR` cannot be read by software and an unhandled `BKPT 0xAB` would escalate to HardFault).

---

##### 5. WeAct BlackPill STM32F411CE / STM32F412RE (Cortex-M4F — SWD via CMSIS-DAP / WCH-Link)

```bash
"$OCD" \
  -s "$OCD_SCRIPTS" \
  -f interface/cmsis-dap.cfg \
  -c "cmsis-dap vid_pid 0x1a86 0x8011" \
  -c "transport select swd" \
  -c "adapter speed 4000" \
  -f target/stm32f4x.cfg \
  -c "gdb port disabled" -c "tcl port disabled" -c "telnet port disabled" \
  -c "init" \
  -c "reset halt" \
  -c "program zig-out/firmware/weactf411/rtos-apis.elf verify" \
  -c "arm semihosting enable" \
  -c "reset run"
```

*(For `nucleof411`, replace `-f interface/cmsis-dap.cfg -c "cmsis-dap vid_pid ..."` with `-f interface/stlink.cfg`).*
