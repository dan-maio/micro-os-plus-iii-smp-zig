//! Devices (`os::posix` I/O: `char_device`, `block_device`,
//! `block_device_partition`, `device_registry`, `file_descriptors_manager`,
//! `tty`).
//!
//! The C++ class hierarchy (`io` -> `device` -> `char_device`/`block_device`,
//! each split into an interface and an `_impl`) becomes Zig interfaces: a
//! type-erased pointer plus a vtable, the same shape as `std.mem.Allocator`
//! and `std.Io.Writer`. Every device opens into the standard streams, so all
//! of `std.Io.Reader`/`std.Io.Writer` (formatting, line reading, `streamRemaining`,
//! ...) works on it:
//!
//! ```zig
//! var registry: uos.io.devices.Registry(4) = .{};
//! var tty: uos.io.devices.TraceTty = .{};
//! try registry.add(tty.device("tty"));
//!
//! const dev = registry.find("/dev/tty").?;
//! var buf: [64]u8 = undefined;
//! var w = dev.char.writer(&buf);
//! try w.interface.print("hello {d}\n", .{42});
//! try w.interface.flush();
//! ```
//!
//! The file systems of the C++ edition (FatFS behind `file_system`) are not
//! part of this layer; a block device is the place to mount one.

const std = @import("std");
const assert = std.debug.assert;

const interrupts = @import("../rtos/interrupts.zig");
const scheduler = @import("../rtos/scheduler.zig");
const lists = @import("../rtos/lists.zig");
const clocks = @import("../rtos/clocks.zig");
const Mutex = @import("../rtos/mutex.zig").Mutex;
const trace = @import("../trace.zig");

pub const Error = error{
    /// EIO
    InputOutput,
    /// EBADF
    BadFile,
    /// ENOTTY / ENOTSUP
    Unsupported,
    /// EINVAL
    InvalidArgument,
    /// EAGAIN, for a non blocking device
    WouldBlock,
    /// ENOSPC
    NoSpaceLeft,
    /// EMFILE
    TooManyOpenFiles,
    /// ENOENT
    NotFound,
};

// ----------------------------------------------------------------------------
// Character devices.

/// A character device (`char_device`): a byte stream.
pub const CharDevice = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Read at most `buf.len` bytes; 0 means end of stream.
        read: *const fn (ptr: *anyopaque, buf: []u8) Error!usize,
        /// Write some of `bytes`; returns how many.
        write: *const fn (ptr: *anyopaque, bytes: []const u8) Error!usize,
        open: ?*const fn (ptr: *anyopaque) Error!void = null,
        close: ?*const fn (ptr: *anyopaque) void = null,
        /// Device specific control requests (`ioctl`).
        ioctl: ?*const fn (ptr: *anyopaque, request: u32, arg: usize) Error!usize = null,
    };

    pub fn read(d: CharDevice, buf: []u8) Error!usize {
        return d.vtable.read(d.ptr, buf);
    }

    pub fn write(d: CharDevice, bytes: []const u8) Error!usize {
        return d.vtable.write(d.ptr, bytes);
    }

    pub fn writeAll(d: CharDevice, bytes: []const u8) Error!void {
        var rest = bytes;
        while (rest.len > 0) rest = rest[try d.write(rest)..];
    }

    pub fn ioctl(d: CharDevice, request: u32, arg: usize) Error!usize {
        const f = d.vtable.ioctl orelse return error.Unsupported;
        return f(d.ptr, request, arg);
    }

    /// An `std.Io.Writer` on the device.
    pub fn writer(d: CharDevice, buffer: []u8) Writer {
        return .{ .device = d, .interface = .{ .vtable = &Writer.vtable, .buffer = buffer } };
    }

    /// An `std.Io.Reader` on the device.
    pub fn reader(d: CharDevice, buffer: []u8) Reader {
        return .{ .device = d, .interface = .{ .vtable = &Reader.vtable, .buffer = buffer, .seek = 0, .end = 0 } };
    }

    pub const Writer = struct {
        device: CharDevice,
        err: ?Error = null,
        interface: std.Io.Writer,

        const vtable: std.Io.Writer.VTable = .{ .drain = drain };

        fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
            const self: *Writer = @alignCast(@fieldParentPtr("interface", w));
            self.device.writeAll(w.buffered()) catch |e| {
                self.err = e;
                return error.WriteFailed;
            };
            w.end = 0;
            var n: usize = 0;
            for (data[0 .. data.len - 1]) |bytes| {
                self.device.writeAll(bytes) catch |e| {
                    self.err = e;
                    return error.WriteFailed;
                };
                n += bytes.len;
            }
            const pattern = data[data.len - 1];
            for (0..splat) |_| self.device.writeAll(pattern) catch |e| {
                self.err = e;
                return error.WriteFailed;
            };
            return n + pattern.len * splat;
        }
    };

    pub const Reader = struct {
        device: CharDevice,
        err: ?Error = null,
        interface: std.Io.Reader,

        const vtable: std.Io.Reader.VTable = .{ .stream = stream };

        fn stream(r: *std.Io.Reader, w: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
            const self: *Reader = @alignCast(@fieldParentPtr("interface", r));
            const dest = limit.slice(try w.writableSliceGreedy(1));
            const n = self.device.read(dest) catch |e| {
                self.err = e;
                return error.ReadFailed;
            };
            if (n == 0) return error.EndOfStream;
            w.advance(n);
            return n;
        }
    };
};

/// The trace channel as a write-only tty (`/dev/tty`, like the C++ trace
/// backed stdout).
pub const TraceTty = struct {
    pub fn device(self: *TraceTty, name: []const u8) Device {
        return .{ .name = name, .kind = .{ .char = .{ .ptr = self, .vtable = &.{
            .read = read,
            .write = write,
        } } } };
    }

    fn read(_: *anyopaque, _: []u8) Error!usize {
        return 0;
    }

    fn write(_: *anyopaque, bytes: []const u8) Error!usize {
        trace.write(bytes);
        return bytes.len;
    }
};

/// A byte FIFO between an interrupt handler (or a thread) and readers
/// that block until data arrives: the usual UART receive path. `put()` is
/// ISR safe; `read()` blocks, honouring `timeout` (ticks, null = forever).
pub fn RingBuffer(comptime capacity: usize) type {
    return struct {
        buffer: [capacity]u8 = undefined,
        head: usize = 0,
        len: usize = 0,
        readers: lists.WaitingThreadsList = .{},
        timeout: ?clocks.Duration = null,
        /// Bytes dropped because the buffer was full.
        overruns: usize = 0,

        const Self = @This();

        /// Store one byte; from an interrupt handler too.
        pub fn put(self: *Self, byte: u8) void {
            {
                const cs = interrupts.CriticalSection.enter();
                defer cs.exit();
                if (self.len == capacity) {
                    self.overruns += 1;
                    return;
                }
                self.buffer[(self.head + self.len) % capacity] = byte;
                self.len += 1;
            }
            _ = self.readers.resumeOne();
        }

        const Request = struct { self: *Self, buf: []u8 };

        fn tryRead(r: Request) ?usize {
            const s = r.self;
            if (s.len == 0) return null;
            const n = @min(r.buf.len, s.len);
            for (r.buf[0..n]) |*b| {
                b.* = s.buffer[s.head];
                s.head = (s.head + 1) % capacity;
            }
            s.len -= n;
            return n;
        }

        pub fn device(self: *Self, name: []const u8) Device {
            return .{ .name = name, .kind = .{ .char = .{ .ptr = self, .vtable = &.{
                .read = read,
                .write = write,
            } } } };
        }

        fn read(ptr: *anyopaque, buf: []u8) Error!usize {
            const self: *Self = @ptrCast(@alignCast(ptr));
            if (buf.len == 0) return 0;
            return scheduler.waitFor(usize, &self.readers, &clocks.sysclock, self.timeout, Request{ .self = self, .buf = buf }, tryRead) catch |err| switch (err) {
                error.TimedOut => error.WouldBlock,
                else => error.InputOutput,
            };
        }

        /// Writing feeds the buffer (a loopback), handy for tests.
        fn write(ptr: *anyopaque, bytes: []const u8) Error!usize {
            const self: *Self = @ptrCast(@alignCast(ptr));
            for (bytes) |b| self.put(b);
            return bytes.len;
        }
    };
}

// ----------------------------------------------------------------------------
// Block devices.

/// A block device (`block_device`): fixed size blocks, random access.
pub const BlockDevice = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        read_blocks: *const fn (ptr: *anyopaque, buf: []u8, first_block: u64) Error!void,
        write_blocks: *const fn (ptr: *anyopaque, buf: []const u8, first_block: u64) Error!void,
        block_size: *const fn (ptr: *anyopaque) usize,
        num_blocks: *const fn (ptr: *anyopaque) u64,
        sync: ?*const fn (ptr: *anyopaque) Error!void = null,
    };

    pub fn blockSize(d: BlockDevice) usize {
        return d.vtable.block_size(d.ptr);
    }

    pub fn numBlocks(d: BlockDevice) u64 {
        return d.vtable.num_blocks(d.ptr);
    }

    /// Read whole blocks; `buf.len` must be a multiple of the block size.
    pub fn readBlocks(d: BlockDevice, buf: []u8, first_block: u64) Error!void {
        try d.check(buf.len, first_block);
        return d.vtable.read_blocks(d.ptr, buf, first_block);
    }

    pub fn writeBlocks(d: BlockDevice, buf: []const u8, first_block: u64) Error!void {
        try d.check(buf.len, first_block);
        return d.vtable.write_blocks(d.ptr, buf, first_block);
    }

    pub fn sync(d: BlockDevice) Error!void {
        if (d.vtable.sync) |f| return f(d.ptr);
    }

    fn check(d: BlockDevice, len: usize, first_block: u64) Error!void {
        const bs = d.blockSize();
        if (len % bs != 0) return error.InvalidArgument;
        if (first_block + len / bs > d.numBlocks()) return error.InvalidArgument;
    }
};

/// A block device in RAM.
pub const RamDisk = struct {
    storage: []u8,
    block_size: usize = 512,

    pub fn device(self: *RamDisk, name: []const u8) Device {
        return .{ .name = name, .kind = .{ .block = .{ .ptr = self, .vtable = &.{
            .read_blocks = readBlocks,
            .write_blocks = writeBlocks,
            .block_size = blockSize,
            .num_blocks = numBlocks,
        } } } };
    }

    fn readBlocks(ptr: *anyopaque, buf: []u8, first: u64) Error!void {
        const self: *RamDisk = @ptrCast(@alignCast(ptr));
        const off: usize = @intCast(first * self.block_size);
        @memcpy(buf, self.storage[off..][0..buf.len]);
    }

    fn writeBlocks(ptr: *anyopaque, buf: []const u8, first: u64) Error!void {
        const self: *RamDisk = @ptrCast(@alignCast(ptr));
        const off: usize = @intCast(first * self.block_size);
        @memcpy(self.storage[off..][0..buf.len], buf);
    }

    fn blockSize(ptr: *anyopaque) usize {
        const self: *RamDisk = @ptrCast(@alignCast(ptr));
        return self.block_size;
    }

    fn numBlocks(ptr: *anyopaque) u64 {
        const self: *RamDisk = @ptrCast(@alignCast(ptr));
        return self.storage.len / self.block_size;
    }
};

/// A window of another block device (`block_device_partition`).
pub const Partition = struct {
    parent: BlockDevice,
    first_block: u64,
    blocks: u64,

    pub fn device(self: *Partition, name: []const u8) Device {
        return .{ .name = name, .kind = .{ .block = .{ .ptr = self, .vtable = &.{
            .read_blocks = readBlocks,
            .write_blocks = writeBlocks,
            .block_size = blockSize,
            .num_blocks = numBlocks,
        } } } };
    }

    fn readBlocks(ptr: *anyopaque, buf: []u8, first: u64) Error!void {
        const self: *Partition = @ptrCast(@alignCast(ptr));
        return self.parent.readBlocks(buf, self.first_block + first);
    }

    fn writeBlocks(ptr: *anyopaque, buf: []const u8, first: u64) Error!void {
        const self: *Partition = @ptrCast(@alignCast(ptr));
        return self.parent.writeBlocks(buf, self.first_block + first);
    }

    fn blockSize(ptr: *anyopaque) usize {
        const self: *Partition = @ptrCast(@alignCast(ptr));
        return self.parent.blockSize();
    }

    fn numBlocks(ptr: *anyopaque) u64 {
        const self: *Partition = @ptrCast(@alignCast(ptr));
        return self.blocks;
    }
};

/// A block device whose operations are serialised by a mutex
/// (`block_device_lockable`, `block_device_partition_lockable`).
pub const LockedBlockDevice = struct {
    inner: BlockDevice,
    mutex: *Mutex,

    pub fn device(self: *LockedBlockDevice, name: []const u8) Device {
        return .{ .name = name, .kind = .{ .block = .{ .ptr = self, .vtable = &.{
            .read_blocks = readBlocks,
            .write_blocks = writeBlocks,
            .block_size = blockSize,
            .num_blocks = numBlocks,
            .sync = sync,
        } } } };
    }

    fn readBlocks(ptr: *anyopaque, buf: []u8, first: u64) Error!void {
        const self: *LockedBlockDevice = @ptrCast(@alignCast(ptr));
        self.mutex.lock() catch return error.InputOutput;
        defer self.mutex.unlock() catch {};
        return self.inner.readBlocks(buf, first);
    }

    fn writeBlocks(ptr: *anyopaque, buf: []const u8, first: u64) Error!void {
        const self: *LockedBlockDevice = @ptrCast(@alignCast(ptr));
        self.mutex.lock() catch return error.InputOutput;
        defer self.mutex.unlock() catch {};
        return self.inner.writeBlocks(buf, first);
    }

    fn blockSize(ptr: *anyopaque) usize {
        const self: *LockedBlockDevice = @ptrCast(@alignCast(ptr));
        return self.inner.blockSize();
    }

    fn numBlocks(ptr: *anyopaque) u64 {
        const self: *LockedBlockDevice = @ptrCast(@alignCast(ptr));
        return self.inner.numBlocks();
    }

    fn sync(ptr: *anyopaque) Error!void {
        const self: *LockedBlockDevice = @ptrCast(@alignCast(ptr));
        self.mutex.lock() catch return error.InputOutput;
        defer self.mutex.unlock() catch {};
        return self.inner.sync();
    }
};

// ----------------------------------------------------------------------------
// Registry and descriptors.

/// A named device of either kind.
pub const Device = struct {
    name: []const u8,
    kind: union(enum) {
        char: CharDevice,
        block: BlockDevice,
    },

    pub fn asChar(d: Device) ?CharDevice {
        return switch (d.kind) {
            .char => |c| c,
            else => null,
        };
    }

    pub fn asBlock(d: Device) ?BlockDevice {
        return switch (d.kind) {
            .block => |b| b,
            else => null,
        };
    }
};

/// The devices known by name (`device_registry`); `find()` accepts the
/// name with or without the `/dev/` prefix.
pub fn Registry(comptime capacity: usize) type {
    return struct {
        devices: [capacity]Device = undefined,
        count: usize = 0,

        const Self = @This();

        pub fn add(self: *Self, dev: Device) Error!void {
            const cs = interrupts.CriticalSection.enter();
            defer cs.exit();
            if (self.count == capacity) return error.NoSpaceLeft;
            self.devices[self.count] = dev;
            self.count += 1;
        }

        pub fn remove(self: *Self, name: []const u8) void {
            const cs = interrupts.CriticalSection.enter();
            defer cs.exit();
            for (self.devices[0..self.count], 0..) |d, i| {
                if (std.mem.eql(u8, d.name, name)) {
                    self.devices[i] = self.devices[self.count - 1];
                    self.count -= 1;
                    return;
                }
            }
        }

        pub fn find(self: *Self, path: []const u8) ?Device {
            const name = if (std.mem.startsWith(u8, path, "/dev/")) path[5..] else path;
            for (self.devices[0..self.count]) |d| {
                if (std.mem.eql(u8, d.name, name)) return d;
            }
            return null;
        }
    };
}

/// Small integer descriptors for open devices (`file_descriptors_manager`),
/// for code that wants the POSIX `open/read/write/close` shape.
pub fn FileDescriptors(comptime capacity: usize) type {
    return struct {
        slots: [capacity]?CharDevice = @splat(null),

        const Self = @This();
        /// 0, 1, 2 are reserved for the standard streams.
        pub const first_fd = 3;

        pub fn open(self: *Self, dev: CharDevice) Error!usize {
            if (dev.vtable.open) |f| try f(dev.ptr);
            const cs = interrupts.CriticalSection.enter();
            defer cs.exit();
            for (&self.slots, 0..) |*slot, i| {
                if (slot.* == null) {
                    slot.* = dev;
                    return i + first_fd;
                }
            }
            return error.TooManyOpenFiles;
        }

        pub fn get(self: *Self, fd: usize) Error!CharDevice {
            if (fd < first_fd or fd - first_fd >= capacity) return error.BadFile;
            return self.slots[fd - first_fd] orelse error.BadFile;
        }

        pub fn read(self: *Self, fd: usize, buf: []u8) Error!usize {
            return (try self.get(fd)).read(buf);
        }

        pub fn write(self: *Self, fd: usize, bytes: []const u8) Error!usize {
            return (try self.get(fd)).write(bytes);
        }

        pub fn close(self: *Self, fd: usize) Error!void {
            const dev = try self.get(fd);
            if (dev.vtable.close) |f| f(dev.ptr);
            self.slots[fd - first_fd] = null;
        }
    };
}
