//! The GIC-400 (GICv2) distributor and CPU interface (the C++ board's
//! gic.hpp): every interrupt priority 0xA0, group 0 and 1 enabled, PMR open.

const arch = @import("arch.zig");

pub const Gic = struct {
    gicd: usize,
    gicc: usize,

    // Distributor.
    const CTLR = 0x000;
    const TYPER = 0x004;
    const ISENABLER = 0x100;
    const ICENABLER = 0x180;
    const ICPENDR = 0x280;
    const IPRIORITYR = 0x400;
    const ITARGETSR = 0x800;
    const ICFGR = 0xC00;
    const SGIR = 0xF00;
    // CPU interface.
    const C_CTLR = 0x000;
    const C_PMR = 0x004;
    const C_BPR = 0x008;
    const C_IAR = 0x00C;
    const C_EOIR = 0x010;

    fn d(g: Gic, off: usize) *volatile u32 {
        return arch.reg(g.gicd + off);
    }

    fn c(g: Gic, off: usize) *volatile u32 {
        return arch.reg(g.gicc + off);
    }

    /// The whole distributor, then this CPU's interface (CPU 0).
    pub fn init(g: Gic) void {
        g.d(CTLR).* = 0;
        const n = ((g.d(TYPER).* & 0x1F) + 1) * 32;
        var i: usize = 0;
        while (i < n / 32) : (i += 1) g.d(ICENABLER + i * 4).* = 0xFFFF_FFFF;
        i = 0;
        while (i < n / 32) : (i += 1) g.d(ICPENDR + i * 4).* = 0xFFFF_FFFF;
        i = 0;
        while (i < n / 4) : (i += 1) g.d(IPRIORITYR + i * 4).* = 0xA0A0_A0A0;
        i = 8;
        while (i < n / 4) : (i += 1) g.d(ITARGETSR + i * 4).* = 0x0101_0101; // SPIs to CPU 0
        i = 2;
        while (i < n / 16) : (i += 1) g.d(ICFGR + i * 4).* = 0; // level
        g.d(CTLR).* = 0b11; // group 0 and 1
        g.initCpuInterface();
    }

    /// This CPU's banked SGI/PPI priorities and its CPU interface.
    pub fn initCpuInterface(g: Gic) void {
        var i: usize = 0;
        while (i < 8) : (i += 1) g.d(IPRIORITYR + i * 4).* = 0xA0A0_A0A0;
        g.c(C_PMR).* = 0xFF;
        g.c(C_BPR).* = 0;
        g.c(C_CTLR).* = 0b11;
    }

    pub fn enableIrq(g: Gic, id: u32) void {
        g.d(ISENABLER + (id / 32) * 4).* = @as(u32, 1) << @intCast(id % 32);
    }

    pub fn disableIrq(g: Gic, id: u32) void {
        g.d(ICENABLER + (id / 32) * 4).* = @as(u32, 1) << @intCast(id % 32);
    }

    pub fn setPriority(g: Gic, id: u32, prio: u8) void {
        const r = g.d(IPRIORITYR + (id / 4) * 4);
        const shift: u5 = @intCast((id % 4) * 8);
        r.* = (r.* & ~(@as(u32, 0xFF) << shift)) | (@as(u32, prio) << shift);
    }

    pub fn setTarget(g: Gic, id: u32, cpu_mask: u8) void {
        const r = g.d(ITARGETSR + (id / 4) * 4);
        const shift: u5 = @intCast((id % 4) * 8);
        r.* = (r.* & ~(@as(u32, 0xFF) << shift)) | (@as(u32, cpu_mask) << shift);
    }

    /// The raw IAR (interrupt id in bits 9..0, source CPU above for SGIs).
    pub fn acknowledge(g: Gic) u32 {
        return g.c(C_IAR).*;
    }

    pub fn endOfInterrupt(g: Gic, iar: u32) void {
        g.c(C_EOIR).* = iar;
    }

    pub fn sendSgi(g: Gic, cpu_mask: u32, sgi: u32) void {
        arch.dsb();
        g.d(SGIR).* = ((cpu_mask & 0xFF) << 16) | (sgi & 0xF);
    }
};

/// The private timer interrupts (PPIs).
pub const irq_physical_timer: u32 = 29;
pub const irq_physical_timer_ns: u32 = 30;
pub const irq_spurious: u32 = 1023;
