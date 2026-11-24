//! tutor-01-bring-up-4cpu -- lesson 01, four CPUs (see ../README.md).
//!
//! The kernel is built for four CPUs (`board.options(4)`: the SMP
//! scheduler). The main thread starts on core 0, pinned there; the lesson
//! then releases cores 1-3, waits for each to join the scheduler, and checks
//! each has its own idle thread. The work is the one-CPU version's,
//! unchanged, still in the main thread on core 0: the same 24 samples in the
//! same 3 regions, the same sorted order, maximum and checksum -- the
//! secondary cores only idle.
//!
//! The Zig version of the C++ lesson (golden workspace,
//! test/rpi4b/tutor/01-bring-up/4cpu/main.cpp), with the same data.

const std = @import("std");
const uos = @import("uos");
const board = @import("board");
const tutor = @import("tutor");

const Sample = tutor.Sample;

pub const uos_options = board.options(4);

const seed: u32 = 2026;
const per_region = 8;
const total = 3 * per_region;

// The data segment: `Sample`'s non-zero default id puts the array in .data.
var g_data: [per_region]Sample = @splat(.{});

pub fn main() void {
    board.uart.init();
    uos.rtos.run(osMain);
}

fn osMain() void {
    const self = uos.rtos.this_thread.thread();
    const gpa = uos.memory.allocator();

    self.setCpuAffinity(1 << 0);
    tutor.printBanner("01 bring-up");
    board.console("Lesson 01, four CPUs: {d} samples in 3 regions, one list, sort and max.\n", .{total});
    tutor.printRegions();

    // ---- New with four CPUs: release cores 1-3 and see them join.
    board.console("\n-- SMP bring-up\n", .{});
    board.console("  main thread on core {d}\n", .{board.cpuSlot()});
    board.smp.startSecondaryCores();
    const waited = board.smp.waitSecondaries(3000);
    board.console("  cores joined after {d} ms: {s}\n", .{ waited, board.smp.joinSummary() });
    _ = tutor.check(board.smp.secondariesJoined(), "cores 1-{d} joined the scheduler", .{uos.config.ncpu - 1});
    var idles = true;
    for (uos.rtos.scheduler.idle_thread_core, 0..) |idle, cpu| {
        board.console("  core {d} idle thread: {s}\n", .{ cpu, if (idle) |t| t.name else "(none)" });
        if (idle == null) idles = false;
    }
    _ = tutor.check(idles, "every core has its idle thread", .{});
    const heap0 = tutor.heapBytes();

    // ---- 8 samples in each region, all in one list.
    var local: [per_region]Sample = undefined; // this thread's stack
    var heap: [per_region]*Sample = undefined;
    var list: tutor.SampleList = .{};
    var id: u32 = 0;
    for (&local) |*s| {
        s.init(id, tutor.generate(seed, id), .stack);
        list.push(s);
        id += 1;
    }
    for (&g_data) |*s| {
        s.init(id, tutor.generate(seed, id), .data);
        list.push(s);
        id += 1;
    }
    for (&heap) |*p| {
        p.* = gpa.create(Sample) catch {
            _ = tutor.check(false, "heap sample #{d}: out of memory", .{id});
            tutor.finish("");
        };
        p.*.init(id, tutor.generate(seed, id), .heap);
        list.push(p.*);
        id += 1;
    }

    board.console("\n-- the list (built on core {d})\n", .{board.cpuSlot()});
    var per: [3]u32 = @splat(0);
    var all_placed = true;
    var it = list.head;
    while (it) |s| : (it = s.next) {
        if (tutor.placed(s, self)) per[@intFromEnum(s.where)] += 1 else all_placed = false;
    }
    _ = tutor.check(list.count() == total, "{d} samples in the list", .{list.count()});
    _ = tutor.check(per[0] == per_region and per[1] == per_region and per[2] == per_region, "{d} on the stack, {d} in .data, {d} on the heap", .{ per[0], per[1], per[2] });
    _ = tutor.check(all_placed, "every sample lies in the region it claims, seal intact", .{});

    // ---- The work.
    tutor.sortList(&list);
    const m = tutor.maxOf(list);
    const c = tutor.checksum(list);
    const e = tutor.reference(seed, 0, total);

    board.console("\n-- sorted (value id region)\n", .{});
    var ascending = true;
    var prev: ?*const Sample = null;
    it = list.head;
    while (it) |s| : (it = s.next) {
        board.console("  {d:>4}  #{d:<2} {s}\n", .{ s.value, s.id, tutor.regionName(s.where) });
        if (prev) |p| {
            if (p.value > s.value) ascending = false;
        }
        prev = s;
    }
    _ = tutor.check(ascending, "the list is in ascending order", .{});
    _ = tutor.check(c == e.sorted_checksum, "checksum {x:0>8}, expected {x:0>8}", .{ c, e.sorted_checksum });
    const mv: i32 = if (m) |x| x.value else -1;
    const mi: u32 = if (m) |x| x.id else 0;
    _ = tutor.check(m != null and mv == e.max_value and mi == e.max_id, "max {d} (#{d}), expected {d} (#{d})", .{ mv, mi, e.max_value, e.max_id });

    // ---- Free the heap samples (out of the list first).
    for (heap) |p| {
        _ = list.unlink(p);
        gpa.destroy(p);
    }
    _ = tutor.check(tutor.heapBytes() == heap0, "heap back to {d} B", .{heap0});

    tutor.finish("24 samples in 3 regions, sorted, max and checksum exact, four CPUs");
}
