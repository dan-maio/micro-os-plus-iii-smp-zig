//! tutor-16-sd-card-4cpu -- lesson 16, four CPUs (see ../README.md).
//!
//! One logger thread owns the UART and the SD card (test/tutor/common/
//! sdlog.zig); every other thread sends it lines through a message queue,
//! and the logger prints them and appends them, 4 KiB at a time, to
//! tests/tutor16.log on the card's FAT32 volume.
//!
//! Part A, the owner above its clients: with the logger at above_normal,
//! each line is printed before the producer's say() returns.
//!
//! Part B, the owner below them: lowered to below_normal, the logger runs
//! only when the producer waits, so a burst fills the queue (64 lines)
//! without waiting, and every further line waits for a slot -- the producer
//! then goes at the logger's pace. Then a quiet half second writes out the
//! buffer.
//!
//! With four CPUs (the `four` switch) the logger stays on core 0, and part C
//! sends lines from three producers on cores 1-3 at once (from a start
//! line): each producer's lines arrive in its order, mixed with the others'.
//!
//! At the end the log is read back from the card: its size, its CRC-32 and
//! its line count are those written. (Under QEMU there is no card: the lines
//! go to the UART only and the read-back is skipped.)
//!
//! The Zig version of the C++ lesson (golden workspace,
//! test/rpi4b/tutor/16-sd-card/4cpu/main.cpp), with the same checks.

const std = @import("std");
const uos = @import("uos");
const board = @import("board");
const tutor = @import("tutor");
const sdlog = @import("sdlog");

const rtos = uos.rtos;
const sysclock = rtos.sysclock;
const second_timer = tutor.second_timer;
const prio = rtos.priority;
const say = sdlog.say;

const four = true;

pub const uos_options = board.options(4);

const log_leaf = "tutor16.log";

const n_a = 40; // part A's lines
const n_b = 300; // part B's burst

fn lines() u32 {
    return sdlog.stats().messages.load(.monotonic);
}

// The parts' results, printed again on the console once the logger has
// stopped: on the board the logger's lines reach only the UART, the
// console's also the runner's log (semihosting).
var g_sum: struct {
    a_at_once: u32 = 0,
    a_waited: u32 = 0,
    a_us: u32 = 0,
    b_fast: u32 = 0,
    b_fast_us: u32 = 0,
    b_waited: u32 = 0,
    b_slow_us: u32 = 0,
    b_first: u32 = 0,
    b_taken: u32 = 0,
    b_idle: u32 = 0,
    c_lines: u32 = 0,
    c_out_of_order: u32 = 0,
    c_switches: u32 = 0,
    c_waited: [4]u32 = .{ 0, 0, 0, 0 },
    c_ran_on: [4]u32 = .{ 0, 0, 0, 0 },
} = .{};

// ---- Part C: three producers on cores 1-3 ------------------------------------

const n_c = 100; // lines per producer

// The start line: the producers wait, busy, until all three exist. Started
// one by one, the first would fill the queue before the next is created --
// the logger, above the main thread on core 0, then keeps core 0 busy.
var g_go = std.atomic.Value(bool).init(false);

const ProducerCtx = struct {
    core: u32 = 0,
    ran_on: u32 = 99,
    waited: u32 = 0,
};

fn producer(arg: ?*anyopaque) ?*anyopaque {
    const p: *ProducerCtx = @ptrCast(@alignCast(arg.?));
    p.ran_on = board.cpuSlot();
    while (!g_go.load(.acquire)) {}
    for (0..n_c) |i| {
        if (say("C c{d} {d:0>3} value {d:>5}\n", .{ p.core, i, tutor.generate(16 + p.core, @intCast(i)) })) p.waited += 1;
    }
    return null;
}

// What the logger saw of part C's lines, in the order it took them.
var g_count: [4]u32 = .{ 0, 0, 0, 0 };
var g_next: [4]u32 = .{ 0, 0, 0, 0 };
var g_out_of_order: u32 = 0;
var g_switches: u32 = 0;
var g_last: u32 = 0;

fn observe(text: []const u8) void {
    if (text.len < 9 or text[0] != 'C' or text[1] != ' ' or text[2] != 'c') return;
    const core: u32 = text[3] -% '0';
    if (core < 1 or core > 3) return;
    const seq: u32 = @as(u32, text[5] - '0') * 100 + @as(u32, text[6] - '0') * 10 + (text[7] - '0');
    if (seq != g_next[core]) g_out_of_order += 1;
    g_next[core] = seq + 1;
    g_count[core] += 1;
    if (g_last != 0 and core != g_last) g_switches += 1;
    g_last = core;
}

// ---- The lesson ------------------------------------------------------------------

pub fn main() void {
    board.uart.init();
    rtos.run(osMain);
}

fn osMain() void {
    const gpa = uos.memory.allocator();
    const self = rtos.this_thread.thread();

    if (four) self.setCpuAffinity(1 << 0);
    tutor.printBanner("16 sd card");
    board.console("Lesson 16, {s}: one logger thread owns the SD card; the other threads send it lines.\n", .{if (four) "four CPUs" else "one CPU"});
    tutor.printRegions();
    if (four) {
        // ---- Release cores 1-3 (as in lesson 01).
        board.smp.startSecondaryCores();
        const waited = board.smp.waitSecondaries(3000);
        board.console("  cores joined after {d} ms: {s}\n", .{ waited, board.smp.joinSummary() });
        _ = tutor.check(board.smp.secondariesJoined(), "cores 1-{d} joined the scheduler", .{uos.config.ncpu - 1});
    }

    const heap0 = tutor.heapBytes();

    // ---- The card and its owner.
    board.console("\n-- the card: {s}\n", .{if (tutor.onHardware()) "init, mount the FAT32 volume, tests/ ready" else "none in this image (QEMU): the lines go to the UART only"});
    if (!sdlog.start(log_leaf, prio.above_normal, 0)) {
        _ = tutor.check(false, "the SD card is ready", .{});
        tutor.finish("");
    }
    const st = sdlog.stats();
    if (sdlog.hasCard()) {
        _ = say("  card ready in {d} ms; every line from now on goes to the UART and to tests/{s}\n", .{ sdlog.cardStartMs(), log_leaf });
    } else {
        _ = say("  every line from now on goes through the logger, to the UART\n", .{});
    }

    // ---- Part A.
    _ = say("\n-- part A: the logger (above_normal{s}) above the producer: {d} lines\n", .{ if (four) ", core 0" else "", n_a });
    sdlog.sync();
    {
        var at_once: u32 = 0;
        var waited: u32 = 0;
        var us: u32 = 0;
        for (0..n_a) |i| {
            const before = lines();
            const t0 = second_timer.nowUs();
            if (say("A {d:0>2} value {d:>5}\n", .{ i, tutor.generate(16, @intCast(i)) })) waited += 1;
            us += second_timer.nowUs() -% t0;
            if (lines() == before + 1) at_once += 1;
        }
        _ = say("  {d} of {d} lines printed before say () returned, {d} waited for a slot; say () took {d} us each\n", .{ at_once, n_a, waited, us / n_a });
        g_sum.a_at_once = at_once;
        g_sum.a_waited = waited;
        g_sum.a_us = us / n_a;
        _ = tutor.check(at_once == n_a and waited == 0, "above the producer, the logger takes each line at once", .{});
    }

    // ---- Part B.
    _ = say("\n-- part B: the logger lowered to below_normal; a burst of {d} lines into a queue of {d}\n", .{ n_b, sdlog.queue_slots });
    sdlog.sync();
    {
        sdlog.logger().setPriority(prio.below_normal) catch {};
        var waited: u32 = 0;
        var first_wait: u32 = n_b;
        var taken_when_full: u32 = 0;
        var fast_us: u32 = 0;
        var slow_us: u32 = 0;
        const before = lines();
        for (0..n_b) |i| {
            const t0 = second_timer.nowUs();
            const w = say("B {d:0>3} value {d:>5}\n", .{ i, tutor.generate(16, @intCast(n_a + i)) });
            const dt = second_timer.nowUs() -% t0;
            if (w) {
                if (waited == 0) first_wait = @intCast(i);
                waited += 1;
                slow_us += dt;
            } else {
                fast_us += dt;
            }
            if (i == sdlog.queue_slots - 1) taken_when_full = lines() - before;
        }
        sdlog.logger().setPriority(prio.above_normal) catch {};
        sdlog.sync();
        const fast = n_b - waited;
        _ = say("  {d} lines queued without waiting ({d} us each), the logger had taken {d} of them;\n", .{ fast, if (fast != 0) fast_us / fast else 0, taken_when_full });
        _ = say("  then {d} waited for a slot ({d} us each), from line {d}\n", .{ waited, if (waited != 0) slow_us / waited else 0, first_wait });
        g_sum.b_fast = fast;
        g_sum.b_fast_us = if (fast != 0) fast_us / fast else 0;
        g_sum.b_waited = waited;
        g_sum.b_slow_us = if (waited != 0) slow_us / waited else 0;
        g_sum.b_first = first_wait;
        g_sum.b_taken = taken_when_full;
        _ = tutor.check(first_wait == sdlog.queue_slots and waited == n_b - sdlog.queue_slots and taken_when_full == 0, "below the producer, the queue takes {d} lines; then each line waits for a slot", .{sdlog.queue_slots});

        const idle0 = st.flushes_idle.load(.monotonic);
        _ = say("  one line, then 1200 ms quiet\n", .{});
        sysclock.sleepFor(1200) catch {};
        _ = say("  the buffer was written out {d} time(s) while quiet\n", .{st.flushes_idle.load(.monotonic) - idle0});
        g_sum.b_idle = st.flushes_idle.load(.monotonic) - idle0;
        _ = tutor.check(st.flushes_idle.load(.monotonic) == idle0 + 1, "half a second without a line writes out the buffer, once", .{});
    }

    if (four) {
        // ---- Part C.
        _ = say("\n-- part C: three producers on cores 1-3, {d} lines each, at once; the logger on core 0\n", .{n_c});
        sdlog.sync();
        sdlog.setObserver(observe);
        var ctx: [4]ProducerCtx = .{ .{}, .{}, .{}, .{} };
        var th: [4]?*rtos.Thread = .{ null, null, null, null };
        for (1..4) |c| {
            ctx[c].core = @intCast(c);
            th[c] = rtos.Thread.create(gpa, "producer", producer, &ctx[c], .{ .stack_size_bytes = 8 * 1024, .cpu_affinity = @as(u32, 1) << @intCast(c) }) catch null;
        }
        g_go.store(true, .release);
        for (1..4) |c| {
            if (th[c]) |t| {
                _ = t.join() catch null;
                t.destroy();
            }
        }
        sdlog.sync();
        sdlog.setObserver(null);
        var cores_ok = true;
        var waited: u32 = 0;
        var counted: u32 = 0;
        for (1..4) |c| {
            cores_ok = cores_ok and ctx[c].ran_on == c;
            waited += ctx[c].waited;
            g_sum.c_waited[c] = ctx[c].waited;
            g_sum.c_ran_on[c] = ctx[c].ran_on;
            counted += g_count[c];
            _ = say("  producer {d}: ran on core {d}, {d} lines taken, {d} waited for a slot\n", .{ c, ctx[c].ran_on, g_count[c], ctx[c].waited });
        }
        _ = say("  {d} lines; out of their producer's order: {d}; the logger switched producer {d} times\n", .{ counted, g_out_of_order, g_switches });
        g_sum.c_lines = counted;
        g_sum.c_out_of_order = g_out_of_order;
        g_sum.c_switches = g_switches;
        _ = tutor.check(cores_ok, "each producer ran on its core", .{});
        _ = tutor.check(counted == 3 * n_c and g_out_of_order == 0, "every line arrived, each producer's in its order", .{});
        _ = tutor.check(g_switches > 2, "the lines of the three cores arrived mixed", .{});
        _ = tutor.check(waited > 0, "three producers outran the one logger: they waited for slots", .{});
        _ = tutor.check(st.cpus.load(.monotonic) == 1, "the logger ran only on core 0", .{});
    }

    // ---- The read-back.
    _ = say("\n-- the log read back\n", .{});
    sdlog.stop(); // from here on, the console
    const rb = sdlog.verify();
    board.console("  the parts, again: A {d} of {d} lines printed before say () returned ({d} us each), {d} waited;\n", .{ g_sum.a_at_once, n_a, g_sum.a_us, g_sum.a_waited });
    board.console("  B {d} queued at once ({d} us each, {d} taken meanwhile), then {d} waited ({d} us each) from line {d}; {d} quiet write-out\n", .{ g_sum.b_fast, g_sum.b_fast_us, g_sum.b_taken, g_sum.b_waited, g_sum.b_slow_us, g_sum.b_first, g_sum.b_idle });
    if (four) {
        board.console("  C {d} lines, {d} out of order, {d} producer switches; waited {d} / {d} / {d} on cores {d} / {d} / {d}\n", .{ g_sum.c_lines, g_sum.c_out_of_order, g_sum.c_switches, g_sum.c_waited[1], g_sum.c_waited[2], g_sum.c_waited[3], g_sum.c_ran_on[1], g_sum.c_ran_on[2], g_sum.c_ran_on[3] });
    }
    const full = st.flushes_full.load(.monotonic);
    const idle = st.flushes_idle.load(.monotonic);
    const syn = st.flushes_sync.load(.monotonic);
    board.console("  {d} say () calls, {d} lines, {d} B; written out {d} times: {d} full, {d} quiet, {d} sync; {d} write errors\n", .{ st.messages.load(.monotonic), st.lines.load(.monotonic), st.bytes.load(.monotonic), full + idle + syn, full, idle, syn, st.write_errors.load(.monotonic) });
    _ = tutor.check(full >= 1 and syn >= 3, "the buffer was written out when full and on every sync", .{});
    if (sdlog.hasCard()) {
        board.console("  tests/{s}: {d} B and {d} lines on the card; the longest append took {d} us\n", .{ log_leaf, rb.on_card, rb.lines_on_card, st.max_flush_us.load(.monotonic) });
        _ = tutor.check(rb.ok and rb.on_card == st.bytes.load(.monotonic) and rb.lines_on_card == st.lines.load(.monotonic), "the log read back: its size, CRC-32 and lines are those written", .{});
    } else {
        board.console("  no card in this image: the read-back is skipped\n", .{});
    }

    const heap1 = tutor.heapBytes();
    board.console("  heap: {d} B before the card, {d} B after\n", .{ heap0, heap1 });
    _ = tutor.check(heap1 == heap0, "the heap is back to its level", .{});

    tutor.finish(if (sdlog.hasCard()) "the SD log verified" else "no SD card in this image");
}
