//! Reject unsupported codec values and backend-specific container mappings.
const std = @import("std");
const ir = @import("../ir/root.zig");

pub fn validate(alloc: std.mem.Allocator, spec: *const ir.Spec) !void {
    try validateWithOptions(alloc, spec, .{});
}

pub const Options = struct {
    reject_dynamic: bool = true,
    reject_long_double: bool = true,
    zig_map_keys: bool = false,
};

pub fn validateWithOptions(alloc: std.mem.Allocator, spec: *const ir.Spec, opts: Options) !void {
    var visitor = Visitor{ .alloc = alloc, .opts = opts };
    defer visitor.seen.deinit(alloc);
    try visitor.items(spec.items);
}

const Visitor = struct {
    alloc: std.mem.Allocator,
    opts: Options,
    seen: std.AutoHashMapUnmanaged(usize, void) = .empty,

    fn items(self: *Visitor, list: []const ir.ModuleItem) anyerror!void {
        for (list) |item| switch (item) {
            .module => |m| try self.items(m.items),
            .type_decl => |td| switch (td) {
                // Native and interface declarations are valid opaque binding
                // declarations. They are rejected only as encoded value fields.
                .native, .interface => {},
                .typedef => |td_alias| {
                    // A standalone alias is a binding declaration, not a codec
                    // root. Reaching it from an encoded field still validates
                    // its complete value family below. Container mapping checks
                    // apply even to declarations and use a separate seen set.
                    if (self.opts.zig_map_keys) {
                        var declarations = Visitor{ .alloc = self.alloc, .opts = .{ .reject_dynamic = false, .reject_long_double = false, .zig_map_keys = true } };
                        defer declarations.seen.deinit(self.alloc);
                        try declarations.ref(td_alias.type_ref);
                    }
                },
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
            .native, .interface => if (self.opts.reject_dynamic) {
                return error.UnsupportedOpaqueCdrValue;
            },
            else => {},
        }
    }

    fn ref(self: *Visitor, tr: ir.TypeRef) anyerror!void {
        switch (tr) {
            .base => |b| switch (b) {
                .any, .object, .value_base => if (self.opts.reject_dynamic) {
                    return error.UnsupportedDynamicCdrValue;
                },
                .long_double => if (self.opts.reject_long_double) {
                    return error.UnsupportedLongDoubleCdrValue;
                },
                else => {},
            },
            .named => |td| try self.named(td),
            .sequence => |s| try self.ref(s.element.*),
            .map => |m| {
                if (self.opts.zig_map_keys) switch (@import("cdr_skip.zig").resolveAlias(m.key.*)) {
                    .string => |bound| if (bound != null) {
                        return error.UnsupportedZigMapKey;
                    },
                    .base => |b| switch (b) {
                        .float, .double, .long_double, .any, .object, .value_base => return error.UnsupportedZigMapKey,
                        else => {},
                    },
                    .named => |td| switch (td) {
                        .enum_, .bitmask => {},
                        else => return error.UnsupportedZigMapKey,
                    },
                    else => return error.UnsupportedZigMapKey,
                };
                try self.ref(m.key.*);
                try self.ref(m.value.*);
            },
            else => {},
        }
    }
};

test "binding aliases do not imply wire codecs; encoded uses still reject" {
    const cases = [_]struct { source: []const u8, expected: ?anyerror }{
        .{ .source = "interface Handle {}; typedef sequence<Handle> Handles; struct S { long value; };", .expected = null },
        .{ .source = "interface Handle {}; typedef sequence<Handle> Handles; struct S { Handles values; };", .expected = error.UnsupportedOpaqueCdrValue },
        .{ .source = "typedef long double Wide; struct S { long value; };", .expected = null },
        .{ .source = "typedef long double Wide; struct S { Wide value; };", .expected = error.UnsupportedLongDoubleCdrValue },
        .{ .source = "typedef any Dynamic; struct S { Dynamic value; };", .expected = error.UnsupportedDynamicCdrValue },
    };
    for (cases) |case| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var parser = @import("../parser.zig").Parser.init(case.source, arena.allocator());
        const ast = try parser.parseSpecification();
        var analyzer = try @import("../semantic/root.zig").Analyzer.init(std.testing.allocator);
        defer analyzer.deinit();
        try analyzer.analyze(&ast);
        var spec = try ir.build(std.testing.allocator, &ast, analyzer.global_scope, &.{});
        defer spec.deinit();
        if (case.expected) |expected| try std.testing.expectError(expected, validate(std.testing.allocator, &spec)) else try validate(std.testing.allocator, &spec);
    }
}
