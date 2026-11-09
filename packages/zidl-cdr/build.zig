const std = @import("std");
pub const addCAbiLibrary = @import("c_api_build.zig").add;

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const coverage = b.option(bool, "coverage", "Use LLVM for coverage") orelse false;
    const sanitize_thread = b.option(bool, "sanitize-thread", "Enable ThreadSanitizer") orelse false;
    const mod = b.addModule("zidl-cdr", .{ .root_source_file = b.path("src/root.zig"), .target = target, .optimize = optimize, .sanitize_thread = sanitize_thread });
    alias(b, "zidl_cdr", mod);
    const shared = b.option(bool, "shared-primitives", "Use the shared native C ABI archive") orelse true;
    if (!shared) @panic("The C reference is test-only; use c-api/ with -Dshared-primitives=false");
    b.installArtifact(addCAbiLibrary(b, b.path("."), mod, target, optimize, sanitize_thread, shared));
    const tests = b.addTest(.{ .root_module = mod });
    if (coverage or sanitize_thread) tests.use_llvm = true;
    b.step("test", "Test the native CDR codec").dependOn(&b.addRunArtifact(tests).step);
    b.step("emit-tests", "Install native test binaries").dependOn(&b.addInstallArtifact(tests, .{ .dest_dir = .{ .override = .{ .custom = "tests" } } }).step);
}

fn alias(b: *std.Build, name: []const u8, module: *std.Build.Module) void {
    if (@hasField(@TypeOf(b.modules), "allocator")) {
        b.modules.put(name, module) catch @panic("OOM");
    } else {
        b.modules.put(b.allocator, name, module) catch @panic("OOM");
    }
}
