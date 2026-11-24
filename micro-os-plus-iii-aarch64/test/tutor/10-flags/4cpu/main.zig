//! tutor-10-flags-4cpu -- lesson 10, four CPUs (see ../README.md).
//!
//! Part A, phases started by flags: four `generate` threads each build 18
//! samples and raise their own bit of an event flags object; a `sort` thread
//! waits for all four bits (mode all | clear), merges and sorts, then raises
//! a thread flag of the `max` thread, which computes the maximum and the
//! checksum. `sort` and `max` run above the generators, so without the flags
//! they would run first: every phase must start only after its inputs.
//!
//! Part B, the semantics: any vs all, the auto-clear, timed_wait; one raise
//! and two waiters -- with mode::clear only one takes it, without it both.
//!
//! Part C, from an interrupt: the second timer's ISR raises a thread flag 20
//! times, every 2 ms; the thread takes every one, each within a bound.
//!
//! With four CPUs the phases run on different cores: the generators on cores
//! 1, 2, 3 and 0, `sort` on core 2, `max` on core 3; the two waiters of part B
//! on cores 1 and 2; the ISR on core 0 and its waiter on core 2. A flag raised
//! on one core starts a phase on another.
//!
//! The Zig version of the C++ lesson (golden workspace,
//! test/rpi4b/tutor/10-flags/4cpu/main.cpp), with the same checks.

const std = @import("std");
const uos = @import("uos");
const board = @import("board");
const tutor = @import("tutor");

const rtos = uos.rtos;
const flags = rtos.flags;
const Sample = tutor.Sample;
const sysclock = rtos.sysclock;
const second_timer = tutor.second_timer;
const prio = rtos.priority;

pub const uos_options = board.options(4);

// The port's external-interrupt hook: the second interrupt.
pub const uos_external_irq = second_timer.onIrq;

const four = true;
const seed: u32 = 2026;

fn spawn(gpa: std.mem.Allocator, name: [:0]const u8, f: *const fn (?*anyopaque) ?*anyopaque, arg: usize, p: rtos.Priority, core: ?u32) *rtos.Thread {
    var attr: rtos.Thread.Attributes = .{ .priority = p, .stack_size_bytes = 8 * 1024 };
    if (core) |c| attr.cpu_affinity = @as(u32, 1) << @intCast(c);
    return rtos.Thread.create(gpa, name, f, @ptrFromInt(arg), attr) catch {
        _ = tutor.check(false, "cannot create {s}", .{name});
        tutor.finish("");
    };
}

// The C++ lesson's names for the results.
fn nameOf(r: anyerror!flags.Mask) []const u8 {
    _ = r catch |e| return switch (e) {
        error.WouldBlock => "EWOULDBLOCK",
        error.TimedOut => "ETIMEDOUT",
        else => "other",
    };
    return "ok";
}

fn isErr(r: anyerror!flags.Mask, want: anyerror) bool {
    _ = r catch |e| return e == want;
    return false;
}

fn isOk(r: anyerror!flags.Mask) bool {
    _ = r catch return false;
    return true;
}

// The order of events: every phase records when it started and ended.
var g_seq = std.atomic.Value(u32).init(0);

fn nextSeq() u32 {
    return g_seq.fetchAdd(1, .monotonic) + 1;
}

// ---- Part A: generate -> sort -> max, started by flags ---------------------

const n_gen = 4;
const per_gen = 18;
const n_samples = n_gen * per_gen;

var g_data: [n_gen][per_gen]Sample = @splat(@splat(.{})); // the data segment
var g_lists: [n_gen]tutor.SampleList = @splat(.{}); // one per generator
var g_sorted: tutor.SampleList = .{};

var g_phases: rtos.EventFlags = .{ .name = "phases" };
const all_generated: flags.Mask = (1 << n_gen) - 1;

var g_gen_end: [n_gen]u32 = @splat(0);
var g_sort_start: u32 = 0;
var g_sort_end: u32 = 0;
var g_max_start: u32 = 0;
var g_max_end: u32 = 0;
var g_sort_got: flags.Mask = 0;
var g_gen_core: [n_gen]u32 = @splat(99);
var g_sort_core: u32 = 99;
var g_max_core: u32 = 99;

var g_max: ?*const Sample = null;
var g_checksum: u32 = 0;

var g_max_thread: ?*rtos.Thread = null;

fn generator(arg: ?*anyopaque) ?*anyopaque {
    const w = @intFromPtr(arg);
    g_gen_core[w] = board.cpuSlot();
    for (&g_data[w], 0..) |*s, i| {
        const id: u32 = @intCast(w * per_gen + i);
        s.init(id, tutor.generate(seed, id), .data);
        g_lists[w].push(s);
    }
    g_gen_end[w] = nextSeq();
    _ = g_phases.raise(@as(flags.Mask, 1) << @intCast(w)) catch {}; // this input is ready
    return null;
}

fn sorter(_: ?*anyopaque) ?*anyopaque {
    g_sort_core = board.cpuSlot();
    // All four inputs, and consume them (clear), whatever order they come in.
    g_sort_got = g_phases.wait(all_generated, flags.Mode.all_clear) catch 0;
    g_sort_start = nextSeq();
    for (&g_lists) |*l| {
        while (l.head) |s| {
            _ = l.unlink(s);
            g_sorted.push(s);
        }
    }
    tutor.sortList(&g_sorted);
    g_sort_end = nextSeq();
    _ = g_max_thread.?.flagsRaise(1) catch {}; // the next phase's input is ready
    return null;
}

fn maxer(_: ?*anyopaque) ?*anyopaque {
    g_max_core = board.cpuSlot();
    _ = rtos.this_thread.flagsWait(1, flags.Mode.all_clear) catch {};
    g_max_start = nextSeq();
    g_max = tutor.maxOf(g_sorted);
    g_checksum = tutor.checksum(g_sorted);
    g_max_end = nextSeq();
    return null;
}

// ---- Part B: two waiters on one bit ---------------------------------------------

const bit_b: flags.Mask = 0x8;
var g_b_taken = std.atomic.Value(u32).init(0);
var g_b_mode: flags.Mode = .{ .all = true }; // set by bRun()

fn bWaiter(arg: ?*anyopaque) ?*anyopaque {
    const ef: *rtos.EventFlags = @ptrCast(@alignCast(arg));
    if (isOk(ef.wait(bit_b, g_b_mode))) _ = g_b_taken.fetchAdd(1, .monotonic);
    return null;
}

// Two waiters for bit_b in `mode`; one raise; how many took it.
fn bRun(gpa: std.mem.Allocator, ef: *rtos.EventFlags, mode: flags.Mode, core0: ?u32, core1: ?u32, second: *u32) u32 {
    g_b_mode = mode;
    g_b_taken.store(0, .monotonic);
    const t0 = spawn(gpa, "bw0", bWaiter, @intFromPtr(ef), prio.above_normal, core0);
    const t1 = spawn(gpa, "bw1", bWaiter, @intFromPtr(ef), prio.above_normal, core1);
    sysclock.sleepFor(5) catch {}; // both waiting
    _ = ef.raise(bit_b) catch {};
    sysclock.sleepFor(5) catch {};
    const first = g_b_taken.load(.monotonic);
    if (first < 2) {
        _ = ef.raise(bit_b) catch {}; // the other one
        sysclock.sleepFor(5) catch {};
    }
    second.* = g_b_taken.load(.monotonic);
    for ([_]*rtos.Thread{ t0, t1 }) |t| {
        _ = t.join() catch null;
        t.destroy();
    }
    return first;
}

// ---- Part C: a thread flag raised from an interrupt ---------------------------

const n_irq = 20;
const irq_period_us: u32 = 2000;

var g_irq_thread: ?*rtos.Thread = null;
var g_irq_raised = std.atomic.Value(u32).init(0);
var g_irq_us = std.atomic.Value(u32).init(0);
var g_irq_taken: u32 = 0;
var g_irq_lat_max: u32 = 0;
var g_irq_waiter_core: u32 = 99;

fn onIrq(_: ?*anyopaque) void {
    if (g_irq_raised.load(.monotonic) < n_irq) {
        if (g_irq_thread) |t| {
            g_irq_us.store(second_timer.nowUs(), .monotonic);
            _ = g_irq_raised.fetchAdd(1, .monotonic);
            _ = t.flagsRaise(1) catch {}; // allowed in an ISR
        }
    }
}

fn irqWaiter(_: ?*anyopaque) ?*anyopaque {
    g_irq_waiter_core = board.cpuSlot();
    for (0..n_irq) |_| {
        _ = rtos.this_thread.flagsWait(1, flags.Mode.all_clear) catch {};
        const lat = second_timer.nowUs() -% g_irq_us.load(.monotonic);
        g_irq_lat_max = @max(g_irq_lat_max, lat);
        g_irq_taken += 1;
    }
    return null;
}

pub fn main() void {
    board.uart.init();
    rtos.run(osMain);
}

fn osMain() void {
    const gpa = uos.memory.allocator();
    const self = rtos.this_thread.thread();

    if (four) self.setCpuAffinity(1 << 0);
    tutor.printBanner("10 flags");
    board.console(if (four) "Lesson 10, four CPUs: event flags (any/all, auto-clear) and thread flags.\n" else "Lesson 10, one CPU: event flags (any/all, auto-clear) and thread flags.\n", .{});
    tutor.printRegions();
    if (four) {
        // ---- Release cores 1-3 (as in lesson 01).
        board.smp.startSecondaryCores();
        const waited = board.smp.waitSecondaries(3000);
        board.console("  cores joined after {d} ms: {s}\n", .{ waited, board.smp.joinSummary() });
        _ = tutor.check(board.smp.secondariesJoined(), "cores 1-{d} joined the scheduler", .{uos.config.ncpu - 1});
    }
    const heap0 = tutor.heapBytes();
    const lat_bound_us: u32 = if (tutor.onHardware()) 1000 else 20000;

    // ---- Part A.
    board.console(if (four) "\n-- part A: {d} generators (cores 1, 2, 3, 0) -> sort (core 2) -> max (core 3), each phase started by flags\n" else "\n-- part A: {d} generators -> sort -> max, each phase started by flags\n", .{n_gen});
    {
        // `max` and `sort` first, and above the generators: only the flags
        // hold them back.
        const gen_core = [n_gen]u32{ 1, 2, 3, 0 };
        g_max_thread = spawn(gpa, "max", maxer, 0, prio.high, if (four) 3 else null);
        const ts = spawn(gpa, "sort", sorter, 0, prio.above_normal, if (four) 2 else null);
        var tg: [n_gen]*rtos.Thread = undefined;
        for (&tg, 0..) |*t, w| t.* = spawn(gpa, "generate", generator, w, prio.normal, if (four) gen_core[w] else null);
        for (tg) |t| {
            _ = t.join() catch null;
            t.destroy();
        }
        for ([_]*rtos.Thread{ ts, g_max_thread.? }) |t| {
            _ = t.join() catch null;
            t.destroy();
        }
    }
    var last_gen: u32 = 0;
    for (g_gen_end) |e| last_gen = @max(last_gen, e);
    const e = tutor.reference(seed, 0, n_samples);
    board.console("  order: generators ended at {d} {d} {d} {d}; sort {d}..{d} (flags 0x{x}); max {d}..{d}\n", .{ g_gen_end[0], g_gen_end[1], g_gen_end[2], g_gen_end[3], g_sort_start, g_sort_end, g_sort_got, g_max_start, g_max_end });
    const mx = g_max;
    board.console("  {d} samples sorted, max {d} (#{d}), checksum {x:0>8}\n", .{ g_sorted.count(), if (mx) |m| m.value else -1, if (mx) |m| m.id else 0, g_checksum });
    _ = tutor.check(g_sort_start > last_gen and g_sort_got == all_generated, "sort started after all {d} generators had raised their bit", .{n_gen});
    _ = tutor.check(g_max_start > g_sort_end, "max started after sort had raised its thread flag", .{});
    if (four) {
        _ = tutor.check(g_gen_core[0] == 1 and g_gen_core[1] == 2 and g_gen_core[2] == 3 and g_gen_core[3] == 0 and g_sort_core == 2 and g_max_core == 3, "the generators on cores 1, 2, 3, 0, sort on core 2, max on core 3", .{});
    }
    _ = tutor.check(g_sorted.count() == n_samples and g_checksum == e.sorted_checksum and mx != null and mx.?.value == e.max_value and mx.?.id == e.max_id, "{d} samples sorted; checksum and max equal the reference", .{n_samples});

    // ---- Part B.
    board.console("\n-- part B: any and all, the auto-clear, timed_wait, one raise and two waiters\n", .{});
    {
        var ef: rtos.EventFlags = .{ .name = "b" };
        _ = ef.raise(0x1) catch {};
        const r_all = ef.tryWait(0x3, .{ .all = true });
        const r_any = ef.tryWait(0x3, .{ .any = true });
        const got_any = r_any catch 0;
        const kept = ef.get(0x3, .{}); // read, do not clear
        const r_clr = ef.tryWait(0x1, flags.Mode.any_clear);
        const after = ef.get(0x3, .{});
        board.console("  0x1 raised: try_wait(0x3, all) {s}; try_wait(0x3, any) {s}, got 0x{x}, still set 0x{x}; with clear {s}, then 0x{x}\n", .{ nameOf(r_all), nameOf(r_any), got_any, kept, nameOf(r_clr), after });
        _ = tutor.check(isErr(r_all, error.WouldBlock) and isOk(r_any) and got_any == 0x1, "all waits for every bit, any for one of them", .{});
        _ = tutor.check(kept == 0x1 and isOk(r_clr) and after == 0, "without clear the flags stay; with clear they are taken", .{});

        const t0 = sysclock.now();
        const tw = ef.timedWait(0x4, 10, .{ .all = true, .clear = true });
        const waited = sysclock.now() - t0;
        board.console("  timed_wait(0x4, 10): {s} after {d} ticks\n", .{ nameOf(tw), waited });
        _ = tutor.check(isErr(tw, error.TimedOut) and waited >= 10 and waited <= 11, "timed_wait: ETIMEDOUT after 10 ticks", .{});

        var c_second: u32 = 0;
        var k_second: u32 = 0;
        const c_first = bRun(gpa, &ef, flags.Mode.all_clear, if (four) 1 else null, if (four) 2 else null, &c_second);
        const c_left = ef.get(bit_b, .{});
        var ek: rtos.EventFlags = .{ .name = "keep" };
        const k_first = bRun(gpa, &ek, .{ .all = true }, if (four) 1 else null, if (four) 2 else null, &k_second);
        const k_left = ek.get(bit_b, .{});
        board.console("  two waiters, one raise: with clear {d} took it ({d} after a second raise, 0x{x} left); without clear {d} (0x{x} left)\n", .{ c_first, c_second, c_left, k_first, k_left });
        _ = tutor.check(c_first == 1 and c_second == 2 and c_left == 0, "with clear one raise wakes one taker: the flag is consumed", .{});
        _ = tutor.check(k_first == 2 and k_left == bit_b, "without clear one raise wakes both, and the flag stays set", .{});

        const own = rtos.this_thread.flagsTryWait(1, flags.Mode.all_clear);
        board.console("  thread flags are per thread: main's own try_wait(1) {s}\n", .{nameOf(own)});
        _ = tutor.check(isErr(own, error.WouldBlock), "a thread flag raised for another thread is not seen by main", .{});
    }

    // ---- Part C.
    board.console(if (four) "\n-- part C: the second timer's ISR raises a thread flag {d} times, every {d} us, ISR on core 0, waiter on core 2\n" else "\n-- part C: the second timer's ISR raises a thread flag {d} times, every {d} us\n", .{ n_irq, irq_period_us });
    {
        const tw = spawn(gpa, "waiter", irqWaiter, 0, prio.high, if (four) 2 else null);
        g_irq_thread = tw;
        second_timer.start(irq_period_us, onIrq, null); // on this core, core 0
        _ = tw.join() catch null;
        second_timer.stop();
        g_irq_thread = null;
        tw.destroy();
    }
    board.console("  raised {d}, taken {d}; ISR on core mask {x}, waiter on core {d}; ISR -> waiter max {d} us\n", .{ g_irq_raised.load(.monotonic), g_irq_taken, second_timer.cpusSeen(), g_irq_waiter_core, g_irq_lat_max });
    _ = tutor.check(g_irq_taken == n_irq and g_irq_raised.load(.monotonic) == n_irq, "every flag raised by the ISR taken ({d})", .{n_irq});
    _ = tutor.check(g_irq_lat_max <= lat_bound_us, "each within {d} us of its interrupt", .{lat_bound_us});
    if (four) {
        _ = tutor.check(second_timer.cpusSeen() == 1 and g_irq_waiter_core == 2, "the ISR on core 0, the waiter woken on core 2 (cross-core)", .{});
    }

    _ = tutor.check(tutor.heapBytes() == heap0, "heap back to {d} B", .{heap0});
    tutor.finish(if (four) "generate -> sort -> max in order across cores, started by flags; any/all, clear, timed_wait; ISR flags taken across cores; four CPUs" else "generate -> sort -> max in order, started by flags; any/all, clear, timed_wait; ISR flags taken; one CPU");
}
