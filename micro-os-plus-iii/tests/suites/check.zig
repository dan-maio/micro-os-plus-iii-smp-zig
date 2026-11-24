//! Minimal check helpers for the on-target suites: a failed check is traced
//! with its location and counted; the run goes on.

const std = @import("std");
const uos = @import("uos");

pub var failures: u32 = 0;
pub var checks: u32 = 0;

pub fn reset() void {
    failures = 0;
    checks = 0;
}

pub fn expect(cond: bool, src: std.builtin.SourceLocation, comptime what: []const u8, args: anytype) void {
    checks += 1;
    if (!cond) {
        failures += 1;
        uos.trace.print("FAILED {s}:{d}: " ++ what ++ "\n", .{ src.file, src.line } ++ args);
    }
}

pub fn ok(cond: bool, src: std.builtin.SourceLocation) void {
    expect(cond, src, "condition", .{});
}

pub fn eq(expected: anytype, actual: @TypeOf(expected), src: std.builtin.SourceLocation) void {
    expect(std.meta.eql(expected, actual), src, "expected {any}, got {any}", .{ expected, actual });
}

/// `actual` must be an error union holding `expected`.
pub fn err(expected: anyerror, actual: anytype, src: std.builtin.SourceLocation) void {
    if (actual) |_| {
        expect(false, src, "expected error.{s}, got success", .{@errorName(expected)});
    } else |e| {
        expect(e == expected, src, "expected error.{s}, got error.{s}", .{ @errorName(expected), @errorName(e) });
    }
}

/// `actual` must succeed.
pub fn success(actual: anytype, src: std.builtin.SourceLocation) void {
    if (actual) |_| {
        expect(true, src, "", .{});
    } else |e| {
        expect(false, src, "unexpected error.{s}", .{@errorName(e)});
    }
}

pub fn section(name: []const u8) void {
    uos.trace.print("\n-- {s}\n", .{name});
}

pub fn summary(name: []const u8) u32 {
    uos.trace.print("\n{s}: {d} checks, {d} failed\n", .{ name, checks, failures });
    return failures;
}
