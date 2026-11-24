//! mutex-stress -- mutex stress & uniformity test on Raspberry Pi 4 B
//! (the C++ test/rpi4b/mutex-stress: the kernel's suite tests/sources/mutex-stress).
//!
//! Ten threads t0..t9 loop: busy 10..90 µs, sleep 10..200 ticks, then lock
//! the mutex and, inside, busy 1..9 µs and sleep 1..20 ticks and count. A
//! thread "P" (above normal) prints the counts and their spread every 5 s,
//! and after `seconds` interrupts and joins the ten threads. main() joins P,
//! prints "Done." and the verdict. As the C++ rpi4b harness build: 4 CPUs
//! (1..3 released first), an 8192-element main stack, 30 s.

const std = @import("std");
const builtin = @import("builtin");
const uos = @import("uos");
const board = @import("board");
const rtos = uos.rtos;
const sysclock = rtos.sysclock;
const hrclock = rtos.hrclock;

/// As the C++ rpi4b harness build: the board's 4 CPUs, an 8192-element
/// main stack.
pub const uos_options: uos.Options = blk: {
    var o = board.options(4);
    o.main_stack_size_bytes = 8192 * @sizeOf(uos.port.StackElement);
    break :blk o;
};

pub fn main() void {
    board.uart.init();
    rtos.run(osMain);
}

const printf = board.uart.print;

/// The C++ rpi4b harness platform (tests/platforms/aarch64-rpi4b/src/
/// platform-support.cpp): the suite runs on all four CPUs, so CPUs 1..3 are
/// released (and waited for) before it starts.
fn bringUpSecondaries() void {
    board.smp.startSecondaryCores();
    _ = board.smp.waitSecondaries(3000);
}

// ---- newlib rand() / srand() -----------------------------------------------

var rand_next: u64 = 1;

fn srand(seed: u32) void {
    rand_next = seed;
}

fn rand() c_int {
    rand_next = rand_next *% 6364136223846793005 +% 1;
    return @intCast((rand_next >> 32) & 0x7fffffff);
}

// ---- main ------------------------------------------------------------------

fn busyWait(micros: u32) void {
    const start = hrclock.now();
    const until_cycles = start + @as(u64, hrclock.inputClockFrequencyHz()) * micros / 1000000;
    var now_cycles: u64 = undefined;
    while (true) {
        now_cycles = hrclock.now();
        if (!(now_cycles < until_cycles)) break;
    }
}

fn osMain() void {
    bringUpSecondaries();
    const seconds: u32 = 30; // the suite's default (the board passes no argument)

    printf("\nMutex stress & uniformity test\n", .{});
    printf("Built with Zig {s}\n", .{builtin.zig_version_string});

    // Seed from hrclock or generic timer
    const seed: u32 = @truncate((hrclock.now() +% 15485863) *% 179424673);

    printf("Seed {d}\n", .{seed});
    srand(seed);

    const status = runTests(seconds);

    printf("\nRESULT: {s}\n", .{if (status == 0) "PASS" else "FAIL"});
    if (status == 0) board.hw_result.ok();
    board.hw_result.fail();
}

// ---- test logic ------------------------------------------------------------

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
        printf("mutex_test @{*} {s}\n", .{ self, name });
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
        printf("periodic @{*}\n", .{self});
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
            sysclock.sleepFor(5000) catch {};
            tt += 5;

            {
                const scs = rtos.scheduler.CriticalSection.enter();
                defer scs.exit();

                var min: u32 = std.math.maxInt(u32);
                var max: u32 = 0;
                var sum: u32 = 0;

                for (mt) |t| {
                    if (t.count < min) min = t.count;
                    if (t.count > max) max = t.count;
                    sum += t.count;
                }

                const delta = max - min;
                const percent: u32 = if (sum > 0)
                    @intCast((@as(u64, delta) * 1000) / sum)
                else
                    0;

                printf("{d:>3}s: {d:>5} (delta={d:>2}, {d}.{d}%)\n", .{
                    tt, sum, delta, percent / 10, percent % 10,
                });

                for (mt) |t| {
                    t.count = 0;
                }
            }

            if (tt >= self.seconds) {
                for (mt) |t| {
                    _ = t.th.interrupt(true);
                }
                for (mt) |t| {
                    _ = t.th.join() catch {};
                }
                break;
            }
        }
        return null;
    }
};

fn runTests(seconds: u32) u32 {
    const a = uos.memory.allocator();

    for (0..10) |i| {
        mt[i] = a.create(MutexTest) catch @panic("create MutexTest");
    }

    mx.init("mx", .{}) catch @panic("mx init");

    const names = [_][:0]const u8{ "t0", "t1", "t2", "t3", "t4", "t5", "t6", "t7", "t8", "t9" };
    for (0..10) |i| {
        mt[i].init(names[i]);
    }

    var periodic: Periodic = undefined;
    periodic.init(seconds);

    _ = periodic.th.join() catch {};

    periodic.deinit();

    var min: u32 = std.math.maxInt(u32);
    var max: u32 = 0;
    var sum: u32 = 0;

    for (mt) |t| {
        if (t.accumulated_count < min) min = t.accumulated_count;
        if (t.accumulated_count > max) max = t.accumulated_count;
        sum += t.accumulated_count;
    }

    const delta = max - min;
    const percent: u32 = if (sum > 0)
        @intCast((@as(u64, delta) * 1000) / sum)
    else
        0;

    printf("\nTotal: {d} (delta={d}, {d}.{d}%)\n", .{
        sum, delta, percent / 10, percent % 10,
    });

    for (mt) |t| {
        t.deinit();
        a.destroy(t);
    }

    mx.deinit();

    printf("Done.\n", .{});
    // Criteria: sum > 0 and reasonable spread
    return if (sum > 0 and percent < 800) 0 else 1;
}
