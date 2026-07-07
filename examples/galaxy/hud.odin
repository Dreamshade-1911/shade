package main;

import "core:fmt";

// -----------------------------------------------------------------------------
// The on-screen performance overlay, built from solid rectangles so it needs no
// font. A scrolling frame-time graph (with the refresh-rate budget marked) plus
// 7-segment readouts for the current frame time, the sim time, and the FPS.
//
// The metric is *work time*, the frame minus the framecap sleep (sampled in
// main.odin just before the sleep). When the sim can't keep up (more bodies, or
// serial mode) it climbs past the mid-height budget line and the graph turns red.
// -----------------------------------------------------------------------------

g_hud_verts: [dynamic]Hud_Vertex;

Color8 :: [4]u8;

C_PANEL  :: Color8 { 10, 12, 20, 180 };
C_GOOD   :: Color8 { 90, 220, 130, 255 };
C_WARN   :: Color8 { 235, 200, 90, 255 };
C_BAD    :: Color8 { 235, 90, 90, 255 };
C_BUDGET :: Color8 { 120, 140, 180, 220 };
C_TEXT   :: Color8 { 210, 220, 235, 255 };
C_DIM    :: Color8 { 120, 130, 150, 255 };

hud_rect :: proc(x, y, w, h: f32, color: Color8) {
    p0 := Vec2 { x,     y     };
    p1 := Vec2 { x + w, y     };
    p2 := Vec2 { x + w, y + h };
    p3 := Vec2 { x,     y + h };
    append(&g_hud_verts,
        Hud_Vertex { p0, color }, Hud_Vertex { p1, color }, Hud_Vertex { p2, color },
        Hud_Vertex { p0, color }, Hud_Vertex { p2, color }, Hud_Vertex { p3, color },
    );
}

build_hud :: proc(app: ^App, screen_w, screen_h: f32) {
    clear(&g_hud_verts);

    budget := 1000.0 / max(app.refresh_rate, 1);  // ms/frame we aim to stay under
    max_ms := budget * 2;                          // top of the graph: the budget line sits exactly mid-height

    // --- Frame-time graph (bottom-left) --------------------------------------
    gw, gh: f32 = 360, 90;
    gx := f32(16);
    gy := screen_h - gh - 16;

    hud_rect(gx - 4, gy - 4, gw + 8, gh + 8, C_PANEL);

    bar_w := gw / f32(FT_HISTORY);
    for k in 0 ..< FT_HISTORY {
        idx := (app.ft_head + k) % FT_HISTORY;
        ms  := app.ft_history[idx];
        if ms <= 0 do continue;

        frac := clamp(ms / max_ms, 0, 1);
        bh   := frac * gh;

        color := C_GOOD;
        if ms > budget * 1.5      do color = C_BAD;
        else if ms > budget       do color = C_WARN;

        hud_rect(gx + f32(k) * bar_w, gy + gh - bh, max(bar_w - 1, 1), bh, color);
    }

    // Refresh-rate budget line (1000 / refresh_rate ms), mid-height by
    // construction, so "how full is my frame budget" reads at a glance:
    // bars below the line fit the budget, bars above it missed a vblank.
    line_y := gy + gh - (budget / max_ms) * gh;
    hud_rect(gx, line_y, gw, 1.5, C_BUDGET);

    // --- Numeric readouts (top-left) -----------------------------------------
    buf: [32]u8;

    // Big: the last frame's work time in ms (same metric as the graph).
    ft := fmt.bprintf(buf[:], "%.1f", app.work_ms);
    end := draw_number(16, 16, 26, 44, 6, 9, C_TEXT, ft);
    draw_label_ms(end + 6, 16 + 44, C_DIM);   // little "ms" tick under the number

    // Smaller row: sim ms and fps.
    sim := fmt.bprintf(buf[:], "%.1f", app.sim_ms);
    sx  := draw_number(16, 74, 15, 26, 4, 6, C_DIM, sim);
    fps_col := C_GOOD;
    if app.serial do fps_col = C_WARN;   // serial mode: highlight the slower FPS
    draw_number(sx + 20, 74, 15, 26, 4, 6, fps_col, fmt.bprintf(buf[:], "%.0f", app.fps));
}

// 7-segment bit masks for digits 0-9. Bits: a=0x01 b=0x02 c=0x04 d=0x08
// e=0x10 f=0x20 g=0x40.
@(rodata)
SEG_DIGITS := [10]u8 { 0x3F, 0x06, 0x5B, 0x4F, 0x66, 0x6D, 0x7D, 0x07, 0x7F, 0x6F };

// Draws a numeric string (digits, '.', '-') left-to-right and returns the x just
// past the last glyph.
draw_number :: proc(x, y, w, h, t, gap: f32, color: Color8, s: string) -> f32 {
    cx := x;
    for ch in s {
        switch ch {
        case '0' ..= '9':
            draw_seg_glyph(cx, y, w, h, t, color, SEG_DIGITS[int(ch - '0')]);
            cx += w + gap;
        case '.':
            hud_rect(cx, y + h - t, t, t, color);
            cx += t + gap;
        case '-':
            hud_rect(cx, y + (h - t) * 0.5, w, t, color);
            cx += w + gap;
        case ' ':
            cx += w + gap;
        }
    }
    return cx;
}

draw_seg_glyph :: proc(x, y, w, h, t: f32, color: Color8, mask: u8) {
    mid := y + (h - t) * 0.5;
    vh  := (h + t) * 0.5;   // vertical segment length (overlaps the joints)
    if mask & 0x01 != 0 do hud_rect(x,         y,      w,  t,   color); // a  top
    if mask & 0x02 != 0 do hud_rect(x + w - t, y,      t, vh,   color); // b  top-right
    if mask & 0x04 != 0 do hud_rect(x + w - t, mid,    t, vh,   color); // c  bottom-right
    if mask & 0x08 != 0 do hud_rect(x,         y + h - t, w, t, color); // d  bottom
    if mask & 0x10 != 0 do hud_rect(x,         mid,    t, vh,   color); // e  bottom-left
    if mask & 0x20 != 0 do hud_rect(x,         y,      t, vh,   color); // f  top-left
    if mask & 0x40 != 0 do hud_rect(x,         mid,    w,  t,   color); // g  middle
}

// A tiny "ms" marker (two little blocks) so the big number reads as milliseconds
// without needing a real font.
draw_label_ms :: proc(x, y: f32, color: Color8) {
    hud_rect(x,      y - 8, 10, 3, color);
    hud_rect(x + 14, y - 8, 10, 3, color);
}
