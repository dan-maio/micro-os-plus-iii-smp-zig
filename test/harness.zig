//! What every test application shares: the MicroZig wiring, the panic
//! handler, `std.log` on the trace channel, and a small check/verdict API.
//!
//! A test's root file:
//!
//! ```zig
//! const t = @import("uos_test");
//! pub const microzig_options = t.microzig_options;
//! pub const panic = t.panic;
//! pub const std_options = t.std_options;
//! pub const uos_options = t.options(.{});
//! comptime { t.exportStartup(); }
//! pub fn main() void { t.run(appMain); }
//! ```

const std = @import("std");
const microzig = @import("microzig");
const uos = @import("uos");
const board = @import("uos_board");

pub const microzig_options = uos.port.microzig_options;

pub const std_options: std.Options = .{
    .logFn = uos.trace.logFn,
    .log_level = .info,
    // Freestanding has no pages; std.Io's (unused) memory maps still name
    // the size.
    .page_size_min = 4096,
    .page_size_max = 4096,
};

pub fn exportStartup() void {
    microzig.export_startup();
}

/// The kernel options of a test: the board's CPU count, SMP when more than
/// one, and the overrides.
pub fn options(overrides: anytype) uos.Options {
    var o: uos.Options = .{
        .ncpu = board.ncpu,
        .smp = board.ncpu > 1,
        .main_stack_size_bytes = 8192,
        .idle_stack_size_bytes = 2048,
        .default_stack_size_bytes = 4096,
        .dynamic_memory_size_bytes = 64 * 1024,
    };
    inline for (@typeInfo(@TypeOf(overrides)).@"struct".field_names) |name| {
        @field(o, name) = @field(overrides, name);
    }
    return o;
}

/// The panic handler: trace the message and end the run with a FAIL.
pub const panic = std.debug.FullPanic(struct {
    fn panicFn(message: []const u8, first_trace_address: ?usize) noreturn {
        _ = first_trace_address;
        uos.trace.print("\n!! PANIC: {s}\n", .{message});
        uos.rtos.terminate(1);
    }
}.panicFn);

/// Run the test in the main thread, with an LED heartbeat (4 Hz) from a
/// periodic timer while it runs.
pub fn run(comptime app_main: anytype) noreturn {
    const Wrapper = struct {
        var heartbeat: uos.rtos.Timer = .init("heartbeat", blink, null, .periodic);

        fn blink(_: ?*anyopaque) void {
            board.led.toggle();
        }

        fn main() u8 {
            heartbeat.start(125) catch {};
            const ReturnType = @typeInfo(@TypeOf(app_main)).@"fn".return_type.?;
            const code: u8 = switch (@typeInfo(ReturnType)) {
                .void => blk: {
                    app_main();
                    break :blk 0;
                },
                .int => @intCast(app_main()),
                else => @compileError("test main must return void or an integer"),
            };
            heartbeat.stop() catch {};
            board.led.set(code != 0); // on: failed, off: passed
            return code;
        }
    };
    uos.rtos.run(Wrapper.main);
}

// ----------------------------------------------------------------------------
// Checks.

var failures: u32 = 0;
var checks: u32 = 0;

/// Record a check; a failed one is traced with its description.
pub fn expect(ok: bool, comptime what: []const u8, args: anytype) void {
    checks += 1;
    if (!ok) {
        failures += 1;
        uos.trace.print("FAILED: " ++ what ++ "\n", args);
    }
}

pub fn expectEqual(expected: anytype, actual: @TypeOf(expected), comptime what: []const u8) void {
    expect(std.meta.eql(expected, actual), what ++ " (expected {any}, got {any})", .{ expected, actual });
}

pub fn expectError(expected: anyerror, actual: anytype, comptime what: []const u8) void {
    if (actual) |_| {
        expect(false, what ++ " (expected error.{s}, got success)", .{@errorName(expected)});
    } else |err| {
        expect(err == expected, what ++ " (expected error.{s}, got error.{s})", .{ @errorName(expected), @errorName(err) });
    }
}

/// The verdict of the checks recorded so far.
pub fn passed() bool {
    return failures == 0;
}

/// Print the summary; the exit code of the run (0 = PASS).
pub fn summary(name: []const u8) u8 {
    uos.trace.print("\n{s}: {d} checks, {d} failed\n", .{ name, checks, failures });
    return if (failures == 0) 0 else 1;
}

/// Burn CPU for about `ms` milliseconds without sleeping.
pub fn busyWaitMs(ms: u32) void {
    const loops = @as(u64, ms) * (board.cpuFrequencyHz() / 4000);
    var i: u64 = 0;
    while (i < loops) : (i += 1) asm volatile ("nop");
}
