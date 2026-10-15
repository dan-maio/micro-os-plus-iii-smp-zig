//! The ARMv7-A (AArch32) port of µOS++ IIIe (the C++
//! micro-os-plus-iii-aarch32, smp branch: src/rtos/os-core.cpp,
//! src/context_switch.cpp, src/handlers.cpp, the board's port_isr.cpp and
//! port_sys.cpp, and the port's os-inlines.h).
//!
//!   - Threads run in SVC mode, on their own stacks. A suspended thread's
//!     registers are a `Frame` on its stack: d0-d31, FPSCR, CPSR, PC,
//!     r0-r12, LR (328 bytes).
//!   - A context switch is a function call from thread code (`reschedule()`)
//!     or the return of an IRQ; both build the same frame and return through
//!     IRQ mode with `movs pc, lr` (CPSR and PC restored at once).
//!   - The tick is each CPU's generic physical timer (PPI 29/30), 1 ms; CPU 0
//!     drives the clocks. The IPI is an SGI (the board's `ipi_sgi`).
//!   - The kernel lock is a recursive LDREX/STREX spin lock with a per-CPU
//!     owner, taken with the IRQs masked (CPSR.I).
//!   - SMP publish/claim: the outgoing context becomes claimable by other
//!     CPUs only after its frame is complete and the stack pointer has left
//!     it (`_smp_pub_addr`/`_smp_pub_val`, done by the assembly).
//!   - Faults are reported on the UART only (semihosting is a trap and could
//!     fault again).
//!
//! The board module (`uos_board`) supplies the memory map, the GIC and UART
//! addresses, the IPI SGI, the console and the secondary CPU release.

const std = @import("std");
const uos = @import("uos");
const board = @import("uos_board");
const root = @import("root");

pub const arch = @import("arch.zig");
pub const gic_mod = @import("gic.zig");

const config = uos.config;
const ncpu = config.ncpu;

comptime {
    if (ncpu > board.ncpu) @compileError("uos_options.ncpu is above the board's CPU count");
}

pub const gic: gic_mod.Gic = .{ .gicd = board.gicd_base, .gicc = board.gicc_base };

// ----------------------------------------------------------------------------
// Contract: stacks and contexts.

pub const StackElement = u32;
pub const stack_alignment: usize = 8;
pub const stack_magic: StackElement = 0xEFBE_ADDE;

pub const Context = struct {
    /// The saved frame; null while the context is live in some CPU.
    stack_ptr: ?[*]StackElement = null,
};

/// The saved context (C++ `ctx_t`), lowest address first.
pub const Frame = extern struct {
    vfp: [32]u32, // d0-d15
    vfp_hi: [32]u32, // d16-d31
    fpscr: u32,
    pad: u32,
    cpsr: u32,
    pc: u32,
    r: [13]u32, // r0-r12
    lr: u32,
};

pub const frame_cpsr_word = @offsetOf(Frame, "cpsr") / 4;

comptime {
    if (@sizeOf(Frame) != 328) @compileError("the frame must match the assembly (328 bytes)");
}

const mode_svc: u32 = 0x13;

pub fn contextCreate(ctx: *Context, stack: []StackElement, entry: *const fn (?*anyopaque) callconv(.c) noreturn, arg: ?*anyopaque) void {
    var p = @intFromPtr(stack.ptr + stack.len) & ~@as(usize, 7);
    p -= @sizeOf(Frame);
    p &= ~@as(usize, 7);
    const f: *Frame = @ptrFromInt(p);
    f.* = .{
        .vfp = @splat(0),
        .vfp_hi = @splat(0),
        .fpscr = 0,
        .pad = 0,
        .cpsr = mode_svc, // SVC, ARM state, IRQs enabled
        .pc = @intFromPtr(entry),
        .r = @splat(0xCCCC_CCCC),
        .lr = 0,
    };
    f.r[0] = @intFromPtr(arg);
    ctx.stack_ptr = @ptrFromInt(p);
}

// ----------------------------------------------------------------------------
// The kernel lock (recursive, per-CPU owner) and the per-CPU state.

const no_owner: u32 = 0xFFFF_FFFF;

const KernelLock = extern struct {
    lock: u32 = 0,
    owner: u32 = no_owner,
    depth: u32 = 0,
};

export var _smp_klock: KernelLock = .{};

/// Per-CPU scheduler lock state.
var lock_state: [ncpu]bool = @splat(false);
/// A context switch requested while it could not happen; done at the next
/// interrupt's exit.
var ctx_pending: [ncpu]u32 = @splat(0);
/// Per-CPU handler flag (set by port_isr_handler()).
var in_isr: [ncpu]bool = @splat(false);
/// Per-CPU "first tick seen".
var core_alive: [ncpu]u32 = @splat(0);

/// The deferred publish slots, read by the assembly after the switch.
export var _smp_pub_addr: [ncpu]u32 = @splat(0);
export var _smp_pub_val: [ncpu]u32 = @splat(0);

inline fn klockRawAcquire() void {
    while (true) {
        if (@atomicRmw(u32, &_smp_klock.lock, .Xchg, 1, .acquire) == 0) break;
        while (@atomicLoad(u32, &_smp_klock.lock, .monotonic) != 0) {}
    }
}

inline fn klockRawRelease() void {
    arch.dmb();
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
// Contract: interrupts.

pub const interrupts = struct {
    /// The CPSR at entry.
    pub const State = u32;

    pub inline fn criticalEnter() State {
        const cpsr = arch.getCpsr();
        arch.disableIrq();
        klockTake(arch.cpuId());
        return cpsr;
    }

    pub inline fn criticalExit(state: State) void {
        klockPut(arch.cpuId());
        arch.restoreIrq(state);
    }

    pub inline fn uncriticalEnter() State {
        const cpsr = arch.getCpsr();
        arch.enableIrq();
        return cpsr;
    }

    pub inline fn uncriticalExit(state: State) void {
        arch.restoreIrq(state);
    }

    pub inline fn inHandlerMode() bool {
        const cpu = arch.cpuId();
        if (cpu < ncpu and @atomicLoad(bool, &in_isr[cpu], .monotonic)) return true;
        const mode = arch.getCpsr() & 0x1F;
        return mode == 0x12 or mode == 0x11; // IRQ, FIQ
    }

    pub inline fn isPriorityValid() bool {
        return true;
    }
};

// ----------------------------------------------------------------------------
// Contract: scheduler.

pub const scheduler = struct {
    pub fn initialize() void {
        arch.disableIrq();
    }

    pub inline fn cpuId() u32 {
        return arch.cpuId();
    }

    pub fn isLocked() bool {
        const cpsr = arch.getCpsr();
        arch.disableIrq();
        const res = lock_state[arch.cpuId()];
        arch.restoreIrq(cpsr);
        return res;
    }

    /// `port::scheduler::locked(state)`.
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

    /// Request a context switch: now (a call to the switch handler), or,
    /// when this CPU holds the kernel lock or is in a handler, at the next
    /// interrupt's exit.
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
        // The handler saves and restores every register but LR (the call).
        asm volatile ("bl port_ctx_switch_handler" ::: .{ .lr = true, .memory = true });
    }

    pub fn waitForInterrupt() void {
        arch.dsb();
        arch.wfi();
    }

    pub fn prepareSuspend() void {}

    pub fn ipi(cpu: u32) void {
        if (cpu < ncpu) gic.sendSgi(@as(u32, 1) << @intCast(cpu), board.ipi_sgi);
    }

    pub fn greeting(w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("Scheduler: {s}, {d} CPU(s), 1ms tick, LDREX lock\n", .{ board.port_greeting, ncpu });
    }

    /// Start CPU 0: GIC, tick, first switch; never returns.
    pub fn start() noreturn {
        arch.disableIrq();
        // `interrupts::stack()->initialize()`: the IRQ-mode stack is filled
        // with the magic word, for the idle check and the usage report. No
        // interrupt has run on it yet.
        if (interruptStack()) |st| @memset(st, stack_magic);
        sysInit();
        uos.rtos.scheduler.internalPrepareCpu(0);
        for (&lock_state) |*s| s.* = false;
        reschedule();
        arch.enableIrq();
        while (true) arch.wfi();
    }
};

/// The interrupt controller and the tick of this CPU (`port_sys_init()`).
fn sysInit() void {
    const cpu = arch.cpuId();
    if (cpu == 0) gic.init() else gic.initCpuInterface();
    timer.init();
    timer.start1ms();
    inline for (.{ gic_mod.irq_physical_timer, gic_mod.irq_physical_timer_ns }) |id| {
        gic.enableIrq(id);
        gic.setPriority(id, 0xA0);
    }
    // The SGIs are always enabled on the GIC-400; gic.init() gave them
    // priority 0xA0.
}

/// The context switch proper (C++ `switch_stacks()`): with the IRQs masked,
/// take the kernel lock, let the kernel pick the next thread, stage the
/// outgoing context's publication and claim the incoming one.
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
    _smp_pub_addr[cpu] = 0; // no publish unless staged below
    if (new_thread != old_thread) {
        const p = new_thread.context.port.stack_ptr;
        checkClaim(cpu, old_thread, new_thread, p);
        // The outgoing frame is published by the assembly, once the stack
        // pointer has left it.
        _smp_pub_val[cpu] = @intFromPtr(sp);
        _smp_pub_addr[cpu] = @intFromPtr(&old_thread.context.port.stack_ptr);
        out_sp = p.?;
        // Claim: live in this CPU's registers now.
        @atomicStore(?[*]StackElement, &new_thread.context.port.stack_ptr, null, .release);
    }

    // Release the kernel lock.
    _smp_klock.depth = 0;
    @atomicStore(u32, &_smp_klock.owner, no_owner, .monotonic);
    klockRawRelease();
    return out_sp;
}

/// The claim tripwire: a claimed frame must lie inside the thread's stack
/// and hold an SVC-mode CPSR.
fn checkClaim(cpu: u32, old: *uos.rtos.Thread, new: *uos.rtos.Thread, p: ?[*]StackElement) void {
    const st = new.context.stack;
    const lo = if (st.bottom_address) |b| @intFromPtr(b) else 0;
    const hi = lo + st.size_bytes; // top()
    const addr = if (p) |q| @intFromPtr(q) else 0;
    const bad_bounds = lo != 0 and (addr < lo or addr + @sizeOf(Frame) > hi);
    const bad_frame = addr != 0 and (p.?[frame_cpsr_word] & 0x1F) != mode_svc;
    if (addr == 0 or bad_bounds or bad_frame) {
        arch.disableIrq();
        board.uartPrint("\n!!! SMP CLAIM TRIPWIRE (core {d}) !!!\n  old={s} new={s}\n  claimed sp=0x{x:0>8} stack=[0x{x:0>8},0x{x:0>8})\n  new state={s}\n", .{
            cpu, old.name, new.name, addr, lo, hi, @tagName(new.state),
        });
        while (true) arch.wfi();
    }
}

/// The interrupt dispatcher (C++ `port_isr_handler()`), called by the IRQ
/// entry with the interrupted frame; returns the frame to resume.
export fn port_isr_handler(current_sp: [*]StackElement) callconv(.c) [*]StackElement {
    const cpu = arch.cpuId();
    in_isr[cpu] = true;
    const iar = gic.acknowledge();
    const id = iar & 0x3FF;
    if (id == gic_mod.irq_physical_timer or id == gic_mod.irq_physical_timer_ns) {
        arch.setCntpTval(timer.period_cycles);
        gic.endOfInterrupt(iar);
        core_alive[cpu] = 1;
        if (cpu == 0) uos.rtos.clocks.sysTickHandler();
        ctx_pending[cpu] = 1;
    } else if (ncpu > 1 and id == board.ipi_sgi) {
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
        board.uartPrint("\n!!! CORRUPT STACK POINTER !!!\n  new_sp=0x{x:0>8}  old_sp=0x{x:0>8}\n", .{ a, @intFromPtr(old_sp) });
        while (true) arch.wfi();
    }
    const cpsr = new_sp[frame_cpsr_word];
    if (cpsr & 0x1F == mode_svc) return;
    arch.disableIrq();
    board.uartPrint("\n!!! CORRUPT CONTEXT FRAME !!!\n  new_sp=0x{x:0>8}  old_sp=0x{x:0>8}  saved_cpsr=0x{x:0>8}\n", .{ a, @intFromPtr(old_sp), cpsr });
    while (true) arch.wfi();
}

export fn port_ctx_switch_corrupt(new_sp: u32, old_sp: u32) callconv(.c) noreturn {
    arch.disableIrq();
    board.uartPrint("\n!!! COOPERATIVE CONTEXT SWITCH CORRUPT STACK POINTER !!!\n  new_sp=0x{x:0>8}  old_sp=0x{x:0>8}\n", .{ new_sp, old_sp });
    while (true) arch.wfi();
}

// ----------------------------------------------------------------------------
// The assembly: the cooperative switch and the IRQ entry. Both build the
// same `Frame` on the thread's SVC stack, call into Zig, then publish the
// outgoing frame, CLREX, and return through IRQ mode with `movs pc, lr`.

const ram_check = std.fmt.comptimePrint(
    \\ movw   r1, #0x{x}
    \\ movt   r1, #0x{x}
    \\ cmp    r0, r1
    \\ blo    1f
    \\ movw   r1, #0x{x}
    \\ movt   r1, #0x{x}
    \\ cmp    r0, r1
    \\ bhs    1f
    \\
, .{ board.ram_base & 0xFFFF, board.ram_base >> 16, board.ram_end & 0xFFFF, board.ram_end >> 16 });

/// Publish the frame the switch staged (the per-CPU slots), then drop any
/// LDREX reservation of the previous thread.
const publish_and_restore =
    \\ mrc    p15, 0, r0, c0, c0, 5
    \\ and    r0, r0, #0xFF
    \\ movw   r1, #:lower16:_smp_pub_addr
    \\ movt   r1, #:upper16:_smp_pub_addr
    \\ ldr    r2, [r1, r0, lsl #2]
    \\ cmp    r2, #0
    \\ beq    8f
    \\ movw   r3, #:lower16:_smp_pub_val
    \\ movt   r3, #:upper16:_smp_pub_val
    \\ ldr    r3, [r3, r0, lsl #2]
    \\ str    r3, [r2]
    \\ mov    r3, #0
    \\ str    r3, [r1, r0, lsl #2]
    \\ dmb
    \\8:
    \\ clrex
    \\ vpop   {d0-d15}
    \\ vpop   {d16-d31}
    \\ pop    {r2, r3}
    \\ vmsr   fpscr, r2
    \\ pop    {r0, r1}
    \\ cps    #0x12
    \\ msr    spsr_cxsf, r0
    \\ mov    lr, r1
    \\ cps    #0x13
    \\ pop    {r0-r12, lr}
    \\ cps    #0x12
    \\ movs   pc, lr
    \\
;

export fn port_ctx_switch_handler() callconv(.naked) void {
    asm volatile (
        \\ mrs    r2, cpsr
        \\ cpsid  i
        \\ push   {r0-r12, lr}
        \\ push   {r2, lr}
        \\ vmrs   r2, fpscr
        \\ push   {r2, r3}
        \\ vpush  {d16-d31}
        \\ vpush  {d0-d15}
        \\ mov    r0, sp
        \\ bl     port_switch_stacks
        \\
    ++ ram_check ++
        \\ mov    sp, r0
        \\
    ++ publish_and_restore ++
        \\1:
        \\ cpsid  if
        \\ mov    r1, sp
        \\ bl     port_ctx_switch_corrupt
    );
}

export fn irq_handler() callconv(.naked) void {
    asm volatile (
        \\ sub    lr, lr, #4
        \\ push   {r0-r3}
        \\ mrs    r0, spsr
        \\ mov    r1, lr
        \\ cps    #0x13
        \\ push   {r4-r12, lr}
        \\ cps    #0x12
        \\ pop    {r4-r7}
        \\ cps    #0x13
        \\ push   {r4-r7}
        \\ push   {r0, r1}
        \\ vmrs   r2, fpscr
        \\ push   {r2, r3}
        \\ vpush  {d16-d31}
        \\ vpush  {d0-d15}
        \\ mov    r0, sp
        \\ bl     port_isr_handler
        \\ mov    sp, r0
        \\
    ++ publish_and_restore);
}

// ----------------------------------------------------------------------------
// The secondary CPUs.

/// Per-CPU stage, as the boards report it: 0 not started, 3 scheduler
/// entered (`g_core_stage[]`).
export var g_core_stage: [ncpu]u32 = @splat(0);

pub fn coreStage(cpu: u32) u32 {
    return @atomicLoad(u32, &g_core_stage[cpu], .acquire);
}

/// A secondary CPU, from the board's startup once its MMU is on
/// (`port_smp_secondary_start()`).
fn secondaryStart(cpu: u32) noreturn {
    @atomicStore(u32, &g_core_stage[cpu], 3, .release);
    arch.disableIrq();
    sysInit();
    uos.rtos.scheduler.internalPrepareCpu(cpu);
    scheduler.reschedule();
    arch.enableIrq();
    while (true) arch.wfi();
}

export fn boot_core1() callconv(.c) noreturn {
    secondaryStart(1);
}

export fn boot_core2() callconv(.c) noreturn {
    secondaryStart(2);
}

/// Release CPUs 1..ncpu-1 (`smp::start_secondary_cores()`).
pub fn startSecondaryCpus() void {
    board.releaseSecondaries();
}

// ----------------------------------------------------------------------------
// Contract: clocks.

pub const timer = struct {
    pub var frequency: u32 = 24_000_000;
    pub var period_cycles: u32 = 24_000;

    pub fn init() void {
        var f = arch.cntFrq();
        if (f == 0) {
            f = 24_000_000;
            arch.setCntFrq(f);
        }
        frequency = f;
        period_cycles = f / uos.rtos.Clock.frequency_hz;
    }

    pub fn start1ms() void {
        arch.setCntpTval(period_cycles);
        arch.setCntpCtl(0x1); // enabled, not masked
    }
};

pub const clock_systick = struct {
    pub fn start() void {}
};

pub const clock_highres = struct {
    pub const has_hardware_counter = true;

    pub fn start() void {}

    pub fn hardwareCounter() u64 {
        return arch.cntPct();
    }

    pub fn inputClockFrequencyHz() u32 {
        return timer.frequency;
    }

    pub fn cyclesPerTick() u32 {
        return timer.frequency / 1000;
    }

    pub fn cyclesSinceTick() u32 {
        const load = cyclesPerTick();
        const val = arch.cntpTval();
        return if (val > load) 0 else load - val;
    }
};

// ----------------------------------------------------------------------------
// Contract: trace, termination, memory.

pub const semihosting = @import("semihosting.zig");

/// The console: the board's UART, every line mirrored to semihosting.
pub const trace = struct {
    pub fn write(bytes: []const u8) void {
        board.uartWrite(bytes);
        semihosting.mirror(bytes);
    }
};

/// End the run with a verdict (`hw_result`): the console drained, then a
/// semihosting SYS_EXIT. The probe that bridges the UART drops what it has
/// not forwarded when OpenOCD disconnects, so the UART is drained and about
/// one second passes first (as on the Cortex-M port).
pub fn terminate(code: u8) noreturn {
    arch.disableIrq();
    semihosting.flush();
    board.uartFlush();
    const start = arch.cntPct();
    while (arch.cntPct() - start < timer.frequency) {}
    semihosting.exit(code);
    arch.disableIrq();
    while (true) arch.wfi();
}

extern var __heap_start: u8;
extern var __heap_end: u8;

/// The free store: the linker script's heap region.
pub fn freeRam() []u8 {
    const start = @intFromPtr(&__heap_start);
    const end = @intFromPtr(&__heap_end);
    return @as([*]u8, @ptrCast(&__heap_start))[0 .. end - start];
}

extern var __fiq_stack_top: u8;
extern var __irq_stack_top: u8;

/// The IRQ-mode stack (C++: `interrupts::stack()` set to it).
pub fn interruptStack() ?[]StackElement {
    const lo = @intFromPtr(&__fiq_stack_top);
    const hi = @intFromPtr(&__irq_stack_top);
    const p: [*]StackElement = @ptrFromInt(lo);
    return p[0 .. (hi - lo) / @sizeOf(StackElement)];
}

// ----------------------------------------------------------------------------
// Entry from the board's startup, and the exception handlers.

pub const faults = @import("faults.zig");

/// Called by the board's startup on CPU 0, with the MMU on.
export fn uos_core0_main() callconv(.c) noreturn {
    board.init();
    root.main();
    while (true) arch.wfi();
}

comptime {
    _ = faults;
    _ = board;
}
