//! tutor-03-priorities-4cpu -- lesson 03, four CPUs (see ../README.md).
//!
//! The one-CPU lesson on four cores, where priorities mean something else.
//!
//! Part A, priorities: the three workers at low, normal and high priority are
//! pinned to cores 1, 2 and 3. Each is the highest-priority thread *of its
//! core*, so all three run at the same time: priority orders the threads
//! competing for one CPU, it does not serialize threads on different CPUs.
//! Each waits at a barrier until all three are running -- with one CPU none
//! would ever pass it -- and the test checks they overlap (each started
//! before any finished).
//!
//! Part B, preemption by an interrupt, on core 1: the busy thread (low) and
//! the responder (high) are both pinned to core 1, and the responder arms the
//! second interrupt (its core's virtual timer, every 5 ms) there, so every
//! interrupt runs on core 1 and the preemption happens on core 1 while the
//! main thread waits on core 0.
//!
//! The Zig version of the C++ lesson (golden workspace,
//! test/rpi4b/tutor/03-priorities/4cpu/main.cpp), with the same data.

const std = @import("std");
const uos = @import("uos");
const board = @import("board");
const tutor = @import("tutor");

const rtos = uos.rtos;
const Sample = tutor.Sample;
const second_timer = tutor.second_timer;

pub const uos_options = board.options(4);

// The port's external-interrupt hook: the second interrupt.
pub const uos_external_irq = second_timer.onIrq;

const seed: u32 = 2026;
const per_round = 18;

// ---- One round of work: lesson 02's steps on the caller's stack ---------------

// Builds `per_round` samples with ids first.. on the stack, sorts them and
// returns the sorted checksum.
fn oneRound(first: u32) u32 {
    var local: [per_round]Sample = undefined;
    var list: tutor.SampleList = .{};
    for (&local, 0..) |*s, i| {
        const id = first + @as(u32, @intCast(i));
        s.init(id, tutor.generate(seed, id), .stack);
        list.push(s);
    }
    tutor.sortList(&list);
    return tutor.checksum(list);
}

// ---- Part A: three priorities ---------------------------------------------------

const n_workers = 3;
const rounds_a = 400;
const prio_of = [n_workers]rtos.Priority{ rtos.priority.low, rtos.priority.normal, rtos.priority.high };
const name_of = [n_workers][:0]const u8{ "low", "normal", "high" };

const WorkerRecord = struct {
    start_us: u32 = 0,
    end_us: u32 = 0,
    start_seq: u32 = 0,
    end_seq: u32 = 0,
    bad_rounds: u32 = 0,
    core: u32 = 0,
};
var g_rec: [n_workers]WorkerRecord = @splat(.{});
var g_seq = std.atomic.Value(u32).init(0);
var g_ref_a: [n_workers]u32 = undefined;
var g_go = std.atomic.Value(bool).init(false);
var g_running = std.atomic.Value(u32).init(0); // the start barrier

fn worker(arg: ?*anyopaque) ?*anyopaque {
    const w: usize = @intFromPtr(arg);
    const r = &g_rec[w];
    while (!g_go.load(.acquire)) {}
    r.start_us = second_timer.nowUs();
    r.start_seq = g_seq.fetchAdd(1, .monotonic);
    // The barrier: wait until all three are running. Only possible because
    // they run at the same time, each on its core; with one CPU it would
    // never be passed (no worker gives the CPU away).
    _ = g_running.fetchAdd(1, .acq_rel);
    while (g_running.load(.acquire) < n_workers) {}
    for (0..rounds_a) |_| {
        if (oneRound(@intCast(100 * w)) != g_ref_a[w]) r.bad_rounds += 1;
    }
    r.end_us = second_timer.nowUs();
    r.end_seq = g_seq.fetchAdd(1, .monotonic);
    r.core = board.cpuSlot();
    return null;
}

// ---- Part B: an interrupt preempts a busy thread ------------------------------

const n_irq = 100;
const period_us: u32 = 5000;

var g_sem: rtos.Semaphore = .counting("irq", n_irq, 0);
var g_done: rtos.Semaphore = .binary("done", 0); // the responder -> main: all handled
var g_isr_us = std.atomic.Value(u32).init(0); // when the last interrupt ran
var g_fired = std.atomic.Value(u32).init(0);
var g_stop = std.atomic.Value(bool).init(false);
var g_busy_rounds = std.atomic.Value(u32).init(0);
var g_busy_bad: u32 = 0;
var g_ref_b: u32 = 0;
var g_t0: u32 = 0; // the responder's first and last interrupt
var g_t1: u32 = 0;
var g_resp_core = std.atomic.Value(u32).init(99);

const Response = struct { latency_us: u32 = 0, busy_rounds: u32 = 0 };
var g_resp: [n_irq]Response = @splat(.{});

// Interrupt context: stamp the time, wake the responder.
fn onSecondTimer(_: ?*anyopaque) void {
    g_isr_us.store(second_timer.nowUs(), .monotonic);
    if (g_fired.load(.monotonic) < n_irq) {
        _ = g_fired.fetchAdd(1, .monotonic);
        g_sem.post() catch {};
    }
}

fn busy(_: ?*anyopaque) ?*anyopaque {
    // Never blocks, never yields: only a higher-priority thread made ready
    // by an interrupt can take the CPU from it.
    while (!g_stop.load(.monotonic)) {
        if (oneRound(900) != g_ref_b) g_busy_bad += 1;
        _ = g_busy_rounds.fetchAdd(1, .monotonic);
    }
    return null;
}

fn responder(_: ?*anyopaque) ?*anyopaque {
    // The timer is the core's own: armed here, it interrupts this core.
    g_t0 = second_timer.nowUs();
    second_timer.start(period_us, onSecondTimer, null);
    g_resp_core.store(board.cpuSlot(), .monotonic);
    for (&g_resp) |*r| {
        g_sem.wait() catch {};
        r.latency_us = second_timer.nowUs() -% g_isr_us.load(.monotonic);
        r.busy_rounds = g_busy_rounds.load(.monotonic);
    }
    g_t1 = second_timer.nowUs();
    second_timer.stop();
    g_done.post() catch {};
    return null;
}

pub fn main() void {
    board.uart.init();
    rtos.run(osMain);
}

fn osMain() void {
    const gpa = uos.memory.allocator();
    const self = rtos.this_thread.thread();

    self.setCpuAffinity(1 << 0);
    tutor.printBanner("03 priorities");
    board.console("Lesson 03, four CPUs: priorities, and preemption by a second interrupt.\n", .{});
    tutor.printRegions();

    // ---- Release cores 1-3 (as in lesson 01).
    board.smp.startSecondaryCores();
    const waited = board.smp.waitSecondaries(3000);
    board.console("  cores joined after {d} ms: {s}\n", .{ waited, board.smp.joinSummary() });
    _ = tutor.check(board.smp.secondariesJoined(), "cores 1-{d} joined the scheduler", .{uos.config.ncpu - 1});
    const heap0 = tutor.heapBytes();
    // The board must answer within 1 ms; under QEMU the bound is loose (its
    // cores are host threads, not real-time).
    const on_hw = tutor.onHardware();
    const latency_bound_us: u32 = if (on_hw) 1000 else 20000;

    // The references, computed once here (reference() is not reentrant).
    for (&g_ref_a, 0..) |*r, w| r.* = tutor.reference(seed, @intCast(100 * w), per_round).sorted_checksum;
    g_ref_b = tutor.reference(seed, 900, per_round).sorted_checksum;

    // ---- Part A.
    //
    // The main thread runs at realtime, above all three, while it creates them
    // (lowest first), so that none runs before all exist; then it releases them
    // and blocks in join().
    board.console("\n-- part A: three workers, low on core 1, normal on core 2, high on core 3\n", .{});
    self.setPriority(rtos.priority.realtime) catch {};
    var th: [n_workers]*rtos.Thread = undefined;
    for (0..n_workers) |w| {
        // New with four CPUs: one core each.
        const attr: rtos.Thread.Attributes = .{ .priority = prio_of[w], .stack_size_bytes = 8 * 1024, .cpu_affinity = @as(u32, 1) << @intCast(w + 1) };
        th[w] = rtos.Thread.create(gpa, name_of[w], worker, @ptrFromInt(w), attr) catch {
            _ = tutor.check(false, "cannot create worker {d}", .{w});
            tutor.finish("");
        };
    }
    g_go.store(true, .release);
    for (th) |t| _ = t.join() catch null;

    var base = g_rec[0].start_us; // the earliest start
    for (g_rec) |r| {
        if (@as(i32, @bitCast(r.start_us -% base)) < 0) base = r.start_us;
    }
    var exact = true;
    for (g_rec, 0..) |r, w| {
        board.console("  {s: <6} core {d}, started #{d}, finished #{d}, ran {d} us .. {d} us ({d} us), {d} bad rounds\n", .{
            name_of[w], r.core, r.start_seq, r.end_seq, r.start_us -% base, r.end_us -% base, r.end_us -% r.start_us, r.bad_rounds,
        });
        if (r.bad_rounds != 0) exact = false;
    }
    _ = tutor.check(exact, "every worker's {d} rounds exact", .{rounds_a});
    // Run at the same time: every start (sequence 0, 1, 2) before any end.
    var overlap = true;
    var on_core = true;
    for (g_rec, 0..) |r, w| {
        if (r.start_seq > 2) overlap = false;
        if (r.core != w + 1) on_core = false;
    }
    _ = tutor.check(on_core, "each worker ran on its own core (low 1, normal 2, high 3)", .{});
    _ = tutor.check(overlap, "four CPUs: the three priorities ran at the same time (all started before any finished)", .{});
    for (th) |t| t.destroy();

    // ---- Part B.
    //
    // The busy thread at low, the responder at high; main at normal now, so
    // that it does not compete with the responder, and blocked on `done`.
    //
    // Not in join(): in µOS++ a thread that returns is only queued as
    // terminated; the *idle thread* destroys it and wakes its joiner. The busy
    // thread never blocks, so the idle thread never runs and a join() on the
    // responder would never return while the busy thread computes. The
    // responder posts `done` instead; main, above the busy thread, wakes,
    // stops it, and joins both once the CPU can go idle.
    board.console("\n-- part B: on core 1, a busy thread at low, a responder at high, the virtual timer every {d} us\n", .{period_us});
    const tb = rtos.Thread.create(gpa, "busy", busy, null, .{ .priority = rtos.priority.low, .stack_size_bytes = 8 * 1024, .cpu_affinity = 1 << 1 }) catch {
        _ = tutor.check(false, "cannot create the busy thread", .{});
        tutor.finish("");
    };
    const tr = rtos.Thread.create(gpa, "responder", responder, null, .{ .priority = rtos.priority.high, .stack_size_bytes = 8 * 1024, .cpu_affinity = 1 << 1 }) catch {
        _ = tutor.check(false, "cannot create the responder", .{});
        tutor.finish("");
    };
    self.setPriority(rtos.priority.normal) catch {};

    g_done.wait() catch {};
    g_stop.store(true, .monotonic);
    _ = tb.join() catch null;
    _ = tr.join() catch null;
    tr.destroy();
    tb.destroy();

    var lat_max: u32 = 0;
    var lat_sum: u32 = 0;
    var progressed: u32 = 0; // pairs of interrupts with busy rounds in between
    for (g_resp, 0..) |r, i| {
        lat_max = @max(lat_max, r.latency_us);
        lat_sum += r.latency_us;
        if (i > 0 and r.busy_rounds > g_resp[i - 1].busy_rounds) progressed += 1;
    }
    board.console("  {d} interrupts in {d} us (ISR count {d}, on cores mask {x})\n", .{ g_fired.load(.monotonic), g_t1 -% g_t0, second_timer.count(), second_timer.cpusSeen() });
    board.console("  latency ISR -> responder: max {d} us, mean {d} us\n", .{ lat_max, lat_sum / n_irq });
    board.console("  busy thread: {d} rounds, {d} bad; at the responder's wakes: {d}, {d}, ..., {d}\n", .{ g_busy_rounds.load(.monotonic), g_busy_bad, g_resp[0].busy_rounds, g_resp[1].busy_rounds, g_resp[n_irq - 1].busy_rounds });

    _ = tutor.check(g_fired.load(.monotonic) == n_irq and second_timer.count() >= n_irq, "the second interrupt fired {d} times", .{n_irq});
    _ = tutor.check(g_resp_core.load(.monotonic) == 1 and second_timer.cpusSeen() == 1 << 1, "the responder and every interrupt ran on core 1", .{});
    _ = tutor.check(lat_max <= latency_bound_us, "every interrupt handled by the responder within {d} us (max {d} us)", .{ latency_bound_us, lat_max });
    // Every pair on the board; under QEMU a host hiccup may deliver two
    // interrupts back to back, so 90% of the pairs.
    _ = tutor.check(progressed == n_irq - 1 or (!on_hw and progressed >= (n_irq - 1) * 9 / 10), "the busy thread progressed between {d} of {d} pairs of interrupts (preempted, then resumed)", .{ progressed, n_irq - 1 });
    _ = tutor.check(g_busy_rounds.load(.monotonic) > 0 and g_busy_bad == 0, "every busy round exact", .{});
    _ = tutor.check(tutor.heapBytes() == heap0, "heap back to {d} B", .{heap0});

    tutor.finish("priorities run in parallel on separate cores; a timer interrupt preempts a busy thread on core 1; four CPUs");
}
