//! Interrupt critical sections (`os::rtos::interrupts`).
//!
//! The C++ RAII objects become values with an explicit `exit()`, used with
//! `defer`:
//!
//! ```zig
//! const cs = interrupts.CriticalSection.enter();
//! defer cs.exit();
//! ```
//!
//! Both nest freely. On a single-CPU build the port masks interrupts (or
//! raises BASEPRI); on SMP it also takes the recursive kernel lock, so a
//! critical section is exclusive across CPUs as well.

const port = @import("uos_port");

pub const State = port.interrupts.State;

/// Interrupts masked (below the scheduler priority) until `exit()`.
pub const CriticalSection = struct {
    state: State,

    pub inline fn enter() CriticalSection {
        return .{ .state = port.interrupts.criticalEnter() };
    }

    pub inline fn exit(cs: CriticalSection) void {
        port.interrupts.criticalExit(cs.state);
    }
};

/// Interrupts enabled until `exit()`, even inside a critical section.
pub const UncriticalSection = struct {
    state: State,

    pub inline fn enter() UncriticalSection {
        return .{ .state = port.interrupts.uncriticalEnter() };
    }

    pub inline fn exit(us: UncriticalSection) void {
        port.interrupts.uncriticalExit(us.state);
    }
};

/// True when running in an exception/interrupt handler.
pub inline fn inHandlerMode() bool {
    return port.interrupts.inHandlerMode();
}

/// True when the current handler (if any) may call the RTOS, i.e. its
/// priority is not above the critical section level.
pub inline fn isPriorityValid() bool {
    return port.interrupts.isPriorityValid();
}

/// The interrupt (MSP) stack, when the port has a separate one.
pub fn stack() ?[]port.StackElement {
    if (@hasDecl(port, "interruptStack")) return port.interruptStack();
    return null;
}
