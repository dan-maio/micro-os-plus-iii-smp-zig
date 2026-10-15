//! The synthetic POSIX port of µOS++ IIIe (the C++ micro-os-plus-iii-posix-arch,
//! smp branch: src/rtos/os-core.cpp, src/host_cpu.cpp, the port headers).
//!
//! µOS++ runs as a host process; host threads act as CPUs:
//!
//!   - a CPU is a host thread (CPU 0 the process' main thread, the others
//!     started by `startSecondaryCpus()`); its index is a thread-local;
//!   - a µOS++ thread is a glibc ucontext on its µOS++ stack; a context switch
//!     is `swapcontext()`, on whichever host thread runs it;
//!   - the interrupts are two signals: SIGRTMIN, each CPU's tick (a
//!     `timer_create()` timer aimed at its host thread), and SIGRTMIN+1, the
//!     cross-CPU reschedule request (`pthread_kill()`); "interrupts masked"
//!     is the two signals blocked;
//!   - the handlers run on the current µOS++ thread's stack and may switch
//!     context there (preemption), unless the kernel lock is held, in which
//!     case the switch is left pending for the next interrupt;
//!   - the kernel lock is a recursive spin lock with a per-CPU owner, as on
//!     the ARM ports, taken with the signals blocked.
//!
//! Only GNU/Linux: the per-thread tick needs `SIGEV_THREAD_ID`.

const std = @import("std");
const builtin = @import("builtin");
const uos = @import("uos");
const c = @import("host_c");

const config = uos.config;
const ncpu = config.ncpu;

comptime {
    if (builtin.os.tag != .linux) @compileError("the POSIX port supports GNU/Linux only (per-thread tick timers)");
}

// ----------------------------------------------------------------------------
// Contract: stacks and contexts.

pub const StackElement = u64;
pub const stack_alignment: usize = 16;
pub const stack_magic: StackElement = 0xEFBE_ADDE_EFBE_ADDE;

/// The per-thread context: `stack_ptr` first (null while the context is
/// live in some CPU, as the SMP scheduler expects), then the ucontext.
pub const Context = struct {
    stack_ptr: ?[*]StackElement = null,
    ucontext: c.ucontext_t = undefined,
};

/// The C API storage sizes this port raises, in pointer words: a thread
/// carries a ucontext. The same numbers as
/// include/cmsis-plus/rtos/port/os-c-storage.h.
pub const c_storage_words = struct {
    pub const thread = 192;
};

const Entry = *const fn (?*anyopaque) callconv(.c) noreturn;

/// The first code a new context runs: unmask what the switch left masked,
/// publish the outgoing context, then the thread body.
fn trampoline(func: Entry, args: ?*anyopaque) callconv(.c) noreturn {
    blockIrqs(null);
    publishPending();
    unblockIrqs();
    func(args);
}

pub fn contextCreate(ctx: *Context, stack: []StackElement, entry: Entry, arg: ?*anyopaque) void {
    ctx.* = .{};
    const uc = &ctx.ucontext;
    if (c.getcontext(uc) != 0) fatal("getcontext");
    uc.uc_link = null;
    uc.uc_stack.ss_sp = @ptrCast(stack.ptr);
    uc.uc_stack.ss_size = stack.len * @sizeOf(StackElement);
    uc.uc_stack.ss_flags = 0;
    // The thread starts with the interrupts masked; the trampoline unmasks
    // them once the switch is complete.
    _ = c.sigemptyset(&uc.uc_sigmask);
    _ = c.sigaddset(&uc.uc_sigmask, tickSignal());
    _ = c.sigaddset(&uc.uc_sigmask, ipiSignal());
    c.makecontext(uc, @ptrCast(&trampoline), 2, entry, arg);
    ctx.stack_ptr = @ptrCast(@alignCast(&ctx.ucontext));
}

// ----------------------------------------------------------------------------
// CPUs, signals, the kernel lock.

/// The CPU (host thread) the caller runs on. Out of line, as the C++
/// `port_cpu_id()`: a thread-local address must be computed anew after a
/// context switch, which may have moved the thread to another host thread.
threadlocal var this_cpu: u32 = 0;

noinline fn readCpu() u32 {
    asm volatile ("" ::: .{ .memory = true });
    return this_cpu;
}

fn tickSignal() c_int {
    return c.__libc_current_sigrtmin();
}

fn ipiSignal() c_int {
    return c.__libc_current_sigrtmin() + 1;
}

/// The signals this port treats as interrupts.
var irq_set: c.sigset_t = undefined;

fn blockIrqs(old: ?*c.sigset_t) void {
    _ = c.pthread_sigmask(c.SIG_BLOCK, &irq_set, old);
}

fn unblockIrqs() void {
    _ = c.pthread_sigmask(c.SIG_UNBLOCK, &irq_set, null);
}

/// Per-CPU handler-mode flag.
var in_isr: [ncpu]bool = @splat(false);

/// Raised by the CMSIS-RTOS validator's host shim around its SIGUSR1
/// "interrupt" (cmsis-plus/src/main.c), so the RTOS sees handler mode.
export var signal_nesting: u32 = 0;

const no_owner: u32 = 0xFFFF_FFFF;

const KernelLock = extern struct {
    lock: u32 = 0,
    owner: u32 = no_owner,
    depth: u32 = 0,
};

var klock: KernelLock = .{};

/// Per-CPU scheduler lock state.
var lock_state: [ncpu]bool = @splat(false);

/// A context switch requested while it could not happen (kernel lock held,
/// or in a handler); done at the next interrupt's exit.
var ctx_pending: [ncpu]u32 = @splat(0);

inline fn klockRawAcquire() void {
    while (@atomicRmw(u32, &klock.lock, .Xchg, 1, .acquire) != 0) {
        std.atomic.spinLoopHint();
    }
}

inline fn klockRawRelease() void {
    @atomicStore(u32, &klock.lock, 0, .release);
}

inline fn klockTake(cpu: u32) void {
    if (@atomicLoad(u32, &klock.owner, .monotonic) != cpu) {
        klockRawAcquire();
        @atomicStore(u32, &klock.owner, cpu, .monotonic);
    }
    klock.depth += 1;
}

inline fn klockPut(cpu: u32) void {
    if (@atomicLoad(u32, &klock.owner, .monotonic) == cpu and klock.depth > 0) {
        const d = klock.depth - 1;
        klock.depth = d;
        if (d == 0) {
            @atomicStore(u32, &klock.owner, no_owner, .monotonic);
            klockRawRelease();
        }
    }
}

inline fn klockHeldHere(cpu: u32) bool {
    return @atomicLoad(u32, &klock.owner, .monotonic) == cpu and klock.depth > 0;
}

// ----------------------------------------------------------------------------
// Contract: interrupts.

pub const interrupts = struct {
    /// True when this CPU's interrupt signals were blocked.
    pub const State = bool;

    pub fn criticalEnter() State {
        var old: c.sigset_t = undefined;
        blockIrqs(&old);
        klockTake(readCpu());
        return c.sigismember(&old, tickSignal()) != 0;
    }

    pub fn criticalExit(state: State) void {
        klockPut(readCpu());
        _ = c.pthread_sigmask(if (state) c.SIG_BLOCK else c.SIG_UNBLOCK, &irq_set, null);
    }

    pub fn uncriticalEnter() State {
        var old: c.sigset_t = undefined;
        _ = c.pthread_sigmask(c.SIG_UNBLOCK, &irq_set, &old);
        return c.sigismember(&old, tickSignal()) != 0;
    }

    pub fn uncriticalExit(state: State) void {
        _ = c.pthread_sigmask(if (state) c.SIG_BLOCK else c.SIG_UNBLOCK, &irq_set, null);
    }

    pub fn inHandlerMode() bool {
        const cpu = readCpu();
        return (cpu < ncpu and @atomicLoad(bool, &in_isr[cpu], .monotonic)) or
            @atomicLoad(u32, &signal_nesting, .monotonic) != 0;
    }

    pub fn isPriorityValid() bool {
        return true;
    }
};

// ----------------------------------------------------------------------------
// Contract: scheduler.

pub const scheduler = struct {
    pub fn initialize() void {
        // The trace writes the standard output directly; C code linked with
        // the application prints there through stdio. Unbuffered, the two
        // stay in program order (in C++ both go through stdio).
        _ = c.setvbuf(c.stdout, null, c._IONBF, 0);
        _ = c.sigemptyset(&irq_set);
        _ = c.sigaddset(&irq_set, tickSignal());
        _ = c.sigaddset(&irq_set, ipiSignal());
        for (0..ncpu) |i| {
            lock_state[i] = false;
            ctx_pending[i] = 0;
            in_isr[i] = false;
        }
        installHandlers();
        faults.install();
        blockIrqs(null);
    }

    pub fn cpuId() u32 {
        return readCpu();
    }

    pub fn isLocked() bool {
        return @atomicLoad(bool, &lock_state[readCpu()], .monotonic);
    }

    /// `port::scheduler::locked(state)`: set this CPU's lock state, taking
    /// or releasing the kernel lock; returns the previous state.
    pub fn setLocked(state: bool) bool {
        std.debug.assert(!interrupts.inHandlerMode());
        if (state) {
            blockIrqs(null);
            const cpu = readCpu();
            const prev = lock_state[cpu];
            if (!prev) {
                if (@atomicLoad(u32, &klock.owner, .monotonic) != cpu) {
                    klockRawAcquire();
                    @atomicStore(u32, &klock.owner, cpu, .monotonic);
                }
                klock.depth += 1;
                @atomicStore(bool, &lock_state[cpu], true, .monotonic);
            }
            return prev;
        } else {
            const cpu = readCpu();
            const prev = lock_state[cpu];
            if (prev) {
                @atomicStore(bool, &lock_state[cpu], false, .monotonic);
                klockPut(cpu);
                unblockIrqs();
            }
            return prev;
        }
    }

    /// Request a context switch on this CPU: now, or, when the kernel lock
    /// is held or in a handler, at the next interrupt's exit.
    pub fn reschedule() void {
        const cpu = readCpu();
        if (uos.rtos.scheduler.locked() or
            (interrupts.inHandlerMode() and !uos.rtos.scheduler.isPreemptive())) return;
        if (klockHeldHere(cpu) or interrupts.inHandlerMode()) {
            ctx_pending[cpu] = 1;
            return;
        }
        switchStacks();
    }

    /// Sleep until an interrupt signal arrives.
    pub fn waitForInterrupt() void {
        var mask: c.sigset_t = undefined;
        _ = c.pthread_sigmask(c.SIG_SETMASK, null, &mask);
        _ = c.sigdelset(&mask, tickSignal());
        _ = c.sigdelset(&mask, ipiSignal());
        _ = c.sigsuspend(&mask);
    }

    pub fn prepareSuspend() void {}

    /// Cross-CPU reschedule request.
    pub fn ipi(cpu: u32) void {
        if (cpu < ncpu and @atomicLoad(bool, &cpu_up[cpu], .acquire)) {
            _ = c.pthread_kill(cpu_thread[cpu], ipiSignal());
        }
    }

    pub fn greeting(w: *std.Io.Writer) std.Io.Writer.Error!void {
        var name: c.struct_utsname = undefined;
        if (c.uname(&name) != -1) {
            try w.print("POSIX synthetic SMP, running on {s} {s} {s}", .{
                std.mem.sliceTo(&name.machine, 0),
                std.mem.sliceTo(&name.sysname, 0),
                std.mem.sliceTo(&name.release, 0),
            });
        } else {
            try w.writeAll("POSIX synthetic SMP");
        }
        try w.print("; {d} CPU{s}, {d} Hz tick, preemptive\n", .{
            ncpu, if (ncpu == 1) "" else "s", uos.rtos.Clock.frequency_hz,
        });
    }

    /// Start CPU 0: its tick, then the first context switch; never returns.
    pub fn start() noreturn {
        blockIrqs(null);
        uos.rtos.scheduler.internalPrepareCpu(0);
        for (&lock_state) |*s| s.* = false;
        startThisCpuTick();
        reschedule();
        unblockIrqs();
        while (true) _ = c.pause();
    }
};

/// The context switch (`port::scheduler::switch_stacks()`): with the
/// interrupts masked and the kernel lock held, let the kernel pick the next
/// thread, then `swapcontext()` to it.
///
/// The outgoing context is published (its `stack_ptr` set back to non-null)
/// only after the switch completed, by whatever code runs next on this CPU
/// (`publishPending()`): until then its registers are still being saved,
/// and another CPU must not pick it.
fn switchStacks() void {
    var saved_mask: c.sigset_t = undefined;
    blockIrqs(&saved_mask);

    const cpu = readCpu();
    klockRawAcquire();
    @atomicStore(u32, &klock.owner, cpu, .monotonic);
    klock.depth = 1;

    const sched = uos.rtos.scheduler;
    const old_thread = sched.current_thread[cpu].?;
    const pub_addr = &old_thread.context.port.stack_ptr;
    const pub_val: [*]StackElement = @ptrCast(@alignCast(&old_thread.context.port.ucontext));
    @atomicStore(?[*]StackElement, pub_addr, null, .release);

    sched.internalSwitchThreads();

    const new_thread = sched.current_thread[cpu] orelse {
        traceWrite("\n!!! no ready thread and no idle thread on this CPU !!!\n");
        c.abort();
    };

    if (new_thread == old_thread) {
        @atomicStore(?[*]StackElement, pub_addr, pub_val, .release);
        klock.depth = 0;
        @atomicStore(u32, &klock.owner, no_owner, .monotonic);
        klockRawRelease();
        _ = c.pthread_sigmask(c.SIG_SETMASK, &saved_mask, null);
        return;
    }

    @atomicStore(?[*]StackElement, &new_thread.context.port.stack_ptr, null, .release);
    deferPublish(cpu, pub_addr, pub_val);

    // Release the kernel lock before the switch: the incoming context may
    // resume anywhere (the end of this function, a handler, the trampoline)
    // and none of them expects to own it.
    klock.depth = 0;
    @atomicStore(u32, &klock.owner, no_owner, .monotonic);
    klockRawRelease();

    if (c.swapcontext(&old_thread.context.port.ucontext, &new_thread.context.port.ucontext) != 0) {
        fatal("swapcontext");
    }

    // Back in this thread, possibly on another CPU.
    publishPending();
    _ = c.pthread_sigmask(c.SIG_SETMASK, &saved_mask, null);
}

// ----------------------------------------------------------------------------
// The host CPUs (`host_cpu.cpp`).

var cpu_thread: [ncpu]c.pthread_t = undefined;
var cpu_up: [ncpu]bool = @splat(false);

/// Per-CPU stage, as on the ARM boards: 0 not started, 3 scheduler entered
/// (`g_core_stage[]`).
var core_stage: [ncpu]u32 = @splat(0);

pub fn coreStage(cpu: u32) u32 {
    return @atomicLoad(u32, &core_stage[cpu], .acquire);
}

/// The deferred-publish slot, one per CPU.
const PublishSlot = struct {
    addr: ?*?[*]StackElement = null,
    val: ?[*]StackElement = null,
};
var publish_slot: [ncpu]PublishSlot = @splat(.{});

fn deferPublish(cpu: u32, addr: *?[*]StackElement, val: [*]StackElement) void {
    publish_slot[cpu] = .{ .addr = addr, .val = val };
}

fn publishPending() void {
    const cpu = readCpu();
    if (cpu >= ncpu) return;
    const addr = publish_slot[cpu].addr orelse return;
    publish_slot[cpu].addr = null;
    @atomicStore(?[*]StackElement, addr, publish_slot[cpu].val, .release);
}

/// After a handler: do the context switch it asked for, if it can be done.
fn irqEpilogue(cpu: u32) void {
    if (ctx_pending[cpu] == 0) return;
    if (uos.rtos.scheduler.locked()) return;
    if (klockHeldHere(cpu)) return;
    ctx_pending[cpu] = 0;
    switchStacks();
}

/// errno belongs to the µOS++ thread a handler interrupted.
fn errnoPtr() *c_int {
    return c.__errno_location();
}

fn tickHandler(_: c_int, _: ?*c.siginfo_t, _: ?*anyopaque) callconv(.c) void {
    const saved = errnoPtr().*;
    defer errnoPtr().* = saved;
    const cpu = readCpu();
    if (cpu >= ncpu) return;
    @atomicStore(bool, &in_isr[cpu], true, .monotonic);
    // Every CPU ticks; only CPU 0 drives the clocks.
    if (cpu == 0) uos.rtos.clocks.sysTickHandler();
    ctx_pending[cpu] = 1;
    @atomicStore(bool, &in_isr[cpu], false, .monotonic);
    irqEpilogue(cpu);
}

fn ipiHandler(_: c_int, _: ?*c.siginfo_t, _: ?*anyopaque) callconv(.c) void {
    const saved = errnoPtr().*;
    defer errnoPtr().* = saved;
    const cpu = readCpu();
    if (cpu >= ncpu) return;
    @atomicStore(bool, &in_isr[cpu], true, .monotonic);
    ctx_pending[cpu] = 1;
    @atomicStore(bool, &in_isr[cpu], false, .monotonic);
    irqEpilogue(cpu);
}

fn installHandlers() void {
    var sa: c.struct_sigaction = std.mem.zeroes(c.struct_sigaction);
    sa.sa_flags = c.SA_SIGINFO | c.SA_RESTART;
    _ = c.sigemptyset(&sa.sa_mask);
    _ = c.sigaddset(&sa.sa_mask, tickSignal());
    _ = c.sigaddset(&sa.sa_mask, ipiSignal());
    sa.__sigaction_handler.sa_sigaction = tickHandler;
    if (c.sigaction(tickSignal(), &sa, null) != 0) fatal("sigaction(tick)");
    sa.__sigaction_handler.sa_sigaction = ipiHandler;
    if (c.sigaction(ipiSignal(), &sa, null) != 0) fatal("sigaction(ipi)");

    cpu_thread[0] = c.pthread_self();
    @atomicStore(bool, &cpu_up[0], true, .release);
    @atomicStore(u32, &core_stage[0], 3, .release);
    faults.installStack();
}

/// This CPU's tick: a `CLOCK_MONOTONIC` timer whose signal goes to this
/// host thread only.
fn startThisCpuTick() void {
    var sev: c.struct_sigevent = std.mem.zeroes(c.struct_sigevent);
    sev.sigev_notify = c.SIGEV_THREAD_ID;
    sev._sigev_un._tid = @intCast(std.os.linux.gettid());
    sev.sigev_signo = tickSignal();
    var timer: c.timer_t = undefined;
    if (c.timer_create(c.CLOCK_MONOTONIC, &sev, &timer) != 0) fatal("timer_create");
    const period_ns: c_long = @intCast(1_000_000_000 / uos.rtos.Clock.frequency_hz);
    var its: c.struct_itimerspec = .{
        .it_value = .{ .tv_sec = 0, .tv_nsec = period_ns },
        .it_interval = .{ .tv_sec = 0, .tv_nsec = period_ns },
    };
    if (c.timer_settime(timer, 0, &its, null) != 0) fatal("timer_settime");
}

fn secondaryCpuBody(arg: ?*anyopaque) callconv(.c) ?*anyopaque {
    const cpu: u32 = @intCast(@intFromPtr(arg));
    this_cpu = cpu;
    faults.installStack();
    blockIrqs(null);
    uos.rtos.scheduler.internalPrepareCpu(cpu);
    @atomicStore(bool, &cpu_up[cpu], true, .release);
    startThisCpuTick();
    @atomicStore(u32, &core_stage[cpu], 3, .release);
    scheduler.reschedule();
    unblockIrqs();
    while (true) _ = c.pause();
}

/// Start CPUs 1..ncpu-1 (`host_cpu::start_secondary_cpus()`, called by the
/// application, as `smp::start_secondary_cores()` in C++), and wait until
/// they are up.
pub fn startSecondaryCpus() void {
    var cpu: u32 = 1;
    while (cpu < ncpu) : (cpu += 1) {
        if (c.pthread_create(&cpu_thread[cpu], null, secondaryCpuBody, @ptrFromInt(cpu)) != 0) {
            fatal("pthread_create(cpu)");
        }
    }
    cpu = 1;
    while (cpu < ncpu) : (cpu += 1) {
        while (!@atomicLoad(bool, &cpu_up[cpu], .acquire)) _ = c.usleep(100);
    }
}

// ----------------------------------------------------------------------------
// Contract: clocks.

pub const clock_systick = struct {
    pub fn start() void {}
};

fn monotonicMicros() u64 {
    var tp: c.struct_timespec = undefined;
    _ = c.clock_gettime(c.CLOCK_MONOTONIC, &tp);
    return @as(u64, @intCast(tp.tv_sec)) * 1_000_000 + @as(u64, @intCast(tp.tv_nsec)) / 1000;
}

var previous_timestamp: u64 = 0;

pub const clock_highres = struct {
    pub const has_hardware_counter = true;

    pub fn start() void {
        previous_timestamp = monotonicMicros();
    }

    /// Microseconds of `CLOCK_MONOTONIC`.
    pub fn hardwareCounter() u64 {
        return monotonicMicros();
    }

    pub fn inputClockFrequencyHz() u32 {
        return 1_000_000;
    }

    pub fn cyclesPerTick() u32 {
        const ts = monotonicMicros();
        const delta: u32 = @truncate(ts - previous_timestamp);
        previous_timestamp = ts;
        return delta;
    }

    pub fn cyclesSinceTick() u32 {
        return @truncate(monotonicMicros() - previous_timestamp);
    }
};

// ----------------------------------------------------------------------------
// Contract: trace, termination, memory.

fn traceWrite(bytes: []const u8) void {
    var rest = bytes;
    while (rest.len > 0) {
        const n = c.write(1, rest.ptr, rest.len);
        if (n <= 0) {
            if (n < 0 and errnoPtr().* == c.EINTR) continue;
            return;
        }
        rest = rest[@intCast(n)..];
    }
}

/// The trace goes to the standard output (`OS_USE_TRACE_POSIX_STDOUT`).
pub const trace = struct {
    pub fn write(bytes: []const u8) void {
        traceWrite(bytes);
    }
};

/// End the process with the verdict as its exit code (`hw_result`): flush
/// the C stdio buffers first (C code linked with the application prints
/// with printf()), then `_exit()`.
pub fn terminate(code: u8) noreturn {
    _ = c.fflush(null);
    c._exit(code);
}

/// The application free store: 32 MiB, as the C++ native board's heap.
var heap: [32 * 1024 * 1024]u8 align(16) = undefined;

pub fn freeRam() []u8 {
    return &heap;
}

fn fatal(what: []const u8) noreturn {
    traceWrite("\n!!! posix-arch: ");
    traceWrite(what);
    traceWrite(": ");
    traceWrite(std.mem.span(c.strerror(errnoPtr().*)));
    traceWrite("\n");
    c.abort();
}

// ----------------------------------------------------------------------------
// Synchronous faults (`exception_handler.cpp`): reported, not silent.

pub const faults = struct {
    /// One per CPU: the handler runs here, not on the (possibly overflowed)
    /// thread stack.
    var stacks: [ncpu][64 * 1024]u8 align(16) = undefined;
    var load_bias: u64 = 0;

    fn installStack() void {
        const cpu = readCpu();
        if (cpu >= ncpu) return;
        var ss: c.stack_t = std.mem.zeroes(c.stack_t);
        ss.ss_sp = &stacks[cpu];
        ss.ss_size = stacks[cpu].len;
        ss.ss_flags = 0;
        _ = c.sigaltstack(&ss, null);
    }

    fn install() void {
        var info: c.Dl_info = undefined;
        if (c.dladdr(@ptrCast(&install), &info) != 0) load_bias = @intFromPtr(info.dli_fbase);

        var sa: c.struct_sigaction = std.mem.zeroes(c.struct_sigaction);
        // On the alternate stack (and NOT the tick, which must run on the
        // thread's stack so that its frame migrates with the thread).
        sa.sa_flags = c.SA_SIGINFO | c.SA_ONSTACK;
        _ = c.sigemptyset(&sa.sa_mask);
        sa.__sigaction_handler.sa_sigaction = handler;
        for ([_]c_int{ c.SIGSEGV, c.SIGBUS, c.SIGFPE, c.SIGILL }) |sig| _ = c.sigaction(sig, &sa, null);
    }

    fn emit(s: []const u8) void {
        _ = c.write(2, s.ptr, s.len);
    }

    fn emitHex(v: u64) void {
        var buf: [18]u8 = undefined;
        emit(std.fmt.bufPrint(&buf, "0x{X:0>16}", .{v}) catch unreachable);
    }

    fn pcOf(ucontext: ?*anyopaque) u64 {
        const uc: *c.ucontext_t = @ptrCast(@alignCast(ucontext orelse return 0));
        return switch (builtin.cpu.arch) {
            .x86_64 => @bitCast(uc.uc_mcontext.gregs[c.REG_RIP]),
            .aarch64 => uc.uc_mcontext.pc,
            else => 0,
        };
    }

    fn handler(sig: c_int, info: ?*c.siginfo_t, ucontext: ?*anyopaque) callconv(.c) void {
        const pc = pcOf(ucontext);
        const addr: u64 = if (info) |i| @intFromPtr(i._sifields._sigfault.si_addr) else 0;

        emit("\n!!! FATAL EXCEPTION on CPU ");
        emit(&.{'0' + @as(u8, @intCast(readCpu() % 10))});
        emit(" -- signal ");
        emit(std.mem.span(c.strsignal(sig)));
        emit(" at ");
        emitHex(addr);
        emit(", pc ");
        emitHex(pc);
        emit(" (static ");
        emitHex(pc -% load_bias);
        emit(")\n");

        for (0..ncpu) |cpu| {
            emit("  cpu");
            emit(&.{'0' + @as(u8, @intCast(cpu % 10))});
            emit(": ");
            emit(if (uos.rtos.scheduler.current_thread[cpu]) |th| th.name else "(null)");
            emit("\n");
        }
        emit("  klock: owner=");
        emitHex(klock.owner);
        emit(" depth=");
        emitHex(klock.depth);
        emit(" lock=");
        emitHex(klock.lock);
        emit("\n");

        var frames: [24]?*anyopaque = undefined;
        const n = c.backtrace(&frames, frames.len);
        emit("  backtrace (static):\n");
        for (frames[0..@intCast(n)]) |f| {
            emit("    ");
            emitHex(@intFromPtr(f) -% load_bias);
            emit("\n");
        }

        _ = c.signal(sig, c.SIG_DFL);
        _ = c.raise(sig);
        c._exit(@intCast(128 + sig));
    }
};
