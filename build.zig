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
};

const tests = [_]Test{
    .{ .name = "smp-test0" },
    .{ .name = "smp-test1" },
    .{ .name = "smp-test2" },
    .{ .name = "smp-test3" },
    .{ .name = "smp-test4" },
    .{ .name = "smp-mat-test" },
};

pub fn build(b: *std.Build) void {
    const optimize = b.option(std.lang.Optimize, "optimize", "Optimization mode (default safe)") orelse .safe;
    const board_id = b.option(BoardId, "board", "Target board (default rpi4b)") orelse .rpi4b;
    const only_test = b.option([]const u8, "test", "Build (and run) only this test");
    const qemu_bin = b.option([]const u8, "qemu", "Path to qemu-system-aarch64");

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

        const exe = addFirmware(b, kernel_dep, .{
            .name = t.name,
            .board = board_id,
            .target = target,
            .optimize = optimize,
            .app_source_file = b.path(b.fmt("test/{s}/main.zig", .{t.name})),
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

    const exe = b.addExecutable(.{
        .name = options.name,
        .root_module = root_mod,
    });
    exe.setLinkerScript(b.path(b.fmt("{s}/linker.ld", .{board_dir})));
    exe.entry = .{ .symbol_name = "_start" };

    return exe;
}
