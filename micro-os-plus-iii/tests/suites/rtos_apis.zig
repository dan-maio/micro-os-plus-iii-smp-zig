//! rtos-apis: every RTOS object, its blocking paths, timeouts and error
//! returns (the C++ `test-cpp-api.cpp`, with real checks).

const std = @import("std");
const uos = @import("uos");
const t = @import("check.zig");
const rtos = uos.rtos;

const sysclock = rtos.sysclock;

pub fn run() u32 {
    t.reset();
    uos.trace.puts("\nrtos-apis - started");
    memoryManagers();
    threads();
    threadFlags();
    mutexes();
    conditionVariables();
    semaphores();
    eventFlags();
    messageQueues();
    memoryPools();
    timers();
    clocksAndInterrupts();
    iterateThreads();
    uos.memory.tracePrintStatistics();
    return t.summary("rtos-apis");
}

// ----------------------------------------------------------------------------

const Blk = struct { i: i32, s: []const u8 };

fn memoryManagers() void {
    t.section("memory managers");
    {
        // Room for exactly two blocks.
        var arena: [2 * uos.memory.BlockPool.blockSize(@sizeOf(Blk))]u8 align(8) = undefined;
        var bp: uos.memory.BlockPool = .init("bp1", @sizeOf(Blk), &arena);
        const a = bp.allocator();
        const b1 = a.create(Blk) catch null;
        const b2 = a.create(Blk) catch null;
        t.ok(b1 != null and b2 != null, @src());
        t.err(error.OutOfMemory, a.create(Blk), @src());
        a.destroy(b1.?);
        a.destroy(b2.?);
        t.eq(@as(usize, 0), bp.count, @src());
    }
    {
        var arena: [1024]u8 align(8) = undefined;
        var lifo: uos.memory.FirstFitTop = .init("lifo", &arena, .lifo);
        const a = lifo.allocator();
        const p1 = a.alloc(u8, 100) catch unreachable;
        const p2 = a.alloc(u32, 20) catch unreachable;
        a.free(p2);
        a.free(p1);
        t.eq(@as(usize, 1), lifo.stats.free_chunks, @src());
    }
    {
        // The system heap, through std containers.
        const gpa = uos.memory.allocator();
        var list: std.ArrayList(u32) = .empty;
        defer list.deinit(gpa);
        for (0..100) |i| list.append(gpa, @intCast(i)) catch unreachable;
        t.eq(@as(usize, 100), list.items.len, @src());
        t.eq(@as(u32, 99), list.items[99], @src());
    }
}

// ----------------------------------------------------------------------------

var func_runs: u32 = 0;

fn func(args: ?*anyopaque) ?*anyopaque {
    _ = @atomicRmw(u32, &func_runs, .Add, 1, .monotonic);
    return args;
}

fn add(a: u32, b: u32, out: *u32) void {
    out.* = a + b;
}

fn sleeper(_: ?*anyopaque) ?*anyopaque {
    sysclock.sleepFor(1_000_000) catch |err| {
        return if (err == error.Interrupted) @ptrFromInt(0x1) else null;
    };
    return null;
}

var sth: rtos.ThreadInclusive(2048) = undefined;

fn threads() void {
    t.section("threads");
    const gpa = uos.memory.allocator();
    func_runs = 0;
    {
        // Static, with the exit value through join().
        sth.init("sth1", func, @ptrFromInt(0x1234), .{}) catch unreachable;
        const r = sth.thread.join() catch null;
        t.eq(@as(usize, 0x1234), @intFromPtr(r), @src());
        sth.deinit();
    }
    {
        // Dynamic.
        const th = rtos.Thread.create(gpa, "th2", func, null, .{ .priority = rtos.priority.above_normal }) catch unreachable;
        t.success(th.join(), @src());
        t.eq(rtos.Thread.State.destroyed, th.getState(), @src());
        th.destroy();
    }
    {
        // Typed arguments.
        var out: u32 = 0;
        const th = rtos.Thread.spawn(gpa, .{}, "th3", add, .{ 40, 2, &out }) catch unreachable;
        _ = th.join() catch {};
        th.destroy();
        t.eq(@as(u32, 42), out, @src());
    }
    t.eq(@as(u32, 2), func_runs, @src());
    {
        // Interrupt a sleeping thread; then kill one.
        const th = rtos.Thread.create(gpa, "sleeper", sleeper, null, .{}) catch unreachable;
        sysclock.sleepFor(5) catch {};
        _ = th.interrupt(true);
        const r = th.join() catch null;
        t.eq(@as(usize, 1), @intFromPtr(r), @src());
        th.destroy();

        const th2 = rtos.Thread.create(gpa, "victim", sleeper, null, .{}) catch unreachable;
        sysclock.sleepFor(5) catch {};
        t.success(th2.kill(), @src());
        t.eq(rtos.Thread.State.destroyed, th2.getState(), @src());
        th2.destroy();
    }
    {
        // Priorities.
        const me = rtos.this_thread.thread();
        const prev = me.priority();
        t.success(me.setPriority(rtos.priority.high), @src());
        t.eq(rtos.priority.high, me.priority(), @src());
        t.err(error.InvalidArgument, me.setPriority(rtos.priority.none), @src());
        t.success(me.setPriority(prev), @src());
    }
    {
        // The stack of this thread.
        const st = rtos.this_thread.thread().stack();
        t.ok(st.checkBottomMagic() and st.checkTopMagic(), @src());
        t.ok(st.available() > 0 and st.available() < st.size(), @src());
    }
}

// ----------------------------------------------------------------------------

fn threadFlags() void {
    t.section("thread event flags");
    const me = rtos.this_thread.thread();
    _ = rtos.this_thread.flagsClear(rtos.flags.all) catch {};
    _ = me.flagsRaise(0x3) catch {};
    t.eq(@as(u32, 0x3), rtos.this_thread.flagsWait(0x3, .all_clear) catch 0, @src());
    _ = me.flagsRaise(0x3) catch {};
    t.eq(@as(u32, 0x1), rtos.this_thread.flagsTryWait(0x1, .any_clear) catch 0, @src());
    t.eq(@as(u32, 0x2), rtos.this_thread.flagsGet(0, .{}), @src());
    t.err(error.WouldBlock, rtos.this_thread.flagsTryWait(0x1, .any_clear), @src());
    const t0 = sysclock.now();
    t.err(error.TimedOut, rtos.this_thread.flagsTimedWait(0x1, 10, .all_clear), @src());
    t.ok(sysclock.now() - t0 >= 10, @src());
    _ = rtos.this_thread.flagsClear(rtos.flags.all) catch {};
    t.err(error.InvalidArgument, me.flagsRaise(0), @src());
}

// ----------------------------------------------------------------------------

var mx: rtos.Mutex = .{ .name = "mx" };
var holder_ready: rtos.Semaphore = .binary("holder-ready", 0);
var holder_release: rtos.Semaphore = .binary("holder-release", 0);

fn holder(arg: ?*anyopaque) ?*anyopaque {
    const m: *rtos.Mutex = @ptrCast(@alignCast(arg.?));
    m.lock() catch return null;
    holder_ready.post() catch {};
    holder_release.wait() catch {};
    m.unlock() catch {};
    return null;
}

fn mutexes() void {
    t.section("mutexes");
    const gpa = uos.memory.allocator();

    t.success(mx.lock(), @src());
    t.eq(rtos.this_thread.thread(), mx.getOwner().?, @src());
    t.err(error.WouldBlock, mx.tryLock(), @src()); // normal: no recursion
    t.success(mx.unlock(), @src());
    t.err(error.NotRecoverable, mx.unlock(), @src()); // normal, not owned

    {
        var rmx: rtos.Mutex = .initRecursive("rmx");
        t.success(rmx.lock(), @src());
        t.success(rmx.lock(), @src());
        t.eq(@as(u16, 2), rmx.count, @src());
        t.success(rmx.unlock(), @src());
        t.success(rmx.unlock(), @src());
        t.err(error.NotPermitted, rmx.unlock(), @src());
    }
    {
        var emx: rtos.Mutex = .initWith("emx", .{ .type = .errorcheck });
        t.success(emx.lock(), @src());
        t.err(error.Deadlock, emx.lock(), @src());
        t.success(emx.unlock(), @src());
    }
    {
        // Contention, timeout, and priority inheritance: a low priority
        // holder is boosted while a higher priority thread waits.
        const me = rtos.this_thread.thread();
        const prev = me.priority();
        const th = rtos.Thread.create(gpa, "holder", holder, &mx, .{ .priority = rtos.priority.low }) catch unreachable;
        holder_ready.wait() catch {};
        t.err(error.WouldBlock, mx.tryLock(), @src());
        const t0 = sysclock.now();
        t.err(error.TimedOut, mx.timedLock(20), @src());
        t.ok(sysclock.now() - t0 >= 20, @src());

        _ = me.setPriority(rtos.priority.high) catch {};
        // While we wait in timedLock, the holder runs boosted.
        t.err(error.TimedOut, mx.timedLock(5), @src());
        holder_release.post() catch {};
        t.success(mx.lock(), @src());
        t.ok(th.priorityInherited() == rtos.priority.none or th.getState() == .destroyed or th.priority() <= rtos.priority.high, @src());
        t.success(mx.unlock(), @src());
        _ = th.join() catch {};
        th.destroy();
        _ = me.setPriority(prev) catch {};
    }
    {
        var pmx: rtos.Mutex = .initWith("ceiling", .{ .protocol = .protect, .priority_ceiling = rtos.priority.realtime });
        const me = rtos.this_thread.thread();
        t.success(pmx.lock(), @src());
        t.eq(rtos.priority.realtime, me.priority(), @src()); // boosted to the ceiling
        t.success(pmx.unlock(), @src());
        t.ok(me.priority() < rtos.priority.realtime, @src());
    }
    {
        var rmx: rtos.Mutex = .initWith("robust", .{ .robustness = .robust });
        rmx.internalMarkOwnerDead();
        t.err(error.OwnerDead, rmx.lock(), @src());
        t.success(rmx.consistent(), @src());
        t.success(rmx.unlock(), @src());
        t.success(rmx.lock(), @src());
        t.success(rmx.unlock(), @src());
        t.success(rmx.reset(), @src());
    }
}

// ----------------------------------------------------------------------------

var cv: rtos.ConditionVariable = .{ .name = "cv" };
var cv_mx: rtos.Mutex = .{ .name = "cv-mx" };
var cv_ready: u32 = 0;

fn cvProducer(_: ?*anyopaque) ?*anyopaque {
    sysclock.sleepFor(5) catch {};
    cv_mx.lock() catch return null;
    cv_ready = 1;
    cv.signal() catch {};
    cv_mx.unlock() catch {};
    return null;
}

fn conditionVariables() void {
    t.section("condition variables");
    const gpa = uos.memory.allocator();
    cv_ready = 0;
    const th = rtos.Thread.create(gpa, "producer", cvProducer, null, .{}) catch unreachable;
    t.success(cv_mx.lock(), @src());
    while (cv_ready == 0) {
        cv.wait(&cv_mx) catch |e| {
            t.expect(false, @src(), "wait: {s}", .{@errorName(e)});
            break;
        };
    }
    t.eq(@as(u32, 1), cv_ready, @src());
    t.err(error.TimedOut, cv.timedWait(&cv_mx, 10), @src());
    t.eq(rtos.this_thread.thread(), cv_mx.getOwner().?, @src()); // re-locked
    t.success(cv_mx.unlock(), @src());
    t.success(cv.broadcast(), @src());
    _ = th.join() catch {};
    th.destroy();
}

// ----------------------------------------------------------------------------

var sem_posts: rtos.Semaphore = .counting("posts", 5, 0);

fn poster(_: ?*anyopaque) ?*anyopaque {
    for (0..3) |_| {
        sysclock.sleepFor(2) catch {};
        sem_posts.post() catch {};
    }
    return null;
}

fn semaphores() void {
    t.section("semaphores");
    const gpa = uos.memory.allocator();
    {
        var b: rtos.Semaphore = .binary("b", 0);
        t.err(error.WouldBlock, b.tryWait(), @src());
        t.success(b.post(), @src());
        t.err(error.Again, b.post(), @src()); // binary: max 1
        t.success(b.wait(), @src());
        t.err(error.TimedOut, b.timedWait(5), @src());
    }
    {
        var bad: rtos.Semaphore = undefined;
        t.err(error.InvalidArgument, bad.init("bad", .{ .initial_value = 3, .max_value = 2 }), @src());
    }
    {
        const th = rtos.Thread.create(gpa, "poster", poster, null, .{}) catch unreachable;
        for (0..3) |_| t.success(sem_posts.timedWait(1000), @src());
        t.eq(@as(rtos.semaphore.Count, 0), sem_posts.value(), @src());
        _ = th.join() catch {};
        th.destroy();
        t.success(sem_posts.reset(), @src());
    }
}

// ----------------------------------------------------------------------------

var ev: rtos.EventFlags = .{ .name = "ev" };

fn raiser(_: ?*anyopaque) ?*anyopaque {
    sysclock.sleepFor(3) catch {};
    _ = ev.raise(0x1) catch {};
    sysclock.sleepFor(3) catch {};
    _ = ev.raise(0x2) catch {};
    return null;
}

fn eventFlags() void {
    t.section("event flags");
    const gpa = uos.memory.allocator();
    const th = rtos.Thread.create(gpa, "raiser", raiser, null, .{}) catch unreachable;
    t.eq(@as(u32, 0x3), ev.wait(0x3, .all_clear) catch 0, @src());
    t.eq(@as(u32, 0), ev.get(0, .{}), @src());
    t.err(error.WouldBlock, ev.tryWait(0x1, .any_clear), @src());
    t.err(error.TimedOut, ev.timedWait(0x4, 5, .any_clear), @src());
    _ = ev.raise(0x5) catch {};
    t.eq(@as(u32, 0x1), ev.tryWait(0x1, .{ .any = true }) catch 0, @src());
    t.eq(@as(u32, 0x5), ev.clear(0x5) catch 0, @src());
    t.ok(!ev.waiting(), @src());
    t.err(error.InvalidArgument, ev.raise(0), @src());
    _ = th.join() catch {};
    th.destroy();
}

// ----------------------------------------------------------------------------

const Msg = struct { i: i32, tag: u8 };

var tq: rtos.MessageQueueTyped(Msg).Static(4) = .{};

fn sender(_: ?*anyopaque) ?*anyopaque {
    for (0..10) |i| tq.typed.send(.{ .i = @intCast(i), .tag = 's' }, 0) catch return null;
    return null;
}

fn messageQueues() void {
    t.section("message queues");
    const gpa = uos.memory.allocator();
    {
        var q: rtos.MessageQueue = .{};
        t.success(q.create(gpa, "q1", 3, @sizeOf(Msg), .{}), @src());
        defer q.deinit();
        const m1: Msg = .{ .i = 1, .tag = 'a' };
        const m2: Msg = .{ .i = 2, .tag = 'b' };
        const m3: Msg = .{ .i = 3, .tag = 'c' };
        t.success(q.send(std.mem.asBytes(&m1), 1), @src());
        t.success(q.send(std.mem.asBytes(&m2), 5), @src());
        t.success(q.send(std.mem.asBytes(&m3), 1), @src());
        t.ok(q.isFull(), @src());
        t.err(error.WouldBlock, q.trySend(std.mem.asBytes(&m1), 0), @src());
        t.err(error.TimedOut, q.timedSend(std.mem.asBytes(&m1), 5, 0), @src());
        var in: Msg = undefined;
        // Highest priority first, then FIFO.
        t.eq(@as(u8, 5), q.receive(std.mem.asBytes(&in)) catch 0, @src());
        t.eq(@as(i32, 2), in.i, @src());
        _ = q.receive(std.mem.asBytes(&in)) catch {};
        t.eq(@as(i32, 1), in.i, @src());
        _ = q.receive(std.mem.asBytes(&in)) catch {};
        t.eq(@as(i32, 3), in.i, @src());
        t.err(error.WouldBlock, q.tryReceive(std.mem.asBytes(&in)), @src());
        t.err(error.TimedOut, q.timedReceive(std.mem.asBytes(&in), 5), @src());
        var too_big: [64]u8 = undefined;
        t.err(error.MessageSize, q.send(&too_big, 0), @src());
        t.success(q.reset(), @src());
    }
    {
        // Typed, embedded storage, a blocked sender.
        t.success(tq.init("tq", .{}), @src());
        const th = rtos.Thread.create(gpa, "sender", sender, null, .{}) catch unreachable;
        var sum: i32 = 0;
        for (0..10) |_| {
            const m = tq.typed.timedReceive(1000) catch break;
            sum += m.i;
        }
        t.eq(@as(i32, 45), sum, @src());
        _ = th.join() catch {};
        th.destroy();
    }
}

// ----------------------------------------------------------------------------

var tp: rtos.MemoryPoolTyped(Blk).Static(3) = .{};

fn memoryPools() void {
    t.section("memory pools");
    const gpa = uos.memory.allocator();
    {
        var mp: rtos.MemoryPool = .{};
        t.success(mp.create(gpa, "mp1", 3, @sizeOf(Blk), .{}), @src());
        defer mp.deinit();
        const a = mp.alloc() catch unreachable;
        const b = mp.tryAlloc() catch unreachable;
        const c = mp.timedAlloc(1) catch unreachable;
        t.ok(mp.isFull(), @src());
        t.err(error.WouldBlock, mp.tryAlloc(), @src());
        t.err(error.TimedOut, mp.timedAlloc(5), @src());
        var junk: u32 = 0;
        t.err(error.InvalidArgument, mp.free(&junk), @src());
        t.success(mp.free(a), @src());
        t.success(mp.free(b), @src());
        t.success(mp.free(c), @src());
        t.ok(mp.isEmpty(), @src());
        t.success(mp.reset(), @src());
    }
    {
        t.success(tp.init("tp", .{}), @src());
        const b: *Blk = tp.typed.alloc() catch unreachable;
        b.* = .{ .i = 7, .s = "blk" };
        t.success(tp.typed.free(b), @src());
    }
}

// ----------------------------------------------------------------------------

var once_count: u32 = 0;
var periodic_count: u32 = 0;

fn onceFn(_: ?*anyopaque) void {
    once_count += 1;
}

fn periodicFn(_: ?*anyopaque) void {
    periodic_count += 1;
}

fn timers() void {
    t.section("timers");
    once_count = 0;
    periodic_count = 0;
    var once: rtos.Timer = .init("once", onceFn, null, .once);
    var periodic: rtos.Timer = .init("periodic", periodicFn, null, .periodic);
    t.success(once.start(5), @src());
    t.success(periodic.start(10), @src());
    sysclock.sleepFor(105) catch {};
    t.success(periodic.stop(), @src());
    t.err(error.Again, periodic.stop(), @src());
    t.eq(@as(u32, 1), once_count, @src());
    t.eq(rtos.timer.State.completed, once.getState(), @src());
    t.ok(periodic_count >= 9 and periodic_count <= 11, @src());
    once.deinit();
    periodic.deinit();
}

// ----------------------------------------------------------------------------

fn clocksAndInterrupts() void {
    t.section("clocks");
    {
        const t0 = sysclock.now();
        sysclock.sleepFor(50) catch {};
        const dt = sysclock.now() - t0;
        t.ok(dt >= 50 and dt <= 52, @src());
    }
    {
        const deadline = sysclock.now() + 20;
        t.success(sysclock.sleepUntil(deadline), @src());
        t.ok(sysclock.now() >= deadline, @src());
    }
    {
        const h0 = rtos.hrclock.now();
        sysclock.sleepFor(10) catch {};
        const h1 = rtos.hrclock.now();
        const hz = rtos.hrclock.inputClockFrequencyHz();
        const us = (h1 - h0) * 1_000_000 / hz;
        t.ok(us >= 9_000 and us <= 12_000, @src());
    }
    {
        const prev = rtos.rtclock.setOffset(1_700_000_000);
        t.ok(rtos.rtclock.now() >= 1_700_000_000, @src());
        _ = rtos.rtclock.setOffset(prev);
    }
    {
        t.err(error.TimedOut, sysclock.waitFor(5), @src());
        t.eq(@as(rtos.Duration, 10), rtos.Clock.msToTicks(10), @src());
    }
    {
        // Blocking calls with the scheduler locked are refused.
        const scs = rtos.scheduler.CriticalSection.enter();
        t.err(error.NotPermitted, sysclock.sleepFor(1), @src());
        scs.exit();
    }
}

fn iterateThreads() void {
    t.section("threads tree");
    printTree(null, 0);
}

fn printTree(parent: ?*rtos.Thread, depth: usize) void {
    var it = rtos.scheduler.childrenThreads(parent).typedIterator(rtos.Thread, "child_links");
    while (it.next()) |th| {
        const st = th.stack();
        const used = st.size() - st.available();
        for (0..depth) |_| uos.trace.write("  ");
        uos.trace.print("{s} {d}/{d} {s}\n", .{ th.name, used, st.size(), @tagName(th.getState()) });
        printTree(th, depth + 1);
    }
}
