//! smp-test0 (Pico / RP2040) -- Phase 1: bare bring-up, no RTOS.
//!
//! The Zig port of test/pico/smp-test0/main.cpp, line for line:
//!
//!   - clocks (125 MHz, the HAL preset) and UART0 (GPIO0=TX, GPIO1=RX,
//!     115200 8N1);
//!   - the banner and the board facts on the UART;
//!   - core 1 launched through the bootrom FIFO handshake; it proves it ran
//!     (`core1_alive = 0xC0FFEE`) and blinks the LED (GPIO25, 300 ms on,
//!     300 ms off), counting its loops;
//!   - core 0 prints 20 ticks, ~500 ms apart, with core 1's counters;
//!   - RESULT: PASS when core 1 came up and looped, on the UART and on the
//!     semihosting channel the runner reads, then semihosting SYS_EXIT.
//!
//! Zig has no static constructors: the "static ctor" line checks the
//! equivalent start-up step, the initialised-data copy (`.data`).

const std = @import("std");
const microzig = @import("microzig");
const uos = @import("uos");
const board = @import("uos_board");

const hal = microzig.hal;
const uart = board.uart;
const semihosting = uos.port.semihosting;

pub const microzig_options = uos.port.microzig_options;

comptime {
    microzig.export_startup();
}

/// Set by the `.data` initialisation; the C++ test's constructor probe.
var g_ctor_probe_ran: bool = true;

var core1_stack: [512]u32 align(16) = undefined;

var g_core1_alive: u32 = 0;
var g_core1_loops: u32 = 0;

fn core1Entry() void {
    @atomicStore(u32, &g_core1_alive, 0xC0FFEE, .release); // FIRST thing: prove we ran
    board.led.init();
    while (true) {
        board.led.set(true);
        hal.time.sleep_ms(300);
        board.led.set(false);
        hal.time.sleep_ms(300);
        @atomicStore(u32, &g_core1_loops, g_core1_loops + 1, .release);
    }
}

fn printHex32(v: u32) void {
    var buf: [8]u8 = undefined;
    for (0..8) |i| {
        const d: u8 = @truncate((v >> @intCast((7 - i) * 4)) & 0xF);
        buf[i] = if (d < 10) '0' + d else 'a' + d - 10;
    }
    uart.write(&buf);
}

pub fn main() void {
    uart.init();

    uart.write("\n");
    uart.write("=============================================\n");
    uart.write("  Pico / RP2040 - micro-os-plus-iii port\n");
    uart.write("  smp-test0 : Phase 1 bare bring-up\n");
    uart.write("=============================================\n");

    uart.write("core id        : ");
    uart.write(&.{'0' + @as(u8, @intCast(hal.get_cpu_id()))});
    uart.write("\n");
    uart.write("static ctor    : ");
    uart.write(if (g_ctor_probe_ran) "RAN" else "NOT RUN");
    uart.write("\n");
    uart.write("system clock   : 125 MHz\n");
    uart.write("UART0          : 115200 8N1 (GPIO0=TX, GPIO1=RX)\n");

    uart.write("\nlaunching core 1 (LED blink)...\n");
    hal.multicore.launch_core1_with_stack(core1Entry, &core1_stack);
    uart.write("core 1 launch returned.\n\n");

    // A bounded run so the hardware runner gets a verdict: 20 ticks of
    // ~500 ms (about 10 s), then check that core 1 really came up.
    const iterations = 20;
    for (0..iterations) |tick| {
        uart.write("[core0] tick 0x");
        printHex32(@intCast(tick));
        uart.write("  core1_alive=0x");
        printHex32(@atomicLoad(u32, &g_core1_alive, .acquire));
        uart.write("  core1_loops=0x");
        printHex32(@atomicLoad(u32, &g_core1_loops, .acquire));
        uart.write("\n");
        hal.time.sleep_ms(500);
    }

    const ok = @atomicLoad(u32, &g_core1_alive, .acquire) == 0xC0FFEE and
        @atomicLoad(u32, &g_core1_loops, .acquire) != 0;
    uart.write("\ncore 1 launch  : ");
    uart.write(if (ok) "PASS" else "FAIL");
    uart.write("\n");
    uart.write(if (ok) "RESULT: PASS\n" else "RESULT: FAIL\n");
    // Also on the debug channel, which is what the hardware runner greps.
    semihosting.write(if (ok) "RESULT: PASS\n" else "RESULT: FAIL\n");

    // Ends the run with a semihosting SYS_EXIT carrying the verdict.
    semihosting.exit(if (ok) 0 else 1);
}
