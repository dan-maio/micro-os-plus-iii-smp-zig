//! flatfs -- a minimal flat file system on an SD card (the C++
//! drivers/src/flatfs.cpp, same on-disk layout):
//!
//!   block 0               superblock ("FLATFS01", geometry, free count)
//!   1 .. b                free-block bitmap, one bit per data block
//!   1+b .. 1+b+16         file table: 256 entries of 32 bytes
//!                         (name[20], start, size, flags; little endian)
//!   1+b+16 ..             file data, one contiguous extent per file
//!
//! The results are an error set; `resultStr()` gives the C++ messages.

const std = @import("std");
const sd = @import("sd");
const uos = @import("uos");

pub const block_size: u32 = sd.sector_size; // 512
pub const super_block: u32 = 0;
pub const entry_bytes: u32 = 32;
pub const entries_per_block: u32 = block_size / entry_bytes; // 16
pub const table_blocks: u32 = 16; // 256 files at most
pub const name_max: u32 = 19; // bytes in name[], without the NUL

const sb_magic = 0;
const sb_version = 8;
const sb_block_size = 12;
const sb_total = 16;
const sb_data_start = 20;
const sb_bitmap_blocks = 24;
const sb_table_blocks = 28;
const sb_max_files = 32;
const sb_free = 36;
const layout_version: u32 = 1;

const e_name = 0;
const e_start = 20;
const e_size = 24;
const e_flags = 28;
const flag_valid: u32 = 1;

const bits_per_sector: u32 = 512 * 8; // 4096
const magic_str = "FLATFS01";

pub const Error = error{
    Io, // block device I/O failed
    NoFs, // no valid superblock
    Format, // geometry/layout inconsistency
    NoSpace, // not enough contiguous free blocks
    NotFound, // the file does not exist
    Exists, // (unused; writes overwrite)
    Full, // file table full
    Name, // bad file name
    Media, // looks like a DOS MBR/FAT volume (refusing to wipe it)
    Buf, // caller buffer too small
};

pub fn resultStr(err: ?Error) []const u8 {
    const e = err orelse return "ok";
    return switch (e) {
        error.Io => "I/O error",
        error.NoFs => "not a flatfs volume",
        error.Format => "layout error",
        error.NoSpace => "no free space",
        error.NotFound => "file not found",
        error.Exists => "file exists",
        error.Full => "file table full",
        error.Name => "bad file name",
        error.Media => "refusing to format: media looks like a DOS MBR/FAT boot volume (real SD boot card?)",
        error.Buf => "buffer too small",
    };
}

pub const FileEntry = struct {
    name: [name_max + 1]u8,
    start_block: u32,
    size_bytes: u32,
};

const Geometry = struct {
    total_blocks: u32 = 0,
    data_start: u32 = 0, // the first file data block
    bitmap_blocks: u32 = 0,
    table_blocks: u32 = table_blocks,
    data_blocks: u32 = 0, // blocks available for file data
    max_files: u32 = table_blocks * entries_per_block,
};

fn geometryFor(total_blocks: u32) Geometry {
    var g: Geometry = .{ .total_blocks = total_blocks };
    var b: u32 = 1;
    while (@as(u64, b) * bits_per_sector < @as(u64, total_blocks) -| (1 + g.table_blocks + b)) b += 1;
    g.bitmap_blocks = b;
    g.data_start = 1 + b + g.table_blocks;
    g.data_blocks = if (g.data_start < total_blocks) total_blocks - g.data_start else 0;
    return g;
}

fn storeLe32(p: []u8, v: u32) void {
    std.mem.writeInt(u32, p[0..4], v, .little);
}

fn loadLe32(p: []const u8) u32 {
    return std.mem.readInt(u32, p[0..4], .little);
}

fn sectorsFor(size: u32) u32 {
    return (size + block_size - 1) / block_size;
}

pub const FlatFs = struct {
    card: ?*sd.SdCard = null,
    mounted_: bool = false,
    geom: Geometry = .{},
    bitmap: []u8 = &.{}, // 1 bit per data block
    dirty: []u8 = &.{}, // per bitmap sector
    table: []u8 = &.{}, // max_files * entry_bytes
    free_blocks_: u32 = 0,
    last: ?Error = null,

    fn gpa() std.mem.Allocator {
        return uos.memory.allocator();
    }

    fn releaseBuffers(self: *FlatFs) void {
        const a = gpa();
        if (self.bitmap.len > 0) a.free(self.bitmap);
        if (self.dirty.len > 0) a.free(self.dirty);
        if (self.table.len > 0) a.free(self.table);
        self.bitmap = &.{};
        self.dirty = &.{};
        self.table = &.{};
    }

    fn ensureBuffers(self: *FlatFs) bool {
        const a = gpa();
        if (self.bitmap.len == 0) self.bitmap = a.alloc(u8, @as(usize, self.geom.bitmap_blocks) * block_size) catch return false;
        if (self.dirty.len == 0) {
            self.dirty = a.alloc(u8, self.geom.bitmap_blocks) catch return false;
            @memset(self.dirty, 0);
        }
        if (self.table.len == 0) self.table = a.alloc(u8, @as(usize, self.geom.table_blocks) * block_size) catch return false;
        return true;
    }

    fn cardOf(self: *FlatFs) *sd.SdCard {
        return self.card.?;
    }

    fn writeSb(self: *FlatFs) Error!void {
        var sb: [block_size]u8 = @splat(0);
        @memcpy(sb[sb_magic..][0..8], magic_str);
        storeLe32(sb[sb_version..], layout_version);
        storeLe32(sb[sb_block_size..], block_size);
        storeLe32(sb[sb_total..], self.geom.total_blocks);
        storeLe32(sb[sb_data_start..], self.geom.data_start);
        storeLe32(sb[sb_bitmap_blocks..], self.geom.bitmap_blocks);
        storeLe32(sb[sb_table_blocks..], self.geom.table_blocks);
        storeLe32(sb[sb_max_files..], self.geom.max_files);
        storeLe32(sb[sb_free..], self.free_blocks_);
        if (!self.cardOf().writeSectors(super_block, 1, &sb)) return error.Io;
    }

    fn readSb(self: *FlatFs) Error!void {
        var sb: [block_size]u8 = undefined;
        if (!self.cardOf().readSectors(super_block, 1, &sb)) return error.Io;
        if (!std.mem.eql(u8, sb[sb_magic..][0..8], magic_str)) return error.NoFs;
        if (loadLe32(sb[sb_version..]) != layout_version) return error.NoFs;
        if (loadLe32(sb[sb_block_size..]) != block_size) return error.NoFs;
        self.geom.total_blocks = loadLe32(sb[sb_total..]);
        self.geom.data_start = loadLe32(sb[sb_data_start..]);
        self.geom.bitmap_blocks = loadLe32(sb[sb_bitmap_blocks..]);
        self.geom.table_blocks = loadLe32(sb[sb_table_blocks..]);
        self.geom.max_files = loadLe32(sb[sb_max_files..]);
        self.geom.data_blocks = self.geom.total_blocks -% self.geom.data_start;
        self.free_blocks_ = loadLe32(sb[sb_free..]);
        if (self.geom.total_blocks != self.cardOf().sectorCount()) return error.Format;
        if (self.geom.data_start != 1 + self.geom.bitmap_blocks + self.geom.table_blocks) return error.Format;
        if (self.geom.max_files != self.geom.table_blocks * entries_per_block) return error.Format;
    }

    // ---- The bitmap.

    fn bitTest(self: *const FlatFs, p: u32) bool {
        return (self.bitmap[p >> 3] & (@as(u8, 1) << @intCast(p & 7))) != 0;
    }

    fn bitSet(self: *FlatFs, p: u32) void {
        self.bitmap[p >> 3] |= @as(u8, 1) << @intCast(p & 7);
        self.markDirty(p);
    }

    fn bitClear(self: *FlatFs, p: u32) void {
        self.bitmap[p >> 3] &= ~(@as(u8, 1) << @intCast(p & 7));
        self.markDirty(p);
    }

    fn markDirty(self: *FlatFs, bitpos: u32) void {
        self.dirty[bitpos >> 12] = 1; // 4096 bits per sector
    }

    fn loadBitmap(self: *FlatFs) Error!void {
        if (!self.cardOf().readSectors(1, self.geom.bitmap_blocks, self.bitmap)) return error.Io;
        // Recompute the free count from the bitmap (do not trust the
        // superblock).
        var free: u32 = 0;
        var p: u32 = 0;
        while (p < self.geom.data_blocks) : (p += 1) {
            if (!self.bitTest(p)) free += 1;
        }
        self.free_blocks_ = free;
    }

    fn flushBitmapDirty(self: *FlatFs) Error!void {
        var s: u32 = 0;
        while (s < self.geom.bitmap_blocks) : (s += 1) {
            if (self.dirty[s] != 0) {
                if (!self.cardOf().writeSectors(1 + s, 1, self.bitmap[@as(usize, s) * block_size ..])) return error.Io;
                self.dirty[s] = 0;
            }
        }
    }

    // ---- The file table.

    fn loadTable(self: *FlatFs) Error!void {
        if (!self.cardOf().readSectors(1 + self.geom.bitmap_blocks, self.geom.table_blocks, self.table)) return error.Io;
    }

    fn flushTable(self: *FlatFs) Error!void {
        if (!self.cardOf().writeSectors(1 + self.geom.bitmap_blocks, self.geom.table_blocks, self.table)) return error.Io;
    }

    fn entry(self: *FlatFs, idx: u32) []u8 {
        return self.table[@as(usize, idx) * entry_bytes ..][0..entry_bytes];
    }

    fn findFile(self: *FlatFs, name: []const u8) ?u32 {
        var e: u32 = 0;
        while (e < self.geom.max_files) : (e += 1) {
            const p = self.entry(e);
            if (loadLe32(p[e_flags..]) & flag_valid != 0) {
                const stored = std.mem.sliceTo(p[e_name .. e_name + name_max + 1], 0);
                if (std.mem.eql(u8, stored, name)) return e;
            }
        }
        return null;
    }

    // ---- The public API.

    pub fn format(self: *FlatFs, card: *sd.SdCard) Error!void {
        self.card = card;
        self.releaseBuffers();
        self.geom = geometryFor(card.sectorCount());
        if (self.geom.data_blocks == 0) return error.Format;

        // Refuse media that already looks like a DOS MBR / FAT boot volume
        // (a real boot card): blank images and flatfs volumes are fine.
        {
            var sec0: [512]u8 = undefined;
            if (card.readSectors(0, 1, &sec0) and sec0[510] == 0x55 and sec0[511] == 0xAA) {
                self.last = error.Media;
                return error.Media;
            }
        }
        if (!self.ensureBuffers()) return error.Io;

        // Empty metadata: nothing allocated, an empty table.
        @memset(self.bitmap, 0);
        @memset(self.dirty, 0);
        @memset(self.table, 0);
        self.free_blocks_ = self.geom.data_blocks;

        if (!card.writeSectors(1, self.geom.bitmap_blocks, self.bitmap)) return error.Io;
        if (!card.writeSectors(1 + self.geom.bitmap_blocks, self.geom.table_blocks, self.table)) return error.Io;
        self.writeSb() catch return error.Io;
        self.mounted_ = true;
        self.last = null;
    }

    pub fn mount(self: *FlatFs, card: *sd.SdCard) Error!void {
        self.card = card;
        self.releaseBuffers();
        self.readSb() catch {
            self.last = error.NoFs;
            return error.NoFs;
        };
        if (!self.ensureBuffers()) return error.Io;
        self.loadBitmap() catch return error.Io;
        self.loadTable() catch return error.Io;
        self.mounted_ = true;
        self.last = null;
    }

    pub fn mounted(self: *const FlatFs) bool {
        return self.mounted_;
    }

    fn allocBlocks(self: *FlatFs, n: u32) ?u32 {
        var run: u32 = 0;
        var run_start: u32 = 0;
        var p: u32 = 0;
        while (p < self.geom.data_blocks) : (p += 1) {
            if (self.bitTest(p)) {
                run = 0;
                run_start = p + 1;
            } else {
                if (run == 0) run_start = p;
                run += 1;
                if (run == n) {
                    var q = run_start;
                    while (q <= p) : (q += 1) self.bitSet(q);
                    self.free_blocks_ -= n;
                    return self.geom.data_start + run_start;
                }
            }
        }
        return null;
    }

    fn freeBlocks(self: *FlatFs, start_block: u32, n: u32) void {
        if (n == 0) return;
        const first = start_block - self.geom.data_start;
        var q: u32 = 0;
        while (q < n) : (q += 1) self.bitClear(first + q);
        self.free_blocks_ += n;
    }

    pub fn writeFile(self: *FlatFs, name: []const u8, data: []const u8) Error!void {
        if (!self.mounted_) return error.NoFs;
        if (name.len == 0 or name.len > name_max) return error.Name;
        const size: u32 = @intCast(data.len);

        var idx: ?u32 = self.findFile(name);
        if (idx) |i| {
            const p = self.entry(i);
            self.freeBlocks(loadLe32(p[e_start..]), sectorsFor(loadLe32(p[e_size..])));
        } else {
            // The first free slot.
            var e: u32 = 0;
            while (e < self.geom.max_files) : (e += 1) {
                if (loadLe32(self.entry(e)[e_flags..]) & flag_valid == 0) {
                    idx = e;
                    break;
                }
            }
            if (idx == null) return error.Full;
        }

        const sectors = sectorsFor(size);
        var start: u32 = 0;
        if (sectors > 0) {
            start = self.allocBlocks(sectors) orelse {
                // Leave the slot empty rather than half-written.
                @memset(self.entry(idx.?), 0);
                return error.NoSpace;
            };
            const full = size / block_size;
            if (full > 0 and !self.cardOf().writeSectors(start, full, data)) return error.Io;
            const rem = size % block_size;
            if (rem > 0) {
                var sector: [block_size]u8 = @splat(0);
                @memcpy(sector[0..rem], data[@as(usize, full) * block_size ..][0..rem]);
                if (!self.cardOf().writeSectors(start + full, 1, &sector)) return error.Io;
            }
        }

        // The table entry.
        const q = self.entry(idx.?);
        @memset(q, 0);
        @memcpy(q[e_name..][0..name.len], name);
        storeLe32(q[e_start..], start);
        storeLe32(q[e_size..], size);
        storeLe32(q[e_flags..], flag_valid);

        self.flush() catch |err| {
            self.last = err;
            return err;
        };
        self.last = null;
    }

    pub fn appendFile(self: *FlatFs, name: []const u8, data: []const u8) Error!void {
        if (!self.mounted_) return error.NoFs;
        const size: u32 = @intCast(data.len);
        if (size == 0) return;

        // Nothing to append to yet: the first append is a write.
        const idx = self.findFile(name) orelse return self.writeFile(name, data);

        const q = self.entry(idx);
        const start = loadLe32(q[e_start..]);
        const old_size = loadLe32(q[e_size..]);
        // An empty file has no extent: allocate one, as a write does.
        if (old_size == 0) return self.writeFile(name, data);
        const new_size, const overflow = @addWithOverflow(old_size, size);
        if (overflow != 0) return error.NoSpace; // 32-bit size overflow

        const old_sectors = sectorsFor(old_size);
        const new_sectors = sectorsFor(new_size);

        // Grow the extent in place: the blocks right after it must be free
        // (extents are contiguous; there is no relocation).
        if (new_sectors > old_sectors) {
            const extra = new_sectors - old_sectors;
            const first = start + old_sectors - self.geom.data_start;
            if (first + extra > self.geom.data_blocks) return error.NoSpace;
            var i: u32 = 0;
            while (i < extra) : (i += 1) if (self.bitTest(first + i)) return error.NoSpace;
            i = 0;
            while (i < extra) : (i += 1) self.bitSet(first + i);
            self.free_blocks_ -= extra;
        }

        var written: u32 = 0;
        var sector: [block_size]u8 = undefined;

        // Head: the last sector is usually partial, a read-modify-write.
        const head_off = old_size % block_size;
        if (head_off != 0) {
            const sec = start + old_size / block_size;
            if (!self.cardOf().readSectors(sec, 1, &sector)) return error.Io;
            const n = @min(block_size - head_off, size);
            @memcpy(sector[head_off..][0..n], data[0..n]);
            if (!self.cardOf().writeSectors(sec, 1, &sector)) return error.Io;
            written = n;
        }

        // Body: whole sectors, straight from the caller's buffer.
        const body_start = start + (old_size + written) / block_size;
        const full = (size - written) / block_size;
        if (full > 0) {
            if (!self.cardOf().writeSectors(body_start, full, data[written..])) return error.Io;
            written += full * block_size;
        }

        // Tail: a final partial sector, zero-padded.
        const rem = size - written;
        if (rem > 0) {
            const sec = start + (old_size + written) / block_size;
            @memset(&sector, 0);
            @memcpy(sector[0..rem], data[written..][0..rem]);
            if (!self.cardOf().writeSectors(sec, 1, &sector)) return error.Io;
        }

        storeLe32(q[e_size..], new_size);
        self.flush() catch |err| {
            self.last = err;
            return err;
        };
        self.last = null;
    }

    /// Read up to `buf.len` bytes from `offset`; returns the bytes read (0
    /// at or after the end). `buf` must also hold the sector-aligned span.
    pub fn readFileAt(self: *FlatFs, name: []const u8, offset: u32, buf: []u8) Error!u32 {
        if (!self.mounted_) return error.NoFs;
        const idx = self.findFile(name) orelse return error.NotFound;
        const p = self.entry(idx);
        const start = loadLe32(p[e_start..]);
        const size = loadLe32(p[e_size..]);
        if (offset >= size) return 0; // at/after EOF: no bytes, not an error

        const cap: u32 = @intCast(buf.len);
        var want = @min(size - offset, cap);
        // Whole sectors are read into the caller's buffer, then the payload
        // slides down over the leading partial sector: trim `want` until the
        // aligned span fits.
        const sec_off = offset % block_size;
        while (want > 0 and sectorsFor(sec_off + want) * block_size > cap) want -|= block_size;
        if (want == 0) return error.Buf;

        const sec_first = start + offset / block_size;
        const nsec = sectorsFor(sec_off + want);
        if (!self.cardOf().readSectors(sec_first, nsec, buf)) return error.Io;
        if (sec_off != 0) std.mem.copyForwards(u8, buf[0..want], buf[sec_off..][0..want]);
        return want;
    }

    /// Read the whole file into `buf`; returns its size.
    pub fn readFile(self: *FlatFs, name: []const u8, buf: []u8) Error!u32 {
        if (!self.mounted_) return error.NoFs;
        const idx = self.findFile(name) orelse return error.NotFound;
        const p = self.entry(idx);
        const start = loadLe32(p[e_start..]);
        const size = loadLe32(p[e_size..]);
        if (size == 0) return 0;
        if (buf.len < size) return error.Buf;

        const sectors = sectorsFor(size);
        if (buf.len >= @as(usize, sectors) * block_size) {
            // Room for whole sectors: one read, straight into the buffer.
            if (!self.cardOf().readSectors(start, sectors, buf)) return error.Io;
        } else {
            // Copy only the meaningful bytes, never past the buffer.
            var sector: [block_size]u8 = undefined;
            var left = size;
            var s: u32 = 0;
            while (s < sectors) : (s += 1) {
                if (!self.cardOf().readSectors(start + s, 1, &sector)) return error.Io;
                const take = @min(left, block_size);
                @memcpy(buf[@as(usize, s) * block_size ..][0..take], sector[0..take]);
                left -= take;
            }
        }
        return size;
    }

    pub fn fileSize(self: *FlatFs, name: []const u8) Error!u32 {
        const idx = self.findFile(name) orelse return error.NotFound;
        return loadLe32(self.entry(idx)[e_size..]);
    }

    pub fn removeFile(self: *FlatFs, name: []const u8) Error!void {
        if (!self.mounted_) return error.NoFs;
        const idx = self.findFile(name) orelse return error.NotFound;
        const p = self.entry(idx);
        self.freeBlocks(loadLe32(p[e_start..]), sectorsFor(loadLe32(p[e_size..])));
        @memset(p, 0);
        self.flush() catch |err| {
            self.last = err;
            return err;
        };
        self.last = null;
    }

    pub const Stat = struct { total_sectors: u32, free_sectors: u32, file_count: u32 };

    pub fn stat(self: *FlatFs) Error!Stat {
        if (!self.mounted_) return error.NoFs;
        var count: u32 = 0;
        var e: u32 = 0;
        while (e < self.geom.max_files) : (e += 1) {
            if (loadLe32(self.entry(e)[e_flags..]) & flag_valid != 0) count += 1;
        }
        return .{ .total_sectors = self.geom.total_blocks, .free_sectors = self.free_blocks_, .file_count = count };
    }

    /// Call `visitor` for every file, until it returns false.
    pub fn list(self: *FlatFs, ctx: anytype, comptime visitor: fn (@TypeOf(ctx), *const FileEntry) bool) Error!void {
        if (!self.mounted_) return error.NoFs;
        var e: u32 = 0;
        while (e < self.geom.max_files) : (e += 1) {
            const p = self.entry(e);
            if (loadLe32(p[e_flags..]) & flag_valid != 0) {
                var fe: FileEntry = .{ .name = undefined, .start_block = loadLe32(p[e_start..]), .size_bytes = loadLe32(p[e_size..]) };
                @memcpy(&fe.name, p[e_name..][0 .. name_max + 1]);
                fe.name[name_max] = 0;
                if (!visitor(ctx, &fe)) break;
            }
        }
    }

    pub fn flush(self: *FlatFs) Error!void {
        if (!self.mounted_) return error.NoFs;
        self.flushTable() catch return error.Io;
        self.flushBitmapDirty() catch return error.Io;
        self.writeSb() catch return error.Io;
    }
};
