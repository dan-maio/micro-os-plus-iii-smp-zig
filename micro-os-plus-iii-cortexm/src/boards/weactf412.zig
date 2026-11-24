//! WeAct STM32F412RE core board: Cortex-M4F, 1 CPU, 8 MHz HSE -> PLL ->
//! 100 MHz (AHB /1, APB1 /2, APB2 /1), falling back to the reset HSI as the
//! C++ board does; LED on PB2 (active high); console on USART1 PA9/PA10
//! 115200 8N1, interrupt-driven reception and DMA transmission (the C++
//! board's uart.cpp, `stm32f4_uart_dma.zig`), the trace mirrored to
//! semihosting.

const microzig = @import("microzig");
const f4 = @import("stm32f4.zig");
pub const uart = @import("stm32f4_uart_dma.zig");

pub const name = "WeAct F412RE (STM32F412RE, Cortex-M4F)";
pub const ncpu = 1;

pub const led = f4.Led(1, 2, false);

/// The USART1 receive and DMA2 Stream7 transmit-complete interrupts.
pub const interrupts = .{
    .USART1 = microzig.interrupt.Handler{ .c = uart.usart1Handler },
    .DMA2_Stream7 = microzig.interrupt.Handler{ .c = uart.dma2Stream7Handler },
};

pub fn init() void {
    // HSE 8 MHz / 8 * 200 / 2 = 100 MHz; 3 wait states.
    f4.initClocks(.{ .hse_hz = 8_000_000, .m = 8, .n = 200, .p = 2, .q = 4, .flash_wait_states = 3 });
    led.init();
    uart.init(115200, f4.cpu_frequency_hz); // APB2 = SYSCLK
}

/// The trace console: USART1 through the DMA ring, never blocking.
pub fn uartWrite(bytes: []const u8) void {
    uart.traceWrite(bytes);
}

/// Everything sent, by polling; `terminate()` calls it with the interrupts
/// masked.
pub fn uartFlush() void {
    uart.flush();
}

pub fn cpuFrequencyHz() u32 {
    return f4.cpu_frequency_hz;
}
