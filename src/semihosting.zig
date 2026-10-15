//! ARM semihosting for AArch64 (hlt #0xF000).
//! Line-buffered output via SYS_WRITE0, exit via SYS_EXIT.

const uos = @import("uos");
const arch = @import("arch.zig");

const sys_write0: u64 = 0x04;
const sys_exit: u64 = 0x18;
const adp_stopped_application_exit: u64 = 0x20026;

inline fn call(op: u64, arg: usize) u64 {
    const daif = arch.getDaif();
    arch.disableIrq();
    defer arch.restoreIrq(daif);
    return asm volatile ("hlt #0xF000"
        : [ret] "={x0}" (-> u64),
        : [op] "{x0}" (op),
          [arg] "{x1}" (arg),
        : .{ .x2 = true, .x3 = true, .memory = true });
}

/// SYS_WRITE0: print NUL-terminated string.
pub fn write0(s: [*:0]const u8) void {
    _ = call(sys_write0, @intFromPtr(s));
}

/// SYS_EXIT with ApplicationExit and return code.
pub fn exit(code: u8) noreturn {
    var block: [2]u64 = .{ adp_stopped_application_exit, code };
    _ = call(sys_exit, @intFromPtr(&block));
    while (true) arch.wfi();
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
