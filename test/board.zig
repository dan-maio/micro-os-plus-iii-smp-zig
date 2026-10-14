//! The `native` test board (the C++ test/boards/native/): what the test
//! applications use besides the kernel.
//!
//!   uart        the console: the standard output (`uart.hpp`)
//!   led         the user LED, printed when it changes (`led.hpp`)
//!   banner_*    the banner texts (`PORT_BANNER_*`)
//!   smp         the secondary CPUs and their stage (`smp.hpp`, `smp.cpp`)
//!   hw_result   the verdict, as the process exit code (`hw_result.hpp`)

const std = @import("std");
const builtin = @import("builtin");
const uos = @import("uos");

pub const banner_long = "POSIX synthetic host";
pub const banner_short = "native";
pub const banner_isa = switch (builtin.cpu.arch) {
    .x86_64 => "x86-64",
    .aarch64 => "AArch64",
    else => "host",
};
pub const banner_cpu = "POSIX host threads as CPUs";

/// The console, `uart::uart1`: unbuffered writes to the standard output.
pub const uart = struct {
    pub fn init() void {}

    pub fn puts(s: []const u8) void {
        uos.port.trace.write(s);
    }

    pub fn print(comptime fmt: []const u8, args: anytype) void {
        var buf: [512]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buf);
        w.print(fmt, args) catch {};
        puts(w.buffered());
    }
};

/// The user LED: a host has no GPIO, so it is a console line, printed only
/// when it changes.
pub const led = struct {
    var state = false;
    var state_valid = false;

    fn emit(on_: bool) void {
        if (state_valid and state == on_) return;
        state = on_;
        state_valid = true;
        uos.port.trace.write(if (on_) "[LED on]\n" else "[LED off]\n");
    }

    pub fn init() void {
        state_valid = false;
        emit(false);
    }
    pub fn on() void {
        emit(true);
    }
    pub fn off() void {
        emit(false);
    }
    pub fn set(on_: bool) void {
        emit(on_);
    }
};

/// The secondary CPUs.
pub const smp = struct {
    /// Per-CPU stage: 0 not started, 3 scheduler entered.
    pub fn coreStage(cpu: u32) u32 {
        return uos.port.coreStage(cpu);
    }

    /// Start CPUs 1..ncpu-1 and wait until each is up
    /// (`smp::start_secondary_cores()`).
    pub fn startSecondaryCores() void {
        uos.port.startSecondaryCpus();
    }
};

/// The verdict: the process exit code.
pub const hw_result = struct {
    pub fn ok() noreturn {
        uos.port.terminate(0);
    }
    pub fn fail() noreturn {
        uos.port.terminate(1);
    }
};
