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

/// The clocks are set by the HAL before `main()`.
pub fn init() void {
    led.init();
}

pub fn cpuFrequencyHz() u32 {
    return comptime hal.clock_config.get_frequency(.clk_sys).?;
}
