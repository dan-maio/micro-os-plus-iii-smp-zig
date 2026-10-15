//! FatFs on the board's boot card (the C++ drivers/fatfs/diskio_sd.cpp and
//! fatfs_hw.cpp, the hardware build of the SD tests).
//!
//! The card is the board's boot card: the volume is the EXISTING first FAT
//! partition of its MBR (or the whole card without one), mounted read-write
//! and never formatted (FF_USE_MKFS is 0), and every test file lives under
//! "tests/". FatFs itself is the C ff.c (R0.15a), compiled unchanged; this
//! file is its disk glue (`disk_*`) and the test helpers.
//!
//! Single volume, not reentrant (FF_FS_REENTRANT 0): the callers serialise
//! access, as in C++.

const std = @import("std");
const sd = @import("sd");
const ff = @import("ff");

// ---- The disk glue (diskio_sd.cpp) -----------------------------------------

var g_card: ?*sd.SdCard = null;
var g_inited = false;

/// The FAT volume inside the card.
var g_base_lba: u32 = 0;
var g_vol_blocks: u32 = 0;

fn isFatType(t: u8) bool {
    return switch (t) {
        0x01, 0x04, 0x06, 0x0e, // FAT12/FAT16
        0x0b, 0x0c, 0x1b, 0x1c, // FAT32
        0x2b, 0x2c,
        => true,
        else => false,
    };
}

/// Scan the MBR for the first FAT partition; false only on an I/O error.
/// Without a FAT partition (or an MBR) the whole card is the volume.
fn locatePartition() bool {
    const card = g_card.?;
    var mbr: [512]u8 = undefined;
    if (!card.readSectors(0, 1, &mbr)) return false;
    if (mbr[510] == 0x55 and mbr[511] == 0xAA) {
        for (0..4) |i| {
            const e = mbr[446 + i * 16 ..][0..16];
            if (e[4] != 0 and isFatType(e[4])) {
                g_base_lba = std.mem.readInt(u32, e[8..12], .little);
                g_vol_blocks = std.mem.readInt(u32, e[12..16], .little);
                return true;
            }
        }
    }
    g_base_lba = 0;
    g_vol_blocks = card.sectorCount();
    return true;
}

/// `fatfs_use_card()`: hand over a card; an initialised one is scanned now.
fn useCard(card: *sd.SdCard) void {
    g_card = card;
    if (card.ready()) {
        _ = locatePartition();
        g_inited = true;
    }
}

export fn disk_status(pdrv: ff.BYTE) callconv(.c) ff.DSTATUS {
    if (pdrv != 0) return ff.STA_NOINIT;
    return if (g_inited) 0 else ff.STA_NOINIT;
}

var lazy_card: sd.SdCard = .{};

export fn disk_initialize(pdrv: ff.BYTE) callconv(.c) ff.DSTATUS {
    if (pdrv != 0) return ff.STA_NOINIT;
    if (!g_inited) {
        const card = g_card orelse blk: {
            g_card = &lazy_card;
            break :blk &lazy_card;
        };
        if (!card.init()) return ff.STA_NOINIT | ff.STA_NODISK;
        if (!locatePartition()) return ff.STA_NOINIT;
        g_inited = true;
    }
    return 0;
}

export fn disk_read(pdrv: ff.BYTE, buff: [*]ff.BYTE, sector: ff.LBA_t, count: ff.UINT) callconv(.c) ff.DRESULT {
    if (pdrv != 0) return ff.RES_PARERR;
    if (!g_inited) return ff.RES_NOTRDY;
    if (@as(u64, sector) + count > g_vol_blocks) return ff.RES_PARERR;
    return if (g_card.?.readSectors(g_base_lba + sector, count, buff[0 .. @as(usize, count) * sd.sector_size]))
        ff.RES_OK
    else
        ff.RES_ERROR;
}

export fn disk_write(pdrv: ff.BYTE, buff: [*]const ff.BYTE, sector: ff.LBA_t, count: ff.UINT) callconv(.c) ff.DRESULT {
    if (pdrv != 0) return ff.RES_PARERR;
    if (!g_inited) return ff.RES_NOTRDY;
    if (@as(u64, sector) + count > g_vol_blocks) return ff.RES_PARERR;
    return if (g_card.?.writeSectors(g_base_lba + sector, count, buff[0 .. @as(usize, count) * sd.sector_size]))
        ff.RES_OK
    else
        ff.RES_ERROR;
}

export fn disk_ioctl(pdrv: ff.BYTE, cmd: ff.BYTE, buff: ?*anyopaque) callconv(.c) ff.DRESULT {
    if (pdrv != 0) return ff.RES_PARERR;
    switch (cmd) {
        ff.CTRL_SYNC => return ff.RES_OK, // writes are synchronous
        ff.GET_SECTOR_COUNT => {
            @as(*ff.LBA_t, @ptrCast(@alignCast(buff.?))).* = g_vol_blocks;
            return ff.RES_OK;
        },
        ff.GET_SECTOR_SIZE => {
            @as(*ff.WORD, @ptrCast(@alignCast(buff.?))).* = 512;
            return ff.RES_OK;
        },
        ff.GET_BLOCK_SIZE => {
            @as(*ff.DWORD, @ptrCast(@alignCast(buff.?))).* = 1; // unknown
            return ff.RES_OK;
        },
        else => return ff.RES_PARERR,
    }
}

// ---- The test helpers (fatfshw::) ------------------------------------------

var g_bound_card: ?*sd.SdCard = null;
var g_fs: ff.FATFS = undefined;
var g_mounted = false;
var g_dir_ok = false;
var g_last: ff.FRESULT = ff.FR_OK;

fn fresStr(fr: ff.FRESULT) []const u8 {
    return switch (fr) {
        ff.FR_OK => "ok",
        ff.FR_DISK_ERR => "disk error",
        ff.FR_INT_ERR => "internal error",
        ff.FR_NOT_READY => "drive not ready",
        ff.FR_NO_FILE => "no such file",
        ff.FR_NO_PATH => "no such path",
        ff.FR_INVALID_NAME => "invalid name",
        ff.FR_DENIED => "access denied",
        ff.FR_EXIST => "already exists",
        ff.FR_INVALID_OBJECT => "invalid object",
        ff.FR_WRITE_PROTECTED => "write protected",
        ff.FR_INVALID_DRIVE => "invalid drive",
        ff.FR_NOT_ENABLED => "volume not mounted",
        ff.FR_NO_FILESYSTEM => "no FAT filesystem",
        ff.FR_MKFS_ABORTED => "mkfs aborted",
        ff.FR_TIMEOUT => "timeout",
        ff.FR_LOCKED => "locked",
        ff.FR_NOT_ENOUGH_CORE => "out of memory",
        ff.FR_TOO_MANY_OPEN_FILES => "too many open files",
        ff.FR_INVALID_PARAMETER => "invalid parameter",
        else => "unknown",
    };
}

/// The FA_* macros come out of translate-c as c_int.
fn openMode(comptime m: c_int) ff.BYTE {
    return @intCast(m);
}

fn fatOk(fr: ff.FRESULT) bool {
    g_last = fr;
    return fr == ff.FR_OK;
}

/// "tests/<leaf>", NUL-terminated.
fn testsPath(buf: *[64]u8, leaf: []const u8) [*:0]const u8 {
    return (std.fmt.bufPrintSentinel(buf, "tests/{s}", .{leaf}, 0) catch return "").ptr;
}

pub fn bindCard(card: *sd.SdCard) void {
    g_bound_card = card;
}

/// Mount the volume already on the card (never formats).
pub fn mountVolume() bool {
    if (g_mounted) return true;
    const card = g_bound_card orelse {
        g_last = ff.FR_NOT_READY;
        return false;
    };
    useCard(card);
    if (!fatOk(ff.f_mount(&g_fs, "", 1))) return false;
    g_mounted = true;
    return true;
}

/// Create "tests" when missing; its contents are kept.
pub fn ensureTestsDir() bool {
    if (g_dir_ok) return true;
    if (!g_mounted) return false;
    var fr = ff.f_mkdir("tests");
    if (fr == ff.FR_EXIST) fr = ff.FR_OK;
    if (!fatOk(fr)) return false;
    g_dir_ok = true;
    return true;
}

fn writeFile(leaf: []const u8, data: []const u8, comptime mode: c_int) bool {
    if (!g_mounted or !g_dir_ok) return false;
    var path: [64]u8 = undefined;
    var f: ff.FIL = undefined;
    if (!fatOk(ff.f_open(&f, testsPath(&path, leaf), openMode(mode | ff.FA_WRITE)))) return false;
    var written: ff.UINT = 0;
    var fr = ff.f_write(&f, data.ptr, @intCast(data.len), &written);
    if (fr == ff.FR_OK and written != data.len) fr = ff.FR_DISK_ERR;
    _ = ff.f_close(&f);
    return fatOk(fr);
}

pub fn storeFile(leaf: []const u8, data: []const u8) bool {
    return writeFile(leaf, data, ff.FA_CREATE_ALWAYS);
}

/// Create when missing, else append.
pub fn appendFile(leaf: []const u8, data: []const u8) bool {
    return writeFile(leaf, data, ff.FA_OPEN_APPEND);
}

pub fn loadFileAt(leaf: []const u8, offset: u32, data: []u8) bool {
    if (!g_mounted or !g_dir_ok) return false;
    var path: [64]u8 = undefined;
    var f: ff.FIL = undefined;
    if (!fatOk(ff.f_open(&f, testsPath(&path, leaf), openMode(ff.FA_READ)))) return false;
    var fr = ff.f_lseek(&f, offset);
    if (fr == ff.FR_OK and f.fptr != offset) fr = ff.FR_DISK_ERR; // past EOF
    if (fr == ff.FR_OK) {
        var got: ff.UINT = 0;
        fr = ff.f_read(&f, data.ptr, @intCast(data.len), &got);
        if (fr == ff.FR_OK and got != data.len) fr = ff.FR_DISK_ERR;
    }
    _ = ff.f_close(&f);
    return fatOk(fr);
}

pub fn loadFile(leaf: []const u8, data: []u8) bool {
    if (!g_mounted or !g_dir_ok) return false;
    var path: [64]u8 = undefined;
    var f: ff.FIL = undefined;
    if (!fatOk(ff.f_open(&f, testsPath(&path, leaf), openMode(ff.FA_READ)))) return false;
    var got: ff.UINT = 0;
    var fr = ff.f_read(&f, data.ptr, @intCast(data.len), &got);
    if (fr == ff.FR_OK and got != data.len) fr = ff.FR_DISK_ERR;
    _ = ff.f_close(&f);
    return fatOk(fr);
}

pub fn fileSize(leaf: []const u8) ?u32 {
    if (!g_mounted or !g_dir_ok) return null;
    var path: [64]u8 = undefined;
    var fi: ff.FILINFO = std.mem.zeroes(ff.FILINFO);
    if (!fatOk(ff.f_stat(testsPath(&path, leaf), &fi))) return null;
    return @intCast(fi.fsize);
}

pub fn removeFile(leaf: []const u8) bool {
    if (!g_mounted or !g_dir_ok) return false;
    var path: [64]u8 = undefined;
    return fatOk(ff.f_unlink(testsPath(&path, leaf)));
}

pub const Space = struct { total_kib: u32, free_kib: u32 };

/// Total and free space, in KiB (counted in sectors: bytes overflow 32 bits
/// past 4 GB).
pub fn volumeSpaceKib() ?Space {
    if (!g_mounted) return null;
    var free_clst: ff.DWORD = 0;
    var pfs: ?*ff.FATFS = null;
    if (!fatOk(ff.f_getfree("", &free_clst, &pfs))) return null;
    const fs = pfs.?;
    const total_sect: u32 = @as(u32, @intCast(fs.n_fatent - 2)) * fs.csize;
    const free_sect: u32 = @as(u32, @intCast(free_clst)) * fs.csize;
    return .{ .total_kib = total_sect >> 1, .free_kib = free_sect >> 1 };
}

/// Call `visitor(name, size)` for every file in "tests"; stops when it
/// returns false. Returns the files visited.
pub fn visitTestsDir(ctx: anytype, comptime visitor: fn (@TypeOf(ctx), []const u8, u32) bool) u32 {
    if (!g_mounted or !g_dir_ok) return 0;
    var d: ff.DIR = undefined;
    if (!fatOk(ff.f_opendir(&d, "tests"))) return 0;
    var count: u32 = 0;
    while (true) {
        var fi: ff.FILINFO = std.mem.zeroes(ff.FILINFO);
        if (!fatOk(ff.f_readdir(&d, &fi)) or fi.fname[0] == 0) break;
        if (fi.fattrib & ff.AM_DIR != 0) continue;
        count += 1;
        if (!visitor(ctx, std.mem.sliceTo(&fi.fname, 0), @intCast(fi.fsize))) break;
    }
    _ = ff.f_closedir(&d);
    return count;
}

/// One "<name>  <size>" line per file of "tests" into `buf`; returns the
/// files listed (the output is cut at a whole line).
pub fn listTestsDir(buf: []u8) struct { count: u32, text: []const u8 } {
    var w: std.Io.Writer = .fixed(buf);
    const Ctx = struct {
        w: *std.Io.Writer,
        n: u32 = 0,
        fn line(c: *@This(), name: []const u8, size: u32) bool {
            const before = c.w.end;
            c.w.print("{s:<12}  {d:>8}\n", .{ name, size }) catch {
                c.w.end = before;
                return false;
            };
            c.n += 1;
            return true;
        }
    };
    var ctx: Ctx = .{ .w = &w };
    _ = visitTestsDir(&ctx, Ctx.line);
    return .{ .count = ctx.n, .text = w.buffered() };
}

pub const Window = struct { base_lba: u32, blocks: u32 };

/// The FAT window located in the MBR (scanned now if the card is bound).
pub fn partitionWindow() Window {
    if (g_bound_card) |card| useCard(card);
    return .{ .base_lba = g_base_lba, .blocks = g_vol_blocks };
}

pub const Geometry = struct { fat_type: []const u8, sec_per_clus: u32, clusters: u32 };

pub fn volumeGeometry() ?Geometry {
    if (!g_mounted) return null;
    return .{
        .fat_type = switch (g_fs.fs_type) {
            ff.FS_FAT12 => "FAT12",
            ff.FS_FAT16 => "FAT16",
            ff.FS_FAT32 => "FAT32",
            ff.FS_EXFAT => "exFAT",
            else => "?",
        },
        .sec_per_clus = g_fs.csize,
        .clusters = if (g_fs.n_fatent >= 2) @intCast(g_fs.n_fatent - 2) else 0,
    };
}

pub fn lastError() []const u8 {
    return fresStr(g_last);
}
