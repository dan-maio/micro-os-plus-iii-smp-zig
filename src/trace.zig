//! Trace output (`os::trace`).
//!
//! The C++ `trace::printf()` becomes `trace.print()`, a `std.fmt` call that
//! formats into an `std.Io.Writer` whose sink is the port's trace channel
//! (semihosting, a UART, ITM...). The whole message is written inside one
//! interrupts critical section, so on SMP the lines of two CPUs never mix.
//!
//! `trace.logFn` plugs the same channel into `std.log`:
//!
//! ```zig
//! pub const std_options: std.Options = .{ .logFn = uos.trace.logFn };
//! ```

const std = @import("std");
const port = @import("uos_port");
const interrupts = @import("rtos/interrupts.zig");

/// Write raw bytes to the trace channel.
pub fn write(bytes: []const u8) void {
    if (bytes.len == 0) return;
    const cs = interrupts.CriticalSection.enter();
    defer cs.exit();
    port.trace.write(bytes);
}

pub fn putchar(c: u8) void {
    write(&.{c});
}

/// The line followed by a new line, like `puts()`.
pub fn puts(s: []const u8) void {
    const cs = interrupts.CriticalSection.enter();
    defer cs.exit();
    port.trace.write(s);
    port.trace.write("\n");
}

/// Formatted output; the `trace::printf()` of the C++ edition.
pub fn print(comptime fmt: []const u8, args: anytype) void {
    var buffer: [128]u8 = undefined;
    var w: Writer = .init(&buffer);
    const cs = interrupts.CriticalSection.enter();
    defer cs.exit();
    w.interface.print(fmt, args) catch {};
    w.interface.flush() catch {};
}

/// An `std.Io.Writer` draining into the trace channel. It does not lock, so
/// wrap long sequences in a critical section, or use `print()`.
pub const Writer = struct {
    interface: std.Io.Writer,

    pub fn init(buffer: []u8) Writer {
        return .{ .interface = .{
            .vtable = &.{ .drain = drain },
            .buffer = buffer,
        } };
    }

    fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        port.trace.write(w.buffered());
        w.end = 0;

        var n: usize = 0;
        for (data[0 .. data.len - 1]) |bytes| {
            port.trace.write(bytes);
            n += bytes.len;
        }
        const pattern = data[data.len - 1];
        for (0..splat) |_| port.trace.write(pattern);
        return n + pattern.len * splat;
    }
};

/// An unbuffered trace writer, for code that wants an `*std.Io.Writer`.
pub fn writer() *std.Io.Writer {
    const S = struct {
        var w: Writer = .init(&.{});
    };
    return &S.w.interface;
}

/// Print the program arguments, like `trace::dump_args()`.
pub fn dumpArgs(args: []const [:0]const u8) void {
    print("main() argc={d} argv=", .{args.len});
    for (args) |arg| print("\"{s}\" ", .{arg});
    puts("");
}

/// `std.log` backend.
pub fn logFn(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    const prefix = "[" ++ comptime level.asText() ++ "] " ++
        (if (scope == .default) "" else "(" ++ @tagName(scope) ++ ") ");
    print(prefix ++ format ++ "\n", args);
}
