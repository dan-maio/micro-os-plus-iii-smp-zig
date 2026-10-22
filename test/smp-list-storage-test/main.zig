//! smp-list-storage-test -- the generic intrusive list of the interfaces
//! example with its nodes in the three storage regions (a thread's stack,
//! the data segment and the heap), shared by threads on all four CPUs.
//! Console on the UART; no SD card.
//!
//! `list.zig` is the example's `IntrusiveList(T)`, instantiated for two
//! unrelated payloads: `Record` (sealed: it detects a field changed behind
//! its back) and `TextNode` (the example's `StringNode`). One list of each
//! is shared by every thread, guarded by one RTOS mutex. Every node is also
//! checked to be where it claims: in its own thread's stack, in the
//! data-segment arrays or inside the system heap's arena (the thread stacks
//! are static arrays here, so the three ranges do not overlap).
//!
//! Phase 1, regions: four threads, one per CPU, each put 8 records and one
//! text node on their stack, in the data segment and on the heap, and push
//! them on the shared lists; then they wait, their stack frames alive, while
//! the main thread checks the lists (96 records, 8 per thread and region, 12
//! texts, every seal and address) and uppercases the data-segment texts
//! through the generic list. Released, each thread unlinks its stack nodes
//! (which die with its frame) and returns; the data-segment and heap nodes
//! stay, 64 records and 8 texts.
//!
//! Phase 2, stress: 10 rounds of 1 s. Each round creates 8 workers (two per
//! CPU) and a scanner. The workers push nodes from their stack frame, from
//! their data-segment pool and from the heap, unlink and free them, change
//! their values (under the mutex) and search the phase 1 records; each
//! changes only its own nodes. The scanner walks both lists under the mutex
//! and checks every seal and address. At the end of the round every worker
//! unlinks all its nodes and returns; the nine threads are joined and
//! destroyed. After each round the lists must again hold the phase 1 nodes,
//! the data-segment pool must be free and the heap back to its level.
//!
//! PASS when no check failed and, all nodes released, the heap is back to
//! its starting level. The verdict line is the only one on semihosting.

const std = @import("std");
const uos = @import("uos");
const board = @import("board");
const list = @import("list.zig");

const rtos = uos.rtos;
const sysclock = rtos.sysclock;
const this_thread = rtos.this_thread;
const ncpu = uos.config.ncpu;
const Record = list.Record;
const TextNode = list.TextNode;
const Region = list.Region;

pub const uos_options = board.options(4);

const per_region = 8; // phase 1: records per thread and region
const rounds = 10;
const round_ms = 1000;
const n_workers = ncpu * 2;
const pool = 6; // phase 2: nodes per worker and region
const stack_elems = 4096; // 32 KiB per thread

fn cpuId() u32 {
    return board.cpuSlot();
}

// ---- The three regions -----------------------------------------------------

/// Every thread's stack: static, so its range is known and is neither the
/// data-segment arrays nor the heap.
var g_stacks: [n_workers + 1][stack_elems]uos.port.StackElement align(16) = undefined;

// The data segment. Initialised to a non-zero pattern, so the arrays are in
// .data, not .bss.
var g_data_recs: [ncpu][per_region]Record = @splat(@splat(.{ .id = 0xD47A }));
var g_data_txt: [ncpu]TextNode = @splat(.{ .text = @splat('.'), .len = 1 });
var g_pool_data: [n_workers][pool]Record = @splat(@splat(.{ .id = 0xD47A }));
var g_pool_busy: [n_workers][pool]bool = @splat(@splat(false));

fn inside(p: usize, base: usize, len: usize) bool {
    return p >= base and p < base + len;
}

fn inArray(p: usize, arr: anytype) bool {
    return inside(p, @intFromPtr(arr), @sizeOf(@TypeOf(arr.*)));
}

/// The region an address is in; null when it is in none of the three.
fn regionOf(ptr: *const anyopaque) ?Region {
    const p = @intFromPtr(ptr);
    if (inArray(p, &g_stacks)) return .stack;
    if (inArray(p, &g_data_recs) or inArray(p, &g_data_txt) or inArray(p, &g_pool_data)) return .data;
    const arena = uos.memory.systemHeap().arena;
    if (inside(p, @intFromPtr(arena.ptr), arena.len)) return .heap;
    return null;
}

/// The thread slot whose stack holds `ptr`.
fn stackSlot(ptr: *const anyopaque) usize {
    return (@intFromPtr(ptr) - @intFromPtr(&g_stacks)) / @sizeOf(@TypeOf(g_stacks[0]));
}

// ---- The shared lists ------------------------------------------------------

var g_recs: list.IntrusiveList(Record) = .{};
var g_texts: list.IntrusiveList(TextNode) = .{};
var g_mtx: rtos.Mutex = .{ .name = "lists" };

fn lock() void {
    g_mtx.lock() catch bad("list mutex lock", .{});
}

fn unlock() void {
    g_mtx.unlock() catch bad("list mutex unlock", .{});
}

fn heapBytes() usize {
    return uos.memory.statistics().allocated_bytes;
}

// ---- Checks ----------------------------------------------------------------

var g_errors = std.atomic.Value(u32).init(0);

fn bad(comptime fmt: []const u8, args: anytype) void {
    const n = g_errors.fetchAdd(1, .monotonic);
    if (n < 20) board.console("  BAD c{d}: " ++ fmt ++ "\n", .{cpuId()} ++ args);
}

/// The seal, and the address in the region the record claims (for a stack
/// record, in its own thread's stack).
fn checkRecord(r: *const Record) bool {
    if (!r.valid()) {
        bad("record {x} @{x}: broken seal", .{ r.id, @intFromPtr(r) });
        return false;
    }
    const where = regionOf(r) orelse {
        bad("record {x} @{x}: in no known region", .{ r.id, @intFromPtr(r) });
        return false;
    };
    if (where != r.region) {
        bad("record {x}: says {s}, is in {s}", .{ r.id, @tagName(r.region), @tagName(where) });
        return false;
    }
    if (where == .stack and stackSlot(r) != r.owner) {
        bad("record {x}: on the stack of thread {d}, owned by {d}", .{ r.id, stackSlot(r), r.owner });
        return false;
    }
    return true;
}

fn checkText(t: *const TextNode) bool {
    const where = regionOf(t);
    if (where != t.region or t.len == 0 or t.len > TextNode.capacity) {
        bad("text @{x} ({s}) in the wrong region or length {d}", .{ @intFromPtr(t), @tagName(t.region), t.len });
        return false;
    }
    return true;
}

fn idOf(owner: usize, region: Region, i: usize) u32 {
    return @intCast((owner << 16) | (@as(usize, @intFromEnum(region)) << 8) | i);
}

// ---- Threads -----------------------------------------------------------------

var g_names: [n_workers + 1][8:0]u8 = undefined;

fn threadName(slot: usize, prefix: []const u8, n: usize) [:0]const u8 {
    var w: std.Io.Writer = .fixed(g_names[slot][0..7]);
    w.print("{s}{d}", .{ prefix, n }) catch {};
    const len = w.buffered().len;
    g_names[slot][len] = 0;
    return g_names[slot][0..len :0];
}

/// A thread on stack slot `slot` (its own static stack).
fn startThread(slot: usize, name: [:0]const u8, func: *const fn (?*anyopaque) ?*anyopaque, cpu_mask: u32) ?*rtos.Thread {
    return rtos.Thread.create(uos.memory.allocator(), name, func, @ptrFromInt(slot), .{
        .stack = &g_stacks[slot],
        .cpu_affinity = cpu_mask,
    }) catch {
        bad("cannot create thread {s}", .{name});
        return null;
    };
}

fn joinAndDestroy(th: ?*rtos.Thread) void {
    const t = th orelse return;
    _ = t.join() catch bad("join {s}", .{t.name});
    t.destroy();
}

// ---- Phase 1: one thread per CPU, nodes in the three regions ----------------

var g_ready: rtos.Semaphore = .counting("ready", ncpu, 0);
var g_release: [ncpu]rtos.Semaphore = @splat(.binary("release", 0));

fn regionWorker(arg: ?*anyopaque) ?*anyopaque {
    const w: usize = @intFromPtr(arg);
    const owner: u8 = @intCast(w);
    const gpa = uos.memory.allocator();

    // On this thread's stack: they live as long as this frame.
    var local: [per_region]Record = undefined;
    var local_txt: TextNode = undefined;
    var buf: [TextNode.capacity]u8 = undefined;

    for (&local, 0..) |*r, i| r.init(idOf(w, .stack, i), owner, .stack, 1000 * w + i);
    for (&g_data_recs[w], 0..) |*r, i| r.init(idOf(w, .data, i), owner, .data, 2000 * w + i);
    var heap_recs: [per_region]?*Record = @splat(null);
    for (&heap_recs, 0..) |*h, i| {
        const r = gpa.create(Record) catch {
            bad("w{d}: out of memory", .{w});
            continue;
        };
        r.init(idOf(w, .heap, i), owner, .heap, 3000 * w + i);
        h.* = r;
    }
    local_txt.init(std.fmt.bufPrint(&buf, "w{d} stack text", .{w}) catch "w stack", .stack) catch {};
    g_data_txt[w].init(std.fmt.bufPrint(&buf, "w{d} data text", .{w}) catch "w data", .data) catch {};
    const heap_txt = gpa.create(TextNode) catch null;
    if (heap_txt) |t| t.init(std.fmt.bufPrint(&buf, "w{d} heap text", .{w}) catch "w heap", .heap) catch {};

    lock();
    for (&local) |*r| g_recs.push(r);
    for (&g_data_recs[w]) |*r| g_recs.push(r);
    for (heap_recs) |h| if (h) |r| g_recs.push(r);
    g_texts.push(&local_txt);
    g_texts.push(&g_data_txt[w]);
    if (heap_txt) |t| g_texts.push(t);
    unlock();

    board.console("  w{d} c{d}: 8 records + 1 text on its stack @{x}, in .data @{x}, on the heap @{x}\n", .{
        w, cpuId(), @intFromPtr(&local), @intFromPtr(&g_data_recs[w]), @intFromPtr(heap_recs[0]),
    });

    g_ready.post() catch {};
    g_release[w].wait() catch {};

    // The stack nodes die with this frame: out of the lists first.
    lock();
    for (&local) |*r| {
        if (!g_recs.unlink(r)) bad("w{d}: stack record {x} not in the list", .{ w, r.id });
    }
    if (!g_texts.unlink(&local_txt)) bad("w{d}: stack text not in the list", .{w});
    unlock();
    return null;
}

fn phaseRegions() void {
    board.console("\n-- phase 1: {d} threads, {d} records + 1 text each on the stack, in .data, on the heap\n", .{ ncpu, per_region });
    var th: [ncpu]?*rtos.Thread = undefined;
    for (0..ncpu) |w| th[w] = startThread(w, threadName(w, "reg", w), regionWorker, @as(u32, 1) << @intCast(w));
    for (0..ncpu) |_| g_ready.wait() catch {};

    // Every thread waits with its nodes in the lists, its stack alive.
    var tally: [ncpu][list.regions.len]usize = @splat(@splat(0));
    var bad_nodes: usize = 0;
    lock();
    const n_recs = g_recs.count();
    const n_texts = g_texts.count();
    var it = g_recs.head;
    while (it) |r| : (it = r.next) {
        if (checkRecord(r) and r.owner < ncpu) tally[r.owner][@intFromEnum(r.region)] += 1 else bad_nodes += 1;
    }
    // The generic list over the other payload: uppercase the .data texts.
    var upper: usize = 0;
    var tt = g_texts.head;
    while (tt) |t| : (tt = t.next) {
        if (!checkText(t)) bad_nodes += 1;
        if (t.region == .data) {
            t.toUpper();
            upper += 1;
        }
    }
    var texts_ok = true;
    tt = g_texts.head;
    while (tt) |t| : (tt = t.next) {
        const s = t.slice();
        const want_upper = t.region == .data;
        for (s) |c| {
            if (std.ascii.isAlphabetic(c) and std.ascii.isUpper(c) != want_upper) texts_ok = false;
        }
    }
    unlock();

    for (0..ncpu) |w| {
        board.console("  w{d}: stack {d}, data {d}, heap {d} records\n", .{ w, tally[w][0], tally[w][1], tally[w][2] });
        for (tally[w]) |n| if (n != per_region) bad("w{d}: {d} records in a region, not {d}", .{ w, n, per_region });
    }
    const want_recs = ncpu * list.regions.len * per_region;
    const want_texts = ncpu * list.regions.len;
    board.console("  lists: {d} records, {d} texts ({d} uppercased in .data) {s}\n", .{
        n_recs, n_texts, upper, if (n_recs == want_recs and n_texts == want_texts and bad_nodes == 0 and texts_ok) "ok" else "BAD",
    });
    if (n_recs != want_recs or n_texts != want_texts or bad_nodes != 0) bad("{d} records, {d} texts, {d} bad nodes", .{ n_recs, n_texts, bad_nodes });
    if (!texts_ok) bad("texts not uppercased as asked", .{});

    for (&g_release) |*s| s.post() catch {};
    for (th) |t| joinAndDestroy(t);

    var stack_left: usize = 0;
    lock();
    const left_recs = g_recs.count();
    const left_texts = g_texts.count();
    it = g_recs.head;
    while (it) |r| : (it = r.next) {
        if (r.region == .stack) stack_left += 1;
    }
    unlock();
    const ok = left_recs == want_recs - ncpu * per_region and left_texts == want_texts - ncpu and stack_left == 0;
    board.console("  after the threads returned: {d} records, {d} texts, {d} on a stack {s}\n", .{ left_recs, left_texts, stack_left, if (ok) "ok" else "BAD" });
    if (!ok) bad("after phase 1: {d} records, {d} texts, {d} stack nodes left", .{ left_recs, left_texts, stack_left });
}

// ---- Phase 2: churn ------------------------------------------------------------

var g_stop = std.atomic.Value(bool).init(false);
var g_scans: u32 = 0;
var g_round: usize = 0;
var g_pushed = std.atomic.Value(u32).init(0);
var g_unlinked = std.atomic.Value(u32).init(0);

const Worker = struct {
    w: usize,
    rng: u64,
    next_id: u32 = 0,
    local: *[pool]Record,
    local_busy: [pool]bool = @splat(false),
    heap: [pool]*Record = undefined,
    n_heap: usize = 0,
    pushed: u32 = 0,
    unlinked: u32 = 0,
    mutated: u32 = 0,
    searched: u32 = 0,

    fn rand(self: *Worker) u32 {
        self.rng = self.rng *% 6364136223846793005 +% 1442695040888963407;
        return @truncate(self.rng >> 33);
    }

    fn newRecord(self: *Worker, r: *Record, region: Region) void {
        self.next_id += 1;
        r.init(0x8000_0000 | @as(u32, @intCast(self.w << 20)) | self.next_id, @intCast(self.w), region, self.rand());
        lock();
        g_recs.push(r);
        unlock();
        self.pushed += 1;
    }

    fn drop(self: *Worker, r: *Record) void {
        lock();
        const ok = g_recs.unlink(r);
        unlock();
        if (!ok) bad("w{d}: own record {x} not in the list", .{ self.w, r.id });
        _ = checkRecord(r);
        self.unlinked += 1;
    }

    /// A busy slot of `busy`, starting from a random one.
    fn pick(self: *Worker, busy: []const bool, want: bool) ?usize {
        const start = self.rand() % busy.len;
        for (0..busy.len) |k| {
            const i = (start + k) % busy.len;
            if (busy[i] == want) return i;
        }
        return null;
    }

    fn push(self: *Worker, gpa: std.mem.Allocator, region: Region) void {
        switch (region) {
            .stack => if (self.pick(&self.local_busy, false)) |i| {
                self.newRecord(&self.local[i], .stack);
                self.local_busy[i] = true;
            },
            .data => if (self.pick(&g_pool_busy[self.w], false)) |i| {
                self.newRecord(&g_pool_data[self.w][i], .data);
                g_pool_busy[self.w][i] = true;
            },
            .heap => if (self.n_heap < pool) {
                const r = gpa.create(Record) catch {
                    bad("w{d}: out of memory", .{self.w});
                    return;
                };
                self.newRecord(r, .heap);
                self.heap[self.n_heap] = r;
                self.n_heap += 1;
            },
        }
    }

    fn release(self: *Worker, gpa: std.mem.Allocator, region: Region) void {
        switch (region) {
            .stack => if (self.pick(&self.local_busy, true)) |i| {
                self.drop(&self.local[i]);
                self.local_busy[i] = false;
            },
            .data => if (self.pick(&g_pool_busy[self.w], true)) |i| {
                self.drop(&g_pool_data[self.w][i]);
                g_pool_busy[self.w][i] = false;
            },
            .heap => if (self.n_heap > 0) {
                const i = self.rand() % self.n_heap;
                const r = self.heap[i];
                self.drop(r);
                gpa.destroy(r);
                self.n_heap -= 1;
                self.heap[i] = self.heap[self.n_heap];
            },
        }
    }

    fn mutate(self: *Worker) void {
        const r: *Record = if (self.pick(&self.local_busy, true)) |i| &self.local[i] else if (self.n_heap > 0) self.heap[0] else return;
        lock();
        r.value +%= 1;
        r.seal();
        unlock();
        self.mutated += 1;
    }

    fn search(self: *Worker) void {
        // A phase 1 record: in .data or on the heap, they stay.
        const region: Region = if (self.rand() & 1 == 0) .data else .heap;
        const id = idOf(self.rand() % ncpu, region, self.rand() % per_region);
        lock();
        var found = false;
        var it = g_recs.head;
        while (it) |r| : (it = r.next) {
            if (r.id == id) {
                found = r.valid();
                break;
            }
        }
        unlock();
        if (!found) bad("w{d}: phase 1 record {x} not found", .{ self.w, id });
        self.searched += 1;
    }
};

fn stressWorker(arg: ?*anyopaque) ?*anyopaque {
    const w: usize = @intFromPtr(arg);
    const gpa = uos.memory.allocator();
    var local: [pool]Record = undefined; // the stack nodes
    var self: Worker = .{ .w = w, .rng = 0x5EED_0000 + g_round * 977 + w * 7919, .local = &local };
    var ops: u32 = 0;
    while (!g_stop.load(.acquire)) {
        const op = self.rand() % 100;
        const region = list.regions[self.rand() % list.regions.len];
        if (op < 50) self.push(gpa, region) else if (op < 85) self.release(gpa, region) else if (op < 95) self.mutate() else self.search();
        ops += 1;
        if (ops % 8 == 0) this_thread.yield();
    }
    // Everything out, the stack nodes before this frame ends.
    for (list.regions) |region| {
        for (0..pool) |_| self.release(gpa, region);
    }
    for (self.local_busy) |b| if (b) bad("w{d}: a stack node left", .{w});
    _ = g_pushed.fetchAdd(self.pushed, .monotonic);
    _ = g_unlinked.fetchAdd(self.unlinked, .monotonic);
    board.console("  round {d} w{d} c{d}: pushed {d}, unlinked {d}, changed {d}, searched {d}\n", .{
        g_round, w, cpuId(), self.pushed, self.unlinked, self.mutated, self.searched,
    });
    return null;
}

fn scannerFunc(_: ?*anyopaque) ?*anyopaque {
    const limit = ncpu * list.regions.len * per_region + n_workers * list.regions.len * pool;
    var scans: u32 = 0;
    while (!g_stop.load(.acquire)) {
        lock();
        var n: usize = 0;
        var it = g_recs.head;
        while (it) |r| : (it = r.next) {
            n += 1;
            if (n > limit) {
                bad("scan: more than {d} records, a cycle?", .{limit});
                break;
            }
            if (!checkRecord(r)) break;
        }
        var tt = g_texts.head;
        while (tt) |t| : (tt = t.next) {
            if (!checkText(t)) break;
        }
        unlock();
        scans += 1;
        sysclock.sleepFor(1) catch {};
    }
    g_scans = scans;
    return null;
}

fn phaseChurn() void {
    board.console("\n-- phase 2: {d} rounds of {d} workers + 1 scanner, {d} ms each\n", .{ rounds, n_workers, round_ms });
    lock();
    const base_recs = g_recs.count();
    const base_texts = g_texts.count();
    unlock();
    for (0..rounds) |r| {
        g_round = r;
        const heap_before = heapBytes();
        const pushed_before = g_pushed.load(.monotonic);
        const unlinked_before = g_unlinked.load(.monotonic);
        g_stop.store(false, .release);
        var th: [n_workers]?*rtos.Thread = undefined;
        for (0..n_workers) |w| th[w] = startThread(w, threadName(w, "w", w), stressWorker, @as(u32, 1) << @intCast(w % ncpu));
        const scanner = startThread(n_workers, threadName(n_workers, "scan", r), scannerFunc, 0xFFFF_FFFF);

        sysclock.sleepFor(round_ms) catch {};
        g_stop.store(true, .release);
        for (th) |t| joinAndDestroy(t);
        joinAndDestroy(scanner);

        var busy: usize = 0;
        for (g_pool_busy) |row| {
            for (row) |b| {
                if (b) busy += 1;
            }
        }
        lock();
        const n = g_recs.count();
        const nt = g_texts.count();
        unlock();
        const heap_after = heapBytes();
        const pushed = g_pushed.load(.monotonic) - pushed_before;
        const unlinked = g_unlinked.load(.monotonic) - unlinked_before;
        const ok = n == base_recs and nt == base_texts and busy == 0 and pushed == unlinked and heap_after == heap_before;
        if (!ok) bad("round {d}: {d} records, {d} texts, {d} pool slots busy, +{d} -{d}, heap {d} -> {d}", .{ r, n, nt, busy, pushed, unlinked, heap_before, heap_after });
        board.console("  round {d}: {d} threads joined, +{d} -{d} nodes, {d} scans, lists {d}/{d}, heap {d} B {s}\n", .{
            r, n_workers + 1, pushed, unlinked, g_scans, n, nt, heap_after, if (ok) "ok" else "BAD",
        });
    }
}

/// Unlink every node; free the heap ones.
fn releaseAll() void {
    const gpa = uos.memory.allocator();
    lock();
    while (g_recs.head) |r| {
        _ = g_recs.unlink(r);
        if (r.region == .heap) gpa.destroy(r);
    }
    while (g_texts.head) |t| {
        _ = g_texts.unlink(t);
        if (t.region == .heap) gpa.destroy(t);
    }
    unlock();
}

// ---- Main ------------------------------------------------------------------

pub fn main() void {
    board.uart.init();
    rtos.run(osMain);
}

fn osMain() void {
    this_thread.thread().setCpuAffinity(1 << 0);
    board.uart.puts("\n" ++
        "=============================================\n" ++
        "  " ++ board.banner_long ++ " - " ++ board.banner_cpu ++ "\n" ++
        "  micro-os-plus-iii  smp-list-storage-test\n" ++
        "  intrusive list: stack, .data and heap nodes\n" ++
        "=============================================\n");

    board.smp.startSecondaryCores();
    const waited = board.smp.waitSecondaries(3000);
    board.console("SMP up ({s}) after {d} ms\n", .{ board.smp.joinSummary(), waited });

    const arena = uos.memory.systemHeap().arena;
    board.console("  stacks  {x:0>16}..{x:0>16}\n", .{ @intFromPtr(&g_stacks), @intFromPtr(&g_stacks) + @sizeOf(@TypeOf(g_stacks)) });
    board.console("  .data   {x:0>16}..{x:0>16} (records)\n", .{ @intFromPtr(&g_data_recs), @intFromPtr(&g_data_recs) + @sizeOf(@TypeOf(g_data_recs)) });
    board.console("  heap    {x:0>16}..{x:0>16}\n", .{ @intFromPtr(arena.ptr), @intFromPtr(arena.ptr) + arena.len });

    const heap_start = heapBytes();
    phaseRegions();
    phaseChurn();

    releaseAll();
    const heap_end = heapBytes();
    const heap_ok = heap_end == heap_start;
    board.console("\nall nodes released, heap {d} B (at start {d} B) {s}\n", .{ heap_end, heap_start, if (heap_ok) "ok" else "BAD" });
    if (!heap_ok) bad("heap {d} B at the end, {d} B at the start", .{ heap_end, heap_start });

    const errors = g_errors.load(.monotonic);
    if (errors == 0) {
        board.console("RESULT: PASS (96 nodes in 3 regions checked, {d} churn rounds, heap restored)\n", .{rounds});
        board.hw_result.ok();
    }
    board.console("RESULT: FAIL ({d} failed checks)\n", .{errors});
    board.hw_result.fail();
}
