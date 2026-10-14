//! smp-test1 (Pico 2 / RP2350) -- Phase 2: single-core RTOS bring-up.
//!
//! The Zig port of test/pico2/smp-test1/main.cpp, line for line. The
//! kernel runs on ONE Cortex-M33 core (core 0), with the reference
//! scheduler on the PendSV context switch and the SysTick tick (the SMP
//! scheduler off). Proves:
//!   - scheduler + context switch (3 threads)
//!   - system clock (sysclock.sleepFor / now, 1 tick == 1 ms)
//!   - plain mutex (shared, protected global counter)
//!   - counting semaphore (worker -> led handoff)
//!   - LED heartbeat (GPIO25) as a visual "RTOS is alive"
//!
//! Output on UART0 @115200.

const std = @import("std");
const microzig = @import("microzig");
const uos = @import("uos");
const board = @import("uos_board");

const rtos = uos.rtos;
const sysclock = rtos.sysclock;
const uart = board.uart;
const semihosting = uos.port.semihosting;

pub const microzig_options = uos.port.microzig_options;

/// The C++ os-app-config.h of the pico2 board; OS_USE_SMP_SCHEDULER is not
/// defined for this test.
pub const uos_options: uos.Options = .{
    .ncpu = 1,
    .smp = false,
    .systick_frequency_hz = 1000,
    .critical_section_interrupt_priority = 5,
    .main_stack_size_bytes = 8192,
    .idle_stack_size_bytes = 4096,
    .default_stack_size_bytes = 4096,
    .dynamic_memory_size_bytes = 96 * 1024,
};

comptime {
    microzig.export_startup();
}

pub fn main() void {
    rtos.run(osMain);
}

var g_global: u32 = 0;
var g_mutex: rtos.Mutex = .{ .name = "g" };
var g_beats: rtos.Semaphore = .counting("beats", 8, 0);

var worker_stacks: [2][1024]uos.port.StackElement align(8) = undefined;
var led_stack: [1024]uos.port.StackElement align(8) = undefined;

const Ctx = struct {
    id: u32,
    local: u32,
};
var worker_ctx: [2]Ctx = undefined;

var workers: [2]rtos.Thread = undefined;
var led_th: rtos.Thread = undefined;

fn line(role: []const u8, id: u32, local: u32, global: u32) void {
    var b: [80]u8 = undefined;
    const s = std.fmt.bufPrint(&b, "[{d:>8} ms] {s:<6} #{d}  local={d:<4} global={d}\n", .{
        sysclock.now(), role, id, local, global,
    }) catch return;
    g_mutex.lock() catch {};
    uart.write(s);
    g_mutex.unlock() catch {};
}

fn worker(arg: ?*anyopaque) ?*anyopaque {
    const c: *Ctx = @ptrCast(@alignCast(arg.?));
    while (true) {
        c.local += 1;
        g_mutex.lock() catch {};
        g_global += 1;
        const g = g_global;
        g_mutex.unlock() catch {};
        line("worker", c.id, c.local, g);
        g_beats.post() catch {}; // signal the LED thread
        sysclock.sleepFor(500) catch {};
    }
}

fn ledThread(_: ?*anyopaque) ?*anyopaque {
    while (true) {
        g_beats.wait() catch {}; // one blink per worker beat
        board.led.set(true);
        sysclock.sleepFor(100) catch {};
        board.led.set(false);
    }
}

fn osMain() u8 {
    board.led.init();

    uart.write("\n");
    uart.write("=============================================\n");
    uart.write("  Pico 2 / RP2350 - micro-os-plus-iii\n");
    uart.write("  smp-test1 : single-core RTOS (core 0)\n");
    uart.write("=============================================\n");

    const names = [2][:0]const u8{ "wrk0", "wrk1" };
    for (0..2) |i| {
        worker_ctx[i] = .{ .id = @intCast(i), .local = 0 };
        workers[i].init(names[i], worker, &worker_ctx[i], .{ .stack = &worker_stacks[i] }, null) catch
            @panic("cannot create a worker");
    }

    led_th.init("led", ledThread, null, .{ .stack = &led_stack }, null) catch
        @panic("cannot create the led thread");

    const check_beats = 10;
    for (0..check_beats) |_| {
        sysclock.sleepFor(500) catch {};
    }

    const ok = g_global > 0 and worker_ctx[0].local > 0 and worker_ctx[1].local > 0;
    var b: [80]u8 = undefined;
    uart.write(std.fmt.bufPrint(&b, "\nRESULT: {s}  (global={d}, wrk0={d}, wrk1={d})\n", .{
        if (ok) "PASS" else "FAIL", g_global, worker_ctx[0].local, worker_ctx[1].local,
    }) catch "");

    // The verdict on the debug channel, then the semihosting exit that
    // carries it (hw_result::ok()/fail() in C++).
    semihosting.write(if (ok) "RESULT: PASS\n" else "RESULT: FAIL\n");
    semihosting.exit(if (ok) 0 else 1);
}
