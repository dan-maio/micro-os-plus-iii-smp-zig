//! tutor-13-timers-4cpu -- lesson 13, four CPUs (see ../README.md).
//!
//! Part A, sampling driven by a periodic timer: a timer of 5 ticks calls back
//! 40 times; each callback records its tick and its time in microseconds and
//! hands the next sample id to a worker through a message queue (try_send:
//! the callback runs in the tick interrupt and must not block). The worker
//! builds the samples. 40 periods must take exactly 200 ticks, every period
//! 5; every callback runs in handler mode, and none of its sends is refused.
//!
//! Part B, one-shot and stop: a one-shot of 10 ticks calls back once, and is
//! then no longer running (stop() returns EAGAIN); one stopped before it
//! expires (stop() returns ok) never calls back; a periodic timer restarted
//! with another period keeps the new one.
//!
//! Part C, the cost: the jitter of the periodic callbacks, in microseconds of
//! the System Timer, around their 5 ms period.
//!
//! With four CPUs the callbacks run in core 0's tick interrupt and feed three
//! workers, on cores 1, 2 and 3: every id crosses a core, and the three share
//! the work.
//!
//! The Zig version of the C++ lesson (golden workspace,
//! test/rpi4b/tutor/13-timers/4cpu/main.cpp), with the same checks.

const std = @import("std");
const uos = @import("uos");
const board = @import("board");
const tutor = @import("tutor");

const rtos = uos.rtos;
const mqueue = rtos.mqueue;
const interrupts = rtos.interrupts;
const Sample = tutor.Sample;
const sysclock = rtos.sysclock;
const second_timer = tutor.second_timer;
const prio = rtos.priority;

pub const uos_options = board.options(4);

const four = true;
const seed: u32 = 2026;

fn spawn(gpa: std.mem.Allocator, name: [:0]const u8, f: *const fn (?*anyopaque) ?*anyopaque, arg: usize, p: rtos.Priority, core: ?u32) *rtos.Thread {
    var attr: rtos.Thread.Attributes = .{ .priority = p, .stack_size_bytes = 8 * 1024 };
    if (core) |c| attr.cpu_affinity = @as(u32, 1) << @intCast(c);
    return rtos.Thread.create(gpa, name, f, @ptrFromInt(arg), attr) catch {
        _ = tutor.check(false, "cannot create {s}", .{name});
        tutor.finish("");
    };
}

// The C++ lesson's names for the results.
fn nameOf(r: anyerror!void) []const u8 {
    r catch |e| return switch (e) {
        error.Again => "EAGAIN (not running)",
        else => "other",
    };
    return "ok";
}

fn isErr(r: anyerror!void, want: anyerror) bool {
    r catch |e| return e == want;
    return false;
}

// ---- Part A: a periodic timer feeds the worker(s) -----------------------------

const n_ticks = 40;
const period: rtos.clocks.Duration = 5; // ticks (1 ms each)
const n_workers = if (four) 3 else 1; // on cores 1, 2, 3

// Ids as usize, the size of a pointer (as the C++ queue requires).
var g_ids: rtos.MessageQueue = .{};
var g_ids_buf: [mqueue.storageSize(8, @sizeOf(usize))]u8 align(8) = undefined;

var g_calls = std.atomic.Value(u32).init(0);
var g_in_handler = std.atomic.Value(u32).init(0); // callbacks that ran in handler mode
var g_refused = std.atomic.Value(u32).init(0); // try_send found the queue full
var g_cb_core_mask = std.atomic.Value(u32).init(0);
var g_tick_at: [n_ticks]rtos.clocks.Timestamp = @splat(0);
var g_us_at: [n_ticks]u32 = @splat(0);

var g_items: [n_ticks]Sample = @splat(.{}); // the data segment
var g_built: tutor.SampleList = .{};
var g_built_mx: rtos.Mutex = .initWith("built", .{});
var g_got: [n_workers]u32 = @splat(0);
var g_worker_core: [n_workers]u32 = @splat(99);

fn onTick(_: ?*anyopaque) void {
    const n = g_calls.load(.monotonic);
    if (n >= n_ticks) return;
    g_tick_at[n] = sysclock.now();
    g_us_at[n] = second_timer.nowUs();
    if (interrupts.inHandlerMode()) _ = g_in_handler.fetchAdd(1, .monotonic);
    _ = g_cb_core_mask.fetchOr(@as(u32, 1) << @intCast(board.cpuSlot()), .monotonic);
    const id: usize = n;
    g_ids.trySend(std.mem.asBytes(&id), mqueue.default_priority) catch { // never block in a callback
        _ = g_refused.fetchAdd(1, .monotonic);
    };
    g_calls.store(n + 1, .monotonic);
}

const stop_id: usize = std.math.maxInt(usize);

fn worker(arg: ?*anyopaque) ?*anyopaque {
    const w = @intFromPtr(arg);
    g_worker_core[w] = board.cpuSlot();
    while (true) {
        var id: usize = 0;
        _ = g_ids.receive(std.mem.asBytes(&id)) catch 0;
        if (id == stop_id) break;
        if (id >= n_ticks) continue;
        const s = &g_items[id];
        const id32: u32 = @intCast(id);
        s.init(id32, tutor.generate(seed, id32), .data);
        g_built_mx.lock() catch {};
        g_built.push(s);
        g_built_mx.unlock() catch {};
        g_got[w] += 1;
    }
    return null;
}

// ---- Part B ------------------------------------------------------------------

var g_b_calls = std.atomic.Value(u32).init(0);
var g_b_at = std.atomic.Value(rtos.clocks.Timestamp).init(0);

fn onB(_: ?*anyopaque) void {
    g_b_at.store(sysclock.now(), .monotonic);
    _ = g_b_calls.fetchAdd(1, .monotonic);
}

pub fn main() void {
    board.uart.init();
    rtos.run(osMain);
}

fn osMain() void {
    const gpa = uos.memory.allocator();
    const self = rtos.this_thread.thread();

    if (four) self.setCpuAffinity(1 << 0);
    tutor.printBanner("13 timers");
    board.console(if (four) "Lesson 13, four CPUs: software timers, one-shot and periodic, their callbacks.\n" else "Lesson 13, one CPU: software timers, one-shot and periodic, their callbacks.\n", .{});
    tutor.printRegions();
    if (four) {
        // ---- Release cores 1-3 (as in lesson 01).
        board.smp.startSecondaryCores();
        const waited = board.smp.waitSecondaries(3000);
        board.console("  cores joined after {d} ms: {s}\n", .{ waited, board.smp.joinSummary() });
        _ = tutor.check(board.smp.secondariesJoined(), "cores 1-{d} joined the scheduler", .{uos.config.ncpu - 1});
    }
    const heap0 = tutor.heapBytes();
    const jitter_bound_us: i32 = if (tutor.onHardware()) 100 else 20000;

    g_ids.init("ids", 8, @sizeOf(usize), &g_ids_buf, .{}) catch {};

    // ---- Part A.
    board.console("\n-- part A: a periodic timer of {d} ticks, {d} callbacks, each handing a sample id to {d} worker(s)\n", .{ period, n_ticks, n_workers });
    {
        var tw: [n_workers]*rtos.Thread = undefined;
        for (&tw, 0..) |*t, w| t.* = spawn(gpa, "worker", worker, w, prio.normal, if (four) @as(u32, @intCast(w + 1)) else null);
        var tm = rtos.Timer.init("sampler", onTick, null, .periodic);
        const t0 = sysclock.now();
        tm.start(period) catch {};
        while (g_calls.load(.monotonic) < n_ticks) sysclock.sleepFor(period) catch {};
        tm.stop() catch {};
        for (0..n_workers) |_| g_ids.send(std.mem.asBytes(&stop_id), mqueue.default_priority) catch {};
        for (tw) |t| {
            _ = t.join() catch null;
            t.destroy();
        }
        var exact = true;
        for (1..n_ticks) |i| if (g_tick_at[i] - g_tick_at[i - 1] != period) {
            exact = false;
        };
        const total = g_tick_at[n_ticks - 1] - t0;
        board.console("  {d} callbacks, first at tick +{d}, last at +{d} ({d} periods of {d}); in handler mode {d}; refused sends {d}; callbacks on core mask {x}\n", .{ g_calls.load(.monotonic), g_tick_at[0] - t0, total, n_ticks, period, g_in_handler.load(.monotonic), g_refused.load(.monotonic), g_cb_core_mask.load(.monotonic) });
        _ = tutor.check(g_calls.load(.monotonic) == n_ticks and exact and total == n_ticks * period, "{d} callbacks, every one {d} ticks after the last, {d} ticks in all", .{ n_ticks, period, n_ticks * period });
        _ = tutor.check(g_in_handler.load(.monotonic) == n_ticks and g_refused.load(.monotonic) == 0, "every callback ran in the tick interrupt (handler mode) and never had to wait", .{});

        const n_built = g_built.count();
        tutor.sortList(&g_built);
        const e = tutor.reference(seed, 0, n_ticks);
        if (four) {
            board.console("  the workers built {d} samples: {d} on core {d}, {d} on core {d}, {d} on core {d}\n", .{ n_built, g_got[0], g_worker_core[0], g_got[1], g_worker_core[1], g_got[2], g_worker_core[2] });
            _ = tutor.check(g_cb_core_mask.load(.monotonic) == 1 and g_worker_core[0] == 1 and g_worker_core[1] == 2 and g_worker_core[2] == 3 and g_got[0] > 0 and g_got[1] > 0 and g_got[2] > 0, "the callbacks on core 0 fed the workers on cores 1, 2 and 3, each of them", .{});
        } else {
            board.console("  the worker built {d} samples\n", .{n_built});
        }
        _ = tutor.check(n_built == n_ticks and tutor.checksum(g_built) == e.sorted_checksum, "every sample built once; the sorted checksum equals the reference ({x:0>8})", .{e.sorted_checksum});

        // ---- Part C (the same run): the jitter, in microseconds.
        var dmin: i32 = 1 << 30;
        var dmax: i32 = -(1 << 30);
        for (1..n_ticks) |i| {
            const d: i32 = @as(i32, @bitCast(g_us_at[i] -% g_us_at[i - 1])) - 5000;
            dmin = @min(dmin, d);
            dmax = @max(dmax, d);
        }
        board.console("\n-- part C: the callbacks' period in microseconds: 5000 {d} .. {d} us\n", .{ dmin, dmax });
        _ = tutor.check(dmax <= jitter_bound_us and -dmin <= jitter_bound_us, "the period within {d} us of 5 ms", .{jitter_bound_us});
    }

    // ---- Part B.
    board.console("\n-- part B: one-shot, stop, restart\n", .{});
    {
        var once = rtos.Timer.init("once", onB, null, .once);
        g_b_calls.store(0, .monotonic);
        const t0 = sysclock.now();
        once.start(10) catch {};
        sysclock.sleepFor(20) catch {};
        const c1 = g_b_calls.load(.monotonic);
        const after = g_b_at.load(.monotonic) - t0;
        const s1 = once.stop(); // completed: no longer running
        board.console("  one-shot of 10 ticks: {d} callback, {d} ticks after start; then stop () {s}\n", .{ c1, after, nameOf(s1) });
        _ = tutor.check(c1 == 1 and after == 10 and isErr(s1, error.Again), "a one-shot calls back once, at its time, and completes", .{});

        g_b_calls.store(0, .monotonic);
        once.start(10) catch {};
        sysclock.sleepFor(3) catch {};
        const s2 = once.stop(); // still running: stopped now
        sysclock.sleepFor(20) catch {};
        board.console("  started, stopped after 3 ticks (stop () {s}): {d} callbacks\n", .{ nameOf(s2), g_b_calls.load(.monotonic) });
        _ = tutor.check(g_b_calls.load(.monotonic) == 0 and !std.meta.isError(s2), "a timer stopped before its time never calls back", .{});

        var per = rtos.Timer.init("per", onB, null, .periodic);
        g_b_calls.store(0, .monotonic);
        per.start(4) catch {};
        sysclock.sleepFor(14) catch {}; // 3 callbacks at 4, 8, 12
        const c4 = g_b_calls.load(.monotonic);
        per.stop() catch {};
        g_b_calls.store(0, .monotonic);
        per.start(7) catch {};
        sysclock.sleepFor(22) catch {}; // 3 callbacks at 7, 14, 21
        per.stop() catch {};
        board.console("  periodic of 4 ticks for 14: {d} callbacks; restarted with 7 for 22: {d}\n", .{ c4, g_b_calls.load(.monotonic) });
        _ = tutor.check(c4 == 3 and g_b_calls.load(.monotonic) == 3, "a periodic timer restarted with another period keeps the new one", .{});
    }

    _ = tutor.check(tutor.heapBytes() == heap0, "heap back to {d} B", .{heap0});
    tutor.finish(if (four) "a periodic timer, exact to the tick, its callbacks on core 0 feeding workers on cores 1-3; one-shot, stop, restart; four CPUs" else "a periodic timer, exact to the tick, feeding the worker from its callback; one-shot, stop, restart; one CPU");
}
