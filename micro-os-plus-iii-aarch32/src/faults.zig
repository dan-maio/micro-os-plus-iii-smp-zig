//! The exception handlers (the C++ src/handlers.cpp and
//! src/exception_handler.cpp): undefined instruction, prefetch abort and
//! data abort dump the registers and the fault status on the UART only (a
//! semihosting call is a trap of its own and could fault again), then halt
//! with "[FATAL] System halted.".
//!
//! Each entry pushes r0-r12, the faulting PC and the SPSR on the mode's own
//! stack and calls the reporter with that frame; a zero return halts.

const std = @import("std");
const board = @import("uos_board");
const arch = @import("arch.zig");

/// The frame the entries push, above the SPSR word.
pub const ExceptionContext = extern struct {
    r: [13]u32,
    lr: u32, // the faulting PC
};

const out = board.uartPrint;

fn faultStatusString(fs: u32) []const u8 {
    return switch (fs) {
        0b00001 => "Alignment fault",
        0b00010 => "Debug event",
        0b00011 => "Access flag fault (section)",
        0b00100 => "I-cache maintenance fault",
        0b00101 => "Translation fault (section)",
        0b00110 => "Access flag fault (page)",
        0b00111 => "Translation fault (page)",
        0b01000 => "Synchronous external abort",
        0b01001 => "Domain fault (section)",
        0b01011 => "Domain fault (page)",
        0b01100 => "Translation table walk (L1)",
        0b01101 => "Permission fault (section)",
        0b01110 => "Translation table walk (L2)",
        0b01111 => "Permission fault (page)",
        0b10110 => "Asynchronous external abort",
        0b11000 => "Async parity/ECC error",
        0b11001 => "Sync parity/ECC error",
        else => "Unknown fault",
    };
}

fn separator() void {
    out("+--------------------------------------------------+\n", .{});
}

fn hex32(label: []const u8, value: u32) void {
    out("  {s}: 0x{X:0>8}\n", .{ label, value });
}

fn readSpsr() u32 {
    return asm volatile ("mrs %[r], spsr"
        : [r] "=r" (-> u32),
    );
}

fn registerDump(ctx: *const ExceptionContext, fault_pc: u32, spsr: u32) void {
    out("  Register Dump (Core {X}):\n", .{arch.cpuId() & 0xF});
    out("    R0 =0x{X:0>8}  R1 =0x{X:0>8}  R2 =0x{X:0>8}  R3 =0x{X:0>8}\n", .{ ctx.r[0], ctx.r[1], ctx.r[2], ctx.r[3] });
    out("    R4 =0x{X:0>8}  R5 =0x{X:0>8}  R6 =0x{X:0>8}  R7 =0x{X:0>8}\n", .{ ctx.r[4], ctx.r[5], ctx.r[6], ctx.r[7] });
    out("    R8 =0x{X:0>8}  R9 =0x{X:0>8}  R10=0x{X:0>8}  R11=0x{X:0>8}\n", .{ ctx.r[8], ctx.r[9], ctx.r[10], ctx.r[11] });
    out("    R12=0x{X:0>8}  PC =0x{X:0>8}\n", .{ ctx.r[12], fault_pc });
    const mode: []const u8 = switch (spsr & 0x1F) {
        0x10 => "USR",
        0x11 => "FIQ",
        0x12 => "IRQ",
        0x13 => "SVC",
        0x17 => "ABT",
        0x1B => "UND",
        0x1F => "SYS",
        else => "???",
    };
    out("    SPSR=0x{X:0>8} [{c}{c}{c}{c}] Mode={s} IRQ={s} FIQ={s}\n", .{
        spsr,
        @as(u8, if (spsr & (1 << 31) != 0) 'N' else 'n'),
        @as(u8, if (spsr & (1 << 30) != 0) 'Z' else 'z'),
        @as(u8, if (spsr & (1 << 29) != 0) 'C' else 'c'),
        @as(u8, if (spsr & (1 << 28) != 0) 'V' else 'v'),
        mode,
        if (spsr & 0x80 != 0) "off" else "on",
        if (spsr & 0x40 != 0) "off" else "on",
    });
}

fn instructionAt(address: u32) void {
    const p: *volatile u32 = @ptrFromInt(address & ~@as(u32, 3));
    out("  Instruction at 0x{X:0>8}: 0x{X:0>8}\n", .{ address, p.* });
}

fn fatal() u32 {
    out("  [FATAL] System halted.\n", .{});
    separator();
    return 0;
}

export fn handle_undefined_instruction(ctx: *const ExceptionContext, fault_pc: u32) callconv(.c) u32 {
    const spsr = readSpsr();
    const cpacr = asm volatile ("mrc p15, 0, %[r], c1, c0, 2"
        : [r] "=r" (-> u32),
    );
    var fpexc: u32 = 0xDEADDEAD;
    var fpscr: u32 = 0xDEADDEAD;
    const cp10 = (cpacr >> 20) & 3;
    const cp11 = (cpacr >> 22) & 3;
    if (cp10 != 0) {
        fpexc = asm volatile ("vmrs %[r], fpexc"
            : [r] "=r" (-> u32),
        );
        if (fpexc & (1 << 30) != 0) fpscr = asm volatile ("vmrs %[r], fpscr"
            : [r] "=r" (-> u32),
        );
    }

    separator();
    out("| EXCEPTION: Undefined Instruction               |\n", .{});
    separator();
    hex32("Faulting PC", fault_pc);
    instructionAt(fault_pc);
    hex32("CPACR", cpacr);
    out("    CP10={d} CP11={d}{s}\n", .{
        cp10, cp11,
        if (cp10 == 3 and cp11 == 3) " (full access)" else if (cp10 == 0 and cp11 == 0) " (NO ACCESS)" else " (restricted)",
    });
    if (fpexc != 0xDEADDEAD) {
        hex32("FPEXC", fpexc);
        out("    EN={d} EX={d} DEX={d}{s}\n", .{
            (fpexc >> 30) & 1,                                                     (fpexc >> 31) & 1, (fpexc >> 29) & 1,
            if (fpexc & (1 << 30) != 0) " (VFP enabled)" else " (VFP DISABLED!)",
        });
        if (fpscr != 0xDEADDEAD) {
            hex32("FPSCR", fpscr);
            out("    Traps:", .{});
            const traps = [_]struct { u5, []const u8 }{ .{ 8, " IOE" }, .{ 9, " DZE" }, .{ 10, " OFE" }, .{ 11, " UFE" }, .{ 12, " IXE" }, .{ 15, " IDE" } };
            for (traps) |t| if (fpscr & (@as(u32, 1) << t[0]) != 0) out("{s}", .{t[1]});
            if (fpscr & 0x9F00 == 0) out(" none", .{});
            out("  Flags:", .{});
            const flags = [_]struct { u5, []const u8 }{ .{ 0, " IOC" }, .{ 1, " DZC" }, .{ 2, " OFC" }, .{ 3, " UFC" }, .{ 4, " IXC" }, .{ 7, " IDC" } };
            for (flags) |f| if (fpscr & (@as(u32, 1) << f[0]) != 0) out("{s}", .{f[1]});
            if (fpscr & 0x9F == 0) out(" none", .{});
            out("\n", .{});
        }
    } else {
        out("  FPEXC: unreadable (CP10/CP11 denied by CPACR)\n", .{});
    }
    registerDump(ctx, fault_pc, spsr);
    return fatal();
}

export fn handle_prefetch_abort(ctx: *const ExceptionContext, fault_pc: u32, ifsr: u32, ifar: u32) callconv(.c) u32 {
    const spsr = readSpsr();
    separator();
    out("| EXCEPTION: Prefetch Abort                      |\n", .{});
    separator();
    hex32("Faulting PC", fault_pc);
    hex32("IFSR", ifsr);
    hex32("IFAR", ifar);
    const fs = (((ifsr >> 10) & 1) << 4) | (ifsr & 0xF);
    out("  Fault: {s}\n", .{faultStatusString(fs)});
    registerDump(ctx, fault_pc, spsr);
    return fatal();
}

export fn handle_data_abort(ctx: *const ExceptionContext, fault_pc: u32, dfsr: u32, dfar: u32) callconv(.c) u32 {
    const spsr = readSpsr();
    separator();
    out("| EXCEPTION: Data Abort                          |\n", .{});
    separator();
    hex32("Faulting PC", fault_pc);
    hex32("DFSR", dfsr);
    hex32("DFAR", dfar);
    const fs = (((dfsr >> 10) & 1) << 4) | (dfsr & 0xF);
    out("  Fault: {s}\n", .{faultStatusString(fs)});
    out("  Access: {s}\n", .{if ((dfsr >> 11) & 1 != 0) "Write" else "Read"});
    instructionAt(fault_pc);
    registerDump(ctx, fault_pc, spsr);
    return fatal();
}

// ----------------------------------------------------------------------------
// The entries (vector targets).

export fn undefined_handler() callconv(.naked) void {
    asm volatile (
        \\ sub    lr, lr, #4
        \\ push   {r0-r12, lr}
        \\ mrs    r0, spsr
        \\ push   {r0}
        \\ add    r0, sp, #4
        \\ ldr    r1, [sp, #56]
        \\ bl     handle_undefined_instruction
        \\ cmp    r0, #0
        \\ beq    1f
        \\ mov    lr, r0
        \\ pop    {r0}
        \\ msr    spsr_cxsf, r0
        \\ pop    {r0-r12}
        \\ add    sp, sp, #4
        \\ movs   pc, lr
        \\1:
        \\ wfi
        \\ b      1b
    );
}

export fn prefetch_handler() callconv(.naked) void {
    asm volatile (
        \\ sub    lr, lr, #4
        \\ push   {r0-r12, lr}
        \\ mrs    r0, spsr
        \\ push   {r0}
        \\ mrc    p15, 0, r2, c5, c0, 1
        \\ mrc    p15, 0, r3, c6, c0, 2
        \\ add    r0, sp, #4
        \\ ldr    r1, [sp, #56]
        \\ bl     handle_prefetch_abort
        \\ cmp    r0, #0
        \\ beq    1f
        \\ mov    lr, r0
        \\ pop    {r0}
        \\ msr    spsr_cxsf, r0
        \\ pop    {r0-r12}
        \\ add    sp, sp, #4
        \\ movs   pc, lr
        \\1:
        \\ wfi
        \\ b      1b
    );
}

export fn data_handler() callconv(.naked) void {
    asm volatile (
        \\ sub    lr, lr, #8
        \\ push   {r0-r12, lr}
        \\ mrs    r0, spsr
        \\ push   {r0}
        \\ mrc    p15, 0, r2, c5, c0, 0
        \\ mrc    p15, 0, r3, c6, c0, 0
        \\ add    r0, sp, #4
        \\ ldr    r1, [sp, #56]
        \\ bl     handle_data_abort
        \\ cmp    r0, #0
        \\ beq    1f
        \\ mov    lr, r0
        \\ pop    {r0}
        \\ msr    spsr_cxsf, r0
        \\ pop    {r0-r12}
        \\ add    sp, sp, #4
        \\ movs   pc, lr
        \\1:
        \\ wfi
        \\ b      1b
    );
}

/// A supervisor call. The semihosting trap is an SVC; with a debugger
/// attached the debugger takes it, without one it lands here. The C++
/// handler spins; this one returns, so a semihosting call is a no-op on a
/// board running without a probe (a deliberate deviation).
export fn svc_handler() callconv(.naked) void {
    asm volatile ("movs pc, lr");
}

export fn fiq_handler() callconv(.naked) void {
    asm volatile (
        \\1:
        \\ b      1b
    );
}
