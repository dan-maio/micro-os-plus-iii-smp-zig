//! A minimal C runtime for freestanding C code linked with the kernel
//! (`Options.c_runtime`): the headers are in include/c/.
//!
//!   stdio.h    printf, vprintf, snprintf, vsnprintf, fprintf, vfprintf,
//!              fflush, puts, putchar; the output goes to the trace channel
//!   string.h   strlen, strcmp, strncmp, strcpy, strncpy, strchr, strrchr
//!              (memcpy, memset, memmove and memcmp come from compiler_rt)
//!   assert.h   assert() -> __assert_func() -> the Zig panic
//!   trace.h    trace_printf, trace_vprintf, trace_puts, trace_putchar,
//!              trace_write, trace_flush (cmsis-plus/diag/trace.h); these
//!              also with `Options.c_api`, on hosted targets too
//!
//! The printf conversions are the usual subset: d i u x X o c s p %, the
//! flags '-' '0' '+' ' ' '#', width and precision (also '*'), and the
//! length modifiers hh h l ll z j t. No floating point.

const std = @import("std");
const config = @import("config.zig");
const trace = @import("trace.zig");

comptime {
    if (config.options.c_runtime) {
        const weak: std.lang.GlobalLinkage = .weak;
        for (.{
            .{ "printf", &printf },
            .{ "vprintf", &vprintf },
            .{ "snprintf", &snprintf },
            .{ "vsnprintf", &vsnprintf },
            .{ "fprintf", &fprintf },
            .{ "vfprintf", &vfprintf },
            .{ "fflush", &fflush },
            .{ "puts", &puts },
            .{ "putchar", &putchar },
            .{ "strlen", &strlen },
            .{ "strcmp", &strcmp },
            .{ "strncmp", &strncmp },
            .{ "strcpy", &strcpy },
            .{ "strncpy", &strncpy },
            .{ "strchr", &strchr },
            .{ "strrchr", &strrchr },
            .{ "__assert_func", &assertFunc },
        }) |e| @export(e[1], .{ .name = e[0], .linkage = weak });
    }
    // The trace C API (cmsis-plus/diag/trace.h) is part of the µOS++ C API:
    // also on hosted targets, which have their own libc.
    if (config.options.c_runtime or config.options.c_api) {
        const weak: std.lang.GlobalLinkage = .weak;
        for (.{
            .{ "trace_printf", &printf },
            .{ "trace_vprintf", &vprintf },
            .{ "trace_puts", &puts },
            .{ "trace_putchar", &putchar },
            .{ "trace_write", &traceWrite },
            .{ "trace_flush", &traceFlush },
        }) |e| @export(e[1], .{ .name = e[0], .linkage = weak });
    }
}

// ----------------------------------------------------------------------------
// Output sinks.

/// Buffered output to the trace channel.
const TraceSink = struct {
    buf: [80]u8 = undefined,
    len: usize = 0,
    count: usize = 0,

    fn put(s: *TraceSink, c: u8) void {
        if (s.len == s.buf.len) s.flush();
        s.buf[s.len] = c;
        s.len += 1;
        s.count += 1;
    }

    fn flush(s: *TraceSink) void {
        if (s.len > 0) trace.write(s.buf[0..s.len]);
        s.len = 0;
    }
};

/// Output to a C buffer, truncated, always terminated (when size > 0).
const BufferSink = struct {
    buf: [*]u8,
    size: usize,
    count: usize = 0,

    fn put(s: *BufferSink, c: u8) void {
        if (s.count + 1 < s.size) s.buf[s.count] = c;
        s.count += 1;
    }

    fn finish(s: *BufferSink) void {
        if (s.size > 0) s.buf[@min(s.count, s.size - 1)] = 0;
    }
};

// ----------------------------------------------------------------------------
// The formatter.

const Spec = struct {
    left: bool = false,
    zero: bool = false,
    plus: bool = false,
    space: bool = false,
    alt: bool = false,
    width: usize = 0,
    precision: ?usize = null,
};

fn pad(sink: anytype, c: u8, n: usize) void {
    for (0..n) |_| sink.put(c);
}

fn putString(sink: anytype, s: []const u8, spec: Spec) void {
    const str = if (spec.precision) |p| s[0..@min(p, s.len)] else s;
    const fill = spec.width -| str.len;
    if (!spec.left) pad(sink, ' ', fill);
    for (str) |c| sink.put(c);
    if (spec.left) pad(sink, ' ', fill);
}

fn putNumber(sink: anytype, magnitude: u64, negative: bool, base: u8, upper: bool, spec: Spec, prefix: []const u8) void {
    var digits: [24]u8 = undefined;
    var n: usize = 0;
    var v = magnitude;
    const charset = if (upper) "0123456789ABCDEF" else "0123456789abcdef";
    while (v != 0) : (v /= base) {
        digits[n] = charset[@intCast(v % base)];
        n += 1;
    }
    // A precision gives the minimum number of digits; ".0" prints nothing
    // for zero.
    const min_digits = spec.precision orelse 1;
    const zeros = min_digits -| n;

    const sign: []const u8 = if (negative) "-" else if (spec.plus) "+" else if (spec.space) " " else "";
    const body = sign.len + prefix.len + zeros + n;
    const fill = spec.width -| body;
    const zero_fill = spec.zero and !spec.left and spec.precision == null;

    if (!spec.left and !zero_fill) pad(sink, ' ', fill);
    for (sign) |c| sink.put(c);
    for (prefix) |c| sink.put(c);
    if (zero_fill) pad(sink, '0', fill);
    pad(sink, '0', zeros);
    while (n > 0) {
        n -= 1;
        sink.put(digits[n]);
    }
    if (spec.left) pad(sink, ' ', fill);
}

const Length = enum { hh, h, none, l, ll, z, j, t };

fn format(sink: anytype, fmt: [*:0]const u8, ap: *std.builtin.VaList) void {
    var i: usize = 0;
    while (fmt[i] != 0) : (i += 1) {
        const c = fmt[i];
        if (c != '%') {
            sink.put(c);
            continue;
        }
        i += 1;

        var spec: Spec = .{};
        while (true) : (i += 1) {
            switch (fmt[i]) {
                '-' => spec.left = true,
                '0' => spec.zero = true,
                '+' => spec.plus = true,
                ' ' => spec.space = true,
                '#' => spec.alt = true,
                else => break,
            }
        }
        if (fmt[i] == '*') {
            const w = @cVaArg(ap, c_int);
            if (w < 0) {
                spec.left = true;
                spec.width = @intCast(-w);
            } else spec.width = @intCast(w);
            i += 1;
        } else while (fmt[i] >= '0' and fmt[i] <= '9') : (i += 1) {
            spec.width = spec.width * 10 + (fmt[i] - '0');
        }
        if (fmt[i] == '.') {
            i += 1;
            var p: usize = 0;
            if (fmt[i] == '*') {
                const v = @cVaArg(ap, c_int);
                p = if (v < 0) 0 else @intCast(v);
                i += 1;
            } else while (fmt[i] >= '0' and fmt[i] <= '9') : (i += 1) {
                p = p * 10 + (fmt[i] - '0');
            }
            spec.precision = p;
        }

        var length: Length = .none;
        switch (fmt[i]) {
            'h' => {
                length = .h;
                if (fmt[i + 1] == 'h') {
                    length = .hh;
                    i += 1;
                }
                i += 1;
            },
            'l' => {
                length = .l;
                if (fmt[i + 1] == 'l') {
                    length = .ll;
                    i += 1;
                }
                i += 1;
            },
            'z' => {
                length = .z;
                i += 1;
            },
            'j' => {
                length = .j;
                i += 1;
            },
            't' => {
                length = .t;
                i += 1;
            },
            else => {},
        }

        switch (fmt[i]) {
            0 => return,
            '%' => sink.put('%'),
            'c' => {
                const ch: u8 = @truncate(@as(c_uint, @bitCast(@cVaArg(ap, c_int))));
                putString(sink, &.{ch}, .{ .left = spec.left, .width = spec.width });
            },
            's' => {
                const s = @cVaArg(ap, ?[*:0]const u8);
                putString(sink, if (s) |p| std.mem.span(p) else "(null)", spec);
            },
            'd', 'i' => {
                const v: i64 = switch (length) {
                    .hh => @as(i8, @truncate(@cVaArg(ap, c_int))),
                    .h => @as(i16, @truncate(@cVaArg(ap, c_int))),
                    .none => @cVaArg(ap, c_int),
                    .l => @cVaArg(ap, c_long),
                    .ll, .j => @cVaArg(ap, c_longlong),
                    .z, .t => @as(isize, @bitCast(@cVaArg(ap, usize))),
                };
                putNumber(sink, @abs(v), v < 0, 10, false, spec, "");
            },
            'u', 'x', 'X', 'o' => {
                const v: u64 = switch (length) {
                    .hh => @as(u8, @truncate(@cVaArg(ap, c_uint))),
                    .h => @as(u16, @truncate(@cVaArg(ap, c_uint))),
                    .none => @cVaArg(ap, c_uint),
                    .l => @cVaArg(ap, c_ulong),
                    .ll, .j => @cVaArg(ap, c_ulonglong),
                    .z, .t => @cVaArg(ap, usize),
                };
                const base: u8 = switch (fmt[i]) {
                    'x', 'X' => 16,
                    'o' => 8,
                    else => 10,
                };
                const prefix: []const u8 = if (!spec.alt or v == 0) "" else switch (fmt[i]) {
                    'x' => "0x",
                    'X' => "0X",
                    'o' => "0",
                    else => "",
                };
                putNumber(sink, v, false, base, fmt[i] == 'X', spec, prefix);
            },
            'p' => {
                const p = @intFromPtr(@cVaArg(ap, ?*anyopaque));
                putNumber(sink, p, false, 16, false, spec, "0x");
            },
            else => |other| {
                // Unknown conversion: print it as is.
                sink.put('%');
                sink.put(other);
            },
        }
    }
}

// ----------------------------------------------------------------------------
// stdio.h

fn vprintf(fmt: [*:0]const u8, ap: *std.builtin.VaList) callconv(.c) c_int {
    var sink: TraceSink = .{};
    format(&sink, fmt, ap);
    sink.flush();
    return @intCast(sink.count);
}

fn printf(fmt: [*:0]const u8, ...) callconv(.c) c_int {
    var ap = @cVaStart();
    defer @cVaEnd(&ap);
    return vprintf(fmt, &ap);
}

fn vsnprintf(buf: [*]u8, size: usize, fmt: [*:0]const u8, ap: *std.builtin.VaList) callconv(.c) c_int {
    var sink: BufferSink = .{ .buf = buf, .size = size };
    format(&sink, fmt, ap);
    sink.finish();
    return @intCast(sink.count);
}

fn snprintf(buf: [*]u8, size: usize, fmt: [*:0]const u8, ...) callconv(.c) c_int {
    var ap = @cVaStart();
    defer @cVaEnd(&ap);
    return vsnprintf(buf, size, fmt, &ap);
}

/// There are no files: every stream is the trace channel.
fn vfprintf(stream: ?*anyopaque, fmt: [*:0]const u8, ap: *std.builtin.VaList) callconv(.c) c_int {
    _ = stream;
    return vprintf(fmt, ap);
}

fn fprintf(stream: ?*anyopaque, fmt: [*:0]const u8, ...) callconv(.c) c_int {
    var ap = @cVaStart();
    defer @cVaEnd(&ap);
    return vfprintf(stream, fmt, &ap);
}

/// The trace output is not buffered beyond a call.
fn fflush(stream: ?*anyopaque) callconv(.c) c_int {
    _ = stream;
    return 0;
}

fn puts(s: [*:0]const u8) callconv(.c) c_int {
    trace.write(std.mem.span(s));
    trace.write("\n");
    return 1;
}

fn putchar(c: c_int) callconv(.c) c_int {
    const b: u8 = @truncate(@as(c_uint, @bitCast(c)));
    trace.write(&.{b});
    return b;
}

fn traceWrite(buf: [*]const u8, nbyte: usize) callconv(.c) isize {
    trace.write(buf[0..nbyte]);
    return @intCast(nbyte);
}

fn traceFlush() callconv(.c) void {}

// ----------------------------------------------------------------------------
// string.h

fn strlen(s: [*:0]const u8) callconv(.c) usize {
    return std.mem.len(s);
}

fn strcmp(a: [*:0]const u8, b: [*:0]const u8) callconv(.c) c_int {
    var i: usize = 0;
    while (a[i] != 0 and a[i] == b[i]) i += 1;
    return @as(c_int, a[i]) - @as(c_int, b[i]);
}

fn strncmp(a: [*:0]const u8, b: [*:0]const u8, n: usize) callconv(.c) c_int {
    var i: usize = 0;
    while (i < n) : (i += 1) {
        if (a[i] != b[i] or a[i] == 0) return @as(c_int, a[i]) - @as(c_int, b[i]);
    }
    return 0;
}

fn strcpy(dst: [*]u8, src: [*:0]const u8) callconv(.c) [*]u8 {
    var i: usize = 0;
    while (true) : (i += 1) {
        dst[i] = src[i];
        if (src[i] == 0) return dst;
    }
}

fn strncpy(dst: [*]u8, src: [*:0]const u8, n: usize) callconv(.c) [*]u8 {
    var i: usize = 0;
    while (i < n and src[i] != 0) : (i += 1) dst[i] = src[i];
    while (i < n) : (i += 1) dst[i] = 0;
    return dst;
}

fn strchr(s: [*:0]const u8, c: c_int) callconv(.c) ?[*:0]const u8 {
    const ch: u8 = @truncate(@as(c_uint, @bitCast(c)));
    var i: usize = 0;
    while (true) : (i += 1) {
        if (s[i] == ch) return s + i;
        if (s[i] == 0) return null;
    }
}

fn strrchr(s: [*:0]const u8, c: c_int) callconv(.c) ?[*:0]const u8 {
    const ch: u8 = @truncate(@as(c_uint, @bitCast(c)));
    var last: ?[*:0]const u8 = null;
    var i: usize = 0;
    while (true) : (i += 1) {
        if (s[i] == ch) last = s + i;
        if (s[i] == 0) return last;
    }
}

// ----------------------------------------------------------------------------
// assert.h

fn assertFunc(file: [*:0]const u8, line: c_int, func: ?[*:0]const u8, expr: [*:0]const u8) callconv(.c) noreturn {
    std.debug.panic("assertion \"{s}\" failed: file \"{s}\", line {d}, function: {s}", .{
        std.mem.span(expr), std.mem.span(file), line, if (func) |f| std.mem.span(f) else "?",
    });
}
