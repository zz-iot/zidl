//! Reject value families that have declarations but no native CDR codec.
const std = @import("std");
const ir = @import("../ir/root.zig");

pub fn validate(alloc: std.mem.Allocator, spec: *const ir.Spec) !void {
    var visitor = Visitor{ .alloc = alloc };
    defer visitor.seen.deinit(alloc);
    try visitor.items(spec.items);
}

const Visitor = struct {
    alloc: std.mem.Allocator,
    seen: std.AutoHashMapUnmanaged(usize, void) = .empty,

    fn items(self: *Visitor, list: []const ir.ModuleItem) anyerror!void {
        for (list) |item| switch (item) {
            .module => |m| try self.items(m.items),
            .type_decl => |td| switch (td) {
                // Native and interface declarations are valid opaque binding
                // declarations. They are rejected only as encoded value fields.
                .native, .interface => {},
                else => try self.named(td),
            },
            else => {},
        };
    }

    fn named(self: *Visitor, td: ir.TypeDecl) anyerror!void {
        const address = switch (td) {
            inline else => |p| @intFromPtr(p),
        };
        const entry = try self.seen.getOrPut(self.alloc, address);
        if (entry.found_existing) return;
        switch (td) {
            .struct_ => |s| {
                if (s.base) |base| try self.named(base);
                for (s.members) |m| try self.ref(m.type_ref);
            },
            .union_ => |u| {
                try self.ref(u.discriminant);
                for (u.cases) |c| try self.ref(c.type_ref);
            },
            .exception => |e| for (e.members) |m| try self.ref(m.type_ref),
            .typedef => |t| try self.ref(t.type_ref),
            .native, .interface => return error.UnsupportedOpaqueCdrValue,
            else => {},
        }
    }

    fn ref(self: *Visitor, tr: ir.TypeRef) anyerror!void {
        switch (tr) {
            .base => |b| switch (b) {
                .any, .object, .value_base => return error.UnsupportedDynamicCdrValue,
                else => {},
            },
            .named => |td| try self.named(td),
            .sequence => |s| try self.ref(s.element.*),
            .map => |m| {
                try self.ref(m.key.*);
                try self.ref(m.value.*);
            },
            else => {},
        }
    }
};
