//! The test suites shared by every port (`tests/sources/` in the C++
//! edition). A port's test application calls a suite's `run()` from its
//! main thread and turns the returned failure count into the verdict.

pub const check = @import("suites/check.zig");
pub const rtos_apis = @import("suites/rtos_apis.zig");
pub const io_apis = @import("suites/io_apis.zig");
pub const mutex_stress = @import("suites/mutex_stress.zig");
pub const smp = @import("suites/smp.zig");
