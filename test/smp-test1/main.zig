//! smp-test1 -- Semaphore ping-pong across 4 Cortex-A72 cores + LED (Raspberry Pi 4 B).
//!
//! "ping" on Core 0 and "pong" on Core 1 hand two binary semaphores back and
//! forth; "logger" on Core 2 toggles the ACT LED and reports the round count
//! every second. After 10 seconds: PASS when every secondary joined and rounds advanced.

const std = @import("std");
const uos = @import("uos");
const board = @import("board");
const rtos = uos.rtos;
const uart = board.uart;
const led = board.led;
const sysclock = rtos.sysclock;

pub const uos_options = board.options(4);

var g_ping: rtos.Semaphore = .binary("ping", 1); // starts signalled
var g_pong: rtos.Semaphore = .binary("pong", 0);
var g_rounds = std.atomic.Value(u32).init(0);
var g_ping_core = std.atomic.Value(i32).init(-1);
var g_pong_core = std.atomic.Value(i32).init(-1);

fn cpuId() i32 {
    return @intCast(uos.port.scheduler.cpuId());
}

fn pinger(_: ?*anyopaque) ?*anyopaque {
    while (true) {
        g_ping.wait() catch {};
        g_ping_core.store(cpuId(), .monotonic);
        _ = g_rounds.fetchAdd(1, .monotonic);
        g_pong.post() catch {};
    }
}

fn ponger(_: ?*anyopaque) ?*anyopaque {
    while (true) {
        g_pong.wait() catch {};
        g_pong_core.store(cpuId(), .monotonic);
        g_ping.post() catch {};
    }
}

fn logger(_: ?*anyopaque) ?*anyopaque {
    var s = false;
    while (true) {
        s = !s;
        led.set(s);
        uart.print("[c{d}] rounds={d}  ping@c{d} pong@c{d}  t={d}ms\n", .{
            cpuId(),
            g_rounds.load(.monotonic),
            g_ping_core.load(.monotonic),
            g_pong_core.load(.monotonic),
            @as(u32, @truncate(sysclock.now())),
        });
        sysclock.sleepFor(1000) catch {};
    }
}

var s_ping: [4096]uos.port.StackElement = undefined;
var s_pong: [4096]uos.port.StackElement = undefined;
var s_log: [4096]uos.port.StackElement = undefined;
var t_ping: rtos.Thread = undefined;
var t_pong: rtos.Thread = undefined;
var t_log: rtos.Thread = undefined;

pub fn main() void {
    uart.init();
    led.init();
    uart.puts("\n\n+== " ++ board.banner_short ++ " µOS++ SMP TEST 1 : semaphore ping-pong + LED ==+\n\n");
    rtos.run(osMain);
}

fn osMain() void {
    _ = rtos.interrupts.UncriticalSection.enter();
    board.smp.startSecondaryCores();
    const waited = board.smp.waitSecondaries(3000);
    uart.print("join: {s} ({d}ms)\n", .{ board.smp.joinSummary(), waited });

    const gpa = uos.memory.allocator();
    t_ping.init("ping", pinger, null, .{ .stack = &s_ping, .cpu_affinity = 1 << 0 }, gpa) catch unreachable;
    t_pong.init("pong", ponger, null, .{ .stack = &s_pong, .cpu_affinity = 1 << 1 }, gpa) catch unreachable;
    t_log.init("logger", logger, null, .{ .stack = &s_log, .cpu_affinity = 1 << 2 }, gpa) catch unreachable;

    // 10 one-second beats
    const check_beats = 10;
    for (0..check_beats) |_| sysclock.sleepFor(1000) catch {};

    const ok = board.smp.secondariesJoined() and g_rounds.load(.monotonic) > 0;
    uart.puts(if (ok) "\nRESULT: PASS\n" else "\nRESULT: FAIL\n");
    if (ok) board.hw_result.ok() else board.hw_result.fail();
}
