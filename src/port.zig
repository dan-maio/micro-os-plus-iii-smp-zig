//! µOS++ IIIe Cortex-M port (the `uos_port` module).
//!
//! One port for the whole Cortex-M family, as the C++ edition's
//! `os-core.cpp`, `os-core-rp2040.cpp` and `os-core-rp2350.cpp` together:
//!
//! - single CPU (any Cortex-M, e.g. the STM32F411): PRIMASK or BASEPRI
//!   critical sections, a scalar lock state, SysTick drives the clock;
//! - SMP on the Raspberry Pi RP2040 (2x M0+) and RP2350 (2x M33): the
//!   kernel lock is SIO hardware spinlock 0, the IPI is the SIO inter-core
//!   FIFO interrupt, the CPU index is SIO.CPUID, core 1 is launched with the
//!   bootrom FIFO handshake. Only core 0 advances the RTOS clock; core 1's
//!   SysTick reschedules core 1.
//!
//! The context switch is a cooperative PendSV at the lowest priority, one
//! per core, running on the MSP; the outgoing stack pointer can therefore be
//! published immediately.
//!
//! The application root wires the vectors through MicroZig:
//!
//! ```zig
//! pub const microzig_options = uos.port.microzig_options;
//! ```

const std = @import("std");
const microzig = @import("microzig");
const uos = @import("uos");
const board = @import("uos_board");

pub const arch = @import("arch.zig");
pub const semihosting = @import("semihosting.zig");
const context = @import("context.zig");

const root = @import("root");
const config = uos.config;
const ncpu = config.ncpu;
const smp = config.smp;

const chip_name = microzig.config.chip_name;
pub const is_rp2350 = std.mem.eql(u8, chip_name, "RP2350");
pub const is_rp2040 = std.mem.eql(u8, chip_name, "RP2040");
const is_rp = is_rp2040 or is_rp2350;

comptime {
    if (smp and !is_rp) @compileError("uos_options.smp: the Cortex-M SMP port supports the RP2040 and the RP2350");
    if (ncpu > 2) @compileError("the RP2040/RP2350 have two cores");
}

/// Application options of the port, from `pub const uos_port_options` in
/// the root file.
pub const Options = struct {
    /// Launch core 1 inside `scheduler.start()`. When false, the application
    /// launches it from a thread with `launchCore1()`, as the C++ pico tests
    /// do from `os_main()`.
    launch_core1_at_start: bool = true,
};

pub const options: Options = if (@hasDecl(root, "uos_port_options")) root.uos_port_options else .{};

/// BASEPRI critical sections (ARMv7-M/v8-M, single CPU, when configured).
const basepri_level: ?u32 = if (config.options.critical_section_interrupt_priority) |prio|
    (if (!arch.is_armv6m and !smp) @as(u32, prio) << (8 - @as(u5, arch.nvic_prio_bits)) else null)
else
    null;

// ----------------------------------------------------------------------------
// Contract: stacks and contexts.

pub const StackElement = context.StackElement;
pub const stack_alignment: usize = 8;
pub const stack_magic: StackElement = 0xEFBE_ADDE;
pub const Context = context.Context;
pub const contextCreate = context.contextCreate;

/// Bytes reserved at the top of RAM for the interrupt (MSP) stack.
pub const interrupt_stack_size_bytes: usize = if (@hasDecl(board, "interrupt_stack_size_bytes")) board.interrupt_stack_size_bytes else 2048;

const end_of_stack: usize = @intFromPtr(microzig.utilities.end_of_stack);
var interrupt_stack_slice: ?[]StackElement = null;

pub fn interruptStack() ?[]StackElement {
    return interrupt_stack_slice;
}

/// The memory between the end of `.bss` and the interrupt stack, for the
/// RTOS heap.
pub fn freeRam() []u8 {
    const start = @intFromPtr(&microzig_heap_start);
    const end = end_of_stack - interrupt_stack_size_bytes;
    const p: [*]u8 = @ptrFromInt(start);
    return p[0..(end - start)];
}
extern var microzig_heap_start: u8;

// ----------------------------------------------------------------------------
// The RP2040/RP2350 SIO, the SMP silicon.

pub const sio = struct {
    const base: usize = 0xD000_0000;
    pub const CPUID: *volatile u32 = @ptrFromInt(base + 0x000);
    pub const FIFO_ST: *volatile u32 = @ptrFromInt(base + 0x050);
    pub const FIFO_WR: *volatile u32 = @ptrFromInt(base + 0x054);
    pub const FIFO_RD: *volatile u32 = @ptrFromInt(base + 0x058);
    pub const SPINLOCK0: *volatile u32 = @ptrFromInt(base + 0x100);

    pub const FIFO_ST_VLD: u32 = 1 << 0;
    pub const FIFO_ST_RDY: u32 = 1 << 1;

    /// The FIFO interrupt of each core: RP2350 has one shared line (25),
    /// the RP2040 one per core (15, 16).
    pub fn fifoIrq(cpu: u32) u32 {
        if (is_rp2350) return 25;
        return 15 + cpu;
    }

    /// Drain the RX FIFO and clear the sticky WOF/ROE flags.
    pub fn fifoDrain() void {
        while (FIFO_ST.* & FIFO_ST_VLD != 0) _ = FIFO_RD.*;
        FIFO_ST.* = 0x0C;
    }
};

// ----------------------------------------------------------------------------
// The SMP kernel lock: recursive, per-CPU owner, IRQs masked while held.

const no_owner: u32 = 0xFFFF_FFFF;

const KernelLock = struct {
    owner: u32 = no_owner,
    depth: u32 = 0,
};

var klock_storage: KernelLock = .{};
const klock: *volatile KernelLock = &klock_storage;

var lock_state_storage: [ncpu]bool = @splat(false);
const lock_state: *volatile [ncpu]bool = &lock_state_storage;
var lock_primask: [ncpu]u32 = @splat(0);

inline fn klockRawAcquire() void {
    while (sio.SPINLOCK0.* == 0) {}
    arch.dmb();
}

inline fn klockRawRelease() void {
    arch.dmb();
    sio.SPINLOCK0.* = 1;
    arch.dsb();
}

/// Mask IRQs and take the kernel lock (recursively).
inline fn setLock() void {
    arch.disableIrq();
    const cpu = scheduler.cpuId();
    if (klock.owner != cpu) {
        klockRawAcquire();
        klock.owner = cpu;
    }
    klock.depth += 1;
}

/// Release one level of the kernel lock and restore PRIMASK.
inline fn putLock(primask: u32) void {
    const cpu = scheduler.cpuId();
    if (klock.owner == cpu and klock.depth > 0) {
        const d = klock.depth - 1;
        klock.depth = d;
        if (d == 0) {
            klock.owner = no_owner;
            klockRawRelease();
        }
    }
    arch.setPrimask(primask);
}

// ----------------------------------------------------------------------------
// Contract: interrupts.

pub const interrupts = struct {
    pub const State = u32;

    pub inline fn criticalEnter() State {
        if (smp) {
            const pri = arch.getPrimask();
            setLock();
            return pri;
        }
        if (basepri_level) |level| {
            const pri = arch.getBasepri();
            arch.setBasepriMax(level);
            return pri;
        }
        const pri = arch.getPrimask();
        arch.disableIrq();
        return pri;
    }

    pub inline fn criticalExit(state: State) void {
        if (smp) return putLock(state);
        if (basepri_level != null) return arch.setBasepri(state);
        arch.setPrimask(state);
    }

    pub inline fn uncriticalEnter() State {
        if (basepri_level != null) {
            const pri = arch.getBasepri();
            arch.setBasepri(0);
            return pri;
        }
        const pri = arch.getPrimask();
        arch.enableIrq();
        return pri;
    }

    pub inline fn uncriticalExit(state: State) void {
        if (basepri_level != null) return arch.setBasepri(state);
        arch.setPrimask(state);
    }

    pub inline fn inHandlerMode() bool {
        return arch.getIpsr() != 0;
    }

    /// With BASEPRI critical sections, an interrupt above the critical level
    /// must not call the RTOS.
    pub fn isPriorityValid() bool {
        const level = config.options.critical_section_interrupt_priority orelse return true;
        if (basepri_level == null) return true;
        const exception = arch.getIpsr();
        if (exception < 16) return true;
        const prio = arch.nvicGetPriority(exception - 16) >> (8 - @as(u4, arch.nvic_prio_bits));
        return prio >= level;
    }
};

// ----------------------------------------------------------------------------
// Contract: scheduler.

pub const scheduler = struct {
    /// Mask the interrupts and bring the board up (clocks, LED).
    pub fn initialize() void {
        arch.disableIrq();
        if (@hasDecl(board, "init")) board.init();
    }

    pub inline fn cpuId() u32 {
        if (!smp) return 0;
        return sio.CPUID.*;
    }

    pub inline fn isLocked() bool {
        return lock_state[cpuId()];
    }

    /// Set the lock state of this CPU; returns the previous one.
    pub fn setLocked(state: bool) bool {
        std.debug.assert(!interrupts.inHandlerMode());
        if (smp) {
            // Mask IRQs BEFORE reading the CPU index: a PendSV in between
            // could move this thread to the other CPU, mark that one locked
            // and leave its own unmarked, and the unlock would never release
            // the kernel lock.
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
                    // Publish "unlocked" BEFORE releasing the lock and
                    // restoring PRIMASK; otherwise an IRQ in the window sees
                    // this CPU still locked, skips the PendSV, and the next
                    // thread here inherits the stale flag.
                    lock_state[cpu] = false;
                    putLock(lock_primask[cpu]);
                }
            } else {
                arch.setPrimask(pri);
            }
            return prev;
        }
        const cs = interrupts.criticalEnter();
        defer interrupts.criticalExit(cs);
        const prev = lock_state[0];
        lock_state[0] = state;
        return prev;
    }

    /// Request a context switch on this CPU (PendSV, deferred until the
    /// current interrupt, if any, returns).
    pub fn reschedule() void {
        if (isLocked() or (interrupts.inHandlerMode() and !uos.rtos.scheduler.isPreemptive())) return;
        arch.scs.ICSR.* = arch.scs.ICSR_PENDSVSET;
        arch.dsb();
        arch.isb();
    }

    pub fn waitForInterrupt() void {
        arch.dsb();
        arch.wfi();
    }

    pub fn prepareSuspend() void {}

    /// Cross-CPU reschedule request over the SIO FIFO. Non-blocking: a full
    /// FIFO means an IPI is already pending.
    pub fn ipi(cpu: u32) void {
        if (!smp) return;
        if (cpu == cpuId()) return;
        if (sio.FIFO_ST.* & sio.FIFO_ST_RDY != 0) {
            sio.FIFO_WR.* = 0x4D53; // "SM"
            asm volatile ("sev");
        }
    }

    pub fn greeting(w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("Board: {s}\n", .{board.name});
        if (smp) {
            try w.print("Scheduler: µOS++ {s} SMP, {d} cores, PendSV, SIO spinlock\n", .{ chip_name, ncpu });
        } else {
            try w.print("Scheduler: µOS++ Cortex-M ({s}{s}), preemptive", .{
                microzig.config.cpu_name, if (arch.has_fpu) " FP" else "",
            });
            if (basepri_level != null) {
                try w.print(", BASEPRI({d})", .{config.options.critical_section_interrupt_priority.?});
            } else {
                try w.writeAll(", DI/EI");
            }
            try w.writeAll(if (config.options.idle_sleep) ", WFI\n" else ", no WFI\n");
        }
        try w.print("System clock: {d} Hz\n", .{board.cpuFrequencyHz()});
    }

    /// Switch CPU 0 to the scheduler; never returns.
    pub fn start() noreturn {
        arch.disableIrq();
        arch.fpuEnableStacking();

        // Thread mode moves to the PSP (same value, so the running code is
        // undisturbed); the MSP restarts at the top, as the interrupt stack.
        switchToPsp();
        arch.setMsp(end_of_stack);

        // Fill the free part of the interrupt stack with the magic word, so
        // that its usage can be measured; stop below the live frames.
        {
            const limit = end_of_stack - interrupt_stack_size_bytes;
            const here = @frameAddress() - 256;
            const p: [*]StackElement = @ptrFromInt(limit);
            const words = interrupt_stack_size_bytes / @sizeOf(StackElement);
            interrupt_stack_slice = p[0..words];
            const fill = @min(words, (here -| limit) / @sizeOf(StackElement));
            @memset(p[0..fill], stack_magic);
        }

        arch.setPendSvSysTickLowest();

        uos.rtos.scheduler.internalPrepareCpu(0);
        for (lock_state) |*s| s.* = false;

        if (smp) {
            sio.fifoDrain();
            arch.nvicSetPriority(sio.fifoIrq(0), arch.lowest_priority_byte);
            if (options.launch_core1_at_start) launchCore1();
        }

        if (basepri_level != null) arch.setBasepri(0);

        reschedule();
        arch.enableIrq();
        // The first context switch happens here.
        while (true) arch.nop();
    }
};

/// Launch core 1 (bootrom FIFO handshake) and then open core 0's IPI
/// channel. The FIFO IRQ of core 0 must stay off during the launch: the
/// handshake words travel through the very same FIFO.
pub fn launchCore1() void {
    if (!smp) return;
    microzig.hal.multicore.launch_core1_with_stack(secondaryStart, &core1_msp_stack);
    sio.fifoDrain();
    arch.nvicClearPending(sio.fifoIrq(0));
    arch.nvicEnable(sio.fifoIrq(0));
}

/// Set PSP = MSP and select it, in one asm block so no stack slot is
/// addressed in between.
inline fn switchToPsp() void {
    asm volatile (
        \\ mrs r0, msp
        \\ msr psp, r0
        \\ mrs r0, control
        \\ orrs r0, r0, %[spsel]
        \\ msr control, r0
        \\ isb
        :
        : [spsel] "r" (arch.CONTROL_SPSEL),
        : .{ .r0 = true, .memory = true });
}

/// Core 1's handler-mode stack (8-byte aligned, as the bootrom requires).
var core1_msp_stack: [1024]u32 align(8) = undefined;

/// Core 1 entry, from the bootrom FIFO launch.
fn secondaryStart() void {
    arch.disableIrq();
    arch.fpuEnableStacking();

    const cpu = scheduler.cpuId();

    arch.setPendSvSysTickLowest();
    arch.sysTickConfig(board.cpuFrequencyHz() / uos.rtos.Clock.frequency_hz);

    // The IPI channel of this core.
    sio.fifoDrain();
    arch.nvicSetPriority(sio.fifoIrq(cpu), arch.lowest_priority_byte);
    arch.nvicClearPending(sio.fifoIrq(cpu));
    arch.nvicEnable(sio.fifoIrq(cpu));

    uos.rtos.scheduler.internalPrepareCpu(cpu);

    switchToPsp();
    scheduler.reschedule();
    arch.enableIrq();
    while (true) arch.wfi();
}

/// The heart of the context switch, called from PendSV on the MSP with the
/// outgoing stack pointer; returns the incoming one.
export fn uos_port_switch_stacks(sp: [*]StackElement) callconv(.c) [*]StackElement {
    const pri = arch.getPrimask();
    arch.disableIrq();
    defer arch.setPrimask(pri);

    if (smp) {
        const cpu = scheduler.cpuId();
        if (klock.owner != cpu) {
            klockRawAcquire();
            klock.owner = cpu;
        }
        klock.depth += 1;
    }

    // Clear PendSV (late-arrival safety).
    arch.scs.ICSR.* = arch.scs.ICSR_PENDSVCLR;

    const cpu = scheduler.cpuId();
    const old_thread = uos.rtos.scheduler.current_thread[cpu].?;
    // Publish the outgoing context at once: we run on the MSP, its PSP is
    // quiescent.
    @atomicStore(?[*]StackElement, &old_thread.context.port.stack_ptr, sp, .release);

    uos.rtos.scheduler.internalSwitchThreads();

    const new_thread = uos.rtos.scheduler.current_thread[cpu] orelse {
        // No thread and no idle thread for this CPU: fatal. Release the lock
        // so the other CPU does not deadlock, and stay masked.
        if (smp) klockRelease();
        while (true) arch.wfi();
    };

    var out_sp: [*]StackElement = sp;
    if (new_thread != old_thread) out_sp = new_thread.context.port.stack_ptr.?;
    if (std.debug.runtime_safety and (out_sp[8] & 0xFFFF_FF00) != 0xFFFF_FF00) badFrame(old_thread, new_thread, sp, out_sp);
    if (smp) {
        // Claim it: the context is now live in this CPU's registers; the
        // other CPU must not pick it.
        @atomicStore(?[*]StackElement, &new_thread.context.port.stack_ptr, null, .release);
        klockRelease();
    }
    return out_sp;
}

/// The incoming frame does not hold an EXC_RETURN: report and stop.
fn badFrame(old: *uos.rtos.Thread, new: *uos.rtos.Thread, sp: [*]StackElement, out_sp: [*]StackElement) noreturn {
    var buf: [128]u8 = undefined;
    trace.write(std.fmt.bufPrint(&buf, "\n!! BAD FRAME cpu{d}: {s}@{x} sp={x} -> {s}@{x} sp={x} [8]={x} state={s}\n", .{
        scheduler.cpuId(),
        old.name,
        @intFromPtr(old),
        @intFromPtr(sp),
        new.name,
        @intFromPtr(new),
        @intFromPtr(out_sp),
        out_sp[8],
        @tagName(new.state),
    }) catch "");
    const st = new.context.stack;
    trace.write(std.fmt.bufPrint(&buf, "   new stack {x}..{x}\n", .{ @intFromPtr(st.bottom_address), @intFromPtr(st.bottom_address) + st.size_bytes }) catch "");
    terminate(1);
}

fn klockRelease() void {
    klock.depth -= 1;
    if (klock.depth == 0) {
        klock.owner = no_owner;
        klockRawRelease();
    }
}

// ----------------------------------------------------------------------------
// Contract: clocks.

pub const clock_systick = struct {
    pub fn start() void {
        arch.sysTickConfig(board.cpuFrequencyHz() / uos.rtos.Clock.frequency_hz);
        arch.setPendSvSysTickLowest();
    }
};

pub const clock_highres = struct {
    /// The RP chips have a free running 1 MHz 64-bit timer.
    pub const has_hardware_counter = is_rp;

    pub fn start() void {}

    pub fn hardwareCounter() u64 {
        if (!is_rp) return 0;
        return microzig.hal.time.get_time_since_boot().to_us();
    }

    pub fn inputClockFrequencyHz() u32 {
        return if (is_rp) 1_000_000 else board.cpuFrequencyHz();
    }

    pub fn cyclesPerTick() u32 {
        return arch.scs.SYST_RVR.* + 1;
    }

    pub fn cyclesSinceTick() u32 {
        const load = arch.scs.SYST_RVR.*;
        const val = arch.scs.SYST_CVR.*;
        if (arch.scs.ICSR.* & arch.scs.ICSR_PENDSTSET != 0) {
            // The tick interrupt is pending: the counter wrapped.
            const again = arch.scs.SYST_CVR.*;
            if (val > again) return load + 1 + (load - again);
        }
        return load - val;
    }
};

// ----------------------------------------------------------------------------
// Contract: trace and termination.

pub const trace = struct {
    /// Every trace byte goes to the console -- the application's own writer
    /// when its root declares `uos_trace_write` (a test with its own UART
    /// driver), otherwise the board's UART -- and to semihosting, when a
    /// debugger is attached.
    pub fn write(bytes: []const u8) void {
        if (@hasDecl(root, "uos_trace_write")) {
            root.uos_trace_write(bytes);
        } else if (@hasDecl(board, "uartWrite")) {
            board.uartWrite(bytes);
        }
        semihosting.write(bytes);
    }
};

/// End the run with a verdict, through semihosting (`os_terminate()`, from
/// the kernel's `uos.rtos.terminate()`, the C++ `_Exit()`).
///
/// The verdict line is printed here only when the run printed none: the C++
/// board tests print theirs (`hw_result`), and the C++ harness wrapper of
/// the suites prints it before `exit()`.
///
/// Before the SYS_EXIT: wait until the console UART sent its last byte,
/// then about 1 s more. OpenOCD exits on SYS_EXIT and disconnects the
/// probe at once; a probe that also bridges the UART (the WCH-Link of the
/// WeAct board) drops what it has not yet forwarded to the host, and the
/// terminal lost the end of the run (the summary, the stacks, the RESULT).
pub fn terminate(code: u8) noreturn {
    arch.disableIrq();
    if (!semihosting.verdict_written) trace.write(if (code == 0) "RESULT: PASS\n" else "RESULT: FAIL\n");
    if (@hasDecl(board, "uartFlush")) {
        board.uartFlush();
        var n: u32 = board.cpuFrequencyHz(); // >= 1 s: >= 1 cycle per turn
        while (n > 0) : (n -= 1) arch.nop();
    }
    semihosting.exit(code);
}

// ----------------------------------------------------------------------------
// Exception handlers.

fn sysTickHandler() callconv(.c) void {
    if (smp and scheduler.cpuId() != 0) {
        // Only core 0 drives the clock; core 1 picks up the threads it woke.
        scheduler.reschedule();
        return;
    }
    uos.rtos.clocks.sysTickHandler();
}

fn sioFifoHandler() callconv(.c) void {
    sio.fifoDrain();
    scheduler.reschedule();
}

/// The fault handlers: pass the stacked frame (MSP or PSP, by EXC_RETURN
/// bit 2) to `faultReport()`.
fn faultHandler() callconv(.naked) void {
    if (arch.is_armv6m) {
        asm volatile (
            \\ mov r0, lr
            \\ movs r1, #4
            \\ tst r0, r1
            \\ bne 1f
            \\ mrs r0, msp
            \\ b 2f
            \\1:
            \\ mrs r0, psp
            \\2:
            \\ mov r1, lr
            \\ bl uos_port_fault_report
        );
    } else {
        asm volatile (
            \\ tst lr, #4
            \\ ite eq
            \\ mrseq r0, msp
            \\ mrsne r0, psp
            \\ mov r1, lr
            \\ bl uos_port_fault_report
        );
    }
}

/// Dump the fault (frame, status registers, CPU, thread) and end the run.
export fn uos_port_fault_report(frame: [*]const u32, exc_return: u32) callconv(.c) noreturn {
    arch.disableIrq();
    const ipsr = arch.getIpsr();
    var buf: [96]u8 = undefined;
    const lines = [_][]const u8{
        std.fmt.bufPrint(&buf, "\n!! FAULT exception {d} on cpu{d}, EXC_RETURN 0x{X:0>8}\n", .{ ipsr, scheduler.cpuId(), exc_return }) catch "",
    };
    trace.write(lines[0]);
    trace.write(std.fmt.bufPrint(&buf, "   pc 0x{X:0>8} lr 0x{X:0>8} xpsr 0x{X:0>8}\n", .{ frame[6], frame[5], frame[7] }) catch "");
    trace.write(std.fmt.bufPrint(&buf, "   r0 0x{X:0>8} r1 0x{X:0>8} r2 0x{X:0>8} r3 0x{X:0>8} r12 0x{X:0>8}\n", .{ frame[0], frame[1], frame[2], frame[3], frame[4] }) catch "");
    if (!arch.is_armv6m) {
        const cfsr: *volatile u32 = @ptrFromInt(0xE000_ED28);
        const hfsr: *volatile u32 = @ptrFromInt(0xE000_ED2C);
        const mmfar: *volatile u32 = @ptrFromInt(0xE000_ED34);
        const bfar: *volatile u32 = @ptrFromInt(0xE000_ED38);
        trace.write(std.fmt.bufPrint(&buf, "   CFSR 0x{X:0>8} HFSR 0x{X:0>8} MMFAR 0x{X:0>8} BFAR 0x{X:0>8}\n", .{ cfsr.*, hfsr.*, mmfar.*, bfar.* }) catch "");
    }
    if (uos.rtos.scheduler.current_thread[scheduler.cpuId()]) |th| {
        trace.write(std.fmt.bufPrint(&buf, "   thread {s} @0x{X}\n", .{ th.name, @intFromPtr(th) }) catch "");
    }
    terminate(1);
}

const pendSv = if (arch.is_armv6m) context.pendSvHandlerV6m else context.pendSvHandlerV7m;

/// The MicroZig options the application root re-exports. The board may add
/// its own interrupt handlers with `board.interrupts`.
pub const microzig_options: microzig.Options = blk: {
    var o: microzig.Options = .{
        .overwrite_hal_interrupts = true,
        .cpu = .{ .verbose_unhandled_irq = false },
    };
    o.interrupts.PendSV = .{ .naked = pendSv };
    o.interrupts.SysTick = .{ .c = sysTickHandler };
    o.interrupts.HardFault = .{ .naked = faultHandler };
    if (!arch.is_armv6m) {
        o.interrupts.MemManageFault = .{ .naked = faultHandler };
        o.interrupts.BusFault = .{ .naked = faultHandler };
        o.interrupts.UsageFault = .{ .naked = faultHandler };
    }
    if (smp) {
        if (is_rp2350) o.interrupts.SIO_IRQ_FIFO = .{ .c = sioFifoHandler };
        if (is_rp2040) {
            o.interrupts.SIO_IRQ_PROC0 = .{ .c = sioFifoHandler };
            o.interrupts.SIO_IRQ_PROC1 = .{ .c = sioFifoHandler };
        }
    }
    // The board's handlers, then the application's (`uos_interrupts` in the
    // root file), which may override them.
    if (@hasDecl(board, "interrupts")) {
        for (@typeInfo(@TypeOf(board.interrupts)).@"struct".field_names) |name| {
            @field(o.interrupts, name) = @field(board.interrupts, name);
        }
    }
    if (@hasDecl(root, "uos_interrupts")) {
        for (@typeInfo(@TypeOf(root.uos_interrupts)).@"struct".field_names) |name| {
            @field(o.interrupts, name) = @field(root.uos_interrupts, name);
        }
    }
    break :blk o;
};
