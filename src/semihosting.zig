//! ARM semihosting, the trace and verdict channel of the test boards.
//!
//! OpenOCD services the `BKPT 0xAB` requests (`arm semihosting enable` in
//! the runners). Without a debugger a BKPT escalates to a HardFault, so on
//! ARMv7-M/v8-M every request first checks DHCSR.C_DEBUGEN and becomes a
//! no-op when nothing is attached.

const arch = @import("arch.zig");

pub const SYS_WRITEC = 0x03;
pub const SYS_WRITE0 = 0x04;
pub const SYS_EXIT = 0x18;

pub const ADP_Stopped_ApplicationExit = 0x20026;
pub const ADP_Stopped_RunTimeErrorUnknown = 0x20023;

inline fn call(op: u32, arg: usize) usize {
    return asm volatile ("bkpt 0xAB"
        : [ret] "={r0}" (-> usize),
        : [op] "{r0}" (op),
          [arg] "{r1}" (arg),
        : .{ .memory = true });
}

/// Write bytes to the debugger console (SYS_WRITE0, in NUL terminated
/// chunks copied to the stack).
pub fn write(bytes: []const u8) void {
    if (!arch.debuggerAttached()) return;
    var chunk: [64]u8 = undefined;
    var rest = bytes;
    while (rest.len > 0) {
        const n = @min(rest.len, chunk.len - 1);
        @memcpy(chunk[0..n], rest[0..n]);
        chunk[n] = 0;
        _ = call(SYS_WRITE0, @intFromPtr(&chunk));
        rest = rest[n..];
    }
}

/// End the session with a verdict (SYS_EXIT). Waits for a debugger first on
/// the profiles that can tell, like the C++ `_Exit()`.
pub fn exit(code: u8) noreturn {
    if (!arch.is_armv6m) {
        // Without a debugger the BKPT would fault; wait to be attached.
        while (!arch.debuggerAttached()) {}
    }
    _ = call(SYS_EXIT, if (code == 0) ADP_Stopped_ApplicationExit else ADP_Stopped_RunTimeErrorUnknown);
    while (true) arch.wfi();
}
