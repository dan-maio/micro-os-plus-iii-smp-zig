//! Host unit tests of the port-independent parts (`zig build test`).
//! The kernel itself is tested on the POSIX synthetic port and on the
//! boards.

test {
    _ = @import("rtos/flags.zig");
    _ = @import("memory/FirstFitTop.zig");
    _ = @import("memory/BlockPool.zig");
    _ = @import("rtos/lists.zig").List;
    _ = @import("c_storage.zig");
}

test "lists" {
    _ = @import("rtos/lists.zig");
}
