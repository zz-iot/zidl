const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const coverage = b.option(bool, "coverage", "Use LLVM for kcov-compatible test debug information") orelse false;
    const sanitize_thread = b.option(bool, "sanitize-thread", "Enable ThreadSanitizer") orelse false;

    const bindings = b.dependency("zidl_bindings", .{ .target = target, .optimize = optimize, .@"sanitize-thread" = sanitize_thread }).module("zidl-bindings");
    const codec = bindings.import_table.get("zidl_cdr").?;
    const mod = b.addModule("zidl-rt", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{ .{ .name = "zidl_cdr", .module = codec }, .{ .name = "zidl_bindings", .module = bindings } },
        .sanitize_thread = sanitize_thread,
    });

    alias(b, "zidl_rt", mod);
    alias(b, "zidl_cdr", codec);
    alias(b, "zidl_bindings", bindings);

    const mod_tests = b.addTest(.{
        .root_module = mod,
    });
    const run_tests = b.addRunArtifact(mod_tests);
    const test_step = b.step("test", "Run zidl-rt tests");
    test_step.dependOn(&run_tests.step);

    if (coverage or sanitize_thread) mod_tests.use_llvm = true;
    const emit_tests_step = b.step("emit-tests", "Build test binaries for kcov coverage analysis");
    emit_tests_step.dependOn(&b.addInstallArtifact(mod_tests, .{
        .dest_dir = .{ .override = .{ .custom = "tests" } },
    }).step);
}

fn alias(b: *std.Build, name: []const u8, module: *std.Build.Module) void {
    if (@hasField(@TypeOf(b.modules), "allocator")) {
        b.modules.put(name, module) catch @panic("OOM");
    } else {
        b.modules.put(b.allocator, name, module) catch @panic("OOM");
    }
}
