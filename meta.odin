package main;

import "core:fmt";
import "core:os";
import "core:strings";
import "core:flags";
import "core:time";

import "src/lane";


Options :: struct {
    target:  string `args:"pos=0,required" usage:"Target to be built (folder name inside ./examples)."`,
    release: bool   `usage:"Build {target} in release mode."`,
    run:     bool   `usage:"Runs {target} after building."`,
    // TODO: shaders_only: bool `usage:"Only compile {target}'s shaders."`,
    // TODO: clean: bool `usage:"Deletes previous outputs and rebuilds from scratch."`,
    threads: int    `usage:"Number of threads to use."`,
}

Shader_Target :: struct {
    input:  string,
    output: string,
    stderr: []byte,
}
Shader_Comp_Ctx :: struct {
    shader_targets: []Shader_Target,
    successful:     int,
    failed:         int,
}

main :: proc() {
    context.allocator = context.temp_allocator;

    options: Options;
    flags.parse_or_exit(&options, os.args, .Odin);

    cwd, _ := os.get_absolute_path(".", context.temp_allocator);
    target_path, _ := os.join_path({ cwd, "examples", options.target }, context.temp_allocator);
    if !os.is_directory(target_path) {
        fmt.printfln("Error: Target {} doesn't exist.", options.target);
        os.exit(1);
    }
    target_data_path, _ := os.join_path({ cwd, "data", options.target }, context.temp_allocator);
    if !os.is_directory(target_data_path) {
        err := os.mkdir_all(target_data_path);
        if err != nil {
            fmt.printfln("Error: Failed to create data folder: {}.", target_data_path);
            os.exit(1);
        }
    }

    lane.init(max(0, options.threads));
    defer lane.deinit();

    if is_shadercross_available() {
        shader_targets, skipped := find_hlsl_targets(target_path, target_data_path);
        if len(shader_targets) > 0 {
            fmt.printfln("Compiling {} shaders on {} thread(s)...", len(shader_targets), lane.capacity());
            ctx := Shader_Comp_Ctx { shader_targets = shader_targets };

            time_base := time.tick_now();
            lane.split(compile_shaders, &ctx);
            comp_time := time.tick_since(time_base);

            has_failed := ctx.failed > 0;
            if ctx.successful > 0 || has_failed {
                for st in ctx.shader_targets {
                    if len(st.stderr) > 0 do os.write(os.stderr, st.stderr);
                }
                fmt.printfln("Shader compilation complete in {}: {} successful, {} failed, {} skipped.", time.duration_round(comp_time, time.Millisecond), ctx.successful, ctx.failed, skipped);
            }
            if has_failed do os.exit(1);
        }
    }

    EXE_EXT :: ".exe" when ODIN_OS == .Windows else "";
    bin_path, _ := os.join_path({ cwd, "bin", strings.concatenate({ options.target, EXE_EXT }) }, context.temp_allocator);

    // Compile program
    {
        command: [dynamic]string;
        append(&command, "odin", "build", target_path, fmt.tprintf("-out:{}", bin_path), "-collection:shade=src", "-show-timings", "-max-error-count:4");
        if options.release {
            append(&command, "-microarch:native", "-o:speed", "-disable-assert", "-no-bounds-check");
        } else {
            append(&command, "-o:none", "-debug");
        }

        p, _ := os.process_start({ command = command[:], stdout = os.stdout, stderr = os.stderr });
        state, err := os.process_wait(p);
        if state.exit_code != 0 || err != nil do os.exit(1);
        fmt.printfln("Build finished successfully.");
    }

    if options.run {
        p, _ := os.process_start({ command = { bin_path }, working_dir = target_data_path });
        state, _ := os.process_wait(p);
    }

    return;
}

is_shadercross_available :: proc() -> bool {
    _, _, _, err := os.process_exec({ command = { "shadercross", "--help" } }, context.temp_allocator);
    return err == nil;
}

find_hlsl_targets :: proc(target_path: string, target_data_path: string) -> (targets: []Shader_Target, skipped: int) {
    BACKEND_FORMATS :: [?]string { "spv", "dxil", "msl" };
    tdyn: [dynamic]Shader_Target;

    shaders_data_path, _ := os.join_path({ target_data_path, "shaders" }, context.temp_allocator);
    err := os.mkdir_all(shaders_data_path);
    if err != nil {
        fmt.printfln("Error: Failed to create shaders folder: {}", shaders_data_path);
        os.exit(1);
    }

    glob_pattern, _ := os.join_path({ target_path, "shaders", "*.hlsl" }, context.temp_allocator);
    files, _ := os.glob(glob_pattern);
    for f in files {
        output_stem, _ := os.join_path({ shaders_data_path, os.stem(f) }, context.temp_allocator);
        info, err := os.stat(f, context.temp_allocator);
        if err != nil {
            skipped += len(BACKEND_FORMATS);
            continue;
        }

        for format in BACKEND_FORMATS {
            output := fmt.tprintf("{}.{}", output_stem, format);
            out_info, err := os.stat(output, context.temp_allocator);
            // size > 0: a failed shadercross run leaves a truncated output behind.
            if err == nil && out_info.size > 0 && time.diff(info.modification_time, out_info.modification_time) > 0 {
                skipped += 1;
                continue;
            }

            sc: Shader_Target = {
                input  = f,
                output = output,
            };
            append(&tdyn, sc);
        }
    }

    targets = tdyn[:];
    return;
}

compile_shaders :: proc(ctx: ^Shader_Comp_Ctx) {
    totals: [2]int;

    cursor := 0;
    cursor_ptr := lane.share(&cursor);
    for i in lane.grab(cursor_ptr, len(ctx.shader_targets), 1) {
        st := &ctx.shader_targets[i];
        fmt.printfln("Compiling shader target: {}...", st.output);

        state, _, stderr, err := os.process_exec({ command = { "shadercross", st.input, "-o", st.output } }, context.temp_allocator);
        if state.exit_code == 0 && err == nil {
            totals[0] += 1;
        } else {
            totals[1] += 1;
            st.stderr = stderr;
            os.remove(st.output);
        }
    }

    total := lane.sum(totals);
    if lane.is_main() {
        ctx.successful = total[0];
        ctx.failed = total[1];
    }
}
