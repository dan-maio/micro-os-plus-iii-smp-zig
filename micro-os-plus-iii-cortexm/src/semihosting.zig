//! ARM semihosting on Cortex-M: the trap of the kernel's `uos.semihosting`
//! (every operation lives there), the trace and verdict channel of the test
//! boards.
//!
//! OpenOCD services the `BKPT 0xAB` requests (`arm semihosting enable` in
//! the runners). Without a debugger a BKPT escalates to a HardFault, so on
//! ARMv7-M/v8-M every request first checks DHCSR.C_DEBUGEN (`attached()`)
//! and becomes a no-op when nothing is attached. SYS_EXIT takes the reason
//! in r1, as the C++ `report_exception()`.

const std = @import("std");
const uos = @import("uos");
const arch = @import("arch.zig");

/// The trap (the C++ `call_host()`).
pub fn call(op: usize, arg: usize) usize {
    return asm volatile ("bkpt 0xAB"
        : [ret] "={r0}" (-> usize),
        : [op] "{r0}" (op),
          [arg] "{r1}" (arg),
        : .{ .memory = true });
}

/// SYS_EXIT gets the reason in r1.
pub const exit_by_block = false;

/// Whether a debugger would service a request.
pub fn attached() bool {
    return arch.debuggerAttached();
}

/// Whether a "RESULT:" line went to the debugger (the trace or a test's
/// own verdict): `terminate()` prints one only when none did.
pub var verdict_written: bool = false;

/// Bytes to the debugger console (SYS_WRITE0, in NUL-terminated chunks).
pub fn write(bytes: []const u8) void {
    if (std.mem.indexOf(u8, bytes, "RESULT:") != null) verdict_written = true;
    uos.semihosting.writeConsole(bytes);
}

/// End the session with a verdict (SYS_EXIT, the C++ `os_terminate()`).
/// Waits for a debugger first on the profiles that can tell.
pub fn exit(code: u8) noreturn {
    if (!arch.is_armv6m) {
        // Without a debugger the BKPT would fault; wait to be attached.
        while (!arch.debuggerAttached()) {}
    }
    uos.semihosting.exit(code);
}
