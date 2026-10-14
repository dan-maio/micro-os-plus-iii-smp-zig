//! Condition variables (`os::rtos::condition_variable`,
//! `src/rtos/os-condvar.cpp`).
//!
//! ```zig
//! try mx.lock();
//! while (!ready) try cv.wait(&mx);
//! mx.unlock() catch {};
//! ```

const std = @import("std");
const assert = std.debug.assert;

const config = @import("../config.zig");
const trace = @import("../trace.zig");
const Error = @import("result.zig").Error;
const interrupts = @import("interrupts.zig");
const scheduler = @import("scheduler.zig");
const lists = @import("lists.zig");
const clocks = @import("clocks.zig");
const Mutex = @import("mutex.zig").Mutex;

const tr = config.options.trace;

pub const Attributes = struct {
    clock: ?*clocks.Clock = null,
};

pub const ConditionVariable = struct {
    name: [:0]const u8 = "-",
    list: lists.WaitingThreadsList = .{},
    clock: *clocks.Clock = &clocks.sysclock,

    pub fn init(cv: *ConditionVariable, name: [:0]const u8, attr: Attributes) Error!void {
        if (interrupts.inHandlerMode()) return error.NotPermitted;
        cv.* = .{ .name = name, .clock = attr.clock orelse &clocks.sysclock };
    }

    pub fn deinit(cv: *ConditionVariable) void {
        assert(cv.list.isEmpty());
    }

    /// Wake one waiting thread.
    pub fn signal(cv: *ConditionVariable) Error!void {
        if (tr.condvar) trace.print("ConditionVariable.signal() @{*} {s}\n", .{ cv, cv.name });
        if (interrupts.inHandlerMode()) return error.NotPermitted;
        _ = cv.list.resumeOne();
    }

    /// Wake all waiting threads.
    pub fn broadcast(cv: *ConditionVariable) Error!void {
        if (tr.condvar) trace.print("ConditionVariable.broadcast() @{*} {s}\n", .{ cv, cv.name });
        if (interrupts.inHandlerMode()) return error.NotPermitted;
        cv.list.resumeAll();
    }

    /// Atomically release `mutex` and wait to be signalled; the mutex is
    /// locked again on return. As in POSIX, a return does not guarantee the
    /// predicate: wait in a loop.
    pub fn wait(cv: *ConditionVariable, mutex: *Mutex) Error!void {
        return cv.internalWait(mutex, null);
    }

    /// The same, waiting at most `timeout` ticks; `error.TimedOut` (with
    /// the mutex locked again) when it elapsed.
    pub fn timedWait(cv: *ConditionVariable, mutex: *Mutex, timeout: clocks.Duration) Error!void {
        return cv.internalWait(mutex, timeout);
    }

    fn internalWait(cv: *ConditionVariable, mutex: *Mutex, timeout: ?clocks.Duration) Error!void {
        if (tr.condvar) trace.print("ConditionVariable.wait() @{*} {s}\n", .{ cv, cv.name });
        if (interrupts.inHandlerMode()) return error.NotPermitted;
        if (scheduler.locked()) return error.NotPermitted;

        var w: scheduler.Waiter = .init(cv.clock, timeout);
        {
            // Link first, then release the mutex, all without a switch, so
            // a signal between the two cannot be lost.
            const scs = scheduler.CriticalSection.enter();
            defer scs.exit();
            {
                const cs = interrupts.CriticalSection.enter();
                defer cs.exit();
                w.link(&cv.list);
            }
            mutex.unlock() catch |err| {
                if (w.timed) scheduler.internalUnlinkNodeTimeout(&w.node, &w.timeout_node) else scheduler.internalUnlinkNode(&w.node);
                return err;
            };
        }

        const woke = w.sleep();
        try mutex.lock();
        woke catch |err| switch (err) {
            // The C++ edition reports only the timeout; an interruption is a
            // spurious wake-up, which POSIX allows.
            error.Interrupted => {},
            else => return err,
        };
    }
};
