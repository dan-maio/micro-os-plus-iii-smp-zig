//! First fit, top down allocator (`os::memory::first_fit_top`, and with
//! `.lifo` the `os::memory::lifo` variant), as an `std.mem.Allocator`.
//!
//! The arena is a list of chunks `{ size, next }`; the free list is ordered
//! by address. Allocation takes the first free chunk large enough and
//! carves the block from its top (so a fresh arena fills from the top
//! down); deallocation re-inserts the chunk in address order and coalesces
//! it with its neighbours.
//!
//! The `.lifo` policy allocates only from the lowest free chunk, which
//! makes allocation deterministic and fragmentation free for strictly LIFO
//! usage (startup objects, pools).
//!
//! Not thread safe by itself: wrap it with `memory.Locked` for the RTOS.

const std = @import("std");
const assert = std.debug.assert;
const Alignment = std.mem.Alignment;

const FirstFitTop = @This();

pub const Policy = enum { first_fit_top, lifo };

const Chunk = extern struct {
    /// The chunk size in bytes, header included. In an alignment gap, the
    /// word before the payload holds the negative offset to the chunk.
    size: usize,
    /// Free chunks: the next free chunk. Allocated chunks: the payload.
    next: ?*Chunk,
};

const chunk_align = @sizeOf(usize);
const chunk_offset = @offsetOf(Chunk, "next");
const chunk_minsize = @sizeOf(Chunk);
const block_minsize = @sizeOf(usize);

pub const Statistics = struct {
    total_bytes: usize = 0,
    allocated_bytes: usize = 0,
    max_allocated_bytes: usize = 0,
    free_bytes: usize = 0,
    allocated_chunks: usize = 0,
    free_chunks: usize = 0,
};

name: []const u8,
policy: Policy,
arena: []u8,
free_list: ?*Chunk = null,
stats: Statistics = .{},
/// Called when an allocation fails; may free memory and return true to
/// retry (`out_of_memory_handler`).
out_of_memory_handler: ?*const fn () bool = null,

pub fn init(name: []const u8, arena: []u8, policy: Policy) FirstFitTop {
    var self: FirstFitTop = .{ .name = name, .policy = policy, .arena = &.{} };
    const start = std.mem.alignForward(usize, @intFromPtr(arena.ptr), chunk_align);
    const end = std.mem.alignBackward(usize, @intFromPtr(arena.ptr) + arena.len, chunk_align);
    assert(end > start and end - start > chunk_minsize);
    self.arena = @as([*]u8, @ptrFromInt(start))[0 .. end - start];
    self.reset();
    return self;
}

/// Forget every allocation.
pub fn reset(self: *FirstFitTop) void {
    const chunk: *Chunk = @ptrCast(@alignCast(self.arena.ptr));
    chunk.size = self.arena.len;
    chunk.next = null;
    self.free_list = chunk;
    self.stats = .{
        .total_bytes = self.arena.len,
        .free_bytes = self.arena.len,
        .free_chunks = 1,
    };
}

pub fn allocator(self: *FirstFitTop) std.mem.Allocator {
    return .{ .ptr = self, .vtable = &vtable };
}

pub const vtable: std.mem.Allocator.VTable = .{
    .alloc = vAlloc,
    .resize = vResize,
    .remap = vRemap,
    .free = vFree,
};

fn vAlloc(ctx: *anyopaque, len: usize, alignment: Alignment, ret_addr: usize) ?[*]u8 {
    _ = ret_addr;
    const self: *FirstFitTop = @ptrCast(@alignCast(ctx));
    return self.allocate(len, alignment.toByteUnits());
}

fn vResize(ctx: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) bool {
    _ = alignment;
    _ = ret_addr;
    const self: *FirstFitTop = @ptrCast(@alignCast(ctx));
    // Shrinking or growing within the chunk is free; nothing moves.
    return new_len <= self.usableSize(memory.ptr);
}

fn vRemap(ctx: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
    return if (vResize(ctx, memory, alignment, new_len, ret_addr)) memory.ptr else null;
}

fn vFree(ctx: *anyopaque, memory: []u8, alignment: Alignment, ret_addr: usize) void {
    _ = alignment;
    _ = ret_addr;
    const self: *FirstFitTop = @ptrCast(@alignCast(ctx));
    self.deallocate(memory.ptr, memory.len);
}

fn calcBlockPadding(alignment: usize) usize {
    return @max(alignment, chunk_align) - chunk_align;
}

fn calcBlockMinchunk(block_padding: usize) usize {
    return chunk_offset + block_minsize + block_padding;
}

pub fn allocate(self: *FirstFitTop, bytes: usize, alignment: usize) ?[*]u8 {
    const total = self.arena.len;
    if (bytes > total) return null;

    const block_padding = calcBlockPadding(alignment);
    var alloc_size = std.mem.alignForward(usize, @max(bytes, 1), chunk_align);
    alloc_size += block_padding + chunk_offset;
    const block_minchunk = calcBlockMinchunk(block_padding);
    alloc_size = @max(alloc_size, block_minchunk);
    if (alloc_size > total) return null;

    while (true) {
        if (self.takeChunk(alloc_size, block_minchunk)) |chunk| {
            return self.alignPayload(chunk, alignment);
        }
        const handler = self.out_of_memory_handler orelse return null;
        if (!handler()) return null;
    }
}

fn takeChunk(self: *FirstFitTop, alloc_size: usize, block_minchunk: usize) ?*Chunk {
    var prev: ?*Chunk = null;
    var chunk = self.free_list;
    while (chunk) |c| {
        if (c.size >= alloc_size) {
            const rem = c.size - alloc_size;
            if (rem >= block_minchunk) {
                // Split: keep the bottom free, hand out the top.
                c.size = rem;
                const top: *Chunk = @ptrFromInt(@intFromPtr(c) + rem);
                top.size = alloc_size;
                self.stats.free_chunks += 1;
                return top;
            }
            // Take it whole.
            if (prev) |p| p.next = c.next else self.free_list = c.next;
            return c;
        }
        // LIFO: only the lowest free chunk is a candidate.
        if (self.policy == .lifo) return null;
        prev = c;
        chunk = c.next;
    }
    return null;
}

fn alignPayload(self: *FirstFitTop, chunk: *Chunk, alignment: usize) [*]u8 {
    self.stats.allocated_bytes += chunk.size;
    self.stats.free_bytes -= chunk.size;
    self.stats.allocated_chunks += 1;
    self.stats.free_chunks -= 1;
    self.stats.max_allocated_bytes = @max(self.stats.max_allocated_bytes, self.stats.allocated_bytes);

    const payload = @intFromPtr(chunk) + chunk_offset;
    const aligned = std.mem.alignForward(usize, payload, @max(alignment, 1));
    const offset = aligned - payload;
    if (offset != 0) {
        // The word before the aligned payload points back to the chunk.
        const adj: *usize = @ptrFromInt(aligned - chunk_offset);
        adj.* = @bitCast(-@as(isize, @intCast(offset)));
    }
    return @ptrFromInt(aligned);
}

fn chunkOf(addr: [*]u8) *Chunk {
    const header: *usize = @ptrFromInt(@intFromPtr(addr) - chunk_offset);
    const signed: isize = @bitCast(header.*);
    const chunk_addr = if (signed < 0)
        @intFromPtr(header) - @as(usize, @intCast(-signed))
    else
        @intFromPtr(header);
    return @ptrFromInt(chunk_addr);
}

/// The bytes usable at `addr` (the rest of its chunk).
pub fn usableSize(self: *FirstFitTop, addr: [*]u8) usize {
    _ = self;
    const chunk = chunkOf(addr);
    return @intFromPtr(chunk) + chunk.size - @intFromPtr(addr);
}

pub fn deallocate(self: *FirstFitTop, addr: [*]u8, bytes: usize) void {
    const a = @intFromPtr(addr);
    const start = @intFromPtr(self.arena.ptr);
    if (a < start or a > start + self.arena.len) {
        assert(false);
        return;
    }
    const chunk = chunkOf(addr);
    if (bytes != 0 and bytes + chunk_offset > chunk.size) {
        assert(false);
        return;
    }

    self.stats.allocated_bytes -= chunk.size;
    self.stats.free_bytes += chunk.size;
    self.stats.allocated_chunks -= 1;
    self.stats.free_chunks += 1;

    const head = self.free_list orelse {
        chunk.next = null;
        self.free_list = chunk;
        return;
    };

    if (@intFromPtr(chunk) < @intFromPtr(head)) {
        // Before the first free chunk: insert in front, merging if adjacent.
        if (@intFromPtr(chunk) + chunk.size == @intFromPtr(head)) {
            chunk.size += head.size;
            chunk.next = head.next;
            self.stats.free_chunks -= 1;
        } else {
            chunk.next = head;
        }
        self.free_list = chunk;
        return;
    }

    // Find the free chunks around it.
    var prev = head;
    var next = head.next;
    while (next) |n| {
        if (@intFromPtr(n) > @intFromPtr(chunk)) break;
        prev = n;
        next = n.next;
    }

    const prev_end = @intFromPtr(prev) + prev.size;
    if (prev_end == @intFromPtr(chunk)) {
        // Merge with the previous one, and maybe with the next one too.
        prev.size += chunk.size;
        self.stats.free_chunks -= 1;
        if (next) |n| {
            if (@intFromPtr(prev) + prev.size == @intFromPtr(n)) {
                prev.size += n.size;
                prev.next = n.next;
                self.stats.free_chunks -= 1;
            }
        }
    } else if (prev_end > @intFromPtr(chunk)) {
        // Overlap: a double free. Undo the statistics and ignore it.
        self.stats.allocated_bytes += chunk.size;
        self.stats.free_bytes -= chunk.size;
        self.stats.allocated_chunks += 1;
        self.stats.free_chunks -= 1;
        assert(false);
    } else if (next != null and @intFromPtr(chunk) + chunk.size == @intFromPtr(next.?)) {
        chunk.size += next.?.size;
        chunk.next = next.?.next;
        prev.next = chunk;
        self.stats.free_chunks -= 1;
    } else {
        chunk.next = next;
        prev.next = chunk;
    }
}

pub fn maxSize(self: *const FirstFitTop) usize {
    return self.arena.len;
}

// ----------------------------------------------------------------------------

test "FirstFitTop: allocate, free, coalesce" {
    var buffer: [1024]u8 align(8) = undefined;
    var ff: FirstFitTop = .init("test", &buffer, .first_fit_top);
    const a = ff.allocator();

    const p1 = try a.alloc(u8, 100);
    const p2 = try a.alloc(u32, 10);
    const p3 = try a.alignedAlloc(u8, .@"64", 3);
    try std.testing.expect(@intFromPtr(p3.ptr) % 64 == 0);
    try std.testing.expectEqual(3, ff.stats.allocated_chunks);
    // Top down: the first block is the highest.
    try std.testing.expect(@intFromPtr(p1.ptr) > @intFromPtr(p2.ptr));

    a.free(p2);
    a.free(p1);
    a.free(p3);
    try std.testing.expectEqual(0, ff.stats.allocated_chunks);
    try std.testing.expectEqual(1, ff.stats.free_chunks);
    try std.testing.expectEqual(ff.arena.len, ff.stats.free_bytes);

    // The whole arena is usable again.
    const big = try a.alloc(u8, ff.arena.len - 64);
    a.free(big);
    try std.testing.expectError(error.OutOfMemory, a.alloc(u8, 4096));
}

test "FirstFitTop: lifo policy" {
    var buffer: [512]u8 align(8) = undefined;
    var lifo: FirstFitTop = .init("lifo", &buffer, .lifo);
    const a = lifo.allocator();
    const p1 = try a.alloc(u8, 16);
    const p2 = try a.alloc(u8, 16);
    a.free(p2);
    a.free(p1);
    try std.testing.expectEqual(1, lifo.stats.free_chunks);
}
