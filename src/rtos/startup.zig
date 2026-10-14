//! Startup, the main thread and the idle threads (`os-main.cpp`,
//! `os-idle.cpp`).
//!
//! The C++ `main()` creates a thread for `os_main()` and starts the
//! scheduler. Here the application's `main()` hands its real entry to
//! `uos.rtos.run()`:
//!
//! ```zig
//! pub fn main() void {
//!     uos.rtos.run(appMain);
//! }
//!
//! fn appMain() !void {
//!     // runs in the "main" thread, with the scheduler started
//! }
//! ```
//!
//! When `appMain` returns, its result becomes the exit code (`void` and
//! success are 0, an error is 1) and `terminate()` ends the run through the
//! port (semihosting `SYS_EXIT` on the test boards).

const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;

const port = @import("uos_port");
const config = @import("../config.zig");
const trace = @import("../trace.zig");
const interrupts = @import("interrupts.zig");
const scheduler = @import("scheduler.zig");
const clocks = @import("clocks.zig");
const thread_mod = @import("thread.zig");
const Thread = thread_mod.Thread;
const this_thread = thread_mod.this_thread;
const priority = thread_mod.priority;

const ncpu = config.ncpu;
const opts = config.options;

pub const version = "7.0.0";

var main_thread_storage: thread_mod.ThreadInclusive(opts.main_stack_size_bytes) = undefined;
var idle_thread_storage: [ncpu]thread_mod.ThreadInclusive(opts.idle_stack_size_bytes) = undefined;

/// The thread running the application entry (`os_main_thread`).
pub var main_thread: ?*Thread = null;

const idle_names: [10][:0]const u8 = .{ "idle", "idle1", "idle2", "idle3", "idle4", "idle5", "idle6", "idle7", "idle8", "idle9" };

/// Print the greeting, create the main and idle threads, start the
/// scheduler. Never returns.
pub fn run(comptime app_main: anytype) noreturn {
    const Main = struct {
        fn trampoline(_: ?*anyopaque) ?*anyopaque {
            trace.puts("");
            terminate(callMain(app_main));
        }
    };

    // The port brings the board up (clocks) before anything is printed.
    scheduler.initialize() catch unreachable;

    trace.print("\nµOS++ IIIe version {s} (Zig {s})\n", .{ version, builtin.zig_version_string });
    trace.print("Copyright (c) 2007-2025 Liviu Ionescu\n", .{});
    {
        const cs = interrupts.CriticalSection.enter();
        defer cs.exit();
        port.scheduler.greeting(trace.writer()) catch {};
    }
    trace.print("Scheduler frequency: {d} ticks/sec\n", .{clocks.Clock.frequency_hz});
    trace.print("Default stack size: {d} bytes\n", .{thread_mod.Stack.default_size_bytes});
    if (interrupts.stack()) |st| trace.print("Interrupts stack size: {d} bytes\n", .{st.len * @sizeOf(port.StackElement)});
    trace.print("Built with Zig {s}, {s}\n\n", .{ builtin.zig_version_string, @tagName(builtin.mode) });

    main_thread_storage.init("main", Main.trampoline, null, .{
        .cpu_affinity = if (ncpu > 1) 1 else 0xFFFF_FFFF,
    }) catch @panic("cannot create the main thread");
    main_thread = &main_thread_storage.thread;

    createIdleThreads();

    scheduler.start();
}

fn createIdleThreads() void {
    for (&idle_thread_storage, 0..) |*storage, cpu| {
        storage.init(idle_names[cpu], if (cpu == 0) idleMain else idleSecondary, null, .{
            .priority = priority.idle,
            .cpu_affinity = @as(u32, 1) << @intCast(cpu),
        }) catch @panic("cannot create an idle thread");
        scheduler.idle_thread_core[cpu] = &storage.thread;
    }
}

/// Call the application entry and turn its result into an exit code.
fn callMain(comptime app_main: anytype) u8 {
    const ReturnType = @typeInfo(@TypeOf(app_main)).@"fn".return_type.?;
    switch (@typeInfo(ReturnType)) {
        .void, .noreturn => {
            app_main();
            return 0;
        },
        .int => return @intCast(app_main()),
        .error_union => |eu| {
            const value = app_main() catch |err| {
                trace.print("main() returned error.{s}\n", .{@errorName(err)});
                if (@errorReturnTrace()) |t| std.debug.dumpStackTrace(t.*);
                return 1;
            };
            return switch (@typeInfo(eu.payload)) {
                .void => 0,
                .int => @intCast(value),
                else => @compileError("main() must return void, an integer, or an error union of those"),
            };
        },
        else => @compileError("main() must return void, an integer, or an error union of those"),
    }
}

/// End the run: print the statistics, then let the port terminate
/// (semihosting `SYS_EXIT` on the test boards, a reset or a halt otherwise).
pub fn terminate(code: u8) noreturn {
    goodbye();
    if (@hasDecl(port, "terminate")) port.terminate(code);
    _ = interrupts.CriticalSection.enter();
    while (true) port.scheduler.waitForInterrupt();
}

/// `os_terminate_goodbye()`.
pub fn goodbye() void {
    if (main_thread) |th| {
        const st = th.stack();
        if (st.size() > 0) trace.print("Main thread stack: {d}/{d} bytes used\n", .{ st.size() - st.available(), st.size() });
    }
    if (interrupts.stack()) |st| {
        var unused: usize = 0;
        while (unused < st.len and st[unused] == thread_mod.stack_magic) unused += 1;
        trace.print("Interrupts stack: {d}/{d} bytes used\n", .{ (st.len - unused) * @sizeOf(port.StackElement), st.len * @sizeOf(port.StackElement) });
    }
}

// ----------------------------------------------------------------------------
// Idle.

/// Return true when the application put the CPU in a power saving mode
/// itself (`os_rtos_idle_enter_power_saving_mode_hook()`).
pub var idle_power_saving_hook: ?*const fn () bool = null;

/// Destroy the terminated threads (`os_rtos_idle_actions()`).
pub fn idleActions() void {
    while (!scheduler.terminated_threads_list.isEmpty()) {
        var th: *Thread = undefined;
        {
            const cs = interrupts.CriticalSection.enter();
            defer cs.exit();
            const node = scheduler.terminated_threads_list.first() orelse break;
            th = node.thread;

            if (config.smp) {
                // Still live on some CPU (inside its own internalExit()):
                // leave it for later, or another reaper.
                var live = @atomicLoad(?[*]port.StackElement, &th.context.port.stack_ptr, .acquire) == null;
                for (&scheduler.current_thread) |*ct| {
                    if (@atomicLoad(?*Thread, ct, .acquire) == th) live = true;
                }
                if (live) break;
            }
            if (th.state == .destroying or th.state == .destroyed) {
                // kill() owns it.
                node.links.unlink();
                continue;
            }
            th.state = .destroying;
            node.links.unlink();
        }
        th.internalDestroy();
        this_thread.yield();
    }

    if (interrupts.stack()) |st| {
        if (st.len > 0) assert(st[0] == thread_mod.stack_magic);
    }

    const saved = if (idle_power_saving_hook) |hook| hook() else false;
    if (!saved and opts.idle_sleep) port.scheduler.waitForInterrupt();
}

fn idleMain(_: ?*anyopaque) ?*anyopaque {
    if (opts.idle_priority_below_idle) {
        this_thread.thread().setPriority(priority.idle - 1) catch {};
    }
    while (true) {
        idleActions();
        this_thread.yield();
    }
}

/// The idle thread of the secondary CPUs: no reaping, just sleep.
fn idleSecondary(_: ?*anyopaque) ?*anyopaque {
    while (true) {
        if (opts.idle_sleep) port.scheduler.waitForInterrupt();
        this_thread.yield();
    }
}
