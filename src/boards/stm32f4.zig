//! STM32F4 support shared by the F411/F412 boards: the clock bring-up
//! (HSE -> PLL with bounded waits; every failure leaves the core on the
//! reset HSI, 16 MHz, and `cpu_frequency_hz` reports what is actually
//! running), a polled USART console and the LED.

const RCC_CR: *volatile u32 = @ptrFromInt(0x4002_3800);
const RCC_PLLCFGR: *volatile u32 = @ptrFromInt(0x4002_3804);
const RCC_CFGR: *volatile u32 = @ptrFromInt(0x4002_3808);
const RCC_AHB1ENR: *volatile u32 = @ptrFromInt(0x4002_3830);
const RCC_APB1ENR: *volatile u32 = @ptrFromInt(0x4002_3840);
const RCC_APB2ENR: *volatile u32 = @ptrFromInt(0x4002_3844);
const FLASH_ACR: *volatile u32 = @ptrFromInt(0x4002_3C00);

const CR_HSEON: u32 = 1 << 16;
const CR_HSERDY: u32 = 1 << 17;
const CR_PLLON: u32 = 1 << 24;
const CR_PLLRDY: u32 = 1 << 25;

pub var cpu_frequency_hz: u32 = 16_000_000;
/// SYSCLK / APB1: 1 on the reset HSI, 2 once `initClocks()` set the PLL.
pub var apb1_divider: u32 = 1;

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
    apb1_divider = 2;
}

pub const UsartConfig = struct {
    /// The USART's registers.
    base: usize,
    /// The bit in RCC_APB1ENR (`apb = 1`) or RCC_APB2ENR (`apb = 2`).
    apb: u2,
    enable_bit: u5,
    /// The TX and RX pins, on GPIOA, alternate function 7.
    tx_pin: u5,
    rx_pin: u5,
};

/// A polled USART console on two GPIOA pins (AF7), 8N1.
pub fn Usart(comptime cfg: UsartConfig) type {
    return struct {
        const GPIOA_MODER: *volatile u32 = @ptrFromInt(0x4002_0000);
        const GPIOA_OSPEEDR: *volatile u32 = @ptrFromInt(0x4002_0008);
        const SR: *volatile u32 = @ptrFromInt(cfg.base + 0x00);
        const DR: *volatile u32 = @ptrFromInt(cfg.base + 0x04);
        const BRR: *volatile u32 = @ptrFromInt(cfg.base + 0x08);
        const CR1: *volatile u32 = @ptrFromInt(cfg.base + 0x0C);

        var ready = false;

        pub fn init(baud: u32) void {
            RCC_AHB1ENR.* |= 1 << 0; // GPIOA
            if (cfg.apb == 1) RCC_APB1ENR.* |= @as(u32, 1) << cfg.enable_bit else RCC_APB2ENR.* |= @as(u32, 1) << cfg.enable_bit;
            inline for (.{ cfg.tx_pin, cfg.rx_pin }) |pin| {
                GPIOA_MODER.* = (GPIOA_MODER.* & ~(@as(u32, 3) << (@as(u5, pin) * 2))) | (@as(u32, 2) << (@as(u5, pin) * 2));
                GPIOA_OSPEEDR.* |= @as(u32, 3) << (@as(u5, pin) * 2);
                const afr: *volatile u32 = @ptrFromInt(0x4002_0020 + 4 * @as(usize, pin / 8));
                const shift: u5 = @as(u5, pin % 8) * 4;
                afr.* = (afr.* & ~(@as(u32, 0xF) << shift)) | (@as(u32, 7) << shift);
            }
            CR1.* = 0;
            const f_apb = if (cfg.apb == 1) cpu_frequency_hz / apb1_divider else cpu_frequency_hz;
            BRR.* = (f_apb + baud / 2) / baud;
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

        /// Wait until the last byte left the pin (TC).
        pub fn flush() void {
            if (!ready) return;
            while (SR.* & (1 << 6) == 0) {}
        }
    };
}

/// An interrupt-driven USART transmitter: `write()` copies into a ring and
/// returns, the TXE interrupt sends it. A full ring sends one byte by polling
/// first, so `write()` works in any context, a tick handler included, and
/// costs real time only when the line cannot keep up. The board installs
/// `irq` as the USART's handler (`board.interrupts`).
pub fn BufferedUsart(comptime cfg: UsartConfig, comptime irq_number: u32, comptime ring_size: usize) type {
    return struct {
        const Base = Usart(cfg);
        const SR: *volatile u32 = @ptrFromInt(cfg.base + 0x00);
        const DR: *volatile u32 = @ptrFromInt(cfg.base + 0x04);
        const CR1: *volatile u32 = @ptrFromInt(cfg.base + 0x0C);
        const NVIC_ISER: *volatile u32 = @ptrFromInt(0xE000_E100 + 4 * (irq_number / 32));
        const SR_TXE: u32 = 1 << 7;
        const SR_TC: u32 = 1 << 6;
        const CR1_TXEIE: u32 = 1 << 7;

        var ring: [ring_size]u8 = undefined;
        var head: usize = 0; // next free slot
        var tail: usize = 0; // next byte to send
        var ready = false;

        pub fn init(baud: u32) void {
            Base.init(baud);
            NVIC_ISER.* = @as(u32, 1) << @intCast(irq_number % 32);
            ready = true;
        }

        inline fn mask() u32 {
            const p = asm volatile ("mrs %[p], primask"
                : [p] "=r" (-> u32),
            );
            asm volatile ("cpsid i" ::: .{ .memory = true });
            return p;
        }

        inline fn unmask(p: u32) void {
            asm volatile ("msr primask, %[p]"
                :
                : [p] "r" (p),
                : .{ .memory = true });
        }

        /// One byte from the ring to the data register, waiting for TXE
        /// (interrupts masked by the caller).
        fn sendOnePolled() void {
            while (SR.* & SR_TXE == 0) {}
            DR.* = ring[tail];
            tail = (tail + 1) % ring_size;
        }

        fn put(c: u8) void {
            const p = mask();
            defer unmask(p);
            if ((head + 1) % ring_size == tail) sendOnePolled();
            ring[head] = c;
            head = (head + 1) % ring_size;
            CR1.* |= CR1_TXEIE;
        }

        pub fn write(bytes: []const u8) void {
            if (!ready) return;
            for (bytes) |c| {
                if (c == '\n') put('\r');
                put(c);
            }
        }

        /// The USART interrupt: refill the data register while it is empty.
        pub fn irq() callconv(.c) void {
            while (SR.* & SR_TXE != 0) {
                if (head == tail) {
                    CR1.* &= ~CR1_TXEIE;
                    return;
                }
                DR.* = ring[tail];
                tail = (tail + 1) % ring_size;
            }
        }

        /// Send what is left in the ring by polling, and wait until the last
        /// byte left the pin (TC); usable with the interrupts masked.
        pub fn flush() void {
            if (!ready) return;
            const p = mask();
            defer unmask(p);
            CR1.* &= ~CR1_TXEIE;
            while (head != tail) sendOnePolled();
            while (SR.* & SR_TC == 0) {}
        }
    };
}

/// USART1 on PA9 (TX) / PA10 (RX), on APB2: the WeAct boards' console.
pub const usart1 = Usart(.{ .base = 0x4001_1000, .apb = 2, .enable_bit = 4, .tx_pin = 9, .rx_pin = 10 });

/// USART2 on PA2 (TX) / PA3 (RX), on APB1 (IRQ 38), interrupt driven: the
/// Nucleo's ST-Link virtual COM port.
pub const usart2 = BufferedUsart(.{ .base = 0x4000_4400, .apb = 1, .enable_bit = 17, .tx_pin = 2, .rx_pin = 3 }, 38, 4096);

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
