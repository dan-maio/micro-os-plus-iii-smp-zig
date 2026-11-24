//! The SD card of the Luckfox Lyra (the C++ soc/rk3506/include/sd_dwmmc.hpp
//! and src/sd_dwmmc.cpp, SD_BACKEND_DWMMC): `sd.SdCard`, the same API as the
//! POSIX port's host-file card, forwarding to the DW-MMC driver.

const sdmmc = @import("sdmmc.zig");

pub const sector_size: u32 = 512;

pub const Result = enum {
    ok,
    err_no_card,
    err_timeout,
    err_crc,
    err_cmd,
    err_voltage,
    err_unsupported,
    err_range,
};

pub const SdCard = struct {
    hw: sdmmc.SdMmc = .{},
    result: Result = .ok,
    err: []const u8 = "no error",

    fn setResult(self: *SdCard, r: Result, msg: []const u8) void {
        self.result = r;
        self.err = msg;
    }

    /// Identify the card. On a failure the error is the bring-up step it
    /// stopped at; one that did not get past CMD0 means no card.
    pub fn init(self: *SdCard) bool {
        if (self.hw.init()) {
            self.setResult(.ok, "no error");
            return true;
        }
        const step = self.hw.step;
        self.setResult(
            if (@intFromEnum(step) <= @intFromEnum(sdmmc.Step.cmd0)) .err_no_card else .err_timeout,
            step.name(),
        );
        return false;
    }

    pub fn sectorCount(self: *const SdCard) u32 {
        return @intCast(self.hw.capacity_bytes / sdmmc.block_size);
    }

    pub fn capacityBytes(self: *const SdCard) u64 {
        return self.hw.capacity_bytes;
    }

    pub fn highCapacity(self: *const SdCard) bool {
        return self.hw.high_capacity;
    }

    pub fn ready(self: *const SdCard) bool {
        return self.hw.present;
    }

    pub fn lastError(self: *const SdCard) []const u8 {
        return self.err;
    }

    pub fn lastResult(self: *const SdCard) Result {
        return self.result;
    }

    fn rangeOk(self: *SdCard, lba: u32, count: u32) bool {
        if (!self.hw.present) {
            self.setResult(.err_no_card, "no card");
            return false;
        }
        const total = self.sectorCount();
        if (count == 0 or lba > total or count > total - lba) {
            self.setResult(.err_range, "LBA range beyond end of card");
            return false;
        }
        return true;
    }

    pub fn readSectors(self: *SdCard, lba: u32, count: u32, dst: []u8) bool {
        if (!self.rangeOk(lba, count)) return false;
        if (!self.hw.readBlocks(lba, dst[0 .. @as(usize, count) * sector_size], count)) {
            self.setResult(.err_timeout, "read failed");
            return false;
        }
        self.setResult(.ok, "no error");
        return true;
    }

    pub fn writeSectors(self: *SdCard, lba: u32, count: u32, src: []const u8) bool {
        if (!self.rangeOk(lba, count)) return false;
        if (!self.hw.writeBlocks(lba, src[0 .. @as(usize, count) * sector_size], count)) {
            self.setResult(.err_timeout, "write failed");
            return false;
        }
        self.setResult(.ok, "no error");
        return true;
    }
};
