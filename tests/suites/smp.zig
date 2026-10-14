//! SMP suites (the C++ `smp-test2`..`smp-test4`, `smp-mat-test` and
//! `fp-switch`). They also run on one CPU, where the "core 1" threads
//! simply share core 0; the per-CPU checks are skipped there.

const std = @import("std");
const uos = @import("uos");
const t = @import("check.zig");
const rtos = uos.rtos;

const ncpu = uos.config.ncpu;
const smp = ncpu > 1;
const sysclock = rtos.sysclock;

fn cpu() u32 {
    return uos.port.scheduler.cpuId();
}

fn affinity(c: u32) u32 {
    return if (smp) @as(u32, 1) << @intCast(c) else 0xFFFF_FFFF;
}

fn microseconds() u64 {
    return rtos.hrclock.now() * 1_000_000 / rtos.hrclock.inputClockFrequencyHz();
}

// ----------------------------------------------------------------------------
// smp-test2: pinned workers, a shared counter under a mutex.

var g_mutex: rtos.Mutex = .{ .name = "g" };
var g_global: u32 = 0;

const Pinned = struct {
    th: rtos.ThreadInclusive(2048) = undefined,
    want_cpu: u32,
    beats: u32 = 0,
    wrong_cpu: u32 = 0,
};

var pinned_workers: [2]Pinned = .{ .{ .want_cpu = 0 }, .{ .want_cpu = 1 } };

fn pinnedMain(arg: ?*anyopaque) ?*anyopaque {
    const p: *Pinned = @ptrCast(@alignCast(arg.?));
    const me = rtos.this_thread.thread();
    while (!me.isInterrupted()) {
        if (smp and cpu() != p.want_cpu) p.wrong_cpu += 1;
        g_mutex.lock() catch break;
        g_global += 1;
        g_mutex.unlock() catch {};
        p.beats += 1;
        sysclock.sleepFor(10) catch {};
    }
    return null;
}

pub fn pinnedWorkers(duration_ms: u32) void {
    t.section("pinned workers (smp-test2)");
    for (&pinned_workers, 0..) |*p, i| {
        p.beats = 0;
        p.wrong_cpu = 0;
        p.th.init(if (i == 0) "w0" else "w1", pinnedMain, p, .{ .cpu_affinity = affinity(@intCast(i)) }) catch unreachable;
    }
    sysclock.sleepFor(duration_ms) catch {};
    for (&pinned_workers) |*p| _ = p.th.thread.interrupt(true);
    for (&pinned_workers) |*p| {
        _ = p.th.thread.join() catch {};
        p.th.deinit();
    }
    for (pinned_workers, 0..) |p, i| {
        uos.trace.print("w{d}: {d} beats, {d} on a wrong CPU\n", .{ i, p.beats, p.wrong_cpu });
        t.ok(p.beats > duration_ms / 20, @src());
        t.eq(@as(u32, 0), p.wrong_cpu, @src());
    }
    t.eq(pinned_workers[0].beats + pinned_workers[1].beats, g_global, @src());
}

// ----------------------------------------------------------------------------
// smp-test3: semaphore ping-pong between the CPUs; the kernel's IPI (a thread
// resumed from a CPU it may not run on) must deliver the wake in
// microseconds, not at the next tick.

var s_ping: rtos.Semaphore = .binary("ping", 0);
var s_pong: rtos.Semaphore = .binary("pong", 0);
var t_sent: u64 = 0;
var lat_max_to1: u64 = 0;
var lat_max_to0: u64 = 0;
var pong_th: rtos.ThreadInclusive(2048) = undefined;
var rounds_left: u32 = 0;

fn ponger(_: ?*anyopaque) ?*anyopaque {
    while (rounds_left > 0) {
        s_ping.wait() catch break;
        lat_max_to1 = @max(lat_max_to1, microseconds() - t_sent);
        t_sent = microseconds();
        s_pong.post() catch {};
    }
    return null;
}

pub fn ipiPingPong(rounds: u32) void {
    t.section("cross-CPU ping-pong (smp-test3)");
    const me = rtos.this_thread.thread();
    const saved = me.cpuAffinity();
    me.setCpuAffinity(affinity(0));
    rtos.this_thread.yield();

    lat_max_to1 = 0;
    lat_max_to0 = 0;
    rounds_left = rounds;
    pong_th.init("ponger", ponger, null, .{ .cpu_affinity = affinity(1) }) catch unreachable;
    var done: u32 = 0;
    while (done < rounds) : (done += 1) {
        if (done + 1 == rounds) rounds_left = 0;
        t_sent = microseconds();
        s_ping.post() catch {};
        s_pong.timedWait(100) catch break;
        lat_max_to0 = @max(lat_max_to0, microseconds() - t_sent);
    }
    _ = pong_th.thread.join() catch {};
    pong_th.deinit();
    me.setCpuAffinity(saved);

    uos.trace.print("{d} rounds, max one-way latency: c0->c1 {d} us, c1->c0 {d} us\n", .{ done, lat_max_to1, lat_max_to0 });
    t.eq(rounds, done, @src());
    if (smp) t.expect(lat_max_to1 < 500, @src(), "c0->c1 woken by the tick, not the IPI ({d} us)", .{lat_max_to1});
}

// ----------------------------------------------------------------------------
// smp-test4: kernel objects with the parties on different CPUs.

const Cross = struct {
    ev: rtos.EventFlags = .{ .name = "x-ev" },
    q: rtos.MessageQueueTyped(u32).Static(2) = .{},
    pool: rtos.MemoryPoolTyped(u64).Static(4) = .{},
    pool_handoff: rtos.MessageQueueTyped(usize).Static(4) = .{},
    mx: rtos.Mutex = .{ .name = "x-mx" },
    cv: rtos.ConditionVariable = .{ .name = "x-cv" },
    predicate: u32 = 0,
    ack: rtos.Semaphore = .binary("x-ack", 0),
};

var cross: Cross = .{};
var cross_th: rtos.ThreadInclusive(2048) = undefined;
const cross_rounds = 50;

fn crossWorker(_: ?*anyopaque) ?*anyopaque {
    const c = &cross;
    // S1 event flags.
    for (0..cross_rounds) |_| {
        _ = c.ev.wait(0x1, .all_clear) catch return null;
        _ = c.ev.raise(0x2) catch {};
    }
    // S2 message queue echo.
    for (0..cross_rounds) |_| {
        const v = c.q.typed.receive() catch return null;
        c.q.typed.send(v + 1, 0) catch {};
    }
    // S3 memory pool: free what core 0 allocated.
    for (0..cross_rounds) |_| {
        const addr = c.pool_handoff.typed.receive() catch return null;
        const blk: *u64 = @ptrFromInt(addr);
        if (blk.* != 0xC0FFEE) c.predicate = 0xBAD;
        c.pool.typed.free(blk) catch {};
    }
    // S4 condition variable.
    for (1..cross_rounds + 1) |i| {
        c.mx.lock() catch return null;
        while (c.predicate != i) c.cv.wait(&c.mx) catch {};
        c.mx.unlock() catch {};
        c.ack.post() catch {};
    }
    // S5 mutex: block while core 0 holds it.
    c.mx.lock() catch return null;
    c.mx.unlock() catch {};
    c.ack.post() catch {};
    return null;
}

pub fn crossObjects() void {
    t.section("kernel objects across CPUs (smp-test4)");
    const c = &cross;
    const me = rtos.this_thread.thread();
    const saved = me.cpuAffinity();
    me.setCpuAffinity(affinity(0));
    rtos.this_thread.yield();

    c.q.init("x-q", .{}) catch unreachable;
    c.pool.init("x-pool", .{}) catch unreachable;
    c.pool_handoff.init("x-handoff", .{}) catch unreachable;
    c.predicate = 0;
    cross_th.init("x-worker", crossWorker, null, .{ .cpu_affinity = affinity(1) }) catch unreachable;

    var ok_rounds: u32 = 0;
    for (0..cross_rounds) |_| {
        _ = c.ev.raise(0x1) catch {};
        if (c.ev.timedWait(0x2, 100, .all_clear)) |_| ok_rounds += 1 else |_| {}
    }
    t.eq(@as(u32, cross_rounds), ok_rounds, @src());

    ok_rounds = 0;
    for (0..cross_rounds) |i| {
        c.q.typed.send(@intCast(i), 0) catch {};
        const back = c.q.typed.timedReceive(100) catch 0;
        if (back == i + 1) ok_rounds += 1;
    }
    t.eq(@as(u32, cross_rounds), ok_rounds, @src());

    for (0..cross_rounds) |_| {
        const blk = c.pool.typed.timedAlloc(100) catch break;
        blk.* = 0xC0FFEE;
        c.pool_handoff.typed.send(@intFromPtr(blk), 0) catch {};
    }
    sysclock.sleepFor(20) catch {};
    t.ok(c.pool.typed.pool.isEmpty(), @src());
    t.ok(c.predicate != 0xBAD, @src());

    ok_rounds = 0;
    for (1..cross_rounds + 1) |i| {
        c.mx.lock() catch break;
        c.predicate = @intCast(i);
        c.cv.signal() catch {};
        c.mx.unlock() catch {};
        if (c.ack.timedWait(100)) |_| ok_rounds += 1 else |_| {}
    }
    t.eq(@as(u32, cross_rounds), ok_rounds, @src());

    c.mx.lock() catch {};
    sysclock.sleepFor(10) catch {};
    t.err(error.WouldBlock, c.ack.tryWait(), @src()); // the worker is blocked
    c.mx.unlock() catch {};
    t.success(c.ack.timedWait(100), @src());

    _ = cross_th.thread.join() catch {};
    cross_th.deinit();
    me.setCpuAffinity(saved);
}

// ----------------------------------------------------------------------------
// smp-mat-test: parallel block Gaussian elimination, checked against the
// serial solve; on two CPUs it should be faster.

pub fn Matrix(comptime n: usize) type {
    return struct {
        a: [n][n]f32,
        b: [n]f32,

        const Self = @This();

        pub fn fill(m: *Self, seed: u64) void {
            var rng: std.Random.DefaultPrng = .init(seed);
            const r = rng.random();
            for (0..n) |i| {
                var row_sum: f32 = 0;
                for (0..n) |j| {
                    m.a[i][j] = r.float(f32) - 0.5;
                    row_sum += @abs(m.a[i][j]);
                }
                m.a[i][i] = row_sum + 1; // diagonally dominant
                m.b[i] = r.float(f32) * 10;
            }
        }

        /// Eliminate below the pivot `k` for the rows `first..last`.
        fn eliminate(m: *Self, k: usize, first: usize, last: usize) void {
            const pivot = m.a[k][k];
            for (first..last) |i| {
                if (i <= k) continue;
                const f = m.a[i][k] / pivot;
                for (k..n) |j| m.a[i][j] -= f * m.a[k][j];
                m.b[i] -= f * m.b[k];
            }
        }

        fn backSubstitute(m: *Self, x: *[n]f32) void {
            var i = n;
            while (i > 0) {
                i -= 1;
                var s = m.b[i];
                for (i + 1..n) |j| s -= m.a[i][j] * x[j];
                x[i] = s / m.a[i][i];
            }
        }

        pub fn solveSerial(m: *Self, x: *[n]f32) void {
            for (0..n) |k| m.eliminate(k, k + 1, n);
            m.backSubstitute(x);
        }

        const Shared = struct {
            m: *Self,
            k: usize = 0,
            go: rtos.Semaphore = .binary("go", 0),
            done: rtos.Semaphore = .binary("done", 0),
            quit: bool = false,
        };

        fn helperMain(arg: ?*anyopaque) ?*anyopaque {
            const s: *Shared = @ptrCast(@alignCast(arg.?));
            while (true) {
                s.go.wait() catch return null;
                if (s.quit) return null;
                const k = s.k;
                const mid = k + 1 + (n - k - 1) / 2;
                s.m.eliminate(k, mid, n);
                s.done.post() catch {};
            }
        }

        /// Rows split in halves between this thread (CPU 0) and a helper
        /// (CPU 1), one hand-off per pivot.
        pub fn solveParallel(m: *Self, x: *[n]f32, helper: *rtos.ThreadInclusive(2048)) void {
            var s: Shared = .{ .m = m };
            helper.init("mat-helper", helperMain, &s, .{ .cpu_affinity = affinity(1) }) catch unreachable;
            for (0..n) |k| {
                s.k = k;
                s.go.post() catch {};
                const mid = k + 1 + (n - k - 1) / 2;
                m.eliminate(k, k + 1, mid);
                s.done.wait() catch {};
            }
            s.quit = true;
            s.go.post() catch {};
            _ = helper.thread.join() catch {};
            helper.deinit();
            m.backSubstitute(x);
        }
    };
}

var mat_helper: rtos.ThreadInclusive(2048) = undefined;

pub fn matrixSolve(comptime n: usize) void {
    t.section("parallel block solver (smp-mat-test)");
    const M = Matrix(n);
    const gpa = uos.memory.allocator();
    const m1 = gpa.create(M) catch {
        t.expect(false, @src(), "no memory for the matrices", .{});
        return;
    };
    defer gpa.destroy(m1);
    const m2 = gpa.create(M) catch return;
    defer gpa.destroy(m2);
    m1.fill(42);
    m2.* = m1.*;

    const me = rtos.this_thread.thread();
    const saved = me.cpuAffinity();
    me.setCpuAffinity(affinity(0));
    rtos.this_thread.yield();

    var x1: [n]f32 = undefined;
    var x2: [n]f32 = undefined;
    const t0 = microseconds();
    m1.solveSerial(&x1);
    const t1 = microseconds();
    m2.solveParallel(&x2, &mat_helper);
    const t2 = microseconds();
    me.setCpuAffinity(saved);

    var max_diff: f32 = 0;
    for (x1, x2) |a, b| max_diff = @max(max_diff, @abs(a - b));
    const serial_us = t1 - t0;
    const parallel_us = t2 - t1;
    uos.trace.print("N={d}: serial {d} us, parallel {d} us, speedup x{d}.{d:0>2}, max |dx| = {e}\n", .{
        n,                                     serial_us, parallel_us,
        serial_us / @max(parallel_us, 1),      (serial_us * 100 / @max(parallel_us, 1)) % 100,
        max_diff,
    });
    t.ok(max_diff < 1e-3, @src());
    if (smp and n >= 64) t.ok(parallel_us < serial_us, @src());
}

// ----------------------------------------------------------------------------
// fp-switch: threads keep FP values live across preemptions and
// migrations; every thread must see only its own values.

const FpWorker = struct {
    th: rtos.ThreadInclusive(8192) = undefined,
    seed: f32,
    errors: u32 = 0,
    loops: u32 = 0,
};

var fp_workers: [4]FpWorker = .{ .{ .seed = 1.5 }, .{ .seed = 2.25 }, .{ .seed = -3.125 }, .{ .seed = 7.0 } };

fn fpMain(arg: ?*anyopaque) ?*anyopaque {
    const w: *FpWorker = @ptrCast(@alignCast(arg.?));
    const me = rtos.this_thread.thread();
    while (!me.isInterrupted()) {
        // Sixteen live values, more than the caller-saved registers.
        var v: @Vector(16, f32) = @splat(w.seed);
        const step: @Vector(16, f32) = .{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16 };
        for (0..200) |_| {
            v += step;
            std.mem.doNotOptimizeAway(&v);
        }
        rtos.this_thread.yield();
        for (0..200) |_| {
            v -= step;
            std.mem.doNotOptimizeAway(&v);
        }
        const expected: @Vector(16, f32) = @splat(w.seed);
        if (!@reduce(.And, v == expected)) w.errors += 1;
        w.loops += 1;
    }
    return null;
}

pub fn fpSwitch(duration_ms: u32) void {
    t.section("FPU context switch (fp-switch)");
    for (&fp_workers, 0..) |*w, i| {
        w.errors = 0;
        w.loops = 0;
        w.th.init("fp", fpMain, w, .{ .cpu_affinity = if (i % 2 == 0) 0xFFFF_FFFF else affinity(@intCast(i % ncpu)) }) catch unreachable;
    }
    sysclock.sleepFor(duration_ms) catch {};
    for (&fp_workers) |*w| _ = w.th.thread.interrupt(true);
    for (&fp_workers) |*w| {
        _ = w.th.thread.join() catch {};
        w.th.deinit();
    }
    for (&fp_workers, 0..) |*w, i| {
        uos.trace.print("fp{d}: {d} loops, {d} errors\n", .{ i, w.loops, w.errors });
        t.ok(w.loops > 0, @src());
        t.eq(@as(u32, 0), w.errors, @src());
    }
}

/// Everything above, in order.
pub fn run(comptime mat_n: usize) u32 {
    t.reset();
    uos.trace.print("\nsmp - {d} CPU(s)\n", .{ncpu});
    pinnedWorkers(2000);
    ipiPingPong(2000);
    crossObjects();
    matrixSolve(mat_n);
    fpSwitch(2000);
    return t.summary("smp");
}
