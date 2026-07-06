# `lane` — SPMD lanes over a fixed gang of persistent threads

`lane` runs the *same* procedure on every core at once and gives each copy a
lane index, in the style of ISPC tasks or a compute shader: you write one
piece of code, and each lane picks its share of the data. The threads are
spawned once at `init` and park on a futex between splits, so a `split` costs
a wakeup, not a thread spawn — cheap enough to call several times per frame.

The design is based on Ryan Fleury's
[Multi-Core By Default](https://www.dgtlgrove.com/p/multi-core-by-default),
which is the recommended read for the philosophy behind wide execution,
lane-owned shared state, and phase-based synchronization.

```odin
import "lane";

main :: proc() {
    lane.init();                 // one lane per logical core
    defer lane.deinit();

    for game_running {
        lane.split(update_entities);   // every lane runs update_entities
        render();                      // back to plain single-threaded code
    }
}

update_entities :: proc() {
    lo, hi := lane.range(len(g_entities));   // this lane's share
    for i in lo ..< hi do update_entity(&g_entities[i]);
}
```

## The model

- **Lanes are fixed.** `lane.init(thread_count)` creates `thread_count` lanes.
  Non-positive counts are relative to the logical core count: `0` = one lane
  per core, `-n` = all cores but `n` — e.g. `lane.init(-2)` leaves two cores
  free for dedicated threads (audio, streaming). Always clamped to at least
  one lane. The calling thread is always lane `lane.MAIN`
  (`0`) in every split; worker `i` is always lane `i`, for the whole program.
  Per-lane data (scratch arenas, RNG streams, profiler slots) can therefore
  be indexed by `lane.index()` and allocated once, sized with
  `lane.capacity()`.
- **The splitter participates.** `lane.split(p)` runs `p` on all lanes,
  including the caller, and returns when every lane has finished. Because the
  caller is always lane `MAIN`, main-thread-only APIs (SDL event pump, etc.)
  work inside a split behind `if lane.is_main()`.
- **Serial code is the degenerate case, by construction.** Outside a split,
  `count()` is `1` and `index()` is `0`, so `range(n)` covers everything,
  `sync()`/`broadcast()` are no-ops, and every collective returns its input.
  The same proc runs correctly SPMD, serially, and under `lane.init(1)`
  (single-threaded mode, useful for debugging and platforms where you want
  the engine on one core — with a constant `1` most of it optimizes away).

## Distributing work

**`range` — static schedule.** Zero contention; the right default when items
cost roughly the same. `range` is an overload group: pass a length and get
index bounds, or pass a slice and get this lane's sub-slice plus its base
index (for writing to parallel arrays):

```odin
lo, hi := lane.range(len(items));           // index form
for i in lo ..< hi do process(&items[i]);
```

```odin
chunk, base := lane.range(items);           // slice form: chunk[j] is items[base + j]
for &item in chunk do process(&item);
```

**`grab` — dynamic schedule.** When per-item cost varies wildly (pathfinding
for 3 agents vs. 300), lanes pull chunks from a shared atomic cursor instead,
so fast lanes steal what slow lanes never reach. The cursor is shared state,
and shared state lives on the lane that originates it: declare it on the
main lane's stack, `share` its pointer, and close the phase with the sync
you would close it with anyway:

```odin
update_agents :: proc() {
    cursor := 0;
    cursor_ptr := lane.share(&cursor);   // everyone points at main's cursor

    for chunk in lane.grab(cursor_ptr, g_agents[:], 16) {
        for &agent in chunk do update_agent(&agent);
    }

    lane.sync();   // phase boundary: no lane moves on while others still grab
}
```

The trailing `sync` is the ordinary end of any phase that touches shared
state — it is also what keeps main's `cursor` alive until the last grab.
Without the `share`, every lane would spin its *own* cursor and process
everything. This degrades serially like everything else: one lane, `share`
returns the lane's own pointer, `sync` no-ops, and the loop just eats all
chunks.

Like `range`, `grab` is an overload group: pass a slice and get sub-slices
back, or pass a length and get index ranges. The slice form also yields the
chunk's base index, for writing to parallel arrays:

```odin
for lo, hi in lane.grab(&cursor, len(items), 16) { ... }
for chunk, lo in lane.grab(&cursor, items, 16) { ... }  // chunk[j] is items[lo + j]
```

Pick the chunk size so that a chunk is meaningful work (hundreds of cycles at
least); tiny chunks turn the cursor into a contention point.

**`owns` — dispatching tasks by number.** Where `range` and `grab` split a
loop, `lane.owns(n)` hands out whole tasks: it is true on exactly one lane,
the one that owns task `n` (`n % count()`). Number the tasks you know are
independent and dispatch them without caring how many lanes are actually
running — the modulo folds any task count onto any lane count, so the same
code works on 16 lanes, on 2, or serially (where the one lane owns every
task):

```odin
if lane.owns(0) do step_physics();
if lane.owns(1) do step_audio();
if lane.owns(2) do step_particles();   // folds onto lane 0 with 2 lanes
```

The task number doubles as a stable identity for managing per-task data.
`lane.is_main()` is the same test with the lane chosen for you — it picks
the main lane, for work that must run there like main-thread-only APIs
(equivalent to `lane.owns(0)`).

## Synchronizing: `sync`

`lane.sync()` is a barrier: no lane continues until all lanes arrive. Use it
to separate phases where one phase reads what another wrote:

```odin
simulate :: proc() {
    lo, hi := lane.range(len(g_bodies));

    for i in lo ..< hi do integrate(&g_bodies[i]);

    lane.sync(); // every body integrated before anyone reads neighbors

    for i in lo ..< hi do resolve_collisions(&g_bodies[i]);
}
```

The barrier is, by default, a sense-reversing futex barrier that spins
briefly before sleeping — when all lanes arrive close together (the normal
case for a per-frame gang), no lane enters the kernel, measured at ~41µs →
~1µs per 16-lane rendezvous compared to `core:sync.Barrier`. If you hit
problems, or the spin burns CPU you need elsewhere (heavily oversubscribed
machines, more lanes than cores), build with
`-define:LANE_FAST_BARRIER=false` to fall back to `core:sync.Barrier` —
behavior is identical either way, only the rendezvous cost changes.

**The one rule that cannot be checked for you:** every lane must reach every
`sync()` (and every collective, which synchronizes internally), in the same
order. A lane that skips a barrier the others hit deadlocks the split. Never
put collective ops behind a lane-dependent branch — compute the condition
with `any_of`/`all_of` first so all lanes agree on it.

## Moving data around

**`user_data`** carries one pointer into the split:

```odin
Frame_Ctx :: struct { dt: f32, input: ^Input };

frame :: proc(ctx: ^Frame_Ctx) {
    lane.split(tick, ctx);
}

tick :: proc() {
    ctx := lane.user_data(^Frame_Ctx);
    ...
}
```

**`broadcast`** copies one lane's local variable to all the others — for
values computed inside the split by a single lane:

```odin
tick :: proc() {
    cam: Camera;
    if lane.is_main() do cam = compute_camera(); // main polled the input
    lane.broadcast(&cam);                        // now every lane has it
    cull_with(cam);
}
```

The source defaults to `lane.MAIN`; passing another index broadcasts from
that lane. The index is validated like a slice index (see
[Failure contract](#failure-contract)).

**`share`** hands out a pointer instead of a copy: every lane receives the
same pointer into the *source lane's stack*, which becomes the single home
of a piece of mutable shared state — a `grab` cursor, a shared accumulator,
the header of a shared output list:

```odin
hits := 0;
hits_ptr := lane.share(&hits);   // one counter, living on main's stack
// ... lanes atomically add to hits_ptr^ ...
lane.sync();                     // close the phase before main's frame moves on
```

Because the pointee lives on the source lane's stack, it is only valid while
that frame stays put: close every phase that touches shared state with
`lane.sync()`, so no lane moves on (and no frame dies) while another is
still reading or writing.

Choosing between them: `broadcast` when every lane should own a snapshot
copy — the source can immediately reuse its variable, and lanes read their
own stacks from then on. `share` when all lanes should work on *one*
variable. Note that `share(&x)^` is **not** a substitute for
`broadcast(&x)`: the copy through the shared pointer happens after `share`
returns, so it races with the source mutating `x` — `broadcast` does the
copy inside its barriers, which is the entire point of it.

## Collectives

Collectives combine one value per lane and hand the result to **every** lane
(two barriers, no atomics). They fold in fixed lane order, so results are
deterministic and bitwise identical on all lanes — floats included, which is
what a lockstep simulation needs.

```odin
total_energy := lane.sum(local_energy);          // + works on vectors too
closest      := lane.minimum(local_closest);
farthest     := lane.maximum(local_farthest);
if lane.any_of(local_hit)   { ... }              // did anyone hit?
if lane.all_of(local_valid) { ... }              // is everyone valid?
```

**`any_of` / `all_of`** are the boolean reductions — OR and AND across the
lanes — but their real job is making a lane-dependent condition **uniform**:
after the call, every lane holds the same answer, so every lane takes the
same branch. That is exactly what the barrier rule demands. This deadlocks:

```odin
// WRONG: lanes that found nothing skip the sync the others are waiting at.
if local_dirty {
    rebuild_grid();
    lane.sync();
}
```

Reduce first, branch after — now the `if` is all-or-nothing, and the body
may freely contain syncs and collectives:

```odin
if lane.any_of(local_dirty) {   // one lane's dirt is everyone's problem
    rebuild_grid();
    lane.sync();
}
```

The same reasoning applies to loops: a lane may not leave a loop early if
the body contains collectives, so the exit condition must be collective too.
`all_of` at the bottom keeps the iteration count identical on every lane —
the canonical shape for iterating until convergence:

```odin
relax :: proc() {
    lo, hi := lane.range(len(g_constraints));
    for {
        max_err: f32 = 0;
        for i in lo ..< hi do max_err = max(max_err, solve_constraint(i));
        if lane.all_of(max_err < EPSILON) do break; // every lane exits together
    }
}
```

No separate `sync` is needed before the vote: like every collective,
`all_of` synchronizes internally, so it doubles as the phase boundary —
each iteration's writes land before any lane starts the next one.

Both follow the serial degradation rule: outside a split they return their
argument, so `any_of(hit)` is just `hit` and the code above stays correct
single-threaded.

Custom folds with `reduce` — e.g. fitting bounds for shadow cascades:

```odin
bounds := lane.reduce(local_bounds, proc "contextless" (a, b: AABB) -> AABB {
    return AABB { min = linalg.min(a.min, b.min), max = linalg.max(a.max, b.max) };
});
```

Or a per-tick state checksum for desync detection:

```odin
h := hash_bytes(my_slice_of_state);
tick_hash := lane.reduce(h, proc "contextless" (a, b: u64) -> u64 {
    return (a ~ b) * 0x9E3779B97F4A7C15;
});
```

**`scan`** is the exclusive prefix sum, and it is how you build compact
arrays in parallel with no atomics and a deterministic, stable order. Each
lane says how many items it wants to output; `scan` returns where to write
them and how big the final array is:

```odin
cull :: proc() {
    lo, hi := lane.range(len(g_objects));

    // Each lane has its own temp_allocator (see Rules), so this is a cheap,
    // race-free bump allocation, sized to this lane's exact worst case.
    visible_local := make([]int, hi - lo, context.temp_allocator);
    n := 0;
    for i in lo ..< hi {
        if in_frustum(g_objects[i]) {
            visible_local[n] = i;
            n += 1;
        }
    }

    offset, total := lane.scan(n);
    copy(g_visible[offset:][:n], visible_local[:n]);
    if lane.is_main() do g_visible_count = total;
}
```

The compaction is dense at both levels. Locally, `visible_local` is packed
by construction: the write cursor `n` only advances on hits, so culled
objects never leave holes (the buffer is sized `hi - lo` for the worst
case; only the first `n` slots are ever written or copied). Globally,
`scan` packs the lanes' dense chunks against each other: each lane's offset
is exactly the previous lane's offset plus its count, so every window ends
where the next begins, and `total` is the end of the last one. Because
lane ranges are ordered and each lane writes in index order, `g_visible`
comes out globally sorted and deterministic — the same input always yields
the identical packed array, unlike atomic-append compaction, where thread
timing scrambles the order.

One discipline comes with per-lane temp allocations: each lane owns its
arena, so each lane must also reset it — a plain `free_all` only resets the
calling thread's arena. Call `lane.free_all_temp_allocators()` once per
frame instead: it resets **every** lane's arena, main's included, so it
*replaces* the usual end-of-frame `free_all(context.temp_allocator)` rather
than adding to it. Outside a split it runs a minimal split under the hood;
inside one, each lane frees its own arena, so reach it on every lane like
any other collective — at the end of the frame's last lane proc, once no
lane can still hold another lane's temp pointers.

`scan` also has a generic form for custom ops, where `identity` is lane 0's
prefix: `prefix, total := lane.scan(value, identity, combine)`.

Collective values travel through cache-line-padded slots, so a value can be
at most `lane.MAX_COLLECTIVE_SIZE` (64) bytes — a `matrix[4, 4]f32` fits
exactly. Bigger types fail at compile time.

## Rules

1. **`init` first, `deinit` last.** The lane count is fixed in between.
2. **One split at a time**, no nesting, always from the thread that called
   `init`. All of these are asserted.
3. **Lanes run with the splitter's `context`**, so `context.allocator` must
   be thread-safe during a split (the default heap allocator is). Each lane
   keeps its *own* `temp_allocator` and `random_generator` — free per-lane
   scratch, but also the reason a value temp-allocated by one lane must not
   be freed by another, and why each lane must `free_all` its own arena —
   `lane.free_all_temp_allocators()` once per frame does it for all of them
   (see the culling example).
4. **Collectives are collective.** Every lane, every collective, same order
   (see [Synchronizing](#synchronizing-sync)).
5. Threads that are not lanes (e.g. a dedicated audio thread) may call any
   of the query/collective procs safely: they see the serial behavior. They
   may not call `split`.

## Failure contract

Misuse fails the way the rest of Odin fails, and the test suite
(`test.bat lane` from the project root) pins each of these down:

| Misuse | Result |
|---|---|
| `split`/`init` misuse (before init, twice, nested, concurrent), `deinit` inside a split | `assert` with a clear message; compiled out by `-disable-assert` |
| `broadcast` from an out-of-range lane index | Bounds-check error at the caller's line, like a slice index; compiled out by `-no-bounds-check` |
| A lane skips a `sync`/collective the others reach | Deadlock — inherent to barriers, cannot be checked cheaply |

Debug builds keep every check; the release target (`-disable-assert
-no-bounds-check`) strips them all.

## API summary

| Proc | Purpose |
|---|---|
| `init(thread_count := 0)` | Spawn the gang; `0` = logical core count, `-n` = all cores but `n`. |
| `deinit()` | Join and free the gang. |
| `split(p: Proc, user_data: rawptr = nil)` | Run `p` on every lane; returns when all finish. |
| `index()` / `count()` / `is_main()` | This lane's identity. Serial: `0` / `1` / `true`. |
| `capacity()` | Configured lane count, valid outside splits; for sizing per-lane storage. |
| `user_data()` / `user_data(^T)` | The split's user pointer, raw or cast. |
| `range(n or slice)` | This lane's static share: `(lo, hi)` bounds from a length, `(sub-slice, base index)` from a slice. |
| `grab(&cursor, n or slice, chunk_size)` | Dynamic chunking off a shared atomic cursor. |
| `owns(n)` | True on the one lane that owns task `n` (`n % count()`); dispatch independent tasks regardless of lane count. |
| `sync()` | Barrier across all lanes. |
| `free_all_temp_allocators()` | Reset every lane's temp arena, main's included — replaces the end-of-frame `free_all`. Once per frame, inside or outside a split. |
| `broadcast(&value, source := MAIN)` | Copy one lane's variable to all lanes (each gets a snapshot). |
| `share(&value, source := MAIN) -> ^T` | Pointer to the source lane's stack variable on every lane; pin it with `sync` per phase. |
| `sum` / `minimum` / `maximum` / `any_of` / `all_of` | Common reductions; result on every lane. |
| `reduce(value, combine)` | Custom reduction, deterministic left-fold in lane order. |
| `scan(value)` / `scan(value, identity, combine)` | Exclusive prefix sum/fold; returns `(offset/prefix, total)`. |
| `MAIN`, `Proc`, `MAX_COLLECTIVE_SIZE` | Lane 0's index; the split proc type; collective value size limit (bytes). |
