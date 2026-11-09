// C ABI adapter and temporary C reference builds.
//
// Outputs:
//   lib   — libzidl_cdr.a (stable C ABI)
//   test  — native/C ABI contracts and independent wire witnesses
const std = @import("std");
const Translator = @import("translate_c").Translator;

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const coverage = b.option(bool, "coverage", "Use LLVM for kcov-compatible test debug information") orelse false;
    const sanitize_thread = b.option(bool, "sanitize-thread", "Enable ThreadSanitizer") orelse false;
    const shared_primitives = b.option(bool, "shared-primitives", "Use the shared native codec (false selects the test-only C reference)") orelse true;

    const codec_dep = b.dependency("zidl_cdr", .{ .target = target, .optimize = optimize, .@"sanitize-thread" = sanitize_thread });

    // ── Library ────────────────────────────────────────────────────────────────

    const zidl_cdr_mod = codec_dep.module("zidl-cdr");
    const lib = @import("zidl_cdr").addCAbiLibrary(b, codec_dep.path("."), zidl_cdr_mod, target, optimize, sanitize_thread, shared_primitives);
    b.installArtifact(lib);

    const external_test = b.step("test-external-c", "Link/run the shared archive with a native Unix-style system C compiler");
    const external_cc = b.option([]const u8, "external-cc", "System C compiler executable for test-external-c") orelse "cc";
    if (!shared_primitives) {
        external_test.dependOn(&b.addFail("test-external-c requires -Dshared-primitives=true").step);
    } else if (!target.query.isNative() or (target.result.os.tag != .linux and target.result.os.tag != .macos)) {
        external_test.dependOn(&b.addFail("test-external-c currently requires a native Linux/macOS target and Unix-style C compiler").step);
    } else {
        const consumer = b.addSystemCommand(&.{ external_cc, "-std=c11", "-Wall", "-Wextra", "-Werror", "-DZIDL_CDR_SHARED_CONSUMER", "-I" });
        consumer.addDirectoryArg(codec_dep.path("include"));
        consumer.addFileArg(codec_dep.path("test/shared_primitives.c"));
        consumer.addFileArg(codec_dep.path("test/fixed_external.c"));
        consumer.addArtifactArg(lib);
        consumer.addArg("-o");
        const executable = consumer.addOutputFileArg("cdr-external-consumer");
        external_test.dependOn(&b.addRunFile(executable).step);
    }

    // ── Tests ──────────────────────────────────────────────────────────────────

    const c: Translator = .init(b.dependency("translate_c", .{}), .{
        .c_source_file = codec_dep.path("include/zidl_cdr.h"),
        .target = target,
        .optimize = optimize,
    });

    const fixed_vectors = b.addWriteFiles();
    const fixed_cases = b.createModule(.{ .root_source_file = fixed_vectors.addCopyFile(codec_dep.path("src/fixed_test_cases.zig"), "fixed_cases.zig"), .target = target });
    const test_mod = b.createModule(.{
        .root_source_file = codec_dep.path("test/roundtrip.zig"),
        .target = target,
        .optimize = optimize,
        .sanitize_thread = sanitize_thread,
        .link_libc = true,
        .imports = &.{
            .{ .name = "zidl_cdr_native", .module = zidl_cdr_mod },
            .{ .name = "fixed_cases", .module = fixed_cases },
            .{ .name = "zidl_cdr", .module = c.mod },
        },
    });
    test_mod.addCSourceFile(.{
        .file = codec_dep.path("test/optional.c"),
        .flags = &.{ "-std=c99", "-Wall", "-Wextra", "-Werror" },
    });
    test_mod.addIncludePath(codec_dep.path("include"));
    test_mod.linkLibrary(lib);

    const test_exe = b.addTest(.{
        .root_module = test_mod,
    });
    const run_tests = b.addRunArtifact(test_exe);
    const test_step = b.step("test", "Run zidl-cdr tests");
    test_step.dependOn(&run_tests.step);

    const adapter_mod = b.createModule(.{
        .root_source_file = codec_dep.path("src/shared_primitives.zig"),
        .target = target,
        .optimize = optimize,
        .sanitize_thread = sanitize_thread,
        .imports = &.{.{ .name = "zidl_cdr", .module = zidl_cdr_mod }},
    });
    const shared_test_mod = b.createModule(.{
        .root_source_file = codec_dep.path("test/shared_primitives.zig"),
        .target = target,
        .optimize = optimize,
        .sanitize_thread = sanitize_thread,
        .link_libc = true,
        .imports = &.{
            .{ .name = "zidl_cdr_native", .module = zidl_cdr_mod },
            .{ .name = "fixed_cases", .module = fixed_cases },
            .{ .name = "adapter", .module = adapter_mod },
            .{ .name = "c_header", .module = c.mod },
        },
    });
    shared_test_mod.addCSourceFile(.{
        .file = codec_dep.path("test/optional.c"),
        .flags = &.{ "-std=c99", "-Wall", "-Wextra", "-Werror" },
    });
    shared_test_mod.addIncludePath(codec_dep.path("include"));
    shared_test_mod.addCSourceFile(.{
        .file = codec_dep.path("src/zidl_cdr.c"),
        .flags = &.{ "-std=c99", "-Wall", "-Wextra", "-Werror" },
    });
    shared_test_mod.addCSourceFile(.{
        .file = codec_dep.path("test/shared_primitives.c"),
        .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Werror" },
    });
    const shared_tests = b.addTest(.{ .root_module = shared_test_mod });
    if (coverage or sanitize_thread) shared_tests.use_llvm = true;
    const run_shared = b.addRunArtifact(shared_tests);
    b.step("test-shared-primitives", "Check shared Zig/C wire operations, modes and ABI").dependOn(&run_shared.step);
    test_step.dependOn(&run_shared.step);

    if (coverage or sanitize_thread) test_exe.use_llvm = true;
    const emit_tests_step = b.step("emit-tests", "Build test binaries for kcov coverage analysis");
    emit_tests_step.dependOn(&b.addInstallArtifact(test_exe, .{
        .dest_dir = .{ .override = .{ .custom = "tests" } },
    }).step);
}
