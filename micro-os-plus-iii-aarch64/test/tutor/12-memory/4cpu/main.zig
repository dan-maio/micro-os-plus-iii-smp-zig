//! tutor-12-memory-4cpu -- lesson 12, four CPUs (see ../README.md).
//!
//! Part A, samples from a pool instead of `new`: four workers, 20 rounds
//! each; every round takes 4 samples from a memory pool of 13 blocks (a yield
//! after each, so the workers interleave and the pool runs dry), fills,
//! checks and frees them. 13 = 4 x (4 - 1) + 1, the least that cannot
//! deadlock while each worker holds its blocks and waits for the next. A
//! worker that finds the pool empty blocks in alloc() until another frees a
//! block. The pool must never overflow, every block must lie in the pool,
//! and it must end with nothing in use.
//!
//! Part B, memory resources and their statistics, each over a static arena:
//! first_fit_top (a hole after freeing the middle block, coalesced back into
//! one chunk at the end), lifo (freeing in reverse order never fragments),
//! block_pool (the 9th of 8 blocks is refused), an out-of-memory handler
//! that frees a reserve so the allocation succeeds, and an empty memory
//! pool's try_alloc and timed_alloc. Every resource back to zero.
//!
//! With four CPUs the four workers run on cores 0, 1, 2 and 3: the pool is
//! shared by four cores, its alloc() and free() racing in parallel.
//!
//! The Zig version of the C++ lesson (golden workspace,
//! test/rpi4b/tutor/12-memory/4cpu/main.cpp), with the same checks.

const std = @import("std");
const uos = @import("uos");
const board = @import("board");
const tutor = @import("tutor");

const rtos = uos.rtos;
const mempool = rtos.mempool;
const FirstFitTop = uos.memory.FirstFitTop;
const BlockPool = uos.memory.BlockPool;
const Sample = tutor.Sample;
const sysclock = rtos.sysclock;
const prio = rtos.priority;

pub const uos_options = board.options(4);

const four = true;
const seed: u32 = 2026;

fn spawn(gpa: std.mem.Allocator, name: [:0]const u8, f: *const fn (?*anyopaque) ?*anyopaque, arg: usize, p: rtos.Priority, core: ?u32) *rtos.Thread {
    var attr: rtos.Thread.Attributes = .{ .priority = p, .stack_size_bytes = 8 * 1024 };
    if (core) |c| attr.cpu_affinity = @as(u32, 1) << @intCast(c);
    return rtos.Thread.create(gpa, name, f, @ptrFromInt(arg), attr) catch {
        _ = tutor.check(false, "cannot create {s}", .{name});
        tutor.finish("");
    };
}

// ---- Part A: four workers share one pool of samples ------------------------

const n_workers = 4;
const n_rounds = 20;
const per_round = 4;
// Each worker keeps the blocks it has while it waits for the next one (hold
// and wait). With fewer than workers x (per_round - 1) + 1 blocks, all four
// could hold 3 and wait for ever: a deadlock. 13 is the least that is safe,
// and still less than the 16 asked for at once, so the pool runs dry.
const pool_blocks = n_workers * (per_round - 1) + 1;

var g_pool: rtos.MemoryPool = .{};
var g_pool_buf: [mempool.storageSize(pool_blocks, @sizeOf(Sample))]u8 align(@alignOf(usize)) = undefined;

var g_in_use: u32 = 0; // blocks allocated now
var g_in_use_max: u32 = 0; // the most at once
var g_waits = std.atomic.Value(u32).init(0); // allocations that found the pool empty
var g_outside = std.atomic.Value(u32).init(0); // blocks not inside the pool
var g_bad_rounds = std.atomic.Value(u32).init(0); // rounds whose samples did not check
var g_allocs = std.atomic.Value(u32).init(0);
var g_core_of: [n_workers]u32 = @splat(99);
var g_count_mx: rtos.Mutex = .initWith("count", .{});

fn inPool(p: *const anyopaque) bool {
    const lo = @intFromPtr(&g_pool_buf);
    const a = @intFromPtr(p);
    return a >= lo and a < lo + g_pool_buf.len;
}

fn count(delta: i32) void {
    g_count_mx.lock() catch {};
    g_in_use = @intCast(@as(i32, @intCast(g_in_use)) + delta);
    g_in_use_max = @max(g_in_use_max, g_in_use);
    g_count_mx.unlock() catch {};
}

fn worker(arg: ?*anyopaque) ?*anyopaque {
    const w: u32 = @intCast(@intFromPtr(arg));
    g_core_of[w] = board.cpuSlot();
    for (0..n_rounds) |r| {
        var got: [per_round]*Sample = undefined;
        for (&got, 0..) |*slot, i| {
            const block = g_pool.tryAlloc() catch blk: {
                _ = g_waits.fetchAdd(1, .monotonic);
                break :blk g_pool.alloc() catch unreachable; // blocks until a block is freed
            };
            _ = g_allocs.fetchAdd(1, .monotonic);
            if (!inPool(block)) _ = g_outside.fetchAdd(1, .monotonic);
            count(1);
            const s: *Sample = @ptrCast(@alignCast(block));
            const id: u32 = @intCast((w * n_rounds + r) * per_round + i);
            s.init(id, tutor.generate(seed, id), .data);
            slot.* = s;
            rtos.this_thread.yield(); // let the others take blocks too
        }
        var ok = true;
        for (got, 0..) |s, i| {
            const id: u32 = @intCast((w * n_rounds + r) * per_round + i);
            if (!s.valid() or s.id != id or s.value != tutor.generate(seed, id)) ok = false;
        }
        if (!ok) _ = g_bad_rounds.fetchAdd(1, .monotonic);
        rtos.this_thread.yield(); // hold all of them a moment: the next worker finds the pool dry
        for (got) |s| {
            count(-1);
            g_pool.free(s) catch {};
        }
    }
    return null;
}

// ---- Part B: the out-of-memory handler ---------------------------------------

var g_oom_arena: [1024]u8 align(16) = undefined;
var g_oom: FirstFitTop = undefined;
var g_reserve: ?[*]u8 = null;
var g_oom_calls: u32 = 0;

fn onOutOfMemory() bool {
    g_oom_calls += 1;
    if (g_reserve) |r| {
        g_oom.deallocate(r, 600); // give the reserve back; the allocation is retried
        g_reserve = null;
        return true;
    }
    return false; // nothing left to give: let it fail
}

fn stats(what: []const u8, s: FirstFitTop.Statistics) void {
    board.console("  {s: <28} allocated {d: >4} B in {d} chunks, free {d: >4} B in {d} chunks, max {d: >4} B\n", .{ what, s.allocated_bytes, s.allocated_chunks, s.free_bytes, s.free_chunks, s.max_allocated_bytes });
}

pub fn main() void {
    board.uart.init();
    rtos.run(osMain);
}

fn osMain() void {
    const gpa = uos.memory.allocator();
    const self = rtos.this_thread.thread();

    if (four) self.setCpuAffinity(1 << 0);
    tutor.printBanner("12 memory");
    board.console(if (four) "Lesson 12, four CPUs: memory pools and memory resources, their statistics.\n" else "Lesson 12, one CPU: memory pools and memory resources, their statistics.\n", .{});
    tutor.printRegions();
    if (four) {
        // ---- Release cores 1-3 (as in lesson 01).
        board.smp.startSecondaryCores();
        const waited = board.smp.waitSecondaries(3000);
        board.console("  cores joined after {d} ms: {s}\n", .{ waited, board.smp.joinSummary() });
        _ = tutor.check(board.smp.secondariesJoined(), "cores 1-{d} joined the scheduler", .{uos.config.ncpu - 1});
    }
    const heap0 = tutor.heapBytes();

    g_pool.init("samples", pool_blocks, @sizeOf(Sample), &g_pool_buf, .{}) catch {};

    // ---- Part A.
    if (four) {
        board.console("\n-- part A: {d} workers (cores 0-3) x {d} rounds x {d} samples from a pool of {d} blocks ({d} B each)\n", .{ n_workers, n_rounds, per_round, pool_blocks, mempool.blockSize(@sizeOf(Sample)) });
    } else {
        board.console("\n-- part A: {d} workers x {d} rounds x {d} samples from a pool of {d} blocks ({d} B each)\n", .{ n_workers, n_rounds, per_round, pool_blocks, mempool.blockSize(@sizeOf(Sample)) });
    }
    {
        var tw: [n_workers]*rtos.Thread = undefined;
        for (&tw, 0..) |*t, w| t.* = spawn(gpa, "worker", worker, w, prio.normal, if (four) @as(u32, @intCast(w)) else null);
        for (tw) |t| {
            _ = t.join() catch null;
            t.destroy();
        }
    }
    board.console("  {d} allocations, {d} found the pool empty and waited; at most {d} of {d} in use; {d} outside the pool, {d} bad rounds; now {d} in use (pool count {d})\n", .{ g_allocs.load(.monotonic), g_waits.load(.monotonic), g_in_use_max, pool_blocks, g_outside.load(.monotonic), g_bad_rounds.load(.monotonic), g_in_use, g_pool.countUsed() });
    _ = tutor.check(g_allocs.load(.monotonic) == n_workers * n_rounds * per_round and g_bad_rounds.load(.monotonic) == 0, "{d} samples allocated, filled and checked", .{n_workers * n_rounds * per_round});
    _ = tutor.check(g_in_use_max <= pool_blocks and g_outside.load(.monotonic) == 0, "never more than {d} blocks, all inside the pool", .{pool_blocks});
    _ = tutor.check(g_waits.load(.monotonic) > 0, "the pool ran dry and allocations waited for a free block", .{});
    _ = tutor.check(g_in_use == 0 and g_pool.countUsed() == 0 and g_pool.isEmpty(), "the pool ends with nothing in use", .{});
    if (four) {
        _ = tutor.check(g_core_of[0] == 0 and g_core_of[1] == 1 and g_core_of[2] == 2 and g_core_of[3] == 3, "the pool shared by four cores (workers on cores 0, 1, 2, 3)", .{});
    }

    // ---- Part B.
    board.console("\n-- part B: memory resources over static arenas, and their statistics\n", .{});
    {
        var fft_arena: [2048]u8 align(16) = undefined;
        var fft = FirstFitTop.init("fft", &fft_arena, .first_fit_top);
        const a = fft.allocate(100, 8).?;
        const b = fft.allocate(200, 8).?;
        const c = fft.allocate(300, 8).?;
        stats("first_fit_top, 3 blocks:", fft.stats);
        const free_chunks_3 = fft.stats.free_chunks;
        fft.deallocate(b, 200);
        stats("first_fit_top, middle freed:", fft.stats);
        const free_chunks_hole = fft.stats.free_chunks;
        fft.deallocate(a, 100);
        fft.deallocate(c, 300);
        stats("first_fit_top, all freed:", fft.stats);
        _ = tutor.check(free_chunks_hole == free_chunks_3 + 1, "first_fit_top: freeing the middle block leaves a hole (one more free chunk)", .{});
        _ = tutor.check(fft.stats.allocated_bytes == 0 and fft.stats.allocated_chunks == 0 and fft.stats.free_chunks == 1, "first_fit_top: all freed, the arena is one free chunk again", .{});

        var lf_arena: [2048]u8 align(16) = undefined;
        var lf = FirstFitTop.init("lifo", &lf_arena, .lifo);
        var p: [4][*]u8 = undefined;
        for (&p, 0..) |*x, i| x.* = lf.allocate(64 * (i + 1), 8).?;
        stats("lifo, 4 blocks:", lf.stats);
        var max_free_chunks: usize = 0;
        var i: usize = 4;
        while (i > 0) {
            i -= 1;
            lf.deallocate(p[i], 64 * (i + 1));
            max_free_chunks = @max(max_free_chunks, lf.stats.free_chunks);
        }
        stats("lifo, freed in reverse:", lf.stats);
        _ = tutor.check(max_free_chunks == 1 and lf.stats.allocated_bytes == 0, "lifo: freed in reverse order the arena never fragments (one free chunk throughout)", .{});

        var bp_buf: [8 * BlockPool.blockSize(@sizeOf(Sample))]u8 align(@alignOf(usize)) = undefined;
        var bp = BlockPool.init("bp", @sizeOf(Sample), &bp_buf);
        const bpa = bp.allocator();
        var blk: [9]?*Sample = @splat(null);
        var taken: u32 = 0;
        for (&blk) |*x| {
            x.* = bpa.create(Sample) catch null;
            if (x.* != null) taken += 1;
        }
        const bp_count = bp.count;
        board.console("  block_pool, 9 asked of 8:    {d} given, the 9th {s}; {d} in use\n", .{ taken, if (blk[8] == null) "refused" else "given", bp_count });
        for (blk) |x| if (x) |s| bpa.destroy(s);
        board.console("  block_pool, all freed:       {d} in use (most at once {d})\n", .{ bp.count, bp.max_count });
        _ = tutor.check(taken == 8 and blk[8] == null and bp_count == 8, "block_pool: 8 blocks given, the 9th refused (nullptr)", .{});
        _ = tutor.check(bp.count == 0, "block_pool: all back", .{});

        g_oom = FirstFitTop.init("oom", &g_oom_arena, .first_fit_top);
        g_reserve = g_oom.allocate(600, 8);
        g_oom.out_of_memory_handler = onOutOfMemory;
        const big = g_oom.allocate(500, 8); // does not fit while the reserve is held
        const calls_ok = g_oom_calls;
        const huge = g_oom.allocate(4096, 8); // never fits
        board.console("  out of memory: 500 B with a 600 B reserve held -> {s} after {d} handler call; 4096 B -> {s} after {d} calls\n", .{ if (big != null) "ok" else "nullptr", calls_ok, if (huge != null) "ok" else "nullptr", g_oom_calls });
        _ = tutor.check(big != null and calls_ok == 1, "the handler freed the reserve and the allocation succeeded", .{});
        _ = tutor.check(huge == null, "an allocation larger than the arena fails (nullptr)", .{});
        if (big) |x| g_oom.deallocate(x, 500);
        _ = tutor.check(g_oom.stats.allocated_bytes == 0, "the handler's arena back to zero", .{});

        var mp: rtos.MemoryPool = .{};
        var mp_buf: [mempool.storageSize(2, @sizeOf(Sample))]u8 align(@alignOf(usize)) = undefined;
        mp.init("two", 2, @sizeOf(Sample), &mp_buf, .{}) catch {};
        const m1 = mp.alloc() catch unreachable;
        const m2 = mp.alloc() catch unreachable;
        const m3 = mp.tryAlloc() catch null;
        const t0 = sysclock.now();
        const m4 = mp.timedAlloc(10) catch null;
        const waited = sysclock.now() - t0;
        board.console("  memory_pool of 2: two taken, try_alloc {s}, timed_alloc(10) {s} after {d} ticks\n", .{ if (m3 != null) "a block" else "nullptr", if (m4 != null) "a block" else "nullptr", waited });
        _ = tutor.check(m3 == null and m4 == null and waited >= 10 and waited <= 11, "an empty pool: try_alloc nullptr, timed_alloc nullptr after 10 ticks", .{});
        mp.free(m1) catch {};
        mp.free(m2) catch {};
        _ = tutor.check(mp.countUsed() == 0, "the small pool back to zero", .{});
    }

    _ = tutor.check(tutor.heapBytes() == heap0, "heap back to {d} B (no `new` behind the pools)", .{heap0});
    tutor.finish(if (four) "samples from a pool shared by four cores, never over capacity, all freed; first_fit_top, lifo, block_pool, out-of-memory handler; every resource back to zero; four CPUs" else "samples from a shared pool, never over capacity, all freed; first_fit_top, lifo, block_pool, out-of-memory handler; every resource back to zero; one CPU");
}
