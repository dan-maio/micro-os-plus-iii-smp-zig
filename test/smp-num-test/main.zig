//! smp-num-test -- Multi-threaded concurrent I/O demo across 4 cores
//! (the C++ test/rpi4b/smp-num-test).
//!
//! Five concurrent worker threads with explicit priorities:
//!   1. uart-writer    (prio high)         : console tick every 0.5 s
//!   2. led-blinker    (prio above_normal) : GPIO ACT LED, 5 blinks per pass (0.3s on/off),
//!                                           paces passes with a counting semaphore
//!   3. sd-text-writer (prio normal)       : 20 lines of text appended to num.txt on SD card
//!   4. fp-compute     (prio below_normal) : 20 sin/cos/sqrt/log results appended to num.txt
//!   5. sd-reader      (prio low)          : streams and verifies newly appended tail
//!
//! Synchronisation: num.txt access is serialised by a mutex; the LED thread paces passes
//! via a counting semaphore. Runs for 20 seconds.

const std = @import("std");
const uos = @import("uos");
const board = @import("board");
const sd = @import("sd");
const flatfs = @import("flatfs");
const rtos = uos.rtos;
const sysclock = rtos.sysclock;
const ncpu = uos.config.ncpu;

pub const uos_options = board.options(4);

const printf = board.uart.print;
const run_ms: u32 = 20000; // 20 seconds soak

const kTextLines: usize = 20;
const kComputeLines: usize = 20;
const kNumFile = "num.txt";

var g_card: sd.SdCard = .{};
var g_fs: flatfs.FlatFs = .{};
var g_file_mtx: rtos.Mutex = .{ .name = "file_mtx" };
var g_beat: rtos.Semaphore = .counting("beat", 3, 0);

var g_text_written: std.atomic.Value(u32) = .init(0);
var g_calc_written: std.atomic.Value(u32) = .init(0);
var g_text_fail: std.atomic.Value(u32) = .init(0);
var g_calc_fail: std.atomic.Value(u32) = .init(0);
var g_read_fail: std.atomic.Value(u32) = .init(0);
var g_finish: std.atomic.Value(bool) = .init(false);

var g_num_buf: [256 * 1024]u8 = undefined;
var g_num_len: usize = 0;
var g_read_buf: [256 * 1024]u8 = undefined;
var g_core_lines: [4]u32 = @splat(0);

fn cpuId() u32 {
    return uos.port.scheduler.cpuId();
}

fn appendFile(text: []const u8) bool {
    g_file_mtx.lock() catch return false;
    defer g_file_mtx.unlock() catch {};

    const cid = cpuId();
    if (cid < 4) g_core_lines[cid] += 1;

    var line_buf: [256]u8 = undefined;
    const tagged = std.fmt.bufPrint(&line_buf, "[c{d}] {s}\n", .{ cid, text }) catch return false;

    if (g_num_len + tagged.len > g_num_buf.len) return false;
    @memcpy(g_num_buf[g_num_len .. g_num_len + tagged.len], tagged);
    g_num_len += tagged.len;

    g_fs.writeFile(kNumFile, g_num_buf[0..g_num_len]) catch return false;
    return true;
}

// 1. UART console writer thread
fn uartWriterThread(_: ?*anyopaque) ?*anyopaque {
    var tick: u32 = 0;
    while (!g_finish.load(.monotonic)) {
        sysclock.sleepFor(500) catch {};
        tick += 1;
        printf("[c{d}] tick {d} (elapsed: {d} ms, num.txt: {d} B)\n", .{
            cpuId(), tick, tick * 500, g_num_len,
        });
    }
    return null;
}

// 2. LED blinker pacing thread
fn ledBlinkerThread(_: ?*anyopaque) ?*anyopaque {
    var pass: u32 = 0;
    while (!g_finish.load(.monotonic)) {
        pass += 1;
        for (0..5) |_| {
            board.led.on();
            sysclock.sleepFor(150) catch {};
            board.led.off();
            sysclock.sleepFor(150) catch {};
        }
        printf("[c{d}] LED pass {d} complete, posting beat...\n", .{ cpuId(), pass });
        for (0..3) |_| {
            g_beat.post() catch {};
        }
    }
    return null;
}

// 3. SD text writer thread
fn sdTextWriterThread(_: ?*anyopaque) ?*anyopaque {
    var pass: u32 = 0;
    while (!g_finish.load(.monotonic)) {
        g_beat.wait() catch continue;
        if (g_finish.load(.monotonic)) break;
        pass += 1;

        for (0..kTextLines) |line| {
            var msg: [128]u8 = undefined;
            const str = std.fmt.bufPrint(&msg, "text line #{d} pass #{d} from thread text-writer", .{ line, pass }) catch continue;
            if (appendFile(str)) {
                _ = g_text_written.fetchAdd(1, .monotonic);
            } else {
                _ = g_text_fail.fetchAdd(1, .monotonic);
            }
        }
    }
    return null;
}

// 4. Floating point math compute writer thread
fn fpComputeThread(_: ?*anyopaque) ?*anyopaque {
    var pass: u32 = 0;
    var x: f32 = 1.0;
    while (!g_finish.load(.monotonic)) {
        g_beat.wait() catch continue;
        if (g_finish.load(.monotonic)) break;
        pass += 1;

        for (0..kComputeLines) |line| {
            x += 0.15;
            const s = @sin(x);
            const c = @cos(x);
            const sq = @sqrt(x);
            const l = @log(x);

            var msg: [128]u8 = undefined;
            const str = std.fmt.bufPrint(&msg, "fp line #{d} pass #{d}: sin={d:.4} cos={d:.4} sqrt={d:.4} log={d:.4}", .{
                line, pass, s, c, sq, l,
            }) catch continue;

            if (appendFile(str)) {
                _ = g_calc_written.fetchAdd(1, .monotonic);
            } else {
                _ = g_calc_fail.fetchAdd(1, .monotonic);
            }
        }
    }
    return null;
}

// 5. SD card reader thread
fn sdReaderThread(_: ?*anyopaque) ?*anyopaque {
    var last_verified_len: usize = 0;
    while (!g_finish.load(.monotonic)) {
        g_beat.wait() catch continue;
        if (g_finish.load(.monotonic)) break;

        g_file_mtx.lock() catch continue;
        var r_ok = false;
        if (g_fs.readFile(kNumFile, &g_read_buf)) |rsize| {
            if (rsize >= last_verified_len) {
                r_ok = std.mem.eql(u8, g_read_buf[0..rsize], g_num_buf[0..rsize]);
                last_verified_len = rsize;
            }
        } else |_| {}
        g_file_mtx.unlock() catch {};

        if (!r_ok) {
            _ = g_read_fail.fetchAdd(1, .monotonic);
        }
    }
    return null;
}

pub fn main() void {
    board.uart.init();
    board.led.init();
    uos.rtos.run(osMain);
}

const worker_stack_size = 16384;
const Stack = [worker_stack_size / @sizeOf(uos.port.StackElement)]uos.port.StackElement;

var s_uart_stk: Stack = undefined;
var s_led_stk: Stack = undefined;
var s_text_stk: Stack = undefined;
var s_calc_stk: Stack = undefined;
var s_read_stk: Stack = undefined;

var t_uart: rtos.Thread = undefined;
var t_led: rtos.Thread = undefined;
var t_text: rtos.Thread = undefined;
var t_calc: rtos.Thread = undefined;
var t_read: rtos.Thread = undefined;

fn osMain() void {
    printf("\n", .{});
    printf("=============================================\n", .{});
    printf("  {s} - {s}\n", .{ board.banner_long, board.banner_cpu });
    printf("  micro-os-plus-iii  smp-num-test\n", .{});
    printf("  5 concurrent threads with priorities & SD card\n", .{});
    printf("=============================================\n\n", .{});

    if (!g_card.init()) {
        printf("Card init failed! (Using in-memory sector buffer fallback)\n", .{});
    }
    g_fs.format(&g_card) catch {};
    g_num_len = 0;

    // Release secondary cores
    _ = rtos.interrupts.UncriticalSection.enter();
    board.smp.startSecondaryCores();
    const joined = board.smp.waitSecondaries(3000);
    printf("Secondary cores joined: {s} ({d} ms)\n\n", .{ board.smp.joinSummary(), joined });

    const gpa = uos.memory.allocator();

    // Launch the 5 threads with distinct priorities and affinities
    t_uart.init("uart-writer", uartWriterThread, null, .{ .stack = &s_uart_stk, .priority = rtos.priority.high, .cpu_affinity = 1 << 0 }, gpa) catch unreachable;
    t_led.init("led-blinker", ledBlinkerThread, null, .{ .stack = &s_led_stk, .priority = rtos.priority.above_normal, .cpu_affinity = 1 << 1 }, gpa) catch unreachable;
    t_text.init("sd-text-wrt", sdTextWriterThread, null, .{ .stack = &s_text_stk, .priority = rtos.priority.normal, .cpu_affinity = 1 << 2 }, gpa) catch unreachable;
    t_calc.init("fp-compute", fpComputeThread, null, .{ .stack = &s_calc_stk, .priority = rtos.priority.below_normal, .cpu_affinity = 1 << 3 }, gpa) catch unreachable;
    t_read.init("sd-reader", sdReaderThread, null, .{ .stack = &s_read_stk, .priority = rtos.priority.low, .cpu_affinity = 1 << 0 }, gpa) catch unreachable;

    printf("5 threads started. Running concurrent soak for {d} ms...\n\n", .{run_ms});

    const start_time: u32 = @truncate(sysclock.now());
    while (@as(u32, @truncate(sysclock.now())) -% start_time < run_ms) {
        sysclock.sleepFor(500) catch {};
    }

    printf("\nStopping threads...\n", .{});
    g_finish.store(true, .monotonic);
    for (0..5) |_| g_beat.post() catch {};
    sysclock.sleepFor(400) catch {};

    const tw = g_text_written.load(.monotonic);
    const cw = g_calc_written.load(.monotonic);
    const tf = g_text_fail.load(.monotonic);
    const cf = g_calc_fail.load(.monotonic);
    const rf = g_read_fail.load(.monotonic);

    printf("\n================ smp-num-test Summary ================\n", .{});
    printf("  Text lines written : {d} (failures: {d})\n", .{ tw, tf });
    printf("  Math lines written : {d} (failures: {d})\n", .{ cw, cf });
    printf("  Reader mismatches  : {d}\n", .{rf});
    printf("  Total num.txt size : {d} bytes\n", .{g_num_len});
    printf("  Lines by core: c0={d} c1={d} c2={d} c3={d}\n", .{
        g_core_lines[0], g_core_lines[1], g_core_lines[2], g_core_lines[3],
    });
    printf("======================================================\n", .{});

    const pass = tw > 50 and cw > 50 and tf == 0 and cf == 0 and rf == 0 and g_num_len > 1000;
    printf("\nRESULT: {s}\n", .{if (pass) "PASS" else "FAIL"});
    if (pass) board.hw_result.ok();
    board.hw_result.fail();
}
