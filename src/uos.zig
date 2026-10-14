//! µOS++ IIIe for Zig -- the portable kernel.
//!
//! ```zig
//! const uos = @import("uos");
//!
//! pub const uos_options: uos.Options = .{ .ncpu = 2, .smp = true };
//!
//! pub fn main() void {
//!     uos.rtos.run(appMain);
//! }
//! ```
//!
//! Map of the C++ edition:
//!
//! | C++                               | Zig                            |
//! |-----------------------------------|--------------------------------|
//! | `os::rtos`                        | `uos.rtos`                     |
//! | `os::rtos::port` (the port repo)  | the `uos_port` module          |
//! | `os::memory`, `memory_resource`   | `uos.memory`, `std.mem.Allocator` |
//! | `os::trace`                       | `uos.trace` (`std.Io.Writer`)  |
//! | `os::estd` (ISO threads)          | `uos.Io` (`std.Io`)            |
//! | `os::posix` (POSIX I/O)           | `uos.Io` files on `uos.io.devices` |
//! | `os-c-api.h`                      | `uos.c_api` (exported `os_*`)  |
//! | `os-app-config.h` macros          | `uos_options` in the root file |

const std = @import("std");

pub const config = @import("config.zig");
pub const Options = config.Options;
pub const options = config.options;

pub const port = @import("uos_port");
pub const rtos = @import("rtos.zig");
pub const memory = @import("memory.zig");
pub const trace = @import("trace.zig");
pub const Io = @import("io/Io.zig");
pub const io = struct {
    pub const devices = @import("io/devices.zig");
};

comptime {
    @import("port_contract.zig").validate(port);
    // The C API and the C runtime export their symbols only when enabled
    // in the options.
    _ = @import("c_api.zig");
    _ = @import("cmsis_os.zig");
    _ = @import("libc.zig");
}

test {
    std.testing.refAllDecls(@This());
}
