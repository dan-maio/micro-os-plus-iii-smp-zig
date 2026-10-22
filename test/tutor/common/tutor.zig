//! tutor.zig -- the shared base of the µOS++ tutorial (test/tutor/README.md).
//!
//! The Zig version of the C++ course's tutor/common/ (golden workspace,
//! micro-os-plus-iii-aarch64/test/rpi4b/tutor/common/), part for part and
//! with the same arithmetic, so that a lesson prints the same results in
//! both languages:
//!
//!   - `Sample`, the one node type of the course: an intrusive `next` link,
//!     an id, a value, the region it lives in, and a seal word that detects a
//!     field changed behind its owner's back;
//!   - `IntrusiveList(T)`, generic over any struct with a `next: ?*T` field
//!     (the interfaces example's list): it never allocates, so where a node
//!     lives is its owner's choice;
//!   - the three storage regions (a thread's stack, the data segment, the
//!     heap) and `placed()`, the check that a node lies where it claims;
//!   - the work: a fixed data generator, a stable sort of the list, its
//!     maximum and an order-sensitive checksum, and `reference()`, the same
//!     results computed independently on an array;
//!   - the console (`board.console()`, one locked line at a time) and the
//!     verdict (`check()`, `finish()`).
//!
//! The lesson module imports it as `tutor` (build.zig adds the module to
//! every test marked `.tutor = true`).

const std = @import("std");
const uos = @import("uos");
const board = @import("board");

const Thread = uos.rtos.Thread;

// ---- The regions ------------------------------------------------------------

pub const Region = enum(u8) { stack, data, heap };

pub fn regionName(r: Region) []const u8 {
    return switch (r) {
        .stack => "stack",
        .data => ".data",
        .heap => "heap",
    };
}

// Defined by the linker script (boards/rpi4b/linker.ld) around .data.
extern var __data_start: u8;
extern var __data_end: u8;

fn inRange(p: usize, lo: usize, hi: usize) bool {
    return p >= lo and p < hi;
}

/// In the data segment (__data_start .. __data_end).
pub fn inData(p: *const anyopaque) bool {
    return inRange(@intFromPtr(p), @intFromPtr(&__data_start), @intFromPtr(&__data_end));
}

/// In the free store: the system heap's arena (the RAM after the image,
/// port.freeRam()).
pub fn inHeap(p: *const anyopaque) bool {
    const arena = uos.memory.systemHeap().arena;
    return inRange(@intFromPtr(p), @intFromPtr(arena.ptr), @intFromPtr(arena.ptr) + arena.len);
}

/// In the stack of thread `th` (the kernel's record of it).
pub fn inStackOf(p: *const anyopaque, th: *Thread) bool {
    return inRange(@intFromPtr(p), @intFromPtr(th.context.stack.bottom()), @intFromPtr(th.context.stack.top()));
}

/// A sample is in the region it claims (a stack sample in the stack of
/// `owner`, the thread that made it) and its seal is intact.
pub fn placed(s: *const Sample, owner: *Thread) bool {
    if (!s.valid()) return false;
    return switch (s.where) {
        .stack => inStackOf(s, owner),
        .data => inData(s),
        .heap => inHeap(s),
    };
}

// ---- The node -----------------------------------------------------------------

pub const Sample = struct {
    next: ?*Sample = null,
    id: u32 = 0xD47A, // not zero: a static array of samples is in .data
    value: i32 = 0,
    where: Region = .data,
    seal_word: u64 = 0,

    pub fn init(s: *Sample, id: u32, value: i32, where: Region) void {
        s.* = .{ .id = id, .value = value, .where = where };
        s.seal();
    }

    fn hash(s: *const Sample) u64 {
        var h: u64 = 0xcbf29ce484222325;
        for ([_]u64{ s.id, @as(u32, @bitCast(s.value)), @intFromEnum(s.where) }) |x| {
            h = (h ^ x) *% 0x00000100000001b3;
        }
        return h;
    }

    pub fn seal(s: *Sample) void {
        s.seal_word = s.hash();
    }

    pub fn valid(s: *const Sample) bool {
        return s.seal_word == s.hash();
    }
};

// ---- The generic intrusive list -------------------------------------------------

pub fn IntrusiveList(comptime T: type) type {
    comptime {
        if (@typeInfo(T) != .@"struct")
            @compileError("IntrusiveList requires a struct type, got " ++ @typeName(T));
        if (!@hasField(T, "next"))
            @compileError("IntrusiveList requires " ++ @typeName(T) ++ " to have a `next` field");
        if (@FieldType(T, "next") != ?*T)
            @compileError("IntrusiveList requires `next` to be `?*" ++ @typeName(T) ++ "`");
    }

    return struct {
        head: ?*T = null,

        const Self = @This();

        pub fn push(self: *Self, node: *T) void {
            node.next = self.head;
            self.head = node;
        }

        pub fn unlink(self: *Self, node: *T) bool {
            var link = &self.head;
            while (link.*) |current| {
                if (current == node) {
                    link.* = current.next;
                    current.next = null;
                    return true;
                }
                link = &current.next;
            }
            return false;
        }

        pub fn count(self: Self) usize {
            var n: usize = 0;
            var it = self.head;
            while (it) |node| : (it = node.next) n += 1;
            return n;
        }
    };
}

pub const SampleList = IntrusiveList(Sample);

// ---- The work ----------------------------------------------------------------------

/// The value of sample `i` of a data set (a fixed LCG): the same on every run,
/// in every lesson and in both languages.
pub fn generate(seed: u32, i: u32) i32 {
    var x: u32 = seed ^ (i *% 0x9E3779B9);
    for (0..3) |_| x = x *% 1664525 +% 1013904223;
    return @rem(@as(i32, @intCast(x >> 16)), 10000); // 0 .. 9999
}

fn before(a: *const Sample, b: *const Sample) bool {
    return a.value < b.value or (a.value == b.value and a.id < b.id);
}

/// Sort the list by value, then by id (stable and deterministic): an
/// insertion sort on the links, no allocation.
pub fn sortList(list: *SampleList) void {
    var sorted: ?*Sample = null;
    var it = list.head;
    while (it) |node| {
        it = node.next;
        var link = &sorted;
        while (link.*) |cur| {
            if (before(node, cur)) break;
            link = &cur.next;
        }
        node.next = link.*;
        link.* = node;
    }
    list.head = sorted;
}

/// The sample with the largest value (the first of equals), or null.
pub fn maxOf(list: SampleList) ?*const Sample {
    var best: ?*const Sample = null;
    var it = list.head;
    while (it) |s| : (it = s.next) {
        if (best == null or s.value > best.?.value) best = s;
    }
    return best;
}

fn mix(c0: u32, id: u32, value: i32) u32 {
    var c = (c0 ^ id) *% 16777619;
    c = (c ^ @as(u32, @bitCast(value))) *% 16777619;
    return c;
}

/// An order-sensitive checksum of (id, value) along the list.
pub fn checksum(list: SampleList) u32 {
    var c: u32 = 2166136261;
    var it = list.head;
    while (it) |s| : (it = s.next) c = mix(c, s.id, s.value);
    return c;
}

pub const Expected = struct {
    sorted_checksum: u32,
    max_value: i32,
    max_id: u32,
};

var ref_values: [4096]i32 = undefined;
var ref_ids: [4096]u32 = undefined;

/// The expected results of `n` samples with ids first_id .. first_id + n - 1
/// and values generate(seed, id), computed on a plain array, independently
/// of the list code: the checksum of the sorted order and the maximum.
pub fn reference(seed: u32, first_id: u32, n_in: u32) Expected {
    const n = @min(n_in, ref_values.len);
    for (0..n) |iu| {
        const i: u32 = @intCast(iu);
        const v = generate(seed, first_id + i);
        const id = first_id + i;
        var j: usize = iu;
        while (j > 0 and (ref_values[j - 1] > v or (ref_values[j - 1] == v and ref_ids[j - 1] > id))) : (j -= 1) {
            ref_values[j] = ref_values[j - 1];
            ref_ids[j] = ref_ids[j - 1];
        }
        ref_values[j] = v;
        ref_ids[j] = id;
    }
    var e: Expected = .{ .sorted_checksum = 2166136261, .max_value = 0, .max_id = 0 };
    for (0..n) |i| {
        e.sorted_checksum = mix(e.sorted_checksum, ref_ids[i], ref_values[i]);
        // Strictly greater: of equal maxima the first in sorted order, the
        // lowest id -- what maxOf() returns on the sorted list.
        if (i == 0 or ref_values[i] > e.max_value) {
            e.max_value = ref_values[i];
            e.max_id = ref_ids[i];
        }
    }
    return e;
}

// ---- The verdict -------------------------------------------------------------------

var g_failures = std.atomic.Value(u32).init(0);

/// Print "  [ok] what" or "  [BAD] what" and count a failure.
pub fn check(cond: bool, comptime fmt: []const u8, args: anytype) bool {
    if (!cond) _ = g_failures.fetchAdd(1, .monotonic);
    board.console("  [{s}] " ++ fmt ++ "\n", .{if (cond) "ok" else "BAD"} ++ args);
    return cond;
}

pub fn failures() u32 {
    return g_failures.load(.monotonic);
}

/// Print the verdict line and end the run (semihosting SYS_EXIT).
pub fn finish(summary: []const u8) noreturn {
    const n = failures();
    if (n == 0) {
        board.console("RESULT: PASS ({s})\n", .{summary});
        board.hw_result.ok();
    }
    board.console("RESULT: FAIL ({d} failed checks)\n", .{n});
    board.hw_result.fail();
}

/// The heap's allocated bytes (the system heap).
pub fn heapBytes() usize {
    return uos.memory.statistics().allocated_bytes;
}

/// The lesson's banner, then the three regions' ranges (the stack one of the
/// calling thread).
pub fn printBanner(lesson: []const u8) void {
    board.console("\n+== " ++ board.banner_short ++ " µOS++ tutorial (Zig) : {s} ({d} CPU) ==+\n\n", .{ lesson, uos.config.ncpu });
}

pub fn printRegions() void {
    const self = uos.rtos.this_thread.thread();
    const arena = uos.memory.systemHeap().arena;
    board.console("  .data   {x:0>8} .. {x:0>8}\n", .{ @intFromPtr(&__data_start), @intFromPtr(&__data_end) });
    board.console("  heap    {x:0>8} .. {x:0>8}\n", .{ @intFromPtr(arena.ptr), @intFromPtr(arena.ptr) + arena.len });
    board.console("  stack   {x:0>8} .. {x:0>8} (thread {s})\n", .{ @intFromPtr(self.context.stack.bottom()), @intFromPtr(self.context.stack.top()), self.name });
}
