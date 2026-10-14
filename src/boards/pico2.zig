//! Raspberry Pi Pico 2: RP2350, 2x Cortex-M33 (SMP), 150 MHz from the
//! 12 MHz crystal (MicroZig's HAL clock preset); LED on GPIO25; trace and
//! verdict over semihosting (the Raspberry Pi Debug Probe).

const microzig = @import("microzig");
const hal = microzig.hal;

pub const name = "Raspberry Pi Pico 2 (RP2350, 2x Cortex-M33)";
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

/// The console: UART0, TX on GPIO0, RX on GPIO1, 115200 8N1.
pub const uart = struct {
    const instance = hal.uart.instance.num(0);
    var ready = false;

    pub fn init() void {
        hal.gpio.num(0).set_function(.uart);
        hal.gpio.num(1).set_function(.uart);
        instance.apply(.{ .clock_config = hal.clock_config, .baud_rate = 115200 });
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

pub fn cpuFrequencyHz() u32 {
    return comptime hal.clock_config.get_frequency(.clk_sys).?;
}
