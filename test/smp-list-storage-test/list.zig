//! The generic intrusive list of the interfaces example
//! (~/Documents/work_zig/interfaces), on the RTOS, and two unrelated
//! payloads it is instantiated for: `Record`, a sealed record, and
//! `TextNode`, the example's `StringNode` (a 32-byte inline text buffer).
//!
//! The list never allocates and has no ownership: a node lives wherever its
//! owner put it (a thread's stack, the data segment or the heap) and must be
//! unlinked before that storage goes away. It has no locking; the test
//! guards it with an RTOS mutex.

const std = @import("std");

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
            self.push_front(node);
        }

        pub fn push_front(self: *Self, node: *T) void {
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

        pub fn contains(self: Self, node: *const T) bool {
            var it = self.head;
            while (it) |current| : (it = current.next) {
                if (current == node) return true;
            }
            return false;
        }
    };
}

/// Where a node's storage is.
pub const Region = enum(u8) { stack, data, heap };
pub const regions = [_]Region{ .stack, .data, .heap };

/// A record that can tell when its fields were changed behind its back:
/// `seal()` stores a hash of them, `valid()` recomputes it.
pub const Record = struct {
    next: ?*Record = null,
    id: u32 = 0,
    owner: u8 = 0,
    region: Region = .data,
    value: u64 = 0,
    seal_word: u64 = 0,

    pub fn init(self: *Record, id: u32, owner: u8, region: Region, value: u64) void {
        self.* = .{ .id = id, .owner = owner, .region = region, .value = value };
        self.seal();
    }

    fn hash(self: *const Record) u64 {
        var h: u64 = 0xcbf2_9ce4_8422_2325;
        for ([_]u64{ self.id, self.owner, @intFromEnum(self.region), self.value }) |x| {
            h = (h ^ x) *% 0x0000_0100_0000_01b3;
        }
        return h;
    }

    pub fn seal(self: *Record) void {
        self.seal_word = self.hash();
    }

    pub fn valid(self: *const Record) bool {
        return self.seal_word == self.hash();
    }
};

/// The example's `StringNode`.
pub const TextNode = struct {
    pub const capacity = 32;

    next: ?*TextNode = null,
    text: [capacity]u8 = undefined,
    len: usize = 0,
    region: Region = .data,

    pub fn init(self: *TextNode, text: []const u8, region: Region) !void {
        if (text.len > capacity) return error.TextTooLong;
        self.* = .{ .len = text.len, .region = region };
        @memcpy(self.text[0..text.len], text);
    }

    pub fn slice(self: *const TextNode) []const u8 {
        return self.text[0..self.len];
    }

    pub fn toUpper(self: *TextNode) void {
        for (self.text[0..self.len]) |*byte| {
            byte.* = std.ascii.toUpper(byte.*);
        }
    }
};
