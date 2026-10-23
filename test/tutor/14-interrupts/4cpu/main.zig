//! tutor-14-interrupts-4cpu -- lesson 14, four CPUs (see ../README.md).
//!
//! Part A, two interrupt sources and one counter: a software timer of 2
//! ticks (its callback runs in the tick interrupt, 100 times) and the second
//! timer's interrupt (every 1.5 ms, 130 times) both add one to a shared
//! counter in an interrupt critical section and post their own semaphore;
//! meanwhile a thread adds 2000, also in interrupt critical sections. No
//! update may be lost, and the two waiters take every post. Only ISR-safe
//! calls in the handlers: post, try_send, raise -- never a wait.
//!
//! Part B, the interrupt latency, with and without a critical section held:
//! the second timer interrupts every 1 ms at exact due times, so each
//! handler's latency is its time minus its due time. First free; then the
//! main thread holds an interrupt critical section of 0.8 ms that covers each
//! due time by 0.3 ms: the interrupt waits for its end, about 300 us late,
//! and the thread it wakes follows at once.
//!
//! With four CPUs (the `four` switch) the interrupts run on core 0, the
//! thread that adds on core 3, the waiters on cores 1 and 2. And part C: the
//! second timer routed to cores 1, 2 and 3 in turn; while core 0 holds a
//! short interrupt critical section (0.5 ms, between two ticks), core 1's
//! interrupts keep running -- the lock masks one core only -- but a handler on
//! core 1 that takes the critical section itself, and with it the kernel
//! spinlock, waits. A long one (2.5 ms) stalls core 1 too, at its next tick:
//! every core's scheduler needs the kernel spinlock. (Core 1 runs a busy
//! thread meanwhile: idle, it would reschedule after every interrupt, and
//! stall at the first.)
//!
//! The Zig version of the C++ lesson (golden workspace,
//! test/rpi4b/tutor/14-interrupts/4cpu/main.cpp), with the same checks.

const std = @import("std");
const uos = @import("uos");
const board = @import("board");
const tutor = @import("tutor");

const rtos = uos.rtos;
const interrupts = rtos.interrupts;
const sysclock = rtos.sysclock;
const second_timer = tutor.second_timer;
const prio = rtos.priority;

pub const uos_options = board.options(4);

// The port's external-interrupt hook: the second interrupt.
pub const uos_external_irq = second_timer.onIrq;

const four = true;

fn spawn(gpa: std.mem.Allocator, name: [:0]const u8, f: *const fn (?*anyopaque) ?*anyopaque, arg: usize, p: rtos.Priority, core: ?u32) *rtos.Thread {
    var attr: rtos.Thread.Attributes = .{ .priority = p, .stack_size_bytes = 8 * 1024 };
    if (core) |c| attr.cpu_affinity = @as(u32, 1) << @intCast(c);
    return rtos.Thread.create(gpa, name, f, @ptrFromInt(arg), attr) catch {
        _ = tutor.check(false, "cannot create {s}", .{name});
        tutor.finish("");
    };
}

// Busy for `us` microseconds, on the System Timer's clock.
fn spinUs(us: u32) void {
    const t0 = second_timer.nowUs();
    while (second_timer.nowUs() -% t0 < us) {}
}

// ---- Part A: the tick and the second timer update one counter ---------------

const n_tick = 100;
const n_cntv = 130;
const cntv_period_us: u32 = 1500;
const n_thread_adds = 2000;

var g_counter: u32 = 0; // under the interrupt critical section
var g_tick_adds = std.atomic.Value(u32).init(0);
var g_cntv_adds = std.atomic.Value(u32).init(0);
var g_tick_in_handler = std.atomic.Value(u32).init(0);
var g_cntv_in_handler = std.atomic.Value(u32).init(0);
var g_tick_sem: rtos.Semaphore = .counting("tick", n_tick, 0);
var g_cntv_sem: rtos.Semaphore = .counting("cntv", n_cntv, 0);
var g_tick_taken: u32 = 0;
var g_cntv_taken: u32 = 0;
var g_waiter_core: [2]u32 = @splat(99);
var g_adder_core: u32 = 99;

fn addOne(own: *std.atomic.Value(u32), in_handler: *std.atomic.Value(u32)) void {
    if (interrupts.inHandlerMode()) _ = in_handler.fetchAdd(1, .monotonic);
    const cs = interrupts.CriticalSection.enter(); // the counter is shared with the thread and the other ISR
    defer cs.exit();
    g_counter += 1;
    _ = own.fetchAdd(1, .monotonic);
}

fn onTickTimer(_: ?*anyopaque) void { // the tick interrupt
    if (g_tick_adds.load(.monotonic) < n_tick) {
        addOne(&g_tick_adds, &g_tick_in_handler);
        g_tick_sem.post() catch {}; // ISR-safe: never blocks
    }
}

fn onCntvA(_: ?*anyopaque) void { // the second timer's interrupt
    if (g_cntv_adds.load(.monotonic) < n_cntv) {
        addOne(&g_cntv_adds, &g_cntv_in_handler);
        g_cntv_sem.post() catch {};
    }
}

fn tickWaiter(_: ?*anyopaque) ?*anyopaque {
    g_waiter_core[0] = board.cpuSlot();
    for (0..n_tick) |_| {
        g_tick_sem.wait() catch {};
        g_tick_taken += 1;
    }
    return null;
}

fn cntvWaiter(_: ?*anyopaque) ?*anyopaque {
    g_waiter_core[1] = board.cpuSlot();
    for (0..n_cntv) |_| {
        g_cntv_sem.wait() catch {};
        g_cntv_taken += 1;
    }
    return null;
}

fn threadAdds() void {
    for (0..n_thread_adds) |_| {
        {
            const cs = interrupts.CriticalSection.enter(); // on four CPUs: the kernel spinlock too
            defer cs.exit();
            g_counter += 1;
        }
        spinUs(50);
    }
}

fn adder(_: ?*anyopaque) ?*anyopaque {
    g_adder_core = board.cpuSlot();
    threadAdds();
    return null;
}

// ---- Part C: the second timer routed to each core --------------------------------

const RouteMode = enum(u8) { count, locked };

var g_route_mode = std.atomic.Value(RouteMode).init(.count);
var g_route_plain = std.atomic.Value(u32).init(0);
var g_route_locked = std.atomic.Value(u32).init(0);
var g_route_armed = std.atomic.Value(bool).init(false);
var g_route_stop = std.atomic.Value(bool).init(false);
var g_route_seen: u32 = 0;
var g_route_period_us: u32 = 500;

fn onRoute(_: ?*anyopaque) void {
    if (g_route_mode.load(.monotonic) == .count) {
        _ = g_route_plain.fetchAdd(1, .monotonic);
    } else {
        const cs = interrupts.CriticalSection.enter(); // the kernel spinlock: waits while another core holds it
        defer cs.exit();
        _ = g_route_locked.fetchAdd(1, .monotonic);
    }
}

// Arms the second timer on its own core (start() arms the calling core's
// timer), and stops it there when told. It waits busy, without a kernel
// call: an idle core reschedules after every interrupt, and rescheduling
// takes the kernel spinlock -- core 1 would stall at the first interrupt.
fn router(_: ?*anyopaque) ?*anyopaque {
    second_timer.start(g_route_period_us, onRoute, null);
    g_route_armed.store(true, .monotonic);
    while (!g_route_stop.load(.monotonic)) {}
    g_route_seen = second_timer.cpusSeen();
    second_timer.stop();
    return null;
}

const Run = struct { in: u32, after: u32 };

// Core 0's interrupt section, `hold_us` long, starting 0.3 ms after a tick,
// while the second timer interrupts core 1 every 100 us; the handler's runs
// inside it, and after it.
fn hold(gpa: std.mem.Allocator, m: RouteMode, hold_us: u32) Run {
    g_route_mode.store(m, .monotonic);
    g_route_plain.store(0, .monotonic);
    g_route_locked.store(0, .monotonic);
    const tr = spawn(gpa, "router", router, 0, prio.normal, 1);
    while (!g_route_armed.load(.monotonic)) sysclock.sleepFor(1) catch {};
    sysclock.sleepFor(3) catch {}; // returns just after a tick
    spinUs(300);
    const c = if (m == .count) &g_route_plain else &g_route_locked;
    var c0: u32 = undefined;
    var c1: u32 = undefined;
    {
        const cs = interrupts.CriticalSection.enter(); // core 0: IRQs masked, the kernel spinlock held
        defer cs.exit();
        c0 = c.load(.monotonic);
        spinUs(hold_us);
        c1 = c.load(.monotonic);
    }
    sysclock.sleepFor(3) catch {};
    const r: Run = .{ .in = c1 - c0, .after = c.load(.monotonic) - c1 };
    g_route_stop.store(true, .monotonic);
    _ = tr.join() catch null;
    tr.destroy();
    g_route_stop.store(false, .monotonic);
    g_route_armed.store(false, .monotonic);
    return r;
}

// ---- Part B: latency against exact due times ----------------------------------

const n_lat = 50;
const lat_period_us: u32 = 1000;

var g_lat_n = std.atomic.Value(u32).init(0);
var g_isr_us: [n_lat]u32 = @splat(0);
var g_thread_us: [n_lat]u32 = @splat(0);
var g_lat_sem: rtos.Semaphore = .counting("lat", n_lat, 0);
var g_lat_waiter_core: u32 = 99;

fn onCntvB(_: ?*anyopaque) void {
    const n = g_lat_n.load(.monotonic);
    if (n < n_lat) {
        g_isr_us[n] = second_timer.nowUs();
        g_lat_n.store(n + 1, .monotonic);
        g_lat_sem.post() catch {};
    }
}

fn latWaiter(_: ?*anyopaque) ?*anyopaque {
    g_lat_waiter_core = board.cpuSlot();
    for (0..n_lat) |i| {
        g_lat_sem.wait() catch {};
        g_thread_us[i] = second_timer.nowUs();
    }
    return null;
}

const Latency = struct { isr_max: i32, thread_max: u32 };

// n_lat interrupts every lat_period_us; with `held`, the main thread holds an
// interrupt critical section from 0.5 ms to 1.3 ms after each interrupt, so
// the next one (due at +1.0 ms) waits 0.3 ms for its end.
fn measure(gpa: std.mem.Allocator, held: bool, waiter_core: ?u32) Latency {
    g_lat_n.store(0, .monotonic);
    const tw = spawn(gpa, "lat", latWaiter, 0, prio.high, waiter_core);
    second_timer.start(lat_period_us, onCntvB, null);
    while (g_lat_n.load(.monotonic) < n_lat) {
        const n0 = g_lat_n.load(.monotonic);
        while (g_lat_n.load(.monotonic) == n0) {}
        if (held and g_lat_n.load(.monotonic) < n_lat) {
            spinUs(500);
            const cs = interrupts.CriticalSection.enter();
            defer cs.exit();
            spinUs(800);
        }
    }
    _ = tw.join() catch null;
    second_timer.stop();
    tw.destroy();
    // The first interrupt is the reference: its due times follow exactly.
    var r: Latency = .{ .isr_max = 0, .thread_max = 0 };
    for (1..n_lat) |i| {
        const due: i32 = @bitCast(g_isr_us[0] +% @as(u32, @intCast(i)) * lat_period_us);
        const late = @as(i32, @bitCast(g_isr_us[i])) -% due;
        r.isr_max = @max(r.isr_max, late);
        r.thread_max = @max(r.thread_max, g_thread_us[i] -% g_isr_us[i]);
    }
    return r;
}

pub fn main() void {
    board.uart.init();
    rtos.run(osMain);
}

fn osMain() void {
    const gpa = uos.memory.allocator();
    const self = rtos.this_thread.thread();

    if (four) self.setCpuAffinity(1 << 0);
    tutor.printBanner("14 interrupts");
    board.console(if (four) "Lesson 14, four CPUs: interrupt handlers, what they may call, the latency they see.\n" else "Lesson 14, one CPU: interrupt handlers, what they may call, the latency they see.\n", .{});
    tutor.printRegions();
    if (four) {
        // ---- Release cores 1-3 (as in lesson 01).
        board.smp.startSecondaryCores();
        const waited = board.smp.waitSecondaries(3000);
        board.console("  cores joined after {d} ms: {s}\n", .{ waited, board.smp.joinSummary() });
        _ = tutor.check(board.smp.secondariesJoined(), "cores 1-{d} joined the scheduler", .{uos.config.ncpu - 1});
    }
    const heap0 = tutor.heapBytes();
    const lat_bound_us: u32 = if (tutor.onHardware()) 30 else 20000;

    // ---- Part A.
    board.console(if (four) "\n-- part A: the tick (a 2-tick timer, {d} calls) and the second timer ({d} us, {d} calls) update one counter, a thread on core 3 adds {d}\n" else "\n-- part A: the tick (a 2-tick timer, {d} calls) and the second timer ({d} us, {d} calls) update one counter, the main thread adds {d}\n", .{ n_tick, cntv_period_us, n_cntv, n_thread_adds });
    {
        const t1 = spawn(gpa, "tick-waiter", tickWaiter, 0, prio.high, if (four) 1 else null);
        const t2 = spawn(gpa, "cntv-waiter", cntvWaiter, 0, prio.high, if (four) 2 else null);
        var tm = rtos.Timer.init("tick", onTickTimer, null, .periodic);
        tm.start(2) catch {};
        second_timer.start(cntv_period_us, onCntvA, null); // on core 0
        if (four) {
            const ta = spawn(gpa, "adder", adder, 0, prio.normal, 3);
            _ = ta.join() catch null;
            ta.destroy();
        } else threadAdds();
        while (g_tick_adds.load(.monotonic) < n_tick or g_cntv_adds.load(.monotonic) < n_cntv) sysclock.sleepFor(1) catch {};
        tm.stop() catch {};
        second_timer.stop();
        for ([_]*rtos.Thread{ t1, t2 }) |t| {
            _ = t.join() catch null;
            t.destroy();
        }
    }
    const expect: u32 = n_tick + n_cntv + n_thread_adds;
    board.console("  counter {d} (expected {d}: tick {d} + second timer {d} + thread {d}); in handler mode {d} and {d}; posts taken {d} and {d}\n", .{ g_counter, expect, g_tick_adds.load(.monotonic), g_cntv_adds.load(.monotonic), n_thread_adds, g_tick_in_handler.load(.monotonic), g_cntv_in_handler.load(.monotonic), g_tick_taken, g_cntv_taken });
    _ = tutor.check(g_counter == expect, "no update lost ({d})", .{expect});
    _ = tutor.check(g_tick_in_handler.load(.monotonic) == n_tick and g_cntv_in_handler.load(.monotonic) == n_cntv, "both callbacks ran in handler mode: the timer's in the tick interrupt", .{});
    _ = tutor.check(g_tick_taken == n_tick and g_cntv_taken == n_cntv, "every post from both interrupts woke its waiter", .{});
    if (four) {
        _ = tutor.check(g_adder_core == 3 and g_waiter_core[0] == 1 and g_waiter_core[1] == 2, "the interrupts on core 0, the adder on core 3, the waiters on cores 1 and 2", .{});
    }

    // ---- Part B.
    board.console("\n-- part B: the second timer every {d} us, {d} times; its latency against exact due times\n", .{ lat_period_us, n_lat });
    const free = measure(gpa, false, if (four) 2 else null);
    const held = measure(gpa, true, if (four) 2 else null);
    board.console("  free: interrupt late by at most {d} us, thread {d} us after it; a 0.8 ms interrupt section covering each due time by 0.3 ms: interrupt late by {d} us, thread {d} us after it\n", .{ free.isr_max, free.thread_max, held.isr_max, held.thread_max });
    _ = tutor.check(free.isr_max <= @as(i32, @intCast(lat_bound_us)) and free.thread_max <= lat_bound_us, "free: the interrupt on time and the thread right after it (within {d} us)", .{lat_bound_us});
    _ = tutor.check(held.isr_max >= 250 and held.isr_max <= 300 + @as(i32, @intCast(lat_bound_us)), "held: the interrupt late by the rest of the critical section (about 300 us)", .{});
    if (four) {
        _ = tutor.check(held.thread_max <= lat_bound_us and g_lat_waiter_core == 2, "held: the thread (on core 2) still right after its interrupt", .{});
    } else {
        _ = tutor.check(held.thread_max <= lat_bound_us, "held: the thread still right after its interrupt", .{});
    }

    // ---- Part C.
    if (four) {
        board.console("\n-- part C: the second timer routed to cores 1, 2, 3; core 0's interrupt section and core 1's handler\n", .{});
        var seen: [4]u32 = @splat(0);
        var counts: [4]u32 = @splat(0);
        for (1..4) |k| {
            g_route_mode.store(.count, .monotonic);
            g_route_plain.store(0, .monotonic);
            const tr = spawn(gpa, "router", router, 0, prio.normal, @intCast(k));
            while (!g_route_armed.load(.monotonic)) sysclock.sleepFor(1) catch {};
            sysclock.sleepFor(20) catch {};
            g_route_stop.store(true, .monotonic);
            _ = tr.join() catch null;
            tr.destroy();
            seen[k] = g_route_seen;
            counts[k] = g_route_plain.load(.monotonic);
            g_route_stop.store(false, .monotonic);
            g_route_armed.store(false, .monotonic);
        }
        board.console("  armed on core 1: {d} interrupts, core mask {x}; on core 2: {d}, {x}; on core 3: {d}, {x}\n", .{ counts[1], seen[1], counts[2], seen[2], counts[3], seen[3] });
        _ = tutor.check(seen[1] == 0x2 and seen[2] == 0x4 and seen[3] == 0x8 and counts[1] > 0 and counts[2] > 0 and counts[3] > 0, "the handler ran on the core that armed the timer, each in turn", .{});

        g_route_period_us = 100;
        const short_plain = hold(gpa, .count, 500);
        const long_plain = hold(gpa, .count, 2500);
        const short_locked = hold(gpa, .locked, 500);
        board.console("  core 0 in an interrupt section, core 1's handler every 100 us: plain, 0.5 ms section: {d} runs inside; plain, 2.5 ms: {d} inside (of 25); taking the section itself, 0.5 ms: {d} inside, {d} after\n", .{ short_plain.in, long_plain.in, short_locked.in, short_locked.after });
        _ = tutor.check(short_plain.in > 0, "core 0's interrupt lock does not mask core 1's interrupts", .{});
        _ = tutor.check(short_locked.in == 0 and short_locked.after > 0, "but a handler on core 1 that takes the section waits for core 0's (the kernel spinlock)", .{});
        if (tutor.onHardware()) {
            _ = tutor.check(long_plain.in < 20, "a long section stalls core 1 as well, at its next tick (its scheduler needs the kernel spinlock)", .{});
        }
    }

    _ = tutor.check(tutor.heapBytes() == heap0, "heap back to {d} B", .{heap0});
    tutor.finish(if (four) "two interrupts and a thread on another core: no update lost; latency longer by the section held; routed to each core; one core's lock does not mask another's interrupts; four CPUs" else "the tick and a second interrupt update one counter, nothing lost, every post taken; interrupt latency longer by the critical section held; one CPU");
}
