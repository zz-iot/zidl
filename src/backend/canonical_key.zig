//! Key-holder projection and sizing use resolved IR IDs, separate from wire samples.
//! Member-ID fallbacks support manually constructed IR only.

const std = @import("std");
const ir = @import("../ir/root.zig");
const wire = @import("cdr_skip.zig");

pub const Field = struct {
    member: *const ir.StructMember,
    owner_name: []const u8,
    owner: *const ir.Struct,
    index: usize,
    base_depth: usize,
    id: u32,
    ordinal: usize,
};

fn collect(alloc: std.mem.Allocator, s: *const ir.Struct, depth: usize, result: *std.ArrayList(Field)) !void {
    if (depth > 64) return error.RecursiveKeyInheritance;
    if (s.base) |base| switch (base) {
        .struct_ => |parent| try collect(alloc, parent, depth + 1, result),
        else => return error.UnsupportedCanonicalKeyType,
    };
    for (s.members, 0..) |*member, index| try result.append(alloc, .{
        .member = member,
        .owner_name = s.qualified_name,
        .owner = s,
        .index = index,
        .base_depth = depth,
        .id = member.annotations.memberId(@intCast(index)),
        .ordinal = result.items.len,
    });
}

pub fn wireFields(alloc: std.mem.Allocator, s: *const ir.Struct, projection: bool) ![]Field {
    var result = std.ArrayList(Field).empty;
    errdefer result.deinit(alloc);
    try collect(alloc, s, 0, &result);
    var has_key = false;
    for (result.items) |field| has_key = has_key or field.member.annotations.is_key;
    if (projection and has_key) {
        var count: usize = 0;
        for (result.items) |field| if (field.member.annotations.is_key) {
            result.items[count] = field;
            count += 1;
        };
        result.items.len = count;
    }
    return result.toOwnedSlice(alloc);
}

pub fn zigMemberPath(alloc: std.mem.Allocator, field: Field) ![]u8 {
    var path = std.ArrayList(u8).empty;
    errdefer path.deinit(alloc);
    for (0..field.base_depth) |_| try path.appendSlice(alloc, "_base.");
    try path.appendSlice(alloc, field.member.name);
    return path.toOwnedSlice(alloc);
}

pub fn fields(alloc: std.mem.Allocator, s: *const ir.Struct) ![]Field {
    const members = try wireFields(alloc, s, true);
    std.mem.sort(Field, members, {}, struct {
        fn less(_: void, a: Field, b: Field) bool {
            return if (a.id == b.id) a.ordinal < b.ordinal else a.id < b.id;
        }
    }.less);
    return members;
}

const Validator = struct {
    alloc: std.mem.Allocator,
    active: [128]?ir.TypeDecl = @splat(null),
    depth: usize = 0,

    fn visit(self: *Validator, tr: ir.TypeRef) anyerror!bool {
        return switch (tr) {
            .base => |b| b != .long_double and wire.baseWireSize(b) != null,
            .string, .wstring, .fixed_pt => true,
            .sequence => |seq| self.visit(seq.element.*),
            .map => false, // XTypes 1.3 §7.2.2.4.4.4.8 excludes maps from keys.
            .named => |td| blk: {
                for (self.active[0..self.depth]) |old| if (old) |value| {
                    if (std.meta.activeTag(value) == std.meta.activeTag(td) and switch (td) {
                        inline else => |p, tag| @intFromPtr(p) == @intFromPtr(@field(value, @tagName(tag))),
                    }) break :blk true;
                };
                if (self.depth == self.active.len) break :blk false;
                self.active[self.depth] = td;
                self.depth += 1;
                defer self.depth -= 1;
                break :blk switch (td) {
                    .struct_ => |s| struct_blk: {
                        const members = try fields(self.alloc, s);
                        defer self.alloc.free(members);
                        for (members) |field| {
                            if (field.member.annotations.is_optional or !try self.visit(field.member.type_ref)) break :struct_blk false;
                        }
                        break :struct_blk true;
                    },
                    .union_ => |u| union_blk: {
                        if (!try self.visit(u.discriminant)) break :union_blk false;
                        for (u.cases) |cas| {
                            if (cas.annotations.is_key or cas.annotations.is_optional or !try self.visit(cas.type_ref)) break :union_blk false;
                        }
                        break :union_blk true;
                    },
                    .typedef => |t| self.visit(t.type_ref),
                    .enum_, .bitmask => true,
                    else => false,
                };
            },
        };
    }
};

pub fn supported(alloc: std.mem.Allocator, tr: ir.TypeRef) !bool {
    var validator = Validator{ .alloc = alloc };
    return validator.visit(tr) catch |err| {
        if (err == error.RecursiveKeyInheritance) return false;
        return err;
    };
}

/// Element width for the fixed-width non-primitive collection subset.
pub fn fixedCollectionElementWidth(tr: ir.TypeRef) ?usize {
    const element = wire.resolveAlias(tr);
    return switch (element) {
        .named => |td| switch (td) {
            .enum_, .bitmask => wire.typeRefPrimWireSize(element),
            else => null,
        },
        else => null,
    };
}

/// XCDR2 enum/bitmask arrays retain their collection DHEADER in a FINAL
/// canonical key holder. Flatten member dimensions and array typedefs into
/// one extent; the streaming hash writer must know the payload size up front.
/// Other non-primitive collections require a separate variable-size plan.
pub fn fixedArrayDelimiterSize(tr: ir.TypeRef, dims: []const u64) !?u32 {
    if (dims.len == 0 and wire.arrayTypedefOf(tr) == null) return null;
    const element = wire.arrayInnermost(tr);
    const width = switch (element) {
        .named => |td| switch (td) {
            .enum_, .bitmask => wire.typeRefPrimWireSize(element).?,
            else => return null,
        },
        else => return null,
    };
    var size: u64 = width;
    for (dims) |dim| size = std.math.mul(u64, size, dim) catch return error.CanonicalArrayExtentOverflow;
    var current = tr;
    while (wire.arrayTypedefOf(current)) |array| {
        for (array.dimensions) |dim| size = std.math.mul(u64, size, dim) catch return error.CanonicalArrayExtentOverflow;
        current = array.type_ref;
    }
    return std.math.cast(u32, size) orelse error.CanonicalArrayExtentOverflow;
}

// Saturation at 17 is sufficient for the <=16 policy. Avoid usize arithmetic
// overflow, huge bound loops, and guessing from the currently supplied value.
const Maximum = struct {
    alloc: std.mem.Allocator,
    depth: usize = 0,

    fn add(pos: usize, size: u64) usize {
        return @intCast(@min(@as(u64, 17), @as(u64, pos) + @min(size, 17)));
    }
    fn primitive(pos: usize, size: usize) usize {
        const alignment = @min(size, 4);
        return add(add(pos, (alignment - pos % alignment) % alignment), size);
    }
    fn repeat(self: *Maximum, tr: ir.TypeRef, dims: []const u64, count: u64, start: usize) anyerror!usize {
        var pos = start;
        var i: u64 = 0;
        while (i < count and pos <= 16) : (i += 1) {
            const next = try self.array(tr, dims, pos);
            if (next == pos) break; // Zero-size elements remain zero at this origin.
            pos = next;
        }
        return pos;
    }
    fn array(self: *Maximum, tr: ir.TypeRef, dims: []const u64, pos: usize) anyerror!usize {
        if (try fixedArrayDelimiterSize(tr, dims)) |size| return add(primitive(pos, 4), size);
        if (dims.len != 0) return self.repeat(tr, dims[1..], dims[0], pos);
        return self.value(tr, pos);
    }
    fn value(self: *Maximum, tr: ir.TypeRef, start: usize) anyerror!usize {
        if (start > 16) return 17;
        if (self.depth >= 128) return 17; // A recursively expanding holder is unbounded.
        self.depth += 1;
        defer self.depth -= 1;
        return switch (tr) {
            .base => |b| primitive(start, wire.baseWireSize(b).?),
            .string => |bound| if (bound) |n| add(primitive(start, 4), @min(n, 17) + 1) else 17,
            .wstring => |bound| if (bound) |n| add(primitive(start, 4), @min(n, 17) * 2) else 17,
            .fixed_pt => |f| add(start, (@as(u64, f.digits) + 2) / 2),
            .sequence => |seq| self.repeat(seq.element.*, &.{}, seq.bound orelse std.math.maxInt(u64), primitive(if (fixedCollectionElementWidth(seq.element.*) != null) primitive(start, 4) else start, 4)),
            .named => |td| switch (td) {
                .struct_ => |s| blk: {
                    const members = try fields(self.alloc, s);
                    defer self.alloc.free(members);
                    var pos = start;
                    for (members) |field| {
                        pos = try self.array(field.member.type_ref, field.member.dimensions, pos);
                        if (pos > 16) break;
                    }
                    break :blk pos;
                },
                .union_ => |u| blk: {
                    const disc_end = try self.value(u.discriminant, start);
                    var end = disc_end;
                    for (u.cases) |cas| end = @max(end, try self.array(cas.type_ref, cas.dimensions, disc_end));
                    break :blk end;
                },
                .typedef => |t| self.array(t.type_ref, t.dimensions, start),
                .enum_, .bitmask => primitive(start, wire.typeRefPrimWireSize(tr).?),
                else => unreachable, // supported() validates the complete holder first.
            },
            .map => unreachable,
        };
    }
};

pub fn forceMd5(alloc: std.mem.Allocator, s: *const ir.Struct) !bool {
    const tr: ir.TypeRef = .{ .named = .{ .struct_ = @constCast(s) } };
    if (!try supported(alloc, tr)) return error.UnsupportedCanonicalKeyType;
    var maximum = Maximum{ .alloc = alloc };
    return try maximum.value(tr, 0) > 16;
}

/// Common C/C++ key-holder emitter. Language mappings supply their existing
/// primitive/container accessors; this path never emits aggregate headers.
pub fn emitCStruct(self: anytype, s: *const ir.Struct, name: []const u8, value_type: []const u8, comptime cpp: bool, has_key: bool) !void {
    if (has_key) _ = try forceMd5(self.alloc, s);
    try self.print("int {s}_serialize_key_holder(ZidlCdrWriter *_w, const {s} *_v) {{\n", .{ name, value_type });
    try self.writeI("(void)_w; (void)_v;\n");
    if (!try supported(self.alloc, .{ .named = .{ .struct_ = @constCast(s) } })) {
        try self.writeI("return ZIDL_CDR_INVALID;\n");
    } else {
        try self.writeI("int _rc = ZIDL_CDR_OK;\n");
        const members = try fields(self.alloc, s);
        defer self.alloc.free(members);
        const old = self.canonical_key;
        self.canonical_key = true;
        defer self.canonical_key = old;
        for (members) |field| {
            const access = if (cpp) blk: {
                break :blk if (field.base_depth == 0)
                    try std.fmt.allocPrint(self.alloc, "_v->{s}", .{field.member.name})
                else
                    try std.fmt.allocPrint(self.alloc, "static_cast<const ::{s} *>(_v)->{s}", .{ field.owner_name, field.member.name });
            } else blk: {
                var path = std.ArrayList(u8).empty;
                defer path.deinit(self.alloc);
                try path.appendSlice(self.alloc, "_v->");
                for (0..field.base_depth) |_| try path.appendSlice(self.alloc, "_base.");
                break :blk try std.fmt.allocPrint(self.alloc, "{s}{s}", .{ path.items, field.member.name });
            };
            defer self.alloc.free(access);
            if (field.member.dimensions.len != 0) {
                try self.emitWriteArray(field.member.type_ref, access, field.member.dimensions, 0);
            } else try self.emitWriteForTypeRef(field.member.type_ref, field.member.name, access);
        }
        try self.writeI("return _rc;\n");
    }
    try self.write("}\n\n");
}

pub fn emitCUnion(self: anytype, u: *const ir.Union, name: []const u8, value_type: []const u8, comptime cpp: bool) !void {
    try self.print("int {s}_serialize_key_holder(ZidlCdrWriter *_w, const {s} *_v) {{\n", .{ name, value_type });
    try self.writeI("(void)_w; (void)_v;\n");
    if (!try supported(self.alloc, .{ .named = .{ .union_ = @constCast(u) } })) {
        try self.writeI("return ZIDL_CDR_INVALID;\n");
    } else {
        const old = self.canonical_key;
        self.canonical_key = true;
        defer self.canonical_key = old;
        try self.writeI("int _rc = ZIDL_CDR_OK;\n");
        if (cpp) try self.emitDiscWriteCpp(u.discriminant, "_v->_d()") else try self.emitDiscWriteC(u.discriminant, "_v->_d");
        try self.writeI(if (cpp) "switch (_v->_d()) {\n" else "switch (_v->_d) {\n");
        self.indent_depth += 1;
        var has_default = false;
        for (u.cases) |cas| {
            for (cas.labels) |label| if (label == .default) {
                has_default = true;
            };
            if (cas.labels.len == 0) has_default = true;
            if (cpp) try self.emitUnionCaseLabelLinesCpp(u.discriminant, cas) else try self.emitUnionCaseLabelLinesC(u.discriminant, cas);
            if (cpp) try self.writeI("{\n");
            self.indent_depth += 1;
            const access = if (cpp)
                (if (cas.dimensions.len != 0) try std.fmt.allocPrint(self.alloc, "_v->{s}()", .{cas.name}) else try self.emitUnionCaseSerializeAccess(cas))
            else
                try std.fmt.allocPrint(self.alloc, "_v->_u.{s}", .{cas.name});
            defer self.alloc.free(access);
            if (cas.dimensions.len != 0) {
                try self.emitWriteArray(cas.type_ref, access, cas.dimensions, 0);
            } else try self.emitWriteForTypeRef(cas.type_ref, cas.name, access);
            try self.writeI("break;\n");
            self.indent_depth -= 1;
            if (cpp) try self.writeI("}\n");
        }
        if (!has_default) try self.writeI("default: break;\n");
        self.indent_depth -= 1;
        try self.writeI("}\nreturn _rc;\n");
    }
    try self.write("}\n\n");
}

test "maximum key policy is based on bounds, including zero-sized elements and huge arrays" {
    const testing = std.testing;
    var members = [_]ir.StructMember{.{ .name = "key", .span = undefined, .type_ref = .{ .string = 11 }, .dimensions = &.{}, .annotations = .{ .is_key = true } }};
    const s = ir.Struct{ .name = "S", .qualified_name = "S", .span = undefined, .members = &members, .annotations = .{} };
    try testing.expect(!try forceMd5(testing.allocator, &s));
    members[0].type_ref = .{ .string = 12 };
    try testing.expect(try forceMd5(testing.allocator, &s));
    members[0].type_ref = .{ .wstring = 6 };
    try testing.expect(!try forceMd5(testing.allocator, &s));
    members[0].type_ref = .{ .wstring = 7 };
    try testing.expect(try forceMd5(testing.allocator, &s));
    const octet: ir.TypeRef = .{ .base = .octet };
    members[0].type_ref = .{ .sequence = .{ .element = &octet, .bound = 12 } };
    try testing.expect(!try forceMd5(testing.allocator, &s));
    members[0].type_ref.sequence.bound = 13;
    try testing.expect(try forceMd5(testing.allocator, &s));
    const empty = ir.Struct{ .name = "Empty", .qualified_name = "Empty", .span = undefined, .members = &.{}, .annotations = .{} };
    const empty_ref: ir.TypeRef = .{ .named = .{ .struct_ = @constCast(&empty) } };
    members[0].type_ref = .{ .sequence = .{ .element = &empty_ref, .bound = null } };
    try testing.expect(!try forceMd5(testing.allocator, &s));
    members[0].type_ref = octet;
    members[0].dimensions = &.{ std.math.maxInt(u64), std.math.maxInt(u64) };
    try testing.expect(try forceMd5(testing.allocator, &s));
}

test "key-holder projection sorts IDs and includes unannotated nested members recursively" {
    const testing = std.testing;
    const base_members = [_]ir.StructMember{.{ .name = "base", .span = undefined, .type_ref = .{ .base = .long }, .dimensions = &.{}, .annotations = .{ .is_key = true, .id = 20 } }};
    var base = ir.Struct{ .name = "Base", .qualified_name = "Base", .span = undefined, .members = &base_members, .annotations = .{} };
    const members = [_]ir.StructMember{
        .{ .name = "ignored", .span = undefined, .type_ref = .{ .string = null }, .dimensions = &.{}, .annotations = .{} },
        .{ .name = "derived", .span = undefined, .type_ref = .{ .base = .octet }, .dimensions = &.{}, .annotations = .{ .is_key = true, .id = 10 } },
    };
    const derived = ir.Struct{ .name = "Derived", .qualified_name = "Derived", .span = undefined, .base = .{ .struct_ = &base }, .members = &members, .annotations = .{} };
    const projected = try fields(testing.allocator, &derived);
    defer testing.allocator.free(projected);
    try testing.expectEqual(@as(usize, 2), projected.len);
    try testing.expectEqualStrings("derived", projected[0].member.name);
    try testing.expectEqualStrings("base", projected[1].member.name);
    try testing.expectEqual(@as(usize, 1), projected[1].base_depth);
    try testing.expect(!try forceMd5(testing.allocator, &derived));
    base.members = &.{ .{ .name = "a", .span = undefined, .type_ref = .{ .base = .octet }, .dimensions = &.{}, .annotations = .{} }, .{ .name = "b", .span = undefined, .type_ref = .{ .base = .unsigned_long_long }, .dimensions = &.{}, .annotations = .{} } };
    try testing.expect(!try forceMd5(testing.allocator, &base));
}

test "array key delimiters flatten typedefs, affect MD5 policy and reject overflow" {
    const testing = std.testing;
    var enumeration = ir.Enum{ .name = "E", .qualified_name = "E", .span = undefined, .enumerators = &.{}, .annotations = .{} };
    const element: ir.TypeRef = .{ .named = .{ .enum_ = &enumeration } };
    var row = ir.Typedef{ .name = "Row", .qualified_name = "Row", .span = undefined, .type_ref = element, .dimensions = &.{2}, .raw = &.{} };
    var alias = ir.Typedef{ .name = "Alias", .qualified_name = "Alias", .span = undefined, .type_ref = .{ .named = .{ .typedef = &row } }, .dimensions = &.{}, .raw = &.{} };
    const alias_ref: ir.TypeRef = .{ .named = .{ .typedef = &alias } };
    try testing.expectEqual(@as(?u32, 16), try fixedArrayDelimiterSize(alias_ref, &.{2}));
    try testing.expectEqual(@as(?u32, 8), try fixedArrayDelimiterSize(alias_ref, &.{}));
    try testing.expectEqual(@as(?u32, null), try fixedArrayDelimiterSize(element, &.{}));
    try testing.expectEqual(@as(?u32, null), try fixedArrayDelimiterSize(.{ .base = .unsigned_long }, &.{ 2, 2 }));
    try testing.expectError(error.CanonicalArrayExtentOverflow, fixedArrayDelimiterSize(element, &.{1073741824}));
    try testing.expectError(error.CanonicalArrayExtentOverflow, fixedArrayDelimiterSize(element, &.{ std.math.maxInt(u64), 2 }));
    var members = [_]ir.StructMember{.{ .name = "key", .span = undefined, .type_ref = element, .dimensions = &.{3}, .annotations = .{ .is_key = true } }};
    const holder = ir.Struct{ .name = "S", .qualified_name = "S", .span = undefined, .members = &members, .annotations = .{} };
    try testing.expect(!try forceMd5(testing.allocator, &holder)); // 4 + 3*4 = 16
    members[0].dimensions = &.{4};
    try testing.expect(try forceMd5(testing.allocator, &holder)); // 4 + 4*4 = 20
}

test "sequence key delimiter contributes to schema maximum through enum aliases" {
    const testing = std.testing;
    var enumeration = ir.Enum{ .name = "E", .qualified_name = "E", .span = undefined, .enumerators = &.{}, .annotations = .{} };
    var alias = ir.Typedef{ .name = "Alias", .qualified_name = "Alias", .span = undefined, .type_ref = .{ .named = .{ .enum_ = &enumeration } }, .dimensions = &.{}, .raw = &.{} };
    const element: ir.TypeRef = .{ .named = .{ .typedef = &alias } };
    var members = [_]ir.StructMember{.{ .name = "key", .span = undefined, .type_ref = .{ .sequence = .{ .element = &element, .bound = 2 } }, .dimensions = &.{}, .annotations = .{ .is_key = true } }};
    const holder = ir.Struct{ .name = "S", .qualified_name = "S", .span = undefined, .members = &members, .annotations = .{} };
    try testing.expectEqual(@as(?usize, 4), fixedCollectionElementWidth(element));
    try testing.expect(!try forceMd5(testing.allocator, &holder));
    members[0].type_ref.sequence.bound = 3;
    try testing.expect(try forceMd5(testing.allocator, &holder));
}
