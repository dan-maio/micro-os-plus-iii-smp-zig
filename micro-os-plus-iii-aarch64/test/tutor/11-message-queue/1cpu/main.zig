//! tutor-11-message-queue-1cpu -- lesson 11, one CPU (see ../README.md).
//!
//! Part A, a three-stage pipeline: `source` sends the sample ids 0 .. 199 to
//! q1, every 20th one urgent (priority 1); `filter` computes each value and
//! sends {id, value} on to q2 with the same priority; `sink`, the slowest,
//! takes them and builds the list. Every id must arrive exactly once, the
//! normal ids in order and the urgent ids in order, and the urgent ones must
//! overtake normal ones that were sent before them.
//!
//! Part B, the semantics: with no receiver, seven messages of priorities 0,
//! 10 and 5 come out highest priority first and in order within one priority;
//! try_send to a full queue and try_receive from an empty one return
//! EWOULDBLOCK; timed_send and timed_receive return ETIMEDOUT after their
//! timeout.
//!
//! Part C, from an interrupt: the second timer's ISR sends 20 messages with
//! try_send, every 2 ms; a waiter receives every one, each within a bound.
//!
//! The Zig version of the C++ lesson (golden workspace,
//! test/rpi4b/tutor/11-message-queue/1cpu/main.cpp), with the same checks.

const std = @import("std");
const uos = @import("uos");
const board = @import("board");
const tutor = @import("tutor");

const rtos = uos.rtos;
const mqueue = rtos.mqueue;
const Sample = tutor.Sample;
const sysclock = rtos.sysclock;
const second_timer = tutor.second_timer;
const prio = rtos.priority;

pub const uos_options = board.options(1);

// The port's external-interrupt hook: the second interrupt.
pub const uos_external_irq = second_timer.onIrq;

const four = false;
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
        error.WouldBlock => "EWOULDBLOCK",
        error.TimedOut => "ETIMEDOUT",
        else => "other",
    };
    return "ok";
}

fn isErr(r: anyerror!void, want: anyerror) bool {
    r catch |e| return e == want;
    return false;
}

fn voidOf(r: anyerror!mqueue.Priority) anyerror!void {
    _ = try r;
}

// Busy for `us` microseconds, on the System Timer's clock.
fn spinUs(us: u32) void {
    const t0 = second_timer.nowUs();
    while (second_timer.nowUs() -% t0 < us) {}
}

// ---- Part A: source -> q1 -> filter -> q2 -> sink --------------------------

const n_ids = 200;
const urgent_every = 20;
const prio_urgent: mqueue.Priority = 1;

const Msg = extern struct {
    id: u32,
    value: i32,
};

// The storage is static (no heap): a buffer per queue, given to init().
var g_q1: rtos.MessageQueue = .{};
var g_q2: rtos.MessageQueue = .{};
var g_q1_buf: [mqueue.storageSize(4, @sizeOf(Msg))]u8 align(8) = undefined;
var g_q2_buf: [mqueue.storageSize(8, @sizeOf(Msg))]u8 align(8) = undefined;

var g_items: [n_ids]Sample = @splat(.{}); // the data segment
var g_received: tutor.SampleList = .{};
var g_order: [n_ids]u32 = @splat(0); // the ids, in the order the sink took them
var g_n_received: u32 = 0;
var g_core_of: [3]u32 = @splat(99);

fn isUrgent(id: u32) bool {
    return (id % urgent_every) == urgent_every - 1;
}

fn source(_: ?*anyopaque) ?*anyopaque {
    g_core_of[0] = board.cpuSlot();
    var id: u32 = 0;
    while (id < n_ids) : (id += 1) {
        const m: Msg = .{ .id = id, .value = 0 };
        g_q1.send(std.mem.asBytes(&m), if (isUrgent(id)) prio_urgent else mqueue.default_priority) catch {};
    }
    return null;
}

fn filter(_: ?*anyopaque) ?*anyopaque {
    g_core_of[1] = board.cpuSlot();
    for (0..n_ids) |_| {
        var m: Msg = undefined;
        const p = g_q1.receive(std.mem.asBytes(&m)) catch 0;
        m.value = tutor.generate(seed, m.id);
        g_q2.send(std.mem.asBytes(&m), p) catch {}; // the priority travels with the message
    }
    return null;
}

fn sink(_: ?*anyopaque) ?*anyopaque {
    g_core_of[2] = board.cpuSlot();
    for (0..n_ids) |_| {
        var m: Msg = undefined;
        _ = g_q2.receive(std.mem.asBytes(&m)) catch 0;
        spinUs(200); // the slowest stage: the queues fill behind it
        if (m.id < n_ids and g_n_received < n_ids) {
            g_order[g_n_received] = m.id;
            g_n_received += 1;
            const s = &g_items[m.id];
            s.init(m.id, m.value, .data);
            g_received.push(s);
        }
    }
    return null;
}

// ---- Part C: messages sent from an interrupt ---------------------------------

const n_irq = 20;
const irq_period_us: u32 = 2000;

var g_qi: rtos.MessageQueue = .{};
var g_qi_buf: [mqueue.storageSize(4, @sizeOf(Msg))]u8 align(8) = undefined;
var g_irq_sent = std.atomic.Value(u32).init(0);
var g_irq_full = std.atomic.Value(u32).init(0); // try_send refused (queue full)
var g_irq_us = std.atomic.Value(u32).init(0);
var g_irq_taken: u32 = 0;
var g_irq_in_order: u32 = 0;
var g_irq_lat_max: u32 = 0;
var g_irq_waiter_core: u32 = 99;

fn onIrq(_: ?*anyopaque) void {
    const sent = g_irq_sent.load(.monotonic);
    if (sent < n_irq) {
        const m: Msg = .{ .id = sent, .value = 0 };
        g_irq_us.store(second_timer.nowUs(), .monotonic);
        if (g_qi.trySend(std.mem.asBytes(&m), mqueue.default_priority)) |_| { // never blocks: allowed in an ISR
            _ = g_irq_sent.fetchAdd(1, .monotonic);
        } else |_| {
            _ = g_irq_full.fetchAdd(1, .monotonic);
        }
    }
}

fn irqWaiter(_: ?*anyopaque) ?*anyopaque {
    g_irq_waiter_core = board.cpuSlot();
    for (0..n_irq) |i| {
        var m: Msg = undefined;
        _ = g_qi.receive(std.mem.asBytes(&m)) catch 0;
        const lat = second_timer.nowUs() -% g_irq_us.load(.monotonic);
        g_irq_lat_max = @max(g_irq_lat_max, lat);
        if (m.id == i) g_irq_in_order += 1;
        g_irq_taken += 1;
    }
    return null;
}

pub fn main() void {
    board.uart.init();
    rtos.run(osMain);
}

fn osMain() void {
    const gpa = uos.memory.allocator();
    const self = rtos.this_thread.thread();

    if (four) self.setCpuAffinity(1 << 0);
    tutor.printBanner("11 message queue");
    board.console(if (four) "Lesson 11, four CPUs: message queues, priorities, timed send and receive, a send from an ISR.\n" else "Lesson 11, one CPU: message queues, priorities, timed send and receive, a send from an ISR.\n", .{});
    tutor.printRegions();
    if (four) {
        // ---- Release cores 1-3 (as in lesson 01).
        board.smp.startSecondaryCores();
        const waited = board.smp.waitSecondaries(3000);
        board.console("  cores joined after {d} ms: {s}\n", .{ waited, board.smp.joinSummary() });
        _ = tutor.check(board.smp.secondariesJoined(), "cores 1-{d} joined the scheduler", .{uos.config.ncpu - 1});
    }
    const heap0 = tutor.heapBytes();
    const lat_bound_us: u32 = if (tutor.onHardware()) 1000 else 20000;

    g_q1.init("q1", 4, @sizeOf(Msg), &g_q1_buf, .{}) catch {};
    g_q2.init("q2", 8, @sizeOf(Msg), &g_q2_buf, .{}) catch {};
    g_qi.init("irq", 4, @sizeOf(Msg), &g_qi_buf, .{}) catch {};

    // ---- Part A.
    if (four) {
        board.console("\n-- part A: source (core 1) -> q1 (4) -> filter (core 2) -> q2 (8) -> sink (core 3), {d} ids, every {d}th urgent\n", .{ n_ids, urgent_every });
    } else {
        board.console("\n-- part A: source -> q1 (4) -> filter -> q2 (8) -> sink, {d} ids, every {d}th urgent\n", .{ n_ids, urgent_every });
    }
    {
        const ts = spawn(gpa, "source", source, 0, prio.above_normal, if (four) 1 else null);
        const tf = spawn(gpa, "filter", filter, 0, prio.normal, if (four) 2 else null);
        const tk = spawn(gpa, "sink", sink, 0, prio.below_normal, if (four) 3 else null);
        for ([_]*rtos.Thread{ ts, tf, tk }) |t| {
            _ = t.join() catch null;
            t.destroy();
        }
    }
    var once = g_n_received == n_ids;
    var seen: [n_ids]bool = @splat(false);
    for (g_order[0..g_n_received]) |id| {
        if (seen[id]) once = false;
        seen[id] = true;
    }
    var normal_ordered = true;
    var urgent_ordered = true;
    var last_normal: i64 = -1;
    var last_urgent: i64 = -1;
    var overtakes: u32 = 0; // urgent ids taken before a smaller normal id
    for (g_order[0..g_n_received]) |id| {
        if (isUrgent(id)) {
            if (@as(i64, id) <= last_urgent) urgent_ordered = false;
            last_urgent = id;
            if (@as(i64, id) > last_normal + 1) overtakes += 1; // some normal id below it had not been taken yet
        } else {
            if (@as(i64, id) <= last_normal) normal_ordered = false;
            last_normal = id;
        }
    }
    tutor.sortList(&g_received);
    const e = tutor.reference(seed, 0, n_ids);
    board.console("  received {d}; urgent ids taken ahead of waiting normal ones: {d} of {d}; first ids taken: {d} {d} {d} {d} {d} {d} {d} {d}\n", .{ g_n_received, overtakes, n_ids / urgent_every, g_order[0], g_order[1], g_order[2], g_order[3], g_order[4], g_order[5], g_order[6], g_order[7] });
    _ = tutor.check(once, "every id arrived exactly once ({d})", .{n_ids});
    _ = tutor.check(normal_ordered and urgent_ordered, "normal ids in order, urgent ids in order (FIFO within a priority)", .{});
    _ = tutor.check(overtakes >= 1, "urgent messages overtook normal ones sent before them", .{});
    if (four) {
        _ = tutor.check(g_core_of[0] == 1 and g_core_of[1] == 2 and g_core_of[2] == 3, "one stage per core: source 1, filter 2, sink 3", .{});
    }
    _ = tutor.check(tutor.checksum(g_received) == e.sorted_checksum, "the values' sorted checksum equals the reference ({x:0>8})", .{e.sorted_checksum});

    // ---- Part B.
    board.console("\n-- part B: priorities with no receiver; full, empty, timeouts\n", .{});
    {
        var q: rtos.MessageQueue = .{};
        var q_buf: [mqueue.storageSize(8, @sizeOf(Msg))]u8 align(8) = undefined;
        q.init("b", 8, @sizeOf(Msg), &q_buf, .{}) catch {};
        const Sent = struct { id: u32, p: mqueue.Priority };
        const sent = [_]Sent{ .{ .id = 1, .p = 0 }, .{ .id = 2, .p = 0 }, .{ .id = 3, .p = 0 }, .{ .id = 100, .p = 10 }, .{ .id = 4, .p = 0 }, .{ .id = 101, .p = 10 }, .{ .id = 50, .p = 5 } };
        for (sent) |s| {
            const m: Msg = .{ .id = s.id, .value = 0 };
            q.send(std.mem.asBytes(&m), s.p) catch {};
        }
        const n_queued = q.length();
        const want = [_]u32{ 100, 101, 50, 1, 2, 3, 4 };
        var by_prio = true;
        var got_ids: [7]u32 = @splat(0);
        for (&got_ids, 0..) |*g, i| {
            var m: Msg = .{ .id = 0, .value = 0 };
            _ = q.receive(std.mem.asBytes(&m)) catch 0;
            g.* = m.id;
            if (m.id != want[i]) by_prio = false;
        }
        board.console("  sent 1 2 3 (p0) 100 (p10) 4 (p0) 101 (p10) 50 (p5); {d} queued; received {d} {d} {d} {d} {d} {d} {d}\n", .{ n_queued, got_ids[0], got_ids[1], got_ids[2], got_ids[3], got_ids[4], got_ids[5], got_ids[6] });
        _ = tutor.check(n_queued == 7 and by_prio, "highest priority first, FIFO within one priority", .{});

        var m: Msg = .{ .id = 0, .value = 0 };
        const r_empty = voidOf(q.tryReceive(std.mem.asBytes(&m)));
        var t0 = sysclock.now();
        const r_tr = voidOf(q.timedReceive(std.mem.asBytes(&m), 10));
        const w_tr = sysclock.now() - t0;
        for (0..q.capacity()) |_| q.send(std.mem.asBytes(&m), mqueue.default_priority) catch {};
        const r_full = q.trySend(std.mem.asBytes(&m), mqueue.default_priority);
        t0 = sysclock.now();
        const r_ts = q.timedSend(std.mem.asBytes(&m), 10, mqueue.default_priority);
        const w_ts = sysclock.now() - t0;
        board.console("  empty: try_receive {s}, timed_receive(10) {s} after {d} ticks; full ({d} of {d}): try_send {s}, timed_send(10) {s} after {d} ticks\n", .{ nameOf(r_empty), nameOf(r_tr), w_tr, q.length(), q.capacity(), nameOf(r_full), nameOf(r_ts), w_ts });
        _ = tutor.check(isErr(r_empty, error.WouldBlock) and isErr(r_full, error.WouldBlock), "try_receive on empty and try_send on full: EWOULDBLOCK", .{});
        _ = tutor.check(isErr(r_tr, error.TimedOut) and w_tr >= 10 and w_tr <= 11 and isErr(r_ts, error.TimedOut) and w_ts >= 10 and w_ts <= 11, "timed_receive and timed_send: ETIMEDOUT after 10 ticks", .{});
    }

    // ---- Part C.
    board.console(if (four) "\n-- part C: the second timer's ISR sends {d} messages with try_send, every {d} us, ISR on core 0, waiter on core 2\n" else "\n-- part C: the second timer's ISR sends {d} messages with try_send, every {d} us\n", .{ n_irq, irq_period_us });
    {
        const tw = spawn(gpa, "waiter", irqWaiter, 0, prio.high, if (four) 2 else null);
        second_timer.start(irq_period_us, onIrq, null); // on this core, core 0
        _ = tw.join() catch null;
        second_timer.stop();
        tw.destroy();
    }
    board.console("  sent {d} (refused {d}), taken {d}, in order {d}; ISR on core mask {x}, waiter on core {d}; ISR -> waiter max {d} us\n", .{ g_irq_sent.load(.monotonic), g_irq_full.load(.monotonic), g_irq_taken, g_irq_in_order, second_timer.cpusSeen(), g_irq_waiter_core, g_irq_lat_max });
    _ = tutor.check(g_irq_taken == n_irq and g_irq_sent.load(.monotonic) == n_irq and g_irq_in_order == n_irq, "every message sent by the ISR taken, in order ({d})", .{n_irq});
    _ = tutor.check(g_irq_lat_max <= lat_bound_us, "each within {d} us of its interrupt", .{lat_bound_us});
    if (four) {
        _ = tutor.check(second_timer.cpusSeen() == 1 and g_irq_waiter_core == 2, "the ISR on core 0, the waiter woken on core 2 (cross-core)", .{});
    }

    _ = tutor.check(tutor.heapBytes() == heap0, "heap back to {d} B", .{heap0});
    tutor.finish(if (four) "3-stage pipeline, one stage per core: every id once, in order per priority, urgent ones overtake; priorities, timeouts; ISR messages taken across cores; four CPUs" else "3-stage pipeline: every id once, in order per priority, urgent ones overtake; priorities, timeouts; ISR messages taken; one CPU");
}
