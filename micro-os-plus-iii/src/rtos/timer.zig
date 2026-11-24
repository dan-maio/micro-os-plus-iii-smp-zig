//! Software timers (`os::rtos::timer`, `src/rtos/os-timer.cpp`).
//!
//! One-shot or periodic; the callback runs in the tick interrupt context,
//! so it must not block.
//!
//! ```zig
//! var tm: uos.rtos.Timer = .init("blink", blink, null, .periodic);
//! try tm.start(500);
//! ```

const std = @import("std");
const assert = std.debug.assert;

const config = @import("../config.zig");
const trace = @import("../trace.zig");
const Error = @import("result.zig").Error;
const interrupts = @import("interrupts.zig");
const lists = @import("lists.zig");
const clocks = @import("clocks.zig");

const tr = config.options.trace;

pub const Func = *const fn (args: ?*anyopaque) void;

pub const Run = enum(u8) { once = 0, periodic = 1 };

pub const State = enum(u8) {
    undefined = 0,
    initialized = 1,
    running = 2,
    completed = 3,
    stopped = 4,
    destroyed = 5,
};

pub const Attributes = struct {
    type: Run = .once,
    clock: ?*clocks.Clock = null,
};

pub const Timer = struct {
    name: [:0]const u8,
    func: Func,
    func_args: ?*anyopaque,
    clock: *clocks.Clock = &clocks.sysclock,
    node: lists.TimestampNode = .{ .timestamp = 0, .action = action },
    period: clocks.Duration = 0,
    type: Run = .once,
    state: State = .initialized,

    /// A timer ready to start (no runtime checks; may be a static
    /// initialiser).
    pub fn init(name: [:0]const u8, function: Func, args: ?*anyopaque, run: Run) Timer {
        return .{ .name = name, .func = function, .func_args = args, .type = run };
    }

    pub fn initWith(name: [:0]const u8, function: Func, args: ?*anyopaque, attr: Attributes) Timer {
        return .{
            .name = name,
            .func = function,
            .func_args = args,
            .type = attr.type,
            .clock = attr.clock orelse &clocks.sysclock,
        };
    }

    pub fn deinit(tm: *Timer) void {
        const cs = interrupts.CriticalSection.enter();
        defer cs.exit();
        if (tm.state == .running) tm.node.links.unlink();
        tm.state = .destroyed;
    }

    /// Start (or restart) the timer; the first callback after `period`
    /// ticks.
    pub fn start(tm: *Timer, period: clocks.Duration) Error!void {
        if (tr.timer) trace.print("Timer.start({d}) @{*} {s}\n", .{ period, tm, tm.name });
        if (interrupts.inHandlerMode()) return error.NotPermitted;
        tm.period = if (period == 0) 1 else period;
        tm.node.action = action;
        {
            const cs = interrupts.CriticalSection.enter();
            defer cs.exit();
            tm.node.timestamp = tm.clock.steady_count + tm.period;
            tm.node.links.unlink();
            tm.clock.steady_list.link(&tm.node);
            tm.state = .running;
        }
    }

    /// Stop a running timer (`error.Again` when not running).
    pub fn stop(tm: *Timer) Error!void {
        if (tr.timer) trace.print("Timer.stop() @{*} {s}\n", .{ tm, tm.name });
        if (interrupts.inHandlerMode()) return error.NotPermitted;
        // The state is checked and changed under the same lock as the
        // callback's re-arm (see action()).
        const cs = interrupts.CriticalSection.enter();
        defer cs.exit();
        if (tm.state != .running) return error.Again;
        tm.node.links.unlink();
        tm.state = .stopped;
    }

    pub fn getState(tm: *const Timer) State {
        return tm.state;
    }

    /// The clock list action: re-arm when periodic, then call back.
    ///
    /// The list check unlinks the node and calls this outside its lock, so
    /// on SMP another CPU may stop (and destroy) the timer meanwhile. The
    /// state is therefore checked, and the timer re-armed, under the lock
    /// stop() and deinit() take, and the callback and its argument are read
    /// there too: a stopped timer is never re-armed and its memory is not
    /// touched after the lock. (The C++ timer::internal_callback() re-links
    /// without the check.)
    fn action(node: *lists.TimestampNode) void {
        const tm: *Timer = @alignCast(@fieldParentPtr("node", node));
        const func, const args = blk: {
            const cs = interrupts.CriticalSection.enter();
            defer cs.exit();
            node.links.unlink();
            if (tm.state != .running) return; // stopped meanwhile
            if (tm.type == .periodic) {
                tm.node.timestamp += tm.period;
                const now = tm.clock.steadyNow();
                if (tm.node.timestamp <= now) tm.node.timestamp = now + tm.period;
                tm.clock.steady_list.link(&tm.node);
            } else {
                tm.state = .completed;
            }
            if (tr.timer) trace.puts(tm.name);
            break :blk .{ tm.func, tm.func_args };
        };
        func(args);
    }
};
