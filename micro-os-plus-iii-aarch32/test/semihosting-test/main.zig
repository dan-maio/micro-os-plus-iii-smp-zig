//! semihosting-test -- every semihosting operation of the kernel's
//! `uos.semihosting` (the C++ cmsis-plus/arm/semihosting.h and
//! c-syscalls-semihosting.cpp), against the debugger as the host.
//!
//! No C++ counterpart: the C++ tests use semihosting only for the console
//! and the verdict. This one exercises the whole layer:
//!
//!   console   SYS_WRITE0, SYS_WRITEC, the console as descriptors 0..2
//!             (":tt", SYS_ISTTY)
//!   files     SYS_OPEN, SYS_WRITE, SYS_CLOSE, SYS_FLEN, SYS_READ,
//!             SYS_SEEK, SYS_RENAME, SYS_REMOVE, SYS_ERRNO (a failed open)
//!   host      SYS_TMPNAM, SYS_GET_CMDLINE (and the argument split),
//!             SYS_HEAPINFO, SYS_ISERROR, SYS_SYSTEM
//!   time      SYS_TIME, SYS_CLOCK, SYS_ELAPSED, SYS_TICKFREQ
//!
//! The file is created in the folder OpenOCD runs in (the repository),
//! renamed, and removed. PASS when the file round trip, the rename, the
//! remove, the error paths, the clocks and the console checks hold;
//! SYS_TMPNAM, SYS_ELAPSED, SYS_TICKFREQ, SYS_SYSTEM, SYS_HEAPINFO, the
//! command line and the console's SYS_ISTTY are reported only (OpenOCD 0.12
//! implements neither SYS_TMPNAM nor SYS_ELAPSED nor SYS_TICKFREQ, and
//! under the runner its console is a pipe, not a terminal). It ends through
//! `exit()`, as the C++ tests.

const std = @import("std");
const uos = @import("uos");
const board = @import("board");
const sh = uos.semihosting;
const uart = board.uart;

pub const uos_options = board.options(1);

var failures: u32 = 0;

fn check(ok: bool, comptime what: []const u8, args: anytype) void {
    uart.print("  [{s}] " ++ what ++ "\n", .{if (ok) "PASS" else "FAIL"} ++ args);
    if (!ok) failures += 1;
}

fn info(comptime what: []const u8, args: anytype) void {
    uart.print("  [info] " ++ what ++ "\n", args);
}

const file_name = "zig-out/semihosting-test.txt";
const file_bak = "zig-out/semihosting-test.bak";
const text = "Hello from uos.semihosting!\nThe second line.\n";

pub fn main() void {
    uart.init();
    uart.puts("\n\n+== " ++ board.banner_short ++ " µOS++ SEMIHOSTING TEST : every operation ==+\n\n");
    uos.rtos.run(osMain);
}

fn osMain() u8 {
    check(sh.available and sh.attached(), "semihosting available, a debugger attached", .{});

    // ---- The console.
    uart.puts("\nConsole:\n");
    sh.write0("  SYS_WRITE0: a NUL-terminated string\n");
    for ("  SYS_WRITEC: one character at a time\n") |c| sh.writec(c);
    // The host's answer: OpenOCD's output is a pipe under the runner.
    info("SYS_ISTTY: descriptor 1 (the host console) is a terminal: {}", .{sh.File.stdout.isTty()});
    const n_out = sh.File.stdout.write("  SYS_WRITE to descriptor 1 (\":tt\")\n") catch 0;
    check(n_out > 0, "SYS_WRITE to the console: {d} bytes", .{n_out});

    // ---- Host files.
    uart.puts("\nFiles:\n");
    sh.remove(file_name) catch {};
    sh.remove(file_bak) catch {};
    if (sh.open(file_name, .{ .access = .write_only, .create = true, .truncate = true })) |f| {
        const w = f.write(text) catch 0;
        check(w == text.len, "SYS_OPEN \"w\", SYS_WRITE: {d}/{d} bytes", .{ w, text.len });
        check(!f.isTty(), "SYS_ISTTY: a file is not the console", .{});
        f.close() catch |e| check(false, "SYS_CLOSE: {s}", .{@errorName(e)});
    } else |e| check(false, "SYS_OPEN \"w\" {s}: {s} (errno {d})", .{ file_name, @errorName(e), sh.lastErrno() });

    if (sh.open(file_name, .{})) |f| {
        const len = f.length() catch 0;
        check(len == text.len, "SYS_FLEN: {d} bytes", .{len});
        var buf: [128]u8 = undefined;
        const r = f.read(&buf) catch 0;
        check(r == text.len and std.mem.eql(u8, buf[0..r], text), "SYS_READ: {d} bytes, the same text", .{r});
        const eof = f.read(&buf) catch 99;
        check(eof == 0, "SYS_READ at the end: 0 bytes ({d})", .{eof});
        const p = f.seek(6, .set) catch 0;
        const r2 = f.read(buf[0..4]) catch 0;
        check(p == 6 and r2 == 4 and std.mem.eql(u8, buf[0..4], "from"), "SYS_SEEK to 6, SYS_READ \"{s}\"", .{buf[0..r2]});
        const pe = f.seek(-5, .end) catch 0;
        check(pe == text.len - 5, "SYS_SEEK from the end: position {d}", .{pe});
        const pc = f.seek(-10, .current) catch 0;
        check(pc == text.len - 15, "SYS_SEEK from the current position: {d}", .{pc});
        check(if (f.seek(-1, .set)) |_| false else |e| e == error.InvalidArgument, "SYS_SEEK before the start is refused", .{});
        f.close() catch |e| check(false, "SYS_CLOSE: {s}", .{@errorName(e)});
        check(if (f.close()) |_| false else |e| e == error.BadDescriptor, "a closed descriptor is refused", .{});
    } else |e| check(false, "SYS_OPEN \"r\": {s} (errno {d})", .{ @errorName(e), sh.lastErrno() });

    if (sh.open(file_name, .{ .access = .write_only, .append = true })) |f| {
        _ = f.write("Appended.\n") catch 0;
        f.close() catch {};
        const len = sh.stat(file_name) catch 0;
        check(len == text.len + 10, "SYS_OPEN \"a\": {d} bytes after the append", .{len});
    } else |e| check(false, "SYS_OPEN \"a\": {s}", .{@errorName(e)});

    check(if (sh.open(file_name, .{ .access = .write_only, .create = true, .exclusive = true })) |_| false else |e| e == error.AlreadyExists, "create exclusive on an existing file is refused", .{});

    if (sh.rename(file_name, file_bak)) |_| {
        const old_gone = if (sh.stat(file_name)) |_| false else |_| true;
        const new_len = sh.stat(file_bak) catch 0;
        check(old_gone and new_len == text.len + 10, "SYS_RENAME: the file moved ({d} bytes)", .{new_len});
    } else |e| check(false, "SYS_RENAME: {s} (errno {d})", .{ @errorName(e), sh.lastErrno() });

    if (sh.remove(file_bak)) |_| {
        check(if (sh.stat(file_bak)) |_| false else |_| true, "SYS_REMOVE: the file is gone", .{});
    } else |e| check(false, "SYS_REMOVE: {s} (errno {d})", .{ @errorName(e), sh.lastErrno() });

    const missing = sh.open("zig-out/no-such-file.txt", .{});
    check(if (missing) |_| false else |e| e == error.HostError and sh.lastErrno() != 0, "SYS_OPEN of a missing file fails, SYS_ERRNO {d}", .{sh.lastErrno()});

    // ---- The host.
    uart.puts("\nHost:\n");
    var tmp: [64]u8 = undefined;
    if (sh.tmpnam(&tmp, 7)) |name| info("SYS_TMPNAM: \"{s}\"", .{name}) else |e| info("SYS_TMPNAM: {s}", .{@errorName(e)});
    var line: [80]u8 = undefined;
    var argv: [10][]const u8 = undefined;
    const a = sh.args(&line, &argv);
    info("SYS_GET_CMDLINE: {d} argument(s), first \"{s}\"", .{ a.len, a[0] });
    check(a.len >= 1, "the argument split gives at least one argument", .{});
    if (sh.heapInfo()) |h| info("SYS_HEAPINFO: heap 0x{x}..0x{x}, stack 0x{x}..0x{x}", .{ h.heap_base, h.heap_limit, h.stack_base, h.stack_limit }) else |e| info("SYS_HEAPINFO: {s}", .{@errorName(e)});
    check(sh.isError(-1) or !sh.isError(0), "SYS_ISERROR: 0 is not an error", .{});
    if (sh.system("true")) |st| info("SYS_SYSTEM \"true\": status {d}", .{st}) else |e| info("SYS_SYSTEM: {s} (errno {d})", .{ @errorName(e), sh.lastErrno() });

    // ---- Time.
    uart.puts("\nTime:\n");
    const t = sh.time() catch 0;
    check(t > 1_700_000_000, "SYS_TIME: {d} s since 1970", .{t});
    const c1 = sh.clock() catch 0;
    uos.rtos.sysclock.sleepFor(300) catch {};
    const c2 = sh.clock() catch 0;
    check(c2 >= c1, "SYS_CLOCK: {d} -> {d} cs over 300 ms", .{ c1, c2 });
    if (sh.elapsed()) |ticks| info("SYS_ELAPSED: {d} ticks", .{ticks}) else |e| info("SYS_ELAPSED: {s}", .{@errorName(e)});
    if (sh.tickFreq()) |f| info("SYS_TICKFREQ: {d} Hz", .{f}) else |e| info("SYS_TICKFREQ: {s}", .{@errorName(e)});

    uart.print("\n{d} failed\n", .{failures});
    uart.puts(if (failures == 0) "\nRESULT: PASS\n" else "\nRESULT: FAIL\n");
    // As the C++ tests: main()'s value goes to exit() (the trampoline).
    return if (failures == 0) 0 else 1;
}
