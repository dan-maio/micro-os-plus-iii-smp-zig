//! flatfs-test -- appending to a file that was created empty (the C++
//! test/native/flatfs-test).
//!
//! write_file() gives a zero-length file no extent (start = 0); an append
//! must then allocate one, not grow a wrapped-around extent over the
//! superblock and the file table. Checks: the append succeeds, the file
//! reads back exactly, a file written beside it is untouched, and the volume
//! still mounts with both files.
//!
//! The card is the board's host file (disk.img in the current folder, or
//! $UOS_SD_IMAGE). Difference from C++: the kernel prints its startup
//! banner.

const std = @import("std");
const uos = @import("uos");
const board = @import("board");
const sd = @import("sd");
const flatfs = @import("flatfs");
const rtos = uos.rtos;

pub const uos_options = board.options(4);

var g_card: sd.SdCard = .{};
var g_fs: flatfs.FlatFs = .{};

const other_size = 1500;
const append_size = 128 * flatfs.block_size; // 64 KiB

var g_other: [other_size]u8 = undefined;
var g_data: [append_size]u8 = undefined;
var g_back: [append_size + flatfs.block_size]u8 = undefined;

var g_failures: u32 = 0;

fn say(s: []const u8) void {
    board.uart.puts(s);
}

fn check(cond: bool, what: []const u8) void {
    board.uart.print("  {s:<52} {s}\n", .{ what, if (cond) "ok" else "FAIL" });
    if (!cond) g_failures += 1;
}

fn ok(r: flatfs.Error!void) bool {
    r catch return false;
    return true;
}

fn sameFile(fs: *flatfs.FlatFs, name: []const u8, want: []const u8) bool {
    const got = fs.readFile(name, &g_back) catch return false;
    return got == want.len and std.mem.eql(u8, g_back[0..got], want);
}

pub fn main() void {
    board.uart.init();
    rtos.run(osMain);
}

fn osMain() void {
    say("\nflatfs-test: append to a file created empty\n");

    for (&g_other, 0..) |*b, i| b.* = @truncate(0xA5 ^ i);
    for (&g_data, 0..) |*b, i| b.* = @truncate(i * 7 + (i >> 9));

    if (!g_card.init()) {
        say("  SD init failed\nRESULT: FAIL\n");
        board.hw_result.fail();
    }
    check(ok(g_fs.format(&g_card)), "format");

    check(ok(g_fs.writeFile("log", &.{})), "write_file(log, 0 bytes)");
    check(ok(g_fs.writeFile("other", &g_other)), "write_file(other, 1500 bytes)");

    const r: ?flatfs.Error = if (g_fs.appendFile("log", &g_data)) |_| null else |err| err;
    board.uart.print("  append_file(log, {d} bytes) -> {s}\n", .{ append_size, flatfs.resultStr(r) });
    check(r == null, "append to the empty file succeeds");

    const size = g_fs.fileSize("log") catch 0;
    check(size == append_size, "log size is the appended size");
    check(sameFile(&g_fs, "log", &g_data), "log reads back exactly");
    check(sameFile(&g_fs, "other", &g_other), "other is untouched");

    // The superblock and the file table survive: a fresh mount sees both.
    var again: flatfs.FlatFs = .{};
    check(ok(again.mount(&g_card)), "volume mounts again");
    const st = again.stat() catch flatfs.FlatFs.Stat{ .total_sectors = 0, .free_sectors = 0, .file_count = 0 };
    check(st.file_count == 2, "two files after remount");
    check(sameFile(&again, "log", &g_data), "log reads back after remount");
    check(sameFile(&again, "other", &g_other), "other reads back after remount");

    const pass = g_failures == 0;
    say(if (pass) "RESULT: PASS\n" else "RESULT: FAIL\n");
    if (pass) board.hw_result.ok() else board.hw_result.fail();
}
