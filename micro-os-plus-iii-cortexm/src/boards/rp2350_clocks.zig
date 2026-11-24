//! RP2350 clock configuration from scratch: the table-driven parts of the
//! C++ test/boards/pico2/src/clocks.cpp (PICO2_CLOCK_FROM_SCRATCH), line for
//! line, for the smp-test-nested-clock tests.
//!
//! `Clocks(enable_250, psram)` is the C++ build's two defines:
//! PICO2_ENABLE_250MHZ adds the 250 MHz row; PICO2_PSRAM also slows the
//! PSRAM's QMI clock above 200 MHz.
//!
//! Difference from C++: there `clocks::init()` runs in the start-up, on the
//! slow boot clock; here MicroZig has already brought the chip to 150 MHz,
//! and `init()` is called at the start of main(), before the scheduler. The
//! sequence is the same (the system clock moves to clk_ref while the PLL is
//! reprogrammed), and its callers then set the console's baud divisors and
//! the SysTick from the new frequency.

/// One row of the run-time frequency table: clk_sys = 12 MHz * fbdiv / pd1 /
/// pd2 (VCO = 12 * fbdiv, 750..1600 MHz), at the core voltage `vsel`.
pub const SysEntry = struct {
    khz: u32,
    fbdiv: u16,
    pd1: u8,
    pd2: u8,
    vsel: u8,
};

const RESETS_BASE: usize = 0x4002_0000;
const CLOCKS_BASE: usize = 0x4001_0000;
const XOSC_BASE: usize = 0x4004_8000;
const PLL_SYS_BASE: usize = 0x4005_0000;
const PLL_USB_BASE: usize = 0x4005_8000;
const TICKS_BASE: usize = 0x4010_8000;
const WATCHDOG_BASE: usize = 0x400D_8000;
const POWMAN_BASE: usize = 0x4010_0000;
const PSM_BASE: usize = 0x4001_8000;
const SIO_CPUID: usize = 0xD000_0000;

// Register offsets.
const XOSC_CTRL = 0x00;
const XOSC_STATUS = 0x04;
const XOSC_STARTUP = 0x0C;
const PLL_CS = 0x00;
const PLL_PWR = 0x04;
const PLL_FBDIV_INT = 0x08;
const PLL_PRIM = 0x0C;
const CLK_REF_CTRL = 0x30;
const CLK_SYS_CTRL = 0x3C;
const CLK_PERI_CTRL = 0x48;
const CLK_DIV = 0x04;
const CLK_SELECTED = 0x08;
const RESETS_RESET = 0x00;
const RESETS_DONE = 0x08;

// Bit fields.
const XOSC_FREQ_1_15MHZ: u32 = 0x0AA0;
const XOSC_ENABLE: u32 = 0x0FAB;
const XOSC_STABLE: u32 = 1 << 31;
const PLL_PWR_PD: u32 = 1 << 0;
const PLL_PWR_POSTDIVPD: u32 = 1 << 3;
const PLL_PWR_VCOPD: u32 = 1 << 5;
const PLL_CS_LOCK: u32 = 1 << 31;
const CLK_REF_SRC: u32 = 0x3;
const CLK_REF_SRC_XOSC: u32 = 2;
const CLK_SYS_SRC: u32 = 0x3;
const CLK_SYS_SRC_AUX: u32 = 1;
const CLK_SYS_AUX: u32 = 0xE0;
const CLK_SYS_AUX_LSB: u5 = 5;
const CLK_REF_AUX: u32 = 0x60;
const CLK_REF_AUX_LSB: u5 = 5;
const CLK_PERI_AUX: u32 = 0xE0;
const CLK_PERI_AUX_LSB: u5 = 5;
const CLK_PERI_ENABLE: u32 = 1 << 11;
const RESET_PLL_SYS: u32 = 1 << 14;
const RESET_PLL_USB: u32 = 1 << 15;
const RESET_IO_BANK0: u32 = 1 << 6;
const RESET_PADS_BANK0: u32 = 1 << 9;
const CLK_DIV_UNDIVIDED: u32 = 1 << 16;

fn reg(a: usize) *volatile u32 {
    return @ptrFromInt(a);
}

fn nop() void {
    asm volatile ("nop");
}

fn resetBlock(mask: u32) void {
    reg(RESETS_BASE + RESETS_RESET).* |= mask;
    // Wait a couple of cycles for the reset to propagate.
    nop();
    nop();
}

fn unresetBlock(mask: u32) void {
    reg(RESETS_BASE + RESETS_RESET).* &= ~mask;
    while (reg(RESETS_BASE + RESETS_DONE).* & mask != mask) {}
}

fn xoscInit() void {
    reg(XOSC_BASE + XOSC_STARTUP).* = 0xC4;
    reg(XOSC_BASE + XOSC_CTRL).* = (XOSC_ENABLE << 12) | XOSC_FREQ_1_15MHZ;
    while (reg(XOSC_BASE + XOSC_STATUS).* & XOSC_STABLE == 0) {}
}

/// Program PLL_SYS to VCO = 12 MHz * fbdiv, then /postdiv1 /postdiv2.
fn pllSysProgram(fbdiv: u32, postdiv1: u32, postdiv2: u32) void {
    const b = PLL_SYS_BASE;
    resetBlock(RESET_PLL_SYS);
    unresetBlock(RESET_PLL_SYS);
    reg(b + PLL_CS).* = 1; // REFDIV = 1
    reg(b + PLL_FBDIV_INT).* = fbdiv;
    reg(b + PLL_PWR).* &= ~(PLL_PWR_PD | PLL_PWR_VCOPD);
    while (reg(b + PLL_CS).* & PLL_CS_LOCK == 0) {}
    reg(b + PLL_PRIM).* = (postdiv1 << 16) | (postdiv2 << 12);
    reg(b + PLL_PWR).* &= ~PLL_PWR_POSTDIVPD;
}

/// Configure a glitchless clock (clk_ref / clk_sys).
fn clkConfigure(ctrl_addr: usize, src_mask: u32, aux_mask: u32, aux_lsb: u5, src: u32, auxsrc: u32) void {
    if (src == CLK_SYS_SRC_AUX) {
        reg(ctrl_addr).* &= ~src_mask;
        while (reg(ctrl_addr + CLK_SELECTED).* & 1 == 0) {}
    }
    reg(ctrl_addr).* = (reg(ctrl_addr).* & ~aux_mask) | (auxsrc << aux_lsb);
    reg(ctrl_addr).* = (reg(ctrl_addr).* & ~src_mask) | (src << 0);
    while (reg(ctrl_addr + CLK_SELECTED).* & (@as(u32, 1) << @intCast(src)) == 0) {}
    reg(ctrl_addr + CLK_DIV).* = CLK_DIV_UNDIVIDED;
}

/// clk_sys = clk_peri = PLL_SYS(fbdiv/pd1/pd2), clk_ref = XOSC.
fn bringUpClockTree(fbdiv: u32, pd1: u32, pd2: u32) void {
    const c = CLOCKS_BASE;
    xoscInit();

    // Move clk_sys/clk_ref off any AUX source before touching the PLLs.
    reg(c + CLK_SYS_CTRL).* &= ~CLK_SYS_SRC;
    while (reg(c + CLK_SYS_CTRL + CLK_SELECTED).* & 1 == 0) {}
    reg(c + CLK_REF_CTRL).* &= ~CLK_REF_SRC;
    while (reg(c + CLK_REF_CTRL + CLK_SELECTED).* & 1 == 0) {}

    pllSysProgram(fbdiv, pd1, pd2);

    // clk_ref = XOSC (12 MHz).
    clkConfigure(c + CLK_REF_CTRL, CLK_REF_SRC, CLK_REF_AUX, CLK_REF_AUX_LSB, CLK_REF_SRC_XOSC, 0);
    // clk_sys = PLL_SYS.
    clkConfigure(c + CLK_SYS_CTRL, CLK_SYS_SRC, CLK_SYS_AUX, CLK_SYS_AUX_LSB, CLK_SYS_SRC_AUX, 0);

    // clk_peri = clk_sys: the UART reference clock.
    reg(c + CLK_PERI_CTRL).* &= ~CLK_PERI_ENABLE;
    reg(c + CLK_PERI_CTRL).* = (reg(c + CLK_PERI_CTRL).* & ~CLK_PERI_AUX) | (0 << CLK_PERI_AUX_LSB);
    reg(c + CLK_PERI_CTRL + CLK_DIV).* = CLK_DIV_UNDIVIDED;
    reg(c + CLK_PERI_CTRL).* |= CLK_PERI_ENABLE;

    unresetBlock(RESET_IO_BANK0 | RESET_PADS_BANK0);

    // The watchdog and TIMER0 tick generators: 12 clk_ref cycles = 1 us.
    reg(TICKS_BASE + 0x34).* = 12; // TICKS_WATCHDOG_CYCLES
    reg(TICKS_BASE + 0x30).* = 1; // TICKS_WATCHDOG_CTRL.ENABLE
    reg(TICKS_BASE + 0x1C).* = 12; // TICKS_TIMER0_CYCLES
    reg(TICKS_BASE + 0x18).* = 1; // TICKS_TIMER0_CTRL.ENABLE
}

/// POWMAN VSEL codes: 0.55 V + 50 mV per step (0x0b = 1.10 V).
pub fn vselToMv(vsel: u8) u32 {
    return 550 + 50 * @as(u32, vsel);
}

/// Set the core voltage (raise it BEFORE raising the clock).
pub fn vregSet(vsel: u8) void {
    const PASSWD: u32 = 0x5AFE_0000;
    const VREG_CTRL = 0x04;
    const VREG = 0x0C;
    const UNLOCK: u32 = 1 << 13;
    const VSEL_LSB: u5 = 4;
    const VSEL_BITS: u32 = 0x1F0;
    const UPDATE_IN_PROGRESS: u32 = 1 << 15;
    const p = POWMAN_BASE;

    // Unlock the regulator (needed only for > 1.30 V, harmless otherwise).
    reg(p + VREG_CTRL).* = PASSWD | (reg(p + VREG_CTRL).* & 0xFFFF) | UNLOCK;
    while (reg(p + VREG).* & UPDATE_IN_PROGRESS != 0) {}
    // Write VSEL (the password in the high half on every POWMAN write).
    reg(p + VREG).* = PASSWD | (reg(p + VREG).* & ~VSEL_BITS) | (@as(u32, vsel) << VSEL_LSB);
    while (reg(p + VREG).* & UPDATE_IN_PROGRESS != 0) {}
    // Let the rail settle before the caller raises the clock.
    for (0..20000) |_| nop();
}

/// Bring up PLL_USB (48 MHz) if not already, then clk_adc from it.
pub fn adcClkInit() void {
    const b = PLL_USB_BASE;
    unresetBlock(RESET_PLL_USB);
    if (reg(b + PLL_CS).* & PLL_CS_LOCK == 0) {
        reg(b + PLL_CS).* = 1;
        reg(b + PLL_FBDIV_INT).* = 100; // VCO 1200
        reg(b + PLL_PWR).* &= ~(PLL_PWR_PD | PLL_PWR_VCOPD);
        while (reg(b + PLL_CS).* & PLL_CS_LOCK == 0) {}
        reg(b + PLL_PRIM).* = (5 << 16) | (5 << 12); // /5 /5 = 48 MHz
        reg(b + PLL_PWR).* &= ~PLL_PWR_POSTDIVPD;
    }
    // clk_adc = PLL_USB (AUXSRC 0), /1, enabled; CTRL at 0x6c.
    const c = CLOCKS_BASE;
    const CLK_ADC_CTRL = 0x6C;
    const CLK_ADC_ENABLE: u32 = 1 << 11;
    const CLK_ADC_AUX: u32 = 0xE0;
    reg(c + CLK_ADC_CTRL).* &= ~CLK_ADC_ENABLE;
    reg(c + CLK_ADC_CTRL + CLK_DIV).* = CLK_DIV_UNDIVIDED;
    reg(c + CLK_ADC_CTRL).* = (reg(c + CLK_ADC_CTRL).* & ~CLK_ADC_AUX) | (0 << 5);
    reg(c + CLK_ADC_CTRL).* |= CLK_ADC_ENABLE;
}

const MAGIC: u32 = 0xC10C_4B01;

/// The table and the selected clock, for one build configuration.
pub fn Clocks(comptime enable_250: bool, comptime psram: bool) type {
    return struct {
        /// The run-time frequency table (48..200 MHz, and 250 MHz with
        /// `enable_250`). Every row is < 0.03 % from 115200 baud with the
        /// PL011 fractional divisor. vsel: 0x0b = 1.10 V (<= 150 MHz),
        /// 0x0c = 1.15 V (176/192), 0x0d = 1.20 V (200), 0x0e = 1.25 V (250).
        pub const sys_table = [_]SysEntry{
            .{ .khz = 48000, .fbdiv = 100, .pd1 = 5, .pd2 = 5, .vsel = 0x0b }, // VCO 1200
            .{ .khz = 60000, .fbdiv = 125, .pd1 = 5, .pd2 = 5, .vsel = 0x0b }, // VCO 1500
            .{ .khz = 72000, .fbdiv = 120, .pd1 = 5, .pd2 = 4, .vsel = 0x0b }, // VCO 1440
            .{ .khz = 84000, .fbdiv = 98, .pd1 = 7, .pd2 = 2, .vsel = 0x0b }, // VCO 1176
            .{ .khz = 96000, .fbdiv = 96, .pd1 = 4, .pd2 = 3, .vsel = 0x0b }, // VCO 1152
            .{ .khz = 108000, .fbdiv = 108, .pd1 = 6, .pd2 = 2, .vsel = 0x0b }, // VCO 1296
            .{ .khz = 120000, .fbdiv = 100, .pd1 = 5, .pd2 = 2, .vsel = 0x0b }, // VCO 1200
            .{ .khz = 132000, .fbdiv = 110, .pd1 = 5, .pd2 = 2, .vsel = 0x0b }, // VCO 1320
            .{ .khz = 150000, .fbdiv = 125, .pd1 = 5, .pd2 = 2, .vsel = 0x0b }, // VCO 1500 (default)
            .{ .khz = 176000, .fbdiv = 88, .pd1 = 6, .pd2 = 1, .vsel = 0x0c }, // VCO 1056, 1.15 V
            .{ .khz = 192000, .fbdiv = 96, .pd1 = 6, .pd2 = 1, .vsel = 0x0c }, // VCO 1152, 1.15 V
            .{ .khz = 200000, .fbdiv = 100, .pd1 = 6, .pd2 = 1, .vsel = 0x0d }, // VCO 1200, 1.20 V
        } ++ (if (enable_250) [_]SysEntry{
            .{ .khz = 250000, .fbdiv = 125, .pd1 = 6, .pd2 = 1, .vsel = 0x0e }, // VCO 1500, 1.25 V (overclock)
        } else [_]SysEntry{});

        pub const sys_table_len = sys_table.len;

        var g_khz: u32 = 150000;
        var g_vsel: u8 = 0x0b;
        var g_index: u32 = 0xFFFF;

        /// Pick the row from the watchdog scratch registers (48 MHz on a cold
        /// boot), raise the core voltage, slow the QMI clocks above 200 MHz,
        /// and bring up the clock tree. Returns the new clk_sys in Hz.
        pub fn init() u32 {
            const default_index = 0; // 48 MHz (the pot rests at 0 on power-up)
            var idx: u32 = default_index;
            if (reg(WATCHDOG_BASE + 0x10).* == MAGIC) { // SCRATCH1
                const s = reg(WATCHDOG_BASE + 0x0C).*; // SCRATCH0
                if (s < sys_table_len) idx = s;
            }
            const e = sys_table[idx];
            vregSet(e.vsel);
            if (enable_250 and e.khz > 200000) {
                // The XIP flash SCK = clk_sys / QMI CLKDIV: raise CLKDIV so the
                // SCK stays at ~<= 90 MHz (raising it only slows the reads).
                const QMI_M0_TIMING: usize = 0x400D_000C; // CLKDIV = bits[7:0]
                var div = (e.khz + 89999) / 90000; // 250 MHz -> 3
                if (div < 2) div = 2;
                reg(QMI_M0_TIMING).* = (reg(QMI_M0_TIMING).* & ~@as(u32, 0xFF)) | (div & 0xFF);
                if (psram) {
                    // The PSRAM (QMI M1) too: 250/2 = 125 MHz would exceed the
                    // APS6404's ~109 MHz window.
                    const QMI_M1_TIMING: usize = 0x400D_0020;
                    reg(QMI_M1_TIMING).* = (reg(QMI_M1_TIMING).* & ~@as(u32, 0xFF)) | (div & 0xFF);
                }
                asm volatile ("dsb 0xf" ::: .{ .memory = true });
            }
            bringUpClockTree(e.fbdiv, e.pd1, e.pd2);
            g_index = idx;
            g_khz = e.khz;
            g_vsel = e.vsel;
            return e.khz * 1000;
        }

        pub fn currentIndex() u32 {
            return g_index;
        }

        pub fn currentKhz() u32 {
            return g_khz;
        }

        pub fn currentVsel() u8 {
            return g_vsel;
        }

        /// Reboot (watchdog) into table row `idx`.
        pub fn rebootToIndex(idx: u32) noreturn {
            const w = WATCHDOG_BASE;
            // Quiesce BEFORE arming the watchdog: mask this core's IRQs and
            // hold the other core in reset (PSM FRCE_OFF; PROC0 = 1 << 23,
            // PROC1 = 1 << 24) so nothing touches the bus during the
            // countdown.
            asm volatile ("cpsid i" ::: .{ .memory = true });
            {
                const self = reg(SIO_CPUID).* & 1;
                const other_proc: u32 = if (self != 0) 1 << 23 else 1 << 24;
                reg(PSM_BASE + 0x04).* |= other_proc;
                for (0..2000) |_| nop();
            }
            reg(w + 0x0C).* = idx; // SCRATCH0 = target index
            reg(w + 0x10).* = MAGIC; // SCRATCH1 = validity magic
            reg(w + 0x1C).* = 0; // SCRATCH4 = 0: no bootrom reboot vector, boot flash
            // The watchdog counts on its tick: 12 clk_ref cycles = 1 us.
            reg(TICKS_BASE + 0x34).* = 12; // TICKS_WATCHDOG_CYCLES
            reg(TICKS_BASE + 0x30).* = 1; // TICKS_WATCHDOG_CTRL.ENABLE
            // The watchdog resets everything except ROSC/XOSC (PSM WDSEL).
            reg(PSM_BASE + 0x08).* = 0x01FF_FFFF & ~@as(u32, 0x0C);
            // CTRL: ENABLE off, and clear the debug/JTAG PAUSE bits (with a
            // debugger attached they pause the watchdog).
            var ctrl = reg(w + 0x00).*;
            ctrl &= ~@as(u32, 1 << 30); // ENABLE = 0
            ctrl &= ~@as(u32, (1 << 26) | (1 << 25) | (1 << 24)); // PAUSE_DBG1/DBG0/JTAG = 0
            reg(w + 0x00).* = ctrl;
            // A short countdown (~2 ms of ticks), then ENABLE.
            reg(w + 0x04).* = 2000; // LOAD (us ticks)
            reg(w + 0x00).* = ctrl | (1 << 30); // CTRL.ENABLE
            while (true) asm volatile ("wfi");
        }
    };
}
