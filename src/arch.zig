//! Cortex-M core registers and instructions (the CMSIS `__get_*`/`__set_*`
//! intrinsics) and the profile facts the port depends on.

const std = @import("std");
const builtin = @import("builtin");
const microzig = @import("microzig");

const cpu_name = microzig.config.cpu_name;

/// ARMv6-M (Cortex-M0/M0+): no BASEPRI, no STMDB, LDM/STM on r0-r7 only.
pub const is_armv6m = std.mem.eql(u8, cpu_name, "cortex_m0") or std.mem.eql(u8, cpu_name, "cortex_m0plus");

/// Hard float: the context switch saves s16-s31 for threads using the FPU.
pub const has_fpu = builtin.abi.float() == .hard;

/// Implemented NVIC priority bits.
pub const nvic_prio_bits: u3 = blk: {
    const props = microzig.chip.properties;
    if (@hasField(@TypeOf(props), "interrupt_priority_bits")) {
        if (props.interrupt_priority_bits) |bits| break :blk @intCast(bits);
    }
    break :blk if (is_armv6m) 2 else 4;
};

/// The lowest priority, as written to the 8-bit priority registers.
pub const lowest_priority_byte: u8 = 0xFF;

pub inline fn getPrimask() u32 {
    return asm volatile ("mrs %[r], primask"
        : [r] "=r" (-> u32),
    );
}

pub inline fn setPrimask(v: u32) void {
    asm volatile ("msr primask, %[v]"
        :
        : [v] "r" (v),
        : .{ .memory = true });
}

pub inline fn disableIrq() void {
    asm volatile ("cpsid i" ::: .{ .memory = true });
}

pub inline fn enableIrq() void {
    asm volatile ("cpsie i" ::: .{ .memory = true });
}

pub inline fn getBasepri() u32 {
    if (is_armv6m) @compileError("no BASEPRI on ARMv6-M");
    return asm volatile ("mrs %[r], basepri"
        : [r] "=r" (-> u32),
    );
}

pub inline fn setBasepri(v: u32) void {
    if (is_armv6m) @compileError("no BASEPRI on ARMv6-M");
    asm volatile ("msr basepri, %[v]"
        :
        : [v] "r" (v),
        : .{ .memory = true });
}

/// Raise BASEPRI only (never lowers it).
pub inline fn setBasepriMax(v: u32) void {
    if (is_armv6m) @compileError("no BASEPRI on ARMv6-M");
    asm volatile ("msr basepri_max, %[v]"
        :
        : [v] "r" (v),
        : .{ .memory = true });
}

pub inline fn getIpsr() u32 {
    return asm volatile ("mrs %[r], ipsr"
        : [r] "=r" (-> u32),
    );
}

pub inline fn getMsp() u32 {
    return asm volatile ("mrs %[r], msp"
        : [r] "=r" (-> u32),
    );
}

pub inline fn setMsp(v: u32) void {
    asm volatile ("msr msp, %[v]"
        :
        : [v] "r" (v),
        : .{ .memory = true });
}

pub inline fn setPsp(v: u32) void {
    asm volatile ("msr psp, %[v]"
        :
        : [v] "r" (v),
        : .{ .memory = true });
}

pub inline fn getControl() u32 {
    return asm volatile ("mrs %[r], control"
        : [r] "=r" (-> u32),
    );
}

pub inline fn setControl(v: u32) void {
    asm volatile ("msr control, %[v]"
        :
        : [v] "r" (v),
        : .{ .memory = true });
}

pub inline fn dsb() void {
    asm volatile ("dsb" ::: .{ .memory = true });
}

pub inline fn isb() void {
    asm volatile ("isb" ::: .{ .memory = true });
}

pub inline fn dmb() void {
    asm volatile ("dmb" ::: .{ .memory = true });
}

pub inline fn wfi() void {
    asm volatile ("wfi" ::: .{ .memory = true });
}

pub inline fn nop() void {
    asm volatile ("nop");
}

pub const CONTROL_SPSEL: u32 = 1 << 1;
pub const CONTROL_FPCA: u32 = 1 << 2;

/// Memory mapped System Control Space registers (fixed on every Cortex-M).
pub const scs = struct {
    pub const ICSR: *volatile u32 = @ptrFromInt(0xE000_ED04);
    pub const VTOR: *volatile u32 = @ptrFromInt(0xE000_ED08);
    pub const SHPR3: *volatile u32 = @ptrFromInt(0xE000_ED20);
    pub const CPACR: *volatile u32 = @ptrFromInt(0xE000_ED88);
    pub const FPCCR: *volatile u32 = @ptrFromInt(0xE000_EF34);
    pub const DHCSR: *volatile u32 = @ptrFromInt(0xE000_EDF0);

    pub const SYST_CSR: *volatile u32 = @ptrFromInt(0xE000_E010);
    pub const SYST_RVR: *volatile u32 = @ptrFromInt(0xE000_E014);
    pub const SYST_CVR: *volatile u32 = @ptrFromInt(0xE000_E018);

    pub const NVIC_ISER: [*]volatile u32 = @ptrFromInt(0xE000_E100);
    pub const NVIC_ICER: [*]volatile u32 = @ptrFromInt(0xE000_E180);
    pub const NVIC_ICPR: [*]volatile u32 = @ptrFromInt(0xE000_E280);
    pub const NVIC_IPR: [*]volatile u32 = @ptrFromInt(0xE000_E400);

    pub const ICSR_PENDSVSET: u32 = 1 << 28;
    pub const ICSR_PENDSVCLR: u32 = 1 << 27;
    pub const ICSR_PENDSTSET: u32 = 1 << 26;

    pub const FPCCR_ASPEN: u32 = 1 << 31;
    pub const FPCCR_LSPEN: u32 = 1 << 30;
};

/// Set the priority of external interrupt `irq` (word access, as ARMv6-M
/// requires).
pub fn nvicSetPriority(irq: u32, prio: u8) void {
    const reg = &scs.NVIC_IPR[irq / 4];
    const shift: u5 = @intCast((irq % 4) * 8);
    reg.* = (reg.* & ~(@as(u32, 0xFF) << shift)) | (@as(u32, prio) << shift);
}

pub fn nvicGetPriority(irq: u32) u8 {
    const shift: u5 = @intCast((irq % 4) * 8);
    return @truncate(scs.NVIC_IPR[irq / 4] >> shift);
}

pub fn nvicEnable(irq: u32) void {
    scs.NVIC_ISER[irq / 32] = @as(u32, 1) << @intCast(irq % 32);
}

pub fn nvicDisable(irq: u32) void {
    scs.NVIC_ICER[irq / 32] = @as(u32, 1) << @intCast(irq % 32);
}

pub fn nvicClearPending(irq: u32) void {
    scs.NVIC_ICPR[irq / 32] = @as(u32, 1) << @intCast(irq % 32);
}

/// PendSV and SysTick at the lowest priority (SHPR3 bytes 2 and 3).
pub fn setPendSvSysTickLowest() void {
    scs.SHPR3.* = (scs.SHPR3.* & 0x0000_FFFF) | 0xFFFF_0000;
}

/// Configure SysTick for `ticks` processor clocks per interrupt.
pub fn sysTickConfig(ticks: u32) void {
    std.debug.assert(ticks - 1 <= 0x00FF_FFFF);
    scs.SYST_RVR.* = ticks - 1;
    scs.SYST_CVR.* = 0;
    scs.SYST_CSR.* = 0b111; // CLKSOURCE = processor, TICKINT, ENABLE
}

/// True when a debugger is attached (DHCSR.C_DEBUGEN). ARMv6-M software
/// cannot read the debug registers, so it always answers true there.
pub fn debuggerAttached() bool {
    if (is_armv6m) return true;
    return (scs.DHCSR.* & 1) != 0;
}

/// Enable CP10/CP11 and the automatic + lazy FP state preservation, and
/// clear CONTROL.FPCA (no FP context at boot).
pub fn fpuEnableStacking() void {
    if (!has_fpu) return;
    scs.CPACR.* |= 0xF << 20;
    dsb();
    isb();
    scs.FPCCR.* |= scs.FPCCR_ASPEN | scs.FPCCR_LSPEN;
    setControl(getControl() & ~CONTROL_FPCA);
    dsb();
    isb();
}
