//! data/samples.zig -- where the capstone's samples live: the four sources a
//! producer can take its samples from, each in one of the course's regions.
//! (C++: app/data/samples.*.)
//!
//!   .data    a static array (.data: the sample's non-zero initializer)
//!   .stack   an array on the producer's own stack
//!   .heap    the allocator, one by one
//!   .pool    a memory pool, its storage on the heap: fixed-size blocks, no
//!            fragmentation, a count of the blocks in use

const std = @import("std");
const uos = @import("uos");
const tutor = @import("tutor");
const config = @import("../core/config.zig");

const rtos = uos.rtos;
const Sample = tutor.Sample;

pub const Source = enum(u32) { data, stack, heap, pool };

pub fn sourceName(s: Source) []const u8 {
    return switch (s) {
        .data => "static",
        .stack => "stack",
        .heap => "new",
        .pool => "pool",
    };
}

/// The region a source's samples must lie in.
pub fn regionOf(s: Source) tutor.Region {
    return switch (s) {
        .data => .data,
        .stack => .stack,
        .heap, .pool => .heap, // the allocator, and the pool's storage
    };
}

var s_static: [config.per_producer]Sample = @splat(.{});
var s_pool: rtos.MemoryPoolTyped(Sample) = .{};
var s_pool_up = false;

/// The pool: created once (its storage from the heap), shared by every round.
pub fn poolCreate() bool {
    // per_producer blocks: the one pool producer takes them all, each round.
    s_pool.create(uos.memory.allocator(), "samples", config.per_producer, .{}) catch return false;
    s_pool_up = true;
    return s_pool.pool.capacity() == config.per_producer;
}

pub fn poolDestroy() void {
    if (s_pool_up) s_pool.deinit();
    s_pool_up = false;
}

/// Blocks in use.
pub fn poolInUse() usize {
    return if (s_pool_up) s_pool.pool.countUsed() else 0;
}

/// The static array of the `data` source: one producer uses it per round.
pub fn staticSamples() []Sample {
    return &s_static;
}

/// A sample from the heap or the pool, and back (null when exhausted).
pub fn take(s: Source) ?*Sample {
    return switch (s) {
        .heap => uos.memory.allocator().create(Sample) catch null,
        .pool => s_pool.tryAlloc() catch null,
        else => null,
    };
}

pub fn giveBack(s: Source, p: *Sample) void {
    switch (s) {
        .heap => uos.memory.allocator().destroy(p),
        .pool => s_pool.free(p) catch {},
        else => {},
    }
}
