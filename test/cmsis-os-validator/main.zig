//! cmsis-os-validator -- the Arm CMSIS-RTOS v1 validator on Raspberry Pi 4 B
//! (the C++ test/rpi4b/cmsis-os-validator).
//!
//! The validator is C: its sources (the arm-cmsis-rtos-validator xPack)
//! are compiled over the kernel's CMSIS-RTOS v1 layer (cmsis_os.zig) and C API.
//! On AArch64 / BCM2711, NVIC IRQ 0 is emulated using GIC-400 SGI 1.

const std = @import("std");
const builtin = @import("builtin");
const uos = @import("uos");
const board = @import("board");
const gic_mod = uos.port.gic_mod;

pub const uos_options: uos.Options = blk: {
    var o = board.options(1);
    o.main_stack_size_bytes = 16384;
    o.c_api = true;
    o.cmsis_os = true;
    o.c_runtime = true;
    break :blk o;
};

extern fn os_main(argc: c_int, argv: ?[*]?[*:0]u8) c_int;
extern fn ARM_CMSIS_VALIDATOR_IRQHandler() callconv(.c) void;

export var SystemCoreClock: u32 = 1500000000;
export var uos_validator_irq_enabled: bool = false;
export var uos_validator_irq_pending: bool = false;

export fn NVIC_EnableIRQ(_: c_int) callconv(.c) void {
    uos_validator_irq_enabled = true;
    uos.port.arch.dmbIsh();
    if (uos_validator_irq_pending) {
        uos_validator_irq_pending = false;
        uos.port.gic.sendSgi(1, uos.port.arch.cpuId());
    }
}

export fn NVIC_DisableIRQ(_: c_int) callconv(.c) void {
    uos_validator_irq_enabled = false;
    uos.port.arch.dmbIsh();
}

export fn NVIC_SetPendingIRQ(_: c_int) callconv(.c) void {
    uos.port.gic.sendSgi(1, uos.port.arch.cpuId());
}

pub fn uos_external_irq(iar: u32) void {
    const id = gic_mod.Gic.intidOf(iar);
    if (id == 1) {
        if (uos_validator_irq_enabled) {
            ARM_CMSIS_VALIDATOR_IRQHandler();
        } else {
            uos_validator_irq_pending = true;
        }
    }
}

pub fn main() void {
    board.uart.init();
    uos.rtos.run(osMain);
}

fn osMain() void {
    // Pin main thread to core 0 as CMSIS-RTOS assumes single-core priority preemption
    uos.rtos.this_thread.thread().setCpuAffinity(1 << 0);
    uos.rtos.this_thread.yield();

    board.uart.print("\nStarting CMSIS-RTOS v1 Validator on Cortex-A72...\n", .{});
    const code = os_main(0, null);
    board.uart.print("\nRESULT: {s}\n", .{if (code == 0) "PASS" else "FAIL"});
    if (code == 0) board.hw_result.ok();
    board.hw_result.fail();
}
