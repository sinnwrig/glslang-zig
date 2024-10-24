const std = @import("std");
const builtin = @import("builtin");
const Build = std.Build;

const log = std.log.scoped(.glslang_zig);

pub fn build(b: *Build) !void {
    const optimize = b.standardOptimizeOption(.{});
    const target = b.standardTargetOptions(.{});
    const debug = b.option(bool, "debug", "Whether to produce detailed debug symbols (g0) or not. These increase binary size considerably.") orelse false;
    const shared = b.option(bool, "shared", "Build glslang as a shared library.") orelse false;
    const enable_hlsl = !(b.option(bool, "no_hlsl", "Skip building glslang HLSL support.") orelse false);
    const enable_opt = !(b.option(bool, "no_opt", "Skip building spirv-tools optimization.") orelse false);
    const shared_tools = b.option(bool, "shared_tools", "Build and link spirv-tools as a shared library.") orelse false;
    const standalone_glslang = b.option(bool, "standalone", "Build glslang.exe standalone command-line compiler.") orelse false;
    const standalone_spvremap = b.option(bool, "standalone_remap", "Build spirv-remap.exe standalone command-line remapper.") orelse false;
    const regenerate_headers = b.option(bool, "regenerate_headers", "Regenerate glslang header libraries.") orelse false;
    const minimal_test_exe = b.option(bool, "minimal_test", "Build a minimal test for linking.") orelse false;

    if (shared and (standalone_glslang or standalone_spvremap)) {
        log.err("Cannot build standalone sources with shared glslang. Recompile without `-Dshared` or `-Dstandalone/-Dstandalone-remap`", .{});
        std.process.exit(1);
    }

    const tag = target.result.os.tag;

    var cppflags = std.ArrayList([]const u8).init(b.allocator);

    if (!debug) {
        try cppflags.append("-g0");
    }

    try cppflags.append("-std=c++17");

    const base_flags = &.{ 
        "-Wno-conversion", 
        "-Wno-extra-semi", 
        "-Wno-ignored-qualifiers", 
        "-Wno-implicit-fallthrough", 
        "-Wno-inconsistent-missing-override", 
        "-Wno-missing-field-initializers", 
        "-Wno-newline-eof", 
        "-Wno-sign-compare", 
        "-Wno-suggest-destructor-override", 
        "-Wno-suggest-override", 
        "-Wno-unused-variable", 
        "-fPIC", 
        "-static",
    };

    try cppflags.appendSlice(base_flags);

    downloadOrPull(b, "sinnwrig", "SPIRV-Tools-zig", &b.path("External/spirv-tools"));
    downloadOrPull(b, "KhronosGroup", "SPIRV-Headers", &b.path("External/spirv-tools/external/spirv-headers"));

    var tools_lib: *Build.Step.Compile = undefined;
    var tools_opt: *Build.Step.Compile = undefined;
    var tools_val: *Build.Step.Compile = undefined;

    const path: []const u8 = "external/spirv-headers";

    if (b.lazyDependency("SPIRV-Tools", .{ .target = target, .optimize = optimize, .debug = debug, .shared = shared_tools, .header_path = path, .no_link = true, .no_reduce = true, .rebuild_headers = regenerate_headers })) |dep| {
        tools_lib = dep.artifact("SPIRV-Tools");
        tools_opt = dep.artifact("SPIRV-Tools-opt");
        tools_val = dep.artifact("SPIRV-Tools-val");
    } else {
        log.err("Error building SPIRV-Tools libraries", .{});
        std.process.exit(1);
    }

    const sources = sources_spirv ++
        sources_generic_codegen ++
        sources_machine_independent ++
        sources_resource_limits ++
        sources_c_interface;

    var glslang_lib: *std.Build.Step.Compile = b.addStaticLibrary(.{
        .name = "glslang",
        .root_source_file = b.addWriteFiles().add("empty.c", ""),
        .optimize = optimize,
        .target = target,
    });

    if (regenerate_headers) {
        glslang_lib.step.dependOn(generateHeaders(b));
    }

    glslang_lib.addCSourceFiles(.{
        .files = &sources,
        .flags = cppflags.items,
    });

    glslang_lib.linkLibrary(tools_lib);
    addIncludes(b, glslang_lib);

    glslang_lib.linkLibCpp();

    // OS-specific headers
    if (tag == .windows) {
        glslang_lib.addCSourceFiles(.{
            .files = &sources_win,
            .flags = cppflags.items,
        });
    } else {
        glslang_lib.addCSourceFiles(.{
            .files = &sources_unix,
            .flags = cppflags.items,
        });
    }

    glslang_lib.defineCMacro("ENABLE_SPIRV", "1");

    // Add HLSL sources
    if (enable_hlsl) {
        glslang_lib.addCSourceFiles(.{
            .files = &sources_hlsl,
            .flags = cppflags.items,
        });

        glslang_lib.defineCMacro("ENABLE_HLSL", "1");
    } else {
        glslang_lib.defineCMacro("ENABLE_HLSL", "0");
    }

    // Add SPIRV-Tools-opt sources
    if (enable_opt) {
        glslang_lib.addCSourceFiles(.{
            .files = &sources_opt,
            .flags = cppflags.items,
        });

        glslang_lib.defineCMacro("ENABLE_OPT", "1");

        glslang_lib.linkLibrary(tools_opt);
        glslang_lib.linkLibrary(tools_val);
    } else {
        glslang_lib.defineCMacro("ENABLE_OPT", "0");
    }

    const build_step = b.step("glslang-library", "Build the glslang library");
    build_step.dependOn(&b.addInstallArtifact(glslang_lib, .{}).step);

    b.installArtifact(glslang_lib);

    // Core glslang sources CANNOT be built as a standalone shared library or segfaults happen in c std::
    // no idea if this is a zig or glslang problem, but it seems like zig
    // the workaround is to build core glslang as a static library, then link it into a stub shared library 
    var shared_glslang: *std.Build.Step.Compile = undefined;

    if (shared) {
        shared_glslang = b.addSharedLibrary(.{
            .name = "glslang",
            .optimize = optimize,
            .target = target,
        });

        const shared_glslang_step = b.step("glslang", "Build and install shared glslang.exe");
        shared_glslang_step.dependOn(&b.addInstallArtifact(shared_glslang, .{}).step);
        shared_glslang.addCSourceFile(.{
            .file = b.path("StandAlone/shared_glslang.cpp"),
            .flags = &.{"-std=c++17"},
        });

        addIncludes(b, shared_glslang);

        b.installArtifact(shared_glslang);
        shared_glslang.linkLibrary(glslang_lib);

        glslang_lib.defineCMacro("GLSLANG_IS_SHARED_LIBRARY", "1");
        glslang_lib.defineCMacro("GLSLANG_EXPORTING", "1");
    }

    if (standalone_glslang) {
        const glslang_exe = b.addExecutable(.{
            .name = "glslang",
            .optimize = optimize,
            .target = target,
        });

        glslang_exe.pie = true;

        const install_glslang_step = b.step("glslang-standalone", "Build and install glslang.exe");
        install_glslang_step.dependOn(&b.addInstallArtifact(glslang_exe, .{}).step);
        glslang_exe.addCSourceFiles(.{
            .files = &sources_standalone_glslang,
            .flags = &.{"-std=c++17"},
        });

        addIncludes(b, glslang_exe);

        b.installArtifact(glslang_exe);

        if (shared) {
            glslang_exe.defineCMacro("GLSLANG_IS_SHARED_LIBRARY", "");
            glslang_exe.linkLibrary(shared_glslang);
        }
        else {
            glslang_exe.linkLibrary(glslang_lib);
        }

        if (enable_hlsl) {
            glslang_exe.defineCMacro("ENABLE_HLSL", "1");
        } else {
            glslang_exe.defineCMacro("ENABLE_HLSL", "0");
        }

        if (enable_opt) {
            glslang_exe.defineCMacro("ENABLE_OPT", "1");
        } else {
            glslang_exe.defineCMacro("ENABLE_OPT", "0");
        }
    }

    if (standalone_spvremap) {
        const spirv_remap = b.addExecutable(.{
            .name = "spirv-remap",
            .optimize = optimize,
            .target = target,
        });

        spirv_remap.pie = true;

        if (shared) {
            spirv_remap.defineCMacro("GLSLANG_IS_SHARED_LIBRARY", "");
            spirv_remap.linkLibrary(shared_glslang);
        }
        else {
            spirv_remap.linkLibrary(glslang_lib);
        }

        const install_remap_step = b.step("spirv-remap", "Build and install spirv-remap.exe");
        install_remap_step.dependOn(&b.addInstallArtifact(spirv_remap, .{}).step);
        spirv_remap.addCSourceFiles(.{
            .files = &sources_standalone_remap,
            .flags = &.{"-std=c++17"},
        });

        addIncludes(b, spirv_remap);

        b.installArtifact(spirv_remap);
        spirv_remap.linkLibrary(glslang_lib);
    }

    if (minimal_test_exe) {
        const min_test = b.addExecutable(.{
            .name = "minimal-test",
            .optimize = optimize,
            .target = target,
        });

        min_test.pie = true;
        
        if (shared) {
            min_test.defineCMacro("GLSLANG_IS_SHARED_LIBRARY", "");
            min_test.linkLibrary(shared_glslang);
        }
        else {
            min_test.linkLibrary(glslang_lib);
        }

        const min_test_step = b.step("minimal-test", "Build and install minimal-test.exe");
        min_test_step.dependOn(&b.addInstallArtifact(min_test, .{}).step);
        min_test.addCSourceFile(.{
            .file = b.path("StandAlone/minimal-test.cpp"),
            .flags = &.{"-std=c++17"},
        });

        addIncludes(b, min_test);

        b.installArtifact(min_test);

    }
}

fn addIncludes(b: *Build, step: *std.Build.Step.Compile) void {
    step.addIncludePath(b.path(header_output_path));
    step.addIncludePath(b.path(""));
    step.addIncludePath(b.path("External/spirv-tools/include"));
}

fn ensureCommandExists(allocator: std.mem.Allocator, name: []const u8, exist_check: []const u8) bool {
    const result = std.process.Child.run(.{
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

// --------------------------
// spirv-tools download logic
// --------------------------

fn downloadOrPull(b: *Build, comptime user: []const u8, comptime repo: []const u8, out_path: *const std.Build.LazyPath) void {
    if (!ensureCommandExists(b.allocator, "git", "--version")) {
        log.err("'git --version' failed. Ensure a valid git installation is present on the path.", .{});
        std.process.exit(1);
    }

    const git_cmd = b.addSystemCommand(&.{"git"});
    git_cmd.setCwd(out_path.dirname());

    _ = std.fs.openDirAbsolute(out_path.getPath(b), .{}) catch |err| {
        if (err == error.FileNotFound) {
            _ = b.run(&.{ "git", "clone", "https://github.com/" ++ user ++ "/" ++ repo, out_path.getPath(b) });

            return;
        }
    };

    _ = b.run(&.{
        "git", "-C", out_path.getPath(b), "pull",
    });
}

// -----------------------
// Header generation logic
// -----------------------

pub const header_output_path = "generated-include";

const build_info_script = "build_info.py";
const ext_header_script = "gen_extension_headers.py";

fn genBuildInfo(b: *Build) *Build.Step.Run {
    const python_cmd = b.addSystemCommand(&.{"python3"});

    python_cmd.setCwd(b.path("."));
    python_cmd.addFileArg(b.path(build_info_script));
    python_cmd.addFileArg(b.path("."));
    python_cmd.addArg("-i");
    python_cmd.addFileArg(b.path("build_info.h.tmpl"));
    python_cmd.addArg("-o");
    python_cmd.addFileArg(b.path(header_output_path).path(b, "glslang").path(b, "build_info.h"));

    return python_cmd;
}

fn genExtensionHeaders(b: *Build) *Build.Step.Run {
    const python_cmd = b.addSystemCommand(&.{"python3"});

    python_cmd.setCwd(b.path("."));
    python_cmd.addFileArg(b.path(ext_header_script));
    python_cmd.addArg("-i");
    python_cmd.addFileArg(b.path("glslang").path(b, "ExtensionHeaders"));
    python_cmd.addArg("-o");
    python_cmd.addFileArg(b.path(header_output_path).path(b, "glslang").path(b, "glsl_intrinsic_header.h"));

    return python_cmd;
}

fn generateHeaders(b: *Build) *std.Build.Step {
    if (!ensureCommandExists(b.allocator, "python3", "--version")) {
        log.err("'python3 --version' failed. Ensure a valid python3 installation is present on the path.", .{});
        std.process.exit(1);
    }

    const headers_step = b.step("build-headers", "Build glslang headers");

    headers_step.dependOn(&genBuildInfo(b).step);
    headers_step.dependOn(&genExtensionHeaders(b).step);

    return headers_step;
}

const sources_spirv = [_][]const u8{
    "SPIRV/GlslangToSpv.cpp",
    "SPIRV/InReadableOrder.cpp",
    "SPIRV/Logger.cpp",
    "SPIRV/SPVRemapper.cpp",
    "SPIRV/SpvBuilder.cpp",
    "SPIRV/SpvPostProcess.cpp",
    "SPIRV/disassemble.cpp",
    "SPIRV/doc.cpp",
};

const sources_c_interface = [_][]const u8{
    "glslang/CInterface/glslang_c_interface.cpp",
    "SPIRV/CInterface/spirv_c_interface.cpp",
};

const sources_resource_limits = [_][]const u8{
    "glslang/ResourceLimits/resource_limits_c.cpp",
    "glslang/ResourceLimits/ResourceLimits.cpp",
};

const sources_generic_codegen = [_][]const u8{
    "glslang/GenericCodeGen/CodeGen.cpp",
    "glslang/GenericCodeGen/Link.cpp",
};

const sources_machine_independent = [_][]const u8{
    "glslang/MachineIndependent/Constant.cpp",
    "glslang/MachineIndependent/InfoSink.cpp",
    "glslang/MachineIndependent/Initialize.cpp",
    "glslang/MachineIndependent/IntermTraverse.cpp",
    "glslang/MachineIndependent/Intermediate.cpp",
    "glslang/MachineIndependent/ParseContextBase.cpp",
    "glslang/MachineIndependent/ParseHelper.cpp",
    "glslang/MachineIndependent/PoolAlloc.cpp",
    "glslang/MachineIndependent/RemoveTree.cpp",
    "glslang/MachineIndependent/Scan.cpp",
    "glslang/MachineIndependent/ShaderLang.cpp",
    "glslang/MachineIndependent/SpirvIntrinsics.cpp",
    "glslang/MachineIndependent/SymbolTable.cpp",
    "glslang/MachineIndependent/Versions.cpp",
    "glslang/MachineIndependent/attribute.cpp",
    "glslang/MachineIndependent/glslang_tab.cpp",
    "glslang/MachineIndependent/intermOut.cpp",
    "glslang/MachineIndependent/iomapper.cpp",
    "glslang/MachineIndependent/limits.cpp",
    "glslang/MachineIndependent/linkValidate.cpp",
    "glslang/MachineIndependent/parseConst.cpp",
    "glslang/MachineIndependent/preprocessor/Pp.cpp",
    "glslang/MachineIndependent/preprocessor/PpAtom.cpp",
    "glslang/MachineIndependent/preprocessor/PpContext.cpp",
    "glslang/MachineIndependent/preprocessor/PpScanner.cpp",
    "glslang/MachineIndependent/preprocessor/PpTokens.cpp",
    "glslang/MachineIndependent/propagateNoContraction.cpp",
    "glslang/MachineIndependent/reflection.cpp",
};

const sources_win = [_][]const u8{"glslang/OSDependent/Windows/ossource.cpp"};

const sources_unix = [_][]const u8{"glslang/OSDependent/Unix/ossource.cpp"};

const sources_hlsl = [_][]const u8{
    "glslang/HLSL/hlslAttributes.cpp",
    "glslang/HLSL/hlslGrammar.cpp",
    "glslang/HLSL/hlslOpMap.cpp",
    "glslang/HLSL/hlslParseHelper.cpp",
    "glslang/HLSL/hlslParseables.cpp",
    "glslang/HLSL/hlslScanContext.cpp",
    "glslang/HLSL/hlslTokenStream.cpp",
};

const sources_opt = [_][]const u8{
    "SPIRV/SpvTools.cpp",
};

const sources_standalone_glslang = [_][]const u8{"StandAlone/StandAlone.cpp"};

const sources_standalone_remap = [_][]const u8{"StandAlone/spirv-remap.cpp"};
