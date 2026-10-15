//! The rtos-apis sub-tests, as a module (`rtos_apis`) for the tests that
//! run them from elsewhere (smp-rtos-apis). test-c-api.c is linked by the
//! build.

pub const cpp_api = @import("test-cpp-api.zig");
pub const iso_api = @import("test-iso-api.zig");
pub const posix_io_api = @import("test-posix-io-api.zig");
