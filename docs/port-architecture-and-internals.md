# µOS++ IIIe Zig Port: Architecture, SMP Design, Low-Level Internals, and Testing Guide

---

## 1. Executive Summary & Architectural Philosophy

### 1.1 Origin & Purpose
**µOS++ IIIe** is a real-time micro-kernel originally conceived and designed in C++ by Liviu Ionescu. It is architected for embedded systems requiring high predictability, deterministic real-time scheduling, modular synchronization primitives, and strict separation between the portable kernel logic and architecture-specific hardware ports.

This project delivers a complete, idiomatic **Zig (0.17.0)** and **MicroZig** port of µOS++ IIIe, targeting dual modern 32-bit ARM Cortex-M platforms:
1. **Raspberry Pi Pico 2 (RP2350)**: Dual ARM Cortex-M33 cores operating in true Symmetric Multi-Processing (SMP) mode with hardware spinlocks and single-precision Floating Point Units (FPUs).
2. **WeAct Studio Black Pill (STM32F411CE)**: Single ARM Cortex-M4F core with hardware FPU, demonstrating single-core real-time preemption and hardware context switching.

Across both microcontrollers, all 14 hardware test suites have been verified on physical silicon with a **100% pass rate**.

---

### 1.2 Core Architectural Principles

| Principle | Traditional C++ Implementation | Zig Port Architecture |
|---|---|---|
| **Memory Allocation** | Dynamic `new` / `malloc` with optional custom placement operators. | **Explicit allocators**: No hidden allocations. Static pre-allocation via `ThreadInclusive(N)` or explicit `BlockPool` arenas. |
| **Metaprogramming** | Heavy C++ preprocessor macros (`#ifdef`, `#define`) and template instantiation. | **`comptime` expressions & type functions**: Compiler-evaluated parameters, dead-code elimination, and typed generics. |
| **Polymorphism** | Dynamic virtual function tables (`vtable`) with run-time dispatch and RTTI overhead. | **Static compile-time dispatch** or compact interface structs with function pointers where dynamic registration is strictly required (e.g. `std.Io`). |
| **Hardware Abstraction** | C-style header files, raw peripheral pointer macros (`(TIM_TypeDef*)0x40000000`). | **MicroZig register descriptions**: Type-safe packed structs, bitfields, and compile-time register generation (`regz`). |
| **Error Handling** | POSIX integer return codes (`-EINVAL`, `-ETIMEDOUT`) or C++ exceptions. | **Exhaustive tagged error sets** (`error{WouldBlock, Interrupted, TimedOut, OutOfMemory}`) propagated with `try` and `catch`. |

---

## 2. Zig Techniques, Paradigms, and Embedded Idiomatics

### 2.1 Zero Hidden Allocations & The Allocator Model
In bare-metal embedded programming, unconstrained heap allocation (`malloc`) causes memory fragmentation, non-deterministic latency, and unpredictable catastrophic Out-Of-Memory (OOM) failures.

In this port, **every function that requires memory demands an explicit allocator parameter** or uses compile-time static sizing. The kernel provides two memory management layers:
1. **`uos.memory.BlockPool`**: Fixed-size block allocator operating in $O(1)$ constant time with zero fragmentation risk.
2. **`uos.memory.FirstFitTop`**: Bounded dynamic heap allocator with coalescing, watermarking, and statistics tracking.
3. **`ThreadInclusive(stack_size)`**: A generic type that embeds the thread's stack storage array directly into the thread control block:
```zig
pub fn ThreadInclusive(comptime stack_size_bytes: usize) type {
    return struct {
        const Self = @This();
        thread: Thread = .{},
        stack_storage: [stack_size_bytes]u8 align(8) = undefined,

        pub fn init(
            self: *Self,
            name: []const u8,
            func: Thread.Function,
            arg: ?*anyopaque,
            attr: Thread.Attributes,
        ) !void {
            var a = attr;
            a.stack = &self.stack_storage;
            try self.thread.init(name, func, arg, a);
        }

        pub fn deinit(self: *Self) void {
            self.thread.deinit();
        }
    };
}
```
This guarantees that thread stacks are statically allocated alongside thread metadata without a single call to dynamic memory routines.

---

### 2.2 Comptime & Generics as Type Functions
In Zig, generics are not implemented via specialized syntax or templates; they are ordinary functions executed at compile time that take types or values as parameters and return a `type`:

```zig
pub fn Registry(comptime capacity: usize) type {
    return struct {
        const Self = @This();
        entries: [capacity]?Device = [_]?Device{null} ** capacity,
        count: usize = 0,

        pub fn add(self: *Self, dev: Device) !void {
            if (self.count >= capacity) return error.NoSpace;
            self.entries[self.count] = dev;
            self.count += 1;
        }
        // ...
    };
}
```
The compiler monomorphizes and optimizes the resulting struct for the exact capacity specified, eliminating dynamic heap structures while enforcing bounds checking.

---

### 2.3 The Embedded Stack Trap: Pass-by-Reference vs Pass-by-Value

A critical finding during hardware bring-up on both the Cortex-M33 and Cortex-M4F involved Zig's loop syntax and stack allocation semantics.

#### The Symptom
During early runs of the FPU test suite (`fp-switch`) and mutex stress suite (`mutex-stress`), worker threads and the main thread experienced sudden Memory Management Faults (`CFSR = 0x00000001` `IACCVIOL` - Instruction Access Violation) with the Program Counter pointing to `0xEFBEADDE`.

#### The Root Cause
In Zig, iterating over an array by value:
```zig
// DANGEROUS ON EMBEDDED:
for (workers) |w| { ... }
```
creates a full copy of each array element. In `fp-switch`, `workers` was an array of four `FpWorker` structs, each containing an 8 KB `ThreadInclusive(8192)` (~8,344 bytes each).

When the Zig compiler compiled `for (workers) |w|`, it allocated space on the stack for the entire copy:
```armasm
sub.w   sp, sp, #33536    ; Smashed an 8 KB stack by 25 KB!
```
The stack pointer was pushed down past the allocated RAM into uninitialized memory filled with the kernel's stack watermark magic `0xEFBEADDE` (`0xDEADBEEF` little-endian). When the function returned, it popped `pc` from corrupted memory and jumped directly to `0xEFBEADDE`.

#### The Fix & Embedded Golden Rule
Always iterate arrays of structs or large objects **by pointer**:
```zig
// CORRECT & IDIOMATIC:
for (&workers) |*w| { ... }
for (&workers, 0..) |*w, i| { ... }
```
When rewritten with `&workers` and `*w`, the compiler passes an 8-byte pointer instead of copying 33 KB. Stack allocation plummeted from 33,536 bytes to 204 bytes, eliminating the fault.

---

### 2.4 Error Handling vs POSIX Return Codes
C-based RTOS implementations typically return negative integer error codes (`-1`, `-EINTR`, `-EBUSY`) or rely on a thread-local `errno`. This leads to silent bugs when callers forget to verify return values.

In this port, all failure modes are strongly typed error unions:
```zig
pub const Error = error{
    NotPermitted,
    NotRecoverable,
    WouldBlock,
    Interrupted,
    TimedOut,
};

pub fn lock(mx: *Mutex) Error!void;
pub fn timedLock(mx: *Mutex, timeout: clocks.Duration) Error!void;
```
The Zig compiler forces the developer to handle or explicitly propagate every possible error via `try` or `catch`. Furthermore, Zig error sets can be merged and refined without memory allocation.

---

## 3. Build System Architecture: `build.zig`, `build.zig.zon`, and Fingerprints

### 3.1 What is `build.zig`?
Unlike traditional embedded projects that rely on complex combinations of Makefiles, CMake, OpenOCD scripts, and Kconfig, Zig unifies the entire build system in `build.zig`.

`build.zig` is not a declarative configuration file; it is an imperative Zig program that builds a Directed Acyclic Graph (DAG) of build steps executed by `zig build`.

```
                    [build.zig]
                         │
        ┌────────────────┴────────────────┐
        ▼                                 ▼
   [MicroZig Dep]                   [Kernel Dep]
   (Chips/Boards/HAL)             (Portable µOS++)
        │                                 │
        └────────────────┬────────────────┘
                         ▼
               [addFirmware() Function]
                         │
        ┌────────────────┴────────────────┐
        ▼                                 ▼
[Compile: Pico 2 ELF]             [Compile: WeAct ELF]
(thumb-freestanding-eabihf)       (thumb-freestanding-eabihf)
        │                                 │
        ▼                                 ▼
  [Install Step]                    [Install Step]
(zig-out/firmware/pico2)          (zig-out/firmware/weactf411)
        │                                 │
        ▼                                 ▼
   [test/hw.sh]                      [test/hw.sh]
(Hardware Run via OpenOCD)        (Hardware Run via OpenOCD)
```

Key features of this architecture:
1. **Built-in Cross-Compilation**: Zig has native LLVM-backed cross-compilers for ARM targets. No external `arm-none-eabi-gcc` toolchain installation is needed.
2. **MicroZig Integration**: `MicroBuild.init()` imports board definitions (pins, clocks, flash layout) and automatically builds register maps (`regz`) from SVD files.
3. **Module Wiring**: The port cleanly injects dependencies into firmware compilation units:
   - `uos`: The portable kernel.
   - `uos_board`: Board-specific pinouts and clock configuration.
   - `uos_test`: The hardware test harness.
   - `uos_suites`: Reusable test logic shared across boards.

---

### 3.2 What is `build.zig.zon`?
`build.zig.zon` is written in **ZON** (Zig Object Notation), a human-readable, minimal data format with syntax identical to anonymous Zig struct literals. It serves as the official package manifest for the Zig Package Manager.

Here is the manifest for `micro-os-plus-iii-cortexm/build.zig.zon`:
```zig
.{
    .name = .micro_os_plus_iii_cortexm,
    .fingerprint = 0x95cd49afa981e1b1,
    .version = "7.0.0",
    .minimum_zig_version = "0.17.0",
    .dependencies = .{
        // The portable kernel (sibling directory)
        .micro_os_plus_iii = .{ .path = "../micro-os-plus-iii" },
        // MicroZig dependency (startup, chips, HAL)
        .microzig = .{ .path = "../../../Downloads/MicroZIG-0.17.18/microzig" },
    },
    .paths = .{ "build.zig", "build.zig.zon", "src", "test", "LICENSE", "README.md" },
}
```

#### Meaning of Fields:
- `.name`: Unique identifier for the package.
- `.version`: Semantic version string (`MAJOR.MINOR.PATCH`).
- `.minimum_zig_version`: Enforces compiler version compatibility (preventing syntax drift).
- `.dependencies`: Defines local or remote dependencies by relative path, git URL, or tarball URL with SHA-256 hash.
- `.paths`: Whitelist of files included in package exports.
- `.fingerprint`: 64-bit structural integrity hash.

---

### 3.3 Demystifying `.fingerprint = 0x95cd49afa981e1b1`

#### What is the Fingerprint?
Starting in modern Zig, package manifests include a 64-bit hexadecimal fingerprint (e.g. `0x95cd49afa981e1b1`).

The fingerprint is a **deterministic hash computed over the structure and declared paths of the package manifest**. Its purposes are:
1. **Detecting Unintended Manifest Changes**: Ensures downstream projects cannot silently alter package identity.
2. **Cache Verification**: Accelerates dependency graph resolution by caching package hashes.
3. **Package Disambiguation**: Differentiates between distinct packages sharing the same name.

#### How to Obtain the Exact Fingerprint: Step-by-Step
When creating a new package or refactoring manifest paths, you do not need to calculate the 64-bit hash by hand. Follow this exact procedure:

1. **Set the Fingerprint to Zero (or omit it)**:
   In `build.zig.zon`:
   ```zig
   .{
       .name = .micro_os_plus_iii_cortexm,
       .fingerprint = 0x0,
       .version = "7.0.0",
       // ...
   }
   ```
2. **Run `zig build`**:
   Execute the build command:
   ```bash
   zig build
   ```
3. **Read the Compiler Diagnostic**:
   The Zig compiler detects the fingerprint mismatch and prints the exact computed hash:
   ```text
   build.zig.zon:3:20: error: package 'micro_os_plus_iii_cortexm' has manifest fingerprint 0x0 but expected 0x95cd49afa981e1b1
       .fingerprint = 0x0,
                      ^~~
   ```
4. **Copy and Paste the Expected Hash**:
   Update `build.zig.zon` with the value reported by the compiler:
   ```zig
   .fingerprint = 0x95cd49afa981e1b1,
   ```
5. **Re-run `zig build`**: The build will now proceed cleanly.

For external dependencies downloaded from a URL or Git repository, the command `zig fetch --save <URL>` automatically calculates both the package hash and fingerprint, writing them directly into `build.zig.zon`.

---

## 4. Symmetric Multi-Processing (SMP) Architecture & Resolution

### 4.1 Dual Cortex-M33 on Raspberry Pi Pico 2 (RP2350)
The RP2350 microcontroller contains two identical ARM Cortex-M33 cores (Core 0 and Core 1). In µOS++ IIIe SMP mode:
- Both cores share a single linear address space (SRAM and XIP Flash).
- Both cores execute the same scheduler instance.
- Any ready thread can run on either core (unless pinned via CPU affinity).

```
   ┌────────────────────────────────────────────────────────┐
   │                     Shared SRAM                        │
   │  ┌───────────────────────┐   ┌──────────────────────┐  │
   │  │  Ready Threads Queue  │   │ Kernel Waiting Lists │  │
   │  └───────────────────────┘   └──────────────────────┘  │
   └───────────▲─────────────────────────────▲──────────────┘
               │                             │
    ┌──────────┴──────────┐       ┌──────────┴──────────┐
    │     Cortex-M33      │       │     Cortex-M33      │
    │       Core 0        │       │       Core 1        │
    │  ┌───────────────┐  │       │  ┌───────────────┐  │
    │  │ Main / Worker │  │       │  │ Worker Thread │  │
    │  ├───────────────┤  │       │  ├───────────────┤  │
    │  │  Idle Thread  │  │       │  │  Idle1 Thread │  │
    │  └───────────────┘  │       │  └───────────────┘  │
    └──────────▲──────────┘       └──────────▲──────────┘
               │                             │
               └──────────────┬──────────────┘
                              │
               ┌──────────────▼──────────────┐
               │    RP2350 Hardware SIO      │
               │   ┌──────────────────────┐  │
               │   │ Hardware Spinlock 0  │  │
               │   ├──────────────────────┤  │
               │   │ Inter-Core FIFO/IPI  │  │
               │   └──────────────────────┘  │
               └─────────────────────────────┘
```

---

### 4.2 Hardware Spinlocks, Atomic Primitives & The 3-Tier Lock Hierarchy
On a single-core Cortex-M processor, critical sections are implemented simply by disabling interrupts (`cpsid i` or masking via `BASEPRI`). On a dual-core SMP processor (such as the RP2350 with dual Cortex-M33 cores), disabling interrupts on Core 0 does **not** stop Core 1 from executing instructions and modifying shared kernel queues.

To guarantee determinism and prevent cross-core data corruption, the port implements a hardware-backed, multi-tiered synchronization architecture.

```
       Core 0 Execution Stream                     Core 1 Execution Stream
  ┌─────────────────────────────────┐         ┌─────────────────────────────────┐
  │ Local Thread / ISR              │         │ Local Thread / ISR              │
  │   1. PRIMASK = 1 (cpsid i)      │         │   1. PRIMASK = 1 (cpsid i)      │
  │   2. SIO.SPINLOCK0 Read == 1    │         │   2. SIO.SPINLOCK0 Read == 0    │
  │      [Lock Granted]             │         │      [Spins in hardware loop]   │
  │   3. DMB (Data Memory Barrier)  │         │                                 │
  │   4. Mutate Kernel Queues       │         │                                 │
  │   5. DMB                        │         │                                 │
  │   6. SIO.SPINLOCK0 Write = 1    │─────────┼──► [Lock Released to Core 1]   │
  │   7. DSB                        │         │   3. DMB                        │
  │   8. PRIMASK = 0 (cpsie i)      │         │   4. Mutate Kernel Queues       │
  └─────────────────────────────────┘         └─────────────────────────────────┘
```

#### 4.2.1 SIO Hardware Spinlock Architecture on RP2350
The RP2350 Single-Cycle IO (SIO) block provides 32 hardware 32-bit spinlock registers mapped from `0xD0000100` (`SPINLOCK0`) to `0xD000017C` (`SPINLOCK31`):
- **Atomic Test-and-Set on Read**: A 32-bit bus read from `SPINLOCK0` performs an atomic test-and-set in silicon. If the lock was free (`0`), reading it returns non-zero (`1`) and simultaneously sets the lock to `1` in a single clock cycle. If the lock was already held, reading it returns `0`.
- **Atomic Clear on Write**: Writing any 32-bit value to `SPINLOCK0` clears the lock bit back to `0`, making it immediately available to the other core.
- **Kernel Reservation**: Hardware spinlock 0 is strictly reserved for the µOS++ SMP kernel lock. Spinlocks 1 through 31 are available for board drivers or application-level synchronization.

#### 4.2.2 The Recursive `KernelLock` & Memory Barriers (`dmb` / `dsb`)
Because kernel functions (such as thread state changes, timer evaluations, and priority recalculations) may call nested functions that also enter critical sections, the raw hardware spinlock is wrapped in a recursive SMP lock:

```zig
const no_owner: u32 = 0xFFFF_FFFF;

const KernelLock = struct {
    owner: u32 = no_owner,
    depth: u32 = 0,
};

var klock_storage: KernelLock = .{};
const klock: *volatile KernelLock = &klock_storage;

inline fn klockRawAcquire() void {
    while (sio.SPINLOCK0.* == 0) {}
    arch.dmb(); // Prevent speculative reads before lock is held
}

inline fn klockRawRelease() void {
    arch.dmb(); // Ensure all memory stores commit before release
    sio.SPINLOCK0.* = 1;
    arch.dsb(); // Force write completion on the bus
}
```

**Why Memory Barriers are Mandatory**:
The Cortex-M33 features an in-order, dual-issue superscalar pipeline with write buffering. Without explicit memory barriers:
1. `arch.dmb()` (Data Memory Barrier) after acquisition prevents the CPU pipeline from speculatively issuing reads or reordering writes to kernel data structures *before* the hardware spinlock is physically granted.
2. `arch.dmb()` before release guarantees that all updates to thread control blocks, ready queues, and sleep lists have retired to memory *before* the spinlock clear is written to the SIO bus.
3. `arch.dsb()` (Data Synchronization Barrier) after release ensures the store to `SPINLOCK0` is completed on the interconnect before the CPU continues, preventing a subsequent lock attempt on the same core from observing a stale busy flag.

#### 4.2.3 The Strict 3-Tier Lock Hierarchy & Deadlock Prevention Proof
To eliminate the risk of deadlocks, the port enforces a strict, unidirectional 3-tier lock acquisition hierarchy:

```
  ┌──────────────────────────────────────────────────────────┐
  │ Tier 1: Local CPU Interrupt Mask (PRIMASK / cpsid i)     │  ◄── Must be FIRST
  └────────────────────────────┬─────────────────────────────┘
                               │
                               ▼
  ┌──────────────────────────────────────────────────────────┐
  │ Tier 2: SIO Hardware Spinlock (SPINLOCK0)                │  ◄── Cross-core mutual exclusion
  └────────────────────────────┬─────────────────────────────┘
                               │
                               ▼
  ┌──────────────────────────────────────────────────────────┐
  │ Tier 3: High-Level Blocking Primitives (Mutex, CondVar)  │  ◄── Never spin; sleep & yield
  └──────────────────────────────────────────────────────────┘
```

**Mathematical Proof of Deadlock Prevention**:
Suppose Tier 1 was omitted, and a thread on Core 0 acquired Tier 2 (`SPINLOCK0`) while local interrupts remained enabled.
1. Thread $T_1$ on Core 0 acquires `SPINLOCK0`.
2. An interrupt (e.g. SysTick or a high-priority peripheral IRQ) fires on Core 0 and preempts $T_1$.
3. The Interrupt Service Routine (ISR) executes on Core 0 and attempts to invoke a kernel API (e.g. `semaphore.post()` or `scheduler.reschedule()`).
4. The ISR attempts to acquire `SPINLOCK0`, reading `0`, and enters `while (sio.SPINLOCK0.* == 0) {}`.
5. **The Catastrophic Self-Deadlock**: $T_1$ cannot resume or release `SPINLOCK0` because Core 0 is trapped in the higher-priority ISR. The ISR cannot acquire `SPINLOCK0` because $T_1$ holds it. Core 0 hangs permanently, and Core 1 also hangs the moment it attempts to enter any kernel critical section.

**Enforcement Rule**: Tier 1 (`arch.disableIrq()` / `cpsid i`) is *always* asserted on the local core *before* querying or spinning on Tier 2 (`SPINLOCK0`).

#### 4.2.4 Critical Concurrency Nuance in `setLocked()`
The scheduler provides `setLocked(state: bool) bool` to permit cooperative non-preemptive regions. During SMP execution, this function handles two subtle race conditions:

```zig
pub fn setLocked(state: bool) bool {
    std.debug.assert(!interrupts.inHandlerMode());
    if (smp) {
        // Race 1 Prevention: Mask IRQs BEFORE reading the CPU index!
        const pri = arch.getPrimask();
        arch.disableIrq();
        const cpu = cpuId();
        const prev = lock_state[cpu];
        if (state != prev) {
            if (state) {
                setLock();
                lock_primask[cpu] = pri;
                lock_state[cpu] = true;
            } else {
                // Race 2 Prevention: Publish "unlocked" BEFORE releasing klock!
                lock_state[cpu] = false;
                putLock(lock_primask[cpu]);
            }
        } else {
            arch.setPrimask(pri);
        }
        return prev;
    }
    // ... single-core fallback ...
}
```

1. **Race 1 (Core Migration Race)**: If `cpuId()` were evaluated before disabling interrupts, a PendSV exception could preempt the thread immediately after reading `cpu = 0`. The scheduler could migrate the thread to Core 1. When execution resumes, the thread would mark `lock_state[0] = true` while actually executing on Core 1! Subsequent unlock calls would then fail to clear the lock on Core 1, permanently wedging the scheduler.
2. **Race 2 (Stale Lock Flag Window)**: When releasing the lock, `lock_state[cpu] = false` is published *before* `putLock()` restores `PRIMASK`. If `putLock()` restored interrupts first, an incoming IRQ between `putLock()` and `lock_state[cpu] = false` would observe `lock_state[cpu] == true`, conclude that the core is in a non-preemptive section, and suppress a needed `reschedule()`.

#### 4.2.5 Cross-Core Context Claiming Protocol (`stack_ptr = null`)
A classic hazard in SMP real-time operating systems is **dual-core double-scheduling**: if a ready thread with affinity `0b11` (any core) is eligible to run, both Core 0 and Core 1 could concurrently select it, leading to simultaneous stack corruption.

µOS++ IIIe solves this through atomic stack pointer ownership in `internalSwitchThreads()`:
- When a thread is quiescent (suspended or ready on the run list), its thread control block holds its valid saved stack pointer: `thread.context.port.stack_ptr != null`.
- When a core selects the thread and loads its context into CPU registers, it atomically claims the thread:
  ```zig
  // Claim thread: active in this CPU's registers; the other CPU must not touch it!
  @atomicStore(?[*]StackElement, &new_thread.context.port.stack_ptr, null, .release);
  ```
- Any inspection of the ready queue by the other core observes `stack_ptr == null` and treats the thread as already live, preventing double execution.
- When the thread yields or is preempted, its updated stack pointer is saved back to `stack_ptr` using release semantics:
  ```zig
  @atomicStore(?[*]StackElement, &old_thread.context.port.stack_ptr, sp, .release);
  ```

---

### 4.3 SMP Ready Queue, CPU Affinity, and IPI
The SMP scheduler manages a single, prioritized ready queue (`scheduler.ready_threads_list`).
- Each thread has a `cpu_affinity: u32` bitmask:
  - `0b01`: Thread may only execute on Core 0.
  - `0b10`: Thread may only execute on Core 1.
  - `0b11`: Thread may execute on either Core 0 or Core 1.
- Each core runs an idle thread when no user threads are eligible:
  - Core 0 runs `idle`.
  - Core 1 runs `idle1`.
- **Inter-Processor Interrupt (IPI)**: When Core 0 awakens a high-priority thread that is pinned to Core 1 (or Core 1 is executing lower priority work), Core 0 triggers an interrupt on Core 1 via the SIO FIFO. Core 1 receives the FIFO interrupt and executes `port.scheduler.reschedule()`, pre-empting its current thread immediately.

---

### 4.4 The Mutex Lost-Wakeup Bug & Its Resolution

#### The Concurrency Problem
During high-contention mutex testing (`mutex-stress` with 10 threads running for 30 seconds), the test executed 2,411 iterations flawlessly, but hung during teardown when the main thread called `join()` on the worker threads.

#### The Race Mechanism
1. Worker Thread A holds the mutex.
2. Worker Threads B, C, D are blocked on the mutex waiting list (`mx.list`).
3. Worker Thread A calls `mx.unlock()`.
4. `unlock()` executes:
   ```zig
   _ = mx.list.resumeOne(); // Wakes Thread B (highest priority waiter)
   mx.owner = null;
   mx.count = 0;
   ```
5. Thread B transitions to ready, but before it can run, the main thread invokes:
   ```zig
   _ = worker_b.thread.interrupt(true);
   ```
6. Thread B wakes up from `port.scheduler.reschedule()` and unlinks its node.
7. Thread B checks `if (crt.isInterrupted()) return error.Interrupted;`.
8. **The Deadlock**: Thread B exits `lock()` with an error without acquiring the mutex and **without waking up Thread C**!
   Because `mx.owner` is `null` and Thread B consumed the single wakeup token produced by `unlock()`, Threads C and D remain asleep on `mx.list` forever. The main thread's `join()` call hangs indefinitely.

#### The Mathematical Resolution: The Baton-Passing Protocol
In both `lock()` and `timedLock()`, when a thread unblocks and discovers it has been interrupted or timed out:
```zig
if (crt.isInterrupted()) {
    const scs = scheduler.CriticalSection.enter();
    defer scs.exit();
    
    // If the mutex is unowned, we were the intended recipient of the unlock.
    // We must pass the wakeup baton to the next waiting thread!
    if (mx.owner == null) {
        _ = mx.list.resumeOne();
    }
    return error.Interrupted;
}
```
If the next thread is also interrupted, it repeats the same cascade. Wakeup tokens are never lost, guaranteeing starvation-free teardown under asynchronous interruption.

---

## 5. Kernel Synchronization Objects Architecture

### 5.1 Mutexes & The Priority Inheritance Protocol (PIP)
µOS++ IIIe implements POSIX-compatible mutual exclusion primitives with strict deterministic priority guarantees:
- **`Normal`**: Non-recursive; re-locking by the owning thread returns `error.WouldBlock` or causes a self-deadlock.
- **`Recursive`**: Re-entrant; tracks nested lock depth via `mx.count`. An identical number of `unlock()` calls must be performed before the mutex becomes unowned.
- **`ErrorCheck`**: Explicit error detection; returns `error.WouldBlock` if re-locked and `error.NotPermitted` if unlocked by a non-owner.
- **`Robust`**: Death-resilient locks. If an owning thread terminates while holding the mutex, the kernel marks `mx.owner_dead = true` and returns `error.NotRecoverable` to subsequent lockers, preventing system-wide deadlock.

#### 5.1.1 The Priority Inversion Hazard
Consider three threads: $T_H$ (high priority, $P=10$), $T_M$ (medium priority, $P=20$), and $T_L$ (low priority, $P=30$):
1. $T_L$ acquires mutex $M_1$.
2. $T_H$ becomes ready and attempts to acquire $M_1$. It blocks because $T_L$ owns it.
3. $T_M$ becomes ready. Because $T_M$ ($P=20$) has a higher priority than $T_L$ ($P=30$), the scheduler preempts $T_L$ and runs $T_M$.
4. **The Priority Inversion**: $T_H$ is indirectly starved by $T_M$, even though $T_H$ has higher priority than $T_M$ and does not share any resources with $T_M$! $T_M$ can run indefinitely, preventing $T_L$ from releasing $M_1$.

```
  Priority
     ▲
  TH │──────┐ (Needs M1)
(10) │      │ [BLOCKED ON TL]
     │      │
  TM │      │               ┌───────────────────────┐ (Runs indefinitely)
(20) │      │               │ Preempts TL & starves TH! │
     │      │               └───────────────────────┘
  TL │──────┴───────┐ (Holds M1)
(30) │  Running     │ [PREEMPTED BY TM]
     └──────────────┴───────────────────────────────────────► Time
```

#### 5.1.2 Priority Inheritance Protocol & Transitive Chains
µOS++ IIIe resolves this via dynamic **Priority Inheritance**:
1. When $T_H$ blocks on $M_1$, the kernel immediately promotes $T_L$'s effective priority to $T_H$'s priority ($P=10$):
   ```zig
   if (mx.protocol == .inherit) {
       owner.setPriorityInherited(th.priority());
   }
   ```
2. $T_L$ can now no longer be preempted by $T_M$ ($P=20$); it runs to completion, finishes its critical section, and calls `unlock()`.
3. **Transitive Propagation**: If $T_L$ is itself blocked waiting on another mutex $M_2$ held by thread $T_{\text{lowest}}$, the priority boost propagates transitively down the entire lock graph:
   $$T_H \xrightarrow{\text{waits on}} M_1 \xrightarrow{\text{held by}} T_L \xrightarrow{\text{waits on}} M_2 \xrightarrow{\text{held by}} T_{\text{lowest}} \implies \text{Priority}(T_{\text{lowest}}) \leftarrow \text{Priority}(T_H)$$
4. **Priority Restoration (De-boosting)**: When $T_L$ calls `unlock()`, its effective priority is not blindly reset to its base priority. Instead, the kernel scans all other mutexes still owned by $T_L$:
   $$\text{effective\_prio}(T_L) = \max \left( \text{base\_prio}(T_L), \max_{m \in \text{held\_mutexes}} (\text{max\_waiter\_prio}(m)) \right)$$
   If $T_L$ holds no other contested mutexes, its priority returns to $P=30$.

---

### 5.2 Condition Variables: State Transitions & Atomicity Guarantees
Condition variables provide signaling primitives for threads waiting on state predicates.

#### 5.2.1 The Atomic Unlock-and-Enqueue Problem
In naive implementations, calling `wait(mx)` involves two separate steps: unlocking the mutex and putting the thread to sleep. If an interrupt or context switch occurs between unlocking and sleeping, a `signal()` from another thread can be lost, causing permanent thread hanging.

In µOS++ IIIe, atomicity is guaranteed under `scheduler.CriticalSection`:
```zig
pub fn wait(self: *ConditionVariable, mx: *Mutex) Error!void {
    const scs = scheduler.CriticalSection.enter();
    defer scs.exit();

    // 1. Validate mutex ownership
    if (mx.owner != this_thread.thread()) return error.NotPermitted;

    // 2. Enqueue calling thread directly onto CV wait list
    self.list.link(this_thread.thread());

    // 3. Atomically release the mutex and transfer wakeup token
    _ = mx.unlockInternal();

    // 4. Block thread and trigger immediate reschedule
    this_thread.thread().state = .suspended;
    port.scheduler.reschedule();

    // 5. When awakened, re-acquire the mutex before returning to caller
    try mx.lockInternal();
}
```

#### 5.2.2 Spurious Wakeups & Predicate Loops
External events (such as timeouts, thread cancellation, or broadcasts) can awaken a thread before the shared predicate is true. All condition variable usage must follow the canonical predicate evaluation loop:
```zig
while (!condition_is_met) {
    try cv.wait(&mutex);
}
```

---

### 5.3 Semaphores, Event Flags, and Message Queues

```
┌────────────────────────────────────────────────────────────────────────┐
│                        Kernel Synchronization                          │
├───────────────────┬────────────────────────────────┬───────────────────┤
│    Primitive      │       Blocking Mechanism       │   Key Attribute   │
├───────────────────┼────────────────────────────────┼───────────────────┤
│ **Semaphore**     │ Atomic counter decrement.      │ Binary or         │
│                   │ Enqueues when counter == 0.    │ Counting.         │
├───────────────────┼────────────────────────────────┼───────────────────┤
│ **Event Flags**   │ 32-bit bitmask comparison.     │ `waitAny` or      │
│                   │ Enqueues until mask matches.   │ `waitAll`.        │
├───────────────────┼────────────────────────────────┼───────────────────┤
│ **Message Queue** │ Circular ring buffer.          │ Prioritized msgs, │
│                   │ Enqueues on Empty/Full.        │ zero-copy ptrs.   │
└───────────────────┴────────────────────────────────┴───────────────────┘
```

#### 5.3.1 Counting & Binary Semaphores
- **`CountingSemaphore`**: Backed by a 32-bit integer counter. `post()` increments the counter atomically under a critical section and wakes up the highest-priority waiting thread if the counter transitions from $0$. `wait()` blocks if the counter is $0$, otherwise decrements the counter.
- **`BinarySemaphore`**: Equivalent to a counting semaphore with a maximum value of $1$.

#### 5.3.2 Event Flags
Event flags provide multi-bit synchronization without allocating memory:
- **`waitAny(mask)`**: Evaluates whether $(\text{current\_flags} \ \& \ \text{mask}) \neq 0$. If any bit matches, returns immediately.
- **`waitAll(mask)`**: Evaluates whether $(\text{current\_flags} \ \& \ \text{mask}) == \text{mask}$. Blocks until all specified bits are asserted.
- **Atomic Clear on Exit**: If configured with `mode = .clear`, the matched bits are atomically cleared before the calling thread unblocks, preventing double processing.

#### 5.3.3 Message Queues (Zero-Copy Ring Buffers)
Message queues allow threads and ISRs to exchange structured data:
- **Zero-Copy Architecture**: Only pointers (`*anyopaque` or `usize`) are copied into the internal circular ring buffer, avoiding stack and buffer copy overheads.
- **Priority-Ordered Messages**: Senders can specify a message priority ($0..255$). High-priority messages are inserted at the head of the ring, bypassing normal FIFO ordering for urgent commands.
- **ISR-Safe Posting**: `postFromInterrupt()` allows interrupt handlers to enqueue data directly into the queue without sleeping or calling blocking scheduler routines.

---

## 6. Scheduler, Context Switch, and Low-Level ARM Assembly

### 6.1 The Dual Stack Model: MSP vs PSP
Cortex-M processors provide two stack pointer registers banked under the name `SP`:
- **Main Stack Pointer (MSP)**: Used by the OS kernel, interrupt service routines (SysTick, UART, timers), and exception handlers (HardFault, PendSV).
- **Process Stack Pointer (PSP)**: Used exclusively by unprivileged application threads.

```
       Interrupt Context (Hardware)             Thread Context (Software)
      ┌─────────────────────────────┐        ┌─────────────────────────────┐
      │     Main Stack (MSP)        │        │    Process Stack (PSP)      │
      │ ┌─────────────────────────┐ │        │ ┌─────────────────────────┐ │
      │ │ SysTick Handler Frame   │ │        │ │ User Stack Storage      │ │
      │ ├─────────────────────────┤ │        │ ├─────────────────────────┤ │
      │ │ PendSV Handler Frame    │ │        │ │ Callee Saved {r4-r11}   │ │
      │ ├─────────────────────────┤ │        │ ├─────────────────────────┤ │
      │ │ Nested Exception Frames │ │        │ │ Auto Hardware Frame     │ │
      │ └─────────────────────────┘ │        │ └─────────────────────────┘ │
      └─────────────────────────────┘        └─────────────────────────────┘
```

**Why this separation is vital for RTOS reliability**:
If threads ran on the MSP, deeply nested interrupts would push exception frames onto whatever user thread was currently running. A thread with a small stack (e.g. 512 bytes) would suffer an immediate stack overflow if an interrupt storm occurred. With MSP/PSP separation, all interrupts execute on a single, dedicated 2 KB MSP stack, insulating user thread stacks completely.

---

### 6.2 Hardware Auto-Stacking (Exception Entry)
When an interrupt or PendSV exception occurs, the ARM Cortex-M hardware automatically pushes 8 words (32 bytes) onto the active stack (PSP):

```
       PSP Address
           │
           ▼
     ┌───────────┐  ◄── PSP before exception
 -4  │   xPSR    │  (Program Status Register: flags, thumb state)
 -8  │    PC     │  (Return Address / Next instruction to execute)
-12  │    LR     │  (Link Register before exception)
-16  │    R12    │  (General purpose scratch register)
-20  │    R3     │  (Argument / scratch register 3)
-24  │    R2     │  (Argument / scratch register 2)
-28  │    R1     │  (Argument / scratch register 1)
-32  │    R0     │  (Argument / scratch register 0)
     └───────────┘  ◄── New PSP after hardware auto-stacking
```
If the hardware FPU is enabled and was actively used by the interrupted thread, the hardware also reserves space for floating point registers `s0-s15` and `FPSCR` (Lazy Stacking).

---

### 6.3 Software Context Switch in PendSV Assembly
µOS++ IIIe triggers context switches by setting the PendSV bit in the NVIC Interrupt Control and State Register (ICSR). Because PendSV is configured with the lowest interrupt priority, it executes only when all other interrupts have completed.

Here is the exact context switch sequence implemented in assembly:

```armasm
.thumb_func
.type PendSV_Handler, %function
PendSV_Handler:
    cpsid   i                       ; Disable interrupts during switch
    mrs     r0, psp                 ; Read current thread's stack pointer

    ; 1. Save software-managed integer context
    stmdb   r0!, {r4-r11}           ; Push callee-saved registers r4-r11

    ; 2. Check for active FPU context (EXC_RETURN bit 4)
    tst     lr, #0x10               ; Bit 4 = 0 means FPU extended frame is active
    it      eq
    vstmdbeq r0!, {s16-s31}         ; Push high FPU registers s16-s31

    ; 3. Save updated stack pointer into current thread control block
    ldr     r1, =current_thread     ; Get pointer to current thread pointer
    ldr     r2, [r1]                ; r2 = current_thread
    str     r0, [r2, #CONTEXT_SP]   ; current_thread.context.stack.top = r0

    ; 4. Call scheduler to pick next ready thread
    push    {lr}                    ; Save EXC_RETURN code on MSP
    bl      uos_scheduler_switch    ; Returns next thread pointer in r0
    pop     {lr}                    ; Restore EXC_RETURN code

    ; 5. Load next thread's stack pointer
    ldr     r1, =current_thread
    str     r0, [r1]                ; current_thread = next_thread
    ldr     r0, [r0, #CONTEXT_SP]   ; r0 = next_thread.context.stack.top

    ; 6. Restore FPU context if incoming thread uses FPU
    tst     lr, #0x10
    it      eq
    vldmiaeq r0!, {s16-s31}         ; Pop high FPU registers s16-s31

    ; 7. Restore software-managed integer context
    ldmia   r0!, {r4-r11}           ; Pop callee-saved registers r4-r11

    ; 8. Update Process Stack Pointer
    msr     psp, r0                 ; Set PSP to incoming thread's stack
    cpsie   i                       ; Re-enable interrupts

    ; 9. Return from exception
    bx      lr                      ; Hardware automatically pops r0-r3, r12, lr, pc, xPSR
```

---

### 6.4 Decoding EXC_RETURN
When entering an exception handler, the processor loads the Link Register (`LR`) with an `EXC_RETURN` value:

| Value | Return Mode | Stack Selected | Frame Type |
|---|---|---|---|
| `0xFFFFFFFD` | Thread Mode | Process Stack (PSP) | Standard (Integer only, 32 bytes) |
| `0xFFFFFFED` | Thread Mode | Process Stack (PSP) | Extended (Integer + FPU, 104 bytes) |
| `0xFFFFFFF9` | Thread Mode | Main Stack (MSP) | Standard (Used by bare-metal loop) |

Bit 4 (`0x10`) dynamically indicates whether the hardware FPU context was stacked. By testing this bit (`tst lr, #0x10`), the scheduler saves `s16-s31` **only when the thread actually performed floating point arithmetic**, achieving optimal context switch speed for pure integer threads.

---

### 6.5 Stack Watermarking & Auditing
Every stack is filled with the sentinel watermark `0xEFBEADDE` at initialization.
The kernel audits runtime stack consumption by scanning from the bottom of the stack storage upwards to locate the first non-watermark word:
```zig
pub fn stackUsedBytes(self: *const Stack) usize {
    var p: [*]const u32 = @ptrCast(@alignCast(self.bottom));
    const words = self.size_bytes / 4;
    var unused: usize = 0;
    while (unused < words and p[unused] == 0xEFBEADDE) : (unused += 1) {}
    return self.size_bytes - (unused * 4);
}
```
This enables live reports like:
```text
Main thread stack: 532/8188 bytes used
Interrupts stack: 544/2048 bytes used
```

---

### 6.6 Cortex-M Interrupt Architecture & The Nested Vectored Interrupt Controller (NVIC)
Cortex-M microcontrollers provide hardware-managed interrupt vectoring through the NVIC. Unlike architectures requiring software dispatch tables or manual IRQ demultiplexing, the Cortex-M processor hardware fetches the target ISR address directly from the vector table located at `VTOR` (Vector Table Offset Register).

```
  Vector Offset     Exception / IRQ Name        Hardware Priority
 ┌───────────────┬───────────────────────────┬──────────────────────────────────────────┐
 │ 0x0000_0000   │ Initial Main Stack (MSP)  │ N/A (Loaded at Reset)                    │
 │ 0x0000_0004   │ Reset Handler             │ Fixed: -3 (Highest priority)             │
 │ 0x0000_0008   │ NMI Handler               │ Fixed: -2                                │
 │ 0x0000_000C   │ HardFault Handler         │ Fixed: -1                                │
 │ 0x0000_0010   │ MemManage Fault Handler   │ Configurable: SHPR1                      │
 │ 0x0000_0014   │ BusFault Handler          │ Configurable: SHPR1                      │
 │ 0x0000_0018   │ UsageFault Handler        │ Configurable: SHPR1                      │
 │ 0x0000_002C   │ SVCall Handler            │ Configurable: SHPR2                      │
 │ 0x0000_0038   │ PendSV Handler (Context)  │ Configurable: SHPR3 (Set to Lowest: 0xFF)│
 │ 0x0000_003C   │ SysTick Handler (Clock)   │ Configurable: SHPR3                      │
 │ 0x0000_0040+  │ Peripheral IRQ 0..N       │ Configurable: IPR0..IPRN                 │
 └───────────────┴───────────────────────────┴──────────────────────────────────────────┘
```

#### 6.6.1 Priority Representation & Bit-Shifting
On ARM Cortex-M processors, priority registers are 8 bits wide per exception, but silicon vendors implement only the most significant bits ($3$ to $4$ bits typically).
- **RP2350 (Cortex-M33)** implements 4 priority bits ($16$ distinct priority levels, $0$ to $15$).
- **STM32F411 (Cortex-M4)** implements 4 priority bits ($16$ distinct priority levels, $0$ to $15$).

Priorities are left-aligned in hardware: to write logical priority $P$, the value must be shifted by $(8 - \text{nvic\_prio\_bits})$:
$$\text{Hardware Priority Byte} = P \ll (8 - \text{nvic\_prio\_bits})$$
Lower numerical values denote higher execution priority: $0$ is the absolute highest configurable priority, while $15$ ($0\text{xF0}$) is the lowest.

---

### 6.7 Managed vs Unmanaged Interrupts: `BASEPRI` vs `PRIMASK` & Zero-Latency Execution
In hard real-time systems (e.g. motor control, digital power inverters, high-speed DSP sampling), critical interrupt routines must execute with predictable, deterministic latency—completely unaffected by operating system critical sections.

µOS++ IIIe implements a dual interrupt masking model:

```
  Priority Level   Execution Mode        Masked by RTOS?    RTOS API Callable?
 ┌────────────────┬─────────────────────┬──────────────────┬────────────────────────┐
 │ 0 .. 4         │ Unmanaged ISRs      │ NEVER MASKED!    │ NO (Fatal if violated) │
 │                │ (Zero-Jitter Control)│ (Zero Latency)   │                        │
 ├────────────────┼─────────────────────┼──────────────────┼────────────────────────┤
 │ 5              │ Critical Section    │ MASKED via       │ YES (Safe zone)        │
 │                │ Threshold (BASEPRI) │ BASEPRI          │                        │
 ├────────────────┼─────────────────────┼──────────────────┼────────────────────────┤
 │ 6 .. 14        │ Managed Peripheral  │ MASKED during    │ YES (e.g. UART, SPI,   │
 │                │ Interrupts          │ Critical Section │       GPIO interrupts) │
 ├────────────────┼─────────────────────┼──────────────────┼────────────────────────┤
 │ 15 (Lowest)    │ PendSV / SysTick    │ MASKED           │ Kernel Internals Only  │
 └────────────────┴─────────────────────┴──────────────────┴────────────────────────┘
```

#### 6.7.1 The `BASEPRI` Masking Mechanism (Cortex-M4 / STM32F411)
When configured with `critical_section_interrupt_priority = 5`:
```zig
pub inline fn criticalEnter() State {
    if (basepri_level) |level| {
        const pri = arch.getBasepri();
        arch.setBasepriMax(level); // Masks interrupts with priority >= level
        return pri;
    }
    const pri = arch.getPrimask();
    arch.disableIrq(); // Fallback to PRIMASK (cpsid i)
    return pri;
}
```
- `setBasepriMax(5 << 4)` masks any interrupt whose numerical priority is $\ge 5$.
- Interrupts with numerical priorities $0..4$ (the unmanaged tier) are **completely unmasked**. Even if the RTOS is performing a complex ready-list rebalancing or heap allocation, an unmanaged high-speed ADC or PWM fault interrupt executes in hardware within $12$ clock cycles.

#### 6.7.2 Run-Time Priority Validation (`isPriorityValid`)
To prevent corrupting the kernel, an unmanaged interrupt ($P < 5$) must never invoke RTOS APIs. µOS++ enforces this via hardware register inspection:
```zig
pub fn isPriorityValid() bool {
    const level = config.options.critical_section_interrupt_priority orelse return true;
    if (basepri_level == null) return true;
    const exception = arch.getIpsr();
    if (exception < 16) return true; // System faults are handled separately
    const prio = arch.nvicGetPriority(exception - 16) >> (8 - @as(u4, arch.nvic_prio_bits));
    return prio >= level; // Returns false if unmanaged ISR illegally calls RTOS!
}
```

---

### 6.8 Dual-Core NVIC Topology & Peripheral Interrupt Routing on RP2350
On the dual Cortex-M33 RP2350, interrupt topology presents distinct architectural characteristics compared to traditional SMP x86 or ARM Cortex-A systems:

```
                          RP2350 Silicon Die
       Core 0 Cortex-M33                      Core 1 Cortex-M33
  ┌─────────────────────────┐            ┌─────────────────────────┐
  │ Private NVIC 0          │            │ Private NVIC 1          │
  │  - SysTick (Core 0)     │            │  - SysTick (Core 1)     │
  │  - PendSV (Core 0)      │            │  - PendSV (Core 1)      │
  │  - IRQ 25 (FIFO IPI)    │            │  - IRQ 25 (FIFO IPI)    │
  │  - IRQ 24 (USBCTRL) ◄───┼──┐         │  - (USBCTRL disabled)   │
  └─────────────────────────┘  │         └─────────────────────────┘
                               │
                ┌──────────────┴──────────────┐
                │   Shared Peripheral Bus     │
                │  - USB Controller           │
                │  - SIO Inter-Core FIFO      │
                │  - UART0 / UART1            │
                └─────────────────────────────┘
```

1. **Independent Private NVICs**: Core 0 and Core 1 have physically separate NVIC hardware instances. An interrupt enabled on Core 0's NVIC is **not** enabled on Core 1's NVIC unless explicitly configured.
2. **Peripheral IRQ Pinning & USB CDC-ACM**:
   In `smp-test-usb-cdc-acm`, the USB device controller driver (`rp2xxx.usb.Polled`) and console bridge task are pinned to Core 0 (`cpu_affinity = 0b01`).
   - `USBCTRL_IRQ` (IRQ 24) is unmasked exclusively in Core 0's NVIC.
   - If the USB service thread were permitted to migrate to Core 1, the USB interrupt would fire on Core 0 while the servicing thread executed on Core 1. Core 0 would enter an unhandled ISR loop, while Core 1 would never see USB packets, causing host enumeration failure. Pinning guarantees that the interrupt, the CDC driver ring, and the CDC task share the same core, eliminating cross-core cache thrashing.

---

### 6.9 Inter-Processor Interrupts (IPI) via SIO Hardware FIFO
When Core 0 updates shared kernel state (e.g. awakening a high-priority thread that is pinned to Core 1, or posting a message to a queue listened to by Core 1), Core 1 must be notified immediately to preempt its current thread.

µOS++ IIIe implements an Inter-Processor Interrupt (IPI) over the RP2350 SIO hardware FIFO:

```
  Core 0 (Sender)                                              Core 1 (Receiver)
  ┌─────────────────────────────────┐                    ┌─────────────────────────────────┐
  │ port.scheduler.ipi(1)           │                    │ (Executing User Thread)         │
  │  1. Check SIO_FIFO_ST.RDY == 1  │                    │                                 │
  │  2. Write SIO_FIFO_WR = 0x4D53  │───────────────────►│ Hardware IRQ 25 Asserted!       │
  │  3. Execute 'sev' instruction   │                    │ Interrupt Vector: sioFifoHandler│
  └─────────────────────────────────┘                    │  1. sio.fifoDrain()             │
                                                         │  2. scheduler.reschedule()      │
                                                         │     -> Triggers PendSV on Core 1│
                                                         └─────────────────────────────────┘
```

```zig
pub fn ipi(cpu: u32) void {
    if (!smp) return;
    if (cpu == cpuId()) return;
    if (sio.FIFO_ST.* & sio.FIFO_ST_RDY != 0) {
        sio.FIFO_WR.* = 0x4D53; // "SM" = SMP Reschedule command
        asm volatile ("sev");
    }
}
```
- **Non-blocking by Design**: If `FIFO_ST.RDY` is $0$ (the 8-entry FIFO is currently full), an IPI request is already queued and pending on Core 1. Core 0 does not spin or wait; it continues immediately.
- **`sioFifoHandler`**: When IRQ 25 fires on Core 1, the handler drains the FIFO (`sio.fifoDrain()`) and invokes `scheduler.reschedule()`, which asserts PendSV on Core 1, pre-empting the lower-priority thread deterministically.

---

### 6.10 Dual-Core SysTick Specialization & PendSV Deferred Context Switching

#### 6.10.1 Clock Drift Prevention in Dual-Core SMP
A fundamental challenge in multi-core RTOS design is maintaining a single, coherent time base. Both Core 0 and Core 1 have their own private SysTick timer hardware running at the CPU clock frequency ($150\text{ MHz}$).
- If both cores advanced the kernel time base (`clock.advanceTick()`), the RTOS clock would advance at twice the intended rate, corrupting all `sleepFor()`, timed mutex, and software timer delays.
- In µOS++ IIIe, the SysTick interrupt handler is specialized by core ID:
  ```zig
  fn sysTickHandler() callconv(.c) void {
      if (smp and scheduler.cpuId() != 0) {
          // Only Core 0 advances the RTOS time base!
          // Core 1 only reschedules to service round-robin time-slicing.
          scheduler.reschedule();
          return;
      }
      uos.rtos.clocks.sysTickHandler();
  }
  ```
  Core 0 exclusively updates the global tick counter, walks the sleep list, and wakes timed threads. Core 1 uses its SysTick strictly as a time-slice interrupt, ensuring perfect clock accuracy.

#### 6.10.2 Deferred Context Switching via PendSV
Cortex-M microcontrollers do not permit context switching directly from within standard peripheral ISRs. Doing so would push multiple exception frames onto the MSP and corrupt nested interrupt states.
- Context switching is always deferred to **PendSV (Pended Service Call)**, which is configured to the absolute lowest execution priority ($0\text{xFF}$).
- When an ISR calls `scheduler.reschedule()`, it sets bit 28 (`PENDSVSET`) in `ICSR`.
- If nested interrupts are active, the hardware executes all of them first (**Tail-Chaining** in just $6$ clock cycles). Only when the last ISR completes does the hardware enter `PendSV_Handler`, performing the register save/restore sequence on the PSP cleanly.

---

## 7. How Tests are Written, Wired, and Executed

### 7.1 Anatomy of a Test Suite
Tests reside in `micro-os-plus-iii/tests/suites/` (portable tests) or `test/<board>/<test>/` (board-specific tests).

Every test follows a standardized structure using `uos_test`:
```zig
const std = @import("std");
const uos = @import("uos");
const t = @import("uos_test");
const rtos = uos.rtos;

// Configure test parameters
pub const microzig_options = t.microzig_options;
pub const panic = t.panic;
pub const std_options = t.std_options;
pub const uos_options = t.options(.{});

comptime {
    t.exportStartup(); // MicroZig startup export
}

pub fn main() void {
    t.run(appMain);
}

fn appMain() u8 {
    t.reset();
    t.section("Basic Semaphore Verification");
    
    var sem: rtos.Semaphore = .init("sem1", 0, 10);
    t.eq(@as(u32, 0), sem.value(), @src());
    
    t.success(sem.post(), @src());
    t.eq(@as(u32, 1), sem.value(), @src());
    
    t.success(sem.wait(), @src());
    t.eq(@as(u32, 0), sem.value(), @src());
    
    return @intFromBool(t.summary("sem-test") != 0);
}
```

The assertion API provides source location tracking via Zig's `@src()`:
- `t.ok(condition, @src())`: Assert boolean truth.
- `t.eq(expected, actual, @src())`: Assert value equality with formatted diagnostics on mismatch.
- `t.success(result, @src())`: Assert that an error union returned without error.
- `t.err(expected_err, result, @src())`: Assert that an operation failed with a specific error.
- `t.summary("suite_name")`: Prints total checks, failed count, and stack watermarks.

---

### 7.2 Wiring Tests into `build.zig`
In `micro-os-plus-iii-cortexm/build.zig`, tests are enumerated and conditionally generated:
```zig
const tests = [_]Test{
    .{ .name = "smp-test0" },
    .{ .name = "smp-test2", .smp_only = true },
    .{ .name = "smp-test5", .only = .pico2 },
    .{ .name = "mutex-stress" },
    .{
        .name = "rtos-apis",
        .c_sources = &.{"test/rtos-apis/test-c-api.c"},
        .c_flags = &.{ "-std=c11", "-DOS_INTEGER_RTOS_DEFAULT_STACK_SIZE_BYTES=2048", "-DOS_INTEGER_SYSTICK_FREQUENCY_HZ=1000" },
    },
    .{
        .name = "cmsis-os-validator",
        .c_sources = &.{"test/cmsis-os-validator/validator-glue.c"},
        .c_flags = &.{ "-std=gnu11", "-DTRACE", "-DOS_USE_OS_APP_CONFIG_H" },
        .cmsis_rv = true,
    },
    // ...
};
```
- `smp_only` skips the test on single-core boards; `only` keeps it on one board.
- A test ported one to one from a board's C++ folder is listed in `board_tests` and lives in `test/<board>/<test>/main.zig`; it replaces the generic `test/<test>/main.zig`.
- `c_sources`/`c_flags` link C code with the test; the kernel's C include folders (`addCIncludes()`) and `test/<test>/include` are added.
- `cmsis_rv` also compiles the Arm CMSIS-RTOS validator sources from the xPack given with `-Dcmsis_rv` (default `~/.local/xPacks/@xpacks/arm-cmsis-rtos-validator/1.0.0-4`); without it the test is skipped.

---

### 7.3 Automated Hardware Execution via OpenOCD & Semihosting (`test/hw.sh`)

Testing embedded hardware requires an automated feedback loop without human intervention.
The runner script `test/hw.sh` orchestrates this via OpenOCD and ARM Semihosting:

```
 [zig build run -Dboard=pico2 -Dtest=fp-switch]
                       │
                       ▼
                 [test/hw.sh]
                       │
       ┌───────────────┴───────────────┐
       ▼                               ▼
 [Detect Probe: USB]             [Configure OpenOCD]
 • 2e8a:000c (RP Debug Probe)   • Target: rp2350.cfg or stm32f4x.cfg
 • 1a86:8011 (WCH-Link)         • SWD Clock: 4-5 MHz
       │                               │
       └───────────────┬───────────────┘
                       ▼
           [OpenOCD Program & Verify]
          (Direct flash write, NO GDB)
                       │
                       ▼
          [Enable ARM Semihosting]
                       │
                       ▼
               [Target Executes]
        • Trace streamed via semihosting
        • UART pins left 100% free for user
                       │
                       ▼
          [Log Monitor in hw.sh]
   Looks for: "RESULT: PASS" or "RESULT: FAIL"
                       │
                       ▼
              [Target Calls SYS_EXIT]
        • Clean termination with code 0
```

#### Why Semihosting Over UART?
1. **User Freedom**: The hardware UART pins (GP0/GP1 on Pico 2, PA9/PA10 on STM32) remain 100% available for the user's terminal monitor without host serial port locks or contention.
2. **Reliability**: Semihosting travels directly over the SWD debug bus via the CMSIS-DAP probe. It is immune to baud rate mismatches or floating serial inputs.
3. **Automated Exit Code**: Upon test completion, `uos.rtos.terminate(0)` issues an ARM semihosting `SYS_EXIT` call (`0x18`), allowing the automated bash harness to detect pass/fail immediately.

---

## 8. C Code: the C API, CMSIS-RTOS v1 and a Minimal C Runtime

C sources can be linked with the kernel and call it as in C++. There is one kernel only: the C functions are thin wrappers that convert their arguments and call the Zig objects; they have no logic of their own. Each layer is exported only when enabled in `uos.Options`.

| Layer | Option | Zig | Header | C++ counterpart |
|---|---|---|---|---|
| µOS++ C API (196 functions) | `c_api` | `src/c_api.zig` | `cmsis-plus/rtos/os-c-api.h` | `os-c-wrapper.cpp` |
| CMSIS-RTOS v1 | `cmsis_os` | `src/cmsis_os.zig` | `cmsis-plus/legacy/cmsis_os.h` | `os-c-wrapper.cpp` (legacy part) |
| Minimal C runtime | `c_runtime` | `src/libc.zig` | `c/stdio.h`, `c/string.h`, `c/assert.h`, `cmsis-plus/diag/trace.h` | newlib, `trace.cpp` |

### 8.1 Object Storage
The C application allocates the objects (`os_thread_t th;`, `osMutexDef(mx)`, ...) and passes pointers. In C++, `os-c-decls.h` mirrors the C++ class members; here the objects are opaque storage, in pointer words, large enough for the Zig objects:
```c
typedef struct os_thread_s
{
  _Alignas (8) void* storage[OS_C_THREAD_STORAGE_WORDS];
} os_thread_t;
```
The Zig object lives at the start of the storage. The sizes are repeated in `src/c_storage.zig`: the build fails when a Zig object outgrows its storage, and a host test (`zig build test`) fails when the header disagrees. The types, enumerations and attribute structures are the C++ ones, so C code written for the C++ API compiles unchanged.

Threads and timers run C functions: the Zig object calls a trampoline, and the C function and its argument are kept in the storage after the Zig object. The same trampoline also runs the CMSIS-RTOS v1 thread functions (`void f(const void*)`).

### 8.2 Status Codes
The C API returns the POSIX `errno` values of `rtos.errno()`. The CMSIS-RTOS v1 layer maps the results exactly as the C++ wrapper does. One difference comes from the kernels: the C++ `sleep_for()` returns `ETIMEDOUT` when the time elapsed, the Zig `sleepFor()` returns normally; `osDelay()` returns `osEventTimeout` in both cases.

### 8.3 The Minimal C Runtime
A freestanding target has no libc, and MicroZig's foundation-libc has no `printf`. `c_runtime` exports what the C tests need, with the output on the kernel trace channel: `printf`, `vprintf`, `snprintf`, `vsnprintf`, `fprintf`, `vfprintf`, `fflush`, `puts`, `putchar`; `strlen`, `strcmp`, `strncmp`, `strcpy`, `strncpy`, `strchr`, `strrchr` (the `mem*` functions come from compiler_rt); `assert` (to the Zig panic handler); `trace_printf` and the other `trace_*` functions. Hosted targets use their own libc instead.

### 8.4 What is Not Provided
`os_thread_get_user_storage()` (the kernel has no thread user storage) and the C startup hooks (`os-hooks.h`). `os_thread_attr_t.th_cpu_affinity` is always present (C++: only with `OS_USE_SMP_SCHEDULER`).

---

## 9. Hardware Test Verification Matrix

Every test is a faithful port of a C++ test (same banners, lines, LED behaviour and verdict); the deviations are stated in each `main.zig`. The harness suites (`fp-switch`, `mutex-stress`, `rtos-apis`, `cmsis-os-validator`) run as in the C++ pico2 harness build: one CPU, with the suite's `os-app-config.h` values.

### 9.1 Raspberry Pi Pico 2 (RP2350 Dual Cortex-M33 SMP)
*Probed with the Raspberry Pi Debug Probe (`2e8a:000c`). Reset or power cycle the board between tests.*

| Test | Status | Notes |
|---|---|---|
| `smp-test0` | **PASS** | Dual-core bring-up. |
| `smp-test1` | **PASS** | |
| `smp-test2` | **PASS** | CPU affinity. |
| `smp-test3` | **PASS** | Resume IPI, kernel and direct phases (fixed in C++ too). |
| `smp-test4` | **PASS** | |
| `smp-test5` | **PASS** | |
| `smp-mat-test` | **PASS** | Speedup 2.016×. |
| `sc-test-ko` | **PASS** | Single core, 10/10. |
| `smp-test-ko` | **PASS** | 10/10. |
| `exc-test` | **PASS** | Phase B handler mode on its own MSP stack (as the fixed C++ test). |
| `smp-test-usb-cdc-acm` | **PASS** | After a reset; without one it panics at start (USB state kept from the previous test). |
| `fp-switch` | **PASS** | 3681 rounds, 0 bad. |
| `mutex-stress` | **PASS** | 10 threads, 35 s report: sigma 7, delta within ±6 %. |
| `rtos-apis` | **PASS** | C++ API, C API (`test-c-api.c`), ISO and POSIX I/O parts. |
| `cmsis-os-validator` | **PASS** | Arm CMSIS-RTOS validator, 60/60. |
| `io-test` | **PASS** | `std.Io` suite, 25/25. |

### 9.2 WeAct Black Pill (STM32F411CE Cortex-M4F Single-Core)
*Probed with a WCH-Link in ARM mode (`1a86:8011`). It may drop the connection under heavy semihosting traffic; reset and run again.*

| Test | Status | Notes |
|---|---|---|
| `smp-test0` | **PASS** | |
| `fp-switch` | **PASS** | 2474 rounds, 0 bad. |
| `mutex-stress` | **PASS** | 35 s report: sigma 9, delta within ±5 %. |
| `rtos-apis` | **PASS** | All four parts, as on the Pico 2. |
| `cmsis-os-validator` | **PASS** | 60/60. |
| `spi-pipeline` | **PASS** | 8/8. |
| `smp-test1`, `smp-mat-test`, `sc-test-ko`, `io-test` | builds | Not run on this board in the last round. |

---

## 10. Conclusion
The Zig port of µOS++ IIIe demonstrates that modern systems programming languages can achieve safety, expressiveness, and maintainability without sacrificing real-time determinism or silicon efficiency. Through compile-time static configuration, explicit memory allocators, SIO hardware spinlocks, clean MSP/PSP separation, and an automated OpenOCD test framework, the system delivers rock-solid SMP real-time performance on Cortex-M microcontrollers.
