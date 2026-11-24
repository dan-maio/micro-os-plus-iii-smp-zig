//! Error reporting.
//!
//! The C++ kernel returns `result_t`, a POSIX `errno` value with `result::ok`
//! for success. In Zig the same information travels in error unions; every
//! error has a fixed POSIX number so the C API (and anything that logs a
//! number) stays compatible.

const std = @import("std");

pub const Error = error{
    /// EPERM: called from an interrupt handler, with the scheduler locked,
    /// or by a thread that does not own the mutex.
    NotPermitted,
    /// EINVAL
    InvalidArgument,
    /// EWOULDBLOCK / EAGAIN from a `try*` call: the operation would block.
    WouldBlock,
    /// EAGAIN: a recursive mutex reached its maximum count, or a semaphore
    /// its maximum value.
    Again,
    /// ETIMEDOUT
    TimedOut,
    /// EINTR: the waiting thread was interrupted.
    Interrupted,
    /// ENOMEM
    OutOfMemory,
    /// EDEADLK: an error-checking mutex is already owned by the caller.
    Deadlock,
    /// EOWNERDEAD: a robust mutex was acquired, but its previous owner
    /// terminated while holding it. **The mutex is held** by the caller.
    OwnerDead,
    /// ENOTRECOVERABLE
    NotRecoverable,
    /// EMSGSIZE: a message queue message does not fit.
    MessageSize,
    /// EBADMSG: a message queue was given an invalid message.
    BadMessage,
};

/// The POSIX number of an error, as the C++ `result_t` would carry it
/// (newlib values, which is what the Cortex-M builds use).
pub fn errno(err: Error) c_int {
    return switch (err) {
        error.NotPermitted => 1, // EPERM
        error.InvalidArgument => 22, // EINVAL
        error.WouldBlock => 11, // EWOULDBLOCK == EAGAIN
        error.Again => 11, // EAGAIN
        error.TimedOut => 116, // ETIMEDOUT
        error.Interrupted => 4, // EINTR
        error.OutOfMemory => 12, // ENOMEM
        error.Deadlock => 45, // EDEADLK
        error.OwnerDead => 130, // EOWNERDEAD
        error.NotRecoverable => 131, // ENOTRECOVERABLE
        error.MessageSize => 122, // EMSGSIZE
        error.BadMessage => 77, // EBADMSG
    };
}

/// Convenience for `os_assert_err()`: return `err` when `ok` is false.
pub inline fn check(ok: bool, comptime err: Error) Error!void {
    if (!ok) return err;
}
