//! The scheduler (`os::rtos::scheduler`, `src/rtos/os-core.cpp`).
//!
//! Priority preemptive, round robin among equal priorities. With
//! `uos_options.smp` it manages `ncpu` CPUs: one current thread per CPU, an
//! affinity-aware pick from the single shared ready list, and the port's
//! recursive kernel lock taken by every critical section.
//!
//! The C++ edition keeps two code paths (scalar `current_thread_` and the
//! SMP arrays). Here there is one: the arrays have `ncpu` entries and
//! `port.scheduler.cpuId()` is 0 on a single-CPU port, so the single-core
//! build compiles to the same scalar code.

const std = @import("std");
const assert = std.debug.assert;

const port = @import("uos_port");
const config = @import("../config.zig");
const trace = @import("../trace.zig");
const result = @import("result.zig");
const Error = result.Error;
const interrupts = @import("interrupts.zig");
const lists = @import("lists.zig");
const thread_mod = @import("thread.zig");
const Thread = thread_mod.Thread;
const clocks = @import("clocks.zig");

const ncpu = config.ncpu;
const tr = config.options.trace;

// ----------------------------------------------------------------------------
// State.

/// Set by `start()`; the scheduler cannot be stopped, only locked.
pub var is_started: bool = false;

/// `OS_BOOL_RTOS_SCHEDULER_PREEMPTIVE`, latched by `start()`.
pub var is_preemptive: bool = false;

/// The children of no thread: threads created before the scheduler started
/// and detached threads.
pub var top_threads_list: lists.List = .{};

/// The running thread of each CPU, indexed by `port.scheduler.cpuId()`.
/// Before `start()` it is the last thread constructed (so that its parent
/// pointer is meaningful), and from `start()` until the first switch it is
/// the CPU's boot pseudo-thread.
pub var current_thread: [ncpu]?*Thread = @splat(null);

/// One idle thread per CPU; secondary CPUs register theirs at boot. The pick
/// pins each one to its own CPU.
pub var idle_thread_core: [ncpu]?*Thread = @splat(null);

pub var ready_threads_list: lists.ReadyThreadsList = .{};

/// Terminated threads, destroyed later by the idle thread.
pub var terminated_threads_list: lists.TerminatedThreadsList = .{};

/// The pseudo-thread each CPU "runs" between the port's start code and the
/// first context switch (the C++ `fake_thread`). Its state is `undefined`,
/// so the first switch does not re-link it, and it is never restored.
pub var boot_threads: [ncpu]Thread = blk: {
    var b: [ncpu]Thread = undefined;
    for (&b) |*t| t.* = .{ .name = "boot" };
    break :blk b;
};

pub const statistics = struct {
    pub var context_switches: u64 = 0;
    pub var switch_timestamp: u64 = 0;
    pub var cpu_cycles: u64 = 0;
};

// ----------------------------------------------------------------------------
// Public API.

/// Initialise the RTOS internals; call once, before creating threads.
pub fn initialize() Error!void {
    if (tr.scheduler) trace.print("scheduler.initialize()\n", .{});
    if (interrupts.inHandlerMode()) return error.NotPermitted;
    port.scheduler.initialize();
}

/// Start the clocks and switch to the highest priority ready thread. Never
/// returns.
pub fn start() noreturn {
    trace.print("scheduler.start()\n", .{});
    assert(!interrupts.inHandlerMode());

    clocks.sysclock.start();
    clocks.hrclock.start();
    clocks.rtclock.start();

    if (config.options.statistics_context_switches) statistics.context_switches = 0;
    if (config.options.statistics_cpu_cycles) {
        statistics.cpu_cycles = 0;
        statistics.switch_timestamp = clocks.hrclock.now();
    }

    is_preemptive = config.options.preemptive;
    is_started = true;

    port.scheduler.start();
}

pub inline fn started() bool {
    return is_started;
}

/// Set the preemptive mode; returns the previous one.
pub fn preemptive(state: bool) Error!bool {
    if (tr.scheduler) trace.print("scheduler.preemptive({})\n", .{state});
    if (interrupts.inHandlerMode()) return error.NotPermitted;
    const cs = interrupts.CriticalSection.enter();
    defer cs.exit();
    const prev = is_preemptive;
    is_preemptive = state;
    return prev;
}

pub inline fn isPreemptive() bool {
    return is_preemptive;
}

/// True while thread switching is locked (on the calling CPU).
pub inline fn locked() bool {
    return port.scheduler.isLocked();
}

/// Lock the scheduler; returns the previous state.
pub fn lock() bool {
    return port.scheduler.setLocked(true);
}

/// Unlock the scheduler; returns the previous state.
pub fn unlock() bool {
    return port.scheduler.setLocked(false);
}

/// Restore a state returned by `lock()`/`unlock()`; returns the previous one.
pub fn setLocked(state: bool) bool {
    return port.scheduler.setLocked(state);
}

/// Thread switching disabled until `exit()`; nests.
///
/// ```zig
/// const scs = scheduler.CriticalSection.enter();
/// defer scs.exit();
/// ```
pub const CriticalSection = struct {
    state: bool,

    pub inline fn enter() CriticalSection {
        if (tr.scheduler) trace.write("{C ");
        return .{ .state = lock() };
    }

    pub inline fn exit(scs: CriticalSection) void {
        if (tr.scheduler) trace.write(" C}");
        _ = setLocked(scs.state);
    }
};

/// Thread switching enabled until `exit()`, even inside a critical section.
pub const UncriticalSection = struct {
    state: bool,

    pub inline fn enter() UncriticalSection {
        return .{ .state = unlock() };
    }

    pub inline fn exit(us: UncriticalSection) void {
        _ = setLocked(us.state);
    }
};

/// The children of `th`, or the top level threads when null.
pub fn childrenThreads(th: ?*Thread) *lists.List {
    return if (th) |t| &t.children else &top_threads_list;
}

// ----------------------------------------------------------------------------
// Internals shared by the synchronisation objects.

/// Suspend the current thread on `list`. Called in an interrupts critical
/// section; the caller then requests a reschedule.
pub fn internalLinkNode(list: *lists.WaitingThreadsList, node: *lists.WaitingThreadNode) void {
    // Remove this thread from the ready list, if there.
    port.scheduler.prepareSuspend();
    list.link(node);
    node.thread.waiting_node = node;
    node.thread.state = .suspended;
}

/// The same, plus a timeout in a clock list.
pub fn internalLinkNodeTimeout(
    list: *lists.WaitingThreadsList,
    node: *lists.WaitingThreadNode,
    timeout_list: *lists.ClockTimestampsList,
    timeout_node: *lists.TimeoutThreadNode,
) void {
    internalLinkNode(list, node);
    timeout_list.link(&timeout_node.node);
    timeout_node.thread.clock_node = timeout_node;
}

pub fn internalUnlinkNode(node: *lists.WaitingThreadNode) void {
    const cs = interrupts.CriticalSection.enter();
    defer cs.exit();
    node.thread.waiting_node = null;
    node.links.unlink();
}

pub fn internalUnlinkNodeTimeout(node: *lists.WaitingThreadNode, timeout_node: *lists.TimeoutThreadNode) void {
    const cs = interrupts.CriticalSection.enter();
    defer cs.exit();
    // Remove the thread from the clock list, if not already removed by the
    // tick, and from the waiting list, if not already resumed.
    timeout_node.thread.clock_node = null;
    timeout_node.node.links.unlink();
    node.thread.waiting_node = null;
    node.links.unlink();
}

/// True when `th` is the idle thread of some CPU.
fn isIdleThread(th: *const Thread) bool {
    for (idle_thread_core) |idle| {
        if (idle == th) return true;
    }
    return false;
}

/// The affinity gate (SMP): a per-CPU idle thread runs only on its own CPU,
/// every other thread follows its affinity mask.
///
/// Identity against `idle_thread_core[]` is authoritative; the name rule is
/// the fallback for the boot window between an idle thread being linked to
/// the ready list by its constructor and its registration.
fn isThreadAllowedOnCpu(th: *const Thread, cpu: u32) bool {
    for (idle_thread_core, 0..) |idle, c| {
        if (idle == th) return cpu == c;
    }
    const name = th.name;
    if (std.mem.startsWith(u8, name, "idle")) {
        if (name.len == 4) return cpu == 0;
        if (name.len == 5 and name[4] >= '0' and name[4] <= '9') return cpu == name[4] - '0';
    }
    return (th.cpu_affinity & (@as(u32, 1) << @intCast(cpu))) != 0;
}

/// The core of the scheduler: re-link the outgoing thread and make the next
/// one current. Called by the port's context switch with the kernel lock
/// held and interrupts masked, after it saved the outgoing context.
pub fn internalSwitchThreads() void {
    const cpu = port.scheduler.cpuId();

    if (config.options.statistics_cpu_cycles) {
        const now = clocks.hrclock.now();
        const delta = now -% statistics.switch_timestamp;
        statistics.cpu_cycles +%= delta;
        current_thread[cpu].?.statistics.cpu_cycles +%= delta;
        statistics.switch_timestamp = now;
    }

    if (!locked()) {
        const old_thread = current_thread[cpu].?;

        if (!config.smp) {
            // Normally the old running thread must be re-linked to ready.
            old_thread.internalRelinkRunning();
            // The top of the ready list gives the next thread to run.
            current_thread[0] = ready_threads_list.unlinkHead();
        } else {
            if (!isIdleThread(old_thread)) {
                old_thread.internalRelinkRunning();
            } else {
                old_thread.state = .ready;
            }

            // Affinity-aware pick. Skip threads whose saved stack pointer is
            // null: their context is still live in another CPU's registers.
            // This CPU's own outgoing thread may always be re-picked.
            var next_thread: ?*Thread = null;
            var it = ready_threads_list.list.iterator();
            while (it.next()) |links| {
                const th = lists.WaitingThreadNode.fromLinks(links).thread;
                if (isThreadAllowedOnCpu(th, cpu) and
                    (th == old_thread or (th.state != .running and
                        @atomicLoad(?[*]port.StackElement, &th.context.port.stack_ptr, .acquire) != null)))
                {
                    next_thread = th;
                    links.unlink();
                    th.state = .running;
                    break;
                }
            }

            if (next_thread) |th| {
                @atomicStore(?*Thread, &current_thread[cpu], th, .release);
            } else {
                const idle = idle_thread_core[cpu];
                @atomicStore(?*Thread, &current_thread[cpu], idle, .release);
                if (idle) |t| t.state = .running;
            }
        }
    }

    if (config.options.statistics_context_switches) {
        statistics.context_switches +%= 1;
        if (current_thread[cpu]) |th| th.statistics.context_switches +%= 1;
    }
}

/// Make `th` the current thread of `cpu` before the scheduler runs it (used
/// by the ports for the boot pseudo-threads).
pub fn setCurrentThread(cpu: u32, th: *Thread) void {
    @atomicStore(?*Thread, &current_thread[cpu], th, .release);
}

/// Called by a port when it brings up `cpu`: the CPU "runs" its boot
/// pseudo-thread until the first context switch.
pub fn internalPrepareCpu(cpu: u32) void {
    boot_threads[cpu] = .{ .name = "boot" };
    setCurrentThread(cpu, &boot_threads[cpu]);
}
