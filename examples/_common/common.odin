package common;

import "core:fmt";
import "core:os";

import sdl "vendor:sdl3";


SHADER_FORMATS :: sdl.GPUShaderFormat { .SPIRV, .DXIL, .MSL };

// Creates a graphics pipeline from shaders the metaprogram compiled into the
// data folder (the examples' working directory at runtime).
//
// `shaders` holds one info per stage the pipeline uses; set `stage` and the
// resource counts, the rest gets good defaults: format is the best one the
// device supports (DXIL preferred on Windows), entrypoint matches what
// shadercross emits for that format, and code is read from
// "{name}.{stage}.{format}" (e.g. "particle.vert.dxil") relative to the
// working directory.
//
// `info` needs everything but its shaders, which are created here and released
// after pipeline creation. Returns nil on failure with the error in sdl.GetError().
create_pipeline :: proc(
    gpu:     ^sdl.GPUDevice,
    name:    string,
    shaders: []sdl.GPUShaderCreateInfo,
    info:    sdl.GPUGraphicsPipelineCreateInfo,
) -> ^sdl.GPUGraphicsPipeline {
    // Extensions in shadercross format.
    stage_ext := [sdl.GPUShaderStage]string {
        .VERTEX   = "vert",
        .FRAGMENT = "frag",
    };
    format_ext := #partial [sdl.GPUShaderFormatFlag]string {
        .SPIRV = "spv",
        .DXIL  = "dxil",
        .MSL   = "msl",
    };

    format, has_format := pick_shader_format(gpu);
    if !has_format {
        sdl.SetError("device supports none of the compiled shader formats");
        return nil;
    }

    created: [sdl.GPUShaderStage]^sdl.GPUShader;
    defer for shader in created do if shader != nil do sdl.ReleaseGPUShader(gpu, shader);

    for shader in shaders {
        shader := shader;
        if shader.format == {} do shader.format = { format };
        if shader.entrypoint == nil {
            // shadercross renames the entrypoint when transpiling to MSL.
            shader.entrypoint = "main0" if format == .MSL else "main";
        }
        if shader.code == nil {
            filename := fmt.tprintf("{}.{}.{}", name, stage_ext[shader.stage], format_ext[format]);
            path, _ := os.join_path({ "shaders", filename }, context.temp_allocator);
            code, err := os.read_entire_file(path, context.temp_allocator);
            if err != nil {
                sdl.SetError("%s", fmt.ctprintf("failed to read shader \"{}\": {}", path, err));
                return nil;
            }
            shader.code      = raw_data(code);
            shader.code_size = len(code);
        }

        created[shader.stage] = sdl.CreateGPUShader(gpu, shader);
        if created[shader.stage] == nil do return nil;
    }

    info := info;
    info.vertex_shader   = created[.VERTEX];
    info.fragment_shader = created[.FRAGMENT];
    return sdl.CreateGPUGraphicsPipeline(gpu, info);
}

// The best format the device accepts among the ones we ship. In practice a
// device reports exactly one of them (D3D12 -> DXIL, Vulkan -> SPIRV,
// Metal -> MSL); DXIL goes first so it wins on Windows if there's ever a tie.
@(private)
pick_shader_format :: proc(gpu: ^sdl.GPUDevice) -> (format: sdl.GPUShaderFormatFlag, ok: bool) {
    available := sdl.GetGPUShaderFormats(gpu) & SHADER_FORMATS;
    for f in ([?]sdl.GPUShaderFormatFlag { .DXIL, .SPIRV, .MSL }) {
        if f in available do return f, true;
    }
    return .PRIVATE, false;
}
