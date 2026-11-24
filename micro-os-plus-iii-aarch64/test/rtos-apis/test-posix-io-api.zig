//! rtos-apis, part 4: the POSIX I/O devices (the C++ test-posix-io-api.cpp),
//! ported to `uos.io.devices`:
//!
//!   char_device_implementable<my_char_impl>   a CharDevice whose operations
//!                                             fail, as my_char_impl's do
//!   block_device_lockable<my_block_impl,      a 5 x 512-byte block device
//!     rtos::mutex>                            in RAM (0xFF-filled), behind a
//!                                             LockedBlockDevice
//!   block_device_partition_implementable      Partition p1 (unlocked)
//!   block_device_partition_lockable           Partition p2 behind a
//!                                             LockedBlockDevice
//!   file_descriptors_manager{5}               FileDescriptors(5)
//!
//! The C++ part checks with assert(); here each check is counted and a
//! failure makes the part return non-zero.

const std = @import("std");
const uos = @import("uos");
const rtos = uos.rtos;
const devices = uos.io.devices;
const trace = uos.trace;
const printf = trace.print;

const test_name = "Test POSIX I/O";

var failures: u32 = 0;

fn check(ok: bool, what: []const u8) void {
    if (!ok) {
        failures += 1;
        printf("FAILED: {s}\n", .{what});
    }
}

// ---- my_char_impl -----------------------------------------------------------

const MyChar = struct {
    buf: []u8,

    fn init(self: *MyChar, buf: []u8, variant: u8) void {
        self.* = .{ .buf = buf };
        trace.print("my_char_impl()=@{*} {d}\n", .{ self, variant });
    }

    fn deinit(self: *MyChar) void {
        trace.print("~my_char_impl() @{*}\n", .{self});
    }

    fn device(self: *MyChar, name: []const u8) devices.Device {
        return .{ .name = name, .kind = .{ .char = .{ .ptr = self, .vtable = &.{
            .read = read,
            .write = write,
            .open = open,
            .close = close,
            .ioctl = ioctl,
        } } } };
    }

    // As my_char_impl: every operation fails.
    fn open(_: *anyopaque) devices.Error!void {
        return error.InputOutput;
    }
    fn read(_: *anyopaque, _: []u8) devices.Error!usize {
        return error.InputOutput;
    }
    fn write(_: *anyopaque, _: []const u8) devices.Error!usize {
        return error.InputOutput;
    }
    fn ioctl(_: *anyopaque, _: u32, _: usize) devices.Error!usize {
        return error.Unsupported;
    }
    fn close(_: *anyopaque) void {}
};

// ---- my_block_impl -------------------------------------------------------------

const MyBlock = struct {
    disk: devices.RamDisk,

    fn init(self: *MyBlock, gpa: std.mem.Allocator, bsize: usize, nblocks: usize) !void {
        trace.print("my_block_impl::my_block_impl()=@{*}\n", .{self});
        const arena = try gpa.alloc(u8, nblocks * bsize);
        @memset(arena, 0xFF);
        self.disk = .{ .storage = arena, .block_size = bsize };
    }

    fn deinit(self: *MyBlock, gpa: std.mem.Allocator) void {
        trace.print("my_block_impl::~my_block_impl() @{*}\n", .{self});
        gpa.free(self.disk.storage);
    }
};

var cbuf: [4]u8 = undefined;
var mc: MyChar = undefined;
var mc2: MyChar = undefined;

var mx1: rtos.Mutex = .{ .name = "mx1" };
var mx2: rtos.Mutex = .{ .name = "mx2" };

var mb_impl: MyBlock = undefined;
var mb: devices.LockedBlockDevice = undefined; // "mb", lockable, mx1
var p1: devices.Partition = undefined; // "mb-p1"
var p2_part: devices.Partition = undefined;
var p2: devices.LockedBlockDevice = undefined; // "mb-p2", lockable, mx2

var fdm: devices.FileDescriptors(5) = .{};

pub fn run(extra: bool) i32 {
    _ = extra;
    failures = 0;
    const gpa = uos.memory.allocator();

    // The static objects of the C++ part, constructed here.
    mc.init(&cbuf, 1);
    mc2.init(&cbuf, 2);
    _ = mc.device("mc");
    _ = mc2.device("mc2");
    mb_impl.init(gpa, 512, 2 + 3) catch {
        check(false, "mb arena");
        return 1;
    };
    mb = .{ .inner = mb_impl.disk.device("mb").asBlock().?, .mutex = &mx1 };
    const mb_dev = mb.device("mb").asBlock().?;

    const buff = gpa.alloc(u8, 512) catch {
        check(false, "buff");
        return 1;
    };
    defer gpa.free(buff);

    var bsz: usize = 0;

    printf("\n{s} - Block device partitions - C++ API\n", .{test_name});
    {
        const bks = mb_dev.numBlocks();
        bsz = mb_dev.blockSize();
        check(bsz > 0, "mb block size");

        const nr = 3;
        p1 = .{ .parent = mb_dev, .first_block = 0, .blocks = bks - nr };
        p2_part = .{ .parent = mb_dev, .first_block = bks - nr, .blocks = nr };
        p2 = .{ .inner = p2_part.device("mb-p2").asBlock().?, .mutex = &mx2 };
    }
    const p1_dev = p1.device("mb-p1").asBlock().?;
    const p2_dev = p2.device("mb-p2").asBlock().?;

    printf("\n{s} - Block device locked - C++ API\n", .{test_name});
    {
        const blocks: usize = @intCast(p2_dev.numBlocks());
        for (0..blocks) |i| {
            if (p2_dev.readBlocks(buff[0..bsz], i)) |_| {} else |_| check(false, "p2 read_block");
            buff[0] = @intCast(i);
            buff[bsz - 1] = @intCast(i);
            if (p2_dev.writeBlocks(buff[0..bsz], i)) |_| {} else |_| check(false, "p2 write_block");
        }
        for (0..blocks) |i| {
            @memset(buff[0..bsz], 0xFF);
            if (p2_dev.readBlocks(buff[0..bsz], i)) |_| {} else |_| check(false, "p2 read_block back");
            check(buff[0] == i, "p2 first byte");
            check(buff[bsz - 1] == i, "p2 last byte");
        }
        // Past the end: must fail.
        check(std.meta.isError(p2_dev.readBlocks(buff[0..bsz], blocks)), "p2 read past the end must fail");
        check(std.meta.isError(p2_dev.writeBlocks(buff[0..bsz], blocks)), "p2 write past the end must fail");
    }

    printf("\n{s} - Block device unlocked - C++ API\n", .{test_name});
    {
        // open()/close() of p1: the Zig block devices need no open; check
        // the partition is usable instead.
        check(p1_dev.numBlocks() == 2, "p1 blocks");
    }

    printf("\n{s} - Block device - intermixed opens - C++ API\n", .{test_name});
    {
        buff[0] = 0xFF;
        if (p2_dev.readBlocks(buff[0..bsz], 0)) |_| {} else |_| check(false, "p2 read_block 0");
        check(buff[0] == 0, "p2 block 0 marker");
    }

    // The file descriptors manager with a char device (the C API section of
    // the C++ part runs only without semihosting syscalls; here the
    // descriptors are exercised directly).
    {
        const fd = fdm.open(mc.device("mc").asChar().?);
        check(std.meta.isError(fd), "my_char open must fail (do_vopen returns -1)");
    }

    mb_impl.deinit(gpa);
    mc2.deinit();
    mc.deinit();
    return if (failures == 0) 0 else 1;
}
