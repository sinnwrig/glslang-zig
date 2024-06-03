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
    const standalone_spvremap = b.option(bool, "standalone-remap", "Build spirv-remap.exe standalone command-line remapper.") orelse false;

    if (shared and (standalone_glslang or standalone_spvremap)) {
        log.err("Cannot build standalone sources with shared glslang. Recompile without `-Dshared` or `-Dstandalone/-Dstandalone-remap`", .{});
        std.process.exit(1);
    }

    const tag = target.result.os.tag;

    var cppflags = std.ArrayList([]const u8).init(b.allocator);

    if (!debug) {
        try cppflags.append("-g0");
    }

    if (tag == .windows and shared) {
        try cppflags.append("-rdynamic");
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
    };

    try cppflags.appendSlice(base_flags);

// ------------------
// SPIRV-Tools
// ------------------

    generateHeaders(b.allocator);

    _ = std.fs.openDirAbsolute(sdkPath("/External/spirv-tools"), .{}) catch |err| {
        if (err == error.FileNotFound) {
            log.err("SPIRV-Tools build directory was not found - ensure sources have been cloned with `./update_glslang_sources.py --site zig`/.", .{});
        }

        std.process.exit(1);
    };

    var tools_lib: *Build.Step.Compile = undefined;
    var tools_opt: *Build.Step.Compile = undefined;
    var tools_val: *Build.Step.Compile = undefined;

    const path: []const u8 = "external/spirv-headers";

    if (b.lazyDependency("SPIRV-Tools", .{
        .target = target,
        .optimize = optimize,
        .debug = debug,
        .shared = shared_tools,
        .header_path = path,
    })) |dep| {
        tools_lib = dep.artifact("SPIRV-Tools");
        tools_opt = dep.artifact("SPIRV-Tools-opt");
        tools_val = dep.artifact("SPIRV-Tools-val");    
    }

    if (tools_lib == undefined or tools_opt == undefined or tools_val == undefined) {
        log.err("Error building SPIRV-Tools libraries", .{});
        std.process.exit(1);
    }

    const sources = sources_spirv ++
        sources_generic_codegen ++
        sources_machine_independent ++ 
        sources_resource_limits ++ 
        sources_c_interface;

    var glslang_lib: *std.Build.Step.Compile = undefined;

    if (shared) {
        glslang_lib = b.addSharedLibrary(.{
            .name = "glslang",
            .root_source_file = b.addWriteFiles().add("empty.c", ""),
            .optimize = optimize,
            .target = target,
        });

        glslang_lib.defineCMacro("GLSLANG_IS_SHARED_LIBRARY", "");
        glslang_lib.defineCMacro("GLSLANG_EXPORTING", "");
    } else {
        glslang_lib = b.addStaticLibrary(.{
            .name = "glslang",
            .root_source_file = b.addWriteFiles().add("empty.c", ""),
            .optimize = optimize,
            .target = target,
        });
    }

    glslang_lib.addCSourceFiles(.{
        .files = &sources,
        .flags = cppflags.items,
    });

    if (tag == .windows) {
        glslang_lib.addCSourceFiles(.{
            .files = &sources_win,
            .flags = cppflags.items,
        });

        glslang_lib.defineCMacro("GLSLANG_OSINCLUDE_WIN32", "");
    } else {
        glslang_lib.addCSourceFiles(.{
            .files = &sources_unix,
            .flags = cppflags.items,
        });

        glslang_lib.defineCMacro("GLSLANG_OSINCLUDE_UNIX", "");
    }

    if (enable_hlsl) {
        glslang_lib.addCSourceFiles(.{
            .files = &sources_hlsl,
            .flags = cppflags.items,
        });

        glslang_lib.defineCMacro("ENABLE_HLSL", "1");
    } else {
        glslang_lib.defineCMacro("ENABLE_HLSL", "0");
    }

    glslang_lib.linkLibrary(tools_lib);

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


    addIncludes(glslang_lib);

    glslang_lib.linkLibCpp();

    const build_step = b.step("glslang-library", "Build the glslang library");
    build_step.dependOn(&b.addInstallArtifact(glslang_lib, .{}).step);

    b.installArtifact(glslang_lib);

    if (standalone_glslang) {
        const glslang_exe = b.addExecutable(.{
            .name = "glslang",
            .optimize = optimize,
            .target = target,
        });

        if (shared) {
            glslang_exe.defineCMacro("GLSLANG_IS_SHARED_LIBRARY", "");
        }

        const install_glslang_step = b.step("glslang-standalone", "Build and install glslang.exe");
        install_glslang_step.dependOn(&b.addInstallArtifact(glslang_exe, .{}).step);
        glslang_exe.addCSourceFiles(.{
            .files = &sources_standalone_glslang,
            .flags = &.{ "-std=c++17" },
        });

        addIncludes(glslang_exe);

        b.installArtifact(glslang_exe);
        glslang_exe.linkLibrary(glslang_lib);

        if (target.result.os.tag == .windows) {
            // windows must be built with LTO disabled due to:
            // https://github.com/ziglang/zig/issues/15958
            glslang_exe.want_lto = false;
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

        if (shared) {
            spirv_remap.defineCMacro("GLSLANG_IS_SHARED_LIBRARY", "");
        }

        const install_remap_step = b.step("spirv-remap", "Build and install spirv-remap.exe");
        install_remap_step.dependOn(&b.addInstallArtifact(spirv_remap, .{}).step);
        spirv_remap.addCSourceFiles(.{
            .files = &sources_standalone_remap,
            .flags = &.{ "-std=c++17" },
        });

        addIncludes(spirv_remap);

        b.installArtifact(spirv_remap);
        spirv_remap.linkLibrary(glslang_lib);

        if (target.result.os.tag == .windows) {
            spirv_remap.want_lto = false;
        }
    }
}

fn addIncludes(step: *std.Build.Step.Compile) void {
    step.addIncludePath(.{ .path = sdkPath("/" ++ output_path) });
    step.addIncludePath(.{ .path = sdkPath("/") });
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

fn sdkPath(comptime suffix: []const u8) []const u8 {
    if (suffix[0] != '/') @compileError("suffix must be an absolute path");
    return comptime blk: {
        const root_dir = std.fs.path.dirname(@src().file) orelse ".";
        break :blk root_dir ++ suffix;
    };
}

fn ensurePython(allocator: std.mem.Allocator) void {
    if (!ensureCommandExists(allocator, "python3", "--version")) {
        log.err("'python3 --version' failed. Is python not installed?", .{});
        std.process.exit(1);
    }
}

fn runPython(allocator: std.mem.Allocator, args: []const []const u8, errMsg: []const u8) void {
    exec(allocator, args, sdkPath("/")) catch |err| {
        log.err("{s}. error: {s}", .{ errMsg, @errorName(err) });
        std.process.exit(1);
    };
}

// ------------------------------------------
// Include generation logic
// ------------------------------------------

pub const output_path = "build";

const build_info_script = "build_info.py";
const ext_header_script = "gen_extension_headers.py";

fn outPath(comptime out_name: []const u8) []const u8 {
    if (out_name[0] != '/') @compileError("suffix must be an absolute path");
    return sdkPath("/" ++ output_path ++ out_name);
}

// Script usage derived from the BUILD.gn

fn genBuildInfo(allocator: std.mem.Allocator) void {
    const args = &[_][]const u8{ 
        "python3", build_info_script, 
        sdkPath("/"), 
        "-i", sdkPath("/build_info.h.tmpl"),
        "-o", outPath("/glslang/build_info.h"),
    };

    runPython(allocator, args, "Failed to generate build info file.");
}

fn genExtensionHeaders(allocator: std.mem.Allocator) void {
    const args = &[_][]const u8 {
        "python3", ext_header_script,
        "-i", sdkPath("/glslang/ExtensionHeaders"),
        "-o", outPath("/glslang/glsl_intrinsic_header.h"),
    };

    runPython(allocator, args, "Failed to generate extension headers");
}

fn generateHeaders(allocator: std.mem.Allocator) void {
    if (!ensureCommandExists(allocator, "python3", "--version")) {
        log.err("'python3 --version' failed. Is python not installed?", .{});
        std.process.exit(1);
    }

    genBuildInfo(allocator);
    genExtensionHeaders(allocator);
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

const sources_win = [_][]const u8{
    "glslang/OSDependent/Windows/ossource.cpp"
};

const sources_unix = [_][]const u8{
    "glslang/OSDependent/Unix/ossource.cpp"
};

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

const sources_standalone_glslang = [_][]const u8{
    "StandAlone/StandAlone.cpp"
};

const sources_standalone_remap = [_][]const u8{
    "StandAlone/spirv-remap.cpp"
};