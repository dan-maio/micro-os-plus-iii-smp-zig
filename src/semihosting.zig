//! ARM semihosting on AArch32: the trap of the kernel's `uos.semihosting`
//! (every operation lives there), as the C++ include/semihosting.hpp
//! hardware build: the Angel trap `svc 0x123456` in ARM state, taken by
//! OpenOCD; SYS_EXIT gets a pointer to the {reason, status} block.
//!
//! The console mirror is line buffered, as the C++ `uart1` one: every call
//! is a debug halt and a probe round trip, so one SYS_WRITE0 per line, not
//! one SYS_WRITEC per byte. The C++ buffer is shared by the CPUs (the tests
//! serialise the console with a mutex); here each CPU has its own, so a line
//! traced outside that mutex cannot be mixed with another CPU's.

const uos = @import("uos");
const arch = @import("arch.zig");


/// The trap. Threads run in SVC mode, so the SVC overwrites LR_svc and
/// SPSR_svc: LR is a clobber, and the IRQs are masked around it (an IRQ in
/// between would not matter for LR, but a switch could move the thread).
pub fn call(op: usize, arg: usize) usize {
    const cpsr = arch.getCpsr();
    arch.disableIrq();
    const r = asm volatile ("svc 0x123456"
        : [ret] "={r0}" (-> usize),
        : [op] "{r0}" (op),
          [arg] "{r1}" (arg),
        : .{ .r2 = true, .r3 = true, .r12 = true, .lr = true, .memory = true, .cpsr = true });
    arch.restoreIrq(cpsr);
    return r;
}

/// SYS_EXIT gets a {reason, status} block.
pub const exit_by_block = true;

/// SYS_WRITE0: a NUL-terminated string.
pub fn write0(s: [*:0]const u8) void {
    uos.semihosting.write0(s);
}

/// SYS_EXIT (the C++ `os_terminate()`).
pub fn exit(code: u8) noreturn {
    uos.semihosting.exit(code);
}

const buf_size = 256;
const ncpu = uos.config.ncpu;
var bufs: [ncpu][buf_size]u8 = undefined;
var lens: [ncpu]usize = @splat(0);

fn flushCpu(cpu: u32) void {
    if (lens[cpu] == 0) return;
    bufs[cpu][lens[cpu]] = 0;
    write0(@ptrCast(&bufs[cpu]));
    lens[cpu] = 0;
}

/// Append the bytes to this CPU's line, one SYS_WRITE0 per line.
pub fn mirror(bytes: []const u8) void {
    const cpsr = arch.getCpsr();
    arch.disableIrq();
    defer arch.restoreIrq(cpsr);
    const cpu = arch.cpuId();
    if (cpu >= ncpu) return;
    for (bytes) |c| {
        if (lens[cpu] + 1 >= buf_size) flushCpu(cpu);
        bufs[cpu][lens[cpu]] = c;
        lens[cpu] += 1;
        if (c == '\n' or c == '\r') flushCpu(cpu);
    }
}

/// Emit this CPU's partial line.
pub fn flush() void {
    const cpsr = arch.getCpsr();
    arch.disableIrq();
    defer arch.restoreIrq(cpsr);
    const cpu = arch.cpuId();
    if (cpu < ncpu) flushCpu(cpu);
}
