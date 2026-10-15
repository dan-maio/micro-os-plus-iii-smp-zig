//! The RK3506 Cortex-M0 firmware of smp-test-int5 (the C++
//! test/luckfox-lyra/smp_test_int5/m0/m0_start.c and m0_main.c, SysTick
//! edition): a mailbox doorbell to A7 cores 1 and 2 every ~40 ms.
//!
//!   SysTick (200 MHz CPU clock) -> exception 15 (sysTickHandler)
//!   the handler writes B2A CMD/DATA of mailbox channels 1 and 2, raising
//!   the channels' SPIs to the A7s.
//!
//! The image is linked at the M0's 0x0, which the A7 maps to System SRAM
//! (0xFFF80000) as TCM before releasing the M0. As in C++, nothing is
//! initialised at reset: there is no .data, and `g_seq` (the first word of
//! the data RAM, 0xFFF88000 to the A7) is set by m0Init().

/// The top of the stack (linker.ld).
extern const _estack: u8;

// ---- The mailbox (BB -> AP), channels 1 and 2 ------------------------------

fn mbReg(ch: u32, off: u32) *volatile u32 {
    return @ptrFromInt(0xFF29_0000 + ch * 0x1000 + off);
}

const B2A_INTEN = 0x10;
const B2A_CMD = 0x18;
const B2A_DATA = 0x1C;

// ---- SysTick ---------------------------------------------------------------

const SYST_CTRL: *volatile u32 = @ptrFromInt(0xE000_E010);
const SYST_LOAD: *volatile u32 = @ptrFromInt(0xE000_E014);
const SYST_VAL: *volatile u32 = @ptrFromInt(0xE000_E018);

/// The doorbell count. First in the data RAM (linker.ld), where the A7
/// logger reads it ("M0 seq=").
export var g_seq: u32 linksection(".m0seq") = 0;

fn maskedWrite(r: *volatile u32, mask: u32, val: u32) void {
    r.* = (mask << 16) | val;
}

fn mailboxFireBoth() void {
    const seq: *volatile u32 = &g_seq;
    const s = seq.*;
    seq.* = s +% 1;
    // Channel 1 -> A7 core 1; the DATA write raises the SPI.
    mbReg(1, B2A_CMD).* = 0x0C01_0000 | (s & 0xFFFF);
    mbReg(1, B2A_DATA).* = 0xABCD_0000 | (s & 0xFFFF);
    // Channel 2 -> A7 core 2.
    mbReg(2, B2A_CMD).* = 0x0C02_0000 | (s & 0xFFFF);
    mbReg(2, B2A_DATA).* = 0x5678_0000 | (s & 0xFFFF);
}

fn sysTickHandler() callconv(.c) void {
    mailboxFireBoth();
}

fn m0Init() void {
    @as(*volatile u32, &g_seq).* = 0;

    // Both channels' B2A tx-done interrupt to the AP (normal mode).
    maskedWrite(mbReg(1, B2A_INTEN), 0x0101, 0x0101);
    maskedWrite(mbReg(2, B2A_INTEN), 0x0101, 0x0101);

    // 40 ms at 200 MHz = 8,000,000 ticks (the counter has 24 bits).
    SYST_LOAD.* = 8_000_000 - 1;
    SYST_VAL.* = 0;
    SYST_CTRL.* = 0x07; // ENABLE, TICKINT, CLKSOURCE = CPU
}

fn resetHandler() callconv(.c) noreturn {
    m0Init();
    while (true) asm volatile ("nop");
}

fn defaultHandler() callconv(.c) void {
    while (true) {}
}

const Handler = ?*const fn () callconv(.c) void;

/// [0] = MSP, [1] = reset, [2..15] = the system exceptions (SysTick is 15),
/// [16 + n] = external IRQ n.
const VectorTable = extern struct {
    initial_sp: *const u8,
    reset: *const fn () callconv(.c) noreturn,
    nmi: Handler = defaultHandler,
    hard_fault: Handler = defaultHandler,
    reserved_4_10: [7]Handler = @splat(null),
    svc: Handler = defaultHandler,
    reserved_12_13: [2]Handler = @splat(null),
    pend_sv: Handler = defaultHandler,
    sys_tick: Handler,
    irq: [32]Handler = @splat(defaultHandler),
};

export const g_vectors: VectorTable linksection(".isr_vector") = .{
    .initial_sp = &_estack,
    .reset = resetHandler,
    .sys_tick = sysTickHandler,
};
