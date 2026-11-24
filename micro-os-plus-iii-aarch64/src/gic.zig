//! GIC-400 (ARM Generic Interrupt Controller v2) for BCM2711 / Raspberry Pi 4 B.
//! Handles Distributor (GICD) and CPU Interface (GICC) for both real hardware (EL1 Non-Secure)
//! and QEMU raspi4b (GIC without Security Extensions).

const arch = @import("arch.zig");

pub const Gic = struct {
    gicd: usize,
    gicc: usize,

    // Distributor offsets
    const GICD_CTLR = 0x000;
    const GICD_TYPER = 0x004;
    const GICD_IGROUPR0 = 0x080;
    const GICD_ISENABLER0 = 0x100;
    const GICD_ICENABLER0 = 0x180;
    const GICD_ICPENDR0 = 0x280;
    const GICD_IPRIORITYR0 = 0x400;
    const GICD_ITARGETSR0 = 0x800;
    const GICD_ICFGR0 = 0xC00;
    const GICD_SGIR = 0xF00;

    // CPU interface offsets
    const GICC_CTLR = 0x000;
    const GICC_PMR = 0x004;
    const GICC_BPR = 0x008;
    const GICC_IAR = 0x00C;
    const GICC_EOIR = 0x010;

    fn d(g: Gic, off: usize) *volatile u32 {
        return @ptrFromInt(g.gicd + off);
    }

    fn c(g: Gic, off: usize) *volatile u32 {
        return @ptrFromInt(g.gicc + off);
    }

    /// Check if IGROUPR is writable (e.g. under QEMU raspi4b or secure view).
    fn groupsVisible(g: Gic) bool {
        return g.d(GICD_IGROUPR0).* != 0;
    }

    /// Distributor initialization: called once on core 0.
    pub fn initDistributor(g: Gic) void {
        const lines = ((g.d(GICD_TYPER).* & 0x1F) + 1) * 32;

        // Shared peripheral interrupts: Group 1, disabled, cleared, to core 0.
        var n: usize = 32;
        while (n < lines) : (n += 32) {
            g.d(GICD_IGROUPR0 + (n / 32) * 4).* = 0xFFFF_FFFF;
            g.d(GICD_ICENABLER0 + (n / 32) * 4).* = 0xFFFF_FFFF;
            g.d(GICD_ICPENDR0 + (n / 32) * 4).* = 0xFFFF_FFFF;
        }

        n = 32;
        while (n < lines) : (n += 4) {
            g.d(GICD_ITARGETSR0 + n).* = 0x0101_0101;
        }

        // Core 0's banked SGIs and PPIs to Group 1
        g.d(GICD_IGROUPR0).* = 0xFFFF_FFFF;

        // Enable forwarding
        const vis = g.groupsVisible();
        g.d(GICD_CTLR).* = if (vis) 0x3 else 0x1;
        arch.dsb();
    }

    /// CPU interface initialization: called on EVERY core.
    pub fn initThisCore(g: Gic) void {
        // SGIs (0-15) and PPIs (16-31) banked per core
        g.d(GICD_IGROUPR0).* = 0xFFFF_FFFF;

        g.setPriority(INTID_IPI, PRIORITY);
        g.setPriority(INTID_TIMER_PNS, PRIORITY);

        g.d(GICD_ISENABLER0).* = (@as(u32, 1) << INTID_IPI) | (@as(u32, 1) << INTID_TIMER_PNS);

        g.c(GICC_PMR).* = 0xFF; // let all priorities through
        g.c(GICC_BPR).* = 0;

        // EnableGrp0 | EnableGrp1 | AckCtl if groups visible; else bit 0 (EnableGrp1)
        const vis = g.groupsVisible();
        g.c(GICC_CTLR).* = if (vis) 0x7 else 0x1;

        arch.dsb();
        arch.isb();
    }

    pub fn acknowledge(g: Gic) u32 {
        return g.c(GICC_IAR).*;
    }

    pub fn endOfInterrupt(g: Gic, iar: u32) void {
        g.c(GICC_EOIR).* = iar;
    }

    pub inline fn intidOf(iar: u32) u32 {
        return iar & 0x3FF;
    }

    pub fn setPriority(g: Gic, intid: u32, prio: u8) void {
        const reg = g.d(GICD_IPRIORITYR0 + (intid & ~@as(u32, 3)));
        const shift: u5 = @intCast((intid & 3) * 8);
        reg.* = (reg.* & ~(@as(u32, 0xFF) << shift)) | (@as(u32, prio) << shift);
    }

    pub fn enableIrq(g: Gic, intid: u32) void {
        g.d(GICD_ISENABLER0 + (intid / 32) * 4).* = @as(u32, 1) << @intCast(intid % 32);
        arch.dsb();
    }

    pub fn disableIrq(g: Gic, intid: u32) void {
        g.d(GICD_ICENABLER0 + (intid / 32) * 4).* = @as(u32, 1) << @intCast(intid % 32);
        arch.dsb();
    }

    /// Send SGI to a target core.
    pub fn sendSgi(g: Gic, intid: u32, target_core: u32) void {
        arch.dsb();
        const target_mask: u32 = (@as(u32, 1) << @intCast(target_core & 7)) << 16;
        const nsatt: u32 = 1 << 15; // Group 1 SGI
        g.d(GICD_SGIR).* = target_mask | nsatt | (intid & 0xF);
        arch.dsb();
    }

    pub fn sendIpi(g: Gic, target_core: u32) void {
        g.sendSgi(INTID_IPI, target_core);
    }
};

pub const INTID_IPI: u32 = 0; // SGI 0: reschedule IPI
pub const INTID_TIMER_PNS: u32 = 30; // CNTPNSIRQ: EL1 non-secure physical timer PPI
pub const INTID_SPURIOUS: u32 = 1023;
pub const INTID_SPURIOUS_OTHER_GROUP: u32 = 1022;

pub const PRIORITY: u8 = 0xA0;
