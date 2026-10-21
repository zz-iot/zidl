const std = @import("std");
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const zidl = b.option([]const u8, "zidl", "Path to prebuilt zidl") orelse "../../../zig-out/bin/zidl";
    b.step("test", "Run wire library integration tests").dependOn(addTests(b, b.path("."), .{ .cwd_relative = zidl }, target, optimize, b.option(bool, "verbose-tests", "Show successful integration test output") orelse false, b.option(bool, "coverage", "Use LLVM for kcov-compatible debug information") orelse false).tests);
}

pub fn addTests(b: *std.Build, base: std.Build.LazyPath, zidl: std.Build.LazyPath, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, verbose_tests: bool, coverage: bool) struct { tests: *std.Build.Step, emit: *std.Build.Step } {
    const rt = b.createModule(.{ .root_source_file = base.path(b, "../../../packages/zidl-rt/src/root.zig"), .target = target, .optimize = optimize });
    const header = b.addTranslateC(.{ .root_source_file = base.path(b, "../../../packages/zidl-typesupport/include/zidl_typesupport.h"), .target = target, .optimize = optimize, .link_libc = false });
    const ts = b.createModule(.{ .root_source_file = base.path(b, "../../../packages/zidl-typesupport/src/root.zig"), .target = target, .optimize = optimize, .imports = &.{ .{ .name = "zidl_rt", .module = rt }, .{ .name = "zidl_typesupport_c", .module = header.createModule() } } });
    ts.addIncludePath(base.path(b, "../../../packages/zidl-typesupport/include"));
    var libs: [3]*std.Build.Step.Compile = undefined;
    for ([_][]const u8{ "a", "b", "conflict" }, 0..) |stem, i| {
        const gen = std.Build.Step.Run.create(b, "generate experimental typesupport");
        gen.addFileArg(zidl);
        gen.addArgs(&.{ "-b", "zig", "--experimental-typesupport-library", "-o" });
        const output = gen.addOutputDirectoryArg(stem);
        gen.addFileArg(base.path(b, b.fmt("{s}.idl", .{stem})));
        const types = b.createModule(.{ .root_source_file = output.path(b, b.fmt("{s}.zig", .{stem})), .target = target, .optimize = optimize, .imports = &.{.{ .name = "zidl_rt", .module = rt }} });
        const provider = b.createModule(.{ .root_source_file = output.path(b, b.fmt("{s}_typesupport.zig", .{stem})), .target = target, .optimize = optimize, .imports = &.{ .{ .name = "types", .module = types }, .{ .name = "zidl_rt", .module = rt }, .{ .name = "zidl_typesupport", .module = ts } } });
        libs[i] = b.addLibrary(.{ .name = stem, .linkage = .dynamic, .root_module = provider });
    }
    const host = b.addExecutable(.{ .name = "ts-host", .root_module = b.createModule(.{ .root_source_file = base.path(b, "host.zig"), .target = target, .optimize = optimize, .link_libc = true, .imports = &.{ .{ .name = "zidl_typesupport", .module = ts }, .{ .name = "zidl_rt", .module = rt } } }) });
    const run = b.addRunArtifact(host);
    if (!verbose_tests) {
        run.expectStdErrEqual("Zig host: metadata integrity/closure, duplicate exports, collisions and bounded wire validation passed\n");
        run.expectExitCode(0);
    }
    for (libs) |lib| run.addArtifactArg(lib);
    const c_host = b.addExecutable(.{ .name = "ts-c-host", .root_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true }) });
    c_host.root_module.addCSourceFile(.{ .file = base.path(b, "host.c"), .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Werror" } });
    c_host.root_module.addIncludePath(base.path(b, "../../../packages/zidl-typesupport/include"));
    if (target.result.os.tag == .linux) c_host.root_module.linkSystemLibrary("dl", .{});
    const run_c = b.addRunArtifact(c_host);
    if (!verbose_tests) run_c.expectStdOutMatch("C ABI: independent providers, equivalent/conflicting exports, full/key-only samples and failures passed");
    for (libs) |lib| run_c.addArtifactArg(lib);
    const tests = b.step("test-typesupport-library", "Generate and load independent libraries through Zig and C hosts");
    tests.dependOn(&run.step);
    tests.dependOn(&run_c.step);
    const static_gen = std.Build.Step.Run.create(b, "generate experimental typesupport");
    static_gen.addFileArg(zidl);
    static_gen.addArgs(&.{ "-b", "zig", "--experimental-typesupport-library", "-o" });
    const static_out = static_gen.addOutputDirectoryArg("static-types");
    static_gen.addFileArg(base.path(b, "b.idl"));
    const static_types = b.createModule(.{ .root_source_file = static_out.path(b, "b.zig"), .target = target, .optimize = optimize, .imports = &.{.{ .name = "zidl_rt", .module = rt }} });
    const static_provider = b.createModule(.{ .root_source_file = static_out.path(b, "b_typesupport.zig"), .target = target, .optimize = optimize, .imports = &.{ .{ .name = "types", .module = static_types }, .{ .name = "zidl_rt", .module = rt }, .{ .name = "zidl_typesupport", .module = ts } } });
    const static_test = b.addTest(.{ .name = "zidl-typesupport-static", .root_module = b.createModule(.{ .root_source_file = base.path(b, "static.zig"), .target = target, .optimize = optimize, .imports = &.{ .{ .name = "provider", .module = static_provider }, .{ .name = "zidl_typesupport", .module = ts } } }) });
    tests.dependOn(&b.addRunArtifact(static_test).step);
    // Keep loadable providers beside the hosts, separate from argument-free tests.
    const emit = b.step("emit-typesupport-tests", "Build typesupport coverage fixtures and hosts");
    if (coverage) {
        for (libs) |lib| lib.use_llvm = true;
        host.use_llvm = true;
        c_host.use_llvm = true;
        static_test.use_llvm = true;
    }
    emit.dependOn(&b.addInstallArtifact(static_test, .{ .dest_dir = .{ .override = .{ .custom = "tests" } } }).step);
    for (libs ++ [_]*std.Build.Step.Compile{ host, c_host }) |artifact| {
        emit.dependOn(&b.addInstallArtifact(artifact, .{ .dest_dir = .{ .override = .{ .custom = "coverage-typesupport" } } }).step);
    }
    return .{ .tests = tests, .emit = emit };
}
