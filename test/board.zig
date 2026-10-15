//! The test board bridge: provides the interface for test applications
//! matching the C++ test scaffolding.

const std = @import("std");
const uos = @import("uos");
const hw = @import("uos_board");

/// Kernel options configured for tests on Raspberry Pi 4 B.
pub fn options(ncpu: u8) uos.Options {
    return .{
        .ncpu = ncpu,
        .smp = ncpu > 1,
        .main_stack_size_bytes = 8192 * @sizeOf(uos.port.StackElement),
        .default_stack_size_bytes = 16 * 1024,
        .idle_stack_size_bytes = 16 * 1024,
        .min_stack_size_bytes = 2048,
        .dynamic_memory_size_bytes = 8 * 1024 * 1024,
        // memcpy() & co. for the C sources (FatFs).
        .c_runtime = true,
    };
}

pub const banner_long = hw.banner_long;
pub const banner_short = hw.banner_short;
pub const banner_isa = hw.banner_isa;
pub const banner_cpu = hw.banner_cpu;
pub const uartPrint = hw.uartPrint;

pub const uart = struct {
    pub fn init() void {
        hw.uartInit();
    }

    pub fn puts(s: []const u8) void {
        uos.port.trace.write(s);
    }

    pub fn putsUart(s: []const u8) void {
        hw.uartWrite(s);
    }

    pub fn flush() void {
        uos.port.semihosting.flush();
        hw.uartFlush();
    }

    pub fn print(comptime fmt: []const u8, args: anytype) void {
        var buf: [512]u8 = undefined;
        var w = std.Io.Writer.fixed(&buf);
        w.print(fmt, args) catch {};
        puts(w.buffered());
    }
};

pub const led = hw.led;

pub const smp = struct {
    pub fn coreStage(cpu: u32) u32 {
        return uos.port.coreStage(cpu);
    }

    pub fn startSecondaryCores() void {
        uos.port.startSecondaryCpus();
    }

    pub const core_joined: u32 = 3;

    pub fn secondariesJoined() bool {
        var cpu: u32 = 1;
        while (cpu < uos.config.ncpu) : (cpu += 1) {
            if (coreStage(cpu) < core_joined) return false;
        }
        return true;
    }

    pub fn waitSecondaries(timeout_ms: u32) u32 {
        var waited: u32 = 0;
        while (!secondariesJoined() and waited < timeout_ms) {
            uos.rtos.sysclock.sleepFor(50) catch {};
            waited += 50;
        }
        return waited;
    }

    var join_summary_buf: [uos.config.ncpu * 8 + 1]u8 = undefined;

    pub fn joinSummary() []const u8 {
        var w = std.Io.Writer.fixed(&join_summary_buf);
        var cpu: u32 = 1;
        while (cpu < uos.config.ncpu) : (cpu += 1) {
            w.print("{s}c{d}={d}", .{ if (cpu == 1) "" else " ", cpu, coreStage(cpu) }) catch break;
        }
        return w.buffered();
    }
};

pub fn cpuSlot() u32 {
    const id = uos.port.scheduler.cpuId();
    return if (id < uos.config.ncpu) id else 0;
}

pub const mmu = uos.port.mmu;

/// The verdict: a semihosting SYS_EXIT (the test printed its RESULT line
/// on the console, mirrored to semihosting).
pub const hw_result = struct {
    pub fn ok() noreturn {
        uos.port.terminate(0);
    }
    pub fn fail() noreturn {
        uos.port.terminate(1);
    }
};

var console_mutex: uos.rtos.Mutex = .{ .name = "con" };

pub fn console(comptime fmt: []const u8, args: anytype) void {
    var buf: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    w.print(fmt, args) catch {};
    console_mutex.lock() catch {};
    uart.puts(w.buffered());
    console_mutex.unlock() catch {};
}

pub fn reportPerCore(label: []const u8, counts: []const u32) void {
    var buf: [32 * 16 + 64]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    w.print("  {s} : ", .{label}) catch {};
    for (counts, 0..) |n, c| w.print("c{d}={d} ", .{ c, n }) catch break;
    console("{s}\n", .{w.buffered()});
}
