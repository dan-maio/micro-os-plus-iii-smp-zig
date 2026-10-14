//! smp-test3 (Pico 2 / RP2350) -- Phase 3+: cross-core IPI ping-pong.
//!
//! The Zig port of test/pico2/smp-test3/main.cpp, line for line.
//!
//! The SMP port's cross-core IPI channel is the SIO inter-core FIFO:
//! `uos.port.scheduler.ipi(cpu)` pushes a word; the RECEIVING core's
//! SIO_IRQ_FIFO (external IRQ 25) drains the FIFO and pends that core's
//! PendSV, so the receiver reschedules immediately.
//!
//! Difference from the C++ test, on purpose: the C++ kernel never sends an
//! IPI by itself (its resume() branch is dead code), so its phase A measured
//! tick-delivered wakes. This kernel's `Thread.resume()` sends the IPI when
//! the resumed thread may not run on the current core
//! (`uos_options.resume_ipi`, on), so:
//!
//! A "pinger" thread pinned to core 0 and a "ponger" pinned to core 1 pass a
//! semaphore ping-pong; the one-way wake latency is measured with the RP2350
//! TIMER0 64-bit microsecond counter.
//!
//!   pinger (c0): t_sent = us(); s_ping.post();  [+ ipi(1) in phase B]
//!   ponger (c1): s_ping.wait(); lat = us() - t_sent;   (core0 -> core1)
//!                t_sent = us(); s_pong.post(); [+ ipi(0) in phase B]
//!   pinger (c0): s_pong.wait(); lat = us() - t_sent;   (core1 -> core0)
//!
//!   phase A (20 rounds)  : the kernel's resume() IPI only.
//!   phase B (2000 rounds): the kernel's IPI plus an explicit one from the
//!                          poster (as in C++).
//!
//! RESULT = PASS when every one-way latency of BOTH phases is < 500 us,
//! i.e. no wake waited for a tick.
//!
//! Output on UART0 @115200; the LED toggles once per round (core 0).
//!
//! TIMER0 and its tick generator are started by MicroZig's HAL clock set-up
//! (the C++ test does it in timer_init()); the self-check below still proves
//! the counter runs.

const std = @import("std");
const microzig = @import("microzig");
const uos = @import("uos");
const board = @import("uos_board");

const hal = microzig.hal;
const rtos = uos.rtos;
const sysclock = rtos.sysclock;
const this_thread = rtos.this_thread;
const uart = board.uart;
const semihosting = uos.port.semihosting;

pub const microzig_options = uos.port.microzig_options;

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

// ---- RP2350 TIMER0: free-running 64-bit microsecond counter -------------

fn timerUs32() u32 {
    return @truncate(hal.time.get_time_since_boot().to_us());
}

inline fn dmb() void {
    asm volatile ("dmb" ::: .{ .memory = true });
}

// ---- Test parameters -----------------------------------------------------

const ph_a_rounds: u32 = 20; // kernel resume() IPI only
const ph_b_rounds: u32 = 2000; // kernel IPI + explicit IPI
const slow_us: u32 = 500; // >= this => tick-delivered
/// Unmeasured rounds before phase A: the first wakes on core 1 run the
/// switch path from cold XIP flash (~0.9 ms, measured), which is not what
/// the test is about. The C++ test did not judge phase A, so it had none.
const warmup_rounds: u32 = 5;

// ---- Cross-core handshake ------------------------------------------------

var s_ping: rtos.Semaphore = .counting("ping", 8, 0);
var s_pong: rtos.Semaphore = .counting("pong", 8, 0);
/// The ponger is running on core 1: phase A is judged now, so its first
/// round must not include the core-1 launch time.
var s_ready: rtos.Semaphore = .binary("ready", 0);

/// Sender's departure time (us), read by the receiver right after the wake.
var g_t_sent: u32 = 0;
/// The phase (0 = A, 1 = B, 2 = done, 3 = warm-up); set by the pinger only.
var g_phase: u32 = 3;
var g_round: u32 = 0; // pinger only

/// One-way latency statistics; each core accumulates only its own leg.
const Stats = struct {
    min: u32 = std.math.maxInt(u32),
    sum: u32 = 0,
    max: u32 = 0,
    cnt: u32 = 0,
    slow: u32 = 0,
};

var g_leg_c1: [2]Stats = .{ .{}, .{} }; // core0 -> core1, written by the ponger
var g_leg_c0: [2]Stats = .{ .{}, .{} }; // core1 -> core0, written by the pinger

fn acc(st: *Stats, lat: u32) void {
    if (lat < st.min) st.min = lat;
    st.sum +%= lat;
    if (lat > st.max) st.max = lat;
    st.cnt += 1;
    if (lat >= slow_us) st.slow += 1;
}

var led_on = false;

fn ledToggle() void {
    led_on = !led_on;
    board.led.set(led_on);
}

/// The results go to the UART and, for the runner's log, to semihosting.
fn out(bytes: []const u8) void {
    uart.write(bytes);
    semihosting.write(bytes);
}

fn printStats(leg: []const u8, st: *const Stats) void {
    var b: [128]u8 = undefined;
    out(std.fmt.bufPrint(&b, "  {s} one-way: min={d:<4} avg={d:<4} max={d:<4} us (slow>={d}: {d}/{d})\n", .{
        leg,                              st.min,  if (st.cnt != 0) st.sum / st.cnt else 0,
        st.max,                           slow_us, st.slow,
        st.cnt,
    }) catch "");
}

fn report() bool {
    var b: [256]u8 = undefined;
    out(std.fmt.bufPrint(&b,
        \\-------------------------------------------------
        \\cross-core IPI ping-pong : results (LED+UART, no SPI)
        \\  phase A: kernel resume() IPI       {d} rounds
        \\  phase B: kernel + explicit IPI     {d} rounds
        \\-------------------------------------------------
        \\
    , .{ ph_a_rounds, ph_b_rounds }) catch "");
    printStats("A core0->1", &g_leg_c1[0]);
    printStats("A core1->0", &g_leg_c0[0]);
    printStats("B core0->1", &g_leg_c1[1]);
    printStats("B core1->0", &g_leg_c0[1]);

    const pass = g_leg_c1[0].max < slow_us and g_leg_c0[0].max < slow_us and
        g_leg_c1[1].max < slow_us and g_leg_c0[1].max < slow_us and
        g_leg_c1[0].cnt == ph_a_rounds and g_leg_c0[0].cnt == ph_a_rounds and
        g_leg_c1[1].cnt == ph_b_rounds and g_leg_c0[1].cnt == ph_b_rounds;
    out(std.fmt.bufPrint(&b, "Explicit IPIs sent: {d} (phase B). Result: {s}\n", .{
        ph_b_rounds * 2, if (pass) "PASS (no tick-delivered wake)" else "FAIL",
    }) catch "");
    return pass;
}

// ---- core-1 ponger ---------------------------------------------------------

fn ponger(_: ?*anyopaque) ?*anyopaque {
    this_thread.thread().setCpuAffinity(1 << 1);
    if (uos.port.scheduler.cpuId() != 1) this_thread.yield();
    s_ready.post() catch {};
    while (true) {
        s_ping.wait() catch {};
        const lat = timerUs32() -% @atomicLoad(u32, &g_t_sent, .acquire);
        const ph = @atomicLoad(u32, &g_phase, .acquire);
        if (ph < 2) acc(&g_leg_c1[ph], lat);
        @atomicStore(u32, &g_t_sent, timerUs32(), .release);
        dmb();
        s_pong.post() catch {};
        if (ph == 1) uos.port.scheduler.ipi(0); // wake core 0 immediately
    }
}

// ---- core-0 pinger ---------------------------------------------------------

fn pinger(_: ?*anyopaque) ?*anyopaque {
    this_thread.thread().setCpuAffinity(1 << 0);
    if (uos.port.scheduler.cpuId() != 0) this_thread.yield();
    s_ready.wait() catch {};
    for (0..warmup_rounds) |_| {
        s_ping.post() catch {};
        s_pong.wait() catch {};
    }
    @atomicStore(u32, &g_phase, 0, .release);
    while (true) {
        const ph = @atomicLoad(u32, &g_phase, .acquire);
        @atomicStore(u32, &g_t_sent, timerUs32(), .release);
        dmb();
        s_ping.post() catch {};
        if (ph == 1) uos.port.scheduler.ipi(1); // wake core 1 immediately
        s_pong.wait() catch {};
        const lat = timerUs32() -% @atomicLoad(u32, &g_t_sent, .acquire);
        acc(&g_leg_c0[ph], lat);
        ledToggle();
        g_round += 1;
        if (ph == 0 and g_round >= ph_a_rounds) {
            @atomicStore(u32, &g_phase, 1, .release);
            g_round = 0;
        } else if (ph == 1 and g_round >= ph_b_rounds) {
            @atomicStore(u32, &g_phase, 2, .release); // stop: the ponger idles on s_ping
            const ok = report();
            uart.write(if (ok) "RESULT: PASS\n" else "RESULT: FAIL\n");
            // The verdict on the debug channel and the semihosting exit
            // (hw_result::ok()/fail() in C++).
            semihosting.write(if (ok) "RESULT: PASS\n" else "RESULT: FAIL\n");
            semihosting.exit(if (ok) 0 else 1);
        }
    }
}

var pinger_stack: [1024]uos.port.StackElement align(8) = undefined;
var ponger_stack: [1024]uos.port.StackElement align(8) = undefined;
var pinger_th: rtos.Thread = undefined;
var ponger_th: rtos.Thread = undefined;

fn osMain() u8 {
    this_thread.thread().setCpuAffinity(1 << 0);

    board.led.init();

    uart.write("\n");
    uart.write("=============================================\n");
    uart.write("  Pico 2 / RP2350 - micro-os-plus-iii\n");
    uart.write("  smp-test3 : cross-core IPI ping-pong\n");
    uart.write("=============================================\n");

    // Self-check the microsecond timer is running.
    {
        const t0 = timerUs32();
        var spin: u32 = 0;
        while (spin < 150000) : (spin += 1) std.mem.doNotOptimizeAway(&spin);
        const t1 = timerUs32();
        var b: [96]u8 = undefined;
        uart.write(std.fmt.bufPrint(&b, "timer self-check: {d} us elapsed\n", .{t1 -% t0}) catch "");
    }

    uart.write("core 0: idle1 installed; creating pinger/ponger...\n");

    pinger_th.init("pinger", pinger, null, .{ .stack = &pinger_stack }, null) catch
        @panic("cannot create the pinger");
    pinger_th.setCpuAffinity(1 << 0);
    ponger_th.init("ponger", ponger, null, .{ .stack = &ponger_stack }, null) catch
        @panic("cannot create the ponger");
    ponger_th.setCpuAffinity(1 << 1);

    uart.write("core 0: launching core 1 (bootrom FIFO handshake)...\n");
    uos.port.launchCore1();
    uart.write("core 0: core 1 launched; SMP running.\n");

    while (true) sysclock.sleepFor(10000) catch {};
}
