//! fp-switch -- the FPU registers survive a preemptive context switch.
//!
//! The Zig port of the C++ harness suite tests/sources/fp-switch, line for
//! line: six threads at three priorities each load s0-s31 and the FPSCR
//! flags (N, Z, C, V), spin, store the registers back and compare, for 3000
//! ticks; higher priority threads wake up in the middle of the lower ones'
//! rounds. On SMP a round that ends on another core counts as migrated.
//!
//! As the C++ pico2 build of the harness suites, the kernel runs single-core
//! (OS_NCPU=1), with the suite's os-app-config.h: BASEPRI 4, a 4000-byte
//! main stack. The verdict is the exit code (0 = PASS).

const std = @import("std");
const builtin = @import("builtin");
const microzig = @import("microzig");
const uos = @import("uos");
const t = @import("uos_test");

const rtos = uos.rtos;
const sysclock = rtos.sysclock;
const this_thread = rtos.this_thread;
const trace = uos.trace;

pub const microzig_options = t.microzig_options;
pub const panic = t.panic;
pub const std_options = t.std_options;

/// tests/sources/fp-switch/include/cmsis-plus/os-app-config.h, single-core.
pub const uos_options: uos.Options = .{
    .ncpu = 1,
    .smp = false,
    .systick_frequency_hz = 1000,
    .critical_section_interrupt_priority = 4,
    .main_stack_size_bytes = 4000,
    .default_stack_size_bytes = 2048,
    .idle_stack_size_bytes = 2048,
    .dynamic_memory_size_bytes = 64 * 1024,
};

comptime {
    t.exportStartup();
}

pub fn main() void {
    rtos.run(osMain);
}

const has_fpu = builtin.abi.float() == .hard;

const threads_count = 6;
const run_ticks = 3000;
const spin_loops: u32 = 40000;
/// FPSCR N, Z, C, V: flags only, the rounding and exception bits are left.
const fpscr_flags_mask: u32 = 0xF000_0000;

var stop: bool = false;

const Context = struct {
    id: u32 = 0,
    rounds: u32 = 0,
    bad_rounds: u32 = 0,
    migrated_rounds: u32 = 0,
};

var contexts: [threads_count]Context = @splat(.{});

/// Load in[] into s0-s31 and flags into the FPSCR, spin, store the registers
/// to out[] and return the FPSCR flags read back. The caller's FPSCR is
/// restored.
fn holdFpRegisters(in: *const [32]u32, out: *[32]u32, flags: u32) u32 {
    var in_p: [*]const u32 = in;
    var out_p: [*]u32 = out;
    var n: u32 = spin_loops;
    var saved: u32 = undefined;
    var read: u32 = undefined;
    asm volatile (
        \\ vmrs %[saved], fpscr
        \\ vldmia %[in]!, {s0-s15}
        \\ vldmia %[in]!, {s16-s31}
        \\ bic %[read], %[saved], %[mask]
        \\ orr %[read], %[read], %[flags]
        \\ vmsr fpscr, %[read]
        \\1:
        \\ subs %[n], %[n], #1
        \\ bne 1b
        \\ vmrs %[read], fpscr
        \\ vstmia %[out]!, {s0-s15}
        \\ vstmia %[out]!, {s16-s31}
        \\ vmsr fpscr, %[saved]
        : [saved] "=&r" (saved),
          [read] "=&r" (read),
          [n] "+r" (n),
          [in] "+r" (in_p),
          [out] "+r" (out_p),
        : [flags] "r" (flags),
          [mask] "r" (fpscr_flags_mask),
        : .{ .memory = true, .cpsr = true, .s0 = true, .s1 = true, .s2 = true, .s3 = true, .s4 = true, .s5 = true, .s6 = true, .s7 = true, .s8 = true, .s9 = true, .s10 = true, .s11 = true, .s12 = true, .s13 = true, .s14 = true, .s15 = true, .s16 = true, .s17 = true, .s18 = true, .s19 = true, .s20 = true, .s21 = true, .s22 = true, .s23 = true, .s24 = true, .s25 = true, .s26 = true, .s27 = true, .s28 = true, .s29 = true, .s30 = true, .s31 = true });
    return read & fpscr_flags_mask;
}

fn worker(arg: ?*anyopaque) ?*anyopaque {
    const ctx: *Context = @ptrCast(@alignCast(arg.?));
    var in: [32]u32 = undefined;
    var out: [32]u32 = undefined;

    while (!@atomicLoad(bool, &stop, .acquire)) {
        for (0..32) |k| {
            in[k] = 0x4000_0000 | (ctx.id << 16) | ((ctx.rounds & 0xFF) << 8) | @as(u32, @intCast(k));
        }
        const flags: u32 = ((ctx.id + ctx.rounds) & 0xF) << 28;

        const cpu_before = uos.port.scheduler.cpuId();
        const flags_read = holdFpRegisters(&in, &out, flags);
        if (uos.config.smp and uos.port.scheduler.cpuId() != cpu_before) ctx.migrated_rounds += 1;

        var bad = flags_read != flags;
        for (in, out) |i, o| {
            if (o != i) bad = true;
        }
        if (bad) ctx.bad_rounds += 1;
        ctx.rounds += 1;

        // Sleep now and then, so the higher priority threads wake up in the
        // middle of the lower ones' rounds.
        if (ctx.rounds % (ctx.id + 2) == 0) sysclock.sleepFor(1) catch {};
    }
    return null;
}

var threads: [threads_count]*rtos.Thread = undefined;

fn osMain() u8 {
    if (!has_fpu) {
        trace.print("\nFPU context switch test: no FPU, nothing to test\n", .{});
        return 0;
    }

    // The workers spin for most of each tick and at up to normal + 2 they can
    // take the whole CPU; keep the controller above the workers.
    this_thread.thread().setPriority(rtos.priority.high) catch {};

    trace.print("\nFPU context switch test, {d} threads, {d} ticks\n", .{ threads_count, run_ticks });

    const gpa = uos.memory.allocator();
    for (0..threads_count) |i| {
        contexts[i].id = @intCast(i);
        threads[i] = rtos.Thread.create(gpa, "fp", worker, &contexts[i], .{
            .priority = rtos.priority.normal + @as(rtos.Priority, @intCast(i % 3)),
            .stack_size_bytes = 2048,
        }) catch @panic("cannot create a worker");
    }

    sysclock.sleepFor(run_ticks) catch {};
    @atomicStore(bool, &stop, true, .release);

    var rounds: u32 = 0;
    var bad: u32 = 0;
    var migrated: u32 = 0;
    for (0..threads_count) |i| {
        _ = threads[i].join() catch {};
        threads[i].destroy();
        trace.print("thread {d}: {d} rounds, {d} bad, {d} migrated\n", .{
            i, contexts[i].rounds, contexts[i].bad_rounds, contexts[i].migrated_rounds,
        });
        rounds += contexts[i].rounds;
        bad += contexts[i].bad_rounds;
        migrated += contexts[i].migrated_rounds;
    }

    trace.print("total: {d} rounds, {d} bad, {d} migrated\n", .{ rounds, bad, migrated });
    return if (bad == 0 and rounds > 0) 0 else 1;
}
