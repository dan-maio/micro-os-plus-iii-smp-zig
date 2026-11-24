//! capstone.zig -- the tutorial's capstone (test/tutor/19-capstone/README.md):
//! an application of the whole course, its sources grouped by domain:
//!
//!   core/       config.zig (sizes, files, priorities, placement), threads.zig
//!               (creating threads where they belong)
//!   data/       samples.zig (the four sample sources: .data, a stack, the
//!               heap, a pool)
//!   pipeline/   pipeline.zig (one round: producers -> queue -> consumer)
//!   churn/      churn.zig (the rounds: threads created and destroyed,
//!               baselines)
//!   storage/    storage.zig (the card's one owner: the log, the USB file in a
//!               ring of buffers, the read-back)
//!   usb/        usb_link.zig (the DWC2 gadget, its service thread and
//!               interrupt), big_transfer.zig (the file transfer protocol)
//!
//! 1cpu/main.zig and 4cpu/main.zig are its two entry points; the build's CPU
//! count (their uos_options) decides the rest (core/config.zig).
//!
//! The Zig version of the C++ application (golden workspace,
//! test/rpi4b/tutor/19-capstone/app/), domain for domain, with the same checks.
//!
//! The flow:
//!   1. (four CPUs) cores 1-3 released;
//!   2. the card and its owner, the logger: every line from here on is logged;
//!   3. the USB device up (on the board) and the file kept open, so the host
//!      can send its file while the rest runs;
//!   4. the churn: the pipeline's rounds, everything checked after each;
//!   5. the USB transfer waited for;
//!   6. the logger stopped, the log and the USB file read back from the card,
//!      the verdict.

const uos = @import("uos");
const board = @import("board");
const tutor = @import("tutor");
const sdlog = @import("sdlog");
const config = @import("core/config.zig");
const samples = @import("data/samples.zig");
const churn = @import("churn/churn.zig");
const storage = @import("storage/storage.zig");
const usb = @import("usb/usb_link.zig");
const big = @import("usb/big_transfer.zig");

const check = tutor.check;
const say = sdlog.say;

/// The interrupts the board's dispatcher does not own: the USB core's (the
/// lesson's root re-exports this as uos_external_irq).
pub fn onExternalIrq(iar: u32) void {
    usb.onIrq(uos.port.gic_mod.Gic.intidOf(iar));
}

/// The whole application; ends the run with its verdict.
pub fn run() noreturn {
    const self = uos.rtos.this_thread.thread();
    if (config.four) self.setCpuAffinity(1 << 0);
    tutor.printBanner("19 capstone");
    board.console("Lesson 19, {s}: the capstone -- threads, regions, a pool, queues, the SD card and the USB device.\n", .{if (config.four) "four CPUs" else "one CPU"});
    tutor.printRegions();

    if (config.four) {
        // ---- 1. Cores 1-3 (as in lesson 01).
        board.smp.startSecondaryCores();
        const waited = board.smp.waitSecondaries(3000);
        board.console("  cores joined after {d} ms: {s}\n", .{ waited, board.smp.joinSummary() });
        _ = check(board.smp.secondariesJoined(), "cores 1-{d} joined the scheduler", .{config.ncpu - 1});
    }

    // ---- 2. The card and its owner.
    const on_hw = tutor.onHardware();
    board.console("\n-- the card: {s}\n", .{if (on_hw) "init, mount the FAT32 volume, tests/ ready" else "none in this image (QEMU): the lines go to the UART only"});
    if (!storage.start()) {
        _ = check(false, "the SD card is ready", .{});
        tutor.finish("");
    }
    _ = say("  the logger owns the UART and the card (tests/{s}); the USB file goes to tests/{s}\n", .{ config.log_leaf, config.usb_leaf });

    // ---- 3. The USB device (on the board only: QEMU's raspi4b has no
    // device-mode DWC2, and this image is the same for both).
    _ = say("\n-- the USB device: the DWC2 gadget behind the USB-C socket, {x:0>4}:{x:0>4}\n", .{ config.usb_vid, config.usb_pid });
    const why: ?[]const u8 = if (on_hw) usb.start() else "no device-mode DWC2 under QEMU";
    if (why) |w| {
        _ = say("  not up: {s}\n", .{w});
    } else {
        _ = say("  up, its service thread on core 0; the host may send: usb_test_host --big <file>\n", .{});
    }
    if (on_hw) {
        _ = check(why == null, "the USB device is up", .{});
        if (why == null) _ = check(storage.openFile(), "tests/{s} created and kept open for the transfer", .{config.usb_leaf});
    }

    // Everything from here on must be given back: the pool, every round, the
    // transfer. (The USB start keeps nothing on the heap.)
    const heap0 = tutor.heapBytes();
    _ = check(samples.poolCreate(), "the sample pool, on the heap: {d} blocks", .{config.per_producer});

    // ---- 4. The churn.
    _ = say("\n-- the churn: {d} rounds of {d} producers (static, stack, new, pool) and one consumer\n", .{ config.rounds, config.producers });
    const ch = churn.runAll();
    _ = check(ch.matched == config.rounds, "every round's result was the reference's ({d} of {d})", .{ ch.matched, config.rounds });
    _ = check(ch.misplaced == 0, "every sample lay where its source says", .{});
    _ = check(ch.clean == config.rounds, "after every round the heap was back and the pool empty", .{});
    _ = check(ch.threads == config.rounds * (config.producers + 1), "{d} threads created and destroyed", .{ch.threads});
    if (config.four) _ = check(ch.producer_cores == (@as(u32, 1) << config.ncpu) - 1, "the producers ran on all {d} cores", .{config.ncpu});

    // ---- 5. The USB transfer.
    var usb_done = false;
    if (usb.up()) {
        _ = say("\n-- the USB transfer: waiting for the host (at most {d} s)\n", .{config.usb_wait_s});
        usb_done = big.wait(config.usb_wait_s);
        const u = big.last();
        if (usb_done) {
            _ = say("  {d} B announced, {d} received, {d} echoed, in {d} ms; {d} blocks to the card (waited {d} us at most); crc {x:0>8}\n", .{ u.announced, u.received, u.echoed, u.us / 1000, u.blocks, u.max_wait_us, u.crc });
        } else {
            usb.diagnose();
        }
        _ = check(usb_done, "the host's file arrived", .{});
        _ = check(usb_done and u.received == u.announced and u.echoed == u.received and u.stored, "every byte received, echoed and stored", .{});
    }

    samples.poolDestroy();
    const heap1 = tutor.heapBytes();

    // ---- 6. The read-back, the verdict.
    _ = say("\n-- the card read back\n", .{});
    storage.stop(); // from here on, the console
    const rb = storage.readBack();
    const st = sdlog.stats();
    board.console("  the churn: {d} rounds, {d} as the reference, {d} clean, {d} misplaced, {d} threads\n", .{ ch.rounds, ch.matched, ch.clean, ch.misplaced, ch.threads });
    if (storage.hasCard()) {
        board.console("  tests/{s}: {d} B, {d} lines ({d} written); {s}\n", .{ config.log_leaf, rb.log_bytes, rb.log_lines, st.lines.load(.monotonic), if (rb.log_ok) "as written" else "NOT as written" });
        _ = check(rb.log_ok, "the log read back: its size, CRC-32 and lines are those written", .{});
    }
    if (usb_done) {
        const u = big.last();
        board.console("  USB: {d} B received, crc {x:0>8}; tests/{s} on the card: {d} B, crc {x:0>8}\n", .{ u.received, u.crc, config.usb_leaf, rb.file_bytes, rb.file_crc });
        _ = check(rb.file_read and rb.file_bytes == u.received and rb.file_crc == u.crc, "the USB file read back from the card: its size and CRC-32 are those received", .{});
    }
    board.console("  heap: {d} B before the pool and the rounds, {d} B at the end\n", .{ heap0, heap1 });
    _ = check(heap1 == heap0, "the heap is back to its level", .{});

    // What was verified: on the board everything; under QEMU (no card, no
    // device-mode USB) the churn.
    tutor.finish(if (!on_hw)
        (if (config.four) "the capstone: rounds, regions, pool, queues; no SD card, no USB device under QEMU; four CPUs" else "the capstone: rounds, regions, pool, queues; no SD card, no USB device under QEMU; one CPU")
    else if (config.four) "the capstone: rounds, regions, pool, queues, SD log and USB file verified; four CPUs" else "the capstone: rounds, regions, pool, queues, SD log and USB file verified; one CPU");
}
