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

fn bitBoundWidth(bound: ?u16) usize {
    const b = bound orelse 32;
    return if (b <= 8) 1 else if (b <= 16) 2 else if (b <= 32) 4 else 8;
}

// ── Skip emitters ────────────────────────────────────────────────────────────

pub fn emitSkipMember(self: anytype, m: ir.StructMember) anyerror!void {
    if (m.annotations.is_optional) {
        try self.writeI("{ bool _present;\n");
        self.indent_depth += 1;
        try self.writeI("_rc = zidl_cdr_read_bool(_r, &_present);\n");
        try self.writeI("if (_rc) return _rc;\n");
        try self.writeI("if (_present) {\n");
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
    // Fixed-size primitive element with all dims known → one bulk advance.
    if (dim_idx == 0) {
        if (typeRefPrimWireSize(elem_tr)) |sz| {
            var total: u64 = 1;
            for (dims) |d| total *= d;
            try self.printI("_rc = zidl_cdr_skip_primitives(_r, {d}u, {d}); if (_rc) return _rc;\n", .{ total, sz });
            return;
        }
    }
    const var_name = try std.fmt.allocPrint(self.alloc, "_ski{d}", .{dim_idx});
    defer self.alloc.free(var_name);
    try self.printI("{{ uint32_t {s}; for ({s} = 0; {s} < {d}u; {s}++) {{\n", .{
        var_name, var_name, var_name, dims[0], var_name,
    });
    self.indent_depth += 1;
    if (dims.len > 1) {
        try emitSkipArray(self, elem_tr, dims[1..], dim_idx + 1);
    } else {
        try emitSkipForTypeRef(self, elem_tr);
    }
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
                try self.writeI("return ZIDL_CDR_INVALID;\n");
            } else {
                try self.printI("{{ {s} _tmp; _rc = {s}(_r, &_tmp); if (_rc) return _rc; }}\n", .{ c_type, fn_name });
            }
        },
        .string => {
            try self.writeI("{ const char *_sp; uint32_t _sl; _rc = zidl_cdr_read_string_zerocopy(_r, &_sp, &_sl); if (_rc) return _rc; }\n");
        },
        .wstring => {
            try self.writeI("{ uint32_t _wl; _rc = zidl_cdr_read_u32(_r, &_wl); if (_rc) return _rc; for (uint32_t _wi = 0; _wi < _wl; _wi++) { uint16_t _wc; _rc = zidl_cdr_read_u16(_r, &_wc); if (_rc) return _rc; } }\n");
        },
        .sequence => |seq| {
            try self.writeI("{ uint32_t _sl;\n");
            self.indent_depth += 1;
            try self.writeI("_rc = zidl_cdr_read_u32(_r, &_sl);\n");
            try self.writeI("if (_rc) return _rc;\n");
            if (typeRefPrimWireSize(seq.element.*)) |sz| {
                try self.printI("_rc = zidl_cdr_skip_primitives(_r, _sl, {d}); if (_rc) return _rc;\n", .{sz});
            } else {
                try self.writeI("for (uint32_t _si = 0; _si < _sl; _si++) {\n");
                self.indent_depth += 1;
                try emitSkipForTypeRef(self, seq.element.*);
                self.indent_depth -= 1;
                try self.writeI("}\n");
            }
            self.indent_depth -= 1;
            try self.writeI("}\n");
        },
        .map => |m| {
            try self.writeI("{ uint32_t _ml;\n");
            self.indent_depth += 1;
            try self.writeI("_rc = zidl_cdr_read_u32(_r, &_ml);\n");
            try self.writeI("if (_rc) return _rc;\n");
            try self.writeI("for (uint32_t _mi = 0; _mi < _ml; _mi++) {\n");
            self.indent_depth += 1;
            try emitSkipForTypeRef(self, m.key.*);
            try emitSkipForTypeRef(self, m.value.*);
            self.indent_depth -= 1;
            try self.writeI("}\n");
            self.indent_depth -= 1;
            try self.writeI("}\n");
        },
        .named => |td| switch (td) {
            .enum_ => |e| {
                const suffix = enumCdrSuffix(e.annotations.bit_bound);
                const ctype = enumCdrType(e.annotations.bit_bound);
                try self.printI("{{ {s} _tmp; _rc = zidl_cdr_read_{s}(_r, &_tmp); if (_rc) return _rc; }}\n", .{ ctype, suffix });
            },
            .bitmask => |bm| {
                const suffix = enumCdrSuffix(bm.annotations.bit_bound);
                const ctype = enumCdrType(bm.annotations.bit_bound);
                try self.printI("{{ {s} _tmp; _rc = zidl_cdr_read_{s}(_r, &_tmp); if (_rc) return _rc; }}\n", .{ ctype, suffix });
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
                try self.printI("_rc = {s}_skip(_r);\n", .{c_type});
                try self.writeI("if (_rc) return _rc;\n");
            },
            .bitset => |bs| {
                var total: u32 = 0;
                for (bs.fields) |f| total += f.bits;
                const ctype = if (total <= 8) "uint8_t" else if (total <= 16) "uint16_t" else if (total <= 32) "uint32_t" else "uint64_t";
                const suffix = if (total <= 8) "u8" else if (total <= 16) "u16" else if (total <= 32) "u32" else "u64";
                try self.printI("{{ {s} _tmp; _rc = zidl_cdr_read_{s}(_r, &_tmp); if (_rc) return _rc; }}\n", .{ ctype, suffix });
            },
            else => try self.writeI("return ZIDL_CDR_INVALID;\n"),
        },
        .fixed_pt => |fp| {
            try self.printI("{{ double _tmp; _rc = zidl_cdr_read_fixed(_r, {d}, {d}, &_tmp); if (_rc) return _rc; }}\n", .{ fp.digits, fp.scale });
        },
    }
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
