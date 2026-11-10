const std = @import("std");

pub const Modules = struct { codec: *std.Build.Module, bindings: *std.Build.Module };

/// Share canonical modules so generated code preserves type and registry identity.
pub fn add(b: *std.Build, root: std.Build.LazyPath, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, sanitize_thread: bool) Modules {
    const codec = b.createModule(.{ .root_source_file = root.path(b, "packages/zidl-cdr/src/root.zig"), .target = target, .optimize = optimize, .sanitize_thread = sanitize_thread });
    const bindings = b.createModule(.{ .root_source_file = root.path(b, "packages/zidl-bindings/src/root.zig"), .target = target, .optimize = optimize, .sanitize_thread = sanitize_thread, .imports = &.{.{ .name = "zidl_cdr", .module = codec }} });
    return .{ .codec = codec, .bindings = bindings };
}
