package main;

import "base:runtime";
import "core:fmt";
import "core:os";
import "core:sync";
import "core:thread";
import "core:time";

import "src:lane";

N :: 100_000;
EXPECTED_SUM :: N * (N - 1) / 2;

_data:  [N]int;
_total: int;

Expect :: enum {
    Ok,   // Child must exit 0.
    Die,  // Child must die (assert or crash).
    Hang, // Child must deadlock; parent kills it after the timeout.
    Gap,  // Misuse we currently do NOT catch: child exits 0. Documents a known hole.
};

Case :: struct {
    name:   string,
    expect: Expect,
    note:   string,
};

CASES :: []Case {
    { "smoke",             .Ok,   "normal use: 200 splits, re-init, 1-lane mode, serial fallback" },
    { "grab",              .Ok,   "dynamic chunking: every index covered exactly once, ragged chunks, n=0, serial use" },
    { "task_lane",         .Ok,   "task dispatch: every task folds onto exactly one lane, n % count, serial fallback" },
    { "once",              .Ok,   "new_once/make_once and t- variants: one allocation aliased by all lanes, task-numbered source, uniform allocation error, serial fallback" },
    { "collectives",       .Ok,   "reduce/sum/minimum/maximum/any_of/all_of/scan: fold order, vectors, compaction, serial degrade" },
    { "nested_split",      .Die,  "lane.split from inside a split (main lane)" },
    { "worker_split",      .Die,  "lane.split from inside a split (worker lane)" },
    { "concurrent_split",  .Die,  "lane.split from an unrelated thread while a split is running" },
    { "sync_outside",      .Ok,   "lane.sync/broadcast outside a split: safe no-ops that don't poison the barrier" },
    { "deinit_inside",     .Die,  "lane.deinit from inside a split" },
    { "double_init",       .Die,  "lane.init called twice" },
    { "double_init_1lane", .Die,  "lane.init(1) called twice (0-len _threads slice used to dodge the old guard)" },
    { "split_before_init", .Die,  "lane.split before lane.init" },
    { "divergent_sync",    .Hang, "one lane skips a lane.sync: barrier deadlock, inherent to barrier misuse" },
    { "broadcast_bad_src", .Die,  "broadcast with an out-of-range source lane index: bounds-checked" },
};

CHILD_TIMEOUT :: 3 * time.Second;


main :: proc() {
    if len(os.args) >= 2 {
        run_case(os.args[1]);
        return;
    }

    exe := os.args[0];
    failed := 0;
    for c in CASES {
        fmt.printfln("--- %s [expect %v]: %s", c.name, c.expect, c.note);

        p, spawn_err := os.process_start({
            command = { exe, c.name },
            stdout  = os.stdout,
            stderr  = os.stderr,
        });
        if spawn_err != nil {
            fmt.printfln("    FAIL: could not spawn child: %v", spawn_err);
            failed += 1;
            continue;
        }

        state, _ := os.process_wait(p, CHILD_TIMEOUT);
        hung := !state.exited;
        if hung do _ = os.process_kill(p);

        ok: bool;
        switch c.expect {
        case .Ok:   ok = !hung && state.exit_code == 0;
        case .Die:  ok = !hung && state.exit_code != 0;
        case .Hang: ok = hung;
        case .Gap:  ok = !hung && state.exit_code == 0;
        }

        if ok {
            if c.expect == .Gap {
                fmt.printfln("    KNOWN GAP: misuse ran without being caught (see note above).");
            } else {
                fmt.printfln("    PASS");
            }
        } else {
            if c.expect == .Gap && !hung && state.exit_code != 0 {
                fmt.printfln("    NOW CAUGHT: gap appears fixed, promote this case to .Die.");
            } else {
                how := "hung (killed)" if hung else fmt.tprintf("exited with code %v", state.exit_code);
                fmt.printfln("    FAIL: child %s", how);
                failed += 1;
            }
        }
    }

    fmt.printfln("");
    if failed > 0 {
        fmt.printfln("%v case(s) FAILED.", failed);
        os.exit(1);
    }
    fmt.printfln("All cases behaved as expected.");
}

run_case :: proc(name: string) {
    switch name {
    case "smoke":             case_smoke();
    case "grab":              case_grab();
    case "task_lane":         case_task_lane();
    case "once":              case_once();
    case "collectives":       case_collectives();
    case "nested_split":      case_nested_split();
    case "worker_split":      case_worker_split();
    case "concurrent_split":  case_concurrent_split();
    case "sync_outside":      case_sync_outside();
    case "deinit_inside":     case_deinit_inside();
    case "double_init":       case_double_init();
    case "double_init_1lane": case_double_init_1lane();
    case "split_before_init": case_split_before_init();
    case "divergent_sync":    case_divergent_sync();
    case "broadcast_bad_src": case_broadcast_bad_src();
    case:
        fmt.printfln("unknown case: %s", name);
        os.exit(2);
    }
}


// ---------------------------------------------------------------- positive

task_lane_work :: proc() {
    // Each task folds onto one lane, so these writes don't race.
    me := lane.index();
    for i in 0 ..< N {
        if lane.is_task_lane(i) {
            assert(me == i % lane.count(), "is_task_lane picked the wrong lane");
            _seen[i] += 1;
        }
    }
    // Task 0 folds onto lane 0, so its test matches is_main.
    assert(lane.is_task_lane(0) == lane.is_main(), "is_task_lane(0) must match is_main");
}

case_task_lane :: proc() {
    lane.init(4);

    // Every task handled exactly once, by lane i % count.
    for i in 0 ..< N do _seen[i] = 0;
    lane.split(task_lane_work);
    for i in 0 ..< N do assert(_seen[i] == 1, "task unhandled or handled twice");

    lane.deinit();

    // Serial fallback: every task folds onto lane 0.
    for i in 0 ..< N do assert(lane.task_lane(i) == 0, "serial task_lane must fold onto lane 0");
}

once_work :: proc() {
    // Everyone aliases one heap int, allocated on main.
    p := lane.new_once(int);
    if lane.is_main() do p^ = 123;
    lane.sync();
    assert(p^ == 123, "new_once pointer not shared");

    // Task-numbered source, folded by the caller: task 7 is lane 3 of 4.
    src := lane.task_lane(7);
    q := lane.new_once(int, src);
    if lane.index() == src do q^ = 7;
    lane.sync();
    assert(q^ == 7, "new_once task-numbered source wrong");

    // Shared slice: every lane writes its share, then reads all of it.
    s := lane.make_once([]int, N);
    lo, hi := lane.range(len(s));
    for i in lo ..< hi do s[i] = i;
    lane.sync();
    for i in 0 ..< len(s) do assert(s[i] == i, "make_once slice not shared");

    lane.sync(); // No lane may still be reading when main frees.
    if lane.is_main() {
        free(p);
        free(q);
        delete(s);
    }

    // Temp variants: same sharing, on the source lane's temp arena.
    tp := lane.tnew_once(int, 2);
    if lane.index() == 2 do tp^ = 55;
    lane.sync();
    assert(tp^ == 55, "tnew_once pointer not shared");
    ts := lane.tmake_once([]int, 4);
    if lane.is_main() do ts[0] = 1;
    lane.sync();
    assert(ts[0] == 1, "tmake_once slice not shared");
    lane.sync(); // No lane may still read temp memory once arenas reset.
    lane.free_all_temp_allocators();

    // The allocation error is broadcast with the result: even though only
    // the owning lane called the allocator, every lane returns the same
    // error, so the failure branch is all-or-nothing (only the source lane
    // called the allocator).
    oom := runtime.Allocator { procedure = failing_allocator_proc };
    bad, err := lane.new_once(int, allocator = oom);
    assert(bad == nil && err == .Out_Of_Memory, "new_once must broadcast the allocation error");
    sbad, serr := lane.make_once([]int, 8, allocator = oom);
    assert(sbad == nil && serr == .Out_Of_Memory, "make_once must broadcast the allocation error");
}

failing_allocator_proc :: proc(allocator_data: rawptr, mode: runtime.Allocator_Mode,
                               size, alignment: int,
                               old_memory: rawptr, old_size: int, loc := #caller_location) -> ([]byte, runtime.Allocator_Error) {
    return nil, .Out_Of_Memory;
}

case_once :: proc() {
    lane.init(4);
    lane.split(once_work);
    lane.deinit();

    // Serial fallback: plain new/make. Task numbers must be folded by the
    // caller; task_lane(5) is lane 0 when serial.
    p := lane.new_once(int, lane.task_lane(5));
    p^ = 5;
    assert(p^ == 5, "serial new_once broken");
    free(p);
    s := lane.make_once([]int, 8);
    assert(len(s) == 8, "serial make_once broken");
    delete(s);
}

sum_work :: proc() {
    lo, hi := lane.range(N);
    s := 0;
    for i in lo ..< hi do s += _data[i];

    // Slice overload must agree with the index form.
    chunk, base := lane.range(_data[:]);
    assert(base == lo && len(chunk) == hi - lo, "range slice form disagrees with index form");
    assert(hi == lo || &chunk[0] == &_data[lo], "range slice chunk misaligned with base index");

    total := lane.sum(s);
    assert(total == EXPECTED_SUM, "lane.sum wrong on some lane");
    if lane.is_main() do _total = total;

    // Broadcast a stack variable from main to everyone and check it.
    magic := 0;
    if lane.is_main() do magic = 12345;
    lane.broadcast(&magic);
    assert(magic == 12345, "broadcast failed");

    // Check user_data plumbing.
    assert(lane.user_data(^int)^ == 777, "user_data failed");
}

fill_data :: proc() {
    for i in 0 ..< N do _data[i] = i;
}

temp_alloc_work :: proc() {
    scratch := make([]int, 1024, context.temp_allocator);
    for &v, i in scratch do v = lane.index() + i;
    assert(scratch[1] == lane.index() + 1, "temp allocation corrupt");

    // In-split form: every lane frees its own arena, then allocates again.
    lane.free_all_temp_allocators();
    scratch2 := make([]int, 64, context.temp_allocator);
    scratch2[0] = lane.index();
    assert(scratch2[0] == lane.index(), "temp allocation after in-split reset corrupt");
}

case_smoke :: proc() {
    fill_data();
    tag := 777;

    lane.init();
    assert(lane.count() == 1 && lane.index() == 0, "bad state outside split");
    for _ in 0 ..< 200 {
        _total = 0;
        lane.split(sum_work, &tag);
        assert(_total == EXPECTED_SUM, "wrong sum");
    }

    // Per-lane temp allocations, reset across all lanes, then reused.
    lane.split(temp_alloc_work);
    lane.free_all_temp_allocators();
    lane.split(temp_alloc_work);

    lane.deinit();

    // Re-init with an explicit count.
    lane.init(3);
    _total = 0;
    lane.split(sum_work, &tag);
    assert(_total == EXPECTED_SUM, "wrong sum after re-init");
    lane.deinit();

    // Single-threaded mode must run serially without blocking.
    lane.init(1);
    _total = 0;
    lane.split(sum_work, &tag);
    assert(_total == EXPECTED_SUM, "wrong sum single-threaded");
    lane.deinit();

    // Serial fallback: lane.range outside a split covers everything.
    lo, hi := lane.range(N);
    assert(lo == 0 && hi == N, "serial fallback failed");
    chunk, base := lane.range(_data[:]);
    assert(base == 0 && len(chunk) == N, "serial slice fallback failed");
}


_seen:    [N]u8;
_compact: [64]int;

collectives_work :: proc() {
    idx, cnt := lane.index(), lane.count();
    assert(cnt == 4, "test assumes 4 lanes");

    assert(lane.sum(idx + 1) == 10,        "sum wrong");
    assert(lane.minimum(idx + 10) == 10,   "minimum wrong");
    assert(lane.maximum(idx + 10) == 13,   "maximum wrong");
    assert(lane.any_of(idx == 3),          "any_of wrong");
    assert(!lane.any_of(false),            "any_of(false) wrong");
    assert(lane.all_of(idx >= 0),          "all_of wrong");
    assert(!lane.all_of(idx != 1),         "all_of partial wrong");

    // Non-commutative combine: only the deterministic left-fold in lane
    // order 0,1,2,3 yields ((0*10+1)*10+2)*10+3 = 123.
    r := lane.reduce(idx, proc "contextless" (a, b: int) -> int { return a * 10 + b; });
    assert(r == 123, "reduce fold order wrong");

    // Array programming: sum of vectors, component-wise.
    v := lane.sum([4]f32{ f32(idx), 1, 0, 2 });
    assert(v == [4]f32{ 6, 4, 0, 8 }, "vector sum wrong");

    // Exclusive prefix sum: lane i contributes i+1.
    offset, total := lane.scan(idx + 1);
    assert(offset == idx * (idx + 1) / 2 && total == 10, "scan_sum wrong");

    // Custom scan (running max, identity -1): prefix of lane i is i-1.
    pmax, tmax := lane.scan(idx, -1, proc "contextless" (a, b: int) -> int { return max(a, b); });
    assert(pmax == idx - 1 && tmax == 3, "scan_custom wrong");

    // Task-numbered broadcast, folded by the caller: 99 % 4 == lane 3.
    fold := 0;
    fold_src := lane.task_lane(99);
    if idx == fold_src do fold = 4242;
    lane.broadcast(&fold, fold_src);
    assert(fold == 4242, "broadcast from task_lane(99) did not come from lane 3");

    // Compaction: lane i writes i+1 copies of its index at its offset.
    for j in 0 ..< idx + 1 do _compact[offset + j] = idx;
    lane.sync();
    if lane.is_main() {
        k := 0;
        for i in 0 ..< cnt {
            for _ in 0 ..< i + 1 {
                assert(_compact[k] == i, "compaction misplaced a value");
                k += 1;
            }
        }
        assert(k == total, "compaction total wrong");
    }
}

case_collectives :: proc() {
    lane.init(4);
    lane.split(collectives_work);

    // Serial degrade outside a split: every collective returns its input.
    assert(lane.sum(5) == 5 && lane.minimum(9) == 9 && lane.maximum(9) == 9, "serial sum/minimum/maximum wrong");
    assert(lane.any_of(true) && !lane.any_of(false) && lane.all_of(true), "serial any_of/all_of wrong");
    assert(lane.reduce(3, proc "contextless" (a, b: int) -> int { return a + b; }) == 3, "serial reduce wrong");
    offset, total := lane.scan(7);
    assert(offset == 0 && total == 7, "serial scan wrong");

    lane.deinit();
}

grab_work :: proc() {
    // The shared cursor lives on the main lane's stack; the trailing sync
    // closes the phase (and pins main's frame until the last grab).
    // Chunks are disjoint by construction, so these increments don't race.
    cursor := 0;
    cursor_ptr := lane.share(&cursor);
    if lane.is_main() do assert(cursor_ptr == &cursor, "share must return main's own pointer on main");
    for lo, hi in lane.grab(cursor_ptr, N, 7) {
        for i in lo ..< hi do _seen[i] += 1;
    }
    lane.sync();
}

grab_slice_work :: proc() {
    cursor := 0;
    cursor_ptr := lane.share(&cursor);
    for chunk, lo in lane.grab(cursor_ptr, _seen[:], 7) {
        for &v, j in chunk {
            assert(&v == &_seen[lo + j], "slice chunk misaligned with base index");
            v += 1;
        }
    }
    lane.sync();
}

case_grab :: proc() {
    lane.init(4);

    // Ragged chunks (7 does not divide N): every index exactly once.
    lane.split(grab_work);
    for i in 0 ..< N do assert(_seen[i] == 1, "index missed or grabbed twice");

    // Slice overload: same exactly-once coverage, chunks aligned with lo.
    for i in 0 ..< N do _seen[i] = 0;
    lane.split(grab_slice_work);
    for i in 0 ..< N do assert(_seen[i] == 1, "index missed or grabbed twice (slice)");

    // n = 0 / empty slice: no chunk, immediately exhausted.
    empty_cursor := 0;
    _, _, ok := lane.grab(&empty_cursor, 0, 16);
    assert(!ok, "grab on empty range must fail");
    empty_cursor = 0;
    empty: []u8;
    _, _, sok := lane.grab(&empty_cursor, empty, 16);
    assert(!sok, "grab on empty slice must fail");

    // Serial use outside a split covers everything too.
    serial_cursor := 0;
    for i in 0 ..< N do _seen[i] = 0;
    for lo, hi in lane.grab(&serial_cursor, N, 1000) {
        for i in lo ..< hi do _seen[i] += 1;
    }
    for i in 0 ..< N do assert(_seen[i] == 1, "serial grab missed an index");

    lane.deinit();
}


// ------------------------------------------------------------------ misuse

noop_work :: proc() {}

nested_split_work :: proc() {
    if lane.is_main() do lane.split(noop_work);
}

case_nested_split :: proc() {
    lane.init(4);
    lane.split(nested_split_work);
}

worker_split_work :: proc() {
    if !lane.is_main() do lane.split(noop_work);
}

case_worker_split :: proc() {
    lane.init(4);
    lane.split(worker_split_work);
}

_split_running: bool;

concurrent_attacker :: proc() {
    for !sync.atomic_load(&_split_running) do time.sleep(time.Millisecond);
    lane.split(noop_work); // Must assert: another thread's split is in flight.
}

concurrent_split_work :: proc() {
    if lane.is_main() do sync.atomic_store(&_split_running, true);
    for { time.sleep(time.Millisecond); } // Park the split; the attacker's assert kills us.
}

case_concurrent_split :: proc() {
    lane.init(4);
    thread.create_and_start(concurrent_attacker);
    lane.split(concurrent_split_work);
}

case_sync_outside :: proc() {
    lane.init(4);

    // Both must degrade to no-ops outside a split.
    lane.sync();
    x := 5;
    lane.broadcast(&x);
    assert(x == 5, "broadcast outside a split must not touch the value");

    // The no-op sync must not have registered an arrival on the barrier:
    // a real split afterwards has to stay in sync.
    fill_data();
    tag := 777;
    _total = 0;
    lane.split(sum_work, &tag);
    assert(_total == EXPECTED_SUM, "split desynced after outside-split sync");
}

deinit_inside_work :: proc() {
    if lane.is_main() do lane.deinit();
}

case_deinit_inside :: proc() {
    lane.init(4);
    lane.split(deinit_inside_work);
}

case_double_init :: proc() {
    lane.init(4);
    lane.init(4);
}

case_double_init_1lane :: proc() {
    lane.init(1);
    lane.init(1);
}

case_split_before_init :: proc() {
    lane.split(noop_work); // No lane.init.
}

divergent_sync_work :: proc() {
    if !lane.is_main() do lane.sync(); // Main never arrives: workers block forever.
}

case_divergent_sync :: proc() {
    lane.init(4);
    lane.split(divergent_sync_work);
}

bad_broadcast_work :: proc() {
    x := 0;
    lane.broadcast(&x, -1); // Not a lane index: bounds-checked.
}

case_broadcast_bad_src :: proc() {
    lane.init(4);
    lane.split(bad_broadcast_work);
}
