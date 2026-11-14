//! Representation-agnostic CDR "skip" codegen, shared by the C and C++
//! backends.
//!
//! Skipping a serialized value never touches the output struct -- it only
//! advances the reader cursor -- so the code is identical whether the
//! backend represents a `string` as `char *` or `std::string`, a
//! `sequence<T>` as a POD `{ T* _buffer; ... }` or a `std::vector<T>`, etc.
//! The C and C++ backends previously carried near-verbatim copies of these
//! three functions; this module is the single copy.
//!
//! `self` is duck-typed: any value exposing
//!   - `writeI([]const u8) !void`           -- indent + write a line
//!   - `printI(comptime []const u8, args) !void`
//!   - `indent_depth: <integer, mutable>`
//!   - `coll_depth: <integer, mutable>`     -- nesting of collection elements
//!   - `alloc: std.mem.Allocator`
//!   - `prefixedCName([]const u8) ![]u8`     -- qualified IDL name -> C name
//! Both backends' `CdrGenerator` structs satisfy it.
//!
//! Emitted C is valid C99 and C++: `bool` (generated C includes
//! `<stdbool.h>` via `zidl_cdr.h`), `uint32_t` loop counters, and the
//! `zidl_cdr_*` reader API.

const std = @import("std");
const ast = @import("../ast.zig");
const ir = @import("../ir/root.zig");

// ── Fast-path helpers ────────────────────────────────────────────────────────

/// Fixed wire size (bytes) of a base type, or null for variable-size /
/// unsupported. Turns a per-element skip loop into one
/// `zidl_cdr_skip_primitives` advance.
pub fn baseWireSize(b: ast.BaseTypeSpec) ?usize {
    return switch (b) {
        .boolean, .octet, .uint8, .char, .int8 => 1,
        .wchar, .short, .int16, .unsigned_short, .uint16 => 2,
        .long, .int32, .unsigned_long, .uint32, .float => 4,
        .long_long, .int64, .unsigned_long_long, .uint64, .double, .long_double => 8,
        .any, .object, .value_base => null,
    };
}

/// Wire size of a type that skips as a flat run of fixed-size elements
/// (base primitive, or an enum/bitmask by its storage width), else null.
pub fn typeRefPrimWireSize(tr: ir.TypeRef) ?usize {
    return switch (tr) {
        .base => |b| baseWireSize(b),
        .named => |td| switch (td) {
            .enum_ => |e| bitBoundWidth(e.annotations.bit_bound),
            .bitmask => |bm| bitBoundWidth(bm.annotations.bit_bound),
            else => null,
        },
        else => null,
    };
}

pub fn enumLengthCode(bound: ?u16) u2 {
    const b = bound orelse 32;
    return if (b <= 8) 0 else if (b <= 16) 1 else if (b <= 32) 2 else 3;
}

fn bitBoundWidth(bound: ?u16) usize {
    const b = bound orelse 32;
    return if (b <= 8) 1 else if (b <= 16) 2 else if (b <= 32) 4 else 8;
}

// ── XCDR2 collection rules (shared by the C and C++ backends) ────────────────

/// Follow dimension-less typedefs to the aliased type. Stops at an array
/// typedef, which is a distinct (array) type.
pub fn resolveAlias(tr: ir.TypeRef) ir.TypeRef {
    var t = tr;
    while (true) {
        switch (t) {
            .named => |td| switch (td) {
                .typedef => |td2| if (td2.dimensions.len == 0) {
                    t = td2.type_ref;
                    continue;
                },
                else => {},
            },
            else => {},
        }
        return t;
    }
}

/// The array typedef `tr` names (through dimension-less aliases), if any.
pub fn arrayTypedefOf(tr: ir.TypeRef) ?*const ir.Typedef {
    return switch (resolveAlias(tr)) {
        .named => |td| switch (td) {
            .typedef => |t| if (t.dimensions.len > 0) t else null,
            else => null,
        },
        else => null,
    };
}

/// Innermost element of an array: XCDR flattens array typedefs used as array
/// elements into the enclosing array's dimensions.
pub fn arrayInnermost(tr: ir.TypeRef) ir.TypeRef {
    var t = tr;
    while (arrayTypedefOf(t)) |td| t = td.type_ref;
    return resolveAlias(t);
}

/// XCDR2 prefixes a sequence, array or map with a DHEADER unless its element
/// type is primitive: integers, floating point, boolean, char/octet and wchar.
/// Enums, bitmasks, strings, aggregates and collections all get one.
pub fn isPrimitiveElement(tr: ir.TypeRef) bool {
    return resolveAlias(tr) == .base;
}

/// Collection-local name for nesting depth `depth`: `base` at depth 0,
/// `base{depth}` inside nested collections so an inner loop never shadows an
/// outer one. Caller frees.
pub fn collName(alloc: std.mem.Allocator, base: []const u8, depth: anytype) ![]u8 {
    if (depth == 0) return alloc.dupe(u8, base);
    return std.fmt.allocPrint(alloc, "{s}{d}", .{ base, depth });
}

/// Array loop variable `{base}{dim}`, qualified by collection depth when
/// nested. Caller frees.
pub fn arrayVar(alloc: std.mem.Allocator, base: []const u8, depth: anytype, dim: usize) ![]u8 {
    if (depth == 0) return std.fmt.allocPrint(alloc, "{s}{d}", .{ base, dim });
    return std.fmt.allocPrint(alloc, "{s}{d}_{d}", .{ base, depth, dim });
}

/// `ZIDL_EXT_*` constant for `zidl_cdr_write_encap_kind`: the XCDR2
/// representation id a top-level sample needs (CDR2 / D_CDR2 / PL_CDR2).
pub fn encapKindC(s: *const ir.Struct) []const u8 {
    return switch (s.annotations.extensibility) {
        .final => "ZIDL_EXT_FINAL",
        .appendable => "ZIDL_EXT_APPENDABLE",
        .mutable => "ZIDL_EXT_MUTABLE",
    };
}

// ── Skip emitters ────────────────────────────────────────────────────────────

/// Allocation-free traversal of the same nested projection as key-value readers.
/// Keep a named function for recursive collection types and split-file output.
pub fn emitKeyValueSkip(self: anytype, s: *const ir.Struct, c_name: []const u8) !void {
    const name = try std.fmt.allocPrint(self.alloc, "{s}_skip_key_value", .{c_name});
    defer self.alloc.free(name);
    const previous = self.wire_key;
    self.wire_key = true;
    defer self.wire_key = previous;
    try emitReadFunction(self, name, null, false, "0");
    try self.writeI("int _rc = ZIDL_CDR_OK; (void)_rc;\n");
    if (s.annotations.extensibility == .mutable) {
        try self.writeI("size_t _end;\n_rc = zidl_cdr_read_mutable_dheader(_r, &_end);\n");
        try readRcCheck(self);
        try self.writeI("return zidl_cdr_seek_to(_r, _end);\n");
    } else {
        if (s.annotations.extensibility == .appendable) {
            try self.writeI("if (_r->xcdr_version == ZIDL_XCDR2) {\n");
            self.indent_depth += 1;
            try self.writeI("uint32_t _size;\n_rc = zidl_cdr_read_dheader(_r, &_size);\n");
            try readRcCheck(self);
            try self.writeI("return zidl_cdr_skip(_r, _size);\n");
            self.indent_depth -= 1;
            try self.writeI("}\n");
        }
        const fields = try @import("canonical_key.zig").wireFields(self.alloc, s, true);
        defer self.alloc.free(fields);
        for (fields) |field| try emitSkipMember(self, field.member.*);
        try self.writeI("return ZIDL_CDR_OK;\n");
    }
    try self.write("}\n\n");
}

pub fn emitSkipMember(self: anytype, m: ir.StructMember) anyerror!void {
    if (m.annotations.is_optional) {
        try self.writeI("{ bool _present;\n");
        self.indent_depth += 1;
        try self.writeI("ZidlCdrOptionalRead _scope;\n");
        try self.printI("_rc = zidl_cdr_begin_optional_read(_r, {d}, &_scope, &_present);\n", .{m.annotations.memberId(0)});
        try readRcCheck(self);
        try self.writeI("if (_r->xcdr_version != ZIDL_XCDR2) {\n");
        self.indent_depth += 1;
        try self.writeI("zidl_cdr_end_optional_read(_r, &_scope);\n");
        self.indent_depth -= 1;
        try self.writeI("} else if (_present) {\n");
        self.indent_depth += 1;
        if (m.dimensions.len > 0) {
            try emitSkipArray(self, m.type_ref, m.dimensions, 0);
        } else {
            try emitSkipForTypeRef(self, m.type_ref);
        }
        self.indent_depth -= 1;
        try self.writeI("}\n");
        self.indent_depth -= 1;
        try self.writeI("}\n");
        return;
    }
    if (m.dimensions.len > 0) {
        try emitSkipArray(self, m.type_ref, m.dimensions, 0);
    } else {
        try emitSkipForTypeRef(self, m.type_ref);
    }
}

pub fn emitSkipArray(self: anytype, elem_tr: ir.TypeRef, dims: []const u64, dim_idx: usize) anyerror!void {
    if (dim_idx == 0) {
        // XCDR2: one DHEADER covers the whole (flattened) array.
        // Fixed-size primitive element with all dims known → one bulk advance.
        if (typeRefPrimWireSize(elem_tr)) |sz| {
            var total: u64 = 1;
            for (dims) |d| total *= d;
            try self.printI("_rc = zidl_cdr_skip_primitives(_r, {d}u, {d});\n", .{ total, sz });
            try readRcCheck(self);
            return;
        }
    }
    const window = try openReadWindow(self, dim_idx == 0 and !isPrimitiveElement(arrayInnermost(elem_tr)));
    try emitSkipArrayDims(self, elem_tr, dims, dim_idx);
    try closeReadWindow(self, window);
}

fn emitSkipArrayDims(self: anytype, elem_tr: ir.TypeRef, dims: []const u64, dim_idx: usize) anyerror!void {
    if (dims.len == 0) {
        // An array typedef element continues the enclosing array.
        if (arrayTypedefOf(elem_tr)) |t| return emitSkipArrayDims(self, t.type_ref, t.dimensions, dim_idx);
        self.coll_depth += 1;
        defer self.coll_depth -= 1;
        return emitSkipForTypeRef(self, elem_tr);
    }
    const var_name = try arrayVar(self.alloc, "_ski", self.coll_depth, dim_idx);
    defer self.alloc.free(var_name);
    try self.printI("{{ uint32_t {s}; for ({s} = 0; {s} < {d}u; {s}++) {{\n", .{
        var_name, var_name, var_name, dims[0], var_name,
    });
    self.indent_depth += 1;
    try emitSkipArrayDims(self, elem_tr, dims[1..], dim_idx + 1);
    self.indent_depth -= 1;
    try self.writeI("}\n");
    try self.writeI("}\n");
}

pub fn emitSkipForTypeRef(self: anytype, tr: ir.TypeRef) anyerror!void {
    switch (tr) {
        .base => |b| {
            const fn_name = baseCReadFn(b);
            const c_type = baseCType(b);
            if (std.mem.startsWith(u8, fn_name, "//")) {
                try invalidRead(self);
            } else {
                try self.printI("{{ {s} _tmp; _rc = {s}(_r, &_tmp); }}\n", .{ c_type, fn_name });
                try readRcCheck(self);
            }
        },
        .string => {
            try self.writeI("{ const char *_sp; uint32_t _sl; _rc = zidl_cdr_read_string_zerocopy(_r, &_sp, &_sl);\n");
            try readRcCheck(self);
            try self.writeI("}\n");
        },
        .wstring => {
            try self.writeI("_rc = zidl_cdr_skip_wstring(_r);\n");
            try readRcCheck(self);
        },
        .sequence => |seq| {
            const window = try openReadWindow(self, !isPrimitiveElement(seq.element.*));
            const sl = try collName(self.alloc, "_sl", self.coll_depth);
            defer self.alloc.free(sl);
            const si = try collName(self.alloc, "_si", self.coll_depth);
            defer self.alloc.free(si);
            try self.printI("{{ uint32_t {s};\n", .{sl});
            self.indent_depth += 1;
            try self.printI("_rc = zidl_cdr_read_u32(_r, &{s});\n", .{sl});
            try readRcCheck(self);
            if (seq.bound) |bound| {
                try self.printI("if ({s} > {d}u) {{\n", .{ sl, bound });
                self.indent_depth += 1;
                try invalidRead(self);
                self.indent_depth -= 1;
                try self.writeI("}\n");
            }
            if (typeRefPrimWireSize(resolveAlias(seq.element.*))) |sz| {
                try self.printI("_rc = zidl_cdr_skip_primitives(_r, {s}, {d});\n", .{ sl, sz });
                try readRcCheck(self);
            } else {
                try self.printI("for (uint32_t {s} = 0; {s} < {s}; {s}++) {{\n", .{ si, si, sl, si });
                self.indent_depth += 1;
                self.coll_depth += 1;
                try emitSkipForTypeRef(self, seq.element.*);
                self.coll_depth -= 1;
                self.indent_depth -= 1;
                try self.writeI("}\n");
            }
            self.indent_depth -= 1;
            try self.writeI("}\n");
            try closeReadWindow(self, window);
        },
        .map => |m| {
            const window = try openReadWindow(self, !(isPrimitiveElement(m.key.*) and isPrimitiveElement(m.value.*)));
            const ml = try collName(self.alloc, "_ml", self.coll_depth);
            defer self.alloc.free(ml);
            const mi = try collName(self.alloc, "_mi", self.coll_depth);
            defer self.alloc.free(mi);
            try self.printI("{{ uint32_t {s};\n", .{ml});
            self.indent_depth += 1;
            try self.printI("_rc = zidl_cdr_read_u32(_r, &{s});\n", .{ml});
            try readRcCheck(self);
            try self.printI("for (uint32_t {s} = 0; {s} < {s}; {s}++) {{\n", .{ mi, mi, ml, mi });
            self.indent_depth += 1;
            self.coll_depth += 1;
            try emitSkipForTypeRef(self, m.key.*);
            try emitSkipForTypeRef(self, m.value.*);
            self.coll_depth -= 1;
            self.indent_depth -= 1;
            try self.writeI("}\n");
            self.indent_depth -= 1;
            try self.writeI("}\n");
            try closeReadWindow(self, window);
        },
        .named => |td| switch (td) {
            .enum_ => |e| {
                const suffix = enumCdrSuffix(e.annotations.bit_bound);
                const ctype = enumCdrType(e.annotations.bit_bound);
                try self.printI("{{ {s} _tmp; _rc = zidl_cdr_read_{s}(_r, &_tmp); }}\n", .{ ctype, suffix });
                try readRcCheck(self);
            },
            .bitmask => |bm| {
                const suffix = enumCdrSuffix(bm.annotations.bit_bound);
                const ctype = enumCdrType(bm.annotations.bit_bound);
                try self.printI("{{ {s} _tmp; _rc = zidl_cdr_read_{s}(_r, &_tmp); }}\n", .{ ctype, suffix });
                try readRcCheck(self);
            },
            .typedef => |t| {
                if (t.dimensions.len > 0) {
                    try emitSkipArray(self, t.type_ref, t.dimensions, 0);
                } else {
                    try emitSkipForTypeRef(self, t.type_ref);
                }
            },
            .struct_, .exception, .union_ => {
                const c_type = try self.prefixedCName(ir.typeDeclQualifiedName(td));
                defer self.alloc.free(c_type);
                try self.printI("_rc = {s}_{s}(_r);\n", .{ c_type, if (self.wire_key and td == .struct_) "skip_key_value" else "skip" });
                try readRcCheck(self);
            },
            .bitset => |bs| {
                var total: u32 = 0;
                for (bs.fields) |f| total += f.bits;
                const ctype = if (total <= 8) "uint8_t" else if (total <= 16) "uint16_t" else if (total <= 32) "uint32_t" else "uint64_t";
                const suffix = if (total <= 8) "u8" else if (total <= 16) "u16" else if (total <= 32) "u32" else "u64";
                try self.printI("{{ {s} _tmp; _rc = zidl_cdr_read_{s}(_r, &_tmp); }}\n", .{ ctype, suffix });
                try readRcCheck(self);
            },
            else => try invalidRead(self),
        },
        .fixed_pt => |fp| {
            try self.printI("{{ double _tmp; _rc = zidl_cdr_read_fixed(_r, {d}, {d}, &_tmp); }}\n", .{ fp.digits, fp.scale });
            try readRcCheck(self);
        },
    }
}

/// Validate a complete sequence on a stack reader before allocating its native
/// container. Primitive elements use a bulk span check; variable-size elements
/// use the same bounded skip traversal as the public skip API.
pub fn preflightSequence(self: anytype, tr: ir.TypeRef) !void {
    const id = self.reader_window_id;
    self.reader_window_id += 1;
    const label = try std.fmt.allocPrint(self.alloc, "_sequence_probe_end_{d}", .{id});
    defer self.alloc.free(label);
    try self.writeI("{\n");
    self.indent_depth += 1;
    try self.writeI("ZidlCdrReader *_sequence_reader = _r;\n");
    try self.writeI("ZidlCdrReader _sequence_probe = *_r;\n");
    try self.writeI("{\n");
    self.indent_depth += 1;
    try self.writeI("ZidlCdrReader *_r = &_sequence_probe;\n");
    const previous_label = self.goto_label;
    self.goto_label = label;
    defer self.goto_label = previous_label;
    try emitSkipForTypeRef(self, tr);
    self.goto_label = previous_label;
    self.indent_depth -= 1;
    try self.writeI("}\n");
    try self.printI("{s}:\n", .{label});
    // Preserve useful failure progress, without advancing the real reader on success.
    try self.writeI("if (_rc) _sequence_reader->pos = _sequence_probe.pos;\n");
    try readRcCheck(self);
    self.indent_depth -= 1;
    try self.writeI("}\n");
}

fn invalidRead(self: anytype) !void {
    try self.writeI("_rc = ZIDL_CDR_INVALID;\n");
    try readRcCheck(self);
}

// ── Private C-language constant tables (identical in the C and C++
// backends; kept module-local so callers need not thread them through) ──────

fn baseCReadFn(b: ast.BaseTypeSpec) []const u8 {
    return switch (b) {
        .boolean => "zidl_cdr_read_bool",
        .octet, .uint8 => "zidl_cdr_read_u8",
        .char => "zidl_cdr_read_char",
        .wchar => "zidl_cdr_read_u16",
        .int8 => "zidl_cdr_read_i8",
        .short, .int16 => "zidl_cdr_read_i16",
        .long, .int32 => "zidl_cdr_read_i32",
        .long_long, .int64 => "zidl_cdr_read_i64",
        .unsigned_short, .uint16 => "zidl_cdr_read_u16",
        .unsigned_long, .uint32 => "zidl_cdr_read_u32",
        .unsigned_long_long, .uint64 => "zidl_cdr_read_u64",
        .float => "zidl_cdr_read_f32",
        .double => "zidl_cdr_read_f64",
        .long_double => "zidl_cdr_read_f64",
        .any, .object, .value_base => "// unsupported",
    };
}

fn baseCType(b: ast.BaseTypeSpec) []const u8 {
    return switch (b) {
        .float => "float",
        .double => "double",
        .long_double => "long double",
        .short, .int16 => "int16_t",
        .long, .int32 => "int32_t",
        .long_long, .int64 => "int64_t",
        .unsigned_short, .wchar, .uint16 => "uint16_t",
        .unsigned_long, .uint32 => "uint32_t",
        .unsigned_long_long, .uint64 => "uint64_t",
        .char => "char",
        .boolean => "bool",
        .octet, .uint8 => "uint8_t",
        .int8 => "int8_t",
        .any, .object, .value_base => "void *",
    };
}

fn enumCdrSuffix(bit_bound: ?u16) []const u8 {
    const b = bit_bound orelse 32;
    return if (b <= 8) "u8" else if (b <= 16) "u16" else if (b <= 32) "u32" else "u64";
}

fn enumCdrType(bit_bound: ?u16) []const u8 {
    const b = bit_bound orelse 32;
    return if (b <= 8) "uint8_t" else if (b <= 16) "uint16_t" else if (b <= 32) "uint32_t" else "uint64_t";
}

/// Every public traversal receives a stack reader. Its private body can narrow
/// data_len without leaking a limit through early returns or cleanup gotos.
pub fn emitReadFunction(self: anytype, name: []const u8, value_type: ?[]const u8, selected: bool, complete_frame: []const u8) !void {
    const args = if (value_type) |t| try std.fmt.allocPrint(self.alloc, "{s}, {s} *_v", .{ if (selected) "ZidlCdrReader *_r, uint64_t _want" else "ZidlCdrReader *_r", t }) else try self.alloc.dupe(u8, "ZidlCdrReader *_r");
    defer self.alloc.free(args);
    const call_args = if (value_type != null) (if (selected) "&_local, _want, _v" else "&_local, _v") else "&_local";
    try self.print("static int {s}_bounded_impl({s});\n", .{ name, args });
    try self.print("int {s}({s}) {{\n", .{ name, args });
    try self.writeI("ZidlCdrReader _local = *_r;\n");
    if (comptime @hasDecl(@TypeOf(self.*), "emitReadCall")) {
        if (value_type != null) {
            try self.emitReadCall(name, call_args);
        } else {
            try self.printI("int _rc = {s}_bounded_impl({s});\n", .{ name, call_args });
        }
    } else {
        try self.printI("int _rc = {s}_bounded_impl({s});\n", .{ name, call_args });
    }
    try self.printI("_r->pos = !_rc && ({s}) ? _local.data_len : (_local.pos <= _local.data_len ? _local.pos : _local.data_len);\n", .{complete_frame});
    try self.writeI("return _rc;\n");
    try self.write("}\n\n");
    try self.print("static int {s}_bounded_impl({s}) {{\n", .{ name, args });
}

pub fn readRcCheck(self: anytype) !void {
    if (comptime @hasField(@TypeOf(self.*), "goto_label")) {
        if (self.goto_label) |label| {
            try self.printI("if (_rc) goto {s};\n", .{label});
            return;
        }
    }
    try self.writeI("if (_rc) return _rc;\n");
}

pub fn limitReader(self: anytype, end: []const u8) !void {
    try self.printI("_rc = zidl_cdr_reader_limit(_r, {s}, _r);\n", .{end});
    try readRcCheck(self);
}

pub fn memberWindow(self: anytype) !void {
    try self.writeI("_rc = zidl_cdr_emheader_end(_r, &_emh, &_member_end);\n");
    try readRcCheck(self);
    try limitReader(self, "_member_end");
}

/// A lexical collection window, closed before later fields are read. On error
/// the public traversal's stack reader keeps the caller's enclosing limit intact.
pub fn openReadWindow(self: anytype, needed: bool) !?usize {
    if (!needed) return null;
    const id = self.reader_window_id;
    self.reader_window_id += 1;
    try self.writeI("{\n");
    self.indent_depth += 1;
    try self.printI("size_t _read_end_{d} = (size_t)-1, _read_limit_{d} = _r->data_len;\n", .{ id, id });
    try self.writeI("if (_r->xcdr_version == ZIDL_XCDR2) {\n");
    self.indent_depth += 1;
    try self.printI("_rc = zidl_cdr_read_mutable_dheader(_r, &_read_end_{d});\n", .{id});
    try readRcCheck(self);
    const end = try std.fmt.allocPrint(self.alloc, "_read_end_{d}", .{id});
    defer self.alloc.free(end);
    try limitReader(self, end);
    self.indent_depth -= 1;
    try self.writeI("}\n");
    return id;
}

pub fn closeReadWindow(self: anytype, window: ?usize) !void {
    const id = window orelse return;
    try self.printI("if (_read_end_{d} != (size_t)-1) _r->pos = _read_end_{d};\n", .{ id, id });
    try self.printI("_r->data_len = _read_limit_{d};\n", .{id});
    self.indent_depth -= 1;
    try self.writeI("}\n");
}
