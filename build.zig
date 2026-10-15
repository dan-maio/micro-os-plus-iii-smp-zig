//! micro-os-plus-iii-aarch64 -- the ARMv8-A (AArch64) port of µOS++ IIIe,
//! for Zig 0.17: SMP on the Raspberry Pi 4 B (BCM2711, 4x Cortex-A72).
//!
//! Build commands:
//!     zig build                              build every test for rpi4b
//!     zig build -Dtest=smp-test0             build one test
//!     zig build run -Dtest=smp-test0         build and run under QEMU
//!
//! Generated binaries are installed to `zig-out/firmware/rpi4b/<test>.elf`
//! and `zig-out/firmware/rpi4b/<test>.img`.

const std = @import("std");
const uos_build = @import("micro_os_plus_iii");

const BoardId = enum { rpi4b };

const Board = struct {
    id: BoardId,
    cpu: *const std.Target.Cpu.Model,
};

const boards = [_]Board{
    .{ .id = .rpi4b, .cpu = &std.Target.aarch64.cpu.cortex_a72 },
};

const Test = struct {
    name: []const u8,
    c_sources: []const []const u8 = &.{},
    c_flags: []const []const u8 = &.{},
    c_include: ?[]const u8 = null,
    devices: bool = false,
    cmsis_rv: bool = false,
};

const cmsis_rv_sources = [_][]const u8{
    "cmsis-plus/src/main.c",
    "Source/RV_Framework.c",
    "Source/cmsis_rv.c",
    "Source/RV_Signal.c",
    "Source/RV_Report.c",
    "Source/RV_Thread.c",
    "Source/RV_MailQueue.c",
    "Source/RV_Timer.c",
    "Source/RV_GenWait.c",
    "Source/RV_WaitFunc.c",
    "Source/RV_MemoryPool.c",
    "Source/RV_MsgQueue.c",
    "Source/RV_Mutex.c",
    "Source/RV_Semaphore.c",
};

const cmsis_rv_flags = [_][]const u8{
    "-std=gnu11",
    "-DTRACE",
    "-DOS_INTEGER_SYSTICK_FREQUENCY_HZ=1000",
};

const tests = [_]Test{
    .{ .name = "smp-test0" },
    .{ .name = "smp-test1" },
    .{ .name = "smp-test2" },
    .{ .name = "smp-test3" },
    .{ .name = "smp-test4" },
    .{ .name = "smp-mat-test" },
    .{ .name = "mutex-stress" },
    .{ .name = "smp-pro-cons-test" },
    .{
        .name = "rtos-apis",
        .c_sources = &.{"test/rtos-apis/test-c-api.c"},
        .c_flags = &.{ "-std=c11", "-DOS_INTEGER_RTOS_DEFAULT_STACK_SIZE_BYTES=16384", "-DOS_INTEGER_SYSTICK_FREQUENCY_HZ=1000" },
        .c_include = "test/rtos-apis",
    },
    .{ .name = "smp-pipeline-test", .devices = true },
    .{ .name = "smp-mat-sdcard-test", .devices = true },
    .{
        .name = "cmsis-os-validator",
        .c_sources = &.{"test/cmsis-os-validator/validator-glue.c"},
        .c_flags = &.{ "-std=gnu11", "-DTRACE", "-DOS_USE_OS_APP_CONFIG_H" },
        .cmsis_rv = true,
    },
    .{ .name = "sd-test", .devices = true },
    .{ .name = "smp-num-test", .devices = true },
    .{ .name = "smp-mem-test" },
    .{ .name = "smp-mem-inter-test" },
};

pub fn build(b: *std.Build) void {
    const optimize = b.option(std.lang.Optimize, "optimize", "Optimization mode (default safe)") orelse .safe;
    const board_id = b.option(BoardId, "board", "Target board (default rpi4b)") orelse .rpi4b;
    const only_test = b.option([]const u8, "test", "Build (and run) only this test");
    const qemu_bin = b.option([]const u8, "qemu", "Path to qemu-system-aarch64");
    const cmsis_rv_opt = b.option([]const u8, "cmsis_rv", "The arm-cmsis-rtos-validator xPack folder");

    const cmsis_rv_path: ?[]const u8 = cmsis_rv_opt orelse
        if (b.graph.environ_map.get("HOME")) |home| b.fmt("{s}/.local/xPacks/@xpacks/arm-cmsis-rtos-validator/1.0.0-4", .{home}) else null;

    const kernel_dep = b.dependency("micro_os_plus_iii", .{});

    const board = for (boards) |bd| {
        if (bd.id == board_id) break bd;
    } else unreachable;

    const target = b.resolveTargetQuery(.{
        .cpu_arch = .aarch64,
        .os_tag = .freestanding,
        .abi = .none,
        .cpu_model = .{ .explicit = board.cpu },
    });

    const run_step = b.step("run", "Run the test selected with -Dtest under QEMU raspi4b");

    for (tests) |t| {
        if (only_test) |name| if (!std.mem.eql(u8, name, t.name)) continue;
        if (t.cmsis_rv and cmsis_rv_path == null) continue;

        const exe = addFirmware(b, kernel_dep, .{
            .name = t.name,
            .board = board_id,
            .target = target,
            .optimize = optimize,
            .app_source_file = b.path(b.fmt("test/{s}/main.zig", .{t.name})),
            .test_def = t,
            .cmsis_rv_path = cmsis_rv_path,
        });

        const install_elf = b.addInstallArtifact(exe, .{
            .dest_dir = .{ .override = .{ .custom = b.fmt("firmware/{s}", .{@tagName(board_id)}) } },
            .dest_sub_path = b.fmt("{s}.elf", .{t.name}),
        });
        b.getInstallStep().dependOn(&install_elf.step);

        // Convert ELF to flat raw binary (e.g. kernel8.img)
        const bin = b.addObjCopy(exe.getEmittedBin(), .{ .format = .binary });
        const install_bin = b.addInstallFile(
            bin.getOutput(),
            b.fmt("firmware/{s}/{s}.img", .{ @tagName(board_id), t.name }),
        );
        b.getInstallStep().dependOn(&install_bin.step);

        if (only_test != null) {
            const default_qemu = "/home/dan/.local/xPacks/@xpack-dev-tools/qemu-arm/9.2.4-1.1/.content/bin/qemu-system-aarch64";
            const qemu_path = qemu_bin orelse default_qemu;

            const run = b.addSystemCommand(&.{
                qemu_path,
                "-M",
                "raspi4b",
                "-smp",
                "4",
                "-nographic",
                "-serial",
                "stdio",
                "-semihosting-config",
                "enable=on,target=native",
                "-kernel",
            });
            run.addFileArg(exe.getEmittedBin());
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
    app_source_file: std.Build.LazyPath,
    test_def: Test,
    cmsis_rv_path: ?[]const u8 = null,
};

pub fn addFirmware(
    b: *std.Build,
    kernel_dep: *std.Build.Dependency,
    options: FirmwareOptions,
) *std.Build.Step.Compile {
    const board_dir = b.fmt("boards/{s}", .{@tagName(options.board)});

    const board_mod = b.createModule(.{
        .root_source_file = b.path(b.fmt("{s}/board.zig", .{board_dir})),
    });

    const port_mod = b.createModule(.{
        .root_source_file = b.path("src/port.zig"),
    });
    port_mod.addImport("uos_board", board_mod);

    const uos_mod = uos_build.createModule(b, kernel_dep, .{
        .target = options.target,
        .optimize = options.optimize,
        .port = port_mod,
    });

    const test_board_mod = b.createModule(.{
        .root_source_file = b.path("test/board.zig"),
    });
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

    if (options.test_def.devices) {
        const sd_mod = b.createModule(.{ .root_source_file = b.path("drivers/sd.zig") });
        sd_mod.addImport("uos", uos_mod);

        const flatfs_mod = b.createModule(.{ .root_source_file = b.path("drivers/flatfs.zig") });
        flatfs_mod.addImport("sd", sd_mod);
        flatfs_mod.addImport("uos", uos_mod);

        app_mod.addImport("sd", sd_mod);
        app_mod.addImport("flatfs", flatfs_mod);
    }

    const root_mod = b.createModule(.{
        .root_source_file = b.path("test/start.zig"),
        .target = options.target,
        .optimize = options.optimize,
        .single_threaded = false,
        .imports = &.{
            .{ .name = "uos", .module = uos_mod },
            .{ .name = "app", .module = app_mod },
        },
    });
    root_mod.addAssemblyFile(b.path(b.fmt("{s}/startup.S", .{board_dir})));

    if (options.test_def.c_sources.len > 0 or options.test_def.cmsis_rv) {
        uos_build.addCIncludes(kernel_dep, root_mod, true);
        root_mod.addIncludePath(b.path("include"));
        root_mod.addCSourceFile(.{ .file = b.path("src/c_printf.c"), .flags = &.{"-std=c11"} });
        if (options.test_def.c_include) |inc| root_mod.addIncludePath(b.path(inc));
        if (options.test_def.c_sources.len > 0) {
            root_mod.addCSourceFiles(.{ .files = options.test_def.c_sources, .flags = options.test_def.c_flags });
        }
        if (options.test_def.cmsis_rv and options.cmsis_rv_path != null) {
            const rv: std.Build.LazyPath = .{ .cwd_relative = options.cmsis_rv_path.? };
            root_mod.addIncludePath(rv.path(b, "Include"));
            root_mod.addIncludePath(rv.path(b, "cmsis-plus/include"));
            root_mod.addIncludePath(kernel_dep.path("include/cmsis-plus/legacy"));
            root_mod.addCSourceFiles(.{ .root = rv, .files = &cmsis_rv_sources, .flags = &cmsis_rv_flags });
        }
    }

    const exe = b.addExecutable(.{
        .name = options.name,
        .root_module = root_mod,
    });
    exe.setLinkerScript(b.path(b.fmt("{s}/linker.ld", .{board_dir})));
    exe.entry = .{ .symbol_name = "_start" };

    return exe;
}
