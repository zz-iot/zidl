// zidl-xtypes build script — skeleton for phase 5.
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const sanitize_thread = b.option(bool, "sanitize-thread", "Enable ThreadSanitizer") orelse false;

    _ = b.addModule("zidl-xtypes", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .sanitize_thread = sanitize_thread,
    });
}
