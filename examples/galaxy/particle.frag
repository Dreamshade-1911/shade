#version 450

layout(location = 0) in vec2 v_uv;     // [-1, 1] across the quad
layout(location = 1) in vec4 v_color;

layout(location = 0) out vec4 frag;

void main() {
    float d    = length(v_uv);                 // 0 at center, ~1 at the disc edge
    float core = 1.0 - smoothstep(0.0, 1.0, d);
    // Bright, tight core fading to a transparent rim; additive blend then blooms
    // wherever dots overlap.
    float a = core * core * v_color.a;
    // Premultiplied output for the additive blend (src=ONE, dst=ONE).
    frag = vec4(v_color.rgb * a, a);
}
