const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const runtime = b.dependency("zidl_bindings", .{
        .target = target,
        .optimize = optimize,
    });

    const types_mod = b.createModule(.{
        .root_source_file = b.path("generated/types.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zidl_cdr", .module = runtime.module("zidl_cdr") }, .{ .name = "zidl_bindings", .module = runtime.module("zidl-bindings") },
        },
    });

    const allocations_mod = b.createModule(.{
        .root_source_file = b.path("generated/allocations.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{ .{ .name = "zidl_cdr", .module = runtime.module("zidl_cdr") }, .{ .name = "zidl_bindings", .module = runtime.module("zidl-bindings") } },
    });

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zidl_cdr", .module = runtime.module("zidl_cdr") }, .{ .name = "zidl_bindings", .module = runtime.module("zidl-bindings") },
                .{ .name = "types", .module = types_mod },                     .{ .name = "allocations", .module = allocations_mod },
            },
        }),
    });

    const test_step = b.step("test", "Compile and run generated XRCE MicroZig-facing bindings");
    test_step.dependOn(&b.addRunArtifact(tests).step);
}
