//! usb/big_transfer.zig -- the file transfer over USB, as the host tool
//! `usb_test_host --big <file>` (luckfox-lyra/smp_test6/host/) speaks it:
//!
//!   host -> device  one 512-byte packet: 0x02, the length (32 bits, big-endian)
//!   host -> device  the file, streamed
//!   device -> host  every byte echoed back as it arrives (the host saves the
//!                   echo as <file>.bak and compares)
//!   device -> host  0x02, the count (32 bits, big-endian), 'O', 'K'
//!
//! Here the device also stores the file on the card, through its owner
//! (storage/storage.zig): the bytes are received straight into the blocks of
//! a ring, each full block handed to the card's owner without waiting; and
//! keeps its CRC-32. (C++: app/usb/big_transfer.*.)

const std = @import("std");
const uos = @import("uos");
const tutor = @import("tutor");
const usb_dwc2 = @import("usb_dwc2");
const storage = @import("../storage/storage.zig");

const rtos = uos.rtos;

pub const Result = struct {
    done: bool = false,
    announced: u32 = 0, // the length in the header
    received: u32 = 0,
    echoed: u32 = 0,
    crc: u32 = 0, // of the bytes received
    blocks: u32 = 0, // written to the card
    stored: bool = false, // every block written
    us: u32 = 0, // from the header to the ack
    max_wait_us: u32 = 0, // the longest wait for a free block of the ring
    bad_headers: u32 = 0,
};

const cmd_big: u8 = 0x02;
const chunk: u32 = 16 * 1024; // one epRead(), one echo

// DMA buffers: cache-line aligned, sizes multiples of the 512-byte packet.
var s_header: [512]u8 align(64) = undefined;
var s_ack: [64]u8 align(64) = undefined;

var s_done: rtos.Semaphore = .binary("usb_done", 0);
var s_last: Result = .{};

fn transfer(len: u32) void {
    var r: Result = .{ .announced = len };
    const t0 = tutor.second_timer.nowUs();
    var waited: u32 = 0;
    var block = storage.nextBlock(&waited);
    var used: u32 = 0;

    while (r.received < len) {
        const want = @min(len - r.received, chunk);
        const n = usb_dwc2.epRead(block[used..][0..want]); // DMA into the block
        if (n <= 0) break;
        const got: u32 = @intCast(n);
        if (usb_dwc2.epWriteStream(block[used..][0..got]) == n) r.echoed += got; // the echo, at once
        r.crc = storage.crc32(r.crc, block[used..][0..got]);
        r.received += got;
        used += got;
        // A full block to the card's owner, and on with the next one: the bus
        // is not left waiting for the card.
        if (used == storage.block_bytes or (got < want and used != 0)) {
            storage.submitBlock(block, used);
            r.blocks += 1;
            block = storage.nextBlock(&waited);
            r.max_wait_us = @max(r.max_wait_us, waited);
            used = 0;
        }
    }
    if (used != 0) {
        storage.submitBlock(block, used);
        r.blocks += 1;
    } else {
        storage.submitBlock(block, 0); // the block taken last, given back unused
    }

    s_ack[0..7].* = .{ cmd_big, @truncate(r.received >> 24), @truncate(r.received >> 16), @truncate(r.received >> 8), @truncate(r.received), 'O', 'K' };
    _ = usb_dwc2.epWrite(s_ack[0..7]);
    r.us = tutor.second_timer.nowUs() -% t0;
    // The host has everything; now the last blocks to the card, the close.
    r.stored = storage.closeFile();
    r.done = true;
    r.bad_headers = s_last.bad_headers;
    s_last = r;
    s_done.post() catch {};
}

fn be32(p: []const u8) u32 {
    return (@as(u32, p[0]) << 24) | (@as(u32, p[1]) << 16) | (@as(u32, p[2]) << 8) | p[3];
}

/// The USB service thread's work once the host has configured the device
/// (usb_dwc2.setConfiguredCallback): serves transfers, one after another.
pub fn serve(_: ?*anyopaque) void {
    while (true) {
        const n = usb_dwc2.epRead(&s_header);
        if (n >= 5 and s_header[0] == cmd_big) transfer(be32(s_header[1..5])) else s_last.bad_headers += 1;
    }
}

/// Wait, at most `seconds`, for the first transfer to end.
pub fn wait(seconds: u32) bool {
    s_done.timedWait(seconds * 1000) catch return false;
    return true;
}

pub fn last() *const Result {
    return &s_last;
}
