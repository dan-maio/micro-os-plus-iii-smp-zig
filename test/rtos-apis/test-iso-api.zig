//! rtos-apis, part 3: the ISO C++ threading API (the C++ test-iso-api.cpp),
//! ported to its Zig counterpart, `std.Io` on the RTOS (`uos.Io`):
//!
//!   estd::thread{f, args...} + join   io.concurrent(f, .{args...}) + await
//!   estd::this_thread::get_id/yield   this_thread.get() / yield()
//!   estd::mutex                       std.Io.Mutex
//!   estd::timed_mutex                 rtos.Mutex (std.Io has no timed lock),
//!                                     durations rounded up to ticks
//!   estd::condition_variable          std.Io.Condition
//!   systick_clock / system_clock /    sysclock ticks / std.Io real clock /
//!   high_resolution_clock             std.Io awake clock (hrclock)
//!   realtime_clock sleeps             rtclock (whole seconds, rounded up)
//!   this_thread::sleep_for/until      io.sleep / Clock.Timestamp.wait
//!
//! `extra` is false, as in the C++ main(): the long waits are skipped.

const std = @import("std");
const Io = std.Io;
const uos = @import("uos");
const rtos = uos.rtos;
const this_thread = rtos.this_thread;
const sysclock = rtos.sysclock;
const printf = uos.trace.print;

const test_name = "Test ISO C++ API";

fn task1() void {
    printf("task1()\n", .{});
}

fn task2(args: *const anyopaque) void {
    printf("task2({*})\n", .{args});
}

fn task3(args: *anyopaque) void {
    printf("task3({*})\n", .{args});
}

fn task4(n: i32, str: []const u8) void {
    printf("task4({d},{s})\n", .{ n, str });
}

fn isReady() bool {
    return true;
}

/// A duration in nanoseconds as systick ticks, rounded up (estd::chrono).
fn ticks(ns: u64) rtos.Duration {
    const hz = rtos.Clock.frequency_hz;
    return @intCast((ns * hz + std.time.ns_per_s - 1) / std.time.ns_per_s);
}

const ns_per_ms = std.time.ns_per_ms;
const ns_per_us = std.time.ns_per_us;
const ns_per_s = std.time.ns_per_s;

/// try_lock_until() on the RTOS mutex: the ticks until `deadline` (sysclock).
fn tryLockUntil(mx: *rtos.Mutex, deadline: rtos.Timestamp) bool {
    const now = sysclock.now();
    const wait: rtos.Duration = if (deadline > now) @intCast(deadline - now) else 0;
    if (mx.timedLock(wait)) |_| return true else |_| return false;
}

/// sleep_for<realtime_clock>(): whole seconds, rounded up.
fn rtSleepFor(ns: u64) void {
    rtos.rtclock.sleepFor(@intCast((ns + ns_per_s - 1) / ns_per_s)) catch {};
}

/// sleep_until(realtime_clock::now() + d): whole seconds, rounded up.
fn rtSleepUntil(ns: u64) void {
    const target = rtos.rtclock.now() + (ns + ns_per_s - 1) / ns_per_s;
    rtos.rtclock.sleepUntil(target) catch {};
}

pub fn run(io: Io, extra: bool) i32 {
    printf("\n{s} - Threads\n", .{test_name});
    {
        {
            var th11 = io.concurrent(task1, .{}) catch return 1;
            th11.await(io);
        }
        {
            var c: u8 = 0;
            var th21 = io.concurrent(task2, .{@as(*const anyopaque, &c)}) catch return 1;
            var th31 = io.concurrent(task3, .{@as(*anyopaque, &c)}) catch return 1;
            var th41 = io.concurrent(task4, .{ 7, "xyz" }) catch return 1;
            th21.await(io);
            th31.await(io);
            th41.await(io);
        }
        {
            const id = this_thread.get();
            _ = id;
            this_thread.yield();
        }
    }

    printf("\n{s} - Mutexes\n", .{test_name});
    {
        {
            var mx11: Io.Mutex = .init;
            mx11.lockUncancelable(io);
            mx11.unlock(io);
            _ = mx11.tryLock();
            mx11.unlock(io);
        }
        {
            var mx21: rtos.Mutex = .{};
            mx21.lock() catch {};
            mx21.unlock() catch {};
            mx21.tryLock() catch {};
            mx21.unlock() catch {};

            mx21.timedLock(2999) catch {}; // systicks (2999)
            mx21.unlock() catch {};
            mx21.timedLock(ticks(3 * ns_per_s)) catch {}; // seconds (3)
            mx21.unlock() catch {};
            mx21.timedLock(ticks(3001 * ns_per_ms)) catch {}; // 3001 ticks
            mx21.unlock() catch {};
            mx21.timedLock(ticks(3001001 * ns_per_us)) catch {}; // 3002 ticks
            mx21.unlock() catch {};
            mx21.timedLock(ticks(3002000001)) catch {}; // 3003 ticks
            mx21.unlock() catch {};
            mx21.timedLock(ticks(ns_per_us)) catch {}; // 1 tick
            mx21.unlock() catch {};
            mx21.timedLock(ticks(1)) catch {}; // 1 tick
            mx21.unlock() catch {};

            // system_clock and systick_clock deadlines (both sysclock based).
            if (tryLockUntil(&mx21, sysclock.now() + ticks(5000 * ns_per_us))) mx21.unlock() catch {};
            if (tryLockUntil(&mx21, sysclock.now() + ticks(5 * ns_per_ms))) mx21.unlock() catch {};
            if (tryLockUntil(&mx21, sysclock.now() + ticks(5 * ns_per_us))) mx21.unlock() catch {};
            if (tryLockUntil(&mx21, sysclock.now() + ticks(5 * ns_per_ms))) mx21.unlock() catch {};
            // realtime_clock deadlines: the mutex is free, it locks at once.
            if (tryLockUntil(&mx21, sysclock.now() + ticks(10 * ns_per_ms))) mx21.unlock() catch {};
            if (tryLockUntil(&mx21, sysclock.now() + ticks(100 * ns_per_ms))) mx21.unlock() catch {};
        }
    }

    printf("\n{s} - Condition variables\n", .{test_name});
    {
        var cv11: Io.Condition = .init;
        cv11.signal(io);
        cv11.broadcast(io);

        if (extra) {
            var mxl: Io.Mutex = .init;
            mxl.lockUncancelable(io);
            defer mxl.unlock(io);
            cv11.waitUncancelable(io, &mxl);
            while (!isReady()) cv11.waitUncancelable(io, &mxl);
            cv11.waitTimeout(io, &mxl, .{ .duration = .{ .raw = .fromMilliseconds(10), .clock = .awake } }) catch {};
        }
    }

    printf("\n{s} - Chrono\n", .{test_name});

    io.sleep(.fromNanoseconds(5 * ns_per_ms), .awake) catch {}; // 5 ticks

    const tp = sysclock.now();
    printf("Systick_clock::now() = {d} ticks\n", .{tp});

    const tp2 = Io.Clock.real.now(io);
    printf("system_clock::now() = {d} us\n", .{tp2.toMicroseconds()});

    const tp3 = Io.Clock.awake.now(io);
    printf("high_resolution_clock::now() = {d} ns\n", .{tp3.toNanoseconds()});

    io.sleep(.fromNanoseconds(5 * ns_per_ms), .awake) catch {}; // 5 ticks
    io.sleep(.fromMilliseconds(5), .awake) catch {};
    io.sleep(.fromMicroseconds(5001), .awake) catch {}; // 5 ticks
    io.sleep(.fromNanoseconds(5002000), .awake) catch {}; // 5 ticks
    io.sleep(.fromMicroseconds(1), .awake) catch {}; // 1 tick
    io.sleep(.fromNanoseconds(1), .awake) catch {}; // 1 tick

    sysclock.sleepFor(4) catch {}; // sleep_for<systick_clock> (4_ticks)
    sysclock.sleepFor(ticks(4 * ns_per_ms)) catch {}; // (4ms)

    printf("sleep_for<chrono::realtime_clock> (1s)\n", .{});
    rtSleepFor(ns_per_s);

    printf("sleep_for<chrono::realtime_clock> (1001ms)\n", .{});
    rtSleepFor(1001 * ns_per_ms);

    if (extra) {
        io.sleep(.fromSeconds(3), .awake) catch {};
    }

    (Io.Clock.Timestamp.fromNow(io, .{ .raw = .fromMicroseconds(1000), .clock = .awake })).wait(io) catch {};
    (Io.Clock.Timestamp.fromNow(io, .{ .raw = .fromMilliseconds(1), .clock = .awake })).wait(io) catch {};
    sysclock.sleepUntil(sysclock.now() + ticks(ns_per_us)) catch {};
    sysclock.sleepUntil(sysclock.now() + ticks(ns_per_ms)) catch {};

    rtSleepUntil(10 * ns_per_ms);
    rtSleepUntil(100 * ns_per_ms);

    printf("sleep_until (chrono::realtime_clock::now () + 1000ms)\n", .{});
    rtSleepUntil(1000 * ns_per_ms);

    printf("sleep_until (chrono::realtime_clock::now () + 1s)\n", .{});
    rtSleepUntil(ns_per_s);

    // my_sleep (70)
    sysclock.sleepFor(70) catch {};

    printf("\n{s} - Done\n", .{test_name});
    return 0;
}
