//! cmsis-os-validator -- the Arm CMSIS-RTOS v1 validator, on the host (the
//! C++ native build of the kernel's suite tests/sources/cmsis-os-validator).
//!
//! The validator's C sources (the arm-cmsis-rtos-validator xPack, with its
//! µOS++ main.c) are compiled as they are, over the kernel's CMSIS-RTOS v1
//! layer and C API, on the host libc. On a host, main.c raises the test
//! "interrupt" with SIGUSR1 (NVIC_SetPendingIRQ() is kill(getpid(),
//! SIGUSR1)) and counts it in `signal_nesting`, which the port exports, so
//! the RTOS sees handler mode.
//!
//! As the C++ native build: one CPU, TRACE (the validator prints with
//! trace_printf()), the port's stacks (main 4 x the default). The verdict
//! is os_main()'s return code.

const uos = @import("uos");
const board = @import("board");

pub const uos_options: uos.Options = blk: {
    var o = board.options(1);
    o.main_stack_size_bytes = 4 * o.default_stack_size_bytes;
    o.c_api = true;
    o.cmsis_os = true;
    break :blk o;
};

extern fn os_main(argc: c_int, argv: ?[*]?[*:0]u8) c_int;

pub fn main() void {
    uos.rtos.run(osMain);
}

fn osMain() void {
    const code = os_main(0, null);
    uos.trace.print("\nRESULT: {s}\n", .{if (code == 0) "PASS" else "FAIL"});
    if (code == 0) board.hw_result.ok();
    board.hw_result.fail();
}
