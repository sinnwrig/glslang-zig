const std = @import("std");
const builtin = @import("builtin");
const Build = std.Build;

/// When building from source, which repository and revision to clone.
const spirv_tools_repository = "https://github.com/KhronosGroup/SPIRV-Tools";
const spirv_headers_repository = "https://github.com/KhronosGroup/SPIRV-Headers";

const log = std.log.scoped(.glslang_zig);

const tools_prefix = "SPIRV-Tools";
const headers_prefix = "SPIRV-Headers";

pub fn build(b: *Build) !void {
    const optimize = b.standardOptimizeOption(.{});
    const target = b.standardTargetOptions(.{});
    const debug_symbols = b.option(bool, "debug_symbols", "Whether to produce detailed debug symbols (g0) or not. These increase binary size considerably.") orelse false;
    const build_shared = b.option(bool, "shared", "Build spirv-tools as a shared library") orelse false;

    _ = build_spirv(b, optimize, target, debug_symbols, build_shared);
}

pub fn build_spirv(b: *Build, optimize: std.builtin.OptimizeMode, target: std.ResolvedTarget, debug_symbols: bool, build_shared: bool) *std.Build.Step.Compile {
    var cflags = std.ArrayList([]const u8).init(b.allocator);
    var cppflags = std.ArrayList([]const u8).init(b.allocator);

    if (!debug_symbols) {
        try cflags.append("-g0");
        try cppflags.append("-g0");
    }

    try cppflags.append("-std=c++17");

    const base_flags = &.{
        "-Wno-unused-command-line-argument",
        "-Wno-unused-variable",
        "-Wno-missing-exception-spec",
        "-Wno-macro-redefined",
        "-Wno-unknown-attributes",
        "-Wno-implicit-fallthrough",
        "-fms-extensions",
    };

    try cflags.appendSlice(base_flags);
    try cppflags.appendSlice(base_flags);

    const spirv_cpp_sources =
        spirv_tools ++
        spirv_tools_util ++
        spirv_tools_reduce ++
        spirv_tools_link ++
        spirv_tools_val ++
        // spirv_tools_wasm ++ // Wasm build support- requires emscripten toolchain
        spirv_tools_opt;

    var spv_lib = null;

    if (build_shared) {
        spv_lib = b.addSharedLibrary(.{
            .name = "SPIRV-Tools",
            .root_source_file = b.addWriteFiles().add("empty.c", ""),
            .optimize = optimize,
            .target = target,
        });
    } else {
        spv_lib = b.addStaticLibrary(.{
            .name = "SPIRV-Tools",
            .root_source_file = b.addWriteFiles().add("empty.c", ""),
            .optimize = optimize,
            .target = target,
        });
    }

    if (target.result.os.tag == .windows) {
        spv_lib.defineCMacro("SPIRV_WINDOWS", "");
    } else if (target.result.os.tag == .linux) {
        spv_lib.defineCMacro("SPIRV_LINUX", "");
    } else if (target.result.os.tag == .macos) {
        spv_lib.defineCMacro("SPIRV_MAC", "");
    } else if (target.result.os.tag == .ios) {
        spv_lib.defineCMacro("SPIRV_IOS", "");
    } else if (target.result.os.tag == .tvos) {
        spv_lib.defineCMacro("SPIRV_TVOS", "");
    } else if (target.result.os.tag == .kfreebsd) {
        spv_lib.defineCMacro("SPIRV_FREEBSD", "");
    } else if (target.result.os.tag == .openbsd) {
        spv_lib.defineCMacro("SPIRV_OPENBSD", "");
    } else if (target.result.os.tag == .fuchsia) {
        spv_lib.defineCMacro("SPIRV_FUCHSIA", "");
    } else {
        log.err("Compilation target incompatible with SPIR-V.", .{});
        std.process.exit(1);
    }

    var download_source = DownloadSourceStep.init(b);

    download_source.repository = spirv_tools_repository;
    download_source.revision = "";
    download_source.output = tools_prefix;

    var download_headers = DownloadSourceStep.init(b);

    download_headers.repository = spirv_headers_repository;
    download_headers.revision = "";
    download_headers.output = headers_prefix;

    var build_grammar = BuildSPIRVGrammarStep.init(b);

    spv_lib.step.dependOn(&download_source);
    spv_lib.step.dependOn(&download_headers);
    spv_lib.step.dependOn(&build_grammar.step);

    spv_lib.addCSourceFiles(.{
        .files = &spirv_cpp_sources,
        .flags = cppflags.items,
    });

    spv_lib.defineCMacro("SPIRV_COLOR_TERMINAL", ""); // Pretty lights by default

    addSPIRVIncludes(spv_lib);
    linkSPIRVDependencies(spv_lib);

    b.installArtifact(spv_lib);

    return spv_lib;
}

fn linkSPIRVDependencies(step: *std.Build.Step.Compile) void {
    const target = step.rootModuleTarget();

    if (target.abi == .msvc) {
        step.linkLibC();
    } else {
        step.linkLibCpp();
    }

    if (target.os.tag == .windows) {
        step.linkSystemLibrary("ole32");
        step.linkSystemLibrary("oleaut32");
    }
}

fn addSPIRVIncludes(step: *std.Build.Step.Compile) void {
    // Generated SPIR-V headers get thrown in here
    step.addIncludePath(.{ .path = "generated-include" });

    step.addIncludePath(.{ .path = tools_prefix ++ "/external/SPIRV-Tools" });
    step.addIncludePath(.{ .path = tools_prefix ++ "/external/SPIRV-Tools/include" });
    step.addIncludePath(.{ .path = tools_prefix ++ "/external/SPIRV-Tools/source" });

    step.addIncludePath(.{ .path = tools_prefix ++ "/external/SPIRV-Headers/include" });
}

fn ensureCommandExists(allocator: std.mem.Allocator, name: []const u8, exist_check: []const u8) bool {
    const result = std.ChildProcess.run(.{
        .allocator = allocator,
        .argv = &[_][]const u8{ name, exist_check },
        .cwd = ".",
    }) catch // e.g. FileNotFound
        {
        return false;
    };

    defer {
        allocator.free(result.stderr);
        allocator.free(result.stdout);
    }

    if (result.term.Exited != 0)
        return false;

    return true;
}

// ------------------------------------------
// Source cloning logic
// ------------------------------------------

fn ensureGitRepoCloned(allocator: std.mem.Allocator, clone_url: []const u8, revision: []const u8, dir: []const u8) !void {
    if (isEnvVarTruthy(allocator, "NO_ENSURE_SUBMODULES") or isEnvVarTruthy(allocator, "NO_ENSURE_GIT")) {
        return;
    }

    ensureGit(allocator);

    if (std.fs.openDirAbsolute(dir, .{})) |_| {
        const current_revision = try getCurrentGitRevision(allocator, dir);
        if (!std.mem.eql(u8, current_revision, revision)) {
            // Reset to the desired revision
            exec(allocator, &[_][]const u8{ "git", "fetch" }, dir) catch |err| log.warn("failed to 'git fetch' in {s}: {s}\n", .{ dir, @errorName(err) });
            try exec(allocator, &[_][]const u8{ "git", "checkout", "--quiet", "--force", revision }, dir);
            try exec(allocator, &[_][]const u8{ "git", "submodule", "update", "--init", "--recursive" }, dir);
        }
        return;
    } else |err| return switch (err) {
        error.FileNotFound => {
            log.info("cloning required dependency..\ngit clone {s} {s}..\n", .{ clone_url, dir });

            try exec(allocator, &[_][]const u8{ "git", "clone", "-c", "core.longpaths=true", clone_url, dir }, sdkPath("/"));
            try exec(allocator, &[_][]const u8{ "git", "checkout", "--quiet", "--force", revision }, dir);
            try exec(allocator, &[_][]const u8{ "git", "submodule", "update", "--init", "--recursive" }, dir);
            return;
        },
        else => err,
    };
}

fn getCurrentGitRevision(allocator: std.mem.Allocator, cwd: []const u8) ![]const u8 {
    const result = try std.ChildProcess.run(.{ .allocator = allocator, .argv = &.{ "git", "rev-parse", "HEAD" }, .cwd = cwd });
    allocator.free(result.stderr);
    if (result.stdout.len > 0) return result.stdout[0 .. result.stdout.len - 1]; // trim newline
    return result.stdout;
}

// Command validation logic moved to ensureCommandExists()
fn ensureGit(allocator: std.mem.Allocator) void {
    if (!ensureCommandExists(allocator, "git", "--version")) {
        log.err("'git --version' failed. Is git not installed?", .{});
        std.process.exit(1);
    }
}

fn exec(allocator: std.mem.Allocator, argv: []const []const u8, cwd: []const u8) !void {
    log.info("cd {s}", .{cwd});
    var buf = std.ArrayList(u8).init(allocator);
    for (argv) |arg| {
        try std.fmt.format(buf.writer(), "{s} ", .{arg});
    }
    log.info("{s}", .{buf.items});

    var child = std.ChildProcess.init(argv, allocator);
    child.cwd = cwd;
    _ = try child.spawnAndWait();
}

fn isEnvVarTruthy(allocator: std.mem.Allocator, name: []const u8) bool {
    if (std.process.getEnvVarOwned(allocator, name)) |truthy| {
        defer allocator.free(truthy);
        if (std.mem.eql(u8, truthy, "true")) return true;
        return false;
    } else |_| {
        return false;
    }
}

fn sdkPath(comptime suffix: []const u8) []const u8 {
    if (suffix[0] != '/') @compileError("suffix must be an absolute path");
    return comptime blk: {
        const root_dir = std.fs.path.dirname(@src().file) orelse ".";
        break :blk root_dir ++ suffix;
    };
}

var download_mutex = std.Thread.Mutex{};

const DownloadSourceStep = struct {
    repository: []const u8,
    revision: []const u8,
    output: []const u8,
    step: std.Build.Step,
    b: *std.Build,

    fn init(b: *std.Build) *DownloadSourceStep {
        const download_step = b.allocator.create(DownloadSourceStep) catch unreachable;
        download_step.* = .{
            .step = std.Build.Step.init(.{
                .id = .custom,
                .name = "download",
                .owner = b,
                .makeFn = &make,
            }),
            .b = b,
        };
        return download_step;
    }

    fn make(step_ptr: *std.Build.Step, prog_node: *std.Progress.Node) anyerror!void {
        _ = prog_node;

        const download_step: DownloadSourceStep = @fieldParentPtr("step", step_ptr);
        const b = download_step.b;

        // Zig will run build steps in parallel if possible, so if there were two invocations of
        // then this function would be called in parallel. We're manipulating the FS here
        // and so need to prevent that.
        download_mutex.lock();
        defer download_mutex.unlock();

        try ensureGitRepoCloned(b.allocator, download_step.repository, download_step.revision, download_step.output);
    }
};

// ------------------------------------------
// SPIR-V include generation logic
// ------------------------------------------

fn ensurePython(allocator: std.mem.Allocator) void {
    if (!ensureCommandExists(allocator, "python3", "--version")) {
        log.err("'python3 --version' failed. Is python not installed?", .{});
        std.process.exit(1);
    }
}

const spirv_headers_path = tools_prefix ++ "/external/SPIRV-Headers";
const spirv_tools_path = tools_prefix ++ "/external/SPIRV-Tools";
const spirv_output_path = "generated-include/spirv-tools";

const grammar_tables_script = spirv_tools_path ++ "/utils/generate_grammar_tables.py";

const debuginfo_insts_file = spirv_headers_path ++ "/include/spirv/unified1/extinst.debuginfo.grammar.json";
const cldebuginfo100_insts_file = spirv_headers_path ++ "/include/spirv/unified1/extinst.opencl.debuginfo.100.grammar.json";

fn spvHeaderFile(comptime version: []const u8, comptime file_name: []const u8) []const u8 {
    return spirv_headers_path ++ "/include/spirv/" ++ version ++ "/" ++ file_name;
}

// Most of this was derived from the BUILD.gn file in SPIRV-Tools

fn genSPIRVCoreTables(allocator: std.mem.Allocator, comptime version: []const u8) void {
    const core_json_file = spvHeaderFile(version, "spirv.core.grammar.json");

    // Outputs
    const core_insts_file = spirv_output_path ++ "/core.insts-" ++ version ++ ".inc";
    const operand_kinds_file = spirv_output_path ++ "/operand.kinds-" ++ version ++ ".inc";

    const args = &[_][]const u8{ "python3", grammar_tables_script, "--spirv-core-grammar", core_json_file, "--core-insts-output", core_insts_file, "--extinst-debuginfo-grammar", debuginfo_insts_file, "--extinst-cldebuginfo100-grammar", cldebuginfo100_insts_file, "--operand-kinds-output", operand_kinds_file, "--output-language", "c++" };

    exec(allocator, args, sdkPath("/")) catch |err|
        {
        log.err("Failed to build SPIR-V core tables: error: {s}", .{@errorName(err)});
        std.process.exit(1);
    };
}

fn genSPIRVCoreEnums(allocator: std.mem.Allocator, comptime version: []const u8) void {
    const core_json_file = spvHeaderFile(version, "spirv.core.grammar.json");

    const extension_enum_file = spirv_output_path ++ "/extension_enum.inc";
    const extension_map_file = spirv_output_path ++ "/enum_string_mapping.inc";

    const args = &[_][]const u8{ "python3", grammar_tables_script, "--spirv-core-grammar", core_json_file, "--extinst-debuginfo-grammar", debuginfo_insts_file, "--extinst-cldebuginfo100-grammar", cldebuginfo100_insts_file, "--extension-enum-output", extension_enum_file, "--enum-string-mapping-output", extension_map_file, "--output-language", "c++" };

    exec(allocator, args, sdkPath("/")) catch |err|
        {
        log.err("Failed to build SPIR-V core enums: error: {s}", .{@errorName(err)});
        std.process.exit(1);
    };
}

fn genSPIRVGlslTables(allocator: std.mem.Allocator, comptime version: []const u8) void {
    const core_json_file = spvHeaderFile(version, "spirv.core.grammar.json");
    const glsl_json_file = spvHeaderFile(version, "extinst.glsl.std.450.grammar.json");

    const glsl_insts_file = spirv_output_path ++ "/glsl.std.450.insts.inc";

    const args = &[_][]const u8{ "python3", grammar_tables_script, "--spirv-core-grammar", core_json_file, "--extinst-debuginfo-grammar", debuginfo_insts_file, "--extinst-cldebuginfo100-grammar", cldebuginfo100_insts_file, "--extinst-glsl-grammar", glsl_json_file, "--glsl-insts-output", glsl_insts_file, "--output-language", "c++" };

    exec(allocator, args, sdkPath("/")) catch |err|
        {
        log.err("Failed to build SPIR-V GLSL tables: error: {s}", .{@errorName(err)});
        std.process.exit(1);
    };
}

fn genSPIRVOpenCLTables(allocator: std.mem.Allocator, comptime version: []const u8) void {
    const core_json_file = spvHeaderFile(version, "spirv.core.grammar.json");
    const opencl_json_file = spvHeaderFile(version, "extinst.opencl.std.100.grammar.json");

    const opencl_insts_file = spirv_output_path ++ "/opencl.std.insts.inc";

    const args = &[_][]const u8{
        "python3",                          grammar_tables_script,
        "--spirv-core-grammar",             core_json_file,
        "--extinst-debuginfo-grammar",      debuginfo_insts_file,
        "--extinst-cldebuginfo100-grammar", cldebuginfo100_insts_file,
        "--extinst-opencl-grammar",         opencl_json_file,
        "--opencl-insts-output",            opencl_insts_file,
    };

    exec(allocator, args, sdkPath("/")) catch |err|
        {
        log.err("Failed to build SPIR-V OpenCL tables: error: {s}", .{@errorName(err)});
        std.process.exit(1);
    };
}

fn genSPIRVLanguageHeader(allocator: std.mem.Allocator, comptime name: []const u8, comptime grammar_file: []const u8) void {
    const script = spirv_tools_path ++ "/utils/generate_language_headers.py";

    const extinst_output_path = spirv_output_path ++ "/" ++ name ++ ".h";

    const args = &[_][]const u8{
        "python3",               script,
        "--extinst-grammar",     grammar_file,
        "--extinst-output-path", extinst_output_path,
    };

    exec(allocator, args, sdkPath("/")) catch |err|
        {
        log.err("Failed to generate SPIR-V language header '" ++ name ++ "'. error: {s}", .{@errorName(err)});
        std.process.exit(1);
    };
}

fn genSPIRVVendorTable(allocator: std.mem.Allocator, comptime name: []const u8, comptime operand_kind_tools_prefix: []const u8) void {
    const extinst_vendor_grammar = spirv_headers_path ++ "/include/spirv/unified1/extinst." ++ name ++ ".grammar.json";
    const extinst_file = spirv_output_path ++ "/" ++ name ++ ".insts.inc";

    const args = &[_][]const u8{
        "python3",                            grammar_tables_script,
        "--extinst-vendor-grammar",           extinst_vendor_grammar,
        "--vendor-insts-output",              extinst_file,
        "--vendor-operand-kind-tools_prefix", operand_kind_tools_prefix,
    };

    exec(allocator, args, sdkPath("/")) catch |err|
        {
        log.err("Failed to generate SPIR-V vendor table '" ++ name ++ "'. error: {s}", .{@errorName(err)});
        std.process.exit(1);
    };
}

fn genSPIRVRegistryTables(allocator: std.mem.Allocator) void {
    const script = spirv_tools_path ++ "/utils/generate_registry_tables.py";

    const xml_file = spirv_headers_path ++ "/include/spirv/spir-v.xml";
    const inc_file = spirv_output_path ++ "/generators.inc";

    const args = &[_][]const u8{
        "python3",     script,
        "--xml",       xml_file,
        "--generator", inc_file,
    };

    exec(allocator, args, sdkPath("/")) catch |err|
        {
        log.err("Failed to generate SPIR-V registry tables. error: {s}", .{@errorName(err)});
        std.process.exit(1);
    };
}

fn buildSPIRVVersion(allocator: std.mem.Allocator) void {
    const script = spirv_tools_path ++ "/utils/update_build_version.py";

    const changes_file = spirv_tools_path ++ "/CHANGES";
    const inc_file = spirv_output_path ++ "/build-version.inc";

    const args = &[_][]const u8{
        "python3",    script,
        changes_file, inc_file,
    };

    exec(allocator, args, sdkPath("/")) catch |err|
        {
        log.err("Failed to generate SPIR-V build version. error: {s}", .{@errorName(err)});
        std.process.exit(1);
    };
}

fn generateSPIRVGrammar(allocator: std.mem.Allocator) void {
    ensurePython(allocator);

    genSPIRVCoreTables(allocator, "unified1");
    genSPIRVCoreEnums(allocator, "unified1");

    genSPIRVGlslTables(allocator, "1.0");

    genSPIRVOpenCLTables(allocator, "1.0");

    genSPIRVLanguageHeader(allocator, "DebugInfo", spvHeaderFile("unified1", "extinst.debuginfo.grammar.json"));
    genSPIRVLanguageHeader(allocator, "OpenCLDebugInfo100", spvHeaderFile("unified1", "extinst.opencl.debuginfo.100.grammar.json"));
    genSPIRVLanguageHeader(allocator, "NonSemanticShaderDebugInfo100", spvHeaderFile("unified1", "extinst.nonsemantic.shader.debuginfo.100.grammar.json"));

    genSPIRVVendorTable(allocator, "spv-amd-shader-explicit-vertex-parameter", "...nil...");
    genSPIRVVendorTable(allocator, "spv-amd-shader-trinary-minmax", "...nil...");
    genSPIRVVendorTable(allocator, "spv-amd-gcn-shader", "...nil...");
    genSPIRVVendorTable(allocator, "spv-amd-shader-ballot", "...nil...");
    genSPIRVVendorTable(allocator, "debuginfo", "...nil...");
    genSPIRVVendorTable(allocator, "opencl.debuginfo.100", "CLDEBUG100_");
    genSPIRVVendorTable(allocator, "nonsemantic.clspvreflection", "...nil...");
    genSPIRVVendorTable(allocator, "nonsemantic.shader.debuginfo.100", "SHDEBUG100_");

    genSPIRVRegistryTables(allocator);

    buildSPIRVVersion(allocator);
}

const BuildSPIRVGrammarStep = struct {
    step: std.Build.Step,
    b: *std.Build,

    fn init(b: *std.Build) *BuildSPIRVGrammarStep {
        const build_grammar_step = b.allocator.create(BuildSPIRVGrammarStep) catch unreachable;

        build_grammar_step.* = .{
            .step = std.Build.Step.init(.{
                .id = .custom,
                .name = "generate grammar",
                .owner = b,
                .makeFn = &make,
            }),
            .b = b,
        };

        return build_grammar_step;
    }

    fn make(step_ptr: *std.Build.Step, prog_node: *std.Progress.Node) anyerror!void {
        _ = prog_node;

        const build_grammar_step: BuildSPIRVGrammarStep = @fieldParentPtr("step", step_ptr);
        const b = build_grammar_step.b;

        // Zig will run build steps in parallel if possible, so if there were two invocations of
        // then this function would be called in parallel. We're manipulating the FS here
        // and so need to prevent that.
        download_mutex.lock();
        defer download_mutex.unlock();

        generateSPIRVGrammar(b.allocator);
    }
};

const tools_source_path = tools_prefix ++ "/source/";

const spirv_tools = [_][]const u8{
    tools_source_path ++ "spirv_reducer_options.cpp",
    tools_source_path ++ "spirv_validator_options.cpp",
    tools_source_path ++ "spirv_endian.cpp",
    tools_source_path ++ "table.cpp",
    tools_source_path ++ "text.cpp",
    tools_source_path ++ "spirv_fuzzer_options.cpp",
    tools_source_path ++ "parsed_operand.cpp",
    tools_source_path ++ "operand.cpp",
    tools_source_path ++ "assembly_grammar.cpp",
    tools_source_path ++ "text_handler.cpp",
    tools_source_path ++ "opcode.cpp",
    tools_source_path ++ "pch_source.cpp",
    tools_source_path ++ "software_version.cpp",
    tools_source_path ++ "binary.cpp",
    tools_source_path ++ "ext_inst.cpp",
    tools_source_path ++ "print.cpp",
    tools_source_path ++ "disassemble.cpp",
    tools_source_path ++ "enum_string_mapping.cpp",
    tools_source_path ++ "spirv_optimizer_options.cpp",
    tools_source_path ++ "libspirv.cpp",
    tools_source_path ++ "diagnostic.cpp",
    tools_source_path ++ "spirv_target_env.cpp",
    tools_source_path ++ "name_mapper.cpp",
    tools_source_path ++ "extensions.cpp",
};

const tools_reduce_path = tools_source_path ++ "reduce/";

const spirv_tools_reduce = [_][]const u8{
    tools_reduce_path ++ "structured_loop_to_selection_reduction_opportunity_finder.cpp",
    tools_reduce_path ++ "structured_construct_to_block_reduction_opportunity_finder.cpp",
    tools_reduce_path ++ "operand_to_undef_reduction_opportunity_finder.cpp",
    tools_reduce_path ++ "remove_block_reduction_opportunity_finder.cpp",
    tools_reduce_path ++ "change_operand_reduction_opportunity.cpp",
    tools_reduce_path ++ "remove_unused_struct_member_reduction_opportunity_finder.cpp",
    tools_reduce_path ++ "simple_conditional_branch_to_branch_opportunity_finder.cpp",
    tools_reduce_path ++ "remove_function_reduction_opportunity.cpp",
    tools_reduce_path ++ "merge_blocks_reduction_opportunity_finder.cpp",
    tools_reduce_path ++ "simple_conditional_branch_to_branch_reduction_opportunity.cpp",
    tools_reduce_path ++ "structured_construct_to_block_reduction_opportunity.cpp",
    tools_reduce_path ++ "reduction_opportunity.cpp",
    tools_reduce_path ++ "change_operand_to_undef_reduction_opportunity.cpp",
    tools_reduce_path ++ "remove_function_reduction_opportunity_finder.cpp",
    tools_reduce_path ++ "remove_selection_reduction_opportunity.cpp",
    tools_reduce_path ++ "operand_to_const_reduction_opportunity_finder.cpp",
    tools_reduce_path ++ "operand_to_dominating_id_reduction_opportunity_finder.cpp",
    tools_reduce_path ++ "remove_block_reduction_opportunity.cpp",
    tools_reduce_path ++ "reduction_pass.cpp",
    tools_reduce_path ++ "conditional_branch_to_simple_conditional_branch_reduction_opportunity.cpp",
    tools_reduce_path ++ "conditional_branch_to_simple_conditional_branch_opportunity_finder.cpp",
    tools_reduce_path ++ "remove_selection_reduction_opportunity_finder.cpp",
    tools_reduce_path ++ "pch_source_reduce.cpp",
    tools_reduce_path ++ "reduction_util.cpp",
    tools_reduce_path ++ "merge_blocks_reduction_opportunity.cpp",
    tools_reduce_path ++ "reducer.cpp",
    tools_reduce_path ++ "remove_struct_member_reduction_opportunity.cpp",
    tools_reduce_path ++ "structured_loop_to_selection_reduction_opportunity.cpp",
    tools_reduce_path ++ "reduction_opportunity_finder.cpp",
    tools_reduce_path ++ "remove_instruction_reduction_opportunity.cpp",
    tools_reduce_path ++ "remove_unused_instruction_reduction_opportunity_finder.cpp",
};

const tools_opt_path = tools_source_path ++ "opt/";

const spirv_tools_opt = [_][]const u8{
    tools_opt_path ++ "loop_unswitch_pass.cpp",
    tools_opt_path ++ "eliminate_dead_output_stores_pass.cpp",
    tools_opt_path ++ "dominator_tree.cpp",
    tools_opt_path ++ "flatten_decoration_pass.cpp",
    tools_opt_path ++ "convert_to_half_pass.cpp",
    tools_opt_path ++ "loop_unroller.cpp",
    tools_opt_path ++ "interface_var_sroa.cpp",
    tools_opt_path ++ "wrap_opkill.cpp",
    tools_opt_path ++ "inst_debug_printf_pass.cpp",
    tools_opt_path ++ "liveness.cpp",
    tools_opt_path ++ "eliminate_dead_io_components_pass.cpp",
    tools_opt_path ++ "feature_manager.cpp",
    tools_opt_path ++ "instrument_pass.cpp",
    tools_opt_path ++ "scalar_replacement_pass.cpp",
    tools_opt_path ++ "loop_dependence_helpers.cpp",
    tools_opt_path ++ "redundancy_elimination.cpp",
    tools_opt_path ++ "strip_nonsemantic_info_pass.cpp",
    tools_opt_path ++ "aggressive_dead_code_elim_pass.cpp",
    tools_opt_path ++ "fix_func_call_arguments.cpp",
    tools_opt_path ++ "fold_spec_constant_op_and_composite_pass.cpp",
    tools_opt_path ++ "dataflow.cpp",
    tools_opt_path ++ "block_merge_util.cpp",
    tools_opt_path ++ "pass.cpp",
    tools_opt_path ++ "relax_float_ops_pass.cpp",
    tools_opt_path ++ "interp_fixup_pass.cpp",
    tools_opt_path ++ "instruction.cpp",
    tools_opt_path ++ "folding_rules.cpp",
    tools_opt_path ++ "inst_bindless_check_pass.cpp",
    tools_opt_path ++ "ssa_rewrite_pass.cpp",
    tools_opt_path ++ "inline_exhaustive_pass.cpp",
    tools_opt_path ++ "amd_ext_to_khr.cpp",
    tools_opt_path ++ "dead_branch_elim_pass.cpp",
    tools_opt_path ++ "loop_dependence.cpp",
    tools_opt_path ++ "eliminate_dead_constant_pass.cpp",
    tools_opt_path ++ "simplification_pass.cpp",
    tools_opt_path ++ "eliminate_dead_functions_pass.cpp",
    tools_opt_path ++ "loop_fusion_pass.cpp",
    tools_opt_path ++ "decoration_manager.cpp",
    tools_opt_path ++ "debug_info_manager.cpp",
    tools_opt_path ++ "basic_block.cpp",
    tools_opt_path ++ "switch_descriptorset_pass.cpp",
    tools_opt_path ++ "code_sink.cpp",
    tools_opt_path ++ "fix_storage_class.cpp",
    tools_opt_path ++ "convert_to_sampled_image_pass.cpp",
    tools_opt_path ++ "graphics_robust_access_pass.cpp",
    tools_opt_path ++ "inline_opaque_pass.cpp",
    tools_opt_path ++ "strip_debug_info_pass.cpp",
    tools_opt_path ++ "dominator_analysis.cpp",
    tools_opt_path ++ "upgrade_memory_model.cpp",
    tools_opt_path ++ "loop_peeling.cpp",
    tools_opt_path ++ "register_pressure.cpp",
    tools_opt_path ++ "unify_const_pass.cpp",
    tools_opt_path ++ "replace_desc_array_access_using_var_index.cpp",
    tools_opt_path ++ "analyze_live_input_pass.cpp",
    tools_opt_path ++ "invocation_interlock_placement_pass.cpp",
    tools_opt_path ++ "scalar_analysis.cpp",
    tools_opt_path ++ "local_redundancy_elimination.cpp",
    tools_opt_path ++ "inst_buff_addr_check_pass.cpp",
    tools_opt_path ++ "const_folding_rules.cpp",
    tools_opt_path ++ "trim_capabilities_pass.cpp",
    tools_opt_path ++ "reduce_load_size.cpp",
    tools_opt_path ++ "build_module.cpp",
    tools_opt_path ++ "local_single_store_elim_pass.cpp",
    tools_opt_path ++ "mem_pass.cpp",
    tools_opt_path ++ "module.cpp",
    tools_opt_path ++ "scalar_analysis_simplification.cpp",
    tools_opt_path ++ "function.cpp",
    tools_opt_path ++ "desc_sroa.cpp",
    tools_opt_path ++ "def_use_manager.cpp",
    tools_opt_path ++ "compact_ids_pass.cpp",
    tools_opt_path ++ "workaround1209.cpp",
    tools_opt_path ++ "instruction_list.cpp",
    tools_opt_path ++ "loop_fission.cpp",
    tools_opt_path ++ "strength_reduction_pass.cpp",
    tools_opt_path ++ "remove_unused_interface_variables_pass.cpp",
    tools_opt_path ++ "fold.cpp",
    tools_opt_path ++ "ccp_pass.cpp",
    tools_opt_path ++ "if_conversion.cpp",
    tools_opt_path ++ "value_number_table.cpp",
    tools_opt_path ++ "loop_descriptor.cpp",
    tools_opt_path ++ "inline_pass.cpp",
    tools_opt_path ++ "struct_cfg_analysis.cpp",
    tools_opt_path ++ "composite.cpp",
    tools_opt_path ++ "freeze_spec_constant_value_pass.cpp",
    tools_opt_path ++ "cfg.cpp",
    tools_opt_path ++ "ir_loader.cpp",
    tools_opt_path ++ "licm_pass.cpp",
    tools_opt_path ++ "replace_invalid_opc.cpp",
    tools_opt_path ++ "propagator.cpp",
    tools_opt_path ++ "types.cpp",
    tools_opt_path ++ "private_to_local_pass.cpp",
    tools_opt_path ++ "spread_volatile_semantics.cpp",
    tools_opt_path ++ "dead_variable_elimination.cpp",
    tools_opt_path ++ "loop_utils.cpp",
    tools_opt_path ++ "local_access_chain_convert_pass.cpp",
    tools_opt_path ++ "cfg_cleanup_pass.cpp",
    tools_opt_path ++ "combine_access_chains.cpp",
    tools_opt_path ++ "copy_prop_arrays.cpp",
    tools_opt_path ++ "type_manager.cpp",
    tools_opt_path ++ "ir_context.cpp",
    tools_opt_path ++ "constants.cpp",
    tools_opt_path ++ "remove_dontinline_pass.cpp",
    tools_opt_path ++ "dead_insert_elim_pass.cpp",
    tools_opt_path ++ "pass_manager.cpp",
    tools_opt_path ++ "merge_return_pass.cpp",
    tools_opt_path ++ "remove_duplicates_pass.cpp",
    tools_opt_path ++ "eliminate_dead_functions_util.cpp",
    tools_opt_path ++ "eliminate_dead_members_pass.cpp",
    tools_opt_path ++ "control_dependence.cpp",
    tools_opt_path ++ "vector_dce.cpp",
    tools_opt_path ++ "optimizer.cpp",
    tools_opt_path ++ "block_merge_pass.cpp",
    tools_opt_path ++ "desc_sroa_util.cpp",
    tools_opt_path ++ "local_single_block_elim_pass.cpp",
    tools_opt_path ++ "set_spec_constant_default_value_pass.cpp",
    tools_opt_path ++ "pch_source_opt.cpp",
    tools_opt_path ++ "loop_fusion.cpp",
};

const tools_util_path = tools_source_path ++ "util/";

const spirv_tools_util = [_][]const u8{
    tools_util_path ++ "bit_vector.cpp",
    tools_util_path ++ "parse_number.cpp",
    tools_util_path ++ "string_utils.cpp",
    tools_util_path ++ "timer.cpp",
};

const spirv_tools_wasm = [_][]const u8{
    tools_source_path ++ "wasm/spirv-tools.cpp",
};

const spirv_tools_link = [_][]const u8{
    tools_source_path ++ "link/linker.cpp",
};

const tools_val_path = tools_source_path ++ "val/";

const spirv_tools_val = [_][]const u8{
    tools_val_path ++ "validate_extensions.cpp",
    tools_val_path ++ "validate_conversion.cpp",
    tools_val_path ++ "validate_arithmetics.cpp",
    tools_val_path ++ "validate_primitives.cpp",
    tools_val_path ++ "validate_ray_tracing.cpp",
    tools_val_path ++ "validate_builtins.cpp",
    tools_val_path ++ "validate_atomics.cpp",
    tools_val_path ++ "validate_memory.cpp",
    tools_val_path ++ "instruction.cpp",
    tools_val_path ++ "validate_ray_tracing_reorder.cpp",
    tools_val_path ++ "validate_ray_query.cpp",
    tools_val_path ++ "validate_literals.cpp",
    tools_val_path ++ "construct.cpp",
    tools_val_path ++ "basic_block.cpp",
    tools_val_path ++ "validate.cpp",
    tools_val_path ++ "validate_small_type_uses.cpp",
    tools_val_path ++ "validate_instruction.cpp",
    tools_val_path ++ "validate_logicals.cpp",
    tools_val_path ++ "validate_execution_limitations.cpp",
    tools_val_path ++ "validate_mesh_shading.cpp",
    tools_val_path ++ "validate_capability.cpp",
    tools_val_path ++ "validate_decorations.cpp",
    tools_val_path ++ "validation_state.cpp",
    tools_val_path ++ "validate_function.cpp",
    tools_val_path ++ "function.cpp",
    tools_val_path ++ "validate_interfaces.cpp",
    tools_val_path ++ "validate_image.cpp",
    tools_val_path ++ "validate_constants.cpp",
    tools_val_path ++ "validate_derivatives.cpp",
    tools_val_path ++ "validate_cfg.cpp",
    tools_val_path ++ "validate_barriers.cpp",
    tools_val_path ++ "validate_mode_setting.cpp",
    tools_val_path ++ "validate_memory_semantics.cpp",
    tools_val_path ++ "validate_type.cpp",
    tools_val_path ++ "validate_misc.cpp",
    tools_val_path ++ "validate_debug.cpp",
    tools_val_path ++ "validate_bitwise.cpp",
    tools_val_path ++ "validate_adjacency.cpp",
    tools_val_path ++ "validate_annotation.cpp",
    tools_val_path ++ "validate_layout.cpp",
    tools_val_path ++ "validate_composites.cpp",
    tools_val_path ++ "validate_scopes.cpp",
    tools_val_path ++ "validate_non_uniform.cpp",
    tools_val_path ++ "validate_id.cpp",
};
