//! tutor-01-bring-up-1cpu -- lesson 01, one CPU (see ../README.md).
//!
//! The kernel is built for one CPU (`board.options(1)`: ncpu 1, smp false,
//! the non-SMP scheduler); cores 1-3 are never started. osMain() runs in the
//! main thread, the only application thread of this lesson. It builds 24
//! samples, 8 in each storage region -- its own stack, the data segment, the
//! heap -- links them in one intrusive list, checks every node lies where it
//! claims, sorts the list, finds the maximum and the checksum, and compares
//! them with the reference computed independently on an array. Then it frees
//! the heap samples and checks the heap is back to its starting level.
//!
//! The Zig version of the C++ lesson (golden workspace,
//! test/rpi4b/tutor/01-bring-up/1cpu/main.cpp), with the same data: it
//! prints the same sorted order, checksum and maximum.

const std = @import("std");
const uos = @import("uos");
const board = @import("board");
const tutor = @import("tutor");

const Sample = tutor.Sample;

pub const uos_options = board.options(1);

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

    tutor.printBanner("01 bring-up");
    board.console("Lesson 01, one CPU: {d} samples in 3 regions, one list, sort and max.\n", .{total});
    tutor.printRegions();
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

    board.console("\n-- the list\n", .{});
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

    tutor.finish("24 samples in 3 regions, sorted, max and checksum exact, one CPU");
}
