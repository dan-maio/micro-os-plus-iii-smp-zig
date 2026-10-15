//! smp-rtos-apis -- the SMP leg of rtos-apis (the C++
//! test/native/smp-rtos-apis): the rtos-apis sequence once per CPU, one CPU
//! at a time, each in a driver thread pinned to that CPU; FAIL when a
//! sequence fails or its driver was found on another CPU.
//!
//! The sub-tests are rtos-apis' own (test/rtos-apis, through the
//! `rtos_apis` module, and test-c-api.c). As in C++, `errno` (the host
//! libc's, which the C part may set) is printed after each one.
//!
//! Differences from C++: the kernel prints its startup banner and creates
//! the secondary idle threads; "Built with Zig" instead of the compiler.

const std = @import("std");
const builtin = @import("builtin");
const uos = @import("uos");
const board = @import("board");
const parts = @import("rtos_apis");
const rtos = uos.rtos;
const ncpu = uos.config.ncpu;

pub const uos_options: uos.Options = blk: {
    var o = board.options(4);
    // The statistics switches of rtos-apis' os-app-config.h.
    o.statistics_context_switches = true;
    o.statistics_cpu_cycles = true;
    o.c_api = true;
    break :blk o;
};

extern fn test_c_api() c_int;

const printf = board.uart.print;

fn cpuId() u32 {
    return uos.port.scheduler.cpuId();
}

fn errno() *c_int {
    return std.c._errno();
}

const Run = struct {
    core: u32,
    ret: i32,
    off_core: u32, // sub-tests after which the driver was elsewhere
};

var runs: [ncpu]Run = undefined;

fn checkCore(r: *Run, after: []const u8) void {
    const now = cpuId();
    if (now != r.core) {
        r.off_core += 1;
        printf("[core {d}] driver found on core {d} after {s}\n", .{ r.core, now, after });
    }
}

var rtos_io: uos.Io = undefined;

/// Upstream's os_main sequence, in order and in its errno idiom.
fn driver(arg: ?*anyopaque) ?*anyopaque {
    const r: *Run = @ptrCast(@alignCast(arg.?));
    printf("\n==== core {d}: driver started on core {d} ====\n", .{ r.core, cpuId() });
    checkCore(r, "start");
    var ret: i32 = 0;
    errno().* = 0;
    if (ret == 0) {
        ret = parts.cpp_api.run();
        printf("errno={d}\n", .{errno().*});
        errno().* = 0;
        checkCore(r, "test_cpp_api");
    }
    if (ret == 0) {
        ret = test_c_api();
        printf("errno={d}\n", .{errno().*});
        errno().* = 0;
        checkCore(r, "test_c_api");
    }
    if (ret == 0) {
        ret = parts.iso_api.run(rtos_io.io(), false);
        printf("errno={d}\n", .{errno().*});
        errno().* = 0;
        checkCore(r, "test_iso_api");
    }
    if (ret == 0) {
        ret = parts.posix_io_api.run(false);
        printf("errno={d}\n", .{errno().*});
        errno().* = 0;
        checkCore(r, "test_posix_io_api");
    }
    r.ret = ret;
    printf("==== core {d}: {s} ====\n", .{ r.core, if (ret == 0) "passed" else "FAILED" });
    return null;
}

pub fn main() void {
    board.uart.init();
    board.uart.print("\n\n+== " ++ board.banner_short ++ " µOS++ SMP RTOS APIS : {d} cores ==+\n\n", .{ncpu});
    rtos.run(osMain);
}

fn osMain() void {
    _ = rtos.interrupts.UncriticalSection.enter();
    printf("os_main on core {d}\n", .{cpuId()});
    board.smp.startSecondaryCores();
    const waited = board.smp.waitSecondaries(3000);
    printf("join: {s} ({d}ms)\n", .{ board.smp.joinSummary(), waited });
    if (!board.smp.secondariesJoined()) {
        printf("\nRESULT: FAIL (secondaries did not join)\n", .{});
        board.hw_result.fail();
    }

    printf("\nµOS++ RTOS simple APIs test, once per core, {d} cores\n", .{ncpu});
    printf("Built with Zig {s}\n", .{builtin.zig_version_string});

    rtos_io = .init(uos.memory.allocator());

    // One core at a time: the API tests use static objects and fixed names,
    // so two sequences at once would test the tests, not the kernel.
    for (0..ncpu) |c| {
        runs[c] = .{ .core = @intCast(c), .ret = -1, .off_core = 0 };
        var drv: rtos.Thread = undefined;
        drv.init("drv", driver, &runs[c], .{
            .cpu_affinity = @as(u32, 1) << @intCast(c),
            .stack_size_bytes = 4 * 64 * 1024,
        }, uos.memory.allocator()) catch unreachable;
        _ = drv.join() catch {};
        drv.deinit();
    }

    var ok = true;
    printf("\n==== per-core checks (OS_NCPU={d}) ====\n", .{ncpu});
    for (0..ncpu) |c| {
        const pass = runs[c].ret == 0 and runs[c].off_core == 0;
        printf("core {d}: sequence {s}, off-core {d}\n", .{ c, if (runs[c].ret == 0) "passed" else "FAILED", runs[c].off_core });
        ok = ok and pass;
    }
    printf("done\n", .{});
    printf("\nRESULT: {s}\n", .{if (ok) "PASS" else "FAIL"});
    if (ok) board.hw_result.ok();
    board.hw_result.fail();
}
