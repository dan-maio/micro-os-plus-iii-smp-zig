//! ARM semihosting: the debugger (OpenOCD, QEMU) as the target's host (the
//! C++ include/cmsis-plus/arm/semihosting.h and
//! src/semihosting/c-syscalls-semihosting.cpp).
//!
//! Every operation of the ARM semihosting specification: the console
//! (SYS_WRITEC, SYS_WRITE0, SYS_READC), host files (SYS_OPEN, SYS_CLOSE,
//! SYS_READ, SYS_WRITE, SYS_SEEK, SYS_FLEN, SYS_ISTTY, SYS_REMOVE,
//! SYS_RENAME, SYS_TMPNAM), the host (SYS_SYSTEM, SYS_ERRNO, SYS_ISERROR,
//! SYS_GET_CMDLINE, SYS_HEAPINFO), time (SYS_CLOCK, SYS_TIME, SYS_ELAPSED,
//! SYS_TICKFREQ) and the end of the run (SYS_EXIT, the C++ `os_terminate()`).
//!
//! Files are user descriptors into a table of open host handles with their
//! position, as in C++ (`fdent`): 0, 1 and 2 are the host console (":tt"
//! read, write and append), opened on first use.
//!
//! The port supplies the trap, `uos_port.semihosting`:
//!
//! ```zig
//! pub const semihosting = struct {
//!     /// Make the request (BKPT 0xAB, SVC 0x123456, HLT #0xF000...).
//!     pub fn call(op: usize, arg: usize) usize;
//!     /// SYS_EXIT takes a {reason, code} block (AArch64, the ARMv7-A
//!     /// boards under OpenOCD), not the reason in the argument register.
//!     pub const exit_by_block: bool;
//!     /// Optional: false when no debugger would service a request.
//!     pub fn attached() bool;
//! };
//! ```
//!
//! A port without it (the POSIX host) has `available == false`, and every
//! request fails with `error.NotAvailable`.

const std = @import("std");
const port = @import("uos_port");

/// Whether the port can make semihosting requests.
pub const available = @hasDecl(port, "semihosting") and @hasDecl(port.semihosting, "call");

/// The operation numbers (`OperationNumber`).
pub const Op = enum(usize) {
    open = 0x01,
    close = 0x02,
    writec = 0x03,
    write0 = 0x04,
    write = 0x05,
    read = 0x06,
    readc = 0x07,
    iserror = 0x08,
    istty = 0x09,
    seek = 0x0A,
    flen = 0x0C,
    tmpnam = 0x0D,
    remove = 0x0E,
    rename = 0x0F,
    clock = 0x10,
    time = 0x11,
    system = 0x12,
    errno = 0x13,
    get_cmdline = 0x15,
    heapinfo = 0x16,
    enter_svc = 0x17,
    /// SYS_EXIT (ReportException).
    exit = 0x18,
    elapsed = 0x30,
    tickfreq = 0x31,
};

/// The reasons of SYS_EXIT.
pub const Reason = enum(usize) {
    application_exit = (2 << 16) + 38, // ADP_Stopped_ApplicationExit
    run_time_error = (2 << 16) + 35, // ADP_Stopped_RunTimeError
};

pub const Error = error{
    /// No semihosting on this port, or no debugger attached.
    NotAvailable,
    /// Not an open descriptor (EBADF).
    BadDescriptor,
    /// The table of open files is full (EMFILE).
    TooManyOpenFiles,
    /// O_CREAT | O_EXCL on an existing file (EEXIST).
    AlreadyExists,
    /// A seek before the start of the file (EINVAL).
    InvalidArgument,
    /// The host reported an error; its errno is `lastErrno()`.
    HostError,
};

/// Whether a request would be serviced now.
pub fn attached() bool {
    if (!available) return false;
    if (@hasDecl(port.semihosting, "attached")) return port.semihosting.attached();
    return true;
}

/// Make a request; the host's raw return value.
pub fn call(op: Op, arg: usize) usize {
    if (!available) return @bitCast(@as(isize, -1));
    return port.semihosting.call(@intFromEnum(op), arg);
}

fn callSigned(op: Op, arg: usize) isize {
    return @bitCast(call(op, arg));
}

/// The parameter block word: the requests take a block of native words.
const Word = usize;

fn checkAvailable() Error!void {
    if (!attached()) return error.NotAvailable;
}

var last_errno: i32 = 0;

/// SYS_ERRNO: the host's errno of the last failed request (also kept by
/// the failing functions, `lastErrno()`).
pub fn errno() i32 {
    return @truncate(callSigned(.errno, 0));
}

/// The host errno saved by the last request that failed.
pub fn lastErrno() i32 {
    return last_errno;
}

fn hostError() Error {
    last_errno = errno();
    return error.HostError;
}

// ----------------------------------------------------------------------------
// The console.

/// SYS_WRITEC: one character.
pub fn writec(c: u8) void {
    if (!attached()) return;
    var ch = c;
    _ = call(.writec, @intFromPtr(&ch));
}

/// SYS_WRITE0: a NUL-terminated string.
pub fn write0(s: [*:0]const u8) void {
    if (!attached()) return;
    _ = call(.write0, @intFromPtr(s));
}

/// Bytes to the host console, in NUL-terminated chunks (SYS_WRITE0).
pub fn writeConsole(bytes: []const u8) void {
    if (!attached()) return;
    var chunk: [128]u8 = undefined;
    var rest = bytes;
    while (rest.len > 0) {
        const n = @min(rest.len, chunk.len - 1);
        @memcpy(chunk[0..n], rest[0..n]);
        chunk[n] = 0;
        _ = call(.write0, @intFromPtr(&chunk));
        rest = rest[n..];
    }
}

/// SYS_READC: one character from the host console (blocks).
pub fn readc() Error!u8 {
    try checkAvailable();
    return @truncate(call(.readc, 0));
}

// ----------------------------------------------------------------------------
// Host files.

/// How a file is opened: the C++ `__posix_open()` flags, mapped to the
/// semihosting mode as there (bit 0 binary, bit 1 "+", bit 2 "w", bit 3
/// "a").
pub const OpenFlags = struct {
    access: enum { read_only, write_only, read_write } = .read_only,
    create: bool = false,
    truncate: bool = false,
    append: bool = false,
    /// With `create`: fail when the file exists.
    exclusive: bool = false,
    binary: bool = true,

    pub fn mode(f: OpenFlags) usize {
        var m: usize = 0;
        if (f.binary) m |= 1;
        if (f.access == .read_write) m |= 2;
        if (f.create or f.truncate or f.access == .write_only) m |= 4;
        if (f.append) {
            m &= ~@as(usize, 4);
            m |= 8;
        }
        return m;
    }
};

/// Open host files (`OS_INTEGER_SEMIHOSTING_MAX_OPEN_FILES`).
pub const max_open_files = 20;

const FdEntry = struct {
    handle: isize = -1,
    pos: usize = 0,
};

var open_files: [max_open_files]FdEntry = @splat(.{});
var handles_ready = false;

/// Open the host console as descriptors 0, 1 and 2
/// (`initialise_monitor_handles()`).
fn initMonitorHandles() void {
    if (handles_ready) return;
    handles_ready = true;
    for (&open_files) |*e| e.* = .{};
    const tt = ":tt";
    var block: [3]Word = .{ @intFromPtr(tt), 0, tt.len }; // "r"
    const stdin_h = callSigned(.open, @intFromPtr(&block));
    block = .{ @intFromPtr(tt), 4, tt.len }; // "w"
    const stdout_h = callSigned(.open, @intFromPtr(&block));
    block = .{ @intFromPtr(tt), 8, tt.len }; // "a"
    var stderr_h = callSigned(.open, @intFromPtr(&block));
    if (stderr_h == -1) stderr_h = stdout_h;
    open_files[0].handle = stdin_h;
    open_files[1].handle = stdout_h;
    open_files[2].handle = stderr_h;
}

fn findSlot(fd: usize) Error!*FdEntry {
    initMonitorHandles();
    if (fd >= max_open_files or open_files[fd].handle == -1) return error.BadDescriptor;
    return &open_files[fd];
}

/// A host file, by its user descriptor.
pub const File = struct {
    fd: usize,

    pub const stdin: File = .{ .fd = 0 };
    pub const stdout: File = .{ .fd = 1 };
    pub const stderr: File = .{ .fd = 2 };

    /// SYS_CLOSE.
    pub fn close(f: File) Error!void {
        try checkAvailable();
        const e = try findSlot(f.fd);
        // stdout and stderr on one handle: only forget this descriptor.
        if ((f.fd == 1 or f.fd == 2) and open_files[1].handle == open_files[2].handle) {
            e.handle = -1;
            return;
        }
        var block: [1]Word = .{@bitCast(e.handle)};
        if (callSigned(.close, @intFromPtr(&block)) == -1) return hostError();
        e.handle = -1;
    }

    /// SYS_READ: the bytes read (0 at the end of the file).
    pub fn read(f: File, buf: []u8) Error!usize {
        try checkAvailable();
        const e = try findSlot(f.fd);
        var block: [3]Word = .{ @bitCast(e.handle), @intFromPtr(buf.ptr), buf.len };
        // The host returns the number of bytes NOT read.
        const res = callSigned(.read, @intFromPtr(&block));
        if (res == -1) return hostError();
        const n = buf.len - @as(usize, @intCast(res));
        e.pos += n;
        return n;
    }

    /// SYS_WRITE: the bytes written.
    pub fn write(f: File, bytes: []const u8) Error!usize {
        try checkAvailable();
        const e = try findSlot(f.fd);
        var block: [3]Word = .{ @bitCast(e.handle), @intFromPtr(bytes.ptr), bytes.len };
        // The host returns the number of bytes NOT written.
        const res = callSigned(.write, @intFromPtr(&block));
        if (res < 0) return hostError();
        const n = bytes.len - @as(usize, @intCast(res));
        e.pos += n;
        if (n == 0 and bytes.len != 0) return hostError();
        return n;
    }

    /// Write all the bytes.
    pub fn writeAll(f: File, bytes: []const u8) Error!void {
        var rest = bytes;
        while (rest.len > 0) rest = rest[try f.write(rest)..];
    }

    pub const Whence = enum { set, current, end };

    /// SYS_SEEK (absolute; `current` and `end` are converted with the kept
    /// position and SYS_FLEN). The new position.
    pub fn seek(f: File, offset: isize, whence: Whence) Error!usize {
        try checkAvailable();
        const e = try findSlot(f.fd);
        const pos: isize = switch (whence) {
            .set => offset,
            .current => @as(isize, @intCast(e.pos)) + offset,
            .end => blk: {
                var lblock: [1]Word = .{@bitCast(e.handle)};
                const len = callSigned(.flen, @intFromPtr(&lblock));
                if (len == -1) return hostError();
                break :blk len + offset;
            },
        };
        if (pos < 0) return error.InvalidArgument;
        var block: [2]Word = .{ @bitCast(e.handle), @intCast(pos) };
        if (callSigned(.seek, @intFromPtr(&block)) < 0) return hostError();
        e.pos = @intCast(pos);
        return e.pos;
    }

    /// The kept position.
    pub fn position(f: File) Error!usize {
        return (try findSlot(f.fd)).pos;
    }

    /// SYS_FLEN: the length of the file.
    pub fn length(f: File) Error!usize {
        try checkAvailable();
        const e = try findSlot(f.fd);
        var block: [1]Word = .{@bitCast(e.handle)};
        const len = callSigned(.flen, @intFromPtr(&block));
        if (len == -1) return hostError();
        return @intCast(len);
    }

    /// SYS_ISTTY: whether the file is the host console.
    pub fn isTty(f: File) bool {
        if (!attached()) return false;
        const e = findSlot(f.fd) catch return false;
        var block: [1]Word = .{@bitCast(e.handle)};
        if (callSigned(.istty, @intFromPtr(&block)) == 1) return true;
        last_errno = errno();
        return false;
    }
};

/// SYS_OPEN: a host file.
pub fn open(path: []const u8, flags: OpenFlags) Error!File {
    try checkAvailable();
    initMonitorHandles();
    const fd = for (open_files, 0..) |e, i| {
        if (e.handle == -1) break i;
    } else return error.TooManyOpenFiles;
    if (flags.create and flags.exclusive) {
        if (stat(path)) |_| return error.AlreadyExists else |_| {}
    }
    var name: [256]u8 = undefined;
    const z = nulTerminated(&name, path) orelse return error.InvalidArgument;
    var block: [3]Word = .{ @intFromPtr(z.ptr), flags.mode(), z.len };
    const fh = callSigned(.open, @intFromPtr(&block));
    if (fh < 0) return hostError();
    open_files[fd] = .{ .handle = fh, .pos = 0 };
    return .{ .fd = fd };
}

fn nulTerminated(buf: []u8, s: []const u8) ?[:0]const u8 {
    if (s.len >= buf.len) return null;
    @memcpy(buf[0..s.len], s);
    buf[s.len] = 0;
    return buf[0..s.len :0];
}

/// The size of a host file (`__posix_stat()`: open it read-only, SYS_FLEN).
pub fn stat(path: []const u8) Error!usize {
    const f = try open(path, .{});
    defer f.close() catch {};
    return f.length();
}

/// SYS_REMOVE.
pub fn remove(path: []const u8) Error!void {
    try checkAvailable();
    var name: [256]u8 = undefined;
    const z = nulTerminated(&name, path) orelse return error.InvalidArgument;
    var block: [2]Word = .{ @intFromPtr(z.ptr), z.len };
    if (callSigned(.remove, @intFromPtr(&block)) != 0) return hostError();
}

/// SYS_RENAME.
pub fn rename(old: []const u8, new: []const u8) Error!void {
    try checkAvailable();
    var a: [256]u8 = undefined;
    var b: [256]u8 = undefined;
    const za = nulTerminated(&a, old) orelse return error.InvalidArgument;
    const zb = nulTerminated(&b, new) orelse return error.InvalidArgument;
    var block: [4]Word = .{ @intFromPtr(za.ptr), za.len, @intFromPtr(zb.ptr), zb.len };
    if (callSigned(.rename, @intFromPtr(&block)) != 0) return hostError();
}

/// SYS_TMPNAM: a temporary file name for `id` (0..255), into `buf`.
pub fn tmpnam(buf: []u8, id: u8) Error![]const u8 {
    try checkAvailable();
    var block: [3]Word = .{ @intFromPtr(buf.ptr), id, buf.len };
    if (callSigned(.tmpnam, @intFromPtr(&block)) != 0) return hostError();
    return std.mem.sliceTo(buf, 0);
}

// ----------------------------------------------------------------------------
// The host.

/// SYS_SYSTEM: run a command on the host; its exit status.
pub fn system(command: []const u8) Error!i32 {
    try checkAvailable();
    var cmd: [256]u8 = undefined;
    const z = nulTerminated(&cmd, command) orelse return error.InvalidArgument;
    var block: [2]Word = .{ @intFromPtr(z.ptr), z.len };
    const e = callSigned(.system, @intFromPtr(&block));
    if (e == -1) return hostError();
    return @truncate(e);
}

/// SYS_ISERROR: whether a return value is an error code.
pub fn isError(status: isize) bool {
    var block: [1]Word = .{@bitCast(status)};
    return call(.iserror, @intFromPtr(&block)) != 0;
}

/// SYS_GET_CMDLINE: the command line the host passes, into `buf`.
pub fn getCmdline(buf: []u8) Error![]const u8 {
    try checkAvailable();
    var block: [2]Word = .{ @intFromPtr(buf.ptr), buf.len - 1 };
    if (callSigned(.get_cmdline, @intFromPtr(&block)) != 0) return hostError();
    buf[buf.len - 1] = 0;
    return std.mem.sliceTo(buf, 0);
}

/// The command line split into arguments, blank-separated, with '"' and
/// '\'' quoting (`os_startup_initialize_args()`); `argv` receives the
/// pieces of `buf`. Always at least one (empty) argument.
pub fn args(buf: []u8, argv: [][]const u8) [][]const u8 {
    var argc: usize = 0;
    if (getCmdline(buf)) |line| {
        var i: usize = 0;
        while (i < line.len and argc < argv.len) {
            while (i < line.len and (line[i] == ' ' or line[i] == '\t')) i += 1;
            if (i >= line.len) break;
            var delim: u8 = 0;
            if (line[i] == '"' or line[i] == '\'') {
                delim = line[i];
                i += 1;
            }
            const start = i;
            while (i < line.len) : (i += 1) {
                if (delim != 0) {
                    if (line[i] == delim) break;
                } else if (line[i] == ' ' or line[i] == '\t') break;
            }
            argv[argc] = line[start..i];
            argc += 1;
            if (i < line.len) i += 1;
        }
    } else |_| {}
    if (argc == 0 and argv.len > 0) {
        argv[0] = "";
        argc = 1;
    }
    return argv[0..argc];
}

pub const HeapInfo = struct {
    heap_base: usize,
    heap_limit: usize,
    stack_base: usize,
    stack_limit: usize,
};

/// SYS_HEAPINFO: the memory the host suggests (zeros when it has no idea).
pub fn heapInfo() Error!HeapInfo {
    try checkAvailable();
    var info: [4]Word = @splat(0);
    var block: [1]Word = .{@intFromPtr(&info)};
    _ = call(.heapinfo, @intFromPtr(&block));
    return .{ .heap_base = info[0], .heap_limit = info[1], .stack_base = info[2], .stack_limit = info[3] };
}

// ----------------------------------------------------------------------------
// Time.

/// SYS_CLOCK: centiseconds since the start of the run.
pub fn clock() Error!u32 {
    try checkAvailable();
    const c = callSigned(.clock, 0);
    if (c == -1) return hostError();
    return @truncate(@as(usize, @bitCast(c)));
}

/// SYS_TIME: seconds since 1970-01-01 (the host's clock).
pub fn time() Error!u32 {
    try checkAvailable();
    return @truncate(call(.time, 0));
}

/// SYS_ELAPSED: target ticks since the start (`tickFreq()` per second).
pub fn elapsed() Error!u64 {
    try checkAvailable();
    var ticks: [2]u32 = .{ 0, 0 };
    if (@sizeOf(Word) == 8) {
        var t: u64 = 0;
        if (callSigned(.elapsed, @intFromPtr(&t)) == -1) return hostError();
        return t;
    }
    if (callSigned(.elapsed, @intFromPtr(&ticks)) == -1) return hostError();
    return (@as(u64, ticks[1]) << 32) | ticks[0];
}

/// SYS_TICKFREQ: the frequency of `elapsed()`.
pub fn tickFreq() Error!usize {
    try checkAvailable();
    const f = callSigned(.tickfreq, 0);
    if (f == -1) return hostError();
    return @intCast(f);
}

// ----------------------------------------------------------------------------
// The end of the run.

/// SYS_EXIT (`os_terminate()`): ApplicationExit for `code` 0, RunTimeError
/// otherwise; the code too where the port passes a block. Does not return
/// (a host that ignores the request leaves the CPU here). The caller masks
/// the interrupts (the port's `terminate()`).
pub fn exit(code: u8) noreturn {
    const reason: Reason = if (code == 0) .application_exit else .run_time_error;
    if (available) {
        if (port.semihosting.exit_by_block) {
            // The block carries ApplicationExit and the status, as the
            // C++ semihosting.hpp of the ARMv7-A and AArch64 boards.
            var block: [2]Word = .{ @intFromEnum(Reason.application_exit), code };
            _ = call(.exit, @intFromPtr(&block));
        } else {
            _ = call(.exit, @intFromEnum(reason));
        }
    }
    while (true) port.scheduler.waitForInterrupt();
}
