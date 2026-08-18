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
        (b.allocator.dupeZ(u8, java_path) catch return null);
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

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const sanitize_thread = b.option(bool, "sanitize-thread", "Enable ThreadSanitizer") orelse false;

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

    // ── run ───────────────────────────────────────────────────────────────────
    const run_step = b.step("run", "Run the app");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    // ── unit tests ────────────────────────────────────────────────────────────
    const mod_tests = b.addTest(.{ .name = "zidl-mod", .root_module = mod });
    const run_mod_tests = b.addRunArtifact(mod_tests);

    const exe_tests = b.addTest(.{ .name = "zidl-exe", .root_module = exe.root_module });
    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run unit tests + Zig integration tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);

    // ── Zig integration tests ─────────────────────────────────────────────────
    // These use the committed golden types.zig and run CDR round-trip + vtable tests.
    const zidl_rt_mod = b.addModule("zidl_rt", .{
        .root_source_file = b.path("packages/zidl-rt/src/root.zig"),
        .target = target,
        .sanitize_thread = sanitize_thread,
    });

    const golden_zig_mod = b.createModule(.{
        .root_source_file = b.path("test/golden/zig/types.zig"),
        .target = target,
        .sanitize_thread = sanitize_thread,
        .imports = &.{
            .{ .name = "zidl_rt", .module = zidl_rt_mod },
        },
    });

    const stub_mod = b.createModule(.{
        .root_source_file = b.path("test/integration/zig/stub_impl.zig"),
        .target = target,
        .sanitize_thread = sanitize_thread,
        .imports = &.{
            .{ .name = "types", .module = golden_zig_mod },
            .{ .name = "zidl_rt", .module = zidl_rt_mod },
        },
    });

    const zig_integration_tests = b.addTest(.{
        .name = "zidl-integ",
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/integration/zig/test.zig"),
            .target = target,
            .sanitize_thread = sanitize_thread,
            .imports = &.{
                .{ .name = "zidl_rt", .module = zidl_rt_mod },
                .{ .name = "types", .module = golden_zig_mod },
                .{ .name = "stub_impl", .module = stub_mod },
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
                .{ .name = "zidl_rt", .module = zidl_rt_mod },
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
                    .{ .name = "zidl_rt", .module = zidl_rt_mod },
                    .{ .name = "fixture", .module = wrapper_fixture_mod },
                    .{ .name = "zzdds", .module = fake_middleware_mod },
                },
            }),
        });
        const run_wrapper_contract = b.addRunArtifact(wrapper_contract_tests);
        test_step.dependOn(&run_wrapper_contract.step);
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
                "packages/zidl-cdr/src/zidl_cdr.c",
            },
            .flags = &.{ "-std=c99", "-Wall", "-Werror" },
        });
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
        cpp_mod.addCSourceFiles(.{
            .files = &.{"packages/zidl-cdr/src/zidl_cdr.c"},
            .flags = &.{ "-std=c99", "-Wall" },
        });
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

    // Same test again, but compiled with -fno-rtti: zidl_allocator_pmr.hpp is
    // meant for embedded/RT builds that routinely disable RTTI, and that
    // claim needs an actual CI-checked compile, not just a one-off manual
    // check — a prior dynamic_cast in do_is_equal broke this silently.
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
            .flags = &.{ "-std=c++17", "-Wall", "-Wextra", "-fno-rtti" },
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

    // Java integration test — requires javac/java on PATH
    {
        const maybe_javac = b.findProgram(&.{"javac"}, &.{}) catch null;
        const maybe_java = b.findProgram(&.{"java"}, &.{}) catch null;
        if (maybe_javac != null and maybe_java != null) {
            const javac = maybe_javac.?;
            const java = maybe_java.?;
            const java_out = "build-tmp/integ-java";
            const compile_java = b.addSystemCommand(&.{
                javac,
                "-d",
                java_out,
                "test/golden/java/Types.java",
                "test/integration/java/Test.java",
            });
            const run_java = b.addSystemCommand(&.{ java, "-cp", java_out, "Test" });
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
                    "entity_jni",            "-o",
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

                const compile_entity_java = b.addSystemCommand(&.{ javac, "-d", "build-tmp/integ-java-entity" });
                compile_entity_java.addArgs(&.{"test/integration/java/EntityTest.java"});
                // The generated .java files live in a fresh per-run output
                // directory (a `LazyPath`) — pass each as its own file arg so
                // Zig's build graph also picks up the dependency on the run
                // step that generates them.
                for (&[_][]const u8{ "Entity.java", "FactoryImpl.java", "WidgetImpl.java" }) |f| {
                    compile_entity_java.addFileArg(gen_entity_java_dir.path(b, f));
                }

                const run_entity_java = b.addSystemCommand(&.{ java, "-cp", "build-tmp/integ-java-entity" });
                run_entity_java.addPrefixedDirectoryArg("-Djava.library.path=", entity_jni_lib.getEmittedBinDirectory());
                run_entity_java.addArg("EntityTest");
                run_entity_java.step.dependOn(&compile_entity_java.step);
                run_entity_java.step.dependOn(&entity_jni_lib.step);
                integ_step.dependOn(&run_entity_java.step);
            } else {
                std.log.warn("jni.h not found under the detected JAVA_HOME — skipping Java entity JNI bridge integration test", .{});
            }
        } else {
            std.log.warn("javac/java not found — skipping Java integration test", .{});
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
                .{ .name = "zidl_rt", .module = zidl_rt_mod },
            },
        }),
    });
    interop_step.dependOn(&b.addRunArtifact(interop_tests).step);

    // ── emit-tests: build all test binaries to zig-out/tests/ for kcov ───────
    const emit_tests_step = b.step("emit-tests", "Build test binaries for kcov coverage analysis");
    emit_tests_step.dependOn(&b.addInstallArtifact(mod_tests, .{ .dest_dir = .{ .override = .{ .custom = "tests" } } }).step);
    emit_tests_step.dependOn(&b.addInstallArtifact(exe_tests, .{ .dest_dir = .{ .override = .{ .custom = "tests" } } }).step);
    emit_tests_step.dependOn(&b.addInstallArtifact(zig_integration_tests, .{ .dest_dir = .{ .override = .{ .custom = "tests" } } }).step);
    emit_tests_step.dependOn(&b.addInstallArtifact(interop_tests, .{ .dest_dir = .{ .override = .{ .custom = "tests" } } }).step);
}
