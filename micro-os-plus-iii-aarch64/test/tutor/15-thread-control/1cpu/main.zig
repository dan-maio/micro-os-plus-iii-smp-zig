//! tutor-15-thread-control-1cpu -- lesson 15, one CPU (see ../README.md).
//!
//! Part A, a thread's states and the calls that move it between them: a
//! worker pauses itself (this_thread.suspend) and is resumed five times;
//! its wait on a semaphore and then its long sleep are cut short by
//! interrupt() (error.Interrupted; the flag stays set until cleared);
//! waiting forever, it is killed -- kill() unlinks it from the semaphore, so
//! a later post stays. A thread that never ran (ready) is killed too, and one
//! that returned is seen terminated, then joined.
//!
//! Part B, the stack: every stack is filled with a magic word when the
//! thread is created, and stack().available() counts the words never
//! written -- the high-water mark. A recursion of 0, 4, 8 and 16 frames of
//! 256 bytes each shows the cost per frame; a shallow thread that is
//! interrupted many times shows that an interrupt's frame lands on the
//! thread's own stack.
//!
//! Part C, statistics: per-thread context switches and CPU time. A `pulse`
//! thread works 2 ms and sleeps 2 ticks, 50 times: 100 ms of CPU; a lower
//! `hog` takes the rest. The CPU time of all threads adds up to the elapsed
//! time of every CPU.
//!
//! With four CPUs (the `four` switch) the worker, the pulses and the hogs
//! run on cores 1-3, and part D kills a thread while it is running on
//! another core.
//!
//! The Zig version of the C++ lesson (golden workspace,
//! test/rpi4b/tutor/15-thread-control/1cpu/main.cpp), with the same checks.

const std = @import("std");
const uos = @import("uos");
const board = @import("board");
const tutor = @import("tutor");

const rtos = uos.rtos;
const interrupts = rtos.interrupts;
const sysclock = rtos.sysclock;
const hrclock = rtos.hrclock;
const second_timer = tutor.second_timer;
const prio = rtos.priority;
const State = rtos.Thread.State;

const four = false;
const ncpu: u32 = if (four) 4 else 1;

// The lesson reads the threads' statistics: the kernel counts them only when
// asked to.
pub const uos_options = blk: {
    var o = board.options(@intCast(ncpu));
    o.statistics_context_switches = true;
    o.statistics_cpu_cycles = true;
    break :blk o;
};

const Func = *const fn (?*anyopaque) ?*anyopaque;

fn spawn(gpa: std.mem.Allocator, name: [:0]const u8, f: Func, arg: usize, p: rtos.Priority, core: ?u32) *rtos.Thread {
    var attr: rtos.Thread.Attributes = .{ .priority = p, .stack_size_bytes = 8 * 1024 };
    if (four) {
        if (core) |c| attr.cpu_affinity = @as(u32, 1) << @intCast(c);
    }
    return rtos.Thread.create(gpa, name, f, @ptrFromInt(arg), attr) catch {
        _ = tutor.check(false, "cannot create {s}", .{name});
        tutor.finish("");
    };
}

fn stateName(s: State) []const u8 {
    return switch (s) {
        .undefined => "undefined",
        .ready => "ready",
        .running => "running",
        .suspended => "suspended",
        .terminated => "terminated",
        .destroyed => "destroyed",
        else => "other",
    };
}

const Res = enum(u8) { none, ok, eintr, other };

fn resName(r: Res) []const u8 {
    return switch (r) {
        .ok => "ok",
        .eintr => "EINTR",
        else => "other",
    };
}

fn resOf(r: rtos.Error!void) Res {
    r catch |e| return if (e == error.Interrupted) .eintr else .other;
    return .ok;
}

// Busy for `us` microseconds, on the System Timer's clock.
fn spinUs(us: u32) void {
    const t0 = second_timer.nowUs();
    while (second_timer.nowUs() -% t0 < us) {}
}

// Wait, busy, until `cond` holds (at most 200 ms); with one CPU it already does.
fn until(ctx: anytype, comptime cond: fn (@TypeOf(ctx)) bool) bool {
    const t0 = second_timer.nowUs();
    while (!cond(ctx)) {
        if (second_timer.nowUs() -% t0 > 200000) return false;
    }
    return true;
}

// ---- Part A: states, suspend/resume, interrupt, kill -------------------------

const n_pauses = 5;
const worker_core: ?u32 = if (four) 1 else null;

var g_runs = std.atomic.Value(u32).init(0);
var g_phase = std.atomic.Value(u32).init(0); // 1 waiting, 2 sleeping, 3 waiting forever
var g_worker_core: u32 = 99;
var g_own_state: State = .undefined;
var g_never: rtos.Semaphore = .binary("never", 0);
var g_wait_res: Res = .none;
var g_sleep_res: Res = .none;
var g_wait_flag = false;
var g_wait_cleared = false;
var g_sleep_flag = false;
var g_slept: u64 = 0;

fn worker(_: ?*anyopaque) ?*anyopaque {
    const me = rtos.this_thread.thread();
    g_worker_core = board.cpuSlot();
    g_own_state = me.getState();
    for (0..n_pauses) |_| {
        _ = g_runs.fetchAdd(1, .seq_cst);
        rtos.this_thread.@"suspend"(); // until someone resumes it
    }
    _ = g_runs.fetchAdd(1, .seq_cst);

    // A wait that nobody will end with a post.
    g_phase.store(1, .seq_cst);
    g_wait_res = resOf(g_never.wait());
    g_wait_flag = me.isInterrupted();
    _ = me.interrupt(false); // the flag stays set until cleared
    g_wait_cleared = !me.isInterrupted();

    // A sleep of 100 s.
    g_phase.store(2, .seq_cst);
    const t0 = sysclock.now();
    g_sleep_res = resOf(sysclock.sleepFor(100000));
    g_slept = sysclock.now() - t0;
    g_sleep_flag = me.isInterrupted();
    _ = me.interrupt(false);

    // Forever: only kill() ends it.
    g_phase.store(3, .seq_cst);
    g_never.wait() catch {};
    g_phase.store(4, .seq_cst);
    return null;
}

var g_low_ran = std.atomic.Value(u32).init(0);

fn lowBody(_: ?*anyopaque) ?*anyopaque {
    g_low_ran.store(1, .seq_cst);
    while (true) {}
}

fn quick(_: ?*anyopaque) ?*anyopaque {
    return @ptrFromInt(42);
}

// ---- Part B: the stack's high-water mark ------------------------------------

const frame_bytes = 256;
const n_depths = 4;
const depths = [n_depths]u32{ 0, 4, 8, 16 };
var g_used: [n_depths]usize = @splat(0);
var g_size: [n_depths]usize = @splat(0);
var g_used_irq: usize = 0;
var g_tick_in: [n_depths]u64 = @splat(0);
var g_sink: u32 = 0;

fn dig(depth: u32) u32 {
    var buf: [frame_bytes]u8 = undefined;
    const vp: *volatile [frame_bytes]u8 = &buf;
    for (0..frame_bytes) |i| vp[i] = @truncate(depth + i);
    if (depth == 0) return vp[0];
    return @call(.never_inline, dig, .{depth - 1}) + vp[frame_bytes - 1];
}

fn usedOf(th: *rtos.Thread) usize {
    return th.stack().size() - th.stack().available();
}

fn digger(arg: ?*anyopaque) ?*anyopaque {
    const k = @intFromPtr(arg);
    // No interrupt in here: its frame would land on the thread's stack too.
    const cs = interrupts.CriticalSection.enter();
    defer cs.exit();
    g_tick_in[k] = sysclock.now();
    g_sink +%= @call(.never_inline, dig, .{depths[k]});
    const me = rtos.this_thread.thread();
    g_size[k] = me.stack().size();
    g_used[k] = usedOf(me);
    return null;
}

// Shallow, but interrupted by the tick 20 times.
fn shallow(_: ?*anyopaque) ?*anyopaque {
    g_sink +%= @call(.never_inline, dig, .{0});
    spinUs(20000);
    g_used_irq = usedOf(rtos.this_thread.thread());
    return null;
}

// ---- Part C: statistics -------------------------------------------------------

const n_pulse = 50;
const pulse_work_us: u32 = 2000;
const n_pairs = if (four) 3 else 1; // on cores 1-3

var g_hog_stop = std.atomic.Value(bool).init(false);
var g_pulse_done: rtos.Semaphore = .counting("done", n_pairs, 0);

fn pulse(_: ?*anyopaque) ?*anyopaque {
    for (0..n_pulse) |_| {
        spinUs(pulse_work_us);
        sysclock.sleepFor(2) catch {};
    }
    g_pulse_done.post() catch {};
    return null;
}

fn hog(_: ?*anyopaque) ?*anyopaque {
    while (!g_hog_stop.load(.monotonic)) {}
    return null;
}

fn usOf(cycles: u64) u64 {
    return cycles * 1000000 / hrclock.inputClockFrequencyHz();
}

// ---- Part D: kill a thread running on another core ---------------------------

var g_spins = std.atomic.Value(u32).init(0);
var g_spin_core: u32 = 99;

fn spinner(_: ?*anyopaque) ?*anyopaque {
    g_spin_core = board.cpuSlot();
    while (true) _ = g_spins.fetchAdd(1, .monotonic);
}

pub fn main() void {
    board.uart.init();
    rtos.run(osMain);
}

fn osMain() void {
    const gpa = uos.memory.allocator();
    const self = rtos.this_thread.thread();

    if (four) self.setCpuAffinity(1 << 0);
    tutor.printBanner("15 thread control");
    board.console("Lesson 15, {s}: a thread's states, suspend/resume, interrupt, kill; its stack; its statistics.\n", .{if (four) "four CPUs" else "one CPU"});
    tutor.printRegions();
    if (four) {
        board.smp.startSecondaryCores();
        const waited = board.smp.waitSecondaries(3000);
        board.console("  cores joined after {d} ms: {s}\n", .{ waited, board.smp.joinSummary() });
        _ = tutor.check(board.smp.secondariesJoined(), "cores 1-{d} joined the scheduler", .{uos.config.ncpu - 1});
    }
    const heap0 = tutor.heapBytes();

    // ---- Part A.
    board.console("\n-- part A: a worker (above_normal{s}) paused and resumed {d} times, interrupted twice, killed\n", .{ if (four) ", on core 1" else "", n_pauses });
    {
        const w = spawn(gpa, "worker", worker, 0, prio.above_normal, worker_core);
        var seen_suspended: u32 = 0;
        for (1..n_pauses + 1) |i| {
            const C = struct {
                th: *rtos.Thread,
                i: u32,
                fn f(c: @This()) bool {
                    return g_runs.load(.seq_cst) == c.i and c.th.getState() == .suspended;
                }
            };
            if (until(C{ .th = w, .i = @intCast(i) }, C.f)) seen_suspended += 1;
            w.@"resume"();
        }
        const P = struct {
            th: *rtos.Thread,
            phase: u32,
            fn f(c: @This()) bool {
                return g_phase.load(.seq_cst) == c.phase and c.th.getState() == .suspended;
            }
        };
        _ = until(P{ .th = w, .phase = 1 }, P.f);
        board.console("  the worker saw itself {s} (core {d}); it paused {d} times, each time {s} until resumed\n", .{ stateName(g_own_state), g_worker_core, g_runs.load(.seq_cst) - 1, if (seen_suspended == n_pauses) "suspended" else "NOT suspended" });
        _ = tutor.check(g_own_state == .running, "a thread sees itself running", .{});
        _ = tutor.check(seen_suspended == n_pauses and g_runs.load(.seq_cst) == n_pauses + 1, "suspended after each pause, it ran again only when resumed ({d} times)", .{n_pauses});
        if (four) _ = tutor.check(g_worker_core == 1, "the worker ran on core 1", .{});

        const st_wait = w.getState();
        _ = w.interrupt(true);
        _ = until(P{ .th = w, .phase = 2 }, P.f);
        sysclock.sleepFor(5) catch {};
        _ = w.interrupt(true);
        _ = until(P{ .th = w, .phase = 3 }, P.f);
        board.console("  waiting ({s}): interrupt() -> {s}, flag {s}, cleared {s}; sleeping 100 s: interrupt() after 5 ticks -> {s} after {d} ticks\n", .{ stateName(st_wait), resName(g_wait_res), if (g_wait_flag) "set" else "clear", if (g_wait_cleared) "yes" else "no", resName(g_sleep_res), g_slept });
        _ = tutor.check(st_wait == .suspended and g_wait_res == .eintr and g_wait_flag and g_wait_cleared, "a wait interrupted returns EINTR; the flag stays set until cleared", .{});
        _ = tutor.check(g_sleep_res == .eintr and g_sleep_flag and g_slept >= 5 and g_slept < 50, "a sleep interrupted returns EINTR at once", .{});

        const kr = resOf(w.kill());
        const st_killed = w.getState();
        g_never.post() catch {};
        const post_stays = g_never.value() == 1;
        board.console("  waiting forever: kill() -> {s}, state {s}; a post then stays (value {d}), phase {d}\n", .{ resName(kr), stateName(st_killed), g_never.value(), g_phase.load(.seq_cst) });
        _ = tutor.check(kr == .ok and st_killed == .destroyed and post_stays and g_phase.load(.seq_cst) == 3, "a waiting thread killed: destroyed, and no longer on the semaphore's list", .{});
        g_never.tryWait() catch {};
        w.destroy();

        // Ready, never run: below main on main's core.
        const lo = spawn(gpa, "low", lowBody, 0, prio.below_normal, 0);
        const st_ready = lo.getState();
        const kr_lo = resOf(lo.kill());
        board.console("  a lower thread just created: {s}; kill() -> {s}, state {s}, ran {d}\n", .{ stateName(st_ready), resName(kr_lo), stateName(lo.getState()), g_low_ran.load(.seq_cst) });
        _ = tutor.check(st_ready == .ready and kr_lo == .ok and lo.getState() == .destroyed and g_low_ran.load(.seq_cst) == 0, "a ready thread killed before it ran", .{});
        lo.destroy();

        // Returned, not yet joined.
        const q = spawn(gpa, "quick", quick, 0, prio.high, 0);
        const st_term = q.getState();
        const ret = q.join() catch null;
        const st_joined = q.getState();
        board.console("  a higher thread that returned: {s}; joined: {s}, its result {d}\n", .{ stateName(st_term), stateName(st_joined), @intFromPtr(ret) });
        // (Four CPUs: an idle core may reap it before it is looked at.)
        _ = tutor.check((st_term == .terminated or (four and st_term == .destroyed)) and st_joined == .destroyed and @intFromPtr(ret) == 42, "a returned thread is terminated until reaped; join gives its result", .{});
        q.destroy();
    }

    // ---- Part B.
    board.console("\n-- part B: the stack's high-water mark: recursion of 0, 4, 8, 16 frames of {d} B; interrupts\n", .{frame_bytes});
    {
        // A tick between a digger's creation and its critical section may
        // have left its frame on the digger's stack: run that depth again.
        var again: u32 = 0;
        for (0..n_depths) |k| {
            for (0..5) |_| {
                const t0 = sysclock.now();
                const t = spawn(gpa, "digger", digger, k, prio.high, @as(u32, @intCast(1 + k % 3)));
                _ = t.join() catch null;
                t.destroy();
                if (g_tick_in[k] == t0) break;
                again += 1;
            }
        }
        const s = spawn(gpa, "shallow", shallow, 0, prio.high, 1);
        _ = s.join() catch null;
        s.destroy();
        const per1 = (g_used[2] - g_used[1]) / 4;
        const per2 = (g_used[3] - g_used[2]) / 8;
        board.console("  of {d} B: depth 0 used {d} B (the frame the thread started from), depth 4 {d} B, 8 {d} B, 16 {d} B -> {d} and {d} B per frame; shallow but interrupted: {d} B (+{d} B); {d} run(s) again after a tick\n", .{ g_size[0], g_used[0], g_used[1], g_used[2], g_used[3], per1, per2, g_used_irq, g_used_irq -% g_used[0], again });
        board.console("  the main thread: {d} B of {d} B used\n", .{ usedOf(self), self.stack().size() });
        _ = tutor.check(g_used[0] < g_used[1] and g_used[1] < g_used[2] and g_used[2] < g_used[3] and g_used[3] < g_size[3], "the high-water mark grows with the depth, within the stack", .{});
        _ = tutor.check(per1 >= frame_bytes and per1 <= frame_bytes + 64 and per2 == per1, "each frame costs its {d} B array plus a few words, the same at every depth", .{frame_bytes});
        _ = tutor.check(g_used_irq > g_used[0] + 200, "an interrupt's frame lands on the interrupted thread's stack", .{});
    }

    // ---- Part C.
    board.console("\n-- part C: statistics: {d} pulse{s} ({d} x {d} us of work, 2-tick sleeps) above {d} hog{s}{s}\n", .{ n_pairs, if (n_pairs > 1) "s" else "", n_pulse, pulse_work_us, n_pairs, if (n_pairs > 1) "s" else "", if (four) ", one of each on cores 1, 2, 3" else "" });
    {
        var hogs: [n_pairs]*rtos.Thread = undefined;
        var pulses: [n_pairs]*rtos.Thread = undefined;
        const tot0 = rtos.scheduler.statistics.cpu_cycles;
        const t0 = hrclock.now();
        for (0..n_pairs) |i| {
            hogs[i] = spawn(gpa, "hog", hog, 0, prio.below_normal, @as(u32, @intCast(1 + i)));
            pulses[i] = spawn(gpa, "pulse", pulse, 0, prio.above_normal, @as(u32, @intCast(1 + i)));
        }
        // Not join(): a terminated thread is destroyed -- and its joiner woken --
        // by the idle thread, which the hog below keeps from running.
        for (0..n_pairs) |_| g_pulse_done.wait() catch {};
        const t1 = hrclock.now();
        const tot1 = rtos.scheduler.statistics.cpu_cycles;
        var hog_us: [n_pairs]u64 = undefined;
        for (0..n_pairs) |i| hog_us[i] = usOf(hogs[i].statistics.cpu_cycles);
        g_hog_stop.store(true, .monotonic);
        for (0..n_pairs) |i| {
            _ = hogs[i].join() catch null;
            _ = pulses[i].join() catch null;
        }

        const elapsed_us = usOf(t1 - t0);
        const total_us = usOf(tot1 -% tot0);
        const lo_us: u64 = n_pulse * pulse_work_us;
        const hi_us: u64 = lo_us + (if (tutor.onHardware()) lo_us / 10 else lo_us / 2);
        var pulses_ok = true;
        var hogs_ok = true;
        for (0..n_pairs) |i| {
            const p_us = usOf(pulses[i].statistics.cpu_cycles);
            const p_sw = pulses[i].statistics.context_switches;
            board.console("  pulse {d}: {d} us of CPU, scheduled {d} times; hog {d}: {d} us\n", .{ i, p_us, p_sw, i, hog_us[i] });
            pulses_ok = pulses_ok and p_us >= lo_us * 95 / 100 and p_us <= hi_us and p_sw >= n_pulse;
            // The hog had the rest of its core, but for the pulse's ticks.
            hogs_ok = hogs_ok and hog_us[i] + p_us >= elapsed_us * 90 / 100;
        }
        board.console("  elapsed {d} us; all threads' CPU time {d} us = {d}.{d:0>2} x elapsed\n", .{ elapsed_us, total_us, total_us / elapsed_us, total_us * 100 / elapsed_us % 100 });
        _ = tutor.check(pulses_ok, "each pulse used about {d} us of CPU and was scheduled at least {d} times", .{ lo_us, n_pulse });
        _ = tutor.check(hogs_ok, "each hog had the rest of its core", .{});
        _ = tutor.check(total_us * 100 >= elapsed_us * ncpu * 97 and total_us * 100 <= elapsed_us * ncpu * 103, "the CPU time of all threads adds up to {d} x the elapsed time", .{ncpu});
        for (0..n_pairs) |i| {
            hogs[i].destroy();
            pulses[i].destroy();
        }
    }

    if (four) {
        // ---- Part D.
        board.console("\n-- part D: kill a thread while it runs on core 2\n", .{});
        const sp = spawn(gpa, "spinner", spinner, 0, prio.normal, 2);
        const S = struct {
            fn f(_: void) bool {
                return g_spins.load(.monotonic) > 1000;
            }
        };
        _ = until({}, S.f);
        const st = sp.getState();
        const t0 = second_timer.nowUs();
        const kr = resOf(sp.kill());
        const dt = second_timer.nowUs() -% t0;
        const s1 = g_spins.load(.monotonic);
        spinUs(2000);
        const s2 = g_spins.load(.monotonic);
        board.console("  spinner on core {d}: {s}; kill() -> {s} in {d} us, state {s}; it spun {d} more times after\n", .{ g_spin_core, stateName(st), resName(kr), dt, stateName(sp.getState()), s2 -% s1 });
        _ = tutor.check(st == .running and g_spin_core == 2, "the spinner was running on core 2", .{});
        _ = tutor.check(kr == .ok and sp.getState() == .destroyed and s2 == s1, "killed while running on another core: it stopped there, at once", .{});
        sp.destroy();
    }

    _ = tutor.check(tutor.heapBytes() == heap0, "heap back to {d} B", .{heap0});
    tutor.finish(if (four) "states, suspend/resume, interrupt and kill across cores; stack high-water marks; CPU time adding up over four CPUs; a running thread killed; four CPUs" else "states, suspend/resume, interrupt and kill; stack high-water marks; CPU time adding up; one CPU");
}
