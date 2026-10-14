//! Semaphores (`os::rtos::semaphore`, `src/rtos/os-semaphore.cpp`).
//!
//! POSIX semantics, binary or counting; `post()` may be called from
//! interrupt handlers.
//!
//! ```zig
//! var sem: uos.rtos.Semaphore = .counting("beats", 8, 0);
//! try sem.post();      // from an ISR too
//! try sem.wait();
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

const tr = config.options.trace;

pub const Count = i16;
pub const max_count_value: Count = 0x7FFF;

pub const Attributes = struct {
    initial_value: Count = 0,
    max_value: Count = 1,
    clock: ?*clocks.Clock = null,
};

pub const Semaphore = struct {
    name: [:0]const u8 = "-",
    list: lists.WaitingThreadsList = .{},
    clock: *clocks.Clock = &clocks.sysclock,
    initial_value: Count = 0,
    count: Count = 0,
    max_value: Count = 1,

    /// A binary semaphore (`semaphore_binary`).
    pub fn binary(name: [:0]const u8, initial_value: Count) Semaphore {
        return .initWith(name, .{ .initial_value = initial_value, .max_value = 1 });
    }

    /// A counting semaphore (`semaphore_counting`).
    pub fn counting(name: [:0]const u8, max_value: Count, initial_value: Count) Semaphore {
        return .initWith(name, .{ .initial_value = initial_value, .max_value = max_value });
    }

    pub fn initWith(name: [:0]const u8, attr: Attributes) Semaphore {
        return .{
            .name = name,
            .clock = attr.clock orelse &clocks.sysclock,
            .initial_value = attr.initial_value,
            .count = attr.initial_value,
            .max_value = attr.max_value,
        };
    }

    /// Initialise in place, validating the values.
    pub fn init(sem: *Semaphore, name: [:0]const u8, attr: Attributes) Error!void {
        if (tr.semaphore) trace.print("Semaphore.init() @{*} {s} {d}/{d}\n", .{ sem, name, attr.initial_value, attr.max_value });
        if (interrupts.inHandlerMode()) return error.NotPermitted;
        if (attr.max_value <= 0 or attr.initial_value < 0 or attr.initial_value > attr.max_value)
            return error.InvalidArgument;
        sem.* = initWith(name, attr);
    }

    pub fn deinit(sem: *Semaphore) void {
        assert(sem.list.isEmpty());
    }

    fn tryTake(sem: *Semaphore) ?void {
        if (sem.count > 0) {
            sem.count -= 1;
            return {};
        }
        return null;
    }

    /// Release the semaphore; wakes one waiter. `error.Again` when it is
    /// already at its maximum value. Can be called from ISRs.
    pub fn post(sem: *Semaphore) Error!void {
        assert(interrupts.isPriorityValid());
        {
            const cs = interrupts.CriticalSection.enter();
            defer cs.exit();
            if (sem.count >= sem.max_value) return error.Again;
            sem.count += 1;
            if (tr.semaphore) trace.print("Semaphore.post() @{*} {s} count {d}\n", .{ sem, sem.name, sem.count });
        }
        _ = sem.list.resumeOne();
    }

    /// Take the semaphore, waiting as long as needed.
    pub fn wait(sem: *Semaphore) Error!void {
        if (tr.semaphore) trace.print("Semaphore.wait() @{*} {s}\n", .{ sem, sem.name });
        return scheduler.waitFor(void, &sem.list, sem.clock, null, sem, tryTake);
    }

    /// Take the semaphore only if available (`error.WouldBlock` otherwise).
    /// Can be called from ISRs.
    pub fn tryWait(sem: *Semaphore) Error!void {
        assert(interrupts.isPriorityValid());
        const cs = interrupts.CriticalSection.enter();
        defer cs.exit();
        return sem.tryTake() orelse error.WouldBlock;
    }

    /// Take the semaphore, waiting at most `timeout` ticks.
    pub fn timedWait(sem: *Semaphore, timeout: clocks.Duration) Error!void {
        if (tr.semaphore) trace.print("Semaphore.timedWait({d}) @{*} {s}\n", .{ timeout, sem, sem.name });
        return scheduler.waitFor(void, &sem.list, sem.clock, timeout, sem, tryTake);
    }

    /// The current value (0 when threads wait).
    pub fn value(sem: *const Semaphore) Count {
        return @max(sem.count, 0);
    }

    pub fn initialValue(sem: *const Semaphore) Count {
        return sem.initial_value;
    }

    pub fn maxValue(sem: *const Semaphore) Count {
        return sem.max_value;
    }

    /// Back to the initial value; all waiters are resumed.
    pub fn reset(sem: *Semaphore) Error!void {
        if (interrupts.inHandlerMode()) return error.NotPermitted;
        const cs = interrupts.CriticalSection.enter();
        defer cs.exit();
        sem.count = sem.initial_value;
        sem.list.resumeAll();
    }
};
