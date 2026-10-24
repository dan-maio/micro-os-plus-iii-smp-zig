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

/// Where check() prints its lines: the console when null (the default),
/// else this function (from lesson 16, the SD log's logger thread).
pub const Output = *const fn (text: []const u8) void;
pub var output: ?Output = null;

/// Print "  [ok] what" or "  [BAD] what" and count a failure.
pub fn check(cond: bool, comptime fmt: []const u8, args: anytype) bool {
    if (!cond) _ = g_failures.fetchAdd(1, .monotonic);
    if (output) |out| {
        var buf: [220]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buf);
        w.print("  [{s}] " ++ fmt ++ "\n", .{if (cond) "ok" else "BAD"} ++ args) catch {};
        out(w.buffered());
    } else {
        board.console("  [{s}] " ++ fmt ++ "\n", .{if (cond) "ok" else "BAD"} ++ args);
    }
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

// ---- The second interrupt (from lesson 03) -------------------------------------
//
// The core's ARM generic *virtual* timer (CNTV), PPI INTID 27: an interrupt
// source independent of the kernel's 1 ms tick, which is the *physical*
// timer (CNTP, INTID 30). Every `period_us` it calls `callback(arg)` in
// interrupt context; the callback may only use the kernel's ISR-safe calls
// (a semaphore's post(), ...).
//
// The timer and its PPI are private to a core (banked): start() arms them on
// the core that calls it, and the interrupts run there; stop() must run on
// the same core. (The BCM2711's own System Timer, an SPI the GIC could route
// to any core, is not wired to the GIC by QEMU's raspi4b, so the course uses
// CNTV, the same on QEMU and on the board.)
//
// The lesson's root file forwards the port's external-interrupt hook here:
//     pub const uos_external_irq = tutor.second_timer.onIrq;
// (src/port.zig hands every interrupt it does not own to root's
// uos_external_irq(iar), which test/start.zig forwards to the app.)

pub const second_timer = struct {
    pub const intid: u32 = 27;

    pub const Callback = *const fn (arg: ?*anyopaque) void;

    const st_clo: usize = 0xFE00_3004; // the System Timer's counter, low 32 bits

    var s_ticks: u64 = 0; // the period, in CNTV ticks
    var s_count = std.atomic.Value(u32).init(0);
    var s_cpus = std.atomic.Value(u32).init(0);
    var s_callback: ?Callback = null;
    var s_arg: ?*anyopaque = null;

    fn cntvct() u64 {
        return asm volatile ("isb; mrs %[r], cntvct_el0"
            : [r] "=r" (-> u64),
        );
    }

    fn cntvCval() u64 {
        return asm volatile ("mrs %[r], cntv_cval_el0"
            : [r] "=r" (-> u64),
        );
    }

    fn setCval(v: u64) void {
        asm volatile ("msr cntv_cval_el0, %[v]; isb"
            :
            : [v] "r" (v),
        );
    }

    fn setCtl(v: u64) void {
        asm volatile ("msr cntv_ctl_el0, %[v]; isb"
            :
            : [v] "r" (v),
        );
    }

    /// The generic timer's frequency (CNTFRQ_EL0).
    pub fn frequency() u64 {
        return asm volatile ("mrs %[r], cntfrq_el0"
            : [r] "=r" (-> u64),
        );
    }

    /// The BCM2711 System Timer's free-running 1 MHz counter, in
    /// microseconds (wraps every ~71 minutes): a clock common to all cores.
    pub fn nowUs() u32 {
        return @as(*volatile u32, @ptrFromInt(st_clo)).*;
    }

    /// Interrupts handled since start().
    pub fn count() u32 {
        return s_count.load(.monotonic);
    }

    /// The cores they ran on (a bit mask).
    pub fn cpusSeen() u32 {
        return s_cpus.load(.monotonic);
    }

    pub fn start(period_us: u32, callback: Callback, arg: ?*anyopaque) void {
        s_ticks = frequency() * period_us / 1_000_000;
        s_callback = callback;
        s_arg = arg;
        s_count.store(0, .monotonic);
        s_cpus.store(0, .monotonic);

        // The first compare one period ahead; enabled, not masked (CTL = ENABLE).
        setCval(cntvct() + s_ticks);
        setCtl(1);
        // This core's banked PPI: priority, enable.
        uos.port.gic.setPriority(intid, uos.port.gic_mod.PRIORITY);
        uos.port.gic.enableIrq(intid);
    }

    pub fn stop() void {
        setCtl(2); // IMASK: the timer's output no longer asserts the PPI
        uos.port.gic.disableIrq(intid);
        s_callback = null;
    }

    /// The port's external-interrupt hook (interrupt context).
    pub fn onIrq(iar: u32) void {
        if (iar & 0x3FF != intid) return;
        // The PPI is level-sensitive: moving the compare into the future
        // de-asserts it. The next compare is one period after the last, or
        // -- when the handler is late -- one period from now (no burst of
        // catch-up interrupts).
        var next = cntvCval() + s_ticks;
        const now = cntvct();
        if (next <= now) next = now + s_ticks;
        setCval(next);

        _ = s_count.fetchAdd(1, .monotonic);
        _ = s_cpus.fetchOr(@as(u32, 1) << @intCast(board.cpuSlot()), .monotonic);
        if (s_callback) |cb| cb(s_arg);
    }
};

/// True on the board, false under QEMU, whose emulated cores are not
/// real-time: timing bounds are checked strictly only on the board. Both
/// run the same image, so it is told at run time: the Pi 4's generic timer
/// runs at 54 MHz, QEMU's raspi4b at 62.5 MHz.
pub fn onHardware() bool {
    return second_timer.frequency() == 54_000_000;
}
