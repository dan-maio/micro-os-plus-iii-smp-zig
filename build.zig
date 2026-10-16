//! micro-os-plus-iii-cortexm -- the Cortex-M port of µOS++ IIIe, for Zig
//! 0.17 and MicroZig.
//!
//! Boards are build configurations of this one port:
//!
//!     zig build -Dboard=pico2                     build every test of the board
//!     zig build -Dboard=weactf411 -Dtest=rtos-apis
//!     zig build run -Dboard=pico2 -Dtest=smp-test2   program it and run it (OpenOCD)
//!
//! The images land in `zig-out/firmware/<board>/<test>.elf`.
//!
//! Applications outside this repository use `addFirmware()`.

const std = @import("std");
const microzig = @import("microzig");
const uos_build = @import("micro_os_plus_iii");

const MicroBuild = microzig.MicroBuild(.{ .rp2xxx = true, .stm32 = true });

pub const BoardId = enum {
    /// WeAct Black Pill, STM32F411CE, Cortex-M4F, 1 CPU.
    weactf411,
    /// ST NUCLEO-F411RE, Cortex-M4F, 1 CPU.
    nucleof411,
    /// WeAct STM32F412RE, Cortex-M4F, 1 CPU.
    weactf412,
    /// Raspberry Pi Pico, RP2040, 2x Cortex-M0+ (SMP).
    pico,
    /// Raspberry Pi Pico 2, RP2350, 2x Cortex-M33 (SMP).
    pico2,
};

pub const Board = struct {
    id: BoardId,
    source: []const u8,
    ncpu: u8,
};

pub const boards = [_]Board{
    .{ .id = .weactf411, .source = "src/boards/weactf411.zig", .ncpu = 1 },
    .{ .id = .nucleof411, .source = "src/boards/nucleof411.zig", .ncpu = 1 },
    .{ .id = .weactf412, .source = "src/boards/weactf412.zig", .ncpu = 1 },
    .{ .id = .pico, .source = "src/boards/pico.zig", .ncpu = 2 },
    .{ .id = .pico2, .source = "src/boards/pico2.zig", .ncpu = 2 },
};

fn boardTarget(mb: *MicroBuild, id: BoardId) *const microzig.Target {
    return switch (id) {
        .weactf411 => mb.ports.stm32.chips.STM32F411CE,
        .nucleof411 => mb.ports.stm32.chips.STM32F411RE,
        .weactf412 => mb.ports.stm32.chips.STM32F412RE,
        .pico => mb.ports.rp2xxx.boards.raspberrypi.pico,
        .pico2 => mb.ports.rp2xxx.boards.raspberrypi.pico2_arm,
    };
}

/// The test applications, `test/<name>/main.zig`.
const Test = struct {
    name: []const u8,
    /// Only on multi-CPU boards.
    smp_only: bool = false,
    /// Only on this board: the test exists only as `test/<board>/<name>/`.
    only: ?BoardId = null,
    /// C sources linked with the test (its main.zig enables `c_api` and
    /// `c_runtime`), and their flags.
    c_sources: []const []const u8 = &.{},
    c_flags: []const []const u8 = &.{},
    /// Also the Arm CMSIS-RTOS validator sources (-Dcmsis_rv).
    cmsis_rv: bool = false,
};

/// The arm-cmsis-rtos-validator xPack files compiled into
/// cmsis-os-validator, as its CMakeLists.txt lists them.
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

/// Tests ported one to one from a board's C++ test folder
/// (`test/<board>/<test>/main.zig`); they replace the generic one.
const board_tests = [_]struct { board: BoardId, name: []const u8 }{
    .{ .board = .pico, .name = "smp-test0" },
    .{ .board = .pico, .name = "smp-test1" },
    .{ .board = .pico, .name = "smp-test2" },
    .{ .board = .pico, .name = "smp-test3" },
    .{ .board = .pico, .name = "smp-test4" },
    .{ .board = .pico, .name = "smp-test5" },
    .{ .board = .pico, .name = "smp-mat-test" },
    .{ .board = .pico, .name = "sc-test-ko" },
    .{ .board = .pico, .name = "smp-test-ko" },
    .{ .board = .pico, .name = "exc-test" },
    .{ .board = .pico, .name = "smp-test-usb-cdc-acm" },
    .{ .board = .pico2, .name = "smp-test0" },
    .{ .board = .pico2, .name = "smp-test1" },
    .{ .board = .pico2, .name = "smp-test2" },
    .{ .board = .pico2, .name = "smp-test3" },
    .{ .board = .pico2, .name = "smp-test4" },
    .{ .board = .pico2, .name = "smp-test5" },
    .{ .board = .pico2, .name = "smp-mat-test" },
    .{ .board = .pico2, .name = "sc-test-ko" },
    .{ .board = .pico2, .name = "smp-test-ko" },
    .{ .board = .pico2, .name = "exc-test" },
    .{ .board = .weactf411, .name = "spi-pipeline" },
    .{ .board = .pico2, .name = "smp-test-usb-cdc-acm" },
};

fn testRoot(b: *std.Build, board: BoardId, name: []const u8) std.Build.LazyPath {
    for (board_tests) |bt| {
        if (bt.board == board and std.mem.eql(u8, bt.name, name))
            return b.path(b.fmt("test/{s}/{s}/main.zig", .{ @tagName(board), name }));
    }
    return b.path(b.fmt("test/{s}/main.zig", .{name}));
}

const tests = [_]Test{
    .{ .name = "smp-test0" },
    .{ .name = "smp-test1" },
    .{ .name = "smp-test2", .smp_only = true },
    .{ .name = "smp-test3", .smp_only = true },
    .{ .name = "smp-test4", .smp_only = true },
    .{ .name = "smp-test5", .smp_only = true },
    .{ .name = "smp-mat-test" },
    .{ .name = "sc-test-ko" },
    .{ .name = "smp-test-ko", .smp_only = true },
    .{ .name = "exc-test", .smp_only = true },
    .{ .name = "fp-switch" },
    .{ .name = "mutex-stress" },
    .{
        .name = "rtos-apis",
        .c_sources = &.{"test/rtos-apis/test-c-api.c"},
        // From the suite's os-app-config.h, as main.zig's uos_options.
        .c_flags = &.{ "-std=c11", "-DOS_INTEGER_RTOS_DEFAULT_STACK_SIZE_BYTES=2048", "-DOS_INTEGER_SYSTICK_FREQUENCY_HZ=1000" },
    },
    .{
        .name = "cmsis-os-validator",
        .c_sources = &.{"test/cmsis-os-validator/validator-glue.c"},
        // TRACE as the C++ debug build: the validator prints with
        // trace_printf().
        .c_flags = &.{ "-std=gnu11", "-DTRACE", "-DOS_USE_OS_APP_CONFIG_H" },
        .cmsis_rv = true,
    },
    .{ .name = "io-test" },
    .{ .name = "spi-pipeline", .only = .weactf411 },
    .{ .name = "smp-test-usb-cdc-acm", .smp_only = true },
};

pub const FirmwareOptions = struct {
    name: []const u8,
    board: BoardId,
    root_source_file: std.Build.LazyPath,
    optimize: std.lang.Optimize,
    imports: []const std.Build.Module.Import = &.{},
};

/// Build a µOS++ firmware: a MicroZig firmware whose root module imports
/// `uos` (the kernel, wired to this port) and `uos_board`.
pub fn addFirmware(
    b: *std.Build,
    mb: *MicroBuild,
    kernel_dep: *std.Build.Dependency,
    port_root: std.Build.LazyPath,
    board_root: std.Build.LazyPath,
    options: FirmwareOptions,
    ncpu: u8,
) *MicroBuild.Firmware {
    const fw = mb.add_firmware(.{
        .name = options.name,
        .target = boardTarget(mb, options.board),
        .optimize = options.optimize,
        .root_source_file = options.root_source_file,
        .imports = options.imports,
        // Two CPUs share memory: atomics and fences must be real.
        .single_threaded = ncpu == 1,
    });

    const board_mod = b.createModule(.{ .root_source_file = board_root });
    board_mod.addImport("microzig", fw.core_mod);

    const port_mod = b.createModule(.{ .root_source_file = port_root });
    port_mod.addImport("microzig", fw.core_mod);
    port_mod.addImport("uos_board", board_mod);

    const uos_mod = uos_build.createModule(b, kernel_dep, .{
        .target = fw.exe.root_module.resolved_target.?,
        .optimize = options.optimize,
        .port = port_mod,
    });

    fw.exe.root_module.addImport("uos", uos_mod);
    fw.exe.root_module.addImport("uos_board", board_mod);
    return fw;
}

pub fn build(b: *std.Build) void {
    const optimize = b.option(std.lang.Optimize, "optimize", "Optimisation mode (default safe)") orelse .safe;
    const board_id = b.option(BoardId, "board", "The board (default pico2)") orelse .pico2;
    const only_test = b.option([]const u8, "test", "Build (and run) only this test");
    const run_timeout = b.option(u32, "timeout", "Seconds the run step waits for the verdict (default 600)") orelse 600;
    const cmsis_rv: ?[]const u8 = b.option([]const u8, "cmsis_rv", "The arm-cmsis-rtos-validator xPack folder (default: the one in ~/.local/xPacks)") orelse
        if (b.graph.environ_map.get("HOME")) |home| b.fmt("{s}/.local/xPacks/@xpacks/arm-cmsis-rtos-validator/1.0.0-4", .{home}) else null;

    const mz_dep = b.dependency("microzig", .{});
    const mb = MicroBuild.init(b, mz_dep) orelse return;
    const kernel_dep = b.dependency("micro_os_plus_iii", .{});

    const board = for (boards) |bd| {
        if (bd.id == board_id) break bd;
    } else unreachable;

    const run_step = b.step("run", "Program the board and run the test selected with -Dtest (OpenOCD, semihosting)");

    for (tests) |t| {
        if (only_test) |name| if (!std.mem.eql(u8, name, t.name)) continue;
        if (t.smp_only and board.ncpu < 2) continue;
        if (t.only) |only| if (only != board_id) continue;
        if (t.cmsis_rv and cmsis_rv == null) continue;

        const harness = b.createModule(.{ .root_source_file = b.path("test/harness.zig") });

        const fw = addFirmware(b, mb, kernel_dep, b.path("src/port.zig"), b.path(board.source), .{
            .name = t.name,
            .board = board_id,
            .root_source_file = testRoot(b, board_id, t.name),
            .optimize = optimize,
            .imports = &.{.{ .name = "uos_test", .module = harness }},
        }, board.ncpu);

        harness.addImport("microzig", fw.core_mod);
        harness.addImport("uos", fw.exe.root_module.import_table.get("uos").?);
        harness.addImport("uos_board", fw.exe.root_module.import_table.get("uos_board").?);
        fw.exe.root_module.addImport("uos_suites", uos_build.createSuitesModule(b, kernel_dep, fw.exe.root_module.import_table.get("uos").?));

        if (t.c_sources.len > 0) {
            const root = fw.exe.root_module;
            uos_build.addCIncludes(kernel_dep, root, true);
            root.addIncludePath(b.path(b.fmt("test/{s}", .{t.name})));
            root.addCSourceFiles(.{ .files = t.c_sources, .flags = t.c_flags });
            root.addIncludePath(b.path(b.fmt("test/{s}/include", .{t.name})));
            if (t.cmsis_rv) {
                const rv: std.Build.LazyPath = .{ .cwd_relative = cmsis_rv.? };
                root.addIncludePath(rv.path(b, "Include"));
                root.addIncludePath(rv.path(b, "cmsis-plus/include"));
                root.addIncludePath(kernel_dep.path("include/cmsis-plus/legacy"));
                root.addCSourceFiles(.{ .root = rv, .files = &cmsis_rv_sources, .flags = t.c_flags });
            }
        }

        const elf = fw.get_emitted_elf();
        const install = b.addInstallFileWithDir(elf, .{ .custom = b.fmt("firmware/{s}", .{@tagName(board_id)}) }, b.fmt("{s}.elf", .{t.name}));
        b.getInstallStep().dependOn(&install.step);

        if (only_test != null) {
            const run = b.addSystemCommand(&.{ "bash", "test/hw.sh", @tagName(board_id) });
            run.addFileArg(elf);
            run.addArg(b.fmt("{d}", .{run_timeout}));
            run.has_side_effects = true;
            run_step.dependOn(&run.step);
        }
    }
}
