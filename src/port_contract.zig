//! The port contract.
//!
//! In C++ every port supplies `cmsis-plus/rtos/port/os-decls.h`,
//! `os-inlines.h` and `src/rtos/os-core.cpp`, and the kernel includes them by
//! fixed path. In Zig the port is one module, imported by the kernel as
//! `uos_port`, which must declare what is listed here. `validate()` checks it
//! at compile time, so a port that misses a piece fails with a message that
//! names the piece, not with an error deep inside the scheduler.
//!
//! ```zig
//! // Stacks
//! pub const StackElement = u32;
//! pub const stack_alignment: usize = 8;
//!
//! // Per-thread machine context. `stack_ptr` is the saved stack pointer; the
//! // SMP scheduler treats `null` as "live in some CPU's registers".
//! pub const Context = struct { stack_ptr: ?[*]StackElement = null };
//! pub fn contextCreate(ctx: *Context, stack: []StackElement,
//!     entry: *const fn (?*anyopaque) callconv(.c) noreturn, arg: ?*anyopaque) void;
//!
//! pub const interrupts = struct {
//!     pub const State = u32;
//!     pub fn criticalEnter() State;  pub fn criticalExit(State) void;
//!     pub fn uncriticalEnter() State; pub fn uncriticalExit(State) void;
//!     pub fn inHandlerMode() bool;
//!     pub fn isPriorityValid() bool;
//! };
//!
//! pub const scheduler = struct {
//!     pub fn initialize() void;
//!     pub fn start() noreturn;            // switches to the first thread
//!     pub fn setLocked(locked: bool) bool; // returns the previous state
//!     pub fn isLocked() bool;
//!     pub fn reschedule() void;           // request a context switch
//!     pub fn waitForInterrupt() void;
//!     pub fn cpuId() u32;                 // 0 on a single-CPU build
//!     pub fn ipi(cpu: u32) void;          // cross-CPU reschedule request
//!     pub fn prepareSuspend() void;
//!     pub fn greeting(w: *std.Io.Writer) std.Io.Writer.Error!void;
//! };
//!
//! pub const clock_systick = struct { pub fn start() void; };
//! pub const clock_highres = struct {
//!     pub fn start() void;
//!     pub const has_hardware_counter: bool;
//!     pub fn hardwareCounter() u64;
//!     pub fn inputClockFrequencyHz() u32;
//!     pub fn cyclesPerTick() u32;
//!     pub fn cyclesSinceTick() u32;
//! };
//!
//! // The trace channel (semihosting, UART, ITM, RTT...).
//! pub const trace = struct { pub fn write(bytes: []const u8) void; };
//!
//! // Optional: the interrupt (MSP) stack, for the idle check and statistics.
//! pub fn interruptStack() ?[]StackElement;
//!
//! // Optional: end the run (`os_terminate()`), from `uos.rtos.terminate()`.
//! pub fn terminate(code: u8) noreturn;
//!
//! // Optional: the ARM semihosting trap, for `uos.semihosting`.
//! pub const semihosting = struct {
//!     pub fn call(op: usize, arg: usize) usize; // BKPT 0xAB, SVC, HLT...
//!     pub const exit_by_block: bool;           // SYS_EXIT block or value
//!     pub fn attached() bool;                  // optional: a debugger is there
//! };
//! ```
//!
//! The scheduler, the threads and the lists are the kernel's; the port calls
//! back into `uos.rtos.scheduler.internalSwitchThreads()` from its context
//! switch, and into `uos.rtos.clocks.sysTickHandler()` from its tick.

const std = @import("std");

pub fn validate(comptime Port: type) void {
    comptime {
        const required_decls = .{
            "StackElement",   "stack_alignment", "Context",       "contextCreate",
            "interrupts",     "scheduler",       "clock_systick", "clock_highres",
            "trace",
        };
        for (required_decls) |name| {
            if (!@hasDecl(Port, name))
                @compileError("uos_port must declare `" ++ name ++ "` (see port_contract.zig)");
        }
        if (!@hasField(Port.Context, "stack_ptr"))
            @compileError("uos_port.Context must have a `stack_ptr` field");

        const interrupt_fns = .{ "criticalEnter", "criticalExit", "uncriticalEnter", "uncriticalExit", "inHandlerMode", "isPriorityValid" };
        for (interrupt_fns) |name| {
            if (!@hasDecl(Port.interrupts, name))
                @compileError("uos_port.interrupts must declare `" ++ name ++ "`");
        }
        const scheduler_fns = .{ "initialize", "start", "setLocked", "isLocked", "reschedule", "waitForInterrupt", "cpuId", "ipi", "prepareSuspend", "greeting" };
        for (scheduler_fns) |name| {
            if (!@hasDecl(Port.scheduler, name))
                @compileError("uos_port.scheduler must declare `" ++ name ++ "`");
        }
        const highres = .{ "start", "has_hardware_counter", "hardwareCounter", "inputClockFrequencyHz", "cyclesPerTick", "cyclesSinceTick" };
        for (highres) |name| {
            if (!@hasDecl(Port.clock_highres, name))
                @compileError("uos_port.clock_highres must declare `" ++ name ++ "`");
        }
    }
}
