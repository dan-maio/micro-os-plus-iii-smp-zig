//! sc-test-ko (Pico / RP2040) -- SINGLE-CORE kernel-object test.
//!
//! The Zig port of test/pico/sc-test-ko/main.cpp, line for line. "sc" =
//! single core: the SMP scheduler is off, so the kernel runs on ONE
//! Cortex-M0+ core (core 0) with its scalar reference scheduler -- the only
//! test on this board that exercises the kernel's non-SMP branch (its SMP
//! twin is smp-test-ko).
//!
//! It exercises EVERY kernel object, each as a self-checking round-trip. A
//! "controller" thread runs the sub-tests sequentially; a "helper" thread
//! provides the second party for the blocking/hand-off paths (both threads
//! live on core 0 and interleave via the scheduler).
//!
//!   T1  mutex               mutual-exclusion counter (2x1000 increments)
//!   T2  mutex               tryLock() reports busy when held by another thread
//!   T3  recursive mutex     nested lock/unlock, then reacquire
//!   T4  counting semaphore  3 posts consumed; tryWait() on empty fails
//!   T5  binary semaphore    post/wait signal
//!   T6  event flags         raise/wait masked + auto-clear + tryWait
//!   T7  message queue       send/receive round-trip with payload verify
//!   T8  memory pool         alloc/exhaust/free/reuse + capacity invariant
//!   T9  condition variable  predicate wait + signal (canonical mutex pattern)
//!   T10 periodic timer      ~20 firings in ~205 ms
//!
//! Visualisation:
//!   - UART0 @115200: one "PASS/FAIL <name>" line per sub-test, then a final
//!     "RESULT: PASS/FAIL (p passed, f failed)".
//!   - LED (GPIO25): a short blink per passed sub-test (triple blink on a
//!     failure).
//! The check lines and the verdict are also written to semihosting.

const std = @import("std");
const microzig = @import("microzig");
const uos = @import("uos");
const board = @import("uos_board");

const rtos = uos.rtos;
const sysclock = rtos.sysclock;
const uart = board.uart;
const semihosting = uos.port.semihosting;

pub const microzig_options = uos.port.microzig_options;

/// The C++ os-app-config.h of the pico board; OS_USE_SMP_SCHEDULER is not
/// defined for this test.
pub const uos_options: uos.Options = .{
    .ncpu = 1,
    .smp = false,
    .systick_frequency_hz = 1000,
    .critical_section_interrupt_priority = 5,
    .main_stack_size_bytes = 8192,
    .idle_stack_size_bytes = 4096,
    .default_stack_size_bytes = 4096,
    .dynamic_memory_size_bytes = 96 * 1024,
};

comptime {
    microzig.export_startup();
}

pub fn main() void {
    rtos.run(osMain);
}

fn ld(p: anytype) @TypeOf(p.*) {
    return @atomicLoad(@TypeOf(p.*), p, .acquire);
}

fn st(p: anytype, v: @TypeOf(p.*)) void {
    @atomicStore(@TypeOf(p.*), p, v, .release);
}

// ---- Objects under test ------------------------------------------------------

var mtx: rtos.Mutex = .{ .name = "mtx" };
var rmtx: rtos.Mutex = .initRecursive("rmtx");
var csem: rtos.Semaphore = .counting("csem", 4, 0);
var bsem: rtos.Semaphore = .binary("bsem", 0);
var ef: rtos.EventFlags = .{ .name = "ef" };

const Msg = extern struct {
    seq: u32,
    data: u32,
};

var mq_c2w: rtos.MessageQueueTyped(Msg).Static(8) = .{};
var mq_w2c: rtos.MessageQueueTyped(Msg).Static(8) = .{};
var mp: rtos.MemoryPoolTyped(Msg).Static(4) = .{};
var cv: rtos.ConditionVariable = .{ .name = "cv" };
var cvm: rtos.Mutex = .{ .name = "cvm" };

// ---- Cross-thread handshake + results --------------------------------------

var sem_go: rtos.Semaphore = .counting("go", 8, 0); // controller -> helper
var sem_ack: rtos.Semaphore = .counting("ack", 8, 0); // helper -> controller

const Stage = enum(u32) {
    none = 0,
    mutex_count = 1,
    trylock,
    csem,
    bsem,
    evf,
    mq,
    cv,
    done,
};

var g_stage: Stage = .none;
var g_counter: u32 = 0;
var g_helper_trylock_busy: bool = false;
var g_helper_csem_got: u32 = 0;
var g_helper_bsem_ok: bool = false;
var g_helper_ef_ok: bool = false;
var g_helper_mq_ok: bool = false;
var g_helper_cv_ok: bool = false;
var g_cv_pred: bool = false;
var g_timer_fires: u32 = 0;

const COUNT_N: u32 = 1000;

var g_log: rtos.Mutex = .{ .name = "log" }; // serialise UART writes
var g_pass: u32 = 0;
var g_fail: u32 = 0;

fn logs(s: []const u8) void {
    g_log.lock() catch {};
    uart.write(s);
    g_log.unlock() catch {};
}

fn check(ok: bool, name: []const u8) void {
    var b: [112]u8 = undefined;
    const line = std.fmt.bufPrint(&b, "[{d:>8} ms] {s:<4} {s}\n", .{
        sysclock.now(), if (ok) "PASS" else "FAIL", name,
    }) catch "";
    g_log.lock() catch {};
    uart.write(line);
    semihosting.write(line);
    g_log.unlock() catch {};
    if (ok) {
        g_pass += 1;
        board.led.set(true);
        sysclock.sleepFor(40) catch {};
        board.led.set(false);
        sysclock.sleepFor(40) catch {};
    } else {
        g_fail += 1;
        for (0..3) |_| {
            board.led.set(true);
            sysclock.sleepFor(60) catch {};
            board.led.set(false);
            sysclock.sleepFor(60) catch {};
        }
    }
}

// ---- Periodic-timer callback (runs in the tick context) --------------------

fn tmrCb(_: ?*anyopaque) void {
    st(&g_timer_fires, g_timer_fires + 1);
}

// ---- Helper thread: the second party for the hand-off tests ----------------

fn helper(_: ?*anyopaque) ?*anyopaque {
    while (true) {
        sem_go.wait() catch {};
        const s = ld(&g_stage);
        if (s == .done) break;
        switch (s) {
            .mutex_count => {
                for (0..COUNT_N) |_| {
                    mtx.lock() catch {};
                    g_counter += 1;
                    mtx.unlock() catch {};
                }
            },
            .trylock => {
                // mtx is held by the controller: tryLock must NOT succeed.
                st(&g_helper_trylock_busy, if (mtx.tryLock()) |_| false else |_| true);
            },
            .csem => {
                st(&g_helper_csem_got, 0);
                for (0..3) |_| {
                    csem.wait() catch {};
                    st(&g_helper_csem_got, g_helper_csem_got + 1);
                }
            },
            .bsem => {
                st(&g_helper_bsem_ok, if (bsem.wait()) |_| true else |_| false);
            },
            .evf => {
                st(&g_helper_ef_ok, if (ef.wait(1 << 0, .all_clear)) |_| true else |_| false);
                _ = ef.raise(1 << 2) catch {}; // hand a flag back to the controller
            },
            .mq => {
                st(&g_helper_mq_ok, false);
                if (mq_c2w.typed.receive()) |received| {
                    var m = received;
                    m.data ^= 0xFFFF; // transform to prove processing
                    if (mq_w2c.typed.send(m, 0)) |_| st(&g_helper_mq_ok, true) else |_| {}
                } else |_| {}
            },
            .cv => {
                cvm.lock() catch {};
                while (!ld(&g_cv_pred)) cv.wait(&cvm) catch {};
                cvm.unlock() catch {};
                st(&g_helper_cv_ok, true);
            },
            else => {},
        }
        sem_ack.post() catch {};
    }
    return null;
}

// ---- Controller thread: drive every object, self-check ---------------------

fn controller(_: ?*anyopaque) ?*anyopaque {
    logs("\n");
    logs("=============================================\n");
    logs("  Pico / RP2040B - micro-os-plus-iii\n");
    logs("  sc-test-ko : kernel objects, single core\n");
    logs("=============================================\n");

    // T1 -- mutex: mutual exclusion. Both threads add COUNT_N under the lock.
    g_counter = 0;
    st(&g_stage, .mutex_count);
    sem_go.post() catch {};
    for (0..COUNT_N) |_| {
        mtx.lock() catch {};
        g_counter += 1;
        mtx.unlock() catch {};
    }
    sem_ack.wait() catch {};
    check(g_counter == 2 * COUNT_N, "mutex: mutual-exclusion counter");

    // T2 -- mutex: tryLock() must report busy while another thread holds it.
    mtx.lock() catch {};
    st(&g_stage, .trylock);
    sem_go.post() catch {};
    sem_ack.wait() catch {};
    mtx.unlock() catch {};
    check(ld(&g_helper_trylock_busy), "mutex: try_lock busy when held");

    // T3 -- recursive mutex: nested lock/unlock, then reacquire.
    {
        var ok = if (rmtx.lock()) |_| true else |_| false;
        ok = ok and (if (rmtx.lock()) |_| true else |_| false); // recursive, no self-deadlock
        ok = ok and (if (rmtx.unlock()) |_| true else |_| false); // depth 2 -> 1
        ok = ok and (if (rmtx.unlock()) |_| true else |_| false); // depth 1 -> 0
        ok = ok and (if (rmtx.tryLock()) |_| true else |_| false); // now free
        rmtx.unlock() catch {};
        check(ok, "recursive mutex: nested lock + reacquire");
    }

    // T4 -- counting semaphore: the helper consumes 3 posts; empty tryWait fails.
    st(&g_stage, .csem);
    sem_go.post() catch {};
    sysclock.sleepFor(5) catch {}; // let the helper block on the empty semaphore
    csem.post() catch {};
    csem.post() catch {};
    csem.post() catch {};
    sem_ack.wait() catch {};
    check(ld(&g_helper_csem_got) == 3 and std.meta.isError(csem.tryWait()), "counting semaphore: 3 consumed + empty try_wait");

    // T5 -- binary semaphore: post/wait signal.
    st(&g_stage, .bsem);
    sem_go.post() catch {};
    sysclock.sleepFor(5) catch {};
    bsem.post() catch {};
    sem_ack.wait() catch {};
    check(ld(&g_helper_bsem_ok), "binary semaphore: post/wait");

    // T6 -- event flags: the helper waits bit0 (auto-clear), we raise
    // bit0|bit1, the helper hands bit2 back, we wait it; an unset-bit tryWait
    // fails.
    {
        _ = ef.clear(0xFFFF_FFFF) catch {};
        st(&g_stage, .evf);
        sem_go.post() catch {};
        sysclock.sleepFor(5) catch {};
        _ = ef.raise((1 << 0) | (1 << 1)) catch {};
        const w = if (ef.wait(1 << 2, .all_clear)) |_| true else |_| false;
        sem_ack.wait() catch {};
        const tw = std.meta.isError(ef.tryWait(1 << 5, .all_clear)); // never raised
        check(ld(&g_helper_ef_ok) and w and tw, "event flags: raise/wait mask + try_wait");
    }

    // T7 -- message queue: send a payload, the helper transforms + echoes it.
    {
        const m: Msg = .{ .seq = 0x1234, .data = 0x00AA };
        st(&g_stage, .mq);
        sem_go.post() catch {};
        mq_c2w.typed.send(m, 0) catch {};
        var ok = false;
        var r: Msg = .{ .seq = 0, .data = 0 };
        if (mq_w2c.typed.receive()) |got| {
            r = got;
            ok = true;
        } else |_| {}
        sem_ack.wait() catch {};
        ok = ok and ld(&g_helper_mq_ok) and r.seq == 0x1234 and r.data == (0x00AA ^ 0xFFFF);
        check(ok, "message queue: send/receive + payload verify");
    }

    // T8 -- memory pool: alloc all, exhaust, free, reuse, capacity invariant.
    {
        var blocks: [4]?*Msg = @splat(null);
        var ok = true;
        for (&blocks) |*blk| {
            blk.* = mp.typed.tryAlloc() catch null;
            ok = ok and blk.* != null;
        }
        ok = ok and std.meta.isError(mp.typed.tryAlloc()); // pool exhausted
        if (blocks[0]) |blk| mp.typed.free(blk) catch {};
        const reuse = mp.typed.tryAlloc() catch null; // the freed slot is reusable
        ok = ok and reuse != null;
        if (reuse) |blk| mp.typed.free(blk) catch {};
        for (blocks[1..]) |maybe| {
            if (maybe) |blk| mp.typed.free(blk) catch {};
        }
        ok = ok and mp.typed.pool.capacity() == 4;
        check(ok, "memory pool: alloc/exhaust/free/reuse + capacity");
    }

    // T9 -- condition variable: the helper waits on a predicate; we set + signal.
    {
        st(&g_cv_pred, false);
        st(&g_stage, .cv);
        sem_go.post() catch {};
        sysclock.sleepFor(10) catch {}; // ensure the helper is parked in cv.wait()
        cvm.lock() catch {};
        st(&g_cv_pred, true);
        cv.signal() catch {};
        cvm.unlock() catch {};
        sem_ack.wait() catch {};
        check(ld(&g_helper_cv_ok), "condition variable: predicate wait + signal");
    }

    // T10 -- periodic timer: ~20 firings across ~205 ms at a 10 ms period.
    {
        st(&g_timer_fires, 0);
        var t: rtos.Timer = .init("t", tmrCb, null, .periodic);
        t.start(10) catch {}; // 10 ticks == 10 ms
        sysclock.sleepFor(205) catch {};
        t.stop() catch {};
        t.deinit();
        const f = ld(&g_timer_fires);
        check(f >= 15 and f <= 25, "periodic timer: ~20 fires in 205 ms");
    }

    // Release the helper thread.
    st(&g_stage, .done);
    sem_go.post() catch {};

    var b: [80]u8 = undefined;
    const verdict = std.fmt.bufPrint(&b, "\nRESULT: {s}  ({d} passed, {d} failed)\n", .{
        if (g_fail == 0) "PASS" else "FAIL", g_pass, g_fail,
    }) catch "";
    logs("---------------------------------------------\n");
    g_log.lock() catch {};
    uart.write(verdict);
    g_log.unlock() catch {};

    // The verdict on the debug channel and the semihosting exit
    // (hw_result::ok()/fail() in C++).
    semihosting.write(verdict);
    semihosting.exit(if (g_fail == 0) 0 else 1);
}

var ctl_stack: [2048]uos.port.StackElement align(8) = undefined;
var hlp_stack: [2048]uos.port.StackElement align(8) = undefined;
var ctl: rtos.Thread = undefined;
var hlp: rtos.Thread = undefined;

fn osMain() u8 {
    board.led.init();

    mq_c2w.init("c2w", .{}) catch @panic("c2w");
    mq_w2c.init("w2c", .{}) catch @panic("w2c");
    mp.init("mp", .{}) catch @panic("mp");

    ctl.init("controller", controller, null, .{ .stack = &ctl_stack }, null) catch
        @panic("cannot create the controller");
    hlp.init("helper", helper, null, .{ .stack = &hlp_stack }, null) catch
        @panic("cannot create the helper");

    while (true) sysclock.sleepFor(10000) catch {};
}
