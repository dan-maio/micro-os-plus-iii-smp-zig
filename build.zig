//! µOS++ IIIe -- the portable kernel, as a Zig package.
//!
//! This package never builds a firmware on its own, exactly like the C++
//! repository: every application links one architecture port, which supplies
//! the `uos_port` module (see `src/port_contract.zig`). The port and the
//! kernel import each other, so the kernel module is created per firmware by
//! `createModule()`, called from the port's build (or the application's).
//!
//! `zig build test` runs the host unit tests of the parts that do not need a
//! port: the intrusive lists, the event flags and the memory allocators.

const std = @import("std");

pub const ModuleOptions = struct {
    target: std.Build.ResolvedTarget,
    optimize: std.lang.Optimize,
    /// The architecture port module (`uos_port`). It must itself import the
    /// returned module as `uos`; use `linkPort()` once both exist.
    port: ?*std.Build.Module = null,
};

/// Creates a fresh `uos` kernel module rooted in this package. A fresh module
/// per firmware, because the port it imports differs per board.
pub fn createModule(b: *std.Build, dep: *std.Build.Dependency, options: ModuleOptions) *std.Build.Module {
    const mod = b.createModule(.{
        .root_source_file = dep.path("src/uos.zig"),
        .target = options.target,
        .optimize = options.optimize,
    });
    if (options.port) |port| linkPort(mod, port);
    return mod;
}

/// The shared on-target test suites (`tests/suites.zig`), for a port's
/// test applications; `uos` is the firmware's kernel module.
pub fn createSuitesModule(b: *std.Build, dep: *std.Build.Dependency, uos: *std.Build.Module) *std.Build.Module {
    const mod = b.createModule(.{ .root_source_file = dep.path("tests/suites.zig") });
    mod.addImport("uos", uos);
    return mod;
}

/// Wires the kernel and the port together (the two import each other).
/// Let `mod` compile C sources against the kernel: the µOS++ C API headers
/// (include/cmsis-plus/rtos/os-c-api.h, `Options.c_api`) and, for
/// freestanding targets, the minimal C runtime headers (include/c/,
/// `Options.c_runtime`).
pub fn addCIncludes(dep: *std.Build.Dependency, mod: *std.Build.Module, freestanding: bool) void {
    mod.addIncludePath(dep.path("include"));
    if (freestanding) mod.addIncludePath(dep.path("include/c"));
}

pub fn linkPort(uos: *std.Build.Module, port: *std.Build.Module) void {
    uos.addImport("uos_port", port);
    port.addImport("uos", uos);
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Host unit tests: only the port-independent parts are reachable from
    // here, thanks to lazy analysis.
    const test_step = b.step("test", "Run the host unit tests");
    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/host_tests.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_tests = b.addRunArtifact(unit_tests);
    // c_storage.zig reads the C API header at run time.
    run_tests.setCwd(b.path("."));
    run_tests.addFileInput(b.path("include/cmsis-plus/rtos/os-c-decls.h"));
    test_step.dependOn(&run_tests.step);
}
