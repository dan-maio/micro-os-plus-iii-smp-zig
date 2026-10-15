//! The Luckfox Lyra B: RK3506, 3x Cortex-A7 (and a Cortex-M0 this port does
//! not use), GIC-400, 128 MiB DDR. The C++ test/boards/luckfox-lyra/
//! (include/rk3506.hpp, uart.hpp, led.hpp, smp.hpp, src/mmu.cpp,
//! src/smp.cpp), as the port's `uos_board` module.
//!
//! The image is loaded and entered at 0x00200000 by the debugger (startup.S,
//! linker.ld); the Rockchip miniloader has set up the DDR, the UART1 pins and
//! baud rate, and holds CPUs 1 and 2 in reset.

const std = @import("std");

pub const name = "Luckfox Lyra B";
pub const banner_long = "Luckfox Lyra B";
pub const banner_short = "Lyra B";
pub const banner_cpu = "RK3506 (3x Cortex-A7 + 1x Cortex-M0)";
pub const banner_isa = "AArch32";
pub const port_greeting = "µOS++ Luckfox Lyra B (RK3506, Cortex-A7 SMP)";

/// The CPUs of the SMP cluster.
pub const ncpu = 3;

/// The interrupt a CPU sends another to make it reschedule
/// (`OS_SMP_IPI_SGI`).
pub const ipi_sgi: u32 = 0;

/// The DRAM window of the image (`PORT_RAM_BASE`, `PORT_RAM_END`): a stack
/// pointer outside it is a corrupt context.
pub const ram_base: u32 = 0x0020_0000;
pub const ram_end: u32 = 0x0800_0000;

// ---- The memory map (rk3506.hpp) -----------------------------------------

pub const uart1_base: usize = 0xFF0B_0000;
pub const gicd_base: usize = 0xFF58_1000;
pub const gicc_base: usize = 0xFF58_2000;
const gpio1_ioc_base: usize = 0xFF66_0000;
const gpio1_base: usize = 0xFF87_0000;
const cru_base: usize = 0xFF9A_0000;
const sram_base: usize = 0xFFF8_0000;

inline fn reg(addr: usize) *volatile u32 {
    return @ptrFromInt(addr);
}

/// A Rockchip write-mask register: the upper half-word selects the bits
/// the lower one changes, so no read-modify-write.
inline fn writeMasked(addr: usize, mask: u16, value: u16) void {
    reg(addr).* = (@as(u32, mask) << 16) | (value & mask);
}

const cru = struct {
    const CLKGATE_CON03 = cru_base + 0x080C; // GPIO1 ctrl + debounce gates (8, 9)
    const CLKGATE_CON22 = cru_base + 0x0858; // GPIO1_IOC gate (1)
    const SOFTRST_CON00 = cru_base + 0x0A00; // CPU core resets
    const SOFTRST_CON03 = cru_base + 0x0A0C; // GPIO1 resets (8, 9)
    const SOFTRST_CON22 = cru_base + 0x0A58; // GPIO1_IOC reset (1)
    const core1_resets: u16 = (1 << 1) | (1 << 5);
    const core2_resets: u16 = (1 << 2) | (1 << 6);
};

const mailbox = struct {
    const MAGIC = sram_base + 0x0004;
    const TARGET = sram_base + 0x0008;
    const magic_value: u32 = 0xDEAD_BEAF;
};

inline fn dsb() void {
    asm volatile ("dsb" ::: .{ .memory = true });
}

inline fn isb() void {
    asm volatile ("isb" ::: .{ .memory = true });
}

/// Called on CPU 0 before `main()`.
pub fn init() void {}

// ---- UART1, the console (uart.hpp) ---------------------------------------
//
// A DesignWare 16550, TX only, polled. The miniloader muxed the pins and set
// the baud rate (115200); init() silences its interrupts and enables the
// FIFO.

const uart_thr = uart1_base + 0x00;
const uart_ier = uart1_base + 0x04;
const uart_fcr = uart1_base + 0x08;
const uart_lsr = uart1_base + 0x14;
const lsr_thre: u32 = 1 << 5;
const lsr_temt: u32 = 1 << 6;

pub fn uartInit() void {
    reg(uart_ier).* = 0x00;
    reg(uart_fcr).* = 0x01;
}

fn uartRaw(c: u8) void {
    while (reg(uart_lsr).* & lsr_thre == 0) {}
    reg(uart_thr).* = c;
}

/// Write the bytes, '\n' as CR LF.
pub fn uartWrite(bytes: []const u8) void {
    for (bytes) |c| {
        if (c == '\n') uartRaw('\r');
        uartRaw(c);
    }
}

/// Formatted output on the UART alone (the fault reports and the port's
/// tripwires: no semihosting).
pub fn uartPrint(comptime fmt: []const u8, args: anytype) void {
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    w.print(fmt, args) catch {};
    uartWrite(w.buffered());
}

/// Wait until the transmitter sent the last bit (LSR.TEMT).
pub fn uartFlush() void {
    while (reg(uart_lsr).* & lsr_temt == 0) {}
}

// ---- The user LED, GPIO1_A0 (led.hpp) ------------------------------------

pub const led = struct {
    var state = false;

    pub fn init() void {
        writeMasked(cru.CLKGATE_CON22, 0x0002, 0); // ungate GPIO1_IOC
        writeMasked(cru.CLKGATE_CON03, 0x0300, 0); // ungate GPIO1 ctrl + debounce
        writeMasked(cru.SOFTRST_CON22, 0x0002, 0); // release GPIO1_IOC reset
        writeMasked(cru.SOFTRST_CON03, 0x0300, 0); // release GPIO1 resets
        writeMasked(gpio1_ioc_base + 0x0020, 0x000F, 0x0000); // A0 -> GPIO
        writeMasked(gpio1_base + 0x0008, 0x0001, 0x0001); // A0 -> output
    }

    pub fn on() void {
        state = true;
        writeMasked(gpio1_base + 0x0000, 0x0001, 0x0001);
    }

    pub fn off() void {
        state = false;
        writeMasked(gpio1_base + 0x0000, 0x0001, 0x0000);
    }

    pub fn set(on_: bool) void {
        if (on_) on() else off();
    }

    pub fn toggle() void {
        set(!state);
    }
};

// ---- The secondary CPUs (smp.cpp) ----------------------------------------

/// Release CPUs 1 and 2: the BootROM's SRAM mailbox gets the entry point
/// and the magic word, then their resets are released and an event sent.
/// They enter `_start` (startup.S), which sends them to `boot_core1/2`.
pub fn releaseSecondaries() void {
    uartWrite("Core 0: setting up SRAM mailbox...\n");
    reg(mailbox.TARGET).* = ram_base;
    reg(mailbox.MAGIC).* = mailbox.magic_value;
    dsb();

    uartWrite("Core 0: releasing core 1...\n");
    writeMasked(cru.SOFTRST_CON00, cru.core1_resets, 0);
    dsb();
    isb();
    asm volatile ("sev" ::: .{ .memory = true });

    uartWrite("Core 0: releasing core 2...\n");
    writeMasked(cru.SOFTRST_CON00, cru.core2_resets, 0);
    dsb();
    isb();
    asm volatile ("sev" ::: .{ .memory = true });

    uartWrite("Core 0: secondary-core startup signals sent.\n");
}

// ---- The MMU (mmu.cpp) ---------------------------------------------------
//
// A flat VA == PA map of 1 MiB sections: the 128 MiB DDR Normal write-back
// write-allocate Shareable (the kernel lock is LDREX/STREX, which needs a
// coherent, shareable mapping), the `.dma_nc` window Normal non-cacheable,
// the peripherals from 0xFF000000 Device and execute-never, the rest
// unmapped. Called from startup.S with the MMU and the caches still off.

extern var __ttb_base: [4096]u32;
extern var __dma_nc_start: u8;
extern var __dma_nc_end: u8;

const dram_top: u32 = 128 << 20;
const mmio_base: u32 = 0xFF00_0000;

const sect = struct {
    const section: u32 = 2 << 0;
    const ap_rw_all: u32 = 3 << 10;
    const xn: u32 = 1 << 4;
    const shared: u32 = 1 << 16;
    const device: u32 = (0 << 12) | (0 << 3) | (1 << 2);
    const normal_nc: u32 = (1 << 12) | (0 << 3) | (0 << 2);
    const normal_wbwa: u32 = (1 << 12) | (1 << 3) | (1 << 2);
};

const dram_attr = sect.section | sect.ap_rw_all | sect.normal_wbwa | sect.shared;
const dram_nc_attr = sect.section | sect.ap_rw_all | sect.normal_nc | sect.shared;
const device_attr = sect.section | sect.ap_rw_all | sect.device | sect.xn;

inline fn cp15Write(comptime op: []const u8, v: u32) void {
    asm volatile ("mcr p15, " ++ op
        :
        : [v] "r" (v),
        : .{ .memory = true });
}

inline fn cp15Read(comptime op: []const u8) u32 {
    return asm volatile ("mrc p15, " ++ op
        : [r] "=r" (-> u32),
    );
}

fn buildTable() void {
    const nc_first = @intFromPtr(&__dma_nc_start) >> 20;
    const nc_last = (@intFromPtr(&__dma_nc_end) - 1) >> 20;
    const ttb: *volatile [4096]u32 = &__ttb_base;
    var i: u32 = 0;
    while (i < 4096) : (i += 1) {
        const base = i << 20;
        ttb[i] = if (i >= nc_first and i <= nc_last)
            base | dram_nc_attr
        else if (base < dram_top)
            base | dram_attr
        else if (base >= mmio_base)
            base | device_attr
        else
            0;
    }
    dsb();
}

/// Turn the MMU and the caches on for this CPU (the shared table).
export fn mmu_enable() callconv(.c) void {
    cp15Write("0, %[v], c8, c7, 0", 0); // TLBIALL
    cp15Write("0, %[v], c7, c5, 6", 0); // BPIALL
    cp15Write("0, %[v], c7, c5, 0", 0); // ICIALLU
    cp15Write("0, %[v], c3, c0, 0", 0x1); // DACR: domain 0 client
    cp15Write("0, %[v], c2, c0, 2", 0); // TTBCR
    cp15Write("0, %[v], c2, c0, 0", @intFromPtr(&__ttb_base)); // TTBR0
    cp15Write("0, %[v], c1, c0, 1", cp15Read("0, %[r], c1, c0, 1") | (1 << 6)); // ACTLR.SMP
    isb();
    var sctlr = cp15Read("0, %[r], c1, c0, 0");
    sctlr |= 1 << 0; // M
    sctlr &= ~@as(u32, 1 << 1); // A: unaligned accesses allowed
    sctlr &= ~@as(u32, 1 << 13); // V: VBAR vectors
    sctlr |= 1 << 2; // C
    sctlr |= 1 << 12; // I
    cp15Write("0, %[v], c1, c0, 0", sctlr);
    isb();
}

/// CPU 0: build the table, clean it to the point of coherency, enable.
export fn mmu_init() callconv(.c) void {
    buildTable();
    var a: u32 = @intFromPtr(&__ttb_base) & ~@as(u32, 63);
    const end = @intFromPtr(&__ttb_base) + 0x4000;
    while (a < end) : (a += 64) cp15Write("0, %[v], c7, c10, 1", a); // DCCMVAC
    dsb();
    mmu_enable();
}
