//! smp-test3 -- Message Queue producer/consumer across 4 CPUs (Raspberry Pi 4 B).
//!
//! Producer (Core 0) sends integers every 20 ms; Consumer (Core 1) classifies
//! primes and toggles the ACT LED; Logger (Core 2) prints status every second.
//! PASS when every secondary joined and messages were consumed.

const std = @import("std");
const uos = @import("uos");
const board = @import("board");
const rtos = uos.rtos;
const uart = board.uart;
const led = board.led;
const sysclock = rtos.sysclock;

pub const uos_options = board.options(4);

var g_mq: rtos.MessageQueue = .{};
var g_print: rtos.Mutex = .{ .name = "print" };
var g_produced = std.atomic.Value(u32).init(0);
var g_consumed = std.atomic.Value(u32).init(0);
var g_primes = std.atomic.Value(u32).init(0);
var g_beats = std.atomic.Value(u32).init(0);

fn isPrime(n: u32) bool {
    if (n < 2) return false;
    var i: u32 = 2;
    while (i * i <= n) : (i += 1) if (n % i == 0) return false;
    return true;
}

fn cpuId() u32 {
    return uos.port.scheduler.cpuId();
}

fn producer(_: ?*anyopaque) ?*anyopaque {
    var v: u32 = 2;
    while (true) {
        g_mq.send(std.mem.asBytes(&v), 0) catch {};
        _ = g_produced.fetchAdd(1, .monotonic);
        v += 1;
        sysclock.sleepFor(20) catch {};
    }
}

fn consumer(_: ?*anyopaque) ?*anyopaque {
    var v: u32 = undefined;
    var led_state = false;
    while (true) {
        if (g_mq.receive(std.mem.asBytes(&v))) |_| {
            _ = g_consumed.fetchAdd(1, .monotonic);
            const p = isPrime(v);
            if (p) {
                _ = g_primes.fetchAdd(1, .monotonic);
                led_state = !led_state;
                led.set(led_state);
            }
            g_print.lock() catch {};
            uart.print("[c{d}] recv {d}{s}", .{ cpuId(), v, if (p) " PRIME\n" else " composite\n" });
            g_print.unlock() catch {};
        } else |_| {}
    }
}

fn logger(_: ?*anyopaque) ?*anyopaque {
    while (true) {
        g_print.lock() catch {};
        uart.print("[c{d}] produced={d} consumed={d} primes={d} t={d}ms\n", .{
            cpuId(),
            g_produced.load(.monotonic),
            g_consumed.load(.monotonic),
            g_primes.load(.monotonic),
            @as(u32, @truncate(sysclock.now())),
        });
        g_print.unlock() catch {};
        sysclock.sleepFor(1000) catch {};
    }
}

var s_prod: [4096]uos.port.StackElement = undefined;
var s_cons: [4096]uos.port.StackElement = undefined;
var s_log: [4096]uos.port.StackElement = undefined;
var t_prod: rtos.Thread = undefined;
var t_cons: rtos.Thread = undefined;
var t_log: rtos.Thread = undefined;

pub fn main() void {
    uart.init();
    led.init();
    uart.puts("\n\n+== " ++ board.banner_short ++ " µOS++ SMP TEST 3 : message_queue producer/consumer ==+\n\n");
    rtos.run(osMain);
}

fn osMain() void {
    const gpa = uos.memory.allocator();
    g_mq.create(gpa, "mq", 8, @sizeOf(*anyopaque), .{}) catch unreachable;

    _ = rtos.interrupts.UncriticalSection.enter();
    board.smp.startSecondaryCores();
    const waited = board.smp.waitSecondaries(3000);
    uart.print("join: {s} ({d}ms)\n", .{ board.smp.joinSummary(), waited });

    t_prod.init("producer", producer, null, .{ .stack = &s_prod, .cpu_affinity = 1 << 0 }, gpa) catch unreachable;
    t_cons.init("consumer", consumer, null, .{ .stack = &s_cons, .cpu_affinity = 1 << 1 }, gpa) catch unreachable;
    t_log.init("logger", logger, null, .{ .stack = &s_log, .cpu_affinity = 1 << 2 }, gpa) catch unreachable;

    var b: u32 = 1;
    while (b <= 10) : (b += 1) {
        sysclock.sleepFor(1000) catch {};
        g_beats.store(b, .monotonic);
    }
    const ok = board.smp.secondariesJoined() and g_consumed.load(.monotonic) > 0;
    uart.puts(if (ok) "\nRESULT: PASS\n" else "\nRESULT: FAIL\n");
    if (ok) board.hw_result.ok() else board.hw_result.fail();
}
