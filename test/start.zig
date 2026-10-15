//! The root of every test image: the test's own `main.zig` is the `app`
//! module, so the test sources stay those of the POSIX port, and this file
//! adds what a freestanding image needs: `std.log` on the trace channel and
//! a panic handler that reports and ends the run with a FAIL.
//!
//! The kernel reads `uos_options`, the port calls `main()` (and, when the
//! test has one, `uos_external_irq()`) through the root.

const std = @import("std");
const uos = @import("uos");
const app = @import("app");

pub const uos_options = app.uos_options;

pub const std_options: std.Options = .{
    .logFn = uos.trace.logFn,
    .log_level = .info,
    // Freestanding has no pages; std.Io's (unused) memory maps still name
    // the size.
    .page_size_min = 4096,
    .page_size_max = 4096,
};

pub const panic = std.debug.FullPanic(struct {
    fn panicFn(message: []const u8, first_trace_address: ?usize) noreturn {
        uos.trace.print("\n!! PANIC: {s} (cpu{d}, at 0x{x})\n", .{ message, uos.port.scheduler.cpuId(), first_trace_address orelse @returnAddress() });
        // The frame-pointer chain ({fp, lr} pairs): the call sites.
        var fp = @frameAddress();
        var depth: u32 = 0;
        while (depth < 8 and fp >= 0x0020_0000 and fp < 0x0800_0000 and fp & 3 == 0) : (depth += 1) {
            const lr = @as(*const usize, @ptrFromInt(fp + 4)).*;
            uos.trace.print("   from 0x{x}\n", .{lr});
            fp = @as(*const usize, @ptrFromInt(fp)).*;
        }
        uos.rtos.terminate(1);
    }
}.panicFn);

pub fn main() void {
    app.main();
}

/// A GIC interrupt other than the tick and the IPI (`port_external_irq_handler()`).
pub fn uos_external_irq(iar: u32) void {
    if (@hasDecl(app, "uos_external_irq")) app.uos_external_irq(iar);
}

// Freestanding has no std.start: the port's exports (the entry from
// startup.S, the vector targets) are what reaches main().
comptime {
    _ = uos.port;
}
