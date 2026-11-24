//! tutor-19-capstone-4cpu -- lesson 19, the capstone, four CPUs (see ../README.md).
//!
//! The entry point only: the application is ../app/ (capstone.zig, the
//! `capstone` module), built for four CPUs -- uos_options below decides the rest
//! (app/core/config.zig).

const uos = @import("uos");
const board = @import("board");
const capstone = @import("capstone");

pub const uos_options = board.options(4);

/// The USB core's interrupt, through the board's dispatcher.
pub const uos_external_irq = capstone.onExternalIrq;

pub fn main() void {
    board.uart.init();
    uos.rtos.run(osMain);
}

fn osMain() void {
    capstone.run();
}
