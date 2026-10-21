//! Deliberately narrow first wire-library prototype. Unsupported IDL fails closed.
const std = @import("std");
const ir = @import("../ir/root.zig");
const to = @import("zig_typeobject.zig");

/// Enforce the contract for direct backend users as well as the CLI, before
/// split-file handling or writing any generated output.
pub fn validateOptions(opts: @import("interface.zig").Options) !void {
    if (!opts.zig_typesupport_library) return;
    if (opts.profile != .full or opts.split_files or opts.no_typesupport or
        opts.no_typeobject_support or opts.pl_cdr or opts.zig_version != .@"0.17.0" or
        opts.type_prefix.len != 0 or opts.zig_idiomatic_enums or opts.default_extensibility != .final)
        return error.TypesupportLibraryIncompatibleOptions;
}

const Generator = struct {
    alloc: std.mem.Allocator,
    out: *std.ArrayList(u8),
    declarations: std.ArrayList(ir.TypeDecl) = .empty,
    visiting: std.ArrayList(bool) = .empty,
    fn print(self: *@This(), comptime fmt: []const u8, args: anytype) !void {
        const text = try std.fmt.allocPrint(self.alloc, fmt, args);
        defer self.alloc.free(text);
        try self.out.appendSlice(self.alloc, text);
    }
    fn index(self: *@This(), td: ir.TypeDecl) ?usize {
        for (self.declarations.items, 0..) |d, i| {
            if (std.mem.eql(u8, ir.typeDeclQualifiedName(d), ir.typeDeclQualifiedName(td))) return i;
        }
        return null;
    }
    fn collect(self: *@This(), td: ir.TypeDecl, depth: usize) anyerror!void {
        if (depth > 64) return error.TypesupportLibraryDependencyDepthExceeded;
        if (self.index(td)) |i| {
            if (self.visiting.items[i]) return error.TypesupportLibraryRecursiveTypeUnsupported;
            return;
        }
        const i = self.declarations.items.len;
        try self.declarations.append(self.alloc, td);
        try self.visiting.append(self.alloc, true);
        switch (td) {
            .struct_ => |s| {
                if (s.annotations.extensibility != .final or s.base != null)
                    return error.TypesupportLibraryRequiresFinalNonInheritedStruct;
                if (s.annotations.raw.len != 0) return error.TypesupportLibraryTypeAnnotationUnsupported;
                for (s.members) |m| {
                    if (m.annotations.is_optional or m.annotations.raw.len != 0)
                        return error.TypesupportLibraryMemberAnnotationUnsupported;
                    // Scalar primitive keys avoid unsupported aggregate key-hash paths.
                    if (m.annotations.is_key and (m.type_ref != .base or m.dimensions.len != 0))
                        return error.TypesupportLibraryRequiresScalarPrimitiveKey;
                    if (m.dimensions.len != 0 and m.type_ref != .base) return error.TypesupportLibraryArrayElementUnsupported;
                    try self.dimensions(m.dimensions);
                    try self.reference(m.type_ref, depth + 1);
                }
            },
            .enum_ => |e| {
                for (e.enumerators) |value| if (value.value < 0 or value.value > std.math.maxInt(u32)) return error.TypesupportLibraryEnumValueUnsupported;
                if (e.annotations.bit_bound != null or e.annotations.extensibility != .final or e.annotations.raw.len != 0)
                    return error.TypesupportLibraryEnumAnnotationUnsupported;
            },
            .typedef => |t| {
                if (t.raw.len != 0) return error.TypesupportLibraryTypeAnnotationUnsupported;
                if (t.dimensions.len != 0 and t.type_ref != .base) return error.TypesupportLibraryArrayElementUnsupported;
                try self.dimensions(t.dimensions);
                try self.reference(t.type_ref, depth + 1);
            },
            else => return error.TypesupportLibraryTypeKindUnsupported,
        }
        self.visiting.items[i] = false;
    }
    fn dimensions(_: *@This(), dims: []const u64) !void {
        for (dims) |n| if (n == 0 or n > 65536) return error.TypesupportLibraryArrayBoundUnsupported;
    }
    fn reference(self: *@This(), ref: ir.TypeRef, depth: usize) anyerror!void {
        if (depth > 64) return error.TypesupportLibraryDependencyDepthExceeded;
        switch (ref) {
            .base => |b| switch (b) {
                .long_double, .wchar, .any, .object, .value_base => return error.TypesupportLibraryPrimitiveUnsupported,
                else => {},
            },
            .named => |td| try self.collect(td, depth + 1),
            .string => |bound| {
                if (bound == null or bound.? > 65536) return error.TypesupportLibraryRequiresBoundedCollection;
            },
            .sequence => |s| {
                if (s.bound == null or s.bound.? > 65536) return error.TypesupportLibraryRequiresBoundedCollection;
                // Enum/bitmask collections require DHEADER handling; add with fixtures.
                if (s.element.* != .base) return error.TypesupportLibrarySequenceElementUnsupported;
                try self.reference(s.element.*, depth + 1);
            },
            else => return error.TypesupportLibraryTypeKindUnsupported,
        }
    }
    fn items(self: *@This(), values: []const ir.ModuleItem) anyerror!void {
        for (values) |item| switch (item) {
            .module => |m| {
                if (m.is_imported) return error.TypesupportLibraryImportsUnsupported;
                if (m.raw.len != 0) return error.TypesupportLibraryModuleAnnotationUnsupported;
                try self.items(m.items);
            },
            .type_decl => |td| try self.collect(td, 0),
            .const_ => {},
        };
    }
    fn byteLiteral(self: *@This(), data: []const u8) !void {
        try self.print("{{", .{});
        for (data) |b| try self.print("0x{x},", .{b});
        try self.print("}}", .{});
    }
    fn walkRef(self: *@This(), ref: ir.TypeRef, dims: []const u64) anyerror!void {
        if (dims.len > 0) {
            try self.print("{{ var i: usize = 0; while (i < {d}) : (i += 1) {{\n", .{dims[0]});
            try self.walkRef(ref, dims[1..]);
            try self.print("}} }}\n", .{});
            return;
        }
        switch (ref) {
            .base => |b| {
                const method: []const u8 = switch (b) {
                    .boolean => "readBool",
                    .char, .octet, .uint8 => "readU8",
                    .int8 => "readI8",
                    .short, .int16 => "readI16",
                    .unsigned_short, .uint16 => "readU16",
                    .long, .int32 => "readI32",
                    .unsigned_long, .uint32 => "readU32",
                    .long_long, .int64 => "readI64",
                    .unsigned_long_long, .uint64 => "readU64",
                    .float => "readF32",
                    .double => "readF64",
                    else => unreachable,
                };
                if (b == .boolean) try self.print("if (try r.readU8() > 1) return error.InvalidBoolean;\n", .{}) else try self.print("_ = try r.{s}();\n", .{method});
            },
            .named => |td| try self.print("try walk_{d}(r);\n", .{self.index(td).?}),
            .string => |bound| try self.print("{{ const n = try r.readU32(); if (n == 0 or n - 1 > {d}) return error.InvalidBound; try r.skip(n); if (r.data[r.pos - 1] != 0) return error.InvalidString; }}\n", .{bound.?}),
            .sequence => |s| {
                try self.print("{{ const n = try r.readU32(); if (n > {d} or n > r.remaining()) return error.InvalidBound; var j: usize = 0; while (j < n) : (j += 1) {{\n", .{s.bound.?});
                try self.walkRef(s.element.*, &.{});
                try self.print("}} }}\n", .{});
            },
            else => unreachable,
        }
    }
    fn dependencies(self: *@This(), ref: ir.TypeRef, deps: *std.ArrayList(usize)) anyerror!void {
        switch (ref) {
            .named => |td| {
                const i = self.index(td).?;
                const encoded = try to.encodeMinimalTypeDecl(self.alloc, td);
                defer self.alloc.free(encoded);
                const id = to.computeEquivalenceHash(encoded[to.encap_header_len..]);
                for (deps.items) |d| {
                    const previous = try to.encodeMinimalTypeDecl(self.alloc, self.declarations.items[d]);
                    defer self.alloc.free(previous);
                    const previous_id = to.computeEquivalenceHash(previous[to.encap_header_len..]);
                    if (std.mem.eql(u8, &id, &previous_id)) return;
                }
                try deps.append(self.alloc, i);
            },
            .sequence => |s| try self.dependencies(s.element.*, deps),
            else => {},
        }
    }
};

pub fn generate(alloc: std.mem.Allocator, spec: *const ir.Spec, out: *std.ArrayList(u8)) !void {
    var g = Generator{ .alloc = alloc, .out = out };
    defer g.declarations.deinit(alloc);
    defer g.visiting.deinit(alloc);
    if (spec.imports.len != 0 or spec.warnings.len != 0) return error.TypesupportLibraryImportsOrDroppedDeclarationsUnsupported;
    try g.items(spec.items);
    try g.print("// Experimental generated wire typesupport library.\nconst ts = @import(\"zidl_typesupport\");\nconst rt = @import(\"zidl_rt\");\nconst types = @import(\"types\");\n", .{});
    for (g.declarations.items, 0..) |td, i| {
        const object = try to.encodeMinimalTypeDecl(alloc, td);
        defer alloc.free(object);
        const hash = to.computeEquivalenceHash(object[to.encap_header_len..]);
        try g.print("const id_{d} = ts.Identifier{{ .value = .", .{i});
        var id: [15]u8 = undefined;
        id[0] = 0xf1;
        @memcpy(id[1..], &hash);
        try g.byteLiteral(&id);
        try g.print(" }};\nconst object_{d} = [_]u8", .{i});
        try g.byteLiteral(object);
        var deps: std.ArrayList(usize) = .empty;
        defer deps.deinit(alloc);
        switch (td) {
            .struct_ => |s| for (s.members) |m| {
                try g.dependencies(m.type_ref, &deps);
            },
            .typedef => |t| try g.dependencies(t.type_ref, &deps),
            else => {},
        }
        try g.print(";\nconst deps_{d} = [_]ts.Identifier{{", .{i});
        for (deps.items) |d| try g.print("id_{d},", .{d});
        try g.print("}};\nfn walk_{d}(r: *rt.CdrReader) anyerror!void {{\n", .{i});
        switch (td) {
            .struct_ => |s| {
                if (s.members.len == 0) try g.print("_ = r;\n", .{});
                for (s.members) |m| try g.walkRef(m.type_ref, m.dimensions);
            },
            .typedef => |t| try g.walkRef(t.type_ref, t.dimensions),
            .enum_ => |e| {
                try g.print("const value = try r.readU32();\n", .{});
                for (e.enumerators) |enumerator| try g.print("if (value == {d}) return;\n", .{enumerator.value});
                try g.print("return error.InvalidEnum;\n", .{});
            },
            else => unreachable,
        }
        try g.print("}}\n", .{});
        if (td == .struct_) {
            try g.print("fn key_walk_{d}(r: *rt.CdrReader) anyerror!void {{\n", .{i});
            var keyed = false;
            for (td.struct_.members) |m| if (m.annotations.is_key) {
                keyed = true;
                try g.walkRef(m.type_ref, m.dimensions);
            };
            if (!keyed) try g.print("_ = r;\n", .{});
            const name = ir.typeDeclQualifiedName(td);
            try g.print("}}\nconst ops_{d} = ts.operations(types", .{i});
            var parts = std.mem.splitSequence(u8, name, "::");
            while (parts.next()) |part| if (part.len != 0) {
                try g.print(".@\"{s}\"", .{part});
            };
            try g.print(", {}, walk_{d}, key_walk_{d});\n", .{ keyed, i, i });
        }
    }
    try g.print("const objects = [_]ts.Object{{\n", .{});
    var emitted_ids: std.ArrayList([14]u8) = .empty;
    defer emitted_ids.deinit(alloc);
    for (g.declarations.items, 0..) |td, i| {
        const encoded = try to.encodeMinimalTypeDecl(alloc, td);
        defer alloc.free(encoded);
        const id = to.computeEquivalenceHash(encoded[to.encap_header_len..]);
        var duplicate = false;
        for (emitted_ids.items) |previous| if (std.mem.eql(u8, &previous, &id)) {
            duplicate = true;
            break;
        };
        if (duplicate) continue;
        try emitted_ids.append(alloc, id);
        try g.print(".{{ .descriptor_size = @sizeOf(ts.Object), .identifier = id_{d}, .cdr = ts.bytes(&object_{d}), .dependencies = &deps_{d}, .dependency_count = deps_{d}.len }},\n", .{ i, i, i, i });
    }
    try g.print("}};\nconst exports = [_]ts.Type{{\n", .{});
    var count: usize = 0;
    for (g.declarations.items, 0..) |td, i| {
        if (td != .struct_ or td.struct_.annotations.is_nested) continue;
        count += 1;
        var keyed = false;
        for (td.struct_.members) |m| keyed = keyed or m.annotations.is_key;
        try g.print(".{{ .descriptor_size = @sizeOf(ts.Type), .representations = 3, .name = ts.bytes(\"{s}\"), .minimal_identifier = id_{d}, .keyed = {d}, .validate = ops_{d}.validate, .key_hash = ops_{d}.keyHash, .key_only_hash = ops_{d}.keyOnlyHash }},\n", .{ ir.typeDeclQualifiedName(td), i, @intFromBool(keyed), i, i, i });
    }
    if (count == 0) return error.TypesupportLibraryNoExportedStructs;
    try g.print("}};\npub const library = ts.Library{{ .descriptor_size = @sizeOf(ts.Library), .abi_major = ts.abi_major, .abi_minor = 0, .required_features = 0, .types = &exports, .type_count = exports.len, .objects = &objects, .object_count = objects.len }};\npub export fn zidl_typesupport_query(major: u32, out: [*c][*c]const ts.Library) callconv(.c) u32 {{ return ts.query(&library, major, out); }}\n", .{});
}

fn testGenerate(source: []const u8) !void {
    const alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    var parser = @import("../parser.zig").Parser.init(source, arena.allocator());
    const ast = try parser.parseSpecification();
    var analyzer = try @import("../semantic/root.zig").Analyzer.init(alloc);
    defer analyzer.deinit();
    try analyzer.analyze(&ast);
    var spec = try ir.build(alloc, &ast, analyzer.global_scope, &.{});
    defer spec.deinit();
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(alloc);
    try generate(alloc, &spec, &output);
}

test "wire library rejects unsupported IDL instead of emitting fallback identities" {
    const expectError = std.testing.expectError;
    try expectError(error.TypesupportLibraryRequiresBoundedCollection, testGenerate("struct S { string s; };"));
    try expectError(error.TypesupportLibraryRequiresBoundedCollection, testGenerate("struct S { sequence<long> s; };"));
    try expectError(error.TypesupportLibraryTypeKindUnsupported, testGenerate("struct S { map<long, long> s; };"));
    try expectError(error.TypesupportLibraryTypeKindUnsupported, testGenerate("struct S { fixed<5,2> s; };"));
    try expectError(error.TypesupportLibraryRequiresFinalNonInheritedStruct, testGenerate("@appendable struct S { long s; };"));
    try expectError(error.TypesupportLibraryRequiresFinalNonInheritedStruct, testGenerate("@mutable struct S { long s; };"));
    try expectError(error.TypesupportLibraryMemberAnnotationUnsupported, testGenerate("struct S { @optional long s; };"));
    try expectError(error.TypesupportLibraryRequiresScalarPrimitiveKey, testGenerate("struct S { @key string<10> s; };"));
    try expectError(error.TypesupportLibraryModuleAnnotationUnsupported, testGenerate("@autoid(HASH) module M { struct S { long x; }; };"));
    try expectError(error.TypesupportLibraryModuleAnnotationUnsupported, testGenerate("module M { struct S { long x; }; }; @autoid(HASH) module M { struct T { long y; }; };"));
    try expectError(error.TypesupportLibraryTypeKindUnsupported, testGenerate("union U switch(long) { case 0: long x; };"));
    try testGenerate("module Test { enum E { A, B }; typedef long L; @nested struct N { long n; }; struct S { @key long id; N n; E e; L x; string<10> s; sequence<octet,8> bytes; }; };");
}

test "wire library rejects incompatible backend options before output selection" {
    const Options = @import("interface.zig").Options;
    const incompatible = [_]Options{
        .{ .input_stem = "test", .profile = .xrce },
        .{ .input_stem = "test", .split_files = true },
        .{ .input_stem = "test", .no_typesupport = true },
        .{ .input_stem = "test", .no_typeobject_support = true },
        .{ .input_stem = "test", .pl_cdr = true },
        .{ .input_stem = "test", .zig_version = .@"0.16.0" },
        .{ .input_stem = "test", .zig_version = .@"0.15.1" },
        .{ .input_stem = "test", .type_prefix = "Prefix" },
        .{ .input_stem = "test", .zig_idiomatic_enums = true },
        .{ .input_stem = "test", .default_extensibility = .appendable },
        .{ .input_stem = "test", .default_extensibility = .mutable },
    };
    var spec = ir.Spec{ .arena = std.heap.ArenaAllocator.init(std.testing.allocator), .items = &.{} };
    defer spec.deinit();
    const implementation = try @import("zig.zig").ZigBackend.create(std.testing.allocator);
    const backend = implementation.backend();
    defer backend.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const output_dir = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer std.testing.allocator.free(output_dir);
    for (incompatible) |base| {
        try validateOptions(base); // Ordinary generation retains its options.
        var opts = base;
        opts.zig_typesupport_library = true;
        opts.output_dir = output_dir;
        try std.testing.expectError(error.TypesupportLibraryIncompatibleOptions, backend.generate(&spec, opts));
    }
    try validateOptions(.{ .input_stem = "test", .zig_typesupport_library = true });
}
