//! rtos-apis -- the µOS++ APIs (the C++ harness suite tests/sources/rtos-apis).
//!
//! The Zig port of its main.cpp: the parts run in the same order and the
//! first one that fails stops the run. Of the C++ parts:
//!
//!   test_cpp_api       ported   (test-cpp-api.zig, the Zig RTOS API)
//!   test_c_api         not yet  (the Zig kernel has no C API yet)
//!   test_iso_api       ported   (test-iso-api.zig, on std.Io / uos.Io)
//!   test_posix_io_api  ported   (test-posix-io-api.zig, uos.io.devices)
//!   test_chan_fatfs    excluded on these boards (OS_EXCLUDE_RTOS_APIS_FATFS)
//!
//! As the C++ pico2 build of the harness suites, the kernel runs single-core
//! with the suite's os-app-config.h (BASEPRI 4, a 4000-byte main stack). The
//! verdict is the exit code (0 = PASS).

const std = @import("std");
const builtin = @import("builtin");
const uos = @import("uos");
const t = @import("uos_test");

const cpp_api = @import("test-cpp-api.zig");
const iso_api = @import("test-iso-api.zig");
const posix_io_api = @import("test-posix-io-api.zig");

pub const microzig_options = t.microzig_options;
pub const panic = t.panic;
pub const std_options = t.std_options;

/// tests/sources/rtos-apis/include/cmsis-plus/os-app-config.h, single-core;
/// the heap is the boards' (the suite asks 512 KB, more than the RAM).
///
/// One deviation: the main stack is 8 KB instead of the suite's 4000 bytes.
/// The C++ API part keeps many objects as locals (threads, queues, pools),
/// and the Zig objects are larger: its frame is 2564 bytes plus 1548 for
/// osMain, which overflowed 4000 bytes into a neighbouring thread object
/// (measured: a corrupted thread function pointer, UsageFault).
pub const uos_options: uos.Options = .{
    .ncpu = 1,
    .smp = false,
    .systick_frequency_hz = 1000,
    .critical_section_interrupt_priority = 4,
    .main_stack_size_bytes = 8192,
    .default_stack_size_bytes = 2048,
    .idle_stack_size_bytes = 2048,
    .dynamic_memory_size_bytes = 32 * 1024,
};

comptime {
    t.exportStartup();
}

pub fn main() void {
    uos.rtos.run(osMain);
}

const printf = uos.trace.print;

fn osMain() u8 {
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

    // test_c_api: not ported yet (the Zig kernel has no C API).

    if (ret == 0) {
        ret = iso_api.run(io, false);
        printf("ret={d}\n", .{ret});
    }

    if (ret == 0) {
        ret = posix_io_api.run(false);
        printf("ret={d}\n", .{ret});
    }

    printf("done\n", .{});
    return if (ret == 0) 0 else 1;
}
