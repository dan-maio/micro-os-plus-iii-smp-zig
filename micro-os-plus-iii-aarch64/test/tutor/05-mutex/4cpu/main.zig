//! tutor-05-mutex-4cpu -- lesson 05, four CPUs (see ../README.md).
//!
//! The one-CPU lesson with the four workers pinned one per core: real
//! contention, no yield needed.
//!
//! Part A, the race: four workers push 200 samples each (ids 0 .. 799) on one
//! shared intrusive list, with no lock, at the same time on four cores. A
//! push reads the head and writes it back, with a short spin between the
//! two; the other cores push in the meantime, and the write-back throws their
//! nodes away. How many are lost depends on timing. *
//! Part B, the fix: the same pushes, each under one mutex: all 800 nodes in
//! the list, each once, and the sorted list's checksum equals the reference.
//!
//! Part C, the three types: a normal mutex's owner calling try_lock gets
//! EWOULDBLOCK (lock would deadlock); an errorcheck mutex reports EDEADLK on a
//! relock and EPERM on an extra unlock; a recursive mutex locks 5 deep, is
//! busy for another thread meanwhile, and refuses a 6th unlock with EPERM.
//!
//! Part D, waiting: a holder keeps a mutex for 50 ticks; try_lock returns
//! EWOULDBLOCK at once, timed_lock(10) ETIMEDOUT after 10 ticks, and
//! timed_lock(200) gets the mutex as soon as the holder releases it.
//!  
//!
//! The Zig version of the C++ lesson (golden workspace,
//! test/rpi4b/tutor/05-mutex/4cpu/main.cpp), with the same checks.

const std = @import("std");
const uos = @import("uos");
const board = @import("board");
const tutor = @import("tutor");

const rtos = uos.rtos;
const Sample = tutor.Sample;
const sysclock = rtos.sysclock;

pub const uos_options = board.options(4);

const four = true;
const seed: u32 = 2026;
const n_workers = 4;
const per_worker = 200;
const n_total = n_workers * per_worker;

// ---- Parts A and B: four workers, one shared list ------------------------------

// The nodes, in the data segment: worker w owns g_nodes[w][], ids
// w * 200 .. w * 200 + 199, so the 800 together are ids 0 .. 799.
var g_nodes: [n_workers][per_worker]Sample = @splat(@splat(.{}));

// The one list every worker pushes on.
var g_list: tutor.SampleList = .{};
var g_list_mx: rtos.Mutex = .initWith("list", .{});
var g_protected = false; // part B: the pushes hold g_list_mx

// The window between reading the head and writing it back: with one CPU a
// yield -- another worker runs in it, as an unlucky preemption would let it;
// with four a short spin, while the other cores do the same.
fn window() void {
    if (four) {
        var i: u32 = 0;
        while (i < 200) : (i += 1) std.mem.doNotOptimizeAway(i);
    } else {
        rtos.this_thread.yield();
    }
}

// A push in two steps with the window between them: what `head = node`
// costs is a load and a store, and a thread that is stopped between the two
// overwrites the pushes made in the meantime.
fn pushSlow(s: *Sample) void {
    const h = @as(*volatile ?*Sample, &g_list.head).*;
    window();
    s.next = h;
    @as(*volatile ?*Sample, &g_list.head).* = s;
}

fn worker(arg: ?*anyopaque) ?*anyopaque {
    const w: u32 = @intCast(@intFromPtr(arg));
    for (&g_nodes[w], 0..) |*s, i| {
        const id = w * per_worker + @as(u32, @intCast(i));
        s.init(id, tutor.generate(seed, id), .data);
        if (@as(*volatile bool, &g_protected).*) {
            g_list_mx.lock() catch {};
            pushSlow(s);
            g_list_mx.unlock() catch {};
        } else {
            pushSlow(s);
        }
    }
    return null;
}

fn spawn(gpa: std.mem.Allocator, name: [:0]const u8, f: *const fn (?*anyopaque) ?*anyopaque, arg: usize, prio: rtos.Priority, core: ?u32) *rtos.Thread {
    var attr: rtos.Thread.Attributes = .{ .priority = prio, .stack_size_bytes = 8 * 1024 };
    if (core) |c| attr.cpu_affinity = @as(u32, 1) << @intCast(c);
    return rtos.Thread.create(gpa, name, f, @ptrFromInt(arg), attr) catch {
        _ = tutor.check(false, "cannot create {s}", .{name});
        tutor.finish("");
    };
}

// Runs the four workers to their end and returns how many nodes are in the
// list; `once` tells whether each of the 800 is there exactly once.
var g_seen: [n_total]u8 = undefined;
fn runWorkers(gpa: std.mem.Allocator, once: *bool) usize {
    g_list.head = null;
    var th: [n_workers]*rtos.Thread = undefined;
    for (&th, 0..) |*t, w| t.* = spawn(gpa, "w", worker, w, rtos.priority.normal, if (four) @intCast(w) else null);
    for (th) |t| {
        _ = t.join() catch null;
        t.destroy();
    }
    @memset(&g_seen, 0);
    once.* = true;
    var n: usize = 0;
    var it = g_list.head;
    while (it) |s| : (it = s.next) {
        n += 1;
        if (n > n_total) break;
        if (s.id >= n_total or g_seen[s.id] != 0) once.* = false else g_seen[s.id] = 1;
    }
    if (n != n_total) once.* = false;
    return n;
}

// ---- Part D: a holder keeps the mutex for 50 ticks -----------------------------

var g_held_mx: rtos.Mutex = .initWith("held", .{});
var g_holding = std.atomic.Value(bool).init(false);
var g_released_at: rtos.Timestamp = 0;

fn holder(_: ?*anyopaque) ?*anyopaque {
    g_held_mx.lock() catch {};
    g_holding.store(true, .release);
    sysclock.sleepFor(50) catch {};
    g_released_at = sysclock.now();
    g_holding.store(false, .release);
    g_held_mx.unlock() catch {};
    return null;
}

// The C++ lesson's names for the results.
fn nameOf(r: rtos.Error!void) []const u8 {
    r catch |e| return switch (e) {
        error.WouldBlock => "EWOULDBLOCK",
        error.TimedOut => "ETIMEDOUT",
        error.Deadlock => "EDEADLK",
        error.NotPermitted => "EPERM",
        else => "other",
    };
    return "ok";
}

fn isErr(r: rtos.Error!void, want: rtos.Error) bool {
    r catch |e| return e == want;
    return false;
}

// Part C, on another thread: tryLock on a mutex the caller does not own.
var g_rec: rtos.Mutex = .initRecursive("recursive");
var g_other_try: rtos.Error!void = {};
fn otherTry(_: ?*anyopaque) ?*anyopaque {
    g_other_try = g_rec.tryLock();
    if (g_other_try) |_| g_rec.unlock() catch {} else |_| {}
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
    tutor.printBanner("05 mutex");
    board.console(if (four) "Lesson 05, four CPUs: mutex, normal, errorcheck, recursive, try_lock, timed_lock.\n" else "Lesson 05, one CPU: mutex, normal, errorcheck, recursive, try_lock, timed_lock.\n", .{});
    tutor.printRegions();
    if (four) {
        // ---- Release cores 1-3 (as in lesson 01).
        board.smp.startSecondaryCores();
        const waited = board.smp.waitSecondaries(3000);
        board.console("  cores joined after {d} ms: {s}\n", .{ waited, board.smp.joinSummary() });
        _ = tutor.check(board.smp.secondariesJoined(), "cores 1-{d} joined the scheduler", .{uos.config.ncpu - 1});
    }
    const heap0 = tutor.heapBytes();

    // ---- Part A: no lock.
    board.console("\n-- part A: {d} workers push {d} nodes each on one list, no lock\n", .{ n_workers, per_worker });
    g_protected = false;
    var once_a = false;
    const n_a = runWorkers(gpa, &once_a);
    board.console("  the list holds {d} of {d} nodes: {d} lost\n", .{ n_a, n_total, n_total - n_a });
    if (four) {
        // Four cores race for real: the losses depend on timing (the spin makes
        // them very likely); a count above 800 or a node twice would be worse.
        _ = tutor.check(n_a <= n_total, "without the lock: no more than {d} nodes (lost ones are printed above)", .{n_total});
    } else {
        _ = tutor.check(n_a < n_total, "without the lock nodes are lost (one CPU: the yield in the window makes it certain)", .{});
    }

    // ---- Part B: the same pushes under a mutex.
    board.console("\n-- part B: the same, each push under one mutex\n", .{});
    g_protected = true;
    var once_b = false;
    const n_b = runWorkers(gpa, &once_b);
    board.console("  the list holds {d} of {d} nodes\n", .{ n_b, n_total });
    _ = tutor.check(n_b == n_total and once_b, "with the mutex: all {d} nodes in the list, each once", .{n_total});
    tutor.sortList(&g_list);
    const e = tutor.reference(seed, 0, n_total);
    _ = tutor.check(tutor.checksum(g_list) == e.sorted_checksum, "the sorted list's checksum equals the reference ({x:0>8})", .{e.sorted_checksum});

    // ---- Part C: the three types.
    board.console("\n-- part C: normal, errorcheck, recursive\n", .{});
    {
        var mx: rtos.Mutex = .initWith("normal", .{});
        mx.lock() catch {};
        const r = mx.tryLock(); // a lock() here would deadlock
        board.console("  normal: lock, then try_lock by the owner: {s}\n", .{nameOf(r)});
        _ = tutor.check(isErr(r, error.WouldBlock), "normal: the owner's try_lock does not deadlock, returns EWOULDBLOCK", .{});
        mx.unlock() catch {};
    }
    {
        var mx: rtos.Mutex = .initWith("errorcheck", .{ .type = .errorcheck });
        mx.lock() catch {};
        const r1 = mx.lock();
        const r2 = mx.unlock();
        const r3 = mx.unlock();
        board.console("  errorcheck: lock, lock again: {s}; unlock: {s}; unlock again: {s}\n", .{ nameOf(r1), nameOf(r2), nameOf(r3) });
        _ = tutor.check(isErr(r1, error.Deadlock) and !std.meta.isError(r2) and isErr(r3, error.NotPermitted), "errorcheck: relock EDEADLK, extra unlock EPERM", .{});
    }
    {
        var all_ok = true;
        for (0..5) |_| g_rec.lock() catch {
            all_ok = false;
        };
        // Another thread, while this one holds it 5 deep.
        const t = spawn(gpa, "other", otherTry, 0, rtos.priority.normal, if (four) 2 else null);
        _ = t.join() catch null;
        t.destroy();
        for (0..5) |_| g_rec.unlock() catch {
            all_ok = false;
        };
        const r6 = g_rec.unlock();
        board.console("  recursive: 5 locks and 5 unlocks {s}; another thread's try_lock: {s}; a 6th unlock: {s}\n", .{ if (all_ok) "ok" else "BAD", nameOf(g_other_try), nameOf(r6) });
        _ = tutor.check(all_ok and isErr(g_other_try, error.WouldBlock) and isErr(r6, error.NotPermitted), "recursive: 5 deep, busy for another thread, the 6th unlock EPERM", .{});
    }

    // ---- Part D: try_lock and timed_lock against a holder.
    board.console(if (four) "\n-- part D: a holder keeps the mutex 50 ticks, on core 1\n" else "\n-- part D: a holder keeps the mutex 50 ticks\n", .{});
    {
        // Above the main thread's priority: it takes the mutex at once.
        const t = spawn(gpa, "holder", holder, 0, rtos.priority.above_normal, if (four) 1 else null);
        while (!g_holding.load(.acquire)) sysclock.sleepFor(1) catch {};
        const r1 = g_held_mx.tryLock();
        var t0 = sysclock.now();
        const r2 = g_held_mx.timedLock(10);
        const waited2 = sysclock.now() - t0;
        t0 = sysclock.now();
        const r3 = g_held_mx.timedLock(200);
        const got_at = sysclock.now();
        if (r3) |_| g_held_mx.unlock() catch {} else |_| {}
        _ = t.join() catch null;
        t.destroy();
        board.console("  try_lock: {s}; timed_lock(10): {s} after {d} ticks; timed_lock(200): {s} after {d} ticks, {d} ticks after the release\n", .{
            nameOf(r1), nameOf(r2), waited2, nameOf(r3), got_at - t0, got_at - g_released_at,
        });
        _ = tutor.check(isErr(r1, error.WouldBlock), "try_lock on a held mutex: EWOULDBLOCK at once", .{});
        _ = tutor.check(isErr(r2, error.TimedOut) and waited2 >= 10 and waited2 <= 11, "timed_lock(10): ETIMEDOUT after 10 ticks", .{});
        _ = tutor.check(!std.meta.isError(r3) and got_at - g_released_at <= 1, "timed_lock(200): the mutex as soon as the holder released it", .{});
    }

    _ = tutor.check(tutor.heapBytes() == heap0, "heap back to {d} B", .{heap0});
    tutor.finish(if (four) "no node lost under the mutex across 4 cores; types, try_lock and timed_lock as specified; four CPUs" else "no node lost under the mutex; types, try_lock and timed_lock as specified; one CPU");
}
