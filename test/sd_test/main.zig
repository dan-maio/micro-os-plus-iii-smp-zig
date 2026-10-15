//! sd_test -- the SD card and FatFs (the C++ test/luckfox-lyra/sd_test, its
//! HW_BUILD branch).
//!
//! The card is the board's boot card: its EXISTING FAT32 partition is
//! mounted read-write and every file goes to "tests/", nothing is formatted.
//! Phase B ("device -> device") writes a text file and three pattern files
//! (the largest, 300 KiB, forces multi-block CMD18/CMD25 transfers), reads
//! them back and compares; the volume geometry, space and the tests/ listing
//! are printed. PASS when every step and every comparison succeeded. (Phase
//! A, the host-seeded file, exists only in the QEMU build.)
//!
//! Differences from C++: the kernel prints its startup banner; the pattern
//! buffers come from the kernel's allocator (C++: new[]). One CPU runs it,
//! as in C++ (the secondaries are not started).

const std = @import("std");
const uos = @import("uos");
const board = @import("board");
const sd = @import("sd");
const fatfs = @import("fatfs");

pub const uos_options = blk: {
    var o = board.options(3);
    // C++: a 32768-element static main stack.
    o.main_stack_size_bytes = 32768 * @sizeOf(uos.port.StackElement);
    break :blk o;
};

fn writeStr(s: []const u8) void {
    board.uart.puts(s);
}

fn writeFmt(comptime fmt: []const u8, args: anytype) void {
    board.uart.print(fmt, args);
}

/// Deterministic pseudo-random file content (the LCG of flatfs_tool.py).
fn fillPattern(seed: u32, buf: []u8) void {
    var x = seed;
    for (buf) |*b| {
        x = x *% 1664525 +% 1013904223;
        b.* = @truncate(x >> 24);
    }
}

/// Board-neutral: the host tool compares this file byte for byte.
const hello_text = "Hello from flatfs on micro-os-plus-iii!\n";

const FileSpec = struct {
    name: []const u8,
    seed: u32, // the pattern files only
    size: u32,
    is_text: bool,
};

const write_specs = [_]FileSpec{
    .{ .name = "hello.txt", .seed = 0, .size = hello_text.len, .is_text = true },
    .{ .name = "data1.bin", .seed = 0x1111_1111, .size = 3000, .is_text = false },
    .{ .name = "data2.bin", .seed = 0x2222_2222, .size = 70000, .is_text = false },
    .{ .name = "big.bin", .seed = 0x3333_3333, .size = 307200, .is_text = false }, // 600 sectors: CMD18/25
};

var g_all_pass = true;

fn report(what: []const u8, ok: bool) void {
    writeFmt("  [{s}] {s}\n", .{ if (ok) "PASS" else "FAIL", what });
    if (!ok) g_all_pass = false;
}

fn hwPhaseFormatAndWrite() void {
    writeStr("\nPhase B: device->device  (FAT32 /tests on the boot card)\n");

    // The MBR window first: resolved before FatFs, it survives a mount
    // failure.
    const win = fatfs.partitionWindow();
    writeFmt("  FAT window: start LBA {d}, {d} sectors ({d} MiB)\n", .{ win.base_lba, win.blocks, win.blocks >> 11 });

    if (!fatfs.mountVolume()) {
        writeFmt("  FAT32 mount failed: {s}\n", .{fatfs.lastError()});
        report("mount FAT32 boot partition", false);
        return;
    }
    report("mount FAT32 boot partition", true);

    if (fatfs.volumeGeometry()) |g| {
        writeFmt("  volume: {s}, {d} sectors/cluster, {d} clusters\n", .{ g.fat_type, g.sec_per_clus, g.clusters });
    }

    if (!fatfs.ensureTestsDir()) {
        writeFmt("  mkdir tests failed: {s}\n", .{fatfs.lastError()});
        report("mkdir tests", false);
        return;
    }
    report("mkdir tests", true);

    const gpa = uos.memory.allocator();

    // Leftovers of a previous run first, then every file.
    for (write_specs) |spec| _ = fatfs.removeFile(spec.name);
    for (write_specs) |spec| {
        var wok = false;
        if (spec.is_text) {
            writeFmt("  writing tests/{s} ({d} B text)...\n", .{ spec.name, spec.size });
            wok = fatfs.storeFile(spec.name, hello_text);
        } else {
            writeFmt("  writing tests/{s} ({d} B pattern)...\n", .{ spec.name, spec.size });
            const data = gpa.alloc(u8, spec.size) catch {
                report(spec.name, false);
                continue;
            };
            defer gpa.free(data);
            fillPattern(spec.seed, data);
            wok = fatfs.storeFile(spec.name, data);
        }
        if (!wok) {
            writeFmt("    write failed: {s}\n", .{fatfs.lastError()});
            report(spec.name, false);
        }
    }

    // Read each back and compare.
    writeStr("\n  read-back verification:\n");
    for (write_specs) |spec| {
        const size = fatfs.fileSize(spec.name) orelse {
            report(spec.name, false);
            continue;
        };
        var ok = size == spec.size;
        if (ok and spec.size > 0) {
            ok = verify(gpa, spec);
        }
        if (!ok) g_all_pass = false;
        writeFmt("  [{s}] {s} read-back verified ({d} B)\n", .{ if (ok) "PASS" else "FAIL", spec.name, size });
    }

    if (fatfs.volumeSpaceKib()) |sp| {
        writeFmt("  volume: {d} KiB total, {d} KiB free\n", .{ sp.total_kib, sp.free_kib });
    }
    writeStr("\ntests/ contents:\n");
    var listing: [512]u8 = undefined;
    writeStr(fatfs.listTestsDir(&listing).text);
}

fn verify(gpa: std.mem.Allocator, spec: FileSpec) bool {
    const got = gpa.alloc(u8, spec.size) catch return false;
    defer gpa.free(got);
    if (!fatfs.loadFile(spec.name, got)) return false;
    if (spec.is_text) return std.mem.eql(u8, got, hello_text);
    const want = gpa.alloc(u8, spec.size) catch return false;
    defer gpa.free(want);
    fillPattern(spec.seed, want);
    return std.mem.eql(u8, got, want);
}

pub fn main() void {
    board.uart.init();
    uos.rtos.run(osMain);
}

fn osMain() void {
    writeStr("\n" ++
        "+=================================================+\n" ++
        "|  " ++ board.banner_long ++ " - micro-os-plus-iii      |\n" ++
        "|  SD card (FAT32 boot partition, files in /tests)|\n" ++
        "+=================================================+\n");

    writeStr("Initialising SD card via SDHCI @0x3F300000...\n");
    var card: sd.SdCard = .{};
    if (!card.init()) {
        writeFmt("  SD init FAILED: {s}\n", .{card.lastError()});
        report("SD card init", false);
        writeStr("RESULT: FAIL (no SD card)\n");
        board.hw_result.fail();
    }
    writeFmt("  SD card ready: {s}, {d} sectors (~{d} MiB)\n", .{
        if (card.highCapacity()) "SDHC/SDXC (block addressing)" else "SDSC (byte addressing)",
        card.sectorCount(),
        card.capacityBytes() >> 20,
    });

    fatfs.bindCard(&card);
    hwPhaseFormatAndWrite();

    writeFmt("\nRESULT: {s}\n", .{if (g_all_pass) "PASS (SD verified)" else "FAIL (see above)"});
    writeStr("-------------------------------------------------\n");
    if (g_all_pass) board.hw_result.ok() else board.hw_result.fail();
}
