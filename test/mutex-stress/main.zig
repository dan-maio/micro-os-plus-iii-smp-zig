//! mutex-stress -- ten threads contending for one mutex.
//! The body is the shared suite in micro-os-plus-iii/tests/suites/.

const uos = @import("uos");
const t = @import("uos_test");
const suites = @import("uos_suites");

pub const microzig_options = t.microzig_options;
pub const panic = t.panic;
pub const std_options = t.std_options;
pub const uos_options = t.options(.{});

comptime {
    t.exportStartup();
}

pub fn main() void {
    t.run(appMain);
}

fn appMain() u8 {
    return @intFromBool(body() != 0);
}

fn body() u32 {
    return suites.mutex_stress.run(30);
}
