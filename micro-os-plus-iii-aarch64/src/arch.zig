//! ARMv8-A (AArch64) instructions, barriers, and system registers used by the port:
//! DAIF interrupt masking, MPIDR CPU identification, Generic Timer, cache maintenance.

pub inline fn dsb() void {
    asm volatile ("dsb sy" ::: .{ .memory = true });
}

pub inline fn dsbIsh() void {
    asm volatile ("dsb ish" ::: .{ .memory = true });
}

pub inline fn dmbIsh() void {
    asm volatile ("dmb ish" ::: .{ .memory = true });
}

pub inline fn isb() void {
    asm volatile ("isb" ::: .{ .memory = true });
}

pub inline fn wfi() void {
    asm volatile ("wfi");
}

pub inline fn wfe() void {
    asm volatile ("wfe");
}

pub inline fn sev() void {
    asm volatile ("sev" ::: .{ .memory = true });
}

pub inline fn nop() void {
    asm volatile ("nop");
}

pub inline fn clrex() void {
    asm volatile ("clrex" ::: .{ .memory = true });
}

/// DAIF I-bit: IRQs masked (bit 7 in DAIF register).
pub const daif_i: u64 = 1 << 7;

pub inline fn getDaif() u64 {
    return asm volatile ("mrs %[r], daif"
        : [r] "=r" (-> u64),
    );
}

pub inline fn setDaif(val: u64) void {
    asm volatile ("msr daif, %[v]"
        :
        : [v] "r" (val),
        : .{ .memory = true });
}

pub inline fn disableIrq() void {
    asm volatile ("msr daifset, #2" ::: .{ .memory = true });
}

pub inline fn enableIrq() void {
    asm volatile ("msr daifclr, #2" ::: .{ .memory = true });
}

pub inline fn restoreIrq(saved_daif: u64) void {
    if (saved_daif & daif_i != 0) disableIrq() else enableIrq();
}

/// The CPU index (MPIDR_EL1.Aff0, 0..3 on BCM2711).
pub inline fn cpuId() u32 {
    const mpidr = asm volatile ("mrs %[r], mpidr_el1"
        : [r] "=r" (-> u64),
    );
    return @truncate(mpidr & 0xFF);
}

/// Current Exception Level (0=EL0, 1=EL1, 2=EL2, 3=EL3).
pub inline fn currentEl() u32 {
    const el = asm volatile ("mrs %[r], CurrentEL"
        : [r] "=r" (-> u64),
    );
    return @truncate((el >> 2) & 3);
}

// ---- The Generic Timer (CNTFRQ_EL0, CNTPCT_EL0, CNTP_TVAL_EL0, CNTP_CTL_EL0) ----

pub inline fn cntFrq() u32 {
    const f = asm volatile ("mrs %[r], cntfrq_el0"
        : [r] "=r" (-> u64),
    );
    return @truncate(f);
}

pub inline fn cntPct() u64 {
    return asm volatile ("mrs %[r], cntpct_el0"
        : [r] "=r" (-> u64),
        :
        : .{ .memory = true });
}

pub inline fn setCntpTval(tval: u32) void {
    asm volatile ("msr cntp_tval_el0, %[v]"
        :
        : [v] "r" (@as(u64, tval)),
        : .{ .memory = true });
}

pub inline fn cntpTval() u32 {
    const v = asm volatile ("mrs %[r], cntp_tval_el0"
        : [r] "=r" (-> u64),
    );
    return @truncate(v);
}

pub inline fn setCntpCval(cval: u64) void {
    asm volatile ("msr cntp_cval_el0, %[v]"
        :
        : [v] "r" (cval),
        : .{ .memory = true });
}

pub inline fn cntpCval() u64 {
    return asm volatile ("mrs %[r], cntp_cval_el0"
        : [r] "=r" (-> u64),
    );
}

pub inline fn setCntpCtl(ctl: u32) void {
    asm volatile ("msr cntp_ctl_el0, %[v]"
        :
        : [v] "r" (@as(u64, ctl)),
        : .{ .memory = true });
}

pub inline fn cntpCtl() u32 {
    const v = asm volatile ("mrs %[r], cntp_ctl_el0"
        : [r] "=r" (-> u64),
    );
    return @truncate(v);
}

// ---- Cache Maintenance ----------------------------------------------------

/// Clean data cache line to Point of Coherency (PoC).
pub inline fn cleanDcacheLine(addr: usize) void {
    asm volatile ("dc cvac, %[v]"
        :
        : [v] "r" (addr),
        : .{ .memory = true });
}

/// Clean and Invalidate data cache line to Point of Coherency (PoC).
pub inline fn cleanAndInvalidateDcacheLine(addr: usize) void {
    asm volatile ("dc civac, %[v]"
        :
        : [v] "r" (addr),
        : .{ .memory = true });
}

// ---- Fault / Exception Registers ------------------------------------------

pub inline fn esrEl1() u64 {
    return asm volatile ("mrs %[r], esr_el1"
        : [r] "=r" (-> u64),
    );
}

pub inline fn elrEl1() u64 {
    return asm volatile ("mrs %[r], elr_el1"
        : [r] "=r" (-> u64),
    );
}

pub inline fn farEl1() u64 {
    return asm volatile ("mrs %[r], far_el1"
        : [r] "=r" (-> u64),
    );
}

pub inline fn spsrEl1() u64 {
    return asm volatile ("mrs %[r], spsr_el1"
        : [r] "=r" (-> u64),
    );
}

// ---- MMIO Accessors -------------------------------------------------------

pub inline fn mmioRead(addr: usize) u32 {
    const ptr: *volatile u32 = @ptrFromInt(addr);
    return ptr.*;
}

pub inline fn mmioWrite(addr: usize, val: u32) void {
    const ptr: *volatile u32 = @ptrFromInt(addr);
    ptr.* = val;
}

pub inline fn mmioRead64(addr: usize) u64 {
    const ptr: *volatile u64 = @ptrFromInt(addr);
    return ptr.*;
}

pub inline fn mmioWrite64(addr: usize, val: u64) void {
    const ptr: *volatile u64 = @ptrFromInt(addr);
    ptr.* = val;
}
