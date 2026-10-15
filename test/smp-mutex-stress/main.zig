//! smp-mutex-stress -- the SMP leg of mutex-stress, with per-core checks
//! (the C++ test/native/smp-mutex-stress, main.cpp + test.cpp).
//!
//! Ten threads t0..t9, pinned round-robin to the CPUs, each with its own
//! xorshift generator: busy 10..90 µs, sleep 10..200 ticks, then lock the
//! mutex and, inside, busy 1..9 µs and sleep 1..20 ticks, count, and check
//! that no other thread holds it and that it runs on its pinned CPU. "P"
//! reports every 5 s; after RUN_SECONDS (10) it interrupts and joins them.
//! FAIL when any CPU never locked, holders overlapped, a lock happened off
//! the pinned CPU, or an update to the shared counter was lost.
//!
//! Differences from C++: the kernel prints its startup banner and creates
//! the secondary idle threads; "Built with Zig" instead of the compiler.

const std = @import("std");
const builtin = @import("builtin");
const uos = @import("uos");
const board = @import("board");
const rtos = uos.rtos;
const sysclock = rtos.sysclock;
const ncpu = uos.config.ncpu;

pub const uos_options = board.options(4);

const run_seconds: u32 = 10;

const printf = board.uart.print;
const trace = uos.trace;

fn cpuId() u32 {
    return uos.port.scheduler.cpuId();
}

fn gettimeofdayMicros() u64 {
    var tp: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.REALTIME, &tp);
    return @as(u64, @intCast(tp.sec)) * 1_000_000 + @as(u64, @intCast(@divTrunc(tp.nsec, 1000)));
}

/// busy_wait(), the host variant: spin on gettimeofday().
fn busyWait(micros: u32) void {
    const until = gettimeofdayMicros() + micros;
    while (gettimeofdayMicros() < until) {}
}

// ---- test.cpp --------------------------------------------------------------

var mx: rtos.Mutex = .{};

// The per-core evidence.
var g_holders = std.atomic.Value(u32).init(0);
var g_overlaps = std.atomic.Value(u32).init(0);
var g_wrong_core = std.atomic.Value(u32).init(0);
var g_locks_on_core: [ncpu]std.atomic.Value(u32) = @splat(.init(0));
var g_counter: u32 = 0; // written only under mx

const MutexTest = struct {
    min_micros: u32 = 10,
    max_micros: u32 = 90,
    min_ticks: u32 = 10,
    max_ticks: u32 = 200,

    ticks: rtos.Duration = 0,
    accumulated_count: u32 = 0,
    count: u32 = 0,
    core: u32,
    rnd: u32,

    th: rtos.Thread = undefined,

    fn init(self: *MutexTest, name: [:0]const u8, core: u32, seed: u32) void {
        self.* = .{ .core = core, .rnd = seed | 1 };
        self.th.init(name, threadMain, self, .{ .cpu_affinity = @as(u32, 1) << @intCast(core) }, uos.memory.allocator()) catch
            @panic("mutex_test thread");
        trace.print("mutex_test @{*} {s} core {d}\n", .{ self, name, core });
    }

    fn deinit(self: *MutexTest) void {
        self.th.deinit();
    }

    fn next(self: *MutexTest) u32 {
        self.rnd ^= self.rnd << 13;
        self.rnd ^= self.rnd >> 17;
        self.rnd ^= self.rnd << 5;
        return self.rnd;
    }

    fn threadMain(attr: ?*anyopaque) ?*anyopaque {
        const self: *MutexTest = @ptrCast(@alignCast(attr.?));
        return self.objectMain();
    }

    fn objectMain(self: *MutexTest) ?*anyopaque {
        while (!self.th.isInterrupted()) {
            var nbusy = (self.next() % (self.max_micros - self.min_micros)) + self.min_micros;
            var nsleep = (self.next() % (self.max_ticks - self.min_ticks)) + self.min_ticks;
            busyWait(nbusy);
            sysclock.sleepFor(nsleep) catch {};
            self.ticks += nsleep;
            // At the end the threads are interrupted, and one blocked here
            // returns without the mutex: not a holder.
            mx.lock() catch break;
            {
                if (g_holders.fetchAdd(1, .monotonic) != 0) _ = g_overlaps.fetchAdd(1, .monotonic);
                const c = cpuId();
                if (c != self.core) _ = g_wrong_core.fetchAdd(1, .monotonic);
                if (c < ncpu) _ = g_locks_on_core[c].fetchAdd(1, .monotonic);
                const v = @as(*volatile u32, &g_counter).*;
                nbusy = (self.next() % (self.max_micros / 10 - self.min_micros / 10)) + self.min_micros / 10;
                nsleep = (self.next() % (self.max_ticks / 10 - self.min_ticks / 10)) + self.min_ticks / 10;
                busyWait(nbusy);
                sysclock.sleepFor(nsleep) catch {};
                self.ticks += nsleep;
                @as(*volatile u32, &g_counter).* = v + 1; // lost if another holder got in meanwhile
                self.accumulated_count += 1;
                self.count += 1;
                _ = g_holders.fetchSub(1, .monotonic);
            }
            mx.unlock() catch {};
        }
        return null;
    }
};

var mt: [10]*MutexTest = undefined;

const Periodic = struct {
    seconds: u32,
    th: rtos.Thread = undefined,

    fn init(self: *Periodic, seconds: u32) void {
        self.* = .{ .seconds = seconds };
        self.th.init("P", threadMain, self, .{}, uos.memory.allocator()) catch @panic("periodic thread");
        trace.print("periodic @{*}\n", .{self});
    }

    fn deinit(self: *Periodic) void {
        self.th.deinit();
    }

    fn threadMain(attr: ?*anyopaque) ?*anyopaque {
        const self: *Periodic = @ptrCast(@alignCast(attr.?));
        return self.objectMain();
    }

    fn objectMain(self: *Periodic) ?*anyopaque {
        self.th.setPriority(rtos.priority.above_normal) catch {};
        var t: u32 = 0;
        while (true) {
            sysclock.sleepFor(5000) catch {};
            t += 5;
            {
                const scs = rtos.scheduler.CriticalSection.enter();
                defer scs.exit();

                printf("[{d:>3}s] ", .{t});
                var sum: u32 = 0;
                for (mt) |m| {
                    const cnt = m.accumulated_count;
                    sum += cnt;
                    printf("{s}:{d:<4} ", .{ m.th.name, cnt });
                }
                const count: u32 = mt.len;
                const average: i32 = @intCast((sum + (count / 2)) / count);
                printf("sum={d}, avg={d}", .{ sum, average });
                var min: i32 = 0;
                var max: i32 = 0;
                var sigma_squares_sum: u32 = 0;
                for (mt) |m| {
                    var delta: i32 = @intCast(m.accumulated_count);
                    delta -= average;
                    sigma_squares_sum +%= @bitCast(delta *% delta);
                    if (delta < min) min = delta;
                    if (delta > max) max = delta;
                }
                const sigma: i32 = @intFromFloat(@sqrt(@as(f64, @floatFromInt(sigma_squares_sum / count))));
                printf(", sigma={d}", .{sigma});
                if (average != 0) {
                    printf(", delta in [{d},{d}] [{d}%,{d}%]", .{
                        min,
                        max,
                        @divTrunc(min * 100 + @divTrunc(average, 2), average),
                        @divTrunc(max * 100 + @divTrunc(average, 2), average),
                    });
                }
                printf(", per core:", .{});
                for (0..ncpu) |c| printf(" c{d}={d}", .{ c, g_locks_on_core[c].load(.monotonic) });
                printf("\n", .{});
            }
            if (self.seconds != 0 and t > self.seconds) break;
        }
        for (mt) |m| {
            _ = m.th.interrupt(true);
            _ = m.th.join() catch {};
        }
        return null;
    }
};

fn runTests(seconds: u32, seed: u32) i32 {
    for (&g_locks_on_core) |*l| l.store(0, .monotonic);

    var tests: [10]MutexTest = undefined;
    const names = [_][:0]const u8{ "t0", "t1", "t2", "t3", "t4", "t5", "t6", "t7", "t8", "t9" };
    for (&tests, 0..) |*m, i| {
        m.init(names[i], @intCast(i % ncpu), seed +% @as(u32, @intCast(i)));
        mt[i] = m;
    }
    defer for (&tests) |*m| m.deinit();

    var pm: Periodic = undefined;
    pm.init(seconds);
    defer pm.deinit();
    _ = pm.th.join() catch {};

    // The verdict.
    var status: i32 = 0;
    var sum: u32 = 0;
    for (mt) |m| sum += m.accumulated_count;
    printf("\n==== per-core checks (OS_NCPU={d}) ====\n", .{ncpu});
    for (0..ncpu) |c| {
        const n = g_locks_on_core[c].load(.monotonic);
        printf("core {d}: {d} locks{s}\n", .{ c, n, if (n == 0) "  <- NEVER" else "" });
        if (n == 0) status = 1;
    }
    printf("overlapping holders: {d}\n", .{g_overlaps.load(.monotonic)});
    printf("locks off the pinned core: {d}\n", .{g_wrong_core.load(.monotonic)});
    const counter = @as(*volatile u32, &g_counter).*;
    printf("counter={d}, sum of thread counts={d}\n", .{ counter, sum });
    if (g_overlaps.load(.monotonic) != 0 or g_wrong_core.load(.monotonic) != 0 or counter != sum or sum == 0) status = 1;
    printf("Done.\n", .{});
    return status;
}

// ---- main.cpp --------------------------------------------------------------

pub fn main() void {
    board.uart.init();
    board.uart.print("\n\n+== " ++ board.banner_short ++ " µOS++ SMP MUTEX STRESS : {d} cores ==+\n\n", .{ncpu});
    rtos.run(osMain);
}

fn osMain() void {
    _ = rtos.interrupts.UncriticalSection.enter();
    printf("os_main on core {d}\n", .{cpuId()});
    board.smp.startSecondaryCores();
    const waited = board.smp.waitSecondaries(3000);
    printf("join: {s} ({d}ms)\n", .{ board.smp.joinSummary(), waited });
    if (!board.smp.secondariesJoined()) {
        printf("\nRESULT: FAIL (secondaries did not join)\n", .{});
        board.hw_result.fail();
    }

    printf("\nMutex stress & uniformity test, {d} cores\n", .{ncpu});
    printf("Built with Zig {s}\n", .{builtin.zig_version_string});

    const us = gettimeofdayMicros();
    const tv_sec: u32 = @truncate(us / 1_000_000);
    const tv_usec: u32 = @intCast(us % 1_000_000);
    const seed: u32 = (tv_sec +% tv_usec +% 15485863) *% 179424673;
    printf("Seed {d}\n", .{seed});

    const status = runTests(run_seconds, seed);
    printf("\nRESULT: {s}\n", .{if (status == 0) "PASS" else "FAIL"});
    if (status == 0) board.hw_result.ok();
    board.hw_result.fail();
}
