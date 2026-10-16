//! uart-test1 (WeAct F412RE) -- USART1 echo test.
//!
//! The Zig port of test/weactf412/uart-test1/main.cpp, line for line. The
//! board's USART1 driver keeps its RXNE receive interrupt and its DMA2
//! Stream7 transmit engine (`src/boards/stm32f4_uart_dma.zig`, the C++
//! uart.cpp), and the application is split into three RTOS threads:
//!
//!   - rx  : blocks on the RX interrupt, hands each received byte to a
//!           bounded buffer (producer);
//!   - tx  : drains the bounded buffer to the UART through the TX DMA
//!           (consumer), and emits a heartbeat when idle for a second;
//!   - led : blinks PB2 at 1 Hz (with `led on`/`led off` on semihosting).
//!
//! The bounded buffer is guarded by a plain mutex and the usual free/used
//! counting-semaphore pair, exactly like mos-test1. After 5 s: PASS when the
//! TX heartbeat advanced.
//!
//! Differences from C++: the kernel's startup banner and its exit trace go
//! to the trace channel, USART1 and semihosting (the C++ build has no
//! startup banner and its trace is semihosting only); the board's clocks,
//! LED and USART1 are set up by the port before main() (C++: led::init()
//! and uart::init() in os_main()); the run ends with main()'s return value
//! through exit() (C++: hw_result::ok(), which is std::exit()).

const std = @import("std");
const uos = @import("uos");
const t = @import("uos_test");
const board = @import("uos_board");
const rtos = uos.rtos;
const sysclock = rtos.sysclock;
const uart = board.uart;

pub const microzig_options = t.microzig_options;
pub const panic = t.panic;
pub const std_options = t.std_options;
pub const uos_options = t.options(.{});

comptime {
    t.exportStartup();
}

pub fn main() void {
    // No heartbeat timer (t.run): the LED is the LED thread's.
    rtos.run(osMain);
}

const BUFFER_SIZE = 32;
const LED_PERIOD_MS = 500; // half period -> 1 Hz blink
const TX_IDLE_MS = 1000; // heartbeat period

var g_buf: [BUFFER_SIZE]u8 = undefined;
var g_head: usize = 0;
var g_tail: usize = 0;
var g_tx_heartbeats: u32 = 0;

var g_buf_mutex: rtos.Mutex = .{ .name = "uart-buf" };
var g_buf_free: rtos.Semaphore = .counting("buf-free", BUFFER_SIZE, BUFFER_SIZE);
var g_buf_used: rtos.Semaphore = .counting("buf-used", BUFFER_SIZE, 0);

const StackElement = uos.port.StackElement;
var rx_stack: [1024]StackElement align(8) = undefined;
var tx_stack: [1024]StackElement align(8) = undefined;
var led_stack: [1024]StackElement align(8) = undefined;

var rx_thread: rtos.Thread = undefined;
var tx_thread: rtos.Thread = undefined;
var led_thread: rtos.Thread = undefined;

// ----- rx thread -------------------------------------------------------------

fn rxFunc(_: ?*anyopaque) ?*anyopaque {
    while (true) {
        const c = uart.readChar(); // blocks until the RX interrupt fires

        g_buf_free.wait() catch {}; // wait for a free slot
        g_buf_mutex.lock() catch {};
        g_buf[g_head] = c;
        g_head = (g_head + 1) % BUFFER_SIZE;
        g_buf_mutex.unlock() catch {};
        g_buf_used.post() catch {}; // signal an item is available
    }
    return null;
}

// ----- tx thread -------------------------------------------------------------

fn txFunc(_: ?*anyopaque) ?*anyopaque {
    var heartbeat: u32 = 0;
    while (true) {
        if (g_buf_used.timedWait(TX_IDLE_MS)) |_| {
            g_buf_mutex.lock() catch {};
            const b = g_buf[g_tail];
            g_tail = (g_tail + 1) % BUFFER_SIZE;
            g_buf_mutex.unlock() catch {};
            g_buf_free.post() catch {};
            uart.putChar(b); // DMA
        } else |_| {
            var line: [48]u8 = undefined;
            const s = std.fmt.bufPrint(&line, "[tx] heartbeat {d}\n", .{heartbeat}) catch "";
            heartbeat += 1;
            uart.write(s);
            @atomicStore(u32, &g_tx_heartbeats, heartbeat, .release);
        }
    }
    return null;
}

// ----- led thread ------------------------------------------------------------

fn ledFunc(_: ?*anyopaque) ?*anyopaque {
    while (true) {
        board.led.set(true);
        uos.port.semihosting.write("led on\n");
        sysclock.sleepFor(LED_PERIOD_MS) catch {};
        board.led.set(false);
        uos.port.semihosting.write("led off\n");
        sysclock.sleepFor(LED_PERIOD_MS) catch {};
    }
    return null;
}

// -----------------------------------------------------------------------------

fn osMain() u8 {
    uart.write("uart-test1: micro-os-plus-iii threads + USART1 IRQ RX + DMA TX\n");
    uart.write("threads: led blink, uart rx, uart tx (echo + heartbeat)\n");

    rx_thread.init("rx", rxFunc, null, .{ .stack = &rx_stack }, null) catch @panic("cannot create rx");
    tx_thread.init("tx", txFunc, null, .{ .stack = &tx_stack }, null) catch @panic("cannot create tx");
    led_thread.init("led", ledFunc, null, .{ .stack = &led_stack }, null) catch @panic("cannot create led");

    // Let the threads run for a bounded time, then check the TX heartbeat
    // advanced and end the run with the verdict.
    const check_ms = 5000;
    sysclock.sleepFor(check_ms) catch {};

    const beats = @atomicLoad(u32, &g_tx_heartbeats, .acquire);
    const ok = beats > 0;
    var rb: [80]u8 = undefined;
    uart.write(std.fmt.bufPrint(&rb, "\nRESULT: {s}  (heartbeats={d})\n", .{
        if (ok) "PASS" else "FAIL", beats,
    }) catch "\nRESULT: ?\n");

    // As hw_result::ok() / fail(): the verdict on semihosting (what the
    // runner reads), then the end of the run (exit()). The threads are
    // still running, as in C++ (std::exit() does not stop them).
    uos.port.semihosting.write(if (ok) "RESULT: PASS\n" else "RESULT: FAIL\n");
    return if (ok) 0 else 1;
}
