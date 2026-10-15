//! rtos-apis -- the µOS++ APIs, on the host (the C++ test/native/rtos-apis:
//! the kernel's suite tests/sources/rtos-apis, as the native board carries
//! it).
//!
//! The parts run in the same order and the first one that fails stops the
//! run; then the RESULT line and `hw_result`, as the native main.cpp:
//!
//!   test_cpp_api       test-cpp-api.zig, the Zig RTOS API
//!   test_c_api         the original test-c-api.c, on the kernel's C API
//!   test_iso_api       test-iso-api.zig, on std.Io / uos.Io
//!   test_posix_io_api  test-posix-io-api.zig, uos.io.devices
//!   test_chan_fatfs    off, as in the native build (not carried there)
//!
//! The sub-tests are the Cortex-M port's, unchanged: the C++ native tree
//! carries the suite's sources unchanged too. As the native build: one CPU,
//! the suite's statistics switches, the port's stacks (the main one 4 x the
//! default), the board's free store; C code on the host libc.

const std = @import("std");
const builtin = @import("builtin");
const uos = @import("uos");
const board = @import("board");

const cpp_api = @import("test-cpp-api.zig");
const iso_api = @import("test-iso-api.zig");
const posix_io_api = @import("test-posix-io-api.zig");

pub const uos_options: uos.Options = blk: {
    var o = board.options(1); // board_test_ncpu: 1
    o.main_stack_size_bytes = 4 * o.default_stack_size_bytes;
    o.statistics_context_switches = true;
    o.statistics_cpu_cycles = true;
    o.c_api = true;
    break :blk o;
};

extern fn test_c_api() c_int;

pub fn main() void {
    uos.rtos.run(osMain);
}

const printf = uos.trace.print;

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

    printf("done\n", .{});

    printf("\nRESULT: {s}\n", .{if (ret == 0) "PASS" else "FAIL"});
    if (ret == 0) board.hw_result.ok();
    board.hw_result.fail();
}
