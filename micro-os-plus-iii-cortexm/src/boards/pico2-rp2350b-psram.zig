//! WeAct RP2350B core board, 16 MB flash + 8 MB PSRAM: RP2350B (QFN-80),
//! 2x Cortex-M33 (SMP), 150 MHz from the 12 MHz crystal (MicroZig's HAL
//! clock preset, the Adafruit Metro RP2350 target: RP2350B, 16 MB flash);
//! LED on GPIO25; console on UART0, TX GPIO12, RX GPIO13 (the C++ board's
//! PICO2_UART_TX_PIN / RX_PIN); trace mirrored to semihosting (a CMSIS-DAP,
//! c251:f001). The C++ test/boards/pico2-rp2350b-psram.

const microzig = @import("microzig");

/// The 8 MB QSPI PSRAM (XIP window 1, CS1 on GPIO0); the tests that use it
/// call `psram.init()`.
pub const psram = @import("rp2350_psram.zig");
/// The from-scratch clock table (the smp-test-nested-clock tests).
pub const clocks = @import("rp2350_clocks.zig");
/// The ADC (the potentiometer on GPIO40).
pub const adc = @import("rp2350_adc.zig");

/// clk_sys = clk_peri, in Hz: MicroZig's 150 MHz preset, until a test
/// reprograms the clocks (`setCpuFrequency()`).
var cpu_hz: u32 = hal.clock_config.get_frequency(.clk_sys).?;
const hal = microzig.hal;

pub const name = "WeAct RP2350B (16 MB flash + 8 MB PSRAM, 2x Cortex-M33)";
pub const ncpu = 2;

const led_pin = hal.gpio.num(25);

pub const led = struct {
    pub fn init() void {
        led_pin.set_function(.sio);
        led_pin.set_direction(.out);
        led_pin.put(0);
    }
    pub fn set(on: bool) void {
        led_pin.put(@intFromBool(on));
    }
    pub fn toggle() void {
        led_pin.toggle();
    }
};

/// The console: UART0, TX on GPIO12, RX on GPIO13, 115200 8N1.
pub const uart = struct {
    const instance = hal.uart.instance.num(0);
    var ready = false;

    pub fn init() void {
        hal.gpio.num(12).set_function(.uart);
        hal.gpio.num(13).set_function(.uart);
        instance.apply(.{ .clock_config = hal.clock_config, .baud_rate = 115200 });
        // The divisors from the RUN-TIME clk_peri: `board.init()` runs in the
        // scheduler's start-up, after a test may have reprogrammed the clocks
        // (the smp-test-nested-clock tests); MicroZig's are for its 150 MHz.
        setBaud(115200);
        ready = true;
    }

    pub fn write(bytes: []const u8) void {
        if (!ready) return;
        for (bytes) |c| {
            if (c == '\n') put('\r');
            put(c);
        }
    }

    fn put(c: u8) void {
        while (!instance.is_writeable()) {}
        instance.get_regs().UARTDR.write_raw(c);
    }

    /// Recompute the PL011 baud divisors from the current clk_peri (after
    /// a clock change): the pico-sdk's formula.
    pub fn setBaud(baud: u32) void {
        const regs = instance.get_regs();
        const div: u32 = @intCast((8 * @as(u64, cpu_hz)) / baud);
        var ibrd: u32 = div >> 7;
        var fbrd: u32 = ((div & 0x7f) + 1) / 2;
        if (ibrd == 0) {
            ibrd = 1;
            fbrd = 0;
        } else if (ibrd >= 65535) {
            ibrd = 65535;
            fbrd = 0;
        }
        regs.UARTIBRD.write_raw(ibrd);
        regs.UARTFBRD.write_raw(fbrd);
        // The divisors latch on a write of the line control register.
        regs.UARTLCR_H.write_raw(regs.UARTLCR_H.raw);
    }

    /// Wait until the last byte left the pin (not BUSY).
    pub fn flush() void {
        if (!ready) return;
        while (instance.get_regs().UARTFR.read().BUSY == 1) {}
    }

    pub fn getChar() ?u8 {
        if (!ready) return null;
        if (!instance.is_readable()) return null;
        return instance.get_regs().UARTDR.read().DATA;
    }
};

/// The clocks are set by the HAL before `main()`.
pub fn init() void {
    led.init();
    uart.init();
}

/// The trace goes to the UART console (the port mirrors it to semihosting).
pub fn uartWrite(bytes: []const u8) void {
    uart.write(bytes);
}

pub fn uartFlush() void {
    uart.flush();
}

pub fn cpuFrequencyHz() u32 {
    return cpu_hz;
}

/// Record a new clk_sys (= clk_peri) and set the console's baud divisors
/// from it; the scheduler's SysTick, started later, uses it too.
pub fn setCpuFrequency(hz: u32) void {
    cpu_hz = hz;
    uart.setBaud(115200);
}
