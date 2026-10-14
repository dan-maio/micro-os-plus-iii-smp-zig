//! The RTOS API (`os::rtos`).

pub const result = @import("rtos/result.zig");
pub const Error = result.Error;
pub const errno = result.errno;

pub const interrupts = @import("rtos/interrupts.zig");
pub const scheduler = @import("rtos/scheduler.zig");
pub const lists = @import("rtos/lists.zig");
pub const flags = @import("rtos/flags.zig");

pub const clocks = @import("rtos/clocks.zig");
pub const Clock = clocks.Clock;
pub const Duration = clocks.Duration;
pub const Timestamp = clocks.Timestamp;
pub const sysclock = &clocks.sysclock;
pub const hrclock = &clocks.hrclock;
pub const rtclock = &clocks.rtclock;

const thread_mod = @import("rtos/thread.zig");
pub const Thread = thread_mod.Thread;
pub const ThreadInclusive = thread_mod.ThreadInclusive;
pub const this_thread = thread_mod.this_thread;
pub const priority = thread_mod.priority;
pub const Priority = thread_mod.Priority;

pub const mutex = @import("rtos/mutex.zig");
pub const Mutex = mutex.Mutex;
pub const condvar = @import("rtos/condvar.zig");
pub const ConditionVariable = condvar.ConditionVariable;
pub const semaphore = @import("rtos/semaphore.zig");
pub const Semaphore = semaphore.Semaphore;
pub const evflags = @import("rtos/evflags.zig");
pub const EventFlags = evflags.EventFlags;
pub const mqueue = @import("rtos/mqueue.zig");
pub const MessageQueue = mqueue.MessageQueue;
pub const MessageQueueTyped = mqueue.MessageQueueTyped;
pub const mempool = @import("rtos/mempool.zig");
pub const MemoryPool = mempool.MemoryPool;
pub const MemoryPoolTyped = mempool.MemoryPoolTyped;
pub const timer = @import("rtos/timer.zig");
pub const Timer = timer.Timer;

pub const startup = @import("rtos/startup.zig");
pub const run = startup.run;
pub const terminate = startup.terminate;
