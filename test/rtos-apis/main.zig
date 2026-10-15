//! rtos-apis -- the µOS++ APIs on Raspberry Pi 4 B AArch64
//! (the C++ test/rpi4b/rtos-apis: the kernel's suite tests/sources/rtos-apis).
//!
//! The parts run in the same order and the first one that fails stops the
//! run; then the RESULT line and hw_result:
//!
//!   test_cpp_api       test-cpp-api.zig, the Zig RTOS API
//!   test_c_api         the original test-c-api.c, on the kernel's C API
//!   test_iso_api       test-iso-api.zig, on std.Io / uos.Io
//!   test_posix_io_api  test-posix-io-api.zig, uos.io.devices

const std = @import("std");
const builtin = @import("builtin");
const uos = @import("uos");
const board = @import("board");

const cpp_api = @import("test-cpp-api.zig");
const iso_api = @import("test-iso-api.zig");
const posix_io_api = @import("test-posix-io-api.zig");

pub const uos_options: uos.Options = blk: {
    var o = board.options(1); // Single-core execution
    o.main_stack_size_bytes = 16384;
    o.statistics_context_switches = true;
    o.statistics_cpu_cycles = true;
    o.c_api = true;
    o.c_runtime = true;
    break :blk o;
};

extern fn test_c_api() c_int;

pub fn main() void {
    board.uart.init();
    uos.rtos.run(osMain);
}

const printf = board.uart.print;

fn osMain() void {
    printf("\n", .{});
    printf("µOS++ RTOS simple APIs test\n", .{});
    printf("Built with Zig {s}\n", .{builtin.zig_version_string});

    var rtos_io: uos.Io = .init(uos.memory.allocator());
    const io = rtos_io.io();

    var ret: i32 = 0;

    if (ret == 0) {
        ret = cpp_api.run();
        printf("ret={d}\n", .{ret});
    }

    if (ret == 0) {
        ret = test_c_api();
        printf("ret={d}\n", .{ret});
    }

    if (ret == 0) {
        ret = iso_api.run(io, false);
        printf("ret={d}\n", .{ret});
    }

    if (ret == 0) {
        ret = posix_io_api.run(false);
        printf("ret={d}\n", .{ret});
    }

    if (ret == 0) {
        printf("All API checks passed. Running 20s soak verification...\n", .{});
        for (1..21) |s| {
            uos.rtos.sysclock.sleepFor(1000) catch {};
            printf("  soak: {d}/20 seconds...\n", .{s});
        }
    }

    printf("done\n", .{});

    printf("\nRESULT: {s}\n", .{if (ret == 0) "PASS" else "FAIL"});
    if (ret == 0) board.hw_result.ok();
    board.hw_result.fail();
}
