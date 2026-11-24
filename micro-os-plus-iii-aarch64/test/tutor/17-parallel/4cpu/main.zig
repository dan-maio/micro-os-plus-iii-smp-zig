//! tutor-17-parallel-4cpu -- lesson 17, four CPUs (see ../README.md).
//!
//! The course's work at its full size: 4096 samples on the heap, sorted
//! (insertion sort on the list, O(n^2)) and their maximum found.
//!
//! Part A, the reference: the whole set as one list, sorted by one thread.
//!
//! Part B, the work split: four workers each link, sort and take the maximum
//! of a quarter of the set; then the main thread merges the four sorted
//! lists into one (by relinking, O(n)) and reduces the four maxima to one.
//! All four workers on one core: whatever is gained here is the algorithm's
//! (four sorts of n/4 cost a quarter of one sort of n), not the CPUs'.
//!
//! With four CPUs (the `four` switch), part C: the same four workers, one on
//! each core. Against part B this is the speed-up of running in parallel;
//! the merge stays serial, and bounds it (Amdahl).
//!
//! Every part's sorted order, checksum and maximum must be those of the
//! independent reference (tutor.reference()).
//!
//! The Zig version of the C++ lesson (golden workspace,
//! test/rpi4b/tutor/17-parallel/4cpu/main.cpp), with the same checks.

const std = @import("std");
const uos = @import("uos");
const board = @import("board");
const tutor = @import("tutor");

const rtos = uos.rtos;
const second_timer = tutor.second_timer;
const Sample = tutor.Sample;
const SampleList = tutor.SampleList;

const four = true;

pub const uos_options = board.options(4);

const seed = 17;
const first_id = 1;
const n = 4096;
const n_workers = 4;
const quarter = n / n_workers;

var g_set: []Sample = &.{}; // the data set, on the heap

// The set's order: by value, then by id (as tutor.sortList()).
fn before(a: *const Sample, b: *const Sample) bool {
    return a.value < b.value or (a.value == b.value and a.id < b.id);
}

// Link samples [first, first + count) into `list`.
fn link(list: *SampleList, first: u32, count: u32) void {
    list.head = null;
    var i = first + count;
    while (i > first) {
        i -= 1;
        list.push(&g_set[i]); // pushed from the end: the list in index order
    }
}

// ---- The workers -------------------------------------------------------------------

const Job = struct {
    first: u32 = 0,
    list: SampleList = .{},
    max: ?*const Sample = null,
    ran_on: u32 = 99,
    start: u32 = 0, // the System Timer's us, common to all cores
    end: u32 = 0,
};

// The start signal: the workers are created first and wait here, so that
// the work is timed apart from creating and joining the threads.
var g_go: rtos.Semaphore = .counting("go", n_workers, 0);

fn worker(arg: ?*anyopaque) ?*anyopaque {
    const j: *Job = @ptrCast(@alignCast(arg.?));
    j.ran_on = board.cpuSlot();
    g_go.wait() catch {};
    j.start = second_timer.nowUs();
    link(&j.list, j.first, quarter);
    tutor.sortList(&j.list);
    j.max = tutor.maxOf(j.list);
    j.end = second_timer.nowUs();
    return null;
}

// Merge the workers' sorted lists into one, by relinking: each step takes
// the smallest of the four heads.
fn merge(jobs: *[n_workers]Job, out: *SampleList) void {
    var heads: [n_workers]?*Sample = undefined;
    for (0..n_workers) |k| heads[k] = jobs[k].list.head;
    var tail: *?*Sample = &out.head;
    while (true) {
        var best: ?usize = null;
        for (0..n_workers) |k| {
            if (heads[k]) |h| {
                if (best == null or before(h, heads[best.?].?)) best = k;
            }
        }
        const b = best orelse break;
        const node = heads[b].?;
        tail.* = node;
        tail = &node.next;
        heads[b] = node.next;
    }
    tail.* = null;
}

// The maxima reduced to one: the largest value, of equals the lowest id.
fn reduce(jobs: *const [n_workers]Job) ?*const Sample {
    var m: ?*const Sample = null;
    for (jobs) |*j| {
        if (j.max) |s| {
            if (m == null or s.value > m.?.value or (s.value == m.?.value and s.id < m.?.id)) m = s;
        }
    }
    return m;
}

const SplitResult = struct {
    sort_us: u32, // from the start signal to the last worker's end
    threads_us: u32, // creating the four threads, and joining them after the work
    merge_us: u32, // the merge and the reduction
    cores_ok: bool,
    ok: bool,
};

// Part B (all workers on `cores[k] = 0`) or C (one per core).
fn runSplit(what: []const u8, cores: [n_workers]u32, want: tutor.Expected) SplitResult {
    const gpa = uos.memory.allocator();
    var jobs: [n_workers]Job = .{ .{}, .{}, .{}, .{} };
    var th: [n_workers]?*rtos.Thread = .{ null, null, null, null };
    const t_create = second_timer.nowUs();
    for (0..n_workers) |k| {
        jobs[k].first = @intCast(k * quarter);
        // Below the main thread, which starts them all before any runs on
        // its core: a thread that makes one of its own priority ready on its
        // own core gives it the CPU (as a yield does).
        var attr: rtos.Thread.Attributes = .{ .stack_size_bytes = 8 * 1024, .priority = rtos.priority.below_normal };
        if (four) attr.cpu_affinity = @as(u32, 1) << @intCast(cores[k]);
        th[k] = rtos.Thread.create(gpa, "worker", worker, &jobs[k], attr) catch null;
    }
    const t_go = second_timer.nowUs();
    for (0..n_workers) |_| g_go.post() catch {};
    for (0..n_workers) |k| {
        if (th[k]) |t| {
            _ = t.join() catch null;
            t.destroy();
        }
    }
    const t1 = second_timer.nowUs();
    var t_end = t_go;
    for (jobs) |j| {
        if (@as(i32, @bitCast(j.end -% t_end)) > 0) t_end = j.end;
    }
    var all: SampleList = .{};
    merge(&jobs, &all);
    const m = reduce(&jobs);
    const t2 = second_timer.nowUs();

    var r: SplitResult = .{ .sort_us = t_end -% t_go, .threads_us = (t_go -% t_create) +% (t1 -% t_end), .merge_us = t2 -% t1, .cores_ok = true, .ok = false };
    for (0..n_workers) |k| {
        if (four) r.cores_ok = r.cores_ok and jobs[k].ran_on == cores[k];
        const mx = jobs[k].max.?;
        board.console("  worker {d}: samples {d:>4}..{d:>4}, core {d}, ran {d:>6} .. {d:>6} us after the start, its max {d} (id {d})\n", .{ k, jobs[k].first + first_id, jobs[k].first + first_id + quarter - 1, jobs[k].ran_on, jobs[k].start -% t_go, jobs[k].end -% t_go, mx.value, mx.id });
    }
    const sum = tutor.checksum(all);
    r.ok = all.count() == n and sum == want.sorted_checksum and m != null and m.?.value == want.max_value and m.?.id == want.max_id and tutor.maxOf(all) == m;
    board.console("  {s}: sorts {d} us, merge + reduction {d} us (the threads' creation and join: {d} us more);\n", .{ what, r.sort_us, r.merge_us, r.threads_us });
    board.console("  {d} samples, checksum {x:0>8}, max {d} (id {d})\n", .{ all.count(), sum, m.?.value, m.?.id });
    return r;
}

// a / b with two decimals, as "x.yy" (integers only).
const Ratio = struct {
    buf: [16]u8 = undefined,
    len: usize = 0,
    fn text(self: *const Ratio) []const u8 {
        return self.buf[0..self.len];
    }
};

fn ratio(a: u64, b: u64) Ratio {
    const r: u64 = if (b != 0) (100 * a + b / 2) / b else 0;
    var out: Ratio = .{};
    const t = std.fmt.bufPrint(&out.buf, "{d}.{d:0>2}", .{ r / 100, r % 100 }) catch out.buf[0..0];
    out.len = t.len;
    return out;
}

// ---- The lesson ------------------------------------------------------------------

pub fn main() void {
    board.uart.init();
    rtos.run(osMain);
}

fn osMain() void {
    const gpa = uos.memory.allocator();
    const self = rtos.this_thread.thread();

    if (four) self.setCpuAffinity(1 << 0);
    tutor.printBanner("17 parallel");
    board.console("Lesson 17, {s}: the work split, merged, measured.\n", .{if (four) "four CPUs" else "one CPU"});
    tutor.printRegions();
    if (four) {
        // ---- Release cores 1-3 (as in lesson 01).
        board.smp.startSecondaryCores();
        const waited = board.smp.waitSecondaries(3000);
        board.console("  cores joined after {d} ms: {s}\n", .{ waited, board.smp.joinSummary() });
        _ = tutor.check(board.smp.secondariesJoined(), "cores 1-{d} joined the scheduler", .{uos.config.ncpu - 1});
    }

    const heap0 = tutor.heapBytes();
    const want = tutor.reference(seed, first_id, n);
    board.console("\n  the reference (an array, no list code): checksum {x:0>8}, max {d} (id {d})\n", .{ want.sorted_checksum, want.max_value, want.max_id });

    g_set = gpa.alloc(Sample, n) catch {
        _ = tutor.check(false, "the data set allocated", .{});
        tutor.finish("");
    };
    var placed_ok: u32 = 0;
    for (g_set, 0..) |*s, i| {
        const id: u32 = first_id + @as(u32, @intCast(i));
        s.init(id, tutor.generate(seed, id), .heap);
        if (tutor.placed(s, self)) placed_ok += 1;
    }
    board.console("  {d} samples on the heap, {d} in place\n", .{ n, placed_ok });
    _ = tutor.check(placed_ok == n, "every sample is on the heap, sealed", .{});

    // ---- Part A.
    board.console("\n-- part A: the reference time: {d} samples, one list, one thread\n", .{n});
    var t_a: u32 = 0;
    {
        var list: SampleList = .{};
        link(&list, 0, n);
        const t0 = second_timer.nowUs();
        tutor.sortList(&list);
        const m = tutor.maxOf(list).?;
        t_a = second_timer.nowUs() -% t0;
        const sum = tutor.checksum(list);
        board.console("  sort + max {d} us; checksum {x:0>8}, max {d} (id {d})\n", .{ t_a, sum, m.value, m.id });
        _ = tutor.check(list.count() == n and sum == want.sorted_checksum and m.value == want.max_value and m.id == want.max_id, "one list: sorted order and max are the reference's", .{});
    }

    // ---- Part B.
    board.console("\n-- part B: split in four, the workers all on {s}; merged, maxima reduced\n", .{if (four) "core 0" else "the one CPU"});
    const b = runSplit("split", .{ 0, 0, 0, 0 }, want);
    const rb = ratio(t_a, b.sort_us + b.merge_us);
    board.console("  part A / part B = {s}: four sorts of {d} cost about a quarter of one of {d} (the algorithm, not the CPUs)\n", .{ rb.text(), quarter, n });
    _ = tutor.check(b.ok, "split and merged: the reference's order, checksum and max", .{});
    if (four) _ = tutor.check(b.cores_ok, "the four workers ran on core 0", .{});
    // n^2 / (4 (n/4)^2) = 4; the bound leaves room for the merge and the threads.
    const b_min: u64 = if (tutor.onHardware()) 300 else 150; // in hundredths
    _ = tutor.check(100 * @as(u64, t_a) >= b_min * (b.sort_us + b.merge_us), "the split alone is at least {d}.{d:0>2}x faster (O(n^2) sort)", .{ b_min / 100, b_min % 100 });

    if (four) {
        // ---- Part C.
        board.console("\n-- part C: the same four workers, one on each core\n", .{});
        const c = runSplit("parallel", .{ 0, 1, 2, 3 }, want);
        const rc = ratio(b.sort_us, c.sort_us);
        const rs = ratio(b.sort_us + b.merge_us, c.sort_us + c.merge_us);
        const ra = ratio(b.sort_us + b.merge_us, b.sort_us / n_workers + b.merge_us);
        board.console("  the sorts: {s} x faster on four cores; with the merge: {s} x (Amdahl's bound for this merge: {s} x)\n", .{ rc.text(), rs.text(), ra.text() });
        const rt = ratio(t_a, c.sort_us + c.merge_us);
        const rw = ratio(b.sort_us + b.merge_us + b.threads_us, c.sort_us + c.merge_us + c.threads_us);
        board.console("  counting the threads' creation and join too: {s} x; part A / part C = {s}\n", .{ rw.text(), rt.text() });
        _ = tutor.check(c.ok, "in parallel: the reference's order, checksum and max", .{});
        _ = tutor.check(c.cores_ok, "worker k ran on core k", .{});
        const c_min: u64 = if (tutor.onHardware()) 300 else 120;
        _ = tutor.check(100 * @as(u64, b.sort_us) >= c_min * c.sort_us, "the four sorts at least {d}.{d:0>2}x faster on four cores", .{ c_min / 100, c_min % 100 });
    }

    gpa.free(g_set);
    g_set = &.{};
    const heap1 = tutor.heapBytes();
    board.console("\n  heap: {d} B before the set, {d} B after\n", .{ heap0, heap1 });
    _ = tutor.check(heap1 == heap0, "the heap is back to its level", .{});

    tutor.finish(if (four) "4096 samples sorted split and in parallel, as the reference; the speed-ups measured; four CPUs" else "4096 samples sorted whole and split, as the reference; one CPU");
}
