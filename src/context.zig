//! Thread contexts and the PendSV context switch.
//!
//! A suspended thread's registers live on its own stack (PSP):
//!
//! ```text
//!   high   xPSR, PC, LR, r12, r3..r0     stacked by the exception entry
//!          [s0-s15, FPSCR]               lazily, when the thread used the FPU
//!          [s16-s31]                     by PendSV, when EXC_RETURN bit 4 = 0
//!   low    r4-r11, EXC_RETURN            by PendSV
//! ```
//!
//! `switchStacks()` runs on the MSP between the save and the restore; it
//! publishes the outgoing stack pointer, asks the kernel for the next thread
//! and returns its stack pointer.

const std = @import("std");
const arch = @import("arch.zig");

pub const StackElement = u32;

/// The frame `contextCreate()` builds, in the PendSV save order.
pub const Frame = extern struct {
    r4: u32,
    r5: u32,
    r6: u32,
    r7: u32,
    r8: u32,
    r9: u32,
    r10: u32,
    r11: u32,
    exc_return: u32,
    // Restored by the exception return.
    r0: u32,
    r1: u32,
    r2: u32,
    r3: u32,
    r12: u32,
    lr: u32,
    pc: u32,
    xpsr: u32,
};

pub const Context = struct {
    /// The saved stack pointer; null while the context is live in a CPU.
    stack_ptr: ?[*]StackElement = null,
};

/// Build the initial frame of a new thread at the top of `stack`, so that
/// the first PendSV "returns" into `entry(arg)`.
pub fn contextCreate(
    ctx: *Context,
    stack: []StackElement,
    entry: *const fn (?*anyopaque) callconv(.c) noreturn,
    arg: ?*anyopaque,
) void {
    const frame_words = @sizeOf(Frame) / @sizeOf(StackElement);
    // Room for at least two exception frames.
    std.debug.assert(stack.len > 2 * frame_words);

    var p: usize = @intFromPtr(stack.ptr + stack.len) - @sizeOf(Frame);
    p &= ~@as(usize, 3);
    // The hardware part (r0..xPSR) must be 8-byte aligned; the software
    // part is 9 words, so the frame base is 4 mod 8.
    if (p & 7 == 0) p -= 4;

    const f: *Frame = @ptrFromInt(p);
    const fn_addr = @intFromPtr(entry);
    f.* = .{
        .xpsr = 0x0100_0000, // Thumb bit
        .pc = fn_addr | 1,
        .lr = fn_addr + 2, // never used: the entry does not return
        .r12 = 0xCCCC_CCCC + 0x0001_0203,
        .r3 = 0x3333_3333 + 0x0001_0203,
        .r2 = 0x2222_2222 + 0x0001_0203,
        .r1 = 0x1111_1111 + 0x0001_0203,
        .r0 = @intFromPtr(arg),
        .exc_return = 0xFFFF_FFFD, // thread mode, PSP, basic frame
        .r11 = 0xBBBB_BBBB + 0x0001_0203,
        .r10 = 0xAAAA_AAAA + 0x0001_0203,
        .r9 = 0x9999_9999 + 0x0001_0203,
        .r8 = 0x8888_8888 + 0x0001_0203,
        .r7 = 0x7777_7777 + 0x0001_0203,
        .r6 = 0x6666_6666 + 0x0001_0203,
        .r5 = 0x5555_5555 + 0x0001_0203,
        .r4 = 0x4444_4444 + 0x0001_0203,
    };
    std.debug.assert(@intFromPtr(&f.r0) & 7 == 0);
    ctx.stack_ptr = @ptrFromInt(p);
}

/// PendSV, ARMv7-M / ARMv8-M Mainline: STMDB/LDMIA, and the high FP
/// registers for the threads with an extended frame.
pub fn pendSvHandlerV7m() callconv(.naked) void {
    if (arch.has_fpu) {
        asm volatile (
            \\ mrs r0, psp
            \\ isb
            \\ tst lr, #0x10
            \\ it eq
            \\ vstmdbeq r0!, {s16-s31}
            \\ stmdb r0!, {r4-r11, lr}
            \\ bl uos_port_switch_stacks
            \\ ldmia r0!, {r4-r11, lr}
            \\ tst lr, #0x10
            \\ it eq
            \\ vldmiaeq r0!, {s16-s31}
            \\ msr psp, r0
            \\ isb
            \\ bx lr
        );
    } else {
        asm volatile (
            \\ mrs r0, psp
            \\ isb
            \\ stmdb r0!, {r4-r11, lr}
            \\ bl uos_port_switch_stacks
            \\ ldmia r0!, {r4-r11, lr}
            \\ msr psp, r0
            \\ isb
            \\ bx lr
        );
    }
}

/// PendSV, ARMv6-M: no STMDB, and LDM/STM reach only r0-r7, so r8-r11 and
/// EXC_RETURN travel through r3-r7. Same frame layout as above.
pub fn pendSvHandlerV6m() callconv(.naked) void {
    asm volatile (
        \\ mrs r0, psp
        \\ isb
        \\ subs r0, #36
        \\ mov r1, r0
        \\ stmia r1!, {r4-r7}
        \\ mov r3, r8
        \\ mov r4, r9
        \\ mov r5, r10
        \\ mov r6, r11
        \\ mov r7, lr
        \\ stmia r1!, {r3-r7}
        \\ bl uos_port_switch_stacks
        \\ mov r1, r0
        \\ adds r1, #16
        \\ ldmia r1!, {r3-r7}
        \\ mov r8, r3
        \\ mov r9, r4
        \\ mov r10, r5
        \\ mov r11, r6
        \\ mov lr, r7
        \\ ldmia r0!, {r4-r7}
        \\ adds r0, #20
        \\ msr psp, r0
        \\ isb
        \\ bx lr
    );
}
