//! Memory management (`os::memory`, `os::rtos::memory`).
//!
//! The C++ `memory_resource` classes become `std.mem.Allocator`
//! implementations, so every Zig container and `std` API can use them:
//!
//! - `FirstFitTop` (`.first_fit_top` / `.lifo` policies)
//! - `BlockPool`
//! - `std.mem.Allocator.failing` is the C++ `null` resource.
//!
//! None of them locks; `Locked` wraps any allocator in a scheduler critical
//! section, which makes it safe for threads (not for interrupt handlers).
//!
//! `allocator()` is the RTOS system heap (`get_default_resource()`): a
//! locked `FirstFitTop` over the RAM the port leaves free, or over a static
//! buffer of `uos_options.dynamic_memory_size_bytes`.

const std = @import("std");
const builtin = @import("builtin");

pub const FirstFitTop = @import("memory/FirstFitTop.zig");
pub const BlockPool = @import("memory/BlockPool.zig");

/// Thread safe wrapper: every call runs with the scheduler locked.
pub const Locked = struct {
    child: std.mem.Allocator,

    pub fn init(child: std.mem.Allocator) Locked {
        return .{ .child = child };
    }

    pub fn allocator(self: *Locked) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: std.mem.Allocator.VTable = .{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };

    const scheduler = @import("rtos/scheduler.zig");

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *Locked = @ptrCast(@alignCast(ctx));
        const scs = scheduler.KernelCriticalSection.enter();
        defer scs.exit();
        return self.child.vtable.alloc(self.child.ptr, len, alignment, ret_addr);
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *Locked = @ptrCast(@alignCast(ctx));
        const scs = scheduler.KernelCriticalSection.enter();
        defer scs.exit();
        return self.child.vtable.resize(self.child.ptr, memory, alignment, new_len, ret_addr);
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *Locked = @ptrCast(@alignCast(ctx));
        const scs = scheduler.KernelCriticalSection.enter();
        defer scs.exit();
        return self.child.vtable.remap(self.child.ptr, memory, alignment, new_len, ret_addr);
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *Locked = @ptrCast(@alignCast(ctx));
        const scs = scheduler.KernelCriticalSection.enter();
        defer scs.exit();
        self.child.vtable.free(self.child.ptr, memory, alignment, ret_addr);
    }
};

// ----------------------------------------------------------------------------
// The RTOS system heap.

const system = struct {
    var heap: FirstFitTop = undefined;
    var locked: Locked = undefined;
    var initialised = false;
    var static_buffer: [heapStaticSize()]u8 align(16) = undefined;

    fn heapStaticSize() usize {
        const config = @import("config.zig");
        const port = @import("uos_port");
        if (config.options.exclude_dynamic_memory_allocations) return 0;
        // A port that hands over its free RAM needs no static buffer.
        if (config.options.dynamic_memory_size_bytes == 0 and @hasDecl(port, "freeRam")) return 0;
        return @max(config.options.dynamic_memory_size_bytes, 64);
    }

    fn get() std.mem.Allocator {
        const config = @import("config.zig");
        if (config.options.exclude_dynamic_memory_allocations) return std.mem.Allocator.failing;
        if (!@atomicLoad(bool, &initialised, .acquire)) {
            const interrupts = @import("rtos/interrupts.zig");
            const cs = interrupts.CriticalSection.enter();
            defer cs.exit();
            if (!initialised) {
                const arena: []u8 = if (static_buffer.len > 0) &static_buffer else @import("uos_port").freeRam();
                heap = .init("sys-heap", arena, .first_fit_top);
                locked = .init(heap.allocator());
                @atomicStore(bool, &initialised, true, .release);
            }
        }
        return locked.allocator();
    }
};

/// The RTOS system heap, thread safe.
pub fn allocator() std.mem.Allocator {
    return system.get();
}

/// The system heap itself (the C API `os_memory_get_default()`); not thread
/// safe, lock the scheduler around its use.
pub fn systemHeap() *FirstFitTop {
    _ = system.get();
    return &system.heap;
}

/// Statistics of the system heap.
pub fn statistics() FirstFitTop.Statistics {
    _ = system.get();
    return system.heap.stats;
}

/// Print the statistics of the system heap (`trace_print_statistics()`).
pub fn tracePrintStatistics() void {
    const trace = @import("trace.zig");
    const s = statistics();
    trace.print("Memory sys-heap: {d}/{d} bytes allocated ({d} max), {d} chunks, {d} free chunks\n", .{
        s.allocated_bytes, s.total_bytes, s.max_allocated_bytes, s.allocated_chunks, s.free_chunks,
    });
}
