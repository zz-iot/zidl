const std = @import("std");
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const runtime = b.dependency("zidl_rt", .{ .target = target });
    const header = b.addTranslateC(.{ .root_source_file = b.path("include/zidl_typesupport.h"), .target = target, .optimize = optimize, .link_libc = false });
    const module = b.addModule("zidl_typesupport", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{ .{ .name = "zidl_rt", .module = runtime.module("zidl-rt") }, .{ .name = "zidl_typesupport_c", .module = header.createModule() } },
    });
    module.addIncludePath(b.path("include"));

    // Optional standalone build recipe for already-generated application files.
    const types_path = b.option([]const u8, "types", "Absolute path to generated application Zig types");
    const provider_path = b.option([]const u8, "provider", "Absolute path to generated typesupport wrapper");
    const name = b.option([]const u8, "name", "Output library name") orelse "application_types";
    if ((types_path == null) != (provider_path == null)) @panic("Supply both -Dtypes and -Dprovider");
    if (types_path) |path| {
        if (!std.fs.path.isAbsolute(path) or !std.fs.path.isAbsolute(provider_path.?)) @panic("Generated source paths must be absolute");
        const types = b.createModule(.{
            .root_source_file = .{ .cwd_relative = path },
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "zidl_rt", .module = runtime.module("zidl-rt") }},
        });
        const provider = b.createModule(.{
            .root_source_file = .{ .cwd_relative = provider_path.? },
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "types", .module = types },
                .{ .name = "zidl_rt", .module = runtime.module("zidl-rt") },
                .{ .name = "zidl_typesupport", .module = module },
            },
        });
        const library = b.addLibrary(.{ .name = name, .linkage = .dynamic, .root_module = provider });
        b.installArtifact(library);
    }
}
