//! tutor-08-critical-sections-4cpu -- lesson 08, four CPUs (see ../README.md).
//!
//! Part A, lost updates across cores: threads on cores 1 and 2 (200 updates
//! each: a read, a 30 us window, a write) and the second timer's ISR on
//! core 0 add one to a shared counter; the ISR under an interrupt critical
//! section. With no lock and under the scheduler lock (which is per core)
//! updates are lost; under the interrupt lock, which on several CPUs also
//! takes the kernel spinlock, none.
//!
//! Part B, what each excludes on four cores: core 0's scheduler section does
//! not stop a high thread made ready on core 1, only the one on core 0. Core
//! 0's interrupt section stops core 0's ISR and a thread on core 1 that
//! enters an interrupt section (at the spinlock), not a thread on core 2 that
//! does not; an interrupt uncritical section inside lets core 0's ISR in but
//! keeps the spinlock.
//!
//! Part C, what each costs: the ISR's lateness on core 0, and the wake-up
//! latency of a high thread on core 2 posted by core 0's ISR, with no lock
//! and under core 0's sections: the scheduler lock of core 0 does not delay
//! core 2's thread.
//!
//! The Zig version of the C++ lesson (golden workspace,
//! test/rpi4b/tutor/08-critical-sections/4cpu/main.cpp), with the same checks.

const std = @import("std");
const uos = @import("uos");
const board = @import("board");
const tutor = @import("tutor");

const rtos = uos.rtos;
const scheduler = rtos.scheduler;
const interrupts = rtos.interrupts;
const second_timer = tutor.second_timer;
const prio = rtos.priority;

pub const uos_options = board.options(4);

// The port's external-interrupt hook: the second interrupt.
pub const uos_external_irq = second_timer.onIrq;

const four = true;

// Busy for `us` microseconds, on the System Timer's clock.
fn spinUs(us: u32) void {
    const t0 = second_timer.nowUs();
    while (second_timer.nowUs() -% t0 < us) {}
}

fn spawn(gpa: std.mem.Allocator, name: [:0]const u8, f: *const fn (?*anyopaque) ?*anyopaque, arg: usize, p: rtos.Priority, core: ?u32) *rtos.Thread {
    var attr: rtos.Thread.Attributes = .{ .priority = p, .stack_size_bytes = 8 * 1024 };
    if (core) |c| attr.cpu_affinity = @as(u32, 1) << @intCast(c);
    return rtos.Thread.create(gpa, name, f, @ptrFromInt(arg), attr) catch {
        _ = tutor.check(false, "cannot create {s}", .{name});
        tutor.finish("");
    };
}

// ---- Part A: a counter updated by threads and by an ISR -----------------------

const n_updates = if (four) 200 else 400; // per thread
const window_us: u32 = 30; // between the read and the write
const count_period_us: u32 = 100;

// Separate loads and stores: the read-modify-write is not atomic.
var g_counter = std.atomic.Value(u32).init(0);
var g_isr_adds = std.atomic.Value(u32).init(0); // written by the ISR only

fn onCount(_: ?*anyopaque) void {
    // On several CPUs an ISR must lock too: masking interrupts on core 0
    // does nothing to the threads on cores 1 and 2.
    const ics = if (four) interrupts.CriticalSection.enter() else {};
    defer if (four) ics.exit();
    g_counter.store(g_counter.load(.monotonic) + 1, .monotonic);
    g_isr_adds.store(g_isr_adds.load(.monotonic) + 1, .monotonic);
}

const LockKind = enum(usize) { none, scheduler, interrupts };

fn kindName(k: LockKind) []const u8 {
    return switch (k) {
        .none => "no lock",
        .scheduler => "scheduler lock",
        .interrupts => "interrupt lock",
    };
}

fn update() void {
    const v = g_counter.load(.monotonic);
    spinUs(window_us);
    g_counter.store(v + 1, .monotonic);
}

fn updates(k: LockKind) void {
    for (0..n_updates) |i| {
        switch (k) {
            .scheduler => {
                const scs = scheduler.CriticalSection.enter();
                defer scs.exit();
                update();
            },
            .interrupts => {
                const ics = interrupts.CriticalSection.enter();
                defer ics.exit();
                update();
            },
            .none => update(),
        }
        // A gap of 13 .. 35 us: a fixed one would lock the loop to the ISR's
        // period, and the ISR would always fall in the same place.
        spinUs(13 + @as(u32, @intCast((i * 7) % 23)));
    }
}

fn updater(arg: ?*anyopaque) ?*anyopaque {
    updates(@enumFromInt(@intFromPtr(arg)));
    return null;
}

// The updates under `k` (one CPU: the main thread's 400; four: 2 x 200 on
// cores 1 and 2), the ISR adding meanwhile; the updates lost.
fn race(gpa: std.mem.Allocator, k: LockKind) u32 {
    g_counter.store(0, .monotonic);
    g_isr_adds.store(0, .monotonic);
    second_timer.start(count_period_us, onCount, null); // on core 0
    if (four) {
        const t1 = spawn(gpa, "upd1", updater, @intFromEnum(k), prio.normal, 1);
        const t2 = spawn(gpa, "upd2", updater, @intFromEnum(k), prio.normal, 2);
        for ([_]*rtos.Thread{ t1, t2 }) |t| {
            _ = t.join() catch null;
            t.destroy();
        }
    } else updates(k);
    second_timer.stop();
    const isr = g_isr_adds.load(.monotonic);
    const n_threads: u32 = if (four) 2 else 1;
    const expect = n_threads * n_updates + isr;
    const counter = g_counter.load(.monotonic);
    const lost = expect -% counter;
    if (four) {
        board.console("  {s: <14}: threads 2 x {d} + ISR {d} = {d} expected, counter {d}, lost {d}\n", .{ kindName(k), n_updates, isr, expect, counter, lost });
    } else {
        board.console("  {s: <14}: thread {d} + ISR {d} = {d} expected, counter {d}, lost {d}\n", .{ kindName(k), n_updates, isr, expect, counter, lost });
    }
    return lost;
}

// ---- Part B: a high thread made ready inside a section --------------------------

var g_h_sem = [2]rtos.Semaphore{ .counting("h0", 10, 0), .counting("h1", 10, 0) };
var g_h_runs = [2]std.atomic.Value(u32){ .init(0), .init(0) };
var g_stop = std.atomic.Value(bool).init(false);

fn highThread(arg: ?*anyopaque) ?*anyopaque {
    const i = @intFromPtr(arg);
    while (true) {
        g_h_sem[i].wait() catch {};
        if (g_stop.load(.monotonic)) break;
        _ = g_h_runs[i].fetchAdd(1, .monotonic);
    }
    return null;
}

var g_c_locked = std.atomic.Value(u32).init(0); // core 1, inside interrupt sections
var g_c_free = std.atomic.Value(u32).init(0); // core 2, no lock

fn locker(_: ?*anyopaque) ?*anyopaque {
    while (!g_stop.load(.monotonic)) {
        {
            const ics = interrupts.CriticalSection.enter();
            defer ics.exit();
            _ = g_c_locked.fetchAdd(1, .monotonic);
        }
        spinUs(5);
    }
    return null;
}

fn freeRunner(_: ?*anyopaque) ?*anyopaque {
    while (!g_stop.load(.monotonic)) {
        _ = g_c_free.fetchAdd(1, .monotonic);
        spinUs(5);
    }
    return null;
}

// ---- Part C: the ISR's lateness, and a woken thread's latency ------------------

var g_last_us: u32 = 0;
var g_gap_max = std.atomic.Value(u32).init(0);
var g_gap_armed = std.atomic.Value(bool).init(false);

fn onGap(_: ?*anyopaque) void {
    const t = second_timer.nowUs();
    if (g_gap_armed.load(.monotonic)) {
        const gap = t -% g_last_us;
        if (gap > g_gap_max.load(.monotonic)) g_gap_max.store(gap, .monotonic);
    }
    g_last_us = t;
    g_gap_armed.store(true, .monotonic);
}

// The longest gap between the ISR's runs while main spends 20 ms, in 1 ms
// sections of kind `k`.
fn isrGap(k: LockKind) u32 {
    g_gap_max.store(0, .monotonic);
    g_gap_armed.store(false, .monotonic);
    second_timer.start(count_period_us, onGap, null);
    spinUs(500);
    g_gap_max.store(0, .monotonic);
    for (0..20) |_| {
        switch (k) {
            .scheduler => {
                const scs = scheduler.CriticalSection.enter();
                defer scs.exit();
                spinUs(1000);
            },
            .interrupts => {
                const ics = interrupts.CriticalSection.enter();
                defer ics.exit();
                spinUs(1000);
            },
            .none => spinUs(1000),
        }
    }
    second_timer.stop();
    return g_gap_max.load(.monotonic);
}

const wake_period_us: u32 = 2000;
const n_wakes = 5;

var g_wake: rtos.Semaphore = .counting("wake", 20, 0);
var g_wake_isr_us = std.atomic.Value(u32).init(0); // when the ISR posted
var g_wake_isrs = std.atomic.Value(u32).init(0);
var g_wake_lat_max = std.atomic.Value(u32).init(0);
var g_wake_stop = std.atomic.Value(bool).init(false);
var g_woken_core: u32 = 99;

fn onWake(_: ?*anyopaque) void {
    g_wake_isr_us.store(second_timer.nowUs(), .monotonic);
    _ = g_wake_isrs.fetchAdd(1, .monotonic);
    g_wake.post() catch {};
}

fn wokenThread(_: ?*anyopaque) ?*anyopaque {
    g_woken_core = board.cpuSlot();
    while (true) {
        g_wake.wait() catch {};
        if (g_wake_stop.load(.monotonic)) break;
        const lat = second_timer.nowUs() -% g_wake_isr_us.load(.monotonic);
        if (lat > g_wake_lat_max.load(.monotonic)) g_wake_lat_max.store(lat, .monotonic);
    }
    return null;
}

const WakeResult = struct {
    lat_max: u32, // ISR -> thread
    isr_late: u32, // interrupt section: from its end to the ISR, max
};

fn waitIsr(n0: u32) void {
    while (g_wake_isrs.load(.monotonic) == n0) {}
}

// n_wakes interrupts, each posting the high thread, while main holds a
// section of kind `k`: a scheduler section from just after the interrupt
// for 1 ms; an interrupt section of 2.5 ms, longer than the period, so that
// one interrupt falls due inside it.
fn wakeLatency(k: LockKind) WakeResult {
    var r: WakeResult = .{ .lat_max = 0, .isr_late = 0 };
    g_wake_lat_max.store(0, .monotonic);
    g_wake_isrs.store(0, .monotonic);
    second_timer.start(wake_period_us, onWake, null);
    for (0..n_wakes) |_| {
        switch (k) {
            .scheduler => {
                const scs = scheduler.CriticalSection.enter();
                defer scs.exit();
                waitIsr(g_wake_isrs.load(.monotonic)); // interrupts run inside
                spinUs(1000);
            },
            .interrupts => {
                const n0 = g_wake_isrs.load(.monotonic);
                var end: u32 = undefined;
                {
                    const ics = interrupts.CriticalSection.enter();
                    defer ics.exit();
                    spinUs(2500);
                    end = second_timer.nowUs();
                }
                waitIsr(n0);
                r.isr_late = @max(r.isr_late, g_wake_isr_us.load(.monotonic) -% end);
            },
            .none => waitIsr(g_wake_isrs.load(.monotonic)),
        }
        spinUs(100); // the thread has run
    }
    second_timer.stop();
    r.lat_max = g_wake_lat_max.load(.monotonic);
    return r;
}

pub fn main() void {
    board.uart.init();
    rtos.run(osMain);
}

fn osMain() void {
    const gpa = uos.memory.allocator();
    const self = rtos.this_thread.thread();

    if (four) self.setCpuAffinity(1 << 0);
    tutor.printBanner("08 critical sections");
    board.console(if (four) "Lesson 08, four CPUs: scheduler and interrupt critical sections, what each excludes and costs.\n" else "Lesson 08, one CPU: scheduler and interrupt critical sections, what each excludes and costs.\n", .{});
    tutor.printRegions();
    if (four) {
        // ---- Release cores 1-3 (as in lesson 01).
        board.smp.startSecondaryCores();
        const waited = board.smp.waitSecondaries(3000);
        board.console("  cores joined after {d} ms: {s}\n", .{ waited, board.smp.joinSummary() });
        _ = tutor.check(board.smp.secondariesJoined(), "cores 1-{d} joined the scheduler", .{uos.config.ncpu - 1});
    }
    const heap0 = tutor.heapBytes();
    const lat_bound_us: u32 = if (tutor.onHardware()) 100 else 20000;

    // ---- Part A.
    if (four) {
        board.console("\n-- part A: threads on cores 1 and 2 and an ISR on core 0 (every {d} us) update one counter; 2 x {d} updates, a {d} us window each\n", .{ count_period_us, n_updates, window_us });
    } else {
        board.console("\n-- part A: a thread and an ISR (every {d} us) update one counter; {d} updates, a {d} us window each\n", .{ count_period_us, n_updates, window_us });
    }
    const lost_none = race(gpa, .none);
    const lost_sched = race(gpa, .scheduler);
    const lost_irq = race(gpa, .interrupts);
    if (four) {
        _ = tutor.check(lost_none > 0, "no lock: updates are lost ({d})", .{lost_none});
        _ = tutor.check(lost_sched > 0, "scheduler lock: still lost ({d}): it holds one core only", .{lost_sched});
        _ = tutor.check(lost_irq == 0, "interrupt lock (and the kernel spinlock): none lost", .{});
    } else {
        _ = tutor.check(lost_none > 0, "no lock: the ISR's updates in the window are lost ({d})", .{lost_none});
        _ = tutor.check(lost_sched > 0, "scheduler lock: still lost ({d}): it does not stop interrupts", .{lost_sched});
        _ = tutor.check(lost_irq == 0, "interrupt lock: none lost", .{});
    }

    // ---- Part B.
    if (four) partB4(gpa) else partB1(gpa);

    // ---- Part C.
    board.console(if (four) "\n-- part C: the cost: core 0's ISR's longest gap (period {d} us), main in 1 ms sections on core 0\n" else "\n-- part C: the cost: the ISR's longest gap (period {d} us), main in 1 ms sections\n", .{count_period_us});
    const gap_none = isrGap(.none);
    const gap_sched = isrGap(.scheduler);
    const gap_irq = isrGap(.interrupts);
    board.console("  ISR gap max: no lock {d} us, scheduler lock {d} us, interrupt lock {d} us\n", .{ gap_none, gap_sched, gap_irq });
    if (tutor.onHardware())
        _ = tutor.check(gap_none <= count_period_us + 50 and gap_sched <= count_period_us + 50, "the scheduler lock does not delay the ISR (gap <= {d} us)", .{count_period_us + 50});
    _ = tutor.check(gap_irq >= 900, "the interrupt lock delays it by the section (gap >= 900 us)", .{});

    board.console(if (four) "-- part C: a high thread on core 2 woken by core 0's ISR (every {d} us), {d} times under each\n" else "-- part C: a high thread woken by the ISR (every {d} us), {d} times under each\n", .{ wake_period_us, n_wakes });
    {
        const tw = spawn(gpa, "woken", wokenThread, 0, prio.high, if (four) 2 else null);
        const w_none = wakeLatency(.none);
        const w_sched = wakeLatency(.scheduler);
        const w_irq = wakeLatency(.interrupts);
        if (four) {
            board.console("  ISR -> thread max: no lock {d} us, core 0 scheduler section (1 ms) {d} us, interrupt section {d} us (the ISR itself {d} us after the section's end); thread on core {d}\n", .{ w_none.lat_max, w_sched.lat_max, w_irq.lat_max, w_irq.isr_late, g_woken_core });
        } else {
            board.console("  ISR -> thread max: no lock {d} us, scheduler section (1 ms) {d} us, interrupt section {d} us (the ISR itself {d} us after the section's end)\n", .{ w_none.lat_max, w_sched.lat_max, w_irq.lat_max, w_irq.isr_late });
        }
        _ = tutor.check(w_none.lat_max <= lat_bound_us, "no lock: the thread within {d} us", .{lat_bound_us});
        if (four) {
            _ = tutor.check(w_sched.lat_max <= lat_bound_us and g_woken_core == 2, "core 0's scheduler section does not delay the thread on core 2 (within {d} us)", .{lat_bound_us});
        } else {
            _ = tutor.check(w_sched.lat_max >= 1000 and w_sched.lat_max <= 1000 + lat_bound_us, "scheduler section: the thread waits for its end (>= 1000 us)", .{});
        }
        _ = tutor.check(w_irq.isr_late <= lat_bound_us and w_irq.lat_max <= lat_bound_us, "interrupt section: the ISR waits for its end, then the thread at once", .{});
        g_wake_stop.store(true, .monotonic);
        g_wake.post() catch {};
        _ = tw.join() catch null;
        tw.destroy();
    }

    _ = tutor.check(tutor.heapBytes() == heap0, "heap back to {d} B", .{heap0});
    tutor.finish(if (four) "updates lost under the per-core scheduler lock, none under the interrupt lock and spinlock; core 0's sections and the other cores; four CPUs" else "the scheduler lock loses ISR updates and delays threads, the interrupt lock loses none and delays the ISR; one CPU");
}

fn runs(i: usize) u32 {
    return g_h_runs[i].load(.monotonic);
}

fn isrAdds() u32 {
    return g_isr_adds.load(.monotonic);
}

// One CPU: the ISR and a high thread, inside each section.
fn partB1(gpa: std.mem.Allocator) void {
    board.console("\n-- part B: inside each section, the ISR (every {d} us) and a high thread made ready\n", .{count_period_us});
    const th = spawn(gpa, "high", highThread, 0, prio.high, null);
    second_timer.start(count_period_us, onCount, null);

    var h_in: u32 = undefined;
    var isr_in: u32 = undefined;
    var locked_in: bool = undefined;
    const r0 = runs(0);
    {
        const n0 = isrAdds();
        const scs = scheduler.CriticalSection.enter();
        g_h_sem[0].post() catch {};
        spinUs(2000);
        h_in = runs(0) - r0;
        isr_in = isrAdds() - n0;
        locked_in = scheduler.locked();
        scs.exit();
    }
    const h_after = runs(0) - r0;
    const locked_after = scheduler.locked();
    var h_uncrit: u32 = undefined;
    {
        const scs = scheduler.CriticalSection.enter();
        defer scs.exit();
        const r1 = runs(0);
        const sucs = scheduler.UncriticalSection.enter();
        g_h_sem[0].post() catch {};
        h_uncrit = runs(0) - r1;
        sucs.exit();
    }
    board.console("  scheduler section, 2 ms: ISR ran {d} times, high thread {d} times inside, {d} after; locked() {} inside, {} after; inside an uncritical section the thread ran {d}\n", .{ isr_in, h_in, h_after, locked_in, locked_after, h_uncrit });
    _ = tutor.check(isr_in > 0, "scheduler section: interrupts keep running", .{});
    _ = tutor.check(h_in == 0 and h_after == 1, "scheduler section: no switch inside, the high thread runs as it ends", .{});
    _ = tutor.check(locked_in and !locked_after, "scheduler::locked () true inside, false after", .{});
    _ = tutor.check(h_uncrit == 1, "scheduler uncritical section: the high thread runs at once", .{});

    var irq_in: u32 = undefined;
    const n0 = isrAdds();
    {
        const ics = interrupts.CriticalSection.enter();
        defer ics.exit();
        spinUs(2000);
        irq_in = isrAdds() - n0;
    }
    const irq_after = isrAdds() - n0;
    var irq_uncrit: u32 = undefined;
    {
        const ics = interrupts.CriticalSection.enter();
        defer ics.exit();
        const n1 = isrAdds();
        {
            const iucs = interrupts.UncriticalSection.enter();
            defer iucs.exit();
            spinUs(1000);
        }
        irq_uncrit = isrAdds() - n1;
        spinUs(1000);
    }
    second_timer.stop();
    board.console("  interrupt section, 2 ms: ISR ran {d} times inside, {d} just after; inside an uncritical section of 1 ms it ran {d}\n", .{ irq_in, irq_after, irq_uncrit });
    _ = tutor.check(irq_in == 0 and irq_after >= 1, "interrupt section: the ISR waits, and runs as it ends", .{});
    _ = tutor.check(irq_uncrit > 0, "interrupt uncritical section: the ISR runs inside", .{});

    g_stop.store(true, .monotonic);
    g_h_sem[0].post() catch {};
    _ = th.join() catch null;
    th.destroy();
}

// Four CPUs: what a section on core 0 stops on the other cores.
fn partB4(gpa: std.mem.Allocator) void {
    board.console("\n-- part B: core 0 in a section; high threads on cores 0 and 1, an interrupt-section loop on core 1, a free loop on core 2\n", .{});
    const th0 = spawn(gpa, "high0", highThread, 0, prio.high, 0);
    const th1 = spawn(gpa, "high1", highThread, 1, prio.high, 1);
    second_timer.start(count_period_us, onCount, null); // on core 0

    var h0_in: u32 = undefined;
    var h1_in: u32 = undefined;
    var isr_in: u32 = undefined;
    const r00 = runs(0);
    {
        const r10 = runs(1);
        const n0 = isrAdds();
        const scs = scheduler.CriticalSection.enter();
        defer scs.exit();
        g_h_sem[0].post() catch {};
        g_h_sem[1].post() catch {};
        spinUs(2000);
        h0_in = runs(0) - r00;
        h1_in = runs(1) - r10;
        isr_in = isrAdds() - n0;
    }
    const h0_after = runs(0) - r00;
    board.console("  core 0 scheduler section, 2 ms: core 0's ISR ran {d} times; inside, the high thread on core 1 ran {d}, on core 0 {d} ({d} after)\n", .{ isr_in, h1_in, h0_in, h0_after });
    _ = tutor.check(isr_in > 0, "scheduler section: core 0's interrupts keep running", .{});
    _ = tutor.check(h1_in == 1 and h0_in == 0 and h0_after == 1, "scheduler section: core 1 switches at once, core 0 only as the section ends", .{});

    const tl = spawn(gpa, "locker", locker, 0, prio.normal, 1);
    const tf = spawn(gpa, "free", freeRunner, 0, prio.normal, 2);
    spinUs(1000);
    var l0: u32 = undefined;
    var l_in: u32 = undefined;
    var f_in: u32 = undefined;
    var i_in: u32 = undefined;
    {
        const ics = interrupts.CriticalSection.enter();
        defer ics.exit();
        l0 = g_c_locked.load(.monotonic);
        const f0 = g_c_free.load(.monotonic);
        const n0 = isrAdds();
        spinUs(2000);
        l_in = g_c_locked.load(.monotonic) - l0;
        f_in = g_c_free.load(.monotonic) - f0;
        i_in = isrAdds() - n0;
    }
    spinUs(200);
    const l_after = g_c_locked.load(.monotonic) - l0;
    var l_uncrit: u32 = undefined;
    var i_uncrit: u32 = undefined;
    {
        const ics = interrupts.CriticalSection.enter();
        defer ics.exit();
        const l1 = g_c_locked.load(.monotonic);
        const n1 = isrAdds();
        {
            const iucs = interrupts.UncriticalSection.enter();
            defer iucs.exit();
            spinUs(1000);
        }
        l_uncrit = g_c_locked.load(.monotonic) - l1;
        i_uncrit = isrAdds() - n1;
        spinUs(1000);
    }
    second_timer.stop();
    board.console("  core 0 interrupt section, 2 ms: core 0's ISR ran {d}, core 1's locked loop {d}, core 2's free loop {d} (core 1 {d} just after)\n", .{ i_in, l_in, f_in, l_after });
    board.console("  inside an interrupt uncritical section of 1 ms: core 0's ISR ran {d}, core 1's locked loop {d}\n", .{ i_uncrit, l_uncrit });
    _ = tutor.check(i_in == 0 and l_in == 0 and f_in > 0, "interrupt section: core 0's ISR and core 1's locked loop stop, core 2's free loop runs", .{});
    _ = tutor.check(l_after > 0, "core 1 enters as the section ends", .{});
    _ = tutor.check(i_uncrit > 0 and l_uncrit == 0, "interrupt uncritical section: core 0's ISR runs, the spinlock is kept (core 1 still waits)", .{});

    g_stop.store(true, .monotonic);
    g_h_sem[0].post() catch {};
    g_h_sem[1].post() catch {};
    for ([_]*rtos.Thread{ th0, th1, tl, tf }) |t| {
        _ = t.join() catch null;
        t.destroy();
    }
}
