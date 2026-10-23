//! tutor-09-condvar-1cpu -- lesson 09, one CPU (see ../README.md).
//!
//! Part A, the pipeline again: lesson 07's producer passes 400 samples to a
//! consumer through 8 slots, this time with one mutex around the ring and
//! two condition variables, `not_full` and `not_empty`, each waited on in a
//! loop over its predicate. Every sample must arrive, in order, and never
//! more than 8 be in flight.
//!
//! Part B, signal and broadcast: three waiters wait for a token. signal()
//! with one token wakes one of them; broadcast() with two tokens wakes all
//! three, two take a token and the third finds none: it must check its
//! predicate again and wait again.
//!
//! Part C, a condition variable has no memory: a signal with nobody waiting
//! is lost (a later timed_wait times out), unlike a semaphore's post. The
//! predicate, set under the mutex before the signal, is what is remembered:
//! a waiter that comes later finds it true and does not wait at all. Every
//! wait returns with the mutex locked again by the waiter.
//!
//! The Zig version of the C++ lesson (golden workspace,
//! test/rpi4b/tutor/09-condvar/1cpu/main.cpp), with the same checks.

const std = @import("std");
const uos = @import("uos");
const board = @import("board");
const tutor = @import("tutor");

const rtos = uos.rtos;
const Sample = tutor.Sample;
const sysclock = rtos.sysclock;
const prio = rtos.priority;

pub const uos_options = board.options(1);

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
fn nameOf(r: rtos.Error!void) []const u8 {
    r catch |e| return switch (e) {
        error.TimedOut => "ETIMEDOUT",
        error.NotPermitted => "EPERM",
        else => "other",
    };
    return "ok";
}

fn isErr(r: rtos.Error!void, want: rtos.Error) bool {
    r catch |e| return e == want;
    return false;
}

fn self() *rtos.Thread {
    return rtos.this_thread.thread();
}

// ---- Part A: producer -> bounded buffer -> consumer(s) --------------------------

const n_items = 400;
const n_slots = 8; // the bounded buffer
const n_consumers = if (four) 3 else 1;

var g_items: [n_items]Sample = @splat(.{}); // the data segment

// The ring and its count, all under g_ring_mx.
var g_ring: [n_slots]*Sample = undefined;
var g_head: usize = 0; // next slot to fill
var g_tail: usize = 0; // next slot to empty
var g_count: u32 = 0; // filled slots
var g_done = false; // four CPUs: the producer has finished

var g_ring_mx: rtos.Mutex = .initWith("ring", .{});
var g_not_full: rtos.ConditionVariable = .{ .name = "not_full" };
var g_not_empty: rtos.ConditionVariable = .{ .name = "not_empty" };

var g_max_in_flight: u32 = 0;
var g_producer_waits: u32 = 0; // times the buffer was full
var g_consumer_waits: u32 = 0; // times it was empty
var g_out_of_order: u32 = 0;
var g_got: [n_consumers]u32 = @splat(0);
var g_core_of: [n_consumers]u32 = @splat(99);
var g_consumed: tutor.SampleList = .{}; // under g_ring_mx

fn producer(_: ?*anyopaque) ?*anyopaque {
    for (&g_items, 0..) |*s, i| {
        const id: u32 = @intCast(i);
        s.init(id, tutor.generate(seed, id), .data);
        g_ring_mx.lock() catch {};
        // The predicate, in a loop: woken does not mean "not full".
        while (g_count == n_slots) {
            g_producer_waits += 1;
            g_not_full.wait(&g_ring_mx) catch {}; // unlocks, waits, locks again
        }
        g_ring[g_head] = s;
        g_head = (g_head + 1) % n_slots;
        g_count += 1;
        g_max_in_flight = @max(g_max_in_flight, g_count);
        g_not_empty.signal() catch {};
        g_ring_mx.unlock() catch {};
    }
    if (four) {
        // The end: every consumer must learn it, wherever it waits.
        g_ring_mx.lock() catch {};
        g_done = true;
        g_not_empty.broadcast() catch {};
        g_ring_mx.unlock() catch {};
    }
    return null;
}

fn consumer(arg: ?*anyopaque) ?*anyopaque {
    const c = @intFromPtr(arg);
    g_core_of[c] = board.cpuSlot();
    var last: i64 = -1;
    g_ring_mx.lock() catch {};
    while (true) {
        if (!four and g_got[c] == n_items) break;
        while (g_count == 0 and !g_done) {
            g_consumer_waits += 1;
            g_not_empty.wait(&g_ring_mx) catch {};
        }
        if (g_count == 0) break; // done, and nothing left
        const s = g_ring[g_tail];
        g_tail = (g_tail + 1) % n_slots;
        g_count -= 1;
        g_not_full.signal() catch {};
        if (four) {
            if (@as(i64, s.id) <= last or !s.valid()) g_out_of_order += 1;
        } else {
            if (s.id != g_got[c] or !s.valid()) g_out_of_order += 1;
        }
        last = s.id;
        g_got[c] += 1;
        g_consumed.push(s);
        if (!four) {
            // One CPU: the C++ lesson's consumer, the mutex released per item.
            g_ring_mx.unlock() catch {};
            g_ring_mx.lock() catch {};
        }
    }
    g_ring_mx.unlock() catch {};
    return null;
}

// ---- Part B: three waiters for tokens ------------------------------------------

const n_waiters = 3;

var g_tok_mx: rtos.Mutex = .initWith("tokens", .{});
var g_tok_cv: rtos.ConditionVariable = .{ .name = "tokens" };
var g_tokens: u32 = 0;
var g_tok_stop = false;
var g_wakes = std.atomic.Value(u32).init(0); // returns from wait()
var g_taken = std.atomic.Value(u32).init(0); // tokens taken
var g_rechecks = std.atomic.Value(u32).init(0); // woken, and the predicate still false
var g_waiting = std.atomic.Value(u32).init(0); // in wait() now

fn waiter(_: ?*anyopaque) ?*anyopaque {
    g_tok_mx.lock() catch {};
    while (true) {
        while (g_tokens == 0 and !g_tok_stop) {
            _ = g_waiting.fetchAdd(1, .monotonic);
            g_tok_cv.wait(&g_tok_mx) catch {};
            _ = g_waiting.fetchSub(1, .monotonic);
            _ = g_wakes.fetchAdd(1, .monotonic);
            if (g_tokens == 0 and !g_tok_stop) _ = g_rechecks.fetchAdd(1, .monotonic);
        }
        if (g_tokens == 0) break; // stop
        g_tokens -= 1;
        _ = g_taken.fetchAdd(1, .monotonic);
    }
    g_tok_mx.unlock() catch {};
    return null;
}

// Wait (sleeping) until `n` waiters are in wait().
fn waitWaiting(n: u32) void {
    var i: u32 = 0;
    while (i < 1000 and g_waiting.load(.monotonic) != n) : (i += 1) sysclock.sleepFor(1) catch {};
}

// ---- Part C: a late waiter, and the predicate -------------------------------

var g_flag_mx: rtos.Mutex = .initWith("flag", .{});
var g_flag_cv: rtos.ConditionVariable = .{ .name = "flag" };
var g_flag = false;
var g_late_waits: u32 = 0;
var g_late_owned = false;

fn lateWaiter(_: ?*anyopaque) ?*anyopaque {
    g_flag_mx.lock() catch {};
    while (!g_flag) {
        g_late_waits += 1;
        g_flag_cv.wait(&g_flag_mx) catch {};
    }
    g_late_owned = g_flag_mx.owner == self();
    g_flag_mx.unlock() catch {};
    return null;
}

pub fn main() void {
    board.uart.init();
    rtos.run(osMain);
}

fn osMain() void {
    const gpa = uos.memory.allocator();

    if (four) self().setCpuAffinity(1 << 0);
    tutor.printBanner("09 condvar");
    board.console(if (four) "Lesson 09, four CPUs: condition variables, predicates, signal and broadcast.\n" else "Lesson 09, one CPU: condition variables, predicates, signal and broadcast.\n", .{});
    tutor.printRegions();
    if (four) {
        // ---- Release cores 1-3 (as in lesson 01).
        board.smp.startSecondaryCores();
        const waited = board.smp.waitSecondaries(3000);
        board.console("  cores joined after {d} ms: {s}\n", .{ waited, board.smp.joinSummary() });
        _ = tutor.check(board.smp.secondariesJoined(), "cores 1-{d} joined the scheduler", .{uos.config.ncpu - 1});
    }
    const heap0 = tutor.heapBytes();

    // ---- Part A.
    if (four) {
        board.console("\n-- part A: a producer on core 1 passes {d} samples through {d} slots to {d} consumers on cores 2, 3 and 0: a mutex and two condition variables\n", .{ n_items, n_slots, n_consumers });
    } else {
        board.console("\n-- part A: a producer passes {d} samples to a consumer through {d} slots: a mutex and two condition variables\n", .{ n_items, n_slots });
    }
    {
        const cores = [3]u32{ 2, 3, 0 };
        const tp = spawn(gpa, "producer", producer, 0, prio.above_normal, if (four) 1 else null);
        var tc: [n_consumers]*rtos.Thread = undefined;
        for (&tc, 0..) |*t, c| t.* = spawn(gpa, "consumer", consumer, c, prio.normal, if (four) cores[c] else null);
        _ = tp.join() catch null;
        for (tc) |t| {
            _ = t.join() catch null; // each saw `done`: no lost wake-up
            t.destroy();
        }
        tp.destroy();
    }
    const n_consumed = g_consumed.count();
    tutor.sortList(&g_consumed);
    const e = tutor.reference(seed, 0, n_items);
    if (four) {
        board.console("  consumed {d} ({d} on core {d}, {d} on core {d}, {d} on core {d}), out of order {d}; at most {d} in flight; the producer waited {d} times, the consumers {d}\n", .{
            n_consumed, g_got[0], g_core_of[0], g_got[1], g_core_of[1], g_got[2], g_core_of[2], g_out_of_order, g_max_in_flight, g_producer_waits, g_consumer_waits,
        });
        _ = tutor.check(n_consumed == n_items and g_out_of_order == 0, "every sample consumed once ({d}), each consumer's in increasing order", .{n_items});
        _ = tutor.check(g_core_of[0] == 2 and g_core_of[1] == 3 and g_core_of[2] == 0, "all {d} consumers joined after the broadcast of `done` (no lost wake-up)", .{n_consumers});
    } else {
        board.console("  consumed {d}, out of order {d}; at most {d} in flight; the producer waited {d} times, the consumer {d}\n", .{ n_consumed, g_out_of_order, g_max_in_flight, g_producer_waits, g_consumer_waits });
        _ = tutor.check(n_consumed == n_items and g_out_of_order == 0, "every sample consumed, in order ({d})", .{n_items});
    }
    _ = tutor.check(tutor.checksum(g_consumed) == e.sorted_checksum, "the consumed samples' sorted checksum equals the reference ({x:0>8})", .{e.sorted_checksum});
    if (four) {
        _ = tutor.check(g_max_in_flight >= 1 and g_max_in_flight <= n_slots, "never more than {d} in flight", .{n_slots});
    } else {
        _ = tutor.check(g_max_in_flight == n_slots and g_producer_waits > 0, "the buffer filled to its {d} slots and the producer waited on not_full", .{n_slots});
    }

    // ---- Part B.
    if (four) {
        board.console("\n-- part B: {d} waiters on cores 1, 2 and 3 wait for a token; signal () with one, broadcast () with two\n", .{n_waiters});
    } else {
        board.console("\n-- part B: {d} waiters wait for a token; signal () with one, broadcast () with two\n", .{n_waiters});
    }
    {
        var tw: [n_waiters]*rtos.Thread = undefined;
        for (&tw, 0..) |*t, i| t.* = spawn(gpa, "waiter", waiter, 0, prio.above_normal, if (four) @as(u32, @intCast(i + 1)) else null);
        waitWaiting(n_waiters);
        const waiting0 = g_waiting.load(.monotonic);

        g_tok_mx.lock() catch {};
        g_tokens = 1;
        g_tok_cv.signal() catch {};
        g_tok_mx.unlock() catch {};
        sysclock.sleepFor(5) catch {};
        const s_wakes = g_wakes.load(.monotonic);
        const s_taken = g_taken.load(.monotonic);
        const s_rechecks = g_rechecks.load(.monotonic);
        waitWaiting(n_waiters);

        g_tok_mx.lock() catch {};
        g_tokens = 2;
        g_tok_cv.broadcast() catch {};
        g_tok_mx.unlock() catch {};
        sysclock.sleepFor(5) catch {};
        waitWaiting(n_waiters);
        const b_wakes = g_wakes.load(.monotonic) - s_wakes;
        const b_taken = g_taken.load(.monotonic) - s_taken;
        const b_rechecks = g_rechecks.load(.monotonic) - s_rechecks;

        board.console("  {d} waiting; signal (): {d} woken, {d} token taken, {d} re-checks; broadcast (): {d} woken, {d} tokens taken, {d} re-checks\n", .{ waiting0, s_wakes, s_taken, s_rechecks, b_wakes, b_taken, b_rechecks });
        _ = tutor.check(waiting0 == n_waiters, "{d} waiters in wait ()", .{n_waiters});
        _ = tutor.check(s_wakes == 1 and s_taken == 1 and s_rechecks == 0, "signal () wakes one waiter", .{});
        _ = tutor.check(b_wakes == n_waiters and b_taken == 2, "broadcast () wakes all {d}; two take a token", .{n_waiters});
        _ = tutor.check(b_rechecks >= 1, "a waiter woken with no token left finds its predicate false and waits again", .{});

        g_tok_mx.lock() catch {};
        g_tok_stop = true;
        g_tok_cv.broadcast() catch {};
        g_tok_mx.unlock() catch {};
        for (tw) |t| {
            _ = t.join() catch null;
            t.destroy();
        }
    }

    // ---- Part C.
    board.console("\n-- part C: a condition variable has no memory; the predicate has\n", .{});
    {
        g_flag_mx.lock() catch {};
        g_flag_cv.signal() catch {}; // nobody waits: lost
        const t0 = sysclock.now();
        const tw = g_flag_cv.timedWait(&g_flag_mx, 10);
        const waited = sysclock.now() - t0;
        const owned = g_flag_mx.owner == self();
        g_flag_mx.unlock() catch {};

        var sem: rtos.Semaphore = .binary("sem", 0);
        sem.post() catch {}; // nobody waits: kept
        const sw = sem.timedWait(10);

        board.console("  signal () with nobody waiting, then timed_wait (10): {s} after {d} ticks, mutex {s}; a semaphore posted first: timed_wait {s}\n", .{ nameOf(tw), waited, if (owned) "locked again" else "NOT locked", nameOf(sw) });
        _ = tutor.check(isErr(tw, error.TimedOut) and waited >= 10 and waited <= 11, "a signal with nobody waiting is lost (ETIMEDOUT)", .{});
        _ = tutor.check(owned, "timed_wait () returns with the mutex locked again", .{});
        _ = tutor.check(!std.meta.isError(sw), "a semaphore's post is kept", .{});

        g_flag_mx.lock() catch {};
        g_flag = true; // the predicate, under the mutex
        g_flag_cv.signal() catch {};
        g_flag_mx.unlock() catch {};
        const tl = spawn(gpa, "late", lateWaiter, 0, prio.above_normal, if (four) 2 else null);
        _ = tl.join() catch null;
        tl.destroy();
        board.console("  the predicate set and signalled before the waiter came: it waited {d} times, owned the mutex: {s}\n", .{ g_late_waits, if (g_late_owned) "yes" else "no" });
        _ = tutor.check(g_late_waits == 0 and g_late_owned, "a late waiter finds the predicate true and does not wait (no lost wake-up)", .{});
    }

    _ = tutor.check(tutor.heapBytes() == heap0, "heap back to {d} B", .{heap0});
    tutor.finish(if (four) "400 samples through 8 slots to 3 consumers on 3 cores, done broadcast to all; signal one, broadcast all, predicates; four CPUs" else "400 samples through 8 slots in order with two condition variables; signal one, broadcast all, predicates; one CPU");
}
