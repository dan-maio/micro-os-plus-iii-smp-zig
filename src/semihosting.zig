//! ARM semihosting on AArch64: the trap of the kernel's `uos.semihosting`
//! (every operation lives there), `hlt #0xF000`; SYS_EXIT gets a
//! {reason, status} block. Here also the per-CPU line-buffered console
//! mirror.

const uos = @import("uos");
const arch = @import("arch.zig");


pub fn call(op: usize, arg: usize) usize {
    const daif = arch.getDaif();
    arch.disableIrq();
    defer arch.restoreIrq(daif);
    return asm volatile ("hlt #0xF000"
        : [ret] "={x0}" (-> usize),
        : [op] "{x0}" (op),
          [arg] "{x1}" (arg),
        : .{ .x2 = true, .x3 = true, .memory = true });
}

/// SYS_EXIT gets a {reason, status} block.
pub const exit_by_block = true;

/// SYS_WRITE0: print NUL-terminated string.
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

/// Append bytes to this CPU's buffer; flush on newline.
pub fn mirror(bytes: []const u8) void {
    const daif = arch.getDaif();
    arch.disableIrq();
    defer arch.restoreIrq(daif);
    const cpu = arch.cpuId();
    if (cpu >= ncpu) return;
    for (bytes) |c| {
        if (lens[cpu] + 1 >= buf_size) flushCpu(cpu);
        bufs[cpu][lens[cpu]] = c;
        lens[cpu] += 1;
        if (c == '\n' or c == '\r') flushCpu(cpu);
    }
}

pub fn flush() void {
    const daif = arch.getDaif();
    arch.disableIrq();
    defer arch.restoreIrq(daif);
    const cpu = arch.cpuId();
    if (cpu < ncpu) flushCpu(cpu);
}
