# µOS++ IIIe Zig Port: The AArch32 Port — Architecture and Internals

Luckfox Lyra B (Rockchip RK3506, 3× Cortex-A7 + 1× Cortex-M0)

---

## 1. Purpose

`micro-os-plus-iii-aarch32` is the ARMv7-A port of the Zig µOS++ IIIe kernel (`../micro-os-plus-iii`), the counterpart of the C++ `micro-os-plus-iii-aarch32`, `smp` branch. It implements the kernel's port contract (`src/port_contract.zig`) for the three Cortex-A7 CPUs of the RK3506, in SMP, and keeps the C++ port's design: the same context frame, the same switch and IRQ entry, the same publish/claim protocol between CPUs, the same board start-up and memory map. Where the Zig port differs, this document says so.

Sources: the C++ `src/rtos/os-core.cpp`, `src/context_switch.cpp`, `src/handlers.cpp`, `src/exception_handler.cpp`, `include/cmsis-plus/rtos/port/os-inlines.h`, `include/semihosting.hpp`, and the board's `test/boards/luckfox-lyra/` (`startup.S`, `linker.ld`, `src/mmu.cpp`, `src/port_sys.cpp`, `src/rtos/port_isr.cpp`, `src/smp.cpp`, `include/*.hpp`).

---

## 2. The Machine Model

| Item | Value |
| --- | --- |
| CPUs | 3× Cortex-A7 (ARMv7-A, VFPv4 with 32 D registers, NEON), one SMP cluster |
| Interrupt controller | GIC-400: distributor 0xFF581000, CPU interface 0xFF582000 |
| Tick | each CPU's generic physical timer (PPI 29/30), 1 ms, priority 0xA0; CNTFRQ 24 MHz |
| IPI | SGI 0 (`board.ipi_sgi`) |
| Console | UART1, a 16550 at 0xFF0B0000 (pins and 115200 baud set by the miniloader) |
| DRAM | 128 MiB; the image at 0x00200000, the free store 16 MiB at 0x06400000 |
| Probe | WCH-Link CMSIS-DAP over SWD; OpenOCD, semihosting on core 0 |

The image is loaded into DRAM by OpenOCD and entered at 0x00200000; there is no flash. The Rockchip miniloader has initialised the DDR and holds CPUs 1 and 2 in reset; the Cortex-M0 is off.

The MMU maps the 4 GiB flat (VA = PA) with 1 MiB sections: DRAM Normal write-back write-allocate **Shareable** (the LDREX/STREX kernel lock needs a coherent, shareable mapping: on non-shareable non-cacheable memory the first LDREX takes an external abort), the `.dma_nc` window Normal non-cacheable, everything from 0xFF000000 Device and execute-never, the rest unmapped. `mmu_enable()` sets ACTLR.SMP (joining the coherency domain), SCTLR M, C and I, clears A (unaligned accesses allowed) and V (VBAR vectors).

---

## 3. Start-up

The board's `startup.S` and `linker.ld` are the C++ ones, with the C++ start-up chain replaced:

1. `_start` (every CPU): mask IRQ and FIQ, CNTFRQ = 24 MHz, VFP/NEON on (CPACR, FPEXC), VBAR, then dispatch on MPIDR.
2. CPU 0: the defensive boot (MMU and caches off, set/way invalidate of every cache level, I-cache, branch predictor and TLB: a hot load may find the previous image's dirty lines), the banked stacks, `.bss` cleared, `mmu_init()` (board.zig: the table, cleaned to the point of coherency, then `mmu_enable()`), then **`uos_core0_main()`** (port.zig) instead of `os_startup_initialize_hardware*()`, `__libc_init_array()` and `main()`. Zig has no static constructors.
3. CPUs 1 and 2 (once released, §7): their own banked stacks, `mmu_enable()` only (no set/way maintenance: they must not discard core 0's dirty lines in the shared L2), then `boot_core1()` / `boot_core2()`.

`uos_core0_main()` calls `board.init()` and the application's `main()`, which prints its banner and calls `uos.rtos.run()`. On a freestanding target Zig's `std.start` exports nothing, so the image root (`test/start.zig`) references the port to pull its exports in; it also supplies `std.log` on the trace channel and a panic handler that reports and ends the run with a FAIL.

---

## 4. Threads and the Context Switch

### 4.1 The frame

A suspended thread's registers are a `Frame` on its own stack (C++ `ctx_t`), lowest address first:

| Words | Contents |
| --- | --- |
| 32 | d0–d15 |
| 32 | d16–d31 |
| 2 | FPSCR, pad (8-byte alignment for `vpush`/`vpop`) |
| 2 | CPSR, PC |
| 13 | r0–r12 |
| 1 | LR |

328 bytes, checked at compile time against the assembly. The whole NEON file is saved: d16–d31 are call-clobbered under AAPCS, but a preemptive switch can land in the middle of NEON code and the thread may resume on another CPU. `contextCreate()` builds a frame at the 8-aligned top of the stack: CPSR 0x13 (SVC, ARM, IRQs on), PC the entry, r0 the argument, r1–r12 0xCCCCCCCC, LR 0.

### 4.2 Two ways in, one way out

- **Cooperative**: `scheduler.reschedule()` from thread code calls the naked `port_ctx_switch_handler`, which captures CPSR, masks IRQs and pushes the frame on the current stack.
- **Preemptive**: the naked `irq_handler` (IRQ mode) moves r0–r3, the SPSR and the return address to the interrupted thread's SVC stack and builds the same frame there, then calls `port_isr_handler(sp)`.

Both then call into Zig with the frame's address, receive the stack pointer to resume, and leave the same way: publish (§4.3), `clrex`, `vpop` d0–d31, FPSCR, then SPSR_irq and LR_irq loaded from the frame's CPSR and PC, r0–r12 and LR popped, and `movs pc, lr` in IRQ mode restores PC and CPSR at once. Before installing a cooperative switch's new stack pointer the assembly checks it lies in the board's DRAM window (`ram_base`..`ram_end`, from `board.zig`; the C++ took them from `smp.hpp`).

Zig cannot call a naked function, so `reschedule()` reaches the handler through `asm volatile ("bl port_ctx_switch_handler")`. That asm must declare what a C call clobbers: **r0–r3, r12, LR and the flags**. The handler restores the callee-saved registers and the VFP file, but its first instruction is `mrs r2, cpsr`, so the r2 it saves (and restores) is the CPSR. In C++ this is harmless, `port_ctx_switchHandler()` being an ordinary call. (A first version declared only LR; see §11.)

### 4.3 Publish and claim (SMP)

A thread whose `stack_ptr` is null is live in some CPU's registers, and the kernel's `internalSwitchThreads()` never picks it on another CPU. `port_switch_stacks()` (C++ `switch_stacks()`), with IRQs masked:

1. takes the kernel lock (owner = this CPU, depth 1);
2. lets the kernel pick the next thread;
3. if it changed: checks the claimed frame (the tripwire: inside the thread's stack, CPSR mode SVC; the Zig port also stops on a null pointer), stages the outgoing frame's publication in this CPU's `_smp_pub_addr` / `_smp_pub_val` slots, takes the incoming frame and claims the thread (`stack_ptr = null`);
4. releases the lock: owner and depth first, then the lock word (the order matters: a release of the word first lets another CPU take the lock and have its owner/depth wiped).

The assembly performs the staged store only after `mov sp, r0`, once the stack pointer has left the outgoing thread's stack: published any earlier, another CPU could resume that thread on the stack this CPU's kernel frames still occupy. Then `clrex`, so that a STREX in the incoming thread cannot succeed on a reservation of the previous one.

---

## 5. Interrupts

### 5.1 The dispatcher

`port_isr_handler()` (C++ `port_isr_handler()`, the board's `port_isr.cpp`) marks the CPU in a handler (`in_isr[cpu]`), acknowledges the GIC and:

- the timer PPI: reloads TVAL (`frequency / 1000`), EOI, on CPU 0 the kernel's `sysTickHandler()`, and a pending switch;
- SGI 0: EOI and a pending switch;
- anything else: the application's `uos_external_irq(iar)` (C++ `port_external_irq_handler()`, weak), then EOI.

A pending switch happens at the exit when the scheduler is not locked and this CPU does not hold the kernel lock; the new frame is validated (in DRAM, CPSR mode SVC) before it is returned.

### 5.2 Critical sections and the kernel lock

`criticalEnter()` saves CPSR, masks IRQs (CPSR.I) and takes the recursive kernel lock (`_smp_klock`: lock word, owner, depth); `criticalExit()` releases one level and restores the I bit. The lock word is taken with an atomic exchange (LDREX/STREX). `setLocked()` is the scheduler lock: per-CPU state plus a level of the kernel lock, with IRQs masked while held, as the C++ `locked()`.

`reschedule()` does not switch while this CPU holds the kernel lock (a switch would strand owner and depth on the outgoing thread; the C++ found this with `message_queue`), nor from a handler: both set the pending flag for the next interrupt exit.

`inHandlerMode()` is the per-CPU flag or CPSR mode IRQ/FIQ.

### 5.3 The GIC and the timer

CPU 0 initialises the distributor (all interrupts disabled and cleared, priority 0xA0, SPIs to CPU 0, level-triggered) and its CPU interface; CPUs 1 and 2 only their banked SGI/PPI priorities and CPU interface. Each CPU enables its timer PPIs; the SGIs are always enabled on the GIC-400. `scheduler.ipi(cpu)` writes GICD_SGIR.

---

## 6. Clocks

The system clock is the kernel's, driven by CPU 0's tick. The high-resolution clock is CNTPCT (`has_hardware_counter`), with `cyclesSinceTick()` from CNTP_TVAL.

---

## 7. The Secondary CPUs

`board.releaseSecondaries()` (C++ `smp::start_secondary_cores()`) writes the BootROM's SRAM mailbox (target 0x00200000 at 0xFFF80008, magic 0xDEADBEAF at 0xFFF80004), then releases each CPU's resets in CRU SOFTRST_CON00 (a Rockchip write-mask register) and sends an event. The CPU enters `_start`, then `boot_coreN()`: stage 3 in `g_core_stage[]` (what the tests wait for), `sysInit()` (CPU interface, tick), the kernel's boot pseudo-thread, and a first switch to the CPU's idle thread (the kernel creates one per CPU; C++ has the tests install them).

---

## 8. Trace, Semihosting and the Verdict

The trace writes the UART (`\n` as CR LF) and mirrors every line to semihosting, so OpenOCD's log carries the console. Semihosting is the Angel trap `svc 0x123456` in ARM state: threads run in SVC mode, so the trap overwrites LR_svc and SPSR_svc (LR is a clobber; IRQs are masked around it). The mirror is line-buffered (one SYS_WRITE0 per line, not one SYS_WRITEC per byte: every call is a debug halt and a probe round trip); the C++ buffer is shared by the CPUs, the Zig one is per CPU, so a line printed outside the console mutex cannot mix with another CPU's.

Without a debugger the SVC lands in `svc_handler`, which in the Zig port returns (`movs pc, lr`): a semihosting call is then a no-op. The C++ handler spins.

`terminate(code)` (the tests' `hw_result`): IRQs masked, the semihosting line flushed, the UART drained (LSR.TEMT) and about one second waited, then SYS_EXIT with ApplicationExit and the status. The WCH-Link bridges the UART and drops what it has not forwarded when OpenOCD disconnects at the exit (the same fix as the Cortex-M port's WeAct board); C++ exits at once.

The cost of semihosting on CPUs 1 and 2 is seconds per call on this probe: a test whose threads there print a lot is throttled by it (`smp-test3`: 11 messages in 10 s instead of ~500, measured the same with the C++ build).

---

## 9. Faults

The undefined-instruction, prefetch-abort and data-abort entries push r0–r12, the faulting PC and the SPSR on their mode's stack and call the reporters (`src/faults.zig`, C++ `exception_handler.cpp`): fault type, PC and the instruction there, IFSR/IFAR or DFSR/DFAR with the decoded status, read or write, CPACR/FPEXC/FPSCR for an undefined instruction, the registers and the SPSR's mode and masks, then "[FATAL] System halted." and a WFI loop. The report goes to the **UART only**: a semihosting call is itself a trap and could fault again. The C++ test mode (resume after a fault) is not ported.

---

## 10. The Board's Drivers

### 10.1 The SD card

`drivers/sdmmc.zig` is the RK3506 SD host, a Synopsys DesignWare MMC controller at 0xFF480000 (C++ `soc/rk3506/src/sdmmc.cpp`, from U-Boot's `dw_mmc.c` and `mmc.c`): clocks from the 24 MHz oscillator, reset and pin mux (GPIO3_A0..A5) in `hardwareInit()`; CMD0, CMD8, ACMD41 (until ready), CMD2, CMD3, CMD9 (the capacity from the CSD), CMD7, ACMD6 (4-bit), CMD16, then 12 MHz; polled PIO through the DATA FIFO, retried transfers, no DMA and no interrupts, so no cache maintenance and any CPU. Commands go through the hold register, with the C++ sample and drive phases. The diagnostic phase scans are not ported. `drivers/sd.zig` is `sd.SdCard` over it, the API of the POSIX port's host-file card (C++ `sd_dwmmc.cpp`).

### 10.2 FatFs

On hardware the C++ SD tests (`HW_BUILD`) do not format the card: they mount its **existing** FAT32 volume and keep their files in `/tests`. The Zig port does the same. FatFs R0.15a is the C `ff.c`, unchanged, with the C++ `ffconf.h` (no mkfs, 8.3 names, one volume), compiled by Zig over the kernel's freestanding C runtime (`uos_options.c_runtime`); `ff.h` and `diskio.h` are translated for Zig. `drivers/fatfs.zig` is the C++ `diskio_sd.cpp` (the `disk_*` glue: the MBR scanned for the first FAT partition, or the whole card without one, every access offset into it) and `fatfs_hw.cpp` (mount, `tests/` creation, store, append, load, size, remove, space, geometry, listing). The callers serialise access (FF_FS_REENTRANT 0), as in C++.

`drivers/flatfs.zig` (the QEMU/native path, which formats the card) is the POSIX port's, identical to the C++ one; no hardware test uses it.

### 10.3 The Cortex-M0

`smp-test-int5` uses the RK3506's fourth core as an interrupt source. It is not an SMP CPU (another ISA, outside the coherency domain). Its firmware, `test/smp-test-int5/m0/main.zig` (C++ `m0_start.c`, `m0_main.c`), is a second, Thumb, Cortex-M0 image built by `build.zig` with its own linker script (code at the M0's 0x0, data from 0x8000), converted to a raw binary and embedded in the A7 image with `@embedFile` (C++ `.incbin`). Its SysTick (8,000,000 cycles at 200 MHz, 40 ms) writes B2A CMD/DATA on mailbox channels 1 and 2; its count, `g_seq`, is the first word of its data RAM (0xFFF88000 to the A7). The A7 copies it to System SRAM at 0xFFF80000, maps it as the M0's TCM through the secure GRF (the writes the vendor TEE performs for `sip_smc_mcu_config()`, reverse-engineered in the C++ test), un-gates its clocks and releases it through the PMU.

The A7 side discovers each mailbox channel's GIC ID at run time (a controlled write latches its GICD_ISPENDR bit while the SPI is still disabled; IDs 171 and 172 on this board), routes channel 1 to CPU 1 and channel 2 to CPU 2, and counts the doorbells in `uos_external_irq()`; per-CPU rings carry them to core 0's logger.

---

## 11. Tests

| Test | What | Result |
| --- | --- | --- |
| `smp-test0` | 10 heartbeats on CPU 0 | PASS |
| `smp-test1` | semaphore ping-pong, CPUs 0/1, logger on 2 | PASS |
| `smp-test2` | mutex coherency, one worker per CPU | PASS, 6000/6000 |
| `smp-test3` | message queue producer/consumer across CPUs | PASS |
| `smp-test4` | load balancing without affinity | PASS |
| `smp-mat-test` | parallel block solver, N = 120 | PASS, 3.23× |
| `smp-pro-cons-test` | producers/consumers over every kernel object | PASS |
| `smp-num-test` | workers and file I/O, `tests/num.txt` | PASS |
| `smp-pipeline-test` | 13-thread pipeline, `tests/pipe.dat` audited | PASS, 3283 records |
| `sd_test` | four files written and read back, `tests/` | PASS |
| `smp-mat-sdcard-test` | parallel block solver, N = 200, matrices on SD | PASS, 4.62× |
| `smp-test-int5` | mailbox doorbells to CPUs 1/2, from core 0 | A7 side verified; the probe dropped at doorbell #31 |
| `smp-test-int5-m0` | the same from the Cortex-M0 | built, not run yet |

They are faithful ports of the C++ `test/luckfox-lyra/` tests; the portable ones share their source with the POSIX port's, with the Lyra C++ differences applied (3 CPUs, affinities wrapped with `% ncpu`, one packet in flight at the stop in `smp-pro-cons-test`, N = 120 / 200 and newlib's `rand()` in the solvers). `smp-num-test` formats its floating-point line with `std.fmt` (the kernel's `printf` has no floating point; the C++ is newlib's), so a value may differ in the last digit. `smp-test0` and `smp-test1` passed before the clobber fix of §4.2, with a register allocation that happened not to keep a value in r2 across a switch.

---

## 12. What the Port Found

Bugs of the Zig port itself, all found on the board:

- **The LR clobber was named `r14`** in the inline asm of the switch call; LLVM ignored it, the caller returned with `bx lr` through the address the `bl` left, and looped. Clobbers on ARM are `.lr`.
- **r2 across the switch** (§4.2): the secondary idle loop kept `&_smp_klock` in r2 across the call and got the CPSR back; CPUs 1 and 2 took a data abort at DFAR 0x20000023 in `smp-test2`. The UART fault report gave the instruction (`ldr r3, [r2, #16]`) and r2 (0x20000013).
- **The interrupt stack's magic**: the kernel's idle check asserts the bottom word of the interrupt stack; C++ fills it in `interrupts::stack()->initialize()`, the Zig port now in `scheduler.start()`.

None of these is in the C++ port.

---

## 13. Limitations

- One board, the Luckfox Lyra B; the BCM2837 boards of the C++ port (Pi Zero 2 W, Pi 3B) are not ported.
- Not ported yet: `smp_test5` (the C++ FatFs), `smp_test6`, `smp_test7` (the USB gadget), `smp_test_int` to `smp_test_int4` (GIC SGI paths, USB and SD interrupts), the SD driver's phase scans, the fault reporter's test mode.
- Semihosting is slow on CPUs 1 and 2, and the WCH-Link may drop the connection under sustained traffic (`smp-test-int5`); the UART carries the full console either way.
- The Cortex-M0's TCM mapping depends on secure GRF writes reverse-engineered from the vendor TEE; it is the open item of the real-M0 path, as in C++.
