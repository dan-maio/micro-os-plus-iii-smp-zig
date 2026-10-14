//! Event flags objects (`os::rtos::event_flags`, `src/rtos/os-evflags.cpp`).
//!
//! ```zig
//! var ev: uos.rtos.EventFlags = .{ .name = "ev" };
//! _ = try ev.raise(0x3);                              // from an ISR too
//! const got = try ev.wait(0x1, .all_clear);
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
const flags = @import("flags.zig");

const tr = config.options.trace;

pub const Attributes = struct {
    clock: ?*clocks.Clock = null,
};

pub const EventFlags = struct {
    name: [:0]const u8 = "-",
    list: lists.WaitingThreadsList = .{},
    clock: *clocks.Clock = &clocks.sysclock,
    flags: flags.EventFlags = .{},

    pub fn init(ev: *EventFlags, name: [:0]const u8, attr: Attributes) Error!void {
        if (interrupts.inHandlerMode()) return error.NotPermitted;
        ev.* = .{ .name = name, .clock = attr.clock orelse &clocks.sysclock };
    }

    pub fn deinit(ev: *EventFlags) void {
        assert(ev.list.isEmpty());
    }

    const Request = struct {
        ev: *EventFlags,
        mask: flags.Mask,
        mode: flags.Mode,

        fn check(r: Request) ?flags.Mask {
            return r.ev.flags.checkRaised(r.mask, r.mode);
        }
    };

    /// Wait for flags; returns the matched flags (cleared with `.clear`).
    pub fn wait(ev: *EventFlags, mask: flags.Mask, mode: flags.Mode) Error!flags.Mask {
        if (tr.evflags) trace.print("EventFlags.wait(0x{X}) @{*} {s}\n", .{ mask, ev, ev.name });
        return scheduler.waitFor(flags.Mask, &ev.list, ev.clock, null, Request{ .ev = ev, .mask = mask, .mode = mode }, Request.check);
    }

    /// Check without waiting (`error.WouldBlock`). Can be called from ISRs.
    pub fn tryWait(ev: *EventFlags, mask: flags.Mask, mode: flags.Mode) Error!flags.Mask {
        assert(interrupts.isPriorityValid());
        const cs = interrupts.CriticalSection.enter();
        defer cs.exit();
        return ev.flags.checkRaised(mask, mode) orelse error.WouldBlock;
    }

    /// Wait at most `timeout` ticks.
    pub fn timedWait(ev: *EventFlags, mask: flags.Mask, timeout: clocks.Duration, mode: flags.Mode) Error!flags.Mask {
        if (tr.evflags) trace.print("EventFlags.timedWait(0x{X}, {d}) @{*} {s}\n", .{ mask, timeout, ev, ev.name });
        return scheduler.waitFor(flags.Mask, &ev.list, ev.clock, timeout, Request{ .ev = ev, .mask = mask, .mode = mode }, Request.check);
    }

    /// Raise flags and wake every waiter to re-check; returns the previous
    /// flags. Can be called from ISRs.
    pub fn raise(ev: *EventFlags, mask: flags.Mask) Error!flags.Mask {
        if (tr.evflags) trace.print("EventFlags.raise(0x{X}) @{*} {s}\n", .{ mask, ev, ev.name });
        if (mask == 0) return error.InvalidArgument;
        const prev = blk: {
            const cs = interrupts.CriticalSection.enter();
            defer cs.exit();
            break :blk try ev.flags.raise(mask);
        };
        ev.list.resumeAll();
        return prev;
    }

    /// Clear flags; returns the previous flags.
    pub fn clear(ev: *EventFlags, mask: flags.Mask) Error!flags.Mask {
        if (mask == 0) return error.InvalidArgument;
        const cs = interrupts.CriticalSection.enter();
        defer cs.exit();
        return ev.flags.clear(mask);
    }

    /// Get (and optionally clear) flags; mask 0 means all.
    pub fn get(ev: *EventFlags, mask: flags.Mask, mode: flags.Mode) flags.Mask {
        const cs = interrupts.CriticalSection.enter();
        defer cs.exit();
        return ev.flags.get(mask, mode);
    }

    /// True when threads are waiting.
    pub fn waiting(ev: *EventFlags) bool {
        const cs = interrupts.CriticalSection.enter();
        defer cs.exit();
        return !ev.list.isEmpty();
    }
};
