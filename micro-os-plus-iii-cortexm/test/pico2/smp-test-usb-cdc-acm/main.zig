//! smp-test-usb-cdc-acm (Pico 2 / RP2350) -- USB CDC-ACM (virtual serial)
//! with host on 2-core SMP kernel. Ported exactly from C++ test.
//!
//! Dual-terminal bridge:
//!   - UART0 console @115200 8N1 (GPIO0/1)
//!   - USB virtual serial /dev/ttyACM* (Cafe:4013)
//!
//! Type in either terminal:
//!   - Characters echo as typed (with backspace support).
//!   - Press Return: echoes "you typed: <line>" to CDC, mirrors "[line] <line>" to UART.
//!   - Send Escape (0x1B) + Return: ends test with "RESULT: PASS (host sent Escape)".
//!
//! Pinned threads:
//!   - Core 0: USB device task + Console bridge task
//!   - Core 1: Blink heartbeat task (onboard LED on GPIO25)

const std = @import("std");
const microzig = @import("microzig");
const uos = @import("uos");
const board = @import("uos_board");

const rtos = uos.rtos;
const sysclock = rtos.sysclock;
const this_thread = rtos.this_thread;
const semihosting = uos.port.semihosting;
const uart = board.uart;

const rp2xxx = microzig.hal;
const usb = microzig.core.usb;

pub const microzig_options = uos.port.microzig_options;

pub const uos_options: uos.Options = .{
    .ncpu = 2,
    .smp = true,
    .systick_frequency_hz = 1000,
    .critical_section_interrupt_priority = 5,
    .main_stack_size_bytes = 8192,
    .idle_stack_size_bytes = 4096,
    .default_stack_size_bytes = 4096,
    .dynamic_memory_size_bytes = 64 * 1024,
};

pub const uos_port_options: uos.port.Options = .{ .launch_core1_at_start = false };

pub const std_options: std.Options = .{
    .logFn = uos.trace.logFn,
    .log_level = .info,
    .page_size_min = 4096,
    .page_size_max = 4096,
};

pub const panic = std.debug.FullPanic(struct {
    fn panicFn(message: []const u8, first_trace_address: ?usize) noreturn {
        _ = first_trace_address;
        uos.trace.print("\n!! PANIC: {s}\n", .{message});
        uos.rtos.terminate(1);
    }
}.panicFn);

comptime {
    microzig.export_startup();
}

pub fn main() void {
    rtos.run(osMain);
}

// ============================================================================
// USB Device & Controller Definition (Cafe:4013)
// ============================================================================

const USB_Device = rp2xxx.usb.Polled(.{});
const USB_Serial = usb.drivers.CDC;

var usb_device: USB_Device = undefined;

var usb_controller: usb.DeviceController(.{
    .bcd_usb = USB_Device.max_supported_bcd_usb,
    .device_triple = .unspecified,
    .vendor = .{ .id = 0xCafe, .str = "Raspberry Pi" },
    .product = .{ .id = 0x4013, .str = "Pico 2 CDC-ACM" },
    .bcd_device = .v1_00,
    .serial = "PICO2-0001",
    .max_supported_packet_size = USB_Device.max_supported_packet_size,
    .configurations = &.{.{
        .attributes = .{ .self_powered = false },
        .max_current_ma = 500,
        .Drivers = struct { serial: USB_Serial },
    }},
}, .{.{
    .serial = .{ .itf_notifi = "Board CDC", .itf_data = "Board CDC Data" },
}}) = .init;

// Stages:
//   0 = boot / before usb_init
//   1 = usb_init running
//   2 = usb_init done
//   3 = controller init done
//   4 = host mounted
var g_usb_stage: u32 = 0;

// Current LED colour driven by blink_task (core 1); 0 = off, 1..3 = R/G/B.
var g_led_state: u32 = 0;

var g_test_done: bool = false;

var usb_stack: [1024]uos.port.StackElement align(8) = undefined;
var cons_stack: [1024]uos.port.StackElement align(8) = undefined;
var blink_stack: [1024]uos.port.StackElement align(8) = undefined;

var usb_th: rtos.Thread = undefined;
var console_th: rtos.Thread = undefined;
var blink_th: rtos.Thread = undefined;

fn traceBoth(s: []const u8) void {
    uart.write(s);
    semihosting.write(s);
}

fn cdcWrite(serial: *USB_Serial, data: []const u8) void {
    var p = data;
    while (p.len > 0) {
        const w = serial.write(p);
        p = p[w..];
        usb_device.poll(&usb_controller);
    }
}

fn cdcFlush(serial: *USB_Serial) void {
    while (!serial.flush()) {
        usb_device.poll(&usb_controller);
    }
}

fn cdcLog(serial: *USB_Serial, msg: []const u8) void {
    cdcWrite(serial, "[cdc] ");
    cdcWrite(serial, msg);
    cdcWrite(serial, "\r\n");
    cdcFlush(serial);
}

// ============================================================================
// USB Device Task (Core 0)
// ============================================================================

fn usbDeviceTask(_: ?*anyopaque) ?*anyopaque {
    this_thread.thread().setCpuAffinity(1 << 0);
    if (uos.port.scheduler.cpuId() != 0) this_thread.yield();

    @atomicStore(u32, &g_usb_stage, 1, .release);

    // Unreset USBCTRL and power USB PHY
    rp2xxx.resets.unreset_block_wait(rp2xxx.resets.Mask.only(.usbctrl));
    @atomicStore(u32, &g_usb_stage, 2, .release);

    usb_device = .init();
    @atomicStore(u32, &g_usb_stage, 3, .release);

    var prev_led: u32 = 0;

    const long_line1 = "0123456789ABCDEFGHIJ0123456789ABCDEFGHIJ\r\n";
    const long_line2 = "9876543210JIHGFEDCBA9876543210JIHGFEDCBA\r\n";

    while (!@atomicLoad(bool, &g_test_done, .acquire)) {
        usb_device.poll(&usb_controller);

        const drivers = usb_controller.drivers();
        if (drivers) |drv| {
            @atomicStore(u32, &g_usb_stage, 4, .release);

            // Handle blink task's LED transitions over CDC
            const ls = @atomicLoad(u32, &g_led_state, .acquire);
            if (ls != prev_led) {
                prev_led = ls;
                if (ls == 0) {
                    cdcLog(&drv.serial, "led OFF");
                } else if (ls == 1) {
                    cdcLog(&drv.serial, "led ON red");
                } else if (ls == 2) {
                    cdcLog(&drv.serial, "led ON green");
                } else {
                    cdcLog(&drv.serial, "led ON blue");
                }

                if (ls != 0) {
                    cdcWrite(&drv.serial, long_line1);
                    cdcWrite(&drv.serial, long_line2);
                    cdcFlush(&drv.serial);
                }
            }
        }

        this_thread.yield();
    }
    return null;
}

// ============================================================================
// Console Bridge Task (Core 0)
// ============================================================================

fn consoleTask(_: ?*anyopaque) ?*anyopaque {
    this_thread.thread().setCpuAffinity(1 << 0);
    if (uos.port.scheduler.cpuId() != 0) this_thread.yield();

    while (@atomicLoad(u32, &g_usb_stage, .acquire) < 3) {
        sysclock.sleepFor(10) catch {};
    }

    var was_mounted = false;
    var line_buf: [256]u8 = undefined;
    var line_idx: usize = 0;
    var rx_tmp: [64]u8 = undefined;

    var uart_line_buf: [256]u8 = undefined;
    var uart_line_idx: usize = 0;

    while (!@atomicLoad(bool, &g_test_done, .acquire)) {
        const drivers = usb_controller.drivers();
        const mounted = (drivers != null);

        if (mounted != was_mounted) {
            was_mounted = mounted;
            traceBoth(if (mounted) "[usb] mounted\n" else "[usb] unmounted\n");

            if (mounted) {
                cdcWrite(&drivers.?.serial, "\r\n=============================================\r\n");
                cdcWrite(&drivers.?.serial, "  Pico 2 / RP2350 - micro-os-plus-iii\r\n");
                cdcWrite(&drivers.?.serial, "  smp-test-usb-cdc-acm : USB virtual serial I/O\r\n");
                cdcWrite(&drivers.?.serial, "  (\xC2\xB5OS++ Zig API only, no std:: layer)\r\n");
                cdcWrite(&drivers.?.serial, "=============================================\r\n");
                cdcFlush(&drivers.?.serial);
            }
        }

        var activity = false;

        // 1. Check CDC Input (USB virtual serial port)
        if (drivers) |drv| {
            const n = drv.serial.read(&rx_tmp);
            if (n > 0) {
                activity = true;
                for (rx_tmp[0..n]) |c| {
                    if (c == '\r' or c == '\n') {
                        // Echo newline to CDC
                        cdcWrite(&drv.serial, "\r\n");
                        cdcFlush(&drv.serial);

                        const line = line_buf[0..line_idx];

                        // Check for Escape (0x1B) anywhere in the line
                        for (line) |ch| {
                            if (ch == 0x1B) {
                                uart.write("\nRESULT: PASS (host sent Escape)\n"); // the UART only, as C++
                                @atomicStore(bool, &g_test_done, true, .release);
                                return null;
                            }
                        }

                        // Local mirror on UART console
                        traceBoth("[line] ");
                        traceBoth(line);
                        traceBoth("\n");

                        // Buffered reply to host over CDC
                        cdcWrite(&drv.serial, "you typed: ");
                        cdcWrite(&drv.serial, line);
                        cdcWrite(&drv.serial, "\r\n");
                        cdcFlush(&drv.serial);

                        line_idx = 0;
                    } else if (c == 0x08 or c == 0x7F) { // Backspace / DEL
                        if (line_idx > 0) {
                            line_idx -= 1;
                            cdcWrite(&drv.serial, "\x08 \x08");
                            cdcFlush(&drv.serial);
                        }
                    } else {
                        if (line_idx < line_buf.len - 1) {
                            line_buf[line_idx] = c;
                            line_idx += 1;
                            // Immediate character echo to CDC
                            const echo_char = [1]u8{c};
                            cdcWrite(&drv.serial, &echo_char);
                            cdcFlush(&drv.serial);
                        }
                    }
                }
            }
        }

        // 2. Check UART0 Input (hardware UART console)
        while (uart.getChar()) |c| {
            activity = true;
            if (c == '\r' or c == '\n') {
                uart.write("\r\n");
                const line = uart_line_buf[0..uart_line_idx];

                // Check for Escape (0x1B) anywhere in the line
                for (line) |ch| {
                    if (ch == 0x1B) {
                        uart.write("\nRESULT: PASS (host sent Escape)\n"); // the UART only, as C++
                        @atomicStore(bool, &g_test_done, true, .release);
                        return null;
                    }
                }

                // Local mirror on UART console
                traceBoth("[line] ");
                traceBoth(line);
                traceBoth("\n");

                // Echo line back to UART
                uart.write("you typed: ");
                uart.write(line);
                uart.write("\r\n");

                // Forward line to CDC if connected
                if (drivers) |drv| {
                    cdcWrite(&drv.serial, "[uart line] ");
                    cdcWrite(&drv.serial, line);
                    cdcWrite(&drv.serial, "\r\n");
                    cdcFlush(&drv.serial);
                }

                uart_line_idx = 0;
            } else if (c == 0x08 or c == 0x7F) { // Backspace / DEL
                if (uart_line_idx > 0) {
                    uart_line_idx -= 1;
                    uart.write("\x08 \x08");
                }
            } else {
                if (uart_line_idx < uart_line_buf.len - 1) {
                    uart_line_buf[uart_line_idx] = c;
                    uart_line_idx += 1;
                    const echo_ch = [1]u8{c};
                    uart.write(&echo_ch);
                }
            }
        }

        if (!activity) {
            sysclock.sleepFor(5) catch {};
        }
    }
    return null;
}

// ============================================================================
// Heartbeat Blink Task (Core 1)
// ============================================================================

fn blinkTask(_: ?*anyopaque) ?*anyopaque {
    this_thread.thread().setCpuAffinity(1 << 1);
    if (uos.port.scheduler.cpuId() != 1) this_thread.yield();

    board.led.init();
    board.led.set(false);

    var k: u32 = 0;

    while (!@atomicLoad(bool, &g_test_done, .acquire)) {
        const st = @atomicLoad(u32, &g_usb_stage, .acquire);

        if (st >= 4) { // Host mounted: R/G/B heartbeat sequence
            k +%= 1;
            const c = (k % 3) + 1; // 1, 2, or 3
            board.led.set(true);
            @atomicStore(u32, &g_led_state, c, .release);
            sysclock.sleepFor(900) catch {};

            board.led.set(false);
            @atomicStore(u32, &g_led_state, 0, .release);
            sysclock.sleepFor(100) catch {};
        } else { // Not mounted yet
            board.led.toggle();
            sysclock.sleepFor(400) catch {};
        }
    }
    return null;
}

// ============================================================================
// Main Coordinator (Core 0)
// ============================================================================

fn osMain() u8 {
    this_thread.thread().setCpuAffinity(1 << 0);

    traceBoth("\n=============================================\n");
    traceBoth("  Pico 2 / RP2350 - micro-os-plus-iii\n");
    traceBoth("  smp-test-usb-cdc-acm : USB virtual serial I/O\n");
    traceBoth("  (\xC2\xB5OS++ Zig API only, no std:: layer)\n");
    traceBoth("=============================================\n");

    traceBoth("core 0: creating USB and console threads on core 0, blink thread on core 1...\n");

    usb_th.init("usb", usbDeviceTask, null, .{ .stack = &usb_stack }, null) catch
        @panic("cannot create usb thread");
    usb_th.setCpuAffinity(1 << 0);

    console_th.init("console", consoleTask, null, .{ .stack = &cons_stack }, null) catch
        @panic("cannot create console thread");
    console_th.setCpuAffinity(1 << 0);

    blink_th.init("blink", blinkTask, null, .{ .stack = &blink_stack }, null) catch
        @panic("cannot create blink thread");
    blink_th.setCpuAffinity(1 << 1);

    traceBoth("core 0: launching core 1 (bootrom FIFO handshake)...\n");
    uos.port.launchCore1();
    traceBoth("core 0: core 1 launched; SMP running.\n");

    traceBoth("core 0: CDC-ACM up. Open gadget port (Cafe:4013), type line,\n");
    traceBoth("        press Return; the line is echoed and mirrored here.\n");
    traceBoth("        send Escape to finish.\n");

    // Keep osMain alive; the test runs until Escape is received over CDC or UART
    while (!@atomicLoad(bool, &g_test_done, .acquire)) {
        sysclock.sleepFor(1000) catch {};
    }

    semihostExit();
    return 0;
}

fn semihostExit() void {
    semihosting.write("RESULT: PASS\n");
    uos.rtos.terminate(0);
}
