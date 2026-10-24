//! core/threads.zig -- creating the application's threads where they belong:
//! a priority, a core (four CPUs) and, for the one that must never touch the
//! heap after start-up, a static stack. (C++: app/core/threads.*.)

const std = @import("std");
const uos = @import("uos");
const config = @import("config.zig");

const rtos = uos.rtos;
const Atomic = std.atomic.Value;

pub const Func = *const fn (?*anyopaque) ?*anyopaque;

var s_created = Atomic(u32).init(0);
var s_reaped = Atomic(u32).init(0);

fn attributes(prio: rtos.Priority, core: ?u32) rtos.Thread.Attributes {
    var attr: rtos.Thread.Attributes = .{ .priority = prio };
    if (config.four) {
        if (core) |c| attr.cpu_affinity = @as(u32, 1) << @intCast(c);
    }
    return attr;
}

/// A thread on the heap (8 KiB of stack, from the heap too); null on failure.
pub fn spawn(name: [:0]const u8, f: Func, arg: ?*anyopaque, prio: rtos.Priority, core: ?u32) ?*rtos.Thread {
    var attr = attributes(prio, core);
    attr.stack_size_bytes = 8 * 1024;
    _ = s_created.fetchAdd(1, .monotonic);
    return rtos.Thread.create(uos.memory.allocator(), name, f, arg, attr) catch null;
}

/// A thread object and stack of the caller's (static: nothing on the heap).
pub fn spawnStatic(th: *rtos.Thread, name: [:0]const u8, f: Func, arg: ?*anyopaque, prio: rtos.Priority, core: ?u32, stack: []uos.port.StackElement) bool {
    var attr = attributes(prio, core);
    attr.stack = stack;
    _ = s_created.fetchAdd(1, .monotonic);
    th.init(name, f, arg, attr, null) catch return false;
    return true;
}

/// join(), then destroy(): for spawn()'s threads.
pub fn reap(th: *rtos.Thread) void {
    _ = th.join() catch null;
    th.destroy();
    _ = s_reaped.fetchAdd(1, .monotonic);
}

pub fn created() u32 {
    return s_created.load(.monotonic);
}

pub fn reaped() u32 {
    return s_reaped.load(.monotonic);
}
