//! mutex-stress -- mutex stress & uniformity test (the C++ harness suite
//! tests/sources/mutex-stress, main.cpp + test.cpp).
//!
//! Ten threads t0..t9 loop: busy 10..90 µs, sleep 10..200 ticks, then lock
//! the mutex and, inside, busy 1..9 µs and sleep 1..20 ticks and count. A
//! thread "P" (above normal) prints the counts and their spread every 5 s,
//! and after `seconds` (30, as main.cpp without arguments) interrupts and
//! joins the ten threads. main() joins P, prints "Done." and returns 0.
//!
//! As the C++ pico2 build of the harness suites, the kernel runs single-core
//! with the suite's os-app-config.h (BASEPRI 4, a 4000-byte main stack).
//!
//! Details kept from the C++ test:
//!   - rand()/srand() are newlib's (the same 64-bit LCG), shared by all
//!     threads; the seed is made from gettimeofday() (here rtclock seconds,
//!     the microseconds are 0 as on the board) with the same primes.
//!   - busy_wait() spins on hrclock cycles, as the __ARM_EABI__ variant.
//!   - lock()/unlock() results are ignored, as in the C++ object_main().
//!   - the report is printed inside a scheduler critical section.

const std = @import("std");
const builtin = @import("builtin");
const uos = @import("uos");
const t = @import("uos_test");
const rtos = uos.rtos;
const sysclock = rtos.sysclock;
const hrclock = rtos.hrclock;

pub const microzig_options = t.microzig_options;
pub const panic = t.panic;
pub const std_options = t.std_options;

/// tests/sources/mutex-stress/include/cmsis-plus/os-app-config.h,
/// single-core; the stack and heap sizes as in rtos-apis.
pub const uos_options: uos.Options = .{
    .ncpu = 1,
    .smp = false,
    .systick_frequency_hz = 1000,
    .critical_section_interrupt_priority = 4,
    .main_stack_size_bytes = 4000,
    .default_stack_size_bytes = 2048,
    .idle_stack_size_bytes = 2048,
    .dynamic_memory_size_bytes = 32 * 1024,
};

comptime {
    t.exportStartup();
}

pub fn main() void {
    rtos.run(osMain);
}

const printf = uos.trace.print;

// ---- newlib rand() / srand() -----------------------------------------------

var rand_next: u64 = 1;

fn srand(seed: u32) void {
    rand_next = seed;
}

fn rand() c_int {
    rand_next = rand_next *% 6364136223846793005 +% 1;
    return @intCast((rand_next >> 32) & 0x7fffffff);
}

// ---- main.cpp --------------------------------------------------------------

fn busyWait(micros: u32) void {
    const start = hrclock.now();
    const until_cycles = start + @as(u64, hrclock.inputClockFrequencyHz()) * micros / 1000000;
    var now_cycles: u64 = undefined;
    while (true) {
        now_cycles = hrclock.now();
        if (!(now_cycles < until_cycles)) break;
    }
}

fn osMain() u8 {
    const seconds: u32 = 30;

    printf("\nMutex stress & uniformity test\n", .{});
    printf("Built with Zig {s}\n", .{builtin.zig_version_string});

    // gettimeofday(): rtclock seconds, no microseconds.
    const tv_sec: u32 = @truncate(rtos.rtclock.now());
    const tv_usec: u32 = 0;
    // Use some large prime numbers and the current time.
    // Must be a 32-bits value, to overflows and mess things further.
    const seed: u32 = (tv_sec +% tv_usec +% 15485863) *% 179424673;

    printf("Seed {d}\n", .{seed});
    srand(seed);

    const status = runTests(seconds);
    return @intCast(status);
}

// ---- test.cpp --------------------------------------------------------------

var mx: rtos.Mutex = .{};

const MutexTest = struct {
    min_micros: u32 = 10,
    max_micros: u32 = 90,
    min_ticks: u32 = 10,
    max_ticks: u32 = 200,

    ticks: rtos.Duration = 0,
    accumulated_count: u32 = 0,
    count: u32 = 0,

    th: rtos.Thread = undefined,

    fn init(self: *MutexTest, name: [:0]const u8) void {
        self.* = .{};
        self.th.init(name, threadMain, self, .{}, uos.memory.allocator()) catch
            @panic("mutex_test thread");
        uos.trace.print("mutex_test @{*} {s}\n", .{ self, name });
    }

    fn deinit(self: *MutexTest) void {
        self.th.deinit();
    }

    fn threadMain(attr: ?*anyopaque) ?*anyopaque {
        const self: *MutexTest = @ptrCast(@alignCast(attr.?));
        return self.objectMain();
    }

    fn objectMain(self: *MutexTest) ?*anyopaque {
        while (!self.th.isInterrupted()) {
            var nbusy: u32 = (@as(u32, @intCast(rand())) % (self.max_micros - self.min_micros)) + self.min_micros;
            var nsleep: u32 = (@as(u32, @intCast(rand())) % (self.max_ticks - self.min_ticks)) + self.min_ticks;

            // simulate a period of intense activity
            busyWait(nbusy);

            // simulate a period of waiting for an external event
            sysclock.sleepFor(nsleep) catch {};
            self.ticks += nsleep;

            mx.lock() catch {};
            {
                nbusy = (@as(u32, @intCast(rand())) % (self.max_micros / 10 - self.min_micros / 10)) + self.min_micros / 10;
                nsleep = (@as(u32, @intCast(rand())) % (self.max_ticks / 10 - self.min_ticks / 10)) + self.min_ticks / 10;

                // simulate a period of intense activity
                busyWait(nbusy);

                // simulate a period of waiting for an external event
                sysclock.sleepFor(nsleep) catch {};
                self.ticks += nsleep;

                self.accumulated_count += 1;
                self.count += 1;
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
        self.th.init("P", threadMain, self, .{}, uos.memory.allocator()) catch
            @panic("periodic thread");
        uos.trace.print("periodic @{*}\n", .{self});
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

        var tt: u32 = 0;
        while (true) {
            // realtime_clock.sleep_for (5);
            sysclock.sleepFor(5000) catch {};
            tt += 5;

            {
                // ----- Enter critical section -------------------------------
                const scs = rtos.scheduler.CriticalSection.enter();
                defer scs.exit();

                printf("[{d:>3}s] ", .{tt});

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

                    if (delta < min)
                        min = delta;

                    if (delta > max)
                        max = delta;
                }

                const sigma: i32 = @intFromFloat(@sqrt(@as(f64, @floatFromInt(sigma_squares_sum / count))));
                printf(", sigma={d}", .{sigma});

                printf(", delta in [{d},{d}] [{d}%,{d}%]", .{
                    min,
                    max,
                    @divTrunc(min * 100 + @divTrunc(average, 2), average),
                    @divTrunc(max * 100 + @divTrunc(average, 2), average),
                });

                printf("\n", .{});

                // ----- Exit critical section --------------------------------
            }

            if (self.seconds != 0 and tt > self.seconds)
                break;
        }

        for (mt) |m| {
            _ = m.th.interrupt(true);
            _ = m.th.join() catch {};
        }
        return null;
    }
};

fn runTests(seconds: u32) i32 {
    var mt0: MutexTest = undefined;
    var mt1: MutexTest = undefined;
    var mt2: MutexTest = undefined;
    var mt3: MutexTest = undefined;
    var mt4: MutexTest = undefined;
    var mt5: MutexTest = undefined;
    var mt6: MutexTest = undefined;
    var mt7: MutexTest = undefined;
    var mt8: MutexTest = undefined;
    var mt9: MutexTest = undefined;
    mt0.init("t0");
    defer mt0.deinit();
    mt1.init("t1");
    defer mt1.deinit();
    mt2.init("t2");
    defer mt2.deinit();
    mt3.init("t3");
    defer mt3.deinit();
    mt4.init("t4");
    defer mt4.deinit();
    mt5.init("t5");
    defer mt5.deinit();
    mt6.init("t6");
    defer mt6.deinit();
    mt7.init("t7");
    defer mt7.deinit();
    mt8.init("t8");
    defer mt8.deinit();
    mt9.init("t9");
    defer mt9.deinit();

    mt[0] = &mt0;
    mt[1] = &mt1;
    mt[2] = &mt2;
    mt[3] = &mt3;
    mt[4] = &mt4;
    mt[5] = &mt5;
    mt[6] = &mt6;
    mt[7] = &mt7;
    mt[8] = &mt8;
    mt[9] = &mt9;

    var pm: Periodic = undefined;
    pm.init(seconds);
    defer pm.deinit();

    _ = pm.th.join() catch {};

    printf("Done.\n", .{});
    return 0;
}
