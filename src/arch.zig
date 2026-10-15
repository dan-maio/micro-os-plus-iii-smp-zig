//! ARMv7-A (AArch32) instructions and system registers used by the port:
//! CP15 accessors, barriers, the CPSR interrupt mask, the generic timer.

pub inline fn dsb() void {
    asm volatile ("dsb" ::: .{ .memory = true });
}

pub inline fn dmb() void {
    asm volatile ("dmb" ::: .{ .memory = true });
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

/// The CPSR I bit: IRQs masked.
pub const cpsr_i: u32 = 1 << 7;

pub inline fn getCpsr() u32 {
    return asm volatile ("mrs %[r], cpsr"
        : [r] "=r" (-> u32),
    );
}

pub inline fn disableIrq() void {
    asm volatile ("cpsid i" ::: .{ .memory = true });
}

pub inline fn enableIrq() void {
    asm volatile ("cpsie i" ::: .{ .memory = true });
}

/// Restore the I bit from a saved CPSR.
pub inline fn restoreIrq(cpsr: u32) void {
    if (cpsr & cpsr_i != 0) disableIrq() else enableIrq();
}

/// The CPU index (MPIDR.Aff0).
pub inline fn cpuId() u32 {
    const mpidr = asm volatile ("mrc p15, 0, %[r], c0, c0, 5"
        : [r] "=r" (-> u32),
    );
    return mpidr & 0xFF;
}

// ---- The generic timer (CP15 CNTFRQ, CNTPCT, CNTP_TVAL, CNTP_CTL) ----------

pub inline fn cntFrq() u32 {
    return asm volatile ("mrc p15, 0, %[r], c14, c0, 0"
        : [r] "=r" (-> u32),
    );
}

pub inline fn setCntFrq(freq: u32) void {
    asm volatile ("mcr p15, 0, %[v], c14, c0, 0"
        :
        : [v] "r" (freq),
        : .{ .memory = true });
}

/// The 64-bit physical counter.
pub inline fn cntPct() u64 {
    var lo: u32 = undefined;
    var hi: u32 = undefined;
    asm volatile ("mrrc p15, 0, %[lo], %[hi], c14"
        : [lo] "=r" (lo),
          [hi] "=r" (hi),
        :
        : .{ .memory = true });
    return (@as(u64, hi) << 32) | lo;
}

pub inline fn setCntpTval(tval: u32) void {
    asm volatile ("mcr p15, 0, %[v], c14, c2, 0"
        :
        : [v] "r" (tval),
        : .{ .memory = true });
}

pub inline fn cntpTval() u32 {
    return asm volatile ("mrc p15, 0, %[r], c14, c2, 0"
        : [r] "=r" (-> u32),
    );
}

pub inline fn setCntpCtl(ctl: u32) void {
    asm volatile ("mcr p15, 0, %[v], c14, c2, 1"
        :
        : [v] "r" (ctl),
        : .{ .memory = true });
}

// ---- Fault registers ------------------------------------------------------

pub inline fn dfsr() u32 {
    return asm volatile ("mrc p15, 0, %[r], c5, c0, 0"
        : [r] "=r" (-> u32),
    );
}

pub inline fn dfar() u32 {
    return asm volatile ("mrc p15, 0, %[r], c6, c0, 0"
        : [r] "=r" (-> u32),
    );
}

pub inline fn ifsr() u32 {
    return asm volatile ("mrc p15, 0, %[r], c5, c0, 1"
        : [r] "=r" (-> u32),
    );
}

pub inline fn ifar() u32 {
    return asm volatile ("mrc p15, 0, %[r], c6, c0, 2"
        : [r] "=r" (-> u32),
    );
}

/// MMIO access.
pub inline fn reg(addr: usize) *volatile u32 {
    return @ptrFromInt(addr);
}
