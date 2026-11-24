//! RP2350 12-bit SAR ADC driver, bare register: the C++
//! test/boards/pico2/glue/adc.cpp, line for line. Un-reset the ADC, set
//! CS.EN and wait for CS.READY, then per conversion write AINSEL +
//! START_ONCE and poll READY. clk_adc must already be running
//! (`rp2350_clocks.adcClkInit()`).

const RESETS_BASE: usize = 0x4002_0000;
const ADC_BASE: usize = 0x400A_0000;
const PADS_BANK0_BASE: usize = 0x4003_8000;

const ADC_CS = 0x00;
const ADC_RESULT = 0x04;
const CS_EN: u32 = 1 << 0;
const CS_START_ONCE: u32 = 1 << 2;
const CS_READY: u32 = 1 << 8;
const CS_AINSEL_LSB: u5 = 12;
const CS_AINSEL_BITS: u32 = 0xF000;
const RESETS_RESET = 0x00;
const RESETS_DONE = 0x08;
const RESET_ADC: u32 = 1 << 0;
const PAD_IE: u32 = 1 << 6;
const PAD_OD: u32 = 1 << 7;

/// The potentiometer: GPIO40, ADC channel 0 on the RP2350B.
pub const pot_pin: u32 = 40;
pub const pot_channel: u32 = 0;

fn reg(a: usize) *volatile u32 {
    return @ptrFromInt(a);
}

pub fn init() void {
    reg(RESETS_BASE + RESETS_RESET).* &= ~RESET_ADC;
    while (reg(RESETS_BASE + RESETS_DONE).* & RESET_ADC == 0) {}
    reg(ADC_BASE + ADC_CS).* = CS_EN;
    while (reg(ADC_BASE + ADC_CS).* & CS_READY == 0) {}
}

/// Isolate the digital pad so the analog input is clean: IE = 0, OD = 1.
pub fn gpioInit(gpio: u32) void {
    const pad = PADS_BANK0_BASE + 0x04 + gpio * 4;
    reg(pad).* = (reg(pad).* & ~PAD_IE) | PAD_OD;
}

pub fn read(channel: u32) u16 {
    const b = ADC_BASE;
    reg(b + ADC_CS).* = (reg(b + ADC_CS).* & ~CS_AINSEL_BITS) | CS_EN |
        ((channel << CS_AINSEL_LSB) & CS_AINSEL_BITS) | CS_START_ONCE;
    while (reg(b + ADC_CS).* & CS_READY == 0) {}
    return @intCast(reg(b + ADC_RESULT).* & 0x0FFF);
}
