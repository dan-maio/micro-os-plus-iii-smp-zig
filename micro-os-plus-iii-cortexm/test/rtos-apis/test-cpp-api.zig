//! rtos-apis, part 1: the RTOS API (the C++ test-cpp-api.cpp, ported).
//!
//! Like the C++ part, it builds every object in the ways the API allows and
//! calls it; the C++ ownership variants map onto Zig as:
//!
//!   object on the stack / static        a local or global `var`, `.init()`
//!   `new` / `delete`                    `gpa.create()` / `gpa.destroy()`
//!   `unique_ptr`, `shared_ptr`,         the same, released with `defer`
//!   `allocate_unique/shared`            (Zig has no smart pointers)
//!   `*_allocated`, `*_inclusive`        storage from `gpa` / embedded
//!
//! The C++ part only checks with `assert()`; here the few checks it makes
//! (the third block of a two-block pool is null) are counted instead.

const std = @import("std");
const uos = @import("uos");
const rtos = uos.rtos;
const memory = uos.memory;
const trace = uos.trace;
const this_thread = rtos.this_thread;
const sysclock = rtos.sysclock;
const scheduler = rtos.scheduler;
const printf = trace.print;

const test_name = "Test C++ API";

pub var failures: u32 = 0;

fn check(ok: bool, what: []const u8) void {
    if (!ok) {
        failures += 1;
        printf("FAILED: {s}\n", .{what});
    }
}

const MyMsg = extern struct { i: i32, s: ?[*:0]const u8 };
const MyBlk = extern struct { i: i32, s: ?[*:0]const u8 };

fn func(_: ?*anyopaque) ?*anyopaque {
    printf("> func() on thread {s}\n", .{this_thread.thread().name});
    return null;
}

fn tmfunc(_: ?*anyopaque) void {
    printf(">> tmfunc()\n", .{});
}

const thread_state = [_][]const u8{ "undf", "rdy", "run", "wait", "term", "dead", "init", "dstr" };

fn iterateThreads(th: ?*rtos.Thread, depth: u32) void {
    var it = scheduler.childrenThreads(th).typedIterator(rtos.Thread, "child_links");
    while (it.next()) |p| {
        const stk = p.stack();
        const used: u32 = @intCast(stk.size() - stk.available());
        const used_proc: u32 = @intCast(used * 100 / stk.size());
        printf("{s}, {d}% ({d}/{d}), {s}, {d}, {d} \n", .{
            p.name,                                 used_proc,                  used, stk.size(),
            thread_state[@intFromEnum(p.getState())], p.statistics.context_switches, p.statistics.cpu_cycles,
        });
        iterateThreads(p, depth + 1);
    }
}

fn passMutexUp(pp: ?*rtos.Mutex) void {
    printf("{?*}\n", .{pp});
}

// The static ("inclusive") threads of the C++ part.
var sth1: rtos.ThreadInclusive(uos.options.default_stack_size_bytes) = undefined;
var sth2: rtos.ThreadInclusive(uos.options.default_stack_size_bytes) = undefined;

pub fn run() i32 {
    const gpa = memory.allocator();

    printf("\n{s} - started\n", .{test_name});

    {
        var it = scheduler.top_threads_list.typedIterator(rtos.Thread, "child_links");
        while (it.next()) |p| printf("{s}\n", .{p.name});
    }

    sysclock.sleepFor(5) catch {};

    printf("\nThreads:\n", .{});
    iterateThreads(null, 0);

    {
        var it = scheduler.top_threads_list.typedIterator(rtos.Thread, "child_links");
        while (it.next()) |p| printf("{s}\n", .{p.name});
    }

    printf("\n{s} - Memory managers\n", .{test_name});

    {
        // block_pool bp1{ "bp1", 2, sizeof (my_blk_t), arena, sizeof (arena) }:
        // two blocks, carved from a 60-byte arena.
        var arena: [60]u8 align(8) = undefined;
        var bp1: memory.BlockPool = .init("bp1", @sizeOf(MyBlk), arena[0 .. 2 * memory.BlockPool.blockSize(@sizeOf(MyBlk))]);
        const a = bp1.allocator();
        const b1 = a.create(MyBlk) catch null;
        const b2 = a.create(MyBlk) catch null;
        const b3 = a.create(MyBlk) catch null;
        check(b3 == null, "bp1: third block must be null");
        if (b1) |b| a.destroy(b);
        if (b2) |b| a.destroy(b);
    }
    {
        // block_pool_typed_inclusive<my_blk_t, 2>
        var storage: [2 * memory.BlockPool.blockSize(@sizeOf(MyBlk))]u8 align(8) = undefined;
        var bp2: memory.BlockPool = .init("bp2", @sizeOf(MyBlk), &storage);
        const a = bp2.allocator();
        const b1 = a.create(MyBlk) catch null;
        const b2 = a.create(MyBlk) catch null;
        const b3 = a.create(MyBlk) catch null;
        check(b3 == null, "bp2: third block must be null");
        if (b1) |b| a.destroy(b);
        if (b2) |b| a.destroy(b);
    }
    {
        // block_pool_typed_allocated<my_blk_t, rtos::memory::allocator>
        const storage = gpa.alignedAlloc(u8, .of(usize), 2 * memory.BlockPool.blockSize(@sizeOf(MyBlk))) catch unreachable;
        defer gpa.free(storage);
        var bp3: memory.BlockPool = .init("bp3", @sizeOf(MyBlk), storage);
        const a = bp3.allocator();
        const b1 = a.create(MyBlk) catch null;
        const b2 = a.create(MyBlk) catch null;
        const b3 = a.create(MyBlk) catch null;
        check(b3 == null, "bp3: third block must be null");
        if (b1) |b| a.destroy(b);
        if (b2) |b| a.destroy(b);
    }

    printf("\n{s} - Threads\n", .{test_name});

    {
        // On the stack, with the stack from the RTOS allocator.
        var th1: rtos.Thread = undefined;
        var th2: rtos.Thread = undefined;
        th1.init("-", func, null, .{}, gpa) catch unreachable;
        th2.init("th2", func, null, .{}, gpa) catch unreachable;
        _ = th1.join() catch {};
        _ = th2.join() catch {};
        th1.deinit();
        th2.deinit();
    }
    {
        // new / delete
        const th3 = rtos.Thread.create(gpa, "th3", func, null, .{}) catch unreachable;
        _ = th3.join() catch {};
        th3.destroy();
    }
    // unique_ptr, make_unique, shared_ptr, make_shared, allocate_shared,
    // rtos::make_shared, allocate_unique (x2): heap threads.
    for ([_][:0]const u8{ "th4", "th5", "th6", "th7", "th8", "th9", "th10", "th11" }) |name| {
        const th = rtos.Thread.create(gpa, name, func, null, .{}) catch unreachable;
        defer th.destroy();
        _ = th.join() catch {};
    }
    {
        // thread_allocated<rtos::memory::allocator>
        var ath1: rtos.Thread = undefined;
        var ath2: rtos.Thread = undefined;
        ath1.init("-", func, null, .{}, gpa) catch unreachable;
        ath2.init("ath2", func, null, .{}, gpa) catch unreachable;
        _ = ath1.join() catch {};
        _ = ath2.join() catch {};
        ath1.deinit();
        ath2.deinit();
    }
    {
        // static thread_inclusive<>
        sth1.init("-", func, null, .{}) catch unreachable;
        sth2.init("sth2", func, null, .{}) catch unreachable;
        _ = sth1.thread.join() catch {};
        _ = sth2.thread.join() catch {};
    }

    printf("\n{s} - Thread stack\n", .{test_name});

    {
        var n = rtos.ThreadStack.default_size_bytes;
        rtos.ThreadStack.default_size_bytes = n;
        n = rtos.ThreadStack.min_size_bytes;
        rtos.ThreadStack.min_size_bytes = n;

        const stack = this_thread.thread().stack();
        _ = stack.bottom();
        _ = stack.top();
        _ = stack.checkBottomMagic();
        _ = stack.checkTopMagic();
    }

    printf("\n{s} - Thread event flags\n", .{test_name});

    {
        const me = this_thread.thread();
        _ = this_thread.flagsClear(rtos.flags.all) catch {};

        _ = me.flagsRaise(0x3) catch {};
        _ = this_thread.flagsWait(0x3, .{ .all = true }) catch {};

        _ = me.flagsRaise(0x3) catch {};
        _ = this_thread.flagsTryWait(0x3, .all_clear) catch {};

        _ = me.flagsRaise(0x3) catch {};
        _ = this_thread.flagsTimedWait(0x3, 10, .all_clear) catch {};
    }

    printf("\n{s} - Message queues\n", .{test_name});

    const msg_out: MyMsg = .{ .i = 1, .s = "msg" };
    var msg_in: MyMsg = undefined;
    const out_bytes = std.mem.asBytes(&msg_out);
    const in_bytes = std.mem.asBytes(&msg_in);

    {
        var cq1: rtos.MessageQueue = .{};
        cq1.create(gpa, "-", 3, @sizeOf(MyMsg), .{}) catch unreachable;
        defer cq1.deinit();
        cq1.send(out_bytes, 0) catch {};

        var cq2: rtos.MessageQueue = .{};
        cq2.create(gpa, "cq2", 3, @sizeOf(MyMsg), .{}) catch unreachable;
        defer cq2.deinit();
        cq2.send(out_bytes, 0) catch {};
        cq2.reset() catch {};
    }
    // new / delete, unique_ptr, allocate_unique (x2)
    for ([_][:0]const u8{ "cq3", "cq4", "cq5", "cq6" }) |name| {
        const q = gpa.create(rtos.MessageQueue) catch unreachable;
        defer gpa.destroy(q);
        q.* = .{};
        q.create(gpa, name, 3, @sizeOf(MyMsg), .{}) catch unreachable;
        defer q.deinit();
        q.send(out_bytes, 0) catch {};
    }

    const MyQueue = rtos.MessageQueueTyped(MyMsg);
    {
        var tq1: MyQueue = .{};
        tq1.create(gpa, "-", 7, .{}) catch unreachable;
        defer tq1.deinit();
        tq1.send(msg_out, 0) catch {};
        msg_in = tq1.receive() catch msg_in;
        tq1.trySend(msg_out, 0) catch {};
        msg_in = tq1.tryReceive() catch msg_in;
        tq1.timedSend(msg_out, 1, 0) catch {};
        msg_in = tq1.timedReceive(1) catch msg_in;

        var tq2: MyQueue = .{};
        tq2.create(gpa, "tq2", 7, .{}) catch unreachable;
        defer tq2.deinit();
        tq2.send(msg_out, 0) catch {};
        msg_in = tq2.receive() catch msg_in;
    }
    for ([_][:0]const u8{ "tq3", "tq4", "tq5", "tq6" }) |name| {
        const tq = gpa.create(MyQueue) catch unreachable;
        defer gpa.destroy(tq);
        tq.* = .{};
        tq.create(gpa, name, 7, .{}) catch unreachable;
        defer tq.deinit();
        tq.send(msg_out, 0) catch {};
        msg_in = tq.receive() catch msg_in;
    }
    {
        // message_queue_inclusive<my_msg_t, 4>
        var sq1: MyQueue.Static(4) = .{};
        sq1.init("-", .{}) catch unreachable;
        sq1.typed.send(msg_out, 0) catch {};
        msg_in = sq1.typed.receive() catch msg_in;
        sq1.typed.trySend(msg_out, 0) catch {};
        msg_in = sq1.typed.tryReceive() catch msg_in;
        sq1.typed.timedSend(msg_out, 1, 0) catch {};
        msg_in = sq1.typed.timedReceive(1) catch msg_in;

        var sq2: MyQueue.Static(4) = .{};
        sq2.init("sq2", .{}) catch unreachable;
        sq2.typed.send(msg_out, 0) catch {};
        msg_in = sq2.typed.receive() catch msg_in;
    }
    _ = in_bytes;

    printf("\n{s} - Memory pools\n", .{test_name});

    {
        var cp1: rtos.MemoryPool = .{};
        cp1.create(gpa, "-", 3, @sizeOf(MyBlk), .{}) catch unreachable;
        defer cp1.deinit();
        var blk = cp1.alloc() catch unreachable;
        cp1.free(blk) catch {};
        blk = cp1.tryAlloc() catch unreachable;
        cp1.free(blk) catch {};
        blk = cp1.timedAlloc(1) catch unreachable;
        cp1.free(blk) catch {};
        cp1.reset() catch {};

        var cp2: rtos.MemoryPool = .{};
        cp2.create(gpa, "cp2", 3, @sizeOf(MyBlk), .{}) catch unreachable;
        defer cp2.deinit();
        blk = cp2.alloc() catch unreachable;
        cp2.free(blk) catch {};
    }
    for ([_][:0]const u8{ "cp3", "cp4", "cp5", "cp6" }) |name| {
        const cp = gpa.create(rtos.MemoryPool) catch unreachable;
        defer gpa.destroy(cp);
        cp.* = .{};
        cp.create(gpa, name, 3, @sizeOf(MyBlk), .{}) catch unreachable;
        defer cp.deinit();
        const blk = cp.alloc() catch unreachable;
        cp.free(blk) catch {};
    }

    const MyPool = rtos.MemoryPoolTyped(MyBlk);
    {
        var tp1: MyPool = .{};
        tp1.create(gpa, "-", 7, .{}) catch unreachable;
        defer tp1.deinit();
        var blk = tp1.alloc() catch unreachable;
        tp1.free(blk) catch {};
        blk = tp1.tryAlloc() catch unreachable;
        tp1.free(blk) catch {};
        blk = tp1.timedAlloc(1) catch unreachable;
        tp1.free(blk) catch {};

        var tp2: MyPool = .{};
        tp2.create(gpa, "tp2", 7, .{}) catch unreachable;
        defer tp2.deinit();
        blk = tp2.alloc() catch unreachable;
        tp2.free(blk) catch {};
    }
    for ([_][:0]const u8{ "tp3", "tp4", "tp5", "tp6" }) |name| {
        const tp = gpa.create(MyPool) catch unreachable;
        defer gpa.destroy(tp);
        tp.* = .{};
        tp.create(gpa, name, 7, .{}) catch unreachable;
        defer tp.deinit();
        const blk = tp.alloc() catch unreachable;
        tp.free(blk) catch {};
    }
    {
        // memory_pool_inclusive<my_blk_t, 4>
        var sp1: MyPool.Static(4) = .{};
        sp1.init("-", .{}) catch unreachable;
        var blk = sp1.typed.alloc() catch unreachable;
        sp1.typed.free(blk) catch {};
        blk = sp1.typed.tryAlloc() catch unreachable;
        sp1.typed.free(blk) catch {};
        blk = sp1.typed.timedAlloc(1) catch unreachable;
        sp1.typed.free(blk) catch {};

        var sp2: MyPool.Static(4) = .{};
        sp2.init("sp2", .{}) catch unreachable;
        blk = sp2.typed.alloc() catch unreachable;
        sp2.typed.free(blk) catch {};
    }

    printf("\n{s} - Condition variables\n", .{test_name});

    {
        var cv1: rtos.ConditionVariable = .{};
        cv1.signal() catch {};

        var cv2: rtos.ConditionVariable = .{ .name = "cv2" };
        cv2.signal() catch {};
        cv2.broadcast() catch {};
    }
    for ([_][:0]const u8{ "cv3", "cv4", "cv5", "cv6", "cv7" }) |name| {
        const cv = gpa.create(rtos.ConditionVariable) catch unreachable;
        defer gpa.destroy(cv);
        cv.init(name, .{}) catch unreachable;
        cv.signal() catch {};
    }

    printf("\n{s} - Event flags\n", .{test_name});

    {
        var ev1: rtos.EventFlags = .{};
        _ = ev1.clear(1) catch {};

        var ev2: rtos.EventFlags = .{ .name = "ev2" };
        _ = ev2.clear(1) catch {};
    }
    for ([_][:0]const u8{ "ev3", "ev4", "ev5", "ev6", "ev7" }) |name| {
        const ev = gpa.create(rtos.EventFlags) catch unreachable;
        defer gpa.destroy(ev);
        ev.init(name, .{}) catch unreachable;
        _ = ev.clear(1) catch {};
    }

    printf("\n{s} - Mutexes\n", .{test_name});

    {
        var mx1: rtos.Mutex = .{};
        mx1.lock() catch {};
        mx1.unlock() catch {};
        mx1.tryLock() catch {};
        mx1.unlock() catch {};
        mx1.timedLock(10) catch {};
        mx1.unlock() catch {};

        _ = mx1.name;
        _ = mx1.getType();
        _ = mx1.protocol;
        _ = mx1.robustness;
        _ = mx1.getOwner();

        const prio = mx1.getPriorityCeiling();
        _ = mx1.setPriorityCeiling(prio) catch {};

        mx1.reset() catch {};
    }
    {
        var mx: rtos.Mutex = .{ .name = "mx2" };
        mx.lock() catch {};
        mx.unlock() catch {};
    }
    {
        var mx: rtos.Mutex = .initRecursive("mx3");
        mx.lock() catch {};
        mx.unlock() catch {};

        var mx2: rtos.Mutex = .initRecursive("mx4"); // mutex_recursive
        mx2.lock() catch {};
        mx2.unlock() catch {};
    }
    for ([_][:0]const u8{ "mx5", "mx6", "mx6", "mx7", "mx8" }) |name| {
        const mx = gpa.create(rtos.Mutex) catch unreachable;
        defer gpa.destroy(mx);
        mx.init(name, .{}) catch unreachable;
        mx.lock() catch {};
        mx.unlock() catch {};
    }
    {
        // A unique_ptr passed by const reference, by reference, and moved.
        var mx: ?*rtos.Mutex = gpa.create(rtos.Mutex) catch unreachable;
        mx.?.init("mx9", .{}) catch unreachable;
        mx.?.lock() catch {};
        mx.?.unlock() catch {};

        passMutexUp(mx);
        printf("{?*}\n", .{mx});
        passMutexUp(mx);
        printf("{?*}\n", .{mx});
        // Moved out: the callee owns it now, the caller's pointer is null.
        const moved = mx;
        mx = null;
        passMutexUp(moved);
        gpa.destroy(moved.?);
        printf("{?*}\n", .{mx});
    }

    printf("\n{s} - Semaphores\n", .{test_name});

    {
        var sp: rtos.Semaphore = .{};
        sp.post() catch {};
    }
    {
        var sp: rtos.Semaphore = .{ .name = "sp2" };
        sp.post() catch {};
        sp.wait() catch {};
        sp.post() catch {};
        sp.tryWait() catch {};
        sp.post() catch {};
        sp.timedWait(1) catch {};
        sp.post() catch {};
        sp.timedWait(0xFFFF_FFFF) catch {};
        sp.reset() catch {};
    }
    {
        var sp: rtos.Semaphore = .binary("sp3", 0);
        sp.post() catch {};
    }
    for ([_][:0]const u8{ "sp4", "sp5", "sp6", "sp7" }) |name| {
        const sp = gpa.create(rtos.Semaphore) catch unreachable;
        defer gpa.destroy(sp);
        sp.init(name, .{}) catch unreachable;
        sp.post() catch {};
    }

    printf("\n{s} - Timers\n", .{test_name});

    {
        var tm: rtos.Timer = .init("-", tmfunc, null, .once);
        defer tm.deinit();
        sysclock.sleepFor(1) catch {}; // sync
        tm.start(1) catch {};
        sysclock.sleepFor(2) catch {};
        tm.stop() catch {};
    }
    {
        var tm: rtos.Timer = .init("tm2", tmfunc, null, .once);
        defer tm.deinit();
        sysclock.sleepFor(1) catch {};
        tm.start(1) catch {};
        sysclock.sleepFor(2) catch {};
        tm.stop() catch {};
    }
    {
        var tm: rtos.Timer = .init("tm3", tmfunc, null, .periodic);
        defer tm.deinit();
        sysclock.sleepFor(1) catch {};
        tm.start(1) catch {};
        sysclock.sleepFor(2) catch {};
        tm.stop() catch {};
    }
    for ([_][:0]const u8{ "tm4", "tm5", "tm6", "tm7", "tm8" }) |name| {
        const tm = gpa.create(rtos.Timer) catch unreachable;
        defer gpa.destroy(tm);
        tm.* = .init(name, tmfunc, null, .once);
        defer tm.deinit();
        sysclock.sleepFor(1) catch {};
        tm.start(1) catch {};
        sysclock.sleepFor(2) catch {};
        tm.stop() catch {};
    }

    {
        _ = scheduler.preemptive(false) catch {};
        _ = scheduler.preemptive(true) catch {};
    }

    printf("\n{s} - done\n", .{test_name});
    return if (failures == 0) 0 else 1;
}
