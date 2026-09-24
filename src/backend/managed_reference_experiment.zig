//! Narrow opt-in experiment. Not the production managed-reference ABI.
const std = @import("std");
const ir = @import("../ir/root.zig");
pub fn enabled(iface: *const ir.Interface) bool {
    for (iface.raw) |a| if (std.mem.eql(u8, a.name, "experimental_managed_reference")) return true;
    return false;
}
pub fn validate(iface: *const ir.Interface) !void {
    if (iface.bases.len != 0 or iface.attributes.len != 0 or iface.type_decls.len != 0 or iface.consts.len != 0 or ir.types.isCallbackInterface(iface)) return error.UnsupportedManagedReferenceExperiment;
    for (iface.operations) |op| {
        const t = op.return_type orelse return error.UnsupportedManagedReferenceExperiment;
        if (op.params.len > 1 or op.raises.len != 0 or op.is_oneway or t != .base or t.base != .long) return error.UnsupportedManagedReferenceExperiment;
        if (op.params.len == 1) {
            const p = op.params[0];
            if (p.mode != .inout or p.type_ref != .named or p.type_ref.named != .interface or p.type_ref.named.interface != iface) return error.UnsupportedManagedReferenceExperiment;
        }
    }
}
pub fn c(alloc: std.mem.Allocator, iface: *const ir.Interface, name: []const u8) ![]u8 {
    try validate(iface);
    var s: std.Io.Writer.Allocating = .init(alloc);
    errdefer s.deinit();
    try s.writer.print("/* Experimental managed reference: provider and handle are not legacy EntityBox. */\nstruct {s}_s {{\n void *owner; void *target;\n int32_t (*retain)(void *); void (*release)(void *);\n", .{name});
    for (iface.operations) |op| {
        if (op.params.len == 0) try s.writer.print(" int32_t (*{s})(void *);\n", .{op.name}) else try s.writer.print(" int32_t (*{s})(void *, {s} *);\n", .{ op.name, name });
    }
    try s.writer.print("}};\nint32_t {s}_ref_assign({s} *slot, {s} borrowed);\nvoid {s}_ref_clear({s} *slot);\n", .{ name, name, name, name, name });
    for (iface.operations) |op| {
        if (op.params.len == 0) try s.writer.print("int32_t {s}_{s}({s} self);\n", .{ name, op.name, name }) else try s.writer.print("int32_t {s}_{s}({s} self, {s} *slot);\n", .{ name, op.name, name, name });
    }
    return s.toOwnedSlice();
}
pub fn zig(alloc: std.mem.Allocator, iface: *const ir.Interface, name: []const u8, cname: []const u8) ![]u8 {
    try validate(iface);
    var s: std.Io.Writer.Allocating = .init(alloc);
    errdefer s.deinit();
    try s.writer.print("pub const {s} = extern struct {{\n owner: *anyopaque, target: *anyopaque,\n retain: *const fn (*anyopaque) callconv(.c) i32,\n release: *const fn (*anyopaque) callconv(.c) void,\n", .{name});
    for (iface.operations) |op| {
        if (op.params.len == 0) try s.writer.print(" {s}: *const fn (*anyopaque) callconv(.c) i32,\n", .{op.name}) else try s.writer.print(" {s}: *const fn (*anyopaque, *?*{s}) callconv(.c) i32,\n", .{ op.name, name });
    }
    try s.writer.print("}};\npub export fn {s}_ref_assign(slot: *?*{s}, borrowed: ?*{s}) i32 {{\n if (slot.* == borrowed) return 0;\n if (borrowed) |b| {{ const rc = b.retain(b.owner); if (rc != 0) return rc; }}\n const old = slot.*; slot.* = borrowed;\n if (old) |o| o.release(o.owner);\n return 0;\n}}\npub export fn {s}_ref_clear(slot: *?*{s}) void {{\n const old = slot.*; slot.* = null; if (old) |o| o.release(o.owner);\n}}\n", .{ cname, name, name, cname, name });
    for (iface.operations) |op| {
        if (op.params.len == 0) try s.writer.print("pub export fn {s}_{s}(self: *{s}) i32 {{ return self.{s}(self.target); }}\n", .{ cname, op.name, name, op.name }) else try s.writer.print("pub export fn {s}_{s}(self: *{s}, slot: *?*{s}) i32 {{ return self.{s}(self.target, slot); }}\n", .{ cname, op.name, name, name, op.name });
    }
    return s.toOwnedSlice();
}

pub fn configEnabled(s: *const ir.Struct) bool {
    for (s.annotations.raw) |a| if (std.mem.eql(u8, a.name, "experimental_managed_config")) return true;
    return false;
}
fn validateConfig(s: *const ir.Struct) !void {
    if (s.base != null or s.members.len == 0) return error.UnsupportedManagedReferenceExperiment;
    for (s.members) |m| {
        if (m.dimensions.len != 0 or m.annotations.is_optional or m.type_ref != .named or m.type_ref.named != .interface or !enabled(m.type_ref.named.interface)) return error.UnsupportedManagedReferenceExperiment;
    }
}
fn cName(alloc: std.mem.Allocator, qualified: []const u8) ![]u8 {
    return std.mem.replaceOwned(u8, alloc, qualified, "::", "_");
}
pub fn configC(alloc: std.mem.Allocator, cfg: *const ir.Struct, name: []const u8) ![]u8 {
    try validateConfig(cfg);
    var s: std.Io.Writer.Allocating = .init(alloc);
    errdefer s.deinit();
    try s.writer.print("typedef struct {s} {{\n", .{name});
    for (cfg.members) |m| {
        const ref = try cName(alloc, m.type_ref.named.interface.qualified_name);
        defer alloc.free(ref);
        try s.writer.print(" {s} {s};\n", .{ ref, m.name });
    }
    try s.writer.print("}} {s};\nvoid {s}_init({s} *self);\nvoid {s}_fini({s} *self);\nint32_t {s}_clone({s} *empty_dst, const {s} *src);\n", .{ name, name, name, name, name, name, name, name });
    for (cfg.members) |m| {
        const ref = try cName(alloc, m.type_ref.named.interface.qualified_name);
        defer alloc.free(ref);
        try s.writer.print("int32_t {s}_set_{s}({s} *self, {s} borrowed);\n", .{ name, m.name, name, ref });
    }
    return s.toOwnedSlice();
}
pub fn configZig(alloc: std.mem.Allocator, cfg: *const ir.Struct, name: []const u8, cname: []const u8) ![]u8 {
    try validateConfig(cfg);
    var s: std.Io.Writer.Allocating = .init(alloc);
    errdefer s.deinit();
    try s.writer.print("pub const {s} = extern struct {{\n", .{name});
    for (cfg.members) |m| {
        const ref = try std.mem.replaceOwned(u8, alloc, m.type_ref.named.interface.qualified_name, "::", ".");
        defer alloc.free(ref);
        try s.writer.print(" {s}: ?*{s} = null,\n", .{ m.name, ref });
    }
    try s.writer.print("}};\npub export fn {s}_init(self: *{s}) void {{ self.* = .{{}}; }}\n", .{ cname, name });
    try s.writer.print("pub export fn {s}_fini(self: *{s}) void {{\n const old = self.*; self.* = .{{}};\n", .{ cname, name });
    for (cfg.members) |m| try s.writer.print(" if (old.{s}) |v| v.release(v.owner);\n", .{m.name});
    try s.writer.writeAll("}\n");
    for (cfg.members) |m| {
        const ref = try std.mem.replaceOwned(u8, alloc, m.type_ref.named.interface.qualified_name, "::", ".");
        defer alloc.free(ref);
        try s.writer.print("pub export fn {s}_set_{s}(self: *{s}, borrowed: ?*{s}) i32 {{\n if (self.{s} == borrowed) return 0;\n if (borrowed) |v| {{ const rc = v.retain(v.owner); if (rc != 0) return rc; }}\n const old = self.{s}; self.{s} = borrowed; if (old) |v| v.release(v.owner); return 0;\n}}\n", .{ cname, m.name, name, ref, m.name, m.name, m.name });
    }
    try s.writer.print("pub export fn {s}_clone(dst: *{s}, src: *const {s}) i32 {{\n", .{ cname, name, name });
    for (cfg.members) |m| try s.writer.print(" if (dst.{s} != null) return -1;\n", .{m.name});
    try s.writer.print(" var tmp: {s} = .{{}};\n", .{name});
    for (cfg.members) |m| try s.writer.print(" {{ const rc = {s}_set_{s}(&tmp, src.{s}); if (rc != 0) {{ {s}_fini(&tmp); return rc; }} }}\n", .{ cname, m.name, m.name, cname });
    try s.writer.writeAll(" dst.* = tmp; return 0;\n}\n");
    return s.toOwnedSlice();
}
