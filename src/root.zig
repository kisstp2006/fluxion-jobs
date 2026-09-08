// SPDX-License-Identifier: BSL-1.0

//! Fluxion Jobs - work, handed out and waited for.
//!
//!   `Jobs`      the scheduler: spawn, spawn after, wait, wait for all, run some
//!   `parallel`  fork and join over a range or a slice, on top of it
//!
//! ```zig
//! const jobs_lib = @import("fluxion_jobs");
//!
//! var jobs: jobs_lib.Jobs = try .init(gpa, .{ .io = io });
//! defer jobs.deinit();
//!
//! const a = try jobs.spawn(decode, .{&albedo});
//! const b = try jobs.spawn(decode, .{&normal});
//! const m = try jobs.spawnAfter(&.{ a, b }, assemble, .{&material});
//! jobs.wait(m);
//! ```
//!
//! **On every core, or on none.** With an `Io` the scheduler starts one worker
//! per spare core and parks them on it. Without one - which is what a
//! `wasm32-freestanding` build has - there are no workers, and jobs run on
//! the thread that waits for them or calls `runUpTo`. The browser's frame
//! callback runs a few jobs and hands the frame back; nothing in the API is
//! different, and `Jobs.threads_available` is the compile-time fact behind
//! the choice.
//!
//! **Spawning allocates nothing.** The arguments are copied into a fixed
//! payload in a slot; a handle to the slot is a
//! [Fluxion Id](https://github.com/kisstp2006/fluxion-id) generational handle
//! that reads as done for ever after the job finishes, however many times the
//! slot is reused.
//!
//! **Waiting helps.** A thread waiting on a job runs whatever else is ready
//! rather than sleeping, which is what keeps a frame from leaving a core idle,
//! and what lets the whole thing work with no workers at all.

const std = @import("std");

pub const Jobs = @import("Jobs.zig");
pub const parallel = @import("parallel.zig");

/// A job, from `spawn` until it finishes. See `Jobs.Handle`.
pub const Handle = Jobs.Handle;

/// What `spawn` can say no with. See `Jobs.Error`.
pub const Error = Jobs.Error;

/// Whether this target can run worker threads at all. See `Jobs`.
pub const threads_available = Jobs.threads_available;

/// Fork and join over a range. See `parallel.forEach`.
pub const forEach = parallel.forEach;

/// Fork and join over a slice. See `parallel.forSlice`.
pub const forSlice = parallel.forSlice;

test {
    _ = Jobs;
    _ = parallel;
    _ = @import("jobs_test.zig");
}
