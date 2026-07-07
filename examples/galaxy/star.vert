#version 450

// Reuses the galaxy's Camera uniform. We only need center/world_scale (to invert
// the world->NDC map) and viewport (to size stars in pixels).
layout(set = 1, binding = 0) uniform Camera {
    vec2 center;
    vec2 world_scale;
    vec2 point_ndc;   // galaxy particle size, unused here
    vec2 viewport;    // pixels (w, h)
};

layout(location = 0) out vec2      v_world;
layout(location = 1) flat out float v_ppw;   // pixels per world unit

void main() {
    // Fullscreen triangle from the vertex index, no vertex buffer needed.
    vec2 p   = vec2(float((gl_VertexIndex << 1) & 2), float(gl_VertexIndex & 2));
    vec2 ndc = p * 2.0 - 1.0;   // (-1,-1), (3,-1), (-1,3)
    gl_Position = vec4(ndc, 0.0, 1.0);

    // Invert world -> NDC (ndc = (world - center) * world_scale).
    v_world = center + ndc / world_scale;
    // world_scale.y = 1/half, so this is isotropic px per world unit.
    v_ppw   = world_scale.y * viewport.y * 0.5;
}
