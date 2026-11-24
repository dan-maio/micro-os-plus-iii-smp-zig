//! An `std.Io` implementation on µOS++ threads: the Zig 0.17 "new I/O"
//! interface, backed by the RTOS.
//!
//! It replaces the C++ `os::estd` layer (ISO threads, mutexes, condition
//! variables, chrono): generic Zig code written against `std.Io` --
//! `io.concurrent()`, `std.Io.Group`, `std.Io.Mutex`, `std.Io.Condition`,
//! `std.Io.Queue`, `io.sleep()`, `std.Io.Clock.now()`, cancellation -- runs
//! unchanged on the RTOS:
//!
//! ```zig
//! var rtos_io: uos.Io = .init(uos.memory.allocator());
//! const io = rtos_io.io();
//!
//! var f = try io.concurrent(work, .{ io, 42 });   // an RTOS thread
//! const r = f.await(io);
//! try io.sleep(.fromMilliseconds(10), .awake);
//! ```
//!
//! What maps where:
//!
//! | `std.Io`                    | µOS++                                     |
//! |-----------------------------|-------------------------------------------|
//! | `async`                     | runs eagerly in the caller (allowed)      |
//! | `concurrent`, `Group.concurrent` | a new `Thread`, stack from `gpa`     |
//! | `await`, `Group.await`      | `Thread.join()`                           |
//! | `cancel`                    | cancel request + `Thread.interrupt()`     |
//! | `futexWait`/`futexWake`     | hashed wait lists in the kernel           |
//! | `sleep`, `Timeout`          | `sysclock` ticks                          |
//! | `now(.awake/.boot/.cpu_*)`  | `hrclock`                                 |
//! | `now(.real)`                | `rtclock`                                 |
//! | stdout/stderr writes        | the trace channel                         |
//! | files, dirs, net, processes | not available (`std.Io.failing`)          |
//!
//! Devices have their own `std.Io.Reader`/`std.Io.Writer` (`uos.io.devices`).

const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const Io = std.Io;
const Alignment = std.mem.Alignment;

const port = @import("uos_port");
const trace = @import("../trace.zig");
const interrupts = @import("../rtos/interrupts.zig");
const scheduler = @import("../rtos/scheduler.zig");
const lists = @import("../rtos/lists.zig");
const clocks = @import("../rtos/clocks.zig");
const thread_mod = @import("../rtos/thread.zig");
const Thread = thread_mod.Thread;
const this_thread = thread_mod.this_thread;

const RtosIo = @This();

/// Allocator for the tasks of `concurrent()` (thread, stack, context).
gpa: std.mem.Allocator,
/// Stack of the concurrent tasks; 0 is the RTOS default.
stack_size_bytes: usize = 0,
/// Priority of the concurrent tasks.
priority: thread_mod.Priority = thread_mod.priority.normal,

pub fn init(gpa: std.mem.Allocator) RtosIo {
    return .{ .gpa = gpa };
}

pub fn io(self: *RtosIo) Io {
    return .{ .userdata = self, .vtable = &vtable };
}

const vtable: Io.VTable = blk: {
    var v = Io.failing.vtable.*;
    v.async = Io.noAsync;
    v.concurrent = concurrent;
    v.await = await;
    v.cancel = cancel;
    v.groupAsync = Io.noGroupAsync;
    v.groupConcurrent = groupConcurrent;
    v.groupAwait = groupAwait;
    v.groupCancel = groupCancel;
    v.recancel = recancel;
    v.swapCancelProtection = swapCancelProtection;
    v.checkCancel = checkCancel;
    v.futexWait = futexWait;
    v.futexWaitUncancelable = futexWaitUncancelable;
    v.futexWake = futexWake;
    v.operate = operate;
    v.fileWritePositional = fileWritePositional;
    v.now = now;
    v.clockResolution = clockResolution;
    v.sleep = sleep;
    v.random = random;
    break :blk v;
};

fn from(userdata: ?*anyopaque) *RtosIo {
    return @ptrCast(@alignCast(userdata.?));
}

// ----------------------------------------------------------------------------
// Tasks: one RTOS thread each.

const Task = struct {
    thread: Thread,
    owner: *RtosIo,
    start: union(enum) {
        future: *const fn (context: *const anyopaque, result: *anyopaque) void,
        group: *const fn (context: *const anyopaque) void,
    },
    context: []u8,
    context_alignment: Alignment,
    result: []u8,
    result_alignment: Alignment,
    /// Next task of the same group.
    group_next: ?*Task = null,

    fn entry(arg: ?*anyopaque) ?*anyopaque {
        const t: *Task = @ptrCast(@alignCast(arg.?));
        switch (t.start) {
            .future => |start| start(t.context.ptr, t.result.ptr),
            .group => |start| start(t.context.ptr),
        }
        return null;
    }

    fn create(
        owner: *RtosIo,
        context: []const u8,
        context_alignment: Alignment,
        result_len: usize,
        result_alignment: Alignment,
        start: @FieldType(Task, "start"),
    ) error{ConcurrencyUnavailable}!*Task {
        const gpa = owner.gpa;
        const t = gpa.create(Task) catch return error.ConcurrencyUnavailable;
        errdefer gpa.destroy(t);
        const ctx = (gpa.rawAlloc(@max(context.len, 1), context_alignment, @returnAddress()) orelse
            return error.ConcurrencyUnavailable)[0..context.len];
        errdefer gpa.rawFree(ctx.ptr[0..@max(context.len, 1)], context_alignment, @returnAddress());
        const res = (gpa.rawAlloc(@max(result_len, 1), result_alignment, @returnAddress()) orelse
            return error.ConcurrencyUnavailable)[0..result_len];
        errdefer gpa.rawFree(res.ptr[0..@max(result_len, 1)], result_alignment, @returnAddress());
        @memcpy(ctx, context);
        t.* = .{
            .thread = undefined,
            .owner = owner,
            .start = start,
            .context = ctx,
            .context_alignment = context_alignment,
            .result = res,
            .result_alignment = result_alignment,
        };
        t.thread.init("io-task", entry, t, .{
            .stack_size_bytes = owner.stack_size_bytes,
            .priority = owner.priority,
        }, gpa) catch return error.ConcurrencyUnavailable;
        return t;
    }

    /// Wait for the task to end and release it.
    fn finish(t: *Task, result: ?[]u8) void {
        _ = t.thread.join() catch {};
        if (result) |r| @memcpy(r, t.result);
        t.thread.deinit();
        const gpa = t.owner.gpa;
        gpa.rawFree(t.context.ptr[0..@max(t.context.len, 1)], t.context_alignment, @returnAddress());
        gpa.rawFree(t.result.ptr[0..@max(t.result.len, 1)], t.result_alignment, @returnAddress());
        gpa.destroy(t);
    }

    fn requestCancel(t: *Task) void {
        @atomicStore(bool, &t.thread.io_cancel.requested, true, .release);
        _ = t.thread.interrupt(true);
    }
};

fn concurrent(
    userdata: ?*anyopaque,
    result_len: usize,
    result_alignment: Alignment,
    context: []const u8,
    context_alignment: Alignment,
    start: *const fn (context: *const anyopaque, result: *anyopaque) void,
) Io.ConcurrentError!*Io.AnyFuture {
    const t = try Task.create(from(userdata), context, context_alignment, result_len, result_alignment, .{ .future = start });
    return @ptrCast(t);
}

fn await(userdata: ?*anyopaque, any_future: *Io.AnyFuture, result: []u8, result_alignment: Alignment) void {
    _ = userdata;
    _ = result_alignment;
    const t: *Task = @ptrCast(@alignCast(any_future));
    t.finish(result);
}

fn cancel(userdata: ?*anyopaque, any_future: *Io.AnyFuture, result: []u8, result_alignment: Alignment) void {
    const t: *Task = @ptrCast(@alignCast(any_future));
    t.requestCancel();
    await(userdata, any_future, result, result_alignment);
}

/// The group's pending tasks, a list anchored in `Group.token`.
fn groupConcurrent(
    userdata: ?*anyopaque,
    group: *Io.Group,
    context: []const u8,
    context_alignment: Alignment,
    start: *const fn (context: *const anyopaque) void,
) Io.ConcurrentError!void {
    const t = try Task.create(from(userdata), context, context_alignment, 0, .@"1", .{ .group = start });
    const cs = interrupts.CriticalSection.enter();
    defer cs.exit();
    t.group_next = @ptrCast(@alignCast(group.token.raw));
    group.token.raw = t;
}

fn takeGroup(group: *Io.Group) ?*Task {
    const cs = interrupts.CriticalSection.enter();
    defer cs.exit();
    const head: ?*Task = @ptrCast(@alignCast(group.token.raw));
    group.token.raw = null;
    return head;
}

fn groupAwait(userdata: ?*anyopaque, group: *Io.Group, token: *anyopaque) Io.Cancelable!void {
    _ = userdata;
    _ = token;
    var t = takeGroup(group);
    while (t) |task| {
        t = task.group_next;
        task.finish(null);
    }
}

fn groupCancel(userdata: ?*anyopaque, group: *Io.Group, token: *anyopaque) void {
    var t: ?*Task = @ptrCast(@alignCast(group.token.raw));
    while (t) |task| : (t = task.group_next) task.requestCancel();
    groupAwait(userdata, group, token) catch {};
}

// ----------------------------------------------------------------------------
// Cancellation.

fn recancel(userdata: ?*anyopaque) void {
    _ = userdata;
    this_thread.thread().io_cancel.requested = true;
}

fn swapCancelProtection(userdata: ?*anyopaque, new: Io.CancelProtection) Io.CancelProtection {
    _ = userdata;
    const th = this_thread.thread();
    const prev: Io.CancelProtection = if (th.io_cancel.protected) .blocked else .unblocked;
    th.io_cancel.protected = new == .blocked;
    return prev;
}

/// Deliver a pending cancel request at this cancellation point.
fn takeCancel(th: *Thread) bool {
    if (th.io_cancel.protected) return false;
    if (!@atomicLoad(bool, &th.io_cancel.requested, .acquire)) return false;
    th.io_cancel.requested = false;
    th.interrupted = false;
    return true;
}

fn checkCancel(userdata: ?*anyopaque) Io.Cancelable!void {
    _ = userdata;
    if (takeCancel(this_thread.thread())) return error.Canceled;
}

// ----------------------------------------------------------------------------
// Futex: waiters hashed by address into the kernel's wait lists.

const FutexWaiter = struct {
    node: lists.WaitingThreadNode,
    address: usize,
};

const futex_buckets = 16;
var futex_lists: [futex_buckets]lists.WaitingThreadsList = @splat(.{});

fn bucket(ptr: *const u32) *lists.WaitingThreadsList {
    const a = @intFromPtr(ptr) >> 2;
    return &futex_lists[(a ^ (a >> 4) ^ (a >> 8)) % futex_buckets];
}

fn futexWaitInternal(ptr: *const u32, expected: u32, timeout: ?clocks.Duration, cancelable: bool) Io.Cancelable!void {
    const th = this_thread.thread();
    if (cancelable and takeCancel(th)) return error.Canceled;
    if (!scheduler.started()) return; // nothing could wake us: spin
    if (timeout) |t| if (t == 0) return;

    var w: FutexWaiter = .{ .node = .{ .thread = th }, .address = @intFromPtr(ptr) };
    var timeout_node: lists.TimeoutThreadNode = .init(0, th);
    const list = bucket(ptr);
    {
        const cs = interrupts.CriticalSection.enter();
        defer cs.exit();
        if (@atomicLoad(u32, ptr, .acquire) != expected) return;
        scheduler.internalLinkNode(list, &w.node);
        if (timeout) |t| {
            timeout_node.node.timestamp = clocks.sysclock.steady_count + t;
            clocks.sysclock.steady_list.link(&timeout_node.node);
            th.clock_node = &timeout_node;
        }
    }
    port.scheduler.reschedule();
    {
        const cs = interrupts.CriticalSection.enter();
        defer cs.exit();
        th.waiting_node = null;
        w.node.links.unlink();
        th.clock_node = null;
        timeout_node.node.links.unlink();
    }
    if (cancelable and takeCancel(th)) return error.Canceled;
    // A spurious wake-up (interrupt without cancel) is allowed by the API.
}

fn futexWait(userdata: ?*anyopaque, ptr: *const u32, expected: u32, timeout: Io.Timeout) Io.Cancelable!void {
    _ = userdata;
    return futexWaitInternal(ptr, expected, timeoutTicks(timeout), true);
}

fn futexWaitUncancelable(userdata: ?*anyopaque, ptr: *const u32, expected: u32) void {
    _ = userdata;
    futexWaitInternal(ptr, expected, null, false) catch unreachable;
}

fn futexWake(userdata: ?*anyopaque, ptr: *const u32, max_waiters: u32) void {
    _ = userdata;
    if (max_waiters == 0) return;
    const list = bucket(ptr);
    var woken: [8]*Thread = undefined;
    var remaining = max_waiters;
    while (remaining > 0) {
        var n: usize = 0;
        {
            const cs = interrupts.CriticalSection.enter();
            defer cs.exit();
            var it = list.list.iterator();
            while (it.next()) |links| {
                if (n == woken.len or n == remaining) break;
                const node = lists.WaitingThreadNode.fromLinks(links);
                const w: *FutexWaiter = @alignCast(@fieldParentPtr("node", node));
                if (w.address != @intFromPtr(ptr)) continue;
                // Unlinking the current node is safe: the iterator already
                // holds the next one.
                links.unlink();
                woken[n] = node.thread;
                n += 1;
            }
        }
        for (woken[0..n]) |th| th.@"resume"();
        if (n < woken.len) break;
        remaining -= @intCast(n);
    }
}

// ----------------------------------------------------------------------------
// Time.

fn hrNanoseconds() i96 {
    const cycles = clocks.hrclock.now();
    const hz = clocks.hrclock.inputClockFrequencyHz();
    return @intCast(@as(u128, cycles) * std.time.ns_per_s / hz);
}

fn now(userdata: ?*anyopaque, clock: Io.Clock) Io.Timestamp {
    _ = userdata;
    return switch (clock) {
        .real => .fromNanoseconds(@as(i96, @intCast(clocks.rtclock.now())) * std.time.ns_per_s),
        .awake, .boot, .cpu_process, .cpu_thread => .fromNanoseconds(hrNanoseconds()),
    };
}

fn clockResolution(userdata: ?*anyopaque, clock: Io.Clock) Io.Clock.ResolutionError!Io.Duration {
    _ = userdata;
    return switch (clock) {
        .real => .fromNanoseconds(std.time.ns_per_s),
        else => .fromNanoseconds(@max(1, std.time.ns_per_s / clocks.hrclock.inputClockFrequencyHz())),
    };
}

/// Ticks of `sysclock` until the timeout, rounded up; null for none.
fn timeoutTicks(timeout: Io.Timeout) ?clocks.Duration {
    const ns: i96 = switch (timeout) {
        .none => return null,
        .duration => |d| d.raw.nanoseconds,
        .deadline => |d| now(null, d.clock).durationTo(d.raw).nanoseconds,
    };
    if (ns <= 0) return 0;
    const hz = clocks.Clock.frequency_hz;
    const ticks = @divFloor(ns * hz + std.time.ns_per_s - 1, std.time.ns_per_s);
    return @intCast(@min(ticks, std.math.maxInt(clocks.Duration)));
}

fn sleep(userdata: ?*anyopaque, timeout: Io.Timeout) Io.Cancelable!void {
    _ = userdata;
    const th = this_thread.thread();
    if (takeCancel(th)) return error.Canceled;
    const ticks = timeoutTicks(timeout) orelse {
        // Sleep forever: until canceled.
        while (true) {
            th.internalSuspend();
            if (takeCancel(th)) return error.Canceled;
        }
    };
    clocks.sysclock.sleepFor(ticks) catch |err| switch (err) {
        error.Interrupted => if (takeCancel(th)) return error.Canceled,
        else => {},
    };
}

// ----------------------------------------------------------------------------
// Randomness (not cryptographic: `randomSecure` stays unavailable).

var prng: std.Random.DefaultPrng = .init(0);
var prng_seeded = false;

fn random(userdata: ?*anyopaque, buffer: []u8) void {
    _ = userdata;
    const cs = interrupts.CriticalSection.enter();
    defer cs.exit();
    if (!prng_seeded) {
        prng = .init(clocks.hrclock.now() ^ 0x9E37_79B9_7F4A_7C15);
        prng_seeded = true;
    }
    prng.random().bytes(buffer);
}

// ----------------------------------------------------------------------------
// Files: the standard output and error go to the trace channel.

fn isConsole(file: Io.File) bool {
    if (Io.File.Handle == void) {
        return true;
    } else {
        return file.handle == std.posix.STDOUT_FILENO or file.handle == std.posix.STDERR_FILENO;
    }
}

/// The standard output, on any target. On freestanding targets the
/// `std.Io.File` handle is `void` and `std.Io.File.stdout()` does not exist;
/// every file write of `uos.Io` goes to the trace channel there.
pub fn stdout() Io.File {
    if (Io.File.Handle == void) {
        return .{ .handle = {}, .flags = .{ .nonblocking = false } };
    } else {
        return .stdout();
    }
}

/// The standard error; see `stdout()`.
pub fn stderr() Io.File {
    if (Io.File.Handle == void) {
        return .{ .handle = {}, .flags = .{ .nonblocking = false } };
    } else {
        return .stderr();
    }
}

/// The console has no position: a positional write is a streaming one.
fn fileWritePositional(userdata: ?*anyopaque, file: Io.File, header: []const u8, data: []const []const u8, splat: usize, offset: u64) Io.File.WritePositionalError!usize {
    _ = offset;
    if (!isConsole(file)) return error.Unseekable;
    const r = operate(userdata, .{ .file_write_streaming = .{ .file = file, .header = header, .data = data, .splat = splat } }) catch return error.Unseekable;
    return r.file_write_streaming catch error.Unseekable;
}

fn operate(userdata: ?*anyopaque, operation: Io.Operation) Io.Cancelable!Io.Operation.Result {
    switch (operation) {
        .file_write_streaming => |w| {
            if (!isConsole(w.file)) return Io.failingOperate(userdata, operation);
            const cs = interrupts.CriticalSection.enter();
            defer cs.exit();
            var n: usize = w.header.len;
            port.trace.write(w.header);
            if (w.data.len > 0) {
                for (w.data[0 .. w.data.len - 1]) |bytes| {
                    port.trace.write(bytes);
                    n += bytes.len;
                }
                const pattern = w.data[w.data.len - 1];
                for (0..w.splat) |_| port.trace.write(pattern);
                n += pattern.len * w.splat;
            }
            return .{ .file_write_streaming = n };
        },
        else => return Io.failingOperate(userdata, operation),
    }
}
