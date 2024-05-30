const std = @import("std");
const builtin = @import("builtin");
const spvtools = @import("External/spirv-tools/build.zig");
const Build = std.Build;

const log = std.log.scoped(.glslang_zig);

pub fn build(b: *Build) !void {
    const optimize = b.standardOptimizeOption(.{});
    const target = b.standardTargetOptions(.{});
    const debug = b.option(bool, "debug", "Whether to produce detailed debug symbols (g0) or not. These increase binary size considerably.") orelse false;
    const shared = b.option(bool, "shared", "Build glslang as a shared library.") orelse false;
    const enable_hlsl = !(b.option(bool, "no-hlsl", "Skip building glslang HLSL support.") orelse false);
    const enable_opt = !(b.option(bool, "no-opt", "Skip building spirv-tools optimization.") orelse false);
    const shared_tools = b.option(bool, "shared-tools", "Build and link spirv-tools as a shared library.") orelse false;

    const tools_libs: spvtools.SPVLibs = spvtools.build_spirv(b, optimize, target, shared_tools, debug) catch |err| {
        log.err("Error building SPIRV-Tools: {s}", .{ @errorName(err) });
        std.process.exit(1);
    }; 

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
    };

    try cppflags.appendSlice(base_flags);

// ------------------
// SPIRV-Tools
// ------------------

    const build_headers = BuildHeadersStep.init(b);    

    const sources = sources_spirv ++
        sources_generic_codegen ++
        sources_machine_independent ++ 
        sources_resource_limits ++ 
        sources_c_interface;

    var lib: *std.Build.Step.Compile = undefined;

    if (shared) {
        lib = b.addSharedLibrary(.{
            .name = "glslang",
            .root_source_file = b.addWriteFiles().add("empty.c", ""),
            .optimize = optimize,
            .target = target,
        });

        lib.defineCMacro("GLSLANG_IS_SHARED_LIBRARY", "1");
        lib.defineCMacro("GLSLANG_EXPORTING", "1");
    } else {
        lib = b.addStaticLibrary(.{
            .name = "glslang",
            .root_source_file = b.addWriteFiles().add("empty.c", ""),
            .optimize = optimize,
            .target = target,
        });
    }

    lib.addCSourceFiles(.{
        .files = &sources,
        .flags = cppflags.items,
    });

    const tag = target.result.os.tag;

    if (tag == .windows) {
        lib.addCSourceFiles(.{
            .files = &sources_win,
            .flags = cppflags.items,
        });

        lib.defineCMacro("GLSLANG_OSINCLUDE_WIN32", "");
    } else {
        lib.addCSourceFiles(.{
            .files = &sources_unix,
            .flags = cppflags.items,
        });

        lib.defineCMacro("GLSLANG_OSINCLUDE_UNIX", "");
    }

    if (enable_hlsl) {
        lib.addCSourceFiles(.{
            .files = &sources_hlsl,
            .flags = cppflags.items,
        });

        lib.defineCMacro("ENABLE_HLSL", "1");
    }

    if (enable_opt) {
        lib.addCSourceFiles(.{
            .files = &sources_opt,
            .flags = cppflags.items,
        });

        lib.defineCMacro("ENABLE_OPT", "1");

        lib.step.dependOn(&tools_libs.tools_opt.step);
        lib.step.dependOn(&tools_libs.tools_val.step);
        lib.linkLibrary(tools_libs.tools_opt);
        lib.linkLibrary(tools_libs.tools_val);
    }


    addIncludes(lib);
    spvtools.addSPIRVPublicIncludes(lib);

    lib.linkLibCpp();

    lib.step.dependOn(&build_headers.step);

    const build_step = b.step("glslang", "Build glslang");
    build_step.dependOn(&b.addInstallArtifact(lib, .{}).step);

    b.installArtifact(lib);
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

var build_mutex = std.Thread.Mutex{};

pub const BuildHeadersStep = struct {
    step: std.Build.Step,
    b: *std.Build,

    pub fn init(b: *std.Build) *BuildHeadersStep {
        const build_headers = b.allocator.create(BuildHeadersStep) catch unreachable;

        build_headers.* = .{
            .step = std.Build.Step.init(.{
                .id = .custom,
                .name = "Build header files.",
                .owner = b,
                .makeFn = &make,
            }),
            .b = b,
        };

        return build_headers;
    }

    fn make(step_ptr: *std.Build.Step, prog_node: *std.Progress.Node) anyerror!void {
        _ = prog_node;

        const build_headers: *BuildHeadersStep = @fieldParentPtr("step", step_ptr);
        const b = build_headers.b;

        // Zig will run build steps in parallel if possible, so if there were two invocations of
        // then this function would be called in parallel. We're manipulating the FS here
        // and so need to prevent that.
        build_mutex.lock();
        defer build_mutex.unlock();

        generateHeaders(b.allocator);
    }
};



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