//! The SD card of the Raspberry Pi 4 B: a polled SDHCI driver (the C++
//! drivers/src/sd.cpp, built for rpi4b with SD_EMMC_BASE = 0xFE340000).
//!
//! The card is on EMMC2, an SD Host Controller v3 at 0xFE340000 (QEMU
//! raspi4b plugs its card into the Arasan SDHCI at 0xFE300000 instead; the
//! C++ QEMU build switches the base, this port targets the board). Every
//! transfer is PIO through the Buffer Data Port: no DMA, no cache
//! maintenance, no interrupt. Bring-up: reset, status enables, 3.3 V, the
//! identification clock (divisor 0x80), the maximum data timeout, then
//! CMD0, CMD8, ACMD41 (until powered), CMD2, CMD3, CMD9 (the capacity from
//! the CSD), CMD7, ACMD6 (4-bit); then the data clock (divisor 0x04).
//! Multi-block transfers (CMD18/CMD25, at most 512 blocks each) end with
//! CMD12.
//!
//! The same `sd.SdCard` API as the other ports' cards.

const std = @import("std");

pub const sector_size: u32 = 512;

const emmc_base: usize = 0xFE34_0000;

// Registers.
const BLKSIZE = emmc_base + 0x04; // block size and count
const ARG = emmc_base + 0x08;
const TRNMOD = emmc_base + 0x0C; // transfer mode (16-bit)
const CMD = emmc_base + 0x0E; // command (16-bit)
const RSP0 = emmc_base + 0x10;
const BDATA = emmc_base + 0x20; // buffer data port
const PRNSTS = emmc_base + 0x24; // present state
const HOSTCTL = emmc_base + 0x28; // host control (8-bit)
const PWR = emmc_base + 0x29; // power control (8-bit)
const CLK = emmc_base + 0x2C; // clock control (16-bit)
const TMOUT = emmc_base + 0x2E; // timeout control (8-bit)
const SWRST = emmc_base + 0x2F; // software reset (8-bit)
const NORINT = emmc_base + 0x30; // normal interrupt status
const ERRINT = emmc_base + 0x32; // error interrupt status
const NORINTEN = emmc_base + 0x34;
const ERRINTEN = emmc_base + 0x36;
const NORSIG = emmc_base + 0x38;
const ERRSIG = emmc_base + 0x3A;

const PRS_CMD_INHIBIT: u32 = 1 << 0;
const PRS_DATA_INHIBIT: u32 = 1 << 1;
const PRS_CARD_PRESENT: u32 = 1 << 16;
const HC_4BITBUS: u8 = 0x02;
const CLK_INT_EN: u16 = 0x0001;
const CLK_INT_STABLE: u16 = 0x0002;
const CLK_SDCLK_EN: u16 = 0x0004;
const RST_ALL: u8 = 0x01;
const NIS_CMDCMP: u16 = 0x0001;
const NIS_TRSCMP: u16 = 0x0002;
const NIS_WBUFRDY: u16 = 0x0010;
const NIS_RBUFRDY: u16 = 0x0020;
const EIS_CMDTIMEOUT: u16 = 0x0001;
const EIS_CMDERR: u16 = 0x000F;
const EIS_DATATIMEOUT: u16 = 0x0010;
const EIS_DATAERR: u16 = 0x0070;
const CMD_CRC_CHECK: u16 = 0x0008;
const CMD_DATA_PRESENT: u16 = 0x0020;
const TRNS_BLK_CNT_EN: u16 = 0x0002;
const TRNS_READ: u16 = 0x0010;
const TRNS_MULTI: u16 = 0x0020;

const CMD0 = 0;
const CMD2 = 2;
const CMD3 = 3;
const CMD6 = 6;
const CMD7 = 7;
const CMD8 = 8;
const CMD9 = 9;
const CMD12 = 12;
const CMD17 = 17;
const CMD18 = 18;
const CMD24 = 24;
const CMD25 = 25;
const CMD41 = 41;
const CMD55 = 55;

/// The response type, the low bits of the command register.
const Rsp = enum(u16) { none = 0, r2 = 1, short = 2, shortb = 3 };

fn dsb() void {
    asm volatile ("dsb sy" ::: .{ .memory = true });
}

fn io8(a: usize) u8 {
    return @as(*volatile u8, @ptrFromInt(a)).*;
}
fn io16(a: usize) u16 {
    return @as(*volatile u16, @ptrFromInt(a)).*;
}
fn io32(a: usize) u32 {
    return @as(*volatile u32, @ptrFromInt(a)).*;
}
fn wo8(a: usize, v: u8) void {
    @as(*volatile u8, @ptrFromInt(a)).* = v;
    dsb();
}
fn wo16(a: usize, v: u16) void {
    @as(*volatile u16, @ptrFromInt(a)).* = v;
    dsb();
}
fn wo32(a: usize, v: u32) void {
    @as(*volatile u32, @ptrFromInt(a)).* = v;
    dsb();
}

/// Spin until none of `mask` is set in the present state.
fn waitClearState(mask: u32, spins: u32) bool {
    var n = spins;
    while (n > 0) : (n -= 1) {
        if (io32(PRNSTS) & mask == 0) return true;
    }
    return false;
}

fn delayLoops(n: u32) void {
    var c: u32 = n;
    const p: *volatile u32 = &c;
    while (p.* != 0) p.* -= 1;
}

pub const Result = enum {
    ok,
    err_no_card, // no medium
    err_timeout, // command or data timed out
    err_crc, // command or data CRC error
    err_cmd, // command error (illegal, index)
    err_voltage, // ACMD41 rejected the voltage window
    err_unsupported, // not an SD card, unknown CSD structure
    err_range, // LBA + count beyond the end of the card
};

pub const SdCard = struct {
    ready_: bool = false,
    hc: bool = false, // SDHC/SDXC block addressing
    sectors: u32 = 0, // from the CSD
    rca: u32 = 0,
    result: Result = .ok,
    err: []const u8 = "no error",

    fn setResult(self: *SdCard, r: Result, msg: []const u8) void {
        self.result = r;
        self.err = msg;
    }

    fn markOk(self: *SdCard) void {
        self.setResult(.ok, "no error");
    }

    // ---- The controller set-up ---------------------------------------------

    fn ioClearStatus() void {
        wo16(NORINT, 0xFFFF); // write 1 to clear
        wo16(ERRINT, 0xFFFF);
    }

    /// Every polled status asserted, the interrupt lines masked.
    fn ioEnableStatus() void {
        wo16(NORINTEN, 0xFFFF);
        wo16(ERRINTEN, 0xFFFF);
        wo16(NORSIG, 0);
        wo16(ERRSIG, 0);
        ioClearStatus();
    }

    fn ioResetAll() void {
        wo8(SWRST, RST_ALL);
        var i: u32 = 0;
        while (i < 0x10000) : (i += 1) if (io8(SWRST) == 0) break;
        ioClearStatus();
    }

    /// SD bus power on, 3.3 V.
    fn ioPowerOn() void {
        wo8(PWR, 0x0F);
        delayLoops(0x80000);
    }

    fn ioSetClock(divisor: u16) void {
        wo16(CLK, CLK_INT_EN);
        var i: u32 = 0;
        while (i < 0x10000) : (i += 1) if (io16(CLK) & CLK_INT_STABLE != 0) break;
        wo16(CLK, (divisor << 8) | CLK_INT_EN | CLK_SDCLK_EN);
    }

    fn ioWaitCardPresent() bool {
        var i: u32 = 0;
        while (i < 0x100000) : (i += 1) if (io32(PRNSTS) & PRS_CARD_PRESENT != 0) return true;
        return false;
    }

    // ---- The command layer --------------------------------------------------

    fn waitCmdDone(self: *SdCard, spins: u32) bool {
        var n = spins;
        while (n > 0) : (n -= 1) {
            const nis = io16(NORINT);
            const eis = io16(ERRINT);
            if (eis & EIS_CMDERR != 0) {
                self.setResult(if (eis & EIS_CMDTIMEOUT != 0) .err_timeout else .err_cmd, "command error");
                ioClearStatus();
                return false;
            }
            if (nis & NIS_CMDCMP != 0) {
                wo16(NORINT, NIS_CMDCMP);
                return true;
            }
        }
        self.setResult(.err_timeout, "command response timeout");
        ioClearStatus();
        return false;
    }

    fn waitTransferDone(self: *SdCard) bool {
        var n: u32 = 0x800000;
        while (n > 0) : (n -= 1) {
            const nis = io16(NORINT);
            const eis = io16(ERRINT);
            if (eis & (EIS_CMDERR | EIS_DATAERR) != 0) {
                const to = eis & EIS_DATATIMEOUT != 0;
                self.setResult(if (to) .err_timeout else .err_crc, if (to) "data timeout at transfer end" else "data error at transfer end");
                ioClearStatus();
                return false;
            }
            if (nis & NIS_TRSCMP != 0) {
                wo16(NORINT, NIS_TRSCMP);
                return true;
            }
        }
        self.setResult(.err_timeout, "transfer complete timeout");
        ioClearStatus();
        return false;
    }

    fn cmd(index: u8, arg: u32, rsp: Rsp, crc: bool, data: bool) void {
        // The previous transfer releases the bus first.
        if (data) _ = waitClearState(PRS_DATA_INHIBIT, 0x200000);
        _ = waitClearState(PRS_CMD_INHIBIT, 0x200000);
        var flags: u16 = @intFromEnum(rsp);
        if (crc) flags |= CMD_CRC_CHECK;
        if (data) flags |= CMD_DATA_PRESENT;
        wo32(ARG, arg);
        // The index in the high byte, the flags in the low one.
        wo16(CMD, (@as(u16, index) << 8) | flags);
    }

    fn rspWord(n: usize) u32 {
        return io32(RSP0 + 4 * n);
    }

    // ---- The data transfers (PIO); `addr` is in card units ------------------

    fn waitBuffer(self: *SdCard, want: u16, msg_err: []const u8, msg_to: []const u8, clear: bool) bool {
        var spins: u32 = 0x800000;
        while (true) {
            const nis = io16(NORINT);
            const eis = io16(ERRINT);
            if (eis & (EIS_CMDERR | EIS_DATAERR) != 0) {
                self.setResult(if (eis & EIS_DATATIMEOUT != 0) .err_timeout else .err_crc, msg_err);
                ioClearStatus();
                return false;
            }
            if (nis & want != 0) {
                if (clear) wo16(NORINT, want); // before draining this block
                return true;
            }
            if (spins == 0) {
                self.setResult(.err_timeout, msg_to);
                ioClearStatus();
                return false;
            }
            spins -= 1;
        }
    }

    fn moveBlock(read: bool, block: []u8) void {
        var i: usize = 0;
        while (i < sector_size / 4) : (i += 1) {
            const w = block[4 * i ..][0..4];
            if (read) {
                std.mem.writeInt(u32, w, io32(BDATA), .little);
            } else {
                wo32(BDATA, std.mem.readInt(u32, w, .little));
            }
        }
    }

    fn xferSingle(self: *SdCard, read: bool, addr: u32, buf: []u8) bool {
        ioClearStatus();
        wo32(BLKSIZE, (1 << 16) | sector_size); // one block of 512
        wo16(TRNMOD, TRNS_BLK_CNT_EN | (if (read) TRNS_READ else 0));
        cmd(if (read) CMD17 else CMD24, addr, .short, true, true);
        if (!self.waitBuffer(if (read) NIS_RBUFRDY else NIS_WBUFRDY, "data error", "buffer ready timeout", false)) return false;
        moveBlock(read, buf[0..sector_size]);
        return self.waitTransferDone();
    }

    fn xferMulti(self: *SdCard, read: bool, addr: u32, count: u32, buf: []u8) bool {
        ioClearStatus();
        wo32(BLKSIZE, (count << 16) | sector_size);
        wo16(TRNMOD, TRNS_BLK_CNT_EN | TRNS_MULTI | (if (read) TRNS_READ else 0));
        cmd(if (read) CMD18 else CMD25, addr, .short, true, true);
        var blk: u32 = 0;
        while (blk < count) : (blk += 1) {
            if (!self.waitBuffer(if (read) NIS_RBUFRDY else NIS_WBUFRDY, "data error (multi)", "buffer ready timeout (multi)", true)) return false;
            moveBlock(read, buf[blk * sector_size ..][0..sector_size]);
        }
        if (!self.waitTransferDone()) return false;
        return self.sendStop();
    }

    fn sendStop(self: *SdCard) bool {
        ioClearStatus();
        cmd(CMD12, 0, .shortb, true, false);
        if (!self.waitCmdDone(0x800000)) return false;
        // The data lines released before the next command.
        _ = waitClearState(PRS_DATA_INHIBIT, 0x200000);
        return true;
    }

    fn xfer(self: *SdCard, read: bool, lba: u32, count: u32, buf: []u8) bool {
        if (!self.ready_) {
            self.setResult(.err_no_card, "card not initialised");
            return false;
        }
        if (count == 0) return true;
        if (@as(u64, lba) + count > self.sectors) {
            self.setResult(.err_range, "sector range beyond card end");
            return false;
        }
        var done: u32 = 0;
        while (done < count) {
            // The block count register has 16 bits: chunks of <= 512.
            const chunk = @min(count - done, 512);
            // SDHC/SDXC address blocks, SDSC bytes.
            const addr = if (self.hc) lba + done else (lba + done) * 512;
            const part = buf[done * sector_size ..][0 .. chunk * sector_size];
            const ok = if (chunk == 1) self.xferSingle(read, addr, part) else self.xferMulti(read, addr, chunk, part);
            if (!ok) return false;
            done += chunk;
        }
        return true;
    }

    // ---- The card identification -------------------------------------------

    fn readCsd(self: *SdCard) bool {
        ioClearStatus();
        cmd(CMD9, self.rca << 16, .r2, true, false);
        if (!self.waitCmdDone(0x800000)) return false;

        // CSD[127:0] as bytes, big-endian, from the four response words.
        const r3 = rspWord(3);
        const r2 = rspWord(2);
        const r1 = rspWord(1);
        const r0 = rspWord(0);
        const c = [15]u8{
            @truncate(r3 >> 16), @truncate(r3 >> 8),  @truncate(r3),
            @truncate(r2 >> 24), @truncate(r2 >> 16), @truncate(r2 >> 8),
            @truncate(r2),       @truncate(r1 >> 24), @truncate(r1 >> 16),
            @truncate(r1 >> 8),  @truncate(r1),       @truncate(r0 >> 24),
            @truncate(r0 >> 16), @truncate(r0 >> 8),  @truncate(r0),
        };
        switch (c[0] >> 6) {
            1 => {
                // CSD 2.0 (SDHC/SDXC): the 22-bit C_SIZE in bytes 7..9.
                const c_size = (@as(u32, c[7] & 0x3F) << 16) | (@as(u32, c[8]) << 8) | c[9];
                self.sectors = (c_size + 1) << 10; // (C_SIZE + 1) * 512 KiB / 512
                self.hc = true;
            },
            0 => {
                // CSD 1.0 (SDSC).
                const read_bl_len: u6 = @intCast(c[5] & 0x0F);
                const c_size = (@as(u32, c[6] & 0x03) << 10) | (@as(u32, c[7]) << 2) | (c[8] >> 6);
                const c_size_mult: u6 = @intCast((@as(u32, c[9] & 0x03) << 1) | (c[10] >> 7));
                const block_nr = @as(u64, c_size + 1) << (c_size_mult + 2);
                const block_len = @as(u64, 1) << read_bl_len;
                self.sectors = @truncate((block_nr * block_len) >> 9);
                self.hc = false;
            },
            else => {
                self.setResult(.err_unsupported, "unknown CSD structure");
                return false;
            },
        }
        return true;
    }

    fn cardInit(self: *SdCard) bool {
        // CMD0: idle.
        ioClearStatus();
        cmd(CMD0, 0, .none, false, false);
        if (!self.waitCmdDone(0x800000)) return false;
        delayLoops(0x20000);

        // CMD8: an SD v2 card?
        ioClearStatus();
        cmd(CMD8, 0x0000_01AA, .short, true, false);
        var sd_v2 = false;
        if (self.waitCmdDone(0x800000)) {
            const r = rspWord(0);
            sd_v2 = (r & 0xFF) == 0xAA and ((r >> 8) & 0xFF) == 0x01;
        } else {
            ioClearStatus(); // an SD v1 card: no CMD8
        }

        // ACMD41 (CMD55 first): power up, read the OCR.
        var ocr: u32 = 0;
        var powered = false;
        var attempt: u32 = 0;
        while (attempt < 64) : (attempt += 1) {
            ioClearStatus();
            cmd(CMD55, 0, .short, true, false);
            if (!self.waitCmdDone(0x800000)) {
                self.setResult(.err_unsupported, "CMD55 rejected (not SD?)");
                return false;
            }
            ioClearStatus();
            // 2.7-3.6 V, and HCS (block addressing) for a v2 card.
            const arg: u32 = 0x00FF_8000 | (if (sd_v2) @as(u32, 0x4000_0000) else 0);
            cmd(CMD41, arg, .short, false, false);
            if (!self.waitCmdDone(0x800000)) {
                self.setResult(.err_voltage, "ACMD41 not accepted");
                return false;
            }
            ocr = rspWord(0);
            if (ocr & 0x8000_0000 != 0) {
                powered = true;
                break;
            }
            delayLoops(0x40000);
        }
        if (!powered) {
            self.setResult(.err_voltage, "card did not power up (ACMD41)");
            return false;
        }
        self.hc = ocr & 0x4000_0000 != 0;

        // CMD2 (CID), CMD3 (RCA), CMD9 (CSD).
        ioClearStatus();
        cmd(CMD2, 0, .r2, true, false);
        if (!self.waitCmdDone(0x800000)) return false;

        ioClearStatus();
        cmd(CMD3, 0, .short, true, false);
        if (!self.waitCmdDone(0x800000)) return false;
        self.rca = rspWord(0) >> 16;
        if (self.rca == 0) {
            self.setResult(.err_unsupported, "card returned RCA 0");
            return false;
        }

        if (!self.readCsd()) return false;

        // CMD7: select (standby -> transfer).
        ioClearStatus();
        cmd(CMD7, self.rca << 16, .shortb, true, false);
        if (!self.waitCmdDone(0x800000)) return false;

        // ACMD6: the 4-bit bus, on the card and then the host.
        ioClearStatus();
        cmd(CMD55, self.rca << 16, .short, true, false);
        if (!self.waitCmdDone(0x800000)) return false;
        ioClearStatus();
        cmd(CMD6, 0x2, .short, true, false);
        if (!self.waitCmdDone(0x800000)) return false;
        wo8(HOSTCTL, io8(HOSTCTL) | HC_4BITBUS);
        return true;
    }

    // ---- The API --------------------------------------------------------------

    pub fn init(self: *SdCard) bool {
        self.ready_ = false;
        self.sectors = 0;
        self.rca = 0;
        self.hc = false;
        self.markOk();

        ioResetAll();
        ioEnableStatus();
        ioPowerOn();
        ioSetClock(0x80); // a very slow clock for the identification

        // The data timeout: the reset value (0) is the shortest, too short
        // for a real card's write programming; 0xE is 2^27 card clocks.
        wo8(TMOUT, 0x0E);

        if (!ioWaitCardPresent()) {
            self.setResult(.err_no_card, "no SD card present");
            return false;
        }
        ioClearStatus();

        if (!self.cardInit()) return false;

        // The data clock, still below 25 MHz.
        ioSetClock(0x04);

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

    pub fn readSectors(self: *SdCard, lba: u32, count: u32, dst: []u8) bool {
        return self.xfer(true, lba, count, dst[0 .. @as(usize, count) * sector_size]);
    }

    pub fn writeSectors(self: *SdCard, lba: u32, count: u32, src: []const u8) bool {
        // xfer() only reads the buffer of a write.
        return self.xfer(false, lba, count, @constCast(src[0 .. @as(usize, count) * sector_size]));
    }
};
