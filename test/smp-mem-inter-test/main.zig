//! smp-mem-inter-test -- smp-mem-test plus inter-thread communication:
//! each block is filled by its owner, modified by another thread, and checked by its owner.
//! (the C++ test/rpi4b/smp_mem_inter_test).
//!
//! 20 threads, 5 pinned on each of the 4 cores, 5 operations each. Thread i
//! works with thread (i + 1) % 20, in a ring. One operation of thread i:
//!   1. allocate a block of 1 .. 512 MB (RAM above the first GB, mapped dynamically),
//!      write a pattern into it and compute CRC32 (crc1) using Cortex-A72 CRC32 instruction;
//!   2. send the block (pointer, size, random 64-bit mask) to thread i + 1's message queue;
//!   3. thread i + 1 XORs every word with the mask and sends done back;
//!   4. thread i XORs with the mask again, computes CRC32 (crc2), checks crc1 == crc2,
//!      checks canaries, unmaps pages, and frees the block.

const std = @import("std");
const uos = @import("uos");
const board = @import("board");
const rtos = uos.rtos;
const sysclock = rtos.sysclock;
const ncpu = uos.config.ncpu;
const console = board.console;

pub const uos_options = board.options(4);

const kWorkers: usize = 20;
const kOps: usize = 5;
const kMB: u64 = 1024 * 1024;
const kMinBytes: u64 = 1 * kMB;
const kMaxBytes: u64 = 512 * kMB;
const kPage: usize = 4096;
const kHeadCanary: usize = 64;
const kCanary: u8 = 0xC5;
const kStride: usize = 8; // On hardware: check every 64-bit word

const Extent = struct {
    start: usize,
    end: usize,
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

const State = struct {
    pub const owned: u32 = 0;
    pub const lent: u32 = 1;
    pub const modifying: u32 = 2;
    pub const modified: u32 = 3;
};

const Block = struct {
    state: std.atomic.Value(u32) = .init(State.owned),
    user: usize = 0,
    size: u64 = 0,
    helper: usize = 0,
};

const MsgType = enum(u32) {
    modify = 1,
    done = 2,
};

const Msg = extern struct {
    type: u32,
    from: u32,
    op: u32,
    pad: u32 = 0,
    user: usize,
    size: u64,
    mask: u64,
};

var g_block: [kWorkers]Block = @splat(.{});
var g_q: [kWorkers]rtos.MessageQueue = @splat(.{});

var g_ops_done = std.atomic.Value(u32).init(0);
var g_workers_done = std.atomic.Value(u32).init(0);
var g_oom = std.atomic.Value(u32).init(0);
var g_crc_ok = std.atomic.Value(u32).init(0);
var g_crc_bad = std.atomic.Value(u32).init(0);
var g_proto_err = std.atomic.Value(u32).init(0);
var g_canary_err = std.atomic.Value(u32).init(0);
var g_probe_err = std.atomic.Value(u32).init(0);
var g_bytes_alloc = std.atomic.Value(u64).init(0);
var g_core_ops: [4]u32 = @splat(0);
var g_core_mods: [4]u32 = @splat(0);

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

inline fn wordsEnd(user: usize, size: u64) usize {
    return user + @as(usize, @intCast(size & ~@as(u64, 7)));
}

inline fn crc32b(crc: u32, data: u8) u32 {
    return asm ("crc32b %[res:w], %[crc:w], %[data:w]"
        : [res] "=r" (-> u32),
        : [crc] "r" (crc),
          [data] "r" (data),
    );
}

inline fn crc32d(crc: u32, data: u64) u32 {
    return asm ("crc32x %[res:w], %[crc:w], %[data]"
        : [res] "=r" (-> u32),
        : [crc] "r" (crc),
          [data] "r" (data),
    );
}

fn blockCrc(user: usize, size: u64) u32 {
    const we = wordsEnd(user, size);
    var crc: u32 = 0xFFFF_FFFF;
    var a = user;
    while (a + 8 <= we) : (a += kStride) {
        const ptr: *volatile u64 = @ptrFromInt(a);
        crc = crc32d(crc, ptr.*);
    }
    if (we - user >= 8) {
        const ptr: *volatile u64 = @ptrFromInt(we - 8);
        crc = crc32d(crc, ptr.*);
    }
    var b = we;
    while (b < user + size) : (b += 1) {
        const ptr: *volatile u8 = @ptrFromInt(b);
        crc = crc32b(crc, ptr.*);
    }
    return ~crc;
}

fn blockXor(user: usize, size: u64, mask: u64) void {
    const we = wordsEnd(user, size);
    var a = user;
    while (a + 8 <= we) : (a += kStride) {
        const ptr: *volatile u64 = @ptrFromInt(a);
        ptr.* ^= mask;
    }
    if (we - user >= 8 and ((we - 8 - user) % kStride) != 0) {
        const ptr: *volatile u64 = @ptrFromInt(we - 8);
        ptr.* ^= mask;
    }
    var b = we;
    while (b < user + size) : (b += 1) {
        const ptr: *volatile u8 = @ptrFromInt(b);
        ptr.* ^= @truncate(mask);
    }
}

fn protoError(id: usize, what: []const u8, other: usize) void {
    _ = g_proto_err.fetchAdd(1, .monotonic);
    console("[w{d:0>2} c{d}] PROTOCOL ERROR: {s} (w{d:0>2})\n", .{
        id, board.cpuSlot(), what, other,
    });
}

fn expectProbe(id: usize, op: usize, what: []const u8, a: usize, want: bool) void {
    if (board.mmu.hiProbe(a) != want) {
        _ = g_probe_err.fetchAdd(1, .monotonic);
        console("[w{d:0>2} c{d}] op {d} MMU ERROR: {s} 0x{x:0>8} is {s}\n", .{
            id, board.cpuSlot(), op, what, a, if (want) "unmapped" else "mapped",
        });
    }
}

fn serveModify(id: usize, m: *const Msg) void {
    const owner = m.from;
    if (owner >= kWorkers) {
        protoError(id, "modify request from invalid owner", owner);
        return;
    }
    const blk = &g_block[owner];
    if (blk.helper != id or blk.user != m.user or blk.size != m.size or
        blk.state.cmpxchgStrong(State.lent, State.modifying, .acquire, .monotonic) != null)
    {
        protoError(id, "modify request for a block not lent to me", owner);
        return;
    }
    blockXor(m.user, m.size, m.mask);
    const slot = board.cpuSlot();
    if (slot < 4) g_core_mods[slot] += 1;
    var b1: [32]u8 = undefined;
    console("[w{d:0>2} c{d}]        xor w{d:0>2} op {d:>2}: {s} MB @ 0x{x:0>8} mask 0x{x:0>16} -> done\n", .{
        id, slot, owner, m.op, mb(&b1, m.size), m.user, m.mask,
    });
    blk.state.store(State.modified, .release);
    const d: Msg = .{
        .type = @intFromEnum(MsgType.done),
        .from = @intCast(id),
        .op = m.op,
        .user = m.user,
        .size = m.size,
        .mask = m.mask,
    };
    g_q[owner].send(std.mem.asBytes(&d), 0) catch {};
}

fn serveOnce(id: usize, op: usize, ms: u32) bool {
    var m: Msg = undefined;
    _ = g_q[id].timedReceive(std.mem.asBytes(&m), ms) catch return false;
    if (m.type == @intFromEnum(MsgType.modify)) {
        serveModify(id, &m);
        return false;
    }
    if (m.type == @intFromEnum(MsgType.done) and m.op == op and m.from == g_block[id].helper) {
        return true;
    }
    protoError(id, "unexpected message", m.from);
    return false;
}

fn workerThread(arg: ?*anyopaque) ?*anyopaque {
    const id: usize = @intCast(@intFromPtr(arg));
    const helper = (id + 1) % kWorkers;
    var rnd: u64 = (0x9E3779B97F4A7C15 *% @as(u64, @intCast(id + 1))) ^ @as(u64, @truncate(sysclock.now()));

    var b1: [32]u8 = undefined;
    var b2: [32]u8 = undefined;
    var b3: [32]u8 = undefined;

    g_block[id].helper = helper;

    var op: usize = 1;
    while (op <= kOps) : (op += 1) {
        var size: u64 = kMinBytes + nextRand(&rnd) % (kMaxBytes - kMinBytes + 1);
        var start: usize = 0;
        var pages: usize = 0;

        // Over memory: halve request until it fits, serving queue meanwhile
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
            _ = serveOnce(id, 0, if (size == kMinBytes) 10 else 1);
        }

        const map_end = start + pages * kPage;
        const len16 = (size + 15) & ~@as(u64, 15);
        const user: usize = map_end - @as(usize, @intCast(len16));
        board.mmu.hiMap(start, pages * kPage, true);
        _ = g_bytes_alloc.fetchAdd(size, .monotonic);

        expectProbe(id, op, "first byte", user, true);
        expectProbe(id, op, "last byte", user + @as(usize, @intCast(size)) - 1, true);
        expectProbe(id, op, "guard page after", map_end, false);
        expectProbe(id, op, "page before", start - kPage, false);

        // Canaries around data
        const p8: [*]volatile u8 = @ptrFromInt(start);
        var ca: usize = start;
        while (ca < user) : (ca += 1) p8[ca - start] = kCanary;
        ca = user + @as(usize, @intCast(size));
        while (ca < map_end) : (ca += 1) p8[ca - start] = kCanary;

        // 1. Write pattern, compute crc1
        const seed = nextRand(&rnd);
        const words_end = wordsEnd(user, size);
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

        const crc1 = blockCrc(user, size);
        var mask = nextRand(&rnd);
        if (mask == 0) mask = 0x5A5A5A5A5A5A5A5A;

        // 2. Lend to helper via message queue
        g_block[id].user = user;
        g_block[id].size = size;
        g_block[id].state.store(State.lent, .release);

        console("[w{d:0>2} c{d}] op {d:>2}/{d} alloc {s} MB @ 0x{x:0>8}, crc1 0x{x:0>8} -> w{d:0>2} | in use {s} / {s} MB\n", .{
            id, board.cpuSlot(), op, kOps, mb(&b1, size), user, crc1, helper, mb(&b2, inUse()), mb(&b3, g_hi - g_lo),
        });

        const m: Msg = .{
            .type = @intFromEnum(MsgType.modify),
            .from = @intCast(id),
            .op = @intCast(op),
            .user = user,
            .size = size,
            .mask = mask,
        };
        g_q[helper].send(std.mem.asBytes(&m), 0) catch {};

        // 3. Wait for modify done, serving ring meanwhile
        while (!serveOnce(id, op, 10)) {}

        if (g_block[id].state.cmpxchgStrong(State.modified, State.owned, .acquire, .monotonic) != null) {
            protoError(id, "block came back not modified", helper);
            g_block[id].state.store(State.owned, .release);
        }

        // 4. XOR back, crc2, compare
        blockXor(user, size, mask);
        const crc2 = blockCrc(user, size);
        const match = (crc1 == crc2);
        if (match) {
            _ = g_crc_ok.fetchAdd(1, .monotonic);
        } else {
            _ = g_crc_bad.fetchAdd(1, .monotonic);
        }

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

        board.mmu.hiMap(start, pages * kPage, false);
        expectProbe(id, op, "freed first byte", user, false);
        expectProbe(id, op, "freed last byte", user + @as(usize, @intCast(size)) - 1, false);
        release(start, size);

        console("[w{d:0>2} c{d}] op {d:>2}/{d} crc1 0x{x:0>8} crc2 0x{x:0>8} {s}, free {s} MB | in use {s} MB\n", .{
            id, board.cpuSlot(), op, kOps, crc1, crc2, if (match) "OK" else "NOT OK", mb(&b1, size), mb(&b2, inUse()),
        });

        const slot = board.cpuSlot();
        if (slot < 4) g_core_ops[slot] += 1;
        _ = g_ops_done.fetchAdd(1, .monotonic);
    }

    // Done as owner; stay helper until all workers finish
    _ = g_workers_done.fetchAdd(1, .monotonic);
    while (g_workers_done.load(.monotonic) < kWorkers) {
        _ = serveOnce(id, 0, 10);
    }
    return null;
}

const worker_stack_size = 16384;
const Stack = [worker_stack_size / @sizeOf(uos.port.StackElement)]uos.port.StackElement;
var s_stacks: [kWorkers]Stack = undefined;
var s_names: [kWorkers][8:0]u8 = undefined;
var s_qnames: [kWorkers][8:0]u8 = undefined;
var s_threads: [kWorkers]*rtos.Thread = undefined;

pub fn main() void {
    board.uart.init();
    board.led.init();
    rtos.run(osMain);
}

fn osMain() void {
    const gpa = uos.memory.allocator();

    console("\n+=============================================================+\n", .{});
    console("|  " ++ board.banner_short ++ " µOS++ SMP MEMORY + INTER-THREAD TEST |\n", .{});
    console("|  smp-mem-inter-test                                         |\n", .{});
    console("+=============================================================+\n\n", .{});

    _ = rtos.interrupts.UncriticalSection.enter();
    board.smp.startSecondaryCores();
    const waited = board.smp.waitSecondaries(3000);
    console("Secondary cores joined: {s} ({d} ms)\n", .{ board.smp.joinSummary(), waited });

    var base: usize = 0;
    var end: usize = 0;
    board.mmu.hiRegion(&base, &end);
    g_lo = base + kPage;
    g_hi = end;
    console("Region 0x{x:0>8} .. 0x{x:0>8}: {d} MB, all pages unmapped\n", .{
        base, end, (end - base) / kMB,
    });
    console("{d} threads in a ring x {d} operations, blocks of 1 .. {d} MB\n\n", .{
        kWorkers, kOps, kMaxBytes / kMB,
    });

    for (0..kWorkers) |i| {
        s_qnames[i] = "mq00\x00\x00\x00\x00".*;
        s_qnames[i][2] = '0' + @as(u8, @intCast(i / 10));
        s_qnames[i][3] = '0' + @as(u8, @intCast(i % 10));
        g_q[i].create(gpa, &s_qnames[i], 4, @sizeOf(Msg), .{}) catch unreachable;
    }

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
            console("[t={d:>4}s] ops {d}/{d}, crc OK {d} NOT OK {d}, in use {s} MB, peak {s} MB, OOM retries {d}\n", .{
                seconds, g_ops_done.load(.monotonic), kWorkers * kOps, g_crc_ok.load(.monotonic),
                g_crc_bad.load(.monotonic), mb(&b1, inUse()), mb(&b2, g_peak), g_oom.load(.monotonic),
            });
        }
    }
    sysclock.sleepFor(50) catch {}; // let last helpers drain

    var still_mapped: u32 = 0;
    var a = base;
    while (a < end) : (a += 2 * kMB) {
        if (board.mmu.hiProbe(a)) still_mapped += 1;
    }
    if (board.mmu.hiProbe(end - kPage)) still_mapped += 1;

    var all_cores = true;
    for (0..ncpu) |c| {
        if (g_core_ops[c] == 0 or g_core_mods[c] == 0) all_cores = false;
    }

    console("\n==== smp_mem_inter_test summary ({d} s) ====\n", .{seconds});
    board.reportPerCore("operations per core   ", &g_core_ops);
    board.reportPerCore("modifications per core", &g_core_mods);
    console("  operations      : {d} / {d}\n", .{ g_ops_done.load(.monotonic), kWorkers * kOps });
    console("  crc1 == crc2    : {d} OK, {d} NOT OK\n", .{ g_crc_ok.load(.monotonic), g_crc_bad.load(.monotonic) });
    console("  allocated total : {s} MB\n", .{mb(&b1, g_bytes_alloc.load(.monotonic))});
    console("  peak in use     : {s} MB of {s} MB\n", .{ mb(&b1, g_peak), mb(&b2, g_hi - g_lo) });
    console("  OOM retries     : {d}\n", .{g_oom.load(.monotonic)});
    console("  protocol errors : {d}\n", .{g_proto_err.load(.monotonic)});
    console("  canary errors   : {d}\n", .{g_canary_err.load(.monotonic)});
    console("  MMU probe errors: {d}\n", .{g_probe_err.load(.monotonic)});
    console("  in use at end   : {s} MB, pages still mapped: {d}\n", .{ mb(&b1, inUse()), still_mapped });

    const ok = board.smp.secondariesJoined() and all_cores and
        g_ops_done.load(.monotonic) == kWorkers * kOps and
        g_crc_ok.load(.monotonic) == kWorkers * kOps and
        g_crc_bad.load(.monotonic) == 0 and
        g_proto_err.load(.monotonic) == 0 and
        g_canary_err.load(.monotonic) == 0 and
        g_probe_err.load(.monotonic) == 0 and
        inUse() == 0 and
        still_mapped == 0;

    console("\nRESULT: {s}\n", .{if (ok) "PASS" else "FAIL"});
    if (ok) board.hw_result.ok();
    board.hw_result.fail();
}
