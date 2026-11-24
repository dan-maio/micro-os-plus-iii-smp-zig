//! smp-num-test -- concurrent workers and file I/O (the C++
//! test/rpi4b/smp-num-test, its HW_BUILD branch: FatFs on the
//! existing FAT32 partition of the board's SD card, num.txt in /tests, the
//! card never formatted).
//!
//! Five threads with explicit priorities, highest first: a console ticker
//! (every 0.5 s), an LED blinker (5 blinks of 0.3 s per pass, then 3 posts
//! of the "beat" semaphore), a text writer and an FPU compute writer (20
//! lines each per beat, appended to num.txt) and a reader that streams the
//! new tail. Every tests/num.txt access is under one mutex. After RUN_MS (60 s)
//! the file is dumped; PASS when both writers wrote and nothing failed.
//!
//! The math and the number formatting are Zig's (@sin/@cos/@log, std.fmt):
//! a value may differ from the C++ output in the last printed digit.
//!
//! Differences from C++: the kernel prints its startup banner and creates
//! the secondary idle threads; the priorities are given at creation. The
//! 4096- and 8192-element stacks are used as given, as in C++.

const std = @import("std");
const uos = @import("uos");
const board = @import("board");
const sd = @import("sd");
const fatfs = @import("fatfs");
const rtos = uos.rtos;
const sysclock = rtos.sysclock;
const this_thread = rtos.this_thread;
const ncpu = uos.config.ncpu;
const console = board.console;
const led = board.led;

pub const uos_options = board.options(4);

const run_ms: u32 = 60000;
const text_lines = 20; // SD text lines per pass
const compute_lines = 20; // FPU compute lines per pass
const led_blinks = 5; // LED blinks per pass (0.3 s each)

fn cpuId() u32 {
    return uos.port.scheduler.cpuId();
}

// ---- Shared state ----------------------------------------------------------

var g_card: sd.SdCard = .{};

const num_file = "num.txt";

// All num.txt access serialised by this mutex.
var g_file_mtx: rtos.Mutex = .{ .name = "file" };

// The pass beat: 3 posts per LED pass, one per writer and one for the reader.
var g_beat: rtos.Semaphore = .counting("beat", 3, 0);

const Counter = std.atomic.Value(u32);
var g_text_written = Counter.init(0);
var g_calc_written = Counter.init(0);
var g_text_fail = Counter.init(0);
var g_calc_fail = Counter.init(0);
var g_read_fail = Counter.init(0);
var g_led_fail = Counter.init(0);

var g_finish = std.atomic.Value(bool).init(false);

fn finished() bool {
    return g_finish.load(.monotonic);
}

// The whole-file read buffer (reader and final dump).
var g_read_buf: [256 * 1024]u8 = undefined;

var g_core_lines: [ncpu]Counter = @splat(.init(0));

// ---- SD helpers, called with g_file_mtx held --------------------------------

fn sdAppend(text: []const u8) bool {
    // "[cN] " first: the CPU doing the file I/O.
    var tagged: [160]u8 = undefined;
    const tag = std.fmt.bufPrint(&tagged, "[c{d}] ", .{cpuId()}) catch tagged[0..0];
    const core = cpuId();
    if (core < ncpu) _ = g_core_lines[core].fetchAdd(1, .monotonic);
    const len = @min(text.len, tagged.len - tag.len);
    @memcpy(tagged[tag.len..][0..len], text[0..len]);
    const line = tagged[0 .. tag.len + len];

    return fatfs.appendFile(num_file, line);
}

fn sdReadAll(out: []u8) ?usize {
    const size = fatfs.fileSize(num_file) orelse return null;
    if (size > out.len) return null;
    if (!fatfs.loadFile(num_file, out[0..size])) return null;
    return size;
}

fn sdRemoveNum() void {
    // So that each run starts from an empty file.
    // A missing file is fine; an I/O error is ignored.
    _ = fatfs.removeFile(num_file);
    console("  removed previous num.txt (if any)\n", .{});
}

fn hang() noreturn {
    while (true) sysclock.sleepFor(1000) catch {};
}

fn sdPrepare() void {
    console("Initialising SD card via SDHCI (EMMC2 @0xFE340000)...\n", .{});
    if (!g_card.init()) {
        console("  SD init FAILED: {s}\n", .{g_card.lastError()});
        board.hw_result.fail();
    }
    console("  SD card ready: {d} sectors (~{d} MiB)\n", .{ g_card.sectorCount(), g_card.capacityBytes() >> 20 });
    fatfs.bindCard(&g_card);
    if (!fatfs.mountVolume()) {
        console("  FAT32 mount failed: {s}\n", .{fatfs.lastError()});
        board.hw_result.fail();
    }
    if (!fatfs.ensureTestsDir()) {
        console("  mkdir tests failed: {s}\n", .{fatfs.lastError()});
        board.hw_result.fail();
    }
    console("  FAT32 /tests ready (boot files untouched).\n", .{});
}

// ---- Thread 1: uart-writer (high) -------------------------------------------

fn uartThread(_: ?*anyopaque) ?*anyopaque {
    var tick: u32 = 0;
    while (!finished()) {
        console("[c{d}][uart] tick {d}  (text={d} calc={d})\n", .{ cpuId(), tick, g_text_written.load(.monotonic), g_calc_written.load(.monotonic) });
        tick += 1;
        sysclock.sleepFor(500) catch {};
    }
    return null;
}

// ---- Thread 2: led-blinker (above normal) ------------------------------------

fn ledThread(_: ?*anyopaque) ?*anyopaque {
    // One pass = led_blinks blinks; then one beat to each writer and one to
    // the reader.
    while (!finished()) {
        for (0..led_blinks) |_| {
            led.on();
            console("[c{d}] led on\n", .{cpuId()});
            sysclock.sleepFor(300) catch {};
            led.off();
            console("[c{d}] led off\n", .{cpuId()});
            sysclock.sleepFor(300) catch {};
        }
        g_beat.post() catch {};
        g_beat.post() catch {};
        g_beat.post() catch {};
    }
    console("[c{d}] LED stopped\n", .{cpuId()});
    return null;
}

/// Stay CPU-bound for a while (no sleep), so that idle CPUs can take the
/// thread.
fn cpuBurnYield() void {
    var acc: f32 = 1.0;
    var k: u32 = 0;
    while (k < 80000) : (k += 1) @as(*volatile f32, &acc).* = @as(*volatile f32, &acc).* * 1.000001 + 0.000001;
    this_thread.yield();
}

fn waitBeat() bool {
    while (!finished()) {
        if (g_beat.tryWait()) |_| return true else |_| {}
        sysclock.sleepFor(10) catch {};
    }
    return false;
}

// ---- Thread 3: sd-text-writer (normal) ----------------------------------------

fn sdTextThread(_: ?*anyopaque) ?*anyopaque {
    const fills = [_][]const u8{ "lorem", "ipsum", "dolor", "amet" };
    const head = "TEXT the quick brown fox jumps over the lazy dog ";
    const tail = " END\n";
    while (!finished()) {
        if (!waitBeat()) break;
        for (0..text_lines) |i| {
            // A ~100-char, letters-only line (no digits).
            const fill = fills[i & 3];
            var line: [128]u8 = undefined;
            @memcpy(line[0..head.len], head);
            var pos: usize = head.len;
            while (pos < 96) {
                for (fill) |ch| {
                    if (pos >= 96) break;
                    line[pos] = ch;
                    pos += 1;
                }
                if (pos < 96) {
                    line[pos] = '-';
                    pos += 1;
                }
            }
            if (pos > 0 and line[pos - 1] == '-') pos -= 1;
            @memcpy(line[pos..][0..tail.len], tail);
            pos += tail.len;

            g_file_mtx.lock() catch {};
            if (sdAppend(line[0..pos])) _ = g_text_written.fetchAdd(1, .monotonic) else _ = g_text_fail.fetchAdd(1, .monotonic);
            g_file_mtx.unlock() catch {};
            cpuBurnYield();
        }
    }
    return null;
}

// ---- Thread 4: fp-compute (below normal) ------------------------------------

/// `%+.6f`: std.fmt has no explicit-sign flag.
const Signed = struct {
    v: f64,
    pub fn format(self: Signed, w: *std.Io.Writer) std.Io.Writer.Error!void {
        if (!std.math.signbit(self.v)) try w.writeByte('+');
        try w.print("{d:.6}", .{self.v});
    }
};

fn computeThread(_: ?*anyopaque) ?*anyopaque {
    while (!finished()) {
        if (!waitBeat()) break;
        for (0..compute_lines) |i| {
            const x: f32 = 0.1 + 0.37 * @as(f32, @floatFromInt(i));
            const s = @sin(x);
            const co = @cos(x);
            const l: f32 = if (x > 0.0) @log(x) else 0.0;
            var line: [160]u8 = undefined;
            const xd: f64 = x;
            // The board has no floating-point printf (the C++ one is
            // newlib's): std.fmt may round the last printed digit
            // differently.
            const text = std.fmt.bufPrint(line[0 .. line.len - 1], "CALC {d:0>3}: sin({d:.3})={f} cos({d:.3})={f} log({d:.3})={f}\n", .{
                i, xd, Signed{ .v = s }, xd, Signed{ .v = co }, xd, Signed{ .v = l },
            }) catch line[0 .. line.len - 1];

            g_file_mtx.lock() catch {};
            if (sdAppend(text)) _ = g_calc_written.fetchAdd(1, .monotonic) else _ = g_calc_fail.fetchAdd(1, .monotonic);
            g_file_mtx.unlock() catch {};
            cpuBurnYield();
        }
    }
    return null;
}

// ---- Thread 5: sd-reader (low) -----------------------------------------------

fn readerThread(_: ?*anyopaque) ?*anyopaque {
    var last_len: usize = 0;
    var pass: u32 = 0;
    while (!finished()) {
        if (!waitBeat()) break;
        sysclock.sleepFor(20) catch {}; // let the writers' last writes land

        g_file_mtx.lock() catch {};
        const got = sdReadAll(&g_read_buf);
        g_file_mtx.unlock() catch {};
        const len = got orelse {
            _ = g_read_fail.fetchAdd(1, .monotonic);
            console("[c{d}][reader] read num.txt FAILED\n", .{cpuId()});
            continue;
        };
        if (len < last_len) last_len = 0; // removed and recreated
        console("[c{d}][reader] pass {d}: num.txt now {d} bytes (+{d})\n", .{ cpuId(), pass, len, len - last_len });
        // Stream only the new tail.
        var off = last_len;
        while (off < len) : (off += 128) {
            board.uart.puts(g_read_buf[off..@min(len, off + 128)]);
            this_thread.yield();
        }
        last_len = len;
        pass += 1;
    }
    console("[c{d}][reader] stopped after {d} dumps\n", .{ cpuId(), pass });
    return null;
}

// ---- Main ------------------------------------------------------------------

const El = uos.port.StackElement;
var uart_stk: [4096]El = undefined;
var led_stk: [4096]El = undefined;
var text_stk: [4096]El = undefined;
var calc_stk: [8192]El = undefined;
var reader_stk: [8192]El = undefined;
var t_uart: rtos.Thread = undefined;
var t_led: rtos.Thread = undefined;
var t_text: rtos.Thread = undefined;
var t_calc: rtos.Thread = undefined;
var t_read: rtos.Thread = undefined;

pub fn main() void {
    board.uart.init();
    led.init();
    rtos.run(osMain);
}

fn osMain() void {
    console("\n+== " ++ board.banner_short ++ " µOS++ NUM TEST (" ++ board.banner_isa ++ ") : uart+LED+SD+FPU ==+\n\n", .{});
    sdPrepare();
    sdRemoveNum();

    _ = rtos.interrupts.UncriticalSection.enter();
    board.smp.startSecondaryCores();
    var waited: u32 = 0;
    while ((board.smp.coreStage(1) < 3 or board.smp.coreStage(2) < 3 or board.smp.coreStage(3) < 3) and waited < 3000) {
        sysclock.sleepFor(50) catch {};
        waited += 50;
    }
    console("join: c1={d} c2={d} c3={d} ({d} ms)\n", .{ board.smp.coreStage(1), board.smp.coreStage(2), board.smp.coreStage(3), waited });

    // The threads, high to low.
    const gpa = uos.memory.allocator();
    t_uart.init("uart", uartThread, null, .{ .stack = &uart_stk, .priority = rtos.priority.high }, gpa) catch unreachable;
    t_led.init("led", ledThread, null, .{ .stack = &led_stk, .priority = rtos.priority.above_normal }, gpa) catch unreachable;
    t_text.init("sdtext", sdTextThread, null, .{ .stack = &text_stk, .priority = rtos.priority.normal }, gpa) catch unreachable;
    t_calc.init("compute", computeThread, null, .{ .stack = &calc_stk, .priority = rtos.priority.below_normal }, gpa) catch unreachable;
    t_read.init("sdread", readerThread, null, .{ .stack = &reader_stk, .priority = rtos.priority.low }, gpa) catch unreachable;

    console("threads started (uart=high, led=above_normal, text=normal, compute=below_normal, reader=low)\n", .{});

    // The repeating passes, for the wall-clock window.
    const start_ms: u32 = @truncate(sysclock.now());
    console("running for {d} ms ...\n", .{run_ms});
    while (@as(u32, @truncate(sysclock.now())) -% start_ms < run_ms) sysclock.sleepFor(100) catch {};

    // Stop the workers.
    g_finish.store(true, .monotonic);
    sysclock.sleepFor(200) catch {};
    g_beat.post() catch {};
    g_beat.post() catch {};
    g_beat.post() catch {};
    sysclock.sleepFor(200) catch {};

    // The final dump of num.txt.
    {
        g_file_mtx.lock() catch {};
        const got = sdReadAll(&g_read_buf);
        g_file_mtx.unlock() catch {};
        if (got) |len| {
            console("\n---- num.txt on SD ({d} bytes, final dump) ----\n", .{len});
            var off: usize = 0;
            while (off < len) : (off += 128) board.uart.puts(g_read_buf[off..@min(len, off + 128)]);
            console("---- end num.txt ----\n", .{});
        } else {
            _ = g_read_fail.fetchAdd(1, .monotonic);
            console("[main] final num.txt read FAILED\n", .{});
        }
    }

    const ok = g_text_written.load(.monotonic) >= text_lines and g_calc_written.load(.monotonic) >= compute_lines and
        g_text_fail.load(.monotonic) == 0 and g_calc_fail.load(.monotonic) == 0 and
        g_read_fail.load(.monotonic) == 0 and g_led_fail.load(.monotonic) == 0;
    console("num.txt lines by core: c0={d} c1={d} c2={d} c3={d}\n", .{
        g_core_lines[0].load(.monotonic), g_core_lines[1].load(.monotonic),
        g_core_lines[2].load(.monotonic), g_core_lines[3].load(.monotonic),
    });
    console("run {d} ms, text={d} calc={d}\n", .{ run_ms, g_text_written.load(.monotonic), g_calc_written.load(.monotonic) });
    board.uart.puts(if (ok) "\nRESULT: PASS\n" else "\nRESULT: FAIL\n");
    if (ok) board.hw_result.ok() else board.hw_result.fail();
}
