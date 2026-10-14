//! WeAct Studio "Black Pill" STM32F411CE: Cortex-M4F, 1 CPU, 25 MHz HSE,
//! 100 MHz; LED on PC13 (active low); trace on USART1 PA9/PA10 115200 8N1,
//! mirrored with the verdict to semihosting (CMSIS-DAP, e.g. a WCH-Link in
//! ARM mode).

const f4 = @import("stm32f4.zig");

pub const name = "WeAct F411CE (STM32F411CE, Cortex-M4F)";
pub const ncpu = 1;

pub const led = f4.Led(2, 13, true);

pub fn init() void {
    f4.initClocks(.{ .hse_hz = 25_000_000, .m = 25, .n = 200, .p = 2, .q = 4, .flash_wait_states = 3 });
    led.init();
    f4.usart1.init(115200);
}

/// The console: USART1, TX on PA9, RX on PA10, 115200 8N1 (the port
/// mirrors the trace to semihosting).
pub fn uartWrite(bytes: []const u8) void {
    f4.usart1.write(bytes);
}

pub fn cpuFrequencyHz() u32 {
    return f4.cpu_frequency_hz;
}
