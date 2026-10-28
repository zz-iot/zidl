//! Schema-independent strict decoding for generated IDL configuration records.
//! The input tree is duck-typed; no parser, DDS semantics or file I/O dependency.
//! Values and presence/provenance are owned by a single arena, released on failure.
const std = @import("std");
const owned = @import("owned.zig");
pub const Spec = struct {
    kind: enum { scalar, string, sequence, array, enumeration, record, unsupported },
    bound: ?usize = null,
    element: ?*const Spec = null,
    enumerators: []const EnumValue = &.{},
};
pub const EnumValue = struct { name: []const u8, value: u64 };
pub const Location = struct { offset: usize = 0, line: usize = 1, column: usize = 1 };
pub const Diagnostic = struct {
    code: ?anyerror = null,
    location: Location = .{},
    path: [512]u8 = undefined,
    path_len: usize = 0,
    path_truncated: bool = false,
    pub fn fieldPath(self: *const @This()) []const u8 {
        return self.path[0..self.path_len];
    }
};
pub const Options = struct {
    /// Explicit convention: a table may author a record sequence by injecting
    /// each table key into this string member. Null requires arrays of records.
    named_field: ?[]const u8 = null,
    conditional_members: bool = false,
    unknown_fields: enum { reject, ignore } = .reject,
    enum_matching: enum { canonical, ascii_case_insensitive } = .canonical,
    capture_element_presence: bool = true,
    capture_skipped: bool = true,
    max_skipped: usize = 65536,
    max_depth: usize = 64,
    max_elements: usize = 65536,
    max_string_bytes: usize = 4096,
    max_path_bytes: usize = 4 * 1024 * 1024,
};
pub const Presence = struct {
    path: []const []const u8,
    input_path: []const []const u8,
    conditional: bool,
    location: Location,
    kind: enum { value, record, sequence, named_collection },
};
pub const Skipped = struct {
    path: []const []const u8,
    input_path: []const []const u8,
    location: Location,
    reason: enum { conditional_unknown, compatibility_unknown },
};
pub fn Decoded(comptime T: type) type {
    return struct {
        arena: std.heap.ArenaAllocator,
        value: T,
        presence: []const Presence,
        skipped: []const Skipped,
        skipped_count: usize,
        skipped_complete: bool,
        pub fn source(self: *const @This(), path: []const []const u8) ?Location {
            for (self.presence) |entry| {
                if (entry.path.len != path.len) continue;
                var same = true;
                for (entry.path, path) |a, b| if (!std.mem.eql(u8, a, b)) {
                    same = false;
                    break;
                };
                if (same) return entry.location;
            }
            return null;
        }
        pub fn collectionIsNamed(self: *const @This(), path: []const []const u8) bool {
            for (self.presence) |entry| {
                if (entry.path.len != path.len) continue;
                var same = true;
                for (entry.path, path) |a, b| if (!std.mem.eql(u8, a, b)) {
                    same = false;
                    break;
                };
                if (same) return entry.kind == .named_collection;
            }
            return false;
        }
        pub fn isPresent(self: *const @This(), path: []const []const u8) bool {
            return self.source(path) != null;
        }
        pub fn deinit(self: *@This()) void {
            self.arena.deinit();
            self.* = undefined;
        }
    };
}
pub fn decode(comptime T: type, a: std.mem.Allocator, table: anytype, options: Options, diag: *Diagnostic) !Decoded(T) {
    return decodeFrom(T, a, .{}, table, options, diag);
}
/// Prepares an independent replacement; base and table are borrowed and unchanged.
pub fn decodeFrom(comptime T: type, a: std.mem.Allocator, base: T, table: anytype, options: Options, diag: *Diagnostic) !Decoded(T) {
    diag.* = .{};
    var arena = std.heap.ArenaAllocator.init(a);
    errdefer arena.deinit();
    var ctx = Context{ .a = arena.allocator(), .options = options, .diag = diag };
    const Node = @typeInfo(@TypeOf(table.get(""))).optional.child;
    const node = Node{ .value = .{ .table = table }, .location = table.location };
    const value = try ctx.read(T, .{ .kind = .record }, node, null, base);
    const presence = try ctx.presence.toOwnedSlice(ctx.a);
    const skipped = try ctx.skipped.toOwnedSlice(ctx.a);
    return .{ .arena = arena, .value = value, .presence = presence, .skipped = skipped, .skipped_count = ctx.skipped_count, .skipped_complete = options.capture_skipped or ctx.skipped_count == 0 };
}
fn initial(comptime T: type) T {
    return switch (@typeInfo(T)) {
        .@"struct" => .{},
        .optional => null,
        .pointer => |p| if (p.size == .slice) &.{} else "".ptr,
        else => std.mem.zeroes(T),
    };
}
const Injected = struct { field: []const u8, value: []const u8 };
const Context = struct {
    a: std.mem.Allocator,
    options: Options,
    diag: *Diagnostic,
    path: std.ArrayList([]const u8) = .empty,
    input_path: std.ArrayList([]const u8) = .empty,
    skipped: std.ArrayList(Skipped) = .empty,
    skipped_count: usize = 0,
    element_depth: usize = 0,
    presence: std.ArrayList(Presence) = .empty,
    count: usize = 0,
    path_bytes: usize = 0,
    fn fail(ctx: *Context, err: anyerror, node: anytype) anyerror {
        ctx.diag.code = err;
        ctx.diag.location = .{ .offset = node.location.offset, .line = node.location.line, .column = node.location.column };
        ctx.diag.path_len = 0;
        for (ctx.input_path.items, 0..) |part, i| {
            if (i != 0) ctx.appendDiagnostic(".");
            ctx.appendDiagnostic(part);
        }
        return err;
    }
    fn appendDiagnostic(ctx: *Context, text: []const u8) void {
        const n = @min(text.len, ctx.diag.path.len - ctx.diag.path_len);
        @memcpy(ctx.diag.path[ctx.diag.path_len..][0..n], text[0..n]);
        ctx.diag.path_len += n;
        if (n != text.len) ctx.diag.path_truncated = true;
    }
    fn push(ctx: *Context, name: []const u8) !void {
        try ctx.pushMember(name, name);
    }
    fn pushMember(ctx: *Context, name: []const u8, input: []const u8) !void {
        try ctx.path.append(ctx.a, name);
        try ctx.input_path.append(ctx.a, input);
    }
    fn pop(ctx: *Context) void {
        ctx.path.items.len -= 1;
        ctx.input_path.items.len -= 1;
    }
    fn work(ctx: *Context, node: anytype) !void {
        if (ctx.path.items.len > ctx.options.max_depth or ctx.count >= ctx.options.max_elements) return ctx.fail(error.LimitExceeded, node);
        ctx.count += 1;
    }
    fn copyPath(ctx: *Context, parts: []const []const u8, node: anytype) ![]const []const u8 {
        for (parts) |part| {
            if (part.len > ctx.options.max_string_bytes or part.len > ctx.options.max_path_bytes -| ctx.path_bytes)
                return ctx.fail(error.LimitExceeded, node);
            ctx.path_bytes += part.len;
        }
        const path = try ctx.a.alloc([]const u8, parts.len);
        for (parts, path) |part, *dest| dest.* = try ctx.a.dupe(u8, part);
        return path;
    }
    fn conditional(ctx: *Context) bool {
        for (ctx.path.items, ctx.input_path.items) |a, b| if (!std.mem.eql(u8, a, b)) return true;
        return false;
    }
    fn remember(ctx: *Context, comptime spec: Spec, node: anytype) !void {
        if (!ctx.options.capture_element_presence and ctx.element_depth > 0) return;
        const path = try ctx.copyPath(ctx.path.items, node);
        const marked = ctx.conditional();
        try ctx.presence.append(ctx.a, .{ .path = path, .input_path = if (marked) try ctx.copyPath(ctx.input_path.items, node) else path, .conditional = marked, .kind = if (spec.kind == .record) .record else if (spec.kind == .sequence or spec.kind == .array) (if (node.value == .table) .named_collection else .sequence) else .value, .location = .{ .offset = node.location.offset, .line = node.location.line, .column = node.location.column } });
    }
    fn skip(ctx: *Context, node: anytype, marked: bool) !void {
        if (ctx.skipped_count >= ctx.options.max_skipped) return ctx.fail(error.LimitExceeded, node);
        ctx.skipped_count += 1;
        if (!ctx.options.capture_skipped) return;
        const path = try ctx.copyPath(ctx.path.items, node);
        try ctx.skipped.append(ctx.a, .{ .path = path, .input_path = if (ctx.conditional()) try ctx.copyPath(ctx.input_path.items, node) else path, .location = .{ .offset = node.location.offset, .line = node.location.line, .column = node.location.column }, .reason = if (marked) .conditional_unknown else .compatibility_unknown });
    }
    fn member(ctx: *Context, raw: []const u8, node: anytype) ![]const u8 {
        if (!ctx.options.conditional_members or raw.len == 0 or raw[0] != '_') return raw;
        if (raw.len == 1 or raw[1] == '_') return ctx.fail(error.InvalidConditionalName, node);
        return raw[1..];
    }
    fn schemaMembers(ctx: *Context, comptime T: type, node: anytype) !void {
        if (ctx.options.conditional_members) inline for (T.toml_fields) |field| {
            if (field.len > 0 and field[0] == '_') return ctx.fail(error.ConditionalNameCollision, node);
        };
    }
    /// Copies only public generated fields; all storage belongs to this arena.
    fn copy(ctx: *Context, comptime T: type, comptime spec: Spec, value: T, node: anytype) anyerror!T {
        try ctx.work(node);
        if (@typeInfo(T) == .optional) return if (value) |v| try ctx.copy(@typeInfo(T).optional.child, spec, v, node) else null;
        switch (spec.kind) {
            .scalar, .enumeration => return value,
            .unsupported => return ctx.fail(error.UnsupportedType, node),
            .string => switch (@typeInfo(T)) {
                .pointer => |p| {
                    const text = if (p.size == .slice) value else std.mem.span(value);
                    if (text.len > ctx.options.max_string_bytes) return ctx.fail(error.LimitExceeded, node);
                    if (p.size == .slice) return try ctx.a.dupe(u8, text);
                    return (try ctx.a.dupeSentinel(u8, text, 0)).ptr;
                },
                else => return value,
            },
            .record => {
                if (@hasField(T, "_base")) return ctx.fail(error.UnsupportedType, node);
                try ctx.schemaMembers(T, node);
                var result: T = .{};
                inline for (T.toml_fields) |field| {
                    try ctx.push(field);
                    defer ctx.pop();
                    @field(result, field) = try ctx.copy(@FieldType(T, field), T.tomlSpec(field), @field(value, field), node);
                }
                return result;
            },
            .sequence, .array => {
                const E = if (spec.kind == .array) @typeInfo(T).array.child else owned.SeqElem(T);
                const src = if (spec.kind == .array) value[0..] else if (@hasField(T, "_buffer")) (if (value._buffer) |buf| buf[0..value._length] else if (value._length == 0) &.{} else return ctx.fail(error.InvalidValue, node)) else value.slice();
                if (src.len > ctx.options.max_elements -| ctx.count) return ctx.fail(error.LimitExceeded, node);
                var result: T = initial(T);
                const dest = if (spec.kind == .array) result[0..] else if (@hasField(T, "_buffer")) blk: {
                    const buf = try ctx.a.alloc(E, src.len);
                    result._buffer = buf.ptr;
                    result._length = @intCast(src.len);
                    result._maximum = @intCast(src.len);
                    result._release = false;
                    break :blk buf;
                } else blk: {
                    result.len = src.len;
                    break :blk result.buf[0..src.len];
                };
                for (src, dest, 0..) |v, *out, i| {
                    try ctx.push(try std.fmt.allocPrint(ctx.a, "{d}", .{i}));
                    defer ctx.pop();
                    out.* = try ctx.copy(E, spec.element.?.*, v, node);
                }
                return result;
            },
        }
    }
    fn read(ctx: *Context, comptime T: type, comptime spec: Spec, node: anytype, injected: ?Injected, base: T) anyerror!T {
        @setEvalBranchQuota(100000);
        try ctx.work(node);
        if (@typeInfo(T) == .optional) {
            const E = @typeInfo(T).optional.child;
            return try ctx.read(E, spec, node, injected, base orelse initial(E));
        }
        try ctx.remember(spec, node);
        switch (spec.kind) {
            .unsupported => return ctx.fail(error.UnsupportedType, node),
            .string => {
                if (node.value != .string) return ctx.fail(error.TypeMismatch, node);
                const text = node.value.string;
                if (std.mem.indexOfScalar(u8, text, 0) != null) return ctx.fail(error.InvalidValue, node);
                if (text.len > ctx.options.max_string_bytes) return ctx.fail(error.LimitExceeded, node);
                if (spec.bound) |bound| if (text.len > bound) return ctx.fail(error.OutOfRange, node);
                switch (@typeInfo(T)) {
                    .pointer => |p| {
                        if (p.size == .slice) return try ctx.a.dupe(u8, text);
                        if (p.size == .many and p.sentinel() != null) return (try ctx.a.dupeSentinel(u8, text, 0)).ptr;
                        return ctx.fail(error.UnsupportedType, node);
                    },
                    .@"struct" => {
                        var result: T = .{};
                        if (text.len > result.buf.len) return ctx.fail(error.OutOfRange, node);
                        @memcpy(result.buf[0..text.len], text);
                        result.len = text.len;
                        return result;
                    },
                    else => return ctx.fail(error.UnsupportedType, node),
                }
            },
            .scalar => switch (@typeInfo(T)) {
                .bool => return if (node.value == .boolean) node.value.boolean else ctx.fail(error.TypeMismatch, node),
                .int => {
                    if (node.value != .integer) return ctx.fail(error.TypeMismatch, node);
                    return std.math.cast(T, node.value.integer) orelse return ctx.fail(error.OutOfRange, node);
                },
                .float => {
                    const v: f64 = switch (node.value) {
                        .float => |v| v,
                        .integer => |v| @floatFromInt(v),
                        else => return ctx.fail(error.TypeMismatch, node),
                    };
                    const result: T = @floatCast(v);
                    if (!std.math.isFinite(result)) return ctx.fail(error.OutOfRange, node);
                    return result;
                },
                else => return ctx.fail(error.UnsupportedType, node),
            },
            .enumeration => {
                if (node.value != .string) return ctx.fail(error.TypeMismatch, node);
                inline for (spec.enumerators) |e| if (if (ctx.options.enum_matching == .ascii_case_insensitive) std.ascii.eqlIgnoreCase(e.name, node.value.string) else std.mem.eql(u8, e.name, node.value.string)) return @fromBackingInt(@intCast(e.value));
                return ctx.fail(error.InvalidEnum, node);
            },
            .record => {
                if (node.value != .table) return ctx.fail(error.TypeMismatch, node);
                if (@hasField(T, "_base")) return ctx.fail(error.UnsupportedType, node);
                try ctx.schemaMembers(T, node);
                const table = node.value.table;
                var members: std.StringHashMapUnmanaged([]const u8) = .empty;
                // Normalize and detect collisions before applying or skipping values.
                for (table.entries.keys()) |raw| {
                    try ctx.push(raw);
                    const field = try ctx.member(raw, table.get(raw).?);
                    try ctx.work(table.get(raw).?);
                    const g = try members.getOrPut(ctx.a, field);
                    if (g.found_existing) return ctx.fail(error.DuplicateSetting, table.get(raw).?);
                    g.value_ptr.* = raw;
                    ctx.pop();
                }
                for (table.entries.keys()) |raw| {
                    const field = try ctx.member(raw, table.get(raw).?);
                    var known = false;
                    inline for (T.toml_fields) |name| if (std.mem.eql(u8, field, name)) {
                        known = true;
                    };
                    if (!known) {
                        try ctx.pushMember(field, raw);
                        defer ctx.pop();
                        const marked = !std.mem.eql(u8, field, raw);
                        if (!marked and ctx.options.unknown_fields == .reject) return ctx.fail(error.UnknownField, table.get(raw).?);
                        try ctx.skip(table.get(raw).?, marked);
                    }
                }
                var result: T = .{};
                inline for (T.toml_fields) |field| {
                    const FT = @FieldType(T, field);
                    if (members.get(field)) |raw| {
                        const child = table.get(raw).?;
                        try ctx.pushMember(field, raw);
                        defer ctx.pop();
                        if (injected) |key| if (std.mem.eql(u8, field, key.field)) return ctx.fail(error.DuplicateName, child);
                        @field(result, field) = try ctx.read(FT, T.tomlSpec(field), child, null, @field(base, field));
                    } else if (injected != null and std.mem.eql(u8, field, injected.?.field)) {
                        const Node = @TypeOf(node);
                        try ctx.push(field);
                        defer ctx.pop();
                        @field(result, field) = try ctx.read(FT, T.tomlSpec(field), Node{ .value = .{ .string = injected.?.value }, .location = node.location }, null, initial(FT));
                    } else {
                        try ctx.push(field);
                        defer ctx.pop();
                        @field(result, field) = try ctx.copy(FT, T.tomlSpec(field), @field(base, field), node);
                    }
                }
                return result;
            },
            .sequence, .array => {
                const E = if (spec.kind == .array) @typeInfo(T).array.child else owned.SeqElem(T);
                const named = node.value == .table and ctx.options.named_field != null;
                if (!named and node.value != .array) return ctx.fail(error.TypeMismatch, node);
                if (named and spec.element.?.kind != .record) return ctx.fail(error.TypeMismatch, node);
                if (comptime spec.element.?.kind == .record) {
                    if (named) {
                        var found = false;
                        inline for (E.toml_fields) |field| if (std.mem.eql(u8, field, ctx.options.named_field.?)) {
                            found = true;
                        };
                        if (!found) return ctx.fail(error.UnsupportedType, node);
                    }
                }
                const len = if (named) node.value.table.entries.count() else node.value.array.len;
                if (len > ctx.options.max_elements -| ctx.count) return ctx.fail(error.LimitExceeded, node);
                if (spec.bound) |bound| if (len > bound) return ctx.fail(error.OutOfRange, node);
                var result: T = if (spec.kind == .array) std.mem.zeroes(T) else .{};
                const dest = if (spec.kind == .array) blk: {
                    if (len != @typeInfo(T).array.len) return ctx.fail(error.OutOfRange, node);
                    break :blk result[0..];
                } else if (@hasField(T, "_buffer")) blk: {
                    const buf = try ctx.a.alloc(E, len);
                    result._buffer = buf.ptr;
                    result._length = @intCast(len);
                    result._maximum = @intCast(len);
                    result._release = false;
                    break :blk buf;
                } else blk: {
                    if (len > result.buf.len) return ctx.fail(error.OutOfRange, node);
                    result.len = len;
                    break :blk result.buf[0..len];
                };
                for (dest, 0..) |*out, i| {
                    const name = if (named) node.value.table.entries.keys()[i] else try std.fmt.allocPrint(ctx.a, "{d}", .{i});
                    try ctx.push(name);
                    defer ctx.pop();
                    const child = if (named) node.value.table.get(name).? else node.value.array[i];
                    ctx.element_depth += 1;
                    defer ctx.element_depth -= 1;
                    out.* = try ctx.read(E, spec.element.?.*, child, if (named) .{ .field = ctx.options.named_field.?, .value = name } else null, initial(E));
                }
                return result;
            },
        }
    }
};
