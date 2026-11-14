const std = @import("std");
const builtin = @import("builtin");

/// Directories containing `jni.h`/`jni_md.h` for the JDK backing `java_path`
/// (the `java` executable's own path, e.g. from `b.findProgram`).
const JniIncludeDirs = struct { base: []const u8, platform: []const u8 };

/// Locates the JDK's JNI include directories by resolving `java_path` (which
/// may be a `PATH`/`update-alternatives`-style symlink chain) back to a real
/// `$JAVA_HOME/bin/java`, then checking `$JAVA_HOME/include/jni.h` exists.
/// Returns null if it can't be found (e.g. a JRE-only install with no JNI
/// headers) — callers should skip the JNI-dependent test, not fail the build.
fn findJniIncludeDir(b: *std.Build, java_path: []const u8) ?JniIncludeDirs {
    const io = b.graph.io;
    const resolved = std.Io.Dir.realPathFileAbsoluteAlloc(io, java_path, b.allocator) catch
        (b.allocator.dupeSentinel(u8, java_path, 0) catch return null);
    const bin_dir = std.fs.path.dirname(resolved) orelse return null;
    const java_home = std.fs.path.dirname(bin_dir) orelse return null;
    const base = std.fs.path.join(b.allocator, &.{ java_home, "include" }) catch return null;
    const platform_name = switch (builtin.os.tag) {
        .linux => "linux",
        .macos => "darwin",
        .windows => "win32",
        else => return null,
    };
    const platform = std.fs.path.join(b.allocator, &.{ base, platform_name }) catch return null;
    const jni_h = std.fs.path.join(b.allocator, &.{ base, "jni.h" }) catch return null;
    std.Io.Dir.cwd().access(io, jni_h, .{}) catch return null;
    return .{ .base = base, .platform = platform };
}

fn versionFromZon(comptime zon: []const u8) []const u8 {
    const needle = ".version = \"";
    const idx = (std.mem.indexOf(u8, zon, needle) orelse
        @compileError("version field not found in build.zig.zon")) + needle.len;
    const end = std.mem.indexOfScalarPos(u8, zon, idx, '"') orelse
        @compileError("version field not terminated in build.zig.zon");
    return zon[idx..end];
}

const JavaCdrRuntime = struct {
    jar: std.Build.LazyPath,
    python: []const u8,
};

fn addJavaCdrRuntime(b: *std.Build) JavaCdrRuntime {
    const python = b.findProgram(.{ .names = &.{ "python3", "python" } }) orelse "python3";
    const javac = b.findProgram(.{ .names = &.{"javac"} }) orelse "javac";
    const version = comptime versionFromZon(@embedFile("build.zig.zon"));
    const name = b.fmt("zidl-cdr-java-{s}.jar", .{version});
    const builder = b.addSystemCommand(&.{python});
    builder.addFileArg(b.path("packages/zidl-cdr-java/build.py"));
    builder.addArgs(&.{ "build", "--javac", javac, "--version", version, "--output" });
    const jar = builder.addOutputFileArg(name);
    builder.addFileInput(b.path("packages/zidl-cdr-java/src/main/java/io/zidl/cdr/Cdr.java"));
    builder.addFileInput(b.path("LICENSE"));
    const install = b.addInstallFile(jar, b.fmt("share/java/{s}", .{name}));
    b.step("java-runtime", "Build and install the standalone Java CDR JAR").dependOn(&install.step);
    return .{ .jar = jar, .python = python };
}

fn javaCommand(b: *std.Build, args: []const []const u8, runtime: JavaCdrRuntime) *std.Build.Step.Run {
    const run = b.addSystemCommand(&.{runtime.python});
    run.addFileArg(b.path("packages/zidl-cdr-java/build.py"));
    run.addArg("run");
    run.addArg("--runtime");
    run.addFileArg(runtime.jar);
    run.addArg("--");
    run.addArgs(args);
    return run;
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const coverage = b.option(bool, "coverage", "Use LLVM for kcov-compatible test debug information") orelse false;
    const sanitize_thread = b.option(bool, "sanitize-thread", "Enable ThreadSanitizer") orelse false;
    const verbose_tests = b.option(bool, "verbose-tests", "Show successful integration test output") orelse false;
    const runtimes = @import("build/runtime.zig").add(b, b.path("."), target, optimize, sanitize_thread);
    const cdr_library = @import("packages/zidl-cdr/c_api_build.zig").add(b, b.path("packages/zidl-cdr"), runtimes.codec, target, .Debug, sanitize_thread, true);
    // Allocation failpoint executables replace global new/delete. TSan defines
    // those same symbols; keep these single-threaded tests and their archive
    // unsanitized, while the normal runtime/consumer tests retain TSan coverage.
    const allocation_cdr_library = if (sanitize_thread) blk: {
        const uninstrumented = @import("build/runtime.zig").add(b, b.path("."), target, .Debug, false);
        break :blk @import("packages/zidl-cdr/c_api_build.zig").add(b, b.path("packages/zidl-cdr"), uninstrumented.codec, target, .Debug, false, true);
    } else cdr_library;
    b.modules.put(b.allocator, "zidl_cdr", runtimes.codec) catch @panic("OOM");
    b.modules.put(b.allocator, "zidl_bindings", runtimes.bindings) catch @panic("OOM");

    const zidl_xtypes_mod = b.addModule("zidl_xtypes", .{
        .root_source_file = b.path("packages/zidl-xtypes/src/root.zig"),
        .target = target,
        .sanitize_thread = sanitize_thread,
    });

    const mod = b.addModule("zidl", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .sanitize_thread = sanitize_thread,
        .imports = &.{
            .{ .name = "zidl_xtypes", .module = zidl_xtypes_mod },
        },
    });

    const build_options = b.addOptions();
    build_options.addOption([]const u8, "version_string", b.fmt("zidl {s}", .{comptime versionFromZon(@embedFile("build.zig.zon"))}));

    const exe = b.addExecutable(.{
        .name = "zidl",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .sanitize_thread = sanitize_thread,
            .imports = &.{
                .{ .name = "zidl", .module = mod },
                .{ .name = "build_options", .module = build_options.createModule() },
            },
        }),
    });
    b.installArtifact(exe);

    const java_cdr = addJavaCdrRuntime(b);

    // ── run ───────────────────────────────────────────────────────────────────
    const run_step = b.step("run", "Run the app");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();

    // ── unit tests ────────────────────────────────────────────────────────────
    const mod_tests = b.addTest(.{ .name = "zidl-mod", .root_module = mod });
    const run_mod_tests = b.addRunArtifact(mod_tests);

    const exe_tests = b.addTest(.{ .name = "zidl-exe", .root_module = exe.root_module });
    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run unit tests + Zig integration tests");
    const java_validation_step = b.step("test-java-cdr-validation", "Test Java CDR validation and output modes");
    test_step.dependOn(java_validation_step);
    if (b.findProgram(.{ .names = &.{"javac"} })) |javac| {
        if (b.findProgram(.{ .names = &.{"java"} })) |java| {
            const runtime_tests = b.step("test-java-runtime", "Test standalone Java CDR API");
            test_step.dependOn(runtime_tests);
            const compile_runtime_test = javaCommand(b, &.{ javac, "--release", "8", "-Xlint:-options", "-Xlint:all", "-Werror", "-d" }, java_cdr);
            const runtime_classes = compile_runtime_test.addOutputDirectoryArg("java-runtime-test-classes");
            compile_runtime_test.addFileArg(b.path("packages/zidl-cdr-java/src/test/java/io/zidl/cdr/CdrTest.java"));
            compile_runtime_test.addFileArg(b.path("packages/zidl-cdr-java/src/test/java/io/zidl/cdr/HelperTest.java"));
            const run_runtime_test = javaCommand(b, &.{ java, "-cp" }, java_cdr);
            run_runtime_test.addDirectoryArg(runtime_classes);
            run_runtime_test.addArg("io.zidl.cdr.CdrTest");
            runtime_tests.dependOn(&run_runtime_test.step);
            const run_helpers = javaCommand(b, &.{ java, "-cp" }, java_cdr);
            run_helpers.addDirectoryArg(runtime_classes);
            run_helpers.addArg("io.zidl.cdr.HelperTest");
            runtime_tests.dependOn(&run_helpers.step);
            for (0..3) |mode| {
                const split = mode != 0;
                const prefix: []const u8 = switch (mode) {
                    0 => "Validation$JavaValidation$",
                    1 => "javavalidation.",
                    else => "",
                };
                const gen = b.addRunArtifact(exe);
                gen.addArgs(&.{ "-b", "java" });
                if (split) gen.addArg("--split-files");
                if (mode == 1) gen.addArgs(&.{ "--java-package", "javavalidation" });
                gen.addArg("-o");
                const generated = gen.addOutputDirectoryArg(b.fmt("java-validation-{d}", .{mode}));
                gen.addFileArg(b.path("test/integration/java_cdr_validation/validation.idl"));
                const compile_java = javaCommand(b, &.{ javac, "-Xlint:unchecked", "-Werror", "-d" }, java_cdr);
                const classes = compile_java.addOutputDirectoryArg("classes");
                if (split) {
                    compile_java.addFileArg(generated.path(b, "ValidationCdrUtils.java"));
                    for ([_][]const u8{ "Narrow", "App", "AppText", "Parent", "Mut", "MutText", "AppChoice", "MutChoice", "Numbers", "Words", "WordArray", "Dict", "Bounded", "BoundedMap", "Empty", "EmptyValues", "NestedValues", "FixedValues", "Flags", "OptionalValues" }) |name| {
                        compile_java.addFileArg(generated.path(b, b.fmt("{s}.java", .{name})));
                    }
                } else compile_java.addFileArg(generated.path(b, "Validation.java"));
                compile_java.addFileArg(b.path("test/integration/java_cdr_validation/ValidationTest.java"));
                compile_java.addFileArg(b.path("test/integration/java_cdr_validation/FrameTest.java"));
                compile_java.addFileArg(b.path("test/integration/java_cdr_validation/MemberTest.java"));
                compile_java.addFileArg(b.path("test/integration/java_cdr_validation/CollectionTest.java"));
                compile_java.addFileArg(b.path("test/integration/java_cdr_validation/ParityTest.java"));
                const run = javaCommand(b, &.{ java, "-Xmx32m", "-cp" }, java_cdr);
                run.addDirectoryArg(classes);
                run.addArgs(&.{ "ValidationTest", prefix });
                java_validation_step.dependOn(&run.step);
                const frames = javaCommand(b, &.{ java, "-Xmx32m", "-cp" }, java_cdr);
                frames.addDirectoryArg(classes);
                frames.addArgs(&.{ "FrameTest", prefix });
                java_validation_step.dependOn(&frames.step);
                const members = javaCommand(b, &.{ java, "-Xmx32m", "-cp" }, java_cdr);
                members.addDirectoryArg(classes);
                members.addArgs(&.{ "MemberTest", prefix });
                java_validation_step.dependOn(&members.step);
                const collections = javaCommand(b, &.{ java, "-Xmx32m", "-cp" }, java_cdr);
                collections.addDirectoryArg(classes);
                collections.addArgs(&.{ "CollectionTest", prefix });
                java_validation_step.dependOn(&collections.step);
                const parity = javaCommand(b, &.{ java, "-Xmx32m", "-cp" }, java_cdr);
                parity.addDirectoryArg(classes);
                parity.addArgs(&.{ "ParityTest", prefix });
                java_validation_step.dependOn(&parity.step);
            }
        }
    }
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);

    const package_step = b.step("test-runtime-packages", "Check canonical codec and binding runtime packages");
    test_step.dependOn(package_step);
    for ([_]*std.Build.Module{ runtimes.codec, runtimes.bindings }) |runtime_module| {
        const runtime_tests = b.addTest(.{ .root_module = runtime_module, .use_llvm = if (coverage or sanitize_thread) true else null });
        package_step.dependOn(&b.addRunArtifact(runtime_tests).step);
    }

    const authoring_step = b.step("test-authoring", "Test generated strict presence-aware authoring records");
    const authoring_gen = b.addRunArtifact(exe);
    authoring_gen.addArgs(&.{ "-b", "zig", "--single-file", "--zig-generate-authoring", "--no-typesupport", "--no-typeobject-support", "-o" });
    const authoring_dir = authoring_gen.addOutputDirectoryArg("authoring-config");
    authoring_gen.addFileArg(b.path("test/integration/authoring/config.idl"));
    const authoring_schema = b.createModule(.{
        .root_source_file = authoring_dir.path(b, "config.zig"),
        .target = target,
        .optimize = optimize,
        .sanitize_thread = sanitize_thread,
        .imports = &.{ .{ .name = "zidl_cdr", .module = runtimes.codec }, .{ .name = "zidl_bindings", .module = runtimes.bindings } },
    });
    const authoring_feature_gen = b.addRunArtifact(exe);
    authoring_feature_gen.addArgs(&.{ "-b", "zig", "--single-file", "--zig-generate-authoring", "--no-typesupport", "--no-typeobject-support", "-D", "AUTHORING_FEATURE", "-o" });
    const authoring_feature_dir = authoring_feature_gen.addOutputDirectoryArg("authoring-config-feature");
    authoring_feature_gen.addFileArg(b.path("test/integration/authoring/config.idl"));
    const authoring_feature = b.createModule(.{
        .root_source_file = authoring_feature_dir.path(b, "config.zig"),
        .target = target,
        .optimize = optimize,
        .sanitize_thread = sanitize_thread,
        .imports = &.{ .{ .name = "zidl_cdr", .module = runtimes.codec }, .{ .name = "zidl_bindings", .module = runtimes.bindings } },
    });
    const authoring_test = b.addTest(.{ .name = "authoring-test", .use_llvm = if (coverage or sanitize_thread) true else null, .root_module = b.createModule(.{
        .root_source_file = b.path("test/integration/authoring/test.zig"),
        .target = target,
        .optimize = optimize,
        .sanitize_thread = sanitize_thread,
        .imports = &.{ .{ .name = "zidl_cdr", .module = runtimes.codec }, .{ .name = "zidl_bindings", .module = runtimes.bindings }, .{ .name = "authoring_types", .module = authoring_schema }, .{ .name = "authoring_feature", .module = authoring_feature } },
    }) });
    const authoring_run = b.addRunArtifact(authoring_test);
    authoring_step.dependOn(&authoring_run.step);
    test_step.dependOn(&authoring_run.step);

    var typesupport_emit: ?*std.Build.Step = null;
    // This prototype's real dynamic-load hosts are Linux-only. Do not make
    // other platforms' existing test suites depend on an unported loader host.
    if (target.result.os.tag == .linux and b.graph.host.result.os.tag == .linux) {
        const typesupport_library_tests = @import("test/integration/typesupport_library/build.zig").addTests(
            b,
            b.path("test/integration/typesupport_library"),
            exe.getEmittedBin(),
            target,
            optimize,
            verbose_tests,
            coverage,
        );
        test_step.dependOn(typesupport_library_tests.tests);
        typesupport_emit = typesupport_library_tests.emit;
    }

    // ── Zig integration tests ─────────────────────────────────────────────────
    // These use the committed golden types.zig and run CDR round-trip + vtable tests.

    // Share the same runtime module with generated wire-library consumers.
    const ts_header = b.addTranslateC(.{
        .root_source_file = b.path("packages/zidl-typesupport/include/zidl_typesupport.h"),
        .target = target,
        .optimize = optimize,
        .link_libc = false,
    });
    _ = b.addModule("zidl_typesupport", .{
        .root_source_file = b.path("packages/zidl-typesupport/src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zidl_cdr", .module = runtimes.codec },                     .{ .name = "zidl_bindings", .module = runtimes.bindings },
            .{ .name = "zidl_typesupport_c", .module = ts_header.createModule() },
        },
    });

    const golden_zig_mod = b.createModule(.{
        .root_source_file = b.path("test/golden/zig/types.zig"),
        .target = target,
        .sanitize_thread = sanitize_thread,
        .imports = &.{
            .{ .name = "zidl_cdr", .module = runtimes.codec }, .{ .name = "zidl_bindings", .module = runtimes.bindings },
        },
    });

    const stub_mod = b.createModule(.{
        .root_source_file = b.path("test/integration/zig/stub_impl.zig"),
        .target = target,
        .sanitize_thread = sanitize_thread,
        .imports = &.{
            .{ .name = "types", .module = golden_zig_mod },
            .{ .name = "zidl_cdr", .module = runtimes.codec },
            .{ .name = "zidl_bindings", .module = runtimes.bindings },
        },
    });

    const zig_integration_tests = b.addTest(.{
        .name = "zidl-integ",
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/integration/zig/test.zig"),
            .target = target,
            .sanitize_thread = sanitize_thread,
            .imports = &.{
                .{ .name = "zidl_cdr", .module = runtimes.codec }, .{ .name = "zidl_bindings", .module = runtimes.bindings },
                .{ .name = "types", .module = golden_zig_mod },    .{ .name = "stub_impl", .module = stub_mod },
            },
        }),
    });
    const run_zig_integration = b.addRunArtifact(zig_integration_tests);
    test_step.dependOn(&run_zig_integration.step);

    // ── Zig "dds module adapter contract" compile check ────────────────────────
    // getFieldFromCdr and the FooDataWriter/FooDataReader wrappers are only
    // emitted with --generate-zzdds-wrappers, which no golden output above
    // uses; their own regression tests (in src/backend/zig.zig) only
    // substring-match generated source text, so they could pass even if Zig
    // rejected the generated code outright (see zidl PR #40 review). This
    // section actually compiles fresh --generate-zzdds-wrappers output
    // against fake_middleware.zig's synthetic contract implementation (see
    // that file's doc comment for why it isn't a zzdds mirror) so a codegen
    // regression here is a real `zig build test` failure, not just a
    // stale-looking substring match.
    {
        const gen_wrapper_fixture = b.addRunArtifact(exe);
        gen_wrapper_fixture.addArgs(&.{ "-b", "zig", "--generate-zzdds-wrappers", "-o" });
        const wrapper_fixture_dir = gen_wrapper_fixture.addOutputDirectoryArg("zig-wrapper-contract-gen");
        gen_wrapper_fixture.addFileArg(b.path("test/integration/zig_wrapper_contract/fixture.idl"));

        const fake_middleware_mod = b.createModule(.{
            .root_source_file = b.path("test/integration/zig_wrapper_contract/fake_middleware.zig"),
            .target = target,
            .sanitize_thread = sanitize_thread,
        });

        const wrapper_fixture_mod = b.createModule(.{
            .root_source_file = wrapper_fixture_dir.path(b, "fixture.zig"),
            .target = target,
            .sanitize_thread = sanitize_thread,
            .imports = &.{
                .{ .name = "zidl_cdr", .module = runtimes.codec },   .{ .name = "zidl_bindings", .module = runtimes.bindings },
                .{ .name = "zzdds", .module = fake_middleware_mod },
            },
        });

        const wrapper_contract_tests = b.addTest(.{
            .name = "zidl-wrapper-contract",
            .root_module = b.createModule(.{
                .root_source_file = b.path("test/integration/zig_wrapper_contract/test.zig"),
                .target = target,
                .sanitize_thread = sanitize_thread,
                .imports = &.{
                    .{ .name = "zidl_cdr", .module = runtimes.codec },     .{ .name = "zidl_bindings", .module = runtimes.bindings },
                    .{ .name = "fixture", .module = wrapper_fixture_mod }, .{ .name = "zzdds", .module = fake_middleware_mod },
                },
            }),
        });
        const run_wrapper_contract = b.addRunArtifact(wrapper_contract_tests);
        test_step.dependOn(&run_wrapper_contract.step);
    }

    // Compile and run the full C++ condition hierarchy and raw-op adapters.
    // Keep this in the default tests: signature text checks alone cannot catch
    // incompatible native_handle return types or incorrect shared_ptr upcasts.
    {
        const gen_c = b.addRunArtifact(exe);
        gen_c.addArgs(&.{ "-b", "c", "--generate-interfaces", "-o" });
        const c_dir = gen_c.addOutputDirectoryArg("cpp-conditions-c");
        gen_c.addFileArg(b.path("test/integration/cpp_conditions/dcps.idl"));
        const gen_cpp = b.addRunArtifact(exe);
        gen_cpp.addArgs(&.{ "-b", "cpp", "--generate-interfaces", "--cpp-generate-impl", "--handle-retire-hook", "test_retire", "--handle-retire-query", "test_is_retired", "-o" });
        const cpp_dir = gen_cpp.addOutputDirectoryArg("cpp-conditions-cpp");
        gen_cpp.addFileArg(b.path("test/integration/cpp_conditions/dcps.idl"));
        const gen_topic = b.addRunArtifact(exe);
        gen_topic.addArgs(&.{ "-b", "cpp", "--generate-zzdds-wrappers", "-o" });
        const topic_dir = gen_topic.addOutputDirectoryArg("cpp-conditions-topic");
        gen_topic.addFileArg(b.path("test/integration/cpp_conditions/topic.idl"));
        // Built twice: as usual, and without RTTI or exceptions, which the
        // generated C++ must also compile and work under.
        const variants = [_]struct { name: []const u8, flags: []const []const u8 }{
            .{ .name = "zidl-cpp-conditions", .flags = &.{ "-std=c++17", "-Wall", "-Werror" } },
            .{ .name = "zidl-cpp-conditions-no-rtti-no-exceptions", .flags = &.{ "-std=c++17", "-Wall", "-Werror", "-fno-rtti", "-fno-exceptions" } },
        };
        for (variants) |variant| {
            const conditions_mod = b.createModule(.{
                .root_source_file = null,
                .target = target,
                .optimize = .Debug,
                .sanitize_thread = sanitize_thread,
                .link_libc = true,
                .link_libcpp = true,
            });
            conditions_mod.addCSourceFile(.{
                .file = b.path("test/integration/cpp_conditions/test.cpp"),
                .flags = variant.flags,
            });
            conditions_mod.addCSourceFile(.{
                .file = cpp_dir.path(b, "dcps_impl.cpp"),
                .flags = variant.flags,
            });
            conditions_mod.addCSourceFile(.{
                .file = topic_dir.path(b, "topic_cdr.cpp"),
                .flags = variant.flags,
            });
            linkCdr(conditions_mod, cdr_library);
            conditions_mod.addIncludePath(topic_dir);
            conditions_mod.addIncludePath(cpp_dir);
            conditions_mod.addIncludePath(c_dir);
            conditions_mod.addIncludePath(b.path("test/integration/cpp_conditions"));
            conditions_mod.addIncludePath(b.path("packages/zidl-cdr/include"));
            const conditions_test = b.addExecutable(.{ .name = variant.name, .root_module = conditions_mod });
            test_step.dependOn(&b.addRunArtifact(conditions_test).step);
        }
    }

    // ── PL_CDR retention / strict-mode compile-and-run check ──────────────────
    // src/backend/zig.zig's PL_CDR tests only substring-match. This generates
    // test/integration/zig_pl_cdr/fixture.idl with --zig-pl-cdr, compiles the
    // output, and round-trips it (retention, replay, strict must-understand,
    // deinit/clone of unknown_params).
    {
        const gen_pl_cdr = b.addRunArtifact(exe);
        gen_pl_cdr.addArgs(&.{ "-b", "zig", "--zig-pl-cdr", "--no-typeobject-support", "-o" });
        const pl_cdr_dir = gen_pl_cdr.addOutputDirectoryArg("zig-pl-cdr-gen");
        gen_pl_cdr.addFileArg(b.path("test/integration/zig_pl_cdr/fixture.idl"));

        const pl_cdr_fixture_mod = b.createModule(.{
            .root_source_file = pl_cdr_dir.path(b, "fixture.zig"),
            .target = target,
            .sanitize_thread = sanitize_thread,
            .imports = &.{
                .{ .name = "zidl_cdr", .module = runtimes.codec }, .{ .name = "zidl_bindings", .module = runtimes.bindings },
            },
        });

        const pl_cdr_tests = b.addTest(.{
            .name = "zidl-pl-cdr",
            .root_module = b.createModule(.{
                .root_source_file = b.path("test/integration/zig_pl_cdr/test.zig"),
                .target = target,
                .sanitize_thread = sanitize_thread,
                .imports = &.{
                    .{ .name = "zidl_cdr", .module = runtimes.codec },    .{ .name = "zidl_bindings", .module = runtimes.bindings },
                    .{ .name = "fixture", .module = pl_cdr_fixture_mod },
                },
            }),
        });
        const run_pl_cdr = b.addRunArtifact(pl_cdr_tests);
        test_step.dependOn(&run_pl_cdr.step);
    }

    // ── Union deinit/error-safety compile-and-run check ───────────────────────
    // src/backend/zig.zig's union codegen tests only substring-match. This
    // generates test/integration/zig_union_safety/fixture.idl, compiles the
    // output, and exercises a mid-decode failure on a heap-owning case to
    // catch a regression in the generated deserializeInto/deinit interaction
    // (the discriminant must not be committed before the payload it now
    // points at is known to actually be there).
    {
        const gen_union_safety = b.addRunArtifact(exe);
        gen_union_safety.addArgs(&.{ "-b", "zig", "--no-typeobject-support", "-o" });
        const union_safety_dir = gen_union_safety.addOutputDirectoryArg("zig-union-safety-gen");
        gen_union_safety.addFileArg(b.path("test/integration/zig_union_safety/fixture.idl"));

        const union_safety_fixture_mod = b.createModule(.{
            .root_source_file = union_safety_dir.path(b, "fixture.zig"),
            .target = target,
            .sanitize_thread = sanitize_thread,
            .imports = &.{
                .{ .name = "zidl_cdr", .module = runtimes.codec }, .{ .name = "zidl_bindings", .module = runtimes.bindings },
            },
        });

        const union_safety_tests = b.addTest(.{
            .name = "zidl-union-safety",
            .root_module = b.createModule(.{
                .root_source_file = b.path("test/integration/zig_union_safety/test.zig"),
                .target = target,
                .sanitize_thread = sanitize_thread,
                .imports = &.{
                    .{ .name = "zidl_cdr", .module = runtimes.codec },          .{ .name = "zidl_bindings", .module = runtimes.bindings },
                    .{ .name = "fixture", .module = union_safety_fixture_mod },
                },
            }),
        });
        const run_union_safety = b.addRunArtifact(union_safety_tests);
        test_step.dependOn(&run_union_safety.step);
        const union_safety_step = b.step("test-zig-union-safety", "Compile and exercise Zig union codecs and cleanup");
        test_step.dependOn(union_safety_step);
        union_safety_step.dependOn(&run_union_safety.step);
        // Lifecycle/default construction is also emitted without wire codecs.
        for ([_]bool{ false, true }) |split| {
            const declarations = b.addRunArtifact(exe);
            declarations.addArgs(&.{ "-b", "zig", "--no-typesupport", "--no-typeobject-support" });
            if (split) declarations.addArg("--split-files");
            declarations.addArg("-o");
            const dir = declarations.addOutputDirectoryArg(if (split) "union-declarations-split" else "union-declarations");
            declarations.addFileArg(b.path("test/integration/zig_union_safety/fixture.idl"));
            const fixture_mod = b.createModule(.{
                .root_source_file = dir.path(b, "fixture.zig"),
                .target = target,
                .sanitize_thread = sanitize_thread,
                .imports = &.{ .{ .name = "zidl_cdr", .module = runtimes.codec }, .{ .name = "zidl_bindings", .module = runtimes.bindings } },
            });
            const tests = b.addTest(.{ .root_module = b.createModule(.{
                .root_source_file = b.path("test/integration/zig_union_safety/construction.zig"),
                .target = target,
                .sanitize_thread = sanitize_thread,
                .imports = &.{.{ .name = "fixture", .module = fixture_mod }},
            }) });
            union_safety_step.dependOn(&b.addRunArtifact(tests).step);
        }
    }

    // ── Sequence-element compile-and-run checks (Zig, C, C++) ───────────────
    // Sequences of struct/union elements (and aliases of them) exercise
    // allocator forwarding, element ownership, declaration order and linkage
    // that the codegen unit tests only substring-match. Generate
    // test/integration/sequence_elements/fixture.idl for each backend, compile
    // it with warnings as errors and run the round-trip, partial-decode and
    // allocation-failure checks. See fixture.idl for the regressions covered.
    {
        const seq_idl = b.path("test/integration/sequence_elements/fixture.idl");

        const gen_zig = b.addRunArtifact(exe);
        gen_zig.addArgs(&.{ "-b", "zig", "--no-typeobject-support", "-o" });
        const zig_dir = gen_zig.addOutputDirectoryArg("sequence-elements-zig");
        gen_zig.addFileArg(seq_idl);

        const zig_fixture_mod = b.createModule(.{
            .root_source_file = zig_dir.path(b, "fixture.zig"),
            .target = target,
            .sanitize_thread = sanitize_thread,
            .imports = &.{
                .{ .name = "zidl_cdr", .module = runtimes.codec }, .{ .name = "zidl_bindings", .module = runtimes.bindings },
            },
        });
        const zig_tests = b.addTest(.{
            .name = "zidl-sequence-elements",
            .root_module = b.createModule(.{
                .root_source_file = b.path("test/integration/sequence_elements/test.zig"),
                .target = target,
                .sanitize_thread = sanitize_thread,
                .imports = &.{
                    .{ .name = "zidl_cdr", .module = runtimes.codec }, .{ .name = "zidl_bindings", .module = runtimes.bindings },
                    .{ .name = "fixture", .module = zig_fixture_mod },
                },
            }),
        });
        test_step.dependOn(&b.addRunArtifact(zig_tests).step);

        const gen_c = b.addRunArtifact(exe);
        gen_c.addArgs(&.{ "-b", "c", "-o" });
        const c_dir = gen_c.addOutputDirectoryArg("sequence-elements-c");
        gen_c.addFileArg(seq_idl);
        const c_mod = b.createModule(.{
            .root_source_file = null,
            .target = target,
            .optimize = .Debug,
            .sanitize_thread = sanitize_thread,
            .link_libc = true,
        });
        c_mod.addCSourceFile(.{
            .file = b.path("test/integration/sequence_elements/test.c"),
            .flags = &.{ "-std=c99", "-Wall", "-Werror" },
        });
        c_mod.addCSourceFile(.{
            .file = c_dir.path(b, "fixture_cdr.c"),
            .flags = &.{ "-std=c99", "-Wall", "-Werror" },
        });
        linkCdr(c_mod, cdr_library);
        c_mod.addIncludePath(c_dir);
        c_mod.addIncludePath(b.path("packages/zidl-cdr/include"));
        const c_test = b.addExecutable(.{ .name = "zidl-sequence-elements-c", .root_module = c_mod });
        const run_c_test = b.addRunArtifact(c_test);
        if (!verbose_tests) run_c_test.expectStdOutMatch("sequence_elements C: all checks passed");
        test_step.dependOn(&run_c_test.step);

        // The same C test against `--split-files` output (one header and
        // `_cdr.c` per type): split headers must not re-declare types their
        // dependency headers provide, and unions / sequence typedefs need
        // their own `_cdr.c`. `fixture.h` is shimmed onto `fixture_all.h`.
        const gen_c_split = b.addRunArtifact(exe);
        gen_c_split.addArgs(&.{ "-b", "c", "--split-files", "-o" });
        const c_split_dir = gen_c_split.addOutputDirectoryArg("sequence-elements-c-split");
        gen_c_split.addFileArg(seq_idl);
        const c_split_shim = b.addWriteFiles().add("fixture.h", "#include \"fixture_all.h\"\n");
        const c_split_mod = b.createModule(.{
            .root_source_file = null,
            .target = target,
            .optimize = .Debug,
            .sanitize_thread = sanitize_thread,
            .link_libc = true,
        });
        c_split_mod.addCSourceFile(.{
            .file = b.path("test/integration/sequence_elements/test.c"),
            .flags = &.{ "-std=c99", "-Wall", "-Werror" },
        });
        // Every type in fixture.idl that gets a `_cdr.c` in split mode
        // (structs, unions, unbounded sequence typedefs). A stale entry fails
        // the build; a missing one fails the link.
        const split_cdr_stems = [_][]const u8{
            "Point",                  "Named",                "Choice",
            "AliasHolder",            "NamedHolder",          "ChoiceHolder",
            "ColorHolder",            "AppendableHolder",     "MutableHolder",
            "SeqCase",                "NamedSeq",             "UnboundedHolder",
            "TypedefUnboundedHolder", "TypedefBoundedHolder", "Outer",
            "LabelList",              "AliasElementHolder",   "OptionalHolder",
            "PeopleCase",
        };
        for (split_cdr_stems) |stem| {
            c_split_mod.addCSourceFile(.{
                .file = c_split_dir.path(b, b.fmt("{s}_cdr.c", .{stem})),
                .flags = &.{ "-std=c99", "-Wall", "-Werror" },
            });
        }
        linkCdr(c_split_mod, cdr_library);
        c_split_mod.addIncludePath(c_split_shim.dirname());
        c_split_mod.addIncludePath(c_split_dir);
        c_split_mod.addIncludePath(b.path("packages/zidl-cdr/include"));
        const c_split_test = b.addExecutable(.{ .name = "zidl-sequence-elements-c-split", .root_module = c_split_mod });
        const run_c_split_test = b.addRunArtifact(c_split_test);
        if (!verbose_tests) run_c_split_test.expectStdOutMatch("sequence_elements C: all checks passed");
        test_step.dependOn(&run_c_split_test.step);

        const gen_cpp = b.addRunArtifact(exe);
        gen_cpp.addArgs(&.{ "-b", "cpp", "-o" });
        const cpp_dir = gen_cpp.addOutputDirectoryArg("sequence-elements-cpp");
        gen_cpp.addFileArg(seq_idl);
        const cpp_mod = b.createModule(.{
            .root_source_file = null,
            .target = target,
            .optimize = .Debug,
            .sanitize_thread = sanitize_thread,
            .link_libc = true,
            .link_libcpp = true,
        });
        cpp_mod.addCSourceFile(.{
            .file = b.path("test/integration/sequence_elements/test.cpp"),
            .flags = &.{ "-std=c++17", "-Wall", "-Werror" },
        });
        cpp_mod.addCSourceFile(.{
            .file = cpp_dir.path(b, "fixture_cdr.cpp"),
            .flags = &.{ "-std=c++17", "-Wall", "-Werror" },
        });
        linkCdr(cpp_mod, cdr_library);
        cpp_mod.addIncludePath(cpp_dir);
        cpp_mod.addIncludePath(b.path("packages/zidl-cdr/include"));
        const cpp_test = b.addExecutable(.{ .name = "zidl-sequence-elements-cpp", .root_module = cpp_mod });
        const run_cpp_test = b.addRunArtifact(cpp_test);
        if (!verbose_tests) run_cpp_test.expectStdOutMatch("sequence_elements C++: all checks passed");
        test_step.dependOn(&run_cpp_test.step);
    }

    // Canonical key holders: independent RTPS bytes and type-maximum hash policy.
    {
        const key_step = b.step("test-canonical-keys", "Check native canonical key holders and type-aware hashes");
        test_step.dependOn(key_step);
        const dir = "test/integration/canonical_keys/";
        const gen_zig = b.addRunArtifact(exe);
        gen_zig.addArgs(&.{ "-b", "zig", "-o" });
        const zig_dir = gen_zig.addOutputDirectoryArg("canonical-keys-zig");
        gen_zig.addFileArg(b.path(dir ++ "keys.idl"));
        gen_zig.addFileInput(b.path(dir ++ "array_keys.idl"));
        gen_zig.addFileInput(b.path(dir ++ "variable_keys.idl"));
        const fixture = b.createModule(.{
            .root_source_file = zig_dir.path(b, "keys.zig"),
            .target = target,
            .sanitize_thread = sanitize_thread,
            .imports = &.{ .{ .name = "zidl_cdr", .module = runtimes.codec }, .{ .name = "zidl_bindings", .module = runtimes.bindings } },
        });
        const tests = b.addTest(.{ .name = "zidl-canonical-keys", .root_module = b.createModule(.{
            .root_source_file = b.path(dir ++ "test.zig"),
            .target = target,
            .sanitize_thread = sanitize_thread,
            .imports = &.{ .{ .name = "zidl_cdr", .module = runtimes.codec }, .{ .name = "zidl_bindings", .module = runtimes.bindings }, .{ .name = "fixture", .module = fixture } },
        }) });
        key_step.dependOn(&b.addRunArtifact(tests).step);
        for ([_][]const u8{ "c", "cpp" }) |lang| {
            const cpp = std.mem.eql(u8, lang, "cpp");
            const gen = b.addRunArtifact(exe);
            gen.addArgs(&.{ "-b", lang, "-o" });
            const generated = gen.addOutputDirectoryArg(b.fmt("canonical-keys-{s}", .{lang}));
            gen.addFileArg(b.path(dir ++ "keys.idl"));
            gen.addFileInput(b.path(dir ++ "array_keys.idl"));
            gen.addFileInput(b.path(dir ++ "variable_keys.idl"));
            const m = b.createModule(.{ .root_source_file = null, .target = target, .optimize = .Debug, .sanitize_thread = sanitize_thread, .link_libc = true, .link_libcpp = cpp });
            const flags: []const []const u8 = if (cpp) &.{ "-std=c++17", "-Wall", "-Wextra", "-Werror" } else &.{ "-std=c99", "-Wall", "-Werror" };
            m.addCSourceFile(.{ .file = b.path(if (cpp) dir ++ "test.cpp" else dir ++ "test.c"), .flags = flags });
            m.addCSourceFile(.{ .file = generated.path(b, if (cpp) "keys_cdr.cpp" else "keys_cdr.c"), .flags = flags });
            linkCdr(m, cdr_library);
            m.addIncludePath(generated);
            m.addIncludePath(b.path("packages/zidl-cdr/include"));
            const app = b.addExecutable(.{ .name = b.fmt("zidl-canonical-keys-{s}", .{lang}), .root_module = m });
            const run = b.addRunArtifact(app);
            run.addFileArg(b.path(dir ++ "vectors.txt"));
            for ([_][]const u8{ "wire_ids.txt", "wide_wire.txt", "key_wire.txt", "array_vectors.txt", "variable_vectors.txt" }) |name| run.addFileInput(b.path(b.fmt("{s}{s}", .{ dir, name })));
            key_step.dependOn(&run.step);
        }
        const maybe_javac = b.findProgram(.{ .names = &.{"javac"} });
        const maybe_java = b.findProgram(.{ .names = &.{"java"} });
        if (maybe_javac != null and maybe_java != null) {
            for ([_]bool{ false, true }) |split| {
                const gen = b.addRunArtifact(exe);
                gen.addArgs(&.{ "-b", "java" });
                if (split) gen.addArgs(&.{ "--split-files", "--java-package", "canonicalkeys" });
                gen.addArg("-o");
                const generated = gen.addOutputDirectoryArg(if (split) "canonical-keys-java-split" else "canonical-keys-java");
                gen.addFileArg(b.path(dir ++ "keys.idl"));
                gen.addFileInput(b.path(dir ++ "array_keys.idl"));
                gen.addFileInput(b.path(dir ++ "variable_keys.idl"));
                const compile_java = javaCommand(b, &.{ maybe_javac.?, "-Xlint:unchecked", "-Werror", "-d" }, java_cdr);
                const classes = compile_java.addOutputDirectoryArg(if (split) "canonical-keys-java-split-classes" else "canonical-keys-java-classes");
                if (split) {
                    for ([_][]const u8{ "KeysCdrUtils", "Align", "Nested", "Example", "Bounded16", "Bounded17", "Unbounded", "Seq16", "Seq17", "InnerNoKeys", "UnkeyedNested", "ArrayKey", "SeqAgg", "Choice", "UnionKey", "Wide16", "Wide17", "Base", "Derived", "Sequential", "Hashed", "AutoBase", "AutoDerived", "IdChoice", "UnionDefault", "WideSeq", "SelectedInner", "SelectedOuter", "ArrayEnum", "ArrayEnum8", "ArrayEnum16", "ArrayMask8", "ArrayMask64", "EnumArray16", "EnumArray20", "EnumGrid", "MaskArray16", "MaskArray17", "NarrowArray", "Enum16Array", "Mask64Array", "PrimitiveGrid", "EnumSeq16", "EnumSeq20", "MaskSeq16", "MaskSeq17", "Enum8Seq17", "Enum16Seq16", "Mask64Seq16", "EnumUnboundedSeq", "PrimitiveSeq16", "EnumSeqAlign", "TextArray", "TextGrid", "TextSeq", "PlainItem", "ItemSeq", "ItemArray", "NestedSeq", "ArraySeq", "VariableChoice", "UnionSeq", "StringEnvelope", "WideArray" }) |name| {
                        compile_java.addFileArg(generated.path(b, b.fmt("{s}.java", .{name})));
                    }
                } else compile_java.addFileArg(generated.path(b, "Keys.java"));
                compile_java.addFileArg(b.path(dir ++ "KeysTest.java"));
                const run = javaCommand(b, &.{ maybe_java.?, "-cp" }, java_cdr);
                run.addDirectoryArg(classes);
                run.addArg("KeysTest");
                run.addFileArg(b.path(dir ++ "vectors.txt"));
                for ([_][]const u8{ "wire_ids.txt", "wide_wire.txt", "key_wire.txt", "array_vectors.txt", "variable_vectors.txt" }) |name| run.addFileInput(b.path(b.fmt("{s}{s}", .{ dir, name })));
                run.addArg(if (split) "canonicalkeys." else "Keys$Canonical$");
                key_step.dependOn(&run.step);
            }
        }
    }

    // Generated-code validation: patch errors and allocation-free span/sequence checks.
    {
        const validation_step = b.step("test-cdr-validation", "Check generated patch errors, wide strings and sequence allocation validation");
        test_step.dependOn(validation_step);
        const fixture_dir = "test/integration/cdr_validation/";
        const gen_zig = b.addRunArtifact(exe);
        gen_zig.addArgs(&.{ "-b", "zig", "-o" });
        const zig_dir = gen_zig.addOutputDirectoryArg("cdr-validation-zig");
        gen_zig.addFileArg(b.path(fixture_dir ++ "validation.idl"));
        const fixture = b.createModule(.{
            .root_source_file = zig_dir.path(b, "validation.zig"),
            .target = target,
            .imports = &.{ .{ .name = "zidl_cdr", .module = runtimes.codec }, .{ .name = "zidl_bindings", .module = runtimes.bindings } },
        });
        const validation_tests = b.addTest(.{
            .name = "zidl-cdr-validation",
            .root_module = b.createModule(.{
                .root_source_file = b.path(fixture_dir ++ "test.zig"),
                .target = target,
                .imports = &.{
                    .{ .name = "zidl_cdr", .module = runtimes.codec }, .{ .name = "zidl_bindings", .module = runtimes.bindings },
                    .{ .name = "fixture", .module = fixture },
                },
            }),
        });
        validation_step.dependOn(&b.addRunArtifact(validation_tests).step);
        for ([_][]const u8{ "c", "cpp" }) |lang| {
            const cpp = std.mem.eql(u8, lang, "cpp");
            const gen = b.addRunArtifact(exe);
            gen.addArgs(&.{ "-b", lang, "-o" });
            const dir = gen.addOutputDirectoryArg(b.fmt("cdr-validation-{s}", .{lang}));
            gen.addFileArg(b.path(fixture_dir ++ "validation.idl"));
            gen.addFileArg(b.path(fixture_dir ++ "sequences.idl"));
            const validation_mod = b.createModule(.{
                .root_source_file = null,
                .target = target,
                .optimize = .Debug,
                .link_libc = true,
                .link_libcpp = cpp,
            });
            const flags: []const []const u8 = if (cpp)
                &.{ "-std=c++17", "-Wall", "-Wextra", "-Werror" }
            else
                &.{ "-std=c99", "-Wall", "-Wextra", "-Werror" };
            validation_mod.addCSourceFile(.{ .file = b.path(if (cpp) fixture_dir ++ "test.cpp" else fixture_dir ++ "test.c"), .flags = flags });
            // Redirect only generated calls. Test injectors forward to the actual
            // runtime by default, and return OVERFLOW when failure is requested.
            const generated_flags = b.allocator.alloc([]const u8, flags.len + 2) catch @panic("OOM");
            @memcpy(generated_flags[0..flags.len], flags);
            generated_flags[flags.len] = "-Dzidl_cdr_patch_dheader_checked=validation_patch_dheader";
            generated_flags[flags.len + 1] = "-Dzidl_cdr_patch_emheader_checked=validation_patch_emheader";
            validation_mod.addCSourceFile(.{
                .file = dir.path(b, if (cpp) "validation_cdr.cpp" else "validation_cdr.c"),
                .flags = generated_flags,
            });
            validation_mod.addCSourceFile(.{
                .file = dir.path(b, if (cpp) "sequences_cdr.cpp" else "sequences_cdr.c"),
                .flags = flags,
            });
            linkCdr(validation_mod, if (cpp) allocation_cdr_library else cdr_library);
            validation_mod.addIncludePath(dir);
            validation_mod.addIncludePath(b.path("packages/zidl-cdr/include"));
            const validation_exe = b.addExecutable(.{ .name = b.fmt("zidl-cdr-validation-{s}", .{lang}), .root_module = validation_mod });
            validation_step.dependOn(&b.addRunArtifact(validation_exe).step);
        }
    }

    // C bounded string aliases must remain inline storage in C and C++ consumers.
    {
        const step = b.step("test-c-bounded-typedefs", "Check bounded string typedef storage and decoding");
        test_step.dependOn(step);
        const fixture = "test/integration/c_bounded_typedefs/";
        const gen = b.addRunArtifact(exe);
        gen.addArgs(&.{ "-b", "c", "-o" });
        const dir = gen.addOutputDirectoryArg("c-bounded-typedefs");
        gen.addFileArg(b.path(fixture ++ "types.idl"));
        for ([_]bool{ false, true }) |cpp| {
            const consumer_mod = b.createModule(.{
                .root_source_file = null,
                .target = target,
                .optimize = .Debug,
                .link_libc = true,
                .link_libcpp = cpp,
            });
            consumer_mod.addCSourceFile(.{ .file = b.path(if (cpp) fixture ++ "test.cpp" else fixture ++ "test.c"), .flags = if (cpp)
                &.{ "-std=c++17", "-Wall", "-Wextra", "-Werror", "-fno-exceptions", "-fno-rtti" }
            else
                &.{ "-std=c99", "-Wall", "-Wextra", "-Werror" } });
            consumer_mod.addCSourceFile(.{ .file = dir.path(b, "types_cdr.c"), .flags = &.{ "-std=c99", "-Wall", "-Wextra", "-Werror" } });
            consumer_mod.addIncludePath(dir);
            consumer_mod.addIncludePath(b.path("packages/zidl-cdr/include"));
            linkCdr(consumer_mod, cdr_library);
            const check = b.addExecutable(.{ .name = if (cpp) "bounded-typedefs-cpp" else "bounded-typedefs-c", .root_module = consumer_mod });
            step.dependOn(&b.addRunArtifact(check).step);
        }
    }

    {
        const step = b.step("test-cpp-split-namespaces", "Compile and link C++ module namespaces in split output");
        test_step.dependOn(step);
        for (0..4) |mode| {
            const split = mode >= 2;
            const gen = b.addRunArtifact(exe);
            gen.addArgs(&.{ "-b", "cpp" });
            if (mode % 2 == 1) gen.addArg("--cpp-pmr-containers");
            if (split) gen.addArg("--split-files");
            gen.addArg("-o");
            const dir = gen.addOutputDirectoryArg(b.fmt("cpp-split-namespaces-{d}", .{mode}));
            gen.addFileArg(b.path("test/integration/cpp_split_namespaces/shapes.idl"));
            const m = b.createModule(.{ .root_source_file = null, .target = target, .optimize = .Debug, .link_libc = true, .link_libcpp = true });
            const flags: []const []const u8 = if (split) &.{ "-std=c++17", "-Wall", "-Wextra", "-Werror", "-DSPLIT" } else &.{ "-std=c++17", "-Wall", "-Wextra", "-Werror" };
            m.addCSourceFile(.{ .file = b.path("test/integration/cpp_split_namespaces/test.cpp"), .flags = flags });
            if (split) {
                for ([_][]const u8{ "Top", "First_Nested_Data", "First_Nested_Value", "First_Nested_Packet", "Second_Nested_Data", "Second_Nested_Packet" }) |name| m.addCSourceFile(.{ .file = dir.path(b, b.fmt("{s}_cdr.cpp", .{name})), .flags = flags });
            } else m.addCSourceFile(.{ .file = dir.path(b, "shapes_cdr.cpp"), .flags = flags });
            m.addIncludePath(dir);
            m.addIncludePath(b.path("packages/zidl-cdr/include"));
            linkCdr(m, cdr_library);
            const app = b.addExecutable(.{ .name = b.fmt("cpp-split-namespaces-{d}", .{mode}), .root_module = m });
            step.dependOn(&b.addRunArtifact(app).step);
        }
    }

    {
        const step = b.step("test-java-union-lifecycle", "Check Java union construction and arm selection");
        test_step.dependOn(step);
        const javac = b.findProgram(.{ .names = &.{"javac"} });
        const java = b.findProgram(.{ .names = &.{"java"} });
        if (javac != null and java != null) for (0..6) |mode| {
            const split = mode % 3 != 0;
            const packaged = mode % 3 == 1;
            const codecs = mode < 3;
            const gen = b.addRunArtifact(exe);
            gen.addArgs(&.{ "-b", "java" });
            if (split) gen.addArg("--split-files");
            if (packaged) gen.addArgs(&.{ "--java-package", "lifecycle" });
            if (!codecs) gen.addArg("--no-typesupport");
            gen.addArg("-o");
            const dir = gen.addOutputDirectoryArg(b.fmt("java-union-lifecycle-{d}", .{mode}));
            gen.addFileArg(b.path("test/integration/java_union_lifecycle/lifecycle.idl"));
            const compile = javaCommand(b, &.{ javac.?, "-Xlint:unchecked", "-Werror", "-d" }, java_cdr);
            const classes = compile.addOutputDirectoryArg("classes");
            if (!split) compile.addFileArg(dir.path(b, "Lifecycle.java")) else {
                if (codecs) compile.addFileArg(dir.path(b, "LifecycleCdrUtils.java"));
                for ([_][]const u8{ "Kind", "Leaf", "EnumValue", "DefaultValue", "LeafDefault", "NoDefault", "BooleanFinal", "BooleanAppendable", "BooleanMutable", "WideValue", "ArrayValue", "EnumArray", "Recursive", "GenericArray", "Holder" }) |name| compile.addFileArg(dir.path(b, b.fmt("{s}.java", .{name})));
            }
            compile.addFileArg(b.path("test/integration/java_union_lifecycle/LifecycleTest.java"));
            const run = javaCommand(b, &.{ java.?, "-cp" }, java_cdr);
            run.addDirectoryArg(classes);
            run.addArg("LifecycleTest");
            run.addArg(if (!split) "Lifecycle$Life$" else if (packaged) "lifecycle." else "");
            run.addArg(if (codecs) "true" else "false");
            step.dependOn(&run.step);
        };
    }

    {
        const step = b.step("test-native-boolean-union", "Check warning-clean boolean union dispatch and lifecycle");
        test_step.dependOn(step);
        const dir = "test/integration/native_boolean_union/";
        for (0..6) |mode| {
            const cpp = mode % 3 != 0;
            const pmr = mode % 3 == 2;
            const split = mode >= 3;
            const gen = b.addRunArtifact(exe);
            gen.addArgs(&.{ "-b", if (cpp) "cpp" else "c" });
            if (pmr) gen.addArg("--cpp-pmr-containers");
            if (split) gen.addArg("--split-files");
            gen.addArg("-o");
            const out = gen.addOutputDirectoryArg(b.fmt("native-boolean-union-{d}", .{mode}));
            gen.addFileArg(b.path(dir ++ "bools.idl"));
            const m = b.createModule(.{ .root_source_file = null, .target = target, .optimize = .Debug, .link_libc = true, .link_libcpp = cpp });
            const flags: []const []const u8 = if (cpp) (if (split) &.{ "-std=c++17", "-Wall", "-Wextra", "-Werror", "-DSPLIT" } else &.{ "-std=c++17", "-Wall", "-Wextra", "-Werror" }) else (if (split) &.{ "-std=c99", "-Wall", "-Wextra", "-Werror", "-DSPLIT" } else &.{ "-std=c99", "-Wall", "-Wextra", "-Werror" });
            m.addCSourceFile(.{ .file = b.path(if (cpp) dir ++ "test.cpp" else dir ++ "test.c"), .flags = flags });
            if (split) {
                for ([_][]const u8{ "FinalValue", "AppendValue", "MutableValue", "Exhaustive" }) |name| m.addCSourceFile(.{ .file = out.path(b, b.fmt("BoolSafety_{s}_cdr.{s}", .{ name, if (cpp) "cpp" else "c" })), .flags = flags });
            } else m.addCSourceFile(.{ .file = out.path(b, if (cpp) "bools_cdr.cpp" else "bools_cdr.c"), .flags = flags });
            m.addIncludePath(out);
            m.addIncludePath(b.path("packages/zidl-cdr/include"));
            linkCdr(m, cdr_library);
            const app = b.addExecutable(.{ .name = b.fmt("boolean-union-{d}", .{mode}), .root_module = m });
            step.dependOn(&b.addRunArtifact(app).step);
        }
    }


    {
        const map_step = b.step("test-c-maps", "Check primitive C map storage, wire bytes and allocation failures");
        test_step.dependOn(map_step);
        const gen = b.addRunArtifact(exe);
        gen.addArgs(&.{ "-b", "c", "-o" });
        const generated = gen.addOutputDirectoryArg("c-maps");
        gen.addFileArg(b.path("test/integration/c_maps/maps.idl"));
        const consumer = b.createModule(.{ .root_source_file = null, .target = target, .optimize = .Debug, .link_libc = true });
        const flags = &.{ "-std=c99", "-Wall", "-Wextra", "-Werror" };
        consumer.addCSourceFile(.{ .file = b.path("test/integration/c_maps/test.c"), .flags = flags });
        consumer.addCSourceFile(.{ .file = generated.path(b, "maps_cdr.c"), .flags = flags });
        consumer.addIncludePath(generated);
        consumer.addIncludePath(b.path("packages/zidl-cdr/include"));
        linkCdr(consumer, cdr_library);
        const app = b.addExecutable(.{ .name = "c-maps", .root_module = consumer });
        map_step.dependOn(&b.addRunArtifact(app).step);
        const owning = b.createModule(.{ .root_source_file = null, .target = target, .optimize = .Debug, .link_libc = true });
        owning.addCSourceFile(.{ .file = b.path("test/integration/c_maps/nonprimitive.c"), .flags = flags });
        owning.addCSourceFile(.{ .file = generated.path(b, "maps_cdr.c"), .flags = flags });
        owning.addIncludePath(generated);
        owning.addIncludePath(b.path("packages/zidl-cdr/include"));
        linkCdr(owning, cdr_library);
        const owning_app = b.addExecutable(.{ .name = "c-maps-owning", .root_module = owning });
        map_step.dependOn(&b.addRunArtifact(owning_app).step);
        const cpp_consumer = b.createModule(.{ .root_source_file = null, .target = target, .optimize = .Debug, .link_libc = true, .link_libcpp = true });
        cpp_consumer.addCSourceFile(.{ .file = b.path("test/integration/c_maps/test.cpp"), .flags = &.{ "-std=c++17", "-Wall", "-Wextra", "-Werror", "-fno-exceptions", "-fno-rtti" } });
        cpp_consumer.addCSourceFile(.{ .file = generated.path(b, "maps_cdr.c"), .flags = flags });
        cpp_consumer.addIncludePath(generated);
        cpp_consumer.addIncludePath(b.path("packages/zidl-cdr/include"));
        linkCdr(cpp_consumer, cdr_library);
        const cpp_app = b.addExecutable(.{ .name = "c-maps-cpp", .root_module = cpp_consumer });
        map_step.dependOn(&b.addRunArtifact(cpp_app).step);
    }


    // STL storage failures must stay inside generated C++ codec entry points.
    {
        const allocation_step = b.step("test-cpp-codec-allocation", "Inject C++ codec allocation failures");
        test_step.dependOn(allocation_step);
        for ([_]bool{ false, true }) |pmr| {
            const gen = b.addRunArtifact(exe);
            gen.addArgs(&.{ "-b", "cpp", "-o" });
            const dir = gen.addOutputDirectoryArg(if (pmr) "allocation-pmr" else "allocation-stl");
            if (pmr) gen.addArg("--cpp-pmr-containers");
            gen.addFileArg(b.path("test/integration/cpp_allocation/fixture.idl"));
            const allocation_mod = b.createModule(.{
                .root_source_file = null,
                .target = target,
                .optimize = .Debug,
                .link_libc = true,
                .link_libcpp = true,
            });
            const flags: []const []const u8 = &.{ "-std=c++17", "-Wall", "-Wextra", "-Werror" };
            allocation_mod.addCSourceFile(.{ .file = b.path("test/integration/cpp_allocation/test.cpp"), .flags = flags });
            allocation_mod.addCSourceFile(.{ .file = dir.path(b, "fixture_cdr.cpp"), .flags = flags });
            allocation_mod.addIncludePath(dir);
            allocation_mod.addIncludePath(b.path("packages/zidl-cdr/include"));
            linkCdr(allocation_mod, allocation_cdr_library);
            const allocation_exe = b.addExecutable(.{ .name = if (pmr) "cpp-codec-allocation-pmr" else "cpp-codec-allocation-stl", .root_module = allocation_mod });
            allocation_step.dependOn(&b.addRunArtifact(allocation_exe).step);
            const no_exceptions_mod = b.createModule(.{
                .root_source_file = null,
                .target = target,
                .optimize = .Debug,
                .link_libc = true,
                .link_libcpp = true,
            });
            const no_exceptions_flags: []const []const u8 = &.{ "-std=c++17", "-Wall", "-Wextra", "-Werror", "-fno-exceptions", "-fno-rtti" };
            no_exceptions_mod.addCSourceFile(.{ .file = b.path("test/integration/cpp_allocation/no_exceptions.cpp"), .flags = no_exceptions_flags });
            no_exceptions_mod.addCSourceFile(.{ .file = dir.path(b, "fixture_cdr.cpp"), .flags = no_exceptions_flags });
            no_exceptions_mod.addIncludePath(dir);
            no_exceptions_mod.addIncludePath(b.path("packages/zidl-cdr/include"));
            linkCdr(no_exceptions_mod, cdr_library);
            const no_exceptions_exe = b.addExecutable(.{ .name = if (pmr) "cpp-codec-no-exceptions-pmr" else "cpp-codec-no-exceptions-stl", .root_module = no_exceptions_mod });
            allocation_step.dependOn(&b.addRunArtifact(no_exceptions_exe).step);
        }
    }

    // Inherited wire frames and recursive key-value projection.
    {
        const projection_step = b.step("test-key-projection", "Check inherited frames and recursive key-only values");
        test_step.dependOn(projection_step);
        const dir = "test/integration/key_projection/";
        const gen_zig = b.addRunArtifact(exe);
        gen_zig.addArgs(&.{ "-b", "zig", "-o" });
        const zig_dir = gen_zig.addOutputDirectoryArg("key-projection-zig");
        gen_zig.addFileArg(b.path(dir ++ "shapes.idl"));
        const fixture = b.createModule(.{
            .root_source_file = zig_dir.path(b, "shapes.zig"),
            .target = target,
            .imports = &.{ .{ .name = "zidl_cdr", .module = runtimes.codec }, .{ .name = "zidl_bindings", .module = runtimes.bindings } },
        });
        const tests = b.addTest(.{ .name = "zidl-key-projection", .root_module = b.createModule(.{
            .root_source_file = b.path(dir ++ "test.zig"),
            .target = target,
            .sanitize_thread = sanitize_thread,
            .imports = &.{ .{ .name = "zidl_cdr", .module = runtimes.codec }, .{ .name = "zidl_bindings", .module = runtimes.bindings }, .{ .name = "fixture", .module = fixture } },
        }) });
        projection_step.dependOn(&b.addRunArtifact(tests).step);
        for ([_][]const u8{ "c", "cpp" }) |lang| {
            const cpp = std.mem.eql(u8, lang, "cpp");
            const gen = b.addRunArtifact(exe);
            gen.addArgs(&.{ "-b", lang, "-o" });
            const generated = gen.addOutputDirectoryArg(b.fmt("key-projection-{s}", .{lang}));
            gen.addFileArg(b.path(dir ++ "shapes.idl"));
            const m = b.createModule(.{ .root_source_file = null, .target = target, .optimize = .Debug, .sanitize_thread = sanitize_thread, .link_libc = true, .link_libcpp = cpp });
            const flags: []const []const u8 = if (cpp) &.{ "-std=c++17", "-Wall", "-Wextra", "-Werror" } else &.{ "-std=c99", "-Wall", "-Werror" };
            m.addCSourceFile(.{ .file = b.path(if (cpp) dir ++ "test.cpp" else dir ++ "test.c"), .flags = flags });
            m.addCSourceFile(.{ .file = generated.path(b, if (cpp) "shapes_cdr.cpp" else "shapes_cdr.c"), .flags = flags });
            linkCdr(m, cdr_library);
            m.addIncludePath(generated);
            m.addIncludePath(b.path("packages/zidl-cdr/include"));
            const app = b.addExecutable(.{ .name = b.fmt("zidl-key-projection-{s}", .{lang}), .root_module = m });
            const run = b.addRunArtifact(app);
            run.addFileArg(b.path(dir ++ "vectors.txt"));
            projection_step.dependOn(&run.step);
        }
        const maybe_javac = b.findProgram(.{ .names = &.{"javac"} });
        const maybe_java = b.findProgram(.{ .names = &.{"java"} });
        if (maybe_javac != null and maybe_java != null) {
            for ([_]bool{ false, true }) |split| {
                const gen = b.addRunArtifact(exe);
                gen.addArgs(&.{ "-b", "java" });
                if (split) gen.addArgs(&.{ "--split-files", "--java-package", "keyprojection" });
                gen.addArg("-o");
                const generated = gen.addOutputDirectoryArg(if (split) "key-projection-java-split" else "key-projection-java");
                gen.addFileArg(b.path(dir ++ "shapes.idl"));
                const compile_java = javaCommand(b, &.{ maybe_javac.?, "-Xlint:unchecked", "-Werror", "-d" }, java_cdr);
                const classes = compile_java.addOutputDirectoryArg(if (split) "key-projection-java-split-classes" else "key-projection-java-classes");
                if (split) {
                    for ([_][]const u8{ "ShapesCdrUtils", "FBase", "FMid", "FDerived", "ABase", "ADerived", "MBase", "MDerived", "Bridge", "RootBridge", "PlainBase", "InheritedBridge", "RootInherited", "MutBridge", "RootMut", "AppBridge", "RootArray", "RootSeq" }) |name| {
                        compile_java.addFileArg(generated.path(b, b.fmt("{s}.java", .{name})));
                    }
                } else compile_java.addFileArg(generated.path(b, "Shapes.java"));
                compile_java.addFileArg(b.path(dir ++ "ProjectionTest.java"));
                const run = javaCommand(b, &.{ maybe_java.?, "-cp" }, java_cdr);
                run.addDirectoryArg(classes);
                run.addArg("ProjectionTest");
                run.addFileArg(b.path(dir ++ "vectors.txt"));
                run.addArg(if (split) "keyprojection." else "Shapes$Projection$");
                projection_step.dependOn(&run.step);
            }
        }
    }

    // Optional member framing and scoped alignment.
    {
        const projection_step = b.step("test-optional-wire", "Check optional member framing and scoped alignment");
        test_step.dependOn(projection_step);
        const dir = "test/integration/optional_wire/";
        const gen_zig = b.addRunArtifact(exe);
        gen_zig.addArgs(&.{ "-b", "zig", "--generate-zzdds-wrappers", "-o" });
        const zig_dir = gen_zig.addOutputDirectoryArg("optional-wire-zig");
        gen_zig.addFileArg(b.path(dir ++ "shapes.idl"));
        const middleware = b.createModule(.{ .root_source_file = b.path("test/integration/zig_wrapper_contract/fake_middleware.zig"), .target = target });
        const fixture = b.createModule(.{
            .root_source_file = zig_dir.path(b, "shapes.zig"),
            .target = target,
            .imports = &.{ .{ .name = "zidl_cdr", .module = runtimes.codec }, .{ .name = "zidl_bindings", .module = runtimes.bindings }, .{ .name = "zzdds", .module = middleware } },
        });
        const tests = b.addTest(.{ .name = "zidl-optional-wire", .root_module = b.createModule(.{
            .root_source_file = b.path(dir ++ "test.zig"),
            .target = target,
            .sanitize_thread = sanitize_thread,
            .imports = &.{ .{ .name = "zidl_cdr", .module = runtimes.codec }, .{ .name = "zidl_bindings", .module = runtimes.bindings }, .{ .name = "fixture", .module = fixture } },
        }) });
        projection_step.dependOn(&b.addRunArtifact(tests).step);
        for ([_][]const u8{ "c", "cpp" }) |lang| {
            const cpp = std.mem.eql(u8, lang, "cpp");
            const gen = b.addRunArtifact(exe);
            gen.addArgs(&.{ "-b", lang, "-o" });
            const generated = gen.addOutputDirectoryArg(b.fmt("optional-wire-{s}", .{lang}));
            gen.addFileArg(b.path(dir ++ "shapes.idl"));
            const m = b.createModule(.{ .root_source_file = null, .target = target, .optimize = .Debug, .sanitize_thread = sanitize_thread, .link_libc = true, .link_libcpp = cpp });
            const flags: []const []const u8 = if (cpp) &.{ "-std=c++17", "-Wall", "-Wextra", "-Werror" } else &.{ "-std=c99", "-Wall", "-Werror" };
            m.addCSourceFile(.{ .file = b.path(if (cpp) dir ++ "test.cpp" else dir ++ "test.c"), .flags = flags });
            m.addCSourceFile(.{ .file = generated.path(b, if (cpp) "shapes_cdr.cpp" else "shapes_cdr.c"), .flags = flags });
            linkCdr(m, cdr_library);
            m.addIncludePath(generated);
            m.addIncludePath(b.path("packages/zidl-cdr/include"));
            const app = b.addExecutable(.{ .name = b.fmt("zidl-optional-wire-{s}", .{lang}), .root_module = m });
            const run = b.addRunArtifact(app);
            run.addFileArg(b.path(dir ++ "vectors.txt"));
            projection_step.dependOn(&run.step);
        }
        const maybe_javac = b.findProgram(.{ .names = &.{"javac"} });
        const maybe_java = b.findProgram(.{ .names = &.{"java"} });
        if (maybe_javac != null and maybe_java != null) {
            for ([_]bool{ false, true }) |split| {
                const gen = b.addRunArtifact(exe);
                gen.addArgs(&.{ "-b", "java", "--generate-zzdds-wrappers" });
                if (split) gen.addArgs(&.{ "--split-files", "--java-package", "optionalwire" });
                gen.addArg("-o");
                const generated = gen.addOutputDirectoryArg(if (split) "optional-wire-java-split" else "optional-wire-java");
                gen.addFileArg(b.path(dir ++ "shapes.idl"));
                const compile_java = javaCommand(b, &.{ maybe_javac.?, "-Xlint:unchecked", "-Werror", "-d" }, java_cdr);
                const classes = compile_java.addOutputDirectoryArg(if (split) "optional-wire-java-split-classes" else "optional-wire-java-classes");
                if (split) {
                    for ([_][]const u8{ "ShapesCdrUtils", "Pair", "Values", "Inner", "Base", "Derived" }) |name| {
                        compile_java.addFileArg(generated.path(b, b.fmt("{s}.java", .{name})));
                    }
                } else compile_java.addFileArg(generated.path(b, "Shapes.java"));
                compile_java.addFileArg(b.path(dir ++ "OptionalTest.java"));
                const run = javaCommand(b, &.{ maybe_java.?, "-cp" }, java_cdr);
                run.addDirectoryArg(classes);
                run.addArg("OptionalTest");
                run.addFileArg(b.path(dir ++ "vectors.txt"));
                run.addArg(if (split) "optionalwire." else "Shapes$OptionalWire$");
                projection_step.dependOn(&run.step);
            }
        }
    }

    {
        const array_step = b.step("test-cpp-optional-arrays", "Compile and exercise C++ optional arrays");
        test_step.dependOn(array_step);
        for ([_]bool{ false, true }) |pmr| {
            const gen = b.addRunArtifact(exe);
            gen.addArgs(&.{ "-b", "cpp" });
            if (pmr) gen.addArg("--cpp-pmr-containers");
            gen.addArg("-o");
            const generated = gen.addOutputDirectoryArg(if (pmr) "optional-arrays-pmr" else "optional-arrays-stl");
            gen.addFileArg(b.path("test/integration/cpp_optional_arrays/shapes.idl"));
            const consumer = b.createModule(.{ .root_source_file = null, .target = target, .optimize = .Debug, .link_libc = true, .link_libcpp = true });
            const flags = &.{ "-std=c++17", "-Wall", "-Wextra", "-Werror" };
            consumer.addCSourceFile(.{ .file = b.path("test/integration/cpp_optional_arrays/test.cpp"), .flags = flags });
            consumer.addCSourceFile(.{ .file = generated.path(b, "shapes_cdr.cpp"), .flags = flags });
            consumer.addIncludePath(generated);
            consumer.addIncludePath(b.path("packages/zidl-cdr/include"));
            linkCdr(consumer, cdr_library);
            const app = b.addExecutable(.{ .name = if (pmr) "optional-arrays-pmr" else "optional-arrays-stl", .root_module = consumer });
            array_step.dependOn(&b.addRunArtifact(app).step);
        }
    }

    {
        const admission_step = b.step("test-native-union-admission", "Check native mutable union member admission and ownership");
        test_step.dependOn(admission_step);
        const gen = b.addRunArtifact(exe);
        gen.addArgs(&.{ "-b", "c", "-o" });
        const generated = gen.addOutputDirectoryArg("union-admission-c");
        gen.addFileArg(b.path("test/integration/native_union_admission/shapes.idl"));
        const consumer = b.createModule(.{ .root_source_file = null, .target = target, .optimize = .Debug, .link_libc = true });
        const flags = &.{ "-std=c99", "-Wall", "-Wextra", "-Werror" };
        consumer.addCSourceFile(.{ .file = b.path("test/integration/native_union_admission/test.c"), .flags = flags });
        consumer.addCSourceFile(.{ .file = generated.path(b, "shapes_cdr.c"), .flags = flags });
        consumer.addIncludePath(generated);
        consumer.addIncludePath(b.path("packages/zidl-cdr/include"));
        linkCdr(consumer, cdr_library);
        const app = b.addExecutable(.{ .name = "union-admission-c", .root_module = consumer });
        admission_step.dependOn(&b.addRunArtifact(app).step);
        for ([_]bool{ false, true }) |pmr| {
            const cpp_gen = b.addRunArtifact(exe);
            cpp_gen.addArgs(&.{ "-b", "cpp" });
            if (pmr) cpp_gen.addArg("--cpp-pmr-containers");
            cpp_gen.addArg("-o");
            const dir = cpp_gen.addOutputDirectoryArg(if (pmr) "union-admission-pmr" else "union-admission-stl");
            cpp_gen.addFileArg(b.path("test/integration/native_union_admission/shapes.idl"));
            const cpp_consumer = b.createModule(.{ .root_source_file = null, .target = target, .optimize = .Debug, .link_libc = true, .link_libcpp = true });
            const cpp_flags = &.{ "-std=c++17", "-Wall", "-Wextra", "-Werror" };
            cpp_consumer.addCSourceFile(.{ .file = b.path("test/integration/native_union_admission/test.cpp"), .flags = cpp_flags });
            cpp_consumer.addCSourceFile(.{ .file = dir.path(b, "shapes_cdr.cpp"), .flags = cpp_flags });
            cpp_consumer.addIncludePath(dir);
            cpp_consumer.addIncludePath(b.path("packages/zidl-cdr/include"));
            linkCdr(cpp_consumer, allocation_cdr_library);
            const cpp_app = b.addExecutable(.{ .name = if (pmr) "union-admission-pmr" else "union-admission-stl", .root_module = cpp_consumer });
            admission_step.dependOn(&b.addRunArtifact(cpp_app).step);
        }
    }

    {
        const step = b.step("test-java-union-admission", "Check Java mutable union admission in all output modes");
        test_step.dependOn(step);
        const javac = b.findProgram(.{ .names = &.{"javac"} });
        const java = b.findProgram(.{ .names = &.{"java"} });
        if (javac != null and java != null) for (0..3) |mode| {
            const gen = b.addRunArtifact(exe);
            gen.addArgs(&.{ "-b", "java" });
            if (mode != 0) gen.addArg("--split-files");
            if (mode == 1) gen.addArgs(&.{ "--java-package", "admission" });
            gen.addArg("-o");
            const dir = gen.addOutputDirectoryArg(b.fmt("union-admission-java-{d}", .{mode}));
            gen.addFileArg(b.path("test/integration/native_union_admission/java_shapes.idl"));
            const compile = javaCommand(b, &.{ javac.?, "-Xlint:unchecked", "-Werror", "-d" }, java_cdr);
            const classes = compile.addOutputDirectoryArg("classes");
            if (mode == 0) compile.addFileArg(dir.path(b, "Java_shapes.java")) else {
                compile.addFileArg(dir.path(b, "Java_shapesCdrUtils.java"));
                for ([_][]const u8{ "Value", "DefaultFirst", "Tag", "EnumValue", "NoDefault", "BooleanValue", "LongValue", "SmallTag", "SmallValue" }) |name| compile.addFileArg(dir.path(b, b.fmt("{s}.java", .{name})));
            }
            compile.addFileArg(b.path("test/integration/native_union_admission/AdmissionTest.java"));
            const run = javaCommand(b, &.{ java.?, "-cp" }, java_cdr);
            run.addDirectoryArg(classes);
            run.addArg("AdmissionTest");
            run.addArg(if (mode == 0) "Java_shapes$Admission$" else if (mode == 1) "admission." else "");
            step.dependOn(&run.step);
        };
    }

    // ── XCDR known-answer checks ──────────────────────────────────────────────
    // test/integration/xcdr_known_answer/ka.idl covers every collection kind
    // (primitive / non-primitive / nested / array-typedef elements, multi-
    // dimensional arrays) in final, appendable and mutable holders. Each
    // backend encodes the samples to the exact reference bytes in vectors.txt
    // (from an independent XTypes implementation), decodes the reference
    // bytes, and (Zig) reproduces the reference minimal TypeObject hashes.
    {
        const ka_step = b.step("test-cdr-known-answer", "Check generated codecs against independent XCDR framing/collection vectors");
        const ka_idl = b.path("test/integration/xcdr_known_answer/ka.idl");

        const gen_zig = b.addRunArtifact(exe);
        gen_zig.addArgs(&.{ "-b", "zig", "-o" });
        const zig_dir = gen_zig.addOutputDirectoryArg("xcdr-known-answer-zig");
        gen_zig.addFileArg(ka_idl);
        const zig_fixture_mod = b.createModule(.{
            .root_source_file = zig_dir.path(b, "ka.zig"),
            .target = target,
            .sanitize_thread = sanitize_thread,
            .imports = &.{
                .{ .name = "zidl_cdr", .module = runtimes.codec }, .{ .name = "zidl_bindings", .module = runtimes.bindings },
            },
        });
        const zig_tests = b.addTest(.{
            .name = "zidl-xcdr-known-answer",
            .root_module = b.createModule(.{
                .root_source_file = b.path("test/integration/xcdr_known_answer/test.zig"),
                .target = target,
                .sanitize_thread = sanitize_thread,
                .imports = &.{
                    .{ .name = "zidl_cdr", .module = runtimes.codec }, .{ .name = "zidl_bindings", .module = runtimes.bindings },
                    .{ .name = "fixture", .module = zig_fixture_mod },
                },
            }),
        });
        const run_zig = b.addRunArtifact(zig_tests);
        test_step.dependOn(&run_zig.step);
        ka_step.dependOn(&run_zig.step);

        const vectors = b.path("test/integration/xcdr_known_answer/vectors.txt");

        const gen_c = b.addRunArtifact(exe);
        gen_c.addArgs(&.{ "-b", "c", "-o" });
        const c_dir = gen_c.addOutputDirectoryArg("xcdr-known-answer-c");
        gen_c.addFileArg(ka_idl);
        const c_mod = b.createModule(.{
            .root_source_file = null,
            .target = target,
            .optimize = .Debug,
            .sanitize_thread = sanitize_thread,
            .link_libc = true,
        });
        c_mod.addCSourceFile(.{
            .file = b.path("test/integration/xcdr_known_answer/test.c"),
            .flags = &.{ "-std=c99", "-Wall", "-Werror" },
        });
        c_mod.addCSourceFile(.{
            .file = c_dir.path(b, "ka_cdr.c"),
            .flags = &.{ "-std=c99", "-Wall", "-Werror" },
        });
        linkCdr(c_mod, cdr_library);
        c_mod.addIncludePath(c_dir);
        c_mod.addIncludePath(b.path("packages/zidl-cdr/include"));
        const c_test = b.addExecutable(.{ .name = "zidl-xcdr-known-answer-c", .root_module = c_mod });
        const run_c = b.addRunArtifact(c_test);
        run_c.addFileArg(vectors);
        if (!verbose_tests) run_c.expectStdOutMatch("xcdr_known_answer C: all checks passed");
        test_step.dependOn(&run_c.step);
        ka_step.dependOn(&run_c.step);

        const gen_cpp = b.addRunArtifact(exe);
        gen_cpp.addArgs(&.{ "-b", "cpp", "-o" });
        const cpp_dir = gen_cpp.addOutputDirectoryArg("xcdr-known-answer-cpp");
        gen_cpp.addFileArg(ka_idl);
        const cpp_mod = b.createModule(.{
            .root_source_file = null,
            .target = target,
            .optimize = .Debug,
            .sanitize_thread = sanitize_thread,
            .link_libc = true,
            .link_libcpp = true,
        });
        cpp_mod.addCSourceFile(.{
            .file = b.path("test/integration/xcdr_known_answer/test.cpp"),
            .flags = &.{ "-std=c++17", "-Wall", "-Werror" },
        });
        cpp_mod.addCSourceFile(.{
            .file = cpp_dir.path(b, "ka_cdr.cpp"),
            .flags = &.{ "-std=c++17", "-Wall", "-Werror" },
        });
        linkCdr(cpp_mod, cdr_library);
        cpp_mod.addIncludePath(cpp_dir);
        cpp_mod.addIncludePath(b.path("packages/zidl-cdr/include"));
        const cpp_test = b.addExecutable(.{ .name = "zidl-xcdr-known-answer-cpp", .root_module = cpp_mod });
        const run_cpp = b.addRunArtifact(cpp_test);
        run_cpp.addFileArg(vectors);
        if (!verbose_tests) run_cpp.expectStdOutMatch("xcdr_known_answer C++: all checks passed");
        test_step.dependOn(&run_cpp.step);
        ka_step.dependOn(&run_cpp.step);

        // Java: only when a JDK is on PATH.
        const maybe_javac = b.findProgram(.{ .names = &.{"javac"} });
        const maybe_java = b.findProgram(.{ .names = &.{"java"} });
        if (maybe_javac != null and maybe_java != null) {
            const gen_java = b.addRunArtifact(exe);
            gen_java.addArgs(&.{ "-b", "java", "-o" });
            const java_dir = gen_java.addOutputDirectoryArg("xcdr-known-answer-java");
            gen_java.addFileArg(ka_idl);
            const compile_java = javaCommand(b, &.{ maybe_javac.?, "-Xlint:unchecked", "-Werror", "-d" }, java_cdr);
            const java_classes = compile_java.addOutputDirectoryArg("xcdr-known-answer-java-classes");
            compile_java.addFileArg(java_dir.path(b, "Ka.java"));
            compile_java.addFileArg(b.path("test/integration/xcdr_known_answer/KaTest.java"));
            const run_java = javaCommand(b, &.{ maybe_java.?, "-cp" }, java_cdr);
            run_java.addDirectoryArg(java_classes);
            run_java.addArg("KaTest");
            run_java.addFileArg(vectors);
            if (!verbose_tests) run_java.expectStdOutMatch("xcdr_known_answer Java: all checks passed");
            test_step.dependOn(&run_java.step);
            ka_step.dependOn(&run_java.step);
        }
    }

    // ── check_goldens tool ────────────────────────────────────────────────────
    // Bidirectional directory comparison; replaces `diff -rq` and works on all
    // platforms.  Always compiled for the host so it can run during the build.
    const check_goldens_exe = b.addExecutable(.{
        .name = "check_goldens",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/check_goldens.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });

    // ── golden output management ──────────────────────────────────────────────
    const golden_idl = "test/golden/types.idl";
    const golden_root = "test/golden";
    const check_root = "build-tmp/golden-check";

    const backends = [_][]const u8{ "zig", "c", "cpp", "java" };

    // regen-goldens: regenerate test/golden/<lang>/ and test/golden/<lang>-split/ in-place
    const regen_step = b.step("regen-goldens", "Regenerate test/golden/ from types.idl");
    for (backends) |lang| {
        const out_dir = b.fmt("{s}/{s}", .{ golden_root, lang });
        const regen_run = b.addRunArtifact(exe);
        regen_run.addArgs(&.{ "-b", lang, "--generate-interfaces", "-o", out_dir, golden_idl });
        regen_step.dependOn(&regen_run.step);

        const out_dir_split = b.fmt("{s}/{s}-split", .{ golden_root, lang });
        const regen_run_split = b.addRunArtifact(exe);
        regen_run_split.addArgs(&.{ "-b", lang, "--generate-interfaces", "--split-files", "-o", out_dir_split, golden_idl });
        regen_step.dependOn(&regen_run_split.step);
    }

    // check-goldens: regenerate to build-tmp/golden-check/ and compare against
    // test/golden/ using the check_goldens tool (bidirectional: missing files
    // and extra generated files both fail).  Integrated into `zig build test`.
    const check_goldens_step = b.step("check-goldens", "Verify golden files match current zidl output");
    for (backends) |lang| {
        // Single-file mode
        const gen_dir = b.fmt("{s}/{s}", .{ check_root, lang });
        const gold_dir = b.fmt("{s}/{s}", .{ golden_root, lang });
        const gen_run = b.addRunArtifact(exe);
        gen_run.addArgs(&.{ "-b", lang, "--generate-interfaces", "-o", gen_dir, golden_idl });
        const cmp = b.addRunArtifact(check_goldens_exe);
        cmp.addArg(gold_dir);
        cmp.addArg(gen_dir);
        cmp.step.dependOn(&gen_run.step);
        check_goldens_step.dependOn(&cmp.step);

        // Split-file mode
        const gen_dir_split = b.fmt("{s}/{s}-split", .{ check_root, lang });
        const gold_dir_split = b.fmt("{s}/{s}-split", .{ golden_root, lang });
        const gen_run_split = b.addRunArtifact(exe);
        gen_run_split.addArgs(&.{ "-b", lang, "--generate-interfaces", "--split-files", "-o", gen_dir_split, golden_idl });
        const cmp_split = b.addRunArtifact(check_goldens_exe);
        cmp_split.addArg(gold_dir_split);
        cmp_split.addArg(gen_dir_split);
        cmp_split.step.dependOn(&gen_run_split.step);
        check_goldens_step.dependOn(&cmp_split.step);
    }
    test_step.dependOn(check_goldens_step);

    // ── integration-test ──────────────────────────────────────────────────────
    const integ_step = b.step("integration-test", "Compile and run C/C++/Java integration tests");

    // C integration test — uses Zig's bundled clang; no external gcc needed
    {
        const c_mod = b.createModule(.{
            .root_source_file = null,
            .target = target,
            .optimize = .Debug,
            .link_libc = true,
        });
        c_mod.addCSourceFiles(.{
            .files = &.{
                "test/integration/c/test.c",
                "test/golden/c/types_cdr.c",
            },
            .flags = &.{ "-std=c99", "-Wall", "-Werror" },
        });
        linkCdr(c_mod, cdr_library);
        c_mod.addIncludePath(b.path("packages/zidl-cdr/include"));
        c_mod.addIncludePath(b.path("test/golden/c"));
        const c_exe = b.addExecutable(.{ .name = "test_c", .root_module = c_mod });
        integ_step.dependOn(&b.addRunArtifact(c_exe).step);
    }

    // C++ integration test — uses Zig's bundled clang++; no external g++ needed
    {
        const cpp_mod = b.createModule(.{
            .root_source_file = null,
            .target = target,
            .optimize = .Debug,
            .link_libc = true,
            .link_libcpp = true,
        });
        cpp_mod.addCSourceFiles(.{
            .files = &.{
                "test/integration/cpp/test.cpp",
                "test/golden/cpp/types_cdr.cpp",
            },
            .flags = &.{ "-std=c++17", "-Wall" },
        });
        linkCdr(cpp_mod, cdr_library);
        cpp_mod.addIncludePath(b.path("packages/zidl-cdr/include"));
        cpp_mod.addIncludePath(b.path("test/golden/cpp"));
        const cpp_exe = b.addExecutable(.{ .name = "test_cpp", .root_module = cpp_mod });
        integ_step.dependOn(&b.addRunArtifact(cpp_exe).step);
    }

    // C++ integration test — zidl_allocator_pmr.hpp (ZidlAllocator <-> std::pmr bridge)
    {
        const alloc_pmr_mod = b.createModule(.{
            .root_source_file = null,
            .target = target,
            .optimize = .Debug,
            .link_libc = true,
            .link_libcpp = true,
        });
        alloc_pmr_mod.addCSourceFiles(.{
            .files = &.{"test/integration/cpp/test_allocator_pmr.cpp"},
            .flags = &.{ "-std=c++17", "-Wall", "-Wextra" },
        });
        alloc_pmr_mod.addIncludePath(b.path("packages/zidl-cdr/include"));
        const alloc_pmr_exe = b.addExecutable(.{ .name = "test_allocator_pmr", .root_module = alloc_pmr_mod });
        integ_step.dependOn(&b.addRunArtifact(alloc_pmr_exe).step);
    }

    // Same test again, but compiled with -fno-rtti -fno-exceptions:
    // zidl_allocator_pmr.hpp is meant for embedded/RT builds that routinely
    // disable both, and that claim needs an actual CI-checked compile, not
    // just a one-off manual check — a prior dynamic_cast in do_is_equal broke
    // this silently.
    {
        const no_rtti_mod = b.createModule(.{
            .root_source_file = null,
            .target = target,
            .optimize = .Debug,
            .link_libc = true,
            .link_libcpp = true,
        });
        no_rtti_mod.addCSourceFiles(.{
            .files = &.{"test/integration/cpp/test_allocator_pmr.cpp"},
            .flags = &.{ "-std=c++17", "-Wall", "-Wextra", "-fno-rtti", "-fno-exceptions" },
        });
        no_rtti_mod.addIncludePath(b.path("packages/zidl-cdr/include"));
        const no_rtti_exe = b.addExecutable(.{ .name = "test_allocator_pmr_no_rtti", .root_module = no_rtti_mod });
        integ_step.dependOn(&b.addRunArtifact(no_rtti_exe).step);
    }

    // zidl_allocator_pmr.hpp's opt-in ZIDL_ALLOCATOR_PMR_STATIC_POOL_SIZE
    // mode (bare-metal / no-heap targets): CI-checks that setCppAllocator's
    // own bookkeeping never calls global operator new when this macro is
    // defined, by overriding operator new/delete to abort.
    {
        const static_pool_mod = b.createModule(.{
            .root_source_file = null,
            .target = target,
            .optimize = .Debug,
            .link_libc = true,
            .link_libcpp = true,
        });
        static_pool_mod.addCSourceFiles(.{
            .files = &.{"test/integration/cpp/test_allocator_pmr_static_pool.cpp"},
            .flags = &.{ "-std=c++17", "-Wall", "-Wextra" },
        });
        static_pool_mod.addIncludePath(b.path("packages/zidl-cdr/include"));
        const static_pool_exe = b.addExecutable(.{ .name = "test_allocator_pmr_static_pool", .root_module = static_pool_mod });
        integ_step.dependOn(&b.addRunArtifact(static_pool_exe).step);
    }

    // C++ integration test — --cpp-pmr-containers backend flag: proves
    // generated struct fields actually route through zidl::setCppAllocator.
    // Generates its own fresh (non-golden) types.hpp from the shared
    // test/golden/types.idl with the flag on, since the checked-in cpp
    // goldens are generated without it.
    {
        const gen_pmr_cpp = b.addRunArtifact(exe);
        gen_pmr_cpp.addArgs(&.{ "-b", "cpp", "--cpp-pmr-containers", "-o" });
        const gen_pmr_cpp_dir = gen_pmr_cpp.addOutputDirectoryArg("integ-cpp-pmr-containers");
        gen_pmr_cpp.addFileArg(b.path("test/golden/types.idl"));

        const pmr_containers_mod = b.createModule(.{
            .root_source_file = null,
            .target = target,
            .optimize = .Debug,
            .link_libc = true,
            .link_libcpp = true,
        });
        pmr_containers_mod.addCSourceFiles(.{
            .files = &.{"test/integration/cpp/test_pmr_containers.cpp"},
            .flags = &.{ "-std=c++17", "-Wall", "-Wextra" },
        });
        pmr_containers_mod.addIncludePath(gen_pmr_cpp_dir);
        pmr_containers_mod.addIncludePath(b.path("packages/zidl-cdr/include"));
        const pmr_containers_exe = b.addExecutable(.{ .name = "test_pmr_containers", .root_module = pmr_containers_mod });
        integ_step.dependOn(&b.addRunArtifact(pmr_containers_exe).step);
    }

    // Cross-file widening: an operation in plugin.idl declares an imported
    // core::TopicDescription parameter; the generated C++ and Java bindings
    // must convert imported subtypes (core::Topic, core::ContentFilteredTopic)
    // to that view. native.c tags every view and rejects an unconverted
    // handle. The C++ half runs here; the Java half below (needs a JDK).
    const xfw_dir = "test/integration/cross_file_widening";
    const gen_xfw_c = b.addRunArtifact(exe);
    gen_xfw_c.addArgs(&.{ "-b", "c", "--generate-interfaces", "-o" });
    const xfw_c_dir = gen_xfw_c.addOutputDirectoryArg("xfw-c");
    gen_xfw_c.addFileArg(b.path(xfw_dir ++ "/core.idl"));
    const gen_xfw_c_ext = b.addRunArtifact(exe);
    gen_xfw_c_ext.addArgs(&.{ "-b", "c", "--generate-interfaces", "-o" });
    const xfw_c_ext_dir = gen_xfw_c_ext.addOutputDirectoryArg("xfw-c-ext");
    gen_xfw_c_ext.addFileArg(b.path(xfw_dir ++ "/plugin.idl"));
    {
        const gen_cpp_base = b.addRunArtifact(exe);
        gen_cpp_base.addArgs(&.{ "-b", "cpp", "--generate-interfaces", "--cpp-generate-impl", "-o" });
        const cpp_base_dir = gen_cpp_base.addOutputDirectoryArg("xfw-cpp-base");
        gen_cpp_base.addFileArg(b.path(xfw_dir ++ "/core.idl"));
        const gen_cpp_ext = b.addRunArtifact(exe);
        gen_cpp_ext.addArgs(&.{ "-b", "cpp", "--generate-interfaces", "--cpp-generate-impl", "-o" });
        const cpp_ext_dir = gen_cpp_ext.addOutputDirectoryArg("xfw-cpp-ext");
        gen_cpp_ext.addFileArg(b.path(xfw_dir ++ "/plugin.idl"));
        const xfw_cpp_mod = b.createModule(.{
            .root_source_file = null,
            .target = target,
            .optimize = .Debug,
            .link_libc = true,
            .link_libcpp = true,
        });
        const cpp_flags = &.{ "-std=c++17", "-Wall", "-Werror" };
        xfw_cpp_mod.addCSourceFile(.{ .file = b.path(xfw_dir ++ "/test.cpp"), .flags = cpp_flags });
        xfw_cpp_mod.addCSourceFile(.{ .file = cpp_base_dir.path(b, "core_impl.cpp"), .flags = cpp_flags });
        xfw_cpp_mod.addCSourceFile(.{ .file = cpp_ext_dir.path(b, "plugin_impl.cpp"), .flags = cpp_flags });
        xfw_cpp_mod.addCSourceFile(.{ .file = b.path(xfw_dir ++ "/native.c"), .flags = &.{ "-std=c99", "-Wall", "-Werror" } });
        xfw_cpp_mod.addIncludePath(b.path(xfw_dir));
        xfw_cpp_mod.addIncludePath(cpp_base_dir);
        xfw_cpp_mod.addIncludePath(cpp_ext_dir);
        xfw_cpp_mod.addIncludePath(xfw_c_dir);
        xfw_cpp_mod.addIncludePath(xfw_c_ext_dir);
        xfw_cpp_mod.addIncludePath(b.path("packages/zidl-cdr/include"));
        const xfw_cpp = b.addExecutable(.{ .name = "zidl-cross-file-widening-cpp", .root_module = xfw_cpp_mod });
        integ_step.dependOn(&b.addRunArtifact(xfw_cpp).step);
    }

    // Java integration test — requires javac/java on PATH
    {
        const maybe_javac = b.findProgram(.{ .names = &.{"javac"} });
        const maybe_java = b.findProgram(.{ .names = &.{"java"} });
        if (maybe_javac != null and maybe_java != null) {
            const javac = maybe_javac.?;
            const java = maybe_java.?;
            const java_out = "build-tmp/integ-java";
            const compile_java = javaCommand(b, &.{
                javac,
                "-d",
                java_out,
                "test/golden/java/Types.java",
                "test/integration/java/Test.java",
            }, java_cdr);
            const run_java = javaCommand(b, &.{ java, "-cp", java_out, "Test" }, java_cdr);
            run_java.step.dependOn(&compile_java.step);
            integ_step.dependOn(&run_java.step);

            // Java *entity JNI bridge* integration test — compiles+links the
            // generated `entity_jni.c` (from `--generate-interfaces`) against
            // a hand-written native impl (test/integration/java/entity_native.c)
            // and runs a real Java program through it. This is what catches
            // JNI symbol/signature/marshaling bugs (wrong extern name, missing
            // header include, entity box/unbox, typedef resolution, …) that
            // the pure-data `Test.java` above never exercises, since it never
            // touches `*Impl.java`/the JNI bridge at all.
            const jni_include = findJniIncludeDir(b, java);
            if (jni_include) |jni_inc| {
                const gen_entity_c = b.addRunArtifact(exe);
                gen_entity_c.addArgs(&.{ "-b", "c", "--generate-interfaces", "-o" });
                const gen_entity_c_dir = gen_entity_c.addOutputDirectoryArg("integ-java-entity-c");
                gen_entity_c.addFileArg(b.path("test/integration/java/entity.idl"));

                const gen_entity_java = b.addRunArtifact(exe);
                gen_entity_java.addArgs(&.{
                    "-b",                    "java",
                    "--generate-interfaces", "--java-jni-library",
                    "entity_jni",            "--handle-retire-hook",
                    "entity_retire",         "--handle-retire-query",
                    "entity_is_retired",     "-o",
                });
                const gen_entity_java_dir = gen_entity_java.addOutputDirectoryArg("integ-java-entity-java");
                gen_entity_java.addFileArg(b.path("test/integration/java/entity.idl"));

                const entity_jni_mod = b.createModule(.{
                    .root_source_file = null,
                    .target = target,
                    .optimize = .Debug,
                    .link_libc = true,
                });
                entity_jni_mod.addCSourceFile(.{
                    .file = gen_entity_java_dir.path(b, "entity_jni.c"),
                    .flags = &.{"-std=c99"},
                });
                entity_jni_mod.addCSourceFile(.{
                    .file = b.path("test/integration/java/entity_native.c"),
                    .flags = &.{"-std=c99"},
                });
                entity_jni_mod.addIncludePath(gen_entity_c_dir);
                entity_jni_mod.addIncludePath(b.path("packages/zidl-cdr/include"));
                entity_jni_mod.addIncludePath(.{ .cwd_relative = jni_inc.base });
                entity_jni_mod.addIncludePath(.{ .cwd_relative = jni_inc.platform });
                const entity_jni_lib = b.addLibrary(.{
                    .name = "entity_jni",
                    .linkage = .dynamic,
                    .root_module = entity_jni_mod,
                });

                const compile_entity_java = javaCommand(b, &.{ javac, "-d", "build-tmp/integ-java-entity" }, java_cdr);
                compile_entity_java.addArgs(&.{"test/integration/java/EntityTest.java"});
                // The generated .java files live in a fresh per-run output
                // directory (a `LazyPath`) — pass each as its own file arg so
                // Zig's build graph also picks up the dependency on the run
                // step that generates them.
                for (&[_][]const u8{ "Entity.java", "FactoryImpl.java", "WidgetImpl.java", "PartImpl.java", "GearImpl.java", "SpringImpl.java" }) |f| {
                    compile_entity_java.addFileArg(gen_entity_java_dir.path(b, f));
                }

                const run_entity_java = javaCommand(b, &.{ java, "-cp", "build-tmp/integ-java-entity" }, java_cdr);
                run_entity_java.addPrefixedDirectoryArg("-Djava.library.path=", entity_jni_lib.getEmittedBinDirectory());
                run_entity_java.addArg("EntityTest");
                run_entity_java.step.dependOn(&compile_entity_java.step);
                run_entity_java.step.dependOn(&entity_jni_lib.step);
                integ_step.dependOn(&run_entity_java.step);

                // Java half of the cross-file widening test (see above).
                const gen_xfw_java_base = b.addRunArtifact(exe);
                gen_xfw_java_base.addArgs(&.{ "-b", "java", "--generate-interfaces", "--java-package", "xfw.core", "--java-jni-library", "xfw_jni", "-o" });
                const xfw_java_base_dir = gen_xfw_java_base.addOutputDirectoryArg("xfw-java-base");
                gen_xfw_java_base.addFileArg(b.path(xfw_dir ++ "/core.idl"));
                const gen_xfw_java_ext = b.addRunArtifact(exe);
                gen_xfw_java_ext.addArgs(&.{
                    "-b",                    "java",
                    "--generate-interfaces", "--java-package",
                    "xfw.plugin",            "--java-import-package",
                    "core=xfw.core",         "--java-jni-library",
                    "xfw_jni",               "-o",
                });
                const xfw_java_ext_dir = gen_xfw_java_ext.addOutputDirectoryArg("xfw-java-ext");
                gen_xfw_java_ext.addFileArg(b.path(xfw_dir ++ "/plugin.idl"));

                const xfw_jni_mod = b.createModule(.{
                    .root_source_file = null,
                    .target = target,
                    .optimize = .Debug,
                    .link_libc = true,
                });
                xfw_jni_mod.addCSourceFile(.{ .file = xfw_java_base_dir.path(b, "core_jni.c"), .flags = &.{"-std=c99"} });
                xfw_jni_mod.addCSourceFile(.{ .file = xfw_java_ext_dir.path(b, "plugin_jni.c"), .flags = &.{"-std=c99"} });
                xfw_jni_mod.addCSourceFile(.{ .file = b.path(xfw_dir ++ "/native.c"), .flags = &.{"-std=c99"} });
                xfw_jni_mod.addCSourceFile(.{ .file = b.path(xfw_dir ++ "/jni_bootstrap.c"), .flags = &.{"-std=c99"} });
                xfw_jni_mod.addIncludePath(b.path(xfw_dir));
                xfw_jni_mod.addIncludePath(xfw_c_dir);
                xfw_jni_mod.addIncludePath(xfw_c_ext_dir);
                xfw_jni_mod.addIncludePath(b.path("packages/zidl-cdr/include"));
                xfw_jni_mod.addIncludePath(.{ .cwd_relative = jni_inc.base });
                xfw_jni_mod.addIncludePath(.{ .cwd_relative = jni_inc.platform });
                const xfw_jni_lib = b.addLibrary(.{ .name = "xfw_jni", .linkage = .dynamic, .root_module = xfw_jni_mod });

                const compile_xfw_java = javaCommand(b, &.{ javac, "-d", "build-tmp/integ-java-xfw" }, java_cdr);
                compile_xfw_java.addArg(xfw_dir ++ "/CrossFileTest.java");
                for (&[_][]const u8{ "Core.java", "TopicDescriptionImpl.java", "TopicImpl.java", "ContentFilteredTopicImpl.java", "FactoryImpl.java" }) |f| {
                    compile_xfw_java.addFileArg(xfw_java_base_dir.path(b, f));
                }
                for (&[_][]const u8{ "Plugin.java", "ReaderImpl.java" }) |f| {
                    compile_xfw_java.addFileArg(xfw_java_ext_dir.path(b, f));
                }
                const run_xfw_java = javaCommand(b, &.{ java, "-cp", "build-tmp/integ-java-xfw" }, java_cdr);
                run_xfw_java.addPrefixedDirectoryArg("-Djava.library.path=", xfw_jni_lib.getEmittedBinDirectory());
                run_xfw_java.addArg("CrossFileTest");
                run_xfw_java.step.dependOn(&compile_xfw_java.step);
                run_xfw_java.step.dependOn(&xfw_jni_lib.step);
                integ_step.dependOn(&run_xfw_java.step);
            } else {
                // A missing optional JDK header is a skip, not a configure-time
                // warning during every install/test or consuming build.
                const skipped = b.step("skip-java-jni", "Skip optional Java JNI tests: jni.h not found");
                integ_step.dependOn(skipped);
            }
        } else {
            const skipped = b.step("skip-java-integration", "Skip optional Java integration tests: javac/java not found");
            integ_step.dependOn(skipped);
        }
    }

    // ── interop-test ──────────────────────────────────────────────────────────
    // Runs the Zig CDR interop tests against committed byte vectors.
    // Expected bytes are hardcoded in zig_interop_test.zig — no Cyclone DDS needed.
    // To regenerate the byte vectors after changing types.idl or cyclone_dump.c,
    // run: make -C interop regen CYCLONE=/path/to/cyclonedds
    const interop_step = b.step("interop-test", "Run Zig CDR interop tests (no Cyclone required)");
    const interop_tests = b.addTest(.{
        .name = "zidl-interop",
        .root_module = b.createModule(.{
            .root_source_file = b.path("interop/zig_interop_test.zig"),
            .target = target,
            .sanitize_thread = sanitize_thread,
            .imports = &.{
                .{ .name = "zidl_cdr", .module = runtimes.codec }, .{ .name = "zidl_bindings", .module = runtimes.bindings },
            },
        }),
    });
    interop_step.dependOn(&b.addRunArtifact(interop_tests).step);

    // ── emit-tests: build all test binaries to zig-out/tests/ for kcov ───────
    const emit_tests_step = b.step("emit-tests", "Build test binaries for kcov coverage analysis");
    if (typesupport_emit) |emit| emit_tests_step.dependOn(emit);
    emit_tests_step.dependOn(&b.addInstallArtifact(exe, .{}).step);
    // kcov instrumentation crashes with the default x86 backend's debug
    // information (reproduced in lexer tests). LLVM works with stock libdw;
    // ordinary builds retain their default backend.
    if (coverage) {
        for ([_]*std.Build.Step.Compile{ exe, mod_tests, exe_tests, zig_integration_tests, interop_tests, authoring_test }) |tests| {
            tests.use_llvm = true;
        }
    }
    emit_tests_step.dependOn(&b.addInstallArtifact(mod_tests, .{ .dest_dir = .{ .override = .{ .custom = "tests" } } }).step);
    emit_tests_step.dependOn(&b.addInstallArtifact(exe_tests, .{ .dest_dir = .{ .override = .{ .custom = "tests" } } }).step);
    emit_tests_step.dependOn(&b.addInstallArtifact(zig_integration_tests, .{ .dest_dir = .{ .override = .{ .custom = "tests" } } }).step);
    emit_tests_step.dependOn(&b.addInstallArtifact(authoring_test, .{ .dest_dir = .{ .override = .{ .custom = "tests" } } }).step);
    emit_tests_step.dependOn(&b.addInstallArtifact(interop_tests, .{ .dest_dir = .{ .override = .{ .custom = "tests" } } }).step);
}

// Instrumented archives require the final executable to link the same runtime.
fn linkCdr(module: *std.Build.Module, library: *std.Build.Step.Compile) void {
    module.sanitize_thread = library.root_module.sanitize_thread;
    module.linkLibrary(library);
}
