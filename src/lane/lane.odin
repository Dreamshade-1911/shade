/*
MIT License

Copyright (c) 2026 Fernando Nunes de Miranda

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
*/

// =========================================================================
//
// SPMD lanes over a fixed gang of persistent threads.
//
// The design is based on Ryan Fleury's "Multi-Core By Default" (Recommended read):
// https://www.dgtlgrove.com/p/multi-core-by-default
//
// lane.init spawns the worker threads once; they park on a futex between
// splits, so lane.split is cheap enough to call every frame. The calling
// thread always participates as lane.MAIN, so main-thread-only APIs
// (SDL events, etc.) can be used inside a split via `if lane.is_main()`
// (provided you called init from the main thread).
// Lane indices are fixed for the program's lifetime: worker i is always
// lane i, the splitter is always lane 0.
// Running lane.init(1) is valid and will run parallel code single-threaded,
// most code becomes no-op after an optimizer pass (provided that 1 is a
// compile-time constant).
//
// Rules:
// - One split at a time, always from the same thread that called lane.init.
// - Lanes run with the splitter's context; context.allocator must therefore
//   be thread-safe during a split. temp_allocator and random_generator stay
//   per-thread.
// - Collective ops (sync, broadcast, share, new_once, make_once and their
//   t- temp variants, reduce, sum, minimum, maximum, any_of, all_of, scan)
//   must be reached by every lane of the split, in the same order, or the
//   lanes desync.
//
// =========================================================================

package lane;

import "base:runtime";
import "core:os";
import csync "core:sync";
import "core:thread";


#assert(thread.IS_SUPPORTED, "Cannot run lanes when threads aren't supported");

Proc :: proc();

MAIN :: 0;

@(private) State :: struct {
    index:  int,
    active: bool,
}

// Collectives exchange one value per lane through padded, aligned scratch
// slots of MAX_COLLECTIVE_SIZE bytes (two banks, see the collectives): one
// cache line of the target by default 64 (a matrix[4, 4]f32 fits exactly),
// 128 on Apple Silicon.
// Override it in bytes with -define:LANE_MAX_COLLECTIVE_SIZE, for a line
// size the default doesn't know (32 on many embedded parts) or simply to
// fit a fatter value type. It must be a power of two because it is also
// the slot alignment, which is what keeps different lanes' slots on
// separate lines. For payloads much bigger than a line, don't copy through
// slots at all: put the data on one lane and share/new_once a pointer.
MAX_COLLECTIVE_SIZE :: #config(LANE_MAX_COLLECTIVE_SIZE, 128 when ODIN_ARCH == .arm64 && ODIN_OS == .Darwin else 64);
#assert(MAX_COLLECTIVE_SIZE > 0 && (MAX_COLLECTIVE_SIZE & (MAX_COLLECTIVE_SIZE - 1)) == 0,
    "LANE_MAX_COLLECTIVE_SIZE must be a positive power of two (it doubles as the slot alignment).");

@(private) Slot :: struct #align(MAX_COLLECTIVE_SIZE) {
    data: [MAX_COLLECTIVE_SIZE]u8,
}

@(private) _threads:      []^thread.Thread;
@(private) _scratch:      []Slot;       // Two banks of _count slots (see the collectives).
@(private) _count:        int = 1;
@(private) _split_proc:   Proc;
@(private) _split_data:   rawptr;
@(private) _split_ctx:    runtime.Context;
@(private) _broadcast:    rawptr;
@(private) _pending:      csync.Futex;  // Workers still inside the current split.
@(private) _join_waiting: csync.Futex;  // 1 while the splitter is parked on _pending.
@(private) _go:           csync.Futex;  // Generation counter, bumped once per split (and once on deinit).
@(private) _live:         bool;
@(private) _splitting:    bool;
@(private, thread_local) _state: State;
@(private, thread_local) _collective_gen: uint; // Collectives reached this split; picks the scratch bank.

// Spin iterations before sleeping in the kernel (barrier and split join).
@(private) _SPIN :: 2000;

// The default barrier is a sense-reversing futex barrier that spins briefly
// before sleeping: when all lanes arrive close together (the normal case
// for a per-frame gang), no lane ever enters the kernel, measured
// ~41us -> ~1us per 16-lane rendezvous vs core:sync's mutex+condvar
// barrier. Build with -define:LANE_FAST_BARRIER=false to fall back to
// core:sync.Barrier if you hit problems or the spinning burns CPU you need
// elsewhere (e.g. heavily oversubscribed machines).
LANE_FAST_BARRIER :: #config(LANE_FAST_BARRIER, true);

when LANE_FAST_BARRIER {
    @(private) _bar_gen:      csync.Futex; // Generation counter (the sense).
    @(private) _bar_count:    csync.Futex; // Arrivals in the current generation.
    @(private) _bar_sleepers: csync.Futex; // Lanes parked in the kernel on _bar_gen.

    @(private)
    _barrier_init :: proc "contextless" (count: int) {
        _bar_gen      = 0;
        _bar_count    = 0;
        _bar_sleepers = 0;
    }

    @(private)
    _barrier :: proc "contextless" () {
        gen := u32(csync.atomic_load_explicit(&_bar_gen, .Acquire));
        if int(csync.atomic_add_explicit(&_bar_count, 1, .Acq_Rel)) == _count - 1 {
            // Last to arrive: reset BEFORE bumping the generation, so a
            // lane re-entering the next barrier can only increment after
            // the reset. The bump stays seq_cst: the sleeper check below
            // relies on it.
            csync.atomic_store_explicit(&_bar_count, 0, .Release);
            csync.atomic_add(&_bar_gen, 1);

            // Skip the kernel wake when nobody is parked. Safe: a sleeper
            // bumps _bar_sleepers before futex_wait re-validates _bar_gen,
            // so either we see it here or it sees the new generation and
            // never sleeps.
            if csync.atomic_load(&_bar_sleepers) != 0 {
                csync.futex_broadcast(&_bar_gen);
            }
        } else {
            spun := 0;
            for u32(csync.atomic_load_explicit(&_bar_gen, .Acquire)) == gen {
                if spun < _SPIN {
                    csync.cpu_relax();
                    spun += 1;
                } else {
                    csync.atomic_add(&_bar_sleepers, 1);
                    csync.futex_wait(&_bar_gen, gen);
                    csync.atomic_sub_explicit(&_bar_sleepers, 1, .Relaxed);
                }
            }
        }
    }
} else {
    @(private) _bar: csync.Barrier;

    @(private)
    _barrier_init :: proc "contextless" (count: int) {
        csync.barrier_init(&_bar, count);
    }

    @(private)
    _barrier :: proc "contextless" () {
        csync.barrier_wait(&_bar);
    }
}


// thread_count is the total number of lanes, including the calling thread.
// Non-positive values are relative to the logical core count: 0 means one
// lane per core, -n means all cores but n (for leaving cores free for
// dedicated threads). Always clamped to at least 1 lane.
init :: proc(thread_count := 0) {
    assert(!_live, "lane.init called twice.");
    lc := thread_count;
    if lc <= 0 do lc += os.get_processor_core_count();
    lc = max(lc, 1);

    _count = lc;
    _go = 0;
    _live = true;
    _barrier_init(lc);
    _scratch = make([]Slot, 2 * lc);   // two banks (see the collectives)

    _threads = make([]^thread.Thread, lc - 1);
    for i in 0 ..< lc - 1 {
        t := thread.create(_worker);
        t.user_index = i + 1;
        _threads[i] = t;
        thread.start(t);
    }
}

deinit :: proc() {
    assert(!_state.active, "lane.deinit called inside a split.");
    csync.atomic_store(&_live, false);
    csync.atomic_add(&_go, 1);
    csync.futex_broadcast(&_go);
    for t in _threads {
        thread.join(t);
        thread.destroy(t);
    }
    delete(_threads);
    delete(_scratch);
    _threads = nil;
    _scratch = nil;
    _count = 1;
}

// Runs lane_proc on every lane; the caller participates as lane MAIN.
// Returns once all lanes have finished.
split :: proc(lane_proc: Proc, user_data: rawptr = nil) {
    assert(_live, "lane.split called before lane.init.");
    assert(!_state.active, "lane.split cannot be nested inside a running split.");
    assert(!csync.atomic_exchange(&_splitting, true), "Concurrent lane.split from multiple threads.");

    _split_proc = lane_proc;
    _split_data = user_data;
    _split_ctx  = context;
    csync.atomic_store_explicit(&_pending, csync.Futex(_count - 1), .Relaxed);
    csync.atomic_add(&_go, 1); // Publishes the globals above: workers acquire _go before reading them.
    csync.futex_broadcast(&_go);

    _collective_gen = 0;
    _state.active = true;
    lane_proc();
    _state.active = false;

    _join();
    csync.atomic_store(&_splitting, false);
}

// Waits for this split's workers. Spin first: they usually finish within
// nanoseconds of the splitter, so parking just to be woken right away would
// cost a wake round-trip per split. Same sleep handshake as the barrier:
// raise _join_waiting, then futex_wait re-validates _pending.
@(private)
_join :: proc "contextless" () {
    spun := 0;
    for {
        p := csync.atomic_load_explicit(&_pending, .Acquire);
        if p == 0 do break;
        if spun < _SPIN {
            csync.cpu_relax();
            spun += 1;
        } else {
            csync.atomic_store(&_join_waiting, 1);
            csync.futex_wait(&_pending, u32(p));
        }
    }
    csync.atomic_store_explicit(&_join_waiting, 0, .Relaxed);
}

// Frees every lane's temp allocator arena, the main thread's included:
// one call per frame replaces the usual end-of-frame
// free_all(context.temp_allocator), which would only reset the calling
// thread's arena.
// Outside a split it runs a minimal split under the hood; inside a split
// it frees the calling lane's arena, so reach it on every lane like any
// collective (typically at the end of the frame's last lane proc, after
// no lane can still hold another lane's temp pointers).
free_all_temp_allocators :: proc() {
    if _state.active {
        free_all(context.temp_allocator);
    } else {
        split(proc() { free_all(context.temp_allocator); });
    }
}

@(private)
_worker :: proc(t: ^thread.Thread) {
    _state.index = t.user_index;
    gen: u32 = 0;
    for {
        csync.futex_wait(&_go, gen);
        g := u32(csync.atomic_load_explicit(&_go, .Acquire));
        if g == gen do continue; // Spurious wakeup.
        gen = g;
        if !csync.atomic_load(&_live) do break;

        // Adopt the splitter's context, but keep this thread's own
        // thread-local pieces: sharing them across lanes would race.
        ctx := _split_ctx;
        ctx.temp_allocator    = context.temp_allocator;
        ctx.random_generator  = context.random_generator;
        context = ctx;

        _collective_gen = 0;
        _state.active = true;
        _split_proc();
        _state.active = false;

        // Last worker out signals the splitter, but only if it is parked.
        if csync.atomic_sub(&_pending, 1) == 1 {
            if csync.atomic_load(&_join_waiting) != 0 {
                csync.futex_signal(&_pending);
            }
        }
    }
}

index     :: #force_inline proc "contextless" () -> int  { return _state.index }
count     :: #force_inline proc "contextless" () -> int  { return _count if _state.active else 1 }
is_main   :: #force_inline proc "contextless" () -> bool { return _state.index == MAIN }

// Total lane count as configured at init, valid outside splits too.
// Use this to size per-lane storage before splitting.
capacity :: #force_inline proc "contextless" () -> int  { return _count }

user_data     :: proc { user_data_raw, user_data_t }
user_data_raw :: #force_inline proc "contextless" ()           -> rawptr { return _split_data }
user_data_t   :: #force_inline proc "contextless" ($T: typeid) -> T      { return cast(T)_split_data }

// Waits for all lanes to reach the same point before proceeding.
// No-op outside a split, so SPMD code degrades to correct serial code.
sync :: #force_inline proc "contextless" () {
    if !_state.active do return;
    _barrier();
}

// Copies a variable on the stack of a source lane to the other lanes.
// No-op outside a split (the early return also keeps non-lane threads from
// touching _broadcast while a split is mid-flight).
// source_lane is a lane index, bounds-checked against the lane count
// (compiled out with -no-bounds-check). For task-numbered dispatch, fold
// the task onto a lane yourself with task_index, once on entry.
broadcast :: proc "contextless" (p: ^$T, source_lane := MAIN, loc := #caller_location) {
    runtime.bounds_check_error_loc(loc, source_lane, _count);
    if !_state.active do return;
    when size_of(T) <= MAX_COLLECTIVE_SIZE {
        // The value rides through the source lane's scratch slot: one
        // barrier, and the source is free to move on immediately.
        bank := _next_bank();
        if _state.index == source_lane do _slot(T, source_lane, bank)^ = p^;
        sync();
        if _state.index != source_lane do p^ = _slot(T, source_lane, bank)^;
    } else {
        // Too big for a slot: copy straight from the source lane's frame.
        // The trailing sync keeps the source from moving on (and mutating
        // or popping the pointee) while another lane is still copying.
        if _state.index == source_lane do _broadcast = rawptr(p);
        sync();
        if _state.index != source_lane do p^ = (cast(^T)_broadcast)^;
        sync();
    }
}

// Shares a pointer to a variable living on the source lane's stack with
// all lanes. Unlike broadcast, nothing is copied: every lane receives the
// same pointer into the source lane's frame, which becomes the single home
// of mutable shared state (a grab cursor, a shared accumulator). Because
// the pointee lives on the source lane's stack, it is only valid while that
// frame stays put: close every phase that touches it with lane.sync(), so
// no lane moves on while another still uses it. Use broadcast instead when
// each lane should own a snapshot copy.
// source_lane follows broadcast's lane-index contract.
// Outside a split, returns p unchanged.
share :: proc "contextless" (p: ^$T, source_lane := MAIN, loc := #caller_location) -> ^T {
    q := p;
    broadcast(&q, source_lane, loc);
    return q;
}

// new on one lane, everyone gets the pointer: lane source_lane allocates a
// T and broadcasts the pointer, so all lanes alias one heap value. The
// allocation uses the source lane's allocator argument
// (context.allocator by default), free it with that allocator, on one
// lane, after a sync. The error contract is new's own (ignorable via
// #optional_allocator_error), with one addition: the error is broadcast
// with the pointer, so every lane returns the same one and a failure
// branch is all-or-nothing, free to contain collectives.
// Outside a split this is plain new.
new_once :: proc($T: typeid, source_lane := MAIN, allocator := context.allocator, loc := #caller_location) -> (^T, runtime.Allocator_Error) #optional_allocator_error {
    r: struct { p: ^T, err: runtime.Allocator_Error };
    if index() == source_lane do r.p, r.err = new(T, allocator, loc);
    broadcast(&r, source_lane, loc);
    return r.p, r.err;
}

// new_once on the source lane's temp arena: shared frame scratch with
// nothing to free, the end-of-frame free_all_temp_allocators reclaims it.
tnew_once :: #force_inline proc($T: typeid, source_lane := MAIN, loc := #caller_location) -> (^T, runtime.Allocator_Error) #optional_allocator_error {
    return new_once(T, source_lane, context.temp_allocator, loc);
}

// make on one lane, everyone gets the slice: for shared storage whose size
// is only known mid-split (compaction outputs, per-frame visible lists).
// Frame-scoped scratch usually wants tmake_once below; with a persistent
// allocator, delete the slice like new_once's pointer. Only the slice
// form of make is provided, deliberately: growable containers (map,
// [dynamic]) cannot be safely grown from several lanes, so sharing one is
// not a pattern worth sugaring. The error contract is new_once's: make's
// own, but broadcast, so every lane returns the same error.
// Outside a split this is plain make.
make_once :: proc($T: typeid/[]$E, #any_int len: int, source_lane := MAIN, allocator := context.allocator, loc := #caller_location) -> (T, runtime.Allocator_Error) #optional_allocator_error {
    r: struct { s: T, err: runtime.Allocator_Error };
    if index() == source_lane do r.s, r.err = make(T, len, allocator, loc);
    broadcast(&r, source_lane, loc);
    return r.s, r.err;
}

// make_once on the source lane's temp arena: the shape of most mid-split
// scratch (sized this frame, dead by the next), so the common case reads
//     visible := lane.tmake_once([]int, total);
// with free_all_temp_allocators reclaiming it at end of frame.
tmake_once :: #force_inline proc($T: typeid/[]$E, #any_int len: int, source_lane := MAIN, loc := #caller_location) -> (T, runtime.Allocator_Error) #optional_allocator_error {
    return make_once(T, len, source_lane, context.temp_allocator, loc);
}

// Collectives: combine one value per lane, returning the result to every
// lane (one barrier). All of them fold in fixed lane order, so results are
// deterministic and bitwise identical on all lanes. Outside a split they
// degrade to their serial meaning (the value itself / empty prefix).
//
// The scratch is double-buffered: consecutive collectives use alternating
// banks, so no trailing barrier is needed. A bank is only reused after the
// next collective's barrier, by which point every fold of it has finished.
// The per-lane bank counter resets each split and stays uniform because all
// lanes reach the same collectives in the same order.

@(private)
_next_bank :: #force_inline proc "contextless" () -> int {
    bank := int(_collective_gen & 1);
    _collective_gen += 1;
    return bank;
}

@(private)
_slot :: #force_inline proc "contextless" ($T: typeid, i, bank: int) -> ^T {
    return cast(^T)&_scratch[bank * _count + i].data;
}

// Combines one value per lane with a custom op, e.g.:
//     bounds := lane.reduce(local_bounds, proc "contextless" (a, b: AABB) -> AABB { return aabb_union(a, b); });
reduce :: proc "contextless" (value: $T, combine: proc "contextless" (a, b: T) -> T) -> T
    where size_of(T) <= MAX_COLLECTIVE_SIZE {
    if !_state.active do return value;
    bank := _next_bank();
    _slot(T, _state.index, bank)^ = value;
    sync();
    acc := _slot(T, 0, bank)^;
    for i in 1 ..< _count do acc = combine(acc, _slot(T, i, bank)^);
    return acc;
}

// Sum of one value per lane. Works on anything with +, including vectors.
sum :: proc "contextless" (value: $T) -> T where size_of(T) <= MAX_COLLECTIVE_SIZE {
    if !_state.active do return value;
    bank := _next_bank();
    _slot(T, _state.index, bank)^ = value;
    sync();
    acc := _slot(T, 0, bank)^;
    for i in 1 ..< _count do acc += _slot(T, i, bank)^;
    return acc;
}

minimum :: proc "contextless" (value: $T) -> T where size_of(T) <= MAX_COLLECTIVE_SIZE {
    if !_state.active do return value;
    bank := _next_bank();
    _slot(T, _state.index, bank)^ = value;
    sync();
    acc := _slot(T, 0, bank)^;
    for i in 1 ..< _count do acc = min(acc, _slot(T, i, bank)^);
    return acc;
}

maximum :: proc "contextless" (value: $T) -> T where size_of(T) <= MAX_COLLECTIVE_SIZE {
    if !_state.active do return value;
    bank := _next_bank();
    _slot(T, _state.index, bank)^ = value;
    sync();
    acc := _slot(T, 0, bank)^;
    for i in 1 ..< _count do acc = max(acc, _slot(T, i, bank)^);
    return acc;
}

// True if the value is true on any lane (any_of) / on all lanes (all_of).
// Beyond the reduction itself, these make a lane-dependent condition
// uniform, every lane gets the same answer, so every lane takes the same
// branch. Required whenever a branch or loop exit guards collectives, which
// every lane must reach:
//     if lane.any_of(local_dirty) {           // all-or-nothing branch
//         rebuild_grid();
//         lane.sync();                        // safe: no lane skipped the if
//     }
//     for {                                   // iterate until convergence
//         err := relax_my_share();
//         if lane.all_of(err < EPSILON) do break; // all lanes exit together
//     }
// Outside a split they return the value unchanged.
any_of :: proc "contextless" (value: bool) -> bool {
    if !_state.active do return value;
    bank := _next_bank();
    _slot(bool, _state.index, bank)^ = value;
    sync();
    acc := _slot(bool, 0, bank)^;
    for i in 1 ..< _count do acc ||= _slot(bool, i, bank)^;
    return acc;
}

all_of :: proc "contextless" (value: bool) -> bool {
    if !_state.active do return value;
    bank := _next_bank();
    _slot(bool, _state.index, bank)^ = value;
    sync();
    acc := _slot(bool, 0, bank)^;
    for i in 1 ..< _count do acc &&= _slot(bool, i, bank)^;
    return acc;
}

scan :: proc { scan_sum, scan_custom }

// Exclusive prefix sum: offset is the sum of the lower-indexed lanes'
// values (zero for lane 0), total is the sum across all lanes. The classic
// use is compaction: pass the number of items this lane wants to output,
// write them at offset, and total is the final size:
//     n_visible := cull(chunk);
//     offset, total := lane.scan(n_visible);
//     copy(visible[offset:][:n_visible], chunk_results);
scan_sum :: proc "contextless" (value: $T) -> (offset, total: T)
    where size_of(T) <= MAX_COLLECTIVE_SIZE {
    if !_state.active { total = value; return; }
    bank := _next_bank();
    _slot(T, _state.index, bank)^ = value;
    sync();
    for i in 0 ..< _count {
        v := _slot(T, i, bank)^;
        if i < _state.index do offset += v;
        total += v;
    }
    return;
}

// Exclusive prefix fold with a custom op; identity is what lane 0 gets as
// its prefix (and the fold's starting value).
scan_custom :: proc "contextless" (value: $T, identity: T, combine: proc "contextless" (a, b: T) -> T) -> (prefix, total: T)
    where size_of(T) <= MAX_COLLECTIVE_SIZE {
    if !_state.active { prefix = identity; total = value; return; }
    bank := _next_bank();
    _slot(T, _state.index, bank)^ = value;
    sync();
    prefix = identity;
    total  = identity;
    for i in 0 ..< _count {
        v := _slot(T, i, bank)^;
        if i < _state.index do prefix = combine(prefix, v);
        total = combine(total, v);
    }
    return;
}

// The lane that task n folds onto: n % count(). For dispatching independent
// tasks by number without caring how many lanes are actually running, the
// modulo folds any task count onto any lane count, so the same dispatch
// code works on 16 lanes, on 2, or serially (where lane 0 gets every task):
//     me := lane.index();
//     if me == lane.task_index(0) do step_physics();
//     if me == lane.task_index(1) do step_audio();
//     if me == lane.task_index(2) do step_particles();   // lane 0 with 2 lanes
// The task number doubles as a stable identity for managing per-task data.
// Collectives with a source_lane parameter (broadcast, share, new_once,
// make_once) take a plain lane index; pass task_index(n) to publish from
// whoever gets task n.
task_index :: #force_inline proc "contextless" (n: int) -> int {
    return n % count();
}

// Splits n into ranges of values to be operated onto by the current lane.
// e.g.: 4 lanes, n = 11:
// lane 0: lo = 0, hi = 3
// lane 1: lo = 3, hi = 6
// lane 2: lo = 6, hi = 9
// lane 3: lo = 9, hi = 11
// An overload group: pass a length and get index bounds, or pass a slice
// and get this lane's sub-slice plus its base index:
//     lo, hi := lane.range(len(items));
//     chunk, base := lane.range(items);   // chunk[j] is items[base + j]
range :: proc { range_index, range_slice }

range_index :: proc "contextless" (n: int) -> (lo, hi: int) {
    idx, cnt := index(), count();
    per := n / cnt;
    rem := n % cnt;
    lo = idx * per + min(idx, rem);
    hi = lo + per + (1 if idx < rem else 0);
    return;
}

range_slice :: proc "contextless" (s: []$T) -> (chunk: []T, lo: int) {
    l, h := range_index(len(s));
    return s[l:h], l;
}

// Grabs the next chunk of at most chunk_size values from a shared cursor,
// for dynamically scheduling work with uneven per-item cost (range's static
// schedule is better when costs are uniform: no contention on a cursor).
// The cursor is shared state: it lives on the main lane's stack, shared
// through lane.share, and the phase ends with the sync it would end with
// anyway (which also keeps main's frame alive until the last grab):
//     cursor := 0;
//     cursor_ptr := lane.share(&cursor);
//     for chunk in lane.grab(cursor_ptr, items, 16) {
//         for &item in chunk do process(&item);
//     }
//     lane.sync();
// Without the share every lane would spin its own cursor and process
// everything. Like range, an overload group (index form, and slice form
// with the chunk's base index):
//     for lo, hi in lane.grab(cursor_ptr, len(items), 16) { ... }
//     for chunk, lo in lane.grab(cursor_ptr, items, 16) { ... } // chunk[j] is items[lo + j]
grab :: proc { grab_index, grab_slice }

grab_index :: proc "contextless" (cursor: ^int, n: int, chunk_size: int) -> (lo, hi: int, ok: bool) {
    assert_contextless(chunk_size > 0, "lane.grab chunk_size must be positive.");
    lo = csync.atomic_add(cursor, chunk_size);
    if lo >= n do return 0, 0, false;
    hi = min(lo + chunk_size, n);
    return lo, hi, true;
}

grab_slice :: proc "contextless" (cursor: ^int, s: []$T, chunk_size: int) -> (chunk: []T, lo: int, ok: bool) {
    l, h, k := grab_index(cursor, len(s), chunk_size);
    if !k do return nil, 0, false;
    return s[l:h], l, true;
}
