// SPDX-License-Identifier: BSL-1.0

//! Work, handed out and waited for.
//!
//! ```zig
//! var jobs: Jobs = try .init(gpa, .{ .io = io });
//! defer jobs.deinit();
//!
//! const a = try jobs.spawn(decode, .{&texture});
//! const b = try jobs.spawn(decode, .{&normal_map});
//! const upload = try jobs.spawnAfter(&.{ a, b }, upload, .{&material});
//! jobs.wait(upload);
//! ```
//!
//! **A job is a function and its arguments, copied into a slot.** Nothing is
//! allocated when one is spawned: the arguments go into a fixed payload in the
//! slot, the slot goes onto a ready queue, and a worker takes it from there.
//! Spawning is the cost of a copy and a lock.
//!
//! **A handle stays valid after the job is done**, and says so. A slot is
//! reused once its job finishes, but its generation steps when it is, so a
//! handle to a finished job is never mistaken for the job that took its slot.
//!
//! **Waiting helps.** A thread that waits for a job does not sleep while
//! there is work in the queue: it runs whatever is ready, which is what keeps
//! a frame that waits on its own jobs from leaving a core idle - and what
//! makes the whole thing work with no workers at all.
//!
//! **No workers is a mode, not a failure.** Without an `Io` there is no way to
//! park a thread, so there are none: every job runs on the thread that waits
//! for it, or on the one that calls `runOne`. That is the browser. A game
//! built for `wasm32-freestanding` calls `runUpTo` from its frame callback,
//! spends as much of the frame on jobs as it likes, and hands the rest back to
//! the page - the same code, the same jobs, the same handles as on a machine
//! with sixteen cores.
//!
//! One queue, one lock. Not work-stealing, which is the right design for a
//! thousand jobs a frame and the wrong one to write before there are a
//! thousand jobs a frame; the API does not care which is underneath.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const id = @import("fluxion_id");

const Jobs = @This();

/// Whether this target can run worker threads at all. False for a wasm
/// module without shared memory, and for `-fsingle-threaded` builds; the
/// scheduler still works there, with `workers = 0` whatever was asked for.
pub const threads_available = !builtin.single_threaded and switch (builtin.os.tag) {
    .freestanding, .other, .uefi => false,
    .wasi, .emscripten => std.Target.wasm.featureSetHas(builtin.cpu.features, .atomics),
    else => true,
};

/// The most bytes a job's arguments may take. Pass a pointer to anything
/// bigger.
pub const payload_len = 64;

pub const Options = struct {
    /// What worker threads park on. Without one there are no workers, and
    /// the scheduler may only be touched from the thread that made it.
    io: ?Io = null,
    workers: Workers = .auto,
    /// How many jobs may be in flight - spawned and not yet finished - at
    /// once. `error.TooManyJobs` past this, rather than a heap allocation
    /// in the middle of a frame.
    capacity: u32 = 4096,
    /// How many dependency edges may be in flight. A job that waits on
    /// three others is three edges.
    edges: u32 = 8192,

    pub const Workers = union(enum) {
        /// One fewer than the machine has cores, leaving one for the thread
        /// that spawns. Zero where threads are not available or no `Io` was
        /// given.
        auto,
        /// Exactly this many. Zero is allowed and means "the caller runs
        /// everything", which is also what a target without threads gets.
        count: u32,
    };
};

pub const Error = error{
    /// Every slot is taken. Wait for something to finish, or ask for more
    /// capacity.
    TooManyJobs,
    /// Every edge is taken.
    TooManyEdges,
} || Allocator.Error;

/// A job, from `spawn` until `wait` or `isDone` says it finished.
pub const Handle = id.handle.Handle(Slot);

gpa: Allocator,
io: ?Io,
slots: []Slot,
edges: []Edge,
/// Indices of slots whose jobs may run now.
ready: []u32,
ready_head: u32 = 0,
ready_len: u32 = 0,
first_free_slot: u32,
first_free_edge: u32,
/// Jobs spawned and not yet finished.
live: u32 = 0,
threads: []std.Thread,
/// How many workers to start, the first time a job is spawned. Started then
/// rather than in `init`, because `init` returns the scheduler by value and
/// a worker needs its address to be the final one.
workers_wanted: u32,
started: bool = false,
stopping: bool = false,

mutex: Io.Mutex = .init,
/// Signalled when the ready queue gains a job, for parked workers.
has_work: Io.Condition = .init,
/// Signalled when any job finishes, for threads waiting on one.
finished: Io.Condition = .init,

const end = std.math.maxInt(u32);

/// A slot holds one job at a time, and its history.
pub const Slot = struct {
    generation: u32,
    /// While free, the next free slot. While live, unused.
    next_free: u32,
    /// How many jobs this one still waits for. Runs when it reaches zero.
    pending: u32,
    /// The head of the chain of jobs waiting on this one.
    first_edge: u32,
    run: *const fn (payload: *align(16) const [payload_len]u8, jobs: *Jobs) void,
    payload: [payload_len]u8 align(16),
};

/// "When `from` finishes, one fewer thing is holding `to` back."
const Edge = struct {
    to: u32,
    next: u32,
};

// -------------------------------------------------------------------------
// Starting and stopping
// -------------------------------------------------------------------------

pub fn init(gpa: Allocator, options: Options) Error!Jobs {
    const slots = try gpa.alloc(Slot, options.capacity);
    errdefer gpa.free(slots);
    for (slots, 0..) |*slot, i| slot.* = .{
        .generation = 1,
        .next_free = if (i + 1 < slots.len) @intCast(i + 1) else end,
        .pending = 0,
        .first_edge = end,
        .run = undefined,
        .payload = undefined,
    };

    const edges = try gpa.alloc(Edge, options.edges);
    errdefer gpa.free(edges);
    for (edges, 0..) |*edge, i| edge.* = .{
        .to = end,
        .next = if (i + 1 < edges.len) @intCast(i + 1) else end,
    };

    const ready = try gpa.alloc(u32, options.capacity);
    errdefer gpa.free(ready);

    var self: Jobs = .{
        .gpa = gpa,
        .io = options.io,
        .slots = slots,
        .edges = edges,
        .ready = ready,
        .first_free_slot = if (slots.len != 0) 0 else end,
        .first_free_edge = if (edges.len != 0) 0 else end,
        .threads = &.{},
        .workers_wanted = 0,
    };
    self.workers_wanted = self.workersWanted(options.workers);
    return self;
}

/// Start the workers. Called under the lock, once, from the first spawn -
/// by which time `self` is where it will stay.
fn startWorkers(self: *Jobs) void {
    self.started = true;
    if (comptime !threads_available) return;
    if (self.workers_wanted == 0) return;

    const threads = self.gpa.alloc(std.Thread, self.workers_wanted) catch return;
    // A thread that cannot be made is not an error: the scheduler works
    // with the ones it got, down to none.
    var made: usize = 0;
    while (made < threads.len) : (made += 1) {
        threads[made] = std.Thread.spawn(.{}, worker, .{self}) catch break;
    }
    if (made == 0) {
        self.gpa.free(threads);
        return;
    }
    self.threads = threads[0..made];
}

/// The number of workers this configuration and this target allow.
fn workersWanted(self: *const Jobs, workers: Options.Workers) u32 {
    // `comptime`, so a target without threads never sees `std.Thread` at all.
    if (comptime !threads_available) return 0;
    if (self.io == null) return 0;
    return switch (workers) {
        .count => |n| n,
        .auto => blk: {
            const cores = std.Thread.getCpuCount() catch 1;
            break :blk @intCast(@max(cores, 1) - 1);
        },
    };
}

/// Finish every job, stop the workers, and give the memory back. Jobs still
/// in flight are run to completion first; nothing is dropped.
pub fn deinit(self: *Jobs) void {
    self.waitAll();

    if (comptime threads_available) if (self.threads.len != 0) {
        const io = self.io.?;
        self.mutex.lockUncancelable(io);
        self.stopping = true;
        self.has_work.broadcast(io);
        self.mutex.unlock(io);
        for (self.threads) |thread| thread.join();
        // `threads` may be a prefix of what was allocated; the allocation is
        // what has to be freed.
        self.gpa.free(self.threads.ptr[0..self.threads.len]);
    };

    self.gpa.free(self.ready);
    self.gpa.free(self.edges);
    self.gpa.free(self.slots);
    self.* = undefined;
}

/// How many worker threads there are, or will be once the first job is
/// spawned. Zero where the caller runs everything.
pub fn workerCount(self: *const Jobs) usize {
    return if (self.started) self.threads.len else self.workers_wanted;
}

// -------------------------------------------------------------------------
// Spawning
// -------------------------------------------------------------------------

/// Run `function(args...)` on some thread, some time from now.
///
/// `args` is a tuple, copied into the job; `@sizeOf` it must be at most
/// `payload_len`. Anything bigger is passed by pointer, and the caller keeps
/// it alive until the job is done.
pub fn spawn(self: *Jobs, comptime function: anytype, args: anytype) Error!Handle {
    return self.spawnAfter(&.{}, function, args);
}

/// Like `spawn`, but the job does not start until every job in `after` has
/// finished. Handles to jobs already done are fine, and cost nothing.
pub fn spawnAfter(
    self: *Jobs,
    after: []const Handle,
    comptime function: anytype,
    args: anytype,
) Error!Handle {
    const Args = @TypeOf(args);
    comptime {
        if (@sizeOf(Args) > payload_len) {
            @compileError("fluxion-jobs: the arguments of " ++ @typeName(@TypeOf(function)) ++
                " take more than " ++ std.fmt.comptimePrint("{d}", .{payload_len}) ++
                " bytes; pass a pointer to them instead");
        }
        if (@alignOf(Args) > 16) {
            @compileError("fluxion-jobs: arguments need alignment above 16; pass a pointer to them instead");
        }
    }

    const Shim = struct {
        fn run(payload: *align(16) const [payload_len]u8, jobs: *Jobs) void {
            _ = jobs;
            const stored: *const Args = @ptrCast(@alignCast(payload));
            @call(.auto, function, stored.*);
        }
    };

    self.lock();
    defer self.unlock();
    if (!self.started) self.startWorkers();

    const index = self.first_free_slot;
    if (index == end) return error.TooManyJobs;
    const slot = &self.slots[index];

    // Count the dependencies that are not done yet, and hang an edge on each,
    // before the slot is made live - so a dependency finishing right now
    // either sees the edge or was already counted as done, never neither.
    var waiting_on: u32 = 0;
    var edges_taken: u32 = 0;
    errdefer self.releaseEdges(after, edges_taken);
    for (after) |dep| {
        if (self.isDoneLocked(dep)) continue;
        const edge_index = self.first_free_edge;
        if (edge_index == end) return error.TooManyEdges;
        const edge = &self.edges[edge_index];
        self.first_free_edge = edge.next;
        edge.* = .{ .to = index, .next = self.slots[dep.index].first_edge };
        self.slots[dep.index].first_edge = edge_index;
        edges_taken += 1;
        waiting_on += 1;
    }

    self.first_free_slot = slot.next_free;
    slot.next_free = end;
    slot.pending = waiting_on;
    slot.first_edge = end;
    slot.run = Shim.run;
    if (@sizeOf(Args) != 0) {
        const stored: *Args = @ptrCast(@alignCast(&slot.payload));
        stored.* = args;
    }
    self.live += 1;

    const handle: Handle = .{ .index = index, .generation = slot.generation };
    if (waiting_on == 0) self.pushReady(index);
    return handle;
}

/// Undo the edges a failed spawn hung on its dependencies.
fn releaseEdges(self: *Jobs, after: []const Handle, taken: u32) void {
    var left = taken;
    var i: usize = after.len;
    while (left != 0 and i != 0) {
        i -= 1;
        const dep = after[i];
        if (self.isDoneLocked(dep)) continue;
        const dep_slot = &self.slots[dep.index];
        const edge_index = dep_slot.first_edge;
        if (edge_index == end) continue;
        dep_slot.first_edge = self.edges[edge_index].next;
        self.edges[edge_index].next = self.first_free_edge;
        self.first_free_edge = edge_index;
        left -= 1;
    }
}

// -------------------------------------------------------------------------
// Asking and waiting
// -------------------------------------------------------------------------

/// Has this job finished? True for `Handle.none` and for any handle whose
/// slot has moved on since.
pub fn isDone(self: *Jobs, handle: Handle) bool {
    self.lock();
    defer self.unlock();
    return self.isDoneLocked(handle);
}

fn isDoneLocked(self: *const Jobs, handle: Handle) bool {
    if (handle.isNone()) return true;
    if (handle.index >= self.slots.len) return true;
    return self.slots[handle.index].generation != handle.generation;
}

/// How many jobs are spawned and not yet finished.
pub fn pending(self: *Jobs) u32 {
    self.lock();
    defer self.unlock();
    return self.live;
}

/// Block until `handle` is done, running other jobs meanwhile.
///
/// With no workers this is where jobs run at all. A job that waits on itself
/// - from inside its own function - is a deadlock on any scheduler, and is
/// caught as one here.
pub fn wait(self: *Jobs, handle: Handle) void {
    while (true) {
        self.lock();
        if (self.isDoneLocked(handle)) {
            self.unlock();
            return;
        }
        if (self.popReady()) |index| {
            self.unlock();
            self.execute(index);
            continue;
        }
        if (self.io) |io| {
            // Nothing to help with; sleep until something finishes.
            self.finished.waitUncancelable(io, &self.mutex);
            self.unlock();
            continue;
        }
        self.unlock();
        @panic("fluxion-jobs: waiting on a job that can never run - a job waiting on itself, or on one whose dependency waits on it");
    }
}

/// Block until every job spawned so far is done, running them meanwhile.
pub fn waitAll(self: *Jobs) void {
    while (true) {
        self.lock();
        if (self.live == 0) {
            self.unlock();
            return;
        }
        if (self.popReady()) |index| {
            self.unlock();
            self.execute(index);
            continue;
        }
        if (self.io) |io| {
            self.finished.waitUncancelable(io, &self.mutex);
            self.unlock();
            continue;
        }
        self.unlock();
        @panic("fluxion-jobs: jobs are pending but none can run - a dependency cycle");
    }
}

/// Run one ready job on this thread, if there is one. True if one ran.
///
/// The browser's verb: a frame callback calls `runUpTo` or this, and hands
/// the rest of the frame back to the page.
pub fn runOne(self: *Jobs) bool {
    self.lock();
    const index = self.popReady() orelse {
        self.unlock();
        return false;
    };
    self.unlock();
    self.execute(index);
    return true;
}

/// Run up to `limit` ready jobs on this thread. Returns how many ran.
pub fn runUpTo(self: *Jobs, limit: usize) usize {
    var ran: usize = 0;
    while (ran < limit and self.runOne()) ran += 1;
    return ran;
}

// -------------------------------------------------------------------------
// Underneath
// -------------------------------------------------------------------------

/// Run the job in `index` and then finish it.
fn execute(self: *Jobs, index: u32) void {
    const slot = &self.slots[index];
    // The payload is read while the slot is live and nobody else may touch
    // it; the slot itself is only written again under the lock, below.
    slot.run(&slot.payload, self);
    self.finish(index);
}

/// Release everything waiting on `index`, free its slot, and say so.
fn finish(self: *Jobs, index: u32) void {
    self.lock();
    defer self.unlock();

    const slot = &self.slots[index];
    var edge_index = slot.first_edge;
    while (edge_index != end) {
        const edge = &self.edges[edge_index];
        const next = edge.next;
        const to = &self.slots[edge.to];
        to.pending -= 1;
        if (to.pending == 0) self.pushReady(edge.to);
        edge.* = .{ .to = end, .next = self.first_free_edge };
        self.first_free_edge = edge_index;
        edge_index = next;
    }

    // Stepping the generation is what makes every handle to this job read
    // as done, however long the slot is reused after.
    slot.generation +%= 1;
    if (slot.generation == 0) slot.generation = 1;
    slot.first_edge = end;
    slot.next_free = self.first_free_slot;
    self.first_free_slot = index;
    self.live -= 1;

    if (self.io) |io| self.finished.broadcast(io);
}

fn pushReady(self: *Jobs, index: u32) void {
    // Cannot overflow: the queue is as long as there are slots.
    const at = (self.ready_head + self.ready_len) % @as(u32, @intCast(self.ready.len));
    self.ready[at] = index;
    self.ready_len += 1;
    if (self.io) |io| {
        if (self.threads.len != 0) self.has_work.signal(io);
    }
}

fn popReady(self: *Jobs) ?u32 {
    if (self.ready_len == 0) return null;
    const index = self.ready[self.ready_head];
    self.ready_head = (self.ready_head + 1) % @as(u32, @intCast(self.ready.len));
    self.ready_len -= 1;
    return index;
}

fn worker(self: *Jobs) void {
    const io = self.io.?;
    while (true) {
        self.mutex.lockUncancelable(io);
        while (self.ready_len == 0 and !self.stopping) {
            self.has_work.waitUncancelable(io, &self.mutex);
        }
        if (self.stopping and self.ready_len == 0) {
            self.mutex.unlock(io);
            return;
        }
        const index = self.popReady().?;
        self.mutex.unlock(io);
        self.execute(index);
    }
}

/// The lock is real only when other threads can exist. Without an `Io` there
/// is no way for them to, so there is nothing to lock against.
fn lock(self: *Jobs) void {
    if (self.io) |io| self.mutex.lockUncancelable(io);
}

fn unlock(self: *Jobs) void {
    if (self.io) |io| self.mutex.unlock(io);
}
