//! Event flags masks and modes (`os::rtos::flags`, `internal::event_flags`).

const std = @import("std");
const result = @import("result.zig");
const Error = result.Error;

pub const Mask = u32;

/// Wait for any flag (with `Mode.any`/`Mode.all` ignored).
pub const any: Mask = 0;
/// All flags.
pub const all: Mask = 0xFFFF_FFFF;

/// How a wait matches the mask. The C++ `flags::mode::all | flags::mode::clear`
/// becomes `.{ .all = true, .clear = true }`.
pub const Mode = packed struct(u32) {
    /// All flags of the mask must be raised.
    all: bool = false,
    /// At least one flag of the mask must be raised.
    any: bool = false,
    /// Clear the matched flags.
    clear: bool = false,
    _padding: u29 = 0,

    pub const all_clear: Mode = .{ .all = true, .clear = true };
    pub const any_clear: Mode = .{ .any = true, .clear = true };
};

/// The flags word shared by threads and event flags objects. It does not
/// lock; the callers wrap it in a critical section, which keeps the
/// interrupts-dependency out of this file (and makes it host-testable).
pub const EventFlags = struct {
    mask: Mask = 0,

    /// Raise flags; returns the previous value.
    pub fn raise(ef: *EventFlags, m: Mask) Error!Mask {
        if (m == 0) return error.InvalidArgument;
        const prev = ef.mask;
        ef.mask |= m;
        return prev;
    }

    /// Check whether the wait condition is met; when it is, return the
    /// matched flags (applying `clear`), otherwise null.
    pub fn checkRaised(ef: *EventFlags, m: Mask, mode: Mode) ?Mask {
        if (m == any) {
            if (ef.mask != 0) {
                const ret = ef.mask;
                if (mode.clear) ef.mask = 0;
                return ret;
            }
        } else if ((mode.all and (ef.mask & m) == m) or (mode.any and (ef.mask & m) != 0)) {
            const ret = ef.mask & m;
            if (mode.clear) ef.mask &= ~m;
            return ret;
        }
        return null;
    }

    /// Get (and optionally clear) the selected flags; mask 0 means all.
    pub fn get(ef: *EventFlags, m: Mask, mode: Mode) Mask {
        if (m == 0) return ef.mask;
        const ret = ef.mask & m;
        if (mode.clear) ef.mask &= ~m;
        return ret;
    }

    /// Clear flags; returns the previous value.
    pub fn clear(ef: *EventFlags, m: Mask) Error!Mask {
        if (m == 0) return error.InvalidArgument;
        const prev = ef.mask;
        ef.mask &= ~m;
        return prev;
    }
};

test EventFlags {
    var ef: EventFlags = .{};
    try std.testing.expectError(error.InvalidArgument, ef.raise(0));
    _ = try ef.raise(0b0101);
    try std.testing.expectEqual(null, ef.checkRaised(0b0111, .{ .all = true }));
    try std.testing.expectEqual(0b0101, ef.checkRaised(0b0111, .{ .any = true }));
    try std.testing.expectEqual(0b0001, ef.checkRaised(0b0001, .all_clear));
    try std.testing.expectEqual(0b0100, ef.mask);
    try std.testing.expectEqual(0b0100, ef.checkRaised(any, .{ .clear = true }));
    try std.testing.expectEqual(0, ef.mask);
}
