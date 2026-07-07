#version 450

layout(set = 1, binding = 0) uniform Viewport {
    vec2 viewport_size;
};

layout(location = 0) in vec2 in_pos; // pixels, top-left origin
layout(location = 1) in vec4 in_color;

layout(location = 0) out vec4 v_color;

void main() {
    // Pixel coords -> NDC, Y flipped so (0,0) is the top-left.
    vec2 ndc = (in_pos / viewport_size) * 2.0 - 1.0;
    gl_Position = vec4(ndc.x, -ndc.y, 0.0, 1.0);
    v_color = in_color;
}
