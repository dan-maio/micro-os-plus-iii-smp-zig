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
};

const tests = [_]Test{
    .{ .name = "smp-test0" },
    .{ .name = "smp-test1" },
    .{ .name = "smp-test2", .smp_only = true },
    .{ .name = "smp-test3", .smp_only = true },
    .{ .name = "smp-test4", .smp_only = true },
    .{ .name = "smp-mat-test" },
    .{ .name = "sc-test-ko" },
    .{ .name = "fp-switch" },
    .{ .name = "mutex-stress" },
    .{ .name = "rtos-apis" },
    .{ .name = "io-test" },
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

        const harness = b.createModule(.{ .root_source_file = b.path("test/harness.zig") });

        const fw = addFirmware(b, mb, kernel_dep, b.path("src/port.zig"), b.path(board.source), .{
            .name = t.name,
            .board = board_id,
            .root_source_file = b.path(b.fmt("test/{s}/main.zig", .{t.name})),
            .optimize = optimize,
            .imports = &.{.{ .name = "uos_test", .module = harness }},
        }, board.ncpu);

        harness.addImport("microzig", fw.core_mod);
        harness.addImport("uos", fw.exe.root_module.import_table.get("uos").?);
        harness.addImport("uos_board", fw.exe.root_module.import_table.get("uos_board").?);
        fw.exe.root_module.addImport("uos_suites", uos_build.createSuitesModule(b, kernel_dep, fw.exe.root_module.import_table.get("uos").?));

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
