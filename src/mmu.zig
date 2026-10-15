//! AArch64 MMU setup for BCM2711 / Raspberry Pi 4 B.
//! Sets up 4 GB identity mapping with 4 KB granule, Level 1 root table (T0SZ=32),
//! 2 MB block descriptors:
//!   - 0x00000000 .. 0x3B3FFFFF: Normal Cacheable Inner-Shareable (RAM)
//!   - 0x3B400000 .. 0x3FFFFFFF: Invalid (VideoCore / GPU memory)
//!   - 0xFC000000 .. 0xFFFFFFFF: Device-nGnRnE, Privileged/Unprivileged Execute-Never (MMIO)

const arch = @import("arch.zig");

const PTE_VALID: u64 = 1 << 0;
const PTE_TABLE: u64 = 1 << 1; // at L1/L2: next-level table pointer
const PTE_BLOCK: u64 = 0 << 1; // block descriptor
const PTE_AF: u64 = 1 << 10; // Access Flag
const PTE_SH_IS: u64 = 3 << 8; // Inner-Shareable
const PTE_SH_NONE: u64 = 0 << 8; // Non-Shareable
const PTE_PXN: u64 = @as(u64, 1) << 53; // Privileged execute-never
const PTE_UXN: u64 = @as(u64, 1) << 54; // Unprivileged execute-never

const ATTR_IDX_NORMAL: u64 = 0 << 2;
const ATTR_IDX_DEVICE: u64 = 1 << 2;

pub const BLOCK_2M: u64 = 2 * 1024 * 1024;
pub const BLOCK_1G: u64 = 1 * 1024 * 1024 * 1024;
pub const RAM_TOP: u64 = 0x3B400000; // 948 MB (matches PORT_RAM_END)
pub const RAM_ENTRIES: usize = RAM_TOP / BLOCK_2M; // 474 entries
pub const HIGH_GB: u64 = 3 * BLOCK_1G; // 0xC0000000
pub const DEVICE_START: u64 = 0xFC000000;

// SCTLR_EL1 bits
const SCTLR_M: u64 = 1 << 0;
const SCTLR_A: u64 = 1 << 1;
const SCTLR_C: u64 = 1 << 2;
const SCTLR_SA: u64 = 1 << 3;
const SCTLR_SA0: u64 = 1 << 4;
const SCTLR_I: u64 = 1 << 12;
const SCTLR_DZE: u64 = 1 << 14;
const SCTLR_RES1: u64 = (1 << 29) | (1 << 28) | (1 << 23) | (1 << 22) | (1 << 20) | (1 << 11);

// Shared translation tables (4 KB each, 4 KB aligned)
export var l1: [512]u64 align(4096) = @splat(0);
export var l2_low: [512]u64 align(4096) = @splat(0); // 0x00000000 .. 0x3FFFFFFF
export var l2_high: [512]u64 align(4096) = @splat(0); // 0xC0000000 .. 0xFFFFFFFF

inline fn makeBlock(pa: u64, attr_idx: u64, sh: u64) u64 {
    return pa | PTE_VALID | PTE_BLOCK | PTE_AF | attr_idx | sh;
}

pub fn buildTables() void {
    for (&l1) |*entry| entry.* = 0;
    for (&l2_low) |*entry| entry.* = 0;
    for (&l2_high) |*entry| entry.* = 0;

    // First GB: RAM up to VideoCore memory
    var i: usize = 0;
    while (i < RAM_ENTRIES) : (i += 1) {
        l2_low[i] = makeBlock(@as(u64, i) * BLOCK_2M, ATTR_IDX_NORMAL, PTE_SH_IS);
    }

    // Last GB (0xC0000000 .. 0xFFFFFFFF): map devices at 0xFC000000..0xFFFFFFFF
    i = 0;
    while (i < 512) : (i += 1) {
        const pa = HIGH_GB + @as(u64, i) * BLOCK_2M;
        if (pa >= DEVICE_START) {
            l2_high[i] = makeBlock(pa, ATTR_IDX_DEVICE, PTE_SH_NONE) | PTE_PXN | PTE_UXN;
        }
    }

    l1[0] = @intFromPtr(&l2_low[0]) | PTE_VALID | PTE_TABLE;
    l1[3] = @intFromPtr(&l2_high[0]) | PTE_VALID | PTE_TABLE;

    arch.dsb();
}

pub fn enableOnThisCore() void {
    // MAIR_EL1: Attr0 = Normal WB RA/WA (0xFF), Attr1 = Device-nGnRnE (0x00)
    const mair: u64 = (@as(u64, 0xFF) << 0) | (@as(u64, 0x00) << 8);
    asm volatile ("msr mair_el1, %[v]"
        :
        : [v] "r" (mair),
    );

    // TCR_EL1: T0SZ=32 (32-bit / 4 GB VA), 4 KB granule, Inner-Shareable,
    // Inner/Outer WB WA walks, EPD1=1 (disable TTBR1), IPS=40-bit PA
    const tcr: u64 = (32 << 0) | // T0SZ
        (1 << 8) | // IRGN0 = WB WA
        (1 << 10) | // ORGN0 = WB WA
        (3 << 12) | // SH0 = Inner-Shareable
        (0 << 14) | // TG0 = 4 KB
        (1 << 23) | // EPD1 = disable TTBR1
        (2 << 32); // IPS = 40-bit
    asm volatile ("msr tcr_el1, %[v]"
        :
        : [v] "r" (tcr),
    );

    asm volatile ("msr ttbr0_el1, %[v]"
        :
        : [v] "r" (@intFromPtr(&l1[0])),
    );

    arch.dsbIsh();
    asm volatile ("ic iallu" ::: .{ .memory = true });
    asm volatile ("tlbi vmalle1" ::: .{ .memory = true });
    arch.dsbIsh();
    arch.isb();

    var sctlr: u64 = SCTLR_RES1 | SCTLR_DZE | SCTLR_M | SCTLR_C | SCTLR_I;
    sctlr &= ~(SCTLR_A | SCTLR_SA | SCTLR_SA0);

    arch.dsb();
    arch.isb();
    asm volatile ("msr sctlr_el1, %[v]"
        :
        : [v] "r" (sctlr),
        : .{ .memory = true });
    arch.isb();
}

export fn mmu_init() callconv(.c) void {
    buildTables();
    // Clean tables to point of coherency so parked secondaries with MMU off can read
    var a: usize = @intFromPtr(&l1[0]);
    while (a < @intFromPtr(&l1[0]) + @sizeOf(@TypeOf(l1))) : (a += 64) {
        arch.cleanDcacheLine(a);
    }
    a = @intFromPtr(&l2_low[0]);
    while (a < @intFromPtr(&l2_low[0]) + @sizeOf(@TypeOf(l2_low))) : (a += 64) {
        arch.cleanDcacheLine(a);
    }
    a = @intFromPtr(&l2_high[0]);
    while (a < @intFromPtr(&l2_high[0]) + @sizeOf(@TypeOf(l2_high))) : (a += 64) {
        arch.cleanDcacheLine(a);
    }
    arch.dsb();
    enableOnThisCore();
}

export fn mmu_enable() callconv(.c) void {
    enableOnThisCore();
}
