//! tutor-18-balancing-1cpu -- lesson 18, one CPU (see ../README.md).
//!
//! Threads of one priority, with no affinity: who runs them, and where.
//! The unit of work is a chunk: a fixed number of loop iterations, about
//! 100 us (calibrated at start); a worker records, for every chunk, the core
//! it ran on.
//!
//! Part A, eight workers of 100 chunks each. On one CPU they share it by
//! time slices -- at every tick the running one goes to the end of its
//! priority's ready list -- so all eight are under way before any ends. With
//! four CPUs they float: any core takes the next ready one, so the eight
//! spread over the four cores, and move between them.
//!
//! Part B, fairness: the eight count chunks for 400 ms; each gets its share.
//!
//! With four CPUs (the `four` switch), part C: a thread's affinity changed
//! while it runs. A `mover` floats among four other workers; the main thread
//! pins it to core 2, then to core 3, then frees it again. A new affinity is
//! only a mask: it takes effect at the next scheduling decision of a core.
//!
//! The Zig version of the C++ lesson (golden workspace,
//! test/rpi4b/tutor/18-balancing/1cpu/main.cpp), with the same checks.

const std = @import("std");
const uos = @import("uos");
const board = @import("board");
const tutor = @import("tutor");

const rtos = uos.rtos;
const interrupts = rtos.interrupts;
const sysclock = rtos.sysclock;
const second_timer = tutor.second_timer;
const Atomic = std.atomic.Value;

const four = false;
const ncpu: u32 = if (four) 4 else 1;

pub const uos_options = board.options(1);

const n_workers = 8;
const chunk_us = 100;

// One chunk of work: a fixed number of loop iterations, about chunk_us on a
// core of its own (calibrated at start). Not "busy until chunk_us have
// passed": a chunk preempted half-way would then count the other threads'
// time as its own.
var g_iters: u64 = 1;

// In registers only: a counter in memory (on the thread's stack) made the
// same chunk slower on some threads than on others on the board, as their
// stacks fell in memory. Not inlined: the calibration and the chunks run the
// same code.
noinline fn spin(iters: u64) void {
    var x: u64 = 0;
    var i: u64 = 0;
    while (i < iters) : (i += 1) {
        x = asm volatile ("add %[r], %[a], %[b]"
            : [r] "=r" (-> u64),
            : [a] "r" (x),
              [b] "r" (i),
        );
    }
}

fn chunk() void {
    spin(g_iters);
}

fn calibrate() void {
    const probe = 200000;
    var best: u32 = 0xFFFF_FFFF;
    for (0..3) |_| { // the fastest of three
        // With the interrupts masked: a tick inside the probe would make the
        // loop look slower than it is.
        const cs = interrupts.CriticalSection.enter();
        defer cs.exit();
        const t0 = second_timer.nowUs();
        spin(probe);
        const us = second_timer.nowUs() -% t0;
        if (us < best) best = us;
    }
    g_iters = probe * chunk_us / @max(best, 1);
}

const WorkerCtx = struct {
    id: u32 = 0,
    chunks: u32 = 0, // part A: how many to do; done
    cores: u32 = 0, // the cores it ran on (a mask)
    migrations: u32 = 0, // chunks on another core than the previous one
    last_core: u32 = 0,
    start: u32 = 0,
    end: u32 = 0,
};

var g_last_id = Atomic(u32).init(99);
var g_slices = Atomic(u32).init(0);
var g_stop = Atomic(bool).init(false);

fn note(w: *WorkerCtx) void {
    const core = board.cpuSlot();
    if (w.cores != 0 and core != w.last_core) w.migrations += 1;
    w.cores |= @as(u32, 1) << @intCast(core);
    w.last_core = core;
    if (g_last_id.swap(w.id, .seq_cst) != w.id) _ = g_slices.fetchAdd(1, .seq_cst);
}

// Part A: a fixed number of chunks.
fn fixedWorker(arg: ?*anyopaque) ?*anyopaque {
    const w: *WorkerCtx = @ptrCast(@alignCast(arg.?));
    w.start = second_timer.nowUs();
    for (0..100) |_| {
        chunk();
        note(w);
        w.chunks += 1;
    }
    w.end = second_timer.nowUs();
    return null;
}

// Part B (and C's companions): chunks until told to stop.
fn windowWorker(arg: ?*anyopaque) ?*anyopaque {
    const w: *WorkerCtx = @ptrCast(@alignCast(arg.?));
    while (!g_stop.load(.seq_cst)) {
        chunk();
        note(w);
        w.chunks += 1;
    }
    return null;
}

const Func = *const fn (?*anyopaque) ?*anyopaque;

// The workers float: no affinity. Below the main thread, which starts them
// all before any runs on its core (lesson 17).
fn spawn(name: [:0]const u8, f: Func, arg: ?*anyopaque) *rtos.Thread {
    return rtos.Thread.create(uos.memory.allocator(), name, f, arg, .{ .stack_size_bytes = 8 * 1024, .priority = rtos.priority.below_normal }) catch {
        _ = tutor.check(false, "cannot create {s}", .{name});
        tutor.finish("");
    };
}

fn joinAll(th: []*rtos.Thread) void {
    for (th) |t| {
        _ = t.join() catch null;
        t.destroy();
    }
}

const Cores = struct {
    buf: [8]u8 = undefined,
    len: usize = 0,
    fn text(self: *const Cores) []const u8 {
        return self.buf[0..self.len];
    }
};

fn coresOf(mask: u32) Cores {
    var c: Cores = .{};
    for (0..ncpu) |k| {
        if (mask & (@as(u32, 1) << @intCast(k)) != 0) {
            c.buf[c.len] = '0' + @as(u8, @intCast(k));
            c.len += 1;
        }
    }
    return c;
}

// ---- Part C: the mover -------------------------------------------------------------

const max_log = 8192;

var g_log_t: [max_log]u32 = undefined; // a chunk's end, us
var g_log_core: [max_log]u8 = undefined;
var g_log_n = Atomic(u32).init(0);

fn mover(_: ?*anyopaque) ?*anyopaque {
    while (!g_stop.load(.seq_cst)) {
        chunk();
        const i = g_log_n.load(.seq_cst);
        if (i < max_log) {
            g_log_t[i] = second_timer.nowUs();
            g_log_core[i] = @intCast(board.cpuSlot());
            g_log_n.store(i + 1, .seq_cst);
        }
    }
    return null;
}

const MoveResult = struct {
    latency_us: u32 = 0xFFFF_FFFF, // from the change to the first chunk on the new core(s)
    after_ok: u32 = 0, // chunks after that, all where asked
    after_bad: u32 = 0, // chunks after that, elsewhere
};

// The mover's chunks from `from` (an index in the log) to `to`, seen against
// the affinity `mask` set at time `t_set`.
fn judge(from: u32, to: u32, t_set: u32, mask: u32) MoveResult {
    var r: MoveResult = .{};
    var arrived = false;
    var i = from;
    while (i < to) : (i += 1) {
        const there = mask & (@as(u32, 1) << @intCast(g_log_core[i])) != 0;
        if (!arrived) {
            if (there and @as(i32, @bitCast(g_log_t[i] -% t_set)) > 0) {
                arrived = true;
                r.latency_us = g_log_t[i] -% t_set;
                r.after_ok += 1;
            }
            continue;
        }
        if (there) r.after_ok += 1 else r.after_bad += 1;
    }
    return r;
}

fn seenCores(from: u32, to: u32) u32 {
    var m: u32 = 0;
    var i = from;
    while (i < to) : (i += 1) m |= @as(u32, 1) << @intCast(g_log_core[i]);
    return m;
}

// ---- The lesson ------------------------------------------------------------------

pub fn main() void {
    board.uart.init();
    rtos.run(osMain);
}

fn osMain() void {
    const self = rtos.this_thread.thread();

    if (four) self.setCpuAffinity(1 << 0);
    tutor.printBanner("18 balancing");
    board.console("Lesson 18, {s}: threads without affinity, where they run, and moving one.\n", .{if (four) "four CPUs" else "one CPU"});
    tutor.printRegions();
    if (four) {
        // ---- Release cores 1-3 (as in lesson 01).
        board.smp.startSecondaryCores();
        const waited = board.smp.waitSecondaries(3000);
        board.console("  cores joined after {d} ms: {s}\n", .{ waited, board.smp.joinSummary() });
        _ = tutor.check(board.smp.secondariesJoined(), "cores 1-{d} joined the scheduler", .{uos.config.ncpu - 1});
    }

    const heap0 = tutor.heapBytes();
    const on_hw = tutor.onHardware();
    calibrate();
    board.console("  a chunk: {d} loop iterations, about {d} us\n", .{ g_iters, chunk_us });

    // ---- Part A.
    board.console("\n-- part A: {d} workers of 100 chunks of {d} us, no affinity, {s}\n", .{ n_workers, chunk_us, if (four) "four CPUs" else "one CPU" });
    {
        var w: [n_workers]WorkerCtx = @splat(.{});
        var th: [n_workers]*rtos.Thread = undefined;
        g_slices.store(0, .seq_cst);
        g_last_id.store(99, .seq_cst);
        const t0 = second_timer.nowUs();
        for (0..n_workers) |k| {
            w[k].id = @intCast(k);
            th[k] = spawn("worker", fixedWorker, &w[k]);
        }
        joinAll(&th);
        const elapsed = second_timer.nowUs() -% t0;
        var all_cores: u32 = 0;
        var migrations: u32 = 0;
        var done: u32 = 0;
        var last_start: u32 = 0;
        var first_end: u32 = 0xFFFF_FFFF;
        for (0..n_workers) |k| {
            board.console("  worker {d}: {d} chunks, ran {d:>5} .. {d:>5} us, on cores {s}, {d} migrations\n", .{ k, w[k].chunks, w[k].start -% t0, w[k].end -% t0, coresOf(w[k].cores).text(), w[k].migrations });
            all_cores |= w[k].cores;
            migrations += w[k].migrations;
            if (w[k].chunks == 100) done += 1;
            if (k == 0 or @as(i32, @bitCast(w[k].start -% last_start)) > 0) last_start = w[k].start;
            if (k == 0 or @as(i32, @bitCast(w[k].end -% first_end)) < 0) first_end = w[k].end;
        }
        const work: u32 = n_workers * 100 * chunk_us;
        const r: u32 = @intCast((100 * @as(u64, work) + elapsed / 2) / elapsed);
        if (four) {
            board.console("  {d} us of work in {d} us: {d}.{d:0>2} x; cores used {s}; {d} migrations\n", .{ work, elapsed, r / 100, r % 100, coresOf(all_cores).text(), migrations });
        } else {
            board.console("  {d} us of work in {d} us: {d}.{d:0>2} x; {d} time slices\n", .{ work, elapsed, r / 100, r % 100, g_slices.load(.seq_cst) });
        }
        _ = tutor.check(done == n_workers, "every worker did its 100 chunks", .{});
        _ = tutor.check(@as(i32, @bitCast(last_start -% first_end)) < 0, "all {d} were under way before the first one ended", .{n_workers});
        if (four) {
            _ = tutor.check(all_cores == 0xF, "the eight floating workers ran on all four cores", .{});
            _ = tutor.check(migrations > 0, "floating workers moved between cores", .{});
            const min_x100: u32 = if (on_hw) 350 else 150;
            _ = tutor.check(r >= min_x100, "four cores did the work at least {d}.{d:0>2}x as fast as one", .{ min_x100 / 100, min_x100 % 100 });
        } else {
            _ = tutor.check(g_slices.load(.seq_cst) >= 4 * n_workers, "the CPU went round the eight in time slices (at least 32)", .{});
            _ = tutor.check(r >= (if (on_hw) @as(u32, 95) else 50) and r <= (if (on_hw) @as(u32, 101) else 150), "one CPU: the work took its own time", .{});
        }
    }

    // ---- Part B.
    board.console("\n-- part B: fairness: the {d} count chunks for 400 ms\n", .{n_workers});
    {
        var w: [n_workers]WorkerCtx = @splat(.{});
        var th: [n_workers]*rtos.Thread = undefined;
        g_stop.store(false, .seq_cst);
        for (0..n_workers) |k| {
            w[k].id = @intCast(k);
            th[k] = spawn("worker", windowWorker, &w[k]);
        }
        sysclock.sleepFor(400) catch {};
        g_stop.store(true, .seq_cst);
        joinAll(&th);
        var lo: u32 = 0xFFFF_FFFF;
        var hi: u32 = 0;
        var total: u32 = 0;
        for (w) |x| {
            lo = @min(lo, x.chunks);
            hi = @max(hi, x.chunks);
            total += x.chunks;
        }
        const full: u32 = ncpu * 400 * 1000 / chunk_us;
        board.console("  chunks: {d} {d} {d} {d} {d} {d} {d} {d}\n", .{ w[0].chunks, w[1].chunks, w[2].chunks, w[3].chunks, w[4].chunks, w[5].chunks, w[6].chunks, w[7].chunks });
        board.console("  chunks per worker: {d} .. {d}, {d} in all ({d} cores x 400 ms = {d} chunks of {d} us)\n", .{ lo, hi, total, ncpu, full, chunk_us });
        const share: u32 = if (on_hw) 9 else 5;
        _ = tutor.check(10 * lo >= share * hi, "each got its share: the fewest at least {d}0 % of the most", .{share});
        if (on_hw) _ = tutor.check(100 * total >= 95 * full, "the cores were busy all the time (at least 95 %)", .{});
    }

    if (four) {
        // ---- Part C.
        board.console("\n-- part C: a floating mover among 4 floating workers; pinned to core 2, then 3, then free\n", .{});
        var w: [4]WorkerCtx = @splat(.{});
        var th: [5]*rtos.Thread = undefined;
        g_stop.store(false, .seq_cst);
        g_log_n.store(0, .seq_cst);
        for (0..4) |k| {
            w[k].id = @intCast(k);
            th[k] = spawn("worker", windowWorker, &w[k]);
        }
        const mv = spawn("mover", mover, null);
        th[4] = mv;

        const masks = [3]u32{ 1 << 2, 1 << 3, 0xF };
        var marks: [4]u32 = undefined;
        var t_set: [3]u32 = undefined;
        sysclock.sleepFor(100) catch {};
        marks[0] = g_log_n.load(.seq_cst);
        for (0..3) |s| {
            t_set[s] = second_timer.nowUs();
            mv.setCpuAffinity(masks[s]);
            sysclock.sleepFor(100) catch {};
            marks[s + 1] = g_log_n.load(.seq_cst);
        }
        g_stop.store(true, .seq_cst);
        joinAll(&th);

        const before = seenCores(0, marks[0]);
        board.console("  free, 100 ms: {d} chunks, on cores {s}\n", .{ marks[0], coresOf(before).text() });
        _ = tutor.check(before & (before -% 1) != 0, "free, the mover ran on more than one core", .{});
        var r: [3]MoveResult = undefined;
        const names = [3][]const u8{ "pinned to core 2", "pinned to core 3", "free again" };
        for (0..3) |s| {
            r[s] = judge(marks[s], marks[s + 1], t_set[s], masks[s]);
            board.console("  {s}: first chunk there {d} us after the change; then {d} chunks there, {d} elsewhere (cores {s})\n", .{ names[s], r[s].latency_us, r[s].after_ok, r[s].after_bad, coresOf(seenCores(marks[s], marks[s + 1])).text() });
        }
        const lat_max: u32 = if (on_hw) 3000 else 50000;
        for (0..2) |s| {
            _ = tutor.check(r[s].latency_us <= lat_max and r[s].after_bad == 0 and r[s].after_ok > 0, "pinned to core {d}: there within {d} us, and nowhere else after", .{ s + 2, lat_max });
        }
        const free_seen = seenCores(marks[2], marks[3]);
        _ = tutor.check(free_seen & ~@as(u32, 1 << 3) != 0, "freed again, it left core 3", .{});
    }

    const heap1 = tutor.heapBytes();
    board.console("\n  heap: {d} B before, {d} B after\n", .{ heap0, heap1 });
    _ = tutor.check(heap1 == heap0, "the heap is back to its level", .{});

    tutor.finish(if (four) "eight floating workers over four cores, fair shares; a thread moved at run time; four CPUs" else "eight workers time-sliced on one CPU, fair shares; one CPU");
}
