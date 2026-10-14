//! Fixed size blocks allocator (`os::memory::block_pool`), as an
//! `std.mem.Allocator`: every allocation must fit in one block.
//! Not thread safe by itself: wrap it with `memory.Locked` for the RTOS.

const std = @import("std");
const assert = std.debug.assert;
const Alignment = std.mem.Alignment;

const BlockPool = @This();

const Free = struct { next: ?*Free };

name: []const u8,
pool: []u8,
block_size: usize,
blocks: usize,
first: ?*Free = null,
count: usize = 0,
max_count: usize = 0,

/// The size of a block of `block_size_bytes`, as the pool rounds it.
pub fn blockSize(block_size_bytes: usize) usize {
    return std.mem.alignForward(usize, @max(block_size_bytes, @sizeOf(usize)), @alignOf(usize));
}

pub fn init(name: []const u8, block_size_bytes: usize, buffer: []u8) BlockPool {
    const bs = blockSize(block_size_bytes);
    const start = std.mem.alignForward(usize, @intFromPtr(buffer.ptr), @alignOf(usize));
    const usable = buffer.len - (start - @intFromPtr(buffer.ptr));
    const blocks = usable / bs;
    assert(blocks > 0);
    var self: BlockPool = .{
        .name = name,
        .pool = @as([*]u8, @ptrFromInt(start))[0 .. blocks * bs],
        .block_size = bs,
        .blocks = blocks,
    };
    self.reset();
    return self;
}

pub fn reset(self: *BlockPool) void {
    var next: ?*Free = null;
    var i = self.blocks;
    while (i > 0) {
        i -= 1;
        const b: *Free = @ptrCast(@alignCast(&self.pool[i * self.block_size]));
        b.next = next;
        next = b;
    }
    self.first = next;
    self.count = 0;
}

pub fn allocator(self: *BlockPool) std.mem.Allocator {
    return .{ .ptr = self, .vtable = &.{
        .alloc = vAlloc,
        .resize = vResize,
        .remap = std.mem.Allocator.noRemap,
        .free = vFree,
    } };
}

fn vAlloc(ctx: *anyopaque, len: usize, alignment: Alignment, ret_addr: usize) ?[*]u8 {
    _ = ret_addr;
    const self: *BlockPool = @ptrCast(@alignCast(ctx));
    if (len > self.block_size or alignment.toByteUnits() > @alignOf(usize)) return null;
    const b = self.first orelse return null;
    self.first = b.next;
    self.count += 1;
    self.max_count = @max(self.max_count, self.count);
    return @ptrCast(b);
}

fn vResize(ctx: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) bool {
    _ = memory;
    _ = alignment;
    _ = ret_addr;
    const self: *BlockPool = @ptrCast(@alignCast(ctx));
    return new_len <= self.block_size;
}

fn vFree(ctx: *anyopaque, memory: []u8, alignment: Alignment, ret_addr: usize) void {
    _ = alignment;
    _ = ret_addr;
    const self: *BlockPool = @ptrCast(@alignCast(ctx));
    const a = @intFromPtr(memory.ptr);
    const start = @intFromPtr(self.pool.ptr);
    if (a < start or a >= start + self.pool.len) {
        assert(false);
        return;
    }
    const b: *Free = @ptrCast(@alignCast(memory.ptr));
    b.next = self.first;
    self.first = b;
    self.count -= 1;
}

test BlockPool {
    var buffer: [256]u8 align(8) = undefined;
    var bp: BlockPool = .init("bp", 32, &buffer);
    const a = bp.allocator();
    const p = try a.create([4]u64);
    try std.testing.expectEqual(1, bp.count);
    try std.testing.expectError(error.OutOfMemory, a.alloc(u8, 64));
    a.destroy(p);
    try std.testing.expectEqual(0, bp.count);
}
