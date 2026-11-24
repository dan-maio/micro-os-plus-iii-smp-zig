//! ST Nucleo-F411RE: STM32F411RE, Cortex-M4F, 1 CPU, on the reset HSI
//! (16 MHz), as the C++ board (its `SystemInit()` leaves the core on HSI);
//! LED LD2 on PA5 (active high); console on USART2 PA2/PA3 115200 8N1, the
//! ST-Link's virtual COM port, interrupt driven; the trace is mirrored to
//! semihosting through the integrated ST-Link.
//!
//! The console transmitter is buffered: a polled UART line takes real time
//! (12 characters, about 1 ms at 115200), and rtos-apis prints from a 1 ms
//! periodic timer callback; polled, the timer was always overdue and the
//! threads starved. Semihosting costs no tick time: the core and SysTick are
//! halted while OpenOCD serves the call.

const microzig = @import("microzig");
const f4 = @import("stm32f4.zig");

pub const name = "ST Nucleo-F411RE (STM32F411RE, Cortex-M4F)";
pub const ncpu = 1;

pub const led = f4.Led(0, 5, false);

/// The USART2 transmit interrupt.
pub const interrupts = .{ .USART2 = microzig.interrupt.Handler{ .c = f4.usart2.irq } };

pub fn init() void {
    led.init();
    f4.usart2.init(115200);
}

/// The console: USART2, TX on PA2, RX on PA3, 115200 8N1 (the ST-Link
/// virtual COM port; the port mirrors the trace to semihosting).
pub fn uartWrite(bytes: []const u8) void {
    f4.usart2.write(bytes);
}

/// Everything sent (the ring drained by polling); `terminate()` calls it
/// with the interrupts masked.
pub fn uartFlush() void {
    f4.usart2.flush();
}

pub fn cpuFrequencyHz() u32 {
    return f4.cpu_frequency_hz;
}
