//! mailbox.zig -- the VideoCore mailbox's property channel on the BCM2711
//! (Raspberry Pi 4 B), for powering a device domain.
//!
//! The Zig version of the C++ port's soc/bcm2711/src/mailbox.cpp (golden
//! workspace), call for call: a 16-byte aligned property buffer, cleaned and
//! invalidated around the exchange, handed to channel 8 at its 0xC0000000 bus
//! alias first (the VideoCore's uncached view of RAM), then at the plain
//! address if the firmware does not answer; replies for other channels are
//! drained and ignored.

const std = @import("std");

const periph_base: usize = 0xFE00_0000;
const mbox_base = periph_base + 0xB880;
const mbox_read = mbox_base + 0x00;
const mbox_status = mbox_base + 0x18;
const mbox_write = mbox_base + 0x20;

const status_full: u32 = 0x8000_0000;
const status_empty: u32 = 0x4000_0000;
const channel_property: u32 = 8;
const bus_alias: u32 = 0xC000_0000;
const spin_limit: u32 = 4_000_000;

/// Response code meaning the firmware accepted and processed the request.
pub const resp_success: u32 = 0x8000_0000;
/// Property tag: set a power domain's state.
pub const tag_set_power_state: u32 = 0x0002_8001;
/// Power-domain device id of the USB HCD block.
pub const power_device_usb: u32 = 3;

var g_last_code: u32 = 0;
var g_last_state: u32 = 0;
var g_last_alias: bool = true;
var g_lock = std.atomic.Value(bool).init(false);

fn rd(addr: usize) u32 {
    return @as(*volatile u32, @ptrFromInt(addr)).*;
}

fn wr(addr: usize, v: u32) void {
    @as(*volatile u32, @ptrFromInt(addr)).* = v;
}

fn dsb() void {
    asm volatile ("dsb sy" ::: .{ .memory = true });
}

fn cacheFlush(addr: usize, len: usize) void {
    var p = addr & ~@as(usize, 63);
    const end = addr + len;
    dsb();
    while (p < end) : (p += 64) {
        asm volatile ("dc civac, %[v]"
            :
            : [v] "r" (p),
            : .{ .memory = true });
    }
    dsb();
}

fn doCall(buf: *align(16) [8]u32, use_alias: bool) bool {
    const size = buf[0];
    const addr: u32 = @intCast(@intFromPtr(buf));
    while (g_lock.swap(true, .acquire)) {
        asm volatile ("yield" ::: .{ .memory = true });
    }
    defer g_lock.store(false, .release);

    cacheFlush(@intFromPtr(buf), size);
    const base = if (use_alias) addr | bus_alias else addr;
    const msg = (base & ~@as(u32, 0xF)) | channel_property;

    // Room in the outbound mailbox, then ring. One status register reports
    // both directions.
    var i: u32 = 0;
    while (rd(mbox_status) & status_full != 0) : (i += 1) {
        if (i >= spin_limit) return false;
    }
    dsb();
    wr(mbox_write, msg);

    // OUR reply: the mailbox is shared, replies for other channels are not it.
    while (true) {
        i = 0;
        while (rd(mbox_status) & status_empty != 0) : (i += 1) {
            if (i >= spin_limit) return false;
        }
        dsb();
        if (rd(mbox_read) & 0xF == channel_property) break;
    }
    cacheFlush(@intFromPtr(buf), size);
    return buf[1] == resp_success;
}

fn buildPowerRequest(buf: *align(16) [8]u32, device_id: u32, state: u32) void {
    buf.* = .{ 8 * 4, 0, tag_set_power_state, 8, 8, device_id, state, 0 };
}

/// Power a device domain on or off and wait for it to settle. True when the
/// firmware reported success AND the returned state is what was asked for.
pub fn setPowerState(device_id: u32, on: bool) bool {
    var buf: [8]u32 align(16) = undefined;
    // state bit 0 = on/off, bit 1 = wait for the domain to settle.
    const state: u32 = if (on) 0x3 else 0x2;
    buildPowerRequest(&buf, device_id, state);
    var ok = doCall(&buf, true);
    g_last_alias = true;
    if (!ok) {
        // A partial reply may have touched the buffer: rebuild, plain address.
        buildPowerRequest(&buf, device_id, state);
        ok = doCall(&buf, false);
        g_last_alias = false;
    }
    g_last_code = buf[1];
    g_last_state = buf[6];
    if (!ok) return false;
    return (buf[6] & 1 != 0) == on;
}

/// The last setPowerState()'s response code, returned state, and alias.
pub fn lastCode() u32 {
    return g_last_code;
}
pub fn lastState() u32 {
    return g_last_state;
}
pub fn lastUsedAlias() bool {
    return g_last_alias;
}
