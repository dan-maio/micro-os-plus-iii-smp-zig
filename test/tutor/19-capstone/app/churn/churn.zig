//! churn/churn.zig -- the capstone's rounds: the pipeline run again and
//! again, its five threads created and destroyed every time, and after every
//! round everything back where it was: the heap at its level, the pool empty.
//! (C++: app/churn/churn.*.)

const uos = @import("uos");
const tutor = @import("tutor");
const sdlog = @import("sdlog");
const config = @import("../core/config.zig");
const threads = @import("../core/threads.zig");
const samples = @import("../data/samples.zig");
const pipeline = @import("../pipeline/pipeline.zig");

pub const Summary = struct {
    rounds: u32 = 0,
    matched: u32 = 0, // rounds whose result was the reference's
    clean: u32 = 0, // rounds that left the heap and the pool as they were
    misplaced: u32 = 0, // samples, all rounds
    threads: u32 = 0, // created and destroyed, all rounds
    producer_cores: u32 = 0, // the cores producers ran on (a mask)
};

/// All the rounds, one line each to the log; the checks through check().
pub fn runAll() Summary {
    var s: Summary = .{};
    const threads0 = threads.reaped();
    for (0..config.rounds) |r| {
        const heap0 = tutor.heapBytes();
        const res = pipeline.runRound(@intCast(r));
        const heap1 = tutor.heapBytes();
        const clean = heap1 == heap0 and samples.poolInUse() == 0;
        s.rounds += 1;
        if (res.matches) s.matched += 1;
        if (clean) s.clean += 1;
        s.misplaced += res.misplaced;
        for (res.producer_core) |c| {
            if (c < 32) s.producer_cores |= @as(u32, 1) << @intCast(c);
        }
        // At most 110 bytes: one log line.
        _ = sdlog.say("  round {d}: {d} samples {s}, max {d} (id {d}); {d} misplaced; heap {s}, pool {s}; cores {d}{d}{d}{d}\n", .{
            r,                                                             res.received,
            if (res.matches) "as the reference" else "NOT as the reference", res.max_value,
            res.max_id,                                                     res.misplaced,
            if (heap1 == heap0) "back" else "LEAKED",                       if (samples.poolInUse() == 0) "empty" else "NOT empty",
            res.producer_core[0],                                           res.producer_core[1],
            res.producer_core[2],                                           res.producer_core[3],
        });
    }
    s.threads = threads.reaped() - threads0;
    return s;
}
