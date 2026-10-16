//! smp-test-nested (Pico 2 / RP2350B) -- Nested Interrupts & SMP.
//!
//! The Zig port of test/pico2-rp2350b-psram/smp-test-nested/main.cpp, line
//! for line. Demonstrates:
//!   1. The SMP scheduler with thread migration (no affinity pins for the
//!      workers and the LED thread).
//!   2. Nested interrupts on core 0 and core 1:
//!      - SysTick (priority 15, the lowest) driving scheduling and sleeps;
//!      - UART0_IRQ (priority 12, medium), pended by hand every 1.5 s, busy
//!        for ~2 ms so the alarms preempt it;
//!      - TIMER0_IRQ_2 (priority 8, the highest), every 1.25 s;
//!      - TIMER0_IRQ_3 (priority 10, medium-high), every 1.2495 s.
//!   3. Lock-free real-time trace logging (SIO spinlock 4), with the
//!      time-critical routines and the handlers in RAM (`.ram_text`, the C++
//!      `.data` placement) for a low interrupt latency.
//!
//! Each worker beats 20 times (~20 s); then PASS when both workers did and
//! the three nesting interrupts fired.
//!
//! Differences from C++: the kernel's startup banner and exit trace; the
//! kernel creates each CPU's idle thread itself, so the core-1 NVIC set-up
//! of the C++ test's own idle1 thread is done by `nvic1`, a thread pinned to
//! core 1 at the idle priority, with the same loop; the threads are static
//! objects (C++: `new thread`); the run ends with osMain()'s return value
//! through exit() (C++: hw_result::ok(), which is std::exit()).

const std = @import("std");
const microzig = @import("microzig");
const uos = @import("uos");
const board = @import("uos_board");

const rtos = uos.rtos;
const sysclock = rtos.sysclock;
const this_thread = rtos.this_thread;
const arch = uos.port.arch;
const semihosting = uos.port.semihosting;
const uart = board.uart;

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

/// The three nesting interrupts.
pub const uos_interrupts = .{
    .UART0_IRQ = microzig.interrupt.Handler{ .c = uart0IrqHandler },
    .TIMER0_IRQ_2 = microzig.interrupt.Handler{ .c = timer0Irq2Handler },
    .TIMER0_IRQ_3 = microzig.interrupt.Handler{ .c = timer0Irq3Handler },
};

comptime {
    microzig.export_startup();
}

pub fn main() void {
    rtos.run(osMain);
}

fn reg(a: usize) *volatile u32 {
    return @ptrFromInt(a);
}

fn ld(p: anytype) @TypeOf(p.*) {
    return @atomicLoad(@TypeOf(p.*), p, .acquire);
}

fn st(p: anytype, v: @TypeOf(p.*)) void {
    @atomicStore(@TypeOf(p.*), p, v, .release);
}

var g_global: u32 = 0;
var g_mutex: rtos.Mutex = .{ .name = "g" };

const StackElement = uos.port.StackElement;
var worker_stacks: [2][1024]StackElement align(8) = undefined;
var led_stack: [1024]StackElement align(8) = undefined;
var trigger_stack: [1024]StackElement align(8) = undefined;
var trace_stack: [1024]StackElement align(8) = undefined;
var nvic1_stack: [512]StackElement align(8) = undefined;

const Ctx = struct {
    id: u32,
    local: u32,
};
var worker_ctx: [2]Ctx = undefined;

// How many times each nesting interrupt ran, for the verdict.
var g_irq_uart: u32 = 0;
var g_irq_t2: u32 = 0;
var g_irq_t3: u32 = 0;

// ---- TIMER0 alarm definitions -----------------------------------------------

const RESETS_BASE: usize = 0x4002_0000;
const TIMER0_BASE: usize = 0x400B_0000;
const TIMER0_RESET_BIT: u5 = 23;
const RESET_REG = RESETS_BASE + 0x00;
const RESET_DONE_REG = RESETS_BASE + 0x08;
const TIMER_TIMEHR = TIMER0_BASE + 0x08;
const TIMER_TIMELR = TIMER0_BASE + 0x0C;
const TICKS_BASE: usize = 0x4010_8000;
const TICKS_TIMER0_CTRL = TICKS_BASE + 0x18;
const TICKS_TIMER0_CYCLES = TICKS_BASE + 0x1C;
const TICKS_CTRL_ENABLE: u32 = 1 << 0;
const CLK_REF_HZ: u32 = 12_000_000;
const UART0_BASE: usize = 0x4007_0000;

const TIMER0_IRQ_2: u32 = 2;
const TIMER0_IRQ_3: u32 = 3;
const UART0_IRQ: u32 = 33;

fn timerInit() void {
    reg(RESET_REG).* &= ~(@as(u32, 1) << TIMER0_RESET_BIT);
    while (reg(RESET_DONE_REG).* & (@as(u32, 1) << TIMER0_RESET_BIT) == 0) {}
    reg(TICKS_TIMER0_CYCLES).* = CLK_REF_HZ / 1_000_000;
    reg(TICKS_TIMER0_CTRL).* = TICKS_CTRL_ENABLE;
}

noinline fn timerUs32() linksection(".ram_text") u32 {
    const hi = reg(TIMER_TIMEHR).*;
    const lo = reg(TIMER_TIMELR).*;
    _ = hi;
    return lo;
}

noinline fn alarm2Arm(delay_us: u32) linksection(".ram_text") void {
    const now = timerUs32();
    reg(TIMER0_BASE + 0x18).* = now +% delay_us; // ALARM2
}

noinline fn alarm3Arm(delay_us: u32) linksection(".ram_text") void {
    const now = timerUs32();
    reg(TIMER0_BASE + 0x1c).* = now +% delay_us; // ALARM3
}

/// A priority in the NVIC's upper bits (C++ NVIC_SetPriority).
fn nvicPriority(irq: u32, prio: u8) void {
    arch.nvicSetPriority(irq, prio << (8 - @as(u4, arch.nvic_prio_bits)));
}

fn nvicSetPending(irq: u32) void {
    reg(0xE000_E200 + 4 * (irq / 32)).* = @as(u32, 1) << @intCast(irq % 32);
}

// ---- Lock-free trace logging -------------------------------------------------

const TraceEvent = struct {
    timestamp: u32,
    core: u8,
    event_name: []const u8,
    thread_name: []const u8,
    thread_id: usize,
};

const TRACE_MAX = 512;
var g_trace_buffer: [TRACE_MAX]TraceEvent = undefined;
var g_trace_count: u32 = 0;

// SIO spinlock 4 protects the trace buffer counter increment. Interrupts are
// disabled locally on the core before acquiring the spinlock to prevent a
// same-core preemption deadlock.
const TRACE_LOCK: usize = 0xD000_0100 + 16; // slot 4

noinline fn allocateTraceSlot() linksection(".ram_text") u32 {
    const saved = arch.getPrimask();
    asm volatile ("cpsid i" ::: .{ .memory = true });
    while (reg(TRACE_LOCK).* == 0) {}
    const idx = ld(&g_trace_count);
    st(&g_trace_count, idx + 1);
    reg(TRACE_LOCK).* = 1;
    arch.setPrimask(saved);
    return idx;
}

noinline fn logTraceAt(event_name: []const u8, timestamp: u32) linksection(".ram_text") void {
    const idx = allocateTraceSlot();
    if (idx < TRACE_MAX) {
        const cpu = uos.port.scheduler.cpuId();
        const th = uos.rtos.scheduler.current_thread[cpu];
        g_trace_buffer[idx] = .{
            .timestamp = timestamp,
            .core = @intCast(cpu),
            .event_name = event_name,
            .thread_name = if (th) |t| t.name else "none",
            .thread_id = if (th) |t| @intFromPtr(t) else 0,
        };
    }
}

noinline fn logTrace(event_name: []const u8) linksection(".ram_text") void {
    logTraceAt(event_name, timerUs32());
}

// ---- Worker/heartbeat line prints --------------------------------------------

fn line(role: []const u8, id: u32, local: u32, global: u32) void {
    var buf: [128]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "[{d:>8} ms] {s:<6} #{d} (ID: 0x{x}) core={d} local={d:<4} global={d}\n", .{
        sysclock.now(), role, id, @intFromPtr(this_thread.thread()), uos.port.scheduler.cpuId(), local, global,
    }) catch return;
    g_mutex.lock() catch {};
    uart.write(s);
    g_mutex.unlock() catch {};
}

// ---- Threads -------------------------------------------------------------------

fn worker(arg: ?*anyopaque) ?*anyopaque {
    const c: *Ctx = @ptrCast(@alignCast(arg.?));
    while (true) {
        c.local += 1;
        g_mutex.lock() catch {};
        g_global += 1;
        const g = g_global;
        g_mutex.unlock() catch {};
        line("worker", c.id, c.local, g);
        logTrace("Worker_Run");
        sysclock.sleepFor(1000) catch {};
    }
    return null;
}

fn ledThread(_: ?*anyopaque) ?*anyopaque {
    while (true) {
        sysclock.sleepFor(3000) catch {};
        line("LED", 0, 0, g_global);
        logTrace("LED_Blink");
        for (0..3) |_| {
            board.led.set(true);
            sysclock.sleepFor(200) catch {};
            board.led.set(false);
            sysclock.sleepFor(200) catch {};
        }
    }
    return null;
}

fn triggerThread(_: ?*anyopaque) ?*anyopaque {
    sysclock.sleepFor(2000) catch {};
    while (true) {
        sysclock.sleepFor(1500) catch {}; // trigger the nesting sequence every 1.5 s

        const trig_time = timerUs32();

        // Pend the UART0 exception (priority 12).
        nvicSetPending(UART0_IRQ);

        logTraceAt("Trigger", trig_time);
    }
    return null;
}

fn tracePrinterThread(_: ?*anyopaque) ?*anyopaque {
    sysclock.sleepFor(3000) catch {}; // offset, to avoid overlapping startup prints
    while (true) {
        sysclock.sleepFor(4000) catch {}; // dump the trace log every 4 seconds

        g_mutex.lock() catch {};
        uart.write("\n================== TRACE LOG BUFFER DUMP ==================\n");

        var count = ld(&g_trace_count);
        if (count > TRACE_MAX) count = TRACE_MAX;

        for (g_trace_buffer[0..count]) |*e| {
            var buf: [128]u8 = undefined;
            const s = std.fmt.bufPrint(&buf, "[{d:>8} us] C{d} Event: {s:<12} | Interrupted Thread: {s} (ID: 0x{x})\n", .{
                e.timestamp, e.core, e.event_name, e.thread_name, e.thread_id,
            }) catch continue;
            uart.write(s);
        }

        uart.write("===========================================================\n\n");

        // Reset the counter.
        st(&g_trace_count, 0);
        g_mutex.unlock() catch {};
    }
    return null;
}

/// The core-1 NVIC set-up of the C++ test's idle1 thread (see the header).
fn nvic1Func(_: ?*anyopaque) ?*anyopaque {
    if (uos.port.scheduler.cpuId() != 1) this_thread.yield();

    // ---- NVIC configuration for the nesting demo (core 1) ----------------
    // 1. TIMER0 alarm 2 (IRQ 2), priority 8 (high).
    nvicPriority(TIMER0_IRQ_2, 8);
    arch.nvicEnable(TIMER0_IRQ_2);

    // 2. TIMER0 alarm 3 (IRQ 3), priority 10 (medium-high).
    nvicPriority(TIMER0_IRQ_3, 10);
    arch.nvicEnable(TIMER0_IRQ_3);

    // 3. UART0 (IRQ 33), priority 12 (lower than alarms 2/3).
    nvicPriority(UART0_IRQ, 12);
    arch.nvicEnable(UART0_IRQ);

    while (true) {
        asm volatile ("dsb" ::: .{ .memory = true });
        asm volatile ("wfi");
        this_thread.yield();
    }
    return null;
}

// ---- ISRs ------------------------------------------------------------------------

/// UART0 interrupt handler (priority 12, medium).
fn uart0IrqHandler() linksection(".ram_text") callconv(.c) void {
    const entry_time = timerUs32();

    // Clear the UART interrupt status.
    reg(UART0_BASE + 0x44).* = 0x7FF;

    logTraceAt("UART_Start", entry_time);
    st(&g_irq_uart, ld(&g_irq_uart) + 1);

    // Busy loop for ~2 ms so the alarms preempt it (150 MHz).
    var count: u32 = 0;
    var j: u32 = 0;
    while (j < 55000) : (j += 1) {
        @as(*volatile u32, &count).* += 1;
        asm volatile ("" ::: .{ .memory = true });
    }

    logTrace("UART_End");
}

/// TIMER0 alarm 2 handler (priority 8, the highest): every 1.25 s.
fn timer0Irq2Handler() linksection(".ram_text") callconv(.c) void {
    const entry_time = timerUs32();

    // Clear the TIMER0 alarm 2 interrupt (INTR at 0x3C).
    reg(TIMER0_BASE + 0x3C).* = 1 << 2;

    // Re-arm alarm 2 for another 1.25 s.
    alarm2Arm(1_250_000);

    logTraceAt("T2_Alarm", entry_time);
    st(&g_irq_t2, ld(&g_irq_t2) + 1);
}

/// TIMER0 alarm 3 handler (priority 10, medium-high): every 1.2495 s.
fn timer0Irq3Handler() linksection(".ram_text") callconv(.c) void {
    const entry_time = timerUs32();

    // Clear the TIMER0 alarm 3 interrupt.
    reg(TIMER0_BASE + 0x3C).* = 1 << 3;

    // Re-arm alarm 3 for another 1.2495 s.
    alarm3Arm(1_249_500);

    logTraceAt("T3_Alarm", entry_time);
    st(&g_irq_t3, ld(&g_irq_t3) + 1);
}

// ---- Entry point -------------------------------------------------------------------

var workers: [2]rtos.Thread = undefined;
var led_th: rtos.Thread = undefined;
var trigger_th: rtos.Thread = undefined;
var trace_th: rtos.Thread = undefined;
var nvic1_th: rtos.Thread = undefined;
const worker_names = [2][:0]const u8{ "wrk0", "wrk1" };

fn osMain() u8 {
    // Pin the main thread to core 0 during start-up.
    this_thread.thread().setCpuAffinity(1 << 0);

    board.led.init();
    timerInit();

    uart.write("\n");
    uart.write("=============================================\n");
    uart.write("  Pico 2 / RP2350B - micro-os-plus-iii\n");
    uart.write("  smp-test-nested : Nested Interrupts & SMP\n");
    uart.write("=============================================\n");

    // The core-1 NVIC set-up (C++: the test's idle1 thread).
    nvic1_th.init("nvic1", nvic1Func, null, .{ .stack = &nvic1_stack, .priority = rtos.priority.idle, .cpu_affinity = 1 << 1 }, null) catch
        @panic("cannot create nvic1");

    // Worker threads with the default (any core) affinity: no pinning.
    for (&workers, &worker_stacks, &worker_ctx, 0..) |*th, *stack, *c, i| {
        c.* = .{ .id = @intCast(i), .local = 0 };
        th.init(worker_names[i], worker, c, .{ .stack = stack }, null) catch @panic("cannot create a worker");
    }

    // LED thread with the default (any core) affinity: no pinning.
    led_th.init("led", ledThread, null, .{ .stack = &led_stack }, null) catch @panic("cannot create led");

    // Trigger thread with the default (any core) affinity: no pinning.
    trigger_th.init("trigger", triggerThread, null, .{ .stack = &trigger_stack }, null) catch @panic("cannot create trigger");

    // Trace printer thread.
    trace_th.init("trace", tracePrinterThread, null, .{ .stack = &trace_stack }, null) catch @panic("cannot create trace");

    // ---- NVIC configuration for the nesting demo (core 0) -----------------

    // 1. TIMER0 alarm 2 (IRQ 2), priority 8 (high).
    nvicPriority(TIMER0_IRQ_2, 8);
    alarm2Arm(1_250_000); // in 1.25 s
    reg(TIMER0_BASE + 0x40).* |= 1 << 2; // enable alarm 2 in the timer's INTE
    arch.nvicEnable(TIMER0_IRQ_2);

    // 2. TIMER0 alarm 3 (IRQ 3), priority 10 (medium-high).
    nvicPriority(TIMER0_IRQ_3, 10);
    alarm3Arm(1_249_500); // in 1.2495 s
    reg(TIMER0_BASE + 0x40).* |= 1 << 3; // enable alarm 3 in the timer's INTE
    arch.nvicEnable(TIMER0_IRQ_3);

    // 3. UART0 (IRQ 33), priority 12 (lower than alarms 2/3).
    nvicPriority(UART0_IRQ, 12);
    arch.nvicEnable(UART0_IRQ);

    uart.write("core 0: launching core 1 (bootrom FIFO handshake)...\n");
    uos.port.launchCore1();
    uart.write("core 0: core 1 launched; SMP running without worker affinity.\n");

    // Bounded run: each worker does k_iters beats (~k_iters * 1 s), then the
    // verdict -- both workers ran them all, and all three nesting interrupts
    // (UART0, TIMER0 alarms 2 and 3) fired.
    const k_iters = 20;
    var i: u32 = 0;
    while (i < 600 and (ld(&worker_ctx[0].local) < k_iters or ld(&worker_ctx[1].local) < k_iters)) : (i += 1) {
        sysclock.sleepFor(100) catch {};
    }

    const ok = ld(&worker_ctx[0].local) >= k_iters and ld(&worker_ctx[1].local) >= k_iters and
        ld(&g_irq_uart) > 0 and ld(&g_irq_t2) > 0 and ld(&g_irq_t3) > 0;
    var buf: [128]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "\nRESULT: {s}  (wrk0={d} wrk1={d} uart={d} t2={d} t3={d})\n", .{
        if (ok) "PASS" else "FAIL", ld(&worker_ctx[0].local), ld(&worker_ctx[1].local),
        ld(&g_irq_uart),                    ld(&g_irq_t2),             ld(&g_irq_t3),
    }) catch "\nRESULT: ?\n";
    g_mutex.lock() catch {};
    uart.write(s);
    g_mutex.unlock() catch {};

    // As hw_result::ok() / fail(): the verdict on semihosting (what the
    // runner reads), then the end of the run (exit()).
    semihosting.write(if (ok) "RESULT: PASS\n" else "RESULT: FAIL\n");
    return if (ok) 0 else 1;
}
