//! micro-os-plus-iii-posix-arch -- the synthetic POSIX port of µOS++ IIIe,
//! for Zig 0.17: µOS++ runs as a host process (GNU/Linux), with host threads
//! acting as CPUs.
//!
//!     zig build                         build every test
//!     zig build -Dtest=smp-test0        one test
//!     zig build run -Dtest=smp-test0    build it and run it
//!
//! The executables land in `zig-out/bin/<test>`.
//!
//! As the C++ port (its smp branch): the context switch is glibc's ucontext,
//! the tick a per-CPU `timer_create()` signal, the interrupts the signals
//! SIGRTMIN (tick) and SIGRTMIN+1 (IPI). The glibc declarations come from
//! translate-c (`src/host.h`), so the port uses the host's own definitions.

const std = @import("std");
const uos_build = @import("micro_os_plus_iii");

/// The test applications, `test/<name>/main.zig`; each declares its own
/// `uos_options` (the CPU count among them).
const Test = struct {
    name: []const u8,
    /// C sources linked with the test (its main.zig enables `c_api`).
    c_sources: []const []const u8 = &.{},
    c_flags: []const []const u8 = &.{},
    /// Folder of the C sources' headers (default: the test's own).
    c_include: ?[]const u8 = null,
    /// Also import the rtos-apis sub-tests (test/rtos-apis/parts.zig) as
    /// `rtos_apis`.
    rtos_apis_parts: bool = false,
    /// Also import the board's storage drivers (drivers/): `sd` (the host
    /// file card) and `flatfs`.
    devices: bool = false,
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
// OS_INTEGER_SYSTICK_FREQUENCY_HZ: the default of the C++ port headers, and
// the tests' uos_options.
const cmsis_rv_flags = [_][]const u8{ "-std=c11", "-DTRACE", "-DOS_INTEGER_SYSTICK_FREQUENCY_HZ=1000", "-D_GNU_SOURCE", "-D_POSIX_C_SOURCE=200809L", "-D_XOPEN_SOURCE=700" };

const tests = [_]Test{
    .{ .name = "smp-test0" },
    .{ .name = "smp-test1" },
    .{ .name = "smp-test2" },
    .{ .name = "smp-test3" },
    .{ .name = "smp-test4" },
    .{ .name = "mutex-stress" },
    .{ .name = "mutex-ceiling-test" },
    .{ .name = "smp-mutex-stress" },
    .{ .name = "smp-pro-cons-test" },
    .{ .name = "smp-mat-test" },
    .{ .name = "flatfs-test", .devices = true },
    .{ .name = "smp-num-test", .devices = true },
    .{ .name = "smp-pipeline-test", .devices = true },
    .{ .name = "cmsis-os-validator", .cmsis_rv = true },
    .{ .name = "trace-stdout", .c_sources = &.{"test/trace-stdout/trace-c.c"}, .c_flags = &.{ "-std=c11", "-DTRACE" } },
    .{ .name = "trace-stderr", .c_sources = &.{"test/trace-stderr/trace-c.c"}, .c_flags = &.{ "-std=c11", "-DTRACE" } },
    .{
        .name = "smp-rtos-apis",
        .c_sources = &.{"test/rtos-apis/test-c-api.c"},
        .c_flags = &.{ "-std=c11", "-DOS_INTEGER_RTOS_DEFAULT_STACK_SIZE_BYTES=65536", "-DOS_INTEGER_SYSTICK_FREQUENCY_HZ=1000" },
        .c_include = "test/rtos-apis",
        .rtos_apis_parts = true,
    },
    .{
        .name = "rtos-apis",
        .c_sources = &.{"test/rtos-apis/test-c-api.c"},
        // The port's default stack and tick, as main.zig's uos_options.
        .c_flags = &.{ "-std=c11", "-DOS_INTEGER_RTOS_DEFAULT_STACK_SIZE_BYTES=65536", "-DOS_INTEGER_SYSTICK_FREQUENCY_HZ=1000" },
    },
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.option(std.lang.Optimize, "optimize", "Optimisation mode (default safe)") orelse .safe;
    const only_test = b.option([]const u8, "test", "Build (and run) only this test");
    const cmsis_rv: ?[]const u8 = b.option([]const u8, "cmsis_rv", "The arm-cmsis-rtos-validator xPack folder (default: the one in ~/.local/xPacks)") orelse
        if (b.graph.environ_map.get("HOME")) |home| b.fmt("{s}/.local/xPacks/@xpacks/arm-cmsis-rtos-validator/1.0.0-4", .{home}) else null;

    const kernel_dep = b.dependency("micro_os_plus_iii", .{});

    const host_c = b.addTranslateC(.{
        .root_source_file = b.path("src/host.h"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const host_c_mod = host_c.createModule();

    const run_step = b.step("run", "Build and run the test selected with -Dtest");

    for (tests) |t| {
        if (only_test) |name| if (!std.mem.eql(u8, name, t.name)) continue;
        if (t.cmsis_rv and cmsis_rv == null) continue;

        const exe = addApplication(b, kernel_dep, host_c_mod, .{
            .name = t.name,
            .root_source_file = b.path(b.fmt("test/{s}/main.zig", .{t.name})),
            .target = target,
            .optimize = optimize,
        });
        if (t.c_sources.len > 0) {
            const root = exe.root_module;
            uos_build.addCIncludes(kernel_dep, root, false);
            root.addIncludePath(b.path("include"));
            root.addIncludePath(b.path(t.c_include orelse b.fmt("test/{s}", .{t.name})));
            root.addCSourceFiles(.{ .files = t.c_sources, .flags = t.c_flags });
        }
        if (t.cmsis_rv) {
            const root = exe.root_module;
            const rv: std.Build.LazyPath = .{ .cwd_relative = cmsis_rv.? };
            uos_build.addCIncludes(kernel_dep, root, false);
            root.addIncludePath(b.path("include"));
            root.addIncludePath(rv.path(b, "Include"));
            root.addIncludePath(rv.path(b, "cmsis-plus/include"));
            root.addIncludePath(kernel_dep.path("include/cmsis-plus/legacy"));
            root.addCSourceFiles(.{ .root = rv, .files = &cmsis_rv_sources, .flags = &cmsis_rv_flags });
        }
        if (t.rtos_apis_parts) {
            const parts = b.createModule(.{ .root_source_file = b.path("test/rtos-apis/parts.zig") });
            parts.addImport("uos", exe.root_module.import_table.get("uos").?);
            exe.root_module.addImport("rtos_apis", parts);
        }
        if (t.devices) {
            const uos_mod = exe.root_module.import_table.get("uos").?;
            const sd = b.createModule(.{ .root_source_file = b.path("drivers/sd.zig"), .link_libc = true });
            const flatfs = b.createModule(.{ .root_source_file = b.path("drivers/flatfs.zig") });
            flatfs.addImport("sd", sd);
            flatfs.addImport("uos", uos_mod);
            exe.root_module.addImport("sd", sd);
            exe.root_module.addImport("flatfs", flatfs);
        }
        b.installArtifact(exe);

        if (only_test != null) {
            const run = b.addRunArtifact(exe);
            run_step.dependOn(&run.step);
        }
    }
}

pub const ApplicationOptions = struct {
    name: []const u8,
    root_source_file: std.Build.LazyPath,
    target: std.Build.ResolvedTarget,
    optimize: std.lang.Optimize,
};

/// Build a µOS++ host application: an executable linked with the host libc,
/// whose root module imports `uos` (the kernel, wired to this port).
pub fn addApplication(
    b: *std.Build,
    kernel_dep: *std.Build.Dependency,
    host_c_mod: *std.Build.Module,
    options: ApplicationOptions,
) *std.Build.Step.Compile {
    const port_mod = b.createModule(.{
        .root_source_file = b.path("src/port.zig"),
        .target = options.target,
        .optimize = options.optimize,
        .link_libc = true,
    });
    port_mod.addImport("host_c", host_c_mod);

    const uos_mod = uos_build.createModule(b, kernel_dep, .{
        .target = options.target,
        .optimize = options.optimize,
        .port = port_mod,
    });

    const board_mod = b.createModule(.{ .root_source_file = b.path("test/board.zig") });
    board_mod.addImport("uos", uos_mod);

    const exe = b.addExecutable(.{
        .name = options.name,
        .root_module = b.createModule(.{
            .root_source_file = options.root_source_file,
            .target = options.target,
            .optimize = options.optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "uos", .module = uos_mod },
                .{ .name = "uos_suites", .module = uos_build.createSuitesModule(b, kernel_dep, uos_mod) },
                .{ .name = "board", .module = board_mod },
            },
        }),
    });
    return exe;
}
