//! Bare-metal RP2350 QSPI PSRAM driver: the C++
//! test/boards/pico2/glue/psram.cpp (a port of the pico-sdk PSRAM examples,
//! psram_tool.c / sfe_psram.c), line for line.
//!
//! `init()` and `readId()` are linked in `.ram_text`, which MicroZig copies to
//! internal SRAM at start-up (C++: `.psram_ram`, copied by boot.S): while the
//! QMI is in direct mode (asserting CS1 for the PSRAM commands) it cannot
//! serve the flash XIP the code would otherwise be fetched from. For the same
//! reason everything they call is inline, and no constant table is used (the
//! compiler could copy it with an out-of-line memcpy in flash).
//!
//! The PSRAM is window 1 of the XIP space, 0x11000000; 8 MB on the WeAct
//! RP2350B board, CS1 on GPIO0 (`cs_pin`).

/// The PSRAM base (XIP window 1) and size on the WeAct RP2350B board.
pub const base: usize = 0x1100_0000;
pub const size: usize = 8 * 1024 * 1024;

/// The PSRAM chip-select pin (XIP CS1 function); GPIO0 on the WeAct RP2350B
/// (C++ PICO2_PSRAM_CS_PIN).
pub const cs_pin: u32 = 0;

// RP2350 register bases.
const QMI_BASE: usize = 0x400d_0000;
const XIP_CTRL: usize = 0x400c_8000;
const IO_BANK0_BASE: usize = 0x4002_8000;
const PADS_BANK0: usize = 0x4003_8000;

// QMI register offsets.
const QMI_DIRECT_CSR = QMI_BASE + 0x00;
const QMI_DIRECT_TX = QMI_BASE + 0x04;
const QMI_DIRECT_RX = QMI_BASE + 0x08;
const QMI_M1_TIMING = QMI_BASE + 0x20;
const QMI_M1_RFMT = QMI_BASE + 0x24;
const QMI_M1_RCMD = QMI_BASE + 0x28;
const QMI_M1_WFMT = QMI_BASE + 0x2c;
const QMI_M1_WCMD = QMI_BASE + 0x30;

// QMI DIRECT_CSR bits.
const D_EN: u32 = 0x0000_0001;
const D_BUSY: u32 = 0x0000_0002;
const D_CS1N: u32 = 0x0000_0008;
const D_CLKDIV: u32 = 30 << 22; // ~5 MHz @ 150 MHz

// GPIO / pad.
const GPIO_FUNC_XIP_CS1: u32 = 9;
const PADS_ISO: u32 = 1 << 8;
const PADS_IE: u32 = 1 << 6;
const CS_GPIO_CTRL = IO_BANK0_BASE + cs_pin * 8 + 4;
const CS_PAD_CTRL = PADS_BANK0 + 0x04 + cs_pin * 4;

// PSRAM command codes.
const CMD_RSTEN: u32 = 0x66;
const CMD_RST: u32 = 0x99;
const CMD_QUAD_EN: u32 = 0x35;
const CMD_QUAD_READ: u32 = 0xEB;
const CMD_QUAD_WRITE: u32 = 0x38;

inline fn reg(comptime a: usize) *volatile u32 {
    return @ptrFromInt(a);
}

/// Bounded wait: true if the condition cleared in time.
inline fn waitUntil(mask: u32, set: bool) bool {
    var n: u32 = 0;
    while (n < 100_000) : (n += 1) {
        const now = (reg(QMI_DIRECT_CSR).* & mask) != 0;
        if (now == set) return true;
    }
    return false;
}

inline fn spin(count: u32) void {
    var j: u32 = 0;
    while (j < count) : (j += 1) asm volatile ("" ::: .{ .memory = true });
}

inline fn maskIrqs() u32 {
    const primask = asm volatile ("mrs %[p], primask"
        : [p] "=r" (-> u32),
    );
    asm volatile ("cpsid i" ::: .{ .memory = true });
    asm volatile ("dsb" ::: .{ .memory = true });
    asm volatile ("isb" ::: .{ .memory = true });
    return primask;
}

inline fn restoreIrqs(primask: u32) void {
    asm volatile ("msr primask, %[p]"
        :
        : [p] "r" (primask),
        : .{ .memory = true });
    asm volatile ("dsb" ::: .{ .memory = true });
    asm volatile ("isb" ::: .{ .memory = true });
}

/// Initialise the PSRAM in quad mode and map it at `base`; true when a
/// word written there reads back. Interrupts are masked for the whole
/// sequence: a handler fetched from flash XIP during QMI direct mode would
/// stall forever.
pub noinline fn init() linksection(".ram_text") bool {
    const primask = maskIrqs();

    // 1. Route the CS pin to the XIP CS1 function and un-isolate the pad.
    reg(CS_GPIO_CTRL).* = (reg(CS_GPIO_CTRL).* & ~@as(u32, 0x1F)) | GPIO_FUNC_XIP_CS1;
    reg(CS_PAD_CTRL).* = (reg(CS_PAD_CTRL).* & ~PADS_ISO) | PADS_IE;

    // 2. QMI direct mode (5 MHz), wait for the last XIP transfer cooldown.
    reg(QMI_DIRECT_CSR).* = D_CLKDIV | D_EN;
    _ = waitUntil(D_BUSY, false);

    // 3. Reset the PSRAM and enable quad-SPI mode (CS1 toggled per byte). No
    //    quad-exit (0xF5) frame: RSTEN/RST resets it to SPI regardless.
    var i: u32 = 0;
    while (i < 34) : (i += 1) {
        reg(QMI_DIRECT_CSR).* |= D_CS1N;
        const cmd: u32 = if (i == 0) CMD_RSTEN else if (i == 1) CMD_RST else CMD_QUAD_EN;
        reg(QMI_DIRECT_TX).* = cmd;
        _ = waitUntil(D_BUSY, false);
        reg(QMI_DIRECT_CSR).* &= ~D_CS1N;
        spin(20);
        _ = reg(QMI_DIRECT_RX).*;
    }

    // 4. Leave direct mode.
    reg(QMI_DIRECT_CSR).* &= ~(D_CS1N | D_EN);

    // 5. M1 timing: 150 MHz / 2 = 75 MHz PSRAM SCK, generous CS times.
    reg(QMI_M1_TIMING).* = (0x2 << 28) | // PAGEBREAK at 1 KB
        (3 << 23) | // SELECT_HOLD = 3 extra sys cycles
        (1 << 30) | // COOLDOWN = 1
        (1 << 8) | // RXDELAY = 1
        (14 << 17) | // MAX_SELECT ~8 us
        (6 << 12) | // MIN_DESELECT ~50 ns
        (2 << 0); // CLKDIV = 2

    // 6. M1 read: 0xEB quad read, prefix 8, suffix 0, dummy 24, all quad.
    reg(QMI_M1_RFMT).* = (0x2 << 0) | (0x2 << 2) | (0x2 << 4) | (0x2 << 6) | (0x2 << 8) |
        (0x1 << 12) | (0x0 << 14) | (0x6 << 16);
    reg(QMI_M1_RCMD).* = CMD_QUAD_READ;

    // 7. M1 write: 0x38 quad write, prefix 8, no suffix, no dummy.
    reg(QMI_M1_WFMT).* = (0x2 << 0) | (0x2 << 2) | (0x2 << 4) | (0x2 << 6) | (0x2 << 8) |
        (0x1 << 12) | (0x0 << 14) | (0x0 << 16);
    reg(QMI_M1_WCMD).* = CMD_QUAD_WRITE;

    // 8. Allow writes to the PSRAM window (XIP_CTRL bit 11 = WRITABLE_M1).
    reg(XIP_CTRL).* |= 0x800;

    // 9. Sanity check: write + read back a word in window 1.
    const p: *volatile u32 = @ptrFromInt(base);
    p.* = 0xA5A5_A5A5;
    asm volatile ("dmb sy" ::: .{ .memory = true });
    const ok = p.* == 0xA5A5_A5A5;

    // 10. Restore the interrupt state.
    restoreIrqs(primask);
    return ok;
}

/// Read the PSRAM device ID (SPI command 0x9F) through QMI direct mode, on a
/// fresh PSRAM (it issues RSTEN/RST first): out[0] = MFID (APS6404: 0x0D),
/// out[1] = KGD (0x5D), out[2..7] = EID. From SRAM, as `init()`.
pub noinline fn readId(out: *[8]u8) linksection(".ram_text") void {
    const primask = maskIrqs();

    // Route the CS pin to XIP CS1 + un-isolate the pad (as init step 1).
    reg(CS_GPIO_CTRL).* = (reg(CS_GPIO_CTRL).* & ~@as(u32, 0x1F)) | GPIO_FUNC_XIP_CS1;
    reg(CS_PAD_CTRL).* = (reg(CS_PAD_CTRL).* & ~PADS_ISO) | PADS_IE;

    // Direct mode, slow clock.
    reg(QMI_DIRECT_CSR).* = D_CLKDIV | D_EN;
    _ = waitUntil(D_BUSY, false);

    // RSTEN then RST (each its own CS frame) to force SPI mode.
    var i: u32 = 0;
    while (i < 2) : (i += 1) {
        reg(QMI_DIRECT_CSR).* |= D_CS1N;
        reg(QMI_DIRECT_TX).* = if (i == 0) CMD_RSTEN else CMD_RST;
        _ = waitUntil(D_BUSY, false);
        reg(QMI_DIRECT_CSR).* &= ~D_CS1N;
        spin(200);
        _ = reg(QMI_DIRECT_RX).*;
    }

    // Read ID frame: CS1 held for command 0x9F + 3 address bytes + 8 read.
    reg(QMI_DIRECT_CSR).* |= D_CS1N;
    i = 0;
    while (i < 4) : (i += 1) {
        reg(QMI_DIRECT_TX).* = if (i == 0) 0x9F else 0x00;
        _ = waitUntil(D_BUSY, false);
        _ = reg(QMI_DIRECT_RX).*;
    }
    i = 0;
    while (i < 8) : (i += 1) {
        reg(QMI_DIRECT_TX).* = 0x00;
        _ = waitUntil(D_BUSY, false);
        out[i] = @truncate(reg(QMI_DIRECT_RX).* & 0xFF);
    }
    reg(QMI_DIRECT_CSR).* &= ~(D_CS1N | D_EN);

    restoreIrqs(primask);
}
