//! The Raspberry Pi 4 B: BCM2711, 4x Cortex-A72, GIC-400, PL011 UART0,
//! ARM Generic Timer @ 54 MHz.
//! Supplies the board module `uos_board` for the AArch64 µOS++ SMP port.

const std = @import("std");

pub const name = "Raspberry Pi 4 B";
pub const banner_long = "Raspberry Pi 4 B";
pub const banner_short = "RPi 4 B";
pub const banner_cpu = "BCM2711 (4x Cortex-A72, AArch64)";
pub const banner_isa = "AArch64";
pub const port_greeting = "µOS++ Raspberry Pi 4 B (BCM2711, 4x Cortex-A72 SMP, AArch64/EL1, GIC-400, 1ms Tick, LDAXR lock)";

/// Maximum number of CPUs in the BCM2711 cluster.
pub const ncpu = 4;

/// Inter-Processor Interrupt (IPI) SGI number used by the scheduler.
pub const ipi_sgi: u32 = 0;

/// The DRAM window of the image (0x80000 .. 0x3B3FFFFF).
pub const ram_base: u64 = 0x0008_0000;
pub const ram_end: u64 = 0x3B40_0000; // 948 MB (top of usable RAM below GPU memory)

// ---- Memory Map (BCM2711 default low-peripheral mode) ---------------------

pub const periph_base: usize = 0xFE00_0000;
pub const uart0_base: usize = periph_base + 0x20_1000;
pub const gpio_base: usize = periph_base + 0x20_0000;
pub const systimer_base: usize = periph_base + 0x00_3000;

pub const gic_base: usize = 0xFF84_0000;
pub const gicd_base: usize = gic_base + 0x1000; // 0xFF841000
pub const gicc_base: usize = gic_base + 0x2000; // 0xFF842000

inline fn reg(addr: usize) *volatile u32 {
    return @ptrFromInt(addr);
}

inline fn reg64(addr: usize) *volatile u64 {
    return @ptrFromInt(addr);
}

inline fn dsb() void {
    asm volatile ("dsb sy" ::: .{ .memory = true });
}

inline fn isb() void {
    asm volatile ("isb" ::: .{ .memory = true });
}

inline fn sev() void {
    asm volatile ("sev" ::: .{ .memory = true });
}

pub fn init() void {}

// ---- PL011 UART0 Console --------------------------------------------------

const pl011 = struct {
    const DR = uart0_base + 0x00;
    const FR = uart0_base + 0x18;
    const IBRD = uart0_base + 0x24;
    const FBRD = uart0_base + 0x28;
    const LCRH = uart0_base + 0x2C;
    const CR = uart0_base + 0x30;
    const IMSC = uart0_base + 0x38;
    const ICR = uart0_base + 0x44;

    const FR_TXFF: u32 = 1 << 5;
    const FR_RXFE: u32 = 1 << 4;
    const FR_BUSY: u32 = 1 << 3;
};

pub fn uartInit() void {
    // Disable UART while reprogramming
    reg(pl011.CR).* = 0;
    // Clear pending interrupts
    reg(pl011.ICR).* = 0x7FF;
    // 115200 baud @ 48 MHz UART reference clock:
    // 48000000 / (16 * 115200) = 26.041666...
    // IBRD = 26, FBRD = round(0.041666 * 64) = 3
    reg(pl011.IBRD).* = 26;
    reg(pl011.FBRD).* = 3;
    // 8 bits, no parity, 1 stop bit, FIFOs enabled (WLEN=11b << 5, FEN << 4)
    reg(pl011.LCRH).* = (3 << 5) | (1 << 4);
    // Mask all UART interrupts (polled)
    reg(pl011.IMSC).* = 0;
    // Enable UART, TX, RX (CR: UARTEN=bit 0, TXE=bit 8, RXE=bit 9)
    reg(pl011.CR).* = (1 << 0) | (1 << 8) | (1 << 9);
}

fn uartRaw(c: u8) void {
    while (reg(pl011.FR).* & pl011.FR_TXFF != 0) {}
    reg(pl011.DR).* = c;
}

pub fn uartWrite(bytes: []const u8) void {
    for (bytes) |c| {
        if (c == '\n') uartRaw('\r');
        uartRaw(c);
    }
}

pub fn uartPrint(comptime fmt: []const u8, args: anytype) void {
    var buf: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    w.print(fmt, args) catch {};
    uartWrite(w.buffered());
}

pub fn uartFlush() void {
    while (reg(pl011.FR).* & pl011.FR_BUSY != 0) {}
}

// ---- Activity LED (GPIO 42) -----------------------------------------------

const gpio = struct {
    const GPFSEL4 = gpio_base + 0x10;
    const GPSET1 = gpio_base + 0x20;
    const GPCLR1 = gpio_base + 0x2C;
};

pub const led = struct {
    var state: bool = false;

    pub fn init() void {
        // GPIO 42 is in GPFSEL4, bits [8:6]. Set to output (001b).
        const sel = reg(gpio.GPFSEL4);
        sel.* = (sel.* & ~(@as(u32, 7) << 6)) | (@as(u32, 1) << 6);
    }

    pub fn on() void {
        state = true;
        // GPIO 42 is bit (42 - 32) = 10 in GPSET1
        reg(gpio.GPSET1).* = @as(u32, 1) << 10;
    }

    pub fn off() void {
        state = false;
        // GPIO 42 is bit (42 - 32) = 10 in GPCLR1
        reg(gpio.GPCLR1).* = @as(u32, 1) << 10;
    }

    pub fn set(on_: bool) void {
        if (on_) on() else off();
    }

    pub fn toggle() void {
        set(!state);
    }
};

// ---- Secondary Core Launch (BCM2711 / QEMU raspi4b spin-table) ------------

extern fn _start() void;
extern fn core1_entry() void;
extern fn core2_entry() void;
extern fn core3_entry() void;

extern var __smp_spin: [ncpu]u64;
extern var _port_core_alive: [ncpu]u32;

fn releaseWord(core: u32) *volatile u64 {
    return @ptrFromInt(@as(usize, 0xD8 + 8 * core));
}

fn entryFor(core: u32) u64 {
    return switch (core) {
        1 => @intFromPtr(&core1_entry),
        2 => @intFromPtr(&core2_entry),
        3 => @intFromPtr(&core3_entry),
        else => 0,
    };
}

fn releaseOne(core: u32) void {
    __smp_spin[core] = entryFor(core);

    // Clean __smp_spin slot to Point of Coherency (PoC)
    const slot_addr = @intFromPtr(&__smp_spin[core]);
    asm volatile ("dc cvac, %[v]"
        :
        : [v] "r" (slot_addr),
        : .{ .memory = true });
    dsb();

    // Write _start to the spin-table release word at (0xD8 + 8 * core)
    const rw = releaseWord(core);
    rw.* = @intFromPtr(&_start);

    // Clean cache line containing release word to PoC
    const rw_line = @intFromPtr(rw) & ~@as(usize, 63);
    asm volatile ("dc cvac, %[v]"
        :
        : [v] "r" (rw_line),
        : .{ .memory = true });
    dsb();
    sev();

    // Bounded wait for core to begin ticking
    var spin: u32 = 0;
    while (spin < 40_000_000) : (spin += 1) {
        asm volatile ("dmb ish" ::: .{ .memory = true });
        if (@atomicLoad(u32, &_port_core_alive[core], .monotonic) != 0) break;
        var d: u32 = 0;
        while (d < 50) : (d += 1) {
            asm volatile ("" ::: .{ .memory = true });
        }
        asm volatile ("sev" ::: .{ .memory = true });
    }
}

pub fn releaseSecondaries(log: *const fn ([]const u8) void) void {
    var c: u32 = 1;
    while (c < ncpu) : (c += 1) {
        var msg_buf: [64]u8 = undefined;
        var w = std.Io.Writer.fixed(&msg_buf);
        w.print("core 0: releasing core {d}...\n", .{c}) catch {};
        log(w.buffered());
        releaseOne(c);
    }
}
