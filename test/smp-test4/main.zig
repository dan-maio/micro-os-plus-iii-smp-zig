//! smp-test4 -- load balancing without affinity (the C++
//! test/luckfox-lyra/smp_test4).
//!
//! Eight workers with no affinity burn some CPU and yield, counting on which
//! CPU each round ran; the reporter (CPU 0) prints the histogram every
//! second. After ten seconds: PASS when every secondary joined and every
//! CPU ran some worker.
//!
//! Differences from C++: the kernel prints its startup banner and creates
//! the secondary idle threads; the reporter's affinity is given at creation.

const std = @import("std");
const uos = @import("uos");
const board = @import("board");
const rtos = uos.rtos;
const uart = board.uart;
const led = board.led;
const sysclock = rtos.sysclock;
const ncpu = uos.config.ncpu;

pub const uos_options = board.options(3);

const nwork = 8;
// Serialises the console between the reporter and the RESULT line.
var g_con: rtos.Mutex = .{ .name = "con" };
var hist: [nwork][ncpu]std.atomic.Value(u32) = @splat(@splat(.init(0)));

fn worker(arg: ?*anyopaque) ?*anyopaque {
    const id: usize = @intFromPtr(arg);
    while (true) {
        const c = uos.port.scheduler.cpuId();
        if (c < ncpu) _ = hist[id][c].fetchAdd(1, .monotonic);
        // Burn a little CPU so the scheduler has something to migrate.
        var x: u32 = 0;
        var i: u32 = 0;
        while (i < 200000) : (i += 1) @as(*volatile u32, &x).* = @as(*volatile u32, &x).* +% i;
        rtos.this_thread.yield();
    }
}

fn reporter(_: ?*anyopaque) ?*anyopaque {
    var s = false;
    while (true) {
        s = !s;
        led.set(s);
        g_con.lock() catch {};
        for (0..nwork) |w| {
            var buf: [256]u8 = undefined;
            var wr: std.Io.Writer = .fixed(&buf);
            wr.print("w{d} [", .{w}) catch {};
            for (0..ncpu) |c| wr.print(" c{d}={d}", .{ c, hist[w][c].load(.monotonic) }) catch {};
            wr.writeAll(" ]\n") catch {};
            uart.puts(wr.buffered());
        }
        uart.print("-- reporter on c{d} t={d}ms --\n", .{ uos.port.scheduler.cpuId(), @as(u32, @truncate(sysclock.now())) });
        g_con.unlock() catch {};
        sysclock.sleepFor(1000) catch {};
    }
}

var wstk: [nwork][4096]uos.port.StackElement = undefined;
var rstk: [4096]uos.port.StackElement = undefined;
var workers: [nwork]*rtos.Thread = undefined;
var wn: [nwork][2:0]u8 = undefined;
var t_rep: rtos.Thread = undefined;

pub fn main() void {
    uart.init();
    led.init();
    uart.puts("\n\n+== " ++ board.banner_short ++ " µOS++ SMP TEST 4 : no-affinity load balancing ==+\n\n");
    rtos.run(osMain);
}

fn osMain() void {
    _ = rtos.interrupts.UncriticalSection.enter();
    board.smp.startSecondaryCores();
    const waited = board.smp.waitSecondaries(3000);
    uart.print("join: {s} ({d}ms)\n", .{ board.smp.joinSummary(), waited });

    const gpa = uos.memory.allocator();
    for (0..nwork) |w| {
        wn[w] = .{ 'w', '0' + @as(u8, @intCast(w)) };
        // No affinity: let the scheduler balance the load.
        workers[w] = rtos.Thread.create(gpa, &wn[w], worker, @ptrFromInt(w), .{ .stack = &wstk[w] }) catch unreachable;
    }
    // The console on CPU 0, for tidy output.
    t_rep.init("reporter", reporter, null, .{ .stack = &rstk, .cpu_affinity = 1 << 0 }, gpa) catch unreachable;

    // Exactly 10 one-second beats, then check every CPU ran some worker.
    for (0..10) |_| sysclock.sleepFor(1000) catch {};
    var ok = board.smp.secondariesJoined();
    for (0..ncpu) |c| {
        if (!ok) break;
        var tot: u32 = 0;
        for (0..nwork) |w| tot += hist[w][c].load(.monotonic);
        if (tot == 0) ok = false;
    }
    // Under the console mutex, so the marker is never interleaved with a
    // reporter line.
    g_con.lock() catch {};
    uart.print("\nRESULT: {s}\n", .{if (ok) "PASS" else "FAIL"});
    g_con.unlock() catch {};
    if (ok) board.hw_result.ok() else board.hw_result.fail();
}
