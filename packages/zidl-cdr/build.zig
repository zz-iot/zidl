// zidl-cdr build script.
//
// Outputs:
//   lib   — libzidl_cdr.a (static C99 CDR library)
//   test  — Zig roundtrip tests cross-validating C library against zidl-rt
const std = @import("std");
const Translator = @import("translate_c").Translator;

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const coverage = b.option(bool, "coverage", "Use LLVM for kcov-compatible test debug information") orelse false;
    const sanitize_thread = b.option(bool, "sanitize-thread", "Enable ThreadSanitizer") orelse false;
    const shared_primitives = b.option(bool, "shared-primitives", "Use staged shared Zig primitives, strings, framing, keys and reader cursors") orelse false;

    // ── Library ────────────────────────────────────────────────────────────────

    const lib_mod = b.createModule(.{
        .root_source_file = if (shared_primitives) b.path("src/shared_primitives.zig") else null,
        .target = target,
        .optimize = optimize,
        .sanitize_thread = sanitize_thread,
        .link_libc = true,
    });
    lib_mod.addCSourceFile(.{
        .file = b.path("src/zidl_cdr.c"),
        .flags = &.{ "-std=c99", "-Wall", "-Wextra", "-Wpedantic" },
    });
    lib_mod.addIncludePath(b.path("include"));
    if (shared_primitives) lib_mod.addCMacro("ZIDL_CDR_SHARED_PRIMITIVES", "1");

    const lib = b.addLibrary(.{
        .name = "zidl_cdr",
        .root_module = lib_mod,
        .linkage = .static,
    });
    // A foreign linker does not add Zig's stack-probe or C sanitizer runtimes.
    // Keep both Zig safety and the remaining C source's default instrumentation.
    if (shared_primitives) {
        lib.bundle_compiler_rt = true;
        lib.bundle_ubsan_rt = true;
    }
    b.installArtifact(lib);

    const external_test = b.step("test-external-c", "Link/run the shared archive with a native Unix-style system C compiler");
    const external_cc = b.option([]const u8, "external-cc", "System C compiler executable for test-external-c") orelse "cc";
    if (!shared_primitives) {
        external_test.dependOn(&b.addFail("test-external-c requires -Dshared-primitives=true").step);
    } else if (!target.query.isNative() or (target.result.os.tag != .linux and target.result.os.tag != .macos)) {
        external_test.dependOn(&b.addFail("test-external-c currently requires a native Linux/macOS target and Unix-style C compiler").step);
    } else {
        const consumer = b.addSystemCommand(&.{ external_cc, "-std=c11", "-Wall", "-Wextra", "-Werror", "-DZIDL_CDR_SHARED_CONSUMER", "-I" });
        consumer.addDirectoryArg(b.path("include"));
        consumer.addFileArg(b.path("test/shared_primitives.c"));
        consumer.addFileArg(b.path("test/fixed_external.c"));
        consumer.addArtifactArg(lib);
        consumer.addArg("-o");
        const executable = consumer.addOutputFileArg("cdr-external-consumer");
        external_test.dependOn(&b.addRunFile(executable).step);
    }

    // ── Tests ──────────────────────────────────────────────────────────────────

    // Resolve zidl-rt (sibling package).
    const zidl_rt_dep = b.dependency("zidl_rt", .{
        .target = target,
        .optimize = optimize,
        .@"sanitize-thread" = sanitize_thread,
    });
    const zidl_rt_mod = zidl_rt_dep.module("zidl-rt");
    if (shared_primitives) lib_mod.addImport("zidl_rt", zidl_rt_mod);

    const c: Translator = .init(b.dependency("translate_c", .{}), .{
        .c_source_file = b.path("include/zidl_cdr.h"),
        .target = target,
        .optimize = optimize,
    });

    const fixed_vectors = b.addWriteFiles();
    const fixed_cases = b.createModule(.{ .root_source_file = fixed_vectors.addCopyFile(zidl_rt_dep.path("src/fixed_test_cases.zig"), "fixed_cases.zig"), .target = target });
    const test_mod = b.createModule(.{
        .root_source_file = b.path("test/roundtrip.zig"),
        .target = target,
        .optimize = optimize,
        .sanitize_thread = sanitize_thread,
        .link_libc = true,
        .imports = &.{
            .{ .name = "zidl_rt", .module = zidl_rt_mod },
            .{ .name = "fixed_cases", .module = fixed_cases },
            .{ .name = "zidl_cdr", .module = c.mod },
        },
    });
    test_mod.addCSourceFile(.{
        .file = b.path("test/optional.c"),
        .flags = &.{ "-std=c99", "-Wall", "-Wextra", "-Werror" },
    });
    test_mod.addIncludePath(b.path("include"));
    test_mod.linkLibrary(lib);

    const test_exe = b.addTest(.{
        .root_module = test_mod,
    });
    const run_tests = b.addRunArtifact(test_exe);
    const test_step = b.step("test", "Run zidl-cdr tests");
    test_step.dependOn(&run_tests.step);

    const adapter_mod = b.createModule(.{
        .root_source_file = b.path("src/shared_primitives.zig"),
        .target = target,
        .optimize = optimize,
        .sanitize_thread = sanitize_thread,
        .imports = &.{.{ .name = "zidl_rt", .module = zidl_rt_mod }},
    });
    const shared_test_mod = b.createModule(.{
        .root_source_file = b.path("test/shared_primitives.zig"),
        .target = target,
        .optimize = optimize,
        .sanitize_thread = sanitize_thread,
        .link_libc = true,
        .imports = &.{
            .{ .name = "zidl_rt", .module = zidl_rt_mod },
            .{ .name = "fixed_cases", .module = fixed_cases },
            .{ .name = "adapter", .module = adapter_mod },
        },
    });
    shared_test_mod.addCSourceFile(.{
        .file = b.path("test/optional.c"),
        .flags = &.{ "-std=c99", "-Wall", "-Wextra", "-Werror" },
    });
    shared_test_mod.addIncludePath(b.path("include"));
    shared_test_mod.addCSourceFile(.{
        .file = b.path("src/zidl_cdr.c"),
        .flags = &.{ "-std=c99", "-DZIDL_CDR_SHARED_PRIMITIVES", "-Wall", "-Wextra", "-Werror" },
    });
    shared_test_mod.addCSourceFile(.{
        .file = b.path("test/shared_primitives.c"),
        .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Werror" },
    });
    const shared_tests = b.addTest(.{ .root_module = shared_test_mod });
    if (coverage) shared_tests.use_llvm = true;
    const run_shared = b.addRunArtifact(shared_tests);
    b.step("test-shared-primitives", "Check shared Zig/C wire operations, modes and ABI").dependOn(&run_shared.step);
    test_step.dependOn(&run_shared.step);

    if (coverage) test_exe.use_llvm = true;
    const emit_tests_step = b.step("emit-tests", "Build test binaries for kcov coverage analysis");
    emit_tests_step.dependOn(&b.addInstallArtifact(test_exe, .{
        .dest_dir = .{ .override = .{ .custom = "tests" } },
    }).step);
}
