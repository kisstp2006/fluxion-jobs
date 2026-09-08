// SPDX-License-Identifier: BSL-1.0

//! Fork and join, over a range.
//!
//! ```zig
//! parallel.forEach(&jobs, particles.len, 256, &particles, step);
//! // every particle has been stepped when this returns
//! ```
//!
//! The loop everyone writes by hand: cut a range into chunks, spawn a job per
//! chunk, wait for them all. With no workers the chunks run on the calling
//! thread inside the wait, so a browser build takes the same code and spends
//! the same frame on it - just alone.

const std = @import("std");
const Jobs = @import("Jobs.zig");

/// Call `function(context, begin, end)` for consecutive chunks of `[0, count)`
/// at most `chunk` long, in parallel, and return when all have run.
///
/// `chunk` is the grain: small enough that the work spreads across the
/// workers, large enough that the copy and the lock per job are not most of
/// it. A few hundred particles, a row of pixels, a thousand entities.
pub fn forEach(
    jobs: *Jobs,
    count: usize,
    chunk: usize,
    context: anytype,
    comptime function: fn (@TypeOf(context), usize, usize) void,
) Jobs.Error!void {
    if (count == 0) return;
    const grain = @max(chunk, 1);

    // Handles are kept in batches on the stack, so a range of any size costs
    // no allocation: spawn a batch, wait for it, spawn the next.
    var handles: [64]Jobs.Handle = undefined;
    var begin: usize = 0;
    while (begin < count) {
        var spawned: usize = 0;
        while (spawned < handles.len and begin < count) : (spawned += 1) {
            const stop = @min(begin + grain, count);
            handles[spawned] = try jobs.spawn(function, .{ context, begin, stop });
            begin = stop;
        }
        for (handles[0..spawned]) |handle| jobs.wait(handle);
    }
}

/// `forEach` over a slice, with the chunk handed over as a slice.
pub fn forSlice(
    jobs: *Jobs,
    comptime T: type,
    items: []T,
    chunk: usize,
    comptime function: fn ([]T) void,
) Jobs.Error!void {
    const Shim = struct {
        fn run(all: []T, begin: usize, stop: usize) void {
            function(all[begin..stop]);
        }
    };
    return forEach(jobs, items.len, chunk, items, Shim.run);
}
