# galaxy

An interactive N-body galaxy: a rotating disk of up to 32k bodies orbiting a heavy core, with an all-pairs O(n²) gravity sum running on the CPU and SDL_gpu drawing the result (additive glow particles, a procedural starfield, and a font-less HUD). The point of the example is the two levels of parallelism composing: [`lane`](../../src/lane) splits the outer force loop across every core (SPMD), and `core:simd` vectorizes the inner loop 8-wide within each core.

> **SIMD disclaimer:** the force loop is written with 8-wide f32 vectors (`simd.f32x8`) and the release build compiles with `-microarch:native`. Your CPU needs SIMD support to run it well — it is fastest on AVX/AVX2 hardware; on older CPUs LLVM legalizes the 8-wide ops to narrower (or scalar) code, which is correct but slow.

Build and run (the debug build is unoptimized and will crawl at high body counts):

```
build.bat galaxy release
```

The compiled `.spv` shaders ship in the `data` folder, so there is nothing to compile shader-wise and `glslc` is not required. Only if you change the GLSL sources do you need to rebuild them:

```
build.bat galaxy shaders
```

---

## Controls

| Input        | Action                                             |
| ------------ | -------------------------------------------------- |
| Mouse L / R  | Pull / push the bodies around                      |
| Mouse wheel  | Zoom in / out                                      |
| Space        | Pause                                              |
| R            | Reseed the disk                                    |
| Up / Down    | Add / remove 1000 bodies                           |
| Left / Right | Halve / double the simulation speed                |
| L            | Toggle all-cores vs single-lane                    |
| Esc          | Quit                                               |

---

## What it exercises from `lane`

Every frame issues one `lane.split(simulate, &ctx)`: the same proc runs on every core, with the main thread participating as lane 0 (see `sim.odin`).

- **`split` + `user_data`** — one split per frame; a `Frame_Ctx` pointer carries the frame's inputs in (dt, mouse brush) and the collectives' results back out (energy, bounds).
- **`range`** — each lane takes a static, contiguous slice of the bodies for the force loop. Every body costs the same, so a fixed schedule is right: no cursor, no contention.
- **`sync`** — the force → integrate phase boundary. No lane may move bodies while another is still summing forces off the old positions.
- **`sum`** — total kinetic energy, folded across lanes (shown in the window title).
- **`reduce`** — a world-space AABB of all bodies, combined with a custom op and used to auto-frame the camera.
- **`is_main`** — exactly one lane publishes the folded results to the shared context.
- **`init` / `deinit`** — pressing **L** tears the gang down and respawns it with one lane, live. The same SPMD code degrades to correct serial code: `range` covers everything, `sync` is a no-op, and the collectives return their input — watch the sim time in the title change.
