//! ARMv8-A (AArch64) port of µOS++ IIIe for Raspberry Pi 4 B (BCM2711, 4x Cortex-A72).
//! Implements the port contract defined in `src/port_contract.zig`.
//!
//! Features:
//!   - 4x Cortex-A72 SMP running in EL1h (SP_EL1), threads on individual stacks.
//!   - 800-byte context Frame: x0-x30, SPSR_EL1, ELR_EL1, FPSR, FPCR, pad, q0-q31.
//!   - Full hardware FP/SIMD (NEON) registers saved per context.
//!   - ARM Generic Timer @ 54 MHz (PPI 30, CNTPNSIRQ) driving 1 ms sysclock tick.
//!   - GIC-400 (GICv2) interrupt controller with SGI 0 for cross-core reschedule IPI.
//!   - Re-entrant KernelLock spinlock with CPU owner and depth tracking.
//!   - Deferred SMP frame publication (_smp_pub_addr / _smp_pub_val).
//!   - Atomic context claiming to guarantee single-CPU execution per thread.

const std = @import("std");
const uos = @import("uos");
const board = @import("uos_board");
const root = @import("root");

pub const arch = @import("arch.zig");
pub const gic_mod = @import("gic.zig");
pub const mmu = @import("mmu.zig");
pub const semihosting = @import("semihosting.zig");
pub const faults = @import("faults.zig");

const config = uos.config;
const ncpu = config.ncpu;

comptime {
    if (ncpu > board.ncpu) @compileError("uos_options.ncpu is above the board's CPU count");
}

pub const gic: gic_mod.Gic = .{
    .gicd = board.gicd_base,
    .gicc = board.gicc_base,
};

// ----------------------------------------------------------------------------
// Contract: stacks and contexts

pub const StackElement = u64;
pub const stack_alignment: usize = 16;
pub const stack_magic: StackElement = 0xDEAD_BEEF_CAFE_BABE;

pub const Context = struct {
    /// Saved stack pointer; null while context is active in CPU registers.
    stack_ptr: ?[*]StackElement = null,
};

/// Saved context frame matching `startup.S` (800 bytes).
pub const Frame = extern struct {
    x: [31]u64, // x0..x30 (31 * 8 = 248 bytes)
    spsr: u64, // SPSR_EL1 (8 bytes)
    elr: u64, // ELR_EL1 (8 bytes)
    fpsr: u64, // FPSR (8 bytes)
    fpcr: u64, // FPCR (8 bytes)
    pad: u64, // alignment padding (8 bytes)
    q: [32][2]u64, // q0..q31 (32 * 16 = 512 bytes)
};

pub const frame_spsr_word = @offsetOf(Frame, "spsr") / @sizeOf(StackElement);

comptime {
    if (@sizeOf(Frame) != 800) @compileError("Frame must be exactly 800 bytes to match startup.S");
}

/// SPSR value for threads: EL1h (M[3:0] = 0b0101), DAIF unmasked (0).
const mode_el1h: u64 = 0x05;

pub fn contextCreate(
    ctx: *Context,
    stack: []StackElement,
    entry: *const fn (?*anyopaque) callconv(.c) noreturn,
    arg: ?*anyopaque,
) void {
    var p = @intFromPtr(stack.ptr + stack.len) & ~@as(usize, 15);
    p -= @sizeOf(Frame);
    p &= ~@as(usize, 15);

    const f: *Frame = @ptrFromInt(p);
    f.* = .{
        .x = @splat(0xCCCC_CCCC_CCCC_CCCC),
        .spsr = mode_el1h,
        .elr = @intFromPtr(entry),
        .fpsr = 0,
        .fpcr = 0,
        .pad = 0,
        .q = @splat([2]u64{ 0, 0 }),
    };
    f.x[0] = @intFromPtr(arg);
    f.x[30] = 0; // initial LR
    ctx.stack_ptr = @ptrFromInt(p);
}

// ----------------------------------------------------------------------------
// SMP Kernel Lock & Per-CPU State

const no_owner: u32 = 0xFFFF_FFFF;

const KernelLock = extern struct {
    lock: u32 = 0,
    owner: u32 = no_owner,
    depth: u32 = 0,
};

export var _smp_klock: KernelLock = .{};

var lock_state: [ncpu]bool = @splat(false);
var ctx_pending: [ncpu]u32 = @splat(0);
var in_isr: [ncpu]bool = @splat(false);
export var _port_core_alive: [ncpu]u32 = @splat(0);
export var g_core_stage: [ncpu]u32 = @splat(0);
var debug_isr_ticks: u32 = 0;

export var __smp_spin: [board.ncpu]u64 = @splat(0);
export var _smp_pub_addr: [board.ncpu]usize = @splat(0);
export var _smp_pub_val: [board.ncpu]usize = @splat(0);

inline fn klockRawAcquire() void {
    while (true) {
        if (@atomicRmw(u32, &_smp_klock.lock, .Xchg, 1, .acquire) == 0) break;
        while (@atomicLoad(u32, &_smp_klock.lock, .monotonic) != 0) {
            arch.nop();
        }
    }
}

inline fn klockRawRelease() void {
    arch.dmbIsh();
    @atomicStore(u32, &_smp_klock.lock, 0, .release);
    arch.dsb();
}

inline fn ownerIs(cpu: u32) bool {
    return @atomicLoad(u32, &_smp_klock.owner, .monotonic) == cpu;
}

inline fn klockTake(cpu: u32) void {
    if (!ownerIs(cpu)) {
        klockRawAcquire();
        @atomicStore(u32, &_smp_klock.owner, cpu, .monotonic);
    }
    _smp_klock.depth += 1;
}

inline fn klockPut(cpu: u32) void {
    if (ownerIs(cpu) and _smp_klock.depth > 0) {
        const d = _smp_klock.depth - 1;
        _smp_klock.depth = d;
        if (d == 0) {
            @atomicStore(u32, &_smp_klock.owner, no_owner, .monotonic);
            klockRawRelease();
        }
    }
}

// ----------------------------------------------------------------------------
// Contract: interrupts

pub const interrupts = struct {
    pub const State = u64;

    pub inline fn criticalEnter() State {
        const daif = arch.getDaif();
        arch.disableIrq();
        klockTake(arch.cpuId());
        return daif;
    }

    pub inline fn criticalExit(state: State) void {
        klockPut(arch.cpuId());
        arch.restoreIrq(state);
    }

    pub inline fn uncriticalEnter() State {
        const daif = arch.getDaif();
        arch.enableIrq();
        return daif;
    }

    pub inline fn uncriticalExit(state: State) void {
        arch.restoreIrq(state);
    }

    pub inline fn inHandlerMode() bool {
        // The CPU number and its flag are read with IRQs masked: a thread
        // free to run on any CPU, preempted between the two reads and
        // resumed elsewhere, would otherwise read the flag of the CPU it
        // left, possibly in a handler at that moment (seen as a failed
        // `!inHandlerMode()` assert in setLocked(), smp-list-storage-test's
        // scanner). In a handler IRQs are already masked.
        const daif = arch.getDaif();
        arch.disableIrq();
        const cpu = arch.cpuId();
        const in_handler = cpu < ncpu and @atomicLoad(bool, &in_isr[cpu], .monotonic);
        arch.restoreIrq(daif);
        return in_handler;
    }

    pub inline fn isPriorityValid() bool {
        return true;
    }
};

// ----------------------------------------------------------------------------
// Contract: scheduler

pub const scheduler = struct {
    pub fn initialize() void {
        arch.disableIrq();
    }

    pub inline fn cpuId() u32 {
        return arch.cpuId();
    }

    pub fn isLocked() bool {
        const daif = arch.getDaif();
        arch.disableIrq();
        const res = lock_state[arch.cpuId()];
        arch.restoreIrq(daif);
        return res;
    }

    pub fn setLocked(state: bool) bool {
        std.debug.assert(!interrupts.inHandlerMode());
        if (state) {
            arch.disableIrq();
            const cpu = arch.cpuId();
            const prev = lock_state[cpu];
            if (!prev) {
                klockTake(cpu);
                lock_state[cpu] = true;
            }
            return prev;
        } else {
            const cpu = arch.cpuId();
            const prev = lock_state[cpu];
            if (prev) {
                lock_state[cpu] = false;
                klockPut(cpu);
                arch.enableIrq();
            }
            return prev;
        }
    }

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

    pub fn waitForInterrupt() void {
        arch.dsb();
        arch.wfi();
    }

    pub fn prepareSuspend() void {}

    pub fn ipi(cpu: u32) void {
        if (cpu < ncpu) gic.sendIpi(cpu);
    }

    pub fn greeting(w: *std.Io.Writer) std.Io.Writer.Error!void {
        // The C++ port prints this line as it is (os-inlines.h).
        try w.print("Scheduler: {s}\n", .{board.port_greeting});
    }

    pub fn start() noreturn {
        arch.disableIrq();
        sysInit();
        uos.rtos.scheduler.internalPrepareCpu(0);
        g_core_stage[0] = 3;
        for (&lock_state) |*s| s.* = false;
        reschedule();
        arch.enableIrq();
        while (true) arch.wfi();
    }
};

// ----------------------------------------------------------------------------
// Timer & Interrupt Hardware Setup

var timer_period_cycles: u32 = 54_000;

fn sysInit() void {
    const cpu = arch.cpuId();
    if (cpu == 0) {
        gic.initDistributor();
    }
    gic.initThisCore();

    const freq = arch.cntFrq();
    if (freq > 0) {
        timer_period_cycles = freq / 1000;
    } else {
        timer_period_cycles = 54_000;
    }

    // Program 1 ms physical timer countdown
    arch.setCntpTval(timer_period_cycles);
    arch.setCntpCtl(1); // enable timer, unmask interrupt

    gic.setPriority(gic_mod.INTID_TIMER_PNS, gic_mod.PRIORITY);
    gic.enableIrq(gic_mod.INTID_TIMER_PNS);
    gic.setPriority(gic_mod.INTID_IPI, gic_mod.PRIORITY);
    gic.enableIrq(gic_mod.INTID_IPI);
}

// ----------------------------------------------------------------------------
// Stack Switching & Deferred Publication

export fn port_switch_stacks(sp: [*]StackElement) callconv(.c) [*]StackElement {
    const cpu = arch.cpuId();
    klockRawAcquire();
    @atomicStore(u32, &_smp_klock.owner, cpu, .monotonic);
    _smp_klock.depth = 1;

    const sched = uos.rtos.scheduler;
    const old_thread = sched.current_thread[cpu].?;
    sched.internalSwitchThreads();
    const new_thread = sched.current_thread[cpu] orelse {
        arch.disableIrq();
        board.uartPrint("\n!!! ERROR: no ready thread and no idle thread on Core {d} !!!\n", .{cpu});
        while (true) arch.wfi();
    };

    var out_sp: [*]StackElement = sp;
    _smp_pub_addr[cpu] = 0;

    if (new_thread != old_thread) {
        const p = new_thread.context.port.stack_ptr;
        checkClaim(cpu, old_thread, new_thread, p);

        // Stage publication of outgoing frame (executed by assembly after SP switch)
        _smp_pub_val[cpu] = @intFromPtr(sp);
        _smp_pub_addr[cpu] = @intFromPtr(&old_thread.context.port.stack_ptr);
        out_sp = p.?;

        // Claim incoming thread context
        @atomicStore(?[*]StackElement, &new_thread.context.port.stack_ptr, null, .release);
    }

    _smp_klock.depth = 0;
    @atomicStore(u32, &_smp_klock.owner, no_owner, .monotonic);
    klockRawRelease();
    return out_sp;
}

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

// ----------------------------------------------------------------------------
// Preemptive Interrupt Dispatcher

export fn port_isr_handler(current_sp: [*]StackElement) callconv(.c) [*]StackElement {
    const cpu = arch.cpuId();
    in_isr[cpu] = true;

    const iar = gic.acknowledge();
    const id = gic_mod.Gic.intidOf(iar);

    if (id == gic_mod.INTID_SPURIOUS or id == gic_mod.INTID_SPURIOUS_OTHER_GROUP) {
        in_isr[cpu] = false;
        return current_sp;
    }

    if (id == gic_mod.INTID_TIMER_PNS) {
        arch.setCntpTval(timer_period_cycles);
        gic.endOfInterrupt(iar);
        _port_core_alive[cpu] = 1;
        if (cpu == 0) uos.rtos.clocks.sysTickHandler();
        ctx_pending[cpu] = 1;
    } else if (ncpu > 1 and id == gic_mod.INTID_IPI) {
        gic.endOfInterrupt(iar);
        ctx_pending[cpu] = 1;
    } else {
        if (@hasDecl(root, "uos_external_irq")) root.uos_external_irq(iar);
        gic.endOfInterrupt(iar);
    }

    var ret_sp = current_sp;
    if (ctx_pending[cpu] != 0) {
        if (!uos.rtos.scheduler.locked() and !ownerIs(cpu)) {
            ctx_pending[cpu] = 0;
            const new_sp = port_switch_stacks(current_sp);
            validateContext(new_sp, current_sp);
            ret_sp = new_sp;
        }
    }
    in_isr[cpu] = false;
    return ret_sp;
}

fn validateContext(new_sp: [*]StackElement, old_sp: [*]StackElement) void {
    const a = @intFromPtr(new_sp);
    if (a < board.ram_base or a >= board.ram_end) {
        arch.disableIrq();
        board.uartPrint("\n!!! CORRUPT STACK POINTER !!!\n  new_sp=0x{x:0>16}  old_sp=0x{x:0>16}\n", .{ a, @intFromPtr(old_sp) });
        while (true) arch.wfi();
    }
    const spsr = new_sp[frame_spsr_word];
    if (spsr & 0x1F == mode_el1h) return;
    arch.disableIrq();
    board.uartPrint("\n!!! CORRUPT CONTEXT FRAME !!!\n  new_sp=0x{x:0>16}  old_sp=0x{x:0>16}  saved_spsr=0x{x:0>16}\n", .{ a, @intFromPtr(old_sp), spsr });
    while (true) arch.wfi();
}

export fn port_ctx_switch_corrupt(new_sp: u64, old_sp: u64) callconv(.c) noreturn {
    arch.disableIrq();
    board.uartPrint("\n!!! COOPERATIVE SWITCH CORRUPT STACK POINTER !!!\n  new_sp=0x{x:0>16}  old_sp=0x{x:0>16}\n", .{ new_sp, old_sp });
    while (true) arch.wfi();
}

// ----------------------------------------------------------------------------
// Secondary Core Bringup

fn bootSecondaryCore(cpu: u32) noreturn {
    arch.disableIrq();
    sysInit();
    g_core_stage[cpu] = 2;
    uos.rtos.scheduler.internalPrepareCpu(cpu);
    g_core_stage[cpu] = 3;
    lock_state[cpu] = false;
    scheduler.reschedule();
    arch.enableIrq();
    while (true) arch.wfi();
}

export fn boot_core1() callconv(.c) noreturn {
    bootSecondaryCore(1);
}

export fn boot_core2() callconv(.c) noreturn {
    bootSecondaryCore(2);
}

export fn boot_core3() callconv(.c) noreturn {
    bootSecondaryCore(3);
}

// ----------------------------------------------------------------------------
// Core 0 Main Entry Point from startup.S

export fn uos_core0_main() callconv(.c) noreturn {
    if (@hasDecl(root, "main")) {
        root.main();
    }
    while (true) arch.wfi();
}

// ----------------------------------------------------------------------------
// Clocks & Trace Contracts

pub const clock_systick = struct {
    pub fn start() void {}
};

pub const clock_highres = struct {
    pub fn start() void {}
    pub const has_hardware_counter: bool = true;

    pub inline fn hardwareCounter() u64 {
        return arch.cntPct();
    }

    pub inline fn inputClockFrequencyHz() u32 {
        const f = arch.cntFrq();
        return if (f > 0) f else 54_000_000;
    }

    pub inline fn cyclesPerTick() u32 {
        return timer_period_cycles;
    }

    pub inline fn cyclesSinceTick() u32 {
        const cur = arch.cntpTval();
        if (cur < timer_period_cycles) {
            return timer_period_cycles - cur;
        }
        return 0;
    }
};

/// The console: every byte on the UART; on semihosting only the verdict
/// lines, as the C++ rpi4b hardware build (its uart.hpp, mirror_verdict()):
/// a semihosting call costs seconds on this probe, and OpenOCD 0.12 does
/// not resume CPUs 1..3 after one on this board (a line mirrored from them
/// would stop that CPU). A line holding "RESULT", "FAIL" or "FATAL" is
/// mirrored, with the following pieces up to the end of that line.
pub const trace = struct {
    var verdict_line_open: bool = false;

    fn isVerdict(bytes: []const u8) bool {
        for ([_][]const u8{ "RESULT", "FAIL", "FATAL" }) |key| {
            if (std.mem.indexOf(u8, bytes, key) != null) return true;
        }
        return false;
    }

    pub fn write(bytes: []const u8) void {
        board.uartWrite(bytes);
        if (bytes.len == 0) return;
        if (verdict_line_open or isVerdict(bytes)) {
            verdict_line_open = bytes[bytes.len - 1] != '\n';
            semihosting.mirror(bytes);
        }
    }
};

pub fn interruptStack() ?[]StackElement {
    return null;
}

pub fn coreStage(cpu: u32) u32 {
    return if (cpu < ncpu) @atomicLoad(u32, &g_core_stage[cpu], .monotonic) else 0;
}

pub fn startSecondaryCpus() void {
    board.releaseSecondaries(struct {
        fn log(msg: []const u8) void {
            trace.write(msg);
        }
    }.log);
}

/// End the run with a verdict: IRQs masked, the semihosting line and the
/// UART drained, then a semihosting SYS_EXIT.
pub fn terminate(code: u8) noreturn {
    arch.disableIrq();
    semihosting.flush();
    board.uartFlush();
    semihosting.exit(code);
}

comptime {
    _ = mmu;
    _ = faults;
}
