//! exc-test -- bare M33 exception-entry probe (no RTOS).
//!
//! The Zig port of test/pico2/exc-test/main.cpp, line for line.
//!
//! Isolates the RP2350's first-exception behaviour: arm SysTick and PendSV
//! with trivial handlers and report whether their exception ENTRY works at
//! all.
//!
//! Two phases:
//!   Phase A -- thread mode using MSP (SPSEL=0): arm SysTick, count ticks.
//!   Phase B -- switch to PSP (SPSEL=1) like the RTOS start(): arm PendSV.
//! This tells whether any non-HardFault entry works, and whether the PSP
//! stack mode matters.
//!
//! One deviation, on purpose: phase B gives handler mode its own MSP stack
//! after switching thread mode to the PSP, as the RTOS start() does. The C++
//! test leaves MSP == PSP, so an exception frame stacked on the PSP is under
//! the handler's own MSP stack; it passes only because its handlers compile
//! to leaf code that never touches the stack (`ldr/adds/str/bx lr`). The Zig
//! handlers push {r7, lr}, which overwrites the frame and faults the return
//! (UsageFault INVPC, measured).
//!
//! The test installs its own SysTick/PendSV/HardFault/UsageFault handlers
//! (its own `microzig_options`), not the port's. The vector table is where
//! MicroZig put it, so the two vectors are read through VTOR rather than at
//! the C++ image's fixed 0x1000003C/0x10000040.

const std = @import("std");
const microzig = @import("microzig");
const uos = @import("uos");
const board = @import("uos_board");

const uart = board.uart;
const arch = uos.port.arch;
const semihosting = uos.port.semihosting;

pub const microzig_options: microzig.Options = blk: {
    var o: microzig.Options = .{
        .overwrite_hal_interrupts = true,
        .cpu = .{ .verbose_unhandled_irq = false },
    };
    o.interrupts.SysTick = .{ .c = sysTickHandler };
    o.interrupts.PendSV = .{ .c = pendSvHandler };
    o.interrupts.HardFault = .{ .c = hardFaultHandler };
    o.interrupts.UsageFault = .{ .c = usageFaultHandler };
    break :blk o;
};

comptime {
    microzig.export_startup();
}

/// Handler-mode (MSP) stack for phase B.
var handler_stack: [256]u32 align(8) = undefined;

var g_systick: u32 = 0;
var g_pendsv: u32 = 0;
var g_stage: u32 = 0;

fn ld(p: *u32) u32 {
    return @atomicLoad(u32, p, .acquire);
}

fn printHex32(v: u32) void {
    var buf: [8]u8 = undefined;
    for (0..8) |i| {
        const d: u8 = @truncate((v >> @intCast((7 - i) * 4)) & 0xF);
        buf[i] = if (d < 10) '0' + d else 'a' + d - 10;
    }
    uart.write(&buf);
}

fn report() void {
    uart.write("stage=0x");
    printHex32(ld(&g_stage));
    uart.write(" systick=0x");
    printHex32(ld(&g_systick));
    uart.write(" pendsv=0x");
    printHex32(ld(&g_pendsv));
    uart.write("\n");
}

fn hardFaultHandler() callconv(.c) void {
    uart.write("\n!! HARDFAULT (exc-test)\n");
    report();
    while (true) {}
}

fn sysTickHandler() callconv(.c) void {
    @atomicStore(u32, &g_systick, g_systick + 1, .release);
}

fn pendSvHandler() callconv(.c) void {
    @atomicStore(u32, &g_pendsv, g_pendsv + 1, .release);
}

fn usageFaultHandler() callconv(.c) void {
    uart.write("\n!! USAGEFAULT (exc-test)\n");
    report();
    while (true) {}
}

fn spin(n: u32) void {
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        std.mem.doNotOptimizeAway(&i);
        asm volatile ("nop");
    }
}

fn reg(addr: usize) *volatile u32 {
    return @ptrFromInt(addr);
}

pub fn main() void {
    uart.init();

    uart.write("\n=============================================\n");
    uart.write("  exc-test : M33 exception-entry probe (RP2350B)\n");
    uart.write("=============================================\n");
    const vtor = arch.scs.VTOR.*;
    uart.write("VTOR=0x");
    printHex32(vtor);
    uart.write("\nvec[3c]=0x");
    printHex32(reg(vtor + 0x3C).*);
    uart.write("\nvec[40]=0x");
    printHex32(reg(vtor + 0x40).*);
    uart.write("\n");

    // ---- Phase A: MSP thread mode, arm SysTick -----------------------------
    @atomicStore(u32, &g_stage, 1, .release);
    arch.sysTickConfig(150000);
    arch.setPendSvSysTickLowest();
    arch.enableIrq();
    uart.write("[A] SysTick armed (MSP mode)\n");

    spin(1000000);
    @atomicStore(u32, &g_stage, 2, .release);
    report();

    // ---- Phase B: switch to PSP (like the RTOS), arm PendSV ----------------
    // Thread mode moves to the PSP (same address, so the running code is
    // undisturbed); handler mode then gets its own MSP stack.
    asm volatile (
        \\ mrs r0, msp
        \\ msr psp, r0
        \\ movs r0, #2
        \\ msr control, r0
        \\ isb
        \\ msr msp, %[top]
        \\ isb
        :
        : [top] "r" (@intFromPtr(&handler_stack) + @sizeOf(@TypeOf(handler_stack))),
        : .{ .r0 = true, .memory = true });

    @atomicStore(u32, &g_stage, 3, .release);
    arch.scs.ICSR.* = arch.scs.ICSR_PENDSVSET; // PendSV pending
    uart.write("[B] PENDSVSET set (PSP mode); pendsv should become 1\n");

    // Bounded run so the hardware runner gets a verdict: the point of the
    // probe is that BOTH exception entries actually ran.
    const iterations = 20;
    for (0..iterations) |_| {
        spin(2000000);
        @atomicStore(u32, &g_stage, 4, .release);
        report();
    }

    const ok = ld(&g_systick) != 0 and ld(&g_pendsv) != 0;
    uart.write("\nexception entry : ");
    uart.write(if (ok) "PASS" else "FAIL");
    uart.write("\n");
    uart.write(if (ok) "RESULT: PASS\n" else "RESULT: FAIL\n");
    // Also on the debug channel, which is what the hardware runner greps.
    var b: [96]u8 = undefined;
    semihosting.write(std.fmt.bufPrint(&b, "systick={d} pendsv={d}\n", .{ ld(&g_systick), ld(&g_pendsv) }) catch "");
    semihosting.write(if (ok) "RESULT: PASS\n" else "RESULT: FAIL\n");

    semihosting.exit(if (ok) 0 else 1);
}
