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

/// The kernel options of the board's tests: `ncpu` CPUs (the board has 4);
/// the port's stack sizes (32 KiB minimum, 64 KiB default); main's
/// 8192-element static stack; the board's 32 MiB free store.
pub fn options(ncpu: u8) uos.Options {
    return .{
        .ncpu = ncpu,
        .smp = ncpu > 1,
        .main_stack_size_bytes = 8192 * @sizeOf(uos.port.StackElement),
        .default_stack_size_bytes = 64 * 1024,
        .idle_stack_size_bytes = 64 * 1024,
        .min_stack_size_bytes = 32 * 1024,
        .dynamic_memory_size_bytes = 0,
    };
}

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

    /// The stage a secondary must reach to count as joined.
    pub const core_joined: u32 = 3;

    /// The SMP test helpers of the C++ test/native/src/test-smp-boot.cpp.
    /// (`smp_install_boot_threads()` has no counterpart: the Zig kernel
    /// creates an idle thread for every CPU itself.)
    pub fn secondariesJoined() bool {
        var cpu: u32 = 1;
        while (cpu < uos.config.ncpu) : (cpu += 1) {
            if (coreStage(cpu) < core_joined) return false;
        }
        return true;
    }

    /// Wait (50 ms steps) until every secondary joined or `timeout_ms`
    /// elapsed; returns the milliseconds waited.
    pub fn waitSecondaries(timeout_ms: u32) u32 {
        var waited: u32 = 0;
        while (!secondariesJoined() and waited < timeout_ms) {
            uos.rtos.sysclock.sleepFor(50) catch {};
            waited += 50;
        }
        return waited;
    }

    var join_summary_buf: [uos.config.ncpu * 8 + 1]u8 = undefined;

    /// "c1=3 c2=3 ...", the stage of every secondary.
    pub fn joinSummary() []const u8 {
        var w: std.Io.Writer = .fixed(&join_summary_buf);
        var cpu: u32 = 1;
        while (cpu < uos.config.ncpu) : (cpu += 1) {
            w.print("{s}c{d}={d}", .{ if (cpu == 1) "" else " ", cpu, coreStage(cpu) }) catch break;
        }
        return w.buffered();
    }
};

/// `cpu_slot()`: this CPU's index, clamped to the CPU count.
pub fn cpuSlot() u32 {
    const id = uos.port.scheduler.cpuId();
    return if (id < uos.config.ncpu) id else 0;
}

/// The verdict: the process exit code.
pub const hw_result = struct {
    /// End the run reporting success (`std::_Exit(0)`: the statistics, then
    /// the port's `os_terminate()`).
    pub fn ok() noreturn {
        uos.rtos.terminate(0);
    }
    /// End the run reporting failure (`std::_Exit(1)`).
    pub fn fail() noreturn {
        uos.rtos.terminate(1);
    }
};

/// `console()` / `report_per_core()` (the C++ test-console.hpp): output
/// formatted into a 256-byte buffer and written under one mutex, so lines
/// from different CPUs do not interleave.
var console_mutex: uos.rtos.Mutex = .{ .name = "con" };

pub fn console(comptime fmt: []const u8, args: anytype) void {
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    w.print(fmt, args) catch {};
    console_mutex.lock() catch {};
    uart.puts(w.buffered());
    console_mutex.unlock() catch {};
}

pub fn reportPerCore(label: []const u8, counts: []const u32) void {
    var buf: [32 * 16 + 64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    w.print("  {s} : ", .{label}) catch {};
    for (counts, 0..) |n, c| w.print("c{d}={d} ", .{ c, n }) catch break;
    console("{s}\n", .{w.buffered()});
}
