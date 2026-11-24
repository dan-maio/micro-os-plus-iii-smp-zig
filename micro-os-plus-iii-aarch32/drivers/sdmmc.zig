//! The RK3506 SD host: a Synopsys DesignWare Mobile Storage controller
//! ("dw_mmc") at 0xFF480000 (the C++ soc/rk3506/include/sdmmc.hpp and
//! src/sdmmc.cpp, distilled from U-Boot drivers/mmc/dw_mmc.c and mmc.c).
//!
//! Polled PIO through the DATA FIFO: no IDMAC, no interrupts, no cache
//! maintenance, so it runs from any CPU. Bring-up: CMD0, CMD8, ACMD41
//! (loop), CMD2, CMD3, CMD9 (capacity), CMD7, ACMD6 (4-bit), CMD16, then
//! the card clock goes from 400 kHz to 12 MHz.
//!
//! Not ported: the diagnostic phase scans (`diag_scan*()`), which no test
//! of this port calls.

const base: usize = 0xFF48_0000;
/// cclk_src_sdmmc: the 24 MHz oscillator (hardwareInit()).
const bus_hz: u32 = 24_000_000;
const init_hz: u32 = 400_000;
const xfer_hz: u32 = 12_000_000;
pub const block_size: u32 = 512;

const sample_phase: u32 = 0; // 0 deg: all responses and read data
const sample_phase_r3: u32 = 0;
const drive_phase: u32 = 1; // 90 deg

// Registers.
const CTRL = 0x000;
const PWREN = 0x004;
const CLKDIV = 0x008;
const CLKSRC = 0x00C;
const CLKENA = 0x010;
const TMOUT = 0x014;
const CTYPE = 0x018;
const BLKSIZ = 0x01C;
const BYTCNT = 0x020;
const INTMASK = 0x024;
const CMDARG = 0x028;
const CMD = 0x02C;
const RESP0 = 0x030;
const RESP1 = 0x034;
const RESP2 = 0x038;
const RESP3 = 0x03C;
const RINTSTS = 0x044;
const STATUS = 0x048;
const FIFOTH = 0x04C;
const CDETECT = 0x050;
const TIMING_CON0 = 0x130;
const TIMING_CON1 = 0x134;
const DATA = 0x200;

const CTRL_RESET: u32 = 1 << 0;
const CTRL_FIFO_RESET: u32 = 1 << 1;
const CTRL_DMA_RESET: u32 = 1 << 2;
const CTRL_RESET_ALL = CTRL_RESET | CTRL_FIFO_RESET | CTRL_DMA_RESET;

const CMD_RESP_EXP: u32 = 1 << 6;
const CMD_RESP_LONG: u32 = 1 << 7;
const CMD_CHECK_CRC: u32 = 1 << 8;
const CMD_DATA_EXP: u32 = 1 << 9;
const CMD_RW: u32 = 1 << 10;
const CMD_SEND_STOP: u32 = 1 << 12;
const CMD_PRV_DAT_WAIT: u32 = 1 << 13;
const CMD_INIT: u32 = 1 << 15;
const CMD_UPD_CLK: u32 = 1 << 21;
const CMD_USE_HOLD_REG: u32 = 1 << 29;
const CMD_START: u32 = 1 << 31;

const INT_CDONE: u32 = 1 << 2;
const INT_DTO: u32 = 1 << 3;
const INT_RCRC: u32 = 1 << 6;
const INT_DCRC: u32 = 1 << 7;
const INT_RTO: u32 = 1 << 8;
const INT_DRTO: u32 = 1 << 9;
const INT_ALL: u32 = 0xFFFF_FFFF;

const STAT_BUSY: u32 = 1 << 9;
const STAT_FIFO_EMPTY: u32 = 1 << 2;
const FIFO_COUNT_SHIFT = 17;
const FIFO_COUNT_MASK: u32 = 0x1FFF;

const CTYPE_1BIT: u32 = 0;
const CTYPE_4BIT: u32 = 1 << 0;

// SD commands.
const GO_IDLE_STATE = 0;
const ALL_SEND_CID = 2;
const SEND_RELATIVE_ADDR = 3;
const SELECT_CARD = 7;
const SEND_IF_COND = 8;
const SEND_CSD = 9;
const STOP_TRANSMISSION = 12;
const SEND_STATUS = 13;
const SET_BLOCKLEN = 16;
const READ_SINGLE_BLOCK = 17;
const READ_MULTIPLE_BLOCK = 18;
const WRITE_SINGLE_BLOCK = 24;
const WRITE_MULTI_BLOCK = 25;
const APP_CMD = 55;
const ACMD_SET_BUS_WIDTH = 6;
const ACMD_SEND_OP_COND = 41;

const OCR_BUSY: u32 = 0x8000_0000;
const OCR_HCS: u32 = 0x4000_0000;

const Resp = enum { none, r1, r1b, r2, r3, r6, r7 };

/// How far the bring-up got (`sdcard::Step`), in order.
pub const Step = enum(u8) {
    start,
    ctrl_reset,
    clock_init,
    cmd0,
    cmd8,
    acmd41,
    cmd2,
    cmd3,
    cmd9,
    cmd7,
    acmd6,
    cmd16,
    clock_xfer,
    done,

    /// `step_name()`.
    pub fn name(s: Step) []const u8 {
        return switch (s) {
            .start => "start",
            .ctrl_reset => "ctrl-reset",
            .clock_init => "clock@400kHz",
            .cmd0 => "CMD0 go-idle",
            .cmd8 => "CMD8 if-cond",
            .acmd41 => "ACMD41 op-cond",
            .cmd2 => "CMD2 all-send-cid",
            .cmd3 => "CMD3 send-rca",
            .cmd9 => "CMD9 send-csd",
            .cmd7 => "CMD7 select",
            .acmd6 => "ACMD6 bus-width",
            .cmd16 => "CMD16 blocklen",
            .clock_xfer => "clock@25MHz",
            .done => "done",
        };
    }
};

/// A bounded busy wait: every poll also has this hard bail-out.
const spin: u32 = 300_000;

fn nopDelay(n: u32) void {
    var i: u32 = 0;
    while (i < n) : (i += 1) asm volatile ("nop");
}

/// A Rockchip CRU/GRF write-mask register write.
fn maskedWrite(addr: usize, mask: u16, val: u16) void {
    const p: *volatile u32 = @ptrFromInt(addr);
    p.* = (@as(u32, mask) << 16) | (val & mask);
}

fn rd(off: usize) u32 {
    const p: *volatile u32 = @ptrFromInt(base + off);
    return p.*;
}

fn wr(off: usize, v: u32) void {
    const p: *volatile u32 = @ptrFromInt(base + off);
    p.* = v;
}

/// Clocks, reset and pin mux of the SD host.
pub fn hardwareInit() void {
    const cru: usize = 0xFF9A_0000;
    const clksel49 = cru + 0x03C4;
    const gate17 = cru + 0x0844;
    const softrst17 = cru + 0x0A44;
    const gpio3_ioc: usize = 0xFF4D_8000;

    // Ungate hclk_sdmmc (bit 7) and cclk_src_sdmmc (bit 6).
    maskedWrite(gate17, 0x00C0, 0x0000);
    // cclk_src_sdmmc: the 24 MHz oscillator, divider 1.
    maskedWrite(clksel49, 0x7F80, 0x0000);
    // Pulse hresetn_sdmmc.
    maskedWrite(softrst17, 0x0080, 0x0080);
    nopDelay(1000);
    maskedWrite(softrst17, 0x0080, 0x0000);
    // GPIO3_A0..A5 -> func1 (CLK, CMD, D0..D3).
    maskedWrite(gpio3_ioc + 0x0060, 0xFFFF, 0x1111);
    maskedWrite(gpio3_ioc + 0x0064, 0x00FF, 0x0011);
    // Pull-ups on CMD and D0..D3, none on CLK.
    maskedWrite(gpio3_ioc + 0x0230, 0x0FFF, 0x0554);
}

/// `sdcard::SdMmc`.
pub const SdMmc = struct {
    present: bool = false,
    high_capacity: bool = false,
    /// The relative card address, pre-shifted (<< 16).
    rca: u32 = 0,
    capacity_bytes: u64 = 0,
    step: Step = .start,
    last_resp: u32 = 0,
    last_rints: u32 = 0,
    use_hold_reg: bool = false,
    xfer_stage: i32 = -1,
    xfer_rints: u32 = 0,

    fn ctrlReset(self: *SdMmc, mask: u32) bool {
        _ = self;
        wr(CTRL, mask);
        var i: u32 = 0;
        while (i < spin) : (i += 1) if (rd(CTRL) & mask == 0) return true;
        return false;
    }

    fn updateClock() bool {
        // No CMD_PRV_DAT_WAIT: DAT0 reads busy after the card is selected.
        wr(CMD, CMD_START | CMD_UPD_CLK);
        var i: u32 = 0;
        while (i < spin) : (i += 1) if (rd(CMD) & CMD_START == 0) return true;
        return false;
    }

    /// The card clock, <= `hz` (fcard = bus_hz / (2 * div)).
    fn setClock(self: *SdMmc, hz: u32) bool {
        _ = self;
        wr(CLKENA, 0);
        if (!updateClock()) return false;
        const div: u32 = if (hz == 0) 0 else (bus_hz + 2 * hz - 1) / (2 * hz);
        wr(CLKDIV, div);
        wr(CLKSRC, 0);
        if (!updateClock()) return false;
        wr(CLKENA, 1);
        return updateClock();
    }

    fn setSamplePhase(nineties: u32) void {
        wr(TIMING_CON1, ((nineties & 3) << 1) | (0x7FF << 17));
    }

    fn setDrivePhase(nineties: u32) void {
        wr(TIMING_CON0, ((nineties & 3) << 1) | (0x7FF << 17));
    }

    /// One command; an R2 response comes out in U-Boot's order
    /// (out[0] = RESP3 .. out[3] = RESP0).
    fn command(self: *SdMmc, idx: u32, arg: u32, resp: Resp, extra_flags: u32, out: ?[]u32) bool {
        var i: u32 = 0;
        while (i < spin) : (i += 1) if (rd(STATUS) & STAT_BUSY == 0) break;

        wr(RINTSTS, INT_ALL);

        var flags = idx | CMD_START | extra_flags;
        if (self.use_hold_reg) flags |= CMD_USE_HOLD_REG;
        flags |= switch (resp) {
            .none => 0,
            .r2 => CMD_RESP_EXP | CMD_RESP_LONG | CMD_CHECK_CRC,
            .r3 => CMD_RESP_EXP, // OCR: no CRC
            .r1b => CMD_RESP_EXP | CMD_CHECK_CRC | CMD_PRV_DAT_WAIT,
            else => CMD_RESP_EXP | CMD_CHECK_CRC,
        };

        wr(CMDARG, arg);
        wr(CMD, flags);

        var mask: u32 = 0;
        var done = false;
        i = 0;
        while (i < spin) : (i += 1) {
            mask = rd(RINTSTS);
            if (mask & INT_CDONE != 0) {
                done = true;
                break;
            }
        }
        self.last_rints = mask;
        if (resp != .none) self.last_resp = rd(RESP0);
        if (!done) return false;
        if (mask & INT_RTO != 0) {
            wr(RINTSTS, INT_ALL);
            return false;
        }
        // Only a CRC error is fatal, and only for a CRC-checked response
        // (R3 always raises RE and RCRC).
        const crc_checked = resp != .none and resp != .r3;
        if (crc_checked and mask & INT_RCRC != 0) {
            wr(RINTSTS, INT_ALL);
            return false;
        }
        if (out) |o| if (resp != .none) {
            if (resp == .r2) {
                o[0] = rd(RESP3);
                o[1] = rd(RESP2);
                o[2] = rd(RESP1);
                o[3] = rd(RESP0);
            } else {
                o[0] = rd(RESP0);
            }
        };
        wr(RINTSTS, INT_CDONE);
        return true;
    }

    /// CMD55 + ACMD<idx>. CMD55 only has to reach the card.
    fn appCommand(self: *SdMmc, idx: u32, arg: u32, resp: Resp, out: ?[]u32) bool {
        var r1: [1]u32 = .{0};
        const ok = self.command(APP_CMD, self.rca, .r1, 0, &r1);
        if (!ok and self.last_rints & INT_RTO != 0) return false;
        return self.command(idx, arg, resp, 0, out);
    }

    /// Identify the card; true when it is ready for transfers.
    pub fn init(self: *SdMmc) bool {
        self.present = false;
        self.high_capacity = false;
        self.rca = 0;
        self.capacity_bytes = 0;
        // Commands through the hold register, so the drive phase applies.
        self.use_hold_reg = true;

        hardwareInit();

        self.step = .ctrl_reset;
        if (!self.ctrlReset(CTRL_RESET_ALL)) return false;
        wr(PWREN, 1);
        wr(INTMASK, 0);
        wr(RINTSTS, INT_ALL);
        wr(TMOUT, 0xFFFF_FFFF);
        wr(FIFOTH, (0x6 << 28) | (0x7F << 16) | 0x80);
        wr(CTYPE, CTYPE_1BIT);
        wr(BLKSIZ, block_size);

        self.step = .clock_init;
        if (!self.setClock(init_hz)) return false;
        setSamplePhase(sample_phase);
        setDrivePhase(drive_phase);
        nopDelay(10000);

        self.step = .cmd0;
        if (!self.command(GO_IDLE_STATE, 0, .none, CMD_INIT, null)) return false;
        nopDelay(10000);

        self.step = .cmd8;
        var r: [1]u32 = .{0};
        const sd_v2 = self.command(SEND_IF_COND, 0x1AA, .r7, 0, &r) and (r[0] & 0xFF) == 0xAA;
        self.last_resp = r[0];

        self.step = .acmd41;
        setSamplePhase(sample_phase_r3);
        const ocr_arg: u32 = 0x00FF_8000 | (if (sd_v2) OCR_HCS else 0);
        var ocr: [1]u32 = .{0};
        var ready = false;
        var tries: u32 = 0;
        while (tries < 200) : (tries += 1) {
            if (!self.appCommand(ACMD_SEND_OP_COND, ocr_arg, .r3, &ocr)) return false;
            self.last_resp = ocr[0];
            if (ocr[0] & OCR_BUSY != 0) {
                ready = true;
                break;
            }
            nopDelay(40000);
        }
        setSamplePhase(sample_phase);
        if (!ready) return false;
        self.high_capacity = ocr[0] & OCR_HCS != 0;

        self.step = .cmd2;
        var cid: [4]u32 = undefined;
        if (!self.command(ALL_SEND_CID, 0, .r2, 0, &cid)) return false;

        self.step = .cmd3;
        if (!self.command(SEND_RELATIVE_ADDR, 0, .r6, 0, &r)) return false;
        self.rca = r[0] & 0xFFFF_0000;

        self.step = .cmd9;
        var csd: [4]u32 = undefined;
        if (!self.command(SEND_CSD, self.rca, .r2, 0, &csd)) return false;
        const read_bl_len: u64 = @as(u64, 1) << @intCast((csd[1] >> 16) & 0xF);
        var csize: u64 = undefined;
        var cmult: u6 = undefined;
        if (self.high_capacity) {
            csize = (@as(u64, csd[1] & 0x3F) << 16) | ((csd[2] & 0xFFFF_0000) >> 16);
            cmult = 8;
        } else {
            csize = (@as(u64, csd[1] & 0x3FF) << 2) | ((csd[2] & 0xC000_0000) >> 30);
            cmult = @intCast((csd[2] & 0x0003_8000) >> 15);
        }
        self.capacity_bytes = ((csize + 1) << (cmult + 2)) * read_bl_len;

        self.step = .cmd7;
        if (!self.command(SELECT_CARD, self.rca, .r1b, 0, &r)) return false;

        self.step = .acmd6;
        if (!self.appCommand(ACMD_SET_BUS_WIDTH, 0x2, .r1, &r)) return false;
        wr(CTYPE, CTYPE_4BIT);

        self.step = .cmd16;
        if (!self.command(SET_BLOCKLEN, block_size, .r1, 0, &r)) return false;

        // Best effort: on a timeout the card stays at 400 kHz.
        self.step = .clock_xfer;
        _ = self.setClock(xfer_hz);

        self.step = .done;
        self.present = true;
        return true;
    }

    fn waitDataReady() bool {
        var i: u32 = 0;
        while (i < spin) : (i += 1) if (rd(STATUS) & STAT_BUSY == 0) return true;
        return false;
    }

    fn waitCardReady(self: *SdMmc) bool {
        var status: [1]u32 = .{0};
        var i: u32 = 0;
        while (i < 10000) : (i += 1) {
            if (self.command(SEND_STATUS, self.rca, .r1, 0, &status)) {
                const state = (status[0] >> 9) & 0xF;
                const rdy = status[0] & (1 << 8) != 0;
                if (rdy and state == 4) return true;
            }
            nopDelay(1000);
        }
        return false;
    }

    /// One PIO transfer of `count` blocks. `buf` holds count * 512 bytes; it
    /// need not be word aligned.
    fn xfer(self: *SdMmc, lba: u32, buf: []u8, count: u32, write: bool) bool {
        if (!self.present or count == 0) return false;

        // SDHC/SDXC address by block, SDSC by byte.
        const addr = if (self.high_capacity) lba else lba * block_size;
        const multi = count > 1;

        // Best effort: DAT0 floats "busy" when idle on this board.
        _ = waitDataReady();
        _ = self.ctrlReset(CTRL_FIFO_RESET);
        wr(RINTSTS, INT_ALL);
        wr(BLKSIZ, block_size);
        wr(BYTCNT, block_size * count);

        const idx: u32 = if (write)
            (if (multi) WRITE_MULTI_BLOCK else WRITE_SINGLE_BLOCK)
        else
            (if (multi) READ_MULTIPLE_BLOCK else READ_SINGLE_BLOCK);
        const flags = CMD_DATA_EXP | (if (write) CMD_RW else 0) | (if (multi) CMD_SEND_STOP else 0);

        var r1: [1]u32 = .{0};
        if (!self.command(idx, addr, .r1, flags, &r1)) {
            self.xfer_stage = 0;
            self.xfer_rints = self.last_rints;
            return false;
        }

        const words = (block_size * count) / 4;
        if (write) {
            var w: u32 = 0;
            while (w < words) : (w += 1) {
                // Room in the FIFO (256 words deep; stay under 128).
                var i: u32 = 0;
                while (i < spin) : (i += 1) {
                    if ((rd(STATUS) >> FIFO_COUNT_SHIFT) & FIFO_COUNT_MASK < 128) break;
                }
                wr(DATA, std.mem.readInt(u32, buf[w * 4 ..][0..4], .little));
            }
        } else {
            var guard: u32 = 0;
            var w: u32 = 0;
            while (w < words) {
                const st = rd(STATUS);
                if (st & STAT_FIFO_EMPTY != 0) {
                    const m = rd(RINTSTS);
                    if (m & (INT_DCRC | INT_DRTO) != 0) return false;
                    if (m & INT_DTO != 0) return false; // done but short
                    guard += 1;
                    if (guard > spin) return false;
                    continue;
                }
                guard = 0;
                var avail = (st >> FIFO_COUNT_SHIFT) & FIFO_COUNT_MASK;
                while (avail > 0 and w < words) : (avail -= 1) {
                    std.mem.writeInt(u32, buf[w * 4 ..][0..4], rd(DATA), .little);
                    w += 1;
                }
            }
        }

        // Data transfer over.
        var dto = false;
        var m: u32 = 0;
        var i: u32 = 0;
        while (i < spin) : (i += 1) {
            m = rd(RINTSTS);
            if (m & (INT_DCRC | INT_DRTO) != 0) {
                self.xfer_stage = if (write) 1 else 2;
                self.xfer_rints = m;
                return false;
            }
            if (m & INT_DTO != 0) {
                dto = true;
                break;
            }
        }
        if (!dto) {
            self.xfer_stage = if (write) 3 else 4;
            self.xfer_rints = m;
            return false;
        }
        self.xfer_stage = -1;
        self.xfer_rints = m;
        wr(RINTSTS, INT_ALL);

        // An explicit STOP after a multi-block transfer (auto-stop is on too).
        if (multi) {
            var r: [1]u32 = .{0};
            _ = self.command(STOP_TRANSMISSION, 0, .r1b, 0, &r);
        }
        // Wait for the card to finish programming.
        if (write) _ = self.waitCardReady();
        return true;
    }

    pub fn readBlocks(self: *SdMmc, lba: u32, dst: []u8, count: u32) bool {
        var attempt: u32 = 0;
        while (attempt < 4) : (attempt += 1) {
            if (self.xfer(lba, dst, count, false)) return true;
            _ = self.ctrlReset(CTRL_FIFO_RESET);
            wr(RINTSTS, INT_ALL);
            _ = self.waitCardReady();
        }
        return false;
    }

    /// Retried: the first write after selection tends to fail its CRC on
    /// this board, and a reset and retry succeeds.
    pub fn writeBlocks(self: *SdMmc, lba: u32, src: []const u8, count: u32) bool {
        var attempt: u32 = 0;
        while (attempt < 4) : (attempt += 1) {
            // xfer() only reads the buffer of a write.
            if (self.xfer(lba, @constCast(src), count, true)) return true;
            _ = self.ctrlReset(CTRL_FIFO_RESET);
            wr(RINTSTS, INT_ALL);
            _ = self.waitCardReady();
            nopDelay(20000);
        }
        return false;
    }

    pub fn cdetect() u32 {
        return rd(CDETECT);
    }
};

const std = @import("std");
