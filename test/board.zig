//! The test board: what the test applications use besides the kernel (the
//! C++ test/boards/<board>/include/ and test/luckfox-lyra/include/ helpers),
//! over the board module of the build (`uos_board`).
//!
//!   uart        the console, `uart::uart1`: the UART, mirrored to semihosting
//!   led         the user LED (`led.hpp`)
//!   banner_*    the banner texts (`PORT_BANNER_*`)
//!   smp         the secondary CPUs and their stage (`smp.hpp`, `smp.cpp`)
//!   hw_result   the verdict, a semihosting SYS_EXIT (`hw_result.hpp`)

const std = @import("std");
const uos = @import("uos");
const hw = @import("uos_board");

/// The kernel options of the board's tests: `ncpu` CPUs; the port's stack
/// sizes (2 KiB minimum, 16 KiB default); main's 8192-element static stack;
/// the linker script's 16 MiB free store.
pub fn options(ncpu: u8) uos.Options {
    return .{
        .ncpu = ncpu,
        .smp = ncpu > 1,
        .main_stack_size_bytes = 8192 * @sizeOf(uos.port.StackElement),
        .default_stack_size_bytes = 16 * 1024,
        .idle_stack_size_bytes = 16 * 1024,
        .min_stack_size_bytes = 2048,
        .dynamic_memory_size_bytes = 0,
        // memcpy() & co. for the C sources (FatFs).
        .c_runtime = true,
    };
}

pub const banner_long = hw.banner_long;
pub const banner_short = hw.banner_short;
pub const banner_isa = hw.banner_isa;
pub const banner_cpu = hw.banner_cpu;

/// The console, `uart::uart1`.
pub const uart = struct {
    pub fn init() void {
        hw.uartInit();
    }

    /// UART and semihosting.
    pub fn puts(s: []const u8) void {
        uos.port.trace.write(s);
    }

    /// The UART alone (`puts_uart()`).
    pub fn putsUart(s: []const u8) void {
        hw.uartWrite(s);
    }

    /// Emit the buffered semihosting text now (`flush()`).
    pub fn flush() void {
        uos.port.semihosting.flush();
    }

    pub fn print(comptime fmt: []const u8, args: anytype) void {
        var buf: [512]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buf);
        w.print(fmt, args) catch {};
        puts(w.buffered());
    }
};

pub const led = hw.led;

/// The secondary CPUs.
pub const smp = struct {
    /// Per-CPU stage: 0 not started, 3 scheduler entered.
    pub fn coreStage(cpu: u32) u32 {
        return uos.port.coreStage(cpu);
    }

    /// Release CPUs 1..2 (`smp::start_secondary_cores()`).
    pub fn startSecondaryCores() void {
        uos.port.startSecondaryCpus();
    }

    /// The stage a secondary must reach to count as joined.
    pub const core_joined: u32 = 3;

    /// The SMP test helpers of the C++ test/luckfox-lyra/src/test-smp-boot.cpp.
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

    /// "c1=3 c2=3", the stage of every secondary.
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

/// The verdict: a semihosting SYS_EXIT.
pub const hw_result = struct {
    pub fn ok() noreturn {
        uos.port.terminate(0);
    }
    pub fn fail() noreturn {
        uos.port.terminate(1);
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
