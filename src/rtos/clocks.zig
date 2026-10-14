//! Clocks (`os::rtos::clock`, `src/rtos/os-clocks.cpp`).
//!
//! Three clocks, as in C++:
//!
//! - `sysclock`: the SysTick tick counter (`clock_systick`); every timed
//!   wait of the kernel objects uses it by default;
//! - `hrclock`: high resolution, in CPU cycles (or the port's hardware
//!   timer), for measurements (`clock_highres`);
//! - `rtclock`: seconds since the epoch, adjustable (`clock_rtc`).
//!
//! The C++ virtual methods are a `Kind` switch: the three behaviours are
//! fixed and known at compile time.

const std = @import("std");
const assert = std.debug.assert;

const port = @import("uos_port");
const config = @import("../config.zig");
const trace = @import("../trace.zig");
const result = @import("result.zig");
const Error = result.Error;
const interrupts = @import("interrupts.zig");
const scheduler = @import("scheduler.zig");
const lists = @import("lists.zig");
const this_thread = @import("thread.zig").this_thread;

const tr = config.options.trace;

/// Clock ticks (`clock::duration_t`).
pub const Duration = u32;
/// Absolute clock time, in ticks (`clock::timestamp_t`).
pub const Timestamp = u64;
/// The adjustable clocks offset (`clock::offset_t`).
pub const Offset = i64;

pub const Clock = struct {
    name: [:0]const u8,
    kind: Kind,

    /// Monotone tick count, incremented by the tick interrupt.
    steady_count: Timestamp = 0,
    /// Threads and timers waiting for a steady timestamp.
    steady_list: lists.ClockTimestampsList = .{},

    /// Adjustable clocks only: offset added to the steady count, and the
    /// list of waits for an adjusted timestamp.
    offset: Offset = 0,
    adjusted_list: lists.ClockTimestampsList = .{},

    pub const Kind = enum { systick, highres, rtc };

    /// SysTick frequency, the unit of `sysclock`.
    pub const frequency_hz = config.options.systick_frequency_hz;

    /// Convert microseconds to ticks, rounding up (`clock_systick::ticks_cast`).
    pub fn ticksCast(microseconds: u64) Duration {
        return @intCast((microseconds * frequency_hz + 1_000_000 - 1) / 1_000_000);
    }

    /// Convert milliseconds to `sysclock` ticks, rounding up.
    pub fn msToTicks(milliseconds: u32) Duration {
        return ticksCast(@as(u64, milliseconds) * 1000);
    }

    pub fn start(c: *Clock) void {
        switch (c.kind) {
            .systick => port.clock_systick.start(),
            .highres => port.clock_highres.start(),
            .rtc => assert(!interrupts.inHandlerMode()),
        }
    }

    /// The current time; adjusted for the adjustable clocks.
    pub fn now(c: *Clock) Timestamp {
        switch (c.kind) {
            .systick => {
                const cs = interrupts.CriticalSection.enter();
                defer cs.exit();
                return c.steady_count;
            },
            .highres => {
                if (port.clock_highres.has_hardware_counter) return port.clock_highres.hardwareCounter();
                const cs = interrupts.CriticalSection.enter();
                defer cs.exit();
                return c.steady_count + port.clock_highres.cyclesSinceTick();
            },
            .rtc => {
                const cs = interrupts.CriticalSection.enter();
                defer cs.exit();
                return @bitCast(@as(Offset, @bitCast(c.steady_count)) + c.offset);
            },
        }
    }

    /// The monotone time, never adjusted.
    pub fn steadyNow(c: *Clock) Timestamp {
        const cs = interrupts.CriticalSection.enter();
        defer cs.exit();
        return c.steady_count;
    }

    /// Sleep for a number of ticks. Returns normally when the time elapsed,
    /// `error.Interrupted` when the thread was interrupted.
    pub fn sleepFor(c: *Clock, duration: Duration) Error!void {
        if (tr.clocks) trace.print("{s}.sleepFor({d})\n", .{ c.name, duration });
        if (interrupts.inHandlerMode()) return error.NotPermitted;
        if (scheduler.locked()) return error.NotPermitted;

        const timestamp = c.steadyNow() + duration;
        while (true) {
            c.internalWaitUntil(timestamp, &c.steady_list);
            if (c.steadyNow() >= timestamp) return;
            if (this_thread.thread().isInterrupted()) return error.Interrupted;
        }
    }

    /// Sleep until an absolute time of this clock (adjusted, for the
    /// adjustable clocks).
    pub fn sleepUntil(c: *Clock, timestamp: Timestamp) Error!void {
        if (tr.clocks) trace.print("{s}.sleepUntil({d})\n", .{ c.name, timestamp });
        if (interrupts.inHandlerMode()) return error.NotPermitted;
        if (scheduler.locked()) return error.NotPermitted;

        const list = if (c.kind == .rtc) &c.adjusted_list else &c.steady_list;
        while (true) {
            c.internalWaitUntil(timestamp, list);
            if (c.now() >= timestamp) return;
            if (this_thread.thread().isInterrupted()) return error.Interrupted;
        }
    }

    /// Wait for a resume (or the timeout). Returns normally when resumed
    /// before the timeout, `error.TimedOut` when the timeout elapsed.
    pub fn waitFor(c: *Clock, timeout: Duration) Error!void {
        if (tr.clocks) trace.print("{s}.waitFor({d})\n", .{ c.name, timeout });
        if (interrupts.inHandlerMode()) return error.NotPermitted;
        if (scheduler.locked()) return error.NotPermitted;

        const timestamp = c.steadyNow() + timeout;
        c.internalWaitUntil(timestamp, &c.steady_list);
        if (c.steadyNow() >= timestamp) return error.TimedOut;
        if (this_thread.thread().isInterrupted()) return error.Interrupted;
    }

    /// Advance the steady count after a low power sleep without ticks.
    pub fn updateForSleptTime(c: *Clock, duration: Duration) Timestamp {
        const cs = interrupts.CriticalSection.enter();
        defer cs.exit();
        c.steady_count += duration;
        c.internalCheckTimestamps();
        return c.steady_count;
    }

    pub fn getOffset(c: *const Clock) Offset {
        return if (c.kind == .rtc) c.offset else 0;
    }

    /// Set the offset of an adjustable clock; returns the previous one.
    pub fn setOffset(c: *Clock, value: Offset) Offset {
        if (c.kind != .rtc) return 0;
        const cs = interrupts.CriticalSection.enter();
        defer cs.exit();
        const prev = c.offset;
        c.offset = value;
        return prev;
    }

    fn internalWaitUntil(c: *Clock, timestamp: Timestamp, list: *lists.ClockTimestampsList) void {
        _ = c;
        const crt = this_thread.thread();
        var node: lists.TimeoutThreadNode = .init(timestamp, crt);
        {
            const cs = interrupts.CriticalSection.enter();
            defer cs.exit();
            // Remove this thread from the ready list, if there.
            port.scheduler.prepareSuspend();
            list.link(&node.node);
            crt.clock_node = &node;
            crt.state = .suspended;
        }
        port.scheduler.reschedule();
        {
            const cs = interrupts.CriticalSection.enter();
            defer cs.exit();
            // Remove the node from the list, if the tick did not.
            crt.clock_node = null;
            node.node.links.unlink();
        }
    }

    /// One tick passed (from the interrupt).
    pub fn internalIncrementCount(c: *Clock) void {
        c.steady_count += switch (c.kind) {
            .highres => port.clock_highres.cyclesPerTick(),
            else => 1,
        };
    }

    /// Run the actions of the due nodes (from the interrupt).
    pub fn internalCheckTimestamps(c: *Clock) void {
        c.steady_list.checkTimestamp(c.steady_count);
        if (c.kind == .rtc) {
            c.adjusted_list.checkTimestamp(@bitCast(@as(Offset, @bitCast(c.steady_count)) + c.offset));
        }
    }

    /// For `clock_highres`: the counter input frequency.
    pub fn inputClockFrequencyHz(c: *const Clock) u32 {
        _ = c;
        return port.clock_highres.inputClockFrequencyHz();
    }
};

pub var sysclock: Clock = .{ .name = "sys-clock", .kind = .systick };
pub var hrclock: Clock = .{ .name = "hr-clock", .kind = .highres };
pub var rtclock: Clock = .{ .name = "rt-clock", .kind = .rtc };

var rtc_ticks: u32 = Clock.frequency_hz;

/// The RTOS tick (`os_systick_handler()`); the port calls it from the
/// SysTick interrupt of CPU 0.
pub fn sysTickHandler() void {
    if (tr.sysclock_tick) trace.putchar('.');
    {
        const cs = interrupts.CriticalSection.enter();
        defer cs.exit();
        sysclock.internalIncrementCount();
        hrclock.internalIncrementCount();
    }
    sysclock.internalCheckTimestamps();
    hrclock.internalCheckTimestamps();

    // Without a real time clock driver, derive the seconds from the tick.
    rtc_ticks -= 1;
    if (rtc_ticks == 0) {
        rtc_ticks = Clock.frequency_hz;
        rtcHandler();
    }

    port.scheduler.reschedule();
}

/// The real time clock second (`os_rtc_handler()`).
pub fn rtcHandler() void {
    if (tr.rtc_tick) trace.putchar('!');
    {
        const cs = interrupts.CriticalSection.enter();
        defer cs.exit();
        rtclock.internalIncrementCount();
    }
    rtclock.internalCheckTimestamps();
}
