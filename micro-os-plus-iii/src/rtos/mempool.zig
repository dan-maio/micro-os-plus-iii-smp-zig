//! Fixed size memory pools (`os::rtos::memory_pool`, `src/rtos/os-mempool.cpp`).
//!
//! Deterministic allocation of equal blocks; `tryAlloc()` and `free()` may
//! be called from interrupt handlers.
//!
//! ```zig
//! var pool: uos.rtos.MemoryPoolTyped(Packet).Static(16) = .{};
//! try pool.init("packets", .{});
//! const p = try pool.pool.alloc();   // *Packet
//! try pool.pool.free(p);
//! ```

const std = @import("std");
const assert = std.debug.assert;

const config = @import("../config.zig");
const trace = @import("../trace.zig");
const Error = @import("result.zig").Error;
const interrupts = @import("interrupts.zig");
const scheduler = @import("scheduler.zig");
const lists = @import("lists.zig");
const clocks = @import("clocks.zig");

const tr = config.options.trace;

pub const Attributes = struct {
    clock: ?*clocks.Clock = null,
};

/// Blocks are rounded up to a pointer, which also holds the free list link.
pub fn blockSize(block_size_bytes: usize) usize {
    return std.mem.alignForward(usize, @max(block_size_bytes, @sizeOf(usize)), @alignOf(usize));
}

pub fn storageSize(blocks: usize, block_size_bytes: usize) usize {
    return blocks * blockSize(block_size_bytes);
}

const FreeBlock = struct { next: ?*FreeBlock };

pub const MemoryPool = struct {
    name: [:0]const u8 = "-",
    clock: *clocks.Clock = &clocks.sysclock,
    list: lists.WaitingThreadsList = .{},

    pool: []align(@alignOf(usize)) u8 = &.{},
    block_size: usize = 0,
    blocks: usize = 0,
    count: usize = 0,
    first: ?*FreeBlock = null,

    allocator: ?std.mem.Allocator = null,
    allocated: ?[]align(@alignOf(usize)) u8 = null,

    /// Initialise over a caller supplied buffer of at least
    /// `storageSize(blocks, block_size_bytes)` bytes.
    pub fn init(mp: *MemoryPool, name: [:0]const u8, blocks: usize, block_size_bytes: usize, buffer: []align(@alignOf(usize)) u8, attr: Attributes) Error!void {
        if (tr.mempool) trace.print("MemoryPool.init() @{*} {s} {d}x{d}\n", .{ mp, name, blocks, block_size_bytes });
        if (interrupts.inHandlerMode()) return error.NotPermitted;
        if (blocks == 0) return error.InvalidArgument;
        const bs = blockSize(block_size_bytes);
        if (buffer.len < blocks * bs) return error.InvalidArgument;
        mp.* = .{
            .name = name,
            .clock = attr.clock orelse &clocks.sysclock,
            .pool = buffer[0 .. blocks * bs],
            .block_size = bs,
            .blocks = blocks,
        };
        mp.internalInit();
    }

    /// Initialise with storage from `gpa`; `deinit()` releases it.
    pub fn create(mp: *MemoryPool, gpa: std.mem.Allocator, name: [:0]const u8, blocks: usize, block_size_bytes: usize, attr: Attributes) Error!void {
        // 8: enough for the typed pools of u64/f64 on 32-bit targets.
        const buffer = gpa.alignedAlloc(u8, .@"8", storageSize(blocks, block_size_bytes)) catch return error.OutOfMemory;
        errdefer gpa.free(buffer);
        try mp.init(name, blocks, block_size_bytes, buffer, attr);
        mp.allocator = gpa;
        mp.allocated = buffer;
    }

    pub fn deinit(mp: *MemoryPool) void {
        assert(mp.list.isEmpty());
        if (mp.allocated) |buffer| mp.allocator.?.free(buffer);
        mp.allocated = null;
    }

    fn internalInit(mp: *MemoryPool) void {
        var next: ?*FreeBlock = null;
        var i = mp.blocks;
        while (i > 0) {
            i -= 1;
            const b: *FreeBlock = @ptrCast(@alignCast(&mp.pool[i * mp.block_size]));
            b.next = next;
            next = b;
        }
        mp.first = next;
        mp.count = 0;
    }

    /// Called in an interrupts critical section.
    fn internalTryFirst(mp: *MemoryPool) ?*anyopaque {
        const b = mp.first orelse return null;
        mp.first = b.next;
        mp.count += 1;
        return b;
    }

    /// Allocate a block, waiting while the pool is empty.
    pub fn alloc(mp: *MemoryPool) Error!*anyopaque {
        return scheduler.waitFor(*anyopaque, &mp.list, mp.clock, null, mp, internalTryFirst);
    }

    /// Allocate a block only if one is free (`error.WouldBlock`). ISR safe.
    pub fn tryAlloc(mp: *MemoryPool) Error!*anyopaque {
        assert(interrupts.isPriorityValid());
        const cs = interrupts.CriticalSection.enter();
        defer cs.exit();
        return mp.internalTryFirst() orelse error.WouldBlock;
    }

    /// Allocate a block, waiting at most `timeout` ticks.
    pub fn timedAlloc(mp: *MemoryPool, timeout: clocks.Duration) Error!*anyopaque {
        return scheduler.waitFor(*anyopaque, &mp.list, mp.clock, timeout, mp, internalTryFirst);
    }

    /// Return a block; wakes one waiter. ISR safe.
    pub fn free(mp: *MemoryPool, block: *anyopaque) Error!void {
        assert(interrupts.isPriorityValid());
        const addr = @intFromPtr(block);
        const start = @intFromPtr(mp.pool.ptr);
        if (addr < start or addr >= start + mp.pool.len or (addr - start) % mp.block_size != 0)
            return error.InvalidArgument;
        {
            const cs = interrupts.CriticalSection.enter();
            defer cs.exit();
            const b: *FreeBlock = @ptrCast(@alignCast(block));
            b.next = mp.first;
            mp.first = b;
            mp.count -= 1;
        }
        _ = mp.list.resumeOne();
    }

    /// Blocks in use.
    pub fn countUsed(mp: *const MemoryPool) usize {
        return mp.count;
    }

    pub fn capacity(mp: *const MemoryPool) usize {
        return mp.blocks;
    }

    pub fn isEmpty(mp: *const MemoryPool) bool {
        return mp.count == 0;
    }

    pub fn isFull(mp: *const MemoryPool) bool {
        return mp.count == mp.blocks;
    }

    /// All blocks free again; waiters are resumed.
    pub fn reset(mp: *MemoryPool) Error!void {
        if (interrupts.inHandlerMode()) return error.NotPermitted;
        {
            const cs = interrupts.CriticalSection.enter();
            defer cs.exit();
            mp.internalInit();
        }
        mp.list.resumeAll();
    }
};

/// A pool of `T` blocks (`memory_pool_typed<T>`).
pub fn MemoryPoolTyped(comptime T: type) type {
    return struct {
        pool: MemoryPool = .{},

        const Self = @This();

        /// Blocks rounded to the alignment of `T` (which may exceed a pointer's).
        pub const block_size = std.mem.alignForward(usize, @sizeOf(T), @max(@alignOf(T), @alignOf(usize)));

        pub fn init(self: *Self, name: [:0]const u8, blocks: usize, buffer: []align(@alignOf(usize)) u8, attr: Attributes) Error!void {
            if (@intFromPtr(buffer.ptr) % @alignOf(T) != 0) return error.InvalidArgument;
            return self.pool.init(name, blocks, block_size, buffer, attr);
        }

        pub fn create(self: *Self, gpa: std.mem.Allocator, name: [:0]const u8, blocks: usize, attr: Attributes) Error!void {
            comptime assert(@alignOf(T) <= 8);
            return self.pool.create(gpa, name, blocks, block_size, attr);
        }

        pub fn deinit(self: *Self) void {
            self.pool.deinit();
        }

        pub fn alloc(self: *Self) Error!*T {
            return @ptrCast(@alignCast(try self.pool.alloc()));
        }

        pub fn tryAlloc(self: *Self) Error!*T {
            return @ptrCast(@alignCast(try self.pool.tryAlloc()));
        }

        pub fn timedAlloc(self: *Self, timeout: clocks.Duration) Error!*T {
            return @ptrCast(@alignCast(try self.pool.timedAlloc(timeout)));
        }

        pub fn free(self: *Self, block: *T) Error!void {
            return self.pool.free(block);
        }

        /// A typed pool with its storage embedded (`memory_pool_inclusive`).
        pub fn Static(comptime blocks: usize) type {
            return struct {
                typed: Self = .{},
                buffer: [storageSize(blocks, block_size)]u8 align(@max(@alignOf(T), @alignOf(usize))) = undefined,

                pub fn init(s: *@This(), name: [:0]const u8, attr: Attributes) Error!void {
                    return s.typed.init(name, blocks, &s.buffer, attr);
                }
            };
        }
    };
}
