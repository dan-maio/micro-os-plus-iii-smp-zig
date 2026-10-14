//! io-apis: generic `std.Io` code running on the RTOS (`uos.Io`), and the
//! device layer with the standard readers and writers.

const std = @import("std");
const Io = std.Io;
const uos = @import("uos");
const t = @import("check.zig");
const rtos = uos.rtos;
const devices = uos.io.devices;

pub fn run() u32 {
    t.reset();
    uos.trace.puts("\nio-apis - started");
    var rtos_io: uos.Io = .init(uos.memory.allocator());
    const io = rtos_io.io();
    futures(io);
    groups(io);
    sync(io);
    queues(io);
    timeAndCancel(io);
    console(io);
    deviceLayer();
    return t.summary("io-apis");
}

fn square(io: Io, x: u32) u32 {
    io.sleep(.fromMilliseconds(2), .awake) catch {};
    return x * x;
}

fn futures(io: Io) void {
    t.section("async / concurrent / await");
    var a = io.async(square, .{ io, 3 });
    t.eq(@as(u32, 9), a.await(io), @src());
    var c = io.concurrent(square, .{ io, 7 }) catch {
        t.ok(false, @src());
        return;
    };
    var d = io.concurrent(square, .{ io, 8 }) catch {
        t.ok(false, @src());
        return;
    };
    t.eq(@as(u32, 49), c.await(io), @src());
    t.eq(@as(u32, 64), d.await(io), @src());
}

var group_sum: u32 = 0;

fn addTo(io: Io, mutex: *Io.Mutex, x: u32) Io.Cancelable!void {
    try io.sleep(.fromMilliseconds(1), .awake);
    try mutex.lock(io);
    defer mutex.unlock(io);
    group_sum += x;
}

fn groups(io: Io) void {
    t.section("groups");
    var mutex: Io.Mutex = .init;
    var group: Io.Group = .init;
    group_sum = 0;
    for (1..9) |i| group.concurrent(io, addTo, .{ io, &mutex, @as(u32, @intCast(i)) }) catch t.ok(false, @src());
    group.await(io) catch {};
    t.eq(@as(u32, 36), group_sum, @src());
}

const Shared = struct {
    mutex: Io.Mutex = .init,
    cond: Io.Condition = .init,
    ready: bool = false,
    value: u32 = 0,
};

fn producer(io: Io, s: *Shared) void {
    io.sleep(.fromMilliseconds(5), .awake) catch {};
    s.mutex.lockUncancelable(io);
    s.value = 123;
    s.ready = true;
    s.mutex.unlock(io);
    s.cond.signal(io);
}

fn sync(io: Io) void {
    t.section("std.Io.Mutex / Condition");
    var s: Shared = .{};
    var f = io.concurrent(producer, .{ io, &s }) catch {
        t.ok(false, @src());
        return;
    };
    s.mutex.lockUncancelable(io);
    while (!s.ready) s.cond.waitUncancelable(io, &s.mutex);
    s.mutex.unlock(io);
    t.eq(@as(u32, 123), s.value, @src());
    f.await(io);
}

fn queueProducer(io: Io, q: *Io.Queue(u32)) void {
    for (1..11) |i| q.putOne(io, @intCast(i)) catch return;
}

fn queues(io: Io) void {
    t.section("std.Io.Queue");
    var buf: [4]u32 = undefined;
    var q: Io.Queue(u32) = .init(&buf);
    var f = io.concurrent(queueProducer, .{ io, &q }) catch {
        t.ok(false, @src());
        return;
    };
    var sum: u32 = 0;
    for (0..10) |_| sum += q.getOne(io) catch 0;
    t.eq(@as(u32, 55), sum, @src());
    f.await(io);
}

fn sleepForever(io: Io) Io.Cancelable!void {
    try io.sleep(.fromSeconds(1000), .awake);
}

fn timeAndCancel(io: Io) void {
    t.section("time and cancellation");
    const t0 = Io.Clock.awake.now(io);
    io.sleep(.fromMilliseconds(20), .awake) catch {};
    const dt = t0.durationTo(Io.Clock.awake.now(io)).toMilliseconds();
    t.ok(dt >= 19 and dt <= 25, @src());
    t.ok((Io.Clock.awake.resolution(io) catch Io.Duration.zero).nanoseconds > 0, @src());

    var f = io.concurrent(sleepForever, .{io}) catch {
        t.ok(false, @src());
        return;
    };
    io.sleep(.fromMilliseconds(5), .awake) catch {};
    t.err(error.Canceled, f.cancel(io), @src());

    var r: [8]u8 = @splat(0);
    io.random(&r);
    t.ok(!std.mem.allEqual(u8, &r, 0), @src());
}

fn console(io: Io) void {
    t.section("stdout through std.Io.File");
    var buf: [64]u8 = undefined;
    var w = Io.File.stdout().writer(io, &buf);
    w.interface.print("hello from std.Io.File.stdout() {d}\n", .{42}) catch t.ok(false, @src());
    w.interface.flush() catch t.ok(false, @src());
}

var rx: devices.RingBuffer(32) = .{};
var tty: devices.TraceTty = .{};

fn deviceLayer() void {
    t.section("devices");
    var registry: devices.Registry(4) = .{};
    t.success(registry.add(tty.device("tty")), @src());
    t.success(registry.add(rx.device("loop")), @src());
    t.ok(registry.find("/dev/tty") != null, @src());
    t.ok(registry.find("nope") == null, @src());

    // Writer + Reader on a loopback character device.
    const loop = registry.find("/dev/loop").?.asChar().?;
    var wbuf: [16]u8 = undefined;
    var w = loop.writer(&wbuf);
    w.interface.print("line {d}\nnext\n", .{1}) catch t.ok(false, @src());
    w.interface.flush() catch t.ok(false, @src());
    var rbuf: [32]u8 = undefined;
    var r = loop.reader(&rbuf);
    const line = r.interface.takeDelimiterExclusive('\n') catch "";
    t.ok(std.mem.eql(u8, line, "line 1"), @src());
    r.interface.toss(1);
    rx.timeout = 5;
    const next = r.interface.takeDelimiterExclusive('\n') catch "";
    t.ok(std.mem.eql(u8, next, "next"), @src());

    // Descriptors.
    var fds: devices.FileDescriptors(4) = .{};
    const fd = fds.open(registry.find("tty").?.asChar().?) catch 0;
    t.eq(@as(usize, 3), fd, @src());
    t.eq(@as(usize, 6), fds.write(fd, "fd ok\n") catch 0, @src());
    t.success(fds.close(fd), @src());
    t.err(error.BadFile, fds.write(fd, "x"), @src());

    // Block devices: a RAM disk and a partition of it.
    var storage: [8 * 512]u8 = undefined;
    var disk: devices.RamDisk = .{ .storage = &storage };
    var part: devices.Partition = .{ .parent = disk.device("ram").asBlock().?, .first_block = 2, .blocks = 4 };
    const pdev = part.device("ram1").asBlock().?;
    var block: [512]u8 = @splat(0xA5);
    t.success(pdev.writeBlocks(&block, 1), @src());
    t.eq(@as(u8, 0xA5), storage[3 * 512], @src());
    var back: [512]u8 = undefined;
    t.success(pdev.readBlocks(&back, 1), @src());
    t.ok(std.mem.eql(u8, &back, &block), @src());
    t.err(error.InvalidArgument, pdev.readBlocks(&back, 4), @src());
}
