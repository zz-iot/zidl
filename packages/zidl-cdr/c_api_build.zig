const std = @import("std");

/// Shared artifact construction; validation-only dependencies stay in c-api/.
pub fn add(b: *std.Build, root: std.Build.LazyPath, native: *std.Build.Module, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, sanitize_thread: bool, shared: bool) *std.Build.Step.Compile {
    const mod = b.createModule(.{ .root_source_file = if (shared) root.path(b, "src/shared_primitives.zig") else null, .target = target, .optimize = optimize, .sanitize_thread = sanitize_thread, .link_libc = true, .sanitize_c = .off, .stack_protector = false });
    mod.addCSourceFile(.{ .file = root.path(b, if (shared) "src/zidl_cdr.c" else "test/reference/zidl_cdr.c"), .flags = &.{ "-std=c99", "-Wall", "-Wextra", "-Wpedantic" } });
    mod.addIncludePath(root.path(b, "include"));
    if (shared) {
        mod.addImport("zidl_cdr", native);
    }
    const lib = b.addLibrary(.{ .name = "zidl_cdr", .root_module = mod, .linkage = .static });
    if (sanitize_thread) lib.use_llvm = true;
    if (shared) {
        lib.bundle_compiler_rt = true;
        lib.bundle_ubsan_rt = true;
    }
    lib.installHeadersDirectory(root.path(b, "include"), "", .{ .include_extensions = null });
    return lib;
}
