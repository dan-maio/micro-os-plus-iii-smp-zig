//! sdlog.zig -- the SD log of the µOS++ tutorial (test/tutor/README.md,
//! from lesson 16).
//!
//! The Zig version of the C++ course's tutor/common/sdlog.cpp (golden
//! workspace), part for part.
//!
//! One logger thread owns the UART and the SD card. Every other thread sends
//! it lines through a message queue (`say()`); the logger prints each line on
//! the UART -- on the board only there: not mirrored to semihosting, whose
//! call per line through the probe costs more than the card -- and gathers it
//! in a 4 KiB buffer, which it appends to tests/<leaf> on the card's existing
//! FAT32 volume (never formatted) when the buffer is full, after half a
//! second without a line, and on `sync()`. At the end `verify()` reads the
//! file back and compares its size, its CRC-32 and its newlines with what was
//! written.
//!
//! The card is used only on the board (`tutor.onHardware()`): under QEMU,
//! whose image is the same, the lines go to the UART only.
//!
//! The lesson module imports it as `sdlog` (build.zig adds the module to the
//! tutorial's lessons marked `.devices = true`).

const std = @import("std");
const uos = @import("uos");
const board = @import("board");
const tutor = @import("tutor");
const sd = @import("sd");
const fatfs = @import("fatfs");

const rtos = uos.rtos;
const Atomic = std.atomic.Value;

pub const line_max = 110; // a longer line is cut
pub const queue_slots = 64;
pub const buffer_bytes = 4096;
pub const idle_ms = 500;

/// What the logger did, updated by the logger thread as it goes.
pub const Counters = struct {
    messages: Atomic(u32) = .init(0), // lines taken from the queue (one say() each)
    lines: Atomic(u32) = .init(0), // their newlines
    bytes: Atomic(u32) = .init(0), // their bytes
    written: Atomic(u32) = .init(0), // bytes appended to the card
    flushes_full: Atomic(u32) = .init(0), // the buffer was full
    flushes_idle: Atomic(u32) = .init(0), // no line for idle_ms
    flushes_sync: Atomic(u32) = .init(0), // sync() or stop()
    write_errors: Atomic(u32) = .init(0),
    max_flush_us: Atomic(u32) = .init(0), // the longest append
    cpus: Atomic(u32) = .init(0), // the cores it ran on (a mask)
};

const Op = enum(u8) { line, sync, stop, stream_open, stream_close, stream_write_async };

const Message = struct {
    what: Op = .line,
    len: u8 = 0,
    leaf: []const u8 = "", // .stream_open
    data: []const u8 = &.{}, // .stream_write_async
    done: ?*rtos.Semaphore = null, // .stream_write_async
    text: [line_max]u8 = undefined,
};

var s_queue: rtos.MessageQueueTyped(Message).Static(queue_slots) = .{};
var s_ack: rtos.Semaphore = .binary("log_ack", 0);
var s_logger: ?*rtos.Thread = null;
var s_leaf: []const u8 = "";
var s_card_used = false;
var s_card_ms: u32 = 0;
var s_observer: ?Observer = null;
var s_counters: Counters = .{};
var s_sd: sd.SdCard = .{};

var s_buf: [buffer_bytes]u8 = undefined;
var s_len: usize = 0;
var s_crc: std.hash.Crc32 = .init(); // of what is on the card

var s_stream: fatfs.Stream = .{};
var s_file_ok = false; // the last stream open's or close's result
var s_stream_errors = Atomic(u32).init(0);

/// Called by the logger with every line, before it prints it.
pub const Observer = *const fn (text: []const u8) void;

// The buffer appended to the file, then emptied. Without a card it is only
// emptied.
fn flush(reason: *Atomic(u32)) void {
    if (s_len == 0) return;
    _ = reason.fetchAdd(1, .monotonic);
    if (s_card_used) {
        const t0 = tutor.second_timer.nowUs();
        const chunk = s_buf[0..s_len];
        if (fatfs.appendFile(s_leaf, chunk)) {
            _ = s_counters.written.fetchAdd(@intCast(chunk.len), .monotonic);
            s_crc.update(chunk);
        } else {
            _ = s_counters.write_errors.fetchAdd(1, .monotonic);
        }
        const us = tutor.second_timer.nowUs() -% t0;
        if (us > s_counters.max_flush_us.load(.monotonic)) s_counters.max_flush_us.store(us, .monotonic);
    }
    s_len = 0;
}

fn loggerBody(_: ?*anyopaque) ?*anyopaque {
    const on_board = tutor.onHardware();
    while (true) {
        // Half a second without a line writes out what is buffered.
        const m = s_queue.typed.timedReceive(idle_ms) catch {
            flush(&s_counters.flushes_idle);
            continue;
        };
        _ = s_counters.cpus.fetchOr(@as(u32, 1) << @intCast(board.cpuSlot()), .monotonic);
        switch (m.what) {
            .line => {
                const t = m.text[0..m.len];
                if (s_observer) |obs| obs(t);
                if (on_board) {
                    board.uart.putsUart(t); // not one semihosting call per line
                } else {
                    board.uart.puts(t); // QEMU: mirrored, at no cost
                }
                if (s_len + t.len > s_buf.len) flush(&s_counters.flushes_full);
                @memcpy(s_buf[s_len..][0..t.len], t);
                s_len += t.len;
                _ = s_counters.messages.fetchAdd(1, .monotonic);
                _ = s_counters.lines.fetchAdd(@intCast(std.mem.count(u8, t, "\n")), .monotonic);
                _ = s_counters.bytes.fetchAdd(@intCast(t.len), .monotonic);
            },
            .stream_open => {
                s_file_ok = if (s_card_used) s_stream.create(m.leaf) else true;
                s_ack.post() catch {};
            },
            .stream_close => {
                s_file_ok = if (s_card_used) s_stream.close() else true;
                s_ack.post() catch {};
            },
            .stream_write_async => {
                const ok = if (s_card_used) s_stream.write(m.data) else true;
                if (!ok) _ = s_stream_errors.fetchAdd(1, .monotonic);
                m.done.?.post() catch {};
            },
            .sync, .stop => {
                flush(&s_counters.flushes_sync);
                s_ack.post() catch {};
                if (m.what == .stop) return null;
            },
        }
    }
}

// check()'s lines, while the logger runs.
fn output(text: []const u8) void {
    _ = say("{s}", .{text});
}

/// Bring the card up (on the board: init, mount, /tests, remove the old
/// tests/<leaf>), then create the logger at `prio`, on core `core` (with
/// more than one CPU; null: any). False, with the reason printed, when the
/// card fails.
pub fn start(leaf: []const u8, prio: rtos.Priority, core: ?u32) bool {
    s_leaf = leaf;
    s_card_used = false;
    s_len = 0;
    s_crc = .init();
    if (tutor.onHardware()) {
        const t0 = tutor.second_timer.nowUs();
        if (!s_sd.init()) {
            board.console("  SD card init failed\n", .{});
            return false;
        }
        fatfs.bindCard(&s_sd);
        if (!fatfs.mountVolume()) {
            board.console("  FAT32 mount failed: {s}\n", .{fatfs.lastError()});
            return false;
        }
        if (!fatfs.ensureTestsDir()) {
            board.console("  mkdir tests failed: {s}\n", .{fatfs.lastError()});
            return false;
        }
        _ = fatfs.removeFile(leaf);
        s_card_ms = (tutor.second_timer.nowUs() -% t0 + 500) / 1000;
        s_card_used = true;
    }

    s_queue.init("log", .{}) catch {
        board.console("  log queue init failed\n", .{});
        return false;
    };
    var attr: rtos.Thread.Attributes = .{ .priority = prio, .stack_size_bytes = 8 * 1024 };
    if (uos.config.ncpu > 1) {
        if (core) |c| attr.cpu_affinity = @as(u32, 1) << @intCast(c);
    }
    s_logger = rtos.Thread.create(uos.memory.allocator(), "logger", loggerBody, null, attr) catch {
        board.console("  cannot create the logger\n", .{});
        return false;
    };
    tutor.output = output;
    return true;
}

/// The card is in use (the board), not just the UART (QEMU).
pub fn hasCard() bool {
    return s_card_used;
}

/// How long the card's start took, in milliseconds.
pub fn cardStartMs() u32 {
    return s_card_ms;
}

/// Queue one line for the logger; waits while the queue is full. True when
/// it had to wait.
pub fn say(comptime fmt: []const u8, args: anytype) bool {
    var m: Message = .{};
    var w: std.Io.Writer = .fixed(&m.text);
    w.print(fmt, args) catch {};
    m.len = @intCast(w.buffered().len);
    s_queue.typed.trySend(m, 0) catch {
        s_queue.typed.send(m, 0) catch {}; // the queue is full: wait for a slot
        return true;
    };
    return false;
}

fn request(what: Op) void {
    s_queue.typed.send(.{ .what = what }, 0) catch {};
    s_ack.wait() catch {};
}

/// Have the logger append what it holds to the card, and wait until it has.
pub fn sync() void {
    request(.sync);
}

// ---- A file kept open (from lesson 19: the USB file, as it arrives) -------------

fn streamRequest(m: Message) bool {
    s_queue.typed.send(m, 0) catch {};
    s_ack.wait() catch {};
    return s_file_ok;
}

/// tests/<leaf> created and kept open; waits for the logger.
pub fn streamOpen(leaf: []const u8) bool {
    return streamRequest(.{ .what = .stream_open, .leaf = leaf });
}

/// The file closed (its directory entry written); waits for the logger.
pub fn streamClose() bool {
    return streamRequest(.{ .what = .stream_close });
}

/// A piece written without waiting: the logger writes it in its turn, then
/// posts `done`. The caller must not touch `data` before `done` is posted.
/// Failed writes are counted (streamErrors()).
pub fn streamWriteAsync(data: []const u8, done: *rtos.Semaphore) void {
    s_queue.typed.send(.{ .what = .stream_write_async, .data = data, .done = done }, 0) catch {};
}

pub fn streamErrors() u32 {
    return s_stream_errors.load(.monotonic);
}

/// CRC-32 (IEEE 802.3, as zlib's), continued from `crc` (0 to start).
pub fn crc32(crc: u32, data: []const u8) u32 {
    var h: std.hash.Crc32 = .{ .crc = ~crc };
    h.update(data);
    return h.final();
}

pub const FileCrc = struct { size: u32, crc: u32 };

/// After stop(): tests/<leaf> read back from the card, 4 KiB at a time: its
/// size and CRC-32. Null when it cannot be read (or without a card).
pub fn fileCrc(leaf: []const u8) ?FileCrc {
    if (!s_card_used) return null;
    const size = fatfs.fileSize(leaf) orelse return null;
    var crc: u32 = 0;
    var off: u32 = 0;
    while (off < size) {
        const n: u32 = @min(size - off, s_buf.len);
        if (!fatfs.loadFileAt(leaf, off, s_buf[0..n])) return null;
        crc = crc32(crc, s_buf[0..n]);
        off += n;
    }
    return .{ .size = size, .crc = crc };
}

/// sync(), then the logger returns; it is joined and destroyed.
pub fn stop() void {
    tutor.output = null;
    request(.stop);
    if (s_logger) |l| {
        _ = l.join() catch null;
        l.destroy();
    }
    s_logger = null;
    s_queue.typed.deinit();
}

pub const Readback = struct { ok: bool, on_card: u32 = 0, lines_on_card: u32 = 0 };

/// After stop(): the file read back. `ok` when its size, its CRC-32 and its
/// newlines are those written and no append failed. Without a card, ok and
/// zeros.
pub fn verify() Readback {
    if (!s_card_used) return .{ .ok = true };
    const want = s_counters.written.load(.monotonic);
    const size = fatfs.fileSize(s_leaf) orelse return .{ .ok = false };
    var r: Readback = .{ .ok = s_counters.write_errors.load(.monotonic) == 0 and size == want and want == s_counters.bytes.load(.monotonic), .on_card = size };
    if (size == 0 or size != want) return .{ .ok = false, .on_card = size };
    const gpa = uos.memory.allocator();
    const buf = gpa.alloc(u8, size) catch return .{ .ok = false, .on_card = size };
    defer gpa.free(buf);
    if (!fatfs.loadFile(s_leaf, buf)) {
        r.ok = false;
    } else {
        r.lines_on_card = @intCast(std.mem.count(u8, buf, "\n"));
        r.ok = r.ok and std.hash.Crc32.hash(buf) == s_crc.final() and r.lines_on_card == s_counters.lines.load(.monotonic);
    }
    return r;
}

pub fn stats() *const Counters {
    return &s_counters;
}

pub fn logger() *rtos.Thread {
    return s_logger.?;
}

pub fn setObserver(obs: ?Observer) void {
    s_observer = obs;
}
