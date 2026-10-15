//! smp-test0 -- Phase-1 bring-up on one active CPU (Raspberry Pi 4 B).
//!
//! Validates the board layer: PL011 UART0 console, MMU (cacheable DRAM identity mapping),
//! ARM generic timer 1 ms tick, and the µOS++ scheduler running a thread that sleeps
//! on the system clock: 10 heartbeats 1 second apart on Core 0, then RESULT: PASS.
//! Cores 1-3 remain in the spin-table.

const uos = @import("uos");
const board = @import("board");
const uart = board.uart;

pub const uos_options = board.options(1);

pub fn main() void {
    uart.init();
    uart.puts("\n\n");
    uart.puts("+=============================================+\n");
    uart.puts("|  " ++ board.banner_long ++ "  -  µOS++ SMP TEST 0  |\n");
    uart.puts("|  Phase 1: UART + MMU + 1ms tick (core 0)    |\n");
    uart.puts("+=============================================+\n\n");
    uos.rtos.run(osMain);
}

fn osMain() void {
    uart.print("Scheduler started on core {d}. cntfrq={d} period={d}\n", .{
        uos.port.scheduler.cpuId(),
        uos.port.arch.cntFrq(),
        uos.port.clock_highres.cyclesPerTick(),
    });
    uart.print("Heartbeat via sysclock.sleepFor(1000):\n", .{});

    var beat: u32 = 0;
    while (beat < 10) : (beat += 1) {
        uart.print(
            "[tick] heartbeat {d}  os_clock={d} ms\n",
            .{ beat, @as(u32, @truncate(uos.rtos.sysclock.now())) },
        );
        uos.rtos.sysclock.sleepFor(1000) catch {};
    }

    uart.print("RESULT: PASS (10 heartbeats on core {d})\n", .{uos.port.scheduler.cpuId()});
    board.hw_result.ok();
}
