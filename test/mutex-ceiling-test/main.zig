//! mutex-ceiling-test -- a protect-protocol lock refused with EINVAL leaves
//! nothing behind (the C++ test/native/mutex-ceiling-test).
//!
//! A thread whose priority is above a protect mutex's ceiling must get
//! EINVAL from lock() and must not own the mutex. Checks: the refused lock
//! is EINVAL; after the refused thread exits and is destroyed, a thread at
//! the ceiling locks and unlocks normally, and so does main.
//!
//! The results are printed as their errno values (`res=`), as in C++.
//! Difference from C++: the kernel prints its startup banner.

const std = @import("std");
const uos = @import("uos");
const board = @import("board");
const rtos = uos.rtos;
const uart = board.uart;

pub const uos_options = board.options(4);

var g_mx: *rtos.Mutex = undefined;
var g_high_res: u32 = 0;
var g_low_lock: u32 = 0;
var g_low_unlock: u32 = 0;
var g_failures: u32 = 0;

fn res(r: rtos.Error!void) u32 {
    r catch |err| return @intCast(rtos.errno(err));
    return 0;
}

const einval: u32 = @intCast(rtos.errno(error.InvalidArgument));

fn check(cond: bool, what: []const u8, r: u32) void {
    uart.print("  {s:<48} res={d:>3}  {s}\n", .{ what, r, if (cond) "ok" else "FAIL" });
    if (!cond) g_failures += 1;
}

fn highFunc(_: ?*anyopaque) ?*anyopaque {
    g_high_res = res(g_mx.lock());
    return null;
}

fn lowFunc(_: ?*anyopaque) ?*anyopaque {
    g_low_lock = res(g_mx.lock());
    g_low_unlock = res(g_mx.unlock());
    return null;
}

var mx: rtos.Mutex = undefined;

pub fn main() void {
    uart.init();
    rtos.run(osMain);
}

fn osMain() void {
    uart.puts("\nmutex-ceiling-test: a refused protect lock leaves nothing\n");

    mx.init("mx", .{
        .protocol = .protect,
        .robustness = .robust,
        .priority_ceiling = rtos.priority.normal,
    }) catch unreachable;
    g_mx = &mx;

    const gpa = uos.memory.allocator();

    // Above the ceiling: lock() must be refused.
    const high = rtos.Thread.create(gpa, "high", highFunc, null, .{ .priority = rtos.priority.above_normal }) catch unreachable;
    _ = high.join() catch {};
    high.destroy();
    check(g_high_res == einval, "lock above the ceiling is EINVAL", g_high_res);

    // At the ceiling, from a fresh thread and from main: plain lock/unlock.
    const low = rtos.Thread.create(gpa, "low", lowFunc, null, .{ .priority = rtos.priority.normal }) catch unreachable;
    _ = low.join() catch {};
    low.destroy();
    check(g_low_lock == 0, "lock at the ceiling after it (thread)", g_low_lock);
    check(g_low_unlock == 0, "unlock (thread)", g_low_unlock);

    var r = res(mx.lock());
    check(r == 0, "lock at the ceiling (main)", r);
    r = res(mx.unlock());
    check(r == 0, "unlock (main)", r);

    const ok = g_failures == 0;
    uart.puts(if (ok) "RESULT: PASS\n" else "RESULT: FAIL\n");
    if (ok) board.hw_result.ok() else board.hw_result.fail();
}
