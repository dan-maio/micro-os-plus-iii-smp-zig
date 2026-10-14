//! Mutexes (`os::rtos::mutex`, `src/rtos/os-mutex.cpp`).
//!
//! POSIX semantics: normal, error-checking and recursive types; no
//! protocol, priority inheritance or priority ceiling; stalled or robust.
//!
//! ```zig
//! var mx: uos.rtos.Mutex = .{ .name = "mx1" };          // static, defaults
//! var rmx: uos.rtos.Mutex = .initRecursive("rmx");
//!
//! try mx.lock();
//! defer mx.unlock() catch {};
//! ```

const std = @import("std");
const assert = std.debug.assert;

const port = @import("uos_port");
const config = @import("../config.zig");
const trace = @import("../trace.zig");
const Error = @import("result.zig").Error;
const interrupts = @import("interrupts.zig");
const scheduler = @import("scheduler.zig");
const lists = @import("lists.zig");
const clocks = @import("clocks.zig");
const thread_mod = @import("thread.zig");
const Thread = thread_mod.Thread;
const Priority = thread_mod.Priority;
const priority = thread_mod.priority;
const this_thread = thread_mod.this_thread;

const tr = config.options.trace;

pub const Type = enum(u8) { normal = 0, errorcheck = 1, recursive = 2 };
pub const Protocol = enum(u8) { none = 0, inherit = 1, protect = 2 };
pub const Robustness = enum(u8) { stalled = 0, robust = 1 };

pub const max_count: u16 = 0xFFFF;

/// Creation attributes (`mutex::attributes`).
pub const Attributes = struct {
    priority_ceiling: Priority = priority.highest,
    protocol: Protocol = .inherit,
    robustness: Robustness = .stalled,
    type: Type = .normal,
    max_count: u16 = max_count,
    clock: ?*clocks.Clock = null,

    pub const recursive: Attributes = .{ .type = .recursive };
};

pub const Mutex = struct {
    name: [:0]const u8 = "-",

    owner: ?*Thread = null,
    /// Links in the owner's `mutexes` list.
    owner_links: lists.Links = .{},
    list: lists.WaitingThreadsList = .{},
    clock: *clocks.Clock = &clocks.sysclock,

    count: u16 = 0,
    initial_prio_ceiling: Priority = priority.highest,
    prio_ceiling: Priority = priority.highest,
    boosted_prio: Priority = priority.none,

    owner_dead: bool = false,
    consistent_: bool = true,
    recoverable: bool = true,

    type: Type = .normal,
    protocol: Protocol = .inherit,
    robustness: Robustness = .stalled,
    max_count: u16 = 1,

    /// A mutex with the given attributes, ready to use (no runtime checks;
    /// `init()` validates).
    pub fn initWith(name: [:0]const u8, attr: Attributes) Mutex {
        return .{
            .name = name,
            .type = attr.type,
            .protocol = attr.protocol,
            .robustness = attr.robustness,
            .max_count = if (attr.type == .recursive) attr.max_count else 1,
            .clock = attr.clock orelse &clocks.sysclock,
            .initial_prio_ceiling = attr.priority_ceiling,
            .prio_ceiling = attr.priority_ceiling,
        };
    }

    pub fn initRecursive(name: [:0]const u8) Mutex {
        return initWith(name, .recursive);
    }

    /// Initialise in place, validating the attributes.
    pub fn init(mx: *Mutex, name: [:0]const u8, attr: Attributes) Error!void {
        if (tr.mutex) trace.print("Mutex.init() @{*} {s}\n", .{ mx, name });
        if (interrupts.inHandlerMode()) return error.NotPermitted;
        if (attr.priority_ceiling < priority.lowest or attr.priority_ceiling > priority.highest)
            return error.InvalidArgument;
        mx.* = initWith(name, attr);
    }

    pub fn deinit(mx: *Mutex) void {
        if (tr.mutex) trace.print("Mutex.deinit() @{*} {s}\n", .{ mx, mx.name });
        assert(mx.owner == null);
        assert(mx.list.isEmpty());
    }

    fn internalInit(mx: *Mutex) void {
        mx.owner = null;
        mx.owner_links.unlink();
        mx.count = 0;
        mx.prio_ceiling = mx.initial_prio_ceiling;
        mx.boosted_prio = priority.none;
        mx.owner_dead = false;
        mx.consistent_ = true;
        mx.recoverable = true;
        // Wake all waiters; they will find the mutex free.
        mx.list.resumeAll();
    }

    /// Try to take the mutex for `th`. Called in a scheduler critical
    /// section. `error.WouldBlock` means "must wait".
    fn internalTryLock(mx: *Mutex, th: *Thread) Error!void {
        const saved_owner = mx.owner;
        if (mx.owner == null) {
            // The mutex is free: take it.
            if (mx.protocol == .protect and th.priority() > mx.prio_ceiling) {
                // No thread above the ceiling may lock it.
                return error.InvalidArgument;
            }
            mx.owner = th;
            mx.count = 1;
            th.mutexes.append(&mx.owner_links);
            th.acquired_mutexes += 1;

            if (mx.protocol == .protect) {
                mx.boosted_prio = mx.prio_ceiling;
                if (mx.boosted_prio > th.priorityInherited()) {
                    const us = scheduler.UncriticalSection.enter();
                    defer us.exit();
                    th.setPriorityInherited(mx.boosted_prio) catch {};
                }
            }
            if (tr.mutex) trace.print("Mutex.tryLock() @{*} {s} by {*} {s} LCK\n", .{ mx, mx.name, th, th.name });
            if (mx.owner_dead) return error.OwnerDead;
            return;
        }

        if (saved_owner == th) {
            // The mutex is already owned by the caller.
            switch (mx.type) {
                .recursive => {
                    if (mx.count >= mx.max_count) return error.Again;
                    mx.count += 1;
                    if (tr.mutex) trace.print("Mutex.tryLock() @{*} {s} >{d}\n", .{ mx, mx.name, mx.count });
                    return;
                },
                .errorcheck => return error.Deadlock,
                .normal => return error.WouldBlock, // deadlock, by POSIX
            }
        }

        // Owned by another thread.
        if (mx.protocol == .inherit) {
            const prio = th.priority();
            if (mx.boosted_prio == priority.none or prio > mx.boosted_prio) {
                mx.boosted_prio = prio;
            }
            if (mx.owner_links.isUnlinked()) {
                mx.owner.?.mutexes.append(&mx.owner_links);
            }
            // Boost the owner, if needed.
            const owner = mx.owner;
            if (owner) |o| {
                if (mx.boosted_prio > o.priorityInherited()) {
                    {
                        // Let the owner run with the boosted priority.
                        const us = scheduler.UncriticalSection.enter();
                        defer us.exit();
                        if (mx.owner == o) o.setPriorityInherited(mx.boosted_prio) catch {};
                    }
                    // The owner may have released it meanwhile.
                    if (mx.owner != o) return mx.internalTryLock(th);
                }
            }
            if (tr.mutex) trace.print("Mutex.tryLock() @{*} {s} boost {d} by {*} {s} WAIT\n", .{ mx, mx.name, mx.boosted_prio, th, th.name });
        }
        return error.WouldBlock;
    }

    /// Release the mutex on behalf of `th` (also used when a thread dies
    /// owning it).
    pub fn internalUnlock(mx: *Mutex, th: *Thread) Error!void {
        if (!mx.recoverable) return error.NotRecoverable;

        const scs = scheduler.CriticalSection.enter();
        defer scs.exit();

        if (mx.owner == th) {
            if (mx.type == .recursive and mx.count > 1) {
                mx.count -= 1;
                if (tr.mutex) trace.print("Mutex.unlock() @{*} {s} >{d}\n", .{ mx, mx.name, mx.count });
                return;
            }

            th.acquired_mutexes -= 1;
            // Remove this mutex from the owner's list.
            mx.owner_links.unlink();

            if (mx.boosted_prio != priority.none) {
                // Recompute the inherited priority from the mutexes still
                // owned.
                var inherited: Priority = priority.none;
                var max_prio: Priority = 0;
                var it = th.mutexes.typedIterator(Mutex, "owner_links");
                while (it.next()) |other| {
                    if (other.boosted_prio > max_prio) max_prio = other.boosted_prio;
                }
                if (max_prio > 0) inherited = max_prio;
                th.setPriorityInherited(inherited) catch {};
                mx.boosted_prio = priority.none;
            }

            // Wake the highest priority waiter.
            _ = mx.list.resumeOne();

            mx.owner = null;
            mx.count = 0;
            if (tr.mutex) trace.print("Mutex.unlock() @{*} {s} ULCK\n", .{ mx, mx.name });

            if (mx.owner_dead) {
                mx.owner_dead = false;
                if (!mx.consistent_) {
                    mx.recoverable = false;
                    return error.NotRecoverable;
                }
            }
            return;
        }

        // Not owned by the caller.
        if (mx.type == .errorcheck or mx.type == .recursive or mx.robustness == .robust) {
            return error.NotPermitted;
        }
        // Normal, stalled: undefined behaviour by POSIX.
        return error.NotRecoverable;
    }

    /// The owner died; a robust mutex becomes inconsistent.
    pub fn internalMarkOwnerDead(mx: *Mutex) void {
        if (mx.robustness == .robust) {
            mx.owner_dead = true;
            mx.consistent_ = false;
        }
    }

    /// Lock the mutex, waiting as long as needed.
    pub fn lock(mx: *Mutex) Error!void {
        const crt = this_thread.thread();
        if (tr.mutex) trace.print("Mutex.lock() @{*} {s} by {*} {s}\n", .{ mx, mx.name, crt, crt.name });
        if (interrupts.inHandlerMode()) return error.NotPermitted;
        if (scheduler.locked()) return error.NotPermitted;
        if (!mx.recoverable) return error.NotRecoverable;

        {
            const scs = scheduler.CriticalSection.enter();
            defer scs.exit();
            if (mx.internalTryLock(crt)) |_| return else |err| if (err != error.WouldBlock) return err;
        }

        var node: lists.WaitingThreadNode = .{ .thread = crt };
        while (true) {
            {
                const scs = scheduler.CriticalSection.enter();
                defer scs.exit();
                if (mx.internalTryLock(crt)) |_| return else |err| if (err != error.WouldBlock) return err;
                {
                    const cs = interrupts.CriticalSection.enter();
                    defer cs.exit();
                    // Add this thread to the mutex waiting list.
                    scheduler.internalLinkNode(&mx.list, &node);
                }
            }
            port.scheduler.reschedule();
            // Remove the thread from the waiting list, if not done by the
            // unlock.
            scheduler.internalUnlinkNode(&node);
            if (crt.isInterrupted()) return error.Interrupted;
        }
    }

    /// Lock the mutex only if free (or recursively owned).
    pub fn tryLock(mx: *Mutex) Error!void {
        const crt = this_thread.thread();
        if (tr.mutex) trace.print("Mutex.tryLock() @{*} {s} by {*} {s}\n", .{ mx, mx.name, crt, crt.name });
        if (interrupts.inHandlerMode()) return error.NotPermitted;
        if (!mx.recoverable) return error.NotRecoverable;
        const scs = scheduler.CriticalSection.enter();
        defer scs.exit();
        return mx.internalTryLock(crt);
    }

    /// Lock the mutex, waiting at most `timeout` ticks of the mutex clock.
    pub fn timedLock(mx: *Mutex, timeout: clocks.Duration) Error!void {
        const crt = this_thread.thread();
        if (tr.mutex) trace.print("Mutex.timedLock({d}) @{*} {s} by {*} {s}\n", .{ timeout, mx, mx.name, crt, crt.name });
        if (interrupts.inHandlerMode()) return error.NotPermitted;
        if (scheduler.locked()) return error.NotPermitted;
        if (!mx.recoverable) return error.NotRecoverable;

        {
            const scs = scheduler.CriticalSection.enter();
            defer scs.exit();
            if (mx.internalTryLock(crt)) |_| return else |err| if (err != error.WouldBlock) return err;
        }

        var node: lists.WaitingThreadNode = .{ .thread = crt };
        const clock_list = &mx.clock.steady_list;
        const timeout_timestamp = mx.clock.steadyNow() + timeout;
        var timeout_node: lists.TimeoutThreadNode = .init(timeout_timestamp, crt);

        while (true) {
            {
                const scs = scheduler.CriticalSection.enter();
                defer scs.exit();
                if (mx.internalTryLock(crt)) |_| return else |err| if (err != error.WouldBlock) return err;
                {
                    const cs = interrupts.CriticalSection.enter();
                    defer cs.exit();
                    scheduler.internalLinkNodeTimeout(&mx.list, &node, clock_list, &timeout_node);
                }
            }
            port.scheduler.reschedule();
            scheduler.internalUnlinkNodeTimeout(&node, &timeout_node);

            const err: ?Error = if (crt.isInterrupted())
                error.Interrupted
            else if (mx.clock.steadyNow() >= timeout_timestamp)
                error.TimedOut
            else
                null;

            if (err) |e| {
                // This thread no longer waits: recompute the boost from the
                // remaining waiters.
                const scs = scheduler.CriticalSection.enter();
                defer scs.exit();
                if (mx.boosted_prio != priority.none) {
                    var max_prio: Priority = priority.none;
                    var it = mx.list.threads();
                    while (it.next()) |th| max_prio = @max(max_prio, th.priority());
                    if (max_prio != priority.none) {
                        mx.boosted_prio = max_prio;
                        if (mx.owner) |o| {
                            const us = scheduler.UncriticalSection.enter();
                            defer us.exit();
                            o.setPriorityInherited(max_prio) catch {};
                        }
                    }
                }
                if (tr.mutex and e == error.TimedOut) trace.print("Mutex.timedLock() @{*} {s} timeout\n", .{ mx, mx.name });
                return e;
            }
        }
    }

    /// Unlock the mutex.
    pub fn unlock(mx: *Mutex) Error!void {
        if (interrupts.inHandlerMode()) return error.NotPermitted;
        return mx.internalUnlock(this_thread.thread());
    }

    pub fn getPriorityCeiling(mx: *const Mutex) Priority {
        assert(!interrupts.inHandlerMode());
        return mx.prio_ceiling;
    }

    /// Change the priority ceiling (locking the mutex meanwhile); returns
    /// the previous one.
    pub fn setPriorityCeiling(mx: *Mutex, prio_ceiling: Priority) Error!Priority {
        if (interrupts.inHandlerMode()) return error.NotPermitted;
        try mx.lock();
        const prev = mx.prio_ceiling;
        mx.prio_ceiling = prio_ceiling;
        mx.unlock() catch {};
        return prev;
    }

    /// Mark a robust mutex consistent again, after `error.OwnerDead`.
    pub fn consistent(mx: *Mutex) Error!void {
        if (interrupts.inHandlerMode()) return error.NotPermitted;
        if (mx.robustness != .robust) return error.InvalidArgument;
        if (mx.consistent_) return error.InvalidArgument;
        mx.consistent_ = true;
    }

    /// Return the mutex to the initial state, waking all waiters.
    pub fn reset(mx: *Mutex) Error!void {
        if (interrupts.inHandlerMode()) return error.NotPermitted;
        const scs = scheduler.CriticalSection.enter();
        defer scs.exit();
        mx.internalInit();
    }

    pub fn getOwner(mx: *const Mutex) ?*Thread {
        return mx.owner;
    }

    pub fn getType(mx: *const Mutex) Type {
        return mx.type;
    }
};
