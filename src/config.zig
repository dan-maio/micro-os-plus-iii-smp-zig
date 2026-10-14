//! Compile-time configuration of the kernel.
//!
//! The C++ edition reads `<cmsis-plus/os-app-config.h>` and a cloud of
//! `OS_INTEGER_*`/`OS_INCLUDE_*`/`OS_USE_*` macros. Here the application
//! declares one value in its root source file, the way `std_options` works:
//!
//! ```zig
//! pub const uos_options: uos.Options = .{
//!     .ncpu = 2,
//!     .smp = true,
//!     .trace = .{ .thread = true },
//! };
//! ```
//!
//! Anything not set keeps the default below, which matches the C++ default.

const std = @import("std");
const root = @import("root");

pub const Options = struct {
    /// Number of CPUs the scheduler manages (`OS_NCPU`).
    ncpu: u8 = 1,

    /// Use the SMP scheduler (`OS_USE_SMP_SCHEDULER`): per-CPU current
    /// thread, the recursive kernel lock and the affinity-aware pick. It may
    /// be enabled with `ncpu == 1`, which is how the C++ QEMU platforms run
    /// the SMP kernel single-core.
    smp: bool = false,

    /// SysTick rate (`OS_INTEGER_SYSTICK_FREQUENCY_HZ`).
    systick_frequency_hz: u32 = 1000,

    /// Thread stacks (`OS_INTEGER_RTOS_*_STACK_SIZE_BYTES`).
    min_stack_size_bytes: usize = 256,
    default_stack_size_bytes: usize = 2048,
    main_stack_size_bytes: usize = 4096,
    idle_stack_size_bytes: usize = 1024,

    /// `OS_BOOL_RTOS_SCHEDULER_PREEMPTIVE`.
    preemptive: bool = true,

    /// `OS_INTEGER_RTOS_CRITICAL_SECTION_INTERRUPT_PRIORITY`: when set, on
    /// ARMv7-M/v8-M single-core builds the interrupt critical sections raise
    /// BASEPRI to this level instead of masking every interrupt.
    critical_section_interrupt_priority: ?u8 = null,

    /// Put the idle thread to sleep with WFI (`!OS_EXCLUDE_RTOS_IDLE_SLEEP`).
    idle_sleep: bool = true,

    /// Run the idle thread one level below `idle`
    /// (`OS_BOOL_RTOS_THREAD_IDLE_PRIORITY_BELOW_IDLE`).
    idle_priority_below_idle: bool = false,

    /// `OS_INCLUDE_RTOS_STATISTICS_THREAD_CONTEXT_SWITCHES`.
    statistics_context_switches: bool = false,
    /// `OS_INCLUDE_RTOS_STATISTICS_THREAD_CPU_CYCLES`.
    statistics_cpu_cycles: bool = false,

    /// `OS_INCLUDE_RTOS_THREAD_PUBLIC_FLAGS_CLEAR`.
    thread_public_flags_clear: bool = true,

    /// No heap at all (`OS_EXCLUDE_DYNAMIC_MEMORY_ALLOCATIONS`): the main
    /// and idle threads use static stacks, and objects that would allocate
    /// return `error.OutOfMemory`.
    exclude_dynamic_memory_allocations: bool = false,

    /// Size of the RTOS system heap (`OS_INTEGER_RTOS_DYNAMIC_MEMORY_SIZE_BYTES`),
    /// carved from a static buffer and managed by `memory.FirstFitTop`.
    /// Zero lets the port hand over the rest of RAM, if it can.
    dynamic_memory_size_bytes: usize = 16 * 1024,

    /// The `OS_TRACE_RTOS_*` switches.
    trace: Trace = .{},

    pub const Trace = struct {
        scheduler: bool = false,
        thread: bool = false,
        thread_context: bool = false,
        thread_flags: bool = false,
        mutex: bool = false,
        semaphore: bool = false,
        condvar: bool = false,
        evflags: bool = false,
        mqueue: bool = false,
        mempool: bool = false,
        timer: bool = false,
        clocks: bool = false,
        sysclock_tick: bool = false,
        rtc_tick: bool = false,
        lists: bool = false,
        lists_clocks: bool = false,
        memory: bool = false,
    };
};

/// The resolved options of this firmware.
pub const options: Options = if (@hasDecl(root, "uos_options")) root.uos_options else .{};

pub const ncpu = options.ncpu;
pub const smp = options.smp;

comptime {
    if (ncpu == 0) @compileError("uos_options.ncpu must be at least 1");
    if (ncpu > 1 and !smp) @compileError("uos_options.ncpu > 1 requires uos_options.smp = true");
    if (ncpu > 32) @compileError("the CPU affinity mask is 32 bits wide");
}
