//! trace-stdout -- the trace on the standard output (the C++
//! test/trace-stdout): one line through the Zig trace API (C++: os::trace),
//! one through the C one (trace_puts(), in trace-c.c). The RTOS is not
//! started; the exit code is 0.
//!
//! Difference from C++: the first line says "Zig Message" (C++: "C++
//! Message"), as it comes from the Zig API.

const uos = @import("uos");

pub const uos_options: uos.Options = .{ .c_api = true };
pub const uos_port_options: uos.port.Options = .{ .trace_stderr = false };

extern fn trace_c_message() void;

pub fn main() void {
    uos.trace.puts("Zig Message");
    trace_c_message();
}
