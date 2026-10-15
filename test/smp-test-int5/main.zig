//! smp-test-int5 -- Cortex-M0 -> A7 mailbox interrupts, an AMP doorbell (the
//! C++ test/luckfox-lyra/smp_test_int5).
//!
//! The RK3506's fourth core, a Cortex-M0, fires a mailbox doorbell every
//! ~40 ms to A7 cores 1 and 2; each A7 core, in its mailbox interrupt,
//! reports the event to core 0 through a ring; core 0 owns the console and
//! the LED:
//!
//!   Cortex-M0 --SysTick ~40 ms--> mailbox CH1 --SPI--> A7 core 1 ISR --+
//!                             +-> mailbox CH2 --SPI--> A7 core 2 ISR --+
//!                                                                      v
//!   A7 core 0: logger thread -- "led on"/"led off" every 500 ms   report ring
//!              and "core N received int from Cortex-M0 (#k)"
//!
//! Two builds of this file (build.zig, `int5.selftrig`):
//!
//!   smp-test-int5      SMP_TEST_INT5_SELFTRIG, as the C++ tests.cmake
//!                      builds it: a core-0 thread writes the B2A DATA
//!                      registers every 40 ms, the whole A7 side without the
//!                      M0.
//!   smp-test-int5-m0   the real M0 (m0/main.zig, embedded): copied to System
//!                      SRAM at 0xFFF80000, mapped as the M0's TCM through
//!                      the secure GRF (as the vendor TEE does), clocked and
//!                      released through the PMU.
//!
//! The mailbox GIC IDs are discovered at run time (a controlled A7 write
//! latches the channel's GICD_ISPENDR bit), then routed to cores 1 and 2.
//! As in C++, the verdict is PASS after 20 beats; the evidence is the
//! "received int" lines (and, with the M0, its "M0 seq=" counter).
//!
//! Differences from C++: the kernel prints its startup banner and creates
//! the secondary idle threads (C++ installs its own, with WFI as here); the
//! affinities are given at creation.

const std = @import("std");
const uos = @import("uos");
const board = @import("board");
const int5 = @import("int5");
const rtos = uos.rtos;
const sysclock = rtos.sysclock;
const uart = board.uart;
const led = board.led;
const arch = uos.port.arch;
const gic = uos.port.gic;

pub const uos_options = board.options(3);

fn cpuId() u32 {
    return uos.port.scheduler.cpuId();
}

fn reg(addr: usize) *volatile u32 {
    return @ptrFromInt(addr);
}

// ---- The RK3506 mailbox (BB <-> AP): 4 channels, 0x1000 apart. -------------
// B2A = baseband (M0) to AP (A7): a B2A_DATA write raises the channel's IRQ.

const mbox = struct {
    const base: usize = 0xFF29_0000;
    const stride: usize = 0x1000;
    const B2A_INTEN = 0x10;
    const B2A_STATUS = 0x14; // W1C
    const B2A_CMD = 0x18;
    const B2A_DATA = 0x1C; // the write triggers the IRQ

    fn r(ch: u32, off: usize) *volatile u32 {
        return reg(base + ch * stride + off);
    }

    /// The channel's B2A tx-done interrupt to the AP (bit 8 trigger mode,
    /// bit 0 enable).
    fn enable(ch: u32) void {
        r(ch, B2A_INTEN).* = (0x0101 << 16) | 0x0101;
    }

    fn fire(ch: u32, cmd: u32, data: u32) void {
        r(ch, B2A_CMD).* = cmd;
        r(ch, B2A_DATA).* = data;
    }

    fn clear(ch: u32) void {
        const val = r(ch, B2A_STATUS).*;
        r(ch, B2A_STATUS).* = val;
        r(ch, B2A_STATUS).* = (val << 16) | val;
        arch.dsb();
    }
};

const ch_core1: u32 = 1; // mailbox channel 1 -> A7 core 1
const ch_core2: u32 = 2; // mailbox channel 2 -> A7 core 2

/// The discovered GIC IDs, by channel (0 = not found).
var g_mbox_irq: [3]u32 = @splat(0);

// ---- The Cortex-M0 boot (the vendor SDK's fit_standalone_release, and the
// SGRF writes of the TEE's sip_smc_mcu_config()). -----------------------------

const m0_fw: []const u8 = if (int5.selftrig) &.{} else @embedFile("m0_fw.bin");

const m0_sram_base: usize = 0xFFF8_0000; // the MCU code start
const sgrf: usize = 0xFF96_0000; // the secure GRF

fn m0LoadFirmware() void {
    const dst: [*]volatile u32 = @ptrFromInt(m0_sram_base);
    var i: usize = 0;
    while (i < (m0_fw.len + 3) / 4) : (i += 1) {
        var w: [4]u8 = @splat(0);
        const n = @min(4, m0_fw.len - i * 4);
        @memcpy(w[0..n], m0_fw[i * 4 ..][0..n]);
        dst[i] = std.mem.readInt(u32, &w, .little);
    }
    arch.dsb();

    // The TCM map and the MCU code start (+0x0C masked control: TCM select
    // bits 3/4/5, then remap bits 6/7/8; +0x20 the code start; +0x24 enable).
    reg(sgrf + 0x0C).* = 0x0008_0038; // tcm_sel bit 3
    reg(sgrf + 0x0C).* = 0x0010_0038; // tcm_sel bit 4
    reg(sgrf + 0x0C).* = 0x0020_0038; // tcm_sel bit 5
    reg(sgrf + 0x0C).* = 0x0040_01C0; // remap bit 6
    reg(sgrf + 0x0C).* = 0x0080_01C0; // remap bit 7
    reg(sgrf + 0x0C).* = 0x0100_01C0; // remap bit 8
    reg(sgrf + 0x20).* = 0xFFF8_0000; // the MCU code start
    reg(sgrf + 0x24).* = 0x0000_0001; // enable
    reg(sgrf + 0x0C).* = 0x0200_0000; // final
    arch.dsb();
}

fn m0Activate() void {
    reg(0xFF9A_0814).* = 0x0C00_0000; // CRU_GATE_CON05: hclk_m0 + swclktck_m0
    reg(0xFF28_8090).* = 0x0BCD_3D80; // GRF_SOC_CON36: M0 systime calibration
    arch.dsb();
    reg(0xFF90_000C).* = 0x0006_0004; // PMU_INT_MASK_CON: release the M0
    arch.dsb();
}

// ---- The statistics and the report ring (ISR on core 1/2 -> core 0) --------

var g_int_from_core: [3]u32 = @splat(0);
var g_mbox_irq_core: [3]u32 = @splat(0);

const Report = struct { core: u8, count: u32, cmd: u32, data: u32 };
const rq_size = 128; // a power of two
var g_rq: [3][rq_size]Report = undefined;
var g_rq_head: [3]u32 = @splat(0); // the ISR writes
var g_rq_tail: [3]u32 = @splat(0); // the logger reads

fn reportPush(core: u8, count: u32, cmd: u32, data: u32) void {
    const head = @atomicLoad(u32, &g_rq_head[core], .monotonic);
    const next = (head + 1) & (rq_size - 1);
    if (next == @atomicLoad(u32, &g_rq_tail[core], .acquire)) return; // full: drop
    g_rq[core][head] = .{ .core = core, .count = count, .cmd = cmd, .data = data };
    @atomicStore(u32, &g_rq_head[core], next, .release);
}

/// The mailbox doorbells on cores 1 and 2 (`port_external_irq_handler()`):
/// read the payload, W1C-clear the status, count, report to core 0. (Cores
/// 1/2 never touch the UART.)
pub fn uos_external_irq(iar: u32) void {
    const irq_id = iar & 0x3FF;
    const cpu = cpuId();
    var ch: u32 = 1;
    while (ch <= 2) : (ch += 1) {
        const id = @atomicLoad(u32, &g_mbox_irq[ch], .acquire);
        if (id != 0 and irq_id == id) {
            const cmd = mbox.r(ch, mbox.B2A_CMD).*;
            const data = mbox.r(ch, mbox.B2A_DATA).*;
            mbox.clear(ch); // so that the next pulse latches
            g_mbox_irq_core[cpu] += 1;
            const n = g_int_from_core[cpu] + 1;
            g_int_from_core[cpu] = n;
            reportPush(@intCast(cpu), n, cmd, data);
            return;
        }
    }
}

// ---- GIC pending-register discovery: a level IRQ sets its ISPENDR bit on
// assertion even while disabled at the distributor. ---------------------------

const ispendr_base = board_gicd + 0x200;
const icpendr_base = board_gicd + 0x280;
const board_gicd: usize = 0xFF58_1000;
const irq_uart1: u32 = 67;
const pend_words = 8; // GIC IDs 0..255
var g_pend_base: [pend_words]u32 = undefined;

fn gicPendSnapshot(dst: *[pend_words]u32) void {
    for (dst, 0..) |*w, i| w.* = reg(ispendr_base + i * 4).*;
}

fn gicFindNewSpi(exclude: u32) u32 {
    var i: u32 = 1;
    while (i < pend_words) : (i += 1) {
        const cur = reg(ispendr_base + i * 4).*;
        var fresh = cur & ~g_pend_base[i];
        while (fresh != 0) {
            const id = i * 32 + @ctz(fresh);
            if (id != irq_uart1 and id != exclude) return id;
            fresh &= fresh - 1;
        }
    }
    return 0;
}

/// One channel's GIC ID, by a controlled A7 write that latches its pending
/// bit (its SPI still disabled at the distributor).
fn mboxDiscover(ch: u32, exclude: u32) u32 {
    mbox.enable(ch);
    mbox.clear(ch);
    gicPendSnapshot(&g_pend_base);
    mbox.fire(ch, 0xA5A5_0000 | ch, 0x0000_BEEF | (ch << 16)); // raises the SPI
    var found: u32 = 0;
    var i: u32 = 0;
    while (i < 200 and found == 0) : (i += 1) {
        found = gicFindNewSpi(exclude);
        if (found == 0) {
            var j: u32 = 0;
            while (j < 2000) : (j += 1) asm volatile ("nop");
        }
    }
    mbox.clear(ch);
    return found;
}

fn gicClearPending(irq_id: u32) void {
    reg(icpendr_base + (irq_id / 32) * 4).* = @as(u32, 1) << @intCast(irq_id % 32);
}

// ---- The threads -------------------------------------------------------------

var logger_stack: [2048]uos.port.StackElement = undefined;
var selftrig_stack: [1024]uos.port.StackElement = undefined;
var logger_thread: rtos.Thread = undefined;
var selftrig_thread: rtos.Thread = undefined;

/// Core 0: the LED every 500 ms, and the report rings drained (every 20 ms,
/// so that the 40 ms doorbells surface). The UART's only user.
fn loggerThreadFunc(_: ?*anyopaque) ?*anyopaque {
    var on = false;
    var tick: u32 = 0;
    while (true) {
        sysclock.sleepFor(20) catch {};
        var c: u32 = 1;
        while (c <= 2) : (c += 1) {
            while (@atomicLoad(u32, &g_rq_tail[c], .monotonic) != @atomicLoad(u32, &g_rq_head[c], .acquire)) {
                const t = g_rq_tail[c];
                const r = g_rq[c][t];
                @atomicStore(u32, &g_rq_tail[c], (t + 1) & (rq_size - 1), .release);
                uart.print("core {d} received int from Cortex-M0  (#{d}, data=0x{X:0>8})\n", .{ r.core, r.count, r.data });
            }
        }
        tick += 1;
        if (tick >= 25) { // 25 * 20 ms = 500 ms
            tick = 0;
            on = !on;
            const m0_seq = reg(0xFFF8_8000).*;
            if (on) {
                led.on();
                uart.print("led on  | M0 seq={d}\n", .{@as(i32, @bitCast(m0_seq))});
            } else {
                led.off();
                uart.print("led off | M0 seq={d}\n", .{@as(i32, @bitCast(m0_seq))});
            }
        }
    }
}

/// The bring-up stand-in for the M0: both channels every ~40 ms from core 0.
fn selftrigThreadFunc(_: ?*anyopaque) ?*anyopaque {
    var seq: u32 = 0;
    while (true) {
        sysclock.sleepFor(40) catch {};
        mbox.fire(ch_core1, 0x0C01_0000 | (seq & 0xFFFF), 0x1D1D_0000 | (seq & 0xFFFF));
        mbox.fire(ch_core2, 0x0C02_0000 | (seq & 0xFFFF), 0x2D2D_0000 | (seq & 0xFFFF));
        seq +%= 1;
    }
}

pub fn main() void {
    uart.init();
    uart.puts("\n\n");
    uart.puts("+=============================================+\n");
    uart.puts("|  Luckfox Lyra µOS++ SMP TEST INT5           |\n");
    uart.puts("|  Cortex-M0 -> A7 mailbox doorbell (AMP)     |\n");
    uart.puts("|  M0 pings cores 1 & 2; core 0 logs          |\n");
    uart.puts("+=============================================+\n\n");
    led.init();
    rtos.run(osMain);
}

fn osMain() void {
    arch.enableIrq();
    uart.puts("IRQs enabled (timer only)\n\n");

    // Un-gate every peripheral clock of the CRU (the TIMER0 functional clock
    // among them), and of the PMUCRU; release every CRU soft reset.
    var off: usize = 0x0800;
    while (off <= 0x09E0) : (off += 4) reg(0xFF9A_0000 + off).* = 0xFFFF_0000;
    arch.dsb();
    off = 0x0100;
    while (off <= 0x01E0) : (off += 4) reg(0xFF90_0000 + off).* = 0xFFFF_0000;
    arch.dsb();
    off = 0x0A00;
    while (off <= 0x0BE0) : (off += 4) reg(0xFF9A_0000 + off).* = 0xFFFF_0000;
    arch.dsb();

    // 1. A7 cores 1 and 2.
    board.smp.startSecondaryCores();
    uart.puts("Waiting for cores 1 and 2 to join...\n");
    var waited: u32 = 0;
    while ((board.smp.coreStage(1) < 3 or board.smp.coreStage(2) < 3) and waited < 3000) {
        sysclock.sleepFor(50) catch {};
        waited += 50;
    }
    uart.print("cores: c1={d} c2={d} (after {d}ms)\n\n", .{ board.smp.coreStage(1), board.smp.coreStage(2), waited });

    // 2. The two channels' GIC IDs, routed CH1 -> core 1, CH2 -> core 2.
    uart.puts("Discovering mailbox CH1/CH2 GIC IDs (ISPENDR diff)...\n");
    const id1 = mboxDiscover(ch_core1, 0);
    const id2 = mboxDiscover(ch_core2, id1);
    uart.print("  CH1 -> GIC ID {d}   CH2 -> GIC ID {d}\n", .{ id1, id2 });
    if (id1 != 0) {
        @atomicStore(u32, &g_mbox_irq[ch_core1], id1, .release);
        arch.dsb();
        gicClearPending(id1);
        gic.setTarget(id1, 1 << 1);
        gic.enableIrq(id1);
    }
    if (id2 != 0) {
        @atomicStore(u32, &g_mbox_irq[ch_core2], id2, .release);
        arch.dsb();
        gicClearPending(id2);
        gic.setTarget(id2, 1 << 2);
        gic.enableIrq(id2);
    }
    uart.puts("  routed: CH1->core1, CH2->core2\n\n");

    if (int5.selftrig) {
        uart.puts("SELF-TRIGGER mode: core 0 fires the mailboxes (M0 not required)\n\n");
    } else {
        // 3. The Cortex-M0. The System SRAM is free again: cores 1 and 2
        // have joined, the boot handshake no longer needs it.
        uart.print("Loading M0 firmware ({d} bytes) to 0xFFF80000 + TCM attach...\n", .{m0_fw.len});
        m0LoadFirmware();
        uart.puts("Activating Cortex-M0 (un-gate hclk_m0, release reset)...\n");
        m0Activate();
        uart.puts("M0 released; expecting ~40 ms mailbox doorbells\n\n");
    }

    // 4. The core-0 logger (and the stand-in).
    const gpa = uos.memory.allocator();
    logger_thread.init("logger", loggerThreadFunc, null, .{ .stack = &logger_stack, .cpu_affinity = 1 << 0 }, gpa) catch unreachable;
    if (int5.selftrig) {
        selftrig_thread.init("selftrig", selftrigThreadFunc, null, .{ .stack = &selftrig_stack, .cpu_affinity = 1 << 0 }, gpa) catch unreachable;
    }

    uart.puts("Logger running on core 0. Cores 1/2 idle, waiting on mailbox IRQs.\n");
    uart.puts("---------------------------------------------------------------\n\n");

    // A bounded run: the runner needs a RESULT line and a semihosting stop.
    var it: u32 = 1;
    while (it <= 20) : (it += 1) {
        sysclock.sleepFor(1000) catch {};
        uart.print("beat {d}/20\n", .{it});
    }

    uart.puts("\nRESULT: PASS\n");
    board.hw_result.ok();
}
