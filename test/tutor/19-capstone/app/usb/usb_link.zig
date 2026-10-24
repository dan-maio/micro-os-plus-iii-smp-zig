//! usb/usb_link.zig -- the USB device, for the capstone: the DWC2 core behind
//! the Pi 4's USB-C socket as a vendor-specific bulk gadget
//! (drivers/usb_dwc2.zig), with one owner: the USB service thread on core 0,
//! where its interrupt (GIC INTID 105) is routed. Once the host configures
//! the device, that thread runs the transfer protocol (usb/big_transfer.zig).
//! (C++: app/usb/usb_link.*.)

const uos = @import("uos");
const board = @import("board");
const usb_dwc2 = @import("usb_dwc2");
const mailbox = @import("mailbox");
const config = @import("../core/config.zig");
const threads = @import("../core/threads.zig");
const big = @import("big_transfer.zig");

const rtos = uos.rtos;

// The service thread never returns, so its thread and stack are static:
// nothing of it stays on the heap.
var s_thread: rtos.Thread = .{};
var s_stack: [2048]uos.port.StackElement = undefined; // 16 KiB
var s_up = false;

/// The USB core's interrupt (the lesson's uos_external_irq hands it here).
pub fn onIrq(intid: u32) void {
    if (intid == usb_dwc2.intid) usb_dwc2.isr();
}

fn service(_: ?*anyopaque) ?*anyopaque {
    usb_dwc2.serviceThreadBody(); // never returns
}

/// Power the block, reset it, take device mode, attach to the bus, start the
/// service thread. null when up, else why not (QEMU: no device mode).
pub fn start() ?[]const u8 {
    usb_dwc2.setConfiguredCallback(big.serve, null);
    const ir = usb_dwc2.init(.{ .vid = config.usb_vid, .pid = config.usb_pid });
    if (ir != .ok) return usb_dwc2.initResultStr(ir);
    // At once: the host may enumerate as soon as init() released the soft
    // disconnect, and only this thread answers it.
    if (!threads.spawnStatic(&s_thread, "usb", service, null, config.prio_usb, config.core_usb, &s_stack)) return "cannot start the USB thread";
    s_up = true;
    return null;
}

pub fn up() bool {
    return s_up;
}

pub fn configured() bool {
    return s_up and usb_dwc2.configured();
}

/// The driver's counters and the core's registers, on the console: what the
/// core saw of the bus when the host sees nothing.
pub fn diagnose() void {
    const hw = usb_dwc2.probeHw();
    const d = usb_dwc2.debug();
    const r = usb_dwc2.snapshot();
    board.console("  usb: snpsid {x:0>8} hwcfg2 {x:0>8} hwcfg3 {x:0>8} hwcfg4 {x:0>8}\n", .{ hw.snpsid, hw.hwcfg2, hw.hwcfg3, hw.hwcfg4 });
    board.console("  usb: isr {d} (off core {d}), bus resets {d}, enum done {d}, configured {d}\n", .{ d.isr_calls, d.isr_offcore, d.usbrst, d.enumdone, @intFromBool(configured()) });
    board.console("  usb: dcfg {x:0>8} dctl {x:0>8} dsts {x:0>8} gintsts {x:0>8} gintmsk {x:0>8} gahbcfg {x:0>8}\n", .{ r.dcfg, r.dctl, r.dsts, r.gintsts, r.gintmsk, r.gahbcfg });
    board.console("  usb: ep0 in {d} out {d}; oep {d} iep {d}; mailbox power: code {x:0>8} state {x:0>8}\n", .{ d.ep0_in, d.ep0_out, d.oep, d.iep, mailbox.lastCode(), mailbox.lastState() });
}
