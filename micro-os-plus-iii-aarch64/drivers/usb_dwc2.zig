//! usb_dwc2.zig -- the DWC2 USB OTG core in device mode: a vendor-specific
//! bulk gadget (EP0 control, EP1 bulk IN 0x81 and bulk OUT 0x01, 512-byte
//! high-speed packets), with buffer DMA.
//!
//! The Zig version of the C++ port's drivers/src/usb_dwc2.cpp (golden
//! workspace; written for rpi-zero-2w/usb_test, made to serve the Pi 4's
//! USB-C socket for the tutorial's capstone), function for function: one ISR
//! (GIC INTID 105 on the BCM2711, routed to core 0) that only masks and
//! records the events and posts a semaphore, and one service thread, pinned
//! to core 0, that handles them -- EP0's standard requests, the bulk
//! completions -- and, once the host has configured the device, runs the
//! application's callback, in which ep_read()/ep_write() pump the same events.
//!
//! The device's identity is the caller's (`Identity`): the C++ build takes it
//! from USB_DWC2_VID/USB_DWC2_PID.

const std = @import("std");
const uos = @import("uos");
const mailbox = @import("mailbox");

const rtos = uos.rtos;

// The BCM2711's core, behind the USB-C socket; its interrupt is VideoCore IRQ
// 9, GIC SPI 64 + 9 = 73: INTID 105.
const usb_base: usize = 0xFE00_0000 + 0x98_0000;
pub const intid: u32 = 32 + 73;

// ---- Register map (offsets from usb_base) ------------------------------------

pub const reg = struct {
    pub const GOTGCTL: u32 = 0x000;
    pub const GAHBCFG: u32 = 0x008;
    pub const GUSBCFG: u32 = 0x00C;
    pub const GRSTCTL: u32 = 0x010;
    pub const GINTSTS: u32 = 0x014;
    pub const GINTMSK: u32 = 0x018;
    pub const GRXSTSP: u32 = 0x020;
    pub const GRXFSIZ: u32 = 0x024;
    pub const GNPTXFSIZ: u32 = 0x028;
    pub const GSNPSID: u32 = 0x040;
    pub const GHWCFG1: u32 = 0x044;
    pub const GHWCFG2: u32 = 0x048;
    pub const GHWCFG3: u32 = 0x04C;
    pub const GHWCFG4: u32 = 0x050;
    pub const GDFIFOCFG: u32 = 0x05C;
    pub const DIEPTXF1: u32 = 0x104;
    pub const DCFG: u32 = 0x800;
    pub const DCTL: u32 = 0x804;
    pub const DSTS: u32 = 0x808;
    pub const DIEPMSK: u32 = 0x810;
    pub const DOEPMSK: u32 = 0x814;
    pub const DAINT: u32 = 0x818;
    pub const DAINTMSK: u32 = 0x81C;
    pub const PCGCCTL: u32 = 0xE00;
    const EP_STRIDE: u32 = 0x20;
    const DIEPCTL0: u32 = 0x900;
    const DIEPINT0: u32 = 0x908;
    const DIEPTSIZ0: u32 = 0x910;
    const DIEPDMA0: u32 = 0x914;
    const DOEPCTL0: u32 = 0xB00;
    const DOEPINT0: u32 = 0xB08;
    const DOEPTSIZ0: u32 = 0xB10;
    const DOEPDMA0: u32 = 0xB14;
    const FIFO0: u32 = 0x1000;
    const FIFO_STRIDE: u32 = 0x1000;
};

fn DIEPCTL(n: u32) u32 {
    return reg.DIEPCTL0 + reg.EP_STRIDE * n;
}
fn DIEPINT(n: u32) u32 {
    return reg.DIEPINT0 + reg.EP_STRIDE * n;
}
fn DIEPTSIZ(n: u32) u32 {
    return reg.DIEPTSIZ0 + reg.EP_STRIDE * n;
}
fn DIEPDMA(n: u32) u32 {
    return reg.DIEPDMA0 + reg.EP_STRIDE * n;
}
fn DOEPCTL(n: u32) u32 {
    return reg.DOEPCTL0 + reg.EP_STRIDE * n;
}
fn DOEPINT(n: u32) u32 {
    return reg.DOEPINT0 + reg.EP_STRIDE * n;
}
fn DOEPTSIZ(n: u32) u32 {
    return reg.DOEPTSIZ0 + reg.EP_STRIDE * n;
}
fn DOEPDMA(n: u32) u32 {
    return reg.DOEPDMA0 + reg.EP_STRIDE * n;
}
fn FIFO(n: u32) u32 {
    return reg.FIFO0 + reg.FIFO_STRIDE * n;
}

const bit = struct {
    // GRSTCTL
    const CSRST: u32 = 1 << 0;
    const RXFFLSH: u32 = 1 << 4;
    const TXFFLSH: u32 = 1 << 5;
    const TXFNUM_ALL: u32 = 0x10 << 6;
    const AHBIDLE: u32 = 1 << 31;
    // GOTGCTL
    const AVALOEN: u32 = 1 << 4;
    const BVALOVAL: u32 = 1 << 7;
    const BVALOEN: u32 = 1 << 6;
    // GUSBCFG
    const FHMOD: u32 = 1 << 29;
    const FDMOD: u32 = 1 << 30;
    const TRDT_SHIFT: u5 = 10;
    const TRDT_MASK: u32 = 0xF << TRDT_SHIFT;
    // GAHBCFG
    const GINT_GLBL: u32 = 1 << 0;
    const DMAEN: u32 = 1 << 5;
    // GINTSTS / GINTMSK
    const CURMOD: u32 = 1 << 0;
    const RXFLVL: u32 = 1 << 4;
    const USBSUSP: u32 = 1 << 11;
    const USBRST: u32 = 1 << 12;
    const ENUMDONE: u32 = 1 << 13;
    const IEPINT: u32 = 1 << 18;
    const OEPINT: u32 = 1 << 19;
    // DCTL
    const RWUSIG: u32 = 1 << 0;
    const SDIS: u32 = 1 << 1;
    const POPRGDNE: u32 = 1 << 11;
    // DCFG
    const NZLSOHSK: u32 = 1 << 2;
    const DSPD_HS: u32 = 0;
    const DSPD_MASK: u32 = 3;
    const DAD_SHIFT: u5 = 4;
    const DAD_MASK: u32 = 0x7F << DAD_SHIFT;
    // EPCTL
    const EPTYP_BULK: u32 = 2 << 18;
    const USBACTEP: u32 = 1 << 15;
    const EPENA: u32 = 1 << 31;
    const SNAK: u32 = 1 << 27;
    const CNAK: u32 = 1 << 26;
    const STALL: u32 = 1 << 21;
    const MPS_MASK: u32 = 0x7FF;
    fn TXFNUM(n: u32) u32 {
        return (n & 0xF) << 22;
    }
    // EPINT
    const XFERCOMPL: u32 = 1 << 0;
    const SETUP: u32 = 1 << 3;
    // DAINT
    fn DAINT_IN(n: u32) u32 {
        return @as(u32, 1) << @intCast(n);
    }
    fn DAINT_OUT(n: u32) u32 {
        return @as(u32, 1) << @intCast(16 + n);
    }
    // GRXSTSP
    const RXSTSP_EPNUM_MASK: u32 = 0xF;
    const RXSTSP_BCNT_SHIFT: u5 = 4;
    const RXSTSP_BCNT_MASK: u32 = 0x7FF;
    const RXSTSP_PKTSTS_SHIFT: u5 = 17;
    const RXSTSP_PKTSTS_MASK: u32 = 0xF;
};

// ---- Public types -------------------------------------------------------------

/// Why init() did not reach device mode.
pub const InitResult = enum { ok, no_power, bad_id, no_device_mode, reset_timeout };

pub fn initResultStr(r: InitResult) []const u8 {
    return switch (r) {
        .ok => "ok",
        .no_power => "USB power domain on failed",
        .bad_id => "not a DWC2 core",
        .no_device_mode => "no USB device mode",
        .reset_timeout => "core reset timeout",
    };
}

/// The device's identity on the bus.
pub const Identity = struct { vid: u16 = 0x1d6b, pid: u16 = 0x0104 };

pub const HwInfo = struct { snpsid: u32, hwcfg1: u32, hwcfg2: u32, hwcfg3: u32, hwcfg4: u32 };

pub const Debug = struct {
    isr_calls: u32 = 0,
    isr_offcore: u32 = 0,
    gintsts: u32 = 0,
    usbrst: u32 = 0,
    enumdone: u32 = 0,
    rx_pkts: u32 = 0,
    setups: u32 = 0,
    ep0_in: u32 = 0,
    ep0_out: u32 = 0,
    iep: u32 = 0,
    oep: u32 = 0,
    service_loops: u32 = 0,
    dsts: u32 = 0,
};

pub const RegSnapshot = struct { dcfg: u32, dctl: u32, dsts: u32, gintsts: u32, gintmsk: u32, gahbcfg: u32 };

pub const ConfiguredCallback = *const fn (arg: ?*anyopaque) void;

// ---- MMIO and cache helpers -----------------------------------------------------

inline fn rd(off: u32) u32 {
    return @as(*volatile u32, @ptrFromInt(usb_base + off)).*;
}
inline fn wr(off: u32, v: u32) void {
    @as(*volatile u32, @ptrFromInt(usb_base + off)).* = v;
}
inline fn setb(off: u32, m: u32) void {
    wr(off, rd(off) | m);
}
inline fn clrb(off: u32, m: u32) void {
    wr(off, rd(off) & ~m);
}
inline fn modify(off: u32, clear: u32, set: u32) void {
    wr(off, (rd(off) & ~clear) | set);
}

/// Register read for diagnostics (offset from the core's base).
pub fn readReg(off: u32) u32 {
    return rd(off);
}

// The DWC2 is outside the CPU coherency domain: DMA reads need the buffer
// cleaned to PoC first, DMA writes need the CPU's stale lines invalidated
// before it reads. Line = 64 bytes on the A72.
fn dcOp(comptime op: []const u8, p: usize, len: usize) void {
    var a = p & ~@as(usize, 63);
    const end = p + len;
    asm volatile ("dsb sy" ::: .{ .memory = true });
    while (a < end) : (a += 64) {
        asm volatile ("dc " ++ op ++ ", %[v]"
            :
            : [v] "r" (a),
            : .{ .memory = true });
    }
    asm volatile ("dsb sy" ::: .{ .memory = true });
}
fn dcClean(p: anytype, len: usize) void {
    dcOp("cvac", @intFromPtr(p), len);
}
fn dcInval(p: anytype, len: usize) void {
    dcOp("ivac", @intFromPtr(p), len);
}
fn dcCleanInval(p: anytype, len: usize) void {
    dcOp("civac", @intFromPtr(p), len);
}

// The BUS address the core's DMA master must be given: the VideoCore's
// uncached view of RAM, 0xC0000000 (its cached alias at 0 is served from the
// VideoCore L2, which no ARM cache maintenance reaches).
fn phys(p: anytype) u32 {
    return @as(u32, @intCast(@intFromPtr(p))) | 0xC000_0000;
}

// ---- Constants and state -----------------------------------------------------

var g_setup_dma: [64]u8 align(64) = @splat(0);
var g_ep0_tx: [64]u8 align(64) = @splat(0);
var g_ep0_rx: [64]u8 align(64) = @splat(0);

const spin_long: u32 = 1_000_000;
const mps_hs: u32 = 512; // high-speed bulk max packet
const mps_ep0: u32 = 64;
// A transfer is bounded by PKTCNT (10 bits on this core: 1023 packets) as well
// as XFRSIZ (19 bits).
const max_pkt_cnt: u32 = 1023;
const in_chunk_max: u32 = 512 * 4; // 2048 B == EP1 TX FIFO
const out_chunk_max: u32 = max_pkt_cnt * mps_hs;

var g_evt_sem: rtos.Semaphore = .binary("usb-evt", 0); // posted by the ISR
var g_pending: u32 = 0;
var g_configured = std.atomic.Value(bool).init(false);
var g_dbg: Debug = .{};
var g_cb: ?ConfiguredCallback = null;
var g_cb_arg: ?*anyopaque = null;
var g_identity: Identity = .{};

var g_setup: [8]u8 = @splat(0);
var g_ep0_wlength: u16 = 0;
var g_ep0_expect_status_out = false;
var g_setup_pending = false;
// What EP0 OUT is armed for. In buffer-DMA mode the receipt of a SETUP also
// raises XFERCOMPL, before the SETUP-phase-done interrupt: that completion
// must not be taken for the end of a status stage (the re-arm it caused left
// EP0 OUT disabled under load, the next SETUP stuck in the RX FIFO, and the
// host timing out -- found on the Pi 4 by the C++ capstone).
const Ep0Out = enum { setup, status };
var g_ep0_out: Ep0Out = .setup;

var g_out_buf: [*]u8 = undefined;
var g_out_len: u32 = 0;
var g_out_got: u32 = 0;
var g_out_done = std.atomic.Value(bool).init(false);
var g_in_done = std.atomic.Value(bool).init(false);

// ---- Small helpers -----------------------------------------------------------------

fn waitBitsSet(off: u32, mask: u32, limit: u32) bool {
    var i: u32 = 0;
    while (i < limit) : (i += 1) {
        if (rd(off) & mask == mask) return true;
    }
    return false;
}

fn waitBitsClear(off: u32, mask: u32, limit: u32) bool {
    var i: u32 = 0;
    while (i < limit) : (i += 1) {
        if (rd(off) & mask == 0) return true;
    }
    return false;
}

fn flushRxFifo() void {
    setb(reg.GRSTCTL, bit.RXFFLSH);
    _ = waitBitsClear(reg.GRSTCTL, bit.RXFFLSH, spin_long);
}

fn flushTxFifos() void {
    wr(reg.GRSTCTL, bit.TXFFLSH | bit.TXFNUM_ALL);
    _ = waitBitsClear(reg.GRSTCTL, bit.TXFFLSH, spin_long);
}

// Partition the FIFO RAM: GRXFSIZ/GNPTXFSIZ/DIEPTXF1 hold (start, depth) in
// 32-bit words; the RX FIFO starts at word 0.
fn configureFifos() void {
    var depth = (rd(reg.GHWCFG3) >> 16) & 0xFFFF;
    if (depth == 0) depth = 4096;
    var rx: u32 = 512;
    var ep0: u32 = 128;
    var ep1: u32 = 512;
    if (rx + ep0 + ep1 > depth) {
        rx = 256;
        ep0 = 64;
        ep1 = if (depth > rx + ep0) depth - rx - ep0 else 64;
    }
    wr(reg.GRXFSIZ, rx);
    wr(reg.GNPTXFSIZ, (ep0 << 16) | rx);
    wr(reg.DIEPTXF1, (ep1 << 16) | (rx + ep0));
    // Internal DMA: the EPInfo block reserved at the top of the FIFO RAM.
    wr(reg.GDFIFOCFG, depth | ((rx + ep0 + ep1) << 16));
}

fn readFifo(ep: u32, dst: [*]u8, n: u32) void {
    var i: u32 = 0;
    while (i + 4 <= n) : (i += 4) {
        const w = rd(FIFO(ep));
        dst[i] = @truncate(w);
        dst[i + 1] = @truncate(w >> 8);
        dst[i + 2] = @truncate(w >> 16);
        dst[i + 3] = @truncate(w >> 24);
    }
    if (i < n) {
        const w = rd(FIFO(ep));
        var b: u32 = 0;
        while (b < n - i) : (b += 1) dst[i + b] = @truncate(w >> @intCast(8 * b));
    }
}

fn drainFifo(ep: u32, n: u32) void {
    var words = (n + 3) / 4;
    while (words != 0) : (words -= 1) _ = rd(FIFO(ep));
}

// ---- EP0 -----------------------------------------------------------------------------

// EP0 OUT armed for a SETUP: SUPCNT=3, PKTCNT=1, XFRSIZ=8, DMA'd into
// g_setup_dma (Linux dwc2_hsotg_enqueue_setup()).
fn armEp0Setup() void {
    g_ep0_out = .setup;
    dcCleanInval(&g_setup_dma, g_setup_dma.len);
    wr(DOEPDMA(0), phys(&g_setup_dma));
    wr(DOEPTSIZ(0), (3 << 29) | (1 << 19) | 8);
    wr(DOEPCTL(0), (rd(DOEPCTL(0)) & bit.MPS_MASK) | bit.USBACTEP | bit.EPENA);
}

// EP0 OUT armed for the status stage of a control-IN transfer: a 0-byte OUT,
// into the SETUP buffer -- a SETUP that follows it before EP0 OUT is re-armed
// is then DMA'd where handleEpOut() reads it.
fn armEp0StatusOut() void {
    g_ep0_out = .status;
    dcCleanInval(&g_setup_dma, g_setup_dma.len);
    wr(DOEPDMA(0), phys(&g_setup_dma));
    wr(DOEPTSIZ(0), (3 << 29) | (1 << 19) | 0);
    wr(DOEPCTL(0), (rd(DOEPCTL(0)) & bit.MPS_MASK) | bit.USBACTEP | bit.EPENA | bit.CNAK);
}

fn stallEp0() void {
    setb(DIEPCTL(0), bit.STALL);
    setb(DOEPCTL(0), bit.STALL);
    g_ep0_expect_status_out = false;
    armEp0Setup();
}

fn ep0Send(data: []const u8) void {
    var len: u32 = @intCast(data.len);
    if (len > g_ep0_wlength) len = g_ep0_wlength;
    if (len > mps_ep0) len = mps_ep0; // every descriptor here fits one packet
    @memcpy(g_ep0_tx[0..len], data[0..len]);
    dcClean(&g_ep0_tx, if (len != 0) len else 1);
    wr(DIEPDMA(0), phys(&g_ep0_tx));
    wr(DIEPTSIZ(0), (1 << 19) | (len & 0x7F));
    wr(DIEPCTL(0), (rd(DIEPCTL(0)) & bit.MPS_MASK) | bit.USBACTEP | bit.EPENA | bit.CNAK);
}

fn deviceDesc() [18]u8 {
    const v = g_identity.vid;
    const p = g_identity.pid;
    return .{
        18, 0x01, 0x00, 0x02, // bLength, DEVICE, bcdUSB 2.00
        0xFF, 0x00, 0x00, 64, // class 0xFF/0/0, bMaxPacketSize0
        @truncate(v), @truncate(v >> 8), // idVendor
        @truncate(p), @truncate(p >> 8), // idProduct
        0x00, 0x01, // bcdDevice 1.00
        1, 2, 3, // iManufacturer/iProduct/iSerialNumber
        1, // bNumConfigurations
    };
}

const config_desc = [_]u8{
    9, 0x02, 32, 0x00, 1, 1, 0, 0x80, 50, // CONFIG, total 32, 100 mA
    9, 0x04, 0, 0, 2, 0xFF, 0x00, 0x00, 0, // INTERFACE 0, 0xFF, 2 EPs
    7, 0x05, 0x81, 0x02, 0x00, 0x02, 0, // EP 0x81 BULK IN, 512
    7, 0x05, 0x01, 0x02, 0x00, 0x02, 0, // EP 0x01 BULK OUT, 512
};

fn buildString(index: u32, out: []u8) u32 {
    if (index == 0) {
        if (out.len < 4) return 0;
        out[0..4].* = .{ 4, 0x03, 0x09, 0x04 }; // langid 0x0409
        return 4;
    }
    const s: []const u8 = switch (index) {
        1 => "uOS++",
        2 => "uOS++ bulk test gadget",
        3 => "0001",
        else => return 0,
    };
    var n: u32 = @intCast(s.len);
    if (2 + 2 * n > out.len) n = @intCast((out.len - 2) / 2);
    out[0] = @intCast(2 + 2 * n);
    out[1] = 0x03;
    for (0..n) |i| {
        out[2 + 2 * i] = s[i];
        out[3 + 2 * i] = 0;
    }
    return 2 + 2 * n;
}

fn setConfiguration(on: bool) void {
    if (on) {
        // EP1 IN on TX FIFO 1 (DIEPTXF1), not EP0's non-periodic FIFO 0.
        wr(DIEPCTL(1), bit.USBACTEP | bit.EPTYP_BULK | mps_hs | bit.TXFNUM(1));
        wr(DOEPCTL(1), bit.USBACTEP | bit.EPTYP_BULK | mps_hs | bit.CNAK);
        setb(reg.DAINTMSK, bit.DAINT_IN(1) | bit.DAINT_OUT(1));
        g_configured.store(true, .seq_cst);
    } else {
        clrb(reg.DAINTMSK, bit.DAINT_IN(1) | bit.DAINT_OUT(1));
        setb(DIEPCTL(1), bit.SNAK);
        setb(DOEPCTL(1), bit.SNAK);
        g_configured.store(false, .seq_cst);
    }
}

var g_strbuf: [64]u8 = undefined;

fn handleSetup() void {
    clrb(DIEPCTL(0), bit.STALL);
    clrb(DOEPCTL(0), bit.STALL);
    const bm_rt = g_setup[0];
    const b_req = g_setup[1];
    const w_value: u16 = @as(u16, g_setup[2]) | (@as(u16, g_setup[3]) << 8);
    g_ep0_wlength = @as(u16, g_setup[6]) | (@as(u16, g_setup[7]) << 8);
    // A non-zero wLength on a standard request here is a device-to-host data
    // stage: an OUT status stage follows the IN data.
    g_ep0_expect_status_out = g_ep0_wlength != 0;

    // The standard requests only; class and vendor requests STALL.
    if (bm_rt & 0x60 != 0) return stallEp0();

    switch (b_req) {
        0x06 => { // GET_DESCRIPTOR
            const kind = w_value >> 8;
            const index: u32 = w_value & 0xFF;
            if (kind == 1) {
                const d = deviceDesc();
                ep0Send(&d);
            } else if (kind == 2) {
                ep0Send(&config_desc);
            } else if (kind == 3) {
                const n = buildString(index, &g_strbuf);
                if (n == 0) stallEp0() else ep0Send(g_strbuf[0..n]);
            } else {
                stallEp0(); // device qualifier etc.
            }
        },
        0x05 => { // SET_ADDRESS: at once; the core holds it until the status stage
            modify(reg.DCFG, bit.DAD_MASK, (@as(u32, w_value & 0x7F) << bit.DAD_SHIFT) & bit.DAD_MASK);
            ep0Send(&.{});
        },
        0x08 => ep0Send(&.{if (g_configured.load(.seq_cst)) 1 else 0}), // GET_CONFIGURATION
        0x09 => { // SET_CONFIGURATION
            setConfiguration(w_value != 0);
            ep0Send(&.{});
        },
        0x0A => ep0Send(&.{0}), // GET_INTERFACE
        0x0B => ep0Send(&.{}), // SET_INTERFACE
        0x00 => ep0Send(&.{ 0, 0 }), // GET_STATUS
        0x01, 0x03 => ep0Send(&.{}), // CLEAR_FEATURE, SET_FEATURE
        else => stallEp0(),
    }
}

// ---- Bulk endpoints ------------------------------------------------------------------

fn armBulkOut(len: u32) void {
    var pktcnt = (len + mps_hs - 1) / mps_hs;
    if (pktcnt == 0) pktcnt = 1;
    dcCleanInval(g_out_buf, if (len != 0) len else 1);
    wr(DOEPDMA(1), phys(g_out_buf));
    wr(DOEPTSIZ(1), (pktcnt << 19) | (len & 0x7FFFF));
    wr(DOEPCTL(1), bit.USBACTEP | bit.EPTYP_BULK | mps_hs | bit.EPENA | bit.CNAK);
}

fn programBulkIn(p: [*]const u8, len: u32) void {
    var pktcnt = (len + mps_hs - 1) / mps_hs;
    if (pktcnt == 0) pktcnt = 1;
    dcClean(p, if (len != 0) len else 1);
    wr(DIEPDMA(1), phys(p));
    wr(DIEPTSIZ(1), (pktcnt << 19) | (len & 0x7FFFF));
    wr(DIEPCTL(1), bit.USBACTEP | bit.EPTYP_BULK | mps_hs | bit.TXFNUM(1) | bit.EPENA | bit.CNAK);
}

// ---- Event handlers (the service thread) ---------------------------------------------

fn handleBusReset() void {
    g_dbg.usbrst += 1;
    g_configured.store(false, .seq_cst);
    modify(reg.DCFG, bit.DAD_MASK, 0);
    clrb(DIEPCTL(0), bit.STALL);
    clrb(DOEPCTL(0), bit.STALL);
    wr(reg.DAINTMSK, bit.DAINT_IN(0) | bit.DAINT_OUT(0));
    g_ep0_expect_status_out = false;
    flushRxFifo();
    flushTxFifos();
    armEp0Setup();
}

fn handleEnumDone() void {
    g_dbg.enumdone += 1;
    g_dbg.dsts = rd(reg.DSTS);
    // EP0 max packet 64 at HS and FS: MPS field 0.
    modify(DIEPCTL(0), bit.MPS_MASK, 0);
    modify(DOEPCTL(0), bit.MPS_MASK, 0);
    setb(DIEPCTL(0), bit.USBACTEP);
    setb(DOEPCTL(0), bit.USBACTEP);
    clrb(DIEPCTL(0), bit.STALL);
    clrb(DOEPCTL(0), bit.STALL);
    armEp0Setup();
}

fn handleEpIn() void {
    const pending = rd(reg.DAINT) & rd(reg.DAINTMSK);
    var n: u32 = 0;
    while (n < 16) : (n += 1) {
        if (pending & bit.DAINT_IN(n) == 0) continue;
        const st = rd(DIEPINT(n));
        wr(DIEPINT(n), st);
        if (st & bit.XFERCOMPL == 0) continue;
        if (n == 0) {
            g_dbg.ep0_in += 1;
            // Data stage done: the OUT status follows; no data: the IN ZLP
            // was the status, back to waiting for a SETUP.
            if (g_ep0_expect_status_out) armEp0StatusOut() else armEp0Setup();
        } else if (n == 1) {
            g_dbg.iep += 1;
            g_in_done.store(true, .seq_cst);
        }
    }
}

fn handleEpOut() void {
    const pending = (rd(reg.DAINT) & rd(reg.DAINTMSK)) >> 16;
    var n: u32 = 0;
    while (n < 16) : (n += 1) {
        if (pending & (@as(u32, 1) << @intCast(n)) == 0) continue;
        const st = rd(DOEPINT(n));
        wr(DOEPINT(n), st);
        if (n == 0) {
            if (st & bit.SETUP != 0) {
                // DMA mode: the 8 SETUP bytes are in g_setup_dma.
                dcInval(&g_setup_dma, 8);
                g_setup = g_setup_dma[0..8].*;
                handleSetup();
                continue;
            }
            if (st & bit.XFERCOMPL != 0) {
                g_dbg.ep0_out += 1;
                // The end of a status stage: back to waiting for a SETUP. The
                // receipt of a SETUP completes too: its SETUP interrupt follows.
                if (g_ep0_out == .status) {
                    g_ep0_expect_status_out = false;
                    armEp0Setup();
                }
            }
        } else if (n == 1) {
            if (st & bit.XFERCOMPL != 0) {
                g_dbg.oep += 1;
                // The core decremented XFRSIZ by what it received: the
                // residue is what is left of the length programmed (Linux
                // dwc2_hsotg_handle_outdone()).
                const residue = rd(DOEPTSIZ(1)) & 0x7FFFF;
                g_out_got = if (g_out_len > residue) g_out_len - residue else 0;
                dcInval(g_out_buf, if (g_out_len != 0) g_out_len else 1);
                g_out_done.store(true, .seq_cst);
            }
        }
    }
}

// The PIO path (RXFLVL): unused in DMA mode, where RXFLVL is never unmasked;
// kept as the C++ driver keeps it.
fn handleRxFifo() void {
    while (rd(reg.GINTSTS) & bit.RXFLVL != 0) {
        const sts = rd(reg.GRXSTSP);
        const ep = sts & bit.RXSTSP_EPNUM_MASK;
        const bcnt = (sts >> bit.RXSTSP_BCNT_SHIFT) & bit.RXSTSP_BCNT_MASK;
        const pktsts = (sts >> bit.RXSTSP_PKTSTS_SHIFT) & bit.RXSTSP_PKTSTS_MASK;
        g_dbg.rx_pkts += 1;
        switch (pktsts) {
            6 => { // SETUP data
                g_dbg.setups += 1;
                readFifo(0, &g_setup, if (bcnt < 8) bcnt else 8);
                g_setup_pending = true;
            },
            2 => { // OUT data
                if (ep == 1) {
                    const room = if (g_out_len > g_out_got) g_out_len - g_out_got else 0;
                    const take = if (bcnt < room) bcnt else room;
                    if (take != 0) readFifo(1, g_out_buf + g_out_got, take);
                    if (bcnt > take) drainFifo(1, bcnt - take);
                    g_out_got += take;
                } else drainFifo(ep, bcnt);
            },
            3 => if (ep == 1) g_out_done.store(true, .seq_cst), // OUT transfer complete
            4 => { // SETUP stage complete
                if (g_setup_pending) {
                    g_setup_pending = false;
                    setb(DOEPTSIZ(0), 3 << 29);
                    wr(DOEPINT(0), bit.SETUP);
                    handleSetup();
                }
                if (bcnt != 0) drainFifo(ep, bcnt);
            },
            else => if (bcnt != 0) drainFifo(ep, bcnt),
        }
    }
}

// One batch of events, waiting on the ISR's semaphore. The application's
// callback runs in the service thread and ep_read/ep_write call this same
// function: there is only ever one waiter.
fn serviceEventsOnce() void {
    g_dbg.service_loops += 1;
    g_evt_sem.wait() catch {};
    const ev = blk: {
        const cs = rtos.interrupts.CriticalSection.enter();
        defer cs.exit();
        const v = g_pending;
        g_pending = 0;
        break :blk v;
    };
    if (ev == 0) return;
    if (ev & bit.USBRST != 0) handleBusReset();
    if (ev & bit.ENUMDONE != 0) handleEnumDone();
    if (ev & bit.RXFLVL != 0) handleRxFifo();
    if (ev & bit.IEPINT != 0) handleEpIn();
    if (ev & bit.OEPINT != 0) handleEpOut();
    // USBSUSP is acknowledged by clearing its status bit below.
    wr(reg.GINTSTS, ev);
    setb(reg.GINTMSK, ev & (bit.USBRST | bit.ENUMDONE | bit.RXFLVL | bit.IEPINT | bit.OEPINT | bit.USBSUSP));
}

// ---- Public interface -------------------------------------------------------------------

pub fn probeHw() HwInfo {
    return .{ .snpsid = rd(reg.GSNPSID), .hwcfg1 = rd(reg.GHWCFG1), .hwcfg2 = rd(reg.GHWCFG2), .hwcfg3 = rd(reg.GHWCFG3), .hwcfg4 = rd(reg.GHWCFG4) };
}

/// Power the block, reset the core, force device mode, size the FIFOs,
/// unmask the device interrupts, enable INTID 105 (to core 0) and attach.
pub fn init(identity: Identity) InitResult {
    g_identity = identity;
    // The firmware may have left the block on; the real gate is the identity.
    _ = mailbox.setPowerState(mailbox.power_device_usb, true);

    // A DWC2 core identifies as "OT" + version.
    if (rd(reg.GSNPSID) & 0xFFFF_0000 != 0x4F54_0000) return .bad_id;


    if (!waitBitsSet(reg.GRSTCTL, bit.AHBIDLE, spin_long)) return .reset_timeout;
    setb(reg.GRSTCTL, bit.CSRST);
    if (!waitBitsClear(reg.GRSTCTL, bit.CSRST, spin_long)) return .reset_timeout;
    if (!waitBitsSet(reg.GRSTCTL, bit.AHBIDLE, spin_long)) return .reset_timeout;

    // Device mode; the 8-bit UTMI PHY needs TRDT = 9.
    modify(reg.GUSBCFG, bit.FHMOD | bit.TRDT_MASK, bit.FDMOD | (@as(u32, 9) << bit.TRDT_SHIFT));
    var device = false;
    var i: u32 = 0;
    while (i < spin_long) : (i += 1) {
        if (rd(reg.GINTSTS) & bit.CURMOD == 0) {
            device = true;
            break;
        }
    }
    // QEMU models the DWC2 as a host controller only: device mode never settles.
    if (!device) return .no_device_mode;

    wr(reg.PCGCCTL, 0);
    // B-session valid forced; the non-zero-length status OUT handshake.
    modify(reg.GOTGCTL, bit.AVALOEN, bit.BVALOEN | bit.BVALOVAL);
    setb(reg.DCFG, bit.NZLSOHSK);
    modify(reg.DCFG, bit.DSPD_MASK, bit.DSPD_HS);
    modify(reg.DCFG, bit.DAD_MASK, 0);

    // Power-On Programming Done, pulsed.
    setb(reg.DCTL, bit.POPRGDNE);
    for (0..1000) |_| asm volatile ("nop");
    clrb(reg.DCTL, bit.POPRGDNE);

    configureFifos();
    flushRxFifo();
    flushTxFifos();

    // Stale latches from the boot firmware cleared.
    wr(reg.GINTSTS, 0xFFFF_FFFF);
    wr(DIEPINT(0), 0xFFFF_FFFF);
    wr(DOEPINT(0), 0xFFFF_FFFF);
    wr(DIEPINT(1), 0xFFFF_FFFF);
    wr(DOEPINT(1), 0xFFFF_FFFF);

    // Internal DMA: completions as DIEPINT/DOEPINT, no RXFLVL data.
    wr(reg.GINTMSK, bit.USBRST | bit.ENUMDONE | bit.IEPINT | bit.OEPINT | bit.USBSUSP);
    wr(reg.DIEPMSK, bit.XFERCOMPL);
    wr(reg.DOEPMSK, bit.XFERCOMPL | bit.SETUP);
    wr(reg.DAINTMSK, bit.DAINT_IN(0) | bit.DAINT_OUT(0));

    armEp0Setup();

    // The interrupt routed and enabled, then the global enable, then the soft
    // disconnect released: the host cannot enumerate into an unwired core.
    uos.port.gic.setPriority(intid, uos.port.gic_mod.PRIORITY);
    uos.port.gic.enableIrq(intid);
    setb(reg.GAHBCFG, bit.GINT_GLBL | bit.DMAEN);
    clrb(reg.DCTL, bit.SDIS | bit.RWUSIG);
    return .ok;
}

/// The interrupt: the events masked and recorded, the semaphore posted. No
/// FIFO access.
pub fn isr() void {
    g_dbg.isr_calls += 1;
    if (uos.port.scheduler.cpuId() != 0) {
        g_dbg.isr_offcore += 1;
        return;
    }
    g_dbg.gintsts = rd(reg.GINTSTS);
    const sts = g_dbg.gintsts & rd(reg.GINTMSK);
    if (sts == 0) return;
    clrb(reg.GINTMSK, sts);
    {
        const cs = rtos.interrupts.CriticalSection.enter();
        defer cs.exit();
        g_pending |= sts;
    }
    g_evt_sem.post() catch {};
}

pub fn setConfiguredCallback(cb: ConfiguredCallback, arg: ?*anyopaque) void {
    g_cb = cb;
    g_cb_arg = arg;
}

pub fn configured() bool {
    return g_configured.load(.seq_cst);
}

pub fn debug() *const Debug {
    return &g_dbg;
}

pub fn snapshot() RegSnapshot {
    return .{ .dcfg = rd(reg.DCFG), .dctl = rd(reg.DCTL), .dsts = rd(reg.DSTS), .gintsts = rd(reg.GINTSTS), .gintmsk = rd(reg.GINTMSK), .gahbcfg = rd(reg.GAHBCFG) };
}

/// Never returns: the core-0 service thread. It pumps events until the
/// device is configured, runs the callback, and keeps pumping after.
pub fn serviceThreadBody() noreturn {
    armEp0Setup();
    while (!g_configured.load(.seq_cst)) serviceEventsOnce();
    if (g_cb) |cb| cb(g_cb_arg);
    while (true) serviceEventsOnce();
}

/// Blocking, service-thread only. Bytes moved, or -1 when not configured.
pub fn epRead(buf: []u8) i32 {
    if (!configured()) return -1;
    var done: u32 = 0;
    const len: u32 = @intCast(buf.len);
    while (done < len) {
        const chunk = @min(len - done, out_chunk_max);
        g_out_buf = buf.ptr + done;
        g_out_len = chunk;
        g_out_got = 0;
        g_out_done.store(false, .seq_cst);
        armBulkOut(chunk);
        while (!g_out_done.load(.seq_cst)) serviceEventsOnce();
        done += g_out_got;
        if (g_out_got < chunk) break; // a short packet ends the transfer
    }
    return @intCast(done);
}

pub fn epWrite(buf: []const u8) i32 {
    return epWrite_(buf, true);
}

/// As epWrite(), without the zero-length packet after a multiple of the
/// packet size: for a stream the host reads as one long transfer.
pub fn epWriteStream(buf: []const u8) i32 {
    return epWrite_(buf, false);
}

fn epWrite_(buf: []const u8, zlp: bool) i32 {
    if (!configured()) return -1;
    var done: u32 = 0;
    const len: u32 = @intCast(buf.len);
    while (done < len) {
        const chunk = @min(len - done, in_chunk_max);
        g_in_done.store(false, .seq_cst);
        programBulkIn(buf.ptr + done, chunk);
        while (!g_in_done.load(.seq_cst)) serviceEventsOnce();
        done += chunk;
    }
    // An exact multiple of wMaxPacketSize needs a zero-length packet, or the
    // host's read waits for its timeout.
    if (zlp and len != 0 and len % mps_hs == 0) {
        g_in_done.store(false, .seq_cst);
        programBulkIn(buf.ptr, 0);
        while (!g_in_done.load(.seq_cst)) serviceEventsOnce();
    }
    return @intCast(done);
}
