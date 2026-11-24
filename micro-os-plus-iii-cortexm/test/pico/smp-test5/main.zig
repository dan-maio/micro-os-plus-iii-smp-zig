//! smp-test5 (Pico / RP2040) -- Phase 6: interrupt-driven UART TX,
//! cross-core ISR.
//!
//! The Zig port of test/pico/smp-test5/main.cpp, line for line.
//!
//! The first real peripheral interrupt: UART0 (PL011) external IRQ 20,
//! serviced on CORE 1, draining a producer/consumer TX ring that a thread on
//! core 0 fills:
//!
//!   producer (core 0)                    irq_host (core 1)
//!     sem_uart_ready.wait()                enable UART0_IRQ on core 1
//!     txqWrite(line)                       g_tx_active = true
//!       lock, enqueue ring                 sem_uart_ready.post()
//!       set IMSC.TXIM (kick)            UART0_IRQ handler (IRQ 20, core 1)
//!                                          drain ring -> UART FIFO
//!                                          clear TXIM when ring empty
//!
//! Proves:
//!   - the vector table routes IRQ 20 to the UART0 handler;
//!   - the ISR runs on the SECONDARY core (g_isr_core == 1);
//!   - interrupt-driven TX: no thread busy-polls the UART after boot;
//!   - byte integrity: enqueued == transmitted, 0 dropped.
//!
//! The test has its own PL011 driver (polled for the boot banner,
//! interrupt-driven after); the kernel trace goes through it too
//! (`uos_trace_write`), as the C++ kernel trace goes through the test's
//! `uart::write()`.
//!
//! Output on UART0 @115200; the LED toggles every 100 lines (core 0). The
//! summary is also written to semihosting (the runner's log).

const std = @import("std");
const microzig = @import("microzig");
const uos = @import("uos");
const board = @import("uos_board");

const rtos = uos.rtos;
const sysclock = rtos.sysclock;
const this_thread = rtos.this_thread;
const arch = uos.port.arch;
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

/// The UART0 TX interrupt (IRQ 20 on RP2040).
pub const uos_interrupts = .{
    .UART0_IRQ = microzig.interrupt.Handler{ .c = uart0IrqHandler },
};

/// The kernel trace goes through this test's UART driver.
pub fn uos_trace_write(bytes: []const u8) void {
    txqWrite(bytes);
}

comptime {
    microzig.export_startup();
}

pub fn main() void {
    rtos.run(osMain);
}

fn reg(addr: usize) *volatile u32 {
    return @ptrFromInt(addr);
}

// ----------------------------------------------------------------------------
// Per-test PL011 UART driver: polled while g_tx_active == false (boot
// banner), then interrupt-driven through a TX ring drained by the UART0 IRQ.

const UART0_BASE: usize = 0x4003_4000;
const UART0_IRQN: u32 = 20;

// PL011 register offsets.
const DR = 0x00;
const FR = 0x18;
const IBRD = 0x24;
const FBRD = 0x28;
const LCRH = 0x2C;
const CR = 0x30;
const IFLS = 0x34;
const IMSC = 0x38;
const ICR = 0x44;
const FR_TXFF: u32 = 1 << 5;
const IMSC_TXIM: u32 = 1 << 5; // TX interrupt mask
// TX trigger 4/8 (IRQ when the FIFO has <= 8 bytes) -- bits [3:2].
const IFLS_TXIFLSEL_4_8: u32 = 2 << 2;

fn polledPutChar(c: u8) void {
    while (reg(UART0_BASE + FR).* & FR_TXFF != 0) {}
    reg(UART0_BASE + DR).* = c;
}

fn polledPutStr(s: []const u8) void {
    for (s) |c| {
        if (c == '\n') polledPutChar('\r');
        polledPutChar(c);
    }
}

// ---- TX ring (single producer + ISR consumer, power of two) ----------------

const TXQ_SIZE: u32 = 2048;
var g_txq: [TXQ_SIZE]u8 = undefined;
var g_txq_head: u32 = 0; // producers write here
var g_txq_tail: u32 = 0; // the ISR consumes here
var g_tx_active: bool = false; // false = polled (boot)
var g_tx_enq: u32 = 0; // bytes enqueued (producers)
var g_tx_bytes: u32 = 0; // bytes transmitted (ISR)
var g_tx_dropped: u32 = 0;
var g_tx_irq_count: u32 = 0;
var g_isr_core: u32 = 0xFF;

// Cross-core ring lock: SIO HARDWARE spinlock 2 (slots 0/1 are the kernel
// and console locks) -- not an LDREX/STREX lock.
const TXQ_LOCK: usize = 0xD000_0100 + 0x08; // slot 2

fn ld(p: anytype) @TypeOf(p.*) {
    return @atomicLoad(@TypeOf(p.*), p, .acquire);
}

fn st(p: anytype, v: @TypeOf(p.*)) void {
    @atomicStore(@TypeOf(p.*), p, v, .release);
}

/// Lock: mask local IRQs BEFORE spinning; return the ORIGINAL PRIMASK.
fn txqLockAcquire() u32 {
    const saved = arch.getPrimask();
    arch.disableIrq();
    while (reg(TXQ_LOCK).* == 0) {}
    arch.dmb();
    return saved;
}

fn txqLockRelease(saved: u32) void {
    arch.dmb();
    reg(TXQ_LOCK).* = 1;
    arch.setPrimask(saved);
}

/// Caller holds the lock. '\n' expands to CR+LF. Returns the number of WIRE
/// bytes actually enqueued (0, 1 or 2), so g_tx_enq matches what the ISR
/// later transmits.
fn txqPutcLocked(c: u8) u32 {
    var n: u32 = 0;
    if (c == '\n') {
        const next = (g_txq_head + 1) & (TXQ_SIZE - 1);
        if (next == ld(&g_txq_tail)) return 0;
        g_txq[g_txq_head] = '\r';
        st(&g_txq_head, next);
        n = 1;
    }
    const next = (g_txq_head + 1) & (TXQ_SIZE - 1);
    if (next == ld(&g_txq_tail)) return n; // the '\r' went in but the char did not
    g_txq[g_txq_head] = c;
    st(&g_txq_head, next);
    return n + 1;
}

fn txqKickLocked() void {
    reg(UART0_BASE + IMSC).* |= IMSC_TXIM;
}

fn txqWrite(s: []const u8) void {
    if (!ld(&g_tx_active)) {
        polledPutStr(s);
        return;
    }
    const saved = txqLockAcquire();
    for (s) |c| {
        const placed = txqPutcLocked(c);
        g_tx_enq += placed;
        if (placed == 0) g_tx_dropped += 1;
    }
    txqKickLocked();
    txqLockRelease(saved);
}

/// The UART set-up of the C++ test (the board already muxed GPIO0/1 and
/// released the resets): 115200 8N1 at clk_peri = 125 MHz, FIFOs, the TX
/// interrupt threshold, no interrupts yet.
fn uartInit() void {
    const u = UART0_BASE;
    reg(u + CR).* = 0; // disable while configuring
    reg(u + ICR).* = 0x7FF; // clear pending
    reg(u + IBRD).* = 67; // 125 MHz / (16 * 115200) = 67.82
    reg(u + FBRD).* = 52; // 0.82 * 64, rounded
    reg(u + LCRH).* = (3 << 5) | (1 << 4); // 8N1, FIFO enable
    reg(u + IFLS).* = IFLS_TXIFLSEL_4_8; // TX IRQ at <= 8 bytes
    reg(u + IMSC).* = 0; // no interrupts yet (polled boot)
    reg(u + CR).* = (1 << 9) | (1 << 8) | (1 << 0); // RXE | TXE | UARTEN
}

// ----------------------------------------------------------------------------
// UART0 IRQ handler: drains the TX ring into the PL011 FIFO. Runs on CORE 1
// (the only core with the IRQ enabled). No RTOS calls.

fn uart0IrqHandler() callconv(.c) void {
    st(&g_tx_irq_count, g_tx_irq_count + 1);
    st(&g_isr_core, uos.port.scheduler.cpuId());
    const saved = txqLockAcquire();
    var more = false;
    while (ld(&g_txq_tail) != ld(&g_txq_head)) {
        if (reg(UART0_BASE + FR).* & FR_TXFF != 0) {
            more = true; // FIFO full; leave TXIM set for the next IRQ
            break;
        }
        reg(UART0_BASE + DR).* = g_txq[g_txq_tail];
        st(&g_txq_tail, (g_txq_tail + 1) & (TXQ_SIZE - 1));
        st(&g_tx_bytes, g_tx_bytes + 1);
    }
    if (!more) {
        // Ring empty: stop the level-triggered TX interrupt.
        reg(UART0_BASE + IMSC).* &= ~IMSC_TXIM;
    }
    txqLockRelease(saved);
}

// ----------------------------------------------------------------------------
// Test threads.

var sem_uart_ready: rtos.Semaphore = .counting("u_rdy", 4, 0);
const LINES: u32 = 1000;
const DRAIN_STALL_LIMIT: u32 = 100; // ticks before we call a stall
var g_stall_fail = false;

var led_on = false;

fn ledToggle() void {
    led_on = !led_on;
    board.led.set(led_on);
}

// ---- Core 1: enable the UART IRQ here (cross-core routing), then idle -----

fn irqHost(_: ?*anyopaque) ?*anyopaque {
    this_thread.thread().setCpuAffinity(1 << 1);
    if (uos.port.scheduler.cpuId() != 1) this_thread.yield();
    // Priority 2 of 0..3 (2 priority bits on RP2040); PendSV is 3.
    arch.nvicSetPriority(UART0_IRQN, 2 << (8 - @as(u4, arch.nvic_prio_bits)));
    arch.nvicEnable(UART0_IRQN);
    st(&g_tx_active, true);
    sem_uart_ready.post() catch {};
    while (true) sysclock.sleepFor(1000) catch {};
}

// ---- Core 0: produce lines through the interrupt-driven ring --------------

fn producer(_: ?*anyopaque) ?*anyopaque {
    this_thread.thread().setCpuAffinity(1 << 0);
    if (uos.port.scheduler.cpuId() != 0) this_thread.yield();
    sem_uart_ready.wait() catch {};
    var n: u32 = 1;
    while (n <= LINES) : (n += 1) {
        // Self-throttle to the 115200 wire rate: wait until the ring has
        // fully drained before producing the next line. A stalled ISR
        // visibly stalls the producer and trips g_stall_fail.
        var stall: u32 = 0;
        while (ld(&g_txq_head) != ld(&g_txq_tail)) {
            sysclock.sleepFor(1) catch {};
            stall += 1;
            if (stall > DRAIN_STALL_LIMIT) {
                g_stall_fail = true;
                break;
            }
        }
        var b: [64]u8 = undefined;
        txqWrite(std.fmt.bufPrint(&b, "line {d}: isr=core{d} irqs={d} tx={d} enq={d}\n", .{
            n, ld(&g_isr_core), ld(&g_tx_irq_count), ld(&g_tx_bytes), ld(&g_tx_enq),
        }) catch "");
        if (n % 100 == 0) ledToggle();
    }
    // Wait for the final line to drain so enqueued == transmitted at the
    // summary snapshot.
    while (ld(&g_txq_head) != ld(&g_txq_tail)) sysclock.sleepFor(1) catch {};

    const ok = ld(&g_isr_core) == 1 and ld(&g_tx_bytes) == ld(&g_tx_enq) and
        ld(&g_tx_dropped) == 0 and ld(&g_tx_irq_count) > 0 and !g_stall_fail;
    var b: [320]u8 = undefined;
    const summary = std.fmt.bufPrint(&b,
        \\---------------------------------------------
        \\interrupt-driven UART TX summary
        \\  lines       = {d}
        \\  isr core    = {d} (expect 1)
        \\  tx irqs     = {d}
        \\  enqueued    = {d}
        \\  transmitted = {d}
        \\  dropped     = {d} (expect 0)
        \\  stall fail  = {d} (expect 0)
        \\RESULT: {s}
        \\
    , .{
        LINES,                                   ld(&g_isr_core), ld(&g_tx_irq_count),
        ld(&g_tx_enq),                           ld(&g_tx_bytes), ld(&g_tx_dropped),
        @intFromBool(g_stall_fail),              if (ok) "PASS (cross-core IRQ-driven TX)" else "FAIL",
    }) catch "";
    txqWrite(summary);
    // The summary goes through the TX ring, drained by core 1's IRQ; wait for
    // it to reach the wire before ending the run, or the exit would lose it.
    var i: u32 = 0;
    while (i < 500 and ld(&g_tx_bytes) != ld(&g_tx_enq)) : (i += 1) sysclock.sleepFor(1) catch {};

    // The summary for the runner's log, the verdict, and the semihosting
    // exit (hw_result::ok()/fail() in C++).
    semihosting.write(summary);
    uos.rtos.terminate(if (ok) 0 else 1);
}

var prod_stack: [1024]uos.port.StackElement align(8) = undefined;
var host_stack: [1024]uos.port.StackElement align(8) = undefined;
var producer_th: rtos.Thread = undefined;
var irq_host_th: rtos.Thread = undefined;

fn osMain() u8 {
    this_thread.thread().setCpuAffinity(1 << 0);

    board.led.init();
    uartInit();

    txqWrite("\n");
    txqWrite("=============================================\n");
    txqWrite("  Pico / RP2040 - micro-os-plus-iii\n");
    txqWrite("  smp-test5 : interrupt-driven UART TX\n");
    txqWrite("=============================================\n");

    txqWrite("core 0: idle1 installed; creating producer/irq_host...\n");

    producer_th.init("producer", producer, null, .{ .stack = &prod_stack }, null) catch
        @panic("cannot create the producer");
    producer_th.setCpuAffinity(1 << 0);
    irq_host_th.init("irq_host", irqHost, null, .{ .stack = &host_stack }, null) catch
        @panic("cannot create irq_host");
    irq_host_th.setCpuAffinity(1 << 1);

    txqWrite("core 0: launching core 1 (bootrom FIFO handshake)...\n");
    uos.port.launchCore1();
    txqWrite("core 0: core 1 launched; SMP running.\n");

    while (true) sysclock.sleepFor(10000) catch {};
}
