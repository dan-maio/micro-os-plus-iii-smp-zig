//! STM32F4 clock bring-up shared by the F411/F412 boards: HSE -> PLL with
//! bounded waits. Every failure leaves the core on the reset HSI (16 MHz),
//! and `cpu_frequency_hz` reports what is actually running.

const RCC_CR: *volatile u32 = @ptrFromInt(0x4002_3800);
const RCC_PLLCFGR: *volatile u32 = @ptrFromInt(0x4002_3804);
const RCC_CFGR: *volatile u32 = @ptrFromInt(0x4002_3808);
const RCC_AHB1ENR: *volatile u32 = @ptrFromInt(0x4002_3830);
const RCC_APB2ENR: *volatile u32 = @ptrFromInt(0x4002_3844);
const FLASH_ACR: *volatile u32 = @ptrFromInt(0x4002_3C00);

const CR_HSEON: u32 = 1 << 16;
const CR_HSERDY: u32 = 1 << 17;
const CR_PLLON: u32 = 1 << 24;
const CR_PLLRDY: u32 = 1 << 25;

pub var cpu_frequency_hz: u32 = 16_000_000;

fn waitForBit(reg: *volatile u32, mask: u32) bool {
    for (0..16) |_| {
        if (reg.* & mask != 0) return true;
        var spin: u32 = 0;
        while (spin < 20_000) : (spin += 1) asm volatile ("" ::: .{ .memory = true });
    }
    return reg.* & mask != 0;
}

pub const PllConfig = struct {
    hse_hz: u32,
    m: u32,
    n: u32,
    /// The P divider (2, 4, 6, 8).
    p: u32,
    q: u32,
    flash_wait_states: u32,
};

/// Switch the system clock to the PLL fed by the HSE crystal.
/// AHB /1, APB1 /2, APB2 /1.
pub fn initClocks(comptime cfg: PllConfig) void {
    // Flash wait states, prefetch, instruction and data caches.
    FLASH_ACR.* = (FLASH_ACR.* & ~@as(u32, 0xF)) | cfg.flash_wait_states | (1 << 8) | (1 << 9) | (1 << 10);

    RCC_CR.* |= CR_HSEON;
    if (!waitForBit(RCC_CR, CR_HSERDY)) return;

    RCC_PLLCFGR.* = cfg.m | (cfg.n << 6) | (((cfg.p / 2) - 1) << 16) | (1 << 22) | (cfg.q << 24);
    RCC_CR.* |= CR_PLLON;
    if (!waitForBit(RCC_CR, CR_PLLRDY)) return;

    // HPRE /1, PPRE1 /2 (0b100), PPRE2 /1.
    RCC_CFGR.* = (RCC_CFGR.* & ~@as(u32, 0xFCF0)) | (0b100 << 10);
    RCC_CFGR.* = (RCC_CFGR.* & ~@as(u32, 0b11)) | 0b10;
    if (!waitForBit(RCC_CFGR, 0b10 << 2)) return;

    cpu_frequency_hz = cfg.hse_hz / cfg.m * cfg.n / cfg.p;
}

/// A polled USART1 console on PA9 (TX) / PA10 (RX), AF7.
pub const usart1 = struct {
    const GPIOA_MODER: *volatile u32 = @ptrFromInt(0x4002_0000);
    const GPIOA_OSPEEDR: *volatile u32 = @ptrFromInt(0x4002_0008);
    const GPIOA_AFRH: *volatile u32 = @ptrFromInt(0x4002_0024);
    const SR: *volatile u32 = @ptrFromInt(0x4001_1000);
    const DR: *volatile u32 = @ptrFromInt(0x4001_1004);
    const BRR: *volatile u32 = @ptrFromInt(0x4001_1008);
    const CR1: *volatile u32 = @ptrFromInt(0x4001_100C);

    var ready = false;

    pub fn init(baud: u32) void {
        RCC_AHB1ENR.* |= 1 << 0; // GPIOA
        RCC_APB2ENR.* |= 1 << 4; // USART1
        inline for (.{ 9, 10 }) |pin| {
            GPIOA_MODER.* = (GPIOA_MODER.* & ~(@as(u32, 3) << (pin * 2))) | (@as(u32, 2) << (pin * 2));
            GPIOA_OSPEEDR.* |= @as(u32, 3) << (pin * 2);
            GPIOA_AFRH.* = (GPIOA_AFRH.* & ~(@as(u32, 0xF) << ((pin - 8) * 4))) | (@as(u32, 7) << ((pin - 8) * 4));
        }
        CR1.* = 0;
        BRR.* = (cpu_frequency_hz + baud / 2) / baud; // APB2 = SYSCLK
        CR1.* = (1 << 3) | (1 << 2) | (1 << 13); // TE, RE, UE
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
        while (SR.* & (1 << 7) == 0) {}
        DR.* = c;
    }
};

/// The board LED on a GPIO pin (active low on the WeAct boards).
pub fn Led(comptime port_index: u32, comptime pin: u5, comptime active_low: bool) type {
    return struct {
        const base: usize = 0x4002_0000 + 0x400 * port_index;
        const MODER: *volatile u32 = @ptrFromInt(base + 0x00);
        const ODR: *volatile u32 = @ptrFromInt(base + 0x14);

        pub fn init() void {
            RCC_AHB1ENR.* |= @as(u32, 1) << @intCast(port_index);
            MODER.* = (MODER.* & ~(@as(u32, 3) << (@as(u5, pin) * 2))) | (@as(u32, 1) << (@as(u5, pin) * 2));
            set(false);
        }

        pub fn set(on: bool) void {
            if (on != active_low) ODR.* |= @as(u32, 1) << pin else ODR.* &= ~(@as(u32, 1) << pin);
        }

        pub fn toggle() void {
            ODR.* ^= @as(u32, 1) << pin;
        }
    };
}
