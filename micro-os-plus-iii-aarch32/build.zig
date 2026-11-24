//! micro-os-plus-iii-aarch32 -- the ARMv7-A (AArch32) port of µOS++ IIIe,
//! for Zig 0.17: SMP on the Luckfox Lyra B (RK3506, 3x Cortex-A7).
//!
//!     zig build                              every test of the board
//!     zig build -Dtest=smp-test0             one test
//!     zig build run -Dtest=smp-test0         build it, load it, run it
//!     bash test/hw.sh luckfox-lyra zig-out/firmware/luckfox-lyra/smp-test0.elf
//!
//! The images land in `zig-out/firmware/<board>/<test>.elf`; they are linked
//! at, and entered at, 0x00200000 in DRAM, and loaded by OpenOCD.
//!
//! No MicroZig: the board's startup.S owns the vectors and `_start`, the
//! linker script the memory map; the port's entry `uos_core0_main()` calls
//! the application's `main()`.

const std = @import("std");
const uos_build = @import("micro_os_plus_iii");

const BoardId = enum { @"luckfox-lyra" };

const Board = struct {
    id: BoardId,
    /// The CPU model of the board.
    cpu: *const std.Target.Cpu.Model,
};

const boards = [_]Board{
    .{ .id = .@"luckfox-lyra", .cpu = &std.Target.arm.cpu.cortex_a7 },
};

/// The test applications, `test/<name>/main.zig`; each declares its own
/// `uos_options` (the CPU count among them).
const Test = struct {
    name: []const u8,
    /// Also import the board's storage drivers (drivers/): `sd` (the SD
    /// card) and `fatfs` (FatFs on its FAT32 partition, the C ff.c).
    devices: bool = false,
    /// The test's folder in test/, when not its name.
    dir: ?[]const u8 = null,
    /// smp-test-int5: the doorbell from a core-0 thread, or from the
    /// Cortex-M0 firmware (test/smp-test-int5/m0/, embedded).
    int5: ?Int5 = null,
};

const Int5 = enum { selftrig, m0 };

const tests = [_]Test{
    .{ .name = "smp-test0" },
    .{ .name = "smp-test1" },
    .{ .name = "smp-test2" },
    .{ .name = "smp-test3" },
    .{ .name = "smp-test4" },
    .{ .name = "smp-mat-test" },
    .{ .name = "smp-pro-cons-test" },
    .{ .name = "smp-num-test", .devices = true },
    .{ .name = "smp-pipeline-test", .devices = true },
    .{ .name = "sd_test", .devices = true },
    .{ .name = "smp-mat-sdcard-test", .devices = true },
    .{ .name = "smp-test-int5", .int5 = .selftrig },
    .{ .name = "smp-test-int5-m0", .dir = "smp-test-int5", .int5 = .m0 },
    .{ .name = "semihosting-test" },
};

pub fn build(b: *std.Build) void {
    const optimize = b.option(std.lang.Optimize, "optimize", "Optimisation mode (default safe)") orelse .safe;
    const board_id = b.option(BoardId, "board", "The board (default luckfox-lyra)") orelse .@"luckfox-lyra";
    const only_test = b.option([]const u8, "test", "Build (and run) only this test");
    const run_timeout = b.option(u32, "timeout", "Seconds the run step waits for the verdict (default 300)") orelse 300;

    const kernel_dep = b.dependency("micro_os_plus_iii", .{});

    const board = for (boards) |bd| {
        if (bd.id == board_id) break bd;
    } else unreachable;

    const target = b.resolveTargetQuery(.{
        .cpu_arch = .arm,
        .os_tag = .freestanding,
        .abi = .eabihf,
        .cpu_model = .{ .explicit = board.cpu },
    });

    const run_step = b.step("run", "Load the test selected with -Dtest on the board and run it (OpenOCD, semihosting)");

    for (tests) |t| {
        if (only_test) |name| if (!std.mem.eql(u8, name, t.name)) continue;

        const exe = addFirmware(b, kernel_dep, .{
            .name = t.name,
            .board = board_id,
            .target = target,
            .optimize = optimize,
            .app_source_file = b.path(b.fmt("test/{s}/main.zig", .{t.dir orelse t.name})),
            .devices = t.devices,
            .int5 = t.int5,
        });

        const install = b.addInstallArtifact(exe, .{
            .dest_dir = .{ .override = .{ .custom = b.fmt("firmware/{s}", .{@tagName(board_id)}) } },
            .dest_sub_path = b.fmt("{s}.elf", .{t.name}),
        });
        b.getInstallStep().dependOn(&install.step);

        if (only_test != null) {
            const run = b.addSystemCommand(&.{ "bash", "test/hw.sh", @tagName(board_id) });
            run.addFileArg(exe.getEmittedBin());
            run.addArg(b.fmt("{d}", .{run_timeout}));
            run.has_side_effects = true;
            run_step.dependOn(&run.step);
        }
    }
}

pub const FirmwareOptions = struct {
    name: []const u8,
    board: BoardId,
    target: std.Build.ResolvedTarget,
    optimize: std.lang.Optimize,
    /// The application: a `main.zig` that declares `uos_options` and
    /// `main()`; it imports `uos`, `uos_suites` and the test board `board`.
    app_source_file: std.Build.LazyPath,
    /// Link the storage drivers (`sd`, `fatfs`) and FatFs (ff.c).
    devices: bool = false,
    /// smp-test-int5's variant (the `int5` options module, the M0 image).
    int5: ?Int5 = null,
};

/// Build a µOS++ image for a board: the kernel, this port, the board
/// module, its startup and linker script, and the application.
pub fn addFirmware(b: *std.Build, kernel_dep: *std.Build.Dependency, options: FirmwareOptions) *std.Build.Step.Compile {
    const board_dir = b.fmt("boards/{s}", .{@tagName(options.board)});

    const board_mod = b.createModule(.{ .root_source_file = b.path(b.fmt("{s}/board.zig", .{board_dir})) });

    const port_mod = b.createModule(.{ .root_source_file = b.path("src/port.zig") });
    port_mod.addImport("uos_board", board_mod);

    const uos_mod = uos_build.createModule(b, kernel_dep, .{
        .target = options.target,
        .optimize = options.optimize,
        .port = port_mod,
    });

    const test_board_mod = b.createModule(.{ .root_source_file = b.path("test/board.zig") });
    test_board_mod.addImport("uos", uos_mod);
    test_board_mod.addImport("uos_board", board_mod);

    const app_mod = b.createModule(.{
        .root_source_file = options.app_source_file,
        .imports = &.{
            .{ .name = "uos", .module = uos_mod },
            .{ .name = "uos_suites", .module = uos_build.createSuitesModule(b, kernel_dep, uos_mod) },
            .{ .name = "board", .module = test_board_mod },
        },
    });

    const root_mod = b.createModule(.{
        .root_source_file = b.path("test/start.zig"),
        .target = options.target,
        .optimize = options.optimize,
        // Three CPUs share memory: atomics and fences must be real.
        .single_threaded = false,
        .imports = &.{
            .{ .name = "uos", .module = uos_mod },
            .{ .name = "app", .module = app_mod },
        },
    });
    root_mod.addAssemblyFile(b.path(b.fmt("{s}/startup.S", .{board_dir})));

    if (options.int5) |variant| {
        const opts = b.addOptions();
        opts.addOption(bool, "selftrig", variant == .selftrig);
        app_mod.addOptions("int5", opts);
        if (variant == .m0) app_mod.addAnonymousImport("m0_fw.bin", .{ .root_source_file = addM0Firmware(b, options.optimize) });
    }

    if (options.devices) {
        // FatFs R0.15a, the C sources unchanged, over the kernel's
        // freestanding C runtime (uos_options.c_runtime).
        const ff_c = b.addTranslateC(.{
            .root_source_file = b.path("drivers/ff_api.h"),
            .target = options.target,
            .optimize = options.optimize,
            .link_libc = false,
        });
        ff_c.addIncludePath(b.path("drivers/fatfs"));
        ff_c.addIncludePath(kernel_dep.path("include/c"));
        root_mod.addIncludePath(b.path("drivers/fatfs"));
        root_mod.addIncludePath(kernel_dep.path("include/c"));
        root_mod.addCSourceFiles(.{ .files = &.{"drivers/fatfs/ff.c"}, .flags = &.{"-std=c11"} });

        const sd = b.createModule(.{ .root_source_file = b.path("drivers/sd.zig") });
        const fatfs = b.createModule(.{ .root_source_file = b.path("drivers/fatfs.zig") });
        fatfs.addImport("sd", sd);
        fatfs.addImport("ff", ff_c.createModule());
        app_mod.addImport("sd", sd);
        app_mod.addImport("fatfs", fatfs);
    }

    const exe = b.addExecutable(.{
        .name = options.name,
        .root_module = root_mod,
    });
    exe.setLinkerScript(b.path(b.fmt("{s}/linker.ld", .{board_dir})));
    exe.entry = .{ .symbol_name = "_start" };
    // The vectors and the startup are reached only through the entry and
    // VBAR; keep the sections the linker script lists.
    exe.link_gc_sections = true;
    return exe;
}

/// The Cortex-M0 firmware of smp-test-int5: a Thumb image linked at the M0's
/// 0x0, as a raw binary for the A7 to copy to System SRAM.
fn addM0Firmware(b: *std.Build, optimize: std.lang.Optimize) std.Build.LazyPath {
    const m0 = b.addExecutable(.{
        .name = "m0_fw",
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/smp-test-int5/m0/main.zig"),
            .target = b.resolveTargetQuery(.{
                .cpu_arch = .thumb,
                .os_tag = .freestanding,
                .abi = .eabi,
                .cpu_model = .{ .explicit = &std.Target.arm.cpu.cortex_m0 },
            }),
            // Small and without safety checks: the M0 has no console to
            // report a panic on.
            .optimize = if (optimize == .debug) .debug else .small,
            .single_threaded = true,
        }),
    });
    m0.setLinkerScript(b.path("test/smp-test-int5/m0/linker.ld"));
    m0.entry = .{ .symbol_name = "g_vectors" };
    const bin = b.addObjCopy(m0.getEmittedBin(), .{ .format = .binary });
    b.getInstallStep().dependOn(&b.addInstallFile(bin.getOutput(), "firmware/luckfox-lyra/m0_fw.bin").step);
    return bin.getOutput();
}
