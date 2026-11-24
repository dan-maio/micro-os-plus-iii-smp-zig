//! The SD card of the native board: a host file standing in for the card
//! (the C++ soc/native/src/sd_hostfile.cpp, SD_BACKEND_HOSTFILE).
//!
//! The image is `$UOS_SD_IMAGE` (default `disk.img`, in the current folder),
//! grown (never shrunk) to `$UOS_SD_SECTORS` sectors (default 65536, 32 MiB).
//! Reads and writes are `pread()`/`pwrite()` at the sector offset, with the
//! same range check as the silicon back ends.

const std = @import("std");

pub const sector_size: u32 = 512;

const default_sectors: u32 = 65536; // 32 MiB

pub const Result = enum {
    ok,
    err_no_card, // no medium (here: the image cannot be opened)
    err_timeout, // a transfer failed (here: a short read or write)
    err_crc,
    err_cmd,
    err_voltage,
    err_unsupported,
    err_range, // LBA + count beyond the end of the card
};

fn imagePath() [*:0]const u8 {
    if (std.c.getenv("UOS_SD_IMAGE")) |p| if (p[0] != 0) return p;
    return "disk.img";
}

fn imageSectors() u32 {
    const s = std.c.getenv("UOS_SD_SECTORS") orelse return default_sectors;
    const v = std.fmt.parseInt(u32, std.mem.span(s), 0) catch return default_sectors;
    return if (v > 0) v else default_sectors;
}

pub const SdCard = struct {
    ready_: bool = false,
    hc: bool = true,
    sectors: u32 = 0,
    fd: c_int = -1,
    result: Result = .ok,
    err: []const u8 = "no error",

    fn setResult(self: *SdCard, r: Result, msg: []const u8) void {
        self.result = r;
        self.err = msg;
    }

    fn markOk(self: *SdCard) void {
        self.setResult(.ok, "no error");
    }

    /// Open (or create) the image and size it; true when the card is ready.
    pub fn init(self: *SdCard) bool {
        self.ready_ = false;
        self.fd = std.c.open(imagePath(), .{ .ACCMODE = .RDWR, .CREAT = true }, @as(std.c.mode_t, 0o644));
        if (self.fd < 0) {
            self.setResult(.err_no_card, "cannot open the backing image");
            return false;
        }
        // The image size (the C++ back end fstat()s it).
        const end = std.c.lseek(self.fd, 0, std.c.SEEK.END);
        if (end < 0) {
            self.setResult(.err_no_card, "cannot stat the backing image");
            return false;
        }
        var bytes: u64 = @intCast(end);
        const want = @as(u64, imageSectors()) * sector_size;
        // Grow, never shrink: an existing image is a card that already has
        // something on it.
        if (bytes < want) {
            if (std.c.ftruncate(self.fd, @intCast(want)) != 0) {
                self.setResult(.err_no_card, "cannot size the backing image");
                return false;
            }
            bytes = want;
        }
        self.sectors = @intCast(bytes / sector_size);
        if (self.sectors == 0) {
            self.setResult(.err_unsupported, "backing image holds no sector");
            return false;
        }
        self.ready_ = true;
        self.markOk();
        return true;
    }

    pub fn sectorCount(self: *const SdCard) u32 {
        return self.sectors;
    }

    pub fn capacityBytes(self: *const SdCard) u64 {
        return @as(u64, self.sectors) * sector_size;
    }

    pub fn highCapacity(self: *const SdCard) bool {
        return self.hc;
    }

    pub fn ready(self: *const SdCard) bool {
        return self.ready_;
    }

    pub fn lastError(self: *const SdCard) []const u8 {
        return self.err;
    }

    pub fn lastResult(self: *const SdCard) Result {
        return self.result;
    }

    fn checkRange(self: *SdCard, lba: u32, count: u32) bool {
        if (!self.ready_) {
            self.setResult(.err_no_card, "card not initialised");
            return false;
        }
        // A file system bug must stop here, not touch what follows the image.
        if (count == 0 or lba > self.sectors or count > self.sectors - lba) {
            self.setResult(.err_range, "LBA beyond the end of the card");
            return false;
        }
        return true;
    }

    pub fn readSectors(self: *SdCard, lba: u32, count: u32, dst: []u8) bool {
        if (!self.checkRange(lba, count)) return false;
        var buf = dst[0 .. @as(usize, count) * sector_size];
        var off: i64 = @as(i64, lba) * sector_size;
        while (buf.len > 0) {
            const n = std.c.pread(self.fd, buf.ptr, buf.len, off);
            if (n <= 0) {
                self.setResult(.err_timeout, "short read from the image");
                return false;
            }
            buf = buf[@intCast(n)..];
            off += n;
        }
        self.markOk();
        return true;
    }

    pub fn writeSectors(self: *SdCard, lba: u32, count: u32, src: []const u8) bool {
        if (!self.checkRange(lba, count)) return false;
        var buf = src[0 .. @as(usize, count) * sector_size];
        var off: i64 = @as(i64, lba) * sector_size;
        while (buf.len > 0) {
            const n = std.c.pwrite(self.fd, buf.ptr, buf.len, off);
            if (n <= 0) {
                self.setResult(.err_timeout, "short write to the image");
                return false;
            }
            buf = buf[@intCast(n)..];
            off += n;
        }
        self.markOk();
        return true;
    }
};
