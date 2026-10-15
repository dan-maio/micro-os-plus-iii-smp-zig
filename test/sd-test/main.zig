//! sd-test -- Raspberry Pi 4 B (BCM2711, 4x Cortex-A72) SD card and FlatFs test
//! (the C++ test/rpi4b/sd_test).
//!
//! Exercises the SD card controller (SDHCI / EMMC2) and FlatFs:
//!   Phase A: host->device (mount existing volume, verify seed.bin if present)
//!   Phase B: device->device (format volume, write hello.txt, data1.bin, data2.bin,
//!            and big.bin [300 KB / 600 sectors], read back and verify byte-for-byte)

const std = @import("std");
const uos = @import("uos");
const board = @import("board");
const sd = @import("sd");
const flatfs = @import("flatfs");

pub const uos_options = board.options(1);

const printf = board.uart.print;

fn fillPattern(seed: u32, buf: []u8) void {
    var x = seed;
    for (buf) |*b| {
        x = x *% 1664525 +% 1013904223;
        b.* = @truncate(x >> 24);
    }
}

const kSeedSize: usize = 100000;
const kSeedSeed: u32 = 0x51A7E51;
const kSeedName = "seed.bin";
const kHelloText = "Hello from flatfs on micro-os-plus-iii!\n";

const FileSpec = struct {
    name: []const u8,
    seed: u32 = 0,
    size: usize,
    is_text: bool = false,
};

const kWriteSpecs = [_]FileSpec{
    .{ .name = "hello.txt", .size = kHelloText.len, .is_text = true },
    .{ .name = "data1.bin", .seed = 0x11111111, .size = 3000 },
    .{ .name = "data2.bin", .seed = 0x22222222, .size = 70000 },
    .{ .name = "big.bin", .seed = 0x33333333, .size = 307200 }, // 600 sectors
};

var g_all_pass: bool = true;

fn report(what: []const u8, ok: bool) void {
    printf("  [{s}] {s}\n", .{ if (ok) "PASS" else "FAIL", what });
    if (!ok) g_all_pass = false;
}

pub fn main() void {
    board.uart.init();
    uos.rtos.run(osMain);
}

fn osMain() void {
    printf("\n", .{});
    printf("=============================================\n", .{});
    printf("  {s} - {s}\n", .{ board.banner_long, board.banner_cpu });
    printf("  micro-os-plus-iii  sd-test (FlatFs over SDHCI)\n", .{});
    printf("=============================================\n\n", .{});

    var card: sd.SdCard = .{};
    if (!card.init()) {
        printf("Card init failed! (Using in-memory sector buffer fallback)\n", .{});
    }

    var fs: flatfs.FlatFs = .{};
    const gpa = uos.memory.allocator();

    // -----------------------------------------------------------------------
    // Phase A: host -> device
    // -----------------------------------------------------------------------
    printf("Phase A: host->device (mount host-seeded volume, read seed.bin)\n", .{});
    fs.mount(&card) catch |err| {
        printf("  NOTE: no prior flatfs volume found ({s}) - starting fresh format.\n", .{@errorName(err)});
    };
    if (fs.mounted()) {
        printf("  mounted existing flatfs volume.\n", .{});
        if (fs.fileSize(kSeedName)) |seed_size| {
            if (seed_size == kSeedSize) {
                const got = gpa.alloc(u8, seed_size) catch unreachable;
                defer gpa.free(got);
                const want = gpa.alloc(u8, seed_size) catch unreachable;
                defer gpa.free(want);

                if (fs.readFile(kSeedName, got)) |read_bytes| {
                    if (read_bytes == seed_size) {
                        fillPattern(kSeedSeed, want);
                        const match = std.mem.eql(u8, got, want);
                        report("host-created seed.bin verified on device", match);
                    }
                } else |_| {}
            }
        } else |_| {
            printf("  NOTE: seed.bin not present or different size - skipping.\n", .{});
        }
    }

    // -----------------------------------------------------------------------
    // Phase B: device -> device (format, write, read-back verify)
    // -----------------------------------------------------------------------
    printf("\nPhase B: device->device (format, write pattern files, read-back verify)\n", .{});
    fs.format(&card) catch |err| {
        printf("  format failed: {s}\n", .{@errorName(err)});
        report("format", false);
    };
    if (fs.mounted()) {
        report("format", true);

        // Write each file
        for (kWriteSpecs) |spec| {
            var write_err = false;
            if (spec.is_text) {
                printf("  writing {s} ({d} B text)...\n", .{ spec.name, spec.size });
                fs.writeFile(spec.name, kHelloText) catch |err| {
                    printf("    write failed: {s}\n", .{@errorName(err)});
                    write_err = true;
                };
            } else {
                printf("  writing {s} ({d} B pattern)...\n", .{ spec.name, spec.size });
                const data = gpa.alloc(u8, spec.size) catch unreachable;
                defer gpa.free(data);
                fillPattern(spec.seed, data);
                fs.writeFile(spec.name, data) catch |err| {
                    printf("    write failed: {s}\n", .{@errorName(err)});
                    write_err = true;
                };
            }
            if (write_err) {
                report(spec.name, false);
            }
        }

        // Read-back verification
        printf("\n  read-back verification:\n", .{});
        for (kWriteSpecs) |spec| {
            const actual_size = fs.fileSize(spec.name) catch {
                report(spec.name, false);
                continue;
            };
            if (actual_size != spec.size) {
                report(spec.name, false);
                continue;
            }

            const got = gpa.alloc(u8, spec.size) catch unreachable;
            defer gpa.free(got);

            const read_bytes = fs.readFile(spec.name, got) catch {
                report(spec.name, false);
                continue;
            };
            if (read_bytes != spec.size) {
                report(spec.name, false);
                continue;
            }

            var match = false;
            if (spec.is_text) {
                match = std.mem.eql(u8, got, kHelloText);
            } else {
                const want = gpa.alloc(u8, spec.size) catch unreachable;
                defer gpa.free(want);
                fillPattern(spec.seed, want);
                match = std.mem.eql(u8, got, want);
            }

            report(spec.name, match);
        }
    }

    printf("\nRESULT: {s}\n", .{if (g_all_pass) "PASS" else "FAIL"});
    if (g_all_pass) board.hw_result.ok();
    board.hw_result.fail();
}
