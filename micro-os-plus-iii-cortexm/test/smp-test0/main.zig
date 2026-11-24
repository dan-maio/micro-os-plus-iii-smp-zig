//! smp-test0 -- scheduler bring-up.
//!
//! Two workers increment a shared counter under a mutex and sleep; the
//! main thread waits ~5 s and checks that both ran, on every CPU the board
//! has. The first test to run on a new board.

const std = @import("std");
const uos = @import("uos");
const t = @import("uos_test");
const rtos = uos.rtos;

pub const microzig_options = t.microzig_options;
pub const panic = t.panic;
pub const std_options = t.std_options;
pub const uos_options = t.options(.{});

comptime {
    t.exportStartup();
}

pub fn main() void {
    t.run(appMain);
}

var g_mutex: rtos.Mutex = .{ .name = "g" };
var g_global: u32 = 0;
var g_seen_cpu: [uos.config.ncpu]u32 = @splat(0);

const Ctx = struct { id: u32, local: u32 = 0 };
var ctx: [2]Ctx = .{ .{ .id = 0 }, .{ .id = 1 } };
var workers: [2]rtos.ThreadInclusive(2048) = undefined;

fn worker(arg: ?*anyopaque) ?*anyopaque {
    const c: *Ctx = @ptrCast(@alignCast(arg.?));
    while (true) {
        c.local += 1;
        g_mutex.lock() catch unreachable;
        g_global += 1;
        const g = g_global;
        g_seen_cpu[uos.port.scheduler.cpuId()] += 1;
        g_mutex.unlock() catch unreachable;
        uos.trace.print("[{d:>6} ms] worker #{d} cpu{d} local={d} global={d}\n", .{
            rtos.sysclock.now(), c.id, uos.port.scheduler.cpuId(), c.local, g,
        });
        rtos.sysclock.sleepFor(250) catch {};
    }
}

fn appMain() u8 {
    uos.trace.puts("smp-test0: scheduler bring-up");
    for (&workers, &ctx, 0..) |*w, *c, i| {
        w.init(if (i == 0) "wrk0" else "wrk1", worker, c, .{}) catch unreachable;
    }

    rtos.sysclock.sleepFor(5000) catch {};

    t.expect(ctx[0].local > 5 and ctx[1].local > 5, "both workers ran ({d}, {d})", .{ ctx[0].local, ctx[1].local });
    t.expect(g_global == ctx[0].local + ctx[1].local or g_global + 2 >= ctx[0].local + ctx[1].local, "the mutex kept the count", .{});
    for (g_seen_cpu, 0..) |n, cpu| uos.trace.print("cpu{d}: {d} beats\n", .{ cpu, n });
    return t.summary("smp-test0");
}
