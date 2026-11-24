//! core/config.zig -- the capstone's numbers, in one place: how much work,
//! which files, which priorities, and where each kind of thread runs for the
//! build's CPU count. (C++: app/core/config.hpp.)

const uos = @import("uos");

const rtos = uos.rtos;

pub const ncpu: u32 = uos.config.ncpu;
pub const four = ncpu > 1;

// ---- The churn: rounds of a producer/consumer pipeline.
pub const rounds = 8;
pub const producers = 4; // one per sample source
pub const per_producer = 64;
pub const per_round = producers * per_producer;
pub const first_id: u32 = 1;
pub const seed_base: u32 = 1900; // round r: seed_base + r

// ---- The files on the card (tests/, 8.3 names).
pub const log_leaf = "tutor19.log";
pub const usb_leaf = "usbfile.bin";

// ---- The USB transfer: how long the application waits for the host.
pub const usb_wait_s = 100;

// ---- Priorities: the USB service above the card's owner, which is above the
// main thread, which is above the workers (lesson 17: it starts them).
pub const prio_usb = rtos.priority.high;
pub const prio_logger = rtos.priority.above_normal;
pub const prio_worker = rtos.priority.below_normal;

// ---- Placement (four CPUs): the devices' owners on core 0, where the USB
// interrupt is routed; producer k on core k; the consumer floats. One CPU:
// everything on it. null: any core.
pub const core_usb: ?u32 = 0;
pub const core_logger: ?u32 = 0;
pub const core_consumer: ?u32 = null;
pub fn coreProducer(k: u32) ?u32 {
    return if (four) k % ncpu else null;
}

// ---- The device's identity: what the host tool (usb_test_host) looks for.
pub const usb_vid: u16 = 0x2207;
pub const usb_pid: u16 = 0x0019;
