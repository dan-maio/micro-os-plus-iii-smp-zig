//! smp-test2 -- kernel lock coherency on every CPU (the C++
//! test/native/smp_test2).
//!
//! One worker per CPU, pinned to it, increments a shared counter ITER times
//! under one mutex; PASS when no update was lost.
//!
//! Differences from C++: the kernel prints its startup banner and creates
//! the secondary idle threads; the affinities are given at creation. As in
//! C++, the 4096-element stacks are not above the port's minimum, so the
//! kernel allocates default ones.

const std = @import("std");
const uos = @import("uos");
const board = @import("board");
const rtos = uos.rtos;
const uart = board.uart;
const sysclock = rtos.sysclock;
const ncpu = uos.config.ncpu;

pub const uos_options = board.options(4);

const iter: u32 = 2000;
var g_prog: [ncpu]u32 = @splat(0);
var g_mutex: rtos.Mutex = .{ .name = "cnt" };
var g_counter: u32 = 0;
var g_done = std.atomic.Value(u32).init(0);

fn worker(_: ?*anyopaque) ?*anyopaque {
    var i: u32 = 0;
    while (i < iter) : (i += 1) {
        g_mutex.lock() catch {};
        const v = @as(*volatile u32, &g_counter).*;
        asm volatile ("" ::: .{ .memory = true });
        @as(*volatile u32, &g_counter).* = v + 1; // read-modify-write under the lock
        g_mutex.unlock() catch {};
        const me = uos.port.scheduler.cpuId();
        if (me < ncpu) @as(*volatile u32, &g_prog[me]).* = i;
        if ((i & 0x7F) == 0) rtos.this_thread.yield();
    }
    g_mutex.lock() catch {};
    uart.print("[c{d}] worker done, counter={d}\n", .{ uos.port.scheduler.cpuId(), @as(*volatile u32, &g_counter).* });
    _ = g_done.fetchAdd(1, .monotonic);
    g_mutex.unlock() catch {};
    return null;
}

var wstack: [ncpu][4096]uos.port.StackElement = undefined;
var workers: [ncpu]*rtos.Thread = undefined;
var wn: [ncpu][2:0]u8 = undefined;

pub fn main() void {
    uart.init();
    uart.print("\n\n+== " ++ board.banner_short ++ " µOS++ SMP TEST 2 : {d}-core lock coherency ==+\n\n", .{ncpu});
    rtos.run(osMain);
}

fn osMain() void {
    _ = rtos.interrupts.UncriticalSection.enter();

    uart.print("os_main on core {d}\n", .{uos.port.scheduler.cpuId()});
    uart.print("Releasing cores 1..{d}...\n", .{ncpu - 1});
    board.smp.startSecondaryCores();

    const waited = board.smp.waitSecondaries(3000);
    uart.print("join: {s} ({d}ms)\n", .{ board.smp.joinSummary(), waited });

    const gpa = uos.memory.allocator();
    for (0..ncpu) |c| {
        wn[c] = .{ 'w', '0' + @as(u8, @intCast(c)) };
        workers[c] = rtos.Thread.create(gpa, &wn[c], worker, null, .{
            .stack = &wstack[c],
            .cpu_affinity = @as(u32, 1) << @intCast(c),
        }) catch unreachable;
    }

    while (g_done.load(.monotonic) < ncpu) {
        sysclock.sleepFor(500) catch {};
        var buf: [256]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buf);
        w.writeAll("progress:") catch {};
        for (0..ncpu) |c| w.print(" {s}={d}", .{ &wn[c], @as(*volatile u32, &g_prog[c]).* }) catch {};
        w.print(" done={d} counter={d}\n", .{ g_done.load(.monotonic), @as(*volatile u32, &g_counter).* }) catch {};
        uart.puts(w.buffered());
    }

    const expected = iter * ncpu;
    const counter = @as(*volatile u32, &g_counter).*;
    uart.puts("\n==== RESULT ====\n");
    uart.print("counter = {d}  expected = {d}\n", .{ counter, expected });
    if (counter == expected) {
        uart.print("PASS: lock coherent across {d} cores\n", .{ncpu});
    } else {
        uart.puts("FAIL: lost updates!\n");
    }
    uart.print("\nRESULT: {s}\n", .{if (counter == expected) "PASS" else "FAIL"});
    if (counter == expected) board.hw_result.ok() else board.hw_result.fail();
}
