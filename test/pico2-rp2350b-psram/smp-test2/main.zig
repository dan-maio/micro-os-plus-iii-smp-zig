//! smp-test2 (Pico 2 / RP2350B) -- Phase 3: dual-core SMP RTOS.
//!
//! The Zig port of test/pico2-rp2350b-psram/smp-test2/main.cpp, line for line. The
//! kernel runs its SMP variant on BOTH Cortex-M33 cores:
//!   - per-core PendSV context switch + per-core SysTick (core 0 ticks the
//!     RTOS clock, core 1 only reschedules);
//!   - affinity scheduler (worker0 pinned to core 0, worker1 to core 1);
//!   - kernel spinlock (SIO hardware spinlock 0) protecting the shared data;
//!   - core 1 launched from here, through the bootrom FIFO.
//!
//! Proves:
//!   - both cores running the scheduler (each worker prints its SIO_CPUID);
//!   - cross-core shared state (global counter under a mutex);
//!   - system clock (1 ms tick, advanced by core 0);
//!   - LED heartbeat on core 0.
//!
//! Output on UART0 @115200.
//!
//! One addition to the C++ test: each worker counts the beats it ran on a
//! core other than its own, and the verdict requires none (the C++ verdict
//! only counts beats). The core check is also written to semihosting.
//!
//! The core-1 idle thread ("idle1", WFI + yield, priority idle) is created
//! and registered by the kernel at start-up, so this test does not create
//! one as the C++ test does; the rest is the same.

const std = @import("std");
const microzig = @import("microzig");
const uos = @import("uos");
const board = @import("uos_board");

const rtos = uos.rtos;
const sysclock = rtos.sysclock;
const this_thread = rtos.this_thread;
const uart = board.uart;
const semihosting = uos.port.semihosting;

pub const microzig_options = uos.port.microzig_options;

/// The C++ os-app-config.h of the pico2 board, with OS_USE_SMP_SCHEDULER and
/// OS_NCPU = 2 (critical sections are PRIMASK + kernel lock under SMP).
pub const uos_options: uos.Options = .{
    .ncpu = 2,
    .smp = true,
    .systick_frequency_hz = 1000,
    .critical_section_interrupt_priority = 5,
    .main_stack_size_bytes = 8192,
    .idle_stack_size_bytes = 4096,
    .default_stack_size_bytes = 4096,
    .dynamic_memory_size_bytes = 96 * 1024,
};

/// Core 1 is launched by `osMain()`, as in C++.
pub const uos_port_options: uos.port.Options = .{ .launch_core1_at_start = false };

comptime {
    microzig.export_startup();
}

pub fn main() void {
    rtos.run(osMain);
}

// Bounded run: each worker does iters beats (~iters * 500 ms), then the main
// thread reports the verdict.
const iters = 20;

var g_global: u32 = 0;
var g_done: u32 = 0;
var g_mutex: rtos.Mutex = .{ .name = "g" };
var g_beats: rtos.Semaphore = .counting("beats", 8, 0);

var worker_stacks: [2][1024]uos.port.StackElement align(8) = undefined;
var led_stack: [1024]uos.port.StackElement align(8) = undefined;

const Ctx = struct {
    id: u32,
    local: u32,
    /// Beats run on another core than `id` (the added check).
    wrong_core: u32 = 0,
};
var worker_ctx: [2]Ctx = undefined;

var workers: [2]rtos.Thread = undefined;
var led_th: rtos.Thread = undefined;

fn cpuId() u32 {
    return uos.port.scheduler.cpuId();
}

fn line(role: []const u8, id: u32, local: u32, global: u32) void {
    var b: [96]u8 = undefined;
    const s = std.fmt.bufPrint(&b, "[{d:>8} ms] {s:<6} #{d} core={d} local={d:<4} global={d}\n", .{
        sysclock.now(), role, id, cpuId(), local, global,
    }) catch return;
    g_mutex.lock() catch {};
    uart.write(s);
    g_mutex.unlock() catch {};
}

fn worker(arg: ?*anyopaque) ?*anyopaque {
    const c: *Ctx = @ptrCast(@alignCast(arg.?));
    // Pin this thread to its core (also set in osMain). A freshly created
    // thread has default all-core affinity and could briefly be picked by
    // the wrong core before osMain sets it; pinning here and yielding hands
    // it to the right core before any work is done.
    this_thread.thread().setCpuAffinity(@as(u32, 1) << @intCast(c.id));
    if (cpuId() != c.id) this_thread.yield();

    for (0..iters) |_| {
        if (cpuId() != c.id) c.wrong_core += 1;
        c.local += 1;
        g_mutex.lock() catch {};
        g_global += 1;
        const g = g_global;
        g_mutex.unlock() catch {};
        line("worker", c.id, c.local, g);
        g_beats.post() catch {}; // signal the LED thread
        sysclock.sleepFor(500) catch {};
    }
    _ = @atomicRmw(u32, &g_done, .Add, 1, .release);
    return null;
}

fn ledThread(_: ?*anyopaque) ?*anyopaque {
    var on = false;
    while (true) {
        g_beats.wait() catch {}; // one blink per worker beat
        on = !on;
        board.led.set(on);
    }
}

fn osMain() u8 {
    // Pin the main thread (which launches core 1) to core 0.
    this_thread.thread().setCpuAffinity(1 << 0);

    board.led.init();

    uart.write("\n");
    uart.write("=============================================\n");
    uart.write("  Pico 2 / RP2350B - micro-os-plus-iii\n");
    uart.write("  smp-test2 : dual-core SMP RTOS\n");
    uart.write("=============================================\n");

    uart.write("core 0: idle1 installed; creating worker/LED threads...\n");

    const names = [2][:0]const u8{ "wrk0", "wrk1" };
    for (0..2) |i| {
        worker_ctx[i] = .{ .id = @intCast(i), .local = 0 };
        workers[i].init(names[i], worker, &worker_ctx[i], .{ .stack = &worker_stacks[i] }, null) catch
            @panic("cannot create a worker");
        // Pin worker 0 to core 0 and worker 1 to core 1.
        workers[i].setCpuAffinity(@as(u32, 1) << @intCast(i));
    }

    led_th.init("led", ledThread, null, .{ .stack = &led_stack }, null) catch
        @panic("cannot create the led thread");
    led_th.setCpuAffinity(1 << 0);

    uart.write("core 0: launching core 1 (bootrom FIFO handshake)...\n");
    // The core-0 FIFO IRQ stays off during the launch (the FIFO carries the
    // bootrom handshake words); launchCore1() enables it afterwards.
    uos.port.launchCore1();
    uart.write("core 0: core 1 launched; SMP running.\n");

    // Wait for both bounded workers to finish (or time out).
    var i: u32 = 0;
    while (@atomicLoad(u32, &g_done, .acquire) < 2 and i < 200) : (i += 1) {
        sysclock.sleepFor(100) catch {};
    }

    const done = @atomicLoad(u32, &g_done, .acquire);
    const cores_ok = worker_ctx[0].wrong_core == 0 and worker_ctx[1].wrong_core == 0;
    const ok = done >= 2 and g_global >= 2 * iters and
        worker_ctx[0].local >= iters and worker_ctx[1].local >= iters and cores_ok;
    var b: [96]u8 = undefined;
    const core_line = std.fmt.bufPrint(&b, "\ncore check: wrk0 on core 0 {d}/{d}, wrk1 on core 1 {d}/{d}\n", .{
        worker_ctx[0].local - worker_ctx[0].wrong_core, worker_ctx[0].local,
        worker_ctx[1].local - worker_ctx[1].wrong_core, worker_ctx[1].local,
    }) catch "";
    uart.write(core_line);
    semihosting.write(core_line);
    uart.write(std.fmt.bufPrint(&b, "\nRESULT: {s}  (global={d} wrk0={d} wrk1={d} done={d})\n", .{
        if (ok) "PASS" else "FAIL", g_global, worker_ctx[0].local, worker_ctx[1].local, done,
    }) catch "");

    // The verdict on the debug channel, then the semihosting exit that
    // carries it (hw_result::ok()/fail() in C++).
    semihosting.write(if (ok) "RESULT: PASS\n" else "RESULT: FAIL\n");
    uos.rtos.terminate(if (ok) 0 else 1);
}
