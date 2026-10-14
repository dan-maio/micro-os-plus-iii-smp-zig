//! smp-test0 -- bring-up on one active CPU (the C++ test/native/smp_test0).
//!
//! The banner, then ten heartbeats one second apart on CPU 0, then the
//! verdict. As in C++, the board has 4 CPUs and the secondary ones are not
//! started.
//!
//! Differences from C++: the kernel's startup prints its version banner (the
//! C++ test replaces main() and skips it); the C++ allocator traces
//! (`first_fit_top(...)`, `scheduler::start()`) are the C++ kernel's own and
//! do not exist here.

const uos = @import("uos");
const board = @import("board");
const uart = board.uart;

pub const uos_options: uos.Options = .{
    .ncpu = 4,
    .smp = true,
    .main_stack_size_bytes = 8192 * @sizeOf(uos.port.StackElement),
    .default_stack_size_bytes = 64 * 1024,
    .idle_stack_size_bytes = 64 * 1024,
    .min_stack_size_bytes = 32 * 1024,
    // The board's 32 MiB free store.
    .dynamic_memory_size_bytes = 0,
};

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
