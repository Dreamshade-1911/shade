package main;

import "base:intrinsics";
import "core:math";
import "core:math/rand";
import "core:math/linalg";
import "core:simd";

import "shade:lane";

// -----------------------------------------------------------------------------
// N-body galaxy simulation (showcasing lane).
//
// Every frame we run one `lane.split(simulate)`: the same proc runs on every
// core, each lane taking a static slice of the bodies. The all-pairs force sum
// is O(n^2) and embarrassingly parallel, exactly the case `range` is the
// default for. It exercises:
//
//   range   : static, equal-cost schedule over the bodies (the force loop)
//   sync    : the force -> integrate phase boundary (README's simulate())
//   sum     : total kinetic energy, folded across lanes
//   reduce  : a world-space bounding box, used to auto-frame the camera
//
// The two levels of parallelism compose: `lane` splits the *outer* loop across
// cores (each lane owns a slice of bodies), and SIMD vectorizes the *inner*
// loop within each core (each body sums forces from 8 sources per iteration).
//
// The whole thing degrades to correct serial code: with one lane, `range`
// covers everything, `sync` is a no-op, and the collectives return their input.
// Press [L] at runtime to flip between `lane.init(0)` (all cores) and
// `lane.init(1)` (single lane) and watch the sim time move.
//
// This is O(n^2) on purpose, it is meant to give every core real work. Build
// RELEASE for the real thing (`build.bat galaxy release`); the debug build is
// unoptimized and bounds-checked and will crawl at high body counts.
// -----------------------------------------------------------------------------

Vec2 :: [2]f32;
Vec3 :: [3]f32;

// Tunables. These are picked for a pleasant spiral, not physical accuracy,
// nudge them freely.
G              :: 1.0;      // gravitational constant
CENTER_MASS    :: 1.5e8;    // heavy core the disk orbits (body 0)
BODY_MASS      :: 6.0e3;    // every other body
DISK_RADIUS    :: 520.0;    // initial disk extent, world units
SOFTENING2     :: 400.0;    // epsilon^2, keeps close pairs (esp. the core) tame
SPEED_REF      :: 900.0;    // speed that maps to the hottest color
MAX_SPEED      :: 6000.0;   // clamp to survive the odd slingshot

// Re-circularization: each frame every body's velocity is nudged this fraction
// per second toward the circular orbit at its current radius. Set to 0 for pure gravity.
RECIRC_RATE :: 0.1;

// Containment wall: bodies stay within this radius of the core so escapees
// can't drag the auto-fit camera out forever. Crossing it puts a body back on
// the rim and reflects the outward part of its velocity, damped by the
// restitution factor (1 = lossless bounce, 0 = dead stop at the wall).
BOUND_RADIUS      :: DISK_RADIUS * 4.0;
BOUND_RESTITUTION :: 0.6;

// Mouse "brush": a bounded, smooth pull/push, strongest under the cursor and
// zero at the edge of its radius. The radius is a fraction of the view so it
// feels the same however far the camera has zoomed (set in main.odin).
BRUSH_ACCEL       :: 4000.0;
BRUSH_RADIUS_FRAC :: 0.4;

DEFAULT_BODIES :: 4000;
MIN_BODIES     :: 1000;
MAX_BODIES     :: 32768;

// The force loop's vector width: 8 x f32 (one AVX register; on narrower
// targets LLVM legalizes it to pairs of 128-bit ops, still correct).
SIMD_WIDTH :: 8;
f32w :: simd.f32x8;

// Hot data read by every lane on every inner iteration of the force loop.
// The fields are scalars (not a Vec2) so that #soa yields one flat f32 column
// per component, and the O(n^2) sweep loads 8 bodies into vector registers
// with three plain loads (no gathers, no shuffles).
Hot :: struct {
    x, y: f32,
    mass: f32,
};

// Padded to a multiple of SIMD_WIDTH with zero-mass bodies at the origin:
// they contribute exactly zero force (and SOFTENING2 keeps the distance math
// NaN-free), so the vector loop needs no scalar tail.
g_hot: #soa[]Hot;

g_vel:       []Vec2;
g_acc:       []Vec2;       // written in phase 1, read in phase 2 (across the sync)
g_instances: []Instance;   // compact {pos,color} array uploaded to the GPU

// The real body count (g_hot is longer: padding).
body_count :: #force_inline proc "contextless" () -> int {
    return len(g_instances);
}

// A tight axis-aligned box. 16 bytes, well under lane.MAX_COLLECTIVE_SIZE, so
// it rides through `reduce` in a single collective.
AABB :: struct {
    mn: Vec2,
    mx: Vec2,
};

// One pointer's worth of per-frame state handed to the split via user_data,
// plus the two results the collectives write back for the main thread to read.
Frame_Ctx :: struct {
    dt:               f32,
    attractor:        Vec2,
    attract_strength: f32,   // 0 = idle, + = pull, - = push (an acceleration)
    attract_radius:   f32,
    // outputs:
    energy: f32,
    bounds: AABB,
};

// Allocate and seed a rotating disk around a heavy core.
init_bodies :: proc(n: int) {
    count  := clamp(n, MIN_BODIES, MAX_BODIES);
    padded := (count + SIMD_WIDTH - 1) / SIMD_WIDTH * SIMD_WIDTH;

    deinit_bodies();
    g_hot       = make(#soa[]Hot, padded);   // zero-initialized: the tail
    g_vel       = make([]Vec2, count);       // entries are zero-mass padding
    g_acc       = make([]Vec2, count);
    g_instances = make([]Instance, count);

    // Body 0 is the heavy, pinned galactic core.
    g_hot[0]       = Hot { mass = CENTER_MASS };
    g_instances[0] = Instance { pos = {0, 0}, color = {255, 240, 210, 255} };

    for i in 1 ..< count {
        angle := rand.float32() * math.TAU;
        // sqrt() spreads the bodies uniformly by area across the disk; the +60
        // leaves a small hole so the core doesn't fling inner bodies on frame 1.
        r     := math.sqrt(rand.float32()) * DISK_RADIUS + 60;
        dir   := Vec2 { math.cos(angle), math.sin(angle) };
        pos   := dir * r;

        // Circular orbital speed around the core: v = sqrt(G*M / r).
        v       := math.sqrt(G * CENTER_MASS / r);
        tangent := Vec2 { -dir.y, dir.x };

        g_hot[i]       = Hot { x = pos.x, y = pos.y, mass = BODY_MASS };
        g_vel[i]       = tangent * v;
        g_instances[i] = Instance { pos = pos, color = speed_color(v) };
    }
}

deinit_bodies :: proc() {
    delete(g_hot);
    delete(g_vel);
    delete(g_acc);
    delete(g_instances);
}

// Runs on every lane. `lane.split(simulate, &ctx)` calls it once per core; the
// calling (main) thread is lane 0 and participates like any other.
simulate :: proc() {
    ctx := lane.user_data(^Frame_Ctx);
    dt  := ctx.dt;
    n   := body_count();
    padded := len(g_hot);

    // This lane's static, contiguous share of the bodies. Every body costs the
    // same, so a fixed split is the right call.
    lo, hi := lane.range(n);

    // --- Phase 1: forces -----------------------------------------------------
    // Read every body's position, write only this lane's accelerations. No lane
    // touches another lane's slot, and nobody moves yet, so the reads are safe.
    // The self term (j == i) is naturally zero (d = 0) so no branch needed.
    //
    // The inner loop is 8-wide: each iteration loads 8 source bodies and folds
    // their pull on body i into vector accumulators, reduced to a scalar at the
    // end. One vector div + sqrt replaces 8 scalar ones, that pair dominates
    // the iteration, so the loop runs close to 8x the scalar version.
    soft := f32w(SOFTENING2);
    gee  := f32w(G);
    xs, ys, ms := g_hot.x, g_hot.y, g_hot.mass;   // the #soa columns, as [^]f32
    #no_bounds_check for i in lo ..< hi {
        pi  := Vec2 { xs[i], ys[i] };
        pix := f32w(pi.x);
        piy := f32w(pi.y);

        ax, ay: f32w;
        for j := 0; j < padded; j += SIMD_WIDTH {
            jx := intrinsics.unaligned_load(cast(^f32w)&xs[j]);
            jy := intrinsics.unaligned_load(cast(^f32w)&ys[j]);
            jm := intrinsics.unaligned_load(cast(^f32w)&ms[j]);

            dx := jx - pix;
            dy := jy - piy;
            d2 := dx * dx + dy * dy + soft;
            // f = G * m_j / |d|^3, so a += d * f (zero-mass padding => f = 0).
            f := (gee * jm) / (d2 * simd.sqrt(d2));
            ax += dx * f;
            ay += dy * f;
        }
        a := Vec2 { simd.reduce_add_ordered(ax), simd.reduce_add_ordered(ay) };

        // Mouse brush: bounded, smooth pull (+) or push (-).
        if ctx.attract_strength != 0 {
            d    := ctx.attractor - pi;
            dist := math.sqrt(d.x * d.x + d.y * d.y);
            if dist > 0.001 && dist < ctx.attract_radius {
                falloff := 1 - dist / ctx.attract_radius;   // 1 at cursor -> 0 at edge
                a += (d / dist) * (ctx.attract_strength * falloff);
            }
        }

        g_acc[i] = a;
    }

    // The phase boundary: no lane may start moving bodies while another is
    // still summing forces off their old positions.
    lane.sync();

    // --- Phase 2: integrate, shade, and gather stats -------------------------
    local_energy: f32 = 0;
    local_bounds := AABB { mn = { max(f32), max(f32) }, mx = { min(f32), min(f32) } };

    #no_bounds_check for i in lo ..< hi {
        // Body 0 (the core) stays put so the galaxy doesn't wander off-screen.
        if i != 0 {
            vel := g_vel[i] + g_acc[i] * dt;

            // Nudge particles back into orbit.
            p := Vec2 { g_hot[i].x, g_hot[i].y };
            if r := linalg.length(p); r > 1 {
                tangent := Vec2 { -p.y, p.x } / r;
                if linalg.dot(vel, tangent) < 0 do tangent = -tangent;
                v_circ := tangent * math.sqrt(G * CENTER_MASS / r);
                vel += (v_circ - vel) * min(RECIRC_RATE * dt, 1);
            }

            speed := linalg.length(vel);
            if speed > MAX_SPEED do vel *= MAX_SPEED / speed;
            pos := p + vel * dt;

            // Containment wall: put escapees back on the rim and bounce the
            // outward part of their velocity (damped), keeping the tangential
            // part, they skim along the wall instead of sticking to it.
            if r2 := pos.x * pos.x + pos.y * pos.y; r2 > BOUND_RADIUS * BOUND_RADIUS {
                nrm := pos / math.sqrt(r2);   // outward normal
                pos = nrm * BOUND_RADIUS;
                radial := linalg.dot(vel, nrm);
                if radial > 0 do vel -= nrm * (radial * (1 + BOUND_RESTITUTION));
            }

            g_vel[i]   = vel;
            g_hot[i].x = pos.x;
            g_hot[i].y = pos.y;
        }

        pos   := Vec2 { g_hot[i].x, g_hot[i].y };
        speed := linalg.length(g_vel[i]);
        local_energy += 0.5 * g_hot[i].mass * speed * speed;
        g_instances[i] = Instance { pos = pos, color = speed_color(speed) };

        local_bounds.mn = linalg.min(local_bounds.mn, pos);
        local_bounds.mx = linalg.max(local_bounds.mx, pos);
    }

    // Collectives: every lane contributes, every lane gets the folded result.
    // Both must be reached by all lanes, in the same order (they are).
    energy := lane.sum(local_energy);
    bounds := lane.reduce(local_bounds, combine_aabb);

    // The result lives on every lane; let just one publish it to the shared ctx.
    if lane.is_main() {
        ctx.energy = energy;
        ctx.bounds = bounds;
    }
}

combine_aabb :: proc "contextless" (a, b: AABB) -> AABB {
    return AABB {
        mn = linalg.min(a.mn, b.mn),
        mx = linalg.max(a.mx, b.mx),
    };
}

// Cool (slow) -> hot (fast): deep blue -> cyan -> warm white.
speed_color :: proc "contextless" (speed: f32) -> [4]u8 {
    t := clamp(speed / SPEED_REF, 0, 1);

    lo  := Vec3 { 0.15, 0.25, 0.90 };
    mid := Vec3 { 0.40, 0.85, 1.00 };
    hi  := Vec3 { 1.00, 0.88, 0.65 };

    col: Vec3;
    if t < 0.5 do col = lo  + (mid - lo)  * (t * 2);
    else       do col = mid + (hi  - mid) * ((t - 0.5) * 2);

    return {
        u8(clamp(col.r, 0, 1) * 255),
        u8(clamp(col.g, 0, 1) * 255),
        u8(clamp(col.b, 0, 1) * 255),
        216,
    };
}
