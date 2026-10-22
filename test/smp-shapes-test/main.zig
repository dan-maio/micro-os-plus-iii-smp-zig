//! smp-shapes-test -- the interfaces example (intrusive generic list, vtable
//! polymorphism, threads) on the RTOS, on all four CPUs, with its output on
//! the UART and on the SD card.
//!
//! The shapes and the list are those of ~/Documents/work_zig/interfaces
//! (shapes.zig). One `ShapeList` is shared by every thread and guarded by an
//! RTOS mutex; every shape lives on the kernel heap.
//!
//! Phase 1, build: four builder threads, one per kind and one per CPU, each
//! construct 10 shapes (circles, triangles, ellipses, rects), check each one
//! through the vtable (name, kind, area against its constructor arguments,
//! the node embedded in its own object) and push it on the shared list. Then
//! the list is checked: 40 nodes, 10 of each kind, the total area, a search
//! per kind.
//!
//! Phase 1b, scale: four threads, one per kind, scale their kind by 2 under
//! the mutex at the same time, check the kind's area grew 4x, scale it back
//! and check it is restored; ShapeList.modify() is exercised the same way.
//!
//! Phase 2, stress: 20 rounds. Each round creates 8 worker threads (two per
//! CPU) and a scanner; for 1.5 s the workers create, check, push, scale,
//! search, unlink and free shapes of random kinds and sizes (each worker
//! changes only its own shapes), while the scanner walks the whole list
//! under the mutex and checks every node. At the end of the round every
//! worker frees its shapes and returns; the threads are joined and
//! destroyed. After each round the list must again hold exactly the 40
//! phase 1 shapes with their total area, and the heap must be back to its
//! level before the round: no leaked shape, thread or stack.
//!
//! Output: one logger thread on CPU 0 owns the UART and the SD card. Every
//! other thread sends it lines through a message queue; it prints each line
//! on the UART and appends it to tests/shapes.log on the card's existing
//! FAT32 partition (the card is never formatted). At the end the file is
//! read back, its size and CRC32 compared with what was written.
//!
//! PASS when no check failed, every created shape was freed, the heap is
//! back to its starting level and the SD log reads back intact. The verdict
//! line is the only one that reaches semihosting.

const std = @import("std");
const uos = @import("uos");
const board = @import("board");
const sd = @import("sd");
const fatfs = @import("fatfs");
const shapes = @import("shapes.zig");

const rtos = uos.rtos;
const sysclock = rtos.sysclock;
const this_thread = rtos.this_thread;
const ncpu = uos.config.ncpu;
const Shape = shapes.Shape;
const Kind = shapes.Kind;

pub const uos_options = board.options(4);

const per_kind = 10;
const rounds = 20;
const round_ms = 1500;
const workers_per_cpu = 2;
const n_workers = ncpu * workers_per_cpu;
const max_owned = 16;
const thread_stack_bytes = 32 * 1024;
const log_file = "shapes.log";

fn cpuId() u32 {
    return board.cpuSlot();
}

// ---- The logger: CPU 0 owns the UART and the SD card ---------------------

const LogOp = enum(u8) { line, flush, stop };
const LogMsg = struct {
    op: LogOp = .line,
    len: u8 = 0,
    text: [110]u8 = undefined,
};

var g_log_q: rtos.MessageQueueTyped(LogMsg).Static(64) = .{};
var g_log_ack: rtos.Semaphore = .binary("log_ack", 0);
var g_log_thread: *rtos.Thread = undefined;

var g_sd_buf: [4096]u8 = undefined;
var g_sd_len: usize = 0;
var g_sd_bytes: usize = 0;
var g_sd_crc: std.hash.Crc32 = .init();
var g_sd_errors: u32 = 0;

/// Format one line and queue it for the logger (blocks while the queue is
/// full). Lines longer than the message are cut.
fn log(comptime fmt: []const u8, args: anytype) void {
    var m: LogMsg = .{};
    var w: std.Io.Writer = .fixed(&m.text);
    w.print(fmt, args) catch {};
    m.len = @intCast(w.buffered().len);
    g_log_q.typed.send(m, 0) catch {};
}

/// Ask the logger to write what it holds to the card, and wait until it has.
fn logSync(op: LogOp) void {
    g_log_q.typed.send(.{ .op = op }, 0) catch {};
    g_log_ack.wait() catch {};
}

fn sdFlush() void {
    if (g_sd_len == 0) return;
    const chunk = g_sd_buf[0..g_sd_len];
    if (fatfs.appendFile(log_file, chunk)) {
        g_sd_bytes += chunk.len;
        g_sd_crc.update(chunk);
    } else {
        g_sd_errors += 1;
    }
    g_sd_len = 0;
}

fn loggerFunc(_: ?*anyopaque) ?*anyopaque {
    while (true) {
        // A quiet half second writes out what is buffered.
        const m = g_log_q.typed.timedReceive(500) catch {
            sdFlush();
            continue;
        };
        switch (m.op) {
            .line => {
                const t = m.text[0..m.len];
                board.uart.puts(t);
                if (g_sd_len + t.len > g_sd_buf.len) sdFlush();
                @memcpy(g_sd_buf[g_sd_len..][0..t.len], t);
                g_sd_len += t.len;
            },
            .flush => {
                sdFlush();
                g_log_ack.post() catch {};
            },
            .stop => {
                sdFlush();
                g_log_ack.post() catch {};
                return null;
            },
        }
    }
}

// ---- Checks ----------------------------------------------------------------

var g_errors = std.atomic.Value(u32).init(0);

/// A failed check: counted, and the first 20 are logged.
fn bad(comptime fmt: []const u8, args: anytype) void {
    const n = g_errors.fetchAdd(1, .monotonic);
    if (n < 20) log("  BAD c{d}: " ++ fmt ++ "\n", .{cpuId()} ++ args);
}

/// The checks every freshly built or still listed shape must pass.
fn checkShape(s: *const Shape, want: ?Kind) bool {
    const k = shapes.kindOf(s) orelse {
        bad("node @{x} has an unknown vtable", .{@intFromPtr(s)});
        return false;
    };
    if (want) |w| {
        if (k != w) {
            bad("{s} built as {s}", .{ @tagName(k), @tagName(w) });
            return false;
        }
    }
    if (!std.mem.eql(u8, s.name(), @tagName(k))) {
        bad("{s} reports the name {s}", .{ @tagName(k), s.name() });
        return false;
    }
    if (!shapes.selfConsistent(s)) {
        bad("{s} @{x} is not the node of its object", .{ @tagName(k), @intFromPtr(s) });
        return false;
    }
    const got = s.area();
    if (!(got > 0) or !shapes.close(got, shapes.expectedArea(s))) {
        bad("{s} area {d:.6}, expected {d:.6}", .{ @tagName(k), got, shapes.expectedArea(s) });
        return false;
    }
    return true;
}

// ---- The shared list -------------------------------------------------------

var g_list: shapes.ShapeList = .{};
var g_list_mtx: rtos.Mutex = .{ .name = "shapes" };

fn lockList() void {
    g_list_mtx.lock() catch bad("list mutex lock", .{});
}

fn unlockList() void {
    g_list_mtx.unlock() catch bad("list mutex unlock", .{});
}

fn heapBytes() usize {
    return uos.memory.statistics().allocated_bytes;
}

// ---- Phase 1: four builders, one kind each ---------------------------------

var g_built_area: [shapes.kinds.len]f64 = @splat(0);

fn builderFunc(arg: ?*anyopaque) ?*anyopaque {
    const k: Kind = @enumFromInt(@intFromPtr(arg));
    const ki = @intFromEnum(k);
    const gpa = uos.memory.allocator();
    var sum: f64 = 0;
    for (0..per_kind) |i| {
        const fi: f64 = @floatFromInt(i);
        const a = 1.0 + 0.5 * fi + 0.25 * @as(f64, @floatFromInt(ki));
        const b = 2.0 + 0.25 * fi;
        const s = shapes.make(gpa, k, a, b) catch {
            bad("{s} #{d}: out of memory", .{ @tagName(k), i });
            continue;
        };
        const ok = checkShape(s, k);
        const area = s.area();
        lockList();
        g_list.push(s);
        unlockList();
        sum += area;
        log("  c{d} {s:<8} #{d}: a={d:.2} b={d:.2} area={d:.4} {s}\n", .{
            cpuId(), @tagName(k), i, a, b, area, if (ok) "ok" else "BAD",
        });
    }
    g_built_area[ki] = sum;
    return null;
}

var g_names: [16][8:0]u8 = undefined;

fn threadName(slot: usize, prefix: []const u8, n: usize) [:0]const u8 {
    var w: std.Io.Writer = .fixed(g_names[slot][0..7]);
    w.print("{s}{d}", .{ prefix, n }) catch {};
    const len = w.buffered().len;
    g_names[slot][len] = 0;
    return g_names[slot][0..len :0];
}

fn startThread(name: [:0]const u8, func: *const fn (?*anyopaque) ?*anyopaque, arg: usize, cpu_mask: u32) ?*rtos.Thread {
    return rtos.Thread.create(uos.memory.allocator(), name, func, @ptrFromInt(arg), .{
        .stack_size_bytes = thread_stack_bytes,
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

fn phaseBuild() f64 {
    log("\n-- phase 1: 4 builder threads, {d} shapes of each kind\n", .{per_kind});
    var th: [shapes.kinds.len]?*rtos.Thread = undefined;
    for (shapes.kinds, 0..) |k, i| {
        th[i] = startThread(threadName(i, "build", i), builderFunc, @intFromEnum(k), @as(u32, 1) << @intCast(i % ncpu));
    }
    for (th) |t| joinAndDestroy(t);

    // The list, as the builders left it.
    var per: [shapes.kinds.len]usize = @splat(0);
    var bad_nodes: usize = 0;
    lockList();
    const n = g_list.count();
    const total = g_list.totalArea();
    var it = g_list.nodes.head;
    while (it) |s| : (it = s.next) {
        if (checkShape(s, null)) per[@intFromEnum(shapes.kindOf(s).?)] += 1 else bad_nodes += 1;
    }
    var found: [shapes.kinds.len]bool = undefined;
    for (shapes.kinds, 0..) |k, i| found[i] = g_list.search(@tagName(k)) != null;
    unlockList();

    var want_total: f64 = 0;
    for (g_built_area) |a| want_total += a;
    log("  list: {d} shapes ({d} circles, {d} triangles, {d} ellipses, {d} rects)\n", .{ n, per[0], per[1], per[2], per[3] });
    log("  total area {d:.4} (builders {d:.4})\n", .{ total, want_total });
    if (n != shapes.kinds.len * per_kind or bad_nodes != 0) bad("list holds {d} shapes, {d} bad", .{ n, bad_nodes });
    for (per, 0..) |p, i| if (p != per_kind) bad("{d} {s}s", .{ p, @tagName(shapes.kinds[i]) });
    if (!shapes.close(total, want_total)) bad("total area {d:.6} != {d:.6}", .{ total, want_total });
    for (found, 0..) |f, i| if (!f) bad("search({s}) found nothing", .{@tagName(shapes.kinds[i])});
    return total;
}

// ---- Phase 1b: concurrent scaling, one kind per thread ----------------------

fn kindArea(k: Kind) f64 {
    var sum: f64 = 0;
    var it = g_list.nodes.head;
    while (it) |s| : (it = s.next) {
        if (shapes.kindOf(s) == k) sum += s.area();
    }
    return sum;
}

fn scaleKind(k: Kind, factor: f64) void {
    var it = g_list.nodes.head;
    while (it) |s| : (it = s.next) {
        if (shapes.kindOf(s) == k) s.scale(factor);
    }
}

fn scalerFunc(arg: ?*anyopaque) ?*anyopaque {
    const k: Kind = @enumFromInt(@intFromPtr(arg));
    lockList();
    const before = kindArea(k);
    scaleKind(k, 2.0);
    const doubled = kindArea(k);
    unlockList();
    this_thread.yield();
    lockList();
    scaleKind(k, 0.5);
    const restored = kindArea(k);
    // ShapeList.modify(): the first shape of the kind, 3x and back.
    const first = g_list.search(@tagName(k));
    const a0 = if (first) |s| s.area() else 0;
    const m1 = g_list.modify(@tagName(k), 3.0);
    const a1 = if (first) |s| s.area() else 0;
    const m2 = g_list.modify(@tagName(k), 1.0 / 3.0);
    const a2 = if (first) |s| s.area() else 0;
    unlockList();

    const ok = shapes.close(doubled, 4.0 * before) and shapes.close(restored, before) and
        m1 and m2 and shapes.close(a1, 9.0 * a0) and shapes.close(a2, a0);
    if (!ok) bad("{s}: scale x2 {d:.4} -> {d:.4} -> {d:.4}, modify {d:.4} -> {d:.4}", .{ @tagName(k), before, doubled, restored, a0, a1 });
    log("  c{d} {s:<8}: area {d:.4} -> x2 {d:.4} -> back {d:.4}; modify x3 {d:.4} -> {d:.4} {s}\n", .{
        cpuId(), @tagName(k), before, doubled, restored, a0, a1, if (ok) "ok" else "BAD",
    });
    return null;
}

fn phaseScale(base_total: f64) void {
    log("\n-- phase 1b: 4 threads scale their kind at the same time\n", .{});
    var th: [shapes.kinds.len]?*rtos.Thread = undefined;
    for (shapes.kinds, 0..) |k, i| {
        th[i] = startThread(threadName(i, "scale", i), scalerFunc, @intFromEnum(k), @as(u32, 1) << @intCast(i % ncpu));
    }
    for (th) |t| joinAndDestroy(t);
    lockList();
    const total = g_list.totalArea();
    unlockList();
    if (!shapes.close(total, base_total)) bad("total area after scaling {d:.6} != {d:.6}", .{ total, base_total });
    log("  total area after the round trip {d:.4} {s}\n", .{ total, if (shapes.close(total, base_total)) "ok" else "BAD" });
}

// ---- Phase 2: generation / destruction stress -------------------------------

const Worker = struct {
    id: usize = 0,
    rng: u64 = 0,
    owned: [max_owned]*Shape = undefined,
    n_owned: usize = 0,
    created: u32 = 0,
    destroyed: u32 = 0,
    scaled: u32 = 0,
    searched: u32 = 0,

    fn next(w: *Worker) u32 {
        w.rng = w.rng *% 6364136223846793005 +% 1442695040888963407;
        return @truncate(w.rng >> 33);
    }

    fn param(w: *Worker) f64 {
        return 0.5 + @as(f64, @floatFromInt(w.next() % 1000)) / 100.0;
    }

    fn create(w: *Worker, gpa: std.mem.Allocator) void {
        const k = shapes.kinds[w.next() % shapes.kinds.len];
        const s = shapes.make(gpa, k, w.param(), w.param()) catch {
            bad("w{d}: out of memory", .{w.id});
            return;
        };
        _ = checkShape(s, k);
        lockList();
        g_list.push(s);
        unlockList();
        w.owned[w.n_owned] = s;
        w.n_owned += 1;
        w.created += 1;
    }

    fn destroy(w: *Worker, gpa: std.mem.Allocator, idx: usize) void {
        const s = w.owned[idx];
        lockList();
        const unlinked = g_list.delete(s);
        unlockList();
        if (!unlinked) bad("w{d}: own {s} missing from the list", .{ w.id, s.name() });
        _ = checkShape(s, null);
        // An unknown vtable is already counted; the shape is dropped (leaked)
        // rather than freed with a wrong size.
        if (shapes.free(gpa, s)) w.destroyed += 1;
        w.n_owned -= 1;
        w.owned[idx] = w.owned[w.n_owned];
    }

    fn scale(w: *Worker, idx: usize) void {
        const s = w.owned[idx];
        const factor: f64 = if (w.next() & 1 == 0) 2.0 else 0.5;
        lockList();
        const before = s.area();
        s.scale(factor);
        const after = s.area();
        unlockList();
        if (!shapes.close(after, before * factor * factor)) bad("w{d}: {s} scaled {d:.6} -> {d:.6}", .{ w.id, s.name(), before, after });
        w.scaled += 1;
    }

    fn search(w: *Worker) void {
        const k = shapes.kinds[w.next() % shapes.kinds.len];
        lockList();
        const found = g_list.search(@tagName(k));
        const kind_ok = if (found) |s| shapes.kindOf(s) == k else false;
        unlockList();
        // The 40 phase 1 shapes are always there.
        if (!kind_ok) bad("w{d}: search({s}) failed", .{ w.id, @tagName(k) });
        w.searched += 1;
    }
};

var g_workers: [n_workers]Worker = undefined;
var g_stop = std.atomic.Value(bool).init(false);
var g_scans: u32 = 0;
var g_round: usize = 0;

fn workerFunc(arg: ?*anyopaque) ?*anyopaque {
    const w = &g_workers[@intFromPtr(arg)];
    const gpa = uos.memory.allocator();
    var ops: u32 = 0;
    while (!g_stop.load(.acquire)) {
        const r = w.next() % 100;
        if (r < 45) {
            if (w.n_owned < max_owned) w.create(gpa) else w.destroy(gpa, w.next() % w.n_owned);
        } else if (r < 75) {
            if (w.n_owned > 0) w.destroy(gpa, w.next() % w.n_owned);
        } else if (r < 92) {
            if (w.n_owned > 0) w.scale(w.next() % w.n_owned);
        } else {
            w.search();
        }
        ops += 1;
        if (ops % 8 == 0) this_thread.yield();
    }
    while (w.n_owned > 0) w.destroy(gpa, w.n_owned - 1);
    log("  round {d:>2} w{d} c{d}: +{d} -{d} scaled {d} searched {d}\n", .{
        g_round, w.id, cpuId(), w.created, w.destroyed, w.scaled, w.searched,
    });
    return null;
}

fn scannerFunc(_: ?*anyopaque) ?*anyopaque {
    const limit = shapes.kinds.len * per_kind + n_workers * max_owned;
    var scans: u32 = 0;
    while (!g_stop.load(.acquire)) {
        lockList();
        var n: usize = 0;
        var it = g_list.nodes.head;
        while (it) |s| : (it = s.next) {
            n += 1;
            if (n > limit) {
                bad("scan: more than {d} nodes, a cycle?", .{limit});
                break;
            }
            if (!checkShape(s, null)) break;
        }
        unlockList();
        scans += 1;
        sysclock.sleepFor(1) catch {};
    }
    g_scans = scans;
    return null;
}

fn phaseStress(base_total: f64) void {
    log("\n-- phase 2: {d} rounds of {d} workers + 1 scanner, {d} ms each\n", .{ rounds, n_workers, round_ms });
    var created: u64 = 0;
    var destroyed: u64 = 0;
    for (0..rounds) |r| {
        g_round = r;
        const heap_before = heapBytes();
        g_stop.store(false, .release);
        g_scans = 0;
        var th: [n_workers]?*rtos.Thread = undefined;
        for (0..n_workers) |i| {
            g_workers[i] = .{ .id = i, .rng = 0x5EED_0000 + r * 977 + i * 7919 };
            th[i] = startThread(threadName(i, "w", i), workerFunc, i, @as(u32, 1) << @intCast(i % ncpu));
        }
        const scanner = startThread(threadName(n_workers, "scan", r), scannerFunc, 0, 0xFFFF_FFFF);

        sysclock.sleepFor(round_ms) catch {};
        g_stop.store(true, .release);

        for (th) |t| joinAndDestroy(t);
        joinAndDestroy(scanner);

        var c: u32 = 0;
        var d: u32 = 0;
        for (g_workers) |w| {
            c += w.created;
            d += w.destroyed;
        }
        created += c;
        destroyed += d;

        lockList();
        const n = g_list.count();
        const total = g_list.totalArea();
        unlockList();
        const heap_after = heapBytes();
        const ok = n == shapes.kinds.len * per_kind and shapes.close(total, base_total) and
            c == d and heap_after == heap_before;
        if (!ok) bad("round {d}: list {d}, area {d:.6}, +{d} -{d}, heap {d} -> {d}", .{ r, n, total, c, d, heap_before, heap_after });
        log("  round {d:>2}: {d} threads joined, +{d} -{d} shapes, {d} scans, list {d}, heap {d} B {s}\n", .{
            r, n_workers + 1, c, d, g_scans, n, heap_after, if (ok) "ok" else "BAD",
        });
    }
    log("  stress total: {d} shapes created, {d} destroyed, {d} threads created and destroyed\n", .{
        created, destroyed, rounds * (n_workers + 1),
    });
    if (created != destroyed) bad("{d} shapes created, {d} destroyed", .{ created, destroyed });
}

/// Free the phase 1 shapes.
fn freeAll() void {
    const gpa = uos.memory.allocator();
    while (true) {
        lockList();
        const head = g_list.nodes.head;
        if (head) |s| _ = g_list.delete(s);
        unlockList();
        const s = head orelse break;
        if (!shapes.free(gpa, s)) bad("unknown vtable while freeing", .{});
    }
}

// ---- Main --------------------------------------------------------------------

var g_card: sd.SdCard = .{};

fn fatal(msg: []const u8) noreturn {
    board.uart.puts("FATAL: ");
    board.uart.puts(msg);
    board.uart.puts("\n");
    board.hw_result.fail();
}

pub fn main() void {
    board.uart.init();
    rtos.run(osMain);
}

fn osMain() void {
    this_thread.thread().setCpuAffinity(1 << 0);

    board.uart.puts("\n" ++
        "=============================================\n" ++
        "  " ++ board.banner_long ++ " - " ++ board.banner_cpu ++ "\n" ++
        "  micro-os-plus-iii  smp-shapes-test\n" ++
        "  intrusive list + vtables, threads on 4 CPUs\n" ++
        "=============================================\n");

    // The card first, on CPU 0, before the secondaries run.
    board.uart.puts("Initialising SD card...\n");
    if (!g_card.init()) fatal("SD card init failed");
    fatfs.bindCard(&g_card);
    if (!fatfs.mountVolume()) fatal("FAT32 mount failed");
    if (!fatfs.ensureTestsDir()) fatal("mkdir tests failed");
    _ = fatfs.removeFile(log_file);
    board.uart.puts("  FAT32 /tests ready, logging to tests/" ++ log_file ++ "\n");

    g_log_q.init("log", .{}) catch fatal("log queue init failed");
    g_log_thread = rtos.Thread.create(uos.memory.allocator(), "logger", loggerFunc, null, .{
        .stack_size_bytes = thread_stack_bytes,
        .priority = rtos.priority.above_normal,
        .cpu_affinity = 1 << 0,
    }) catch fatal("cannot create the logger");

    board.smp.startSecondaryCores();
    const waited = board.smp.waitSecondaries(3000);
    log("smp-shapes-test: SMP up ({s}) after {d} ms\n", .{ board.smp.joinSummary(), waited });

    const heap_start = heapBytes();
    log("heap at start: {d} B\n", .{heap_start});

    const base_total = phaseBuild();
    phaseScale(base_total);
    phaseStress(base_total);

    freeAll();
    const heap_end = heapBytes();
    log("\nall shapes freed, heap {d} B (at start {d} B) {s}\n", .{ heap_end, heap_start, if (heap_end == heap_start) "ok" else "BAD" });
    if (heap_end != heap_start) bad("heap {d} B at the end, {d} B at the start", .{ heap_end, heap_start });

    // Everything so far to the card, then read it back.
    logSync(.flush);
    var sd_ok = g_sd_errors == 0;
    const size = fatfs.fileSize(log_file) orelse 0;
    if (size != g_sd_bytes) sd_ok = false;
    const gpa = uos.memory.allocator();
    if (gpa.alloc(u8, g_sd_bytes)) |buf| {
        defer gpa.free(buf);
        if (!fatfs.loadFile(log_file, buf) or std.hash.Crc32.hash(buf) != g_sd_crc.final()) sd_ok = false;
    } else |_| sd_ok = false;
    log("SD log tests/{s}: {d} B written, {d} B on the card, {d} write errors, read-back {s}\n", .{
        log_file, g_sd_bytes, size, g_sd_errors, if (sd_ok) "ok" else "BAD",
    });

    const errors = g_errors.load(.monotonic);
    const pass = errors == 0 and sd_ok;
    if (pass) {
        log("RESULT: PASS (40 shapes built and checked, {d} stress rounds, SD log verified)\n", .{rounds});
    } else {
        log("RESULT: FAIL ({d} failed checks, SD log {s})\n", .{ errors, if (sd_ok) "ok" else "bad" });
    }
    logSync(.stop);
    if (pass) board.hw_result.ok() else board.hw_result.fail();
}
