#version 450

// Vertex uniforms live in set 1 for SDL_gpu's SPIR-V binding model.
layout(set = 1, binding = 0) uniform Camera {
    vec2 center;       // world-space center of the view
    vec2 world_scale;  // world units -> NDC
    vec2 point_ndc;    // half-size of a particle quad in NDC (constant pixels)
    vec2 _pad;
};

layout(location = 0) in vec2 a_corner;  // static unit-quad corner, [-1, 1]
layout(location = 1) in vec2 a_pos;     // per-instance world position
layout(location = 2) in vec4 a_color;   // per-instance color

layout(location = 0) out vec2 v_uv;
layout(location = 1) out vec4 v_color;

void main() {
    vec2 c = (a_pos - center) * world_scale;   // particle center in NDC
    vec2 p = c + a_corner * point_ndc;         // expand to a fixed-pixel quad
    gl_Position = vec4(p, 0.0, 1.0);
    v_uv    = a_corner;
    v_color = a_color;
}
