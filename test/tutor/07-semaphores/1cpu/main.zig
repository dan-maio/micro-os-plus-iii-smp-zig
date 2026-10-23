//! tutor-07-semaphores-1cpu -- lesson 07, one CPU (see ../README.md).
//!
//! Part A, the pipeline: a producer passes 400 samples (ids 0 .. 399) to a consumer through a bounded buffer of 8 slots --
//! the classic pair of counting semaphores, `slots` (free, starting at 8) and
//! `items` (filled, starting at 0), and a binary semaphore guarding the ring's
//! indices. Every sample must arrive, in order, and never more than 8 be in
//! flight.
//!
//! Part B, the semantics: a counting semaphore (max 3) takes 3 posts and
//! refuses the 4th (EAGAIN); 3 try_waits succeed, the 4th returns
//! EWOULDBLOCK; timed_wait(10) returns ETIMEDOUT after 10 ticks; a binary
//! semaphore refuses a second post before a wait.
//!
//! Part C, from an interrupt: the second timer's ISR posts a counting
//! semaphore 50 times, every 2 ms; a waiter takes every post, each within a
//! bound of its interrupt. A semaphore may be posted from an ISR, a mutex not.
//!
//! With one CPU the producer runs above the consumer: it fills the buffer
//! until all 8 slots are taken and then must wait -- back-pressure -- so the
//! number in flight reaches exactly 8.
//!  
//!
//! The Zig version of the C++ lesson (golden workspace,
//! test/rpi4b/tutor/07-semaphores/1cpu/main.cpp), with the same checks.

const std = @import("std");
const uos = @import("uos");
const board = @import("board");
const tutor = @import("tutor");

const rtos = uos.rtos;
const Sample = tutor.Sample;
const sysclock = rtos.sysclock;
const second_timer = tutor.second_timer;
const prio = rtos.priority;

pub const uos_options = board.options(1);

// The port's external-interrupt hook: the second interrupt.
pub const uos_external_irq = second_timer.onIrq;

const four = false;
const seed: u32 = 2026;

// ---- Part A: producer -> bounded buffer -> consumer --------------------------

const n_items = 400;
const n_slots = 8; // the bounded buffer

var g_items: [n_items]Sample = @splat(.{}); // the data segment

// The ring: n_slots pointers, written by the producer, read by the consumer.
var g_ring: [n_slots]*Sample = undefined;
var g_head: usize = 0; // next slot to fill
var g_tail: usize = 0; // next slot to empty

var g_slots: rtos.Semaphore = .counting("slots", n_slots, n_slots); // free slots
var g_full: rtos.Semaphore = .counting("items", n_slots, 0); // filled slots
var g_ring_lock: rtos.Semaphore = .binary("ring", 1); // the indices

var g_in_flight = std.atomic.Value(i32).init(0); // produced, not yet consumed
var g_max_in_flight: i32 = 0;
var g_producer_blocked: u32 = 0; // times the buffer was full
var g_out_of_order: u32 = 0;
var g_consumed: tutor.SampleList = .{};

fn producer(_: ?*anyopaque) ?*anyopaque {
    for (&g_items, 0..) |*s, i| {
        const id: u32 = @intCast(i);
        s.init(id, tutor.generate(seed, id), .data);
        // A free slot: at once if there is one, otherwise wait for the
        // consumer to make one (back-pressure).
        g_slots.tryWait() catch {
            g_producer_blocked += 1;
            g_slots.wait() catch {};
        };
        g_ring_lock.wait() catch {};
        g_ring[g_head] = s;
        g_head = (g_head + 1) % n_slots;
        const n = g_in_flight.fetchAdd(1, .monotonic) + 1;
        if (n > g_max_in_flight) g_max_in_flight = n;
        g_ring_lock.post() catch {};
        g_full.post() catch {};
    }
    return null;
}

fn consumer(_: ?*anyopaque) ?*anyopaque {
    for (0..n_items) |i| {
        g_full.wait() catch {};
        g_ring_lock.wait() catch {};
        const s = g_ring[g_tail];
        g_tail = (g_tail + 1) % n_slots;
        _ = g_in_flight.fetchSub(1, .monotonic);
        g_ring_lock.post() catch {};
        g_slots.post() catch {};
        if (s.id != i or !s.valid()) g_out_of_order += 1;
        g_consumed.push(s);
    }
    return null;
}

// ---- Part C: posted from an interrupt -------------------------------------------

const n_irq = 50;
const irq_period_us: u32 = 2000;

var g_irq_sem: rtos.Semaphore = .counting("irq", n_irq, 0);
var g_irq_posted = std.atomic.Value(u32).init(0);
var g_irq_us = std.atomic.Value(u32).init(0);
var g_irq_taken: u32 = 0;
var g_irq_lat_max: u32 = 0;
var g_waiter_core: u32 = 99;

fn onIrq(_: ?*anyopaque) void {
    if (g_irq_posted.load(.monotonic) < n_irq) {
        g_irq_us.store(second_timer.nowUs(), .monotonic);
        _ = g_irq_posted.fetchAdd(1, .monotonic);
        g_irq_sem.post() catch {}; // a semaphore may be posted from an ISR (a mutex may not)
    }
}

fn irqWaiter(_: ?*anyopaque) ?*anyopaque {
    g_waiter_core = board.cpuSlot();
    for (0..n_irq) |_| {
        g_irq_sem.wait() catch {};
        const lat = second_timer.nowUs() -% g_irq_us.load(.monotonic);
        g_irq_lat_max = @max(g_irq_lat_max, lat);
        g_irq_taken += 1;
    }
    return null;
}

fn spawn(gpa: std.mem.Allocator, name: [:0]const u8, f: *const fn (?*anyopaque) ?*anyopaque, p: rtos.Priority, core: ?u32) *rtos.Thread {
    var attr: rtos.Thread.Attributes = .{ .priority = p, .stack_size_bytes = 8 * 1024 };
    if (core) |c| attr.cpu_affinity = @as(u32, 1) << @intCast(c);
    return rtos.Thread.create(gpa, name, f, null, attr) catch {
        _ = tutor.check(false, "cannot create {s}", .{name});
        tutor.finish("");
    };
}

// The C++ lesson's names for the results.
fn nameOf(r: rtos.Error!void) []const u8 {
    r catch |e| return switch (e) {
        error.Again => "EAGAIN",
        error.WouldBlock => "EWOULDBLOCK",
        error.TimedOut => "ETIMEDOUT",
        else => "other",
    };
    return "ok";
}

fn isErr(r: rtos.Error!void, want: rtos.Error) bool {
    r catch |e| return e == want;
    return false;
}

pub fn main() void {
    board.uart.init();
    rtos.run(osMain);
}

fn osMain() void {
    const gpa = uos.memory.allocator();
    const self = rtos.this_thread.thread();

    if (four) self.setCpuAffinity(1 << 0);
    tutor.printBanner("07 semaphores");
    board.console(if (four) "Lesson 07, four CPUs: binary and counting semaphores, a bounded buffer, a post from an ISR.\n" else "Lesson 07, one CPU: binary and counting semaphores, a bounded buffer, a post from an ISR.\n", .{});
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

    // ---- Part A.
    board.console(if (four) "\n-- part A: a producer passes {d} samples to a consumer through {d} slots, producer on core 1, consumer on core 2\n" else "\n-- part A: a producer passes {d} samples to a consumer through {d} slots\n", .{ n_items, n_slots });
    {
        const tp = spawn(gpa, "producer", producer, prio.above_normal, if (four) 1 else null);
        const tc = spawn(gpa, "consumer", consumer, prio.normal, if (four) 2 else null);
        for ([_]*rtos.Thread{ tp, tc }) |t| {
            _ = t.join() catch null;
            t.destroy();
        }
    }
    const n_consumed = g_consumed.count();
    tutor.sortList(&g_consumed);
    const e = tutor.reference(seed, 0, n_items);
    board.console("  consumed {d}, out of order {d}; at most {d} in flight; the producer found the buffer full {d} times\n", .{ n_consumed, g_out_of_order, g_max_in_flight, g_producer_blocked });
    _ = tutor.check(n_consumed == n_items and g_out_of_order == 0, "every sample consumed, in order ({d})", .{n_items});
    _ = tutor.check(tutor.checksum(g_consumed) == e.sorted_checksum, "the consumed samples' sorted checksum equals the reference ({x:0>8})", .{e.sorted_checksum});
    if (four) {
        _ = tutor.check(g_max_in_flight >= 1 and g_max_in_flight <= n_slots, "never more than {d} in flight", .{n_slots});
    } else {
        _ = tutor.check(g_max_in_flight == n_slots and g_producer_blocked > 0, "back-pressure: the buffer filled to its {d} slots and the producer waited", .{n_slots});
    }

    // ---- Part B: the semantics.
    board.console("\n-- part B: counting (max 3) and binary semaphores\n", .{});
    {
        var sc: rtos.Semaphore = .counting("count3", 3, 0);
        var posts_ok = true;
        for (0..3) |_| sc.post() catch {
            posts_ok = false;
        };
        const r4 = sc.post();
        const v = sc.value();
        var waits_ok = true;
        for (0..3) |_| sc.tryWait() catch {
            waits_ok = false;
        };
        const w4 = sc.tryWait();
        const t0 = sysclock.now();
        const tw = sc.timedWait(10);
        const waited = sysclock.now() - t0;
        board.console("  counting: 3 posts {s}, a 4th {s}, value {d}; 3 try_waits {s}, a 4th {s}; timed_wait(10) {s} after {d} ticks\n", .{
            if (posts_ok) "ok" else "BAD", nameOf(r4), v, if (waits_ok) "ok" else "BAD", nameOf(w4), nameOf(tw), waited,
        });
        _ = tutor.check(posts_ok and isErr(r4, error.Again) and v == 3, "counting: up to its maximum, then EAGAIN", .{});
        _ = tutor.check(waits_ok and isErr(w4, error.WouldBlock), "counting: 3 taken, then try_wait EWOULDBLOCK", .{});
        _ = tutor.check(isErr(tw, error.TimedOut) and waited >= 10 and waited <= 11, "timed_wait(10): ETIMEDOUT after 10 ticks", .{});

        var sb: rtos.Semaphore = .binary("binary", 0);
        const b1 = sb.post();
        const b2 = sb.post();
        board.console("  binary: post {s}, post again {s} (it is a flag: one pending at most)\n", .{ nameOf(b1), nameOf(b2) });
        _ = tutor.check(!std.meta.isError(b1) and isErr(b2, error.Again), "binary: a second post before a wait is refused (EAGAIN)", .{});
    }

    // ---- Part C: from an interrupt.
    board.console(if (four) "\n-- part C: the second timer's ISR posts {d} times, every {d} us, ISR on core 0, waiter on core 2\n" else "\n-- part C: the second timer's ISR posts {d} times, every {d} us\n", .{ n_irq, irq_period_us });
    {
        const tw = spawn(gpa, "waiter", irqWaiter, prio.high, if (four) 2 else null);
        second_timer.start(irq_period_us, onIrq, null); // on this core, core 0
        _ = tw.join() catch null;
        second_timer.stop();
        tw.destroy();
    }
    board.console("  posted {d}, taken {d}; ISR on core mask {x}, waiter on core {d}; ISR -> waiter max {d} us\n", .{
        g_irq_posted.load(.monotonic), g_irq_taken, second_timer.cpusSeen(), g_waiter_core, g_irq_lat_max,
    });
    _ = tutor.check(g_irq_taken == n_irq and g_irq_posted.load(.monotonic) == n_irq, "every post from the ISR taken ({d})", .{n_irq});
    _ = tutor.check(g_irq_lat_max <= lat_bound_us, "each within {d} us of its interrupt", .{lat_bound_us});
    if (four) {
        _ = tutor.check(second_timer.cpusSeen() == 1 and g_waiter_core == 2, "the ISR on core 0, the waiter woken on core 2 (cross-core)", .{});
    } else {
        _ = tutor.check(second_timer.cpusSeen() == 1, "the ISR ran on core 0", .{});
    }

    _ = tutor.check(tutor.heapBytes() == heap0, "heap back to {d} B", .{heap0});
    tutor.finish(if (four) "400 samples through 8 slots across cores in order, semaphore semantics, every ISR post taken across cores; four CPUs" else "400 samples through 8 slots in order, semaphore semantics, every ISR post taken; one CPU");
}
