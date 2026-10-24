//! storage/storage.zig -- the card, for the capstone: one owner (the course's
//! SD log, test/tutor/common/sdlog.zig), which prints and logs every line and
//! also stores the USB file, and the read-back of both at the end.
//! (C++: app/storage/storage.*.)
//!
//! The USB file goes through a ring of buffers between the USB thread and the
//! card: the USB thread fills a block and hands it over without waiting; the
//! card's owner writes the blocks, in order, into the file it keeps open, and
//! frees each one when written. The USB thread waits only when every block is
//! still waiting for the card -- and then for one block's write. (Waiting for
//! the card on every block kept it away from the bus longer than the host
//! tolerates: more than 20 ms, less than 50.)

const uos = @import("uos");
const tutor = @import("tutor");
const sdlog = @import("sdlog");
const config = @import("../core/config.zig");

const rtos = uos.rtos;

pub const ring_blocks = 16;
pub const block_bytes: u32 = 32 * 1024;

var s_ring: [ring_blocks][block_bytes]u8 align(64) = undefined; // 512 KiB
var s_free: rtos.Semaphore = .counting("ring", ring_blocks, ring_blocks);
var s_next: u32 = 0;

/// The card and its owner; false when the card fails (on the board).
pub fn start() bool {
    return sdlog.start(config.log_leaf, config.prio_logger, config.core_logger);
}

/// The card is in use (the board).
pub fn hasCard() bool {
    return sdlog.hasCard();
}

/// The file created and kept open, before any transfer (creating it takes
/// time the bus does not have).
pub fn openFile() bool {
    return sdlog.streamOpen(config.usb_leaf);
}

/// The next free block (waits while there is none); `waited_us`: how long.
pub fn nextBlock(waited_us: *u32) []u8 {
    const t0 = tutor.second_timer.nowUs();
    s_free.wait() catch {};
    waited_us.* = tutor.second_timer.nowUs() -% t0;
    // The card's owner writes the blocks in the order handed over, so they come
    // free in that order too.
    const b = s_ring[s_next][0..];
    s_next = (s_next + 1) % ring_blocks;
    return b;
}

/// A filled block (its first `len` bytes) to the card's owner; returns at once.
pub fn submitBlock(block: []u8, len: u32) void {
    sdlog.streamWriteAsync(block[0..len], &s_free);
}

/// Every block written, the file closed. True when no write failed.
pub fn closeFile() bool {
    // Every block back: every write done.
    for (0..ring_blocks) |_| s_free.wait() catch {};
    for (0..ring_blocks) |_| s_free.post() catch {};
    return sdlog.streamClose() and sdlog.streamErrors() == 0;
}

/// The owner writes out what it holds and returns; from here on the console.
pub fn stop() void {
    sdlog.stop();
}

pub const ReadBack = struct {
    log_ok: bool = false, // the log: size, CRC-32, newlines as written
    log_bytes: u32 = 0,
    log_lines: u32 = 0,
    file_read: bool = false, // the USB file could be read back
    file_bytes: u32 = 0,
    file_crc: u32 = 0,
};

/// After stop().
pub fn readBack() ReadBack {
    const v = sdlog.verify();
    var r: ReadBack = .{ .log_ok = v.ok, .log_bytes = v.on_card, .log_lines = v.lines_on_card };
    if (sdlog.fileCrc(config.usb_leaf)) |f| {
        r.file_read = true;
        r.file_bytes = f.size;
        r.file_crc = f.crc;
    }
    return r;
}

/// CRC-32 (zlib's), continued from `crc` (0 to start).
pub fn crc32(crc: u32, data: []const u8) u32 {
    return sdlog.crc32(crc, data);
}
