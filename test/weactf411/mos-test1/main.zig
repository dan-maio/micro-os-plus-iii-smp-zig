//! mos-test1 (WeAct F411CE) -- single-CPU acceptance test.
//!
//! The Zig port of test/weactf411/mos-test1/main.cpp, line for line (the
//! C++ file is the Nucleo-F411RE's, banner included, and so is this one). One
//! producer/consumer application that exercises every core RTOS mechanism
//! at once:
//!
//!   - plain mutex          : protects the shared global counter
//!   - recursive mutex      : serialises the console; taken nested (banner ->
//!                            consoleLine) to prove recursive ownership
//!   - counting semaphores  : the classic empty/full bounded-buffer pair
//!   - system clock         : sysclock.sleepFor() pacing + sysclock.now()
//!                            timestamps (1 tick == 1 ms at 1000 Hz SysTick)
//!   - scheduler / switch   : 3 producers + 3 consumers + 2 down-counting
//!                            consumers (local starts at 10000) + 1 LED thread
//!
//! Output channels, as in C++:
//!   - USART1 @ 115200 8N1 (PA9/PA10): every worker prints, twice a
//!     second, its role, thread number, its own local counter, and the
//!     shared global counter; the banner and the RESULT line.
//!   - ARM semihosting: the LED thread prints "led on"/"led off"; the
//!     verdict line and the end of the run (exit(), SYS_EXIT).
//!   - LED (PC13): blinks at a 1 s interval.
//!
//! After 5 s the workers are stopped and joined; PASS when the shared
//! counter moved.
//!
//! Differences from C++: the kernel's startup banner and its exit trace
//! (`exit(0)`, `_Exit()`, the stack report) go to the trace channel, USART1
//! and semihosting (the C++ build has no startup banner and its trace is
//! semihosting only); the board's clocks, LED and USART1 are set up by the port
//! before main() (C++: led::init() and uart::init() in os_main()); the
//! threads are static objects (C++: `new thread`); the run ends with
//! main()'s return value through exit() (C++: hw_result::ok(), which is
//! std::exit()).

const std = @import("std");
const uos = @import("uos");
const t = @import("uos_test");
const board = @import("uos_board");
const rtos = uos.rtos;
const sysclock = rtos.sysclock;

pub const microzig_options = t.microzig_options;
pub const panic = t.panic;
pub const std_options = t.std_options;
pub const uos_options = t.options(.{});

comptime {
    t.exportStartup();
}

pub fn main() void {
    // No heartbeat timer (t.run): the LED is the LED thread's.
    rtos.run(osMain);
}

// ----------------------------------------------------------------------------
// Shared resources.

const BUFFER_SIZE = 8;
const PRODUCERS = 3;
const CONSUMERS = 3;
const CONSUMERS_DEC = 2; // down-counting consumers
const DEC_START: u32 = 10000; // their local counter starts here

const WORKER_PERIOD_MS = 500; // "twice a second"
const LED_PERIOD_MS = 1000; // 1 s blink interval

// Bounded buffer, guarded by g_buffer_mutex + the two counting semaphores.
const RingBuffer = struct {
    data: [BUFFER_SIZE]i32 = @splat(0),
    head: usize = 0,
    tail: usize = 0,
};
var g_buffer: RingBuffer = .{};

var g_buffer_mutex: rtos.Mutex = .{ .name = "buffer" }; // plain
var g_sem_free: rtos.Semaphore = .counting("free", BUFFER_SIZE, BUFFER_SIZE);
var g_sem_used: rtos.Semaphore = .counting("used", BUFFER_SIZE, 0);

// Shared counter incremented by every thread, under a plain mutex.
var g_global_counter: u32 = 0;

// Set by osMain() at the end of the run: every worker leaves its loop at the
// next check, so the run can join them before the end.
var g_stop: bool = false;
var g_count_mutex: rtos.Mutex = .{ .name = "count" };

// Console serialisation, using a RECURSIVE mutex so a holder may re-enter
// (banner() locks it and calls consoleLine(), which locks it again).
var g_console_mutex: rtos.Mutex = .initWith("console", .recursive);

// Per-thread context.
const WorkerCtx = struct {
    role: []const u8,
    id: u32,
    local_counter: u32,
};

fn stopped() bool {
    return @atomicLoad(bool, &g_stop, .acquire);
}

// ----- helpers -------------------------------------------------------------

fn bumpGlobal() u32 {
    g_count_mutex.lock() catch {};
    g_global_counter += 1;
    const v = g_global_counter;
    g_count_mutex.unlock() catch {};
    return v;
}

// Emit one console line atomically. Locks the recursive console mutex.
fn consoleLine(text: []const u8) void {
    g_console_mutex.lock() catch {};
    board.uartWrite(text);
    g_console_mutex.unlock() catch {};
}

fn consoleWorker(ctx: *const WorkerCtx, global_snapshot: u32) void {
    var line: [96]u8 = undefined;
    const s = std.fmt.bufPrint(&line, "[{d:>8} ms] {s:<8} #{d}  local={d:<5}  global={d}\n", .{
        sysclock.now(), ctx.role, ctx.id, ctx.local_counter, global_snapshot,
    }) catch return;
    g_console_mutex.lock() catch {};
    board.uartWrite(s);
    g_console_mutex.unlock() catch {};
}

// Multi-line banner printed while HOLDING the recursive mutex, then calling
// consoleLine() (which locks it again) -> proves recursive re-entry works.
fn banner() void {
    g_console_mutex.lock() catch {}; // depth 1
    consoleLine("=============================================\n"); // depth 2
    consoleLine("  Nucleo-F411RE  micro-os-plus-iii  mos-test1\n");
    consoleLine("  producers/consumers + mutex/recursive/sem\n");
    consoleLine("=============================================\n");
    g_console_mutex.unlock() catch {}; // back to depth 0
}

// ----- threads -------------------------------------------------------------

fn producerFunc(arg: ?*anyopaque) ?*anyopaque {
    const ctx: *WorkerCtx = @ptrCast(@alignCast(arg.?));
    var value: i32 = @intCast(ctx.id * 1000);
    while (!stopped()) {
        g_sem_free.wait() catch {}; // wait for a free slot
        if (stopped()) break;

        g_buffer_mutex.lock() catch {};
        g_buffer.data[g_buffer.head] = value;
        g_buffer.head = (g_buffer.head + 1) % BUFFER_SIZE;
        g_buffer_mutex.unlock() catch {};

        g_sem_used.post() catch {}; // signal an item is available

        ctx.local_counter += 1;
        const g = bumpGlobal();
        consoleWorker(ctx, g);

        value += 1;
        sysclock.sleepFor(WORKER_PERIOD_MS) catch {};
    }
    return null;
}

fn consumerFunc(arg: ?*anyopaque) ?*anyopaque {
    const ctx: *WorkerCtx = @ptrCast(@alignCast(arg.?));
    while (!stopped()) {
        g_sem_used.wait() catch {}; // wait for an item
        if (stopped()) break;

        g_buffer_mutex.lock() catch {};
        _ = g_buffer.data[g_buffer.tail];
        g_buffer.tail = (g_buffer.tail + 1) % BUFFER_SIZE;
        g_buffer_mutex.unlock() catch {};

        g_sem_free.post() catch {}; // release the slot

        ctx.local_counter += 1;
        const g = bumpGlobal();
        consoleWorker(ctx, g);

        sysclock.sleepFor(WORKER_PERIOD_MS) catch {};
    }
    return null;
}

// Same bounded-buffer consumer, but its per-thread local counter counts DOWN
// from DEC_START (10000) instead of up. Proves per-thread state is
// independent and that extra consumers share the semaphore/buffer safely.
fn consumerDecFunc(arg: ?*anyopaque) ?*anyopaque {
    const ctx: *WorkerCtx = @ptrCast(@alignCast(arg.?));
    while (!stopped()) {
        g_sem_used.wait() catch {}; // wait for an item
        if (stopped()) break;

        g_buffer_mutex.lock() catch {};
        _ = g_buffer.data[g_buffer.tail];
        g_buffer.tail = (g_buffer.tail + 1) % BUFFER_SIZE;
        g_buffer_mutex.unlock() catch {};

        g_sem_free.post() catch {}; // release the slot

        ctx.local_counter -%= 1; // count DOWN from DEC_START
        const g = bumpGlobal();
        consoleWorker(ctx, g);

        sysclock.sleepFor(WORKER_PERIOD_MS) catch {};
    }
    return null;
}

fn ledFunc(arg: ?*anyopaque) ?*anyopaque {
    const ctx: *WorkerCtx = @ptrCast(@alignCast(arg.?));
    var state = false;
    while (!stopped()) {
        state = !state;
        if (state) {
            board.led.set(true);
            uos.port.semihosting.write("led on\n"); // semihosting console
        } else {
            board.led.set(false);
            uos.port.semihosting.write("led off\n");
        }
        ctx.local_counter += 1;
        _ = bumpGlobal();
        sysclock.sleepFor(LED_PERIOD_MS) catch {};
    }
    return null;
}

// ----- storage -------------------------------------------------------------

const StackElement = uos.port.StackElement;

var producer_stacks: [PRODUCERS][1024]StackElement align(8) = undefined;
var consumer_stacks: [CONSUMERS][1024]StackElement align(8) = undefined;
var consumer_dec_stacks: [CONSUMERS_DEC][1024]StackElement align(8) = undefined;
var led_stack: [1024]StackElement align(8) = undefined;

var producer_ctx: [PRODUCERS]WorkerCtx = undefined;
var consumer_ctx: [CONSUMERS]WorkerCtx = undefined;
var consumer_dec_ctx: [CONSUMERS_DEC]WorkerCtx = undefined;
var led_ctx: WorkerCtx = .{ .role = "led", .id = 0, .local_counter = 0 };

var producers: [PRODUCERS]rtos.Thread = undefined;
var consumers: [CONSUMERS]rtos.Thread = undefined;
var consumers_dec: [CONSUMERS_DEC]rtos.Thread = undefined;
var led_thread: rtos.Thread = undefined;

const producer_names = [PRODUCERS][:0]const u8{ "prod0", "prod1", "prod2" };
const consumer_names = [CONSUMERS][:0]const u8{ "cons0", "cons1", "cons2" };
const consumer_dec_names = [CONSUMERS_DEC][:0]const u8{ "consd0", "consd1" };

// ----------------------------------------------------------------------------

fn osMain() u8 {
    banner();

    for (&producers, &producer_stacks, &producer_ctx, 0..) |*th, *stack, *ctx, i| {
        ctx.* = .{ .role = "producer", .id = @intCast(i), .local_counter = 0 };
        th.init(producer_names[i], producerFunc, ctx, .{ .stack = stack }, null) catch
            @panic("cannot create a producer");
    }

    for (&consumers, &consumer_stacks, &consumer_ctx, 0..) |*th, *stack, *ctx, i| {
        ctx.* = .{ .role = "consumer", .id = @intCast(i), .local_counter = 0 };
        th.init(consumer_names[i], consumerFunc, ctx, .{ .stack = stack }, null) catch
            @panic("cannot create a consumer");
    }

    for (&consumers_dec, &consumer_dec_stacks, &consumer_dec_ctx, 0..) |*th, *stack, *ctx, i| {
        ctx.* = .{ .role = "cons-dec", .id = @intCast(i), .local_counter = DEC_START };
        th.init(consumer_dec_names[i], consumerDecFunc, ctx, .{ .stack = stack }, null) catch
            @panic("cannot create a down-counting consumer");
    }

    led_thread.init("led", ledFunc, &led_ctx, .{ .stack = &led_stack }, null) catch
        @panic("cannot create the led thread");

    // Let the workers run for a bounded time, then check the shared counter
    // moved and end the run with the verdict.
    const check_ms = 5000;
    sysclock.sleepFor(check_ms) catch {};

    // Stop the workers before the verdict ends the run. Each worker leaves
    // its loop at the next g_stop check; one post per possible waiter wakes
    // any blocked in g_sem_free/g_sem_used.wait(). A post that fails with
    // the count at its maximum loses nothing: then no thread can be waiting.
    @atomicStore(bool, &g_stop, true, .release);
    for (0..PRODUCERS) |_| g_sem_free.post() catch {};
    for (0..CONSUMERS + CONSUMERS_DEC) |_| g_sem_used.post() catch {};
    for (&producers) |*th| _ = th.join() catch {};
    for (&consumers) |*th| _ = th.join() catch {};
    for (&consumers_dec) |*th| _ = th.join() catch {};
    _ = led_thread.join() catch {};

    const ok = g_global_counter > 0;
    var rb: [80]u8 = undefined;
    consoleLine(std.fmt.bufPrint(&rb, "\nRESULT: {s}  (global={d})\n", .{
        if (ok) "PASS" else "FAIL", g_global_counter,
    }) catch "\nRESULT: ?\n");

    // As hw_result::ok() / fail(): the verdict on semihosting (what the
    // runner reads), then the end of the run (exit()).
    uos.port.semihosting.write(if (ok) "RESULT: PASS\n" else "RESULT: FAIL\n");
    return if (ok) 0 else 1;
}
