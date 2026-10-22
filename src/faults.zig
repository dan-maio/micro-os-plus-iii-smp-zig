//! AArch64 synchronous / asynchronous exception reporting.

const arch = @import("arch.zig");
const board = @import("uos_board");

export fn port_fatal_exception(vector_id: u64, esr: u64, elr: u64, far: u64, spsr: u64) callconv(.c) noreturn {
    arch.disableIrq();

    const cpu = arch.cpuId();
    // The faulting instruction, only where it can be read: a PC that is not
    // 4-byte aligned or outside RAM (a jump to a junk address, itself a
    // common cause of the exception) would fault, or trip the alignment
    // check of @ptrFromInt, here in the report and lose it.
    const code: u64 = if (elr & 3 == 0 and elr >= board.ram_base and elr < board.ram_end)
        @as(*const u32, @ptrFromInt(elr)).*
    else
        0xFFFF_FFFF_FFFF_FFFF;
    board.uartPrint(
        "\n!!! FATAL EXCEPTION on CPU {d} (vector 0x{x}) !!!\n" ++
            "  ESR_EL1  = 0x{x:0>16} (EC=0x{x:0>2} ISS=0x{x})\n" ++
            "  ELR_EL1  = 0x{x:0>16} (code 0x{x:0>8}{s})\n" ++
            "  FAR_EL1  = 0x{x:0>16}\n" ++
            "  SPSR_EL1 = 0x{x:0>16}\n\n",
        .{ cpu, vector_id, esr, (esr >> 26) & 0x3F, esr & 0x1FFFFFF, elr, code & 0xFFFF_FFFF, if (code > 0xFFFF_FFFF) ", not readable: PC unaligned or outside RAM" else "", far, spsr },
    );

    while (true) arch.wfi();
}
