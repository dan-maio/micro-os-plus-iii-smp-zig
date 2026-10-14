//! mutex-stress: ten threads take one mutex at random intervals, with busy
//! waits and sleeps inside and outside; a periodic thread prints the
//! distribution. Beyond the C++ test, every critical region checks that it
//! is alone (on SMP too) and the run fails if a thread starves.

const std = @import("std");
const uos = @import("uos");
const t = @import("check.zig");
const rtos = uos.rtos;

const n_threads = 10;

var mx: rtos.Mutex = .{ .name = "mx" };
var inside: u32 = 0;
var overlaps: u32 = 0;

const Worker = struct {
    th: rtos.ThreadInclusive(1536) = undefined,
    count: u32 = 0,
    rng: std.Random.DefaultPrng = .init(0),
    name_buf: [2:0]u8 = "t0".*,
};

var workers: [n_threads]Worker = @splat(.{});

/// Spin for about `us` microseconds on the high resolution clock.
fn busyWait(us: u32) void {
    const hz = rtos.hrclock.inputClockFrequencyHz();
    const start = rtos.hrclock.now();
    const cycles = @as(u64, us) * hz / 1_000_000;
    while (rtos.hrclock.now() - start < cycles) {}
}

fn workerMain(arg: ?*anyopaque) ?*anyopaque {
    const w: *Worker = @ptrCast(@alignCast(arg.?));
    const r = w.rng.random();
    const me = rtos.this_thread.thread();
    while (!me.isInterrupted()) {
        busyWait(r.intRangeLessThan(u32, 10, 90));
        rtos.sysclock.sleepFor(r.intRangeLessThan(u32, 10, 200)) catch break;
        if (me.isInterrupted()) break;
        mx.lock() catch break;
        {
            if (@atomicRmw(u32, &inside, .Add, 1, .acq_rel) != 0) overlaps += 1;
            busyWait(r.intRangeLessThan(u32, 1, 9));
            rtos.sysclock.sleepFor(r.intRangeLessThan(u32, 1, 20)) catch {};
            w.count += 1;
            _ = @atomicRmw(u32, &inside, .Sub, 1, .acq_rel);
        }
        mx.unlock() catch {};
    }
    return null;
}

/// Run for `seconds`, printing every 5 s.
pub fn run(seconds: u32) u32 {
    t.reset();
    uos.trace.print("\nmutex-stress - {d} threads, {d} s\n", .{ n_threads, seconds });

    for (&workers, 0..) |*w, i| {
        w.* = .{};
        w.name_buf[1] = '0' + @as(u8, @intCast(i));
        w.rng = .init(0x5EED + i);
        w.th.init(&w.name_buf, workerMain, w, .{}) catch unreachable;
    }

    var elapsed: u32 = 0;
    while (elapsed < seconds) {
        rtos.sysclock.sleepFor(5000) catch {};
        elapsed += 5;
        var sum: u32 = 0;
        var min: u32 = std.math.maxInt(u32);
        var max: u32 = 0;
        {
            const scs = rtos.scheduler.CriticalSection.enter();
            defer scs.exit();
            for (&workers) |*w| {
                sum += w.count;
                min = @min(min, w.count);
                max = @max(max, w.count);
            }
        }
        const avg = (sum + n_threads / 2) / n_threads;
        uos.trace.print("[{d:>3}s] sum={d} avg={d} min={d} max={d}\n", .{ elapsed, sum, avg, min, max });
    }

    for (&workers) |*w| _ = w.th.thread.interrupt(true);
    for (&workers) |*w| {
        _ = w.th.thread.join() catch {};
        w.th.deinit();
    }

    var min: u32 = std.math.maxInt(u32);
    for (&workers) |*w| min = @min(min, w.count);
    t.eq(@as(u32, 0), overlaps, @src());
    t.expect(min > 0, @src(), "a thread starved", .{});
    t.ok(mx.getOwner() == null, @src());
    return t.summary("mutex-stress");
}
