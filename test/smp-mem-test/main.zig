//! smp-mem-test -- 20 threads x 5 large alloc/write/read/free operations across 4 cores
//! (the C++ test/rpi4b/smp_mem_test).
//!
//! A pool of 20 threads, 5 pinned on each core, each running operations:
//! allocate a random block of 1 .. 512 MB, write a 64-bit pattern, read it back
//! (+256 random re-reads), check protection with AT S1E1R (mmu_hi_probe), check
//! canaries, unmap pages, and free the block.
//!
//! The blocks come from the RAM above the first GB (0x40000000 .. 0xFC000000, 3008 MB).
//! Page tables are managed dynamically via board.mmu.hiMap / board.mmu.hiProbe.

const std = @import("std");
const uos = @import("uos");
const board = @import("board");
const rtos = uos.rtos;
const sysclock = rtos.sysclock;
const ncpu = uos.config.ncpu;
const console = board.console;

pub const uos_options = board.options(4);

const kWorkers: usize = 20;
const kOps: usize = 10;
const kMB: u64 = 1024 * 1024;
const kMinBytes: u64 = 1 * kMB;
const kMaxBytes: u64 = 512 * kMB;
const kPage: usize = 4096;
const kHeadCanary: usize = 64;
const kCanary: u8 = 0xC5;
const kRandomReads: usize = 256;
const kStride: usize = 8; // On hardware: check every 64-bit word

const Extent = struct {
    start: usize,
    end: usize, // guard page included
};

var g_heap_mtx: rtos.Mutex = .{ .name = "heap" };
var g_live: [kWorkers]Extent = undefined;
var g_nlive: usize = 0;
var g_lo: usize = 0;
var g_hi: usize = 0;
var g_in_use: u64 = 0;
var g_peak: u64 = 0;

fn reserve(need: usize, size: u64, largest: *usize) usize {
    g_heap_mtx.lock() catch return 0;
    defer g_heap_mtx.unlock() catch {};

    var cursor = g_lo;
    var at: usize = 0;
    var big: usize = 0;
    var pos: usize = 0;

    var i: usize = 0;
    while (i <= g_nlive) : (i += 1) {
        const gap_end = if (i < g_nlive) g_live[i].start else g_hi;
        const gap = gap_end - cursor;
        if (gap > big) big = gap;
        if (gap >= need) {
            at = cursor;
            pos = i;
            break;
        }
        if (i < g_nlive) cursor = g_live[i].end;
    }

    if (at != 0) {
        var j = g_nlive;
        while (j > pos) : (j -= 1) {
            g_live[j] = g_live[j - 1];
        }
        g_live[pos] = .{ .start = at, .end = at + need };
        g_nlive += 1;
        g_in_use += size;
        if (g_in_use > g_peak) g_peak = g_in_use;
    }

    largest.* = big;
    return at;
}

fn release(start: usize, size: u64) void {
    g_heap_mtx.lock() catch return;
    defer g_heap_mtx.unlock() catch {};

    for (0..g_nlive) |i| {
        if (g_live[i].start == start) {
            var j = i;
            while (j + 1 < g_nlive) : (j += 1) {
                g_live[j] = g_live[j + 1];
            }
            g_nlive -= 1;
            g_in_use -= size;
            break;
        }
    }
}

fn inUse() u64 {
    g_heap_mtx.lock() catch return 0;
    defer g_heap_mtx.unlock() catch {};
    return g_in_use;
}

var g_ops_done = std.atomic.Value(u32).init(0);
var g_workers_done = std.atomic.Value(u32).init(0);
var g_oom = std.atomic.Value(u32).init(0);
var g_data_err = std.atomic.Value(u32).init(0);
var g_canary_err = std.atomic.Value(u32).init(0);
var g_probe_err = std.atomic.Value(u32).init(0);
var g_bytes_alloc = std.atomic.Value(u64).init(0);
var g_bytes_checked = std.atomic.Value(u64).init(0);
var g_core_ops: [4]u32 = @splat(0);

fn mb(buf: []u8, bytes: u64) []const u8 {
    const whole = bytes / kMB;
    const frac = (bytes % kMB) * 100 / kMB;
    return std.fmt.bufPrint(buf, "{d}.{d:0>2}", .{ whole, frac }) catch "?";
}

inline fn pattern(a: usize, seed: u64) u64 {
    return (@as(u64, a) *% 0x9E3779B97F4A7C15) ^ seed;
}

inline fn nextRand(s: *u64) u64 {
    s.* ^= s.* >> 12;
    s.* ^= s.* << 25;
    s.* ^= s.* >> 27;
    return s.* *% 0x2545F4914F6CDD1D;
}

fn expectProbe(id: usize, op: usize, what: []const u8, a: usize, want: bool) void {
    if (board.mmu.hiProbe(a) != want) {
        _ = g_probe_err.fetchAdd(1, .monotonic);
        console("[w{d:0>2} c{d}] op {d} MMU ERROR: {s} 0x{x:0>8} is {s}\n", .{
            id, board.cpuSlot(), op, what, a, if (want) "unmapped" else "mapped",
        });
    }
}

fn dataError(id: usize, op: usize, a: usize, got: u64, want: u64, op_errors: *usize) void {
    op_errors.* += 1;
    if (g_data_err.fetchAdd(1, .monotonic) < 20) {
        console("[w{d:0>2} c{d}] op {d} DATA ERROR at 0x{x:0>8}: 0x{x:0>16}, want 0x{x:0>16}\n", .{
            id, board.cpuSlot(), op, a, got, want,
        });
    }
}

fn workerThread(arg: ?*anyopaque) ?*anyopaque {
    const id: usize = @intCast(@intFromPtr(arg));
    var rnd: u64 = (0x9E3779B97F4A7C15 *% @as(u64, @intCast(id + 1))) ^ @as(u64, @truncate(sysclock.now()));

    var b1: [32]u8 = undefined;
    var b2: [32]u8 = undefined;
    var b3: [32]u8 = undefined;

    var op: usize = 1;
    while (op <= kOps) : (op += 1) {
        var size: u64 = kMinBytes + nextRand(&rnd) % (kMaxBytes - kMinBytes + 1);
        var start: usize = 0;
        var pages: usize = 0;

        // Over memory: halve request until it fits, then wait for frees.
        while (true) {
            pages = (size + kHeadCanary + kPage - 1) / kPage;
            var largest: usize = 0;
            start = reserve((pages + 1) * kPage, size, &largest);
            if (start != 0) break;

            _ = g_oom.fetchAdd(1, .monotonic);
            const smaller = if (size / 2 > kMinBytes) size / 2 else kMinBytes;
            if (smaller != size) {
                console("[w{d:0>2} c{d}] op {d:>2}/{d} OOM: {s} MB does not fit (in use {s} MB, largest free {s} MB) -> retry {d} MB\n", .{
                    id, board.cpuSlot(), op, kOps, mb(&b1, size), mb(&b2, inUse()), mb(&b3, largest), smaller / kMB,
                });
                size = smaller;
            }
            sysclock.sleepFor(if (size == kMinBytes) 10 else 1) catch {};
        }

        const map_end = start + pages * kPage;
        const len16 = (size + 15) & ~@as(u64, 15);
        const user: usize = map_end - @as(usize, @intCast(len16));
        board.mmu.hiMap(start, pages * kPage, true);
        _ = g_bytes_alloc.fetchAdd(size, .monotonic);

        console("[w{d:0>2} c{d}] op {d:>2}/{d} alloc {s} MB @ 0x{x:0>8} | in use {s} / {s} MB\n", .{
            id, board.cpuSlot(), op, kOps, mb(&b1, size), user, mb(&b2, inUse()), mb(&b3, g_hi - g_lo),
        });

        expectProbe(id, op, "first byte", user, true);
        expectProbe(id, op, "last byte", user + @as(usize, @intCast(size)) - 1, true);
        expectProbe(id, op, "guard page after", map_end, false);
        expectProbe(id, op, "page before", start - kPage, false);

        // Canaries around the data
        const p8: [*]volatile u8 = @ptrFromInt(start);
        var ca: usize = start;
        while (ca < user) : (ca += 1) p8[ca - start] = kCanary;
        ca = user + @as(usize, @intCast(size));
        while (ca < map_end) : (ca += 1) p8[ca - start] = kCanary;

        // Write, then read back
        const seed = nextRand(&rnd);
        const words_end = user + @as(usize, @intCast(size & ~@as(u64, 7)));
        var checked: u64 = 0;
        var op_errors: usize = 0;

        var wa = user;
        while (wa + 8 <= words_end) : (wa += kStride) {
            const ptr: *volatile u64 = @ptrFromInt(wa);
            ptr.* = pattern(wa, seed);
        }
        if (words_end - user >= 8) {
            const last = words_end - 8;
            const ptr: *volatile u64 = @ptrFromInt(last);
            ptr.* = pattern(last, seed);
        }
        var ba = words_end;
        while (ba < user + size) : (ba += 1) {
            const ptr: *volatile u8 = @ptrFromInt(ba);
            ptr.* = @truncate(seed ^ ba);
        }

        wa = user;
        while (wa + 8 <= words_end) : (wa += kStride) {
            const ptr: *volatile u64 = @ptrFromInt(wa);
            const v = ptr.*;
            const want = pattern(wa, seed);
            if (v != want) dataError(id, op, wa, v, want, &op_errors);
            checked += 8;
        }
        if (words_end - user >= 8) {
            const last = words_end - 8;
            const ptr: *volatile u64 = @ptrFromInt(last);
            const v = ptr.*;
            const want = pattern(last, seed);
            if (v != want) dataError(id, op, last, v, want, &op_errors);
        }
        ba = words_end;
        while (ba < user + size) : (ba += 1) {
            const ptr: *volatile u8 = @ptrFromInt(ba);
            const v = ptr.*;
            const want: u8 = @truncate(seed ^ ba);
            if (v != want) dataError(id, op, ba, v, want, &op_errors);
        }

        const slots = (words_end - user) / kStride;
        if (slots > 0) {
            for (0..kRandomReads) |_| {
                const ra = user + @as(usize, @intCast(nextRand(&rnd) % slots)) * kStride;
                const ptr: *volatile u64 = @ptrFromInt(ra);
                const v = ptr.*;
                const want = pattern(ra, seed);
                if (v != want) dataError(id, op, ra, v, want, &op_errors);
            }
        }
        _ = g_bytes_checked.fetchAdd(checked, .monotonic);

        // Canaries intact?
        var bad: u32 = 0;
        ca = start;
        while (ca < user) : (ca += 1) {
            if (p8[ca - start] != kCanary) bad += 1;
        }
        ca = user + @as(usize, @intCast(size));
        while (ca < map_end) : (ca += 1) {
            if (p8[ca - start] != kCanary) bad += 1;
        }
        if (bad != 0) {
            _ = g_canary_err.fetchAdd(1, .monotonic);
            console("[w{d:0>2} c{d}] op {d} CANARY ERROR: {d} bytes changed\n", .{
                id, board.cpuSlot(), op, bad,
            });
        }

        // Free: unmap, check block is gone, release
        board.mmu.hiMap(start, pages * kPage, false);
        expectProbe(id, op, "freed first byte", user, false);
        expectProbe(id, op, "freed last byte", user + @as(usize, @intCast(size)) - 1, false);
        release(start, size);

        console("[w{d:0>2} c{d}] op {d:>2}/{d} free  {s} MB, data {s}, canaries {s} | in use {s} MB\n", .{
            id, board.cpuSlot(), op, kOps, mb(&b1, size),
            if (op_errors != 0) "ERR" else "ok",
            if (bad != 0) "ERR" else "ok",
            mb(&b2, inUse()),
        });

        const slot = board.cpuSlot();
        if (slot < 4) g_core_ops[slot] += 1;
        _ = g_ops_done.fetchAdd(1, .monotonic);
    }

    _ = g_workers_done.fetchAdd(1, .monotonic);
    return null;
}

const worker_stack_size = 16384;
const Stack = [worker_stack_size / @sizeOf(uos.port.StackElement)]uos.port.StackElement;
var s_stacks: [kWorkers]Stack = undefined;
var s_names: [kWorkers][8:0]u8 = undefined;
var s_threads: [kWorkers]*rtos.Thread = undefined;

pub fn main() void {
    board.uart.init();
    board.led.init();
    rtos.run(osMain);
}

fn osMain() void {
    const gpa = uos.memory.allocator();

    console("\n+=============================================================+\n", .{});
    console("|  " ++ board.banner_short ++ " µOS++ SMP MEMORY TEST : smp-mem-test     |\n", .{});
    console("+=============================================================+\n\n", .{});

    _ = rtos.interrupts.UncriticalSection.enter();
    board.smp.startSecondaryCores();
    const waited = board.smp.waitSecondaries(3000);
    console("Secondary cores joined: {s} ({d} ms)\n", .{ board.smp.joinSummary(), waited });

    var base: usize = 0;
    var end: usize = 0;
    board.mmu.hiRegion(&base, &end);
    g_lo = base + kPage; // first page stays unmapped guard
    g_hi = end;
    console("Region 0x{x:0>8} .. 0x{x:0>8}: {d} MB, all pages unmapped\n", .{
        base, end, (end - base) / kMB,
    });
    console("{d} threads x {d} operations, blocks of 1 .. {d} MB, every word checked\n\n", .{
        kWorkers, kOps, kMaxBytes / kMB,
    });

    for (0..kWorkers) |i| {
        s_names[i] = "mw00\x00\x00\x00\x00".*;
        s_names[i][2] = '0' + @as(u8, @intCast(i / 10));
        s_names[i][3] = '0' + @as(u8, @intCast(i % 10));
        s_threads[i] = rtos.Thread.create(gpa, &s_names[i], workerThread, @ptrFromInt(i), .{
            .stack = &s_stacks[i],
            .priority = rtos.priority.normal,
            .cpu_affinity = @as(u32, 1) << @intCast(i % ncpu),
        }) catch unreachable;
    }

    var b1: [32]u8 = undefined;
    var b2: [32]u8 = undefined;
    var seconds: u32 = 0;
    while (g_workers_done.load(.monotonic) < kWorkers) {
        sysclock.sleepFor(1000) catch {};
        seconds += 1;
        if (seconds % 5 == 0) {
            console("[t={d:>4}s] ops {d}/{d}, in use {s} MB, peak {s} MB, OOM retries {d}\n", .{
                seconds, g_ops_done.load(.monotonic), kWorkers * kOps,
                mb(&b1, inUse()), mb(&b2, g_peak), g_oom.load(.monotonic),
            });
        }
    }

    // Probe check whole region to verify everything was unmapped
    var still_mapped: u32 = 0;
    var a = base;
    while (a < end) : (a += 2 * kMB) {
        if (board.mmu.hiProbe(a)) still_mapped += 1;
    }
    if (board.mmu.hiProbe(end - kPage)) still_mapped += 1;

    var all_cores = true;
    for (0..ncpu) |c| {
        if (g_core_ops[c] == 0) all_cores = false;
    }

    console("\n==== smp_mem_test summary ({d} s) ====\n", .{seconds});
    board.reportPerCore("operations per core", &g_core_ops);
    console("  operations      : {d} / {d}\n", .{ g_ops_done.load(.monotonic), kWorkers * kOps });
    console("  allocated total : {s} MB\n", .{mb(&b1, g_bytes_alloc.load(.monotonic))});
    console("  written+checked : {s} MB\n", .{mb(&b1, g_bytes_checked.load(.monotonic))});
    console("  peak in use     : {s} MB of {s} MB\n", .{ mb(&b1, g_peak), mb(&b2, g_hi - g_lo) });
    console("  OOM retries     : {d}\n", .{g_oom.load(.monotonic)});
    console("  data errors     : {d}\n", .{g_data_err.load(.monotonic)});
    console("  canary errors   : {d}\n", .{g_canary_err.load(.monotonic)});
    console("  MMU probe errors: {d}\n", .{g_probe_err.load(.monotonic)});
    console("  in use at end   : {s} MB, pages still mapped: {d}\n", .{ mb(&b1, inUse()), still_mapped });

    const ok = board.smp.secondariesJoined() and all_cores and
        g_ops_done.load(.monotonic) == kWorkers * kOps and
        g_data_err.load(.monotonic) == 0 and
        g_canary_err.load(.monotonic) == 0 and
        g_probe_err.load(.monotonic) == 0 and
        inUse() == 0 and
        still_mapped == 0;

    console("\nRESULT: {s}\n", .{if (ok) "PASS" else "FAIL"});
    if (ok) board.hw_result.ok();
    board.hw_result.fail();
}
