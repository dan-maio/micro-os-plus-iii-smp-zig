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
};

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
        if (t.rtos_apis_parts) {
            const parts = b.createModule(.{ .root_source_file = b.path("test/rtos-apis/parts.zig") });
            parts.addImport("uos", exe.root_module.import_table.get("uos").?);
            exe.root_module.addImport("rtos_apis", parts);
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
