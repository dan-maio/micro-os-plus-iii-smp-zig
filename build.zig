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
};

const tests = [_]Test{
    .{ .name = "smp-test0" },
    .{ .name = "smp-test1" },
    .{ .name = "smp-test2" },
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
            .app_source_file = b.path(b.fmt("test/{s}/main.zig", .{t.name})),
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
