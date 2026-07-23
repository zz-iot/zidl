const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    _ = optimize;
    const sanitize_thread = b.option(bool, "sanitize-thread", "Enable ThreadSanitizer") orelse false;

    const mod = b.addModule("zidl-rt", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .sanitize_thread = sanitize_thread,
    });

    const mod_tests = b.addTest(.{
        .root_module = mod,
    });
    const run_tests = b.addRunArtifact(mod_tests);
    const test_step = b.step("test", "Run zidl-rt tests");
    test_step.dependOn(&run_tests.step);

    const emit_tests_step = b.step("emit-tests", "Build test binaries for kcov coverage analysis");
    emit_tests_step.dependOn(&b.addInstallArtifact(mod_tests, .{
        .dest_dir = .{ .override = .{ .custom = "tests" } },
    }).step);
}
