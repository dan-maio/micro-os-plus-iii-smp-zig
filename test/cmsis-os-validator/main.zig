//! cmsis-os-validator -- the Arm CMSIS-RTOS v1 validator (the C++ harness
//! suite tests/sources/cmsis-os-validator), on the Zig kernel.
//!
//! The validator is C: its sources (the arm-cmsis-rtos-validator xPack,
//! with its µOS++ main.c) are compiled as they are, over the kernel's
//! CMSIS-RTOS v1 layer (cmsis_os.zig) and C API (c_api.zig). The xPack is
//! not in this repository; build.zig finds it (-Dcmsis_rv=<folder>).
//!
//! As the C++ pico2 harness build: one CPU, the suite's os-app-config.h
//! (1 kHz tick, a 4000-byte main stack, no BASEPRI level: PRIMASK critical
//! sections, so the test interrupt may call the RTOS) and the board's
//! defaults for what the suite leaves unset (4096-byte default and idle
//! stacks). The validator prints with trace_printf (TRACE is defined, as in
//! the C++ debug build); the verdict is os_main()'s return code.
//!
//! The test interrupt is IRQ 0 (TIMER0_IRQ_0 on the RP2350, WWDG on the
//! STM32F4), left at its reset priority as in C++; its handler is the
//! validator's ARM_CMSIS_VALIDATOR_IRQHandler().

const std = @import("std");
const microzig = @import("microzig");
const uos = @import("uos");
const t = @import("uos_test");

pub const microzig_options = t.microzig_options;
pub const panic = t.panic;
pub const std_options = t.std_options;

pub const uos_options: uos.Options = .{
    .ncpu = 1,
    .smp = false,
    .systick_frequency_hz = 1000,
    .critical_section_interrupt_priority = null,
    .main_stack_size_bytes = 4000,
    .default_stack_size_bytes = 4096,
    .idle_stack_size_bytes = 4096,
    .dynamic_memory_size_bytes = 64 * 1024,
    .c_api = true,
    .cmsis_os = true,
    .c_runtime = true,
};

extern fn os_main(argc: c_int, argv: ?[*]?[*:0]u8) c_int;
extern fn ARM_CMSIS_VALIDATOR_IRQHandler() callconv(.c) void;

fn validatorIrq() callconv(.c) void {
    ARM_CMSIS_VALIDATOR_IRQHandler();
}

/// IRQ 0, the first external interrupt.
pub const uos_interrupts = if (@hasField(microzig.chip.VectorTable, "WWDG"))
    .{ .WWDG = microzig.interrupt.Handler{ .c = validatorIrq } }
else
    .{ .TIMER0_IRQ_0 = microzig.interrupt.Handler{ .c = validatorIrq } };

/// CMSIS-Core's SystemCoreClock: the core clock, which is the SysTick input.
export var SystemCoreClock: u32 = 0;

export fn SystemCoreClockUpdate() callconv(.c) void {
    SystemCoreClock = uos.rtos.hrclock.inputClockFrequencyHz();
}

comptime {
    t.exportStartup();
}

pub fn main() void {
    SystemCoreClockUpdate();
    uos.rtos.run(osMain);
}

fn osMain() u8 {
    const code = os_main(0, null);
    return if (code == 0) 0 else 1;
}
