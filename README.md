# Fluxion Jobs

Work, handed out and waited for. For Zig 0.16, on every core the machine has
or on none at all, which is the browser.

| Module | What it is |
| --- | --- |
| `Jobs` | The scheduler: `spawn`, `spawnAfter`, `wait`, `waitAll`, `runUpTo`. |
| `parallel` | Fork and join over a range or a slice, on top of it. |

```zig
const jobs_lib = @import("fluxion_jobs");

var jobs: jobs_lib.Jobs = try .init(gpa, .{ .io = io });
defer jobs.deinit();

const a = try jobs.spawn(decode, .{&albedo});
const b = try jobs.spawn(decode, .{&normal});
const m = try jobs.spawnAfter(&.{ a, b }, assemble, .{&material});
jobs.wait(m);

try jobs_lib.parallel.forSlice(&jobs, Particle, particles, 256, step);
```

**A job is a function and its arguments, copied into a slot.** Spawning
allocates nothing: the arguments go into a 64-byte payload in the slot, the
slot goes onto the ready queue, and a worker takes it from there. Anything
bigger than the payload is passed by pointer. Past `capacity` jobs in flight,
`spawn` says `error.TooManyJobs` rather than reaching for the heap in the
middle of a frame.

**A handle stays valid after the job is done, and says so.** Slots are reused,
but a slot's generation steps every time its job finishes, so a handle to a
finished job is never mistaken for whatever took the slot after it. A handle
is a [Fluxion Id](https://github.com/kisstp2006/fluxion-id) handle, eight
bytes, `none` for "nothing to wait on".

**Waiting helps.** A thread waiting for a job runs whatever is ready instead
of sleeping while the queue is not empty, so a frame that waits on its own
jobs never leaves a core idle - and so the whole thing works with no workers.

**Dependencies are edges, not callbacks.** `spawnAfter` counts the
dependencies that have not finished and hangs an edge on each; when one
finishes, it walks its edges and releases whatever they lead to. A dependency
already done is skipped at spawn time and costs nothing. A cycle can only be
made by waiting on a job from inside itself, and that is caught as the
deadlock it is.

## The browser, by itself

```bash
zig build web          # zig-out/web/index.html and the .wasm beside it
```

The same source compiled for `wasm32-freestanding`. There is no `Io` there, so
there are no worker threads, and `Jobs.init` needs telling nothing: it sees
that threads are not available on the target and has zero. The page's frame
callback calls `runUpTo(budget)` - a few jobs, then the frame is handed back -
and the tiles of a Mandelbrot set arrive over a couple of seconds at four jobs
a frame, or in one at sixty-four.

`Jobs.threads_available` is the compile-time fact behind it: false for a wasm
module without shared memory, for `-fsingle-threaded` builds, and for
freestanding targets. On a target that has threads but was given no `Io`, the
answer is the same zero, because an `Io` is what a worker parks on. Nothing in
the API changes between the two: `spawn`, `wait` and `spawnAfter` do what they
say on both, and the native demo renders the same picture both ways to prove
it.

Native, for comparison, on the machine this was written on:

| | 512x512 in 32x32 tiles |
| --- | --- |
| 7 workers | 18 ms |
| 0 workers | 106 ms |

## What it is not

One queue and one lock. That is the right design up to a few thousand jobs a
frame and the wrong one after, where per-worker deques and work stealing take
over. The API does not care which is underneath, so that change is a change
to one file.

No priorities, no affinities, no continuations. A job that needs to run on
the main thread - a GL call - is a job the main thread runs with `runOne` from
a queue of its own, which is what `.io = null` on a second scheduler gives you.

## Install

```bash
zig fetch --save git+https://github.com/kisstp2006/fluxion-jobs
```

Or, for a checkout next to your project, add to `build.zig.zon`:

```zig
.dependencies = .{
    .fluxion_jobs = .{ .path = "../fluxion-jobs" },
},
```

Either way, wire it up in `build.zig`:

```zig
const fluxion = b.dependency("fluxion_jobs", .{
    .target = target,
    .optimize = optimize,
});
exe_mod.addImport("fluxion_jobs", fluxion.module("fluxion_jobs"));
```

```zig
const jobs_lib = @import("fluxion_jobs");
```

One dependency comes with it, fetched the same way and needing nothing from
you: [Fluxion Id](https://github.com/kisstp2006/fluxion-id), whose
generational handle is what a job is known by.

## Where it sits

The second tier of the Fluxion licence ladder: `BSL-1.0`, built on one
tier-one library. Engine infrastructure, like `fluxion-mem`, and asking
nothing of a binary built from it.

## The tests

Every test runs twice: once with an `Io` and as many workers as the machine
gives, once with neither. The point is that they pass the same way - the order
jobs run in may differ, what they did may not. A thousand jobs each running
once, a chain of two hundred dependencies in order, a handle that outlives its
slot several times over, every slot taken and every edge taken, a job spawning
a job, and a range of ten thousand covered exactly once. The browser build is
part of `zig build test`, so a change that breaks the no-thread path fails
here and not in a browser later.

## Build

```bash
zig build test        # run the test suite, and build the wasm
zig build example     # tiles with every core and with none, and a graph
zig build web         # the browser example into zig-out/web
zig build docs        # generate API docs into zig-out/docs
```

## Licence

`BSL-1.0`. See [LICENSE](LICENSE).
