package main;

import "core:os";
import "core:fmt";
import "core:time";
import "core:strings";

import sdl "vendor:sdl3";

import "shade:lane";

import common "../_common";

// -----------------------------------------------------------------------------
// examples/galaxy: an interactive N-body galaxy that runs its physics across
// every core with `shade:lane` (see sim.odin) and draws it with SDL_gpu.
//
// Controls:
//   Mouse L / R   pull / push the bodies around
//   Mouse wheel   zoom in / out
//   Space         pause
//   R             reseed the disk
//   Up / Down     add / remove 1000 bodies
//   Left / Right  halve / double the sim speed
//   L             toggle all-cores vs single-lane (watch the sim time change)
//   Esc           quit
// -----------------------------------------------------------------------------

FT_HISTORY :: 180;   // frame-time samples kept for the graph (~3s at 60Hz)

PARTICLE_WORLD_RADIUS :: 8.0;    // dot radius in world units (scales with zoom)
PARTICLE_MIN_PX       :: 1.5;    // ...but never smaller than this on screen
MAX_DT                :: 1.0 / 60.0; // so the physics doesn't screw up

App :: struct {
    window:   ^sdl.Window,
    gpu:      ^sdl.GPUDevice,
    renderer: Renderer,

    running: bool,
    paused:  bool,
    serial:  bool,   // true = lane.init(1), false = lane.init(0)

    time_scale: f32,   // runtime sim-speed multiplier (Left / Right arrows)

    refresh_rate: f32,
    vsync:        bool,
    last_tick:    time.Tick,

    // Camera. cam_half is the auto-fit half-height (world units) that tracks the
    // bodies' bounding box; cam_zoom is the user's scroll-wheel multiplier.
    cam_center: Vec2,
    cam_half:   f32,
    cam_zoom:   f32,

    // Input.
    mouse_px:    Vec2,
    mouse_world: Vec2,
    attract:     f32,

    // Perf.
    frame_ms:    f32,   // full frame, cap sleep included (drives fps)
    work_ms:     f32,   // frame minus the cap sleep, what the graph shows
    sim_ms:      f32,
    fps:         f32,
    energy:      f32,   // total kinetic energy, from lane.sum

    ft_history:  [FT_HISTORY]f32,
    ft_head:     int,
    title_accum: f32,
};

g_app: App;

main :: proc() {
    attach_parent_console();
    ok := start();
    if !ok do os.exit(1);
}
start :: proc() -> bool {
    if !sdl.Init({ .VIDEO }) {
        return log_error("SDL_Init failed");
    }
    defer sdl.Quit();

    g_app.window = sdl.CreateWindow("shade . galaxy", 1280, 800, { .RESIZABLE });
    if g_app.window == nil {
        return log_error("CreateWindow failed");
    }
    defer sdl.DestroyWindow(g_app.window);

    g_app.gpu = sdl.CreateGPUDevice(common.SHADER_FORMATS, ODIN_DEBUG, nil);
    if g_app.gpu == nil {
        return log_error("CreateGPUDevice failed");
    }
    defer sdl.DestroyGPUDevice(g_app.gpu);

    if !sdl.ClaimWindowForGPUDevice(g_app.gpu, g_app.window) {
        return log_error("ClaimWindowForGPUDevice failed");
    }
    defer sdl.ReleaseWindowFromGPUDevice(g_app.gpu, g_app.window);

    // Prefer a non-vsync present mode so our own frame cap (below) governs the
    // pace and the measured frame time reflects real work, not the vblank wait.
    present_mode := sdl.GPUPresentMode.VSYNC;
    g_app.vsync = true;
    if sdl.WindowSupportsGPUPresentMode(g_app.gpu, g_app.window, .MAILBOX) {
        present_mode = .MAILBOX;
        g_app.vsync = false;
    } else if sdl.WindowSupportsGPUPresentMode(g_app.gpu, g_app.window, .IMMEDIATE) {
        present_mode = .IMMEDIATE;
        g_app.vsync = false;
    }
    _ = sdl.SetGPUSwapchainParameters(g_app.gpu, g_app.window, .SDR, present_mode);

    g_app.renderer = init_renderer(g_app.gpu, g_app.window) or_return;
    defer destroy_renderer(g_app.gpu, &g_app.renderer);

    lane.init();
    defer lane.deinit();

    init_bodies(DEFAULT_BODIES);
    defer deinit_bodies();
    defer delete(g_hud_verts);

    g_app.cam_center = { 0, 0 };
    g_app.cam_half   = DISK_RADIUS * 1.4;
    g_app.cam_zoom   = 1;
    g_app.time_scale = 1;

    g_app.refresh_rate = get_refresh_rate();
    g_app.last_tick = time.tick_now();
    g_app.running = true;

    for g_app.running {
        frame();
    }

    return true;
}

frame :: proc() {
    a := &g_app;

    // --- Frame-rate cap ------------------------------------------------------
    // Sleep off any time left in the refresh-rate budget so we sit at the
    // display's rate instead of burning a core to spin the loop.
    if !a.vsync {
        target  := time.Duration(f64(time.Second) / f64(max(a.refresh_rate, 1)));
        elapsed := time.tick_since(a.last_tick);
        if elapsed < target do loop_sleep(target - elapsed);
    }

    dt := f32(time.duration_seconds(time.tick_lap_time(&a.last_tick)));
    a.frame_ms = dt * 1000;
    a.fps      = (1.0 / dt) if dt > 0 else 0;
    dt = min(dt, MAX_DT);

    poll_events();
    a.refresh_rate = get_refresh_rate();

    w, h: i32;
    sdl.GetWindowSizeInPixels(a.window, &w, &h);
    fw, fh := f32(w), f32(h);

    update_mouse_world(fw, fh);

    // --- Simulate ------------------------------------------------------------
    if !a.paused {
        ctx := Frame_Ctx {
            dt               = min(dt, 1.0 / 30.0) * a.time_scale,  // clamp big hitches
            attractor        = a.mouse_world,
            attract_strength = a.attract * BRUSH_ACCEL,
            attract_radius   = effective_half() * BRUSH_RADIUS_FRAC,
        };

        t0 := time.tick_now();
        lane.split(simulate, &ctx);   // <-- the whole gang runs sim.simulate
        a.sim_ms  = f32(time.duration_milliseconds(time.tick_since(t0)));
        a.energy  = ctx.energy;

        update_camera(ctx.bounds, dt);
    }

    // --- Draw ----------------------------------------------------------------
    build_hud(a, fw, fh);
    camera := make_camera(fw, fh);
    _ = render(a.gpu, a.window, &a.renderer, g_instances, g_hud_verts[:], camera);

    // Throttled window-title readout (labels the numbers the HUD shows).
    a.title_accum += dt;
    if a.title_accum > 0.25 {
        a.title_accum = 0;
        update_title();
    }

    // End of frame: reset every lane's temp arena. No lane can still hold
    // another lane's temp pointers here, and each lane frees its own.
    lane.split(proc() { free_all(context.temp_allocator) });

    // Save actual frame time before sleeping.
    a.work_ms = f32(time.duration_milliseconds(time.tick_since(a.last_tick)));
    a.ft_history[a.ft_head] = a.work_ms;
    a.ft_head = (a.ft_head + 1) % FT_HISTORY;
}

poll_events :: proc() {
    a := &g_app;
    event: sdl.Event;
    for sdl.PollEvent(&event) {
        #partial switch event.type {
        case .QUIT:
            a.running = false;

        case .MOUSE_MOTION:
            a.mouse_px = { event.motion.x, event.motion.y };

        case .MOUSE_WHEEL:
            a.cam_zoom = clamp(a.cam_zoom * (1 + event.wheel.y * 0.12), 0.15, 60);

        case .MOUSE_BUTTON_DOWN, .MOUSE_BUTTON_UP:
            down := event.type == .MOUSE_BUTTON_DOWN;
            if event.button.button == sdl.BUTTON_LEFT  do a.attract =  1 if down else 0; // pull
            if event.button.button == sdl.BUTTON_RIGHT do a.attract = -1 if down else 0; // push

        case .KEY_DOWN:
            if event.key.repeat do break;
            #partial switch event.key.scancode {
            case .ESCAPE: a.running = false;
            case .SPACE:  a.paused = !a.paused;
            case .R:      init_bodies(body_count());
            case .UP:     init_bodies(body_count() + 1000);
            case .DOWN:   init_bodies(body_count() - 1000);
            case .LEFT:   a.time_scale = max(a.time_scale * 0.5, 0.125);
            case .RIGHT:  a.time_scale = min(a.time_scale * 2, 8);
            case .L:      toggle_lane_mode();
            }
        }
    }
}

// Re-spawns the gang with a different lane count. Legal here because we are
// outside any split; init/deinit just bracket the new gang.
toggle_lane_mode :: proc() {
    g_app.serial = !g_app.serial;
    lane.deinit();
    lane.init(1 if g_app.serial else 0);
}

// -----------------------------------------------------------------------------
// Camera: fit the view to the bodies' bounding box (from lane.reduce), smoothed.
// -----------------------------------------------------------------------------

update_camera :: proc(bounds: AABB, dt: f32) {
    a := &g_app;

    w, h: i32;
    sdl.GetWindowSizeInPixels(a.window, &w, &h);
    aspect := f32(w) / f32(max(h, 1));

    target_center := (bounds.mn + bounds.mx) * 0.5;
    span := bounds.mx - bounds.mn;
    target_half := max(span.x / max(aspect, 0.001), span.y) * 0.5 * 1.15;
    target_half = max(target_half, 50);

    // Critically-ish damped follow; frame-rate independent.
    k := min(dt * 2.5, 1);
    a.cam_center += (target_center - a.cam_center) * k;
    a.cam_half   += (target_half - a.cam_half) * k;
}

make_camera :: proc(w, h: f32) -> Camera_UBO {
    a := &g_app;
    half   := effective_half();
    aspect := w / max(h, 1);
    // world -> NDC: x squeezed by aspect so circles stay round; y is up.
    scale := Vec2 { 1.0 / (half * aspect), 1.0 / half };
    // Particle radius is a fixed world size, so dots grow when you zoom in and
    // shrink when you zoom out, with a floor so they never vanish.
    pixel_r := max(PARTICLE_WORLD_RADIUS * h / (2 * half), PARTICLE_MIN_PX);
    point_ndc := Vec2 { pixel_r * 2 / w, pixel_r * 2 / h };
    return Camera_UBO { center = a.cam_center, world_scale = scale, point_ndc = point_ndc, viewport = { w, h } };
}

// The camera's half-height in world units after the user's zoom multiplier.
effective_half :: proc() -> f32 {
    return g_app.cam_half / g_app.cam_zoom;
}

// Screen pixel -> world, the inverse of make_camera's mapping (y flips).
update_mouse_world :: proc(w, h: f32) {
    a := &g_app;
    half   := effective_half();
    aspect := w / max(h, 1);
    nx := a.mouse_px.x / w * 2 - 1;
    ny := a.mouse_px.y / h * 2 - 1;
    a.mouse_world = {
        a.cam_center.x + nx * half * aspect,
        a.cam_center.y - ny * half,
    };
}

update_title :: proc() {
    a := &g_app;
    lanes := lane.capacity();
    mode := "serial" if a.serial else "parallel";
    paused_str := " . PAUSED" if a.paused else "";
    title := fmt.tprintf(
        "shade . galaxy  |  %d bodies  |  %d lanes (%s)  |  speed x%g  |  sim %.2f ms  |  frame %.2f ms  |  %.0f fps  |  E %.3e%s",
        body_count(), lanes, mode, a.time_scale, a.sim_ms, a.frame_ms, a.fps, a.energy, paused_str,
    );
    ctitle := strings.clone_to_cstring(title, context.temp_allocator);
    sdl.SetWindowTitle(a.window, ctitle);
}

// -----------------------------------------------------------------------------
// Small helpers.
// -----------------------------------------------------------------------------

get_refresh_rate :: proc() -> f32 {
    display := sdl.GetDisplayForWindow(g_app.window);
    if display != 0 {
        mode := sdl.GetCurrentDisplayMode(display);
        if mode != nil && mode.refresh_rate > 0 do return mode.refresh_rate;
    }
    return 60;
}

// Sleep close to `d`, re-sleeping the remainder until it elapses. Depends on the
// 1ms timer resolution set in main().
loop_sleep :: proc(d: time.Duration) {
    start := time.tick_now();
    for time.tick_since(start) < d {
        time.sleep(d - time.tick_since(start));
    }
}

log_error :: proc(msg: string) -> bool {
    fmt.eprintfln("[galaxy] %s: %s", msg, sdl.GetError());
    return false;
}

