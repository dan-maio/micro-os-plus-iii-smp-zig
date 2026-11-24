//! The root module for every test image on freestanding AArch64.
//! Wires up `std.log`, `panic`, and forwards `main()` to the test's `app.main()`.

const std = @import("std");
const uos = @import("uos");
const app = @import("app");

pub const uos_options = app.uos_options;

pub const std_options: std.Options = .{
    .logFn = uos.trace.logFn,
    .log_level = .info,
    .page_size_min = 4096,
    .page_size_max = 4096,
};

pub const panic = std.debug.FullPanic(struct {
    fn panicFn(message: []const u8, first_trace_address: ?usize) noreturn {
        uos.trace.print(
            "\n!! PANIC: {s} (cpu{d}, at 0x{x})\n",
            .{ message, uos.port.scheduler.cpuId(), first_trace_address orelse @returnAddress() },
        );

        // Frame pointer unwinding on AArch64 (x29 frame pointer, x30 return address)
        var fp = @frameAddress();
        var depth: u32 = 0;
        while (depth < 12 and fp >= 0x0008_0000 and fp < 0x3B40_0000 and fp & 15 == 0) : (depth += 1) {
            const lr = @as(*const usize, @ptrFromInt(fp + 8)).*;
            uos.trace.print("   from 0x{x}\n", .{lr});
            fp = @as(*const usize, @ptrFromInt(fp)).*;
        }
        uos.rtos.terminate(1);
    }
}.panicFn);

pub fn main() void {
    app.main();
}

pub fn uos_external_irq(iar: u32) void {
    if (@hasDecl(app, "uos_external_irq")) app.uos_external_irq(iar);
}

comptime {
    _ = uos.port;
}
