//! Message queues (`os::rtos::message_queue`, `src/rtos/os-mqueue.cpp`).
//!
//! POSIX semantics: fixed size messages, ordered by priority (FIFO among
//! equal priorities); senders block when full, receivers when empty. The
//! `try*` calls may be used from interrupt handlers.
//!
//! The storage is one buffer: the message slots followed by the prev/next
//! index arrays and the priorities. Unlike the C++ edition, the free slots
//! are chained by index too, so a message may be smaller than a pointer.
//!
//! ```zig
//! var q: uos.rtos.MessageQueueTyped(Event).Static(8) = undefined;
//! try q.init("events", .{});
//! try q.queue.send(.{ .code = 1 }, 0);
//! const ev = try q.queue.receive();
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

const tr = config.options.trace;

pub const Index = u16;
pub const Priority = u8;

pub const default_priority: Priority = 0;
pub const max_priority: Priority = 0xFF;

const no_index: Index = std.math.maxInt(Index);

pub const Attributes = struct {
    clock: ?*clocks.Clock = null,
};

/// Bytes of storage needed for `msgs` messages of `msg_size_bytes`.
pub fn storageSize(msgs: usize, msg_size_bytes: usize) usize {
    return msgs * msg_size_bytes + msgs * (2 * @sizeOf(Index) + @sizeOf(Priority));
}

pub const MessageQueue = struct {
    name: [:0]const u8 = "-",
    clock: *clocks.Clock = &clocks.sysclock,
    send_list: lists.WaitingThreadsList = .{},
    receive_list: lists.WaitingThreadsList = .{},

    slots: []u8 = &.{},
    prev: []align(1) Index = &.{},
    next: []align(1) Index = &.{},
    prio: []Priority = &.{},

    msg_size: usize = 0,
    msgs: Index = 0,
    count: Index = 0,
    head: Index = no_index,
    first_free: Index = no_index,

    allocator: ?std.mem.Allocator = null,
    allocated: ?[]u8 = null,

    /// Initialise over a caller supplied buffer of at least
    /// `storageSize(msgs, msg_size_bytes)` bytes.
    pub fn init(mq: *MessageQueue, name: [:0]const u8, msgs: usize, msg_size_bytes: usize, buffer: []u8, attr: Attributes) Error!void {
        if (tr.mqueue) trace.print("MessageQueue.init() @{*} {s} {d}x{d}\n", .{ mq, name, msgs, msg_size_bytes });
        if (interrupts.inHandlerMode()) return error.NotPermitted;
        if (msgs == 0 or msgs >= no_index or msg_size_bytes == 0) return error.InvalidArgument;
        if (buffer.len < storageSize(msgs, msg_size_bytes)) return error.InvalidArgument;

        const slots_len = msgs * msg_size_bytes;
        const idx_bytes = msgs * @sizeOf(Index);
        mq.* = .{
            .name = name,
            .clock = attr.clock orelse &clocks.sysclock,
            .slots = buffer[0..slots_len],
            .prev = std.mem.bytesAsSlice(Index, buffer[slots_len..][0..idx_bytes]),
            .next = std.mem.bytesAsSlice(Index, buffer[slots_len + idx_bytes ..][0..idx_bytes]),
            .prio = buffer[slots_len + 2 * idx_bytes ..][0..msgs],
            .msg_size = msg_size_bytes,
            .msgs = @intCast(msgs),
        };
        mq.internalInit();
    }

    /// Initialise with storage from `gpa`; `deinit()` releases it.
    pub fn create(mq: *MessageQueue, gpa: std.mem.Allocator, name: [:0]const u8, msgs: usize, msg_size_bytes: usize, attr: Attributes) Error!void {
        const buffer = gpa.alloc(u8, storageSize(msgs, msg_size_bytes)) catch return error.OutOfMemory;
        errdefer gpa.free(buffer);
        try mq.init(name, msgs, msg_size_bytes, buffer, attr);
        mq.allocator = gpa;
        mq.allocated = buffer;
    }

    pub fn deinit(mq: *MessageQueue) void {
        assert(mq.send_list.isEmpty());
        assert(mq.receive_list.isEmpty());
        if (mq.allocated) |buffer| mq.allocator.?.free(buffer);
        mq.allocated = null;
    }

    fn internalInit(mq: *MessageQueue) void {
        mq.count = 0;
        mq.head = no_index;
        // Chain the free slots through `next`.
        for (0..mq.msgs) |i| mq.next[i] = if (i + 1 < mq.msgs) @intCast(i + 1) else no_index;
        mq.first_free = 0;
        mq.send_list.resumeAll();
        mq.receive_list.resumeAll();
    }

    fn slot(mq: *MessageQueue, ix: Index) []u8 {
        return mq.slots[@as(usize, ix) * mq.msg_size ..][0..mq.msg_size];
    }

    const SendRequest = struct { mq: *MessageQueue, msg: []const u8, prio: Priority };

    /// Called in an interrupts critical section.
    fn internalTrySend(r: SendRequest) ?void {
        const mq = r.mq;
        if (mq.first_free == no_index) return null;
        const ix = mq.first_free;
        mq.first_free = mq.next[ix];

        const dest = mq.slot(ix);
        @memcpy(dest[0..r.msg.len], r.msg);
        @memset(dest[r.msg.len..], 0);
        mq.prio[ix] = r.prio;

        if (mq.head == no_index) {
            mq.head = ix;
            mq.prev[ix] = ix;
            mq.next[ix] = ix;
        } else {
            // Insert after the last message with priority >= this one.
            var after = mq.prev[mq.head];
            if (r.prio > mq.prio[mq.head]) {
                mq.head = ix;
            } else {
                while (r.prio > mq.prio[after]) after = mq.prev[after];
            }
            mq.prev[ix] = after;
            mq.next[ix] = mq.next[after];
            const tmp = mq.next[after];
            mq.next[after] = ix;
            mq.prev[tmp] = ix;
        }
        mq.count += 1;
        _ = mq.receive_list.resumeOne();
        return {};
    }

    const ReceiveRequest = struct { mq: *MessageQueue, buf: []u8 };

    fn internalTryReceive(r: ReceiveRequest) ?Priority {
        const mq = r.mq;
        if (mq.head == no_index) return null;
        const ix = mq.head;
        const p = mq.prio[ix];
        if (mq.count > 1) {
            mq.prev[mq.next[ix]] = mq.prev[ix];
            mq.next[mq.prev[ix]] = mq.next[ix];
            mq.head = mq.next[ix];
        } else {
            mq.head = no_index;
        }
        mq.count -= 1;

        const src = mq.slot(ix);
        @memcpy(r.buf, src[0..r.buf.len]);

        mq.next[ix] = mq.first_free;
        mq.first_free = ix;
        _ = mq.send_list.resumeOne();
        return p;
    }

    fn checkSend(mq: *MessageQueue, msg: []const u8) Error!void {
        if (msg.len > mq.msg_size) return error.MessageSize;
    }

    /// Send a message (shorter messages are zero padded), waiting while the
    /// queue is full.
    pub fn send(mq: *MessageQueue, msg: []const u8, prio: Priority) Error!void {
        if (tr.mqueue) trace.print("MessageQueue.send({d}, {d}) @{*} {s}\n", .{ msg.len, prio, mq, mq.name });
        try mq.checkSend(msg);
        try scheduler.waitFor(void, &mq.send_list, mq.clock, null, SendRequest{ .mq = mq, .msg = msg, .prio = prio }, internalTrySend);
        port.scheduler.reschedule();
    }

    /// Send only if there is room (`error.WouldBlock`). ISR safe.
    pub fn trySend(mq: *MessageQueue, msg: []const u8, prio: Priority) Error!void {
        try mq.checkSend(msg);
        assert(interrupts.isPriorityValid());
        {
            const cs = interrupts.CriticalSection.enter();
            defer cs.exit();
            internalTrySend(.{ .mq = mq, .msg = msg, .prio = prio }) orelse return error.WouldBlock;
        }
        port.scheduler.reschedule();
    }

    /// Send, waiting at most `timeout` ticks for room.
    pub fn timedSend(mq: *MessageQueue, msg: []const u8, timeout: clocks.Duration, prio: Priority) Error!void {
        try mq.checkSend(msg);
        try scheduler.waitFor(void, &mq.send_list, mq.clock, timeout, SendRequest{ .mq = mq, .msg = msg, .prio = prio }, internalTrySend);
        port.scheduler.reschedule();
    }

    fn checkReceive(mq: *MessageQueue, buf: []u8) Error!void {
        if (buf.len > mq.msg_size) return error.MessageSize;
    }

    /// Receive the highest priority message into `buf` (at most the message
    /// size); returns its priority. Waits while the queue is empty.
    pub fn receive(mq: *MessageQueue, buf: []u8) Error!Priority {
        if (tr.mqueue) trace.print("MessageQueue.receive() @{*} {s}\n", .{ mq, mq.name });
        try mq.checkReceive(buf);
        const p = try scheduler.waitFor(Priority, &mq.receive_list, mq.clock, null, ReceiveRequest{ .mq = mq, .buf = buf }, internalTryReceive);
        port.scheduler.reschedule();
        return p;
    }

    /// Receive only if a message is there (`error.WouldBlock`). ISR safe.
    pub fn tryReceive(mq: *MessageQueue, buf: []u8) Error!Priority {
        try mq.checkReceive(buf);
        assert(interrupts.isPriorityValid());
        const p = blk: {
            const cs = interrupts.CriticalSection.enter();
            defer cs.exit();
            break :blk internalTryReceive(.{ .mq = mq, .buf = buf }) orelse return error.WouldBlock;
        };
        port.scheduler.reschedule();
        return p;
    }

    /// Receive, waiting at most `timeout` ticks for a message.
    pub fn timedReceive(mq: *MessageQueue, buf: []u8, timeout: clocks.Duration) Error!Priority {
        try mq.checkReceive(buf);
        const p = try scheduler.waitFor(Priority, &mq.receive_list, mq.clock, timeout, ReceiveRequest{ .mq = mq, .buf = buf }, internalTryReceive);
        port.scheduler.reschedule();
        return p;
    }

    /// Messages in the queue.
    pub fn length(mq: *const MessageQueue) usize {
        return mq.count;
    }

    pub fn capacity(mq: *const MessageQueue) usize {
        return mq.msgs;
    }

    pub fn msgSize(mq: *const MessageQueue) usize {
        return mq.msg_size;
    }

    pub fn isEmpty(mq: *const MessageQueue) bool {
        return mq.count == 0;
    }

    pub fn isFull(mq: *const MessageQueue) bool {
        return mq.count == mq.msgs;
    }

    /// Discard every message and wake all waiters.
    pub fn reset(mq: *MessageQueue) Error!void {
        if (interrupts.inHandlerMode()) return error.NotPermitted;
        const cs = interrupts.CriticalSection.enter();
        defer cs.exit();
        mq.internalInit();
    }
};

/// A queue of `T` values (`message_queue_typed<T>`).
pub fn MessageQueueTyped(comptime T: type) type {
    return struct {
        queue: MessageQueue = .{},

        const Self = @This();

        pub fn init(self: *Self, name: [:0]const u8, msgs: usize, buffer: []u8, attr: Attributes) Error!void {
            return self.queue.init(name, msgs, @sizeOf(T), buffer, attr);
        }

        pub fn create(self: *Self, gpa: std.mem.Allocator, name: [:0]const u8, msgs: usize, attr: Attributes) Error!void {
            return self.queue.create(gpa, name, msgs, @sizeOf(T), attr);
        }

        pub fn deinit(self: *Self) void {
            self.queue.deinit();
        }

        pub fn send(self: *Self, value: T, prio: Priority) Error!void {
            return self.queue.send(std.mem.asBytes(&value), prio);
        }

        pub fn trySend(self: *Self, value: T, prio: Priority) Error!void {
            return self.queue.trySend(std.mem.asBytes(&value), prio);
        }

        pub fn timedSend(self: *Self, value: T, timeout: clocks.Duration, prio: Priority) Error!void {
            return self.queue.timedSend(std.mem.asBytes(&value), timeout, prio);
        }

        pub fn receive(self: *Self) Error!T {
            var value: T = undefined;
            _ = try self.queue.receive(std.mem.asBytes(&value));
            return value;
        }

        pub fn tryReceive(self: *Self) Error!T {
            var value: T = undefined;
            _ = try self.queue.tryReceive(std.mem.asBytes(&value));
            return value;
        }

        pub fn timedReceive(self: *Self, timeout: clocks.Duration) Error!T {
            var value: T = undefined;
            _ = try self.queue.timedReceive(std.mem.asBytes(&value), timeout);
            return value;
        }

        /// A typed queue with its storage embedded (`message_queue_inclusive`).
        pub fn Static(comptime msgs: usize) type {
            return struct {
                typed: Self = .{},
                buffer: [storageSize(msgs, @sizeOf(T))]u8 align(@alignOf(T)) = undefined,

                pub fn init(s: *@This(), name: [:0]const u8, attr: Attributes) Error!void {
                    return s.typed.init(name, msgs, &s.buffer, attr);
                }
            };
        }
    };
}
