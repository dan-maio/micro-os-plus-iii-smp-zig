//! smp-test4 (Pico / RP2040) -- Phase 4+: kernel objects under dual-core
//! contention.
//!
//! The Zig port of test/pico/smp-test4/main.cpp, line for line.
//!
//! A "controller" thread (core 0) runs seven sub-tests sequentially; a
//! "worker" thread (core 1) participates in the cross-core ones. Each
//! sub-test is a strict round-trip through the object under test:
//!
//!   S1 event flags     -- raise/wait ping-pong across cores.
//!   S2 message queue   -- send/receive ping-pong across cores (two queues),
//!                         payload verify.
//!   S3 memory pool     -- alloc on core 0, free on core 1, count invariant.
//!   S4 condvar         -- canonical mutex+predicate pattern across cores.
//!   S5 mutex (PI)      -- the worker blocks in lock() while core 0 holds the
//!                         mutex, then acquires it and acks.
//!   S6 timeouts        -- semaphore timedWait times out after ~the requested
//!                         duration; a post before the wait returns at once.
//!   S7 timer           -- periodic 10 ms timer on core 0, ~100 firings in
//!                         1000 ms.
//!
//! Output on UART0 @115200; the LED toggles once per controller round. The
//! result lines are also written to semihosting (the runner's log).

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

fn timerUs32() u32 {
    return @truncate(hal.time.get_time_since_boot().to_us());
}

// ---- Test parameters -------------------------------------------------------

const ev_r: u32 = 200;
const mq_r: u32 = 200;
const mp_r: u32 = 200;
const cv_r: u32 = 200;
const pi_r: u32 = 100;
const tmo_r: u32 = 30;
const timeout_ticks: u32 = 10; // 10 ms
const tmr_period_ticks: u32 = 10; // 10 ms
const tmr_run_ticks: u32 = 1000; // ~100 firings

const Msg = extern struct {
    seq: u32,
    tag: u32,
};

// ---- Shared objects --------------------------------------------------------

var ef: rtos.EventFlags = .{ .name = "ef" };
var ef2: rtos.EventFlags = .{ .name = "ef2" };
// S2 uses two queues (controller->worker / worker->controller): a single
// shared queue lets the controller's own send/receive pair self-serve its
// message before the worker receive sees it.
var mq_c2w: rtos.MessageQueueTyped(Msg).Static(16) = .{};
var mq_w2c: rtos.MessageQueueTyped(Msg).Static(16) = .{};
var mp: rtos.MemoryPoolTyped(Msg).Static(8) = .{};
var m_cv: rtos.Mutex = .{ .name = "cv_m" };
var cv: rtos.ConditionVariable = .{ .name = "cv" };
var m_pi: rtos.Mutex = .{ .name = "pi" };
var sem_armed: rtos.Semaphore = .counting("armed", 4, 0);
var sem_go: rtos.Semaphore = .counting("go", 8, 0);
var sem_ack: rtos.Semaphore = .counting("ack", 8, 0);
var sem_t: rtos.Semaphore = .counting("tmo", 8, 0);

// Controller <-> worker coordination (cross-core).
var g_stage: u32 = 0; // 0 = idle, 1..5 = worker stages
var g_wdone: u32 = 0; // worker finished stage N
var g_pred: bool = false; // condvar predicate
var g_mp_block: ?*Msg = null; // pool block handed to the worker
var g_werr: u32 = 0; // worker-side errors

// Periodic timer callback (runs in the tick context on core 0).
var g_tmr_cnt: u32 = 0;

fn tmrCb(_: ?*anyopaque) void {
    g_tmr_cnt += 1;
}

fn load(p: anytype) @TypeOf(p.*) {
    return @atomicLoad(@TypeOf(p.*), p, .acquire);
}

fn store(p: anytype, v: @TypeOf(p.*)) void {
    @atomicStore(@TypeOf(p.*), p, v, .release);
}

// ---- Console (controller thread only) --------------------------------------

/// To the UART and, for the runner's log, to semihosting.
fn out(bytes: []const u8) void {
    uart.write(bytes);
    semihosting.write(bytes);
}

var led_on = false;

fn ledToggle() void {
    led_on = !led_on;
    board.led.set(led_on);
}

// ---- Core-1 worker -----------------------------------------------------------
// Each stage runs exactly N rounds (the same N the controller runs), then
// signals g_wdone and SPINS until the controller advances g_stage, so it never
// re-enters a finished stage.

fn worker(_: ?*anyopaque) ?*anyopaque {
    this_thread.thread().setCpuAffinity(1 << 1);
    if (uos.port.scheduler.cpuId() != 1) this_thread.yield();
    while (true) {
        const st = load(&g_stage);
        var r: u32 = 0;
        switch (st) {
            1 => { // S1 event flags ping-pong
                sem_armed.post() catch {};
                store(&g_werr, 0);
                while (load(&g_stage) == 1 and r < ev_r) : (r += 1) {
                    if (ef.wait(1 << 0, .all_clear)) |_| {} else |_| g_werr += 1;
                    _ = ef.raise(1 << 1) catch {};
                }
                store(&g_wdone, st);
                while (load(&g_stage) == 1) {}
            },
            2 => { // S2 message queue ping-pong (two queues)
                sem_armed.post() catch {};
                store(&g_werr, 0);
                while (load(&g_stage) == 2 and r < mq_r) : (r += 1) {
                    var m: Msg = .{ .seq = 0, .tag = 0 };
                    if (mq_c2w.typed.receive()) |got| {
                        m = got;
                        if (m.tag != 0xCAFE) g_werr += 1 else m.tag = 0xBEEF;
                    } else |_| g_werr += 1;
                    // Always echo back, so the round-trip cannot break.
                    mq_w2c.typed.send(m, 0) catch {
                        g_werr += 1;
                    };
                }
                store(&g_wdone, st);
                while (load(&g_stage) == 2) {}
            },
            3 => { // S3 memory pool: free a block allocated on core 0
                sem_armed.post() catch {};
                store(&g_werr, 0);
                while (load(&g_stage) == 3 and r < mp_r) : (r += 1) {
                    sem_go.wait() catch {};
                    const b = load(&g_mp_block).?;
                    if (b.tag != 0x0DDD) g_werr += 1;
                    mp.typed.free(b) catch {
                        g_werr += 1;
                    };
                    sem_ack.post() catch {};
                }
                store(&g_wdone, st);
                while (load(&g_stage) == 3) {}
            },
            4 => { // S4 condition variable (canonical mutex+predicate)
                sem_armed.post() catch {};
                store(&g_werr, 0);
                while (load(&g_stage) == 4 and r < cv_r) : (r += 1) {
                    m_cv.lock() catch {};
                    while (!load(&g_pred)) cv.wait(&m_cv) catch {};
                    store(&g_pred, false);
                    m_cv.unlock() catch {};
                    sem_ack.post() catch {};
                }
                store(&g_wdone, st);
                while (load(&g_stage) == 4) {}
            },
            5 => { // S5 mutex: block across cores while core 0 holds it
                sem_armed.post() catch {};
                store(&g_werr, 0);
                while (load(&g_stage) == 5 and r < pi_r) : (r += 1) {
                    sem_go.wait() catch {};
                    m_pi.lock() catch {}; // blocks until core 0 releases (PI path)
                    m_pi.unlock() catch {};
                    sem_ack.post() catch {};
                }
                store(&g_wdone, st);
                while (load(&g_stage) == 5) {}
            },
            else => { // idle while the controller runs S6/S7
                sysclock.sleepFor(1) catch {};
            },
        }
    }
}

// ---- Core-0 controller -------------------------------------------------------

fn controller(_: ?*anyopaque) ?*anyopaque {
    this_thread.thread().setCpuAffinity(1 << 0);
    if (uos.port.scheduler.cpuId() != 0) this_thread.yield();

    var all_pass = true;
    var err: u32 = 0;
    var b: [160]u8 = undefined;

    // ---- S1: event flags ---------------------------------------------------
    var ok = true;
    store(&g_stage, 1);
    sem_armed.wait() catch {};
    for (0..ev_r) |_| {
        _ = ef.raise(1 << 0) catch {};
        if (ef.wait(1 << 1, .all_clear)) |_| {} else |_| ok = false;
        ledToggle();
    }
    while (load(&g_wdone) != 1) {}
    err = load(&g_werr);
    all_pass = all_pass and ok and err == 0;
    out(std.fmt.bufPrint(&b, "S1 event_flags   : {s} ({d} rounds, worker err {d})\n", .{
        if (ok and err == 0) "PASS" else "FAIL", ev_r, err,
    }) catch "");

    // ---- S2: message queue (two queues, no self-serve) --------------------
    ok = true;
    store(&g_stage, 2);
    sem_armed.wait() catch {};
    for (0..mq_r) |ri| {
        const r: u32 = @intCast(ri);
        mq_c2w.typed.send(.{ .seq = r, .tag = 0xCAFE }, 0) catch {
            ok = false;
        };
        if (mq_w2c.typed.receive()) |back| {
            if (back.seq != r or back.tag != 0xBEEF) ok = false;
        } else |_| ok = false;
        ledToggle();
    }
    while (load(&g_wdone) != 2) {}
    err = load(&g_werr);
    all_pass = all_pass and ok and err == 0;
    out(std.fmt.bufPrint(&b, "S2 message_queue : {s} ({d} rounds, worker err {d})\n", .{
        if (ok and err == 0) "PASS" else "FAIL", mq_r, err,
    }) catch "");

    // ---- S3: memory pool (alloc core 0, free core 1) -----------------------
    ok = true;
    store(&g_stage, 3);
    sem_armed.wait() catch {};
    for (0..mp_r) |ri| {
        const blk = mp.typed.alloc() catch {
            ok = false;
            continue;
        };
        blk.* = .{ .seq = @intCast(ri), .tag = 0x0DDD };
        store(&g_mp_block, blk);
        sem_go.post() catch {};
        sem_ack.wait() catch {};
        // countUsed() = ALLOCATED blocks; the worker freed it -> must be 0.
        if (mp.typed.pool.countUsed() != 0) ok = false;
        ledToggle();
    }
    while (load(&g_wdone) != 3) {}
    err = load(&g_werr);
    all_pass = all_pass and ok and err == 0;
    out(std.fmt.bufPrint(&b, "S3 memory_pool   : {s} ({d} rounds, worker err {d})\n", .{
        if (ok and err == 0) "PASS" else "FAIL", mp_r, err,
    }) catch "");

    // ---- S4: condition variable --------------------------------------------
    ok = true;
    store(&g_stage, 4);
    sem_armed.wait() catch {};
    for (0..cv_r) |_| {
        m_cv.lock() catch {};
        store(&g_pred, true);
        cv.signal() catch {};
        m_cv.unlock() catch {};
        sem_ack.wait() catch {
            ok = false;
        };
        ledToggle();
    }
    while (load(&g_wdone) != 4) {}
    err = load(&g_werr);
    all_pass = all_pass and ok and err == 0;
    out(std.fmt.bufPrint(&b, "S4 condvar       : {s} ({d} rounds, worker err {d})\n", .{
        if (ok and err == 0) "PASS" else "FAIL", cv_r, err,
    }) catch "");

    // ---- S5: mutex (cross-core blocking + priority inheritance) -----------
    ok = true;
    store(&g_stage, 5);
    sem_armed.wait() catch {};
    for (0..pi_r) |_| {
        m_pi.lock() catch {};
        sem_go.post() catch {}; // the worker now blocks in lock()...
        sysclock.sleepFor(5) catch {}; // ...while core 0 holds the mutex
        m_pi.unlock() catch {};
        sem_ack.wait() catch {
            ok = false;
        };
        ledToggle();
    }
    while (load(&g_wdone) != 5) {}
    err = load(&g_werr);
    all_pass = all_pass and ok and err == 0;
    out(std.fmt.bufPrint(&b, "S5 mutex (PI)    : {s} ({d} rounds, worker err {d})\n", .{
        if (ok and err == 0) "PASS" else "FAIL", pi_r, err,
    }) catch "");

    // ---- S6: timeouts (controller only) -------------------------------------
    store(&g_stage, 6); // the worker idles
    var tmo_ok: u32 = 0;
    var tmo_bad: u32 = 0;
    var tmo_sum: u32 = 0;
    for (0..tmo_r) |_| {
        const t0 = timerUs32();
        const res = sem_t.timedWait(timeout_ticks);
        const dt = timerUs32() -% t0;
        const timed_out = if (res) |_| false else |e| e == error.TimedOut;
        if (timed_out and dt >= 9 * 1000 and dt <= 30 * 1000) {
            tmo_ok += 1;
            tmo_sum += dt;
        } else {
            tmo_bad += 1;
        }
        ledToggle();
    }
    // Wake-before-timeout control: post then wait must return ok, fast.
    var fast_bad: u32 = 0;
    for (0..20) |_| {
        const t0 = timerUs32();
        sem_t.post() catch {};
        const res = sem_t.timedWait(100);
        const dt = timerUs32() -% t0;
        if (std.meta.isError(res) or dt > 5000) fast_bad += 1;
        ledToggle();
    }
    const tmo_pass = tmo_bad == 0 and fast_bad == 0;
    all_pass = all_pass and tmo_pass;
    out(std.fmt.bufPrint(&b, "S6 timeouts      : {s} ({d} ETIMEDOUT, bad {d}; fast-wake bad {d}; dt avg {d} us)\n", .{
        if (tmo_pass) "PASS" else "FAIL", tmo_ok, tmo_bad, fast_bad, if (tmo_ok != 0) tmo_sum / tmo_ok else 0,
    }) catch "");

    // ---- S7: periodic timer (controller only) -------------------------------
    store(&g_stage, 7); // the worker idles
    g_tmr_cnt = 0;
    {
        var t: rtos.Timer = .init("t", tmrCb, null, .periodic);
        t.start(tmr_period_ticks) catch {};
        sysclock.sleepFor(tmr_run_ticks) catch {};
        t.stop() catch {};
        t.deinit();
    }
    const cnt = load(&g_tmr_cnt);
    const tmr_pass = cnt >= 90 and cnt <= 115;
    all_pass = all_pass and tmr_pass;
    out(std.fmt.bufPrint(&b, "S7 timer         : {s} (count {d} in ~{d} ms, expect ~100)\n", .{
        if (tmr_pass) "PASS" else "FAIL", cnt, tmr_run_ticks,
    }) catch "");

    // ---- Summary ------------------------------------------------------------
    uart.write("---------------------------------------------\n");
    uart.write(if (all_pass) "RESULT: PASS (kernel objects under dual-core contention)\n" else "RESULT: FAIL\n");
    // The verdict on the debug channel and the semihosting exit
    // (hw_result::ok()/fail() in C++).
    semihosting.write(if (all_pass) "RESULT: PASS\n" else "RESULT: FAIL\n");
    uos.rtos.terminate(if (all_pass) 0 else 1);
}

var ctl_stack: [1024]uos.port.StackElement align(8) = undefined;
var wrk_stack: [1024]uos.port.StackElement align(8) = undefined;
var controller_th: rtos.Thread = undefined;
var worker_th: rtos.Thread = undefined;

fn osMain() u8 {
    this_thread.thread().setCpuAffinity(1 << 0);

    board.led.init();

    uart.write("\n");
    uart.write("=============================================\n");
    uart.write("  Pico / RP2040 - micro-os-plus-iii\n");
    uart.write("  smp-test4 : kernel objects, dual-core\n");
    uart.write("=============================================\n");

    mq_c2w.init("c2w", .{}) catch @panic("c2w");
    mq_w2c.init("w2c", .{}) catch @panic("w2c");
    mp.init("mp", .{}) catch @panic("mp");

    uart.write("core 0: idle1 installed; creating controller/worker...\n");

    controller_th.init("controller", controller, null, .{ .stack = &ctl_stack }, null) catch
        @panic("cannot create the controller");
    controller_th.setCpuAffinity(1 << 0);
    worker_th.init("worker", worker, null, .{ .stack = &wrk_stack }, null) catch
        @panic("cannot create the worker");
    worker_th.setCpuAffinity(1 << 1);

    uart.write("core 0: launching core 1 (bootrom FIFO handshake)...\n");
    uos.port.launchCore1();
    uart.write("core 0: core 1 launched; SMP running.\n");

    while (true) sysclock.sleepFor(10000) catch {};
}
