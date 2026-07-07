package main;

import "core:fmt";
import "core:mem";

import sdl "vendor:sdl3";

// -----------------------------------------------------------------------------
// A small SDL_gpu renderer: one additive-blended pipeline draws the particles as
// instanced quads (a soft round glow per body), and one alpha-blended pipeline
// draws the HUD (frame-time graph + 7-segment readouts) from pixel-space quads.
//
// The physics is on the CPU (see sim.odin), the GPU only draws. Each frame we
// upload the compact instance array and the HUD vertices and issue three draws.
// -----------------------------------------------------------------------------

// Per-body data the GPU sees: position + color. Kept tight (12 bytes) so the
// per-frame upload stays cheap.
Instance :: struct {
    pos:   Vec2,
    color: [4]u8,
};

Hud_Vertex :: struct {
    pos:   Vec2,     // pixels, top-left origin
    color: [4]u8,
};

// Vertex uniform shared by the particle and star pipelines (set = 1, binding = 0).
Camera_UBO :: struct {
    center:      Vec2,   // world-space center of the view
    world_scale: Vec2,   // world units -> NDC
    point_ndc:   Vec2,   // half-size of a particle quad in NDC (particles only)
    viewport:    Vec2,   // pixels (w, h), the starfield sizes stars from this
};

// Vertex uniform for the HUD pipeline (set = 1, binding = 0).
Viewport_UBO :: struct {
    viewport_size: Vec2,
};

HUD_MAX_VERTS :: 16384;

PARTICLE_VERT_SPV :: #load("../../data/galaxy/particle.vert.spv");
PARTICLE_FRAG_SPV :: #load("../../data/galaxy/particle.frag.spv");
STAR_VERT_SPV     :: #load("../../data/galaxy/star.vert.spv");
STAR_FRAG_SPV     :: #load("../../data/galaxy/star.frag.spv");
HUD_VERT_SPV      :: #load("../../data/galaxy/hud.vert.spv");
HUD_FRAG_SPV      :: #load("../../data/galaxy/hud.frag.spv");

// Premultiplied additive: soft-edged dots that bloom where they overlap (the
// fragment's radial falloff gives the transparent rim). Particles + starfield.
BLEND_ADDITIVE :: sdl.GPUColorTargetBlendState {
    enable_blend          = true,
    src_color_blendfactor = .ONE,
    dst_color_blendfactor = .ONE,
    color_blend_op        = .ADD,
    src_alpha_blendfactor = .ONE,
    dst_alpha_blendfactor = .ONE,
    alpha_blend_op        = .ADD,
};

// Standard alpha compositing for the HUD panels and glyphs.
BLEND_ALPHA :: sdl.GPUColorTargetBlendState {
    enable_blend          = true,
    src_color_blendfactor = .SRC_ALPHA,
    dst_color_blendfactor = .ONE_MINUS_SRC_ALPHA,
    color_blend_op        = .ADD,
    src_alpha_blendfactor = .ONE,
    dst_alpha_blendfactor = .ONE_MINUS_SRC_ALPHA,
    alpha_blend_op        = .ADD,
};

Renderer :: struct {
    particle_pipeline: ^sdl.GPUGraphicsPipeline,
    star_pipeline:     ^sdl.GPUGraphicsPipeline,   // procedural fullscreen starfield
    hud_pipeline:      ^sdl.GPUGraphicsPipeline,

    quad_vbo:      ^sdl.GPUBuffer,           // static 4-corner unit quad
    instance_vbo:  ^sdl.GPUBuffer,           // per-instance particle data
    instance_xfer: ^sdl.GPUTransferBuffer,
    hud_vbo:       ^sdl.GPUBuffer,
    hud_xfer:      ^sdl.GPUTransferBuffer,
};

// Everything that varies between this example's pipelines. All three share the
// same skeleton: SPIR-V vert/frag pair, one vertex uniform buffer, and a single
// blended color target in the swapchain format.
Pipeline_Desc :: struct {
    vert_spv:       []u8,
    frag_spv:       []u8,
    primitive:      sdl.GPUPrimitiveType,
    vertex_buffers: []sdl.GPUVertexBufferDescription,   // empty = no vertex input
    vertex_attrs:   []sdl.GPUVertexAttribute,
    blend:          sdl.GPUColorTargetBlendState,
};

create_pipeline :: proc(
    gpu:    ^sdl.GPUDevice,
    format: sdl.GPUTextureFormat,
    name:   string,
    desc:   Pipeline_Desc,
) -> ^sdl.GPUGraphicsPipeline {
    vs := sdl.CreateGPUShader(gpu, {
        code_size           = len(desc.vert_spv),
        code                = raw_data(desc.vert_spv),
        entrypoint          = "main",
        format              = { .SPIRV },
        stage               = .VERTEX,
        num_uniform_buffers = 1,
    });
    fs := sdl.CreateGPUShader(gpu, {
        code_size  = len(desc.frag_spv),
        code       = raw_data(desc.frag_spv),
        entrypoint = "main",
        format     = { .SPIRV },
        stage      = .FRAGMENT,
    });
    defer if vs != nil do sdl.ReleaseGPUShader(gpu, vs);
    defer if fs != nil do sdl.ReleaseGPUShader(gpu, fs);
    if vs == nil || fs == nil {
        log_error(fmt.tprintf("Failed to create %s shaders", name));
        return nil;
    }

    color_target := sdl.GPUColorTargetDescription { format = format, blend_state = desc.blend };
    pipeline := sdl.CreateGPUGraphicsPipeline(gpu, {
        vertex_shader   = vs,
        fragment_shader = fs,
        primitive_type  = desc.primitive,
        vertex_input_state = {
            vertex_buffer_descriptions = raw_data(desc.vertex_buffers),
            num_vertex_buffers         = u32(len(desc.vertex_buffers)),
            vertex_attributes          = raw_data(desc.vertex_attrs),
            num_vertex_attributes      = u32(len(desc.vertex_attrs)),
        },
        target_info = {
            num_color_targets         = 1,
            color_target_descriptions = &color_target,
        },
    });
    if pipeline == nil do log_error(fmt.tprintf("Failed to create %s pipeline", name));
    return pipeline;
}

init_renderer :: proc(gpu: ^sdl.GPUDevice, window: ^sdl.Window) -> (r: Renderer, ok: bool) {
    swapchain_format := sdl.GetGPUSwapchainTextureFormat(gpu, window);

    // Particles: instanced quads. quad corners in slot 0, per-body data in slot 1.
    particle_buffers := [?]sdl.GPUVertexBufferDescription {
        { slot = 0, pitch = size_of(Vec2),     input_rate = .VERTEX },   // quad corners
        { slot = 1, pitch = size_of(Instance), input_rate = .INSTANCE }, // per-body
    };
    particle_attrs := [?]sdl.GPUVertexAttribute {
        { location = 0, buffer_slot = 0, format = .FLOAT2,      offset = 0 },
        { location = 1, buffer_slot = 1, format = .FLOAT2,      offset = u32(offset_of(Instance, pos)) },
        { location = 2, buffer_slot = 1, format = .UBYTE4_NORM, offset = u32(offset_of(Instance, color)) },
    };
    r.particle_pipeline = create_pipeline(gpu, swapchain_format, "particle", {
        vert_spv       = PARTICLE_VERT_SPV,
        frag_spv       = PARTICLE_FRAG_SPV,
        primitive      = .TRIANGLESTRIP,
        vertex_buffers = particle_buffers[:],
        vertex_attrs   = particle_attrs[:],
        blend          = BLEND_ADDITIVE,
    });

    // Starfield: no vertex input, the vertex shader builds a fullscreen
    // triangle from its index.
    r.star_pipeline = create_pipeline(gpu, swapchain_format, "star", {
        vert_spv  = STAR_VERT_SPV,
        frag_spv  = STAR_FRAG_SPV,
        primitive = .TRIANGLELIST,
        blend     = BLEND_ADDITIVE,
    });

    // HUD: pixel-space colored triangles.
    hud_buffers := [?]sdl.GPUVertexBufferDescription {
        { slot = 0, pitch = size_of(Hud_Vertex), input_rate = .VERTEX },
    };
    hud_attrs := [?]sdl.GPUVertexAttribute {
        { location = 0, buffer_slot = 0, format = .FLOAT2,      offset = u32(offset_of(Hud_Vertex, pos)) },
        { location = 1, buffer_slot = 0, format = .UBYTE4_NORM, offset = u32(offset_of(Hud_Vertex, color)) },
    };
    r.hud_pipeline = create_pipeline(gpu, swapchain_format, "HUD", {
        vert_spv       = HUD_VERT_SPV,
        frag_spv       = HUD_FRAG_SPV,
        primitive      = .TRIANGLELIST,
        vertex_buffers = hud_buffers[:],
        vertex_attrs   = hud_attrs[:],
        blend          = BLEND_ALPHA,
    });

    if r.particle_pipeline == nil || r.star_pipeline == nil || r.hud_pipeline == nil {
        return; // create_pipeline already logged which one failed
    }

    // --- Buffers -------------------------------------------------------------
    r.instance_vbo  = sdl.CreateGPUBuffer(gpu, { usage = { .VERTEX }, size = MAX_BODIES * size_of(Instance) });
    r.instance_xfer = sdl.CreateGPUTransferBuffer(gpu, { usage = .UPLOAD, size = MAX_BODIES * size_of(Instance) });
    r.hud_vbo       = sdl.CreateGPUBuffer(gpu, { usage = { .VERTEX }, size = HUD_MAX_VERTS * size_of(Hud_Vertex) });
    r.hud_xfer      = sdl.CreateGPUTransferBuffer(gpu, { usage = .UPLOAD, size = HUD_MAX_VERTS * size_of(Hud_Vertex) });
    r.quad_vbo      = sdl.CreateGPUBuffer(gpu, { usage = { .VERTEX }, size = 4 * size_of(Vec2) });
    if r.instance_vbo == nil || r.instance_xfer == nil || r.hud_vbo == nil || r.hud_xfer == nil || r.quad_vbo == nil {
        return r, log_error("Failed to create GPU buffers");
    }

    // Upload the static unit quad once (corners for a triangle strip).
    corners := [4]Vec2 { {-1, -1}, {1, -1}, {-1, 1}, {1, 1} };
    quad_xfer := sdl.CreateGPUTransferBuffer(gpu, { usage = .UPLOAD, size = size_of(corners) });
    mapped := sdl.MapGPUTransferBuffer(gpu, quad_xfer, false);
    mem.copy(mapped, raw_data(corners[:]), size_of(corners));
    sdl.UnmapGPUTransferBuffer(gpu, quad_xfer);

    cmd := sdl.AcquireGPUCommandBuffer(gpu);
    copy_pass := sdl.BeginGPUCopyPass(cmd);
    sdl.UploadToGPUBuffer(copy_pass,
        { transfer_buffer = quad_xfer, offset = 0 },
        { buffer = r.quad_vbo, offset = 0, size = size_of(corners) },
        false,
    );
    sdl.EndGPUCopyPass(copy_pass);
    if !sdl.SubmitGPUCommandBuffer(cmd) {
        return r, log_error("Failed to upload quad buffer");
    }
    sdl.ReleaseGPUTransferBuffer(gpu, quad_xfer);

    ok = true;
    return;
}

destroy_renderer :: proc(gpu: ^sdl.GPUDevice, r: ^Renderer) {
    sdl.ReleaseGPUBuffer(gpu, r.quad_vbo);
    sdl.ReleaseGPUBuffer(gpu, r.instance_vbo);
    sdl.ReleaseGPUTransferBuffer(gpu, r.instance_xfer);
    sdl.ReleaseGPUBuffer(gpu, r.hud_vbo);
    sdl.ReleaseGPUTransferBuffer(gpu, r.hud_xfer);
    sdl.ReleaseGPUGraphicsPipeline(gpu, r.particle_pipeline);
    sdl.ReleaseGPUGraphicsPipeline(gpu, r.star_pipeline);
    sdl.ReleaseGPUGraphicsPipeline(gpu, r.hud_pipeline);
}

render :: proc(
    gpu:       ^sdl.GPUDevice,
    window:    ^sdl.Window,
    r:         ^Renderer,
    instances: []Instance,
    hud_verts: []Hud_Vertex,
    camera:    Camera_UBO,
) -> (ok: bool) {
    // Never upload past the fixed-size HUD buffer; trim to whole triangles.
    hud_verts := hud_verts;
    if len(hud_verts) > HUD_MAX_VERTS do hud_verts = hud_verts[:HUD_MAX_VERTS / 3 * 3];

    // Stage instance + HUD data into their transfer buffers.
    if len(instances) > 0 {
        dst := sdl.MapGPUTransferBuffer(gpu, r.instance_xfer, true);
        mem.copy(dst, raw_data(instances), len(instances) * size_of(Instance));
        sdl.UnmapGPUTransferBuffer(gpu, r.instance_xfer);
    }
    if len(hud_verts) > 0 {
        dst := sdl.MapGPUTransferBuffer(gpu, r.hud_xfer, true);
        mem.copy(dst, raw_data(hud_verts), len(hud_verts) * size_of(Hud_Vertex));
        sdl.UnmapGPUTransferBuffer(gpu, r.hud_xfer);
    }

    cmd := sdl.AcquireGPUCommandBuffer(gpu);
    if cmd == nil do return log_error("Failed to acquire command buffer");

    // Copy pass: transfer -> GPU buffers.
    copy_pass := sdl.BeginGPUCopyPass(cmd);
    if len(instances) > 0 {
        sdl.UploadToGPUBuffer(copy_pass,
            { transfer_buffer = r.instance_xfer, offset = 0 },
            { buffer = r.instance_vbo, offset = 0, size = u32(len(instances) * size_of(Instance)) },
            false,
        );
    }
    if len(hud_verts) > 0 {
        sdl.UploadToGPUBuffer(copy_pass,
            { transfer_buffer = r.hud_xfer, offset = 0 },
            { buffer = r.hud_vbo, offset = 0, size = u32(len(hud_verts) * size_of(Hud_Vertex)) },
            false,
        );
    }
    sdl.EndGPUCopyPass(copy_pass);

    w, h: i32;
    sdl.GetWindowSizeInPixels(window, &w, &h);
    cam := camera;
    viewport := Viewport_UBO { viewport_size = { f32(w), f32(h) } };

    swapchain: ^sdl.GPUTexture;
    if !sdl.WaitAndAcquireGPUSwapchainTexture(cmd, window, &swapchain, nil, nil) {
        return log_error("Failed to acquire swapchain texture");
    }

    if swapchain != nil {
        color_target := sdl.GPUColorTargetInfo {
            texture     = swapchain,
            load_op     = .CLEAR,
            clear_color = { 0.02, 0.02, 0.05, 1 },
            store_op    = .STORE,
        };
        pass := sdl.BeginGPURenderPass(cmd, &color_target, 1, nil);

        // Procedural starfield first (behind everything): one fullscreen
        // triangle, no vertex buffer, the shader reconstructs world space from
        // the camera uniform.
        sdl.BindGPUGraphicsPipeline(pass, r.star_pipeline);
        sdl.PushGPUVertexUniformData(cmd, 0, &cam, size_of(cam));
        sdl.DrawGPUPrimitives(pass, 3, 1, 0, 0);

        // Particles: bind quad (slot 0) + instances (slot 1), draw 4 verts * N.
        if len(instances) > 0 {
            sdl.BindGPUGraphicsPipeline(pass, r.particle_pipeline);
            sdl.PushGPUVertexUniformData(cmd, 0, &cam, size_of(cam));
            bindings := [2]sdl.GPUBufferBinding {
                { buffer = r.quad_vbo,     offset = 0 },
                { buffer = r.instance_vbo, offset = 0 },
            };
            sdl.BindGPUVertexBuffers(pass, 0, raw_data(bindings[:]), 2);
            sdl.DrawGPUPrimitives(pass, 4, u32(len(instances)), 0, 0);
        }

        // HUD: same uniform slot, different data.
        if len(hud_verts) > 0 {
            sdl.BindGPUGraphicsPipeline(pass, r.hud_pipeline);
            sdl.PushGPUVertexUniformData(cmd, 0, &viewport, size_of(viewport));
            hud_binding := sdl.GPUBufferBinding { buffer = r.hud_vbo, offset = 0 };
            sdl.BindGPUVertexBuffers(pass, 0, &hud_binding, 1);
            sdl.DrawGPUPrimitives(pass, u32(len(hud_verts)), 1, 0, 0);
        }

        sdl.EndGPURenderPass(pass);
    }

    if !sdl.SubmitGPUCommandBuffer(cmd) {
        return log_error("Failed to submit command buffer");
    }
    ok = true;
    return;
}
