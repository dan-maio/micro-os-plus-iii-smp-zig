//! AArch64 synchronous / asynchronous exception reporting.

const arch = @import("arch.zig");
const board = @import("uos_board");

export fn port_fatal_exception(vector_id: u64, esr: u64, elr: u64, far: u64, spsr: u64) callconv(.c) noreturn {
    arch.disableIrq();

    const cpu = arch.cpuId();
    const inst_ptr: *const u32 = @ptrFromInt(elr);
    board.uartPrint(
        "\n!!! FATAL EXCEPTION on CPU {d} (vector 0x{x}) !!!\n" ++
            "  ESR_EL1  = 0x{x:0>16} (EC=0x{x:0>2} ISS=0x{x})\n" ++
            "  ELR_EL1  = 0x{x:0>16} (code 0x{x:0>8})\n" ++
            "  FAR_EL1  = 0x{x:0>16}\n" ++
            "  SPSR_EL1 = 0x{x:0>16}\n\n",
        .{ cpu, vector_id, esr, (esr >> 26) & 0x3F, esr & 0x1FFFFFF, elr, inst_ptr.*, far, spsr },
    );

    while (true) arch.wfi();
}
