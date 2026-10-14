//! smp-test1 -- semaphore ping-pong across CPUs (the C++ test/native/smp_test1).
//!
//! "ping" on CPU 0 and "pong" on CPU 1 hand two binary semaphores back and
//! forth; "logger" on CPU 2 toggles the LED and prints the rounds every
//! second. After ten seconds: PASS when every secondary joined and the
//! rounds advanced.
//!
//! Differences from C++: the kernel prints its startup banner and creates
//! the secondary idle threads itself (no `smp_install_boot_threads()`); the
//! affinities are given at creation (C++ sets them after construction, so
//! its logger's first line comes from c0). The rounds per second are far
//! higher than in the C++ reference build, which predates the resume IPI fix.

const std = @import("std");
const uos = @import("uos");
const board = @import("board");
const rtos = uos.rtos;
const uart = board.uart;
const led = board.led;
const sysclock = rtos.sysclock;

pub const uos_options: uos.Options = .{
    .ncpu = 4,
    .smp = true,
    .main_stack_size_bytes = 8192 * @sizeOf(uos.port.StackElement),
    .default_stack_size_bytes = 64 * 1024,
    .idle_stack_size_bytes = 64 * 1024,
    .min_stack_size_bytes = 32 * 1024,
    .dynamic_memory_size_bytes = 0,
};

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

    // As in C++: 4096-element stacks are not larger than the port's 32 KiB
    // minimum, so the kernel ignores them and allocates default stacks.
    const gpa = uos.memory.allocator();
    t_ping.init("ping", pinger, null, .{ .stack = &s_ping, .cpu_affinity = 1 << 0 }, gpa) catch unreachable;
    t_pong.init("pong", ponger, null, .{ .stack = &s_pong, .cpu_affinity = 1 << 1 }, gpa) catch unreachable;
    t_log.init("logger", logger, null, .{ .stack = &s_log, .cpu_affinity = 1 << 2 }, gpa) catch unreachable;

    // Exactly 10 one-second beats, then the self-check.
    const check_beats = 10;
    for (0..check_beats) |_| sysclock.sleepFor(1000) catch {};

    const ok = board.smp.secondariesJoined() and g_rounds.load(.monotonic) > 0;
    uart.puts(if (ok) "\nRESULT: PASS\n" else "\nRESULT: FAIL\n");
    if (ok) board.hw_result.ok() else board.hw_result.fail();
}
