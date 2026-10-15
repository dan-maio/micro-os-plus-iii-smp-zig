//! smp-test4 -- Kernel objects across CPUs (Raspberry Pi 4 B).
//!
//! Exercises cross-core synchronization and communication primitives:
//! EventFlags, MessageQueue, MemoryPool, ConditionVariable, and Mutex
//! across multiple Cortex-A72 cores.

const std = @import("std");
const uos = @import("uos");
const board = @import("board");
const suites = @import("uos_suites");
const rtos = uos.rtos;
const uart = board.uart;

pub const uos_options = board.options(4);

pub fn main() void {
    uart.init();
    uart.print("\n\n+== " ++ board.banner_short ++ " µOS++ SMP TEST 4 : cross-CPU kernel objects ==+\n\n", .{});
    rtos.run(osMain);
}

fn osMain() void {
    _ = rtos.interrupts.UncriticalSection.enter();

    uart.print("os_main on core {d}\n", .{uos.port.scheduler.cpuId()});
    uart.print("Releasing secondary cores 1..3...\n", .{});
    board.smp.startSecondaryCores();

    const waited = board.smp.waitSecondaries(3000);
    uart.print("join: {s} ({d}ms)\n", .{ board.smp.joinSummary(), waited });

    suites.smp.crossObjects();

    const failed = suites.check.failures;
    uart.puts("\n==== RESULT ====\n");
    if (failed == 0) {
        uart.puts("RESULT: PASS\n");
        board.hw_result.ok();
    } else {
        uart.print("RESULT: FAIL ({d} checks failed)\n", .{failed});
        board.hw_result.fail();
    }
}
