//! tutor-02-threads-1cpu -- lesson 02, one CPU (see ../README.md).
//!
//! Lesson 01's work split over four worker threads. Each worker builds its
//! own 18 samples -- 6 on its own stack, 6 in its own slice of the data
//! segment, 6 on the heap -- in its own list, checks them, sorts them, finds
//! its maximum and checksum, frees its heap samples and returns a pointer to
//! its result. Two workers run on static stacks, two on stacks the kernel
//! allocates from the heap. The main thread collects the results with
//! join(), checks each against its reference and the merged maximum, then
//! destroys the threads and checks the heap is back to its level.
//!
//! With one CPU the workers take turns: each yields after every step, and a
//! shared trace records the order of the steps; equal-priority threads that
//! yield run round-robin, so all four finish step k before any starts k+1.
//! The main thread runs above the workers' priority while it creates them,
//! so that none starts before all four exist.
//!
//! The Zig version of the C++ lesson (golden workspace,
//! test/rpi4b/tutor/02-threads/1cpu/main.cpp), with the same data.

const std = @import("std");
const uos = @import("uos");
const board = @import("board");
const tutor = @import("tutor");

const rtos = uos.rtos;
const Sample = tutor.Sample;

pub const uos_options = board.options(1);

const seed: u32 = 2026;
const n_workers = 4;
const per_region = 6;
const per_worker = 3 * per_region;
const n_steps = 4; // built, checked, sorted, measured

// The data segment: each worker's slice (non-zero default ids: .data).
var g_data: [n_workers][per_region]Sample = @splat(@splat(.{}));

// Two workers run on static stacks (in .bss); the other two on stacks the
// kernel allocates from the heap.
var g_stacks: [2][4096]uos.port.StackElement align(16) = undefined;

const WorkerResult = struct {
    checksum: u32 = 0,
    max_value: i32 = -1,
    max_id: u32 = 0,
    count: usize = 0,
    placed_ok: bool = false,
    heap_ok: bool = false,
};
var g_results: [n_workers]WorkerResult = @splat(.{});

// The order in which the workers' steps ran.
const Event = struct { worker: u8, step: u8 };
var g_trace: [n_workers * n_steps]Event = undefined;
var g_trace_len = std.atomic.Value(u32).init(0);

fn trace(w: usize, step: u8) void {
    const i = g_trace_len.fetchAdd(1, .monotonic);
    if (i < g_trace.len) g_trace[i] = .{ .worker = @intCast(w), .step = step };
}

fn worker(arg: ?*anyopaque) ?*anyopaque {
    const w: usize = @intFromPtr(arg);
    const self = rtos.this_thread.thread();
    const gpa = uos.memory.allocator();
    const r = &g_results[w];
    const first: u32 = @intCast(100 * w);

    // Step 0: build 6 samples in each region, in this worker's own list.
    var local: [per_region]Sample = undefined; // this thread's stack
    var heap: [per_region]*Sample = undefined;
    var list: tutor.SampleList = .{};
    var id: u32 = first;
    for (&local) |*s| {
        s.init(id, tutor.generate(seed, id), .stack);
        list.push(s);
        id += 1;
    }
    for (&g_data[w]) |*s| {
        s.init(id, tutor.generate(seed, id), .data);
        list.push(s);
        id += 1;
    }
    var n_heap: usize = 0;
    for (&heap) |*p| {
        const s = gpa.create(Sample) catch break;
        s.init(id, tutor.generate(seed, id), .heap);
        list.push(s);
        p.* = s;
        n_heap += 1;
        id += 1;
    }
    trace(w, 0);
    rtos.this_thread.yield();

    // Step 1: every sample where it claims, in this worker's stack for the
    // stack ones.
    r.placed_ok = true;
    var it = list.head;
    while (it) |s| : (it = s.next) {
        if (!tutor.placed(s, self)) r.placed_ok = false;
    }
    r.count = list.count();
    trace(w, 1);
    rtos.this_thread.yield();

    // Step 2: sort.
    tutor.sortList(&list);
    trace(w, 2);
    rtos.this_thread.yield();

    // Step 3: the maximum and the checksum; the heap samples freed.
    const m = tutor.maxOf(list);
    r.checksum = tutor.checksum(list);
    r.max_value = if (m) |x| x.value else -1;
    r.max_id = if (m) |x| x.id else 0;
    for (heap[0..n_heap]) |p| {
        _ = list.unlink(p);
        gpa.destroy(p);
    }
    r.heap_ok = n_heap == per_region and list.count() == 2 * per_region;
    trace(w, 3);

    return r; // join() hands this back to the main thread
}

var g_names: [n_workers][3:0]u8 = undefined;

pub fn main() void {
    board.uart.init();
    rtos.run(osMain);
}

fn osMain() void {
    const gpa = uos.memory.allocator();

    tutor.printBanner("02 threads");
    board.console("Lesson 02, one CPU: {d} worker threads, {d} samples each in 3 regions.\n", .{ n_workers, per_worker });
    tutor.printRegions();
    const heap0 = tutor.heapBytes();

    // ---- Create the workers: two on static stacks, two on heap stacks.
    //
    // The main thread runs above the workers' priority while it creates them,
    // so that none starts before all four exist; at the workers' own priority
    // each would take its turn as soon as it was created, the main thread
    // being one more participant in the round-robin. It blocks in join()
    // afterwards, so it never competes with them.
    rtos.this_thread.thread().setPriority(rtos.priority.above_normal) catch {};
    board.console("\n-- creating the workers (main at above_normal, workers at normal)\n", .{});
    var th: [n_workers]*rtos.Thread = undefined;
    for (0..n_workers) |w| {
        g_names[w] = .{ 'w', '0' + @as(u8, @intCast(w)), 0 };
        var attr: rtos.Thread.Attributes = .{ .priority = rtos.priority.normal };
        if (w < 2) attr.stack = &g_stacks[w] else attr.stack_size_bytes = 32 * 1024; // allocated from the heap
        th[w] = rtos.Thread.create(gpa, g_names[w][0..2 :0], worker, @ptrFromInt(w), attr) catch {
            _ = tutor.check(false, "cannot create worker {d}", .{w});
            tutor.finish("");
        };
        board.console("  {s}: stack {x:0>8} .. {x:0>8} ({s})\n", .{
            g_names[w][0..2],                                    @intFromPtr(th[w].context.stack.bottom()),
            @intFromPtr(th[w].context.stack.top()), if (w < 2) "static, .bss" else "allocated, heap",
        });
    }

    // ---- Wait for each, and take its result.
    var joined = true;
    var returned = true;
    for (th, 0..) |t, w| {
        const ret = t.join() catch blk: {
            joined = false;
            break :blk null;
        };
        if (ret != @as(?*anyopaque, @ptrCast(&g_results[w]))) returned = false;
    }
    _ = tutor.check(joined, "the 4 workers joined", .{});
    _ = tutor.check(returned, "each join() returned its worker's result", .{});

    // ---- The order of the steps: round-robin.
    board.console("\n-- the trace (worker:step)\n ", .{});
    const len = g_trace_len.load(.monotonic);
    var round_robin = len == g_trace.len;
    for (g_trace[0..@min(len, g_trace.len)], 0..) |e, i| {
        board.console(" w{d}:{d}", .{ e.worker, e.step });
        if (e.step != i / n_workers) round_robin = false;
    }
    board.console("\n", .{});
    _ = tutor.check(round_robin, "round-robin: every worker finished step k before any started k+1", .{});

    // ---- The results.
    board.console("\n-- the results\n", .{});
    var merged_value: i32 = -1;
    var merged_id: u32 = 0;
    var want_value: i32 = -1;
    var want_id: u32 = 0;
    var all_exact = true;
    for (g_results, 0..) |r, w| {
        const e = tutor.reference(seed, @intCast(100 * w), per_worker);
        const exact = r.count == per_worker and r.placed_ok and r.heap_ok and
            r.checksum == e.sorted_checksum and r.max_value == e.max_value and r.max_id == e.max_id;
        board.console("  w{d}: {d} samples, checksum {x:0>8}, max {d} (#{d}) {s}\n", .{ w, r.count, r.checksum, r.max_value, r.max_id, if (exact) "ok" else "BAD" });
        if (!exact) all_exact = false;
        if (r.max_value > merged_value or (r.max_value == merged_value and r.max_id < merged_id)) {
            merged_value = r.max_value;
            merged_id = r.max_id;
        }
        if (e.max_value > want_value or (e.max_value == want_value and e.max_id < want_id)) {
            want_value = e.max_value;
            want_id = e.max_id;
        }
    }
    _ = tutor.check(all_exact, "every worker's samples placed, sorted, checksum and max exact", .{});
    _ = tutor.check(merged_value == want_value and merged_id == want_id, "merged max {d} (#{d}), expected {d} (#{d})", .{ merged_value, merged_id, want_value, want_id });

    // ---- The threads destroyed: their objects and the heap stacks returned.
    for (th) |t| t.destroy();
    _ = tutor.check(tutor.heapBytes() == heap0, "heap back to {d} B (threads, heap stacks, samples)", .{heap0});

    tutor.finish("4 threads, 72 samples in 3 regions, joined, round-robin, results exact, one CPU");
}
