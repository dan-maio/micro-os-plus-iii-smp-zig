//! smp-test0 -- Phase-1 bring-up on one active CPU (the C++
//! test/luckfox-lyra/smp_test0).
//!
//! The board layer: the UART, the MMU (cacheable, shareable DRAM), the
//! generic timer's 1 ms tick, and the scheduler running a thread that sleeps
//! on the system clock: ten heartbeats one second apart on CPU 0, then the
//! verdict. CPUs 1 and 2 stay in the BootROM.
//!
//! Differences from C++: the kernel's startup prints its version banner (the
//! C++ test replaces main() and skips it). The C++ main thread's 8192-element
//! static stack is the kernel's main stack here (board.options()).

const uos = @import("uos");
const board = @import("board");
const uart = board.uart;

pub const uos_options = board.options(3);

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
    uart.print("Scheduler started on core {d}. Heartbeat via sysclock.sleep_for(1000):\n", .{uos.port.scheduler.cpuId()});

    // Exactly 10 heartbeats prove the 1 ms tick and the scheduler.
    var beat: u32 = 0;
    while (beat < 10) : (beat += 1) {
        uart.print("[tick] heartbeat {d}  os_clock={d} ms\n", .{ beat, @as(u32, @truncate(uos.rtos.sysclock.now())) });
        uos.rtos.sysclock.sleepFor(1000) catch {};
    }
    uart.print("RESULT: PASS (10 heartbeats on core {d})\n", .{uos.port.scheduler.cpuId()});
    board.hw_result.ok();
}
