//! spi-pipeline -- WeAct Studio F411CE SPI filesystem pipeline in Zig.
//!
//! Five threads, two handoff slots, eight semaphores, two partitions, and
//! end-to-end CRC-32 verification across 8 iterations.
//!
//!   image ──T1──▶ [buffer] ──T2──▶ [buffer_b64] ──T3──▶ enc<n>.b64
//!    0x08000000    256 B    Base64    ≤344 B    append   (partition 1)
//!                                                  │
//!                                       snapshot   ├──▶ T4  blink + UART
//!                                       file_done  └──▶ T5  decode, CRC,
//!                                                            dec<n>.bin
//!                                                            (partition 2)

const std = @import("std");
const uos = @import("uos");
const t = @import("uos_test");
const board = @import("uos_board");
const rtos = uos.rtos;
const sysclock = rtos.sysclock;

pub const microzig_options = t.microzig_options;
pub const panic = t.panic;
pub const std_options = t.std_options;
pub const uos_options = t.options(.{
    .dynamic_memory_size_bytes = 16 * 1024,
});

comptime {
    t.exportStartup();
}

pub fn main() void {
    t.run(appMain);
}

// ============================================================================
// Constants and Sizing
// ============================================================================

const IMAGE_BASE: usize = 0x0800_0000;
const CHUNK: usize = 256;
const B64_MAX: usize = 344;
const ITERATIONS: usize = 8;
const BLINK_CYCLES: usize = 5;
const BLINK_HALF: u32 = 300; // ms
const PRODUCE_SPAN: u32 = 2400; // ms for whole source
const SNAPSHOT_WAIT: u32 = 400; // ms
const SNAPSHOT_SHOW: usize = 96;
const RAM_SOURCE_MAX: usize = 8000;
const RAM_CAP: usize = 10752;
const APP_BASE: u32 = 0x0010_0000;

fn chunks(len: usize) usize {
    return (len + CHUNK - 1) / CHUNK;
}

fn chunkLen(len: usize, i: usize) usize {
    const start = i * CHUNK;
    if (start >= len) return 0;
    if (len - start < CHUNK) return len - start;
    return CHUNK;
}

fn pace(len: usize) u32 {
    const c = chunks(len);
    const step: u32 = if (c > 0) @max(1, PRODUCE_SPAN / @as(u32, @intCast(c))) else 1;
    return step;
}

fn encodedTotal(len: usize) u32 {
    const full = len / CHUNK;
    const rem = len % CHUNK;
    const enc = struct {
        fn calc(n: usize) usize {
            return ((n + 2) / 3) * 4;
        }
    }.calc;
    return @intCast(full * enc(CHUNK) + if (rem != 0) enc(rem) else 0);
}

// ============================================================================
// Base64 (RFC 4648 §4)
// ============================================================================

const base64 = struct {
    const ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

    pub fn encodedLen(n: usize) usize {
        return ((n + 2) / 3) * 4;
    }

    pub fn encode(src: []const u8, dst: []u8) usize {
        var i: usize = 0;
        var o: usize = 0;
        while (i + 3 <= src.len) : (i += 3) {
            const v = (@as(u32, src[i]) << 16) | (@as(u32, src[i + 1]) << 8) | @as(u32, src[i + 2]);
            dst[o + 0] = ALPHABET[(v >> 18) & 63];
            dst[o + 1] = ALPHABET[(v >> 12) & 63];
            dst[o + 2] = ALPHABET[(v >> 6) & 63];
            dst[o + 3] = ALPHABET[v & 63];
            o += 4;
        }
        const rem = src.len - i;
        if (rem == 1) {
            const v = @as(u32, src[i]) << 16;
            dst[o + 0] = ALPHABET[(v >> 18) & 63];
            dst[o + 1] = ALPHABET[(v >> 12) & 63];
            dst[o + 2] = '=';
            dst[o + 3] = '=';
            o += 4;
        } else if (rem == 2) {
            const v = (@as(u32, src[i]) << 16) | (@as(u32, src[i + 1]) << 8);
            dst[o + 0] = ALPHABET[(v >> 18) & 63];
            dst[o + 1] = ALPHABET[(v >> 12) & 63];
            dst[o + 2] = ALPHABET[(v >> 6) & 63];
            dst[o + 3] = '=';
            o += 4;
        }
        return o;
    }

    fn charVal(c: u8) ?u8 {
        if (c >= 'A' and c <= 'Z') return c - 'A';
        if (c >= 'a' and c <= 'z') return c - 'a' + 26;
        if (c >= '0' and c <= '9') return c - '0' + 52;
        if (c == '+') return 62;
        if (c == '/') return 63;
        return null;
    }

    pub fn decode(src: []const u8, dst: []u8) ?usize {
        if (src.len % 4 != 0) return null;
        var i: usize = 0;
        var o: usize = 0;
        while (i < src.len) : (i += 4) {
            const is_last = (i + 4 == src.len);
            const c0 = charVal(src[i + 0]) orelse return null;
            const c1 = charVal(src[i + 1]) orelse return null;
            if (src[i + 2] == '=') {
                if (!is_last or src[i + 3] != '=') return null;
                if (o >= dst.len) return null;
                dst[o] = @intCast((@as(u16, c0) << 2) | (@as(u16, c1) >> 4));
                o += 1;
            } else if (src[i + 3] == '=') {
                if (!is_last) return null;
                const c2 = charVal(src[i + 2]) orelse return null;
                if (o + 2 > dst.len) return null;
                const v = (@as(u32, c0) << 18) | (@as(u32, c1) << 12) | (@as(u32, c2) << 6);
                dst[o + 0] = @intCast((v >> 16) & 0xFF);
                dst[o + 1] = @intCast((v >> 8) & 0xFF);
                o += 2;
            } else {
                const c2 = charVal(src[i + 2]) orelse return null;
                const c3 = charVal(src[i + 3]) orelse return null;
                if (o + 3 > dst.len) return null;
                const v = (@as(u32, c0) << 18) | (@as(u32, c1) << 12) | (@as(u32, c2) << 6) | @as(u32, c3);
                dst[o + 0] = @intCast((v >> 16) & 0xFF);
                dst[o + 1] = @intCast((v >> 8) & 0xFF);
                dst[o + 2] = @intCast(v & 0xFF);
                o += 3;
            }
        }
        return o;
    }

    pub fn selfTest() bool {
        const vectors = [_]struct { in: []const u8, out: []const u8 }{
            .{ .in = "", .out = "" },
            .{ .in = "f", .out = "Zg==" },
            .{ .in = "fo", .out = "Zm8=" },
            .{ .in = "foo", .out = "Zm9v" },
            .{ .in = "foob", .out = "Zm9vYg==" },
            .{ .in = "fooba", .out = "Zm9vYmE=" },
            .{ .in = "foobar", .out = "Zm9vYmFy" },
        };
        var enc_buf: [32]u8 = undefined;
        var dec_buf: [32]u8 = undefined;
        for (vectors) |v| {
            const elen = encode(v.in, &enc_buf);
            if (!std.mem.eql(u8, enc_buf[0..elen], v.out)) return false;
            const dlen = decode(v.out, &dec_buf) orelse return false;
            if (!std.mem.eql(u8, dec_buf[0..dlen], v.in)) return false;
        }
        return true;
    }
};

// ============================================================================
// CRC-32 (IEEE 802.3 / zlib)
// ============================================================================

fn crc32Update(crc_in: u32, data: []const u8) u32 {
    var crc = crc_in;
    for (data) |b| {
        crc ^= b;
        for (0..8) |_| {
            if (crc & 1 != 0) {
                crc = (crc >> 1) ^ 0xEDB88320;
            } else {
                crc >>= 1;
            }
        }
    }
    return crc;
}

fn crc32(data: []const u8) u32 {
    return ~crc32Update(0xFFFF_FFFF, data);
}

// ============================================================================
// Hardware SPI1 & Flash Driver on STM32F411
// ============================================================================

const RCC_AHB1ENR: *volatile u32 = @ptrFromInt(0x4002_3830);
const RCC_APB2ENR: *volatile u32 = @ptrFromInt(0x4002_3844);

const GPIOA_MODER: *volatile u32 = @ptrFromInt(0x4002_0000);
const GPIOA_OTYPER: *volatile u32 = @ptrFromInt(0x4002_0004);
const GPIOA_OSPEEDR: *volatile u32 = @ptrFromInt(0x4002_0008);
const GPIOA_PUPDR: *volatile u32 = @ptrFromInt(0x4002_000C);
const GPIOA_AFRL: *volatile u32 = @ptrFromInt(0x4002_0020);
const GPIOA_BSRR: *volatile u32 = @ptrFromInt(0x4002_0018);

const SPI1_CR1: *volatile u32 = @ptrFromInt(0x4001_3000);
const SPI1_CR2: *volatile u32 = @ptrFromInt(0x4001_3004);
const SPI1_SR: *volatile u32 = @ptrFromInt(0x4001_3008);
const SPI1_DR: *volatile u32 = @ptrFromInt(0x4001_300C);

const JedecId = struct {
    manufacturer: u8,
    mem_type: u8,
    capacity: u8,
};

const spi = struct {
    pub fn init() void {
        RCC_AHB1ENR.* |= 1; // GPIOA
        RCC_APB2ENR.* |= (1 << 12); // SPI1

        // PA4 = CS, push-pull output, very high speed, pull-up, deasserted
        GPIOA_MODER.* = (GPIOA_MODER.* & ~(@as(u32, 3) << 8)) | (@as(u32, 1) << 8);
        GPIOA_OTYPER.* &= ~(@as(u32, 1) << 4);
        GPIOA_OSPEEDR.* |= (@as(u32, 3) << 8);
        GPIOA_PUPDR.* = (GPIOA_PUPDR.* & ~(@as(u32, 3) << 8)) | (@as(u32, 1) << 8);
        csDeassert();

        // PA5=SCK, PA6=MISO, PA7=MOSI: AF5, push-pull, very high speed, pull-up
        inline for (.{ 5, 6, 7 }) |pin| {
            GPIOA_MODER.* = (GPIOA_MODER.* & ~(@as(u32, 3) << (pin * 2))) | (@as(u32, 2) << (pin * 2));
            GPIOA_OTYPER.* &= ~(@as(u32, 1) << pin);
            GPIOA_OSPEEDR.* |= (@as(u32, 3) << (pin * 2));
            GPIOA_PUPDR.* = (GPIOA_PUPDR.* & ~(@as(u32, 3) << (pin * 2))) | (@as(u32, 1) << (pin * 2));
            const shift = pin * 4;
            GPIOA_AFRL.* = (GPIOA_AFRL.* & ~(@as(u32, 0xF) << shift)) | (@as(u32, 5) << shift);
        }

        // SPI1: master, BR/4 (25 MHz), Mode 0, 8-bit, MSB-first, SSM, SSI, SPE
        SPI1_CR1.* = (1 << 2) | (1 << 3) | (1 << 8) | (1 << 9) | (1 << 6);
    }

    pub fn csAssert() void {
        GPIOA_BSRR.* = (1 << (4 + 16)); // PA4 low
    }

    pub fn csDeassert() void {
        while ((SPI1_SR.* & (1 << 7)) != 0) {} // Wait for BSY to clear
        GPIOA_BSRR.* = (1 << 4); // PA4 high
    }

    pub fn xfer(data: u8) u8 {
        while ((SPI1_SR.* & (1 << 1)) == 0) {} // TXE
        SPI1_DR.* = data;
        while ((SPI1_SR.* & (1 << 0)) == 0) {} // RXNE
        return @truncate(SPI1_DR.*);
    }

    pub fn readId() JedecId {
        csAssert();
        _ = xfer(0x9F);
        const mfg = xfer(0xFF);
        const mtype = xfer(0xFF);
        const cap = xfer(0xFF);
        csDeassert();
        return .{ .manufacturer = mfg, .mem_type = mtype, .capacity = cap };
    }
};

// ============================================================================
// Storage Subsystem (SPI NOR Flash & RAM Disk Backends)
// ============================================================================

const Which = enum { encoded, decoded };

const RamFile = struct {
    name: [16]u8 = undefined,
    name_len: usize = 0,
    len: usize = 0,
    live: bool = false,
    bytes: [RAM_CAP]u8 = undefined,

    fn matches(self: *const RamFile, n: []const u8) bool {
        return self.live and self.name_len == n.len and std.mem.eql(u8, self.name[0..self.name_len], n);
    }
};

const MAGIC: u32 = 0x4641_4C31;
const VERSION: u32 = 1;
const TOC_CAP: u32 = 64;
const NAME_MAX: usize = 16;
const STATE_FREE: u32 = 0xFFFF_FFFF;
const STATE_LIVE: u32 = 0x4C49_5645;
const SUPER_SIZE: usize = 32;
const ENTRY_SIZE: usize = 32;
const BLOB_OFF: u32 = 2080;

fn round4k(bytes: u32) u32 {
    return ((bytes + 4095) / 4096) * 4096;
}

fn encodedPartition(src_len: usize) Partition {
    const enc_len = encodedTotal(src_len);
    const size = round4k(BLOB_OFF + enc_len * @as(u32, @intCast(ITERATIONS)));
    return .{ .base = APP_BASE, .size = size };
}

fn decodedPartition(src_len: usize) Partition {
    const enc = encodedPartition(src_len);
    const dec_len: u32 = @intCast(src_len);
    const size = round4k(BLOB_OFF + dec_len * @as(u32, @intCast(ITERATIONS)));
    return .{ .base = enc.base + enc.size, .size = size };
}

fn nameEq(stored: []const u8, query: []const u8) bool {
    var i: usize = 0;
    while (i < NAME_MAX) : (i += 1) {
        const q: u8 = if (i < query.len) query[i] else 0;
        if (stored[i] != q) return false;
        if (stored[i] == 0) return true;
    }
    return true;
}

const FlatFsError = enum {
    none,
    not_formatted,
    bad_name,
    toc_full,
    no_space,
    buffer_too_small,
    corrupt,
    flash_timeout,
};

const FlatFsEntry = struct {
    name: [NAME_MAX]u8 = @splat(0),
    offset: u32 = 0,
    size: u32 = 0,
    crc: u32 = 0,
    state: u32 = STATE_FREE,

    pub fn nameLen(self: *const FlatFsEntry) usize {
        var i: usize = 0;
        while (i < NAME_MAX and self.name[i] != 0) : (i += 1) {}
        return i;
    }
};

const flash = struct {
    fn csSettle() void {
        for (0..24) |_| {
            asm volatile ("nop");
        }
    }

    fn writeEnable() void {
        csSettle();
        spi.csAssert();
        _ = spi.xfer(0x06);
        spi.csDeassert();
        csSettle();
    }

    fn readStatus1() u8 {
        csSettle();
        spi.csAssert();
        _ = spi.xfer(0x05);
        const st = spi.xfer(0xFF);
        spi.csDeassert();
        csSettle();
        return st;
    }

    fn waitIdle() bool {
        for (0..8000) |_| {
            if ((readStatus1() & 0x01) == 0) return true;
            for (0..4000) |_| {
                asm volatile ("nop");
            }
        }
        return false;
    }

    pub fn read(addr: u32, out: []u8) void {
        if (out.len == 0) return;
        csSettle();
        spi.csAssert();
        _ = spi.xfer(0x03);
        _ = spi.xfer(@intCast((addr >> 16) & 0xFF));
        _ = spi.xfer(@intCast((addr >> 8) & 0xFF));
        _ = spi.xfer(@intCast(addr & 0xFF));
        for (out) |*b| {
            b.* = spi.xfer(0xFF);
        }
        spi.csDeassert();
        csSettle();
    }

    pub fn pageProgram(addr: u32, data: []const u8) bool {
        if (data.len == 0) return true;
        writeEnable();
        csSettle();
        spi.csAssert();
        _ = spi.xfer(0x02);
        _ = spi.xfer(@intCast((addr >> 16) & 0xFF));
        _ = spi.xfer(@intCast((addr >> 8) & 0xFF));
        _ = spi.xfer(@intCast(addr & 0xFF));
        for (data) |b| {
            _ = spi.xfer(b);
        }
        spi.csDeassert();
        csSettle();
        return waitIdle();
    }

    pub fn write(addr: u32, data: []const u8) bool {
        var a = addr;
        var pos: usize = 0;
        while (pos < data.len) {
            const page_room = 256 - (a & 0xFF);
            const chunk = @min(page_room, data.len - pos);
            if (!pageProgram(a, data[pos .. pos + chunk])) return false;
            pos += chunk;
            a += @intCast(chunk);
        }
        return true;
    }

    pub fn sectorErase(addr: u32) bool {
        writeEnable();
        csSettle();
        spi.csAssert();
        _ = spi.xfer(0x20);
        _ = spi.xfer(@intCast((addr >> 16) & 0xFF));
        _ = spi.xfer(@intCast((addr >> 8) & 0xFF));
        _ = spi.xfer(@intCast(addr & 0xFF));
        spi.csDeassert();
        csSettle();
        return waitIdle();
    }
};

const Partition = struct {
    base: u32,
    size: u32,

    pub fn valid(self: *const Partition) bool {
        var b: [SUPER_SIZE]u8 = undefined;
        flash.read(self.base, &b);
        const magic = std.mem.readInt(u32, b[0..4], .little);
        const version = std.mem.readInt(u32, b[4..8], .little);
        const toc_off = std.mem.readInt(u32, b[8..12], .little);
        const toc_cap = std.mem.readInt(u32, b[12..16], .little);
        const blob_off = std.mem.readInt(u32, b[16..20], .little);

        const first_legal_blob = SUPER_SIZE + TOC_CAP * ENTRY_SIZE;
        return (magic == MAGIC and version == VERSION and toc_off == SUPER_SIZE and
            toc_cap == TOC_CAP and blob_off >= first_legal_blob and blob_off < self.size);
    }

    pub fn readEntryRaw(self: *const Partition, slot: u32, b: *[ENTRY_SIZE]u8) void {
        const addr = self.base + @as(u32, @intCast(SUPER_SIZE)) + slot * @as(u32, @intCast(ENTRY_SIZE));
        flash.read(addr, b);
    }

    pub fn frontier(self: *const Partition) u32 {
        var b: [SUPER_SIZE]u8 = undefined;
        flash.read(self.base, &b);
        var f = std.mem.readInt(u32, b[16..20], .little);
        var slot: u32 = 0;
        while (slot < TOC_CAP) : (slot += 1) {
            var raw_entry: [ENTRY_SIZE]u8 = undefined;
            self.readEntryRaw(slot, &raw_entry);
            const state = std.mem.readInt(u32, raw_entry[28..32], .little);
            if (state == STATE_LIVE) {
                const off = std.mem.readInt(u32, raw_entry[16..20], .little);
                const sz = std.mem.readInt(u32, raw_entry[20..24], .little);
                const end = off +| sz;
                const aligned = (end + 3) & ~@as(u32, 3);
                if (aligned > f) f = aligned;
            }
        }
        if (f > self.size) f = self.size;
        return f;
    }

    pub fn count(self: *const Partition) u32 {
        if (!self.valid()) return 0;
        var n: u32 = 0;
        var slot: u32 = 0;
        while (slot < TOC_CAP) : (slot += 1) {
            var raw_entry: [ENTRY_SIZE]u8 = undefined;
            self.readEntryRaw(slot, &raw_entry);
            const state = std.mem.readInt(u32, raw_entry[28..32], .little);
            if (state == STATE_LIVE) n += 1;
        }
        return n;
    }

    pub fn format(self: *const Partition) FlatFsError {
        var a = self.base;
        while (a < self.base + self.size) : (a += 4096) {
            if (!flash.sectorErase(a)) return .flash_timeout;
        }
        var super: [SUPER_SIZE]u8 = @splat(0);
        std.mem.writeInt(u32, super[0..4], MAGIC, .little);
        std.mem.writeInt(u32, super[4..8], VERSION, .little);
        std.mem.writeInt(u32, super[8..12], @intCast(SUPER_SIZE), .little);
        std.mem.writeInt(u32, super[12..16], TOC_CAP, .little);
        std.mem.writeInt(u32, super[16..20], BLOB_OFF, .little);
        if (!flash.write(self.base, &super)) return .flash_timeout;
        return .none;
    }

    pub fn find(self: *const Partition, name: []const u8) ?FlatFsEntry {
        if (!self.valid()) return null;
        var slot: u32 = 0;
        while (slot < TOC_CAP) : (slot += 1) {
            var raw_entry: [ENTRY_SIZE]u8 = undefined;
            self.readEntryRaw(slot, &raw_entry);
            const state = std.mem.readInt(u32, raw_entry[28..32], .little);
            if (state == STATE_LIVE and nameEq(raw_entry[0..NAME_MAX], name)) {
                return .{
                    .name = raw_entry[0..NAME_MAX].*,
                    .offset = std.mem.readInt(u32, raw_entry[16..20], .little),
                    .size = std.mem.readInt(u32, raw_entry[20..24], .little),
                    .crc = std.mem.readInt(u32, raw_entry[24..28], .little),
                    .state = state,
                };
            }
        }
        return null;
    }

    pub fn entry(self: *const Partition, index: u32) ?FlatFsEntry {
        if (!self.valid()) return null;
        var seen: u32 = 0;
        var slot: u32 = 0;
        while (slot < TOC_CAP) : (slot += 1) {
            var raw_entry: [ENTRY_SIZE]u8 = undefined;
            self.readEntryRaw(slot, &raw_entry);
            const state = std.mem.readInt(u32, raw_entry[28..32], .little);
            if (state == STATE_LIVE) {
                if (seen == index) {
                    return .{
                        .name = raw_entry[0..NAME_MAX].*,
                        .offset = std.mem.readInt(u32, raw_entry[16..20], .little),
                        .size = std.mem.readInt(u32, raw_entry[20..24], .little),
                        .crc = std.mem.readInt(u32, raw_entry[24..28], .little),
                        .state = state,
                    };
                }
                seen += 1;
            }
        }
        return null;
    }

    pub fn readBlobAt(self: *const Partition, e: FlatFsEntry, at: u32, out: []u8) i32 {
        if (!self.valid() or e.state != STATE_LIVE) return -1;
        if (at >= e.size) return 0;
        const left: usize = e.size - at;
        const n = @min(left, out.len);
        if (n > 0) {
            flash.read(self.base + e.offset + at, out[0..n]);
        }
        return @intCast(n);
    }

    pub fn used(self: *const Partition) u32 {
        if (!self.valid()) return 0;
        return self.frontier();
    }

    pub fn create(self: *const Partition, name: []const u8, w: *FlatFsWriter) FlatFsError {
        if (name.len == 0 or name.len >= NAME_MAX) return .bad_name;
        if (!self.valid()) return .not_formatted;

        var free_slot: u32 = TOC_CAP;
        var slot: u32 = 0;
        while (slot < TOC_CAP) : (slot += 1) {
            var raw_entry: [ENTRY_SIZE]u8 = undefined;
            self.readEntryRaw(slot, &raw_entry);
            const state = std.mem.readInt(u32, raw_entry[28..32], .little);
            if (state != STATE_LIVE) {
                free_slot = slot;
                break;
            }
        }
        if (free_slot == TOC_CAP) return .toc_full;

        const offset = self.frontier();
        if (offset >= self.size) return .no_space;

        w.part = self.*;
        w.name = @splat(0);
        @memcpy(w.name[0..name.len], name);
        w.name_len = name.len;
        w.slot = free_slot;
        w.offset = offset;
        w.len = 0;
        w.crc = 0xFFFF_FFFF;
        return .none;
    }
};

const FlatFsWriter = struct {
    part: Partition = .{ .base = 0, .size = 0 },
    name: [NAME_MAX]u8 = @splat(0),
    name_len: usize = 0,
    slot: u32 = 0,
    offset: u32 = 0,
    len: u32 = 0,
    crc: u32 = 0xFFFF_FFFF,

    pub fn write(self: *FlatFsWriter, data: []const u8) FlatFsError {
        if (data.len == 0) return .none;
        const dlen: u32 = @intCast(data.len);
        if (self.offset +| self.len +| dlen > self.part.size) return .no_space;
        if (!flash.write(self.part.base + self.offset + self.len, data)) return .flash_timeout;
        self.len += dlen;
        self.crc = crc32Update(self.crc, data);
        return .none;
    }

    pub fn readBack(self: *const FlatFsWriter, at: u32, out: []u8) usize {
        if (at >= self.len) return 0;
        const left: usize = self.len - at;
        const n = @min(left, out.len);
        if (n > 0) {
            flash.read(self.part.base + self.offset + at, out[0..n]);
        }
        return n;
    }

    pub fn finish(self: *FlatFsWriter) FlatFsError {
        var e: [ENTRY_SIZE]u8 = @splat(0);
        const n = @min(self.name_len, NAME_MAX - 1);
        @memcpy(e[0..n], self.name[0..n]);
        std.mem.writeInt(u32, e[16..20], self.offset, .little);
        std.mem.writeInt(u32, e[20..24], self.len, .little);
        std.mem.writeInt(u32, e[24..28], ~self.crc, .little);
        std.mem.writeInt(u32, e[28..32], STATE_LIVE, .little);

        const slot_addr = self.part.base + @as(u32, @intCast(SUPER_SIZE)) + self.slot * @as(u32, @intCast(ENTRY_SIZE));
        if (!flash.pageProgram(slot_addr, &e)) return .flash_timeout;
        return .none;
    }
};

const Storage = struct {
    on_flash: bool = false,
    jedec: JedecId = .{ .manufacturer = 0, .mem_type = 0, .capacity = 0 },
    open: bool = false,
    open_which: Which = .encoded,
    writer: FlatFsWriter = .{},
    enc_part: Partition = .{ .base = APP_BASE, .size = 4096 },
    dec_part: Partition = .{ .base = APP_BASE + 4096, .size = 4096 },
    ram: [2]RamFile = @splat(.{}),
    storage_mutex: rtos.Mutex = .{ .name = "store-mx" },

    pub fn probe(self: *Storage) bool {
        self.jedec = spi.readId();
        self.on_flash = (self.jedec.manufacturer == 0xEF);
        return self.on_flash;
    }

    pub fn configure(self: *Storage, src_len: usize) void {
        self.enc_part = encodedPartition(src_len);
        self.dec_part = decodedPartition(src_len);
    }

    pub fn partition(self: *const Storage, w: Which) Partition {
        return if (w == .encoded) self.enc_part else self.dec_part;
    }

    pub fn backend(self: *const Storage) []const u8 {
        return if (self.on_flash) "SPI flash" else "RAM";
    }

    pub fn format(self: *Storage) i32 {
        self.open = false;
        if (self.on_flash) {
            if (self.enc_part.format() != .none) return -1;
            if (self.dec_part.format() != .none) return -2;
            return 0;
        }
        for (&self.ram) |*f| {
            f.live = false;
            f.len = 0;
            f.name_len = 0;
        }
        return 0;
    }

    fn slotIndex(w: Which) usize {
        return if (w == .encoded) 0 else 1;
    }

    pub fn create(self: *Storage, w: Which, name: []const u8) i32 {
        if (self.open) return -100;
        if (self.on_flash) {
            const err = self.partition(w).create(name, &self.writer);
            if (err != .none) return -@as(i32, @intFromEnum(err));
            self.open = true;
            self.open_which = w;
            return 0;
        }
        const ix = slotIndex(w);
        var f = &self.ram[ix];
        @memcpy(f.name[0..name.len], name);
        f.name_len = name.len;
        f.len = 0;
        f.live = false;
        self.open = true;
        self.open_which = w;
        return 0;
    }

    pub fn write(self: *Storage, data: []const u8) i32 {
        if (!self.open) return -1;
        if (self.on_flash) {
            const err = self.writer.write(data);
            return if (err == .none) 0 else -@as(i32, @intFromEnum(err));
        }
        var f = &self.ram[slotIndex(self.open_which)];
        if (f.len + data.len > RAM_CAP) return -2;
        @memcpy(f.bytes[f.len .. f.len + data.len], data);
        f.len += data.len;
        return 0;
    }

    pub fn openLen(self: *const Storage) u32 {
        if (!self.open) return 0;
        if (self.on_flash) return self.writer.len;
        return @intCast(self.ram[slotIndex(self.open_which)].len);
    }

    pub fn close(self: *Storage) i32 {
        if (!self.open) return -1;
        self.open = false;
        if (self.on_flash) {
            const err = self.writer.finish();
            return if (err == .none) 0 else -@as(i32, @intFromEnum(err));
        }
        self.ram[slotIndex(self.open_which)].live = true;
        return 0;
    }

    pub fn fileLen(self: *const Storage, w: Which, name: []const u8) u32 {
        if (self.on_flash) {
            if (self.partition(w).find(name)) |e| return e.size;
            return 0;
        }
        const f = &self.ram[slotIndex(w)];
        return if (f.matches(name)) @intCast(f.len) else 0;
    }

    pub fn visibleLen(self: *const Storage, w: Which, name: []const u8) u32 {
        if (self.open and self.open_which == w) return self.openLen();
        return self.fileLen(w, name);
    }

    pub fn readVisible(self: *const Storage, w: Which, name: []const u8, at: u32, out: []u8) usize {
        if (self.open and self.open_which == w) {
            if (self.on_flash) return self.writer.readBack(at, out);
            const f = &self.ram[slotIndex(self.open_which)];
            if (at >= f.len) return 0;
            const n = @min(f.len - at, out.len);
            @memcpy(out[0..n], f.bytes[at .. at + n]);
            return n;
        }
        const n = self.readFile(w, name, at, out);
        return if (n < 0) 0 else @intCast(n);
    }

    pub fn readFile(self: *const Storage, w: Which, name: []const u8, at: u32, out: []u8) i32 {
        if (self.on_flash) {
            if (self.partition(w).find(name)) |e| {
                return self.partition(w).readBlobAt(e, at, out);
            }
            return -1;
        }
        const f = &self.ram[slotIndex(w)];
        if (!f.matches(name)) return -1;
        if (at >= f.len) return 0;
        const n = @min(f.len - at, out.len);
        @memcpy(out[0..n], f.bytes[at .. at + n]);
        return @intCast(n);
    }

    pub fn used(self: *const Storage, w: Which) u32 {
        if (self.on_flash) return self.partition(w).used();
        const f = &self.ram[slotIndex(w)];
        return if (f.live) @intCast(f.len) else 0;
    }
};

var global_storage: Storage = .{};

// ============================================================================
// Pipeline Global State & Semaphores
// ============================================================================

var g_buf_empty: rtos.Semaphore = rtos.Semaphore.counting("buf_empty", 1, 1);
var g_buf_full: rtos.Semaphore = rtos.Semaphore.counting("buf_full", 1, 0);
var g_b64_empty: rtos.Semaphore = rtos.Semaphore.counting("b64_empty", 1, 1);
var g_b64_full: rtos.Semaphore = rtos.Semaphore.counting("b64_full", 1, 0);
var g_copy_done: rtos.Semaphore = rtos.Semaphore.counting("copy_done", 1, 0);
var g_file_done: rtos.Semaphore = rtos.Semaphore.counting("file_done", 1, 0);
var g_verify_done: rtos.Semaphore = rtos.Semaphore.counting("verify_done", 1, 0);
var g_write_snapshot: rtos.Semaphore = rtos.Semaphore.counting("write_snapshot", 1, 0);

var g_console: rtos.Mutex = .{ .name = "console", .type = .recursive };

var g_raw_buf: [CHUNK]u8 = undefined;
var g_raw_len: usize = 0;
var g_raw_last: bool = false;

var g_enc_buf: [B64_MAX]u8 = undefined;
var g_enc_len: usize = 0;
var g_enc_last: bool = false;

const RunRecord = struct {
    crc0: u32 = 0,
    crc1: u32 = 0,
    chunks: usize = 0,
    enc_bytes: u32 = 0,
    dec_bytes: u32 = 0,
    final_seen: bool = false,
    cycles: usize = 0,
    fresh: usize = 0,
    longest: u32 = 0,
    monotonic: bool = true,
    errors: u32 = 0,
};

var g_run: RunRecord = .{};

fn drain(s: *rtos.Semaphore) void {
    while (s.tryWait()) |_| {} else |_| {}
}

fn refill(s: *rtos.Semaphore) void {
    drain(s);
    _ = s.post() catch {};
}

fn resetPipeline() void {
    refill(&g_buf_empty);
    refill(&g_b64_empty);
    drain(&g_buf_full);
    drain(&g_b64_full);
    drain(&g_copy_done);
    drain(&g_file_done);
    drain(&g_verify_done);
    drain(&g_write_snapshot);

    const crc0 = g_run.crc0;
    g_run = .{};
    g_run.crc0 = crc0;
    g_run.monotonic = true;

    g_raw_len = 0;
    g_raw_last = false;
    g_enc_len = 0;
    g_enc_last = false;
}

fn line(s: []const u8) void {
    g_console.lock() catch return;
    defer g_console.unlock() catch {};
    board.uartWrite(s);
    uos.trace.write(s);
}

fn raw(data: []const u8) void {
    g_console.lock() catch return;
    defer g_console.unlock() catch {};
    board.uartWrite(data);
    uos.trace.write(data);
}

fn fault(what: []const u8) void {
    var buf: [96]u8 = undefined;
    line(std.fmt.bufPrint(&buf, "spi-pipeline: fault: {s}\n", .{what}) catch "");
    g_run.errors += 1;
}

// ============================================================================
// Worker Threads
// ============================================================================

fn imageSlice(len: usize) []const u8 {
    const ptr: [*]const u8 = @ptrFromInt(IMAGE_BASE);
    return ptr[0..len];
}

fn t1ImageToBuffer(arg: ?*anyopaque) ?*anyopaque {
    const len: usize = @intCast(@intFromPtr(arg));
    const step = pace(len);
    var offset: usize = 0;
    const img = imageSlice(len);

    while (offset < len) {
        g_buf_empty.wait() catch {
            fault("T1 buf_empty");
            return null;
        };

        const n = @min(len - offset, CHUNK);
        @memcpy(g_raw_buf[0..n], img[offset .. offset + n]);
        g_raw_len = n;
        g_raw_last = (offset + n == len);
        offset += n;

        _ = g_buf_full.post() catch {};
        sysclock.sleepFor(step) catch {};
    }

    _ = g_copy_done.post() catch {};
    return null;
}

fn t2Base64Encode(arg: ?*anyopaque) ?*anyopaque {
    _ = arg;
    while (true) {
        g_b64_empty.wait() catch {
            fault("T2 b64_empty");
            return null;
        };
        g_buf_full.wait() catch {
            fault("T2 buf_full");
            return null;
        };

        g_enc_len = base64.encode(g_raw_buf[0..g_raw_len], &g_enc_buf);
        g_enc_last = g_raw_last;
        g_raw_len = 0;
        const last = g_enc_last;

        _ = g_buf_empty.post() catch {};
        _ = g_b64_full.post() catch {};

        if (last) return null;
    }
}

const T3Args = struct {
    enc_name: [9]u8,
    name_len: usize,
    src_len: usize,
};

fn t3WriteStorage(arg: ?*anyopaque) ?*anyopaque {
    const a: *const T3Args = @ptrCast(@alignCast(arg.?));
    const name = a.enc_name[0..a.name_len];
    const len = a.src_len;

    var writing = true;
    var created = false;

    {
        global_storage.storage_mutex.lock() catch {};
        defer global_storage.storage_mutex.unlock() catch {};
        if (global_storage.create(.encoded, name) != 0) {
            fault("T3 create");
            writing = false;
        } else {
            created = true;
        }
    }

    var written: usize = 0;
    var final_seen = false;

    while (true) {
        g_b64_full.wait() catch {
            fault("T3 b64_full");
            break;
        };

        const last = g_enc_last;
        if (writing) {
            global_storage.storage_mutex.lock() catch {};
            if (global_storage.write(g_enc_buf[0..g_enc_len]) != 0) {
                fault("T3 write");
                writing = false;
            } else {
                written += 1;
            }
            global_storage.storage_mutex.unlock() catch {};
        }

        _ = g_b64_empty.post() catch {};
        _ = g_write_snapshot.post() catch {};

        if (last) final_seen = true;
        if (final_seen or written >= chunks(len)) break;
    }

    g_copy_done.wait() catch {};

    var enc_bytes: u32 = 0;
    if (created) {
        global_storage.storage_mutex.lock() catch {};
        if (writing) enc_bytes = global_storage.openLen();
        if (global_storage.close() != 0) fault("T3 close");
        global_storage.storage_mutex.unlock() catch {};
    }

    g_run.chunks = written;
    g_run.enc_bytes = enc_bytes;
    g_run.final_seen = final_seen;

    _ = g_file_done.post() catch {};
    return null;
}

const T4Args = struct {
    iter: usize,
    enc_name: [9]u8,
    name_len: usize,
};

fn show(head: []const u8, tail: []const u8, total_len: u32) void {
    if (head.len == 0) {
        line("           (empty)\n");
        return;
    }
    line("           ");
    raw(head);
    if (tail.len != 0) {
        var buf: [64]u8 = undefined;
        const middle: u32 = if (total_len > head.len + tail.len) total_len - @as(u32, @intCast(head.len + tail.len)) else 0;
        line(std.fmt.bufPrint(&buf, " ... {d} more ... ", .{middle}) catch "");
        raw(tail);
    }
    line("\n");
}

fn t4BlinkUart(arg: ?*anyopaque) ?*anyopaque {
    const a: *const T4Args = @ptrCast(@alignCast(arg.?));
    const iter = a.iter;
    const name = a.enc_name[0..a.name_len];

    var head: [SNAPSHOT_SHOW]u8 = undefined;
    var tail: [SNAPSHOT_SHOW]u8 = undefined;
    var previous: u32 = 0;
    var cycles: usize = 0;
    var fresh: usize = 0;
    var monotonic: bool = true;

    for (0..BLINK_CYCLES) |cycle| {
        board.led.toggle();
        sysclock.sleepFor(BLINK_HALF) catch {};
        board.led.toggle();
        sysclock.sleepFor(BLINK_HALF) catch {};

        const new_chunk = if (g_write_snapshot.timedWait(SNAPSHOT_WAIT)) |_| true else |_| false;

        var cur_len: u32 = 0;
        var hn: usize = 0;
        var tn: usize = 0;
        {
            global_storage.storage_mutex.lock() catch {};
            cur_len = global_storage.visibleLen(.encoded, name);
            hn = global_storage.readVisible(.encoded, name, 0, &head);
            const at: u32 = if (cur_len > SNAPSHOT_SHOW) cur_len - SNAPSHOT_SHOW else 0;
            tn = if (at > hn) global_storage.readVisible(.encoded, name, at, &tail) else 0;
            global_storage.storage_mutex.unlock() catch {};
        }

        if (cur_len < previous) monotonic = false;
        previous = @max(previous, cur_len);
        cycles += 1;
        if (new_chunk) fresh += 1;

        var buf: [128]u8 = undefined;
        line(std.fmt.bufPrint(&buf, "[{d:>8} ms] iter {d} cycle {d}: {d} bytes on the file{s}\n", .{
            sysclock.now(), iter, cycle, cur_len, if (new_chunk) ", new chunk" else "",
        }) catch "");
        show(head[0..hn], tail[0..tn], cur_len);
    }

    board.led.set(false);

    g_run.cycles = cycles;
    g_run.fresh = fresh;
    g_run.longest = previous;
    g_run.monotonic = g_run.monotonic and monotonic;
    return null;
}

const T5Args = struct {
    enc_name: [9]u8,
    enc_len: usize,
    dec_name: [9]u8,
    dec_len: usize,
    src_len: usize,
};

fn t5DecodeVerify(arg: ?*anyopaque) ?*anyopaque {
    const a: *const T5Args = @ptrCast(@alignCast(arg.?));
    const enc_name = a.enc_name[0..a.enc_len];
    const dec_name = a.dec_name[0..a.dec_len];
    const len = a.src_len;

    g_file_done.wait() catch {
        fault("T5 file_done");
        _ = g_verify_done.post() catch {};
        return null;
    };

    var piece: [B64_MAX]u8 = undefined;
    var plain: [CHUNK]u8 = undefined;
    var running_crc: u32 = 0xFFFF_FFFF;
    var decoded: u32 = 0;
    var ok = true;

    {
        global_storage.storage_mutex.lock() catch {};
        if (global_storage.create(.decoded, dec_name) != 0) {
            fault("T5 create");
            ok = false;
        }
        global_storage.storage_mutex.unlock() catch {};
    }

    var at: u32 = 0;
    const total = chunks(len);
    for (0..total) |i| {
        if (!ok) break;
        const cl = chunkLen(len, i);
        const want = base64.encodedLen(cl);

        var got: i32 = 0;
        {
            global_storage.storage_mutex.lock() catch {};
            got = global_storage.readFile(.encoded, enc_name, at, piece[0..want]);
            global_storage.storage_mutex.unlock() catch {};
        }

        if (got < 0 or @as(usize, @intCast(got)) != want) {
            fault("T5 read");
            ok = false;
            break;
        }

        const n = base64.decode(piece[0..want], &plain) orelse {
            fault("T5 chunk is not Base64");
            ok = false;
            break;
        };

        if (n != cl) {
            var buf: [96]u8 = undefined;
            line(std.fmt.bufPrint(&buf, "spi-pipeline: fault: T5 chunk {d}: {d} bytes, wanted {d}\n", .{ i, n, cl }) catch "");
            g_run.errors += 1;
            ok = false;
            break;
        }

        {
            global_storage.storage_mutex.lock() catch {};
            if (global_storage.write(plain[0..n]) != 0) {
                fault("T5 write");
                ok = false;
            }
            global_storage.storage_mutex.unlock() catch {};
        }

        running_crc = crc32Update(running_crc, plain[0..n]);
        decoded += @intCast(n);
        at += @intCast(want);
    }

    {
        global_storage.storage_mutex.lock() catch {};
        if (global_storage.close() != 0 and ok) fault("T5 close");
        global_storage.storage_mutex.unlock() catch {};
    }

    const crc1 = ~running_crc;
    const crc0 = g_run.crc0;

    uos.trace.print("CRC0 = 0x{X:0>8}\n", .{crc0});
    uos.trace.print("CRC1 = 0x{X:0>8}\n", .{crc1});
    uos.trace.print("{s}\n", .{if (crc1 == crc0) "OK" else "!OK"});

    var buf: [128]u8 = undefined;
    line(std.fmt.bufPrint(&buf, "[{d:>8} ms] verify: decoded {d} bytes, CRC0 0x{X:0>8} CRC1 0x{X:0>8} {s}\n", .{
        sysclock.now(), decoded, crc0, crc1, if (crc1 == crc0) "OK" else "!OK",
    }) catch "");

    g_run.crc1 = crc1;
    g_run.dec_bytes = decoded;

    _ = g_verify_done.post() catch {};
    return null;
}

// ============================================================================
// Banner & File Listing
// ============================================================================

fn banner(backend_name: []const u8, src_len: usize) bool {
    g_console.lock() catch return false;
    defer g_console.unlock() catch {};
    line("=============================================\n");
    var buf: [128]u8 = undefined;
    line(std.fmt.bufPrint(&buf, "  WeAct-F411CE  spi-pipeline  store: {s}\n", .{backend_name}) catch "");
    line(std.fmt.bufPrint(&buf, "  {d} B -> {d} chunks -> {d} B -> {d} B\n", .{
        src_len, chunks(src_len), encodedTotal(src_len), src_len,
    }) catch "");
    line("=============================================\n");
    return true;
}

fn listFiles() void {
    inline for (.{ Which.encoded, Which.decoded }) |w| {
        global_storage.storage_mutex.lock() catch {};
        const label = if (w == .encoded) "enc" else "dec";
        const used_bytes = global_storage.used(w);
        var buf: [128]u8 = undefined;
        line(std.fmt.bufPrint(&buf, "spi-pipeline: {s} partition, {d} bytes used\n", .{ label, used_bytes }) catch "");
        if (global_storage.on_flash) {
            const p = global_storage.partition(w);
            const cnt = p.count();
            var i: u32 = 0;
            while (i < cnt) : (i += 1) {
                if (p.entry(i)) |e| {
                    const nl = e.nameLen();
                    line(std.fmt.bufPrint(&buf, "  {s:<16} {d:>6} bytes  crc 0x{x:0>8}\n", .{ e.name[0..nl], e.size, e.crc }) catch "");
                }
            }
        } else {
            const ix = Storage.slotIndex(w);
            const f = &global_storage.ram[ix];
            if (f.live) {
                const fcrc = crc32(f.bytes[0..f.len]);
                line(std.fmt.bufPrint(&buf, "  {s:<16} {d:>6} bytes  crc 0x{x:0>8}\n", .{ f.name[0..f.name_len], f.len, fcrc }) catch "");
            }
        }
        global_storage.storage_mutex.unlock() catch {};
    }
}

// ============================================================================
// Main Coordinator
// ============================================================================

var t1_th: rtos.ThreadInclusive(4096) = undefined;
var t2_th: rtos.ThreadInclusive(4096) = undefined;
var t3_th: rtos.ThreadInclusive(4096) = undefined;
var t4_th: rtos.ThreadInclusive(4096) = undefined;
var t5_th: rtos.ThreadInclusive(4096) = undefined;

fn heapFreeBytes() usize {
    const s = uos.memory.statistics();
    return s.total_bytes - s.allocated_bytes;
}

fn appMain() u8 {
    spi.init();

    const codec_ok = base64.selfTest();

    var line_buf: [192]u8 = undefined;
    line(std.fmt.bufPrint(&line_buf, "\nspi-pipeline: heap {d} bytes\n", .{heapFreeBytes()}) catch "");

    _ = global_storage.probe();
    const on_flash = global_storage.on_flash;
    const j = global_storage.jedec;

    line("spi-pipeline: SPI transport polled (bulk from 16 bytes)\n");
    line(std.fmt.bufPrint(&line_buf, "spi-pipeline: JEDEC 0x{x:0>2} 0x{x:0>2} 0x{x:0>2} -> {s} store\n", .{
        j.manufacturer, j.mem_type, j.capacity, global_storage.backend(),
    }) catch "");

    const full_img: usize = 32768;
    const src_len: usize = if (on_flash) full_img else @min(full_img, @as(usize, RAM_SOURCE_MAX));
    global_storage.configure(src_len);

    const enc_p = global_storage.partition(.encoded);
    const dec_p = global_storage.partition(.decoded);
    uos.trace.print("spi-pipeline: enc {d} KiB @ 0x{x:0>8}, dec {d} KiB @ 0x{x:0>8} ({d} iterations)\n", .{
        enc_p.size / 1024, enc_p.base, dec_p.size / 1024, dec_p.base, ITERATIONS,
    });

    if (global_storage.format() != 0) {
        line("spi-pipeline: FAIL, format\n");
        return 1;
    }
    line(std.fmt.bufPrint(&line_buf, "spi-pipeline: enc {d} KiB @ 0x{x}, dec {d} KiB @ 0x{x}\n", .{
        enc_p.size / 1024, enc_p.base, dec_p.size / 1024, dec_p.base,
    }) catch "");
    line("spi-pipeline: fs done\n");

    const enc_len = encodedTotal(src_len);
    const crc0 = crc32(imageSlice(src_len));
    g_run.crc0 = crc0;

    const banner_ok = banner(global_storage.backend(), src_len);
    line(std.fmt.bufPrint(&line_buf, "spi-pipeline: image {d} bytes at 0x{x:0>8}, source {d}{s}, crc0 0x{x:0>8}\n", .{
        full_img, IMAGE_BASE, src_len, if (src_len == full_img) "" else " (clamped: no flash part)", crc0,
    }) catch "");
    line(std.fmt.bufPrint(&line_buf, "spi-pipeline: {d} chunks of {d} (last {d}), {d} encoded, {d} ms per chunk\n", .{
        chunks(src_len), CHUNK, chunkLen(src_len, chunks(src_len) - 1), enc_len, pace(src_len),
    }) catch "");

    var iterations_ok: usize = 0;
    var chunks_ok: usize = 0;
    var lengths_ok: usize = 0;
    var crcs_ok: usize = 0;
    var cycles_ok: usize = 0;

    for (0..ITERATIONS) |iter| {
        resetPipeline();

        var a3: T3Args = .{ .enc_name = undefined, .name_len = 0, .src_len = src_len };
        const enc_name = std.fmt.bufPrint(&a3.enc_name, "enc{d}.b64", .{iter}) catch "enc.b64";
        a3.name_len = enc_name.len;

        var a4: T4Args = .{ .iter = iter, .enc_name = undefined, .name_len = enc_name.len };
        @memcpy(a4.enc_name[0..enc_name.len], enc_name);

        var a5: T5Args = .{ .enc_name = undefined, .enc_len = enc_name.len, .dec_name = undefined, .dec_len = 0, .src_len = src_len };
        @memcpy(a5.enc_name[0..enc_name.len], enc_name);
        const dec_name = std.fmt.bufPrint(&a5.dec_name, "dec{d}.bin", .{iter}) catch "dec.bin";
        a5.dec_len = dec_name.len;

        t1_th.init("t1", t1ImageToBuffer, @ptrFromInt(src_len), .{}) catch unreachable;
        t2_th.init("t2", t2Base64Encode, null, .{}) catch unreachable;
        t3_th.init("t3", t3WriteStorage, &a3, .{}) catch unreachable;
        t4_th.init("t4", t4BlinkUart, &a4, .{}) catch unreachable;
        t5_th.init("t5", t5DecodeVerify, &a5, .{}) catch unreachable;

        uos.trace.print("[{d:>8} ms] iter {d}: heap free {d} B\n", .{
            sysclock.now(), iter, heapFreeBytes(),
        });

        g_verify_done.wait() catch {};

        _ = t1_th.thread.join() catch {};
        t1_th.deinit();
        _ = t2_th.thread.join() catch {};
        t2_th.deinit();
        _ = t3_th.thread.join() catch {};
        t3_th.deinit();
        _ = t4_th.thread.join() catch {};
        t4_th.deinit();
        _ = t5_th.thread.join() catch {};
        t5_th.deinit();

        const this_chunks = (g_run.chunks == chunks(src_len) and g_run.final_seen);
        const this_lengths = (g_run.enc_bytes == enc_len and g_run.dec_bytes == src_len);
        const this_crc = (g_run.crc1 == g_run.crc0);
        const this_cycles = (g_run.cycles == BLINK_CYCLES and g_run.monotonic and g_run.longest <= g_run.enc_bytes);

        if (this_chunks) chunks_ok += 1;
        if (this_lengths) lengths_ok += 1;
        if (this_crc) crcs_ok += 1;
        if (this_cycles) cycles_ok += 1;
        if (this_chunks and this_lengths and this_crc and this_cycles and g_run.errors == 0) {
            iterations_ok += 1;
        }

        line(std.fmt.bufPrint(&line_buf, "[{d:>8} ms] iter {d}: {d} chunks, enc {d} B, dec {d} B, crc 0x{x:0>8}==0x{x:0>8}, {d} cycles ({d} fresh), {d} error(s), heap {d} B\n", .{
            sysclock.now(), iter, g_run.chunks, g_run.enc_bytes, g_run.dec_bytes, g_run.crc0, g_run.crc1, g_run.cycles, g_run.fresh, g_run.errors, heapFreeBytes(),
        }) catch "");
    }

    listFiles();

    var failures: u32 = 0;
    if (chunks_ok != ITERATIONS) failures += 1;
    line(std.fmt.bufPrint(&line_buf, "pipe 1: {d} of {d} iterations wrote {d} chunks and saw the final one\n", .{ chunks_ok, ITERATIONS, chunks(src_len) }) catch "");

    if (lengths_ok != ITERATIONS) failures += 1;
    line(std.fmt.bufPrint(&line_buf, "pipe 2: {d} of {d} produced {d} encoded and {d} decoded bytes\n", .{ lengths_ok, ITERATIONS, enc_len, src_len }) catch "");

    if (crcs_ok != ITERATIONS) failures += 1;
    line(std.fmt.bufPrint(&line_buf, "pipe 3: {d} of {d} decoded back to crc0 0x{x:0>8}\n", .{ crcs_ok, ITERATIONS, crc0 }) catch "");

    if (cycles_ok != ITERATIONS) failures += 1;
    line(std.fmt.bufPrint(&line_buf, "pipe 4: {d} of {d} ran {d} blink cycles with snapshots that never shrank\n", .{ cycles_ok, ITERATIONS, BLINK_CYCLES }) catch "");

    if (!codec_ok) failures += 1;
    line(std.fmt.bufPrint(&line_buf, "pipe 5: base64 matches the RFC 4648 vectors: {s}\n", .{ if (codec_ok) "true" else "false" }) catch "");

    if (!banner_ok) failures += 1;
    line(std.fmt.bufPrint(&line_buf, "pipe 6: banner printed 4 lines at console-lock depth 2: {s}\n", .{ if (banner_ok) "true" else "false" }) catch "");

    line(std.fmt.bufPrint(&line_buf, "spi-pipeline: {d} of {d} iterations clean, heap {d} bytes\n", .{ iterations_ok, ITERATIONS, heapFreeBytes() }) catch "");

    const passed = (failures == 0 and iterations_ok == ITERATIONS);
    if (passed) {
        line("spi-pipeline: PASS\n");
        line("RESULT: PASS\n");
    } else {
        line(std.fmt.bufPrint(&line_buf, "spi-pipeline: FAIL, {d} verdicts\n", .{failures}) catch "");
        line("RESULT: FAIL\n");
    }

    return if (passed) 0 else 1;
}
