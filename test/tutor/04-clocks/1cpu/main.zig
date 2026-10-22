//! tutor-04-clocks-1cpu -- lesson 04, one CPU (see ../README.md).
//!
//! Part A, the three clocks: sysclock (the 1 kHz tick), hrclock (the generic
//! timer's cycles) and rtclock (seconds) are read against an independent
//! reference, the BCM2711 System Timer (1 MHz): each must be monotonic and
//! advance at its nominal rate, and hrclock's now() must agree with the
//! timestamps its own sleeps are measured against.
//!
//! Part B, measuring with hrclock: the insertion sort of 18, 72 and 288
//! samples, timed in cycles; the results exact and the times growing with
//! the size (an insertion sort is quadratic).
//!
//! Part C, periodic threads: two samplers, each doing 2 ms of work per period
//! of 100 ms, 20 periods, over a low-priority background load. The absolute
//! one sleeps until `next += 100` (sleepUntil): its period stays 100 ticks and
//! its 20th wake is exactly 1900 ticks after its first. The relative one
//! sleeps for 100 after its work (sleepFor): its period becomes 102 ticks,
//! and it drifts by the work's length every period.
//!
//! The Zig version of the C++ lesson (golden workspace,
//! test/rpi4b/tutor/04-clocks/1cpu/main.cpp), with the same checks.

const std = @import("std");
const uos = @import("uos");
const board = @import("board");
const tutor = @import("tutor");

const rtos = uos.rtos;
const Sample = tutor.Sample;
const second_timer = tutor.second_timer;
const Timestamp = rtos.Timestamp;
const sysclock = rtos.sysclock;
const hrclock = rtos.hrclock;
const rtclock = rtos.rtclock;

pub const uos_options = board.options(1);

const seed: u32 = 2026;
const four = false;

// ---- Part A: one clock against the System Timer -------------------------------

// What part A measures on one core; the measuring thread may be on any core,
// the main thread prints and checks it.
const ClockProbe = struct {
    mono_sys: bool = true, // 20000 reads in a row: sysclock never back
    mono_hr: bool = true, // nor hrclock
    sleep_us: u32 = 0, // hrclock.sleepUntil(now() + 100 ms), System Timer
    gap: Timestamp = 0, // hrclock.now() - hrclock.steadyNow() after it
};

fn measureClocks(p: *ClockProbe) void {
    var ps = sysclock.now();
    var ph = hrclock.now();
    for (0..20000) |_| {
        const s = sysclock.now();
        const h = hrclock.now();
        if (s < ps) p.mono_sys = false;
        if (h < ph) p.mono_hr = false;
        ps = s;
        ph = h;
    }
    const f: u64 = hrclock.inputClockFrequencyHz();
    const us0 = second_timer.nowUs();
    hrclock.sleepUntil(hrclock.now() + f / 10) catch {};
    p.sleep_us = second_timer.nowUs() -% us0;
    p.gap = hrclock.now() -% hrclock.steadyNow();
}

// hrclock.sleepUntil(now() + 100 ms) must last 100 ms of the System Timer
// (within one tick and the tolerance): now() and the timestamps hrclock's
// sleeps are measured against have the same origin.
fn reportClocks(p: ClockProbe, where: []const u8, tol_us: u32) void {
    board.console("  {s}: monotonic sysclock {s}, hrclock {s}; hrclock.sleep_until(now + 100 ms) {d} us; now - steady_now = {d} cycles\n", .{
        where, if (p.mono_sys) "yes" else "NO", if (p.mono_hr) "yes" else "NO", p.sleep_us, p.gap,
    });
    _ = tutor.check(p.mono_sys and p.mono_hr, "sysclock and hrclock monotonic over 20000 reads ({s})", .{where});
    _ = tutor.check(p.sleep_us + tol_us >= 100000 and p.sleep_us <= 101000 + tol_us, "hrclock.sleep_until(now + 100 ms) lasted 100 ms (+1 tick) ({s})", .{where});
    _ = tutor.check(p.gap <= 2 * @as(u64, uos.port.clock_highres.cyclesPerTick()), "hrclock.now() within two ticks of its steady count ({s})", .{where});
}

// ---- Part B: the samples to sort (the data segment) ---------------------------

const max_sort = 288;
var g_sort: [max_sort]Sample = @splat(.{});

// Sorts n samples with ids first.. five times and returns the shortest time,
// in hrclock cycles (the first run also pays for cold caches); `exact` tells
// whether every sorted checksum equals the reference.
fn timedSort(n: u32, first: u32, exact: *bool) u64 {
    const want = tutor.reference(seed, first, n).sorted_checksum;
    var best: u64 = std.math.maxInt(u64);
    exact.* = true;
    for (0..5) |_| {
        var list: tutor.SampleList = .{};
        for (g_sort[0..n], 0..) |*s, i| {
            const id = first + @as(u32, @intCast(i));
            s.init(id, tutor.generate(seed, id), .data);
            list.push(s);
        }
        const t0 = hrclock.now();
        tutor.sortList(&list);
        const t1 = hrclock.now();
        if (tutor.checksum(list) != want) exact.* = false;
        best = @min(best, t1 - t0);
    }
    return best;
}

// ---- Part C: samplers and background loads ------------------------------------

const n_periods = 20;
const period_ticks: rtos.Duration = 100; // 100 ms
const work_us: u32 = 2000;
const n_abs = if (four) 3 else 1; // absolute samplers: on cores 1-3, or the one CPU
const n_loads = if (four) 4 else 1; // one per core

const SamplerRecord = struct {
    tick: [n_periods]Timestamp = @splat(0), // sysclock at each wake
    us: [n_periods]u32 = @splat(0), // the System Timer at each wake
};
var g_abs: [n_abs]SamplerRecord = @splat(.{});
var g_abs_core: [n_abs]u32 = @splat(99);
var g_rel: SamplerRecord = .{};
var g_samplers_done: rtos.Semaphore = .counting("samplers", n_abs + 1, 0);
var g_stop = std.atomic.Value(bool).init(false);
var g_load_rounds: [n_loads]std.atomic.Value(u32) = @splat(.init(0));
var g_start: Timestamp = 0; // the samplers' common first wake

// The sampler's work: 2 ms of computing.
fn work() void {
    const t = second_timer.nowUs();
    while (second_timer.nowUs() -% t < work_us) {}
}

fn samplerAbsolute(arg: ?*anyopaque) ?*anyopaque {
    const k: usize = @intFromPtr(arg);
    const r = &g_abs[k];
    g_abs_core[k] = board.cpuSlot();
    var next = g_start;
    for (0..n_periods) |i| {
        sysclock.sleepUntil(next) catch {};
        r.tick[i] = sysclock.now();
        r.us[i] = second_timer.nowUs();
        work();
        next += period_ticks; // the next period starts 100 ticks after this one
    }
    g_samplers_done.post() catch {};
    return null;
}

fn samplerRelative(_: ?*anyopaque) ?*anyopaque {
    sysclock.sleepUntil(g_start) catch {};
    for (0..n_periods) |i| {
        g_rel.tick[i] = sysclock.now();
        g_rel.us[i] = second_timer.nowUs();
        work();
        sysclock.sleepFor(period_ticks) catch {}; // 100 ticks after the work ends
    }
    g_samplers_done.post() catch {};
    return null;
}

fn load(arg: ?*anyopaque) ?*anyopaque {
    const c: usize = @intFromPtr(arg);
    while (!g_stop.load(.monotonic)) {
        var local: [18]Sample = undefined;
        var list: tutor.SampleList = .{};
        for (&local, 0..) |*s, i| {
            const id: u32 = 900 + @as(u32, @intCast(i));
            s.init(id, tutor.generate(seed, id), .stack);
            list.push(s);
        }
        tutor.sortList(&list);
        _ = g_load_rounds[c].fetchAdd(1, .monotonic);
    }
    return null;
}

// The largest distance, in µs, of a wake from where period i of an ideal
// 100 ms clock started at the first wake would be.
fn jitterUs(r: SamplerRecord) u32 {
    var worst: u32 = 0;
    for (0..n_periods) |i| {
        const d: i32 = @as(i32, @bitCast(r.us[i] -% r.us[0])) - @as(i32, @intCast(i * period_ticks * 1000));
        worst = @max(worst, @abs(d));
    }
    return worst;
}

// Part A on core 1.
var g_p1: ClockProbe = .{};
fn clocksOnCore1(_: ?*anyopaque) ?*anyopaque {
    measureClocks(&g_p1);
    return null;
}

fn spawn(gpa: std.mem.Allocator, name: [:0]const u8, f: *const fn (?*anyopaque) ?*anyopaque, arg: usize, prio: rtos.Priority, core: ?u32) *rtos.Thread {
    var attr: rtos.Thread.Attributes = .{ .priority = prio, .stack_size_bytes = 8 * 1024 };
    if (core) |c| attr.cpu_affinity = @as(u32, 1) << @intCast(c);
    return rtos.Thread.create(gpa, name, f, @ptrFromInt(arg), attr) catch {
        _ = tutor.check(false, "cannot create {s}", .{name});
        tutor.finish("");
    };
}

pub fn main() void {
    board.uart.init();
    rtos.run(osMain);
}

fn osMain() void {
    const gpa = uos.memory.allocator();
    const self = rtos.this_thread.thread();

    if (four) self.setCpuAffinity(1 << 0);
    tutor.printBanner("04 clocks");
    board.console(if (four) "Lesson 04, four CPUs: the three clocks, timing with hrclock, periodic threads.\n" else "Lesson 04, one CPU: the three clocks, timing with hrclock, periodic threads.\n", .{});
    tutor.printRegions();
    if (four) {
        // ---- Release cores 1-3 (as in lesson 01).
        board.smp.startSecondaryCores();
        const waited = board.smp.waitSecondaries(3000);
        board.console("  cores joined after {d} ms: {s}\n", .{ waited, board.smp.joinSummary() });
        _ = tutor.check(board.smp.secondariesJoined(), "cores 1-{d} joined the scheduler", .{uos.config.ncpu - 1});
    }
    const heap0 = tutor.heapBytes();
    // The bounds: tight on the board, loose under QEMU (not real-time).
    const on_hw = tutor.onHardware();
    const tol_us: u32 = if (on_hw) 200 else 20000;

    // ---- Part A: the three clocks against the System Timer.
    board.console("\n-- part A: the clocks (sysclock {d} Hz, hrclock {d} Hz, rtclock 1 Hz)\n", .{ rtos.Clock.frequency_hz, hrclock.inputClockFrequencyHz() });

    // The rates, over 5000 ticks.
    sysclock.sleepFor(1) catch {};
    const s0 = sysclock.now();
    const h0 = hrclock.now();
    const us0 = second_timer.nowUs();
    sysclock.sleepFor(5000) catch {};
    const s1 = sysclock.now();
    const h1 = hrclock.now();
    const us1 = second_timer.nowUs();
    const sys_us: u32 = @intCast((s1 - s0) * 1000);
    const hr_us: u32 = @intCast((h1 - h0) * 1_000_000 / hrclock.inputClockFrequencyHz());
    const st_us = us1 -% us0;
    board.console("  sleep_for(5000): sysclock +{d} ticks = {d} us, hrclock {d} us, System Timer {d} us\n", .{ s1 - s0, sys_us, hr_us, st_us });
    _ = tutor.check(s1 - s0 == 5000, "sleep_for(5000) slept 5000 ticks", .{});
    _ = tutor.check(sys_us + tol_us >= st_us and st_us + tol_us >= sys_us, "sysclock keeps the System Timer's time (within {d} us in 5 s)", .{tol_us});
    _ = tutor.check(hr_us + tol_us >= st_us and st_us + tol_us >= hr_us, "hrclock keeps the System Timer's time (within {d} us in 5 s)", .{tol_us});
    var p0: ClockProbe = .{};
    measureClocks(&p0);
    reportClocks(p0, "core 0", tol_us);

    // rtclock: from the start of a second, 2.5 s of sysclock is 2 seconds.
    rtclock.sleepFor(1) catch {}; // wakes as the next second begins
    const r0 = rtclock.now();
    sysclock.sleepFor(2500) catch {};
    const r1 = rtclock.now();
    board.console("  rtclock: {d} s, then {d} s after sysclock.sleep_for(2500)\n", .{ r0, r1 });
    _ = tutor.check(r1 - r0 == 2, "rtclock advanced 2 s in 2.5 s from the start of a second", .{});

    if (four) {
        // The same clocks, read from core 1.
        const t1 = spawn(gpa, "core1", clocksOnCore1, 0, rtos.priority.normal, 1);
        _ = t1.join() catch null;
        t1.destroy();
        reportClocks(g_p1, "core 1", tol_us);
    }

    // ---- Part B: timing the sort with hrclock.
    board.console("\n-- part B: the insertion sort timed with hrclock (the best of 5 runs)\n", .{});
    const sizes = [3]u32{ 18, 72, 288 };
    var cyc: [3]u64 = undefined;
    var sorted_exact = true;
    for (sizes, 0..) |n, k| {
        var exact = false;
        cyc[k] = timedSort(n, 1000, &exact);
        if (!exact) sorted_exact = false;
        board.console("  {d: >3} samples: {d: >7} cycles = {d: >5} us, checksum {s}\n", .{ n, cyc[k], cyc[k] * 1_000_000 / hrclock.inputClockFrequencyHz(), if (exact) "exact" else "BAD" });
    }
    _ = tutor.check(sorted_exact, "the three sorts exact", .{});
    // On the board only: QEMU's counter follows the host's clock, and a sort
    // of a few microseconds is below what it can resolve.
    if (on_hw) _ = tutor.check(cyc[0] > 0 and cyc[1] > cyc[0] and cyc[2] > cyc[1], "the time grows with the size", .{});

    // ---- Part C: samplers over background loads.
    board.console("\n-- part C: samplers every {d} ticks, {d} us of work each, over a load at low\n", .{ period_ticks, work_us });
    // The samplers' first wake, set before any of them exists: with four CPUs
    // a sampler starts at once on its own core and reads it.
    g_start = sysclock.now() + 50;
    self.setPriority(rtos.priority.realtime) catch {};
    var tl: [n_loads]*rtos.Thread = undefined;
    for (&tl, 0..) |*t, c| t.* = spawn(gpa, "load", load, c, rtos.priority.low, if (four) @intCast(c) else null);
    var ta: [n_abs]*rtos.Thread = undefined;
    for (&ta, 0..) |*t, k| t.* = spawn(gpa, "absolute", samplerAbsolute, k, rtos.priority.high, if (four) @intCast(k + 1) else null);
    const tr = spawn(gpa, "relative", samplerRelative, 0, rtos.priority.above_normal, if (four) 0 else null);
    // Main waits on `done`, not in join(): the loads never block, so the idle
    // thread -- which completes join() -- cannot run while they compute
    // (lesson 03).
    self.setPriority(rtos.priority.normal) catch {};
    for (0..n_abs + 1) |_| g_samplers_done.wait() catch {};
    g_stop.store(true, .monotonic);
    for (tl) |t| _ = t.join() catch null;
    for (ta) |t| _ = t.join() catch null;
    _ = tr.join() catch null;
    for (ta) |t| t.destroy();
    for (tl) |t| t.destroy();
    tr.destroy();

    var abs_exact = true;
    var on_core = true;
    var abs_jit: u32 = 0;
    for (g_abs, 0..) |r, k| {
        for (r.tick, 0..) |t, i| {
            // Exactly on the tick on the board; under QEMU a host hiccup may
            // make a wake one tick late.
            const want = g_start + i * period_ticks;
            if (t < want or t > want + @as(u64, if (on_hw) 0 else 1)) abs_exact = false;
        }
        if (four and g_abs_core[k] != k + 1) on_core = false;
        const j = jitterUs(r);
        abs_jit = @max(abs_jit, j);
        if (four) {
            board.console("  absolute on core {d}: wakes at +{d}, +{d}, ..., +{d} ticks; span {d} ticks; jitter {d} us\n", .{ g_abs_core[k], r.tick[0] - g_start, r.tick[1] - g_start, r.tick[n_periods - 1] - g_start, r.tick[n_periods - 1] - r.tick[0], j });
        } else {
            board.console("  absolute: wakes at +{d}, +{d}, ..., +{d} ticks; span {d} ticks; jitter {d} us\n", .{ r.tick[0] - g_start, r.tick[1] - g_start, r.tick[n_periods - 1] - g_start, r.tick[n_periods - 1] - r.tick[0], j });
        }
    }
    const rel_span = g_rel.tick[n_periods - 1] - g_rel.tick[0];
    board.console("  relative{s}: wakes at +{d}, +{d}, ..., +{d} ticks; span {d} ticks (drift {d} ticks)\n", .{ if (four) " on core 0" else "", g_rel.tick[0] - g_start, g_rel.tick[1] - g_start, g_rel.tick[n_periods - 1] - g_start, rel_span, rel_span - (n_periods - 1) * period_ticks });
    var loads = true;
    for (&g_load_rounds) |*l| {
        if (l.load(.monotonic) == 0) loads = false;
    }
    if (four) {
        board.console("  the loads: {d}, {d}, {d}, {d} rounds in the gaps (cores 0-3)\n", .{ g_load_rounds[0].load(.monotonic), g_load_rounds[1 % n_loads].load(.monotonic), g_load_rounds[2 % n_loads].load(.monotonic), g_load_rounds[3 % n_loads].load(.monotonic) });
        _ = tutor.check(on_core, "the absolute samplers ran on cores 1, 2, 3", .{});
        _ = tutor.check(abs_exact, "sleep_until: every wake on every core exactly on its tick (start + 100 i): same ticks on all three", .{});
    } else {
        board.console("  the load: {d} rounds in the gaps\n", .{g_load_rounds[0].load(.monotonic)});
        _ = tutor.check(abs_exact, "sleep_until: every wake exactly on its tick (start + 100 i)", .{});
        _ = tutor.check(g_abs[0].tick[n_periods - 1] - g_abs[0].tick[0] <= (n_periods - 1) * period_ticks + @as(u64, if (on_hw) 0 else 1) and
            g_abs[0].tick[n_periods - 1] - g_abs[0].tick[0] + @as(u64, if (on_hw) 0 else 1) >= (n_periods - 1) * period_ticks, "sleep_until: 20 wakes span exactly 1900 ticks", .{});
    }
    _ = tutor.check(abs_jit <= tol_us, if (four) "sleep_until: every wake within {d} us of the ideal period (worst {d} us)" else "sleep_until: every wake within {d} us of the ideal period ({d} us)", .{ tol_us, abs_jit });
    // The work adds about 2 ticks to every period (102 on the board); at least
    // one, whatever the phase of the work against the tick.
    _ = tutor.check(rel_span >= (n_periods - 1) * (period_ticks + 1), "sleep_for: the period grew by the work (span >= 19 x 101 ticks): it drifts", .{});
    _ = tutor.check(loads, if (four) "every core's load ran in the gaps" else "the load ran in the gaps", .{});
    _ = tutor.check(tutor.heapBytes() == heap0, "heap back to {d} B", .{heap0});

    tutor.finish(if (four) "three clocks consistent on cores 0 and 1, sort timed, sleep_until exact on cores 1-3, sleep_for drifts; four CPUs" else "three clocks consistent, sort timed, sleep_until exact, sleep_for drifts; one CPU");
}
