const std = @import("std");
const builtin = @import("builtin");
const Build = std.Build;

/// The latest binary release available at https://github.com/hexops/mach-dxcompiler/releases
const latest_binary_release = "2024.03.09+d19dd6d.1";

/// When building from source, which repository and revision to clone.
const spirv_tools_repository = "https://github.com/KhronosGroup/SPIRV-Tools";

const log = std.log.scoped(.mach_dxcompiler);
const prefix = "libs/DirectXShaderCompiler";

pub fn build(b: *Build) !void {
    const optimize = b.standardOptimizeOption(.{});
    const target = b.standardTargetOptions(.{});
    const debug_symbols = b.option(bool, "debug_symbols", "Whether to produce detailed debug symbols (g0) or not. These increase binary size considerably.") orelse false;
    const build_shared = b.option(bool, "shared", "Build dxcompiler shared libraries") orelse false;
    const skip_executables = b.option(bool, "skip_executables", "Skip building executables") orelse false;
    const skip_tests = b.option(bool, "skip_tests", "Skip building tests") orelse false;

    const machdxcompiler: struct { lib: *std.Build.Step.Compile, lib_path: ?[]const u8 } = blk: {
        const lib = b.addStaticLibrary(.{
            .name = "machdxcompiler",
            .root_source_file = b.addWriteFiles().add("empty.zig", ""),
            .optimize = optimize,
            .target = target,
        });

        b.installArtifact(lib);

        var download_step = DownloadSourceStep.init(b);
        lib.step.dependOn(&download_step.step);

        lib.addCSourceFile(.{
            .file = .{ .path = "src/mach_dxc.cpp" },
            .flags = &.{
                "-fms-extensions", // __uuidof and friends (on non-windows targets)
            },
        });
        if (target.result.os.tag != .windows) lib.defineCMacro("HAVE_DLFCN_H", "1");

        // The Windows 10 SDK winrt/wrl/client.h is incompatible with clang due to #pragma pack usages
        // (unclear why), so instead we use the wrl/client.h headers from https://github.com/ziglang/zig/tree/225fe6ddbfae016395762850e0cd5c51f9e7751c/lib/libc/include/any-windows-any
        // which seem to work fine.
        if (target.result.os.tag == .windows and target.result.abi == .msvc) lib.addIncludePath(.{ .path = "msvc/" });

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
                "-fms-extensions", // __uuidof and friends (on non-windows targets)
            };

            try cflags.appendSlice(base_flags);
            try cppflags.appendSlice(base_flags);

            addConfigHeaders(b, lib);
            addIncludes(lib);

            const cpp_sources =
                tools_clang_lib_lex_sources ++
                tools_clang_lib_basic_sources ++
                tools_clang_lib_driver_sources ++
                tools_clang_lib_analysis_sources ++
                tools_clang_lib_index_sources ++
                tools_clang_lib_parse_sources ++
                tools_clang_lib_ast_sources ++
                tools_clang_lib_edit_sources ++
                tools_clang_lib_sema_sources ++
                tools_clang_lib_codegen_sources ++
                tools_clang_lib_astmatchers_sources ++
                tools_clang_lib_tooling_core_sources ++
                tools_clang_lib_tooling_sources ++
                tools_clang_lib_format_sources ++
                tools_clang_lib_rewrite_sources ++
                tools_clang_lib_frontend_sources ++
                tools_clang_tools_libclang_sources ++
                tools_clang_tools_dxcompiler_sources ++
                lib_bitcode_reader_sources ++
                lib_bitcode_writer_sources ++
                lib_ir_sources ++
                lib_irreader_sources ++
                lib_linker_sources ++
                lib_asmparser_sources ++
                lib_analysis_sources ++
                lib_mssupport_sources ++
                lib_transforms_utils_sources ++
                lib_transforms_instcombine_sources ++
                lib_transforms_ipo_sources ++
                lib_transforms_scalar_sources ++
                lib_transforms_vectorize_sources ++
                lib_target_sources ++
                lib_profiledata_sources ++
                lib_option_sources ++
                lib_passprinters_sources ++
                lib_passes_sources ++
                lib_hlsl_sources ++
                lib_support_cpp_sources ++
                lib_dxcsupport_sources ++
                lib_dxcbindingtable_sources ++
                lib_dxil_sources ++
                lib_dxilcontainer_sources ++
                lib_dxilpixpasses_sources ++
                lib_dxilcompression_cpp_sources ++
                lib_dxilrootsignature_sources;

            const c_sources =
                lib_support_c_sources ++
                lib_dxilcompression_c_sources;

            // Build and link SPIRV-Tools
            if (build_spirv) {
                const spirv_cpp_sources =
                    spirv_tools ++
                    spirv_tools_util ++
                    spirv_tools_reduce ++
                    spirv_tools_link ++
                    spirv_tools_val ++
                    // spirv_tools_wasm ++ // Wasm build support- requires emscripten toolchain
                    spirv_tools_opt;

                const spv_lib = b.addStaticLibrary(.{
                    .name = "SPIRV-Tools",
                    .root_source_file = b.addWriteFiles().add("empty.c", ""),
                    .optimize = optimize,
                    .target = target,
                });

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

                var build_grammar_step = BuildSPIRVGrammarStep.init(b);
                spv_lib.step.dependOn(&build_grammar_step.step);

                spv_lib.addCSourceFiles(.{
                    .files = &spirv_cpp_sources,
                    .flags = cppflags.items,
                });

                spv_lib.defineCMacro("SPIRV_COLOR_TERMINAL", ""); // Pretty lights by default

                addSPIRVIncludes(spv_lib);
                linkMachDxcDependencies(spv_lib);

                b.installArtifact(spv_lib);

                lib.defineCMacro("ENABLE_SPIRV_CODEGEN", "");

                addSPIRVIncludes(lib);

                // Add clang SPIRV tooling sources
                lib.addCSourceFiles(.{
                    .files = &lib_spirv,
                    .flags = cppflags.items,
                });

                lib.linkLibrary(spv_lib);
            }

            lib.addCSourceFiles(.{
                .files = &cpp_sources,
                .flags = cppflags.items,
            });
            lib.addCSourceFiles(.{
                .files = &c_sources,
                .flags = cflags.items,
            });

            if (target.result.abi != .msvc) lib.defineCMacro("NDEBUG", ""); // disable assertions
            if (target.result.os.tag == .windows) {
                lib.defineCMacro("LLVM_ON_WIN32", "1");
                if (target.result.abi == .msvc) lib.defineCMacro("CINDEX_LINKAGE", "");
                lib.linkSystemLibrary("version");
            } else {
                lib.defineCMacro("LLVM_ON_UNIX", "1");
            }

            linkMachDxcDependencies(lib);
            lib.addIncludePath(.{ .path = "src" });

            // TODO: investigate SSE2 #define / cmake option for CPU target
            //
            // TODO: investigate how projects/dxilconv/lib/DxbcConverter/DxbcConverterImpl.h is getting pulled
            // in, we can get rid of dxbc conversion presumably

            if (!skip_executables) {
                // dxc.exe builds
                const dxc_exe = b.addExecutable(.{
                    .name = "dxc",
                    .optimize = optimize,
                    .target = target,
                });
                const install_dxc_step = b.step("dxc", "Build and install dxc.exe");
                install_dxc_step.dependOn(&b.addInstallArtifact(dxc_exe, .{}).step);
                dxc_exe.addCSourceFile(.{
                    .file = .{ .path = prefix ++ "/tools/clang/tools/dxc/dxcmain.cpp" },
                    .flags = &.{"-std=c++17"},
                });
                dxc_exe.defineCMacro("NDEBUG", ""); // disable assertions

                if (target.result.os.tag != .windows) dxc_exe.defineCMacro("HAVE_DLFCN_H", "1");
                dxc_exe.addIncludePath(.{ .path = prefix ++ "/tools/clang/tools" });
                dxc_exe.addIncludePath(.{ .path = prefix ++ "/include" });
                addConfigHeaders(b, dxc_exe);
                addIncludes(dxc_exe);
                dxc_exe.addCSourceFile(.{
                    .file = .{ .path = prefix ++ "/tools/clang/tools/dxclib/dxc.cpp" },
                    .flags = cppflags.items,
                });
                b.installArtifact(dxc_exe);
                dxc_exe.linkLibrary(lib);

                if (target.result.os.tag == .windows) {
                    // windows must be built with LTO disabled due to:
                    // https://github.com/ziglang/zig/issues/15958
                    dxc_exe.want_lto = false;
                    if (builtin.os.tag == .windows and target.result.abi == .msvc) {
                        const msvc_lib_dir: ?[]const u8 = try @import("msvc.zig").MsvcLibDir.find(b.allocator);

                        // The MSVC lib dir looks like this:
                        // C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Tools\MSVC\14.38.33130\Lib\x64
                        // But we need the atlmfc lib dir:
                        // C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Tools\MSVC\14.38.33130\atlmfc\lib\x64
                        const msvc_dir = try std.fs.path.resolve(b.allocator, &.{ msvc_lib_dir.?, "..\\.." });

                        const lib_dir_path = try std.mem.concat(b.allocator, u8, &.{
                            msvc_dir,
                            "\\atlmfc\\lib\\",
                            if (target.result.cpu.arch == .aarch64) "arm64" else "x64",
                        });

                        const lib_path = try std.mem.concat(b.allocator, u8, &.{ lib_dir_path, "\\atls.lib" });
                        const pdb_name = if (target.result.cpu.arch == .aarch64)
                            "atls.arm64.pdb"
                        else
                            "atls.amd64.pdb";
                        const pdb_path = try std.mem.concat(b.allocator, u8, &.{ lib_dir_path, "\\", pdb_name });

                        // For some reason, msvc target needs atls.lib to be in the 'zig build' working directory.
                        // Addomg tp the library path like this has no effect:
                        dxc_exe.addLibraryPath(.{ .path = lib_dir_path });
                        // So instead we must copy the lib into this directory:
                        try std.fs.cwd().copyFile(lib_path, std.fs.cwd(), "atls.lib", .{});
                        try std.fs.cwd().copyFile(pdb_path, std.fs.cwd(), pdb_name, .{});
                        // This is probably a bug in the Zig linker.
                    }
                }
            }

            if (build_shared) buildShared(b, lib, optimize, target);

            break :blk .{ .lib = lib, .lib_path = null };
        };
    };

    if (skip_executables)
        return;

    // Zig bindings
    const mach_dxcompiler = b.addModule("mach-dxcompiler", .{
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = optimize,
    });
    mach_dxcompiler.addIncludePath(.{ .path = "src" });

    mach_dxcompiler.linkLibrary(machdxcompiler.lib);
    if (machdxcompiler.lib_path) |p| mach_dxcompiler.addLibraryPath(.{ .path = p });

    if (skip_tests)
        return;

    const main_tests = b.addTest(.{
        .name = "dxcompiler-tests",
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = optimize,
    });
    main_tests.addIncludePath(.{ .path = "src" });
    main_tests.linkLibrary(machdxcompiler.lib);
    if (machdxcompiler.lib_path) |p| main_tests.addLibraryPath(.{ .path = p });

    b.installArtifact(main_tests);
    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&b.addRunArtifact(main_tests).step);
}

fn buildShared(b: *Build, lib: *Build.Step.Compile, optimize: std.builtin.OptimizeMode, target: std.Build.ResolvedTarget) void {
    const sharedlib = b.addSharedLibrary(.{
        .name = "machdxcompiler",
        .root_source_file = b.addWriteFiles().add("empty.c", ""),
        .optimize = optimize,
        .target = target,
    });

    sharedlib.addCSourceFile(.{
        .file = .{ .path = "src/shared_main.cpp" },
    });

    const shared_install_step = b.step("machdxcompiler", "Build and install the machdxcompiler shared library");
    shared_install_step.dependOn(&b.addInstallArtifact(sharedlib, .{}).step);

    b.installArtifact(sharedlib);
    sharedlib.linkLibrary(lib);
}

fn linkMachDxcDependencies(step: *std.Build.Step.Compile) void {
    const target = step.rootModuleTarget();
    if (target.abi == .msvc) {
        // https://github.com/ziglang/zig/issues/5312
        step.linkLibC();
    } else step.linkLibCpp();
    if (target.os.tag == .windows) {
        step.linkSystemLibrary("ole32");
        step.linkSystemLibrary("oleaut32");
    }
}

fn linkMachDxcDependenciesModule(mod: *std.Build.Module) void {
    const target = mod.resolved_target.?.result;
    if (target.abi == .msvc) {
        // https://github.com/ziglang/zig/issues/5312
        mod.link_libc = true;
    } else {
        mod.link_libcpp = true;
    }
    if (target.os.tag == .windows) {
        mod.linkSystemLibrary("ole32", .{});
        mod.linkSystemLibrary("oleaut32", .{});
    }
}

fn addConfigHeaders(b: *Build, step: *std.Build.Step.Compile) void {
    // /tools/clang/include/clang/Config/config.h.cmake
    step.addConfigHeader(b.addConfigHeader(
        .{
            .style = .{ .cmake = .{ .path = "config-headers/tools/clang/include/clang/Config/config.h.cmake" } },
            .include_path = "clang/Config/config.h",
        },
        .{},
    ));

    // /include/llvm/Config/AsmParsers.def.in
    step.addConfigHeader(b.addConfigHeader(
        .{
            .style = .{ .cmake = .{ .path = "config-headers/include/llvm/Config/AsmParsers.def.in" } },
            .include_path = "llvm/Config/AsmParsers.def",
        },
        .{},
    ));

    // /include/llvm/Config/Disassemblers.def.in
    step.addConfigHeader(b.addConfigHeader(
        .{
            .style = .{ .cmake = .{ .path = "config-headers/include/llvm/Config/Disassemblers.def.in" } },
            .include_path = "llvm/Config/Disassemblers.def",
        },
        .{},
    ));

    // /include/llvm/Config/Targets.def.in
    step.addConfigHeader(b.addConfigHeader(
        .{
            .style = .{ .cmake = .{ .path = "config-headers/include/llvm/Config/Targets.def.in" } },
            .include_path = "llvm/Config/Targets.def",
        },
        .{},
    ));

    // /include/llvm/Config/AsmPrinters.def.in
    step.addConfigHeader(b.addConfigHeader(
        .{
            .style = .{ .cmake = .{ .path = "config-headers/include/llvm/Config/AsmPrinters.def.in" } },
            .include_path = "llvm/Config/AsmPrinters.def",
        },
        .{},
    ));

    // /include/llvm/Support/DataTypes.h.cmake
    step.addConfigHeader(b.addConfigHeader(
        .{
            .style = .{ .cmake = .{ .path = "config-headers/include/llvm/Support/DataTypes.h.cmake" } },
            .include_path = "llvm/Support/DataTypes.h",
        },
        .{
            .HAVE_INTTYPES_H = 1,
            .HAVE_STDINT_H = 1,
            .HAVE_UINT64_T = 1,
            // /* #undef HAVE_U_INT64_T */
        },
    ));

    // /include/llvm/Config/abi-breaking.h.cmake
    step.addConfigHeader(b.addConfigHeader(
        .{
            .style = .{ .cmake = .{ .path = "config-headers/include/llvm/Config/abi-breaking.h.cmake" } },
            .include_path = "llvm/Config/abi-breaking.h",
        },
        .{},
    ));

    const target = step.rootModuleTarget();
    step.addConfigHeader(addConfigHeaderLLVMConfig(b, target, .llvm_config_h));
    step.addConfigHeader(addConfigHeaderLLVMConfig(b, target, .config_h));

    // /include/dxc/config.h.cmake
    step.addConfigHeader(b.addConfigHeader(
        .{
            .style = .{ .cmake = .{ .path = "config-headers/include/dxc/config.h.cmake" } },
            .include_path = "dxc/config.h",
        },
        .{
            .DXC_DISABLE_ALLOCATOR_OVERRIDES = false,
        },
    ));
}

fn addIncludes(step: *std.Build.Step.Compile) void {
    // TODO: replace unofficial external/DIA submodule with something else (or eliminate dep on it)
    step.addIncludePath(.{ .path = prefix ++ "/external/DIA/include" });
    // TODO: replace generated-include with logic to actually generate this code
    step.addIncludePath(.{ .path = "generated-include/" });
    step.addIncludePath(.{ .path = prefix ++ "/tools/clang/include" });
    step.addIncludePath(.{ .path = prefix ++ "/include" });
    step.addIncludePath(.{ .path = prefix ++ "/include/llvm" });
    step.addIncludePath(.{ .path = prefix ++ "/include/llvm/llvm_assert" });
    step.addIncludePath(.{ .path = prefix ++ "/include/llvm/Bitcode" });
    step.addIncludePath(.{ .path = prefix ++ "/include/llvm/IR" });
    step.addIncludePath(.{ .path = prefix ++ "/include/llvm/IRReader" });
    step.addIncludePath(.{ .path = prefix ++ "/include/llvm/Linker" });
    step.addIncludePath(.{ .path = prefix ++ "/include/llvm/Analysis" });
    step.addIncludePath(.{ .path = prefix ++ "/include/llvm/Transforms" });
    step.addIncludePath(.{ .path = prefix ++ "/include/llvm/Transforms/Utils" });
    step.addIncludePath(.{ .path = prefix ++ "/include/llvm/Transforms/InstCombine" });
    step.addIncludePath(.{ .path = prefix ++ "/include/llvm/Transforms/IPO" });
    step.addIncludePath(.{ .path = prefix ++ "/include/llvm/Transforms/Scalar" });
    step.addIncludePath(.{ .path = prefix ++ "/include/llvm/Transforms/Vectorize" });
    step.addIncludePath(.{ .path = prefix ++ "/include/llvm/Target" });
    step.addIncludePath(.{ .path = prefix ++ "/include/llvm/ProfileData" });
    step.addIncludePath(.{ .path = prefix ++ "/include/llvm/Option" });
    step.addIncludePath(.{ .path = prefix ++ "/include/llvm/PassPrinters" });
    step.addIncludePath(.{ .path = prefix ++ "/include/llvm/Passes" });
    step.addIncludePath(.{ .path = prefix ++ "/include/dxc" });
    step.addIncludePath(.{ .path = prefix ++ "/external/DirectX-Headers/include/directx" });

    // SPIR-V generated include stuff- should be OK not having it behind an option check
    step.addIncludePath(.{ .path = "generated-include/spirv-tools" });

    const target = step.rootModuleTarget();
    if (target.os.tag != .windows) step.addIncludePath(.{ .path = prefix ++ "/external/DirectX-Headers/include/wsl/stubs" });
}

fn addSPIRVIncludes(step: *std.Build.Step.Compile) void {
    // Generated SPIR-V headers get thrown in here
    step.addIncludePath(.{ .path = "generated-include/spirv-tools" });

    step.addIncludePath(.{ .path = prefix ++ "/external/SPIRV-Tools" });
    step.addIncludePath(.{ .path = prefix ++ "/external/SPIRV-Tools/include" });
    step.addIncludePath(.{ .path = prefix ++ "/external/SPIRV-Tools/source" });

    step.addIncludePath(.{ .path = prefix ++ "/external/SPIRV-Headers/include" });
}

// /include/llvm/Config/llvm-config.h.cmake
// /include/llvm/Config/config.h.cmake (derives llvm-config.h.cmake)
fn addConfigHeaderLLVMConfig(b: *Build, target: std.Target, which: anytype) *std.Build.Step.ConfigHeader {
    // Note: LLVM_HOST_TRIPLEs can be found by running $ llc --version | grep Default
    // Note: arm64 is an alias for aarch64, we always use aarch64 over arm64.
    const cross_platform = .{
        .LLVM_PREFIX = "/usr/local",
        .LLVM_DEFAULT_TARGET_TRIPLE = "dxil-ms-dx",
        .LLVM_ENABLE_THREADS = 1,
        .LLVM_HAS_ATOMICS = 1,
        .LLVM_VERSION_MAJOR = 3,
        .LLVM_VERSION_MINOR = 7,
        .LLVM_VERSION_PATCH = 0,
        .LLVM_VERSION_STRING = "3.7-v1.4.0.2274-1812-machdxcompiler",
    };

    const LLVMConfigH = struct {
        LLVM_HOST_TRIPLE: []const u8,
        LLVM_ON_WIN32: ?i64 = null,
        LLVM_ON_UNIX: ?i64 = null,
        HAVE_SYS_MMAN_H: ?i64 = null,
    };
    const llvm_config_h = blk: {
        if (target.os.tag == .windows) {
            break :blk switch (target.abi) {
                .msvc => switch (target.cpu.arch) {
                    .x86_64 => merge(cross_platform, LLVMConfigH{
                        .LLVM_HOST_TRIPLE = "x86_64-w64-msvc",
                        .LLVM_ON_WIN32 = 1,
                    }),
                    .aarch64 => merge(cross_platform, LLVMConfigH{
                        .LLVM_HOST_TRIPLE = "aarch64-w64-msvc",
                        .LLVM_ON_WIN32 = 1,
                    }),
                    else => @panic("target architecture not supported"),
                },
                .gnu => switch (target.cpu.arch) {
                    .x86_64 => merge(cross_platform, LLVMConfigH{
                        .LLVM_HOST_TRIPLE = "x86_64-w64-mingw32",
                        .LLVM_ON_WIN32 = 1,
                    }),
                    .aarch64 => merge(cross_platform, LLVMConfigH{
                        .LLVM_HOST_TRIPLE = "aarch64-w64-mingw32",
                        .LLVM_ON_WIN32 = 1,
                    }),
                    else => @panic("target architecture not supported"),
                },
                else => @panic("target ABI not supported"),
            };
        } else if (target.os.tag.isDarwin()) {
            break :blk switch (target.cpu.arch) {
                .aarch64 => merge(cross_platform, LLVMConfigH{
                    .LLVM_HOST_TRIPLE = "aarch64-apple-darwin",
                    .LLVM_ON_UNIX = 1,
                    .HAVE_SYS_MMAN_H = 1,
                }),
                .x86_64 => merge(cross_platform, LLVMConfigH{
                    .LLVM_HOST_TRIPLE = "x86_64-apple-darwin",
                    .LLVM_ON_UNIX = 1,
                    .HAVE_SYS_MMAN_H = 1,
                }),
                else => @panic("target architecture not supported"),
            };
        } else {
            // Assume linux-like
            // TODO: musl support?
            break :blk switch (target.cpu.arch) {
                .aarch64 => merge(cross_platform, LLVMConfigH{
                    .LLVM_HOST_TRIPLE = "aarch64-linux-gnu",
                    .LLVM_ON_UNIX = 1,
                    .HAVE_SYS_MMAN_H = 1,
                }),
                .x86_64 => merge(cross_platform, LLVMConfigH{
                    .LLVM_HOST_TRIPLE = "x86_64-linux-gnu",
                    .LLVM_ON_UNIX = 1,
                    .HAVE_SYS_MMAN_H = 1,
                }),
                else => @panic("target architecture not supported"),
            };
        }
    };

    const tag = target.os.tag;
    const if_windows: ?i64 = if (tag == .windows) 1 else null;
    const if_not_windows: ?i64 = if (tag == .windows) null else 1;
    const if_windows_or_linux: ?i64 = if (tag == .windows and !tag.isDarwin()) 1 else null;
    const if_darwin: ?i64 = if (tag.isDarwin()) 1 else null;
    const if_not_msvc: ?i64 = if (target.abi != .msvc) 1 else null;
    const config_h = merge(llvm_config_h, .{
        .HAVE_STRERROR = if_windows,
        .HAVE_STRERROR_R = if_not_windows,
        .HAVE_MALLOC_H = if_windows_or_linux,
        .HAVE_MALLOC_MALLOC_H = if_darwin,
        .HAVE_MALLOC_ZONE_STATISTICS = if_not_windows,
        .HAVE_GETPAGESIZE = if_not_windows,
        .HAVE_PTHREAD_H = if_not_windows,
        .HAVE_PTHREAD_GETSPECIFIC = if_not_windows,
        .HAVE_PTHREAD_MUTEX_LOCK = if_not_windows,
        .HAVE_PTHREAD_RWLOCK_INIT = if_not_windows,
        .HAVE_DLOPEN = if_not_windows,
        .HAVE_DLFCN_H = if_not_windows, //
        .HAVE_UNISTD_H = if_not_msvc,

        .BUG_REPORT_URL = "http://llvm.org/bugs/",
        .ENABLE_BACKTRACES = "",
        .ENABLE_CRASH_OVERRIDES = "",
        .DISABLE_LLVM_DYLIB_ATEXIT = "",
        .ENABLE_PIC = "",
        .ENABLE_TIMESTAMPS = 1,
        .HAVE_CLOSEDIR = 1,
        .HAVE_CXXABI_H = 1,
        .HAVE_DECL_STRERROR_S = 1,
        .HAVE_DIRENT_H = 1,
        .HAVE_ERRNO_H = 1,
        .HAVE_FCNTL_H = 1,
        .HAVE_FENV_H = 1,
        .HAVE_GETCWD = 1,
        .HAVE_GETTIMEOFDAY = 1,
        .HAVE_INT64_T = 1,
        .HAVE_INTTYPES_H = 1,
        .HAVE_ISATTY = 1,
        .HAVE_LIBPSAPI = 1,
        .HAVE_LIBSHELL32 = 1,
        .HAVE_LIMITS_H = 1,
        .HAVE_LINK_EXPORT_DYNAMIC = 1,
        .HAVE_MKSTEMP = 1,
        .HAVE_MKTEMP = 1,
        .HAVE_OPENDIR = 1,
        .HAVE_READDIR = 1,
        .HAVE_SIGNAL_H = 1,
        .HAVE_STDINT_H = 1,
        .HAVE_STRTOLL = 1,
        .HAVE_SYS_PARAM_H = 1,
        .HAVE_SYS_STAT_H = 1,
        .HAVE_SYS_TIME_H = 1,
        .HAVE_UINT64_T = 1,
        .HAVE_UTIME_H = 1,
        .HAVE__ALLOCA = 1,
        .HAVE___ASHLDI3 = 1,
        .HAVE___ASHRDI3 = 1,
        .HAVE___CMPDI2 = 1,
        .HAVE___DIVDI3 = 1,
        .HAVE___FIXDFDI = 1,
        .HAVE___FIXSFDI = 1,
        .HAVE___FLOATDIDF = 1,
        .HAVE___LSHRDI3 = 1,
        .HAVE___MAIN = 1,
        .HAVE___MODDI3 = 1,
        .HAVE___UDIVDI3 = 1,
        .HAVE___UMODDI3 = 1,
        .HAVE____CHKSTK_MS = 1,
        .LLVM_ENABLE_ZLIB = 0,
        .PACKAGE_BUGREPORT = "http://llvm.org/bugs/",
        .PACKAGE_NAME = "LLVM",
        .PACKAGE_STRING = "LLVM 3.7-v1.4.0.2274-1812-g84da60c6c-dirty",
        .PACKAGE_VERSION = "3.7-v1.4.0.2274-1812-g84da60c6c-dirty",
        .RETSIGTYPE = "void",
        .WIN32_ELMCB_PCSTR = "PCSTR",
        .HAVE__CHSIZE_S = 1,
    });

    return switch (which) {
        .llvm_config_h => b.addConfigHeader(.{
            .style = .{ .cmake = .{ .path = "config-headers/include/llvm/Config/llvm-config.h.cmake" } },
            .include_path = "llvm/Config/llvm-config.h",
        }, llvm_config_h),
        .config_h => b.addConfigHeader(.{
            .style = .{ .cmake = .{ .path = "config-headers/include/llvm/Config/config.h.cmake" } },
            .include_path = "llvm/Config/config.h",
        }, config_h),
        else => unreachable,
    };
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

// Merge struct types A and B
fn Merge(comptime a: type, comptime b: type) type {
    const a_fields = @typeInfo(a).Struct.fields;
    const b_fields = @typeInfo(b).Struct.fields;

    return @Type(std.builtin.Type{
        .Struct = .{
            .layout = .Auto,
            .fields = a_fields ++ b_fields,
            .decls = &.{},
            .is_tuple = false,
        },
    });
}

// Merge struct values A and B
fn merge(a: anytype, b: anytype) Merge(@TypeOf(a), @TypeOf(b)) {
    var merged: Merge(@TypeOf(a), @TypeOf(b)) = undefined;
    inline for (@typeInfo(@TypeOf(merged)).Struct.fields) |f| {
        if (@hasField(@TypeOf(a), f.name)) @field(merged, f.name) = @field(a, f.name);
        if (@hasField(@TypeOf(b), f.name)) @field(merged, f.name) = @field(b, f.name);
    }
    return merged;
}

fn sdkPath(comptime suffix: []const u8) []const u8 {
    if (suffix[0] != '/') @compileError("suffix must be an absolute path");
    return comptime blk: {
        const root_dir = std.fs.path.dirname(@src().file) orelse ".";
        break :blk root_dir ++ suffix;
    };
}

const DownloadSourceStep = struct {
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
        const download_step = @fieldParentPtr(DownloadSourceStep, "step", step_ptr);
        const b = download_step.b;

        // Zig will run build steps in parallel if possible, so if there were two invocations of
        // then this function would be called in parallel. We're manipulating the FS here
        // and so need to prevent that.
        download_mutex.lock();
        defer download_mutex.unlock();

        try ensureGitRepoCloned(b.allocator, source_repository, source_revision, sdkPath("/libs/DirectXShaderCompiler"));
    }
};

// ------------------------------------------
// Binary download logic
// ------------------------------------------
const project_name = "dxcompiler";

var download_mutex = std.Thread.Mutex{};

fn binaryZigTriple(arena: std.mem.Allocator, target: std.Target) ![]const u8 {
    // Craft a zig_triple string that we will use to create the binary download URL. Remove OS
    // version range / glibc version from triple, as we don't include that in our download URL.
    var binary_target = std.zig.CrossTarget.fromTarget(target);
    binary_target.os_version_min = .{ .none = undefined };
    binary_target.os_version_max = .{ .none = undefined };
    binary_target.glibc_version = null;
    return try binary_target.zigTriple(arena);
}

fn binaryOptimizeMode(optimize: std.builtin.OptimizeMode) []const u8 {
    return switch (optimize) {
        .Debug => "Debug",
        // All Release* are mapped to ReleaseFast, as we only provide ReleaseFast and Debug binaries.
        .ReleaseSafe => "ReleaseFast",
        .ReleaseFast => "ReleaseFast",
        .ReleaseSmall => "ReleaseFast",
    };
}

fn binaryCacheDirPath(b: *std.Build, target: std.Target, optimize: std.builtin.OptimizeMode) ![]const u8 {
    // Global Mach project cache directory, e.g. $HOME/.cache/zig/mach/<project_name>
    // TODO: remove this once https://github.com/ziglang/zig/issues/16149 is fixed.
    const global_cache_root = if (@hasField(std.Build, "graph")) b.graph.global_cache_root else b.global_cache_root;
    const project_cache_dir_rel = try global_cache_root.join(b.allocator, &.{ "mach", project_name });

    // Release-specific cache directory, e.g. $HOME/.cache/zig/mach/<project_name>/<latest_binary_release>/<zig_triple>/<optimize>
    // where we will download the binary release to.
    return try std.fs.path.join(b.allocator, &.{
        project_cache_dir_rel,
        latest_binary_release,
        try binaryZigTriple(b.allocator, target),
        binaryOptimizeMode(optimize),
    });
}

const DownloadBinaryStep = struct {
    target: std.Target,
    optimize: std.builtin.OptimizeMode,
    step: std.Build.Step,
    b: *std.Build,

    fn init(b: *std.Build, target: std.Target, optimize: std.builtin.OptimizeMode) *DownloadBinaryStep {
        const download_step = b.allocator.create(DownloadBinaryStep) catch unreachable;
        download_step.* = .{
            .target = target,
            .optimize = optimize,
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
        const download_step = @fieldParentPtr(DownloadBinaryStep, "step", step_ptr);
        const b = download_step.b;
        const target = download_step.target;
        const optimize = download_step.optimize;

        // Zig will run build steps in parallel if possible, so if there were two invocations of
        // then this function would be called in parallel. We're manipulating the FS here
        // and so need to prevent that.
        download_mutex.lock();
        defer download_mutex.unlock();

        // Check if we've already downloaded binaries to the cache dir
        const cache_dir = try binaryCacheDirPath(b, target, optimize);
        if (dirExists(cache_dir)) {
            // Nothing to do.
            return;
        }
        std.fs.cwd().makePath(cache_dir) catch |err| {
            log.err("unable to create cache dir '{s}': {s}", .{ cache_dir, @errorName(err) });
            return error.DownloadFailed;
        };

        // Compose the download URL, e.g.
        // https://github.com/hexops/mach-dxcompiler/releases/download/2023.11.30%2Ba451866.3/aarch64-linux-gnu_Debug_bin.tar.gz
        const download_url = try std.mem.concat(b.allocator, u8, &.{
            "https://github.com",
            "/hexops/mach-" ++ project_name ++ "/releases/download/",
            latest_binary_release,
            "/",
            try binaryZigTriple(b.allocator, target),
            "_",
            binaryOptimizeMode(optimize),
            "_lib",
            ".tar.zst",
        });

        try downloadExtractTarball(
            b.allocator,
            cache_dir,
            try std.fs.openDirAbsolute(cache_dir, .{}),
            download_url,
        );
    }
};

fn downloadExtractTarball(
    arena: std.mem.Allocator,
    out_dir_path: []const u8,
    out_dir: std.fs.Dir,
    url: []const u8,
) !void {
    log.info("downloading {s}\n", .{url});
    const gpa = arena;

    // Fetch the file into memory.
    var resp = std.ArrayList(u8).init(arena);
    defer resp.deinit();
    var client: std.http.Client = .{ .allocator = gpa };
    defer client.deinit();
    var fetch_res = client.fetch(.{
        .location = .{ .url = url },
        .response_storage = .{ .dynamic = &resp },
        .max_append_size = 50 * 1024 * 1024,
    }) catch |err| {
        log.err("unable to fetch: error: {s}", .{@errorName(err)});
        return error.FetchFailed;
    };
    if (fetch_res.status.class() != .success) {
        log.err("unable to fetch: HTTP {}", .{fetch_res.status});
        return error.FetchFailed;
    }
    log.info("extracting {} bytes to {s}\n", .{ resp.items.len, out_dir_path });

    // Decompress tarball
    const window_buffer = try gpa.alloc(u8, 1 << 23);
    defer gpa.free(window_buffer);

    var fbs = std.io.fixedBufferStream(resp.items);
    var decompressor = std.compress.zstd.decompressor(fbs.reader(), .{
        .window_buffer = window_buffer,
    });

    // Unpack tarball
    var diagnostics: std.tar.Options.Diagnostics = .{ .allocator = gpa };
    defer diagnostics.deinit();
    std.tar.pipeToFileSystem(out_dir, decompressor.reader(), .{
        .diagnostics = &diagnostics,
        .strip_components = 1,
        // TODO: we would like to set this to executable_bit_only, but two
        // things need to happen before that:
        // 1. the tar implementation needs to support it
        // 2. the hashing algorithm here needs to support detecting the is_executable
        //    bit on Windows from the ACLs (see the isExecutable function).
        .mode_mode = .ignore,
        .exclude_empty_directories = true,
    }) catch |err| {
        log.err("unable to unpack tarball: {s}", .{@errorName(err)});
        return error.UnpackFailed;
    };
    if (diagnostics.errors.items.len > 0) {
        const notes_len: u32 = @intCast(diagnostics.errors.items.len);
        log.err("unable to unpack tarball(2)", .{});
        for (diagnostics.errors.items, notes_len..) |item, note_i| {
            _ = note_i;

            switch (item) {
                .unable_to_create_sym_link => |info| {
                    log.err("unable to create symlink from '{s}' to '{s}': {s}", .{ info.file_name, info.link_name, @errorName(info.code) });
                },
                .unable_to_create_file => |info| {
                    log.err("unable to create file '{s}': {s}", .{ info.file_name, @errorName(info.code) });
                },
                .unsupported_file_type => |info| {
                    log.err("file '{s}' has unsupported type '{c}'", .{ info.file_name, @intFromEnum(info.file_type) });
                },
            }
        }
        return error.UnpackFailed;
    }
    log.info("finished\n", .{});
}

fn dirExists(path: []const u8) bool {
    var dir = std.fs.openDirAbsolute(path, .{}) catch return false;
    dir.close();
    return true;
}

const hex_charset = "0123456789abcdef";

fn hex64(x: u64) [16]u8 {
    var result: [16]u8 = undefined;
    var i: usize = 0;
    while (i < 8) : (i += 1) {
        const byte = @as(u8, @truncate(x >> @as(u6, @intCast(8 * i))));
        result[i * 2 + 0] = hex_charset[byte >> 4];
        result[i * 2 + 1] = hex_charset[byte & 15];
    }
    return result;
}

test hex64 {
    const s = "[" ++ hex64(0x12345678_abcdef00) ++ "]";
    try std.testing.expectEqualStrings("[00efcdab78563412]", s);
}

// ------------------------------------------
// SPIR-V include generation logic
// ------------------------------------------

fn ensurePython(allocator: std.mem.Allocator) void {
    if (!ensureCommandExists(allocator, "python3", "--version")) {
        log.err("'python3 --version' failed. Is python not installed?", .{});
        std.process.exit(1);
    }
}

const spirv_headers_path = prefix ++ "/external/SPIRV-Headers";
const spirv_tools_path = prefix ++ "/external/SPIRV-Tools";
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

fn genSPIRVVendorTable(allocator: std.mem.Allocator, comptime name: []const u8, comptime operand_kind_prefix: []const u8) void {
    const extinst_vendor_grammar = spirv_headers_path ++ "/include/spirv/unified1/extinst." ++ name ++ ".grammar.json";
    const extinst_file = spirv_output_path ++ "/" ++ name ++ ".insts.inc";

    const args = &[_][]const u8{
        "python3",                      grammar_tables_script,
        "--extinst-vendor-grammar",     extinst_vendor_grammar,
        "--vendor-insts-output",        extinst_file,
        "--vendor-operand-kind-prefix", operand_kind_prefix,
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

        const build_grammar_step = @fieldParentPtr(BuildSPIRVGrammarStep, "step", step_ptr);
        const b = build_grammar_step.b;

        // Zig will run build steps in parallel if possible, so if there were two invocations of
        // then this function would be called in parallel. We're manipulating the FS here
        // and so need to prevent that.
        download_mutex.lock();
        defer download_mutex.unlock();

        generateSPIRVGrammar(b.allocator);
    }
};

const spirv_tools = [_][]const u8{
    "libs/DirectXShaderCompiler/external/SPIRV-Tools/source/spirv_reducer_options.cpp",
    "libs/DirectXShaderCompiler/external/SPIRV-Tools/source/spirv_validator_options.cpp",
    "libs/DirectXShaderCompiler/external/SPIRV-Tools/source/spirv_endian.cpp",
    "libs/DirectXShaderCompiler/external/SPIRV-Tools/source/table.cpp",
    "libs/DirectXShaderCompiler/external/SPIRV-Tools/source/text.cpp",
    "libs/DirectXShaderCompiler/external/SPIRV-Tools/source/spirv_fuzzer_options.cpp",
    "libs/DirectXShaderCompiler/external/SPIRV-Tools/source/parsed_operand.cpp",
    "libs/DirectXShaderCompiler/external/SPIRV-Tools/source/operand.cpp",
    "libs/DirectXShaderCompiler/external/SPIRV-Tools/source/assembly_grammar.cpp",
    "libs/DirectXShaderCompiler/external/SPIRV-Tools/source/text_handler.cpp",
    "libs/DirectXShaderCompiler/external/SPIRV-Tools/source/opcode.cpp",
    "libs/DirectXShaderCompiler/external/SPIRV-Tools/source/pch_source.cpp",
    "libs/DirectXShaderCompiler/external/SPIRV-Tools/source/software_version.cpp",
    "libs/DirectXShaderCompiler/external/SPIRV-Tools/source/binary.cpp",
    "libs/DirectXShaderCompiler/external/SPIRV-Tools/source/ext_inst.cpp",
    "libs/DirectXShaderCompiler/external/SPIRV-Tools/source/print.cpp",
    "libs/DirectXShaderCompiler/external/SPIRV-Tools/source/disassemble.cpp",
    "libs/DirectXShaderCompiler/external/SPIRV-Tools/source/enum_string_mapping.cpp",
    "libs/DirectXShaderCompiler/external/SPIRV-Tools/source/spirv_optimizer_options.cpp",
    "libs/DirectXShaderCompiler/external/SPIRV-Tools/source/libspirv.cpp",
    "libs/DirectXShaderCompiler/external/SPIRV-Tools/source/diagnostic.cpp",
    "libs/DirectXShaderCompiler/external/SPIRV-Tools/source/spirv_target_env.cpp",
    "libs/DirectXShaderCompiler/external/SPIRV-Tools/source/name_mapper.cpp",
    "libs/DirectXShaderCompiler/external/SPIRV-Tools/source/extensions.cpp",
};

const spirv_tools_reduce = [_][]const u8{
    "libs/DirectXShaderCompiler/external/SPIRV-Tools/source/reduce/structured_loop_to_selection_reduction_opportunity_finder.cpp",
    "libs/DirectXShaderCompiler/external/SPIRV-Tools/source/reduce/structured_construct_to_block_reduction_opportunity_finder.cpp",
    "libs/DirectXShaderCompiler/external/SPIRV-Tools/source/reduce/operand_to_undef_reduction_opportunity_finder.cpp",
    "libs/DirectXShaderCompiler/external/SPIRV-Tools/source/reduce/remove_block_reduction_opportunity_finder.cpp",
    "libs/DirectXShaderCompiler/external/SPIRV-Tools/source/reduce/change_operand_reduction_opportunity.cpp",
    "libs/DirectXShaderCompiler/external/SPIRV-Tools/source/reduce/remove_unused_struct_member_reduction_opportunity_finder.cpp",
    "libs/DirectXShaderCompiler/external/SPIRV-Tools/source/reduce/simple_conditional_branch_to_branch_opportunity_finder.cpp",
    "libs/DirectXShaderCompiler/external/SPIRV-Tools/source/reduce/remove_function_reduction_opportunity.cpp",
    "libs/DirectXShaderCompiler/external/SPIRV-Tools/source/reduce/merge_blocks_reduction_opportunity_finder.cpp",
    "libs/DirectXShaderCompiler/external/SPIRV-Tools/source/reduce/simple_conditional_branch_to_branch_reduction_opportunity.cpp",
    "libs/DirectXShaderCompiler/external/SPIRV-Tools/source/reduce/structured_construct_to_block_reduction_opportunity.cpp",
    "libs/DirectXShaderCompiler/external/SPIRV-Tools/source/reduce/reduction_opportunity.cpp",
    "libs/DirectXShaderCompiler/external/SPIRV-Tools/source/reduce/change_operand_to_undef_reduction_opportunity.cpp",
    "libs/DirectXShaderCompiler/external/SPIRV-Tools/source/reduce/remove_function_reduction_opportunity_finder.cpp",
    "libs/DirectXShaderCompiler/external/SPIRV-Tools/source/reduce/remove_selection_reduction_opportunity.cpp",
    "libs/DirectXShaderCompiler/external/SPIRV-Tools/source/reduce/operand_to_const_reduction_opportunity_finder.cpp",
    "libs/DirectXShaderCompiler/external/SPIRV-Tools/source/reduce/operand_to_dominating_id_reduction_opportunity_finder.cpp",
    "libs/DirectXShaderCompiler/external/SPIRV-Tools/source/reduce/remove_block_reduction_opportunity.cpp",
    "libs/DirectXShaderCompiler/external/SPIRV-Tools/source/reduce/reduction_pass.cpp",
    "libs/DirectXShaderCompiler/external/SPIRV-Tools/source/reduce/conditional_branch_to_simple_conditional_branch_reduction_opportunity.cpp",
    "libs/DirectXShaderCompiler/external/SPIRV-Tools/source/reduce/conditional_branch_to_simple_conditional_branch_opportunity_finder.cpp",
    "libs/DirectXShaderCompiler/external/SPIRV-Tools/source/reduce/remove_selection_reduction_opportunity_finder.cpp",
    "libs/DirectXShaderCompiler/external/SPIRV-Tools/source/reduce/pch_source_reduce.cpp",
    "libs/DirectXShaderCompiler/external/SPIRV-Tools/source/reduce/reduction_util.cpp",
    "libs/DirectXShaderCompiler/external/SPIRV-Tools/source/reduce/merge_blocks_reduction_opportunity.cpp",
    "libs/DirectXShaderCompiler/external/SPIRV-Tools/source/reduce/reducer.cpp",
    "libs/DirectXShaderCompiler/external/SPIRV-Tools/source/reduce/remove_struct_member_reduction_opportunity.cpp",
    "libs/DirectXShaderCompiler/external/SPIRV-Tools/source/reduce/structured_loop_to_selection_reduction_opportunity.cpp",
    "libs/DirectXShaderCompiler/external/SPIRV-Tools/source/reduce/reduction_opportunity_finder.cpp",
    "libs/DirectXShaderCompiler/external/SPIRV-Tools/source/reduce/remove_instruction_reduction_opportunity.cpp",
    "libs/DirectXShaderCompiler/external/SPIRV-Tools/source/reduce/remove_unused_instruction_reduction_opportunity_finder.cpp",
};

const spirv_tools_opt = [_][]const u8{
    "libs/DirectXShaderCompiler/external/SPIRV-Tools/source/opt/loop_unswitch_pass.cpp",
    "libs/DirectXShaderCompiler/external/SPIRV-Tools/source/opt/eliminate_dead_output_stores_pass.cpp",
    "libs/DirectXShaderCompiler/external/SPIRV-Tools/source/opt/dominator_tree.cpp",
    "libs/DirectXShaderCompiler/external/SPIRV-Tools/source/opt/flatten_decoration_pass.cpp",
    "libs/DirectXShaderCompiler/external/SPIRV-Tools/source/opt/convert_to_half_pass.cpp",
    "libs/DirectXShaderCompiler/external/SPIRV-Tools/source/opt/loop_unroller.cpp",
    "libs/DirectXShaderCompiler/external/SPIRV-Tools/source/opt/interface_var_sroa.cpp",
    "libs/DirectXShaderCompiler/external/SPIRV-Tools/source/opt/wrap_opkill.cpp",
    "libs/DirectXShaderCompiler/external/SPIRV-Tools/source/opt/inst_debug_printf_pass.cpp",
    "libs/DirectXShaderCompiler/external/SPIRV-Tools/source/opt/liveness.cpp",
    "libs/DirectXShaderCompiler/external/SPIRV-Tools/source/opt/eliminate_dead_io_components_pass.cpp",
    "libs/DirectXShaderCompiler/external/SPIRV-Tools/source/opt/feature_manager.cpp",
    "libs/DirectXShaderCompiler/external/SPIRV-Tools/source/opt/instrument_pass.cpp",
    "libs/DirectXShaderCompiler/external/SPIRV-Tools/source/opt/scalar_replacement_pass.cpp",
    "libs/DirectXShaderCompiler/external/SPIRV-Tools/source/opt/loop_dependence_helpers.cpp",
    "libs/DirectXShaderCompiler/external/SPIRV-Tools/source/opt/redundancy_elimination.cpp",
    "libs/DirectXShaderCompiler/external/SPIRV-Tools/source/opt/strip_nonsemantic_info_pass.cpp",
    "libs/DirectXShaderCompiler/external/SPIRV-Tools/source/opt/aggressive_dead_code_elim_pass.cpp",
    "libs/DirectXShaderCompiler/external/SPIRV-Tools/source/opt/fix_func_call_arguments.cpp",
    "libs/DirectXShaderCompiler/external/SPIRV-Tools/source/opt/fold_spec_constant_op_and_composite_pass.cpp",
    "libs/DirectXShaderCompiler/external/SPIRV-Tools/source/opt/dataflow.cpp",
    "libs/DirectXShaderCompiler/external/SPIRV-Tools/source/opt/block_merge_util.cpp",
    "libs/DirectXShaderCompiler/external/SPIRV-Tools/source/opt/pass.cpp",
    "libs/DirectXShaderCompiler/external/SPIRV-Tools/source/opt/relax_float_ops_pass.cpp",
    "libs/DirectXShaderCompiler/external/SPIRV-Tools/source/opt/interp_fixup_pass.cpp",
    "libs/DirectXShaderCompiler/external/SPIRV-Tools/source/opt/instruction.cpp",
    "libs/DirectXShaderCompiler/external/SPIRV-Tools/source/opt/folding_rules.cpp",
    "libs/DirectXShaderCompiler/external/SPIRV-Tools/source/opt/inst_bindless_check_pass.cpp",
    "libs/DirectXShaderCompiler/external/SPIRV-Tools/source/opt/ssa_rewrite_pass.cpp",
    "libs/DirectXShaderCompiler/external/SPIRV-Tools/source/opt/inline_exhaustive_pass.cpp",
    "libs/DirectXShaderCompiler/external/SPIRV-Tools/source/opt/amd_ext_to_khr.cpp",
    "libs/DirectXShaderCompiler/external/SPIRV-Tools/source/opt/dead_branch_elim_pass.cpp",
    "libs/DirectXShaderCompiler/external/SPIRV-Tools/source/opt/loop_dependence.cpp",
    "libs/DirectXShaderCompiler/external/SPIRV-Tools/source/opt/eliminate_dead_constant_pass.cpp",
    "libs/DirectXShaderCompiler/external/SPIRV-Tools/source/opt/simplification_pass.cpp",
    "libs/DirectXShaderCompiler/external/SPIRV-Tools/source/opt/eliminate_dead_functions_pass.cpp",
    "libs/DirectXShaderCompiler/external/SPIRV-Tools/source/opt/loop_fusion_pass.cpp",
    "libs/DirectXShaderCompiler/external/SPIRV-Tools/source/opt/decoration_manager.cpp",
    "libs/DirectXShaderCompiler/external/SPIRV-Tools/source/opt/debug_info_manager.cpp",
    "libs/DirectXShaderCompiler/external/SPIRV-Tools/source/opt/basic_block.cpp",
    "libs/DirectXShaderCompiler/external/SPIRV-Tools/source/opt/switch_descriptorset_pass.cpp",
    "libs/DirectXShaderCompiler/external/SPIRV-Tools/source/opt/code_sink.cpp",
    "libs/DirectXShaderCompiler/external/SPIRV-Tools/source/opt/fix_storage_class.cpp",
    "libs/DirectXShaderCompiler/external/SPIRV-Tools/source/opt/convert_to_sampled_image_pass.cpp",
    "libs/DirectXShaderCompiler/external/SPIRV-Tools/source/opt/graphics_robust_access_pass.cpp",
    "libs/DirectXShaderCompiler/external/SPIRV-Tools/source/opt/inline_opaque_pass.cpp",
    "libs/DirectXShaderCompiler/external/SPIRV-Tools/source/opt/strip_debug_info_pass.cpp",
    "libs/DirectXShaderCompiler/external/SPIRV-Tools/source/opt/dominator_analysis.cpp",
    "libs/DirectXShaderCompiler/external/SPIRV-Tools/source/opt/upgrade_memory_model.cpp",
    "libs/DirectXShaderCompiler/external/SPIRV-Tools/source/opt/loop_peeling.cpp",
    "libs/DirectXShaderCompiler/external/SPIRV-Tools/source/opt/register_pressure.cpp",
    "libs/DirectXShaderCompiler/external/SPIRV-Tools/source/opt/unify_const_pass.cpp",
    "libs/DirectXShaderCompiler/external/SPIRV-Tools/source/opt/replace_desc_array_access_using_var_index.cpp",
    "libs/DirectXShaderCompiler/external/SPIRV-Tools/source/opt/analyze_live_input_pass.cpp",
    "libs/DirectXShaderCompiler/external/SPIRV-Tools/source/opt/invocation_interlock_placement_pass.cpp",
    "libs/DirectXShaderCompiler/external/SPIRV-Tools/source/opt/scalar_analysis.cpp",
    "libs/DirectXShaderCompiler/external/SPIRV-Tools/source/opt/local_redundancy_elimination.cpp",
    "libs/DirectXShaderCompiler/external/SPIRV-Tools/source/opt/inst_buff_addr_check_pass.cpp",
    "libs/DirectXShaderCompiler/external/SPIRV-Tools/source/opt/const_folding_rules.cpp",
    "libs/DirectXShaderCompiler/external/SPIRV-Tools/source/opt/trim_capabilities_pass.cpp",
    "libs/DirectXShaderCompiler/external/SPIRV-Tools/source/opt/reduce_load_size.cpp",
    "libs/DirectXShaderCompiler/external/SPIRV-Tools/source/opt/build_module.cpp",
    "libs/DirectXShaderCompiler/external/SPIRV-Tools/source/opt/local_single_store_elim_pass.cpp",
    "libs/DirectXShaderCompiler/external/SPIRV-Tools/source/opt/mem_pass.cpp",
    "libs/DirectXShaderCompiler/external/SPIRV-Tools/source/opt/module.cpp",
    "libs/DirectXShaderCompiler/external/SPIRV-Tools/source/opt/scalar_analysis_simplification.cpp",
    "libs/DirectXShaderCompiler/external/SPIRV-Tools/source/opt/function.cpp",
    "libs/DirectXShaderCompiler/external/SPIRV-Tools/source/opt/desc_sroa.cpp",
    "libs/DirectXShaderCompiler/external/SPIRV-Tools/source/opt/def_use_manager.cpp",
    "libs/DirectXShaderCompiler/external/SPIRV-Tools/source/opt/compact_ids_pass.cpp",
    "libs/DirectXShaderCompiler/external/SPIRV-Tools/source/opt/workaround1209.cpp",
    "libs/DirectXShaderCompiler/external/SPIRV-Tools/source/opt/instruction_list.cpp",
    "libs/DirectXShaderCompiler/external/SPIRV-Tools/source/opt/loop_fission.cpp",
    "libs/DirectXShaderCompiler/external/SPIRV-Tools/source/opt/strength_reduction_pass.cpp",
    "libs/DirectXShaderCompiler/external/SPIRV-Tools/source/opt/remove_unused_interface_variables_pass.cpp",
    "libs/DirectXShaderCompiler/external/SPIRV-Tools/source/opt/fold.cpp",
    "libs/DirectXShaderCompiler/external/SPIRV-Tools/source/opt/ccp_pass.cpp",
    "libs/DirectXShaderCompiler/external/SPIRV-Tools/source/opt/if_conversion.cpp",
    "libs/DirectXShaderCompiler/external/SPIRV-Tools/source/opt/value_number_table.cpp",
    "libs/DirectXShaderCompiler/external/SPIRV-Tools/source/opt/loop_descriptor.cpp",
    "libs/DirectXShaderCompiler/external/SPIRV-Tools/source/opt/inline_pass.cpp",
    "libs/DirectXShaderCompiler/external/SPIRV-Tools/source/opt/struct_cfg_analysis.cpp",
    "libs/DirectXShaderCompiler/external/SPIRV-Tools/source/opt/composite.cpp",
    "libs/DirectXShaderCompiler/external/SPIRV-Tools/source/opt/freeze_spec_constant_value_pass.cpp",
    "libs/DirectXShaderCompiler/external/SPIRV-Tools/source/opt/cfg.cpp",
    "libs/DirectXShaderCompiler/external/SPIRV-Tools/source/opt/ir_loader.cpp",
    "libs/DirectXShaderCompiler/external/SPIRV-Tools/source/opt/licm_pass.cpp",
    "libs/DirectXShaderCompiler/external/SPIRV-Tools/source/opt/replace_invalid_opc.cpp",
    "libs/DirectXShaderCompiler/external/SPIRV-Tools/source/opt/propagator.cpp",
    "libs/DirectXShaderCompiler/external/SPIRV-Tools/source/opt/types.cpp",
    "libs/DirectXShaderCompiler/external/SPIRV-Tools/source/opt/private_to_local_pass.cpp",
    "libs/DirectXShaderCompiler/external/SPIRV-Tools/source/opt/spread_volatile_semantics.cpp",
    "libs/DirectXShaderCompiler/external/SPIRV-Tools/source/opt/dead_variable_elimination.cpp",
    "libs/DirectXShaderCompiler/external/SPIRV-Tools/source/opt/loop_utils.cpp",
    "libs/DirectXShaderCompiler/external/SPIRV-Tools/source/opt/local_access_chain_convert_pass.cpp",
    "libs/DirectXShaderCompiler/external/SPIRV-Tools/source/opt/cfg_cleanup_pass.cpp",
    "libs/DirectXShaderCompiler/external/SPIRV-Tools/source/opt/combine_access_chains.cpp",
    "libs/DirectXShaderCompiler/external/SPIRV-Tools/source/opt/copy_prop_arrays.cpp",
    "libs/DirectXShaderCompiler/external/SPIRV-Tools/source/opt/type_manager.cpp",
    "libs/DirectXShaderCompiler/external/SPIRV-Tools/source/opt/ir_context.cpp",
    "libs/DirectXShaderCompiler/external/SPIRV-Tools/source/opt/constants.cpp",
    "libs/DirectXShaderCompiler/external/SPIRV-Tools/source/opt/remove_dontinline_pass.cpp",
    "libs/DirectXShaderCompiler/external/SPIRV-Tools/source/opt/dead_insert_elim_pass.cpp",
    "libs/DirectXShaderCompiler/external/SPIRV-Tools/source/opt/pass_manager.cpp",
    "libs/DirectXShaderCompiler/external/SPIRV-Tools/source/opt/merge_return_pass.cpp",
    "libs/DirectXShaderCompiler/external/SPIRV-Tools/source/opt/remove_duplicates_pass.cpp",
    "libs/DirectXShaderCompiler/external/SPIRV-Tools/source/opt/eliminate_dead_functions_util.cpp",
    "libs/DirectXShaderCompiler/external/SPIRV-Tools/source/opt/eliminate_dead_members_pass.cpp",
    "libs/DirectXShaderCompiler/external/SPIRV-Tools/source/opt/control_dependence.cpp",
    "libs/DirectXShaderCompiler/external/SPIRV-Tools/source/opt/vector_dce.cpp",
    "libs/DirectXShaderCompiler/external/SPIRV-Tools/source/opt/optimizer.cpp",
    "libs/DirectXShaderCompiler/external/SPIRV-Tools/source/opt/block_merge_pass.cpp",
    "libs/DirectXShaderCompiler/external/SPIRV-Tools/source/opt/desc_sroa_util.cpp",
    "libs/DirectXShaderCompiler/external/SPIRV-Tools/source/opt/local_single_block_elim_pass.cpp",
    "libs/DirectXShaderCompiler/external/SPIRV-Tools/source/opt/set_spec_constant_default_value_pass.cpp",
    "libs/DirectXShaderCompiler/external/SPIRV-Tools/source/opt/pch_source_opt.cpp",
    "libs/DirectXShaderCompiler/external/SPIRV-Tools/source/opt/loop_fusion.cpp",
};

const spirv_tools_util = [_][]const u8{
    "libs/DirectXShaderCompiler/external/SPIRV-Tools/source/util/bit_vector.cpp",
    "libs/DirectXShaderCompiler/external/SPIRV-Tools/source/util/parse_number.cpp",
    "libs/DirectXShaderCompiler/external/SPIRV-Tools/source/util/string_utils.cpp",
    "libs/DirectXShaderCompiler/external/SPIRV-Tools/source/util/timer.cpp",
};

const spirv_tools_wasm = [_][]const u8{
    "libs/DirectXShaderCompiler/external/SPIRV-Tools/source/wasm/spirv-tools.cpp",
};

const spirv_tools_link = [_][]const u8{
    "libs/DirectXShaderCompiler/external/SPIRV-Tools/source/link/linker.cpp",
};

const spirv_tools_val = [_][]const u8{
    "libs/DirectXShaderCompiler/external/SPIRV-Tools/source/val/validate_extensions.cpp",
    "libs/DirectXShaderCompiler/external/SPIRV-Tools/source/val/validate_conversion.cpp",
    "libs/DirectXShaderCompiler/external/SPIRV-Tools/source/val/validate_arithmetics.cpp",
    "libs/DirectXShaderCompiler/external/SPIRV-Tools/source/val/validate_primitives.cpp",
    "libs/DirectXShaderCompiler/external/SPIRV-Tools/source/val/validate_ray_tracing.cpp",
    "libs/DirectXShaderCompiler/external/SPIRV-Tools/source/val/validate_builtins.cpp",
    "libs/DirectXShaderCompiler/external/SPIRV-Tools/source/val/validate_atomics.cpp",
    "libs/DirectXShaderCompiler/external/SPIRV-Tools/source/val/validate_memory.cpp",
    "libs/DirectXShaderCompiler/external/SPIRV-Tools/source/val/instruction.cpp",
    "libs/DirectXShaderCompiler/external/SPIRV-Tools/source/val/validate_ray_tracing_reorder.cpp",
    "libs/DirectXShaderCompiler/external/SPIRV-Tools/source/val/validate_ray_query.cpp",
    "libs/DirectXShaderCompiler/external/SPIRV-Tools/source/val/validate_literals.cpp",
    "libs/DirectXShaderCompiler/external/SPIRV-Tools/source/val/construct.cpp",
    "libs/DirectXShaderCompiler/external/SPIRV-Tools/source/val/basic_block.cpp",
    "libs/DirectXShaderCompiler/external/SPIRV-Tools/source/val/validate.cpp",
    "libs/DirectXShaderCompiler/external/SPIRV-Tools/source/val/validate_small_type_uses.cpp",
    "libs/DirectXShaderCompiler/external/SPIRV-Tools/source/val/validate_instruction.cpp",
    "libs/DirectXShaderCompiler/external/SPIRV-Tools/source/val/validate_logicals.cpp",
    "libs/DirectXShaderCompiler/external/SPIRV-Tools/source/val/validate_execution_limitations.cpp",
    "libs/DirectXShaderCompiler/external/SPIRV-Tools/source/val/validate_mesh_shading.cpp",
    "libs/DirectXShaderCompiler/external/SPIRV-Tools/source/val/validate_capability.cpp",
    "libs/DirectXShaderCompiler/external/SPIRV-Tools/source/val/validate_decorations.cpp",
    "libs/DirectXShaderCompiler/external/SPIRV-Tools/source/val/validation_state.cpp",
    "libs/DirectXShaderCompiler/external/SPIRV-Tools/source/val/validate_function.cpp",
    "libs/DirectXShaderCompiler/external/SPIRV-Tools/source/val/function.cpp",
    "libs/DirectXShaderCompiler/external/SPIRV-Tools/source/val/validate_interfaces.cpp",
    "libs/DirectXShaderCompiler/external/SPIRV-Tools/source/val/validate_image.cpp",
    "libs/DirectXShaderCompiler/external/SPIRV-Tools/source/val/validate_constants.cpp",
    "libs/DirectXShaderCompiler/external/SPIRV-Tools/source/val/validate_derivatives.cpp",
    "libs/DirectXShaderCompiler/external/SPIRV-Tools/source/val/validate_cfg.cpp",
    "libs/DirectXShaderCompiler/external/SPIRV-Tools/source/val/validate_barriers.cpp",
    "libs/DirectXShaderCompiler/external/SPIRV-Tools/source/val/validate_mode_setting.cpp",
    "libs/DirectXShaderCompiler/external/SPIRV-Tools/source/val/validate_memory_semantics.cpp",
    "libs/DirectXShaderCompiler/external/SPIRV-Tools/source/val/validate_type.cpp",
    "libs/DirectXShaderCompiler/external/SPIRV-Tools/source/val/validate_misc.cpp",
    "libs/DirectXShaderCompiler/external/SPIRV-Tools/source/val/validate_debug.cpp",
    "libs/DirectXShaderCompiler/external/SPIRV-Tools/source/val/validate_bitwise.cpp",
    "libs/DirectXShaderCompiler/external/SPIRV-Tools/source/val/validate_adjacency.cpp",
    "libs/DirectXShaderCompiler/external/SPIRV-Tools/source/val/validate_annotation.cpp",
    "libs/DirectXShaderCompiler/external/SPIRV-Tools/source/val/validate_layout.cpp",
    "libs/DirectXShaderCompiler/external/SPIRV-Tools/source/val/validate_composites.cpp",
    "libs/DirectXShaderCompiler/external/SPIRV-Tools/source/val/validate_scopes.cpp",
    "libs/DirectXShaderCompiler/external/SPIRV-Tools/source/val/validate_non_uniform.cpp",
    "libs/DirectXShaderCompiler/external/SPIRV-Tools/source/val/validate_id.cpp",
};
