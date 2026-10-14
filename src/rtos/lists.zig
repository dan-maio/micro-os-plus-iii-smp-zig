//! Intrusive doubly linked lists (`utils/lists.h`, `rtos/internal/os-lists.h`).
//!
//! The lists are circular, with the list head acting as sentinel. As in the
//! C++ `static_double_list`, a list whose head pointers are still null is a
//! valid empty list, so every list here can be default-initialised (`.{}`)
//! in static storage and needs no constructor; it is closed into a ring the
//! first time a node is linked.
//!
//! Nodes embed a `Links` and are recovered with `@fieldParentPtr`, which is
//! the Zig rendering of the C++ `intrusive_list<T, N, &T::member>`.
//!
//! None of these functions lock: callers hold the interrupts critical
//! section (and, on SMP, the kernel lock that comes with it).

const std = @import("std");
const assert = std.debug.assert;

const Thread = @import("thread.zig").Thread;

pub const Links = struct {
    prev: ?*Links = null,
    next: ?*Links = null,

    /// A node is unlinked when its `next` pointer is null.
    pub fn isUnlinked(l: *const Links) bool {
        return l.next == null;
    }

    pub fn isLinked(l: *const Links) bool {
        return l.next != null;
    }

    /// Remove the node from whatever list it is in; a no-op when unlinked.
    pub fn unlink(l: *Links) void {
        const next = l.next orelse {
            assert(l.prev == null);
            return;
        };
        const prev = l.prev.?;
        prev.next = next;
        next.prev = prev;
        l.prev = null;
        l.next = null;
    }
};

/// The base list, a ring through `head`.
pub const List = struct {
    head: Links = .{},

    /// Make the list empty (the head points to itself).
    pub fn clear(list: *List) void {
        list.head.next = &list.head;
        list.head.prev = &list.head;
    }

    fn ensureInitialised(list: *List) void {
        if (list.head.prev == null) list.clear();
    }

    pub fn isEmpty(list: *const List) bool {
        const next = list.head.next orelse return true;
        return next == &list.head;
    }

    pub fn sentinel(list: *List) *Links {
        return &list.head;
    }

    /// First node, or null when empty.
    pub fn first(list: *List) ?*Links {
        if (list.isEmpty()) return null;
        return list.head.next;
    }

    /// Last node, or null when empty.
    pub fn last(list: *List) ?*Links {
        if (list.isEmpty()) return null;
        return list.head.prev;
    }

    /// The node after which an append would insert (the tail, or the head).
    pub fn tail(list: *List) *Links {
        list.ensureInitialised();
        return list.head.prev.?;
    }

    pub fn insertAfter(list: *List, node: *Links, after: *Links) void {
        list.ensureInitialised();
        // An unlinked node must have both pointers null; otherwise it is
        // most probably already linked, or the memory is corrupted.
        assert(node.prev == null and node.next == null);
        assert(after.next != null);
        node.prev = after;
        node.next = after.next;
        after.next.?.prev = node;
        after.next = node;
    }

    pub fn append(list: *List, node: *Links) void {
        list.insertAfter(node, list.tail());
    }

    /// Unlink and return the first node, or null when empty.
    pub fn popFirst(list: *List) ?*Links {
        const node = list.first() orelse return null;
        node.unlink();
        return node;
    }

    /// Iterate the nodes in order; the current node may not be unlinked
    /// while iterating.
    pub fn iterator(list: *List) Iterator {
        return .{ .sentinel = &list.head, .node = if (list.isEmpty()) null else list.head.next };
    }

    pub const Iterator = struct {
        sentinel: *Links,
        node: ?*Links,

        pub fn next(it: *Iterator) ?*Links {
            const node = it.node orelse return null;
            if (node == it.sentinel) return null;
            it.node = node.next;
            return node;
        }
    };

    /// Typed view: iterate the parent objects of the nodes.
    pub fn TypedIterator(comptime T: type, comptime field: []const u8) type {
        return struct {
            inner: Iterator,
            pub fn next(it: *@This()) ?*T {
                const links = it.inner.next() orelse return null;
                return @alignCast(@fieldParentPtr(field, links));
            }
        };
    }

    pub fn typedIterator(list: *List, comptime T: type, comptime field: []const u8) TypedIterator(T, field) {
        return .{ .inner = list.iterator() };
    }
};

// ----------------------------------------------------------------------------

/// A thread waiting in a list (`waiting_thread_node`). Used for the ready
/// list (embedded in the thread) and, on the waiter's stack, for every object
/// a thread can block on.
pub const WaitingThreadNode = struct {
    links: Links = .{},
    thread: *Thread,

    pub fn fromLinks(links: *Links) *WaitingThreadNode {
        return @alignCast(@fieldParentPtr("links", links));
    }
};

/// Priority ordered list of waiting threads: the highest priority first,
/// FIFO among equal priorities.
fn linkByPriority(list: *List, node: *WaitingThreadNode) void {
    const prio = node.thread.priority();

    var after = list.tail();
    if (list.isEmpty()) {
        // Insert at the end (after the head).
    } else if (prio <= WaitingThreadNode.fromLinks(after).thread.priority()) {
        // Insert at the end, after the last thread of equal or higher
        // priority, which is the most frequent case.
    } else if (prio > WaitingThreadNode.fromLinks(list.first().?).thread.priority()) {
        // Higher than the first: insert in front.
        after = list.sentinel();
    } else {
        // Walk back from the end to the first node with priority >= prio.
        while (prio > WaitingThreadNode.fromLinks(after).thread.priority()) {
            after = after.prev.?;
        }
    }
    list.insertAfter(&node.links, after);
}

/// The scheduler ready list (`ready_threads_list`).
pub const ReadyThreadsList = struct {
    list: List = .{},

    pub fn link(rl: *ReadyThreadsList, node: *WaitingThreadNode) void {
        linkByPriority(&rl.list, node);
        node.thread.state = .ready;
    }

    pub fn isEmpty(rl: *const ReadyThreadsList) bool {
        return rl.list.isEmpty();
    }

    pub fn first(rl: *ReadyThreadsList) ?*WaitingThreadNode {
        const links = rl.list.first() orelse return null;
        return WaitingThreadNode.fromLinks(links);
    }

    /// Unlink the highest priority thread and mark it running.
    pub fn unlinkHead(rl: *ReadyThreadsList) *Thread {
        const node = rl.first().?;
        node.links.unlink();
        node.thread.state = .running;
        return node.thread;
    }
};

/// Threads waiting for a synchronisation object (`waiting_threads_list`).
pub const WaitingThreadsList = struct {
    list: List = .{},

    pub fn link(wl: *WaitingThreadsList, node: *WaitingThreadNode) void {
        linkByPriority(&wl.list, node);
    }

    pub fn isEmpty(wl: *const WaitingThreadsList) bool {
        return wl.list.isEmpty();
    }

    pub fn first(wl: *WaitingThreadsList) ?*WaitingThreadNode {
        const links = wl.list.first() orelse return null;
        return WaitingThreadNode.fromLinks(links);
    }

    /// Wake the highest priority waiter; false when there is none.
    pub fn resumeOne(wl: *WaitingThreadsList) bool {
        const interrupts = @import("interrupts.zig");
        var th: *Thread = undefined;
        {
            const cs = interrupts.CriticalSection.enter();
            defer cs.exit();
            const node = wl.first() orelse return false;
            th = node.thread;
            node.links.unlink();
        }
        if (th.state != .destroyed) th.@"resume"();
        return true;
    }

    pub fn resumeAll(wl: *WaitingThreadsList) void {
        while (wl.resumeOne()) {}
    }

    pub fn threads(wl: *WaitingThreadsList) ThreadIterator {
        return .{ .inner = wl.list.iterator() };
    }

    pub const ThreadIterator = struct {
        inner: List.Iterator,
        pub fn next(it: *ThreadIterator) ?*Thread {
            const links = it.inner.next() orelse return null;
            return WaitingThreadNode.fromLinks(links).thread;
        }
    };
};

/// Terminated threads waiting for the idle thread to destroy them.
pub const TerminatedThreadsList = struct {
    list: List = .{},

    pub fn link(tl: *TerminatedThreadsList, node: *WaitingThreadNode) void {
        node.thread.state = .terminated;
        tl.list.append(&node.links);
    }

    pub fn isEmpty(tl: *const TerminatedThreadsList) bool {
        return tl.list.isEmpty();
    }

    pub fn first(tl: *TerminatedThreadsList) ?*WaitingThreadNode {
        const links = tl.list.first() orelse return null;
        return WaitingThreadNode.fromLinks(links);
    }
};

// ----------------------------------------------------------------------------

/// A node in a clock list, ordered by timestamp (`timestamp_node`). The C++
/// virtual `action()` becomes a function pointer; the concrete nodes embed
/// this one and recover themselves with `@fieldParentPtr`.
pub const TimestampNode = struct {
    links: Links = .{},
    timestamp: u64,
    action: *const fn (node: *TimestampNode) void,

    pub fn fromLinks(links: *Links) *TimestampNode {
        return @alignCast(@fieldParentPtr("links", links));
    }
};

/// A thread sleeping until a timestamp (`timeout_thread_node`).
pub const TimeoutThreadNode = struct {
    node: TimestampNode,
    thread: *Thread,

    pub fn init(timestamp: u64, th: *Thread) TimeoutThreadNode {
        return .{ .node = .{ .timestamp = timestamp, .action = action }, .thread = th };
    }

    fn action(node: *TimestampNode) void {
        const self: *TimeoutThreadNode = @alignCast(@fieldParentPtr("node", node));
        const th = self.thread;
        node.links.unlink();
        if (th.state != .destroyed) th.@"resume"();
    }
};

/// The clock lists of sleeping threads and armed timers
/// (`clock_timestamps_list`), ordered by timestamp, FIFO among equals.
pub const ClockTimestampsList = struct {
    list: List = .{},

    pub fn isEmpty(cl: *const ClockTimestampsList) bool {
        return cl.list.isEmpty();
    }

    pub fn first(cl: *ClockTimestampsList) ?*TimestampNode {
        const links = cl.list.first() orelse return null;
        return TimestampNode.fromLinks(links);
    }

    pub fn link(cl: *ClockTimestampsList, node: *TimestampNode) void {
        const timestamp = node.timestamp;
        var after = cl.list.tail();
        if (cl.list.isEmpty()) {
            // Insert at the end.
        } else if (timestamp >= TimestampNode.fromLinks(after).timestamp) {
            // Insert at the end, the most frequent case.
        } else if (timestamp < TimestampNode.fromLinks(cl.list.first().?).timestamp) {
            after = cl.list.sentinel();
        } else {
            while (timestamp < TimestampNode.fromLinks(after).timestamp) {
                after = after.prev.?;
            }
        }
        cl.list.insertAfter(&node.links, after);
    }

    /// Run the action of every node whose timestamp is due. Called from the
    /// tick interrupt; each node is unlinked inside a critical section and
    /// its action runs outside it.
    pub fn checkTimestamp(cl: *ClockTimestampsList, now: u64) void {
        const interrupts = @import("interrupts.zig");
        if (cl.list.head.next == null) return; // never used
        while (true) {
            var node: *TimestampNode = undefined;
            {
                const cs = interrupts.CriticalSection.enter();
                defer cs.exit();
                const head = cl.first() orelse return;
                if (now < head.timestamp) return;
                node = head;
                node.links.unlink();
            }
            node.action(node);
        }
    }
};

// ----------------------------------------------------------------------------

test "List: link, unlink, iterate" {
    var list: List = .{};
    try std.testing.expect(list.isEmpty());

    var a: Links = .{};
    var b: Links = .{};
    var c: Links = .{};
    list.append(&a);
    list.append(&b);
    list.insertAfter(&c, &a);
    try std.testing.expect(!list.isEmpty());

    var it = list.iterator();
    try std.testing.expectEqual(&a, it.next().?);
    try std.testing.expectEqual(&c, it.next().?);
    try std.testing.expectEqual(&b, it.next().?);
    try std.testing.expectEqual(null, it.next());

    c.unlink();
    try std.testing.expect(c.isUnlinked());
    c.unlink(); // idempotent
    try std.testing.expectEqual(&a, list.popFirst().?);
    try std.testing.expectEqual(&b, list.popFirst().?);
    try std.testing.expect(list.isEmpty());
    try std.testing.expectEqual(null, list.popFirst());
}
