//! The C object storage sizes, in pointer words: the
//! `OS_C_*_STORAGE_WORDS` of include/cmsis-plus/rtos/os-c-decls.h.
//! c_api.zig checks that each Zig object fits; a host test checks that the
//! header has the same numbers.

pub const words = struct {
    pub const thread = 56;
    pub const timer = 20;
    pub const mutex = 20;
    pub const condvar = 8;
    pub const semaphore = 10;
    pub const mempool = 24;
    pub const mqueue = 32;
    pub const evflags = 10;
};

/// The header the numbers come from, relative to the repository root.
pub const header = "include/cmsis-plus/rtos/os-c-decls.h";

test "os-c-decls.h has the same storage sizes" {
    const std = @import("std");
    const io = std.testing.io;
    const text = try std.Io.Dir.cwd().readFileAlloc(io, header, std.testing.allocator, .limited(1 << 20));
    defer std.testing.allocator.free(text);

    inline for (@typeInfo(words).@"struct".decl_names) |name| {
        var upper: [name.len]u8 = undefined;
        _ = std.ascii.upperString(&upper, name);
        const macro = "#define OS_C_" ++ upper ++ "_STORAGE_WORDS (";
        const at = std.mem.indexOf(u8, text, macro) orelse {
            std.debug.print("{s}: missing\n", .{macro});
            return error.TestUnexpectedResult;
        };
        const rest = text[at + macro.len ..];
        const value = try std.fmt.parseInt(usize, rest[0..std.mem.indexOfScalar(u8, rest, ')').?], 10);
        try std.testing.expectEqual(@as(usize, @field(words, name)), value);
    }
}
