//! C++ language mapping backend (OMG IDL4-native C++ v1.0, formal-25-03-03.pdf).
//!
//! Generates a single `.hpp` header per IDL spec containing:
//!   - Module → namespace (nested, no name-flattening)
//!   - Struct → struct with default-initialised members
//!   - Enum → enum class : uint32_t (or smaller per @bit_bound)
//!   - Union → class with _d() accessor + private anonymous union
//!   - Interface → abstract class with pure-virtual methods
//!   - Exception → struct inheriting std::exception
//!   - Bitmask → using alias + constexpr bit constants
//!   - Bitset → struct with bitfield members
//!   - Typedef → using alias (arrays use std::array<T,N>)
//!   - Native → forward-declared class
//!   - Const → constexpr constant
//!
//! ## Primitive type mapping
//!
//!   IDL short / long / long long       → int16_t / int32_t / int64_t
//!   IDL unsigned short / long / …      → uint16_t / uint32_t / uint64_t
//!   IDL float / double / long double   → float / double / long double
//!   IDL char / wchar                   → char / wchar_t
//!   IDL boolean / octet                → bool / uint8_t
//!   IDL int8 … uint64                  → int8_t … uint64_t
//!   IDL string / wstring               → std::string / std::wstring
//!   IDL sequence<T>                    → std::vector<T>
//!   IDL map<K,V>                       → std::map<K,V>
//!   IDL any / object / value_base      → void *
//!   IDL fixed<D,S>                     → double (approximate)
//!
//! ## Notes
//!
//! Named type references always use the `::` fully-qualified prefix so they
//! resolve unambiguously inside any namespace.  Example: a type `Foo::Bar::Baz`
//! is referenced as `::Foo::Bar::Baz`.
//!
//! Unions with cases of non-trivially-constructible types (std::string,
//! std::vector, …) get explicit constructor/destructor/copy special member
//! functions generated for them (declared in the header, defined out-of-line
//! in the .cpp), since a raw anonymous union with such a member has no
//! usable implicit ones.  `_d()` -- not just the ctor/dtor/copy ops -- is
//! also responsible for placement-constructing/destroying the active case
//! when the discriminant changes; case setters assume `_d()` was already
//! called with a matching value, which is how (de)serialization always
//! calls them.

const std = @import("std");
const ast = @import("../ast.zig");
const ir = @import("../ir/root.zig");
const cdr_skip = @import("cdr_skip.zig");
const interface = @import("interface.zig");

// Stack buffer size for get_key_value; zzdds returns an error if the serialized
// key exceeds this.  Exposed in generated C++ as ZZDDS_KEY_VALUE_BUF_SIZE.
const key_value_buf_size: u32 = 4096;

// ── Public backend struct ─────────────────────────────────────────────────────

pub const CppBackend = struct {
    alloc: std.mem.Allocator,

    pub fn create(alloc: std.mem.Allocator) !*CppBackend {
        const self = try alloc.create(CppBackend);
        self.* = .{ .alloc = alloc };
        return self;
    }

    /// Return a `Backend` value that dispatches to this instance.
    pub fn backend(self: *CppBackend) interface.Backend {
        return .{ .ctx = self, .vtable = &vtable };
    }

    const vtable = interface.Backend.Vtable{
        .language_id = "cpp",
        .generate = vtableGenerate,
        .deinit = vtableDeinit,
    };

    fn vtableGenerate(
        ctx: *anyopaque,
        spec: *const ir.Spec,
        opts: interface.Options,
    ) anyerror!void {
        const self: *CppBackend = @ptrCast(@alignCast(ctx));
        const io = std.Io.Threaded.global_single_threaded.io();

        if (opts.split_files) {
            try generateSplitFiles(self.alloc, io, spec, opts);
            return;
        }

        // ── <stem>.hpp ────────────────────────────────────────────────────────
        var header_content = std.ArrayList(u8).empty;
        defer header_content.deinit(self.alloc);
        try generateHeader(self.alloc, spec, opts, &header_content);
        const hpp_filename = try std.fmt.allocPrint(self.alloc, "{s}.hpp", .{opts.input_stem});
        defer self.alloc.free(hpp_filename);
        try writeOutputFile(self.alloc, io, opts, hpp_filename, header_content.items);

        // ── <stem>_cdr.cpp ───────────────────────────────────────────────────
        if (!opts.no_typesupport) {
            var cdr_content = std.ArrayList(u8).empty;
            defer cdr_content.deinit(self.alloc);
            try generateCdrSource(self.alloc, spec, opts, &cdr_content);
            const cpp_filename = try std.fmt.allocPrint(self.alloc, "{s}_cdr.cpp", .{opts.input_stem});
            defer self.alloc.free(cpp_filename);
            try writeOutputFile(self.alloc, io, opts, cpp_filename, cdr_content.items);
        }

        // ── <stem>_impl.cpp ──────────────────────────────────────────────────
        // Skipped when cpp_generate_impl is also set: generateConcreteImpl writes
        // the same filename and subsumes the listener bridge + factory output.
        if (opts.generate_interfaces and !opts.cpp_generate_impl) {
            var impl_content = std.ArrayList(u8).empty;
            defer impl_content.deinit(self.alloc);
            try generateImplSource(self.alloc, spec, opts, &impl_content);
            const impl_filename = try std.fmt.allocPrint(self.alloc, "{s}_impl.cpp", .{opts.input_stem});
            defer self.alloc.free(impl_filename);
            try writeOutputFile(self.alloc, io, opts, impl_filename, impl_content.items);
        }

        // ── <stem>_impl.hpp + <stem>_impl.cpp (concrete DDS impls) ──────────
        if (opts.cpp_generate_impl) {
            var hdr_content = std.ArrayList(u8).empty;
            defer hdr_content.deinit(self.alloc);
            var src_content = std.ArrayList(u8).empty;
            defer src_content.deinit(self.alloc);
            try generateConcreteImpl(self.alloc, spec, opts, &hdr_content, &src_content);
            const hdr_filename = try std.fmt.allocPrint(self.alloc, "{s}_impl.hpp", .{opts.input_stem});
            defer self.alloc.free(hdr_filename);
            const src_filename2 = try std.fmt.allocPrint(self.alloc, "{s}_impl.cpp", .{opts.input_stem});
            defer self.alloc.free(src_filename2);
            try writeOutputFile(self.alloc, io, opts, hdr_filename, hdr_content.items);
            try writeOutputFile(self.alloc, io, opts, src_filename2, src_content.items);
        }
    }

    fn vtableDeinit(ctx: *anyopaque) void {
        const self: *CppBackend = @ptrCast(@alignCast(ctx));
        self.alloc.destroy(self);
    }
};

// ── Public entry point (testable) ─────────────────────────────────────────────

/// Generate C++ header content into `out`.
///
/// Exposed for unit testing without touching the filesystem.
/// The vtable's `vtableGenerate` calls this then writes the result to
/// `<opts.output_dir>/<opts.input_stem>.hpp`.
pub fn generateHeader(
    alloc: std.mem.Allocator,
    spec: *const ir.Spec,
    opts: interface.Options,
    out: *std.ArrayList(u8),
) !void {
    var gen = Generator{ .alloc = alloc, .opts = opts, .out = out };
    defer gen.entity_base_ifaces.deinit(alloc);
    try gen.emitHeader(spec);
}

/// Generate C++ CDR serialization source content into `out`.
///
/// Exposed for unit testing without touching the filesystem.
/// The vtable's `vtableGenerate` calls this then writes the result to
/// `<opts.output_dir>/<opts.input_stem>_cdr.cpp`.
pub fn generateCdrSource(
    alloc: std.mem.Allocator,
    spec: *const ir.Spec,
    opts: interface.Options,
    out: *std.ArrayList(u8),
) !void {
    var gen = CdrGenerator{ .alloc = alloc, .opts = opts, .out = out };
    try gen.emitSource(spec);
}

// ── Generator (private implementation) ───────────────────────────────────────

const Generator = struct {
    alloc: std.mem.Allocator,
    opts: interface.Options,
    out: *std.ArrayList(u8),
    // Pre-scanned set of non-callback interface qualified names that appear as
    // bases in another non-callback interface.  Populated by emitHeader when
    // generate_interfaces is set; used by emitInterface to decide whether to
    // emit native_handle() on the abstract class.
    entity_base_ifaces: std.StringHashMapUnmanaged(void) = .{},

    // ── Low-level output helpers ──────────────────────────────────────────────

    fn write(self: *Generator, s: []const u8) !void {
        try self.out.appendSlice(self.alloc, s);
    }

    fn print(self: *Generator, comptime fmt: []const u8, args: anytype) !void {
        const s = try std.fmt.allocPrint(self.alloc, fmt, args);
        defer self.alloc.free(s);
        try self.out.appendSlice(self.alloc, s);
    }

    // ── Top-level header emission ─────────────────────────────────────────────

    const IncludeNeeds = struct {
        map: bool = false,
        optional: bool = false,
        union_arrays: bool = false,
        memory: bool = false,
        union_lifetime: bool = false,
    };

    fn scanIncludes(items: []const ir.ModuleItem) IncludeNeeds {
        var needs = IncludeNeeds{};
        scanIncludesItems(items, &needs);
        return needs;
    }

    fn scanIncludesItems(items: []const ir.ModuleItem, needs: *IncludeNeeds) void {
        for (items) |item| {
            switch (item) {
                .module => |m| scanIncludesItems(m.items, needs),
                .type_decl => |td| switch (td) {
                    .struct_ => |s| {
                        for (s.members) |mem| {
                            if (mem.annotations.is_optional) needs.optional = true;
                            scanIncludesTypeRef(mem.type_ref, needs);
                        }
                    },
                    .union_ => |u| {
                        for (u.cases) |c| {
                            if (c.dimensions.len > 0) needs.union_arrays = true;
                            scanIncludesTypeRef(c.type_ref, needs);
                        }
                        if (unionNeedsCppLifetime(u)) needs.union_lifetime = true;
                    },
                    .exception => |e| {
                        for (e.members) |mem| {
                            if (mem.annotations.is_optional) needs.optional = true;
                            scanIncludesTypeRef(mem.type_ref, needs);
                        }
                    },
                    .interface => |iface| scanIncludesInterface(iface, needs),
                    else => {},
                },
                .const_ => {},
            }
        }
    }

    fn scanIncludesTypeRef(tr: ir.TypeRef, needs: *IncludeNeeds) void {
        switch (tr) {
            .map => needs.map = true,
            .sequence => |s| scanIncludesTypeRef(s.element.*, needs),
            .named => |td| {
                if (td == .interface) needs.memory = true;
            },
            else => {},
        }
    }

    fn scanIncludesInterface(iface: *const ir.Interface, needs: *IncludeNeeds) void {
        for (iface.type_decls) |td| scanIncludesTypeDecl(td, needs);
        for (iface.operations) |op| {
            if (op.return_type) |rt| scanIncludesTypeRef(rt, needs);
            for (op.params) |p| scanIncludesTypeRef(p.type_ref, needs);
        }
        for (iface.attributes) |attr| scanIncludesTypeRef(attr.type_ref, needs);
    }

    fn emitHeader(self: *Generator, spec: *const ir.Spec) !void {
        const guard = try self.headerGuard();
        defer self.alloc.free(guard);

        const needs = scanIncludes(spec.items);

        try self.print(
            "// Generated by zidl from {s}.idl — DO NOT EDIT\n\n",
            .{self.opts.input_stem},
        );
        if (self.opts.pragma_once) {
            try self.write("#pragma once\n\n");
        } else {
            try self.print("#ifndef {s}\n#define {s}\n\n", .{ guard, guard });
        }
        try self.write("#include <cstdint>\n");
        try self.write("#include <string>\n");
        try self.write("#include <vector>\n");
        if (self.opts.cpp_pmr_containers) try self.write("#include <memory_resource>\n");
        // Entity interfaces and entity_in adapters use std::shared_ptr whenever
        // interface generation is enabled.
        if (self.opts.generate_interfaces) try self.write("#include <memory>\n");
        if (needs.map) try self.write("#include <map>\n");
        if (needs.optional) try self.write("#include <optional>\n");
        if (needs.union_arrays) try self.write("#include <cstring>\n");
        if (needs.union_lifetime) try self.write("#include <new>\n");
        try self.write("#include <array>\n");
        try self.write("#include <stdexcept>\n");
        if (!self.opts.no_typesupport) {
            try self.write("#include \"zidl_cdr.h\"\n");
        }
        if (self.opts.generate_zzdds_wrappers and !self.opts.no_typesupport and itemsHaveZzddsTopicStructCpp(spec.items)) {
            try self.write("#include \"zzdds_c.h\"\n");
            try self.write("#include <unordered_map>\n");
        }
        for (spec.imports) |import_name| {
            const stem = try interface.includeStemForImport(self.alloc, import_name);
            defer self.alloc.free(stem);
            try self.print("#include \"{s}.hpp\"\n", .{stem});
        }
        // When emitting abstract DDS interfaces, pre-scan the spec to find which
        // interfaces appear as bases (so we can skip native_handle() on them —
        // adding it to both a base and a derived class causes return-type conflicts).
        // Only add #include "{stem}.h" when there are module-scoped leaf entity
        // interfaces that actually need the C handle types.
        if (self.opts.generate_interfaces) {
            try interface.collectEntityBaseNames(self.alloc, spec.items, &self.entity_base_ifaces);
            // Include the C header when any interface needs C ABI types:
            // native_handle() returns C entity handles; c_listener() returns C listener structs.
            if (hasNativeHandleInterfaces(spec.items, &self.entity_base_ifaces) or
                hasCallbackInterfaces(spec.items))
            {
                try self.print("#include \"{s}.h\"\n", .{self.opts.input_stem});
            }
        }
        try self.write("\n");
        if (self.opts.cpp_namespace.len > 0) {
            try self.print("namespace {s} {{\n\n", .{self.opts.cpp_namespace});
        }

        try self.emitItems(spec.items);

        if (self.opts.generate_zzdds_wrappers and !self.opts.no_typesupport) {
            try self.emitAllZzddsWrapperDecls(spec.items);
        }

        // CDR protos are suppressed when the C header ({stem}.h) is included by
        // this file.  The C header is the authoritative source for C ABI function
        // declarations; if we re-declare them in .hpp with C++ type names
        // (::DDS::Foo*) the compiler sees conflicting declarations (e.g.
        // DDS_BuiltinTopicKey_t* ≠ ::DDS::BuiltinTopicKey_t*) in any TU that
        // includes both headers.  The C header is included iff generate_interfaces
        // AND at least one native-handle or callback interface is present.  For
        // type-only IDLs (e.g. types.idl) neither condition holds, so the C header
        // is not included and CDR protos belong here in the .hpp.
        const has_c_header = self.opts.generate_interfaces and
            (hasNativeHandleInterfaces(spec.items, &self.entity_base_ifaces) or
                hasCallbackInterfaces(spec.items));
        if (!self.opts.no_typesupport and !has_c_header) {
            try self.emitCdrProtos(spec.items);
        }

        if (self.opts.cpp_namespace.len > 0) {
            try self.print("\n}} // namespace {s}\n", .{self.opts.cpp_namespace});
        }
        if (!self.opts.pragma_once) {
            try self.print("#endif // {s}\n", .{guard});
        }
    }

    fn emitCdrProtos(self: *Generator, items: []const ir.ModuleItem) anyerror!void {
        // CDR helpers are C functions callable from both C and C++.  Buffer
        // the output; only emit the extern "C" wrapper if there are any protos
        // (avoids stray #endif lines in headers with no CDR types).
        var buf = std.ArrayList(u8).empty;
        defer buf.deinit(self.alloc);
        var inner = Generator{
            .alloc = self.alloc,
            .out = &buf,
            .opts = self.opts,
        };
        var any = false;
        try inner.collectCdrProtos(items, &any);
        if (any) {
            try self.write("#ifdef __cplusplus\nextern \"C\" {\n#endif\n\n");
            try self.out.appendSlice(self.alloc, buf.items);
            try self.write("\n#ifdef __cplusplus\n}\n#endif\n");
        }
    }

    fn collectCdrProtos(self: *Generator, items: []const ir.ModuleItem, any: *bool) anyerror!void {
        for (items) |item| {
            switch (item) {
                .module => |m| try self.collectCdrProtos(m.items, any),
                .type_decl => |td| switch (td) {
                    .struct_ => |s| {
                        if (!any.*) {
                            try self.write("// --- CDR type support ---\n\n");
                            any.* = true;
                        }
                        try self.emitStructCdrProtos(s);
                    },
                    .exception => |e| {
                        if (!any.*) {
                            try self.write("// --- CDR type support ---\n\n");
                            any.* = true;
                        }
                        try self.emitExceptionCdrProtos(e);
                    },
                    .union_ => |u| {
                        if (!any.*) {
                            try self.write("// --- CDR type support ---\n\n");
                            any.* = true;
                        }
                        try self.emitUnionCdrProtos(u);
                    },
                    else => {},
                },
                .const_ => {},
            }
        }
    }

    fn prefixedCName(self: *Generator, qname: []const u8) ![]u8 {
        return interface.prefixedCNameFromQualified(self.alloc, qname, self.opts.type_prefix);
    }

    fn emitStructCdrProtos(self: *Generator, s: *const ir.Struct) !void {
        const c_name = try self.prefixedCName(s.qualified_name);
        defer self.alloc.free(c_name);
        const cpp_qname = try std.fmt.allocPrint(self.alloc, "::{s}", .{s.qualified_name});
        defer self.alloc.free(cpp_qname);

        const has_key = structHasKeyCpp(s);
        const em = self.opts.export_macro;
        const sp: []const u8 = if (em.len > 0) " " else "";
        try self.print("#define {s}_has_key {d}\n", .{ c_name, @intFromBool(has_key) });
        try self.print("{s}{s}int {s}_serialize(ZidlCdrWriter *_w, const {s} *_v);\n", .{ em, sp, c_name, cpp_qname });
        try self.print("{s}{s}int {s}_deserialize(ZidlCdrReader *_r, {s} *_v);\n", .{ em, sp, c_name, cpp_qname });
        try self.print("{s}{s}int {s}_skip(ZidlCdrReader *_r);\n", .{ em, sp, c_name });
        // Keyless structs still get these prototypes when wrappers were
        // requested -- see the matching `else if` in the CDR generator's
        // struct-fns emission, which emits trivial (constant-zero-hash)
        // bodies for them.
        if (has_key or (self.opts.generate_zzdds_wrappers and isZzddsTopicStructCpp(s))) {
            try self.print("{s}{s}int {s}_serialize_key(ZidlCdrWriter *_w, const {s} *_v);\n", .{ em, sp, c_name, cpp_qname });
            try self.print("{s}{s}int {s}_deserialize_key(ZidlCdrReader *_r, {s} *_v);\n", .{ em, sp, c_name, cpp_qname });
            try self.print("{s}{s}int {s}_compute_key_hash(const {s} *_v, uint8_t _hash[16]);\n", .{ em, sp, c_name, cpp_qname });
            try self.print("{s}{s}int {s}_compute_key_hash_from_cdr(const uint8_t *_payload, size_t _len, uint8_t _hash[16]);\n", .{ em, sp, c_name });
        }
        // Unlike _compute_key_hash_from_cdr above (generic C types only, so
        // it's emitted whenever has_key), this one's signature depends on
        // zzdds_c.h's zzdds_filter_value -- only emit it when that header is
        // actually included (--generate-zzdds-wrappers).
        if (self.opts.generate_zzdds_wrappers and isZzddsTopicStructCpp(s)) {
            try self.print("{s}{s}bool {s}_get_field_from_cdr(const uint8_t *_payload, size_t _payload_len, const char *_field, size_t _field_len, zzdds_filter_value *_out, uint8_t *_scratch, size_t _scratch_len);\n", .{ em, sp, c_name });
            // Selective-parse family (no _deinit_selected: RAII).
            try self.print("#define {s}_KEY_FIELD_MASK ((uint64_t)(", .{c_name});
            var first_k = true;
            for (s.members, 0..) |m, idx| {
                if (!m.annotations.is_key or s.base != null or s.members.len > 64) continue;
                if (!first_k) try self.write(" | ");
                try self.print("(1ull << {d})", .{idx});
                first_k = false;
            }
            if (first_k) try self.write("0");
            try self.write("))\n");
            try self.print("{s}{s}bool {s}_field_index(const char *_name, size_t _name_len, uint32_t *_out_idx);\n", .{ em, sp, c_name });
            try self.print("{s}{s}int {s}_deserialize_selected(ZidlCdrReader *_r, uint64_t _want, {s} *_v);\n", .{ em, sp, c_name, cpp_qname });
        }
        try self.write("\n");
    }

    fn emitAllZzddsWrapperDecls(self: *Generator, items: []const ir.ModuleItem) anyerror!void {
        for (items) |item| {
            switch (item) {
                .module => |m| try self.emitAllZzddsWrapperDecls(m.items),
                .type_decl => |td| switch (td) {
                    .struct_ => |s| {
                        if (isZzddsTopicStructCpp(s)) {
                            const cpp_qname = try std.fmt.allocPrint(self.alloc, "::{s}", .{s.qualified_name});
                            defer self.alloc.free(cpp_qname);
                            try self.emitStructZzddsWrapperDecls(s, cpp_qname);
                        }
                    },
                    else => {},
                },
                else => {},
            }
        }
    }

    fn emitStructZzddsWrapperDecls(self: *Generator, s: *const ir.Struct, cpp_qname: []const u8) !void {
        const class_name = s.name;
        const ns = moduleNsOf(s.qualified_name, s.name);

        // A2: open namespace if the struct lives inside an IDL module
        if (ns.len > 0) {
            var it = std.mem.splitSequence(u8, ns, "::");
            while (it.next()) |seg| try self.print("namespace {s} {{\n", .{seg});
            try self.write("\n");
        }

        try self.print("class {s}TypeSupport {{\n", .{class_name});
        try self.write("public:\n");
        // A1: default type_name uses the IDL-scoped name (e.g. "ovidds::Frame")
        try self.print("    static int register_type(DDS_DomainParticipant participant, const char *type_name = \"{s}\");\n", .{s.qualified_name});
        try self.write("};\n\n");

        try self.print("class {s}DataWriter {{\n", .{class_name});
        try self.write("public:\n");
        try self.print("    {s}DataWriter(DDS_DataWriter writer, int xcdr_version = ZIDL_XCDR1) : writer_(writer), xcdr_version_(xcdr_version) {{}}\n", .{class_name});
        try self.print("    DDS_InstanceHandle_t register_instance(const {s}& key);\n", .{cpp_qname});
        try self.print("    DDS_InstanceHandle_t register_instance_w_timestamp(const {s}& key, DDS_Time_t timestamp);\n", .{cpp_qname});
        try self.print("    int write(const {s}& value);\n", .{cpp_qname});
        try self.print("    int write_w_timestamp(const {s}& value, DDS_Time_t timestamp);\n", .{cpp_qname});
        try self.print("    int dispose(const {s}& key);\n", .{cpp_qname});
        try self.print("    int dispose_w_timestamp(const {s}& key, DDS_Time_t timestamp);\n", .{cpp_qname});
        try self.print("    int unregister_instance(const {s}& key);\n", .{cpp_qname});
        try self.print("    int unregister_instance_w_timestamp(const {s}& key, DDS_Time_t timestamp);\n", .{cpp_qname});
        try self.print("    int get_key_value(DDS_InstanceHandle_t handle, {s}& key_out);\n", .{cpp_qname});
        try self.print("    DDS_InstanceHandle_t lookup_instance(const {s}& key);\n", .{cpp_qname});
        try self.print("    int write_w_handle(const {s}& value, DDS_InstanceHandle_t handle);\n", .{cpp_qname});
        try self.print("    int dispose_w_handle(const {s}& key, DDS_InstanceHandle_t handle);\n", .{cpp_qname});
        try self.print("    int unregister_instance_w_handle(const {s}& key, DDS_InstanceHandle_t handle);\n", .{cpp_qname});
        try self.write("private:\n");
        try self.write("    DDS_DataWriter writer_;\n");
        try self.write("    int xcdr_version_;\n");
        try self.write("    std::unordered_map<DDS_InstanceHandle_t, std::array<uint8_t, 16>> instance_handles_;\n");
        try self.write("};\n\n");

        try self.print("class {s}DataReader {{\n", .{class_name});
        try self.write("public:\n");
        try self.print("    struct Sample {{ {s} value; DDS_SampleInfo info; }};\n", .{cpp_qname});
        try self.write("    class Loan {\n");
        try self.write("    public:\n");
        try self.write("        Loan() = default;\n");
        // take_loaned/return_loan's own signature deliberately changed here:
        // the Loan now owns a DDS_OctetSeqSeq/DDS_SampleInfoSeq pair
        // (zero-initialized via {} at the member declarations below) instead
        // of the old hand-written zzdds_loaned_sample -- it's what carries
        // the open loan between take_loaned() and reset(), matching the raw
        // ops' own caller-owned-storage convention instead of a separate ad
        // hoc type.
        try self.print("        Loan({s}DataReader *reader, DDS_OctetSeqSeq loan_payloads, DDS_SampleInfoSeq loan_infos, Sample sample) : reader_(reader), loan_payloads_(loan_payloads), loan_infos_(loan_infos), sample_(sample), active_(true) {{}}\n", .{class_name});
        try self.write("        Loan(const Loan&) = delete;\n");
        try self.write("        Loan& operator=(const Loan&) = delete;\n");
        try self.write("        Loan(Loan&& other) noexcept : reader_(other.reader_), loan_payloads_(other.loan_payloads_), loan_infos_(other.loan_infos_), sample_(other.sample_), active_(other.active_) { other.active_ = false; }\n");
        try self.write("        Loan& operator=(Loan&& other) noexcept { if (this != &other) { reset(); reader_ = other.reader_; loan_payloads_ = other.loan_payloads_; loan_infos_ = other.loan_infos_; sample_ = other.sample_; active_ = other.active_; other.active_ = false; } return *this; }\n");
        try self.write("        ~Loan() { reset(); }\n");
        try self.write("        const Sample& sample() const { return sample_; }\n");
        try self.write("        void reset();\n");
        try self.write("    private:\n");
        try self.print("        {s}DataReader *reader_ = nullptr;\n", .{class_name});
        try self.write("        DDS_OctetSeqSeq loan_payloads_{};\n");
        try self.write("        DDS_SampleInfoSeq loan_infos_{};\n");
        try self.write("        Sample sample_{};\n");
        try self.write("        bool active_ = false;\n");
        try self.write("    };\n");
        try self.print("    explicit {s}DataReader(DDS_DataReader reader) : reader_(reader) {{}}\n", .{class_name});
        try self.write("    DDS_ReturnCode_t take(Sample& out, uint8_t *buf, size_t buf_size, size_t *cdr_len_out);\n");
        try self.write("    DDS_ReturnCode_t read(Sample& out, uint8_t *buf, size_t buf_size, size_t *cdr_len_out);\n");
        try self.write("    DDS_ReturnCode_t take_next_instance(Sample& out, DDS_InstanceHandle_t prev, uint8_t *buf, size_t buf_size, size_t *cdr_len_out);\n");
        try self.write("    DDS_ReturnCode_t read_next_instance(Sample& out, DDS_InstanceHandle_t prev, uint8_t *buf, size_t buf_size, size_t *cdr_len_out);\n");
        try self.print("    int get_key_value(DDS_InstanceHandle_t handle, {s}& key_out);\n", .{cpp_qname});
        try self.print("    DDS_InstanceHandle_t lookup_instance(const {s}& key);\n", .{cpp_qname});
        try self.print("    int take_n({s} *values, DDS_SampleInfo *infos, int max, uint32_t ss, uint32_t vs, uint32_t is);\n", .{cpp_qname});
        try self.print("    int read_n({s} *values, DDS_SampleInfo *infos, int max, uint32_t ss, uint32_t vs, uint32_t is);\n", .{cpp_qname});
        try self.print("    int take_instance(DDS_InstanceHandle_t instance_handle, {s} *values, DDS_SampleInfo *infos, int max, uint32_t ss, uint32_t vs, uint32_t is);\n", .{cpp_qname});
        try self.print("    int read_instance(DDS_InstanceHandle_t instance_handle, {s} *values, DDS_SampleInfo *infos, int max, uint32_t ss, uint32_t vs, uint32_t is);\n", .{cpp_qname});
        try self.print("    int take_w_condition(DDS_ReadCondition condition, {s} *values, DDS_SampleInfo *infos, int max);\n", .{cpp_qname});
        try self.print("    int read_w_condition(DDS_ReadCondition condition, {s} *values, DDS_SampleInfo *infos, int max);\n", .{cpp_qname});
        try self.print("    int take_next_instance_w_condition(DDS_ReadCondition condition, DDS_InstanceHandle_t prev, {s} *values, DDS_SampleInfo *infos, int max);\n", .{cpp_qname});
        try self.print("    int read_next_instance_w_condition(DDS_ReadCondition condition, DDS_InstanceHandle_t prev, {s} *values, DDS_SampleInfo *infos, int max);\n", .{cpp_qname});
        try self.write("    DDS_ReturnCode_t take_loaned(Loan& out);\n");
        try self.write("private:\n");
        try self.write("    DDS_DataReader reader_;\n");
        try self.write("};\n\n");

        // A2: close namespace opened above
        if (ns.len > 0) {
            var segs: std.ArrayListUnmanaged([]const u8) = .empty;
            defer segs.deinit(self.alloc);
            var it2 = std.mem.splitSequence(u8, ns, "::");
            while (it2.next()) |seg| try segs.append(self.alloc, seg);
            var i = segs.items.len;
            while (i > 0) {
                i -= 1;
                try self.print("}} // namespace {s}\n", .{segs.items[i]});
            }
            try self.write("\n");
        }
    }

    fn emitExceptionCdrProtos(self: *Generator, e: *const ir.Exception) !void {
        const c_name = try self.prefixedCName(e.qualified_name);
        defer self.alloc.free(c_name);
        const cpp_qname = try std.fmt.allocPrint(self.alloc, "::{s}", .{e.qualified_name});
        defer self.alloc.free(cpp_qname);
        const em = self.opts.export_macro;
        const sp: []const u8 = if (em.len > 0) " " else "";
        try self.print("{s}{s}int {s}_serialize(ZidlCdrWriter *_w, const {s} *_v);\n", .{ em, sp, c_name, cpp_qname });
        try self.print("{s}{s}int {s}_deserialize(ZidlCdrReader *_r, {s} *_v);\n", .{ em, sp, c_name, cpp_qname });
        try self.write("\n");
    }

    fn emitUnionCdrProtos(self: *Generator, u: *const ir.Union) !void {
        const c_name = try self.prefixedCName(u.qualified_name);
        defer self.alloc.free(c_name);
        const cpp_qname = try std.fmt.allocPrint(self.alloc, "::{s}", .{u.qualified_name});
        defer self.alloc.free(cpp_qname);
        const em = self.opts.export_macro;
        const sp: []const u8 = if (em.len > 0) " " else "";
        try self.print("{s}{s}int {s}_serialize(ZidlCdrWriter *_w, const {s} *_v);\n", .{ em, sp, c_name, cpp_qname });
        try self.print("{s}{s}int {s}_deserialize(ZidlCdrReader *_r, {s} *_v);\n", .{ em, sp, c_name, cpp_qname });
        try self.print("{s}{s}int {s}_skip(ZidlCdrReader *_r);\n", .{ em, sp, c_name });
        try self.write("\n");
    }

    fn headerGuard(self: *Generator) ![]u8 {
        const prefix = self.opts.header_guard_prefix;
        const stem = self.opts.input_stem;
        const g = try std.fmt.allocPrint(self.alloc, "{s}{s}_HPP", .{ prefix, stem });
        for (g) |*c| {
            c.* = if (std.ascii.isAlphanumeric(c.*)) std.ascii.toUpper(c.*) else '_';
        }
        return g;
    }

    // ── Item / declaration emission ───────────────────────────────────────────

    fn emitItems(self: *Generator, items: []const ir.ModuleItem) anyerror!void {
        for (items) |item| {
            switch (item) {
                .module => |m| try self.emitModule(m),
                .type_decl => |td| try self.emitTypeDecl(td),
                .const_ => |c| try self.emitConst(c),
            }
        }
    }

    fn emitModule(self: *Generator, m: *const ir.Module) anyerror!void {
        if (m.items.len == 0) return;
        try self.print("namespace {s} {{\n\n", .{m.name});
        // Forward-declare all interfaces so listener method signatures can reference
        // entity types (DataReader, DataWriter, …) defined later in the same namespace.
        var wrote_any_fwd = false;
        for (m.items) |item| {
            switch (item) {
                .type_decl => |td| switch (td) {
                    .interface => |iface| {
                        try self.print("class {s};\n", .{iface.name});
                        wrote_any_fwd = true;
                    },
                    else => {},
                },
                else => {},
            }
        }
        if (wrote_any_fwd) try self.write("\n");
        try self.emitItems(m.items);
        try self.print("}} // namespace {s}\n\n", .{m.name});
    }

    fn emitTypeDecl(self: *Generator, td: ir.TypeDecl) anyerror!void {
        switch (td) {
            .struct_ => |s| try self.emitStruct(s),
            .union_ => |u| try self.emitUnion(u),
            .enum_ => |e| try self.emitEnum(e),
            .typedef => |t| try self.emitTypedef(t),
            .bitmask => |bm| try self.emitBitmask(bm),
            .bitset => |bs| try self.emitBitset(bs),
            .native => |n| try self.emitNative(n),
            .exception => |e| try self.emitException(e),
            .interface => |iface| try self.emitInterface(iface),
        }
    }

    // ── Struct ────────────────────────────────────────────────────────────────

    fn emitStruct(self: *Generator, s: *const ir.Struct) !void {
        try self.emitVerbatimForPlacement(s.annotations.raw, "before-declaration");
        try self.print("struct {s}", .{s.name});
        if (s.base) |base| {
            try self.print(" : ::{s}", .{ir.typeDeclQualifiedName(base)});
        }
        try self.write(" {\n");
        for (s.members) |m| {
            try self.emitMemberDecl(m.type_ref, m.name, m.dimensions, m.annotations.is_optional, m.annotations.default_value, "    ");
        }
        // Aggregate value-initialization zero-fills members without explicit
        // initializers, including raw array members.
        try self.print("\n    static {s} default_value() {{ return {s}{{}}; }}\n", .{ s.name, s.name });
        try self.print("}}; // struct {s}\n\n", .{s.name});
        try self.emitVerbatimForPlacement(s.annotations.raw, "after-declaration");
    }

    // ── Union ─────────────────────────────────────────────────────────────────

    fn emitUnion(self: *Generator, u: *const ir.Union) !void {
        try self.emitVerbatimForPlacement(u.annotations.raw, "before-declaration");
        const disc_cpp = try self.typeRefToCpp(u.discriminant);
        defer self.alloc.free(disc_cpp);
        const needs_lifetime = unionNeedsCppLifetime(u);

        try self.print("class {s} {{\npublic:\n", .{u.name});

        if (needs_lifetime) {
            // At least one case holds a non-trivially-constructible/
            // destructible type (std::string, std::vector, …). The raw
            // union below has no usable implicit special member functions
            // for that, so they're declared here and defined out-of-line
            // (in the .cpp) to placement-construct/destroy whichever case
            // `_disc` currently selects. `_d()` -- not just the ctor/dtor/
            // copy ops -- must also switch the active member: it's the only
            // point that knows a case change is happening, since the case
            // setter below doesn't know what was previously active.
            try self.print("    {s}();\n", .{u.name});
            try self.print("    {s}(const {s} &other);\n", .{ u.name, u.name });
            try self.print("    {s} &operator=(const {s} &other);\n", .{ u.name, u.name });
            // A real (not compiler-implicit) noexcept move ctor/assign,
            // needed for two reasons: (1) operator=(const&) copies into a
            // temporary first, then *moves* that temporary into *this so
            // nothing past the (only throwable) copy can fail -- but that's
            // only true if the move it performs is actually noexcept, not a
            // silent fallback to a throwing copy; (2) when this union is
            // itself used as a case inside another union, that outer
            // union's own move needs a real move to delegate to for the
            // same reason. Without these, std::move(other) here would bind
            // to the copy ctor above (a plain `const&` accepts an rvalue),
            // which reintroduces exactly the exception-safety hole this
            // whole lifecycle story exists to close.
            try self.print("    {s}({s} &&other) noexcept;\n", .{ u.name, u.name });
            try self.print("    {s} &operator=({s} &&other) noexcept;\n", .{ u.name, u.name });
            try self.print("    ~{s}();\n", .{u.name});
            try self.print("    void _d({s} v);\n", .{disc_cpp});
        } else {
            try self.print("    void _d({s} v) noexcept {{ _disc = v; }}\n", .{disc_cpp});
        }
        try self.print("    {s} _d() const noexcept {{ return _disc; }}\n", .{disc_cpp});

        // Case accessors (setter + getter). Valid once _d() has selected the
        // matching case -- a no-op for a union with no non-trivial cases.
        for (u.cases) |cas| {
            const mem_cpp = try self.typeRefToCpp(cas.type_ref);
            defer self.alloc.free(mem_cpp);
            if (cas.dimensions.len > 0) {
                const dims_str = try cArrayDimsStr(self.alloc, cas.dimensions);
                defer self.alloc.free(dims_str);
                if (typeRefIsCppNonTrivial(cas.type_ref)) {
                    // memcpy would corrupt a non-trivial element's internal
                    // representation (e.g. std::string) -- assign element-
                    // by-element into the already-constructed array instead.
                    const dst_base = try std.fmt.allocPrint(self.alloc, "_u._{s}", .{cas.name});
                    defer self.alloc.free(dst_base);
                    const loop = try arrayAssignLoopCpp(self.alloc, cas.dimensions, 0, dst_base, "v");
                    defer self.alloc.free(loop);
                    try self.print("    void {s}({s} const (&v){s}) {{ {s} }}\n", .{ cas.name, mem_cpp, dims_str, loop });
                } else {
                    try self.print("    void {s}({s} const (&v){s}) noexcept {{ std::memcpy(_u._{s}, v, sizeof(_u._{s})); }}\n", .{ cas.name, mem_cpp, dims_str, cas.name, cas.name });
                }
                try self.print("    auto {s}() const noexcept -> {s} const (&){s} {{ return _u._{s}; }}\n", .{ cas.name, mem_cpp, dims_str, cas.name });
            } else {
                try self.print("    void {s}({s} v) {{ _u._{s} = v; }}\n", .{ cas.name, mem_cpp, cas.name });
                try self.print("    {s} {s}() const {{ return _u._{s}; }}\n", .{ mem_cpp, cas.name, cas.name });
            }
        }

        try self.write("private:\n");
        if (needs_lifetime) {
            try self.write("    void _destroy_active() noexcept;\n");
            try self.write("    void _construct_default();\n");
            try self.print("    void _copy_construct_from(const {s} &other);\n", .{u.name});
            // Shared by the move ctor, move assignment, and operator=(const&)'s
            // temporary-to-*this step.
            try self.print("    void _move_construct_from({s} &other);\n", .{u.name});
        }
        try self.print("    {s} _disc{{}};\n", .{disc_cpp});
        if (needs_lifetime) {
            // A plain unnamed union has no way to name a constructor, so its
            // implicit default ctor/dtor stay deleted (ill-formed) for any
            // non-trivial member regardless of what special members Var
            // itself declares above. Naming the union type lets it get its
            // own EMPTY ctor/dtor -- "empty" is correct: no member is
            // constructed until _construct_default()/_d() placement-new one
            // in, and none is torn down here until _destroy_active() does,
            // both driven by the runtime discriminant, not by this type.
            try self.write("    union _Storage {\n");
        } else {
            try self.write("    union {\n");
        }
        for (u.cases) |cas| {
            const mem_cpp = try self.typeRefToCpp(cas.type_ref);
            defer self.alloc.free(mem_cpp);
            if (cas.dimensions.len > 0) {
                const dims_str = try cArrayDimsStr(self.alloc, cas.dimensions);
                defer self.alloc.free(dims_str);
                try self.print("        {s} _{s}{s};\n", .{ mem_cpp, cas.name, dims_str });
            } else {
                try self.print("        {s} _{s};\n", .{ mem_cpp, cas.name });
            }
        }
        if (needs_lifetime) {
            try self.write("        _Storage() {}\n");
            try self.write("        ~_Storage() {}\n");
        }
        try self.write("    } _u;\n");
        try self.print("}}; // class {s}\n\n", .{u.name});

        if (!self.opts.no_typesupport) {
            const c_name = try self.prefixedCName(u.qualified_name);
            defer self.alloc.free(c_name);
            const cpp_qname = try std.fmt.allocPrint(self.alloc, "::{s}", .{u.qualified_name});
            defer self.alloc.free(cpp_qname);
            const em = self.opts.export_macro;
            const sp: []const u8 = if (em.len > 0) " " else "";
            try self.print("#define {s}_has_key 0\n", .{c_name});
            try self.print("{s}{s}int {s}_serialize(ZidlCdrWriter *_w, const {s} *_v);\n", .{ em, sp, c_name, cpp_qname });
            try self.print("{s}{s}int {s}_deserialize(ZidlCdrReader *_r, {s} *_v);\n", .{ em, sp, c_name, cpp_qname });
            try self.write("\n");
        }
        try self.emitVerbatimForPlacement(u.annotations.raw, "after-declaration");
    }

    // ── Enum ──────────────────────────────────────────────────────────────────

    fn emitEnum(self: *Generator, e: *const ir.Enum) !void {
        try self.emitVerbatimForPlacement(e.annotations.raw, "before-declaration");
        const storage = enumStorageType(e.annotations);
        try self.print("enum class {s} : {s} {{\n", .{ e.name, storage });
        for (e.enumerators, 0..) |en, i| {
            const comma = if (i + 1 < e.enumerators.len) "," else "";
            try self.print("    {s} = {d}{s}\n", .{ en.name, en.value, comma });
        }
        try self.print("}}; // enum class {s}\n\n", .{e.name});
        try self.emitVerbatimForPlacement(e.annotations.raw, "after-declaration");
    }

    // ── Bitmask ───────────────────────────────────────────────────────────────

    fn emitBitmask(self: *Generator, bm: *const ir.Bitmask) !void {
        const storage = bitmaskStorageType(bm.annotations);
        try self.print("using {s} = {s};\n", .{ bm.name, storage });
        for (bm.bits, 0..) |bit, i| {
            try self.print(
                "constexpr {s} {s}_{s}{{{s}(1u << {d})}};\n",
                .{ bm.name, bm.name, bit.name, bm.name, i },
            );
        }
        try self.write("\n");
    }

    // ── Bitset ────────────────────────────────────────────────────────────────

    fn emitBitset(self: *Generator, bs: *const ir.Bitset) !void {
        try self.print("struct {s} {{\n", .{bs.name});
        for (bs.fields) |field| {
            const field_cpp = if (field.type_ref) |tr| blk: {
                const s = try self.typeRefToCpp(tr);
                break :blk s;
            } else try self.alloc.dupe(u8, "unsigned int");
            defer self.alloc.free(field_cpp);

            for (field.names) |fname| {
                try self.print("    {s} {s} : {d};\n", .{ field_cpp, fname, field.bits });
            }
        }
        try self.print("}}; // struct {s}\n\n", .{bs.name});
    }

    // ── Typedef ───────────────────────────────────────────────────────────────

    fn emitTypedef(self: *Generator, t: *const ir.Typedef) !void {
        const cpp_type = try self.typeRefToCpp(t.type_ref);
        defer self.alloc.free(cpp_type);

        if (t.dimensions.len == 0) {
            try self.print("using {s} = {s};\n\n", .{ t.name, cpp_type });
        } else {
            // Array typedef: IDL `typedef long Matrix[2][4]`
            // → C++  `using Matrix = std::array<std::array<int32_t, 4>, 2>;`
            const arr_type = try self.makeArrayType(cpp_type, t.dimensions);
            defer self.alloc.free(arr_type);
            try self.print("using {s} = {s};\n\n", .{ t.name, arr_type });
        }
    }

    /// Build a nested `std::array<…>` type string for an IDL array declaration.
    ///
    /// IDL dimensions are in declaration order: `T[d0][d1]` → `T[d0][d1]`.
    /// C++ `std::array` nests from the inside out:
    ///   `std::array<std::array<T, d1>, d0>`
    ///
    /// Caller owns the returned slice.
    fn makeArrayType(self: *Generator, elem_type: []const u8, dims: []const u64) anyerror![]u8 {
        if (dims.len == 0) return self.alloc.dupe(u8, elem_type);
        const inner = try self.makeArrayType(elem_type, dims[1..]);
        defer self.alloc.free(inner);
        return std.fmt.allocPrint(self.alloc, "std::array<{s}, {d}>", .{ inner, dims[0] });
    }

    // ── Native ────────────────────────────────────────────────────────────────

    fn emitNative(self: *Generator, n: *const ir.Native) !void {
        try self.print("class {s}; // @native\n\n", .{n.name});
    }

    // ── Exception ─────────────────────────────────────────────────────────────

    fn emitException(self: *Generator, e: *const ir.Exception) !void {
        try self.print("struct {s} : std::exception {{\n", .{e.name});
        try self.print(
            "    const char* what() const noexcept override {{ return \"{s}\"; }}\n",
            .{e.name},
        );
        for (e.members) |m| {
            try self.emitMemberDecl(m.type_ref, m.name, m.dimensions, false, null, "    ");
        }
        try self.print("}}; // struct {s}\n\n", .{e.name});
    }

    // ── Interface ─────────────────────────────────────────────────────────────

    fn emitInterface(self: *Generator, iface: *const ir.Interface) anyerror!void {
        // Emit nested type declarations before the class body.
        for (iface.type_decls) |td| {
            try self.emitTypeDecl(td);
        }
        // Emit nested consts before the class body.
        for (iface.consts) |*c| {
            try self.emitConst(c);
        }

        try self.print("class {s}", .{iface.name});
        if (iface.bases.len > 0) {
            try self.write(" : ");
            for (iface.bases, 0..) |base, i| {
                if (i > 0) try self.write(", ");
                try self.print("public ::{s}", .{ir.typeDeclQualifiedName(base)});
            }
        }
        try self.write(" {\npublic:\n");
        try self.print("    virtual ~{s}() = default;\n", .{iface.name});

        // Emit native_handle() on every entity interface that owns its own handle,
        // so callers can retrieve the underlying C handle without a static_cast
        // to Impl. Skipped for: callback/listener interfaces, top-level
        // (non-module) interfaces, interfaces that appear as bases in another
        // non-callback interface (which would create a return-type conflict in
        // derived Impl classes -- see ifaceOwnsNativeHandle), and interfaces
        // that already inherit a compatible one from a qualifying ancestor
        // (checked first -- see nativeHandleBaseFor -- since declaring a fresh
        // one here too would create two same-named virtuals with incompatible,
        // non-covariant return types, a hard compile error).
        if (self.opts.generate_interfaces and !isCallbackIface(iface)) {
            const in_module = std.mem.indexOfScalar(u8, iface.qualified_name, ':') != null;
            if (in_module and
                ifaceOwnsNativeHandle(&self.entity_base_ifaces, iface) and
                (try nativeHandleBaseFor(&self.entity_base_ifaces, iface)) == null)
            {
                const c_type = try self.prefixedCName(iface.qualified_name);
                defer self.alloc.free(c_type);
                try self.print("    virtual {s} native_handle() const noexcept = 0;\n", .{c_type});
            }
        }

        for (iface.operations) |op| {
            try self.emitOperation(&op);
        }
        for (iface.attributes) |attr| {
            try self.emitAttribute(&attr);
        }
        try self.print("}}; // class {s}\n\n", .{iface.name});

        // After the abstract interface, emit the concrete listener base class.
        // FooListenerBase provides default no-op overrides + c_listener() bridge.
        // Only emitted when generate_interfaces is set and this is a callback interface.
        if (self.opts.generate_interfaces and isCallbackIface(iface)) {
            try self.emitListenerBaseDecl(iface);
        }
    }

    fn emitListenerBaseDecl(self: *Generator, iface: *const ir.Interface) !void {
        const c_name = try self.prefixedCName(iface.qualified_name);
        defer self.alloc.free(c_name);

        var ops = std.ArrayListUnmanaged(ir.Operation).empty;
        defer ops.deinit(self.alloc);
        var attrs = std.ArrayListUnmanaged(ir.Attribute).empty;
        defer attrs.deinit(self.alloc);
        try collectIfaceMembers(self.alloc, iface, &ops, &attrs);

        try self.print("class {s}Base : public ::{s} {{\npublic:\n", .{
            iface.name, iface.qualified_name,
        });
        try self.print("    virtual ~{s}Base() = default;\n", .{iface.name});

        // Default no-op overrides
        for (ops.items) |op| {
            const ret = if (op.return_type) |rt| try self.typeRefToCpp(rt) else try self.alloc.dupe(u8, "void");
            defer self.alloc.free(ret);
            try self.print("    {s} {s}(", .{ ret, op.name });
            for (op.params, 0..) |p, i| {
                if (i > 0) try self.write(", ");
                const pt = try self.typeRefToCpp(p.type_ref);
                defer self.alloc.free(pt);
                switch (p.mode) {
                    .in_ => try self.print("{s} /*{s}*/", .{ pt, p.name }),
                    .out, .inout => try self.print("{s}& /*{s}*/", .{ pt, p.name }),
                }
            }
            try self.write(") override {}\n");
        }

        // c_listener() declaration — implemented in dcps_impl.cpp
        try self.print("    {s} c_listener() noexcept;\n", .{c_name});
        try self.write("private:\n");

        // Static trampoline declarations
        for (ops.items) |op| {
            try self.write("    static void s_");
            try self.write(op.name);
            try self.write("(");
            for (op.params, 0..) |p, i| {
                if (i > 0) try self.write(", ");
                const ct = try paramToCTypeStr(self.alloc, p);
                defer self.alloc.free(ct);
                try self.write(ct);
            }
            if (op.params.len > 0) try self.write(", ");
            try self.write("void* d);\n");
        }

        try self.print("}}; // class {s}Base\n\n", .{iface.name});
    }

    fn emitOperation(self: *Generator, op: *const ir.Operation) !void {
        const ret = if (op.return_type) |rt| blk: {
            const s = try self.typeRefToCpp(rt);
            break :blk s;
        } else try self.alloc.dupe(u8, "void");
        defer self.alloc.free(ret);

        try self.print("    virtual {s} {s}(", .{ ret, op.name });
        for (op.params, 0..) |p, i| {
            if (i > 0) try self.write(", ");
            const p_cpp = try self.typeRefToCpp(p.type_ref);
            defer self.alloc.free(p_cpp);
            switch (p.mode) {
                .in_ => try self.print("{s} {s}", .{ p_cpp, p.name }),
                .out, .inout => try self.print("{s}& {s}", .{ p_cpp, p.name }),
            }
        }
        try self.write(") = 0;\n");
    }

    fn emitAttribute(self: *Generator, attr: *const ir.Attribute) !void {
        const a_cpp = try self.typeRefToCpp(attr.type_ref);
        defer self.alloc.free(a_cpp);
        // Getter.
        try self.print("    virtual {s} {s}() const = 0;\n", .{ a_cpp, attr.name });
        // Setter (omitted for readonly).
        if (!attr.readonly) {
            try self.print("    virtual void {s}({s} value) = 0;\n", .{ attr.name, a_cpp });
        }
    }

    // ── Const ─────────────────────────────────────────────────────────────────

    fn emitConst(self: *Generator, c: *const ir.Const) !void {
        const cpp_type = try self.typeRefToCpp(c.type_ref);
        defer self.alloc.free(cpp_type);

        switch (c.value) {
            .integer => |v| try self.print("constexpr {s} {s}{{{d}}};\n", .{ cpp_type, c.name, v }),
            .float => |v| try self.print("constexpr {s} {s}{{{d}}};\n", .{ cpp_type, c.name, v }),
            .boolean => |v| try self.print(
                "constexpr bool {s}{{{s}}};\n",
                .{ c.name, if (v) "true" else "false" },
            ),
            .character => |ch| {
                if (std.ascii.isPrint(ch) and ch != '\'' and ch != '\\') {
                    try self.print("constexpr char {s}{{'{c}'}};\n", .{ c.name, ch });
                } else {
                    try self.print("constexpr char {s}{{char(0x{X:0>2})}};\n", .{ c.name, ch });
                }
            },
            .string => |s| {
                try self.print("constexpr const char* {s}{{\"", .{c.name});
                for (s) |ch| {
                    switch (ch) {
                        '"' => try self.write("\\\""),
                        '\\' => try self.write("\\\\"),
                        '\n' => try self.write("\\n"),
                        '\r' => try self.write("\\r"),
                        '\t' => try self.write("\\t"),
                        else => try self.print("{c}", .{ch}),
                    }
                }
                try self.write("\"};\n");
            },
            .wide_character => |wc| try self.print(
                "constexpr wchar_t {s}{{wchar_t(0x{X:0>4})}};\n",
                .{ c.name, wc },
            ),
            .wide_string => try self.print(
                "// {s}: wide string const — no constexpr wchar_t[] in C++11\n",
                .{c.name},
            ),
            .fixed_pt => |fp| try self.print(
                "// {s}: fixed-point const {s}\n",
                .{ c.name, fp },
            ),
        }
    }

    // ── @verbatim emission ────────────────────────────────────────────────────

    /// Emit raw `@verbatim` annotation text filtered by `language="cpp"` (or
    /// `"*"`) and matching `placement`.  The standard IDL 4.2 placements
    /// "before-declaration" and "after-declaration" are the ones supported here.
    fn emitVerbatimForPlacement(
        self: *Generator,
        raw: []const ir.RawAnnotation,
        placement: []const u8,
    ) anyerror!void {
        for (raw) |ann| {
            if (!std.mem.eql(u8, ann.name, "verbatim")) continue;
            var lang: []const u8 = "*";
            var place: []const u8 = "after-declaration";
            var text: []const u8 = "";
            for (ann.params) |p| {
                if (p.name) |pname| {
                    if (std.mem.eql(u8, pname, "language")) {
                        if (p.value == .string) lang = p.value.string;
                    } else if (std.mem.eql(u8, pname, "placement")) {
                        if (p.value == .string) place = p.value.string;
                    } else if (std.mem.eql(u8, pname, "text")) {
                        if (p.value == .string) text = p.value.string;
                    }
                } else {
                    // positional first param = text
                    if (p.value == .string) text = p.value.string;
                }
            }
            if (!std.mem.eql(u8, lang, "*") and !std.mem.eql(u8, lang, "cpp")) continue;
            if (!std.mem.eql(u8, place, placement)) continue;
            try self.write(text);
            if (text.len > 0 and text[text.len - 1] != '\n') try self.write("\n");
        }
    }

    // ── Member declaration helper ─────────────────────────────────────────────

    /// Emit a single member/field declaration.
    /// Arrays use C-style `Type name[D1][D2];`.
    /// Optional (non-array) members use `std::optional<Type> name{};`.
    /// Plain scalar members use `Type name{};` for default-zero initialisation.
    fn emitMemberDecl(
        self: *Generator,
        type_ref: ir.TypeRef,
        name: []const u8,
        dims: []const u64,
        is_optional: bool,
        default_value: ?ir.AnnotationParamValue,
        indent: []const u8,
    ) !void {
        const cpp_type = try self.typeRefToCpp(type_ref);
        defer self.alloc.free(cpp_type);

        if (dims.len > 0) {
            try self.print("{s}{s} {s}", .{ indent, cpp_type, name });
            for (dims) |d| {
                try self.print("[{d}]", .{d});
            }
            try self.write(";\n");
        } else if (is_optional) {
            if (default_value) |dv| {
                const dv_str = try self.formatDefaultValueCpp(dv, type_ref);
                defer self.alloc.free(dv_str);
                try self.print("{s}std::optional<{s}> {s}{{{s}}};\n", .{ indent, cpp_type, name, dv_str });
            } else {
                try self.print("{s}std::optional<{s}> {s}{{}};\n", .{ indent, cpp_type, name });
            }
        } else if (default_value) |dv| {
            const dv_str = try self.formatDefaultValueCpp(dv, type_ref);
            defer self.alloc.free(dv_str);
            try self.print("{s}{s} {s}{{{s}}};\n", .{ indent, cpp_type, name, dv_str });
        } else {
            try self.print("{s}{s} {s}{{}};\n", .{ indent, cpp_type, name });
        }
    }

    /// Format an `AnnotationParamValue` as a C++ initializer expression.
    fn formatDefaultValueCpp(self: *Generator, dv: ir.AnnotationParamValue, type_ref: ir.TypeRef) ![]u8 {
        return switch (dv) {
            .integer => |v| std.fmt.allocPrint(self.alloc, "{d}", .{v}),
            .float => |v| switch (type_ref) {
                .base => |b| switch (b) {
                    .float => std.fmt.allocPrint(self.alloc, "{d}f", .{v}),
                    else => std.fmt.allocPrint(self.alloc, "{d}", .{v}),
                },
                else => std.fmt.allocPrint(self.alloc, "{d}", .{v}),
            },
            .boolean => |v| self.alloc.dupe(u8, if (v) "true" else "false"),
            .character => |v| if (std.ascii.isPrint(v) and v != '\'' and v != '\\')
                std.fmt.allocPrint(self.alloc, "'{c}'", .{v})
            else
                std.fmt.allocPrint(self.alloc, "'\\x{X:0>2}'", .{v}),
            .string => |s| blk: {
                const esc = try escapeStringLiteral(self.alloc, s);
                defer self.alloc.free(esc);
                break :blk std.fmt.allocPrint(self.alloc, "\"{s}\"", .{esc});
            },
            .scoped_name => |n| self.formatScopedNameDefaultCpp(n, type_ref),
            else => self.alloc.dupe(u8, "{}"),
        };
    }

    fn formatScopedNameDefaultCpp(self: *Generator, name: []const u8, type_ref: ir.TypeRef) ![]u8 {
        return switch (type_ref) {
            .named => |td| switch (td) {
                .enum_ => {
                    const cpp_type = try self.typeRefToCpp(type_ref);
                    defer self.alloc.free(cpp_type);
                    return std.fmt.allocPrint(self.alloc, "{s}::{s}", .{ cpp_type, name });
                },
                // Bitmask bit constants are emitted as namespace-level
                // `BitmaskName_BIT` values, not members of the bitmask alias
                // returned by typeRefToCpp(). IR qualified names already use
                // `::`, so this forms an absolute C++ path like
                // `::Module::BitmaskName_BIT`.
                .bitmask => |bm| std.fmt.allocPrint(self.alloc, "::{s}_{s}", .{ bm.qualified_name, name }),
                .typedef => |t| if (t.dimensions.len == 0)
                    self.formatScopedNameDefaultCpp(name, t.type_ref)
                else
                    self.alloc.dupe(u8, name),
                else => self.alloc.dupe(u8, name),
            },
            else => self.alloc.dupe(u8, name),
        };
    }

    // ── Type-ref → C++ type string ────────────────────────────────────────────

    /// Convert a `TypeRef` to its C++ type expression string.
    /// Named types are emitted with a leading `::` for unambiguous resolution.
    /// Caller owns the returned slice.
    fn typeRefToCpp(self: *Generator, tr: ir.TypeRef) anyerror![]u8 {
        return switch (tr) {
            .base => |b| self.alloc.dupe(u8, baseToCppType(b)),
            .named => |td| self.namedTypeRefToCpp(td),
            .sequence => |seq| blk: {
                const elem = try self.typeRefToCpp(seq.element.*);
                defer self.alloc.free(elem);
                break :blk std.fmt.allocPrint(self.alloc, "{s}<{s}>", .{ vectorTypeName(self.opts), elem });
            },
            .string => self.alloc.dupe(u8, stringTypeName(self.opts)),
            .wstring => self.alloc.dupe(u8, wstringTypeName(self.opts)),
            .fixed_pt => self.alloc.dupe(u8, "double"),
            .map => |m| blk: {
                const key_s = try self.typeRefToCpp(m.key.*);
                defer self.alloc.free(key_s);
                const val_s = try self.typeRefToCpp(m.value.*);
                defer self.alloc.free(val_s);
                break :blk std.fmt.allocPrint(self.alloc, "{s}<{s}, {s}>", .{ mapTypeName(self.opts), key_s, val_s });
            },
        };
    }

    fn namedTypeRefToCpp(self: *Generator, td: ir.TypeDecl) ![]u8 {
        return switch (td) {
            .interface => std.fmt.allocPrint(self.alloc, "std::shared_ptr<::{s}>", .{ir.typeDeclQualifiedName(td)}),
            else => std.fmt.allocPrint(self.alloc, "::{s}", .{ir.typeDeclQualifiedName(td)}),
        };
    }
};

// ── Static helpers ────────────────────────────────────────────────────────────

// Returns the "::" -separated namespace prefix for a qualified name.
// "ovidds::Frame" with name "Frame" → "ovidds"
// "a::b::Foo"    with name "Foo"   → "a::b"
// "Topic"        with name "Topic" → "" (global scope)
fn moduleNsOf(qname: []const u8, name: []const u8) []const u8 {
    if (qname.len == name.len) return "";
    return qname[0 .. qname.len - name.len - 2];
}

fn escapeStringLiteral(alloc: std.mem.Allocator, s: []const u8) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    for (s) |c| {
        switch (c) {
            '\\' => try buf.appendSlice(alloc, "\\\\"),
            '"' => try buf.appendSlice(alloc, "\\\""),
            '\n' => try buf.appendSlice(alloc, "\\n"),
            '\r' => try buf.appendSlice(alloc, "\\r"),
            '\t' => try buf.appendSlice(alloc, "\\t"),
            0 => try buf.appendSlice(alloc, "\\000"),
            else => if (c >= 0x20 and c <= 0x7e) {
                try buf.append(alloc, c);
            } else {
                // Octal escapes (\OOO) instead of \xHH: C/C++ \x is greedy
                // and consumes all following hex digits as part of the escape.
                var tmp: [4]u8 = undefined;
                const oct = std.fmt.bufPrint(&tmp, "\\{o:0>3}", .{c}) catch unreachable;
                try buf.appendSlice(alloc, oct);
            },
        }
    }
    return buf.toOwnedSlice(alloc);
}

// ── --cpp-pmr-containers type-name selection ──────────────────────────────────
//
// Applies uniformly to bounded and unbounded string/wstring/sequence fields:
// the flag only changes the container's allocator (via its type), not whether
// zidl treats the field as bounded (bound enforcement still happens the same
// way it does today, in the CDR read/write bodies -- unaffected by this flag).

fn vectorTypeName(opts: interface.Options) []const u8 {
    return if (opts.cpp_pmr_containers) "std::pmr::vector" else "std::vector";
}

fn stringTypeName(opts: interface.Options) []const u8 {
    return if (opts.cpp_pmr_containers) "std::pmr::string" else "std::string";
}

fn wstringTypeName(opts: interface.Options) []const u8 {
    return if (opts.cpp_pmr_containers) "std::pmr::wstring" else "std::wstring";
}

fn mapTypeName(opts: interface.Options) []const u8 {
    return if (opts.cpp_pmr_containers) "std::pmr::map" else "std::map";
}

/// How `emitGetFieldFromCdr` treats one struct member -- mirrors c.zig's
/// `CFilterFieldKind`/`classifyFilterFieldKindC` (see there for the full
/// rationale); duplicated rather than shared since the two backends'
/// generators are separate types with no common base.
const CppFilterFieldKind = enum { skip, int_like, float32, float64, string_like };

fn classifyFilterFieldKindCpp(tr: ir.TypeRef) CppFilterFieldKind {
    return switch (tr) {
        .base => |b| switch (b) {
            .boolean, .octet, .uint8, .char, .wchar, .int8, .short, .int16, .long, .int32, .long_long, .int64, .unsigned_short, .uint16, .unsigned_long, .uint32, .unsigned_long_long, .uint64 => .int_like,
            .float => .float32,
            .double, .long_double => .float64,
            .any, .object, .value_base => .skip,
        },
        .string => .string_like,
        .wstring, .sequence, .map, .fixed_pt => .skip,
        .named => |td| switch (td) {
            .enum_ => .int_like,
            .typedef => |t| classifyFilterFieldKindCpp(t.type_ref),
            .struct_, .union_, .bitset, .bitmask, .exception, .native, .interface => .skip,
        },
    };
}

fn baseToCppType(b: ast.BaseTypeSpec) []const u8 {
    return switch (b) {
        .float => "float",
        .double => "double",
        .long_double => "long double",
        .short => "int16_t",
        .long => "int32_t",
        .long_long => "int64_t",
        .unsigned_short => "uint16_t",
        .unsigned_long => "uint32_t",
        .unsigned_long_long => "uint64_t",
        .char => "char",
        .wchar => "wchar_t",
        .boolean => "bool",
        .octet => "uint8_t",
        .int8 => "int8_t",
        .uint8 => "uint8_t",
        .int16 => "int16_t",
        .int32 => "int32_t",
        .int64 => "int64_t",
        .uint16 => "uint16_t",
        .uint32 => "uint32_t",
        .uint64 => "uint64_t",
        .any => "void *",
        .object => "void *",
        .value_base => "void *",
    };
}

fn enumStorageType(annotations: ir.EnumAnnotations) []const u8 {
    const bound = annotations.bit_bound orelse 32;
    return if (bound <= 8) "uint8_t" else if (bound <= 16) "uint16_t" else if (bound <= 32) "uint32_t" else "uint64_t";
}

fn bitmaskStorageType(annotations: ir.EnumAnnotations) []const u8 {
    const bound = annotations.bit_bound orelse 32;
    return if (bound <= 8) "uint8_t" else if (bound <= 16) "uint16_t" else if (bound <= 32) "uint32_t" else "uint64_t";
}

fn bitsetCdrStorageType(bs: *const ir.Bitset) []const u8 {
    var total: u32 = 0;
    for (bs.fields) |f| total += f.bits;
    return if (total <= 8) "uint8_t" else if (total <= 16) "uint16_t" else if (total <= 32) "uint32_t" else "uint64_t";
}

fn bitsetCdrFnSuffix(bs: *const ir.Bitset) []const u8 {
    var total: u32 = 0;
    for (bs.fields) |f| total += f.bits;
    return if (total <= 8) "u8" else if (total <= 16) "u16" else if (total <= 32) "u32" else "u64";
}

// ── CDR source generation ─────────────────────────────────────────────────────

const CdrGenerator = struct {
    alloc: std.mem.Allocator,
    opts: interface.Options,
    out: *std.ArrayList(u8),
    /// Indentation depth within a function body.
    /// 1 = function body (4 sp), 2 = one block deep (8 sp), 3 = two deep (12 sp).
    indent_depth: u32 = 1,

    fn write(self: *CdrGenerator, s: []const u8) !void {
        try self.out.appendSlice(self.alloc, s);
    }

    fn print(self: *CdrGenerator, comptime fmt: []const u8, args: anytype) !void {
        const s = try std.fmt.allocPrint(self.alloc, fmt, args);
        defer self.alloc.free(s);
        try self.out.appendSlice(self.alloc, s);
    }

    pub fn ind(self: *CdrGenerator) []const u8 {
        return switch (self.indent_depth) {
            1 => "    ",
            2 => "        ",
            3 => "            ",
            else => "                ",
        };
    }

    pub fn writeI(self: *CdrGenerator, s: []const u8) !void {
        try self.out.appendSlice(self.alloc, self.ind());
        try self.out.appendSlice(self.alloc, s);
    }

    pub fn printI(self: *CdrGenerator, comptime fmt: []const u8, args: anytype) !void {
        try self.out.appendSlice(self.alloc, self.ind());
        const s = try std.fmt.allocPrint(self.alloc, fmt, args);
        defer self.alloc.free(s);
        try self.out.appendSlice(self.alloc, s);
    }

    /// Return the C++ type string suitable for declaring a local variable of this type
    /// in the CDR source file (e.g. `"int32_t"`, `"std::string"`, `"::Ns::Foo"`).
    /// Caller owns the returned slice.
    fn cppTypeForLocal(self: *CdrGenerator, tr: ir.TypeRef) ![]u8 {
        return switch (tr) {
            .base => |b| self.alloc.dupe(u8, baseToCppType(b)),
            .string => self.alloc.dupe(u8, stringTypeName(self.opts)),
            .wstring => self.alloc.dupe(u8, wstringTypeName(self.opts)),
            .fixed_pt => self.alloc.dupe(u8, "double"),
            .named => |td| switch (td) {
                .enum_ => |e| std.fmt.allocPrint(self.alloc, "::{s}", .{e.qualified_name}),
                .bitmask => |bm| self.alloc.dupe(u8, enumCTypeName(bm.annotations)),
                else => std.fmt.allocPrint(self.alloc, "::{s}", .{ir.typeDeclQualifiedName(td)}),
            },
            .sequence => |seq| blk: {
                const elem = try self.cppTypeForLocal(seq.element.*);
                defer self.alloc.free(elem);
                break :blk std.fmt.allocPrint(self.alloc, "{s}<{s}>", .{ vectorTypeName(self.opts), elem });
            },
            .map => |m| blk: {
                const k = try self.cppTypeForLocal(m.key.*);
                defer self.alloc.free(k);
                const v = try self.cppTypeForLocal(m.value.*);
                defer self.alloc.free(v);
                break :blk std.fmt.allocPrint(self.alloc, "{s}<{s}, {s}>", .{ mapTypeName(self.opts), k, v });
            },
        };
    }

    fn emitSource(self: *CdrGenerator, spec: *const ir.Spec) !void {
        try self.print(
            "// Generated by zidl from {s}.idl — DO NOT EDIT\n\n",
            .{self.opts.input_stem},
        );
        try self.print("#include \"{s}.hpp\"\n", .{self.opts.input_stem});
        try self.write("#include \"zidl_cdr.h\"\n");
        if (self.opts.generate_zzdds_wrappers and !self.opts.no_typesupport and itemsHaveZzddsTopicStructCpp(spec.items)) {
            try self.write("#include \"zzdds_c.h\"\n");
        }
        try self.write("#include <cstring>\n");
        if (self.opts.generate_zzdds_wrappers and !self.opts.no_typesupport and itemsHaveZzddsTopicStructCpp(spec.items)) {
            try self.print("#define ZZDDS_KEY_VALUE_BUF_SIZE {d}\n", .{key_value_buf_size});
        }
        try self.write("\n");
        try self.emitItems(spec.items);
    }

    fn emitItems(self: *CdrGenerator, items: []const ir.ModuleItem) anyerror!void {
        for (items) |item| {
            switch (item) {
                .module => |m| try self.emitItems(m.items),
                .type_decl => |td| try self.emitTypeDecl(td),
                .const_ => {},
            }
        }
    }

    fn emitTypeDecl(self: *CdrGenerator, td: ir.TypeDecl) !void {
        switch (td) {
            .struct_ => |s| try self.emitStructFns(s),
            .exception => |e| try self.emitExceptionFns(e),
            .union_ => |u| {
                try self.emitUnionFns(u);
                if (unionNeedsCppLifetime(u)) try self.emitUnionLifecycleFns(u);
            },
            else => {},
        }
    }

    pub fn prefixedCName(self: *CdrGenerator, qname: []const u8) ![]u8 {
        return interface.prefixedCNameFromQualified(self.alloc, qname, self.opts.type_prefix);
    }

    // ── Struct / Exception ────────────────────────────────────────────────────

    fn emitStructFns(self: *CdrGenerator, s: *const ir.Struct) !void {
        const c_name = try self.prefixedCName(s.qualified_name);
        defer self.alloc.free(c_name);
        const cpp_qname = try std.fmt.allocPrint(self.alloc, "::{s}", .{s.qualified_name});
        defer self.alloc.free(cpp_qname);

        const ext = s.annotations.extensibility;
        const appendable = (ext == .appendable or ext == .mutable);
        const mutable = (ext == .mutable);

        const has_key = structHasKeyCpp(s);

        // ── serialize ────────────────────────────────────────────────────────

        try self.print("int {s}_serialize(ZidlCdrWriter *_w, const {s} *_v) {{\n", .{ c_name, cpp_qname });
        try self.writeI("int _rc;\n");
        if (mutable) {
            // @mutable: outer DHEADER + per-member EMHEADER framing.
            try self.writeI("size_t _dh;\n");
            try self.writeI("_rc = zidl_cdr_reserve_dheader(_w, &_dh);\n");
            try self.writeI("if (_rc) return _rc;\n");
            for (s.members, 0..) |m, idx| {
                const member_id: u32 = memberIdAtCpp(m, idx);
                const mu: u8 = if (m.annotations.must_understand) 1 else 0;
                if (m.annotations.is_optional) {
                    try self.printI("if (_v->{s}.has_value()) {{\n", .{m.name});
                    self.indent_depth += 1;
                    const deref = try std.fmt.allocPrint(self.alloc, "(*_v->{s})", .{m.name});
                    defer self.alloc.free(deref);
                    if (lcForCppTypeRef(m.type_ref, m.dimensions)) |lc| {
                        try self.printI("_rc = zidl_cdr_write_emheader(_w, {d}, {d}, {d});\n", .{ member_id, mu, lc });
                        try self.writeI("if (_rc) return _rc;\n");
                        if (m.dimensions.len > 0) {
                            try self.emitWriteArray(m.type_ref, deref, m.dimensions, 0);
                        } else {
                            try self.emitWriteForTypeRef(m.type_ref, m.name, deref);
                        }
                    } else {
                        try self.printI("{{ size_t _em{d} = 0, _es{d} = 0;\n", .{ idx, idx });
                        self.indent_depth += 1;
                        try self.printI("_rc = zidl_cdr_reserve_emheader(_w, {d}, {d}, &_em{d});\n", .{ member_id, mu, idx });
                        try self.writeI("if (_rc) return _rc;\n");
                        try self.printI("_es{d} = _w->len;\n", .{idx});
                        if (m.dimensions.len > 0) {
                            try self.emitWriteArray(m.type_ref, deref, m.dimensions, 0);
                        } else {
                            try self.emitWriteForTypeRef(m.type_ref, m.name, deref);
                        }
                        try self.printI("zidl_cdr_patch_emheader(_w, _em{d}, _es{d}); }}\n", .{ idx, idx });
                        self.indent_depth -= 1;
                    }
                    self.indent_depth -= 1;
                    try self.writeI("}\n");
                    continue;
                }
                const access = try std.fmt.allocPrint(self.alloc, "_v->{s}", .{m.name});
                defer self.alloc.free(access);
                if (lcForCppTypeRef(m.type_ref, m.dimensions)) |lc| {
                    try self.printI("_rc = zidl_cdr_write_emheader(_w, {d}, {d}, {d});\n", .{ member_id, mu, lc });
                    try self.writeI("if (_rc) return _rc;\n");
                    if (m.dimensions.len > 0) {
                        try self.emitWriteArray(m.type_ref, access, m.dimensions, 0);
                    } else {
                        try self.emitWriteForTypeRef(m.type_ref, m.name, access);
                    }
                } else {
                    try self.printI("{{ size_t _em{d} = 0, _es{d} = 0;\n", .{ idx, idx });
                    self.indent_depth += 1;
                    try self.printI("_rc = zidl_cdr_reserve_emheader(_w, {d}, {d}, &_em{d});\n", .{ member_id, mu, idx });
                    try self.writeI("if (_rc) return _rc;\n");
                    try self.printI("_es{d} = _w->len;\n", .{idx});
                    if (m.dimensions.len > 0) {
                        try self.emitWriteArray(m.type_ref, access, m.dimensions, 0);
                    } else {
                        try self.emitWriteForTypeRef(m.type_ref, m.name, access);
                    }
                    try self.printI("zidl_cdr_patch_emheader(_w, _em{d}, _es{d}); }}\n", .{ idx, idx });
                    self.indent_depth -= 1;
                }
            }
            try self.writeI("zidl_cdr_patch_dheader(_w, _dh);\n");
            try self.writeI("return ZIDL_CDR_OK;\n");
            try self.write("}\n\n");
        } else {
            if (appendable) {
                try self.writeI("size_t _dh;\n");
                try self.writeI("_rc = zidl_cdr_reserve_dheader_maybe(_w, &_dh);\n");
                try self.writeI("if (_rc) return _rc;\n");
            }
            if (s.base) |base| {
                const base_c = try self.prefixedCName(ir.typeDeclQualifiedName(base));
                defer self.alloc.free(base_c);
                const base_cpp = try std.fmt.allocPrint(self.alloc, "::{s}", .{ir.typeDeclQualifiedName(base)});
                defer self.alloc.free(base_cpp);
                try self.printI("_rc = {s}_serialize(_w, static_cast<const {s} *>(_v));\n", .{ base_c, base_cpp });
                try self.writeI("if (_rc) return _rc;\n");
            }
            for (s.members) |m| {
                if (m.annotations.is_optional) {
                    // XCDR2: write bool presence flag, then value if present (§12).
                    try self.printI("_rc = zidl_cdr_write_bool(_w, _v->{s}.has_value() ? 1 : 0);\n", .{m.name});
                    try self.writeI("if (_rc) return _rc;\n");
                    try self.printI("if (_v->{s}.has_value()) {{\n", .{m.name});
                    self.indent_depth += 1;
                    const deref = try std.fmt.allocPrint(self.alloc, "(*_v->{s})", .{m.name});
                    defer self.alloc.free(deref);
                    if (m.dimensions.len > 0) {
                        try self.emitWriteArray(m.type_ref, deref, m.dimensions, 0);
                    } else {
                        try self.emitWriteForTypeRef(m.type_ref, m.name, deref);
                    }
                    self.indent_depth -= 1;
                    try self.writeI("}\n");
                    continue;
                }
                const access = try std.fmt.allocPrint(self.alloc, "_v->{s}", .{m.name});
                defer self.alloc.free(access);
                if (m.dimensions.len > 0) {
                    try self.emitWriteArray(m.type_ref, access, m.dimensions, 0);
                } else {
                    try self.emitWriteForTypeRef(m.type_ref, m.name, access);
                }
            }
            if (appendable) {
                try self.writeI("zidl_cdr_patch_dheader_maybe(_w, _dh);\n");
            }
            try self.writeI("return ZIDL_CDR_OK;\n");
            try self.write("}\n\n");
        }

        // ── deserialize ──────────────────────────────────────────────────────

        try self.print("int {s}_deserialize(ZidlCdrReader *_r, {s} *_v) {{\n", .{ c_name, cpp_qname });
        if (mutable) {
            try self.writeI("int _rc;\n");
            try self.writeI("size_t _em_end;\n");
            try self.writeI("_rc = zidl_cdr_read_mutable_dheader(_r, &_em_end);\n");
            try self.writeI("if (_rc) return _rc;\n");
            try self.writeI("while (zidl_cdr_mutable_has_more(_r, _em_end)) {\n");
            self.indent_depth += 1;
            try self.writeI("ZidlEmHeader _emh;\n");
            try self.writeI("_rc = zidl_cdr_read_emheader(_r, &_emh);\n");
            try self.writeI("if (_rc) return _rc;\n");
            try self.writeI("switch (_emh.member_id) {\n");
            self.indent_depth += 1;
            for (s.members, 0..) |m, idx| {
                const member_id: u32 = memberIdAtCpp(m, idx);
                try self.printI("case {d}: {{\n", .{member_id});
                self.indent_depth += 1;
                if (m.annotations.is_optional) {
                    try self.printI("_v->{s}.emplace();\n", .{m.name});
                    const deref = try std.fmt.allocPrint(self.alloc, "(*_v->{s})", .{m.name});
                    defer self.alloc.free(deref);
                    if (m.dimensions.len > 0) {
                        try self.emitReadArray(m.type_ref, m.name, deref, m.dimensions, 0);
                    } else {
                        try self.emitReadForTypeRef(m.type_ref, m.name, deref);
                    }
                } else {
                    const lval = try std.fmt.allocPrint(self.alloc, "_v->{s}", .{m.name});
                    defer self.alloc.free(lval);
                    if (m.dimensions.len > 0) {
                        try self.emitReadArray(m.type_ref, m.name, lval, m.dimensions, 0);
                    } else {
                        try self.emitReadForTypeRef(m.type_ref, m.name, lval);
                    }
                }
                try self.writeI("break;\n");
                self.indent_depth -= 1;
                try self.writeI("}\n");
            }
            try self.writeI("default:\n");
            self.indent_depth += 1;
            try self.writeI("if (_emh.must_understand) return ZIDL_CDR_INVALID;\n");
            try self.writeI("_rc = zidl_cdr_skip_emheader_payload(_r, &_emh);\n");
            try self.writeI("if (_rc) return _rc;\n");
            try self.writeI("break;\n");
            self.indent_depth -= 1;
            self.indent_depth -= 1;
            try self.writeI("}\n"); // switch
            self.indent_depth -= 1;
            try self.writeI("}\n"); // while
            try self.writeI("return ZIDL_CDR_OK;\n");
            try self.write("}\n\n");
        } else {
            try self.writeI("int _rc;\n");
            if (appendable) {
                try self.writeI("_rc = zidl_cdr_skip_dheader_if_xcdr2(_r);\n");
                try self.writeI("if (_rc) return _rc;\n");
            }
            if (s.base) |base| {
                const base_c = try self.prefixedCName(ir.typeDeclQualifiedName(base));
                defer self.alloc.free(base_c);
                const base_cpp = try std.fmt.allocPrint(self.alloc, "::{s}", .{ir.typeDeclQualifiedName(base)});
                defer self.alloc.free(base_cpp);
                try self.printI("_rc = {s}_deserialize(_r, static_cast<{s} *>(_v));\n", .{ base_c, base_cpp });
                try self.writeI("if (_rc) return _rc;\n");
            }
            for (s.members) |m| {
                if (m.annotations.is_optional) {
                    // XCDR2: read bool presence flag; emplace inner value if present.
                    const pvar = try std.fmt.allocPrint(self.alloc, "_ip_{s}", .{m.name});
                    defer self.alloc.free(pvar);
                    try self.printI("{{ int8_t {s};\n", .{pvar});
                    self.indent_depth += 1;
                    try self.printI("_rc = zidl_cdr_read_bool(_r, &{s});\n", .{pvar});
                    try self.writeI("if (_rc) return _rc;\n");
                    try self.printI("if ({s}) {{\n", .{pvar});
                    self.indent_depth += 1;
                    try self.printI("_v->{s}.emplace();\n", .{m.name});
                    const deref = try std.fmt.allocPrint(self.alloc, "(*_v->{s})", .{m.name});
                    defer self.alloc.free(deref);
                    if (m.dimensions.len > 0) {
                        try self.emitReadArray(m.type_ref, m.name, deref, m.dimensions, 0);
                    } else {
                        try self.emitReadForTypeRef(m.type_ref, m.name, deref);
                    }
                    self.indent_depth -= 1;
                    try self.writeI("} else {{\n");
                    self.indent_depth += 1;
                    try self.printI("_v->{s} = std::nullopt;\n", .{m.name});
                    self.indent_depth -= 1;
                    try self.writeI("}\n");
                    self.indent_depth -= 1;
                    try self.writeI("}\n");
                    continue;
                }
                const lval = try std.fmt.allocPrint(self.alloc, "_v->{s}", .{m.name});
                defer self.alloc.free(lval);
                if (m.dimensions.len > 0) {
                    try self.emitReadArray(m.type_ref, m.name, lval, m.dimensions, 0);
                } else {
                    try self.emitReadForTypeRef(m.type_ref, m.name, lval);
                }
            }
            try self.writeI("return ZIDL_CDR_OK;\n");
            try self.write("}\n\n");
        }

        // ── skip ─────────────────────────────────────────────────────────────

        try self.print("int {s}_skip(ZidlCdrReader *_r) {{\n", .{c_name});
        try self.writeI("int _rc;\n");
        if (mutable) {
            try self.writeI("size_t _end;\n");
            try self.writeI("_rc = zidl_cdr_read_mutable_dheader(_r, &_end);\n");
            try self.writeI("if (_rc) return _rc;\n");
            try self.writeI("return zidl_cdr_seek_to(_r, _end);\n");
        } else {
            if (appendable) {
                try self.writeI("if (_r->xcdr_version == ZIDL_XCDR2) {\n");
                self.indent_depth += 1;
                try self.writeI("uint32_t _size;\n");
                try self.writeI("_rc = zidl_cdr_read_dheader(_r, &_size);\n");
                try self.writeI("if (_rc) return _rc;\n");
                try self.writeI("return zidl_cdr_skip(_r, _size);\n");
                self.indent_depth -= 1;
                try self.writeI("}\n");
            }
            if (s.base) |base| {
                const base_c = try self.prefixedCName(ir.typeDeclQualifiedName(base));
                defer self.alloc.free(base_c);
                try self.printI("_rc = {s}_skip(_r);\n", .{base_c});
                try self.writeI("if (_rc) return _rc;\n");
            }
            for (s.members) |m| {
                try cdr_skip.emitSkipMember(self, m);
            }
            try self.writeI("return ZIDL_CDR_OK;\n");
        }
        try self.write("}\n\n");

        // ── serialize_key / deserialize_key / compute_key_hash ───────────────

        if (has_key) {
            try self.print("int {s}_serialize_key(ZidlCdrWriter *_w, const {s} *_v) {{\n", .{ c_name, cpp_qname });
            try self.writeI("int _rc;\n");
            if (appendable) {
                try self.writeI("size_t _dh;\n");
                try self.writeI("_rc = zidl_cdr_reserve_dheader_maybe(_w, &_dh);\n");
                try self.writeI("if (_rc) return _rc;\n");
            }
            if (s.base) |base| {
                if (typeDeclHasKeyCpp(base)) {
                    const base_c = try self.prefixedCName(ir.typeDeclQualifiedName(base));
                    defer self.alloc.free(base_c);
                    const base_cpp = try std.fmt.allocPrint(self.alloc, "::{s}", .{ir.typeDeclQualifiedName(base)});
                    defer self.alloc.free(base_cpp);
                    try self.printI("_rc = {s}_serialize_key(_w, static_cast<const {s} *>(_v));\n", .{ base_c, base_cpp });
                    try self.writeI("if (_rc) return _rc;\n");
                }
            }
            for (s.members) |m| {
                if (!m.annotations.is_key) continue;
                const access = try std.fmt.allocPrint(self.alloc, "_v->{s}", .{m.name});
                defer self.alloc.free(access);
                if (m.dimensions.len > 0) {
                    try self.emitWriteArray(m.type_ref, access, m.dimensions, 0);
                } else {
                    try self.emitWriteForTypeRef(m.type_ref, m.name, access);
                }
            }
            if (appendable) {
                try self.writeI("zidl_cdr_patch_dheader_maybe(_w, _dh);\n");
            }
            try self.writeI("return ZIDL_CDR_OK;\n");
            try self.write("}\n\n");

            try self.print("int {s}_deserialize_key(ZidlCdrReader *_r, {s} *_v) {{\n", .{ c_name, cpp_qname });
            try self.writeI("int _rc;\n");
            if (mutable) {
                try self.writeI("size_t _em_end;\n");
                try self.writeI("_rc = zidl_cdr_read_mutable_dheader(_r, &_em_end);\n");
                try self.writeI("if (_rc) return _rc;\n");
                try self.writeI("while (zidl_cdr_mutable_has_more(_r, _em_end)) {\n");
                self.indent_depth += 1;
                try self.writeI("ZidlEmHeader _emh;\n");
                try self.writeI("_rc = zidl_cdr_read_emheader(_r, &_emh);\n");
                try self.writeI("if (_rc) return _rc;\n");
                try self.writeI("switch (_emh.member_id) {\n");
                self.indent_depth += 1;
                for (s.members, 0..) |m, idx| {
                    if (!m.annotations.is_key) continue;
                    const member_id: u32 = memberIdAtCpp(m, idx);
                    try self.printI("case {d}: {{\n", .{member_id});
                    self.indent_depth += 1;
                    try self.emitReadPresentMember(m);
                    try self.writeI("break;\n");
                    self.indent_depth -= 1;
                    try self.writeI("}\n");
                }
                try self.writeI("default:\n");
                self.indent_depth += 1;
                try self.writeI("if (_emh.must_understand) return ZIDL_CDR_INVALID;\n");
                try self.writeI("_rc = zidl_cdr_skip_emheader_payload(_r, &_emh);\n");
                try self.writeI("if (_rc) return _rc;\n");
                try self.writeI("break;\n");
                self.indent_depth -= 1;
                self.indent_depth -= 1;
                try self.writeI("}\n");
                self.indent_depth -= 1;
                try self.writeI("}\n");
            } else {
                if (appendable) {
                    try self.writeI("size_t _key_end = (size_t)-1;\n");
                    try self.writeI("if (_r->xcdr_version == ZIDL_XCDR2) {\n");
                    self.indent_depth += 1;
                    try self.writeI("uint32_t _size;\n");
                    try self.writeI("_rc = zidl_cdr_read_dheader(_r, &_size);\n");
                    try self.writeI("if (_rc) return _rc;\n");
                    try self.writeI("_key_end = _r->pos + (size_t)_size;\n");
                    self.indent_depth -= 1;
                    try self.writeI("}\n");
                }
                if (s.base) |base| {
                    const base_c = try self.prefixedCName(ir.typeDeclQualifiedName(base));
                    defer self.alloc.free(base_c);
                    const base_cpp = try std.fmt.allocPrint(self.alloc, "::{s}", .{ir.typeDeclQualifiedName(base)});
                    defer self.alloc.free(base_cpp);
                    if (typeDeclHasKeyCpp(base)) {
                        try self.printI("_rc = {s}_deserialize_key(_r, static_cast<{s} *>(_v));\n", .{ base_c, base_cpp });
                    } else {
                        try self.printI("_rc = {s}_skip(_r);\n", .{base_c});
                    }
                    try self.writeI("if (_rc) return _rc;\n");
                }
                // @final: key-only payload — read key members, no skips.
                // Emit static_assert if a non-key member precedes a key member;
                // full-payload callers would silently read wrong bytes.
                if (!appendable) {
                    var saw_non_key = false;
                    for (s.members) |m| {
                        if (m.annotations.is_key) {
                            if (saw_non_key) {
                                try self.printI(
                                    "static_assert(false, \"zidl: @final struct '{s}' has non-leading @key member '{s}'; \"\n",
                                    .{ s.name, m.name },
                                );
                                try self.writeI("    \"move all @key members before non-key members, or use @appendable\");\n");
                                break;
                            }
                        } else {
                            saw_non_key = true;
                        }
                    }
                }
                for (s.members) |m| {
                    if (m.annotations.is_key) {
                        try self.emitReadMember(m);
                    }
                }
                if (appendable) {
                    try self.writeI("if (_key_end != (size_t)-1) { _rc = zidl_cdr_seek_to(_r, _key_end); if (_rc) return _rc; }\n");
                }
            }
            try self.writeI("return ZIDL_CDR_OK;\n");
            try self.write("}\n\n");

            try self.print("int {s}_compute_key_hash(const {s} *_v, uint8_t _hash[16]) {{\n", .{ c_name, cpp_qname });
            try self.writeI("ZidlCdrWriter _w;\n");
            // XCDR1: reserve_dheader_maybe is a no-op, so key bytes are
            // written without a DHEADER regardless of extensibility.
            try self.writeI("int _rc = zidl_cdr_writer_init(&_w, ZIDL_XCDR1);\n");
            try self.writeI("if (_rc) return _rc;\n");
            try self.writeI("zidl_cdr_writer_set_byte_order(&_w, ZIDL_CDR_BE);\n");
            try self.printI("_rc = {s}_serialize_key(&_w, _v);\n", .{c_name});
            try self.writeI("if (!_rc) zidl_cdr_compute_key_hash(_w.buf, _w.len, _hash);\n");
            try self.writeI("zidl_cdr_writer_deinit(&_w);\n");
            try self.writeI("return _rc;\n");
            try self.write("}\n\n");

            try self.print("int {s}_compute_key_hash_from_cdr(const uint8_t *_payload, size_t _len, uint8_t _hash[16]) {{\n", .{c_name});
            try self.writeI("ZidlCdrReader _r_data;\n");
            try self.writeI("int _rc = zidl_cdr_reader_init(&_r_data, _payload, _len);\n");
            try self.writeI("if (_rc) return _rc;\n");
            try self.writeI("ZidlCdrReader *_r = &_r_data;\n");
            try self.printI("{s} _v_data{{}};\n", .{cpp_qname});
            try self.printI("{s} *_v = &_v_data;\n", .{cpp_qname});
            if (mutable) {
                try self.writeI("size_t _em_end;\n");
                try self.writeI("_rc = zidl_cdr_read_mutable_dheader(_r, &_em_end);\n");
                try self.writeI("if (_rc) return _rc;\n");
                try self.writeI("while (zidl_cdr_mutable_has_more(_r, _em_end)) {\n");
                self.indent_depth += 1;
                try self.writeI("ZidlEmHeader _emh;\n");
                try self.writeI("_rc = zidl_cdr_read_emheader(_r, &_emh);\n");
                try self.writeI("if (_rc) return _rc;\n");
                try self.writeI("switch (_emh.member_id) {\n");
                self.indent_depth += 1;
                for (s.members, 0..) |m, idx| {
                    if (!m.annotations.is_key) continue;
                    const member_id: u32 = memberIdAtCpp(m, idx);
                    try self.printI("case {d}: {{\n", .{member_id});
                    self.indent_depth += 1;
                    try self.emitReadPresentMember(m);
                    try self.writeI("break;\n");
                    self.indent_depth -= 1;
                    try self.writeI("}\n");
                }
                try self.writeI("default:\n");
                self.indent_depth += 1;
                try self.writeI("if (_emh.must_understand) return ZIDL_CDR_INVALID;\n");
                try self.writeI("_rc = zidl_cdr_skip_emheader_payload(_r, &_emh);\n");
                try self.writeI("if (_rc) return _rc;\n");
                try self.writeI("break;\n");
                self.indent_depth -= 1;
                self.indent_depth -= 1;
                try self.writeI("}\n");
                self.indent_depth -= 1;
                try self.writeI("}\n");
            } else if (appendable) {
                try self.writeI("size_t _key_end = (size_t)-1;\n");
                try self.writeI("if (_r->xcdr_version == ZIDL_XCDR2) {\n");
                self.indent_depth += 1;
                try self.writeI("uint32_t _dh_size;\n");
                try self.writeI("_rc = zidl_cdr_read_dheader(_r, &_dh_size);\n");
                try self.writeI("if (_rc) return _rc;\n");
                try self.writeI("_key_end = _r->pos + (size_t)_dh_size;\n");
                self.indent_depth -= 1;
                try self.writeI("}\n");
                for (s.members) |m| {
                    if (m.annotations.is_key) {
                        try self.emitReadMember(m);
                    }
                    // seek_to(_key_end) handles both trailing non-key bytes
                    // (full payload) and their absence (key-only payload).
                }
                try self.writeI("if (_key_end != (size_t)-1) { _rc = zidl_cdr_seek_to(_r, _key_end); if (_rc) return _rc; }\n");
            } else {
                for (s.members) |m| {
                    if (m.annotations.is_key) {
                        try self.emitReadMember(m);
                    }
                }
            }
            try self.printI("return {s}_compute_key_hash(_v, _hash);\n", .{c_name});
            try self.write("}\n\n");
        } else if (self.opts.generate_zzdds_wrappers and isZzddsTopicStructCpp(s)) {
            // Keyless topic type but --generate-zzdds-wrappers was requested:
            // emit trivial key functions -- see the matching `else if` in
            // c.zig's emitStructFns for the full rationale (DDS 1.4 2.2.2.1:
            // a keyless Topic is exactly one instance regardless of content).
            try self.print("int {s}_serialize_key(ZidlCdrWriter *_w, const {s} *_v) {{\n", .{ c_name, cpp_qname });
            try self.writeI("(void)_v;\n");
            if (appendable) {
                try self.writeI("size_t _dh;\n");
                try self.writeI("int _rc = zidl_cdr_reserve_dheader_maybe(_w, &_dh);\n");
                try self.writeI("if (_rc) return _rc;\n");
                try self.writeI("zidl_cdr_patch_dheader_maybe(_w, _dh);\n");
            }
            try self.writeI("return ZIDL_CDR_OK;\n");
            try self.write("}\n\n");

            try self.print("int {s}_deserialize_key(ZidlCdrReader *_r, {s} *_v) {{\n", .{ c_name, cpp_qname });
            try self.writeI("(void)_v;\n");
            if (appendable) {
                try self.writeI("if (_r->xcdr_version == ZIDL_XCDR2) {\n");
                self.indent_depth += 1;
                try self.writeI("uint32_t _size;\n");
                try self.writeI("int _rc = zidl_cdr_read_dheader(_r, &_size);\n");
                try self.writeI("if (_rc) return _rc;\n");
                self.indent_depth -= 1;
                try self.writeI("}\n");
            }
            try self.writeI("return ZIDL_CDR_OK;\n");
            try self.write("}\n\n");

            try self.print("int {s}_compute_key_hash(const {s} *_v, uint8_t _hash[16]) {{\n", .{ c_name, cpp_qname });
            try self.writeI("(void)_v;\n");
            try self.writeI("memset(_hash, 0, 16);\n");
            try self.writeI("return ZIDL_CDR_OK;\n");
            try self.write("}\n\n");

            try self.print("int {s}_compute_key_hash_from_cdr(const uint8_t *_payload, size_t _len, uint8_t _hash[16]) {{\n", .{c_name});
            try self.writeI("(void)_payload;\n");
            try self.writeI("(void)_len;\n");
            try self.writeI("memset(_hash, 0, 16);\n");
            try self.writeI("return ZIDL_CDR_OK;\n");
            try self.write("}\n\n");
        }
        if (self.opts.generate_zzdds_wrappers and isZzddsTopicStructCpp(s)) {
            try self.emitSelectiveFnsCpp(s, c_name, cpp_qname, appendable);
        }
        if (self.opts.generate_zzdds_wrappers and !self.opts.no_typesupport and isZzddsTopicStructCpp(s)) {
            try self.emitStructZzddsWrappers(s, c_name, cpp_qname);
        }
    }

    /// Selective-parse family for a Topic struct -- see c.zig's
    /// `emitSelectiveFnsC` and zig.zig's `emitSelectiveFns`. Unlike C, there
    /// is **no** `_deinit_selected`: `::Foo`'s members (`std::string`,
    /// `std::vector`, …) release themselves via RAII when `key_out` goes out
    /// of scope, even after a mid-parse error. Fallback to `_deserialize` for
    /// a struct with a base type or > 64 members.
    fn emitSelectiveFnsCpp(
        self: *CdrGenerator,
        s: *const ir.Struct,
        c_name: []const u8,
        cpp_qname: []const u8,
        appendable: bool,
    ) !void {
        const fallback = s.base != null or s.members.len > 64;

        // _field_index
        try self.print("bool {s}_field_index(const char *_name, size_t _name_len, uint32_t *_out_idx) {{\n", .{c_name});
        if (fallback) {
            try self.writeI("(void)_name; (void)_name_len; (void)_out_idx;\n");
        } else {
            for (s.members, 0..) |m, idx| {
                try self.printI("if (_name_len == sizeof(\"{s}\") - 1 && memcmp(_name, \"{s}\", _name_len) == 0) {{ *_out_idx = {d}u; return true; }}\n", .{ m.name, m.name, idx });
            }
        }
        try self.writeI("return false;\n");
        try self.write("}\n\n");

        // _deserialize_selected
        try self.print("int {s}_deserialize_selected(ZidlCdrReader *_r, uint64_t _want, {s} *_v) {{\n", .{ c_name, cpp_qname });
        try self.writeI("*_v = {};\n");
        if (fallback) {
            try self.writeI("(void)_want;\n");
            try self.printI("return {s}_deserialize(_r, _v);\n", .{c_name});
        } else {
            try self.writeI("int _rc;\n");
            if (appendable) {
                try self.writeI("_rc = zidl_cdr_skip_dheader_if_xcdr2(_r);\n");
                try self.writeI("if (_rc) return _rc;\n");
            }
            for (s.members, 0..) |m, idx| {
                try self.printI("if (_want & (1ull << {d})) {{\n", .{idx});
                self.indent_depth += 1;
                try self.emitReadMember(m);
                self.indent_depth -= 1;
                try self.writeI("} else {\n");
                self.indent_depth += 1;
                try cdr_skip.emitSkipMember(self, m);
                self.indent_depth -= 1;
                try self.writeI("}\n");
            }
            try self.writeI("return ZIDL_CDR_OK;\n");
        }
        try self.write("}\n\n");
    }

    /// Emit `{c_name}_get_field_from_cdr` -- a free function using the flat
    /// C-ABI name (`c_name`), NOT namespace-scoped like the rest of this
    /// struct's `--generate-zzdds-wrappers` output, since it's passed
    /// directly to `zzdds_register_type_support` as a plain function
    /// pointer. See c.zig's `emitGetFieldFromCdr` for the full rationale
    /// (full deserialize rather than a partial parse, `_scratch`'s
    /// dangling-pointer-avoidance contract) -- identical here except C++'s
    /// `_v` needs no manual free (its `std::string`/vector members clean
    /// themselves up via RAII when `_v` goes out of scope, unlike C's
    /// malloc'd `char *`/`_buffer` fields).
    fn emitGetFieldFromCdr(self: *CdrGenerator, s: *const ir.Struct, c_name: []const u8, cpp_qname: []const u8) !void {
        try self.print("bool {s}_get_field_from_cdr(const uint8_t *_payload, size_t _payload_len, const char *_field, size_t _field_len, zzdds_filter_value *_out, uint8_t *_scratch, size_t _scratch_len) {{\n", .{c_name});
        try self.writeI("ZidlCdrReader _r_data;\n");
        try self.writeI("int _rc = zidl_cdr_reader_init(&_r_data, _payload, _payload_len);\n");
        try self.writeI("if (_rc) return false;\n");
        try self.writeI("ZidlCdrReader *_r = &_r_data;\n");
        try self.printI("{s} _v;\n", .{cpp_qname});
        // Decode only the referenced field, skipping every other member.
        try self.writeI("uint32_t _fidx;\n");
        try self.printI("uint64_t _fmask = {s}_field_index(_field, _field_len, &_fidx) ? (1ull << _fidx) : 0;\n", .{c_name});
        try self.printI("_rc = {s}_deserialize_selected(_r, _fmask, &_v);\n", .{c_name});
        try self.writeI("if (_rc) return false;\n");
        try self.writeI("bool _matched = false;\n");
        var first = true;
        for (s.members) |m| {
            if (m.dimensions.len > 0) continue; // array member: not a simple filterable field
            const kind = classifyFilterFieldKindCpp(m.type_ref);
            if (kind == .skip) continue;
            try self.printI("{s} (_field_len == sizeof(\"{s}\") - 1 && memcmp(_field, \"{s}\", _field_len) == 0) {{\n", .{ if (first) "if" else "} else if", m.name, m.name });
            first = false;
            self.indent_depth += 1;
            switch (kind) {
                .skip => unreachable,
                .int_like => {
                    try self.writeI("_out->kind = 0;\n");
                    try self.printI("_out->i = static_cast<int64_t>(_v.{s});\n", .{m.name});
                    try self.writeI("_matched = true;\n");
                },
                .float32, .float64 => {
                    const value_kind: u8 = if (kind == .float32) 3 else 1;
                    try self.printI("_out->kind = {d};\n", .{value_kind});
                    try self.printI("_out->f = static_cast<double>(_v.{s});\n", .{m.name});
                    try self.writeI("_matched = true;\n");
                },
                .string_like => {
                    try self.printI("size_t _s_len = _v.{s}.size();\n", .{m.name});
                    try self.writeI("if (_s_len <= _scratch_len) {\n");
                    self.indent_depth += 1;
                    try self.printI("memcpy(_scratch, _v.{s}.data(), _s_len);\n", .{m.name});
                    try self.writeI("_out->kind = 2;\n");
                    try self.writeI("_out->s_ptr = _scratch;\n");
                    try self.writeI("_out->s_len = _s_len;\n");
                    try self.writeI("_matched = true;\n");
                    self.indent_depth -= 1;
                    try self.writeI("}\n");
                },
            }
            self.indent_depth -= 1;
        }
        if (!first) try self.writeI("}\n");
        try self.writeI("return _matched;\n");
        try self.write("}\n\n");
    }

    fn emitStructZzddsWrappers(self: *CdrGenerator, s: *const ir.Struct, c_name: []const u8, cpp_qname: []const u8) !void {
        try self.emitGetFieldFromCdr(s, c_name, cpp_qname);

        const class_name = s.name;
        const ns = moduleNsOf(s.qualified_name, s.name);

        // A2: open namespace so TypeSupport/DataWriter/DataReader live in the IDL module scope
        if (ns.len > 0) {
            var it = std.mem.splitSequence(u8, ns, "::");
            while (it.next()) |seg| try self.print("namespace {s} {{\n", .{seg});
            try self.write("\n");
        }

        try self.print("int {s}TypeSupport::register_type(DDS_DomainParticipant participant, const char *type_name) {{\n", .{class_name});
        // A1: fallback type_name uses IDL-scoped name (e.g. "ovidds::Frame")
        try self.printI("return zzdds_register_type_support(participant, type_name ? type_name : \"{s}\", {s}_compute_key_hash_from_cdr, {s}_get_field_from_cdr);\n", .{ s.qualified_name, c_name, c_name });
        try self.write("}\n\n");

        // Shared tail for _write_kind/_write_kind_w_timestamp/_write_kind_w_hash
        // below: all three already have their own (possibly pre-known) key
        // hash and a serialized payload by the time they get here -- the only
        // remaining difference between them is the timestamp, which
        // DDS_DataWriter_write_raw now takes directly (TIME_INVALID meaning
        // "use current time"), so this is the one place that actually calls
        // the raw op.
        try self.print("static int {s}_write_raw(DDS_DataWriter writer, DDS_WriteKind kind, const uint8_t *hash, DDS_InstanceHandle_t handle, const uint8_t *buf, size_t len, DDS_Time_t timestamp) {{\n", .{class_name});
        try self.writeI("DDS_OctetSeq _c_hash = { 16, 16, const_cast<uint8_t*>(hash), false };\n");
        try self.writeI("DDS_OctetSeq _c_payload = { (uint32_t)len, (uint32_t)len, const_cast<uint8_t*>(buf), false };\n");
        try self.writeI("return DDS_DataWriter_write_raw(writer, &_c_hash, handle, &_c_payload, kind, &timestamp);\n");
        try self.write("}\n\n");

        // write_kind (no explicit timestamp) uses the count-then-loan path
        // (Phase D's counting-mode ZidlCdrWriter sizes a loan_raw() buffer
        // exactly, then serializes directly into it -- no malloc/realloc
        // growth, and the buffer comes from zzdds's own write-loan pool
        // instead of libc). write_kind_w_timestamp below can't use this
        // path: DDS_DataWriter_publish_loan_raw has no source_timestamp
        // parameter (see dcps.idl) -- only the "use current time" callers
        // (this function and write_kind_w_hash) can route through a loan.
        try self.print("static int {s}_write_kind(DDS_DataWriter writer, int xcdr_version, DDS_WriteKind kind, const {s}& value, bool key_only, DDS_InstanceHandle_t handle) {{\n", .{ class_name, cpp_qname });
        try self.writeI("uint8_t _hash[16];\n");
        try self.printI("int _rc = {s}_compute_key_hash(&value, _hash);\n", .{c_name});
        try self.writeI("if (_rc) return _rc;\n");
        try self.writeI("ZidlCdrWriter _cw;\n");
        try self.writeI("zidl_cdr_writer_init_counting(&_cw, xcdr_version);\n");
        try self.writeI("_rc = zidl_cdr_write_encap(&_cw);\n");
        try self.printI("if (!_rc) _rc = key_only ? {s}_serialize_key(&_cw, &value) : {s}_serialize(&_cw, &value);\n", .{ c_name, c_name });
        try self.writeI("if (_rc) return _rc;\n");
        try self.writeI("DDS_OctetSeq _c_payload = {0};\n");
        try self.writeI("_rc = DDS_DataWriter_loan_raw(writer, (uint32_t)_cw.len, &_c_payload);\n");
        try self.writeI("if (_rc) return _rc;\n");
        try self.writeI("ZidlCdrWriter _w;\n");
        try self.writeI("zidl_cdr_writer_init_fixed(&_w, _c_payload._buffer, _c_payload._maximum, xcdr_version);\n");
        try self.writeI("_rc = zidl_cdr_write_encap(&_w);\n");
        try self.printI("if (!_rc) _rc = key_only ? {s}_serialize_key(&_w, &value) : {s}_serialize(&_w, &value);\n", .{ c_name, c_name });
        try self.writeI("if (_rc) {\n");
        self.indent_depth += 1;
        try self.writeI("DDS_DataWriter_return_loan_raw(writer, &_c_payload);\n");
        try self.writeI("return _rc;\n");
        self.indent_depth -= 1;
        try self.writeI("}\n");
        try self.writeI("DDS_OctetSeq _c_hash = { 16, 16, _hash, false };\n");
        try self.writeI("return DDS_DataWriter_publish_loan_raw(writer, &_c_payload, &_c_hash, handle, kind);\n");
        try self.write("}\n\n");

        try self.print("DDS_InstanceHandle_t {s}DataWriter::register_instance(const {s}& key) {{\n", .{ class_name, cpp_qname });
        try self.writeI("uint8_t _hash[16];\n");
        try self.printI("if ({s}_compute_key_hash(&key, _hash)) return DDS_HANDLE_NIL;\n", .{c_name});
        try self.writeI("DDS_InstanceHandle_t _ih = zzdds_register_instance_raw(writer_, _hash);\n");
        try self.writeI("if (_ih != DDS_HANDLE_NIL) {\n");
        try self.writeI("    std::array<uint8_t, 16> _arr;\n");
        try self.writeI("    std::memcpy(_arr.data(), _hash, 16);\n");
        try self.writeI("    instance_handles_[_ih] = _arr;\n");
        try self.writeI("}\n");
        try self.writeI("return _ih;\n");
        try self.write("}\n\n");

        // Unlike write/dispose/unregister_w_timestamp below (which thread
        // `timestamp` through to DDS_DataWriter_write_raw), zzdds's own
        // instance registration (zzdds_register_instance_raw) is a pure,
        // stateless key-hash-to-handle computation with no source-timestamp
        // involvement -- `timestamp` is accepted here only for spec-shape
        // compliance and is genuinely unused; delegates straight to
        // register_instance() so the instance_handles_ bookkeeping stays in
        // one place.
        try self.print("DDS_InstanceHandle_t {s}DataWriter::register_instance_w_timestamp(const {s}& key, DDS_Time_t timestamp) {{\n", .{ class_name, cpp_qname });
        try self.writeI("(void)timestamp;\n");
        try self.writeI("return register_instance(key);\n");
        try self.write("}\n\n");

        try self.print("static int {s}_write_kind_w_timestamp(DDS_DataWriter writer, int xcdr_version, DDS_WriteKind kind, const {s}& value, bool key_only, DDS_InstanceHandle_t handle, DDS_Time_t timestamp) {{\n", .{ class_name, cpp_qname });
        try self.writeI("ZidlCdrWriter _w;\n");
        try self.writeI("uint8_t _hash[16];\n");
        try self.writeI("int _rc = zidl_cdr_writer_init(&_w, xcdr_version);\n");
        try self.writeI("if (_rc) return _rc;\n");
        try self.writeI("_rc = zidl_cdr_write_encap(&_w);\n");
        try self.printI("if (!_rc) _rc = key_only ? {s}_serialize_key(&_w, &value) : {s}_serialize(&_w, &value);\n", .{ c_name, c_name });
        try self.printI("if (!_rc) _rc = {s}_compute_key_hash(&value, _hash);\n", .{c_name});
        try self.printI("if (!_rc) _rc = {s}_write_raw(writer, kind, _hash, handle, _w.buf, _w.len, timestamp);\n", .{class_name});
        try self.writeI("zidl_cdr_writer_deinit(&_w);\n");
        try self.writeI("return _rc;\n");
        try self.write("}\n\n");

        // write_kind_w_hash (pre-known hash, from the write_w_handle/
        // dispose_w_handle/unregister_instance_w_handle cache lookups) also
        // has no explicit timestamp -- same count-then-loan treatment as
        // write_kind above, just skipping the hash computation since the
        // caller already has it.
        try self.print("static int {s}_write_kind_w_hash(DDS_DataWriter writer, int xcdr_version, DDS_WriteKind kind, const {s}& value, bool key_only, const uint8_t *hash, DDS_InstanceHandle_t handle) {{\n", .{ class_name, cpp_qname });
        try self.writeI("ZidlCdrWriter _cw;\n");
        try self.writeI("zidl_cdr_writer_init_counting(&_cw, xcdr_version);\n");
        try self.writeI("int _rc = zidl_cdr_write_encap(&_cw);\n");
        try self.printI("if (!_rc) _rc = key_only ? {s}_serialize_key(&_cw, &value) : {s}_serialize(&_cw, &value);\n", .{ c_name, c_name });
        try self.writeI("if (_rc) return _rc;\n");
        try self.writeI("DDS_OctetSeq _c_payload = {0};\n");
        try self.writeI("_rc = DDS_DataWriter_loan_raw(writer, (uint32_t)_cw.len, &_c_payload);\n");
        try self.writeI("if (_rc) return _rc;\n");
        try self.writeI("ZidlCdrWriter _w;\n");
        try self.writeI("zidl_cdr_writer_init_fixed(&_w, _c_payload._buffer, _c_payload._maximum, xcdr_version);\n");
        try self.writeI("_rc = zidl_cdr_write_encap(&_w);\n");
        try self.printI("if (!_rc) _rc = key_only ? {s}_serialize_key(&_w, &value) : {s}_serialize(&_w, &value);\n", .{ c_name, c_name });
        try self.writeI("if (_rc) {\n");
        self.indent_depth += 1;
        try self.writeI("DDS_DataWriter_return_loan_raw(writer, &_c_payload);\n");
        try self.writeI("return _rc;\n");
        self.indent_depth -= 1;
        try self.writeI("}\n");
        try self.writeI("DDS_OctetSeq _c_hash = { 16, 16, const_cast<uint8_t*>(hash), false };\n");
        try self.writeI("return DDS_DataWriter_publish_loan_raw(writer, &_c_payload, &_c_hash, handle, kind);\n");
        try self.write("}\n\n");

        try self.print("int {s}DataWriter::write(const {s}& value) {{\n", .{ class_name, cpp_qname });
        try self.printI("return {s}_write_kind(writer_, xcdr_version_, DDS_WriteKind_ALIVE_WRITE_KIND, value, false, DDS_HANDLE_NIL);\n", .{class_name});
        try self.write("}\n\n");
        try self.print("int {s}DataWriter::write_w_timestamp(const {s}& value, DDS_Time_t timestamp) {{\n", .{ class_name, cpp_qname });
        try self.printI("return {s}_write_kind_w_timestamp(writer_, xcdr_version_, DDS_WriteKind_ALIVE_WRITE_KIND, value, false, DDS_HANDLE_NIL, timestamp);\n", .{class_name});
        try self.write("}\n\n");
        try self.print("int {s}DataWriter::dispose(const {s}& key) {{\n", .{ class_name, cpp_qname });
        try self.printI("return {s}_write_kind(writer_, xcdr_version_, DDS_WriteKind_DISPOSE_WRITE_KIND, key, true, DDS_HANDLE_NIL);\n", .{class_name});
        try self.write("}\n\n");
        try self.print("int {s}DataWriter::dispose_w_timestamp(const {s}& key, DDS_Time_t timestamp) {{\n", .{ class_name, cpp_qname });
        try self.printI("return {s}_write_kind_w_timestamp(writer_, xcdr_version_, DDS_WriteKind_DISPOSE_WRITE_KIND, key, true, DDS_HANDLE_NIL, timestamp);\n", .{class_name});
        try self.write("}\n\n");
        try self.print("int {s}DataWriter::unregister_instance(const {s}& key) {{\n", .{ class_name, cpp_qname });
        try self.printI("return {s}_write_kind(writer_, xcdr_version_, DDS_WriteKind_UNREGISTER_WRITE_KIND, key, true, DDS_HANDLE_NIL);\n", .{class_name});
        try self.write("}\n\n");
        try self.print("int {s}DataWriter::unregister_instance_w_timestamp(const {s}& key, DDS_Time_t timestamp) {{\n", .{ class_name, cpp_qname });
        try self.printI("return {s}_write_kind_w_timestamp(writer_, xcdr_version_, DDS_WriteKind_UNREGISTER_WRITE_KIND, key, true, DDS_HANDLE_NIL, timestamp);\n", .{class_name});
        try self.write("}\n\n");
        try self.print("int {s}DataWriter::get_key_value(DDS_InstanceHandle_t handle, {s}& key_out) {{\n", .{ class_name, cpp_qname });
        try self.writeI("uint8_t _buf[ZZDDS_KEY_VALUE_BUF_SIZE];\n");
        try self.writeI("size_t _len = 0;\n");
        try self.writeI("int _rc = zzdds_get_key_value_writer(writer_, handle, _buf, sizeof(_buf), &_len);\n");
        try self.writeI("if (_rc) return _rc;\n");
        try self.writeI("ZidlCdrReader _r;\n");
        try self.writeI("_rc = zidl_cdr_reader_init(&_r, _buf, _len);\n");
        try self.writeI("if (_rc) return _rc;\n");
        // The stored blob is the whole last-alive sample keyed by instance
        // handle; _deserialize_selected decodes just the @key members and skips
        // the rest. Non-key fields of key_out stay default-constructed --
        // unspecified per DDS 1.4 §2.2.2.4.2.17.
        try self.printI("return {s}_deserialize_selected(&_r, {s}_KEY_FIELD_MASK, &key_out);\n", .{ c_name, c_name });
        try self.write("}\n\n");
        try self.print("DDS_InstanceHandle_t {s}DataWriter::lookup_instance(const {s}& key) {{\n", .{ class_name, cpp_qname });
        try self.writeI("uint8_t _hash[16];\n");
        try self.printI("if ({s}_compute_key_hash(&key, _hash)) return DDS_HANDLE_NIL;\n", .{c_name});
        try self.writeI("DDS_InstanceHandle_t _ih = zzdds_lookup_instance_writer(writer_, _hash);\n");
        try self.writeI("if (_ih != DDS_HANDLE_NIL) {\n");
        try self.writeI("    std::array<uint8_t, 16> _arr;\n");
        try self.writeI("    std::memcpy(_arr.data(), _hash, 16);\n");
        try self.writeI("    instance_handles_[_ih] = _arr;\n");
        try self.writeI("}\n");
        try self.writeI("return _ih;\n");
        try self.write("}\n\n");

        try self.print("int {s}DataWriter::write_w_handle(const {s}& value, DDS_InstanceHandle_t handle) {{\n", .{ class_name, cpp_qname });
        try self.writeI("auto it = instance_handles_.find(handle);\n");
        try self.writeI("if (it == instance_handles_.end()) return DDS_RETCODE_BAD_PARAMETER;\n");
        try self.printI("return {s}_write_kind_w_hash(writer_, xcdr_version_, DDS_WriteKind_ALIVE_WRITE_KIND, value, false, it->second.data(), handle);\n", .{class_name});
        try self.write("}\n\n");
        try self.print("int {s}DataWriter::dispose_w_handle(const {s}& key, DDS_InstanceHandle_t handle) {{\n", .{ class_name, cpp_qname });
        try self.writeI("auto it = instance_handles_.find(handle);\n");
        try self.writeI("if (it == instance_handles_.end()) return DDS_RETCODE_BAD_PARAMETER;\n");
        try self.printI("return {s}_write_kind_w_hash(writer_, xcdr_version_, DDS_WriteKind_DISPOSE_WRITE_KIND, key, true, it->second.data(), handle);\n", .{class_name});
        try self.write("}\n\n");
        try self.print("int {s}DataWriter::unregister_instance_w_handle(const {s}& key, DDS_InstanceHandle_t handle) {{\n", .{ class_name, cpp_qname });
        try self.writeI("auto it = instance_handles_.find(handle);\n");
        try self.writeI("if (it == instance_handles_.end()) return DDS_RETCODE_BAD_PARAMETER;\n");
        try self.printI("int _rc = {s}_write_kind_w_hash(writer_, xcdr_version_, DDS_WriteKind_UNREGISTER_WRITE_KIND, key, true, it->second.data(), handle);\n", .{class_name});
        try self.writeI("if (!_rc) instance_handles_.erase(it);\n");
        try self.writeI("return _rc;\n");
        try self.write("}\n\n");

        // Single-sample take/read/take_next_instance/read_next_instance below:
        // `buf`/`buf_size` are no longer used (the new raw ops always allocate
        // their own storage, copy mode or loan mode) -- kept as unused params
        // so this is a signature-compatible drop-in for existing callers, same
        // as the C backend's equivalent rewrite. Each op is always called in
        // copy mode (_maximum = 1, any nonzero value works) since a single
        // sample's worth of loan-mode zero-copy has no benefit over copying
        // once into `out.value` right away, and immediately releases the raw
        // op's own allocation via return_loan_raw once decoded.
        try self.print("DDS_ReturnCode_t {s}DataReader::take(Sample& out, uint8_t *buf, size_t buf_size, size_t *cdr_len_out) {{\n", .{class_name});
        try self.writeI("(void)buf; (void)buf_size;\n");
        try self.writeI("DDS_OctetSeqSeq _c_payloads = { 1, 0, NULL, false };\n");
        try self.writeI("DDS_OctetSeq _c_hashes = {0};\n");
        try self.writeI("DDS_SampleInfoSeq _c_infos = {0};\n");
        try self.writeI("DDS_ReturnCode_t _n = DDS_DataReader_take_raw(reader_, &_c_payloads, &_c_hashes, &_c_infos, DDS_HANDLE_NIL, nullptr, DDS_ANY_SAMPLE_STATE, DDS_ANY_VIEW_STATE, DDS_ANY_INSTANCE_STATE, 1);\n");
        try self.writeI("if (_n != DDS_RETCODE_OK) return _n;\n");
        try self.writeI("if (_c_payloads._length == 0) return DDS_RETCODE_NO_DATA;\n");
        try self.writeI("if (cdr_len_out) *cdr_len_out = _c_payloads._buffer[0]._length;\n");
        try self.writeI("out.info = _c_infos._buffer[0];\n");
        try self.writeI("ZidlCdrReader _r;\n");
        try self.writeI("int _rc = zidl_cdr_reader_init(&_r, _c_payloads._buffer[0]._buffer, _c_payloads._buffer[0]._length);\n");
        try self.printI("if (!_rc) _rc = out.info.valid_data ? {s}_deserialize(&_r, &out.value) : {s}_deserialize_key(&_r, &out.value);\n", .{ c_name, c_name });
        try self.writeI("DDS_DataReader_return_loan_raw(reader_, &_c_payloads, &_c_hashes, &_c_infos);\n");
        try self.writeI("return _rc;\n");
        try self.write("}\n\n");

        try self.print("DDS_ReturnCode_t {s}DataReader::read(Sample& out, uint8_t *buf, size_t buf_size, size_t *cdr_len_out) {{\n", .{class_name});
        try self.writeI("(void)buf; (void)buf_size;\n");
        try self.writeI("DDS_OctetSeqSeq _c_payloads = { 1, 0, NULL, false };\n");
        try self.writeI("DDS_OctetSeq _c_hashes = {0};\n");
        try self.writeI("DDS_SampleInfoSeq _c_infos = {0};\n");
        try self.writeI("DDS_ReturnCode_t _n = DDS_DataReader_read_raw(reader_, &_c_payloads, &_c_hashes, &_c_infos, DDS_HANDLE_NIL, nullptr, DDS_ANY_SAMPLE_STATE, DDS_ANY_VIEW_STATE, DDS_ANY_INSTANCE_STATE, 1);\n");
        try self.writeI("if (_n != DDS_RETCODE_OK) return _n;\n");
        try self.writeI("if (_c_payloads._length == 0) return DDS_RETCODE_NO_DATA;\n");
        try self.writeI("if (cdr_len_out) *cdr_len_out = _c_payloads._buffer[0]._length;\n");
        try self.writeI("out.info = _c_infos._buffer[0];\n");
        try self.writeI("ZidlCdrReader _r;\n");
        try self.writeI("int _rc = zidl_cdr_reader_init(&_r, _c_payloads._buffer[0]._buffer, _c_payloads._buffer[0]._length);\n");
        try self.printI("if (!_rc) _rc = out.info.valid_data ? {s}_deserialize(&_r, &out.value) : {s}_deserialize_key(&_r, &out.value);\n", .{ c_name, c_name });
        try self.writeI("DDS_DataReader_return_loan_raw(reader_, &_c_payloads, &_c_hashes, &_c_infos);\n");
        try self.writeI("return _rc;\n");
        try self.write("}\n\n");

        try self.print("DDS_ReturnCode_t {s}DataReader::take_next_instance(Sample& out, DDS_InstanceHandle_t prev, uint8_t *buf, size_t buf_size, size_t *cdr_len_out) {{\n", .{class_name});
        try self.writeI("(void)buf; (void)buf_size;\n");
        try self.writeI("DDS_OctetSeqSeq _c_payloads = { 1, 0, NULL, false };\n");
        try self.writeI("DDS_OctetSeq _c_hashes = {0};\n");
        try self.writeI("DDS_SampleInfoSeq _c_infos = {0};\n");
        try self.writeI("DDS_ReturnCode_t _n = DDS_DataReader_take_next_instance_raw(reader_, &_c_payloads, &_c_hashes, &_c_infos, prev, nullptr, DDS_ANY_SAMPLE_STATE, DDS_ANY_VIEW_STATE, DDS_ANY_INSTANCE_STATE, 1);\n");
        try self.writeI("if (_n != DDS_RETCODE_OK) return _n;\n");
        try self.writeI("if (_c_payloads._length == 0) return DDS_RETCODE_NO_DATA;\n");
        try self.writeI("if (cdr_len_out) *cdr_len_out = _c_payloads._buffer[0]._length;\n");
        try self.writeI("out.info = _c_infos._buffer[0];\n");
        try self.writeI("ZidlCdrReader _r;\n");
        try self.writeI("int _rc = zidl_cdr_reader_init(&_r, _c_payloads._buffer[0]._buffer, _c_payloads._buffer[0]._length);\n");
        try self.printI("if (!_rc) _rc = out.info.valid_data ? {s}_deserialize(&_r, &out.value) : {s}_deserialize_key(&_r, &out.value);\n", .{ c_name, c_name });
        try self.writeI("DDS_DataReader_return_loan_raw(reader_, &_c_payloads, &_c_hashes, &_c_infos);\n");
        try self.writeI("return _rc;\n");
        try self.write("}\n\n");

        try self.print("DDS_ReturnCode_t {s}DataReader::read_next_instance(Sample& out, DDS_InstanceHandle_t prev, uint8_t *buf, size_t buf_size, size_t *cdr_len_out) {{\n", .{class_name});
        try self.writeI("(void)buf; (void)buf_size;\n");
        try self.writeI("DDS_OctetSeqSeq _c_payloads = { 1, 0, NULL, false };\n");
        try self.writeI("DDS_OctetSeq _c_hashes = {0};\n");
        try self.writeI("DDS_SampleInfoSeq _c_infos = {0};\n");
        try self.writeI("DDS_ReturnCode_t _n = DDS_DataReader_read_next_instance_raw(reader_, &_c_payloads, &_c_hashes, &_c_infos, prev, nullptr, DDS_ANY_SAMPLE_STATE, DDS_ANY_VIEW_STATE, DDS_ANY_INSTANCE_STATE, 1);\n");
        try self.writeI("if (_n != DDS_RETCODE_OK) return _n;\n");
        try self.writeI("if (_c_payloads._length == 0) return DDS_RETCODE_NO_DATA;\n");
        try self.writeI("if (cdr_len_out) *cdr_len_out = _c_payloads._buffer[0]._length;\n");
        try self.writeI("out.info = _c_infos._buffer[0];\n");
        try self.writeI("ZidlCdrReader _r;\n");
        try self.writeI("int _rc = zidl_cdr_reader_init(&_r, _c_payloads._buffer[0]._buffer, _c_payloads._buffer[0]._length);\n");
        try self.printI("if (!_rc) _rc = out.info.valid_data ? {s}_deserialize(&_r, &out.value) : {s}_deserialize_key(&_r, &out.value);\n", .{ c_name, c_name });
        try self.writeI("DDS_DataReader_return_loan_raw(reader_, &_c_payloads, &_c_hashes, &_c_infos);\n");
        try self.writeI("return _rc;\n");
        try self.write("}\n\n");

        try self.print("int {s}DataReader::get_key_value(DDS_InstanceHandle_t handle, {s}& key_out) {{\n", .{ class_name, cpp_qname });
        try self.writeI("uint8_t _buf[ZZDDS_KEY_VALUE_BUF_SIZE];\n");
        try self.writeI("size_t _len = 0;\n");
        try self.writeI("int _rc = zzdds_get_key_value_reader(reader_, handle, _buf, sizeof(_buf), &_len);\n");
        try self.writeI("if (_rc) return _rc;\n");
        try self.writeI("ZidlCdrReader _r;\n");
        try self.writeI("_rc = zidl_cdr_reader_init(&_r, _buf, _len);\n");
        try self.writeI("if (_rc) return _rc;\n");
        // See DataWriter get_key_value: the stored payload is a full sample.
        try self.printI("return {s}_deserialize_selected(&_r, {s}_KEY_FIELD_MASK, &key_out);\n", .{ c_name, c_name });
        try self.write("}\n\n");

        try self.print("DDS_InstanceHandle_t {s}DataReader::lookup_instance(const {s}& key) {{\n", .{ class_name, cpp_qname });
        try self.writeI("uint8_t _hash[16];\n");
        try self.printI("if ({s}_compute_key_hash(&key, _hash)) return DDS_HANDLE_NIL;\n", .{c_name});
        try self.writeI("return zzdds_lookup_instance_reader(reader_, _hash);\n");
        try self.write("}\n\n");

        // Decodes a copy-mode take_raw/read_raw-family batch result
        // (_payloads/_infos, already populated by the caller's own raw-op
        // call) into values/infos, releasing the batch via
        // DDS_DataReader_return_loan_raw either way -- the shared tail of
        // every batch reader op below (take_n/read_n, take_instance/
        // read_instance, take_w_condition/read_w_condition,
        // take_next_instance_w_condition/read_next_instance_w_condition),
        // which otherwise only differ in which raw op produces the batch.
        // `values[_j] = {}` on a decode error relies on values' own
        // assignment operator to release any partially-decoded state
        // (std::vector/std::string members clean up themselves) -- unlike
        // the C backend's equivalent, there's no separate manual _free()
        // call needed here.
        try self.print("static int {s}_reader_decode_batch(DDS_DataReader reader, DDS_OctetSeqSeq *_payloads, DDS_OctetSeq *_hashes, DDS_SampleInfoSeq *_infos, {s} *values, DDS_SampleInfo *infos) {{\n", .{ class_name, cpp_qname });
        try self.writeI("for (uint32_t _i = 0; _i < _payloads->_length; _i++) {\n");
        self.indent_depth += 1;
        try self.writeI("infos[_i] = _infos->_buffer[_i];\n");
        try self.writeI("ZidlCdrReader _r;\n");
        try self.writeI("int _rc = zidl_cdr_reader_init(&_r, _payloads->_buffer[_i]._buffer, _payloads->_buffer[_i]._length);\n");
        try self.writeI("if (!_rc) _rc = infos[_i].valid_data ?\n");
        self.indent_depth += 1;
        try self.printI("{s}_deserialize(&_r, &values[_i]) :\n", .{c_name});
        try self.printI("{s}_deserialize_key(&_r, &values[_i]);\n", .{c_name});
        self.indent_depth -= 1;
        try self.writeI("if (_rc) {\n");
        self.indent_depth += 1;
        try self.writeI("for (uint32_t _j = 0; _j <= _i; _j++) values[_j] = {};\n");
        try self.writeI("DDS_DataReader_return_loan_raw(reader, _payloads, _hashes, _infos);\n");
        try self.writeI("return _rc;\n");
        self.indent_depth -= 1;
        try self.writeI("}\n");
        self.indent_depth -= 1;
        try self.writeI("}\n");
        try self.writeI("int _n = (int)_payloads->_length;\n");
        try self.writeI("DDS_DataReader_return_loan_raw(reader, _payloads, _hashes, _infos);\n");
        try self.writeI("return _n;\n");
        try self.write("}\n\n");

        try self.print("static int {s}_reader_n_impl(DDS_DataReader reader, {s} *values, DDS_SampleInfo *infos, int max, uint32_t ss, uint32_t vs, uint32_t is, bool destructive) {{\n", .{ class_name, cpp_qname });
        try self.writeI("DDS_OctetSeqSeq _c_payloads = { 1, 0, NULL, false };\n");
        try self.writeI("DDS_OctetSeq _c_hashes = {0};\n");
        try self.writeI("DDS_SampleInfoSeq _c_infos = {0};\n");
        try self.writeI("DDS_ReturnCode_t _rc0 = destructive ?\n");
        self.indent_depth += 1;
        try self.writeI("DDS_DataReader_take_raw(reader, &_c_payloads, &_c_hashes, &_c_infos, DDS_HANDLE_NIL, nullptr, ss, vs, is, max) :\n");
        try self.writeI("DDS_DataReader_read_raw(reader, &_c_payloads, &_c_hashes, &_c_infos, DDS_HANDLE_NIL, nullptr, ss, vs, is, max);\n");
        self.indent_depth -= 1;
        try self.writeI("if (_rc0 != DDS_RETCODE_OK) return -1;\n");
        try self.printI("return {s}_reader_decode_batch(reader, &_c_payloads, &_c_hashes, &_c_infos, values, infos);\n", .{class_name});
        try self.write("}\n\n");

        try self.print("int {s}DataReader::take_n({s} *values, DDS_SampleInfo *infos, int max, uint32_t ss, uint32_t vs, uint32_t is) {{\n", .{ class_name, cpp_qname });
        try self.writeI("return ");
        try self.print("{s}_reader_n_impl(reader_, values, infos, max, ss, vs, is, true);\n", .{class_name});
        try self.write("}\n\n");
        try self.print("int {s}DataReader::read_n({s} *values, DDS_SampleInfo *infos, int max, uint32_t ss, uint32_t vs, uint32_t is) {{\n", .{ class_name, cpp_qname });
        try self.writeI("return ");
        try self.print("{s}_reader_n_impl(reader_, values, infos, max, ss, vs, is, false);\n", .{class_name});
        try self.write("}\n\n");

        try self.print("static int {s}_reader_n_instance_impl(DDS_DataReader reader, DDS_InstanceHandle_t instance_handle, {s} *values, DDS_SampleInfo *infos, int max, uint32_t ss, uint32_t vs, uint32_t is, bool destructive) {{\n", .{ class_name, cpp_qname });
        try self.writeI("DDS_OctetSeqSeq _c_payloads = { 1, 0, NULL, false };\n");
        try self.writeI("DDS_OctetSeq _c_hashes = {0};\n");
        try self.writeI("DDS_SampleInfoSeq _c_infos = {0};\n");
        try self.writeI("DDS_ReturnCode_t _rc0 = destructive ?\n");
        self.indent_depth += 1;
        try self.writeI("DDS_DataReader_take_raw(reader, &_c_payloads, &_c_hashes, &_c_infos, instance_handle, nullptr, ss, vs, is, max) :\n");
        try self.writeI("DDS_DataReader_read_raw(reader, &_c_payloads, &_c_hashes, &_c_infos, instance_handle, nullptr, ss, vs, is, max);\n");
        self.indent_depth -= 1;
        try self.writeI("if (_rc0 != DDS_RETCODE_OK) return -1;\n");
        try self.printI("return {s}_reader_decode_batch(reader, &_c_payloads, &_c_hashes, &_c_infos, values, infos);\n", .{class_name});
        try self.write("}\n\n");

        try self.print("int {s}DataReader::take_instance(DDS_InstanceHandle_t instance_handle, {s} *values, DDS_SampleInfo *infos, int max, uint32_t ss, uint32_t vs, uint32_t is) {{\n", .{ class_name, cpp_qname });
        try self.writeI("return ");
        try self.print("{s}_reader_n_instance_impl(reader_, instance_handle, values, infos, max, ss, vs, is, true);\n", .{class_name});
        try self.write("}\n\n");
        try self.print("int {s}DataReader::read_instance(DDS_InstanceHandle_t instance_handle, {s} *values, DDS_SampleInfo *infos, int max, uint32_t ss, uint32_t vs, uint32_t is) {{\n", .{ class_name, cpp_qname });
        try self.writeI("return ");
        try self.print("{s}_reader_n_instance_impl(reader_, instance_handle, values, infos, max, ss, vs, is, false);\n", .{class_name});
        try self.write("}\n\n");

        try self.print("static int {s}_reader_w_condition_impl(DDS_DataReader reader, DDS_ReadCondition condition, {s} *values, DDS_SampleInfo *infos, int max, bool destructive) {{\n", .{ class_name, cpp_qname });
        try self.writeI("DDS_OctetSeqSeq _c_payloads = { 1, 0, NULL, false };\n");
        try self.writeI("DDS_OctetSeq _c_hashes = {0};\n");
        try self.writeI("DDS_SampleInfoSeq _c_infos = {0};\n");
        try self.writeI("DDS_ReturnCode_t _rc0 = destructive ?\n");
        self.indent_depth += 1;
        try self.writeI("DDS_DataReader_take_raw(reader, &_c_payloads, &_c_hashes, &_c_infos, DDS_HANDLE_NIL, condition, DDS_ANY_SAMPLE_STATE, DDS_ANY_VIEW_STATE, DDS_ANY_INSTANCE_STATE, max) :\n");
        try self.writeI("DDS_DataReader_read_raw(reader, &_c_payloads, &_c_hashes, &_c_infos, DDS_HANDLE_NIL, condition, DDS_ANY_SAMPLE_STATE, DDS_ANY_VIEW_STATE, DDS_ANY_INSTANCE_STATE, max);\n");
        self.indent_depth -= 1;
        try self.writeI("if (_rc0 != DDS_RETCODE_OK) return -1;\n");
        try self.printI("return {s}_reader_decode_batch(reader, &_c_payloads, &_c_hashes, &_c_infos, values, infos);\n", .{class_name});
        try self.write("}\n\n");

        try self.print("int {s}DataReader::take_w_condition(DDS_ReadCondition condition, {s} *values, DDS_SampleInfo *infos, int max) {{\n", .{ class_name, cpp_qname });
        try self.writeI("return ");
        try self.print("{s}_reader_w_condition_impl(reader_, condition, values, infos, max, true);\n", .{class_name});
        try self.write("}\n\n");
        try self.print("int {s}DataReader::read_w_condition(DDS_ReadCondition condition, {s} *values, DDS_SampleInfo *infos, int max) {{\n", .{ class_name, cpp_qname });
        try self.writeI("return ");
        try self.print("{s}_reader_w_condition_impl(reader_, condition, values, infos, max, false);\n", .{class_name});
        try self.write("}\n\n");

        try self.print("static int {s}_reader_next_instance_w_condition_impl(DDS_DataReader reader, DDS_ReadCondition condition, DDS_InstanceHandle_t prev, {s} *values, DDS_SampleInfo *infos, int max, bool destructive) {{\n", .{ class_name, cpp_qname });
        try self.writeI("DDS_OctetSeqSeq _c_payloads = { 1, 0, NULL, false };\n");
        try self.writeI("DDS_OctetSeq _c_hashes = {0};\n");
        try self.writeI("DDS_SampleInfoSeq _c_infos = {0};\n");
        try self.writeI("DDS_ReturnCode_t _rc0 = destructive ?\n");
        self.indent_depth += 1;
        try self.writeI("DDS_DataReader_take_next_instance_raw(reader, &_c_payloads, &_c_hashes, &_c_infos, prev, condition, DDS_ANY_SAMPLE_STATE, DDS_ANY_VIEW_STATE, DDS_ANY_INSTANCE_STATE, max) :\n");
        try self.writeI("DDS_DataReader_read_next_instance_raw(reader, &_c_payloads, &_c_hashes, &_c_infos, prev, condition, DDS_ANY_SAMPLE_STATE, DDS_ANY_VIEW_STATE, DDS_ANY_INSTANCE_STATE, max);\n");
        self.indent_depth -= 1;
        try self.writeI("if (_rc0 != DDS_RETCODE_OK) return -1;\n");
        try self.printI("return {s}_reader_decode_batch(reader, &_c_payloads, &_c_hashes, &_c_infos, values, infos);\n", .{class_name});
        try self.write("}\n\n");

        try self.print("int {s}DataReader::take_next_instance_w_condition(DDS_ReadCondition condition, DDS_InstanceHandle_t prev, {s} *values, DDS_SampleInfo *infos, int max) {{\n", .{ class_name, cpp_qname });
        try self.writeI("return ");
        try self.print("{s}_reader_next_instance_w_condition_impl(reader_, condition, prev, values, infos, max, true);\n", .{class_name});
        try self.write("}\n\n");
        try self.print("int {s}DataReader::read_next_instance_w_condition(DDS_ReadCondition condition, DDS_InstanceHandle_t prev, {s} *values, DDS_SampleInfo *infos, int max) {{\n", .{ class_name, cpp_qname });
        try self.writeI("return ");
        try self.print("{s}_reader_next_instance_w_condition_impl(reader_, condition, prev, values, infos, max, false);\n", .{class_name});
        try self.write("}\n\n");

        // take_loaned/return_loan's signature deliberately changed -- see the
        // matching class-decl comment above. loan_payloads_/loan_infos_ start
        // zero-initialized (Loan's member declarations), matching every other
        // caller-owned inout sequence's convention in this API.
        try self.print("DDS_ReturnCode_t {s}DataReader::take_loaned(Loan& out) {{\n", .{class_name});
        try self.writeI("DDS_OctetSeqSeq _loan_payloads = { 0, 0, NULL, false };\n");
        try self.writeI("DDS_SampleInfoSeq _loan_infos = {0};\n");
        try self.writeI("DDS_OctetSeq _c_hashes = {0};\n");
        try self.writeI("Sample _sample{};\n");
        try self.writeI("DDS_ReturnCode_t _n = DDS_DataReader_take_raw(reader_, &_loan_payloads, &_c_hashes, &_loan_infos, DDS_HANDLE_NIL, nullptr, DDS_ANY_SAMPLE_STATE, DDS_ANY_VIEW_STATE, DDS_ANY_INSTANCE_STATE, 1);\n");
        // key_hashes is always a plain copy, independent of _loan_payloads'
        // loan lifetime (see take_raw's own doc comment) -- released right
        // away here rather than held for the Loan's lifetime. return_loan_raw
        // is still the only correct way to release it (a generic free can't
        // recover this reader's own allocator); passing zeroed payloads/infos
        // locals limits this call to releasing only _c_hashes, leaving
        // _loan_payloads/_loan_infos untouched.
        try self.writeI("{ DDS_OctetSeqSeq _c_empty_payloads = {0}; DDS_SampleInfoSeq _c_empty_infos = {0}; DDS_DataReader_return_loan_raw(reader_, &_c_empty_payloads, &_c_hashes, &_c_empty_infos); }\n");
        try self.writeI("if (_n != DDS_RETCODE_OK) return _n;\n");
        try self.writeI("if (_loan_payloads._length == 0) return DDS_RETCODE_NO_DATA;\n");
        try self.writeI("_sample.info = _loan_infos._buffer[0];\n");
        try self.writeI("ZidlCdrReader _r;\n");
        try self.writeI("int _rc = zidl_cdr_reader_init(&_r, _loan_payloads._buffer[0]._buffer, _loan_payloads._buffer[0]._length);\n");
        try self.printI("if (!_rc) _rc = _sample.info.valid_data ? {s}_deserialize(&_r, &_sample.value) : {s}_deserialize_key(&_r, &_sample.value);\n", .{ c_name, c_name });
        try self.writeI("if (_rc) { DDS_OctetSeq _c_no_hashes = {0}; DDS_DataReader_return_loan_raw(reader_, &_loan_payloads, &_c_no_hashes, &_loan_infos); return _rc; }\n");
        try self.writeI("out = Loan(this, _loan_payloads, _loan_infos, _sample);\n");
        try self.writeI("return DDS_RETCODE_OK;\n");
        try self.write("}\n\n");

        try self.print("void {s}DataReader::Loan::reset() {{\n", .{class_name});
        try self.writeI("if (active_ && reader_) {\n");
        self.indent_depth += 1;
        // See take_loaned's matching comment -- key_hashes was already
        // released there, so this always passes an empty one.
        try self.writeI("DDS_OctetSeq _c_no_hashes = {0};\n");
        try self.writeI("DDS_DataReader_return_loan_raw(reader_->reader_, &loan_payloads_, &_c_no_hashes, &loan_infos_);\n");
        try self.writeI("active_ = false;\n");
        self.indent_depth -= 1;
        try self.writeI("}\n");
        try self.write("}\n\n");

        // A2: close namespace opened above
        if (ns.len > 0) {
            var segs: std.ArrayListUnmanaged([]const u8) = .empty;
            defer segs.deinit(self.alloc);
            var it2 = std.mem.splitSequence(u8, ns, "::");
            while (it2.next()) |seg| try segs.append(self.alloc, seg);
            var i = segs.items.len;
            while (i > 0) {
                i -= 1;
                try self.print("}} // namespace {s}\n", .{segs.items[i]});
            }
            try self.write("\n");
        }
    }

    fn emitExceptionFns(self: *CdrGenerator, e: *const ir.Exception) !void {
        const c_name = try self.prefixedCName(e.qualified_name);
        defer self.alloc.free(c_name);
        const cpp_qname = try std.fmt.allocPrint(self.alloc, "::{s}", .{e.qualified_name});
        defer self.alloc.free(cpp_qname);

        try self.print("int {s}_serialize(ZidlCdrWriter *_w, const {s} *_v) {{\n", .{ c_name, cpp_qname });
        try self.writeI("int _rc;\n");
        for (e.members) |m| {
            const access = try std.fmt.allocPrint(self.alloc, "_v->{s}", .{m.name});
            defer self.alloc.free(access);
            if (m.dimensions.len > 0) {
                try self.emitWriteArray(m.type_ref, access, m.dimensions, 0);
            } else {
                try self.emitWriteForTypeRef(m.type_ref, m.name, access);
            }
        }
        try self.writeI("return ZIDL_CDR_OK;\n");
        try self.write("}\n\n");

        try self.print("int {s}_deserialize(ZidlCdrReader *_r, {s} *_v) {{\n", .{ c_name, cpp_qname });
        try self.writeI("int _rc;\n");
        for (e.members) |m| {
            const lval = try std.fmt.allocPrint(self.alloc, "_v->{s}", .{m.name});
            defer self.alloc.free(lval);
            if (m.dimensions.len > 0) {
                try self.emitReadArray(m.type_ref, m.name, lval, m.dimensions, 0);
            } else {
                try self.emitReadForTypeRef(m.type_ref, m.name, lval);
            }
        }
        try self.writeI("return ZIDL_CDR_OK;\n");
        try self.write("}\n\n");
    }

    // ── Union ─────────────────────────────────────────────────────────────────

    /// True if a scalar (non-array) union case of this type is serialized
    /// via `Foo_serialize(_w, &access)` -- i.e. needs an addressable lvalue
    /// -- rather than by passing/calling on `access` directly. See
    /// `emitUnionCaseSerializeAccess`.
    fn typeRefNeedsAddressableAccess(tr: ir.TypeRef) bool {
        return switch (resolveTypeRef(tr)) {
            .named => |td| switch (td) {
                .struct_, .union_, .exception => true,
                else => false,
            },
            else => false,
        };
    }

    /// Build the access expression for a scalar (non-array) union case
    /// inside a serialize switch arm. The case's own getter
    /// (`{s} {s}() const { return _u._{s}; }` in Generator.emitUnion, see
    /// there) returns by value for every non-array case -- fine for a type
    /// serialized by calling a method on it or passing it directly (base,
    /// string, sequence, enum, …), but a struct/union/exception-typed case
    /// is serialized via `Foo_serialize(_w, &access)`, and taking the
    /// address of that by-value return (a temporary) is ill-formed C++.
    /// For those, declare a local `const` copy first and return its name (a
    /// real lvalue) instead of the raw getter-call expression.
    fn emitUnionCaseSerializeAccess(self: *CdrGenerator, cas: ir.UnionCase) anyerror![]u8 {
        if (typeRefNeedsAddressableAccess(cas.type_ref)) {
            const cpp_type = try cppTypeStr(self.alloc, self.opts, cas.type_ref);
            defer self.alloc.free(cpp_type);
            const tmp_name = try std.fmt.allocPrint(self.alloc, "_tmp_{s}", .{cas.name});
            try self.printI("const {s} {s} = _v->{s}();\n", .{ cpp_type, tmp_name, cas.name });
            return tmp_name;
        }
        return std.fmt.allocPrint(self.alloc, "_v->{s}()", .{cas.name});
    }

    fn emitUnionFns(self: *CdrGenerator, u: *const ir.Union) anyerror!void {
        const c_name = try self.prefixedCName(u.qualified_name);
        defer self.alloc.free(c_name);
        const cpp_qname = try std.fmt.allocPrint(self.alloc, "::{s}", .{u.qualified_name});
        defer self.alloc.free(cpp_qname);

        const ext = u.annotations.extensibility;
        const appendable = (ext == .appendable or ext == .mutable);
        const mutable = (ext == .mutable);

        // ── serialize ────────────────────────────────────────────────────────

        try self.print("int {s}_serialize(ZidlCdrWriter *_w, const {s} *_v) {{\n", .{ c_name, cpp_qname });
        if (mutable) {
            // @mutable union: DHEADER + EMHEADER(0)=discriminant + EMHEADER(N)=case value.
            try self.writeI("int _rc;\n");
            try self.writeI("size_t _dh;\n");
            try self.writeI("_rc = zidl_cdr_reserve_dheader(_w, &_dh);\n");
            try self.writeI("if (_rc) return _rc;\n");
            if (lcForCppTypeRef(u.discriminant, &.{})) |lc| {
                try self.printI("_rc = zidl_cdr_write_emheader(_w, 0, 0, {d});\n", .{lc});
                try self.writeI("if (_rc) return _rc;\n");
                try self.emitDiscWriteCpp(u.discriminant, "_v->_d()");
            } else {
                try self.writeI("{ size_t _em_d = 0, _es_d = 0;\n");
                self.indent_depth += 1;
                try self.writeI("_rc = zidl_cdr_reserve_emheader(_w, 0, 0, &_em_d);\n");
                try self.writeI("if (_rc) return _rc;\n");
                try self.writeI("_es_d = _w->len;\n");
                try self.emitDiscWriteCpp(u.discriminant, "_v->_d()");
                try self.writeI("zidl_cdr_patch_emheader(_w, _em_d, _es_d); }\n");
                self.indent_depth -= 1;
            }
            try self.writeI("switch (_v->_d()) {\n");
            self.indent_depth += 1;
            var has_default_m = false;
            for (u.cases, 0..) |cas, cas_idx| {
                if (isDefaultUnionCase(cas)) {
                    has_default_m = true;
                    continue;
                }
                const case_member_id: u32 = if (cas.annotations.id) |id| id else @intCast(cas_idx + 1);
                try self.emitUnionCaseLabelLinesCpp(u.discriminant, cas);
                self.indent_depth += 1;
                if (cas.dimensions.len > 0) {
                    const access = try std.fmt.allocPrint(self.alloc, "_v->{s}()", .{cas.name});
                    defer self.alloc.free(access);
                    try self.printI("{{ size_t _em_c{d} = 0, _es_c{d} = 0;\n", .{ cas_idx, cas_idx });
                    self.indent_depth += 1;
                    try self.printI("_rc = zidl_cdr_reserve_emheader(_w, {d}, 0, &_em_c{d});\n", .{ case_member_id, cas_idx });
                    try self.writeI("if (_rc) return _rc;\n");
                    try self.printI("_es_c{d} = _w->len;\n", .{cas_idx});
                    try self.emitWriteArray(cas.type_ref, access, cas.dimensions, 0);
                    try self.printI("zidl_cdr_patch_emheader(_w, _em_c{d}, _es_c{d}); }}\n", .{ cas_idx, cas_idx });
                    self.indent_depth -= 1;
                } else {
                    const access = try self.emitUnionCaseSerializeAccess(cas);
                    defer self.alloc.free(access);
                    if (lcForCppTypeRef(cas.type_ref, cas.dimensions)) |lc| {
                        try self.printI("_rc = zidl_cdr_write_emheader(_w, {d}, 0, {d});\n", .{ case_member_id, lc });
                        try self.writeI("if (_rc) return _rc;\n");
                        try self.emitWriteForTypeRef(cas.type_ref, cas.name, access);
                    } else {
                        try self.printI("{{ size_t _em_c{d} = 0, _es_c{d} = 0;\n", .{ cas_idx, cas_idx });
                        self.indent_depth += 1;
                        try self.printI("_rc = zidl_cdr_reserve_emheader(_w, {d}, 0, &_em_c{d});\n", .{ case_member_id, cas_idx });
                        try self.writeI("if (_rc) return _rc;\n");
                        try self.printI("_es_c{d} = _w->len;\n", .{cas_idx});
                        try self.emitWriteForTypeRef(cas.type_ref, cas.name, access);
                        try self.printI("zidl_cdr_patch_emheader(_w, _em_c{d}, _es_c{d}); }}\n", .{ cas_idx, cas_idx });
                        self.indent_depth -= 1;
                    }
                }
                try self.writeI("break;\n");
                self.indent_depth -= 1;
            }
            if (!has_default_m) {
                try self.writeI("default: break;\n");
            }
            self.indent_depth -= 1;
            try self.writeI("}\n");
            try self.writeI("zidl_cdr_patch_dheader(_w, _dh);\n");
            try self.writeI("return ZIDL_CDR_OK;\n");
            try self.write("}\n\n");
        } else {
            try self.writeI("int _rc;\n");
            if (appendable) {
                try self.writeI("size_t _dh;\n");
                try self.writeI("_rc = zidl_cdr_reserve_dheader_maybe(_w, &_dh);\n");
                try self.writeI("if (_rc) return _rc;\n");
            }
            // Write discriminant via getter _v->_d()
            try self.emitDiscWriteCpp(u.discriminant, "_v->_d()");
            try self.writeI("switch (_v->_d()) {\n");
            self.indent_depth += 1;
            var has_default = false;
            for (u.cases) |cas| {
                if (isDefaultUnionCase(cas)) has_default = true;
                try self.emitUnionCaseLabelLinesCpp(u.discriminant, cas);
                self.indent_depth += 1;
                if (cas.dimensions.len > 0) {
                    const access = try std.fmt.allocPrint(self.alloc, "_v->{s}()", .{cas.name});
                    defer self.alloc.free(access);
                    try self.emitWriteArray(cas.type_ref, access, cas.dimensions, 0);
                } else {
                    const access = try self.emitUnionCaseSerializeAccess(cas);
                    defer self.alloc.free(access);
                    try self.emitWriteForTypeRef(cas.type_ref, cas.name, access);
                }
                try self.writeI("break;\n");
                self.indent_depth -= 1;
            }
            if (!has_default) {
                try self.writeI("default:\n");
                self.indent_depth += 1;
                try self.writeI("break;\n");
                self.indent_depth -= 1;
            }
            self.indent_depth -= 1;
            try self.writeI("}\n");
            if (appendable) {
                try self.writeI("zidl_cdr_patch_dheader_maybe(_w, _dh);\n");
            }
            try self.writeI("return ZIDL_CDR_OK;\n");
            try self.write("}\n\n");
        }

        // ── deserialize ──────────────────────────────────────────────────────

        try self.print("int {s}_deserialize(ZidlCdrReader *_r, {s} *_v) {{\n", .{ c_name, cpp_qname });
        if (mutable) {
            try self.writeI("int _rc;\n");
            try self.writeI("size_t _em_end;\n");
            try self.writeI("_rc = zidl_cdr_read_mutable_dheader(_r, &_em_end);\n");
            try self.writeI("if (_rc) return _rc;\n");
            try self.writeI("while (zidl_cdr_mutable_has_more(_r, _em_end)) {\n");
            self.indent_depth += 1;
            try self.writeI("ZidlEmHeader _emh;\n");
            try self.writeI("_rc = zidl_cdr_read_emheader(_r, &_emh);\n");
            try self.writeI("if (_rc) return _rc;\n");
            try self.writeI("if (_emh.member_id == 0) {\n");
            self.indent_depth += 1;
            try self.emitDiscReadCpp(u.discriminant, "_v");
            self.indent_depth -= 1;
            try self.writeI("} else {\n");
            self.indent_depth += 1;
            try self.writeI("switch (_v->_d()) {\n");
            self.indent_depth += 1;
            var has_default_d = false;
            for (u.cases) |cas| {
                if (isDefaultUnionCase(cas)) {
                    has_default_d = true;
                    continue;
                }
                try self.emitUnionCaseLabelLinesCpp(u.discriminant, cas);
                // A case body scope of its own: a bare `_tmp_*` declaration
                // directly under the case label would make this an ill-formed
                // "jump to case label" once there's more than one case (later
                // labels jump past this one's initialization).
                try self.writeI("{\n");
                self.indent_depth += 1;
                if (cas.dimensions.len > 0) {
                    const cpp_type = try cppTypeStr(self.alloc, self.opts, cas.type_ref);
                    defer self.alloc.free(cpp_type);
                    const dims_str = try cArrayDimsStr(self.alloc, cas.dimensions);
                    defer self.alloc.free(dims_str);
                    const tmp_name = try std.fmt.allocPrint(self.alloc, "_tmp_{s}", .{cas.name});
                    defer self.alloc.free(tmp_name);
                    try self.printI("{s} {s}{s}{{}};\n", .{ cpp_type, tmp_name, dims_str });
                    try self.emitReadArray(cas.type_ref, cas.name, tmp_name, cas.dimensions, 0);
                    try self.printI("_v->{s}({s});\n", .{ cas.name, tmp_name });
                } else {
                    const cpp_type = try cppTypeStr(self.alloc, self.opts, cas.type_ref);
                    defer self.alloc.free(cpp_type);
                    const tmp_name = try std.fmt.allocPrint(self.alloc, "_tmp_{s}", .{cas.name});
                    defer self.alloc.free(tmp_name);
                    try self.printI("{s} {s}{{}};\n", .{ cpp_type, tmp_name });
                    try self.emitReadForTypeRef(cas.type_ref, cas.name, tmp_name);
                    try self.printI("_v->{s}({s});\n", .{ cas.name, tmp_name });
                }
                try self.writeI("break;\n");
                self.indent_depth -= 1;
                try self.writeI("}\n");
            }
            if (!has_default_d) {
                try self.writeI("default:\n");
                self.indent_depth += 1;
                try self.writeI("if (_emh.must_understand) return ZIDL_CDR_INVALID;\n");
                try self.writeI("_rc = zidl_cdr_skip_emheader_payload(_r, &_emh);\n");
                try self.writeI("if (_rc) return _rc;\n");
                try self.writeI("break;\n");
                self.indent_depth -= 1;
            }
            self.indent_depth -= 1;
            try self.writeI("}\n"); // switch
            self.indent_depth -= 1;
            try self.writeI("}\n"); // if member_id==0 else
            self.indent_depth -= 1;
            try self.writeI("}\n"); // while
            try self.writeI("return ZIDL_CDR_OK;\n");
            try self.write("}\n\n");
        } else {
            try self.writeI("int _rc;\n");
            if (appendable) {
                try self.writeI("_rc = zidl_cdr_skip_dheader_if_xcdr2(_r);\n");
                try self.writeI("if (_rc) return _rc;\n");
            }
            // Read discriminant into temp then set via setter
            try self.emitDiscReadCpp(u.discriminant, "_v");
            try self.writeI("switch (_v->_d()) {\n");
            self.indent_depth += 1;
            var has_default = false;
            for (u.cases) |cas| {
                if (isDefaultUnionCase(cas)) has_default = true;
                try self.emitUnionCaseLabelLinesCpp(u.discriminant, cas);
                // See the mutable-union deserialize branch above for why this
                // case body needs its own scope.
                try self.writeI("{\n");
                self.indent_depth += 1;
                if (cas.dimensions.len > 0) {
                    const cpp_type = try cppTypeStr(self.alloc, self.opts, cas.type_ref);
                    defer self.alloc.free(cpp_type);
                    const dims_str = try cArrayDimsStr(self.alloc, cas.dimensions);
                    defer self.alloc.free(dims_str);
                    const tmp_name = try std.fmt.allocPrint(self.alloc, "_tmp_{s}", .{cas.name});
                    defer self.alloc.free(tmp_name);
                    try self.printI("{s} {s}{s}{{}};\n", .{ cpp_type, tmp_name, dims_str });
                    try self.emitReadArray(cas.type_ref, cas.name, tmp_name, cas.dimensions, 0);
                    try self.printI("_v->{s}({s});\n", .{ cas.name, tmp_name });
                } else {
                    const cpp_type = try cppTypeStr(self.alloc, self.opts, cas.type_ref);
                    defer self.alloc.free(cpp_type);
                    const tmp_name = try std.fmt.allocPrint(self.alloc, "_tmp_{s}", .{cas.name});
                    defer self.alloc.free(tmp_name);
                    try self.printI("{s} {s}{{}};\n", .{ cpp_type, tmp_name });
                    try self.emitReadForTypeRef(cas.type_ref, cas.name, tmp_name);
                    try self.printI("_v->{s}({s});\n", .{ cas.name, tmp_name });
                }
                try self.writeI("break;\n");
                self.indent_depth -= 1;
                try self.writeI("}\n");
            }
            if (!has_default) {
                try self.writeI("default:\n");
                self.indent_depth += 1;
                try self.writeI("break;\n");
                self.indent_depth -= 1;
            }
            self.indent_depth -= 1;
            try self.writeI("}\n");
            try self.writeI("return ZIDL_CDR_OK;\n");
            try self.write("}\n\n");
        }

        // ── skip ─────────────────────────────────────────────────────────────

        try self.print("int {s}_skip(ZidlCdrReader *_r) {{\n", .{c_name});
        try self.writeI("int _rc;\n");
        if (mutable) {
            try self.writeI("size_t _end;\n");
            try self.writeI("_rc = zidl_cdr_read_mutable_dheader(_r, &_end);\n");
            try self.writeI("if (_rc) return _rc;\n");
            try self.writeI("return zidl_cdr_seek_to(_r, _end);\n");
        } else {
            if (appendable) {
                try self.writeI("if (_r->xcdr_version == ZIDL_XCDR2) {\n");
                self.indent_depth += 1;
                try self.writeI("uint32_t _size;\n");
                try self.writeI("_rc = zidl_cdr_read_dheader(_r, &_size);\n");
                try self.writeI("if (_rc) return _rc;\n");
                try self.writeI("return zidl_cdr_skip(_r, _size);\n");
                self.indent_depth -= 1;
                try self.writeI("}\n");
            }
            try self.emitDiscReadLocalCpp(u.discriminant, "_d");
            try self.writeI("switch (_d) {\n");
            self.indent_depth += 1;
            var has_default_s = false;
            for (u.cases) |cas| {
                if (isDefaultUnionCase(cas)) has_default_s = true;
                try self.emitUnionCaseLabelLinesCpp(u.discriminant, cas);
                self.indent_depth += 1;
                if (cas.dimensions.len > 0) {
                    try cdr_skip.emitSkipArray(self, cas.type_ref, cas.dimensions, 0);
                } else {
                    try cdr_skip.emitSkipForTypeRef(self, cas.type_ref);
                }
                try self.writeI("break;\n");
                self.indent_depth -= 1;
            }
            if (!has_default_s) {
                try self.writeI("default:\n");
                self.indent_depth += 1;
                try self.writeI("break;\n");
                self.indent_depth -= 1;
            }
            self.indent_depth -= 1;
            try self.writeI("}\n");
            try self.writeI("return ZIDL_CDR_OK;\n");
        }
        try self.write("}\n\n");
    }

    /// Emit CDR write for union discriminant, using the getter expression.
    fn emitDiscWriteCpp(self: *CdrGenerator, disc: ir.TypeRef, getter_expr: []const u8) anyerror!void {
        switch (resolveTypeRef(disc)) {
            .base => |b| {
                const fn_name = baseCWriteFn(b);
                if (std.mem.startsWith(u8, fn_name, "//")) {
                    try self.printI("/* unsupported discriminant type write */\n", .{});
                } else {
                    const c_type = baseToCType(b);
                    try self.printI("_rc = {s}(_w, static_cast<{s}>({s}));\n", .{ fn_name, c_type, getter_expr });
                    try self.writeI("if (_rc) return _rc;\n");
                }
            },
            .named => |td| switch (td) {
                .enum_ => |e| {
                    const suffix = enumCStorageType(e.annotations);
                    const ctype = enumCTypeName(e.annotations);
                    try self.printI("_rc = zidl_cdr_write_{s}(_w, static_cast<{s}>({s}));\n", .{ suffix, ctype, getter_expr });
                    try self.writeI("if (_rc) return _rc;\n");
                },
                else => try self.printI("/* TODO: unsupported discriminant write */\n", .{}),
            },
            else => try self.printI("/* TODO: unsupported discriminant write */\n", .{}),
        }
    }

    /// Emit CDR read for union discriminant, then call `_v->_d(val)` setter.
    fn emitDiscReadCpp(self: *CdrGenerator, disc: ir.TypeRef, v_expr: []const u8) anyerror!void {
        switch (resolveTypeRef(disc)) {
            .base => |b| {
                const fn_name = baseCReadFn(b);
                const c_type = baseToCType(b);
                if (std.mem.startsWith(u8, fn_name, "//")) {
                    try self.printI("/* unsupported discriminant type read */\n", .{});
                } else {
                    try self.printI("{{ {s} _d; _rc = {s}(_r, &_d); if (_rc) return _rc; {s}->_d(static_cast<decltype({s}->_d())>(_d)); }}\n", .{ c_type, fn_name, v_expr, v_expr });
                }
            },
            .named => |td| switch (td) {
                .enum_ => |e| {
                    const suffix = enumCStorageType(e.annotations);
                    const ctype = enumCTypeName(e.annotations);
                    const cpp_enum = try std.fmt.allocPrint(self.alloc, "::{s}", .{e.qualified_name});
                    defer self.alloc.free(cpp_enum);
                    try self.printI("{{ {s} _d_raw; _rc = zidl_cdr_read_{s}(_r, &_d_raw); if (_rc) return _rc; {s}->_d(static_cast<{s}>(_d_raw)); }}\n", .{ ctype, suffix, v_expr, cpp_enum });
                },
                else => try self.printI("/* TODO: unsupported discriminant read */\n", .{}),
            },
            else => try self.printI("/* TODO: unsupported discriminant read */\n", .{}),
        }
    }

    /// Emit local declaration/read for a union discriminant, used by generated skip code.
    fn emitDiscReadLocalCpp(self: *CdrGenerator, disc: ir.TypeRef, lval: []const u8) anyerror!void {
        switch (resolveTypeRef(disc)) {
            .base => |b| {
                const fn_name = baseCReadFn(b);
                const c_type = baseToCType(b);
                if (std.mem.startsWith(u8, fn_name, "//")) {
                    try self.writeI("return ZIDL_CDR_INVALID;\n");
                } else {
                    try self.printI("{s} {s};\n", .{ c_type, lval });
                    try self.printI("_rc = {s}(_r, &{s});\n", .{ fn_name, lval });
                    try self.writeI("if (_rc) return _rc;\n");
                }
            },
            .named => |td| switch (td) {
                .enum_ => |e| {
                    const suffix = enumCStorageType(e.annotations);
                    const ctype = enumCTypeName(e.annotations);
                    const cpp_enum = try std.fmt.allocPrint(self.alloc, "::{s}", .{e.qualified_name});
                    defer self.alloc.free(cpp_enum);
                    try self.printI("{s} {s};\n", .{ cpp_enum, lval });
                    try self.printI("{{ {s} _d_raw; _rc = zidl_cdr_read_{s}(_r, &_d_raw); if (_rc) return _rc; {s} = static_cast<{s}>(_d_raw); }}\n", .{ ctype, suffix, lval, cpp_enum });
                },
                else => try self.writeI("return ZIDL_CDR_INVALID;\n"),
            },
            else => try self.writeI("return ZIDL_CDR_INVALID;\n"),
        }
    }

    /// Emit `case X:` / `default:` label lines for a union case (C++ style).
    fn emitUnionCaseLabelLinesCpp(self: *CdrGenerator, disc: ir.TypeRef, cas: ir.UnionCase) anyerror!void {
        if (cas.labels.len == 0) {
            try self.writeI("default:\n");
            return;
        }
        for (cas.labels) |lbl| {
            switch (lbl) {
                .default => try self.writeI("default:\n"),
                .integer => |v| try self.printI("case {d}:\n", .{v}),
                .boolean => |b| try self.printI("case {s}:\n", .{if (b) "true" else "false"}),
                .enumerator => |name| switch (resolveTypeRef(disc)) {
                    .named => |td| switch (td) {
                        .enum_ => |e| try self.printI("case ::{s}::{s}:\n", .{ e.qualified_name, name }),
                        else => try self.printI("case {s}:\n", .{name}),
                    },
                    else => try self.printI("case {s}:\n", .{name}),
                },
            }
        }
    }

    // ── Union special member functions (non-trivial cases only) ────────────────
    //
    // Declared in Generator.emitUnion (header); defined here (out-of-line, in
    // the .cpp) since they need CdrGenerator's indent-tracking write helpers.
    // `_destroy_active`/`_construct_default`/`_copy_construct_from` are
    // switch-on-discriminant helpers shared by the constructor, destructor,
    // copy constructor, copy assignment operator, and `_d()`. Every case gets
    // its own label, even trivial ones: a case missing its label would fall
    // through into `default:` at runtime whenever the default case happens to
    // be non-trivial, wrongly running that case's placement-new/destructor on
    // a scalar -- the exact hazard (and fix) already found in the C backend's
    // generated union `_free()`.

    const UnionLifecycleOp = enum { destroy, construct_default, copy, move_construct };

    /// Emit the single-case body for one leaf (non-array) lvalue of type
    /// `tr`. `src_access` is only read for `.copy`/`.move_construct`.
    fn emitUnionLifecycleLeaf(
        self: *CdrGenerator,
        op: UnionLifecycleOp,
        tr: ir.TypeRef,
        dst_access: []const u8,
        src_access: []const u8,
    ) anyerror!void {
        const non_trivial = typeRefIsCppNonTrivial(tr);
        switch (op) {
            .destroy => {
                if (!non_trivial) return;
                const cpp_type = try cppTypeStr(self.alloc, self.opts, tr);
                defer self.alloc.free(cpp_type);
                try self.printI("{{ using _LT = {s}; ({s}).~_LT(); }}\n", .{ cpp_type, dst_access });
            },
            .construct_default => {
                if (!non_trivial) return;
                const cpp_type = try cppTypeStr(self.alloc, self.opts, tr);
                defer self.alloc.free(cpp_type);
                try self.printI("new (&({s})) {s}();\n", .{ dst_access, cpp_type });
            },
            .copy => {
                if (non_trivial) {
                    const cpp_type = try cppTypeStr(self.alloc, self.opts, tr);
                    defer self.alloc.free(cpp_type);
                    try self.printI("new (&({s})) {s}({s});\n", .{ dst_access, cpp_type, src_access });
                } else {
                    try self.printI("{s} = {s};\n", .{ dst_access, src_access });
                }
            },
            .move_construct => {
                if (non_trivial) {
                    // std::string/vector/map's move constructor is noexcept
                    // -- unlike .copy, this can't throw and leave the
                    // destination's discriminant pointing at unconstructed
                    // storage. Used by operator= (see
                    // emitUnionMoveConstructFrom) specifically because its
                    // copy path already has a live temporary to move from
                    // once the (throwable) copy into that temporary
                    // succeeded, so nothing past this point can fail.
                    const cpp_type = try cppTypeStr(self.alloc, self.opts, tr);
                    defer self.alloc.free(cpp_type);
                    try self.printI("new (&({s})) {s}(std::move({s}));\n", .{ dst_access, cpp_type, src_access });
                } else {
                    try self.printI("{s} = {s};\n", .{ dst_access, src_access });
                }
            },
        }
    }

    /// Nested-loop analog of `emitUnionLifecycleLeaf` for an array-typed case
    /// (`cas.dimensions.len > 0`), recursing one loop per dimension.
    fn emitUnionArrayLifecycleOp(
        self: *CdrGenerator,
        op: UnionLifecycleOp,
        elem_tr: ir.TypeRef,
        dst_access: []const u8,
        src_access: []const u8,
        dims: []const u64,
        dim_idx: usize,
    ) anyerror!void {
        const var_name = try std.fmt.allocPrint(self.alloc, "_li{d}", .{dim_idx});
        defer self.alloc.free(var_name);
        try self.printI("{{ uint32_t {s}; for ({s} = 0; {s} < {d}u; {s}++) {{\n", .{
            var_name, var_name, var_name, dims[0], var_name,
        });
        self.indent_depth += 1;
        const dst_elem = try std.fmt.allocPrint(self.alloc, "{s}[{s}]", .{ dst_access, var_name });
        defer self.alloc.free(dst_elem);
        const src_elem = try std.fmt.allocPrint(self.alloc, "{s}[{s}]", .{ src_access, var_name });
        defer self.alloc.free(src_elem);
        if (dims.len > 1) {
            try self.emitUnionArrayLifecycleOp(op, elem_tr, dst_elem, src_elem, dims[1..], dim_idx + 1);
        } else {
            try self.emitUnionLifecycleLeaf(op, elem_tr, dst_elem, src_elem);
        }
        self.indent_depth -= 1;
        try self.writeI("}\n");
        try self.writeI("}\n");
    }

    /// Emit one case's body inside a `_destroy_active`/`_construct_default`
    /// switch (discriminant already selects `_disc`'s own case; no source
    /// value involved).
    fn emitUnionCaseSelfOp(self: *CdrGenerator, op: UnionLifecycleOp, cas: ir.UnionCase) anyerror!void {
        if (!typeRefIsCppNonTrivial(cas.type_ref)) return;
        const access = try std.fmt.allocPrint(self.alloc, "_u._{s}", .{cas.name});
        defer self.alloc.free(access);
        if (cas.dimensions.len > 0) {
            try self.emitUnionArrayLifecycleOp(op, cas.type_ref, access, access, cas.dimensions, 0);
        } else {
            try self.emitUnionLifecycleLeaf(op, cas.type_ref, access, access);
        }
    }

    fn emitUnionDestroyActive(self: *CdrGenerator, u: *const ir.Union, cpp_qname: []const u8) anyerror!void {
        try self.print("void {s}::_destroy_active() noexcept {{\n", .{cpp_qname});
        try self.writeI("switch (_disc) {\n");
        self.indent_depth += 1;
        for (u.cases) |cas| {
            try self.emitUnionCaseLabelLinesCpp(u.discriminant, cas);
            self.indent_depth += 1;
            try self.emitUnionCaseSelfOp(.destroy, cas);
            try self.writeI("break;\n");
            self.indent_depth -= 1;
        }
        self.indent_depth -= 1;
        try self.writeI("}\n");
        try self.write("}\n\n");
    }

    fn emitUnionConstructDefault(self: *CdrGenerator, u: *const ir.Union, cpp_qname: []const u8) anyerror!void {
        try self.print("void {s}::_construct_default() {{\n", .{cpp_qname});
        try self.writeI("switch (_disc) {\n");
        self.indent_depth += 1;
        for (u.cases) |cas| {
            try self.emitUnionCaseLabelLinesCpp(u.discriminant, cas);
            self.indent_depth += 1;
            try self.emitUnionCaseSelfOp(.construct_default, cas);
            try self.writeI("break;\n");
            self.indent_depth -= 1;
        }
        self.indent_depth -= 1;
        try self.writeI("}\n");
        try self.write("}\n\n");
    }

    fn emitUnionCopyConstructFrom(self: *CdrGenerator, u: *const ir.Union, cpp_qname: []const u8) anyerror!void {
        try self.print("void {s}::_copy_construct_from(const {s} &other) {{\n", .{ cpp_qname, cpp_qname });
        try self.writeI("switch (other._disc) {\n");
        self.indent_depth += 1;
        for (u.cases) |cas| {
            try self.emitUnionCaseLabelLinesCpp(u.discriminant, cas);
            self.indent_depth += 1;
            const dst = try std.fmt.allocPrint(self.alloc, "_u._{s}", .{cas.name});
            defer self.alloc.free(dst);
            const src = try std.fmt.allocPrint(self.alloc, "other._u._{s}", .{cas.name});
            defer self.alloc.free(src);
            if (cas.dimensions.len > 0) {
                if (typeRefIsCppNonTrivial(cas.type_ref)) {
                    try self.emitUnionArrayLifecycleOp(.copy, cas.type_ref, dst, src, cas.dimensions, 0);
                } else {
                    try self.printI("std::memcpy({s}, {s}, sizeof({s}));\n", .{ dst, src, dst });
                }
            } else {
                try self.emitUnionLifecycleLeaf(.copy, cas.type_ref, dst, src);
            }
            try self.writeI("break;\n");
            self.indent_depth -= 1;
        }
        self.indent_depth -= 1;
        try self.writeI("}\n");
        try self.write("}\n\n");
    }

    /// Move-construct analog of `emitUnionCopyConstructFrom`, using
    /// `.move_construct` instead of `.copy` -- see `operator=`'s use of this
    /// in `emitUnionLifecycleFns` for why: unlike a copy, this can't throw.
    fn emitUnionMoveConstructFrom(self: *CdrGenerator, u: *const ir.Union, cpp_qname: []const u8) anyerror!void {
        try self.print("void {s}::_move_construct_from({s} &other) {{\n", .{ cpp_qname, cpp_qname });
        try self.writeI("switch (other._disc) {\n");
        self.indent_depth += 1;
        for (u.cases) |cas| {
            try self.emitUnionCaseLabelLinesCpp(u.discriminant, cas);
            self.indent_depth += 1;
            const dst = try std.fmt.allocPrint(self.alloc, "_u._{s}", .{cas.name});
            defer self.alloc.free(dst);
            const src = try std.fmt.allocPrint(self.alloc, "other._u._{s}", .{cas.name});
            defer self.alloc.free(src);
            if (cas.dimensions.len > 0) {
                if (typeRefIsCppNonTrivial(cas.type_ref)) {
                    try self.emitUnionArrayLifecycleOp(.move_construct, cas.type_ref, dst, src, cas.dimensions, 0);
                } else {
                    try self.printI("std::memcpy({s}, {s}, sizeof({s}));\n", .{ dst, src, dst });
                }
            } else {
                try self.emitUnionLifecycleLeaf(.move_construct, cas.type_ref, dst, src);
            }
            try self.writeI("break;\n");
            self.indent_depth -= 1;
        }
        self.indent_depth -= 1;
        try self.writeI("}\n");
        try self.write("}\n\n");
    }

    /// Emit the special member functions and `_d()` declared (for a
    /// lifetime-needing union) in Generator.emitUnion.
    fn emitUnionLifecycleFns(self: *CdrGenerator, u: *const ir.Union) anyerror!void {
        const cpp_qname = try std.fmt.allocPrint(self.alloc, "::{s}", .{u.qualified_name});
        defer self.alloc.free(cpp_qname);
        const disc_cpp = try cppTypeStr(self.alloc, self.opts, u.discriminant);
        defer self.alloc.free(disc_cpp);

        try self.emitUnionDestroyActive(u, cpp_qname);
        try self.emitUnionConstructDefault(u, cpp_qname);
        try self.emitUnionCopyConstructFrom(u, cpp_qname);
        try self.emitUnionMoveConstructFrom(u, cpp_qname);

        try self.print("{s}::{s}() {{\n", .{ cpp_qname, u.name });
        self.indent_depth += 1;
        try self.writeI("_construct_default();\n");
        self.indent_depth -= 1;
        try self.write("}\n\n");

        try self.print("{s}::{s}(const {s} &other) : _disc(other._disc) {{\n", .{ cpp_qname, u.name, cpp_qname });
        self.indent_depth += 1;
        try self.writeI("_copy_construct_from(other);\n");
        self.indent_depth -= 1;
        try self.write("}\n\n");

        // Real (not compiler-implicit) move ctor/assign: every case's own
        // move is noexcept (std::string/vector/map's move ctors are
        // noexcept by the standard; a nested generated union's move is
        // noexcept because every such union gets this exact same pair; a
        // struct case's compiler-implicit move is noexcept because its
        // members can only be one of those). So this is never a
        // throwing-copy fallback the way std::move(other) would be for a
        // type with no move ctor of its own.
        try self.print("{s}::{s}({s} &&other) noexcept : _disc(other._disc) {{\n", .{ cpp_qname, u.name, cpp_qname });
        self.indent_depth += 1;
        try self.writeI("_move_construct_from(other);\n");
        self.indent_depth -= 1;
        try self.write("}\n\n");

        try self.print("{s} &{s}::operator=({s} &&other) noexcept {{\n", .{ cpp_qname, cpp_qname, cpp_qname });
        self.indent_depth += 1;
        try self.writeI("if (this != &other) {\n");
        self.indent_depth += 1;
        try self.writeI("_destroy_active();\n");
        try self.writeI("_disc = other._disc;\n");
        try self.writeI("_move_construct_from(other);\n");
        self.indent_depth -= 1;
        try self.writeI("}\n");
        try self.writeI("return *this;\n");
        self.indent_depth -= 1;
        try self.write("}\n\n");

        try self.print("{s} &{s}::operator=(const {s} &other) {{\n", .{ cpp_qname, cpp_qname, cpp_qname });
        self.indent_depth += 1;
        try self.writeI("if (this != &other) {\n");
        self.indent_depth += 1;
        // Strong exception guarantee: copy into a temporary first (the only
        // step that can throw -- e.g. std::string/vector/map's copy ctor
        // under bad_alloc). If that throws, *this is untouched. Everything
        // from here on is noexcept (destroy, plain int assignment, move
        // construction), so *this can never be left with _disc naming a case
        // whose storage was never actually constructed.
        try self.printI("{s} tmp(other);\n", .{cpp_qname});
        try self.writeI("_destroy_active();\n");
        try self.writeI("_disc = tmp._disc;\n");
        try self.writeI("_move_construct_from(tmp);\n");
        self.indent_depth -= 1;
        try self.writeI("}\n");
        try self.writeI("return *this;\n");
        self.indent_depth -= 1;
        try self.write("}\n\n");

        try self.print("{s}::~{s}() {{\n", .{ cpp_qname, u.name });
        self.indent_depth += 1;
        try self.writeI("_destroy_active();\n");
        self.indent_depth -= 1;
        try self.write("}\n\n");

        try self.print("void {s}::_d({s} v) {{\n", .{ cpp_qname, disc_cpp });
        self.indent_depth += 1;
        try self.writeI("if (v != _disc) {\n");
        self.indent_depth += 1;
        try self.writeI("_destroy_active();\n");
        try self.writeI("_disc = v;\n");
        try self.writeI("_construct_default();\n");
        self.indent_depth -= 1;
        try self.writeI("}\n");
        self.indent_depth -= 1;
        try self.write("}\n\n");
    }

    // ── Write helpers ─────────────────────────────────────────────────────────

    fn emitWriteForTypeRef(
        self: *CdrGenerator,
        tr: ir.TypeRef,
        field_name: []const u8,
        access: []const u8,
    ) anyerror!void {
        switch (tr) {
            .base => |b| {
                const fn_name = baseCWriteFn(b);
                if (std.mem.startsWith(u8, fn_name, "//")) {
                    try self.printI("/* unsupported type for field {s} */\n", .{field_name});
                } else {
                    try self.printI("_rc = {s}(_w, {s});\n", .{ fn_name, access });
                    try self.writeI("if (_rc) return _rc;\n");
                }
            },
            .string => |bound| {
                _ = bound;
                try self.printI("_rc = zidl_cdr_write_string(_w, {s}.c_str(), (uint32_t){s}.size());\n", .{ access, access });
                try self.writeI("if (_rc) return _rc;\n");
            },
            .wstring => {
                // std::wstring → CDR: write count+1 as u32, then each wchar_t cast to u16, then NUL u16.
                try self.printI("{{ uint32_t _wl = (uint32_t){s}.size();\n", .{access});
                self.indent_depth += 1;
                try self.writeI("_rc = zidl_cdr_write_u32(_w, _wl + 1u); if (_rc) return _rc;\n");
                try self.writeI("for (uint32_t _wi = 0; _wi < _wl; _wi++) {\n");
                self.indent_depth += 1;
                try self.printI("_rc = zidl_cdr_write_u16(_w, (uint16_t){s}[_wi]); if (_rc) return _rc;\n", .{access});
                self.indent_depth -= 1;
                try self.writeI("}\n");
                try self.writeI("_rc = zidl_cdr_write_u16(_w, 0u); if (_rc) return _rc;\n");
                self.indent_depth -= 1;
                try self.writeI("}\n");
            },
            .sequence => |seq| {
                try self.printI("_rc = zidl_cdr_write_u32(_w, (uint32_t){s}.size());\n", .{access});
                try self.writeI("if (_rc) return _rc;\n");
                try self.printI("{{ uint32_t _si; for (_si = 0; _si < (uint32_t){s}.size(); _si++) {{\n", .{access});
                self.indent_depth += 1;
                const elem_access = try std.fmt.allocPrint(self.alloc, "{s}[_si]", .{access});
                defer self.alloc.free(elem_access);
                try self.emitWriteForTypeRef(seq.element.*, field_name, elem_access);
                self.indent_depth -= 1;
                try self.writeI("}\n");
                try self.writeI("}\n");
            },
            .named => |td| try self.emitWriteNamed(td, field_name, access),
            .fixed_pt => |fp| {
                try self.printI("_rc = zidl_cdr_write_fixed(_w, {d}, {d}, {s});\n", .{ fp.digits, fp.scale, access });
                try self.writeI("if (_rc) return _rc;\n");
            },
            .map => |m| {
                try self.printI("{{ uint32_t _mc = (uint32_t){s}.size();\n", .{access});
                self.indent_depth += 1;
                try self.writeI("_rc = zidl_cdr_write_u32(_w, _mc); if (_rc) return _rc;\n");
                try self.printI("for (auto const& _me : {s}) {{\n", .{access});
                self.indent_depth += 1;
                try self.emitWriteForTypeRef(m.key.*, field_name, "_me.first");
                try self.emitWriteForTypeRef(m.value.*, field_name, "_me.second");
                self.indent_depth -= 1;
                try self.writeI("}\n");
                self.indent_depth -= 1;
                try self.writeI("}\n");
            },
        }
    }

    fn emitWriteNamed(
        self: *CdrGenerator,
        td: ir.TypeDecl,
        field_name: []const u8,
        access: []const u8,
    ) anyerror!void {
        switch (td) {
            .struct_, .exception => {
                const qname = ir.typeDeclQualifiedName(td);
                const c_type = try self.prefixedCName(qname);
                defer self.alloc.free(c_type);
                try self.printI("_rc = {s}_serialize(_w, &{s});\n", .{ c_type, access });
                try self.writeI("if (_rc) return _rc;\n");
            },
            .enum_ => |e| {
                const suffix = enumCStorageType(e.annotations);
                const ctype = enumCTypeName(e.annotations);
                try self.printI("_rc = zidl_cdr_write_{s}(_w, static_cast<{s}>({s}));\n", .{ suffix, ctype, access });
                try self.writeI("if (_rc) return _rc;\n");
            },
            .bitmask => |bm| {
                const suffix = enumCStorageType(bm.annotations);
                try self.printI("_rc = zidl_cdr_write_{s}(_w, {s});\n", .{ suffix, access });
                try self.writeI("if (_rc) return _rc;\n");
            },
            .typedef => |t| {
                if (t.dimensions.len > 0) {
                    try self.emitWriteArray(t.type_ref, access, t.dimensions, 0);
                } else {
                    try self.emitWriteForTypeRef(t.type_ref, field_name, access);
                }
            },
            .union_ => {
                const qname = ir.typeDeclQualifiedName(td);
                const c_type = try self.prefixedCName(qname);
                defer self.alloc.free(c_type);
                try self.printI("_rc = {s}_serialize(_w, &{s});\n", .{ c_type, access });
                try self.writeI("if (_rc) return _rc;\n");
            },
            .bitset => |bs| {
                const ctype = bitsetCdrStorageType(bs);
                const fn_sfx = bitsetCdrFnSuffix(bs);
                try self.printI("{{ {s} _bsv = 0;\n", .{ctype});
                self.indent_depth += 1;
                var bit_pos: u32 = 0;
                for (bs.fields) |field| {
                    if (field.names.len == 0) {
                        bit_pos += field.bits;
                        continue;
                    }
                    const mask: u64 = if (field.bits >= 64) std.math.maxInt(u64) else (@as(u64, 1) << @intCast(field.bits)) - 1;
                    for (field.names) |fname| {
                        if (bit_pos == 0) {
                            try self.printI("_bsv |= ({s}){s}.{s} & 0x{X}u;\n", .{ ctype, access, fname, mask });
                        } else {
                            try self.printI("_bsv |= (({s}){s}.{s} & 0x{X}u) << {d};\n", .{ ctype, access, fname, mask, bit_pos });
                        }
                    }
                    bit_pos += field.bits;
                }
                try self.printI("_rc = zidl_cdr_write_{s}(_w, _bsv);\n", .{fn_sfx});
                try self.writeI("if (_rc) return _rc;\n");
                self.indent_depth -= 1;
                try self.writeI("}\n");
            },
            else => {
                try self.printI("/* TODO: serialize named {s} */\n", .{field_name});
            },
        }
    }

    fn emitWriteArray(
        self: *CdrGenerator,
        elem_tr: ir.TypeRef,
        access: []const u8,
        dims: []const u64,
        dim_idx: usize,
    ) anyerror!void {
        const var_name = try std.fmt.allocPrint(self.alloc, "_ai{d}", .{dim_idx});
        defer self.alloc.free(var_name);
        try self.printI("{{ uint32_t {s}; for ({s} = 0; {s} < {d}u; {s}++) {{\n", .{
            var_name, var_name, var_name, dims[0], var_name,
        });
        self.indent_depth += 1;
        const elem_access = try std.fmt.allocPrint(self.alloc, "{s}[{s}]", .{ access, var_name });
        defer self.alloc.free(elem_access);
        if (dims.len > 1) {
            try self.emitWriteArray(elem_tr, elem_access, dims[1..], dim_idx + 1);
        } else {
            try self.emitWriteForTypeRef(elem_tr, "_elem", elem_access);
        }
        self.indent_depth -= 1;
        try self.writeI("}\n");
        try self.writeI("}\n");
    }

    fn emitReadMember(self: *CdrGenerator, m: ir.StructMember) anyerror!void {
        if (m.annotations.is_optional) {
            const pvar = try std.fmt.allocPrint(self.alloc, "_ip_{s}", .{m.name});
            defer self.alloc.free(pvar);
            try self.printI("{{ int8_t {s};\n", .{pvar});
            self.indent_depth += 1;
            try self.printI("_rc = zidl_cdr_read_bool(_r, &{s});\n", .{pvar});
            try self.writeI("if (_rc) return _rc;\n");
            try self.printI("if ({s}) {{\n", .{pvar});
            self.indent_depth += 1;
            try self.printI("_v->{s}.emplace();\n", .{m.name});
            const deref = try std.fmt.allocPrint(self.alloc, "(*_v->{s})", .{m.name});
            defer self.alloc.free(deref);
            if (m.dimensions.len > 0) {
                try self.emitReadArray(m.type_ref, m.name, deref, m.dimensions, 0);
            } else {
                try self.emitReadForTypeRef(m.type_ref, m.name, deref);
            }
            self.indent_depth -= 1;
            try self.writeI("} else {\n");
            self.indent_depth += 1;
            try self.printI("_v->{s} = std::nullopt;\n", .{m.name});
            self.indent_depth -= 1;
            try self.writeI("}\n");
            self.indent_depth -= 1;
            try self.writeI("}\n");
            return;
        }

        const lval = try std.fmt.allocPrint(self.alloc, "_v->{s}", .{m.name});
        defer self.alloc.free(lval);
        if (m.dimensions.len > 0) {
            try self.emitReadArray(m.type_ref, m.name, lval, m.dimensions, 0);
        } else {
            try self.emitReadForTypeRef(m.type_ref, m.name, lval);
        }
    }

    fn emitReadPresentMember(self: *CdrGenerator, m: ir.StructMember) anyerror!void {
        if (m.annotations.is_optional) {
            try self.printI("_v->{s}.emplace();\n", .{m.name});
            const deref = try std.fmt.allocPrint(self.alloc, "(*_v->{s})", .{m.name});
            defer self.alloc.free(deref);
            if (m.dimensions.len > 0) {
                try self.emitReadArray(m.type_ref, m.name, deref, m.dimensions, 0);
            } else {
                try self.emitReadForTypeRef(m.type_ref, m.name, deref);
            }
            return;
        }

        const lval = try std.fmt.allocPrint(self.alloc, "_v->{s}", .{m.name});
        defer self.alloc.free(lval);
        if (m.dimensions.len > 0) {
            try self.emitReadArray(m.type_ref, m.name, lval, m.dimensions, 0);
        } else {
            try self.emitReadForTypeRef(m.type_ref, m.name, lval);
        }
    }

    // ── Read helpers ──────────────────────────────────────────────────────────

    fn emitReadForTypeRef(
        self: *CdrGenerator,
        tr: ir.TypeRef,
        field_name: []const u8,
        lval: []const u8,
    ) anyerror!void {
        switch (tr) {
            .base => |b| {
                const fn_name = baseCReadFn(b);
                if (std.mem.startsWith(u8, fn_name, "//")) {
                    try self.printI("/* unsupported type for field {s} */\n", .{field_name});
                } else {
                    try self.printI("_rc = {s}(_r, &{s});\n", .{ fn_name, lval });
                    try self.writeI("if (_rc) return _rc;\n");
                }
            },
            .string => |bound| {
                // All strings in C++ are std::string; use zerocopy read + assign.
                try self.writeI("{ const char *_sp; uint32_t _sl;\n");
                self.indent_depth += 1;
                try self.writeI("_rc = zidl_cdr_read_string_zerocopy(_r, &_sp, &_sl);\n");
                try self.writeI("if (_rc) return _rc;\n");
                if (bound) |n| {
                    try self.printI("if (_sl > {d}u) return ZIDL_CDR_INVALID;\n", .{n});
                }
                try self.printI("{s}.assign(_sp, _sl);\n", .{lval});
                self.indent_depth -= 1;
                try self.writeI("}\n");
            },
            .wstring => |bound| {
                // CDR → std::wstring: read count, then u16 chars cast to wchar_t.
                try self.writeI("{ uint32_t _wc;\n");
                self.indent_depth += 1;
                try self.writeI("_rc = zidl_cdr_read_u32(_r, &_wc); if (_rc) return _rc;\n");
                try self.writeI("if (_wc == 0) return ZIDL_CDR_INVALID;\n");
                try self.writeI("uint32_t _wl = _wc - 1u;\n");
                if (bound) |n| {
                    try self.printI("if (_wl > {d}u) return ZIDL_CDR_INVALID;\n", .{n});
                }
                try self.printI("{s}.resize(_wl);\n", .{lval});
                try self.writeI("for (uint32_t _wi = 0; _wi < _wl; _wi++) {\n");
                self.indent_depth += 1;
                try self.writeI("uint16_t _wv;\n");
                try self.printI("_rc = zidl_cdr_read_u16(_r, &_wv); if (_rc) {{ {s}.clear(); return _rc; }}\n", .{lval});
                try self.printI("{s}[_wi] = (wchar_t)_wv;\n", .{lval});
                self.indent_depth -= 1;
                try self.writeI("}\n");
                try self.writeI("uint16_t _nul;\n");
                try self.printI("_rc = zidl_cdr_read_u16(_r, &_nul); if (_rc) {{ {s}.clear(); return _rc; }}\n", .{lval});
                self.indent_depth -= 1;
                try self.writeI("}\n");
            },
            .sequence => |seq| {
                try self.writeI("{ uint32_t _sl;\n");
                self.indent_depth += 1;
                try self.writeI("_rc = zidl_cdr_read_u32(_r, &_sl);\n");
                try self.writeI("if (_rc) return _rc;\n");
                try self.printI("{s}.resize(_sl);\n", .{lval});
                try self.writeI("{ uint32_t _si; for (_si = 0; _si < _sl; _si++) {\n");
                self.indent_depth += 1;
                const elem_lval = try std.fmt.allocPrint(self.alloc, "{s}[_si]", .{lval});
                defer self.alloc.free(elem_lval);
                try self.emitReadForTypeRef(seq.element.*, field_name, elem_lval);
                self.indent_depth -= 1;
                try self.writeI("}\n");
                try self.writeI("}\n");
                self.indent_depth -= 1;
                try self.writeI("}\n");
            },
            .named => |td| try self.emitReadNamed(td, field_name, lval),
            .fixed_pt => |fp| {
                try self.printI("_rc = zidl_cdr_read_fixed(_r, {d}, {d}, &{s});\n", .{ fp.digits, fp.scale, lval });
                try self.writeI("if (_rc) return _rc;\n");
            },
            .map => |m| {
                const k_type = try self.cppTypeForLocal(m.key.*);
                defer self.alloc.free(k_type);
                const v_type = try self.cppTypeForLocal(m.value.*);
                defer self.alloc.free(v_type);
                try self.writeI("{ uint32_t _mc;\n");
                self.indent_depth += 1;
                try self.writeI("_rc = zidl_cdr_read_u32(_r, &_mc); if (_rc) return _rc;\n");
                try self.writeI("for (uint32_t _mi = 0; _mi < _mc; _mi++) {\n");
                self.indent_depth += 1;
                try self.printI("{s} _mk{{}};\n", .{k_type});
                try self.printI("{s} _mv{{}};\n", .{v_type});
                try self.emitReadForTypeRef(m.key.*, field_name, "_mk");
                try self.emitReadForTypeRef(m.value.*, field_name, "_mv");
                try self.printI("{s}.emplace(std::move(_mk), std::move(_mv));\n", .{lval});
                self.indent_depth -= 1;
                try self.writeI("}\n");
                self.indent_depth -= 1;
                try self.writeI("}\n");
            },
        }
    }

    fn emitReadNamed(
        self: *CdrGenerator,
        td: ir.TypeDecl,
        field_name: []const u8,
        lval: []const u8,
    ) anyerror!void {
        switch (td) {
            .struct_, .exception => {
                const qname = ir.typeDeclQualifiedName(td);
                const c_type = try self.prefixedCName(qname);
                defer self.alloc.free(c_type);
                try self.printI("_rc = {s}_deserialize(_r, &{s});\n", .{ c_type, lval });
                try self.writeI("if (_rc) return _rc;\n");
            },
            .enum_ => |e| {
                const suffix = enumCStorageType(e.annotations);
                const ctype = enumCTypeName(e.annotations);
                const cpp_enum = try std.fmt.allocPrint(self.alloc, "::{s}", .{e.qualified_name});
                defer self.alloc.free(cpp_enum);
                try self.printI(
                    "{{ {s} _ev; _rc = zidl_cdr_read_{s}(_r, &_ev); if (_rc) return _rc; {s} = static_cast<{s}>(_ev); }}\n",
                    .{ ctype, suffix, lval, cpp_enum },
                );
            },
            .bitmask => |bm| {
                const suffix = enumCStorageType(bm.annotations);
                try self.printI("_rc = zidl_cdr_read_{s}(_r, &{s});\n", .{ suffix, lval });
                try self.writeI("if (_rc) return _rc;\n");
            },
            .typedef => |t| {
                if (t.dimensions.len > 0) {
                    try self.emitReadArray(t.type_ref, field_name, lval, t.dimensions, 0);
                } else {
                    try self.emitReadForTypeRef(t.type_ref, field_name, lval);
                }
            },
            .union_ => {
                const qname = ir.typeDeclQualifiedName(td);
                const c_type = try self.prefixedCName(qname);
                defer self.alloc.free(c_type);
                try self.printI("_rc = {s}_deserialize(_r, &{s});\n", .{ c_type, lval });
                try self.writeI("if (_rc) return _rc;\n");
            },
            .bitset => |bs| {
                const ctype = bitsetCdrStorageType(bs);
                const fn_sfx = bitsetCdrFnSuffix(bs);
                try self.printI("{{ {s} _bsv;\n", .{ctype});
                self.indent_depth += 1;
                try self.printI("_rc = zidl_cdr_read_{s}(_r, &_bsv);\n", .{fn_sfx});
                try self.writeI("if (_rc) return _rc;\n");
                var bit_pos: u32 = 0;
                for (bs.fields) |field| {
                    if (field.names.len == 0) {
                        bit_pos += field.bits;
                        continue;
                    }
                    const mask: u64 = if (field.bits >= 64) std.math.maxInt(u64) else (@as(u64, 1) << @intCast(field.bits)) - 1;
                    for (field.names) |fname| {
                        if (bit_pos == 0) {
                            try self.printI("{s}.{s} = _bsv & 0x{X}u;\n", .{ lval, fname, mask });
                        } else {
                            try self.printI("{s}.{s} = (_bsv >> {d}) & 0x{X}u;\n", .{ lval, fname, bit_pos, mask });
                        }
                    }
                    bit_pos += field.bits;
                }
                self.indent_depth -= 1;
                try self.writeI("}\n");
            },
            else => {
                try self.printI("/* TODO: deserialize named {s} */\n", .{field_name});
            },
        }
    }

    fn emitReadArray(
        self: *CdrGenerator,
        elem_tr: ir.TypeRef,
        field_name: []const u8,
        lval: []const u8,
        dims: []const u64,
        dim_idx: usize,
    ) anyerror!void {
        const var_name = try std.fmt.allocPrint(self.alloc, "_ai{d}", .{dim_idx});
        defer self.alloc.free(var_name);
        try self.printI("{{ uint32_t {s}; for ({s} = 0; {s} < {d}u; {s}++) {{\n", .{
            var_name, var_name, var_name, dims[0], var_name,
        });
        self.indent_depth += 1;
        const elem_lval = try std.fmt.allocPrint(self.alloc, "{s}[{s}]", .{ lval, var_name });
        defer self.alloc.free(elem_lval);
        if (dims.len > 1) {
            try self.emitReadArray(elem_tr, field_name, elem_lval, dims[1..], dim_idx + 1);
        } else {
            try self.emitReadForTypeRef(elem_tr, field_name, elem_lval);
        }
        self.indent_depth -= 1;
        try self.writeI("}\n");
        try self.writeI("}\n");
    }
};

// ── Concrete DDS impl generation (--cpp-generate-impl) ───────────────────────

/// Generate `<stem>_impl.hpp` and `<stem>_impl.cpp` with concrete Impl classes
/// (wrapping typed C handles) and listener bridge classes (B3).
pub fn generateConcreteImpl(
    alloc: std.mem.Allocator,
    spec: *const ir.Spec,
    opts: interface.Options,
    hdr_out: *std.ArrayList(u8),
    src_out: *std.ArrayList(u8),
) !void {
    var gen = ConcreteImplGenerator{ .alloc = alloc, .opts = opts, .hdr = hdr_out, .src = src_out };
    defer gen.entity_base_ifaces.deinit(alloc);
    defer gen.wrapped_entities.deinit(alloc);
    defer interface.deinitBaseImplementors(alloc, &gen.base_implementors);
    defer interface.deinitBaseImplementors(alloc, &gen.families);
    try gen.emit(spec);
}

const ConcreteImplGenerator = struct {
    alloc: std.mem.Allocator,
    opts: interface.Options,
    hdr: *std.ArrayList(u8),
    src: *std.ArrayList(u8),
    entity_base_ifaces: std.StringHashMapUnmanaged(void) = .{},
    /// Qualified names of entity interfaces actually wrapped via _getOrCreate
    /// somewhere in the spec (op return, attribute, sequence element,
    /// listener parameter). Populated by a throwaway pre-scan pass in
    /// `emit()` before any real output is written — see its doc comment.
    /// Entity interfaces NOT in this set skip _getOrCreate's declaration and
    /// definition entirely.
    wrapped_entities: std.StringHashMapUnmanaged(void) = .{},
    /// Maps a base interface's qualified name to every OTHER concrete
    /// (sibling) interface that also implements it, transitively through its
    /// own base chain — see `interface.collectBaseImplementors`'s doc
    /// comment. Used by `emitAdaptedParams`'s `entity_in` case to emit a
    /// cascading `dynamic_cast` when a parameter's declared interface has
    /// more than one possible concrete runtime implementation (e.g.
    /// `TopicDescription`, implemented separately by `TopicDescriptionImpl`,
    /// `ContentFilteredTopicImpl`, and `MultiTopicImpl`).
    base_implementors: std.StringHashMapUnmanaged(std.ArrayListUnmanaged(*const ir.Interface)) = .{},
    /// Groups every non-callback interface under its
    /// `interface.sharedCAbiBoxFamilyRoot`'s qualified name — see that
    /// function's doc comment. A family with more than one member shares one
    /// `_getOrCreate` identity cache (owned by the family's root class)
    /// instead of each member keeping its own independent one; see
    /// `familyOf`, `emitEntityImplDecl`, and `emitEntityImplMethods`.
    families: std.StringHashMapUnmanaged(std.ArrayListUnmanaged(*const ir.Interface)) = .{},

    /// The `Family` a given interface belongs to: its shared-box root and
    /// how many members are in that root's group. `size <= 1` means "no
    /// sharing needed here" — `iface` keeps its own independent cache
    /// exactly as it always has.
    const Family = struct {
        root: *const ir.Interface,
        size: usize,
    };

    fn familyOf(self: *ConcreteImplGenerator, iface: *const ir.Interface) Family {
        const root = interface.sharedCAbiBoxFamilyRoot(iface);
        const size = if (self.families.get(root.qualified_name)) |members| members.items.len else 1;
        return .{ .root = root, .size = size };
    }

    fn hdrWrite(self: *ConcreteImplGenerator, s: []const u8) !void {
        try self.hdr.appendSlice(self.alloc, s);
    }
    fn hdrPrint(self: *ConcreteImplGenerator, comptime fmt: []const u8, args: anytype) !void {
        const s = try std.fmt.allocPrint(self.alloc, fmt, args);
        defer self.alloc.free(s);
        try self.hdr.appendSlice(self.alloc, s);
    }
    fn srcWrite(self: *ConcreteImplGenerator, s: []const u8) !void {
        try self.src.appendSlice(self.alloc, s);
    }
    fn srcPrint(self: *ConcreteImplGenerator, comptime fmt: []const u8, args: anytype) !void {
        const s = try std.fmt.allocPrint(self.alloc, fmt, args);
        defer self.alloc.free(s);
        try self.src.appendSlice(self.alloc, s);
    }

    fn emit(self: *ConcreteImplGenerator, spec: *const ir.Spec) !void {
        try self.hdrPrint(
            "// Generated by zidl from {s}.idl \u{2014} DO NOT EDIT\n#pragma once\n",
            .{self.opts.input_stem},
        );
        try self.hdrPrint(
            // <mutex>/<unordered_map> unconditionally, unlike the .cpp's own
            // conditional include below: a shared-family root class (see
            // familyOf/emitEntityImplDecl) declares its _familyMutex()/
            // _familyCache() accessors' *return types* right here in the
            // header, so std::mutex/std::unordered_map must already be
            // complete types by the time this file's own class bodies are
            // parsed -- not just by the time the .cpp implementing them is.
            "#include \"{s}.hpp\"\n#include \"{s}.h\"\n#include \"zzdds_c.h\"\n#include <memory>\n#include <mutex>\n#include <unordered_map>\n\n",
            .{ self.opts.input_stem, self.opts.input_stem },
        );
        for (spec.imports) |import_name| {
            const stem = try interface.includeStemForImport(self.alloc, import_name);
            defer self.alloc.free(stem);
            try self.hdrPrint("#include \"{s}_impl.hpp\"\n", .{stem});
        }
        if (spec.imports.len != 0) try self.hdrWrite("\n");

        try interface.collectEntityBaseNames(self.alloc, spec.items, &self.entity_base_ifaces);
        try interface.collectBaseImplementors(self.alloc, spec.items, &self.base_implementors);
        try interface.collectSharedCAbiBoxFamilies(self.alloc, spec.items, &self.families);

        // Pre-scan: discover which entity interfaces are ever wrapped via
        // _getOrCreate (op return, attribute, sequence element, listener
        // parameter) anywhere in the spec, by running the real emission
        // logic once into throwaway buffers first. Needed because whether
        // class Foo needs _getOrCreate can depend on usage discovered in a
        // different interface/module processed later — emitting a class's
        // header (which must decide this inline, as part of the class body)
        // isn't possible without already knowing the full-spec answer.
        //
        // Some entity interfaces are never wrapped anywhere: typically ones
        // that add only a few operations on top of an inherited, cross-module
        // abstract interface (e.g. zzdds.idl's extension interfaces over
        // dcps.idl's DDS.* base interfaces). Entity interfaces don't get
        // cross-module operation flattening (only `@callback` interfaces do —
        // see `resetNonCallbackInterfaces` in `ir/builder.zig`), so such a
        // class's generated Impl never implements the inherited base's pure
        // virtuals and is left intentionally abstract, completed instead by
        // a hand-written subclass elsewhere (e.g. zzdds_cpp.hpp's
        // DomainParticipantFactorySupport, composing a fully-implemented
        // DDS::DomainParticipantFactoryImpl rather than inheriting from the
        // generated one). Emitting _getOrCreate unconditionally for such a
        // class would try to std::make_shared an abstract type the moment
        // the generated .cpp is compiled, even though nothing ever calls it —
        // confirmed by a real build: every one of zzdds.idl's five entity
        // classes failed this way before this pre-scan was added.
        {
            var scratch_hdr = std.ArrayList(u8).empty;
            var scratch_src = std.ArrayList(u8).empty;
            const real_hdr = self.hdr;
            const real_src = self.src;
            self.hdr = &scratch_hdr;
            self.src = &scratch_src;
            // Restore self.hdr/self.src unconditionally before checking the
            // result — on an error path, `try`-ing directly here would leave
            // both pointing at the scratch buffers this block is about to
            // deinit, a dangling-pointer trap for any future errdefer in
            // emit() that touches self.hdr/self.src.
            const prescan_result = self.emitItems(spec.items);
            self.hdr = real_hdr;
            self.src = real_src;
            scratch_hdr.deinit(self.alloc);
            scratch_src.deinit(self.alloc);
            try prescan_result;
        }

        try self.srcPrint(
            "// Generated by zidl from {s}.idl \u{2014} DO NOT EDIT\n#include \"{s}_impl.hpp\"\n",
            .{ self.opts.input_stem, self.opts.input_stem },
        );
        // --cpp-impl-include: extra includes so any --cpp-impl-override
        // class is visible in this file. Emitted unconditionally when given,
        // regardless of whether the pre-scan below found a matching
        // override actually in use -- cheap, and simpler than threading
        // "was this include actually needed" through the pre-scan result.
        for (self.opts.cpp_impl_includes) |header| {
            try self.srcPrint("#include \"{s}\"\n", .{header});
        }
        // <mutex>/<unordered_map>/zidl_allocator_pmr.hpp back _getOrCreate's identity
        // cache and allocator-aware construction, emitted only when the pre-scan above
        // found at least one interface that actually needs it — skip the includes
        // entirely otherwise (e.g. struct-only IDL, or a spec whose entity interfaces
        // are never wrapped anywhere), rather than always paying for STL headers no
        // emitted code in this file ends up using.
        if (self.wrapped_entities.count() > 0) {
            try self.srcWrite("#include <mutex>\n#include <unordered_map>\n#include \"zidl_allocator_pmr.hpp\"\n");
        }
        try self.srcWrite("\n");
        try self.emitItems(spec.items);
    }

    fn emitItems(self: *ConcreteImplGenerator, items: []const ir.ModuleItem) anyerror!void {
        for (items) |item| {
            switch (item) {
                .module => |m| try self.emitModule(m),
                .type_decl, .const_ => {},
            }
        }
    }

    fn emitModule(self: *ConcreteImplGenerator, m: *const ir.Module) !void {
        var entities = std.ArrayListUnmanaged(*const ir.Interface).empty;
        defer entities.deinit(self.alloc);
        var callbacks = std.ArrayListUnmanaged(*const ir.Interface).empty;
        defer callbacks.deinit(self.alloc);
        try self.collectModuleInterfaces(m.items, &entities, &callbacks);

        // ── Header ────────────────────────────────────────────────────────────
        try self.hdrPrint("namespace {s} {{\n\n", .{m.name});

        // Forward declarations
        for (entities.items) |iface| {
            try self.hdrPrint("class {s}Impl;\n", .{iface.name});
        }
        // FooListenerBase classes are declared in dcps.hpp (Generator), not here.
        if (entities.items.len > 0 or callbacks.items.len > 0) try self.hdrWrite("\n");

        // Class bodies
        for (entities.items) |iface| try self.emitEntityImplDecl(m.name, iface);

        try self.hdrWrite(
            "// Bootstrap factory helpers such as create_participant_udp are not generated here;\n" ++
                "// obtain a factory through the zzdds bootstrap API and use the generated DDS/zzdds factory interfaces.\n",
        );
        try self.hdrPrint("}} // namespace {s}\n\n", .{m.name});

        // ── Source ────────────────────────────────────────────────────────────
        try self.srcPrint("namespace {s} {{\n\n", .{m.name});
        for (entities.items) |iface| try self.emitEntityImplMethods(iface);
        for (callbacks.items) |iface| try self.emitListenerBridgeMethods(m.name, iface);
        try self.srcPrint("}} // namespace {s}\n\n", .{m.name});
    }

    fn collectModuleInterfaces(
        self: *ConcreteImplGenerator,
        items: []const ir.ModuleItem,
        entities: *std.ArrayListUnmanaged(*const ir.Interface),
        callbacks: *std.ArrayListUnmanaged(*const ir.Interface),
    ) anyerror!void {
        for (items) |item| {
            switch (item) {
                .type_decl => |td| switch (td) {
                    .interface => |iface| {
                        if (isCallbackIface(iface)) {
                            try callbacks.append(self.alloc, iface);
                        } else {
                            try entities.append(self.alloc, iface);
                        }
                    },
                    else => {},
                },
                .module => |m| try self.collectModuleInterfaces(m.items, entities, callbacks),
                .const_ => {},
            }
        }
    }

    // ── Entity Impl declaration (header) ──────────────────────────────────────

    fn emitEntityImplDecl(self: *ConcreteImplGenerator, ns: []const u8, iface: *const ir.Interface) !void {
        const c_name = try cNameOf(self.alloc, iface.qualified_name);
        defer self.alloc.free(c_name);

        var ops = std.ArrayListUnmanaged(OwnedOperation).empty;
        defer ops.deinit(self.alloc);
        var attrs = std.ArrayListUnmanaged(OwnedAttribute).empty;
        defer attrs.deinit(self.alloc);
        try collectOwnedIfaceMembers(self.alloc, iface, &ops, &attrs);

        try self.hdrPrint("// \u{2500}\u{2500} {s}Impl \u{2500}\u{2500}\n\n", .{iface.name});
        try self.hdrPrint(
            "class {s}Impl : public ::{s}::{s} {{\npublic:\n",
            .{ iface.name, ns, iface.name },
        );
        // Deliberately left public rather than private+friend/tag-gated: consumers are
        // expected to subclass a generated FooImpl and call this constructor directly
        // from the derived class's own initializer list (e.g. zzdds_cpp.hpp's
        // DomainParticipantFactorySupport : public DomainParticipantFactoryImpl) to
        // override virtual behavior. Locking the constructor down to force everything
        // through _getOrCreate would break that pattern, which zzdds's own hand-written
        // C++ glue already relies on for its factory bootstrap. _getOrCreate is the
        // identity-preserving path for ordinary entity-returning calls; direct
        // construction is an accepted, deliberate escape hatch for subclassing, not an
        // oversight.
        try self.hdrPrint(
            "    explicit {s}Impl({s} h) noexcept : ptr_(h) {{}}\n",
            .{ iface.name, c_name },
        );
        try self.hdrPrint("    ~{s}Impl() override = default;\n", .{iface.name});
        // Returns the cached wrapper for `h` if one is still alive, otherwise
        // constructs and caches a new one. Identity-preserving: repeated calls
        // for the same C handle return the same shared_ptr instance, matching
        // C++'s own class-hierarchy identity semantics.
        //
        // Only declared when the pre-scan (see `wrapped_entities`'s doc
        // comment) found this interface actually wrapped somewhere: some
        // entity interfaces are never fully concrete on their own (a
        // cross-module abstract base's operations aren't visible to the
        // generator — see `emit()`'s pre-scan comment) and rely on a
        // hand-written subclass to complete them; std::make_shared-ing such
        // a type unconditionally would fail to compile even though nothing
        // ever calls it.
        if (self.wrapped_entities.contains(iface.qualified_name)) {
            const fam = self.familyOf(iface);
            if (fam.size <= 1) {
                try self.hdrPrint(
                    "    static std::shared_ptr<{s}Impl> _getOrCreate({s} h);\n",
                    .{ iface.name, c_name },
                );
            } else if (fam.root == iface) {
                // Family root with real sibling implementors (e.g. Condition:
                // GuardCondition/StatusCondition/ReadCondition/QueryCondition) --
                // see `familyOf`'s doc comment. Returns the shared interface
                // type, not this root's own concrete class: a cache hit may
                // genuinely be a sibling object (constructed by ITS OWN
                // _getOrCreate, viewed here through the one thing every family
                // member actually inherits from), which this root's own
                // concrete class can't represent. Every call site already
                // immediately upcasts a _getOrCreate result into the
                // corresponding interface type (an op's declared return type, a
                // sequence element, a listener parameter) — none has ever
                // needed the concrete class specifically, so this is a
                // behavior-preserving signature change for every existing
                // caller.
                try self.hdrPrint(
                    "    static std::shared_ptr<{s}> _getOrCreate({s} h);\n",
                    .{ iface.name, c_name },
                );
                // Shared identity cache for the whole family, exposed so
                // sibling *Impl classes (and hand-written glue for types with
                // no _getOrCreate of their own, e.g. zzdds_cpp.hpp's
                // GuardConditionSupport) can consult/populate the SAME cache
                // this root's own _getOrCreate uses below -- see
                // emitEntityImplMethods. Meyer's-singleton function-local
                // statics rather than class-static data members: no
                // out-of-line definition needed, and C++11 guarantees
                // thread-safe lazy init.
                //
                // std::pmr::unordered_map, not plain std::unordered_map: the
                // *values* this cache stores are already routed through
                // std::pmr::polymorphic_allocator(std::pmr::get_default_resource())
                // below (same as _getOrCreate's own std::allocate_shared
                // call), but the cache's own hash-table node allocations
                // were not -- a real gap, not a hypothetical one: confirmed
                // via an actual operator-new call under a noalloc-guarded
                // custom-allocator example (zzdds-examples' cpp/custom-
                // allocator, GuardCondition family) that otherwise routes
                // every allocation through zidl::setCppAllocator. A bare
                // `std::pmr::unordered_map<K,V> c;` static already
                // default-constructs against std::pmr::get_default_resource()
                // with no explicit allocator argument needed, matching every
                // other pmr container in this codebase.
                try self.hdrPrint(
                    "    static std::mutex& _familyMutex();\n" ++
                        "    static std::pmr::unordered_map<{s}, std::weak_ptr<{s}>>& _familyCache();\n",
                    .{ c_name, iface.name },
                );
            } else {
                // Non-root family member: signature unchanged (still this
                // member's own concrete class -- see `familyOf`'s doc comment
                // for why a downcast-after-lookup is safe here but not for the
                // root), only the body (emitEntityImplMethods) changes to
                // consult the root's shared cache instead of its own.
                try self.hdrPrint(
                    "    static std::shared_ptr<{s}Impl> _getOrCreate({s} h);\n",
                    .{ iface.name, c_name },
                );
            }
        }
        // Check for a qualifying ancestor FIRST, not iface's own eligibility:
        // an interface can be both "not excluded" (own-eligible) AND have an
        // ancestor that already declares a compatible native_handle() (e.g.
        // zzdds::DomainParticipantFactory : DDS::DomainParticipantFactory --
        // both are individually eligible, but the derived one must inherit
        // and convert, not redeclare its own with a different return type,
        // which would create two same-named virtuals with incompatible,
        // non-covariant return types -- a hard compile error).
        // Use 'override' only when the abstract interface declares native_handle().
        // Other concrete Impl classes still expose native_handle() for adapter code,
        // unless a base interface already declares a conflicting native_handle()
        // with a different C handle return type.
        if (try self.nativeHandleBase(iface)) |base_iface| {
            const base_c = try cNameOf(self.alloc, base_iface.qualified_name);
            defer self.alloc.free(base_c);
            const handle_expr = try self.handleExprForOwner(iface, base_iface, "ptr_");
            defer self.alloc.free(handle_expr);
            try self.hdrPrint(
                "    {s} native_handle() const noexcept override {{ return {s}; }}\n\n",
                .{ base_c, handle_expr },
            );
        } else if (self.ifaceDeclaresNativeHandle(iface)) {
            try self.hdrPrint(
                "    {s} native_handle() const noexcept override {{ return ptr_; }}\n\n",
                .{c_name},
            );
        } else {
            try self.hdrPrint(
                "    {s} native_handle() const noexcept {{ return ptr_; }}\n\n",
                .{c_name},
            );
        }

        for (ops.items) |op| {
            const sig = try self.opSignature(op.op);
            defer self.alloc.free(sig);
            try self.hdrPrint("    {s} override;\n", .{sig});
        }
        for (attrs.items) |attr| {
            const at = try self.typeRefToCpp(attr.attr.type_ref);
            defer self.alloc.free(at);
            try self.hdrPrint("    {s} {s}() const override;\n", .{ at, attr.attr.name });
            if (!attr.attr.readonly)
                try self.hdrPrint("    void {s}({s} value) override;\n", .{ attr.attr.name, at });
        }

        try self.hdrPrint(
            "\nprivate:\n    friend {s} zidl_concrete_handle(const {s}Impl& self) noexcept {{ return self.ptr_; }}\n",
            .{ c_name, iface.name },
        );
        if (listenerTypeOf(ops.items)) |listener_tr| {
            const cpp_listener = try self.typeRefToCpp(listener_tr);
            defer self.alloc.free(cpp_listener);
            try self.hdrPrint("    {s} listener_;\n", .{cpp_listener});
        }
        try self.hdrPrint("    {s} ptr_;\n}};\n\n", .{c_name});
    }

    // ── Entity Impl method implementations (source) ───────────────────────────

    fn emitEntityImplMethods(self: *ConcreteImplGenerator, iface: *const ir.Interface) !void {
        var ops = std.ArrayListUnmanaged(OwnedOperation).empty;
        defer ops.deinit(self.alloc);
        var attrs = std.ArrayListUnmanaged(OwnedAttribute).empty;
        defer attrs.deinit(self.alloc);
        try collectOwnedIfaceMembers(self.alloc, iface, &ops, &attrs);

        try self.srcPrint("// \u{2500}\u{2500} {s}Impl \u{2500}\u{2500}\n\n", .{iface.name});

        // See the header declaration's doc comment (emitEntityImplDecl) and
        // wrapped_entities' doc comment for why this is conditional.
        if (self.wrapped_entities.contains(iface.qualified_name)) {
            const c_name = try cNameOf(self.alloc, iface.qualified_name);
            defer self.alloc.free(c_name);
            const fam = self.familyOf(iface);
            if (fam.size <= 1) {
                try self.srcPrint(
                    "std::shared_ptr<{s}Impl> {s}Impl::_getOrCreate({s} h) {{\n" ++
                        "    if (!h) return nullptr;\n" ++
                        "    static std::mutex _mtx;\n" ++
                        "    static std::unordered_map<{s}, std::weak_ptr<{s}Impl>> _cache;\n" ++
                        "    std::lock_guard<std::mutex> _lock(_mtx);\n" ++
                        "    auto _it = _cache.find(h);\n" ++
                        "    if (_it != _cache.end()) {{\n" ++
                        "        if (auto _sp = _it->second.lock()) return _sp;\n" ++
                        "    }}\n" ++
                        "    auto _sp = std::allocate_shared<{s}Impl>(\n" ++
                        "        std::pmr::polymorphic_allocator<{s}Impl>(std::pmr::get_default_resource()), h);\n" ++
                        "    if (_it != _cache.end()) {{\n" ++
                        "        _it->second = _sp;\n" ++
                        "    }} else {{\n" ++
                        "        _cache.emplace(h, _sp);\n" ++
                        "    }}\n" ++
                        "    return _sp;\n" ++
                        "}}\n\n",
                    .{ iface.name, iface.name, c_name, c_name, iface.name, iface.name, iface.name },
                );
            } else if (fam.root == iface) {
                // Family root: owns the one cache every sibling shares (see
                // emitEntityImplDecl). Meyer's singletons -- thread-safe lazy
                // init, no static-initialization-order concerns, no
                // out-of-line data member definition needed.
                try self.srcPrint(
                    "std::mutex& {s}Impl::_familyMutex() {{\n" ++
                        "    static std::mutex m;\n" ++
                        "    return m;\n" ++
                        "}}\n" ++
                        "std::pmr::unordered_map<{s}, std::weak_ptr<{s}>>& {s}Impl::_familyCache() {{\n" ++
                        "    static std::pmr::unordered_map<{s}, std::weak_ptr<{s}>> c;\n" ++
                        "    return c;\n" ++
                        "}}\n",
                    .{ iface.name, c_name, iface.name, iface.name, c_name, iface.name },
                );
                // Cache hit may genuinely be a sibling object (constructed by
                // its own _getOrCreate below) viewed through the shared
                // interface type -- that's fine and correct, this root's
                // return type is that interface, not its own concrete class
                // (see emitEntityImplDecl). Miss falls back to constructing a
                // real (if generically-typed) instance of this root's own
                // class, exactly like the size<=1 case above.
                try self.srcPrint(
                    "std::shared_ptr<{s}> {s}Impl::_getOrCreate({s} h) {{\n" ++
                        "    if (!h) return nullptr;\n" ++
                        "    std::lock_guard<std::mutex> _lock(_familyMutex());\n" ++
                        "    auto& _cache = _familyCache();\n" ++
                        "    auto _it = _cache.find(h);\n" ++
                        "    if (_it != _cache.end()) {{\n" ++
                        "        if (auto _sp = _it->second.lock()) return _sp;\n" ++
                        "    }}\n" ++
                        "    auto _sp = std::allocate_shared<{s}Impl>(\n" ++
                        "        std::pmr::polymorphic_allocator<{s}Impl>(std::pmr::get_default_resource()), h);\n" ++
                        "    if (_it != _cache.end()) {{\n" ++
                        "        _it->second = _sp;\n" ++
                        "    }} else {{\n" ++
                        "        _cache.emplace(h, _sp);\n" ++
                        "    }}\n" ++
                        "    return _sp;\n" ++
                        "}}\n\n",
                    .{ iface.name, iface.name, c_name, iface.name, iface.name },
                );
            } else {
                // Non-root family member: consults/populates the ROOT's
                // shared cache instead of one of its own. A cache hit is
                // recovered via dynamic_pointer_cast back down to this
                // member's own concrete class -- safe (not just hopeful)
                // because the only thing that could ever have populated the
                // shared cache with an object that's actually-at-runtime this
                // class is this exact function, on a previous call for the
                // same handle (every other family member constructs its OWN
                // class, never this one's) -- so a hit here is always either
                // this class or, in the defensive fallback below, treated as
                // a fresh miss rather than trusted blindly.
                const root_c_name = try cNameOf(self.alloc, fam.root.qualified_name);
                defer self.alloc.free(root_c_name);
                const root_impl = try std.fmt.allocPrint(self.alloc, "::{s}Impl", .{fam.root.qualified_name});
                defer self.alloc.free(root_impl);
                const key_expr = try self.handleExprForOwner(iface, fam.root, "h");
                defer self.alloc.free(key_expr);
                try self.srcPrint(
                    "std::shared_ptr<{s}Impl> {s}Impl::_getOrCreate({s} h) {{\n" ++
                        "    if (!h) return nullptr;\n" ++
                        "    {s} _fh = {s};\n" ++
                        "    std::lock_guard<std::mutex> _lock({s}::_familyMutex());\n" ++
                        "    auto& _cache = {s}::_familyCache();\n" ++
                        "    auto _it = _cache.find(_fh);\n" ++
                        "    if (_it != _cache.end()) {{\n" ++
                        "        if (auto _base = _it->second.lock()) {{\n" ++
                        "            if (auto _sp = std::dynamic_pointer_cast<{s}Impl>(_base)) return _sp;\n" ++
                        "        }}\n" ++
                        "    }}\n" ++
                        "    auto _sp = std::allocate_shared<{s}Impl>(\n" ++
                        "        std::pmr::polymorphic_allocator<{s}Impl>(std::pmr::get_default_resource()), h);\n" ++
                        "    _cache[_fh] = _sp;\n" ++
                        "    return _sp;\n" ++
                        "}}\n\n",
                    .{ iface.name, iface.name, c_name, root_c_name, key_expr, root_impl, root_impl, iface.name, iface.name, iface.name },
                );
            }
        }

        const listener_tr = listenerTypeOf(ops.items);
        for (ops.items) |op| {
            try self.emitEntityMethod(iface, op.owner, iface.name, op.op, listener_tr);
        }
        for (attrs.items) |attr| {
            try self.emitEntityAttr(iface, attr.owner, iface.name, attr.attr);
        }
    }

    fn emitEntityMethod(
        self: *ConcreteImplGenerator,
        iface: *const ir.Interface,
        owner: *const ir.Interface,
        class_name: []const u8,
        op: *const ir.Operation,
        listener_tr: ?ir.TypeRef,
    ) !void {
        const owner_c_name = try cNameOf(self.alloc, owner.qualified_name);
        defer self.alloc.free(owner_c_name);
        const handle_expr = try self.handleExprForOwner(iface, owner, "ptr_");
        defer self.alloc.free(handle_expr);
        const ret_cpp = if (op.return_type) |rt| try self.typeRefToCpp(rt) else try self.alloc.dupe(u8, "void");
        defer self.alloc.free(ret_cpp);

        try self.srcPrint("{s} {s}Impl::{s}(", .{ ret_cpp, class_name, op.name });
        for (op.params, 0..) |p, i| {
            if (i > 0) try self.srcWrite(", ");
            const pt = try self.typeRefToCpp(p.type_ref);
            defer self.alloc.free(pt);
            switch (p.mode) {
                .in_ => try self.srcPrint("{s} {s}", .{ pt, p.name }),
                .out, .inout => try self.srcPrint("{s}& {s}", .{ pt, p.name }),
            }
        }
        try self.srcWrite(") {\n");

        if (listener_tr != null and op.params.len == 0 and std.mem.eql(u8, op.name, "get_listener")) {
            try self.srcWrite("    return listener_;\n}\n\n");
            return;
        }

        if (!self.opIsAdaptable(op)) {
            try self.srcWrite("    /* TODO: adapt parameters/return (sequence or complex QoS) */\n");
            if (op.return_type) |rt| {
                switch (rt) {
                    .named => |td| switch (td) {
                        .interface => try self.srcWrite("    return nullptr;\n"),
                        else => try self.srcWrite("    return {};\n"),
                    },
                    else => try self.srcWrite("    return {};\n"),
                }
            }
            try self.srcWrite("}\n\n");
            return;
        }

        // Emit C adaptation locals for complex struct in-params (QoS types with sequences),
        // top-level sequence in-params (StringSeq, OctetSeq, etc.), and zero-init
        // C locals for complex struct out-params (filled post-call by emitComplexStructAdaptOut).
        var seq_ctr: usize = 0;
        for (op.params) |p| {
            switch (paramAdaptKind(p)) {
                .complex_struct_in => {
                    const c_var = try std.fmt.allocPrint(self.alloc, "_c_{s}", .{p.name});
                    defer self.alloc.free(c_var);
                    try self.emitComplexStructAdaptIn(c_var, p.name, p.type_ref, &seq_ctr);
                },
                .seq_in => try self.emitSeqParamAdaptIn(p, &seq_ctr),
                .complex_struct_out => {
                    const s: *const ir.Struct = switch (p.type_ref) {
                        .named => |td| switch (td) {
                            .struct_ => |s| s,
                            else => unreachable,
                        },
                        else => unreachable,
                    };
                    const c_type = try cNameOf(self.alloc, s.qualified_name);
                    defer self.alloc.free(c_type);
                    try self.srcPrint("    {s} _c_{s}{{}};\n", .{ c_type, p.name });
                },
                .seq_out => {
                    // Walk typedef chain to find the C type name for the sequence.
                    var tr = p.type_ref;
                    const c_type: ?[]u8 = while (true) {
                        switch (tr) {
                            .named => |td| switch (td) {
                                .typedef => |t| {
                                    if (t.dimensions.len != 0) break null;
                                    switch (t.type_ref) {
                                        .sequence => break try cNameOf(self.alloc, t.qualified_name),
                                        else => tr = t.type_ref,
                                    }
                                },
                                else => break null,
                            },
                            else => break null,
                        }
                    };
                    if (c_type) |ct| {
                        defer self.alloc.free(ct);
                        try self.srcPrint("    {s} _c_{s}{{}};\n", .{ ct, p.name });
                    }
                },
                else => {},
            }
        }

        // Emit listener local vars
        for (op.params) |p| {
            if (paramAdaptKind(p) == .listener_in) {
                const lc = try self.listenerCType(p.type_ref);
                defer self.alloc.free(lc);
                const bridge_name = try self.listenerBridgeName(p.type_ref);
                defer self.alloc.free(bridge_name);
                try self.srcPrint("    {s}* _lp_{s} = nullptr;\n", .{ lc, p.name });
                try self.srcPrint("    {s} _l_{s}{{}};\n", .{ lc, p.name });
                try self.srcPrint(
                    "    if (auto* _b = dynamic_cast<{s}*>({s}.get())) {{ _l_{s} = _b->c_listener(); _lp_{s} = &_l_{s}; }}\n",
                    .{ bridge_name, p.name, p.name, p.name, p.name },
                );
            }
        }

        // Stash the listener shared_ptr so a later get_listener() can return it —
        // the C ABI has no call to read it back out. Only stashed once the C call
        // reports success, so a rejected set_listener doesn't diverge from the
        // middleware's actual listener state.
        const is_listener_setter = if (listener_tr) |ltr| blk: {
            const listener_qname = switch (ltr) {
                .named => |td| switch (td) {
                    .interface => |listener_iface| listener_iface.qualified_name,
                    else => "",
                },
                else => "",
            };
            break :blk isListenerSetterParam(op, listener_qname);
        } else false;

        // Build the C call
        const ret_kind = returnAdaptKind(op.return_type);
        switch (ret_kind) {
            .entity => {
                const ret_c = try self.typeRefToCType(op.return_type.?);
                defer self.alloc.free(ret_c);
                const impl_name = try self.entityImplName(op.return_type.?);
                defer self.alloc.free(impl_name);
                try self.markWrapped(op.return_type.?);
                try self.srcPrint("    {s} _h = {s}_{s}({s}", .{ ret_c, owner_c_name, op.name, handle_expr });
                try self.emitAdaptedParams(op.params);
                try self.srcWrite(");\n");
                try self.srcPrint("    return {s}::_getOrCreate(_h);\n", .{impl_name});
            },
            .str_ret => {
                try self.srcPrint("    const char* _r = {s}_{s}({s}", .{ owner_c_name, op.name, handle_expr });
                try self.emitAdaptedParams(op.params);
                try self.srcWrite(");\n");
                const str_t = stringTypeName(self.opts);
                try self.srcPrint("    return _r ? {s}(_r) : {s}{{}};\n", .{ str_t, str_t });
            },
            .direct => {
                const needs_post = is_listener_setter or for (op.params) |p| {
                    const k = paramAdaptKind(p);
                    if (k == .complex_struct_out or k == .seq_out) break true;
                } else false;
                if (needs_post) {
                    if (op.return_type != null) {
                        try self.srcPrint("    const auto _rc = {s}_{s}({s}", .{ owner_c_name, op.name, handle_expr });
                    } else {
                        try self.srcPrint("    {s}_{s}({s}", .{ owner_c_name, op.name, handle_expr });
                    }
                    try self.emitAdaptedParams(op.params);
                    try self.srcWrite(");\n");
                    for (op.params) |p| {
                        switch (paramAdaptKind(p)) {
                            .complex_struct_out => try self.emitComplexStructAdaptOut(p.name, p.type_ref, &seq_ctr),
                            .seq_out => try self.emitSeqParamAdaptOut(p, &seq_ctr),
                            else => {},
                        }
                    }
                    if (is_listener_setter) {
                        if (op.return_type != null) {
                            try self.srcPrint("    if (_rc == 0) listener_ = {s};\n", .{op.params[0].name});
                        } else {
                            try self.srcPrint("    listener_ = {s};\n", .{op.params[0].name});
                        }
                    }
                    if (op.return_type != null) try self.srcWrite("    return _rc;\n");
                } else {
                    if (op.return_type != null) {
                        try self.srcPrint("    return {s}_{s}({s}", .{ owner_c_name, op.name, handle_expr });
                    } else {
                        try self.srcPrint("    {s}_{s}({s}", .{ owner_c_name, op.name, handle_expr });
                    }
                    try self.emitAdaptedParams(op.params);
                    try self.srcWrite(");\n");
                }
            },
            .todo => {
                try self.srcWrite("    /* TODO: return type not adaptable */\n");
                try self.srcWrite("    return {};\n");
            },
        }
        try self.srcWrite("}\n\n");
    }

    fn emitEntityAttr(
        self: *ConcreteImplGenerator,
        iface: *const ir.Interface,
        owner: *const ir.Interface,
        class_name: []const u8,
        attr: *const ir.Attribute,
    ) !void {
        const owner_c_name = try cNameOf(self.alloc, owner.qualified_name);
        defer self.alloc.free(owner_c_name);
        const handle_expr = try self.handleExprForOwner(iface, owner, "ptr_");
        defer self.alloc.free(handle_expr);
        const at = try self.typeRefToCpp(attr.type_ref);
        defer self.alloc.free(at);

        // Getter
        try self.srcPrint("{s} {s}Impl::{s}() const {{\n", .{ at, class_name, attr.name });
        switch (returnAdaptKind(attr.type_ref)) {
            .entity => {
                const ret_c = try self.typeRefToCType(attr.type_ref);
                defer self.alloc.free(ret_c);
                const impl_name = try self.entityImplName(attr.type_ref);
                defer self.alloc.free(impl_name);
                try self.markWrapped(attr.type_ref);
                try self.srcPrint("    {s} _h = {s}_get_{s}({s});\n", .{ ret_c, owner_c_name, attr.name, handle_expr });
                try self.srcPrint("    return {s}::_getOrCreate(_h);\n", .{impl_name});
            },
            .str_ret => {
                try self.srcPrint("    const char* _r = {s}_get_{s}({s});\n", .{ owner_c_name, attr.name, handle_expr });
                const str_t = stringTypeName(self.opts);
                try self.srcPrint("    return _r ? {s}(_r) : {s}{{}};\n", .{ str_t, str_t });
            },
            .direct => {
                if (typeRefIsEnumLike(attr.type_ref)) {
                    try self.srcPrint("    return static_cast<{s}>({s}_get_{s}({s}));\n", .{ at, owner_c_name, attr.name, handle_expr });
                } else {
                    try self.srcPrint("    return {s}_get_{s}({s});\n", .{ owner_c_name, attr.name, handle_expr });
                }
            },
            .todo => {
                try self.srcWrite("    /* TODO */\n    return {};\n");
            },
        }
        try self.srcWrite("}\n\n");

        if (!attr.readonly) {
            try self.srcPrint("void {s}Impl::{s}({s} value) {{\n", .{ class_name, attr.name, at });
            switch (paramAdaptKindForTypeRef(attr.type_ref, .in_)) {
                .direct => {
                    if (typeRefIsEnumLike(attr.type_ref)) {
                        const ct = try self.typeRefToCType(attr.type_ref);
                        defer self.alloc.free(ct);
                        try self.srcPrint("    {s}_set_{s}({s}, static_cast<{s}>(value));\n", .{ owner_c_name, attr.name, handle_expr, ct });
                    } else {
                        try self.srcPrint("    {s}_set_{s}({s}, value);\n", .{ owner_c_name, attr.name, handle_expr });
                    }
                },
                .str_in => try self.srcPrint("    {s}_set_{s}({s}, value.c_str());\n", .{ owner_c_name, attr.name, handle_expr }),
                else => try self.srcPrint("    /* TODO */\n    (void)value;\n", .{}),
            }
            try self.srcWrite("}\n\n");
        }
    }

    fn emitAdaptedParams(self: *ConcreteImplGenerator, params: []const ir.Parameter) !void {
        for (params) |p| {
            try self.srcWrite(", ");
            switch (paramAdaptKind(p)) {
                .direct => {
                    if (typeRefIsEnumLike(p.type_ref)) {
                        const ct = try self.typeRefToCType(p.type_ref);
                        defer self.alloc.free(ct);
                        try self.srcPrint("static_cast<{s}>({s})", .{ ct, p.name });
                    } else {
                        try self.srcWrite(p.name);
                    }
                },
                .str_in => try self.srcPrint("{s}.c_str()", .{p.name}),
                .struct_in => {
                    const ct = try self.structCType(p.type_ref);
                    defer self.alloc.free(ct);
                    try self.srcPrint("reinterpret_cast<const {s}*>(&{s})", .{ ct, p.name });
                },
                .struct_inout => {
                    const ct = try self.structCType(p.type_ref);
                    defer self.alloc.free(ct);
                    try self.srcPrint("reinterpret_cast<{s}*>(&{s})", .{ ct, p.name });
                },
                .complex_struct_in, .seq_in, .complex_struct_out, .seq_out => try self.srcPrint("&_c_{s}", .{p.name}),
                .entity_in => {
                    const ct = try self.typeRefToCType(p.type_ref);
                    defer self.alloc.free(ct);
                    // use_virtual requires iface to own its OWN fresh
                    // native_handle() (return type == ct exactly) -- not just
                    // "not excluded". An interface that instead inherits and
                    // converts from a qualifying ancestor (nativeHandleBase
                    // non-null, e.g. zzdds::X : DDS::X) has a native_handle()
                    // returning the ANCESTOR's type, not ct, so it must still
                    // go through the dynamic_cast + zidl_concrete_handle path.
                    const use_virtual = switch (p.type_ref) {
                        .named => |td| switch (td) {
                            .interface => |iface| self.ifaceDeclaresNativeHandle(iface) and
                                (try self.nativeHandleBase(iface)) == null,
                            else => false,
                        },
                        else => false,
                    };
                    if (use_virtual) {
                        try self.srcPrint(
                            "({s} ? {s}->native_handle() : nullptr)",
                            .{ p.name, p.name },
                        );
                    } else {
                        const impl_name = try self.entityImplName(p.type_ref);
                        defer self.alloc.free(impl_name);
                        const target_iface: ?*const ir.Interface = switch (p.type_ref) {
                            .named => |td| switch (td) {
                                .interface => |iface| iface,
                                else => null,
                            },
                            else => null,
                        };
                        const iface_name = if (target_iface) |ti| ti.qualified_name else ct;

                        // Sibling interfaces that also implement iface_name
                        // (see base_implementors's doc comment) -- e.g.
                        // TopicDescription is implemented independently by
                        // TopicDescriptionImpl, ContentFilteredTopicImpl, and
                        // MultiTopicImpl, none of which inherit from each
                        // other. A single dynamic_cast against impl_name
                        // alone would wrongly reject a ContentFilteredTopic
                        // passed where a TopicDescription is expected.
                        const ExtraCandidate = struct { impl_name: []const u8, cast_expr: []const u8 };
                        var extra_impls: std.ArrayListUnmanaged(ExtraCandidate) = .empty;
                        defer {
                            for (extra_impls.items) |e| {
                                self.alloc.free(e.impl_name);
                                self.alloc.free(e.cast_expr);
                            }
                            extra_impls.deinit(self.alloc);
                        }
                        if (target_iface) |ti| {
                            if (self.base_implementors.get(ti.qualified_name)) |implementors| {
                                for (implementors.items) |impl_iface| {
                                    const extra_name = try self.entityImplName(.{ .named = .{ .interface = @constCast(impl_iface) } });
                                    var dup = std.mem.eql(u8, extra_name, impl_name);
                                    if (!dup) for (extra_impls.items) |existing| {
                                        if (std.mem.eql(u8, existing.impl_name, extra_name)) {
                                            dup = true;
                                            break;
                                        }
                                    };
                                    if (dup) {
                                        self.alloc.free(extra_name);
                                        continue;
                                    }
                                    // Real upcast through the C-ABI's own
                                    // generated `X_as_Y` conversion (same
                                    // mechanism this function already uses
                                    // for inherited-method dispatch below) --
                                    // NOT a reinterpret_cast: e.g.
                                    // DDS_ContentFilteredTopic and
                                    // DDS_TopicDescription are boxed with
                                    // different vtables for the very same
                                    // underlying entity, so treating one
                                    // handle as the other without going
                                    // through DDS_ContentFilteredTopic_as_
                                    // DDS_TopicDescription silently breaks
                                    // whatever the receiving C-ABI call does
                                    // with the (mis-vtabled) handle.
                                    const cast_expr = try self.handleExprForOwner(impl_iface, ti, "zidl_concrete_handle(*_impl)");
                                    try extra_impls.append(self.alloc, .{ .impl_name = extra_name, .cast_expr = cast_expr });
                                }
                            }
                        }

                        try self.srcWrite("/* zidl: entity parameter adaptation uses dynamic_cast and requires RTTI. */");
                        try self.srcPrint(
                            "([](const auto& _p) -> {s} {{ if (!_p) return nullptr; if (auto* _impl = dynamic_cast<{s}*>(_p.get())) return zidl_concrete_handle(*_impl); ",
                            .{ ct, impl_name },
                        );
                        for (extra_impls.items) |e| {
                            try self.srcPrint(
                                "if (auto* _impl = dynamic_cast<{s}*>(_p.get())) return {s}; ",
                                .{ e.impl_name, e.cast_expr },
                            );
                        }
                        try self.srcPrint(
                            "throw std::invalid_argument(\"zidl: incompatible entity implementation for {s}\"); }})({s})",
                            .{ iface_name, p.name },
                        );
                    }
                },
                .listener_in => {
                    try self.srcPrint("_lp_{s}", .{p.name});
                },
                .todo => try self.srcPrint("/* TODO({s}) */", .{p.name}),
            }
        }
    }

    // ── Complex struct adaptation (C++ QoS in-params → C structs) ────────────

    fn emitComplexStructAdaptIn(
        self: *ConcreteImplGenerator,
        c_var: []const u8,
        cpp_src: []const u8,
        tr: ir.TypeRef,
        seq_ctr: *usize,
    ) anyerror!void {
        const s = switch (tr) {
            .named => |td| switch (td) {
                .struct_ => |s| s,
                else => return,
            },
            else => return,
        };
        const c_type = try cNameOf(self.alloc, s.qualified_name);
        defer self.alloc.free(c_type);
        try self.srcPrint("    {s} {s}{{}};\n", .{ c_type, c_var });
        for (s.members, 0..) |mem, idx| {
            const c_field = try std.fmt.allocPrint(self.alloc, "{s}.{s}", .{ c_var, mem.name });
            defer self.alloc.free(c_field);
            const cpp_field = try std.fmt.allocPrint(self.alloc, "{s}.{s}", .{ cpp_src, mem.name });
            defer self.alloc.free(cpp_field);
            try self.emitMemberAdaptIn(c_var, c_field, cpp_field, s, mem, idx, seq_ctr, "    ");
        }
    }

    fn emitMemberAdaptIn(
        self: *ConcreteImplGenerator,
        c_parent: []const u8,
        c_dst: []const u8,
        cpp_src: []const u8,
        s: *const ir.Struct,
        mem: ir.StructMember,
        idx: usize,
        seq_ctr: *usize,
        indent: []const u8,
    ) anyerror!void {
        if (!mem.annotations.is_optional) {
            return self.emitFieldAdaptIn(c_dst, cpp_src, mem.type_ref, seq_ctr, indent);
        }
        const bit_idx = optionalBitIndexCpp(s, idx);
        try self.srcPrint("{s}if ({s}.has_value()) {{\n", .{ indent, cpp_src });
        const deref = try std.fmt.allocPrint(self.alloc, "(*{s})", .{cpp_src});
        defer self.alloc.free(deref);
        const child_indent = try std.fmt.allocPrint(self.alloc, "{s}    ", .{indent});
        defer self.alloc.free(child_indent);
        try self.emitFieldAdaptIn(c_dst, deref, mem.type_ref, seq_ctr, child_indent);
        try self.srcPrint("{s}{s}._present |= (1ULL << {d}u);\n", .{ child_indent, c_parent, bit_idx });
        try self.srcPrint("{s}}}\n", .{indent});
    }

    fn emitFieldAdaptIn(
        self: *ConcreteImplGenerator,
        c_dst: []const u8,
        cpp_src: []const u8,
        tr: ir.TypeRef,
        seq_ctr: *usize,
        indent: []const u8,
    ) anyerror!void {
        switch (tr) {
            .base, .fixed_pt => try self.srcPrint("{s}{s} = {s};\n", .{ indent, c_dst, cpp_src }),
            .string => {
                try self.srcPrint("{s}// Borrowed string pointer; valid only for the duration of this C ABI call.\n", .{indent});
                try self.srcPrint("{s}{s} = const_cast<char*>({s}.c_str());\n", .{ indent, c_dst, cpp_src });
            },
            .sequence => |seq| try self.emitSeqFieldAdaptIn(c_dst, cpp_src, seq.element.*, seq_ctr, indent),
            .named => |td| switch (td) {
                .typedef => |t| if (t.dimensions.len == 0)
                    try self.emitFieldAdaptIn(c_dst, cpp_src, t.type_ref, seq_ctr, indent)
                else
                    try self.srcPrint("{s}/* TODO: array typedef for {s} */\n", .{ indent, c_dst }),
                .enum_, .bitmask, .bitset => {
                    const c_type = try cNameOf(self.alloc, ir.typeDeclQualifiedName(td));
                    defer self.alloc.free(c_type);
                    try self.srcPrint("{s}{s} = static_cast<{s}>({s});\n", .{ indent, c_dst, c_type, cpp_src });
                },
                .struct_ => |s| if (isSimpleStruct(s)) {
                    const c_type = try cNameOf(self.alloc, s.qualified_name);
                    defer self.alloc.free(c_type);
                    try self.srcPrint(
                        "{s}{s} = *reinterpret_cast<const {s}*>(&{s});\n",
                        .{ indent, c_dst, c_type, cpp_src },
                    );
                } else {
                    for (s.members, 0..) |mem, idx| {
                        const c_f = try std.fmt.allocPrint(self.alloc, "{s}.{s}", .{ c_dst, mem.name });
                        defer self.alloc.free(c_f);
                        const cpp_f = try std.fmt.allocPrint(self.alloc, "{s}.{s}", .{ cpp_src, mem.name });
                        defer self.alloc.free(cpp_f);
                        try self.emitMemberAdaptIn(c_dst, c_f, cpp_f, s, mem, idx, seq_ctr, indent);
                    }
                },
                else => try self.srcPrint("{s}/* TODO: adapt {s} */\n", .{ indent, c_dst }),
            },
            else => try self.srcPrint("{s}/* TODO: adapt {s} */\n", .{ indent, c_dst }),
        }
    }

    fn emitSeqFieldAdaptIn(
        self: *ConcreteImplGenerator,
        c_dst: []const u8,
        cpp_src: []const u8,
        elem_tr: ir.TypeRef,
        seq_ctr: *usize,
        indent: []const u8,
    ) anyerror!void {
        switch (elem_tr) {
            .string => {
                seq_ctr.* += 1;
                const tmp = try std.fmt.allocPrint(self.alloc, "_ptrs_{d}", .{seq_ctr.*});
                defer self.alloc.free(tmp);
                try self.srcPrint("{s}std::vector<const char*> {s};\n", .{ indent, tmp });
                try self.srcPrint("{s}{s}.reserve({s}.size());\n", .{ indent, tmp, cpp_src });
                try self.srcPrint("{s}for (const auto& _s : {s}) {s}.push_back(_s.c_str());\n", .{ indent, cpp_src, tmp });
                try self.srcPrint("{s}// Borrowed string pointer array; valid only for the duration of this C ABI call.\n", .{indent});
                try self.srcPrint("{s}{s}._buffer = const_cast<char**>({s}.data());\n", .{ indent, c_dst, tmp });
                try self.srcPrint("{s}{s}._length = static_cast<int32_t>({s}.size());\n", .{ indent, c_dst, tmp });
                try self.srcPrint("{s}{s}._maximum = static_cast<int32_t>({s}.size());\n", .{ indent, c_dst, tmp });
                return;
            },
            .named => |td| switch (td) {
                .typedef => |t| if (t.dimensions.len == 0) switch (t.type_ref) {
                    // Nested sequence element (e.g. `sequence<octet_seq>`): build a
                    // temporary std::vector<{InnerCType}>, one inner C sequence
                    // struct per outer C++ element, recursing so each inner
                    // element is marshaled the same way a top-level sequence
                    // param would be -- correct at arbitrary nesting depth, not
                    // just one level. Every buffer borrows into `cpp_src`'s own
                    // storage (or a temporary this same call creates), valid only
                    // for the duration of this C ABI call, same as every other
                    // case in this function.
                    .sequence => |inner_seq| {
                        const inner_c_type = try cNameOf(self.alloc, t.qualified_name);
                        defer self.alloc.free(inner_c_type);
                        seq_ctr.* += 1;
                        const n = seq_ctr.*;
                        const tmp = try std.fmt.allocPrint(self.alloc, "_nested_{d}", .{n});
                        defer self.alloc.free(tmp);
                        try self.srcPrint("{s}std::vector<{s}> {s}({s}.size());\n", .{ indent, inner_c_type, tmp, cpp_src });
                        try self.srcPrint("{s}for (size_t _j_{d} = 0; _j_{d} < {s}.size(); ++_j_{d}) {{\n", .{ indent, n, n, cpp_src, n });
                        const inner_indent = try std.fmt.allocPrint(self.alloc, "{s}    ", .{indent});
                        defer self.alloc.free(inner_indent);
                        const inner_c_elem = try std.fmt.allocPrint(self.alloc, "{s}[_j_{d}]", .{ tmp, n });
                        defer self.alloc.free(inner_c_elem);
                        const inner_cpp_elem = try std.fmt.allocPrint(self.alloc, "{s}[_j_{d}]", .{ cpp_src, n });
                        defer self.alloc.free(inner_cpp_elem);
                        try self.emitSeqFieldAdaptIn(inner_c_elem, inner_cpp_elem, inner_seq.element.*, seq_ctr, inner_indent);
                        try self.srcPrint("{s}}}\n", .{indent});
                        try self.srcPrint("{s}// Borrowed sequence buffer; valid only for the duration of this C ABI call.\n", .{indent});
                        try self.srcPrint("{s}{s}._buffer = {s}.data();\n", .{ indent, c_dst, tmp });
                        try self.srcPrint("{s}{s}._length = static_cast<int32_t>({s}.size());\n", .{ indent, c_dst, tmp });
                        try self.srcPrint("{s}{s}._maximum = static_cast<int32_t>({s}.size());\n", .{ indent, c_dst, tmp });
                        return;
                    },
                    else => {}, // typedef to non-sequence: fall through to the fallback below (existing behavior).
                },
                .struct_ => |s| if (isSimpleStruct(s)) {
                    const cpp_type = try std.fmt.allocPrint(self.alloc, "::{s}", .{s.qualified_name});
                    defer self.alloc.free(cpp_type);
                    const c_type = try cNameOf(self.alloc, s.qualified_name);
                    defer self.alloc.free(c_type);
                    try self.srcPrint("{s}// Borrowed sequence buffer; valid only for the duration of this C ABI call.\n", .{indent});
                    try self.srcPrint(
                        "{s}{s}._buffer = reinterpret_cast<{s}*>(const_cast<{s}*>({s}.data()));\n",
                        .{ indent, c_dst, c_type, cpp_type, cpp_src },
                    );
                    try self.srcPrint("{s}{s}._length = static_cast<int32_t>({s}.size());\n", .{ indent, c_dst, cpp_src });
                    try self.srcPrint("{s}{s}._maximum = static_cast<int32_t>({s}.size());\n", .{ indent, c_dst, cpp_src });
                    return;
                },
                .interface => |iface| if (!isCallbackIface(iface)) {
                    seq_ctr.* += 1;
                    const tmp = try std.fmt.allocPrint(self.alloc, "_handles_{d}", .{seq_ctr.*});
                    defer self.alloc.free(tmp);
                    const c_type = try cNameOf(self.alloc, iface.qualified_name);
                    defer self.alloc.free(c_type);
                    const impl_name = try self.entityImplName(elem_tr);
                    defer self.alloc.free(impl_name);
                    try self.srcPrint("{s}std::vector<{s}> {s};\n", .{ indent, c_type, tmp });
                    try self.srcPrint("{s}{s}.reserve({s}.size());\n", .{ indent, tmp, cpp_src });
                    try self.srcPrint("{s}for (const auto& _e : {s}) {{\n", .{ indent, cpp_src });
                    try self.srcPrint(
                        "{s}    if (auto* _impl = dynamic_cast<{s}*>(_e.get())) {s}.push_back(zidl_concrete_handle(*_impl));\n",
                        .{ indent, impl_name, tmp },
                    );
                    try self.srcPrint(
                        "{s}    else throw std::invalid_argument(\"zidl: incompatible entity implementation for {s}\");\n",
                        .{ indent, iface.qualified_name },
                    );
                    try self.srcPrint("{s}}}\n", .{indent});
                    try self.srcPrint("{s}// Borrowed sequence buffer; valid only for the duration of this C ABI call.\n", .{indent});
                    try self.srcPrint("{s}{s}._buffer = {s}.data();\n", .{ indent, c_dst, tmp });
                    try self.srcPrint("{s}{s}._length = static_cast<int32_t>({s}.size());\n", .{ indent, c_dst, tmp });
                    try self.srcPrint("{s}{s}._maximum = static_cast<int32_t>({s}.size());\n", .{ indent, c_dst, tmp });
                    return;
                },
                else => {},
            },
            else => {},
        }
        const cpp_elem_type = try cppTypeStr(self.alloc, self.opts, elem_tr);
        defer self.alloc.free(cpp_elem_type);
        try self.srcPrint("{s}// Borrowed sequence buffer; valid only for the duration of this C ABI call.\n", .{indent});
        try self.srcPrint(
            "{s}{s}._buffer = const_cast<{s}*>({s}.data());\n",
            .{ indent, c_dst, cpp_elem_type, cpp_src },
        );
        try self.srcPrint("{s}{s}._length = static_cast<int32_t>({s}.size());\n", .{ indent, c_dst, cpp_src });
        try self.srcPrint("{s}{s}._maximum = static_cast<int32_t>({s}.size());\n", .{ indent, c_dst, cpp_src });
    }

    /// Emit a C sequence local variable and fill it from a C++ vector param.
    /// Only callable when paramAdaptKind(p) == .seq_in.
    fn emitSeqParamAdaptIn(self: *ConcreteImplGenerator, p: ir.Parameter, seq_ctr: *usize) !void {
        // Walk typedef chain to find the nearest typedef-to-sequence.
        // Use that typedef's qualified name as the C type (e.g. DDS::StringSeq → DDS_StringSeq).
        var tr = p.type_ref;
        const c_type = while (true) {
            switch (tr) {
                .named => |td| switch (td) {
                    .typedef => |t| {
                        if (t.dimensions.len != 0) break null;
                        switch (t.type_ref) {
                            .sequence => break try cNameOf(self.alloc, t.qualified_name),
                            else => tr = t.type_ref,
                        }
                    },
                    else => break null,
                },
                else => break null,
            }
        };
        const elem = switch (tr) {
            .named => |td| switch (td) {
                .typedef => |t| t.type_ref.sequence.element.*,
                else => unreachable,
            },
            else => unreachable,
        };

        if (c_type == null) {
            // Bare (non-typedef) sequence — should not reach here via .seq_in
            try self.srcPrint("    /* TODO: unnamed seq param {s} */\n", .{p.name});
            return;
        }
        defer self.alloc.free(c_type.?);

        const c_var = try std.fmt.allocPrint(self.alloc, "_c_{s}", .{p.name});
        defer self.alloc.free(c_var);
        try self.srcPrint("    {s} {s}{{}};\n", .{ c_type.?, c_var });
        try self.emitSeqFieldAdaptIn(c_var, p.name, elem, seq_ctr, "    ");
    }

    // ── Complex struct adaptation (C out-params → C++ structs) ───────────────

    /// Copy a C out-param struct into the C++ reference, then free the C struct.
    /// `cpp_dst` is the C++ param name (e.g. "qos"); the C local is "_c_{cpp_dst}".
    fn emitComplexStructAdaptOut(
        self: *ConcreteImplGenerator,
        cpp_dst: []const u8,
        tr: ir.TypeRef,
        seq_ctr: *usize,
    ) anyerror!void {
        const s: *const ir.Struct = switch (tr) {
            .named => |td| switch (td) {
                .struct_ => |s| s,
                else => return,
            },
            else => return,
        };
        const c_var = try std.fmt.allocPrint(self.alloc, "_c_{s}", .{cpp_dst});
        defer self.alloc.free(c_var);
        for (s.members) |mem| {
            const c_field = try std.fmt.allocPrint(self.alloc, "{s}.{s}", .{ c_var, mem.name });
            defer self.alloc.free(c_field);
            const cpp_field = try std.fmt.allocPrint(self.alloc, "{s}.{s}", .{ cpp_dst, mem.name });
            defer self.alloc.free(cpp_field);
            try self.emitFieldAdaptOut(cpp_field, c_field, mem.type_ref, seq_ctr);
        }
        const c_type = try cNameOf(self.alloc, s.qualified_name);
        defer self.alloc.free(c_type);
        try self.srcPrint("    {s}_free(&{s});\n", .{ c_type, c_var });
    }

    fn emitFieldAdaptOut(
        self: *ConcreteImplGenerator,
        cpp_dst: []const u8,
        c_src: []const u8,
        tr: ir.TypeRef,
        seq_ctr: *usize,
    ) anyerror!void {
        switch (tr) {
            .base, .fixed_pt => try self.srcPrint("    {s} = {s};\n", .{ cpp_dst, c_src }),
            .string => try self.srcPrint(
                "    {s} = {s} ? {s}({s}) : {s}{{}};\n",
                .{ cpp_dst, c_src, stringTypeName(self.opts), c_src, stringTypeName(self.opts) },
            ),
            .sequence => |seq| try self.emitSeqFieldAdaptOut(cpp_dst, c_src, seq.element.*, seq_ctr),
            .named => |td| switch (td) {
                .typedef => |t| if (t.dimensions.len == 0)
                    try self.emitFieldAdaptOut(cpp_dst, c_src, t.type_ref, seq_ctr)
                else
                    try self.srcPrint("    /* TODO: array typedef for {s} */\n", .{cpp_dst}),
                .enum_, .bitmask, .bitset => {
                    const cpp_type = try std.fmt.allocPrint(
                        self.alloc,
                        "::{s}",
                        .{ir.typeDeclQualifiedName(td)},
                    );
                    defer self.alloc.free(cpp_type);
                    try self.srcPrint("    {s} = static_cast<{s}>({s});\n", .{ cpp_dst, cpp_type, c_src });
                },
                .struct_ => |s| if (isSimpleStruct(s)) {
                    const cpp_type = try std.fmt.allocPrint(self.alloc, "::{s}", .{s.qualified_name});
                    defer self.alloc.free(cpp_type);
                    try self.srcPrint(
                        "    {s} = *reinterpret_cast<const {s}*>(&{s});\n",
                        .{ cpp_dst, cpp_type, c_src },
                    );
                } else {
                    for (s.members) |mem| {
                        const c_f = try std.fmt.allocPrint(self.alloc, "{s}.{s}", .{ c_src, mem.name });
                        defer self.alloc.free(c_f);
                        const cpp_f = try std.fmt.allocPrint(self.alloc, "{s}.{s}", .{ cpp_dst, mem.name });
                        defer self.alloc.free(cpp_f);
                        try self.emitFieldAdaptOut(cpp_f, c_f, mem.type_ref, seq_ctr);
                    }
                },
                else => try self.srcPrint("    /* TODO: adapt out {s} */\n", .{cpp_dst}),
            },
            else => try self.srcPrint("    /* TODO: adapt out {s} */\n", .{cpp_dst}),
        }
    }

    fn emitSeqFieldAdaptOut(
        self: *ConcreteImplGenerator,
        cpp_dst: []const u8,
        c_src: []const u8,
        elem_tr: ir.TypeRef,
        seq_ctr: *usize,
    ) anyerror!void {
        switch (elem_tr) {
            .string => {
                try self.srcPrint("    {s}.clear();\n", .{cpp_dst});
                try self.srcPrint("    for (int32_t _i = 0; _i < {s}._length; ++_i)\n", .{c_src});
                try self.srcPrint(
                    "        {s}.emplace_back({s}._buffer[_i] ? {s}._buffer[_i] : \"\");\n",
                    .{ cpp_dst, c_src, c_src },
                );
                return;
            },
            .named => |td| switch (td) {
                .typedef => |t| if (t.dimensions.len == 0) switch (t.type_ref) {
                    // Nested sequence element (e.g. `sequence<octet_seq>`): for
                    // each inner C sequence struct in the C outer array, build
                    // the corresponding C++ inner container by recursing —
                    // mirrors emitSeqFieldAdaptIn's nested case, correct at
                    // arbitrary depth. The C-side cleanup (freeing the nested
                    // buffers) is handled by the existing `{c_type}_free()` call
                    // in emitSeqParamAdaptOut/emitComplexStructAdaptOut, which
                    // already recurses correctly into nested sequence fields
                    // (proven by the C backend's own nested-sequence-free test)
                    // — nothing extra needed here.
                    .sequence => {
                        const inner_cpp_type = try cppTypeStr(self.alloc, self.opts, elem_tr);
                        defer self.alloc.free(inner_cpp_type);
                        seq_ctr.* += 1;
                        const n = seq_ctr.*;
                        const local = try std.fmt.allocPrint(self.alloc, "_elem_{d}", .{n});
                        defer self.alloc.free(local);
                        const c_elem = try std.fmt.allocPrint(self.alloc, "{s}._buffer[_k_{d}]", .{ c_src, n });
                        defer self.alloc.free(c_elem);
                        try self.srcPrint("    {s}.clear();\n", .{cpp_dst});
                        try self.srcPrint("    if ({s}._buffer) {{\n", .{c_src});
                        try self.srcPrint("        {s}.reserve({s}._length);\n", .{ cpp_dst, c_src });
                        try self.srcPrint("        for (int32_t _k_{d} = 0; _k_{d} < {s}._length; ++_k_{d}) {{\n", .{ n, n, c_src, n });
                        try self.srcPrint("            {s} {s}{{}};\n", .{ inner_cpp_type, local });
                        try self.emitFieldAdaptOut(local, c_elem, elem_tr, seq_ctr);
                        try self.srcPrint("            {s}.push_back(std::move({s}));\n", .{ cpp_dst, local });
                        try self.srcWrite("        }\n");
                        try self.srcWrite("    }\n");
                        return;
                    },
                    else => {}, // typedef to non-sequence: fall through to the fallback below (existing behavior).
                },
                .struct_ => |s| if (isSimpleStruct(s)) {
                    const cpp_type = try std.fmt.allocPrint(self.alloc, "::{s}", .{s.qualified_name});
                    defer self.alloc.free(cpp_type);
                    try self.srcPrint("    if ({s}._buffer)\n", .{c_src});
                    try self.srcPrint(
                        "        {s}.assign(reinterpret_cast<const {s}*>({s}._buffer), reinterpret_cast<const {s}*>({s}._buffer) + {s}._length);\n",
                        .{ cpp_dst, cpp_type, c_src, cpp_type, c_src, c_src },
                    );
                    try self.srcPrint("    else\n        {s}.clear();\n", .{cpp_dst});
                    return;
                },
                .interface => |iface| if (!isCallbackIface(iface)) {
                    const impl_name = try self.entityImplName(elem_tr);
                    defer self.alloc.free(impl_name);
                    try self.markWrapped(elem_tr);
                    try self.srcPrint("    {s}.clear();\n", .{cpp_dst});
                    try self.srcPrint("    if ({s}._buffer) {{\n", .{c_src});
                    try self.srcPrint("        {s}.reserve({s}._length);\n", .{ cpp_dst, c_src });
                    try self.srcPrint("        for (int32_t _i = 0; _i < {s}._length; ++_i)\n", .{c_src});
                    try self.srcPrint(
                        "            {s}.push_back({s}::_getOrCreate({s}._buffer[_i]));\n",
                        .{ cpp_dst, impl_name, c_src },
                    );
                    try self.srcWrite("    }\n");
                    return;
                },
                else => {},
            },
            else => {},
        }
        // Fallback: base/enum-like elements (existing behaviour, unchanged).
        try self.srcPrint("    if ({s}._buffer)\n", .{c_src});
        try self.srcPrint(
            "        {s}.assign({s}._buffer, {s}._buffer + {s}._length);\n",
            .{ cpp_dst, c_src, c_src, c_src },
        );
        try self.srcPrint("    else\n        {s}.clear();\n", .{cpp_dst});
    }

    /// Copy a C sequence out-param into the C++ reference, then free the C buffer.
    /// Only callable when paramAdaptKind(p) == .seq_out.
    fn emitSeqParamAdaptOut(self: *ConcreteImplGenerator, p: ir.Parameter, seq_ctr: *usize) !void {
        var tr = p.type_ref;
        const c_type = while (true) {
            switch (tr) {
                .named => |td| switch (td) {
                    .typedef => |t| {
                        if (t.dimensions.len != 0) break null;
                        switch (t.type_ref) {
                            .sequence => break try cNameOf(self.alloc, t.qualified_name),
                            else => tr = t.type_ref,
                        }
                    },
                    else => break null,
                },
                else => break null,
            }
        };
        const elem = switch (tr) {
            .named => |td| switch (td) {
                .typedef => |t| t.type_ref.sequence.element.*,
                else => unreachable,
            },
            else => unreachable,
        };
        if (c_type == null) {
            try self.srcPrint("    /* TODO: unnamed seq param out {s} */\n", .{p.name});
            return;
        }
        defer self.alloc.free(c_type.?);
        const c_var = try std.fmt.allocPrint(self.alloc, "_c_{s}", .{p.name});
        defer self.alloc.free(c_var);
        try self.emitSeqFieldAdaptOut(p.name, c_var, elem, seq_ctr);
        try self.srcPrint("    {s}_free(&{s});\n", .{ c_type.?, c_var });
    }

    // ── Listener bridge implementations (source) ──────────────────────────────

    fn emitListenerBridgeMethods(self: *ConcreteImplGenerator, _ns: []const u8, iface: *const ir.Interface) !void {
        _ = _ns;
        const c_name = try cNameOf(self.alloc, iface.qualified_name);
        defer self.alloc.free(c_name);

        var ops = std.ArrayListUnmanaged(ir.Operation).empty;
        defer ops.deinit(self.alloc);
        var attrs = std.ArrayListUnmanaged(ir.Attribute).empty;
        defer attrs.deinit(self.alloc);
        try collectIfaceMembers(self.alloc, iface, &ops, &attrs);

        try self.srcPrint("// \u{2500}\u{2500} {s}Base \u{2500}\u{2500}\n\n", .{iface.name});

        // c_listener() implementation
        try self.srcPrint("{s} {s}Base::c_listener() noexcept {{\n    return {{this", .{ c_name, iface.name });
        for (ops.items) |op| {
            try self.srcPrint(", s_{s}", .{op.name});
        }
        try self.srcWrite("};\n}\n\n");

        // Trampoline static implementations
        for (ops.items) |op| {
            try self.srcPrint("void {s}Base::s_{s}(", .{ iface.name, op.name });
            for (op.params, 0..) |p, i| {
                if (i > 0) try self.srcWrite(", ");
                const ct = try self.paramToCType(p);
                defer self.alloc.free(ct);
                try self.srcPrint("{s} {s}", .{ ct, p.name });
            }
            if (op.params.len > 0) try self.srcWrite(", ");
            try self.srcWrite("void* d) {\n");
            try self.srcPrint("    static_cast<{s}Base*>(d)->{s}(", .{ iface.name, op.name });
            for (op.params, 0..) |p, i| {
                if (i > 0) try self.srcWrite(", ");
                switch (p.type_ref) {
                    .named => |td| switch (td) {
                        .interface => |piface| {
                            if (!isCallbackIface(piface)) {
                                // Wrap entity handle in Impl, reusing the cached
                                // wrapper if one exists (see _getOrCreate).
                                // Must use the fully-qualified entityImplName, not a
                                // bare "{name}Impl" — this trampoline is emitted inside
                                // the *listener's own* namespace, which for a
                                // cross-module @callback interface (e.g. zzdds's
                                // DataWriterListenerEx : DDS::DataWriterListener)
                                // flattens in operations whose entity parameter belongs
                                // to a *different* module than the listener itself. A
                                // bare name would resolve to whatever same-named Impl
                                // class happens to be in scope in the listener's own
                                // namespace (e.g. zzdds::DataWriterImpl) instead of the
                                // one the flattened parameter's type actually names
                                // (::DDS::DataWriterImpl) — silently wrapping the wrong
                                // class and failing to compile (constructing a
                                // zzdds-side Impl from a DDS-side C handle).
                                const impl_name = try self.entityImplName(p.type_ref);
                                defer self.alloc.free(impl_name);
                                try self.markWrapped(p.type_ref);
                                try self.srcPrint("{s}::_getOrCreate({s})", .{ impl_name, p.name });
                            } else {
                                try self.srcPrint("/* TODO({s}) */ {s}", .{ p.name, p.name });
                            }
                        },
                        else => {
                            if (typeRefIsCScalar(p.type_ref)) {
                                // Matches paramToCTypeStr's by-value signature for
                                // this same case (a typedef of a primitive, or
                                // enum/bitmask/bitset) — passed straight through,
                                // no dereference, no cast needed.
                                try self.srcWrite(p.name);
                            } else {
                                // status structs: reinterpret_cast to C++ type
                                const cpp_t = try self.typeRefToCpp(p.type_ref);
                                defer self.alloc.free(cpp_t);
                                try self.srcPrint("reinterpret_cast<const ::{s}&>(*{s})", .{ cpp_t[2..], p.name });
                            }
                        },
                    },
                    .base => try self.srcWrite(p.name),
                    else => try self.srcPrint("/* TODO({s}) */ {s}", .{ p.name, p.name }),
                }
            }
            try self.srcWrite(");\n}\n\n");
        }
    }

    // ── Type helpers ──────────────────────────────────────────────────────────

    fn typeRefToCpp(self: *ConcreteImplGenerator, tr: ir.TypeRef) ![]u8 {
        return switch (tr) {
            .base => |b| self.alloc.dupe(u8, baseToCppType(b)),
            .named => |td| switch (td) {
                .interface => |iface| std.fmt.allocPrint(
                    self.alloc,
                    "std::shared_ptr<::{s}>",
                    .{iface.qualified_name},
                ),
                else => std.fmt.allocPrint(self.alloc, "::{s}", .{ir.typeDeclQualifiedName(td)}),
            },
            .sequence => |seq| blk: {
                const elem = try self.typeRefToCpp(seq.element.*);
                defer self.alloc.free(elem);
                break :blk std.fmt.allocPrint(self.alloc, "{s}<{s}>", .{ vectorTypeName(self.opts), elem });
            },
            .string => self.alloc.dupe(u8, stringTypeName(self.opts)),
            .wstring => self.alloc.dupe(u8, wstringTypeName(self.opts)),
            .fixed_pt => self.alloc.dupe(u8, "double"),
            .map => |m| blk: {
                const ks = try self.typeRefToCpp(m.key.*);
                defer self.alloc.free(ks);
                const vs = try self.typeRefToCpp(m.value.*);
                defer self.alloc.free(vs);
                break :blk std.fmt.allocPrint(self.alloc, "{s}<{s}, {s}>", .{ mapTypeName(self.opts), ks, vs });
            },
        };
    }

    fn typeRefToCType(self: *ConcreteImplGenerator, tr: ir.TypeRef) ![]u8 {
        return switch (tr) {
            .named => |td| cNameOf(self.alloc, ir.typeDeclQualifiedName(td)),
            else => self.alloc.dupe(u8, "void*"),
        };
    }

    /// C type string for a listener callback struct, e.g. DDS_DataWriterListener
    fn listenerCType(self: *ConcreteImplGenerator, tr: ir.TypeRef) ![]u8 {
        return switch (tr) {
            .named => |td| cNameOf(self.alloc, ir.typeDeclQualifiedName(td)),
            else => self.alloc.dupe(u8, "void*"),
        };
    }

    /// Base class name for a listener, e.g. DataWriterListenerBase
    fn listenerBridgeName(self: *ConcreteImplGenerator, tr: ir.TypeRef) ![]u8 {
        return switch (tr) {
            .named => |td| switch (td) {
                .interface => |iface| std.fmt.allocPrint(self.alloc, "::{s}Base", .{iface.qualified_name}),
                else => self.alloc.dupe(u8, "Base"),
            },
            else => self.alloc.dupe(u8, "Base"),
        };
    }

    /// Impl class name for an entity, e.g. PublisherImpl
    fn entityImplName(self: *ConcreteImplGenerator, tr: ir.TypeRef) ![]u8 {
        return switch (tr) {
            .named => |td| switch (td) {
                .interface => |iface| {
                    if (self.cppImplOverride(iface.qualified_name)) |override_class| {
                        return self.alloc.dupe(u8, override_class);
                    }
                    return std.fmt.allocPrint(self.alloc, "::{s}Impl", .{iface.qualified_name});
                },
                else => self.alloc.dupe(u8, "EntityImpl"),
            },
            else => self.alloc.dupe(u8, "EntityImpl"),
        };
    }

    /// `--cpp-impl-override <Interface>=<Class>` lookup: returns `<Class>`
    /// (unparsed, as given on the command line -- e.g. `::zzdds::DataWriterImpl`,
    /// caller-supplied qualification, not re-derived) when `qualified_name`
    /// matches `<Interface>` exactly, else null. Every call site that would
    /// otherwise name the mechanical default impl class -- construction
    /// (`_getOrCreate`) and parameter-adaptation `dynamic_cast` alike --
    /// routes through `entityImplName`, so one override covers both without
    /// needing a separate fallback/dual-cast at the adaptation sites: nothing
    /// constructs the default class anymore once it's overridden, so nothing
    /// needs to `dynamic_cast` against it either.
    fn cppImplOverride(self: *ConcreteImplGenerator, qualified_name: []const u8) ?[]const u8 {
        for (self.opts.cpp_impl_overrides) |entry| {
            const eq = std.mem.indexOf(u8, entry, "=") orelse continue;
            if (std.mem.eql(u8, entry[0..eq], qualified_name)) return entry[eq + 1 ..];
        }
        return null;
    }

    /// Record that `tr` (an entity interface type) is wrapped via
    /// _getOrCreate somewhere in the spec — see `wrapped_entities`'s doc
    /// comment and the pre-scan pass in `emit()`. No-op for anything that
    /// isn't a named interface type.
    fn markWrapped(self: *ConcreteImplGenerator, tr: ir.TypeRef) !void {
        switch (tr) {
            .named => |td| switch (td) {
                .interface => |iface| try self.wrapped_entities.put(self.alloc, iface.qualified_name, {}),
                else => {},
            },
            else => {},
        }
    }

    // Thin wrappers so ConcreteImplGenerator's existing call sites don't need
    // to thread `&self.entity_base_ifaces` through by hand -- see
    // ifaceOwnsNativeHandle/nativeHandleBaseFor (below) for the real logic,
    // shared with Generator's abstract-header emission.
    fn ifaceDeclaresNativeHandle(self: *ConcreteImplGenerator, iface: *const ir.Interface) bool {
        return ifaceOwnsNativeHandle(&self.entity_base_ifaces, iface);
    }

    fn nativeHandleBase(self: *ConcreteImplGenerator, iface: *const ir.Interface) !?*const ir.Interface {
        return nativeHandleBaseFor(&self.entity_base_ifaces, iface);
    }

    fn handleExprForOwner(
        self: *ConcreteImplGenerator,
        from: *const ir.Interface,
        to: *const ir.Interface,
        expr: []const u8,
    ) ![]u8 {
        if (std.mem.eql(u8, from.qualified_name, to.qualified_name)) {
            return self.alloc.dupe(u8, expr);
        }
        for (from.bases) |base| {
            if (base != .interface) continue;
            const base_iface = base.interface;
            if (!interfaceContains(base_iface, to)) continue;
            const from_c = try cNameOf(self.alloc, from.qualified_name);
            defer self.alloc.free(from_c);
            const base_c = try cNameOf(self.alloc, base_iface.qualified_name);
            defer self.alloc.free(base_c);
            const next_expr = try std.fmt.allocPrint(
                self.alloc,
                "{s}_as_{s}({s})",
                .{ from_c, base_c, expr },
            );
            if (std.mem.eql(u8, base_iface.qualified_name, to.qualified_name)) {
                return next_expr;
            }
            defer self.alloc.free(next_expr);
            return self.handleExprForOwner(base_iface, to, next_expr);
        }
        return error.InterfaceCastPathNotFound;
    }

    /// C type name for a struct param (for reinterpret_cast), e.g. DDS_PublisherQos
    fn structCType(self: *ConcreteImplGenerator, tr: ir.TypeRef) ![]u8 {
        return switch (tr) {
            .named => |td| cNameOf(self.alloc, ir.typeDeclQualifiedName(td)),
            else => self.alloc.dupe(u8, "void"),
        };
    }

    /// C type for a trampoline parameter (for static callback decls and impls).
    fn paramToCType(self: *ConcreteImplGenerator, p: ir.Parameter) ![]u8 {
        return paramToCTypeStr(self.alloc, p);
    }

    fn opSignature(self: *ConcreteImplGenerator, op: *const ir.Operation) ![]u8 {
        var buf: std.ArrayListUnmanaged(u8) = .empty;
        defer buf.deinit(self.alloc);

        const ret = if (op.return_type) |rt| try self.typeRefToCpp(rt) else try self.alloc.dupe(u8, "void");
        defer self.alloc.free(ret);
        try buf.appendSlice(self.alloc, ret);
        try buf.append(self.alloc, ' ');
        try buf.appendSlice(self.alloc, op.name);
        try buf.append(self.alloc, '(');

        for (op.params, 0..) |p, i| {
            if (i > 0) try buf.appendSlice(self.alloc, ", ");
            const pt = try self.typeRefToCpp(p.type_ref);
            defer self.alloc.free(pt);
            try buf.appendSlice(self.alloc, pt);
            switch (p.mode) {
                .in_ => {},
                .out, .inout => try buf.append(self.alloc, '&'),
            }
            try buf.append(self.alloc, ' ');
            try buf.appendSlice(self.alloc, p.name);
        }
        try buf.append(self.alloc, ')');
        return buf.toOwnedSlice(self.alloc);
    }

    // ── Adaptation classification ─────────────────────────────────────────────

    fn opIsAdaptable(self: *ConcreteImplGenerator, op: *const ir.Operation) bool {
        _ = self;
        for (op.params) |p| {
            if (paramAdaptKind(p) == .todo) return false;
        }
        return returnAdaptKind(op.return_type) != .todo;
    }
};

const AdaptKind = enum { direct, str_in, struct_in, struct_inout, complex_struct_in, seq_in, complex_struct_out, seq_out, entity_in, listener_in, todo };
const RetAdaptKind = enum { direct, entity, str_ret, todo };

fn paramAdaptKind(p: ir.Parameter) AdaptKind {
    return paramAdaptKindForTypeRef(p.type_ref, p.mode);
}

fn paramAdaptKindForTypeRef(tr: ir.TypeRef, mode: ir.ParamMode) AdaptKind {
    return switch (tr) {
        .base => .direct,
        .fixed_pt => .direct,
        .string => if (mode == .in_) .str_in else .todo,
        .wstring, .map => .todo,
        .sequence => .todo, // bare (non-typedef) sequence: no C typedef name available
        .named => |td| switch (td) {
            .typedef => |t| if (t.dimensions.len == 0) switch (t.type_ref) {
                // Intercept before recursing: typedef-to-sequence gets .seq_in / .seq_out
                .sequence => |seq| if (isAdaptableSeqElemIn(seq.element.*))
                    (if (mode == .in_) .seq_in else .seq_out)
                else
                    .todo,
                else => paramAdaptKindForTypeRef(t.type_ref, mode),
            } else .todo,
            .enum_, .bitmask, .bitset => .direct,
            .struct_ => |s| if (mode == .in_)
                (if (isSimpleStruct(s)) .struct_in else if (isAdaptableStructIn(s)) .complex_struct_in else .todo)
            else
                // .out and .inout both treated as out-direction for complex structs.
                // DDS convention uses `inout` for get_qos (purely writes the param).
                (if (isSimpleStruct(s)) .struct_inout else if (isAdaptableStructIn(s)) .complex_struct_out else .todo),
            .interface => |iface| if (isCallbackIface(iface))
                (if (mode == .in_) .listener_in else .todo)
            else
                (if (mode == .in_) .entity_in else .todo),
            else => .todo,
        },
    };
}

fn returnAdaptKind(rt: ?ir.TypeRef) RetAdaptKind {
    const tr = rt orelse return .direct; // void
    return switch (tr) {
        .base => .direct,
        .fixed_pt => .direct,
        .string => .str_ret,
        .wstring, .sequence, .map => .todo,
        .named => |td| switch (td) {
            .typedef => |t| if (t.dimensions.len == 0) returnAdaptKind(t.type_ref) else .todo,
            .enum_, .bitmask, .bitset => .direct,
            .struct_ => .todo,
            .interface => |iface| if (isCallbackIface(iface)) .todo else .entity,
            else => .todo,
        },
    };
}

fn typeRefIsEnumLike(tr: ir.TypeRef) bool {
    return switch (tr) {
        .named => |td| switch (td) {
            .typedef => |t| t.dimensions.len == 0 and typeRefIsEnumLike(t.type_ref),
            .enum_, .bitmask, .bitset => true,
            else => false,
        },
        else => false,
    };
}

fn optionalBitIndexCpp(s: *const ir.Struct, member_idx: usize) usize {
    var bit_idx: usize = 0;
    for (s.members[0..member_idx]) |m| {
        if (m.annotations.is_optional) bit_idx += 1;
    }
    return bit_idx;
}

fn isSimpleTypeRef(tr: ir.TypeRef) bool {
    return switch (tr) {
        .base, .fixed_pt => true,
        .named => |td| switch (td) {
            .typedef => |t| t.dimensions.len == 0 and isSimpleTypeRef(t.type_ref),
            .enum_, .bitmask, .bitset => true,
            .struct_ => |s| isSimpleStruct(s),
            else => false,
        },
        else => false,
    };
}

fn isSimpleStruct(s: *const ir.Struct) bool {
    for (s.members) |m| {
        // @optional wraps the C++ field in std::optional<T>, which is not
        // layout-compatible with the C struct's bare T — reinterpret_cast would
        // read/write the wrong bytes.
        if (m.annotations.is_optional) return false;
        if (!isSimpleTypeRef(m.type_ref)) return false;
    }
    return true;
}

fn isAdaptableSeqElemIn(tr: ir.TypeRef) bool {
    return switch (tr) {
        .base => true,
        .string => true,
        .sequence => |seq| isAdaptableSeqElemIn(seq.element.*),
        .named => |td| switch (td) {
            .typedef => |t| t.dimensions.len == 0 and isAdaptableSeqElemIn(t.type_ref),
            .enum_, .bitmask, .bitset => true,
            .struct_ => |s| isSimpleStruct(s),
            .interface => |iface| !isCallbackIface(iface),
            else => false,
        },
        else => false,
    };
}

fn isAdaptableTypeRefIn(tr: ir.TypeRef) bool {
    return switch (tr) {
        .base, .fixed_pt => true,
        .string => true,
        .sequence => |seq| isAdaptableSeqElemIn(seq.element.*),
        .named => |td| switch (td) {
            .typedef => |t| t.dimensions.len == 0 and isAdaptableTypeRefIn(t.type_ref),
            .enum_, .bitmask, .bitset => true,
            .struct_ => |s| isAdaptableStructIn(s),
            else => false,
        },
        else => false,
    };
}

fn isAdaptableStructIn(s: *const ir.Struct) bool {
    for (s.members) |m| {
        if (!isAdaptableTypeRefIn(m.type_ref)) return false;
    }
    return true;
}

fn hasNativeHandleInterfaces(
    items: []const ir.ModuleItem,
    base_names: *const std.StringHashMapUnmanaged(void),
) bool {
    for (items) |item| {
        switch (item) {
            .module => |m| if (hasNativeHandleInterfaces(m.items, base_names)) return true,
            .type_decl => |td| switch (td) {
                .interface => |iface| {
                    if (!isCallbackIface(iface) and
                        !base_names.contains(iface.qualified_name) and
                        std.mem.indexOfScalar(u8, iface.qualified_name, ':') != null)
                        return true;
                },
                else => {},
            },
            else => {},
        }
    }
    return false;
}

fn hasCallbackInterfaces(items: []const ir.ModuleItem) bool {
    for (items) |item| {
        switch (item) {
            .module => |m| if (hasCallbackInterfaces(m.items)) return true,
            .type_decl => |td| switch (td) {
                .interface => |iface| if (isCallbackIface(iface)) return true,
                else => {},
            },
            else => {},
        }
    }
    return false;
}

/// C type string for a listener trampoline parameter.
fn paramToCTypeStr(alloc: std.mem.Allocator, p: ir.Parameter) ![]u8 {
    return switch (p.type_ref) {
        .base => |b| alloc.dupe(u8, baseToCType(b)),
        .string => alloc.dupe(u8, "const char*"),
        .named => |td| switch (td) {
            .interface => |iface| blk: {
                if (isCallbackIface(iface)) {
                    const cn = try cNameOf(alloc, iface.qualified_name);
                    defer alloc.free(cn);
                    break :blk std.fmt.allocPrint(alloc, "const {s}*", .{cn});
                } else {
                    break :blk cNameOf(alloc, iface.qualified_name);
                }
            },
            else => blk: {
                const cn = try cNameOf(alloc, ir.typeDeclQualifiedName(td));
                defer alloc.free(cn);
                break :blk switch (p.mode) {
                    // Scalars (a typedef of a primitive, or enum/bitmask/bitset) pass
                    // by value, matching the C backend's isCPrimitive convention
                    // (src/backend/c.zig) for the same operation's listener callback
                    // struct field — e.g. `typedef long InstanceHandle_t` must emit
                    // the same by-value signature here as `zzdds.h`'s
                    // `void (*on_foo)(DDS_InstanceHandle_t handle, ...)`, or the C++
                    // trampoline's static function pointer no longer matches the C
                    // struct field type it's assigned to. `out`/`inout` always pass
                    // by pointer regardless (a scalar out-param still needs a
                    // pointer to write through).
                    .in_ => if (typeRefIsCScalar(p.type_ref))
                        alloc.dupe(u8, cn)
                    else
                        std.fmt.allocPrint(alloc, "const {s}*", .{cn}),
                    else => std.fmt.allocPrint(alloc, "{s}*", .{cn}),
                };
            },
        },
        else => alloc.dupe(u8, "void*"),
    };
}

/// True when `tr` resolves, possibly through a chain of typedefs, to a C
/// scalar (primitive, enum, bitmask, bitset) rather than a struct/union.
/// Mirrors the C backend's `isCPrimitive` (src/backend/c.zig).
fn typeRefIsCScalar(tr: ir.TypeRef) bool {
    return switch (tr) {
        .base => true,
        .named => |td| switch (td) {
            .typedef => |t| typeRefIsCScalar(t.type_ref),
            .enum_, .bitmask, .bitset => true,
            else => false,
        },
        else => false,
    };
}

fn isCallbackIface(iface: *const ir.Interface) bool {
    return interface.isCallbackInterface(iface);
}

/// If `ops` contains a zero-param `get_listener` operation returning a `@callback`
/// interface, return that return type so the caller can emit a stash member for it.
fn listenerTypeOf(ops: []const OwnedOperation) ?ir.TypeRef {
    for (ops) |o| {
        if (o.op.params.len != 0) continue;
        if (!std.mem.eql(u8, o.op.name, "get_listener")) continue;
        const rt = o.op.return_type orelse continue;
        switch (rt) {
            .named => |td| switch (td) {
                .interface => |iface| if (isCallbackIface(iface)) return rt,
                else => {},
            },
            else => {},
        }
    }
    return null;
}

/// True when `op` is the `set_listener` half of a `listenerTypeOf` pair: a first
/// `in` parameter whose type is the same callback interface as `listener_qname`.
fn isListenerSetterParam(op: *const ir.Operation, listener_qname: []const u8) bool {
    if (!std.mem.eql(u8, op.name, "set_listener") or op.params.len == 0) return false;
    const p0 = op.params[0];
    if (p0.mode != .in_) return false;
    return switch (p0.type_ref) {
        .named => |td| switch (td) {
            .interface => |iface| std.mem.eql(u8, iface.qualified_name, listener_qname),
            else => false,
        },
        else => false,
    };
}

fn cNameOf(alloc: std.mem.Allocator, qname: []const u8) ![]u8 {
    return interface.prefixedCNameFromQualified(alloc, qname, "");
}

fn collectIfaceMembers(
    alloc: std.mem.Allocator,
    iface: *const ir.Interface,
    ops: *std.ArrayListUnmanaged(ir.Operation),
    attrs: *std.ArrayListUnmanaged(ir.Attribute),
) anyerror!void {
    for (iface.bases) |base| {
        if (base == .interface) try collectIfaceMembers(alloc, base.interface, ops, attrs);
    }
    try ops.appendSlice(alloc, iface.operations);
    try attrs.appendSlice(alloc, iface.attributes);
}

const OwnedOperation = struct {
    owner: *const ir.Interface,
    op: *const ir.Operation,
};

const OwnedAttribute = struct {
    owner: *const ir.Interface,
    attr: *const ir.Attribute,
};

fn collectOwnedIfaceMembers(
    alloc: std.mem.Allocator,
    iface: *const ir.Interface,
    ops: *std.ArrayListUnmanaged(OwnedOperation),
    attrs: *std.ArrayListUnmanaged(OwnedAttribute),
) anyerror!void {
    for (iface.bases) |base| {
        if (base == .interface) try collectOwnedIfaceMembers(alloc, base.interface, ops, attrs);
    }
    for (iface.operations) |*op| {
        try ops.append(alloc, .{ .owner = iface, .op = op });
    }
    for (iface.attributes) |*attr| {
        try attrs.append(alloc, .{ .owner = iface, .attr = attr });
    }
}

fn interfaceContains(iface: *const ir.Interface, target: *const ir.Interface) bool {
    if (std.mem.eql(u8, iface.qualified_name, target.qualified_name)) return true;
    for (iface.bases) |base| {
        if (base == .interface and interfaceContains(base.interface, target)) return true;
    }
    return false;
}

// An interface "owns" its own native_handle() unless it's a shared
// structural mixin used as a base by some other interface (entity_base_ifaces)
// -- e.g. Entity/TopicDescription/Condition, or ReadCondition (excluded so
// QueryCondition can own its own, more specific DDS_QueryCondition handle
// instead of inheriting ReadCondition's). bases.len is NOT the right test
// here: nearly every real entity (Topic, DataWriter, DomainParticipant, ...)
// has bases.len >= 1 purely because that's how IDL expresses "is-a Entity",
// which has nothing to do with whether it should own its own handle.
//
// Standalone (not a method) so both `Generator` (abstract header) and
// `ConcreteImplGenerator` (impl classes) can share the exact same decision --
// they must agree, or the header would declare one shape and the impl would
// try to satisfy a different one.
fn ifaceOwnsNativeHandle(entity_base_ifaces: *const std.StringHashMapUnmanaged(void), iface: *const ir.Interface) bool {
    return !isCallbackIface(iface) and
        std.mem.indexOfScalar(u8, iface.qualified_name, ':') != null and
        !entity_base_ifaces.contains(iface.qualified_name);
}

// Walks iface's bases looking for an ancestor that already owns a compatible
// native_handle() (directly, or transitively via its own qualifying
// ancestor), so iface can inherit-and-convert instead of declaring its own.
// Must be checked BEFORE `ifaceOwnsNativeHandle(iface)` itself: an interface
// can be simultaneously "not excluded" (so it WOULD own one on its own) and
// have an ancestor that already provides one (e.g.
// zzdds::DomainParticipantFactory : DDS::DomainParticipantFactory) -- in that
// case it must inherit and convert, not redeclare its own with a different,
// non-covariant return type (a hard C++ compile error: two same-named
// virtuals with incompatible return types).
fn nativeHandleBaseFor(entity_base_ifaces: *const std.StringHashMapUnmanaged(void), iface: *const ir.Interface) !?*const ir.Interface {
    var found: ?*const ir.Interface = null;
    for (iface.bases) |base| {
        if (base != .interface) continue;
        const base_iface = base.interface;
        const candidate = if (ifaceOwnsNativeHandle(entity_base_ifaces, base_iface) or
            importedLeafBaseDeclaresNativeHandle(iface, base_iface))
            base_iface
        else
            try nativeHandleBaseFor(entity_base_ifaces, base_iface);
        if (candidate) |decl_iface| {
            if (found) |existing| {
                if (!std.mem.eql(u8, existing.qualified_name, decl_iface.qualified_name)) {
                    return error.MultipleNativeHandleBases;
                }
            } else {
                found = decl_iface;
            }
        }
    }
    return found;
}

fn importedLeafBaseDeclaresNativeHandle(
    derived: *const ir.Interface,
    base: *const ir.Interface,
) bool {
    // The abstract header emits native_handle() for entity interfaces that own
    // their own handle in their own module (see ifaceDeclaresNativeHandle).
    // When an extension interface in a different root module inherits such an
    // interface (e.g. zzdds::Topic : DDS::Topic), nativeHandleBase must still
    // see the imported base's virtual handle even though the base is not part
    // of the current module's entity_base_ifaces scan.
    //
    // This trusts "different root module" alone as a proxy for "base owns its
    // own handle in its home file" -- there's no cross-file entity_base_ifaces
    // registry in this architecture to check directly. Safe for the real
    // dcps.idl/zzdds.idl pair (verified); if this assumption were ever wrong
    // for some future IDL, the failure mode is a loud C++ compile error
    // (mismatched `override`), not silent wrong behavior.
    return !isCallbackIface(base) and
        std.mem.indexOfScalar(u8, base.qualified_name, ':') != null and
        !std.mem.eql(u8, rootModuleName(derived.qualified_name), rootModuleName(base.qualified_name));
}

fn rootModuleName(qname: []const u8) []const u8 {
    if (std.mem.indexOf(u8, qname, "::")) |idx| return qname[0..idx];
    return qname;
}

// ── Interface impl generation ─────────────────────────────────────────────────

/// Generate the interface binding source file `<stem>_impl.cpp` into `out`.
///
/// For each IDL `interface`, emits:
///   - An `extern "C" { ... }` block declaring C ABI runtime exports
///   - A concrete `FooImpl : public ::Foo` subclass that forwards every
///     pure-virtual method to the corresponding C ABI export via `ptr_`
///
/// Method bodies perform direct forwarding for void returns and primitive
/// parameters.  Complex parameters / return types (std::string, std::vector,
/// named structs) emit `/* TODO */` stubs that still compile.
pub fn generateImplSource(
    alloc: std.mem.Allocator,
    spec: *const ir.Spec,
    opts: interface.Options,
    out: *std.ArrayList(u8),
) !void {
    var gen = ImplGenerator{ .alloc = alloc, .opts = opts, .out = out };
    try gen.emitSource(spec);
}

const ImplGenerator = struct {
    alloc: std.mem.Allocator,
    opts: interface.Options,
    out: *std.ArrayList(u8),

    fn write(self: *ImplGenerator, s: []const u8) !void {
        try self.out.appendSlice(self.alloc, s);
    }

    fn print(self: *ImplGenerator, comptime fmt: []const u8, args: anytype) !void {
        const s = try std.fmt.allocPrint(self.alloc, fmt, args);
        defer self.alloc.free(s);
        try self.out.appendSlice(self.alloc, s);
    }

    fn emitSource(self: *ImplGenerator, spec: *const ir.Spec) !void {
        try self.print(
            "// Generated by zidl from {s}.idl — DO NOT EDIT\n\n",
            .{self.opts.input_stem},
        );
        try self.print("#include \"{s}.hpp\"\n\n", .{self.opts.input_stem});
        try self.emitItems(spec.items);
    }

    fn emitItems(self: *ImplGenerator, items: []const ir.ModuleItem) anyerror!void {
        for (items) |item| {
            switch (item) {
                .module => |m| try self.emitItems(m.items),
                .type_decl => |td| switch (td) {
                    .interface => |iface| try self.emitIfaceImpl(iface),
                    else => {},
                },
                .const_ => {},
            }
        }
    }

    fn emitIfaceImpl(self: *ImplGenerator, iface: *const ir.Interface) !void {
        const qname = iface.qualified_name;

        var ops = std.ArrayListUnmanaged(ir.Operation).empty;
        defer ops.deinit(self.alloc);
        var attrs = std.ArrayListUnmanaged(ir.Attribute).empty;
        defer attrs.deinit(self.alloc);
        try self.collectInterfaceMembers(iface, &ops, &attrs);

        // Derive the C-flat name used for C ABI export symbols.
        const c_name = try self.prefixedCName(qname);
        defer self.alloc.free(c_name);

        try self.print("// ── interface {s} ──\n\n", .{c_name});

        // extern "C" declarations for C ABI runtime exports.
        try self.write("extern \"C\" {\n");
        for (ops.items) |op| try self.emitExternDecl(c_name, &op);
        for (attrs.items) |attr| try self.emitExternAttrDecls(c_name, &attr);
        try self.print("void zidl_{s}_deinit(void *ptr);\n", .{c_name});
        try self.write("}\n\n");

        // Concrete Impl subclass.
        try self.print("class {s}Impl : public ::{s} {{\n", .{ c_name, qname });
        try self.write("public:\n");
        try self.print(
            "    explicit {s}Impl(void *ptr) : ptr_(ptr) {{}}\n",
            .{c_name},
        );
        try self.print(
            "    ~{s}Impl() override {{ zidl_{s}_deinit(ptr_); }}\n\n",
            .{ c_name, c_name },
        );

        for (ops.items) |op| try self.emitImplOp(c_name, &op);
        for (attrs.items) |attr| try self.emitImplAttr(c_name, &attr);

        try self.write("private:\n    void *ptr_;\n};\n\n");
    }

    fn emitExternDecl(self: *ImplGenerator, c_name: []const u8, op: *const ir.Operation) !void {
        const ret_c = if (op.return_type) |rt|
            try self.typeRefToC(rt)
        else
            try self.alloc.dupe(u8, "void");
        defer self.alloc.free(ret_c);

        try self.print("{s} zidl_{s}_{s}(void *ptr", .{ ret_c, c_name, op.name });
        for (op.params) |p| {
            const pt = try self.paramTypeC(p);
            defer self.alloc.free(pt);
            try self.print(", {s} {s}", .{ pt, p.name });
        }
        try self.write(");\n");
    }

    fn emitExternAttrDecls(self: *ImplGenerator, c_name: []const u8, attr: *const ir.Attribute) !void {
        const at = try self.typeRefToC(attr.type_ref);
        defer self.alloc.free(at);
        try self.print("{s} zidl_{s}_get_{s}(void *ptr);\n", .{ at, c_name, attr.name });
        if (!attr.readonly) {
            try self.print(
                "void zidl_{s}_set_{s}(void *ptr, {s} value);\n",
                .{ c_name, attr.name, at },
            );
        }
    }

    fn emitImplOp(self: *ImplGenerator, c_name: []const u8, op: *const ir.Operation) !void {
        const ret_cpp = if (op.return_type) |rt|
            try self.typeRefToCpp(rt)
        else
            try self.alloc.dupe(u8, "void");
        defer self.alloc.free(ret_cpp);

        try self.print("    {s} {s}(", .{ ret_cpp, op.name });
        for (op.params, 0..) |p, i| {
            if (i > 0) try self.write(", ");
            const p_cpp = try self.typeRefToCpp(p.type_ref);
            defer self.alloc.free(p_cpp);
            switch (p.mode) {
                .in_ => try self.print("{s} {s}", .{ p_cpp, p.name }),
                .out, .inout => try self.print("{s}& {s}", .{ p_cpp, p.name }),
            }
        }
        try self.write(") override {\n");

        // Decide if we can do direct forwarding.
        const all_simple = blk: {
            if (op.return_type) |rt| {
                if (!self.isSimpleType(rt)) break :blk false;
            }
            for (op.params) |p| {
                if (!self.isSimpleType(p.type_ref)) break :blk false;
            }
            break :blk true;
        };

        if (all_simple) {
            if (op.return_type != null) {
                try self.print("        return zidl_{s}_{s}(ptr_", .{ c_name, op.name });
            } else {
                try self.print("        zidl_{s}_{s}(ptr_", .{ c_name, op.name });
            }
            for (op.params) |p| {
                try self.print(", {s}", .{p.name});
            }
            try self.write(");\n");
        } else {
            // Not all params/return are simple; check what can be adapted.
            const is_str_return = if (op.return_type) |rt| (rt == .string) else false;
            const is_void_return = op.return_type == null;
            const is_simple_return = if (op.return_type) |rt| self.isSimpleType(rt) else false;
            // Params are "adaptable" if each is a simple type or a string.
            const all_adaptable = blk: {
                for (op.params) |p| {
                    if (!self.isSimpleType(p.type_ref) and p.type_ref != .string) break :blk false;
                }
                break :blk true;
            };
            if (is_str_return and all_adaptable) {
                try self.print("        return {s}(zidl_{s}_{s}(ptr_", .{ stringTypeName(self.opts), c_name, op.name });
                for (op.params) |p| try self.emitParamAdapt(p);
                try self.write("));\n");
            } else if ((is_void_return or is_simple_return) and all_adaptable) {
                if (is_simple_return) {
                    try self.print("        return zidl_{s}_{s}(ptr_", .{ c_name, op.name });
                } else {
                    try self.print("        zidl_{s}_{s}(ptr_", .{ c_name, op.name });
                }
                for (op.params) |p| try self.emitParamAdapt(p);
                try self.write(");\n");
            } else {
                // General TODO stub for operations with complex unadaptable types.
                try self.print(
                    "        /* TODO: adapt C++ types to C ABI for {s}::{s} */\n",
                    .{ c_name, op.name },
                );
                if (op.return_type != null) try self.write("        return {};\n");
            }
        }
        try self.write("    }\n");
    }

    fn emitImplAttr(self: *ImplGenerator, c_name: []const u8, attr: *const ir.Attribute) !void {
        const a_cpp = try self.typeRefToCpp(attr.type_ref);
        defer self.alloc.free(a_cpp);

        // Getter.
        try self.print("    {s} {s}() const override {{\n", .{ a_cpp, attr.name });
        if (self.isSimpleType(attr.type_ref)) {
            try self.print("        return zidl_{s}_get_{s}(ptr_);\n", .{ c_name, attr.name });
        } else if (attr.type_ref == .string) {
            try self.print("        return {s}(zidl_{s}_get_{s}(ptr_));\n", .{ stringTypeName(self.opts), c_name, attr.name });
        } else {
            try self.print(
                "        /* TODO: adapt C++ type for get_{s} */\n        return {{}};\n",
                .{attr.name},
            );
        }
        try self.write("    }\n");

        // Setter (omitted for readonly).
        if (!attr.readonly) {
            try self.print("    void {s}({s} value) override {{\n", .{ attr.name, a_cpp });
            if (self.isSimpleType(attr.type_ref)) {
                try self.print("        zidl_{s}_set_{s}(ptr_, value);\n", .{ c_name, attr.name });
            } else if (attr.type_ref == .string) {
                try self.print("        zidl_{s}_set_{s}(ptr_, value.c_str());\n", .{ c_name, attr.name });
            } else {
                try self.print(
                    "        /* TODO: adapt C++ type for set_{s} */\n",
                    .{attr.name},
                );
            }
            try self.write("    }\n");
        }
    }

    fn emitParamAdapt(self: *ImplGenerator, p: ir.Parameter) !void {
        switch (p.type_ref) {
            .string => switch (p.mode) {
                .in_ => try self.print(", {s}.c_str()", .{p.name}),
                .out, .inout => try self.print(", {s}", .{p.name}),
            },
            else => try self.print(", {s}", .{p.name}),
        }
    }

    /// Return true if `tr` is a C-ABI-compatible primitive or enum (no adaptation needed).
    fn isSimpleType(self: *ImplGenerator, tr: ir.TypeRef) bool {
        _ = self;
        return switch (tr) {
            .base => true,
            .named => |td| switch (td) {
                .enum_ => true,
                else => false,
            },
            else => false,
        };
    }

    fn collectInterfaceMembers(
        self: *ImplGenerator,
        iface: *const ir.Interface,
        ops: *std.ArrayListUnmanaged(ir.Operation),
        attrs: *std.ArrayListUnmanaged(ir.Attribute),
    ) anyerror!void {
        for (iface.bases) |base| {
            if (base == .interface) try self.collectInterfaceMembers(base.interface, ops, attrs);
        }
        try ops.appendSlice(self.alloc, iface.operations);
        try attrs.appendSlice(self.alloc, iface.attributes);
    }

    /// C type for a TypeRef (used in extern "C" declarations).
    fn typeRefToC(self: *ImplGenerator, tr: ir.TypeRef) ![]u8 {
        return switch (tr) {
            .base => |b| self.alloc.dupe(u8, baseToCType(b)),
            .named => |td| self.prefixedCName(ir.typeDeclQualifiedName(td)),
            .sequence => |seq| blk: {
                const key = try self.seqElemKey(seq.element.*);
                defer self.alloc.free(key);
                break :blk std.fmt.allocPrint(self.alloc, "{s}_seq", .{key});
            },
            .string => self.alloc.dupe(u8, "char *"),
            .wstring => self.alloc.dupe(u8, "uint16_t *"),
            .fixed_pt => self.alloc.dupe(u8, "double"),
            .map => self.alloc.dupe(u8, "void *"),
        };
    }

    fn seqElemKey(self: *ImplGenerator, elem: ir.TypeRef) ![]u8 {
        return switch (elem) {
            .base => |b| self.alloc.dupe(u8, baseToSeqKey(b)),
            .named => |td| self.prefixedCName(ir.typeDeclQualifiedName(td)),
            .sequence => |seq| blk: {
                const inner = try self.seqElemKey(seq.element.*);
                defer self.alloc.free(inner);
                break :blk std.fmt.allocPrint(self.alloc, "{s}_seq", .{inner});
            },
            .string => self.alloc.dupe(u8, "string"),
            .wstring => self.alloc.dupe(u8, "wstring"),
            .fixed_pt => self.alloc.dupe(u8, "fixed_pt"),
            .map => self.alloc.dupe(u8, "map"),
        };
    }

    fn prefixedCName(self: *ImplGenerator, qname: []const u8) ![]u8 {
        return interface.prefixedCNameFromQualified(self.alloc, qname, self.opts.type_prefix);
    }

    /// C type for a parameter (const ptr for `in` string, etc.).
    fn paramTypeC(self: *ImplGenerator, p: ir.Parameter) ![]u8 {
        const base = try self.typeRefToC(p.type_ref);
        defer self.alloc.free(base);
        return switch (p.mode) {
            .in_ => self.alloc.dupe(u8, base),
            .out, .inout => std.fmt.allocPrint(self.alloc, "{s} *", .{base}),
        };
    }

    /// C++ type for a TypeRef (used in method signatures).
    fn typeRefToCpp(self: *ImplGenerator, tr: ir.TypeRef) ![]u8 {
        return switch (tr) {
            .base => |b| self.alloc.dupe(u8, baseToCppType(b)),
            .named => |td| self.namedTypeRefToCpp(td),
            .sequence => |seq| blk: {
                const elem = try self.typeRefToCpp(seq.element.*);
                defer self.alloc.free(elem);
                break :blk std.fmt.allocPrint(self.alloc, "{s}<{s}>", .{ vectorTypeName(self.opts), elem });
            },
            .string => self.alloc.dupe(u8, stringTypeName(self.opts)),
            .wstring => self.alloc.dupe(u8, wstringTypeName(self.opts)),
            .fixed_pt => self.alloc.dupe(u8, "double"),
            .map => |m| blk: {
                const ks = try self.typeRefToCpp(m.key.*);
                defer self.alloc.free(ks);
                const vs = try self.typeRefToCpp(m.value.*);
                defer self.alloc.free(vs);
                break :blk std.fmt.allocPrint(self.alloc, "{s}<{s}, {s}>", .{ mapTypeName(self.opts), ks, vs });
            },
        };
    }

    fn namedTypeRefToCpp(self: *ImplGenerator, td: ir.TypeDecl) ![]u8 {
        return switch (td) {
            .interface => std.fmt.allocPrint(self.alloc, "std::shared_ptr<::{s}>", .{ir.typeDeclQualifiedName(td)}),
            else => std.fmt.allocPrint(self.alloc, "::{s}", .{ir.typeDeclQualifiedName(td)}),
        };
    }
};

/// Returns true if a union case is the `default:` arm.
fn isDefaultUnionCase(cas: ir.UnionCase) bool {
    if (cas.labels.len == 0) return true;
    for (cas.labels) |lbl| {
        if (lbl == .default) return true;
    }
    return false;
}

/// True if `tr` maps to a C++ type that is not trivially default-
/// constructible/destructible (std::string, std::vector, std::map, or an
/// array/struct/union transitively containing one). Such a type cannot be a
/// member of a raw C++ union without explicit placement-new/destructor
/// calls -- the implicit special member functions the union would
/// otherwise need are ill-formed, so this predicate decides when
/// `unionNeedsCppLifetime` requires generating them by hand instead.
fn typeRefIsCppNonTrivial(tr: ir.TypeRef) bool {
    return switch (tr) {
        .base, .fixed_pt => false,
        .string, .wstring, .sequence, .map => true,
        .named => |td| switch (td) {
            .struct_ => |s| structIsCppNonTrivial(s),
            .union_ => |u| unionNeedsCppLifetime(u),
            .typedef => |t| typeRefIsCppNonTrivial(t.type_ref),
            .enum_, .bitset, .bitmask, .exception, .native, .interface => false,
        },
    };
}

fn structIsCppNonTrivial(s: *const ir.Struct) bool {
    if (s.base) |b| {
        switch (b) {
            .struct_ => |bs| if (structIsCppNonTrivial(bs)) return true,
            else => {},
        }
    }
    for (s.members) |m| {
        if (typeRefIsCppNonTrivial(m.type_ref)) return true;
    }
    return false;
}

/// True if `u` has at least one case whose type is non-trivial (see
/// `typeRefIsCppNonTrivial`), meaning the generated union class needs
/// explicit constructor/destructor/copy special member functions instead of
/// the (otherwise ill-formed) implicit ones.
fn unionNeedsCppLifetime(u: *const ir.Union) bool {
    for (u.cases) |cas| {
        if (typeRefIsCppNonTrivial(cas.type_ref)) return true;
    }
    return false;
}

/// Build a nested-`for`-loop C++ statement string that assigns
/// `dst[i0][i1]… = src[i0][i1]…` element-by-element over `dims`. Used for
/// array-typed union case setters whose element type is non-trivial, where
/// `std::memcpy` (the setter's normal fast path) would violate the element
/// type's invariants (e.g. corrupt a std::string's internal representation).
fn arrayAssignLoopCpp(alloc: std.mem.Allocator, dims: []const u64, dim_idx: usize, dst: []const u8, src: []const u8) ![]u8 {
    const idx = try std.fmt.allocPrint(alloc, "_i{d}", .{dim_idx});
    defer alloc.free(idx);
    const dst2 = try std.fmt.allocPrint(alloc, "{s}[{s}]", .{ dst, idx });
    defer alloc.free(dst2);
    if (dims.len > 1) {
        const src2 = try std.fmt.allocPrint(alloc, "{s}[{s}]", .{ src, idx });
        defer alloc.free(src2);
        const inner = try arrayAssignLoopCpp(alloc, dims[1..], dim_idx + 1, dst2, src2);
        defer alloc.free(inner);
        return std.fmt.allocPrint(alloc, "for (uint32_t {s} = 0; {s} < {d}u; {s}++) {{ {s} }}", .{ idx, idx, dims[0], idx, inner });
    }
    return std.fmt.allocPrint(alloc, "for (uint32_t {s} = 0; {s} < {d}u; {s}++) {{ {s} = {s}[{s}]; }}", .{ idx, idx, dims[0], idx, dst2, src, idx });
}

/// Recursively unwrap typedef chains to the underlying base or enum TypeRef.
/// Array typedefs (dimensions.len > 0) are not unwrapped.
fn resolveTypeRef(tr: ir.TypeRef) ir.TypeRef {
    var current = tr;
    while (true) {
        switch (current) {
            .named => |td| switch (td) {
                .typedef => |t| if (t.dimensions.len == 0) {
                    current = t.type_ref;
                    continue;
                },
                else => {},
            },
            else => {},
        }
        return current;
    }
}

/// EMHEADER LC value (0–3) for a fixed-size scalar type, or null for LC=4.
fn lcForCppTypeRef(type_ref: ir.TypeRef, dimensions: []const u64) ?u2 {
    if (dimensions.len > 0) return null;
    return switch (resolveTypeRef(type_ref)) {
        .base => |b| switch (b) {
            .boolean, .octet, .char, .int8, .uint8 => 0,
            .short, .int16, .unsigned_short, .uint16, .wchar => 1,
            .long, .int32, .unsigned_long, .uint32, .float => 2,
            .long_long, .int64, .unsigned_long_long, .uint64, .double => 3,
            else => null,
        },
        .named => |td| switch (td) {
            .enum_ => 2,
            else => null,
        },
        else => null,
    };
}

/// XTYPES member ID for a struct member (from @id annotation or declaration index).
fn memberIdAtCpp(m: ir.StructMember, idx: usize) u32 {
    return if (m.annotations.id) |id| id else @intCast(idx);
}

fn typeDeclHasKeyCpp(td: ir.TypeDecl) bool {
    return switch (td) {
        .struct_ => |s| structHasKeyCpp(s),
        else => false,
    };
}

fn structHasKeyCpp(s: *const ir.Struct) bool {
    if (s.base) |base| {
        if (typeDeclHasKeyCpp(base)) return true;
    }
    for (s.members) |m| {
        if (m.annotations.is_key) return true;
    }
    return false;
}

/// See isZzddsTopicStruct in zig.zig for why keyless structs are included --
/// DDS 1.4 2.2.2.1 treats a keyless Topic as first-class ("restricted to a
/// single instance"), so this only excludes what genuinely can't be a topic.
fn isZzddsTopicStructCpp(s: *const ir.Struct) bool {
    return !s.annotations.is_nested and s.annotations.extensibility != .mutable;
}

fn itemsHaveZzddsTopicStructCpp(items: []const ir.ModuleItem) bool {
    for (items) |item| {
        switch (item) {
            .type_decl => |td| switch (td) {
                .struct_ => |s| if (isZzddsTopicStructCpp(s)) return true,
                else => {},
            },
            .module => |m| if (itemsHaveZzddsTopicStructCpp(m.items)) return true,
            else => {},
        }
    }
    return false;
}

/// C++ type string for a TypeRef — file-level helper for CdrGenerator.
/// Caller owns the returned slice.
fn cppTypeStr(alloc: std.mem.Allocator, opts: interface.Options, tr: ir.TypeRef) anyerror![]u8 {
    return switch (tr) {
        .base => |b| alloc.dupe(u8, baseToCppType(b)),
        .named => |td| std.fmt.allocPrint(alloc, "::{s}", .{ir.typeDeclQualifiedName(td)}),
        .sequence => |seq| blk: {
            const elem = try cppTypeStr(alloc, opts, seq.element.*);
            defer alloc.free(elem);
            break :blk std.fmt.allocPrint(alloc, "{s}<{s}>", .{ vectorTypeName(opts), elem });
        },
        .string => alloc.dupe(u8, stringTypeName(opts)),
        .wstring => alloc.dupe(u8, wstringTypeName(opts)),
        .fixed_pt => alloc.dupe(u8, "double"),
        .map => |m| blk: {
            const ks = try cppTypeStr(alloc, opts, m.key.*);
            defer alloc.free(ks);
            const vs = try cppTypeStr(alloc, opts, m.value.*);
            defer alloc.free(vs);
            break :blk std.fmt.allocPrint(alloc, "{s}<{s}, {s}>", .{ mapTypeName(opts), ks, vs });
        },
    };
}

/// Build a C-style array dimension suffix string: `[d0][d1]...`
/// Used for union array member declarations and getter/setter signatures.
/// Caller owns the returned slice.
fn cArrayDimsStr(alloc: std.mem.Allocator, dims: []const u64) ![]u8 {
    var result = try alloc.dupe(u8, "");
    for (dims) |d| {
        const seg = try std.fmt.allocPrint(alloc, "[{d}]", .{d});
        defer alloc.free(seg);
        const combined = try std.mem.concat(alloc, u8, &.{ result, seg });
        alloc.free(result);
        result = combined;
    }
    return result;
}

/// C type string for a base type specifier (shared with IfaceGenerator).
fn baseToCType(b: ast.BaseTypeSpec) []const u8 {
    return switch (b) {
        .float => "float",
        .double => "double",
        .long_double => "long double",
        .short => "int16_t",
        .long => "int32_t",
        .long_long => "int64_t",
        .unsigned_short => "uint16_t",
        .unsigned_long => "uint32_t",
        .unsigned_long_long => "uint64_t",
        .char => "char",
        .wchar => "uint16_t",
        .boolean => "bool",
        .octet => "uint8_t",
        .int8 => "int8_t",
        .uint8 => "uint8_t",
        .int16 => "int16_t",
        .int32 => "int32_t",
        .int64 => "int64_t",
        .uint16 => "uint16_t",
        .uint32 => "uint32_t",
        .uint64 => "uint64_t",
        .any, .object, .value_base => "void *",
    };
}

fn baseToSeqKey(b: ast.BaseTypeSpec) []const u8 {
    return switch (b) {
        .float => "float",
        .double => "double",
        .long_double => "long_double",
        .short => "int16_t",
        .long => "int32_t",
        .long_long => "int64_t",
        .unsigned_short => "uint16_t",
        .unsigned_long => "uint32_t",
        .unsigned_long_long => "uint64_t",
        .char => "char",
        .wchar => "wchar",
        .boolean => "bool",
        .octet => "uint8_t",
        .int8 => "int8_t",
        .uint8 => "uint8_t",
        .int16 => "int16_t",
        .int32 => "int32_t",
        .int64 => "int64_t",
        .uint16 => "uint16_t",
        .uint32 => "uint32_t",
        .uint64 => "uint64_t",
        .any, .object, .value_base => "void_ptr",
    };
}

// ── CDR static helpers ────────────────────────────────────────────────────────

fn baseCWriteFn(b: ast.BaseTypeSpec) []const u8 {
    return switch (b) {
        .boolean => "zidl_cdr_write_bool",
        .octet, .uint8 => "zidl_cdr_write_u8",
        .char => "zidl_cdr_write_char",
        .wchar => "zidl_cdr_write_u16",
        .int8 => "zidl_cdr_write_i8",
        .short, .int16 => "zidl_cdr_write_i16",
        .long, .int32 => "zidl_cdr_write_i32",
        .long_long, .int64 => "zidl_cdr_write_i64",
        .unsigned_short, .uint16 => "zidl_cdr_write_u16",
        .unsigned_long, .uint32 => "zidl_cdr_write_u32",
        .unsigned_long_long, .uint64 => "zidl_cdr_write_u64",
        .float => "zidl_cdr_write_f32",
        .double => "zidl_cdr_write_f64",
        .long_double => "zidl_cdr_write_f64",
        .any, .object, .value_base => "// unsupported",
    };
}

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

fn enumCStorageType(annotations: ir.EnumAnnotations) []const u8 {
    const bound = annotations.bit_bound orelse 32;
    return if (bound <= 8) "u8" else if (bound <= 16) "u16" else if (bound <= 32) "u32" else "u64";
}

fn enumCTypeName(annotations: ir.EnumAnnotations) []const u8 {
    const bound = annotations.bit_bound orelse 32;
    return if (bound <= 8) "uint8_t" else if (bound <= 16) "uint16_t" else if (bound <= 32) "uint32_t" else "uint64_t";
}

// ── File writing helper ───────────────────────────────────────────────────────

fn writeOutputFile(
    alloc: std.mem.Allocator,
    io: std.Io,
    opts: interface.Options,
    filename: []const u8,
    content: []const u8,
) !void {
    const path = if (opts.output_dir.len > 0)
        try std.fs.path.join(alloc, &.{ opts.output_dir, filename })
    else
        try alloc.dupe(u8, filename);
    defer alloc.free(path);
    const f = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer f.close(io);
    var write_buf: [4096]u8 = undefined;
    var fw: std.Io.File.Writer = .init(f, io, &write_buf);
    try fw.interface.writeAll(content);
    try fw.interface.flush();
}

// ── Split-file mode ───────────────────────────────────────────────────────────

/// Scan a single TypeDecl for include needs (map / optional).
fn scanIncludesTypeDecl(td: ir.TypeDecl, needs: *Generator.IncludeNeeds) void {
    switch (td) {
        .struct_ => |s| {
            for (s.members) |m| {
                if (m.annotations.is_optional) needs.optional = true;
                Generator.scanIncludesTypeRef(m.type_ref, needs);
            }
        },
        .union_ => |u| {
            for (u.cases) |c| Generator.scanIncludesTypeRef(c.type_ref, needs);
            if (unionNeedsCppLifetime(u)) needs.union_lifetime = true;
        },
        .exception => |e| {
            for (e.members) |m| {
                if (m.annotations.is_optional) needs.optional = true;
                Generator.scanIncludesTypeRef(m.type_ref, needs);
            }
        },
        .interface => |iface| Generator.scanIncludesInterface(iface, needs),
        else => {},
    }
}

/// Collect named type stems that `td` directly depends on (for `#include`).
fn collectHeaderDeps(
    alloc: std.mem.Allocator,
    td: ir.TypeDecl,
    my_stem: []const u8,
    out_set: *std.StringHashMapUnmanaged(void),
) !void {
    switch (td) {
        .struct_ => |s| {
            if (s.base) |b| try addNamedDep(alloc, ir.typeDeclQualifiedName(b), my_stem, out_set);
            for (s.members) |m| try collectTypeRefDeps(alloc, m.type_ref, my_stem, out_set);
        },
        .union_ => |u| {
            try collectTypeRefDeps(alloc, u.discriminant, my_stem, out_set);
            for (u.cases) |c| try collectTypeRefDeps(alloc, c.type_ref, my_stem, out_set);
        },
        .exception => |e| {
            for (e.members) |m| try collectTypeRefDeps(alloc, m.type_ref, my_stem, out_set);
        },
        .typedef => |t| try collectTypeRefDeps(alloc, t.type_ref, my_stem, out_set),
        .interface => |iface| {
            for (iface.bases) |b| try addNamedDep(alloc, ir.typeDeclQualifiedName(b), my_stem, out_set);
            for (iface.operations) |op| {
                if (op.return_type) |rt| try collectTypeRefDeps(alloc, rt, my_stem, out_set);
                for (op.params) |p| try collectTypeRefDeps(alloc, p.type_ref, my_stem, out_set);
            }
            for (iface.attributes) |a| try collectTypeRefDeps(alloc, a.type_ref, my_stem, out_set);
        },
        .bitset => |bs| {
            if (bs.base) |b| try addNamedDep(alloc, ir.typeDeclQualifiedName(b), my_stem, out_set);
        },
        .bitmask, .enum_, .native => {},
    }
}

fn collectTypeRefDeps(
    alloc: std.mem.Allocator,
    tr: ir.TypeRef,
    my_stem: []const u8,
    out_set: *std.StringHashMapUnmanaged(void),
) !void {
    switch (tr) {
        .named => |named_td| try addNamedDep(alloc, ir.typeDeclQualifiedName(named_td), my_stem, out_set),
        .sequence => |s| try collectTypeRefDeps(alloc, s.element.*, my_stem, out_set),
        .map => |m| {
            try collectTypeRefDeps(alloc, m.key.*, my_stem, out_set);
            try collectTypeRefDeps(alloc, m.value.*, my_stem, out_set);
        },
        else => {},
    }
}

fn addNamedDep(
    alloc: std.mem.Allocator,
    qname: []const u8,
    my_stem: []const u8,
    out_set: *std.StringHashMapUnmanaged(void),
) !void {
    const dep = try interface.cNameFromQualified(alloc, qname);
    defer alloc.free(dep);
    if (std.mem.eql(u8, dep, my_stem)) return;
    if (out_set.contains(dep)) return;
    const k = try alloc.dupe(u8, dep);
    errdefer alloc.free(k);
    try out_set.put(alloc, k, {});
}

fn collectTypeDeclsFlat(
    alloc: std.mem.Allocator,
    items: []const ir.ModuleItem,
    out: *std.ArrayListUnmanaged(ir.TypeDecl),
) !void {
    for (items) |item| {
        switch (item) {
            .module => |m| try collectTypeDeclsFlat(alloc, m.items, out),
            .type_decl => |td| try out.append(alloc, td),
            .const_ => {},
        }
    }
}

/// Generate a single-type C++ header into `out`.
fn generateTypeHeader(
    alloc: std.mem.Allocator,
    td: ir.TypeDecl,
    opts: interface.Options,
    out: *std.ArrayList(u8),
) !void {
    const qname = ir.typeDeclQualifiedName(td);
    const type_stem = try interface.cNameFromQualified(alloc, qname);
    defer alloc.free(type_stem);

    var needs = Generator.IncludeNeeds{};
    scanIncludesTypeDecl(td, &needs);

    var deps = std.StringHashMapUnmanaged(void).empty;
    defer {
        var it = deps.keyIterator();
        while (it.next()) |k| alloc.free(k.*);
        deps.deinit(alloc);
    }
    try collectHeaderDeps(alloc, td, type_stem, &deps);

    const prefix = opts.header_guard_prefix;
    const guard = try std.fmt.allocPrint(alloc, "{s}{s}_HPP", .{ prefix, type_stem });
    defer alloc.free(guard);
    for (guard) |*c| c.* = if (std.ascii.isAlphanumeric(c.*)) std.ascii.toUpper(c.*) else '_';

    var gen = Generator{ .alloc = alloc, .opts = opts, .out = out };

    try gen.print("// Generated by zidl from {s}.idl — DO NOT EDIT\n\n", .{opts.input_stem});
    if (opts.pragma_once) {
        try gen.write("#pragma once\n\n");
    } else {
        try gen.print("#ifndef {s}\n#define {s}\n\n", .{ guard, guard });
    }
    try gen.write("#include <cstdint>\n");
    try gen.write("#include <string>\n");
    try gen.write("#include <vector>\n");
    if (opts.cpp_pmr_containers) try gen.write("#include <memory_resource>\n");
    if (opts.generate_interfaces and needs.memory) try gen.write("#include <memory>\n");
    if (needs.map) try gen.write("#include <map>\n");
    if (needs.optional) try gen.write("#include <optional>\n");
    if (needs.union_lifetime) try gen.write("#include <new>\n");
    try gen.write("#include <array>\n");
    try gen.write("#include <stdexcept>\n");
    if (!opts.no_typesupport) {
        switch (td) {
            .struct_, .exception, .union_ => try gen.write("#include \"zidl_cdr.h\"\n"),
            else => {},
        }
    }
    if (opts.generate_zzdds_wrappers and !opts.no_typesupport) {
        switch (td) {
            .struct_ => |s| if (isZzddsTopicStructCpp(s)) {
                try gen.write("#include \"zzdds_c.h\"\n");
                try gen.write("#include <unordered_map>\n");
            },
            else => {},
        }
    }
    var it = deps.keyIterator();
    while (it.next()) |k| {
        try gen.print("#include \"{s}.hpp\"\n", .{k.*});
    }
    try gen.write("\n");
    if (opts.cpp_namespace.len > 0) {
        try gen.print("namespace {s} {{\n\n", .{opts.cpp_namespace});
    }

    try gen.emitTypeDecl(td);

    if (opts.generate_zzdds_wrappers and !opts.no_typesupport) {
        switch (td) {
            .struct_ => |s| if (isZzddsTopicStructCpp(s)) {
                const cpp_qname = try std.fmt.allocPrint(alloc, "::{s}", .{s.qualified_name});
                defer alloc.free(cpp_qname);
                try gen.emitStructZzddsWrapperDecls(s, cpp_qname);
            },
            else => {},
        }
    }

    if (!opts.no_typesupport) {
        switch (td) {
            .struct_ => |s| try gen.emitStructCdrProtos(s),
            .exception => |e| try gen.emitExceptionCdrProtos(e),
            .union_ => |u| try gen.emitUnionCdrProtos(u),
            else => {},
        }
    }

    if (opts.cpp_namespace.len > 0) {
        try gen.print("\n}} // namespace {s}\n", .{opts.cpp_namespace});
    }
    if (!opts.pragma_once) {
        try gen.print("#endif // {s}\n", .{guard});
    }
}

/// Generate a single-type CDR source file into `out`.
fn generateTypeCdrSource(
    alloc: std.mem.Allocator,
    td: ir.TypeDecl,
    opts: interface.Options,
    type_stem: []const u8,
    out: *std.ArrayList(u8),
) !void {
    var gen = CdrGenerator{ .alloc = alloc, .opts = opts, .out = out };
    try gen.print("// Generated by zidl from {s}.idl — DO NOT EDIT\n\n", .{opts.input_stem});
    try gen.print("#include \"{s}.hpp\"\n", .{type_stem});
    try gen.write("#include \"zidl_cdr.h\"\n");
    try gen.write("#include <cstring>\n\n");
    try gen.emitTypeDecl(td);
}

/// Generate the aggregate `<stem>_all.hpp` that includes every per-type header.
fn generateAggregateHeader(
    alloc: std.mem.Allocator,
    type_decls: []const ir.TypeDecl,
    opts: interface.Options,
    out: *std.ArrayList(u8),
) !void {
    const prefix = opts.header_guard_prefix;
    const guard = try std.fmt.allocPrint(alloc, "{s}{s}_ALL_HPP", .{ prefix, opts.input_stem });
    defer alloc.free(guard);
    for (guard) |*c| c.* = if (std.ascii.isAlphanumeric(c.*)) std.ascii.toUpper(c.*) else '_';

    var gen = Generator{ .alloc = alloc, .opts = opts, .out = out };

    try gen.print("// Generated by zidl from {s}.idl — DO NOT EDIT\n\n", .{opts.input_stem});
    if (opts.pragma_once) {
        try gen.write("#pragma once\n\n");
    } else {
        try gen.print("#ifndef {s}\n#define {s}\n\n", .{ guard, guard });
    }
    for (type_decls) |td| {
        const qname = ir.typeDeclQualifiedName(td);
        const type_stem = try interface.cNameFromQualified(alloc, qname);
        defer alloc.free(type_stem);
        try gen.print("#include \"{s}.hpp\"\n", .{type_stem});
    }
    if (opts.pragma_once) {
        try gen.write("\n");
    } else {
        try gen.print("\n#endif // {s}\n", .{guard});
    }
}

/// Split-file entry point: one header+CDR pair per named type, plus aggregate.
pub fn generateSplitFiles(
    alloc: std.mem.Allocator,
    io: std.Io,
    spec: *const ir.Spec,
    opts: interface.Options,
) !void {
    var type_decls = std.ArrayListUnmanaged(ir.TypeDecl).empty;
    defer type_decls.deinit(alloc);
    try collectTypeDeclsFlat(alloc, spec.items, &type_decls);

    for (type_decls.items) |td| {
        const qname = ir.typeDeclQualifiedName(td);
        const type_stem = try interface.cNameFromQualified(alloc, qname);
        defer alloc.free(type_stem);

        var h_content = std.ArrayList(u8).empty;
        defer h_content.deinit(alloc);
        try generateTypeHeader(alloc, td, opts, &h_content);
        const h_filename = try std.fmt.allocPrint(alloc, "{s}.hpp", .{type_stem});
        defer alloc.free(h_filename);
        try writeOutputFile(alloc, io, opts, h_filename, h_content.items);

        if (!opts.no_typesupport) {
            switch (td) {
                .struct_, .exception, .union_ => {
                    var c_content = std.ArrayList(u8).empty;
                    defer c_content.deinit(alloc);
                    try generateTypeCdrSource(alloc, td, opts, type_stem, &c_content);
                    const c_filename = try std.fmt.allocPrint(alloc, "{s}_cdr.cpp", .{type_stem});
                    defer alloc.free(c_filename);
                    try writeOutputFile(alloc, io, opts, c_filename, c_content.items);
                },
                else => {},
            }
        }
    }

    var all_content = std.ArrayList(u8).empty;
    defer all_content.deinit(alloc);
    try generateAggregateHeader(alloc, type_decls.items, opts, &all_content);
    const all_filename = try std.fmt.allocPrint(alloc, "{s}_all.hpp", .{opts.input_stem});
    defer alloc.free(all_filename);
    try writeOutputFile(alloc, io, opts, all_filename, all_content.items);

    if (opts.generate_interfaces) {
        var impl_content = std.ArrayList(u8).empty;
        defer impl_content.deinit(alloc);
        try generateImplSource(alloc, spec, opts, &impl_content);
        const impl_filename = try std.fmt.allocPrint(alloc, "{s}_impl.cpp", .{opts.input_stem});
        defer alloc.free(impl_filename);
        try writeOutputFile(alloc, io, opts, impl_filename, impl_content.items);
    }
}

// ── Tests ─────────────────────────────────────────────────────────────────────

const testing = std.testing;
const parser_mod = @import("../parser.zig");
const semantic_mod = @import("../semantic/root.zig");

/// Parse `source`, analyse, build IR, generate C++ header into a returned buffer.
/// Caller must call `.deinit(testing.allocator)` on the returned ArrayList.
fn testGen(source: []const u8, stem: []const u8) !std.ArrayList(u8) {
    return testGenOpts(source, stem, .{});
}

fn testGenOpts(source: []const u8, stem: []const u8, extra: struct {
    type_prefix: []const u8 = "",
    generate_interfaces: bool = false,
    pragma_once: bool = false,
    cpp_namespace: []const u8 = "",
    export_macro: []const u8 = "",
    no_typesupport: bool = false,
    generate_zzdds_wrappers: bool = false,
    cpp_pmr_containers: bool = false,
}) !std.ArrayList(u8) {
    const alloc = testing.allocator;
    var ast_arena = std.heap.ArenaAllocator.init(alloc);
    defer ast_arena.deinit();
    var p = parser_mod.Parser.init(source, ast_arena.allocator());
    const spec = try p.parseSpecification();
    var az = try semantic_mod.Analyzer.init(alloc);
    defer az.deinit();
    try az.analyze(&spec);
    var ir_spec = try ir.build(alloc, &spec, az.global_scope, &.{});
    defer ir_spec.deinit();
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(alloc);
    const opts = interface.Options{
        .input_stem = stem,
        .type_prefix = extra.type_prefix,
        .generate_interfaces = extra.generate_interfaces,
        .pragma_once = extra.pragma_once,
        .cpp_namespace = extra.cpp_namespace,
        .export_macro = extra.export_macro,
        .no_typesupport = extra.no_typesupport,
        .generate_zzdds_wrappers = extra.generate_zzdds_wrappers,
        .cpp_pmr_containers = extra.cpp_pmr_containers,
    };
    try generateHeader(alloc, &ir_spec, opts, &out);
    return out;
}

/// Like testGen but generates the CDR source (the `_cdr.cpp` file content).
fn testGenCdr(source: []const u8, stem: []const u8) !std.ArrayList(u8) {
    return testGenCdrOpts(source, stem, .{});
}

fn testGenCdrOpts(source: []const u8, stem: []const u8, extra: struct {
    type_prefix: []const u8 = "",
    generate_zzdds_wrappers: bool = false,
    cpp_pmr_containers: bool = false,
}) !std.ArrayList(u8) {
    const alloc = testing.allocator;
    var ast_arena = std.heap.ArenaAllocator.init(alloc);
    defer ast_arena.deinit();
    var p = parser_mod.Parser.init(source, ast_arena.allocator());
    const spec = try p.parseSpecification();
    var az = try semantic_mod.Analyzer.init(alloc);
    defer az.deinit();
    try az.analyze(&spec);
    var ir_spec = try ir.build(alloc, &spec, az.global_scope, &.{});
    defer ir_spec.deinit();
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(alloc);
    const opts = interface.Options{
        .input_stem = stem,
        .type_prefix = extra.type_prefix,
        .generate_zzdds_wrappers = extra.generate_zzdds_wrappers,
        .cpp_pmr_containers = extra.cpp_pmr_containers,
    };
    try generateCdrSource(alloc, &ir_spec, opts, &out);
    return out;
}

fn has(haystack: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, haystack, needle) != null;
}

test "cpp_backend: header guard and includes" {
    var out = try testGen("struct Dummy { long x; };", "my_types");
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "ifndef MY_TYPES_HPP"));
    try testing.expect(has(s, "define MY_TYPES_HPP"));
    try testing.expect(has(s, "#include <cstdint>"));
    try testing.expect(has(s, "#include <vector>"));
    try testing.expect(has(s, "#include <string>"));
    try testing.expect(has(s, "endif // MY_TYPES_HPP"));
}

test "cpp_backend: interface generation includes memory" {
    var primitive_iface = try testGenOpts(
        \\interface Greeter { string greet(in string name); };
    , "greeter", .{ .generate_interfaces = true });
    defer primitive_iface.deinit(testing.allocator);
    try testing.expect(has(primitive_iface.items, "#include <memory>"));

    var interface_ref = try testGenOpts(
        \\interface DataWriter {};
        \\interface Listener { void on_data(in DataWriter writer); };
    , "listener", .{ .generate_interfaces = true });
    defer interface_ref.deinit(testing.allocator);
    try testing.expect(has(interface_ref.items, "#include <memory>"));
    try testing.expect(has(interface_ref.items, "std::shared_ptr<::DataWriter> writer"));
}

test "cpp_backend: zzdds wrappers suppressed when no_typesupport" {
    var out = try testGenOpts(
        "@appendable struct Topic { @key long id; string<16> name; };",
        "topic",
        .{ .generate_zzdds_wrappers = true, .no_typesupport = true },
    );
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(!has(s, "zzdds_c.h"));
    try testing.expect(!has(s, "DDS_DataWriter"));
    try testing.expect(!has(s, "TopicDataWriter"));
}

test "cpp_backend: get_field_from_cdr generated for int/float/string members, skips nested" {
    var out = try testGenCdrOpts(
        "@appendable struct Inner { long z; };" ++
            "@appendable struct Topic { @key long x; float y32; double y64; string<16> color; Inner nested; sequence<long> seq; };",
        "topic",
        .{ .generate_zzdds_wrappers = true },
    );
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "bool Topic_get_field_from_cdr(const uint8_t *_payload, size_t _payload_len, const char *_field, size_t _field_len, zzdds_filter_value *_out, uint8_t *_scratch, size_t _scratch_len) {"));
    try testing.expect(has(s, "::Topic _v;"));
    try testing.expect(has(s, "_rc = Topic_deserialize_selected(_r, _fmask, &_v);"));
    // int-like member
    try testing.expect(has(s, "if (_field_len == sizeof(\"x\") - 1 && memcmp(_field, \"x\", _field_len) == 0) {"));
    try testing.expect(has(s, "_out->kind = 0;"));
    try testing.expect(has(s, "_out->i = static_cast<int64_t>(_v.x);"));
    // float32 and float64 members retain distinct middleware discriminators
    try testing.expect(has(
        s,
        "} else if (_field_len == sizeof(\"y32\") - 1 && memcmp(_field, \"y32\", _field_len) == 0) {\n" ++
            "        _out->kind = 3;\n" ++
            "        _out->f = static_cast<double>(_v.y32);",
    ));
    try testing.expect(has(
        s,
        "} else if (_field_len == sizeof(\"y64\") - 1 && memcmp(_field, \"y64\", _field_len) == 0) {\n" ++
            "        _out->kind = 1;\n" ++
            "        _out->f = static_cast<double>(_v.y64);",
    ));
    // string-like member: scratch-buffer copy via std::string's .data()/.size(),
    // not returning a pointer into _v (which is about to go out of scope)
    try testing.expect(has(s, "} else if (_field_len == sizeof(\"color\") - 1 && memcmp(_field, \"color\", _field_len) == 0) {"));
    try testing.expect(has(s, "size_t _s_len = _v.color.size();"));
    try testing.expect(has(s, "if (_s_len <= _scratch_len) {"));
    try testing.expect(has(s, "memcpy(_scratch, _v.color.data(), _s_len);"));
    try testing.expect(has(s, "_out->s_ptr = _scratch;"));
    // nested struct / sequence members are not filterable -- get_field_from_cdr
    // never compares `_field` against them (`_field_index` maps every member
    // name, which is fine -- those bits just never get set in a filter mask).
    try testing.expect(!has(s, "memcmp(_field, \"nested\""));
    try testing.expect(!has(s, "memcmp(_field, \"seq\""));
    // TypeSupport::register_type wires the new function in
    try testing.expect(has(s, "zzdds_register_type_support(participant, type_name ? type_name : \"Topic\", Topic_compute_key_hash_from_cdr, Topic_get_field_from_cdr);"));
}

test "cpp_backend: get_field_from_cdr with no filterable members always returns false" {
    var out = try testGenCdrOpts(
        "@appendable struct Topic { @key sequence<long> seq; };",
        "topic",
        .{ .generate_zzdds_wrappers = true },
    );
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "bool Topic_get_field_from_cdr("));
    try testing.expect(has(s, "bool _matched = false;"));
    try testing.expect(!has(s, "_matched = true;"));
    try testing.expect(has(s, "return _matched;"));
}

test "cpp_backend: get_field_from_cdr prototype declared in header when zzdds wrappers enabled" {
    var h = try testGenOpts(
        "@appendable struct Topic { @key long id; string<16> name; };",
        "topic",
        .{ .generate_zzdds_wrappers = true },
    );
    defer h.deinit(testing.allocator);
    try testing.expect(has(h.items, "bool Topic_get_field_from_cdr(const uint8_t *_payload, size_t _payload_len, const char *_field, size_t _field_len, zzdds_filter_value *_out, uint8_t *_scratch, size_t _scratch_len);"));
}

test "cpp_backend: zzdds_c omitted when no qualifying topic struct" {
    // A plain top-level keyless struct now qualifies (see the next test) --
    // what's genuinely disqualified is @nested (any key or not) and
    // @mutable.
    var out = try testGenOpts(
        "@nested struct NestedPlain { long id; }; @nested struct NestedKey { @key long id; }; @mutable struct MutableKey { @key long id; };",
        "plain",
        .{ .generate_zzdds_wrappers = true },
    );
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(!has(s, "zzdds_c.h"));
    try testing.expect(!has(s, "DataWriter"));
}

test "cpp_backend: zzdds wrappers still emitted for a keyless top-level struct" {
    // DDS 1.4 2.2.2.1: a keyless Topic is a legitimate single-instance
    // Topic, not a corner case -- it must still get a DataWriter/DataReader.
    var out = try testGenOpts(
        "struct NoKey { long x; long y; };",
        "nokey",
        .{ .generate_zzdds_wrappers = true },
    );
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "zzdds_c.h"));
    try testing.expect(has(s, "NoKeyDataWriter"));
    try testing.expect(has(s, "NoKeyDataReader"));
}

test "cpp_backend: zzdds wrapper declarations for keyed topic" {
    var out = try testGenOpts(
        "@appendable struct Topic { @key long id; string<16> name; };",
        "topic",
        .{ .generate_zzdds_wrappers = true },
    );
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "#include \"zzdds_c.h\""));
    try testing.expect(has(s, "class TopicTypeSupport {"));
    try testing.expect(has(s, "static int register_type(DDS_DomainParticipant participant, const char *type_name = \"Topic\");"));
    try testing.expect(has(s, "class TopicDataWriter {"));
    try testing.expect(has(s, "DDS_DataWriter writer_;"));
    try testing.expect(has(s, "class Loan {"));
    try testing.expect(has(s, "DDS_OctetSeqSeq loan_payloads_{};"));
    try testing.expect(has(s, "DDS_SampleInfoSeq loan_infos_{};"));
}

test "cpp_backend: header guard prefix" {
    const alloc = testing.allocator;
    var ast_arena = std.heap.ArenaAllocator.init(alloc);
    defer ast_arena.deinit();
    var p = parser_mod.Parser.init("struct X { long a; };", ast_arena.allocator());
    const spec = try p.parseSpecification();
    var az = try semantic_mod.Analyzer.init(alloc);
    defer az.deinit();
    try az.analyze(&spec);
    var ir_spec = try ir.build(alloc, &spec, az.global_scope, &.{});
    defer ir_spec.deinit();
    var out = std.ArrayList(u8).empty;
    defer out.deinit(alloc);
    const opts = interface.Options{ .input_stem = "types", .header_guard_prefix = "MYNS_" };
    try generateHeader(alloc, &ir_spec, opts, &out);
    try testing.expect(has(out.items, "ifndef MYNS_TYPES_HPP"));
}

test "cpp_backend: simple struct" {
    var out = try testGen("struct Point { long x; long y; };", "point");
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "struct Point {"));
    try testing.expect(has(s, "int32_t x{};"));
    try testing.expect(has(s, "int32_t y{};"));
    try testing.expect(has(s, "}; // struct Point"));
}

test "cpp_backend: struct in module becomes namespace" {
    var out = try testGen(
        \\module Sensor { struct Reading { double value; }; };
    , "sensor");
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "namespace Sensor {"));
    try testing.expect(has(s, "struct Reading {"));
    try testing.expect(has(s, "double value{};"));
    try testing.expect(has(s, "} // namespace Sensor"));
}

test "cpp_backend: nested modules become nested namespaces" {
    var out = try testGen(
        \\module A { module B { struct C { long x; }; }; };
    , "nested");
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "namespace A {"));
    try testing.expect(has(s, "namespace B {"));
    try testing.expect(has(s, "struct C {"));
    try testing.expect(has(s, "} // namespace B"));
    try testing.expect(has(s, "} // namespace A"));
}

test "cpp_backend: enum class" {
    var out = try testGen("enum Color { RED, GREEN, BLUE };", "color");
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "enum class Color : uint32_t {"));
    try testing.expect(has(s, "RED = 0"));
    try testing.expect(has(s, "GREEN = 1"));
    try testing.expect(has(s, "BLUE = 2"));
    try testing.expect(has(s, "}; // enum class Color"));
}

test "cpp_backend: union" {
    var out = try testGen(
        \\union Var switch (long) { case 0: long i; case 1: double d; };
    , "var");
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "class Var {"));
    try testing.expect(has(s, "int32_t _d() const noexcept"));
    try testing.expect(has(s, "void i(int32_t v)"));
    try testing.expect(has(s, "double d() const"));
    try testing.expect(has(s, "int32_t _disc{};"));
    try testing.expect(has(s, "}; // class Var"));
}

test "cpp_backend: union CDR serialize/deserialize" {
    var out = try testGenCdr(
        \\union Var switch (long) { case 0: long i; case 1: double d; };
    , "var");
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "int Var_serialize(ZidlCdrWriter *_w, const ::Var *_v)"));
    try testing.expect(has(s, "int Var_deserialize(ZidlCdrReader *_r, ::Var *_v)"));
    try testing.expect(has(s, "zidl_cdr_write_i32(_w, static_cast<int32_t>(_v->_d()))"));
    try testing.expect(has(s, "switch (_v->_d()) {"));
    try testing.expect(has(s, "case 0:"));
    try testing.expect(has(s, "case 1:"));
}

test "cpp_backend: union with array member decl" {
    var out = try testGen(
        \\union Var switch (long) { case 0: long arr[3]; case 1: double d; };
    , "var");
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "class Var {"));
    // array private member
    try testing.expect(has(s, "int32_t _arr[3];"));
    // array getter: trailing return type with reference-to-array
    try testing.expect(has(s, "auto arr() const noexcept -> int32_t const (&)[3]"));
    // array setter: const-ref param
    try testing.expect(has(s, "void arr(int32_t const (&v)[3]) noexcept"));
    // std::memcpy in setter
    try testing.expect(has(s, "std::memcpy(_u._arr, v, sizeof(_u._arr))"));
    // <cstring> included for std::memcpy
    try testing.expect(has(s, "#include <cstring>"));
    // scalar member unaffected
    try testing.expect(has(s, "void d(double v)"));
    try testing.expect(has(s, "}; // class Var"));
}

test "cpp_backend: union array CDR serialize/deserialize" {
    var out = try testGenCdr(
        \\union Var switch (long) { case 0: long arr[3]; case 1: double d; };
    , "var");
    defer out.deinit(testing.allocator);
    const s = out.items;
    // serialize: write array via loop
    try testing.expect(has(s, "int Var_serialize(ZidlCdrWriter *_w, const ::Var *_v)"));
    try testing.expect(has(s, "_v->arr()[_ai0]"));
    // deserialize: temp array decl + read loop + setter call
    try testing.expect(has(s, "int Var_deserialize(ZidlCdrReader *_r, ::Var *_v)"));
    try testing.expect(has(s, "int32_t _tmp_arr[3]{}"));
    try testing.expect(has(s, "_v->arr(_tmp_arr)"));
    // no TODO stubs remain
    try testing.expect(!has(s, "TODO"));
}

test "cpp_backend: union with a non-trivial case gets explicit lifetime special members" {
    var out = try testGen(
        \\union Var switch (long) { case 0: long i; default: string s; };
    , "var");
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "Var();"));
    try testing.expect(has(s, "Var(const Var &other);"));
    try testing.expect(has(s, "Var &operator=(const Var &other);"));
    try testing.expect(has(s, "~Var();"));
    // Setting the discriminant is no longer a trivial noexcept assignment --
    // it has to placement-construct/destroy the active case.
    try testing.expect(has(s, "void _d(int32_t v);"));
    try testing.expect(!has(s, "void _d(int32_t v) noexcept { _disc = v; }"));
    // The anonymous union needs its own name to declare a (deliberately
    // empty) ctor/dtor pair -- otherwise its implicit ones stay deleted for
    // any non-trivial member, regardless of what Var itself declares.
    try testing.expect(has(s, "union _Storage {"));
    try testing.expect(has(s, "_Storage() {}"));
    try testing.expect(has(s, "~_Storage() {}"));
    try testing.expect(has(s, "#include <new>"));
}

test "cpp_backend: union with only trivial cases keeps the plain unnamed union" {
    var out = try testGen(
        \\union Var switch (long) { case 0: long i; case 1: double d; };
    , "var");
    defer out.deinit(testing.allocator);
    const s = out.items;
    // No regression for the common case: same trivial noexcept setter as
    // before, no extra special members, no named storage type.
    try testing.expect(has(s, "void _d(int32_t v) noexcept { _disc = v; }"));
    try testing.expect(!has(s, "union _Storage {"));
    try testing.expect(!has(s, "Var(const Var &other);"));
    try testing.expect(!has(s, "#include <new>"));
}

test "cpp_backend cdr: non-trivial union gets _destroy_active/_construct_default/_copy_construct_from with a label for every case" {
    var out = try testGenCdr(
        \\union Var switch (long) { case 0: long i; default: string s; };
    , "var");
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "void ::Var::_destroy_active() noexcept {"));
    try testing.expect(has(s, "void ::Var::_construct_default() {"));
    try testing.expect(has(s, "void ::Var::_copy_construct_from(const ::Var &other) {"));
    // Every case needs its own label, even the trivial one -- omitting it
    // would let discriminant 0 fall through into `default:` at runtime and
    // wrongly placement-new/destroy a std::string over the int's bit
    // pattern. Same hazard (and fix) as the C backend's union _free().
    try testing.expect(has(s, "case 0:"));
    try testing.expect(has(s, "using _LT = std::string; (_u._s).~_LT();"));
    try testing.expect(has(s, "new (&(_u._s)) std::string();"));
    try testing.expect(has(s, "new (&(_u._s)) std::string(other._u._s);"));
    // Trivial case in _copy_construct_from: plain value copy, not placement.
    try testing.expect(has(s, "_u._i = other._u._i;"));
}

test "cpp_backend cdr: union deserialize wraps each case body in its own scope" {
    var out = try testGenCdr(
        \\union Var switch (long) { case 0: long i; default: string s; };
    , "var");
    defer out.deinit(testing.allocator);
    const s = out.items;
    // A bare `_tmp_*` declaration directly under a case label (no braces)
    // is ill-formed once there's more than one case -- a later label jumps
    // past this one's initialization ("jump to case label" in gcc/clang).
    try testing.expect(has(s, "case 0:\n        {\n"));
    try testing.expect(has(s, "default:\n        {\n"));
}

test "cpp_backend cdr: non-trivial union operator= copies into a temporary before touching *this" {
    var out = try testGenCdr(
        \\union Var switch (long) { case 0: long i; default: string s; };
    , "var");
    defer out.deinit(testing.allocator);
    const s = out.items;
    // Strong exception guarantee: if copying `other` into the temporary
    // throws (e.g. std::string's copy ctor under bad_alloc), *this must be
    // completely untouched -- so the copy has to happen *before*
    // _destroy_active()/_disc are touched, not after. The old shape
    // destroyed the old member and committed the new discriminant first,
    // then risked the throw -- leaving _disc naming a case whose storage
    // was never actually constructed.
    try testing.expect(has(s,
        \\::Var &::Var::operator=(const ::Var &other) {
        \\        if (this != &other) {
        \\            ::Var tmp(other);
        \\            _destroy_active();
        \\            _disc = tmp._disc;
        \\            _move_construct_from(tmp);
    ));
    // The move into *this must use std::string's move ctor (noexcept),
    // never its copy ctor (which can throw) -- that's what makes everything
    // after the temporary's construction safe.
    try testing.expect(has(s, "void ::Var::_move_construct_from(::Var &other) {"));
    try testing.expect(has(s, "new (&(_u._s)) std::string(std::move(other._u._s));"));
}

test "cpp_backend: non-trivial union gets a real noexcept move ctor/assign" {
    var out = try testGen(
        \\union Var switch (long) { case 0: long i; default: string s; };
    , "var");
    defer out.deinit(testing.allocator);
    const s = out.items;
    // Required so std::move(other) in _move_construct_from actually selects
    // a real move (noexcept) instead of silently falling back to the copy
    // ctor above it (a plain `const&` parameter also accepts an rvalue) --
    // which would reintroduce the throwing-copy hole operator= exists to
    // avoid, specifically when this union is itself used as a case inside
    // another union (see the CDR test below).
    try testing.expect(has(s, "Var(Var &&other) noexcept;"));
    try testing.expect(has(s, "Var &operator=(Var &&other) noexcept;"));
}

test "cpp_backend cdr: a union used as another union's case gets a real move, not a throwing-copy fallback" {
    var out = try testGenCdr(
        \\union Inner switch (long) { case 0: long i; default: string s; };
        \\union Outer switch (long) { case 0: long i; default: Inner nested; };
    , "outer");
    defer out.deinit(testing.allocator);
    const s = out.items;
    // Inner itself must get a real move ctor (checked above already applies
    // per-union, so this just confirms Outer's own move-from delegates via
    // std::move -- which only avoids Inner's copy ctor because Inner has a
    // real move ctor to bind to).
    try testing.expect(has(s, "void ::Outer::_move_construct_from(::Outer &other) {"));
    try testing.expect(has(s, "new (&(_u._nested)) ::Inner(std::move(other._u._nested));"));
}

test "cpp_backend cdr: serializing a struct/union-typed union case copies into a local first, not &-of-temporary" {
    var out = try testGenCdr(
        \\union Inner switch (long) { case 0: long i; default: string s; };
        \\union Outer switch (long) { case 0: long i; default: Inner nested; };
    , "outer");
    defer out.deinit(testing.allocator);
    const s = out.items;
    // The case getter (`{s} {s}() const { return _u._{s}; }` in
    // Generator.emitUnion) returns by value for every non-array case --
    // `Inner_serialize(_w, &_v->nested())` would take the address of that
    // temporary, which is ill-formed C++. A local const copy is an
    // addressable lvalue instead.
    try testing.expect(has(s, "const ::Inner _tmp_nested = _v->nested();"));
    try testing.expect(has(s, "Inner_serialize(_w, &_tmp_nested);"));
    try testing.expect(!has(s, "Inner_serialize(_w, &_v->nested());"));
}

test "cpp_backend: typedef scalar" {
    var out = try testGen("typedef long MyInt;", "types");
    defer out.deinit(testing.allocator);
    try testing.expect(has(out.items, "using MyInt = int32_t;"));
}

test "cpp_backend: typedef array" {
    var out = try testGen("typedef long Matrix[2][4];", "types");
    defer out.deinit(testing.allocator);
    // IDL [2][4] → std::array<std::array<int32_t, 4>, 2>
    try testing.expect(has(out.items, "using Matrix = std::array<std::array<int32_t, 4>, 2>;"));
}

test "cpp_backend: typedef 1d array" {
    var out = try testGen("typedef double Vec3[3];", "types");
    defer out.deinit(testing.allocator);
    try testing.expect(has(out.items, "using Vec3 = std::array<double, 3>;"));
}

test "cpp_backend: const integer" {
    var out = try testGen("const long MAX_SIZE = 100;", "consts");
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "constexpr int32_t MAX_SIZE{100};"));
}

test "cpp_backend: const boolean" {
    var out = try testGen("const boolean FLAG = TRUE;", "consts");
    defer out.deinit(testing.allocator);
    try testing.expect(has(out.items, "constexpr bool FLAG{true};"));
}

test "cpp_backend: const string" {
    var out = try testGen(
        \\const string GREETING = "hello";
    , "consts");
    defer out.deinit(testing.allocator);
    try testing.expect(has(out.items, "constexpr const char* GREETING{\"hello\"};"));
}

test "cpp_backend: sequence member becomes std::vector" {
    var out = try testGen("struct Foo { sequence<long> items; };", "seq");
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "std::vector<int32_t> items{};"));
}

test "cpp_backend: string member becomes std::string" {
    var out = try testGen("struct Msg { string text; };", "msg");
    defer out.deinit(testing.allocator);
    try testing.expect(has(out.items, "std::string text{};"));
}

test "cpp_backend: --cpp-pmr-containers off (default) leaves std::vector/string/map unchanged" {
    var out = try testGenOpts(
        "struct Foo { sequence<long> items; string text; map<string, long> counts; };",
        "seq",
        .{},
    );
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "std::vector<int32_t> items{};"));
    try testing.expect(has(s, "std::string text{};"));
    try testing.expect(has(s, "std::map<std::string, int32_t> counts{};"));
    try testing.expect(!has(s, "std::pmr::"));
    try testing.expect(!has(s, "#include <memory_resource>"));
}

test "cpp_backend: --cpp-pmr-containers on emits std::pmr:: container fields + include" {
    var out = try testGenOpts(
        "struct Foo { sequence<long> items; string text; wstring wtext; map<string, long> counts; };",
        "seq",
        .{ .cpp_pmr_containers = true },
    );
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "std::pmr::vector<int32_t> items{};"));
    try testing.expect(has(s, "std::pmr::string text{};"));
    try testing.expect(has(s, "std::pmr::wstring wtext{};"));
    try testing.expect(has(s, "std::pmr::map<std::pmr::string, int32_t> counts{};"));
    try testing.expect(has(s, "#include <memory_resource>"));
    try testing.expect(!has(s, "std::vector<int32_t>"));
    try testing.expect(!has(s, "std::string text"));
}

test "cpp_backend: --cpp-pmr-containers on applies equally to bounded string/sequence fields" {
    var out = try testGenOpts(
        "struct Foo { string<16> text; sequence<long, 4> items; };",
        "bounded",
        .{ .cpp_pmr_containers = true },
    );
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "std::pmr::string text{};"));
    try testing.expect(has(s, "std::pmr::vector<int32_t> items{};"));
}

test "cpp_backend: --cpp-pmr-containers on emits pmr locals in CDR union case decode" {
    var out = try testGenCdrOpts(
        \\union U switch (long) {
        \\  case 1: sequence<long> items;
        \\  case 2: string text;
        \\};
    , "u", .{ .cpp_pmr_containers = true });
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "std::pmr::vector<int32_t> _tmp_items{};"));
    try testing.expect(has(s, "std::pmr::string _tmp_text{};"));
}

test "cpp_backend: optional member" {
    var out = try testGen(
        \\struct Opt {
        \\  @optional long maybe_x;
        \\  long required_y;
        \\};
    , "opt");
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "#include <optional>"));
    try testing.expect(!has(s, "#include <map>"));
    try testing.expect(has(s, "std::optional<int32_t> maybe_x{};"));
    try testing.expect(has(s, "int32_t required_y{};"));
}

test "cpp_backend: no optional no map omits those includes" {
    var out = try testGen(
        \\struct Plain { long x; string s; sequence<long> nums; };
    , "plain");
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(!has(s, "#include <optional>"));
    try testing.expect(!has(s, "#include <map>"));
}

test "cpp_backend: interface with operation" {
    var out = try testGen(
        \\interface Calc {
        \\  long add(in long a, in long b);
        \\  void reset();
        \\};
    , "calc");
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "class Calc {"));
    try testing.expect(has(s, "virtual ~Calc() = default;"));
    try testing.expect(has(s, "virtual int32_t add(int32_t a, int32_t b) = 0;"));
    try testing.expect(has(s, "virtual void reset() = 0;"));
    try testing.expect(has(s, "}; // class Calc"));
}

test "cpp_backend: interface with attribute" {
    var out = try testGen(
        \\interface Obj {
        \\  attribute long value;
        \\  readonly attribute string name;
        \\};
    , "obj");
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "virtual int32_t value() const = 0;"));
    try testing.expect(has(s, "virtual void value(int32_t value) = 0;"));
    try testing.expect(has(s, "virtual std::string name() const = 0;"));
    // No setter for readonly.
    try testing.expect(!has(s, "virtual void name("));
}

test "cpp_backend: interface inheritance" {
    var out = try testGen(
        \\interface Base { void foo(); };
        \\interface Derived : Base { void bar(); };
    , "inh");
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "class Derived : public ::Base {"));
}

test "cpp_backend: exception" {
    var out = try testGen(
        \\exception MyError { long code; string message; };
    , "err");
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "struct MyError : std::exception {"));
    try testing.expect(has(s, "const char* what() const noexcept override { return \"MyError\"; }"));
    try testing.expect(has(s, "int32_t code{};"));
    try testing.expect(has(s, "std::string message{};"));
}

test "cpp_backend: bitmask" {
    var out = try testGen(
        \\bitmask Flags { FLAG_A, FLAG_B, FLAG_C };
    , "flags");
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "using Flags = uint32_t;"));
    try testing.expect(has(s, "Flags_FLAG_A{Flags(1u << 0)};"));
    try testing.expect(has(s, "Flags_FLAG_B{Flags(1u << 1)};"));
    try testing.expect(has(s, "Flags_FLAG_C{Flags(1u << 2)};"));
}

test "cpp_backend: bitset" {
    var out = try testGen(
        \\bitset Bits { bitfield<4> lo; bitfield<4> hi; };
    , "bits");
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "struct Bits {"));
    try testing.expect(has(s, "lo : 4;"));
    try testing.expect(has(s, "hi : 4;"));
}

test "cpp_backend: bitset cdr byte" {
    // 3+1 = 4 bits → uint8_t wire
    var out = try testGenCdr(
        \\bitset BS { bitfield<3> a; bitfield<1> b; };
        \\struct S { BS bs; };
    , "bits");
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "uint8_t _bsv = 0;"));
    try testing.expect(has(s, "_bsv |= (uint8_t)_v->bs.a & 0x7u;"));
    try testing.expect(has(s, "_bsv |= ((uint8_t)_v->bs.b & 0x1u) << 3;"));
    try testing.expect(has(s, "zidl_cdr_write_u8(_w, _bsv)"));
    try testing.expect(has(s, "zidl_cdr_read_u8(_r, &_bsv)"));
    try testing.expect(has(s, "_v->bs.a = _bsv & 0x7u;"));
    try testing.expect(has(s, "_v->bs.b = (_bsv >> 3) & 0x1u;"));
}

test "cpp_backend: bitset cdr int" {
    // 16+16 = 32 bits → uint32_t wire
    var out = try testGenCdr(
        \\bitset Cfg { bitfield<16> lo; bitfield<16> hi; };
        \\struct S { Cfg c; };
    , "cfg");
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "uint32_t _bsv = 0;"));
    try testing.expect(has(s, "zidl_cdr_write_u32(_w, _bsv)"));
    try testing.expect(has(s, "zidl_cdr_read_u32(_r, &_bsv)"));
    try testing.expect(has(s, "_v->c.lo = _bsv & 0xFFFFu;"));
    try testing.expect(has(s, "_v->c.hi = (_bsv >> 16) & 0xFFFFu;"));
}

test "cpp_backend: map field declaration" {
    var out = try testGen("struct S { map<long, string> m; };", "map_test");
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "#include <map>"));
    try testing.expect(has(s, "std::map<int32_t, std::string> m{}"));
}

test "cpp_backend: map cdr write" {
    var out = try testGenCdr("struct S { map<long, string> m; };", "map_test");
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "uint32_t _mc = (uint32_t)_v->m.size()"));
    try testing.expect(has(s, "zidl_cdr_write_u32(_w, _mc)"));
    try testing.expect(has(s, "for (auto const& _me : _v->m)"));
    try testing.expect(has(s, "zidl_cdr_write_i32(_w, _me.first)"));
    try testing.expect(has(s, "_me.second.c_str()"));
}

test "cpp_backend: map cdr read" {
    var out = try testGenCdr("struct S { map<long, string> m; };", "map_test");
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "zidl_cdr_read_u32(_r, &_mc)"));
    try testing.expect(has(s, "for (uint32_t _mi = 0; _mi < _mc; _mi++)"));
    try testing.expect(has(s, "int32_t _mk{};"));
    try testing.expect(has(s, "std::string _mv{};"));
    try testing.expect(has(s, "_v->m.emplace(std::move(_mk), std::move(_mv))"));
}

test "cpp_backend: native" {
    var out = try testGen("native Opaque;", "nat");
    defer out.deinit(testing.allocator);
    try testing.expect(has(out.items, "class Opaque; // @native"));
}

test "cpp_backend: struct array member" {
    var out = try testGen("struct Vec { long data[3]; };", "vec");
    defer out.deinit(testing.allocator);
    try testing.expect(has(out.items, "int32_t data[3];"));
}

test "cpp_backend: cross-namespace type ref uses :: prefix" {
    var out = try testGen(
        \\struct Color { long r; long g; long b; };
        \\struct Pixel { Color color; long alpha; };
    , "cross");
    defer out.deinit(testing.allocator);
    const s = out.items;
    // Pixel.color should reference Color with :: prefix.
    try testing.expect(has(s, "::Color color{};"));
}

// ── CDR (Phase 8) tests ───────────────────────────────────────────────────────

test "cpp_backend: header includes zidl_cdr.h when typesupport enabled" {
    var out = try testGen("struct Foo { long x; };", "foo");
    defer out.deinit(testing.allocator);
    try testing.expect(has(out.items, "#include \"zidl_cdr.h\""));
}

test "cpp_backend: header omits zidl_cdr.h with --no-typesupport" {
    const alloc = testing.allocator;
    var ast_arena = std.heap.ArenaAllocator.init(alloc);
    defer ast_arena.deinit();
    var p = parser_mod.Parser.init("struct Foo { long x; };", ast_arena.allocator());
    const spec = try p.parseSpecification();
    var az = try semantic_mod.Analyzer.init(alloc);
    defer az.deinit();
    try az.analyze(&spec);
    var ir_spec = try ir.build(alloc, &spec, az.global_scope, &.{});
    defer ir_spec.deinit();
    var out = std.ArrayList(u8).empty;
    defer out.deinit(alloc);
    const opts = interface.Options{ .input_stem = "foo", .no_typesupport = true };
    try generateHeader(alloc, &ir_spec, opts, &out);
    try testing.expect(!has(out.items, "zidl_cdr.h"));
}

test "cpp_backend: header contains CDR prototypes for struct" {
    var out = try testGen("struct Point { long x; long y; };", "point");
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "#define Point_has_key 0"));
    try testing.expect(has(s, "int Point_serialize(ZidlCdrWriter *_w, const ::Point *_v);"));
    try testing.expect(has(s, "int Point_deserialize(ZidlCdrReader *_r, ::Point *_v);"));
}

test "cpp_backend: header CDR prototype uses :: for namespaced type" {
    var out = try testGen("module Ns { struct Reading { double v; }; };", "ns");
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "int Ns_Reading_serialize(ZidlCdrWriter *_w, const ::Ns::Reading *_v);"));
    try testing.expect(has(s, "int Ns_Reading_deserialize(ZidlCdrReader *_r, ::Ns::Reading *_v);"));
}

test "cpp_backend: header CDR prototype includes serialize_key when @key present" {
    var out = try testGen("struct Msg { @key long id; string text; };", "msg");
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "#define Msg_has_key 1"));
    try testing.expect(has(s, "int Msg_serialize_key(ZidlCdrWriter *_w, const ::Msg *_v);"));
}

test "cpp_backend: cdr source banner and includes" {
    var out = try testGenCdr("struct Foo { long x; };", "types");
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "Generated by zidl from types.idl"));
    try testing.expect(has(s, "#include \"types.hpp\""));
    try testing.expect(has(s, "#include \"zidl_cdr.h\""));
}

test "cpp_backend: cdr @final struct serialize/deserialize" {
    var out = try testGenCdr(
        \\@final struct Point { long x; long y; };
    , "point");
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "int Point_serialize(ZidlCdrWriter *_w, const ::Point *_v) {"));
    try testing.expect(has(s, "zidl_cdr_write_i32(_w, _v->x)"));
    try testing.expect(has(s, "zidl_cdr_write_i32(_w, _v->y)"));
    // No DHEADER for @final.
    try testing.expect(!has(s, "reserve_dheader_maybe"));
    try testing.expect(has(s, "int Point_deserialize(ZidlCdrReader *_r, ::Point *_v) {"));
    try testing.expect(has(s, "zidl_cdr_read_i32(_r, &_v->x)"));
}

test "cpp_backend: cdr @appendable struct gets DHEADER framing" {
    var out = try testGenCdr(
        \\@appendable struct Node { long val; };
    , "node");
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "zidl_cdr_reserve_dheader_maybe(_w, &_dh)"));
    try testing.expect(has(s, "zidl_cdr_patch_dheader_maybe(_w, _dh)"));
    try testing.expect(has(s, "zidl_cdr_skip_dheader_if_xcdr2(_r)"));
}

test "cpp_backend: cdr @key serialize_key" {
    var out = try testGenCdr(
        \\struct Topic { @key long id; string name; };
    , "topic");
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "int Topic_serialize_key(ZidlCdrWriter *_w, const ::Topic *_v) {"));
    try testing.expect(has(s, "zidl_cdr_write_i32(_w, _v->id)"));
}

test "cpp_backend: cdr std::string serialize uses c_str and size" {
    var out = try testGenCdr("struct Msg { string text; };", "msg");
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "zidl_cdr_write_string(_w, _v->text.c_str(), (uint32_t)_v->text.size())"));
}

test "cpp_backend: cdr std::string deserialize uses zerocopy assign" {
    var out = try testGenCdr("struct Msg { string text; };", "msg");
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "zidl_cdr_read_string_zerocopy(_r, &_sp, &_sl)"));
    try testing.expect(has(s, "_v->text.assign(_sp, _sl)"));
}

test "cpp_backend: cdr bounded string deserialize checks bound" {
    var out = try testGenCdr("struct Msg { string<64> name; };", "msg");
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "if (_sl > 64u) return ZIDL_CDR_INVALID"));
    try testing.expect(has(s, "_v->name.assign(_sp, _sl)"));
}

test "cpp_backend: cdr std::vector serialize" {
    var out = try testGenCdr("struct List { sequence<long> items; };", "list");
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "zidl_cdr_write_u32(_w, (uint32_t)_v->items.size())"));
    try testing.expect(has(s, "_v->items.size(); _si++"));
    try testing.expect(has(s, "zidl_cdr_write_i32(_w, _v->items[_si])"));
}

test "cpp_backend: cdr std::vector deserialize uses resize" {
    var out = try testGenCdr("struct List { sequence<long> items; };", "list");
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "_v->items.resize(_sl)"));
    try testing.expect(has(s, "zidl_cdr_read_i32(_r, &_v->items[_si])"));
}

test "cpp_backend: cdr enum class uses static_cast" {
    var out = try testGenCdr(
        \\enum Color { RED, GREEN, BLUE };
        \\struct Pixel { Color c; };
    , "px");
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "zidl_cdr_write_u32(_w, static_cast<uint32_t>(_v->c))"));
    try testing.expect(has(s, "static_cast<::Color>(_ev)"));
}

test "cpp_backend: cdr nested struct calls serialize/deserialize by name" {
    var out = try testGenCdr(
        \\struct Inner { long v; };
        \\struct Outer { Inner inner; };
    , "nested");
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "Inner_serialize(_w, &_v->inner)"));
    try testing.expect(has(s, "Inner_deserialize(_r, &_v->inner)"));
}

test "cpp_backend: cdr array member generates loop" {
    var out = try testGenCdr("struct Mat { long data[3]; };", "mat");
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "for (_ai0 = 0; _ai0 < 3u; _ai0++)"));
    try testing.expect(has(s, "zidl_cdr_write_i32(_w, _v->data[_ai0])"));
    try testing.expect(has(s, "zidl_cdr_read_i32(_r, &_v->data[_ai0])"));
}

test "cpp_backend: cdr all primitives serialize" {
    var out = try testGenCdr(
        \\struct Prims {
        \\  boolean b; octet o; char c; short s; long l;
        \\  unsigned long ul; long long ll; float f; double d;
        \\};
    , "prims");
    defer out.deinit(testing.allocator);
    const src = out.items;
    try testing.expect(has(src, "zidl_cdr_write_bool(_w, _v->b)"));
    try testing.expect(has(src, "zidl_cdr_write_u8(_w, _v->o)"));
    try testing.expect(has(src, "zidl_cdr_write_char(_w, _v->c)"));
    try testing.expect(has(src, "zidl_cdr_write_i16(_w, _v->s)"));
    try testing.expect(has(src, "zidl_cdr_write_i32(_w, _v->l)"));
    try testing.expect(has(src, "zidl_cdr_write_u32(_w, _v->ul)"));
    try testing.expect(has(src, "zidl_cdr_write_i64(_w, _v->ll)"));
    try testing.expect(has(src, "zidl_cdr_write_f32(_w, _v->f)"));
    try testing.expect(has(src, "zidl_cdr_write_f64(_w, _v->d)"));
}

test "cpp_backend: cdr @optional scalar serialize writes bool then value" {
    var out = try testGenCdr(
        \\struct Opt { @optional long maybe_x; long y; };
    , "opt");
    defer out.deinit(testing.allocator);
    const s = out.items;
    // Presence flag written before value.
    try testing.expect(has(s, "zidl_cdr_write_bool(_w, _v->maybe_x.has_value() ? 1 : 0)"));
    // Inner value accessed via dereference.
    try testing.expect(has(s, "zidl_cdr_write_i32(_w, (*_v->maybe_x))"));
    // Non-optional field unaffected.
    try testing.expect(has(s, "zidl_cdr_write_i32(_w, _v->y)"));
}

test "cpp_backend: cdr @optional scalar deserialize reads bool then emplaces" {
    var out = try testGenCdr(
        \\struct Opt { @optional long maybe_x; long y; };
    , "opt");
    defer out.deinit(testing.allocator);
    const s = out.items;
    // Presence flag read.
    try testing.expect(has(s, "zidl_cdr_read_bool(_r, &_ip_maybe_x)"));
    // Emplace + read inner value on present.
    try testing.expect(has(s, "_v->maybe_x.emplace()"));
    try testing.expect(has(s, "zidl_cdr_read_i32(_r, &(*_v->maybe_x))"));
    // Nullopt on absent.
    try testing.expect(has(s, "_v->maybe_x = std::nullopt"));
}

// ── wstring CDR tests ─────────────────────────────────────────────────────────

test "cpp_backend cdr: wstring write emits u32 count then u16 loop" {
    var out = try testGenCdr("struct S { wstring ws; };", "s");
    defer out.deinit(testing.allocator);
    const s = out.items;
    // Count written as u32 (length + 1 for NUL wchar).
    try testing.expect(has(s, "zidl_cdr_write_u32(_w, _wl + 1u)"));
    // Each wchar_t cast to uint16_t and written as u16.
    try testing.expect(has(s, "zidl_cdr_write_u16(_w, (uint16_t)"));
    // Terminating NUL wchar.
    try testing.expect(has(s, "zidl_cdr_write_u16(_w, 0u)"));
}

test "cpp_backend cdr: wstring read decodes u32 count then u16 chars" {
    var out = try testGenCdr("struct S { wstring ws; };", "s");
    defer out.deinit(testing.allocator);
    const s = out.items;
    // Count read as u32.
    try testing.expect(has(s, "zidl_cdr_read_u32(_r, &_wc)"));
    // Each u16 read and cast to wchar_t.
    try testing.expect(has(s, "zidl_cdr_read_u16(_r, &_wv)"));
    try testing.expect(has(s, "(wchar_t)_wv"));
    // NUL wchar consumed.
    try testing.expect(has(s, "zidl_cdr_read_u16(_r, &_nul)"));
}

test "cpp_backend cdr: bounded wstring read includes bound check" {
    var out = try testGenCdr("struct S { wstring<8> ws; };", "s");
    defer out.deinit(testing.allocator);
    // Bound check with the correct value (8).
    try testing.expect(has(out.items, "8u"));
    try testing.expect(has(out.items, "ZIDL_CDR_INVALID"));
}

test "cpp_backend cdr: unbounded wstring read has no bound check" {
    var out = try testGenCdr("struct S { wstring ws; };", "s");
    defer out.deinit(testing.allocator);
    // The 8u bound guard from the bounded test must not appear here.
    try testing.expect(!has(out.items, "8u"));
}

// ── --generate-interfaces tests ───────────────────────────────────────────────

fn testGenImpl(source: []const u8, stem: []const u8) !std.ArrayList(u8) {
    return testGenImplOpts(source, stem, .{});
}

fn testGenImplOpts(source: []const u8, stem: []const u8, extra: struct {
    cpp_pmr_containers: bool = false,
}) !std.ArrayList(u8) {
    const alloc = testing.allocator;
    var ast_arena = std.heap.ArenaAllocator.init(alloc);
    defer ast_arena.deinit();
    var p = parser_mod.Parser.init(source, ast_arena.allocator());
    const spec = try p.parseSpecification();
    var az = try semantic_mod.Analyzer.init(alloc);
    defer az.deinit();
    try az.analyze(&spec);
    var ir_spec = try ir.build(alloc, &spec, az.global_scope, &.{});
    defer ir_spec.deinit();
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(alloc);
    const opts = interface.Options{
        .input_stem = stem,
        .generate_interfaces = true,
        .cpp_pmr_containers = extra.cpp_pmr_containers,
    };
    try generateImplSource(alloc, &ir_spec, opts, &out);
    return out;
}

test "cpp_backend: impl source includes header" {
    var out = try testGenImpl("interface Foo { void bar(); };", "foo");
    defer out.deinit(testing.allocator);
    try testing.expect(has(out.items, "#include \"foo.hpp\""));
}

test "cpp_backend: impl source extern C block" {
    var out = try testGenImpl(
        \\interface Calc { long add(in long a, in long b); void reset(); };
    , "calc");
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "extern \"C\" {"));
    try testing.expect(has(s, "int32_t zidl_Calc_add(void *ptr, int32_t a, int32_t b);"));
    try testing.expect(has(s, "void zidl_Calc_reset(void *ptr);"));
    try testing.expect(has(s, "void zidl_Calc_deinit(void *ptr);"));
}

test "cpp_backend: impl source Impl class" {
    var out = try testGenImpl(
        \\interface Calc { long add(in long a, in long b); void reset(); };
    , "calc");
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "class CalcImpl : public ::Calc {"));
    try testing.expect(has(s, "explicit CalcImpl(void *ptr) : ptr_(ptr) {}"));
    try testing.expect(has(s, "~CalcImpl() override { zidl_Calc_deinit(ptr_); }"));
    try testing.expect(has(s, "int32_t add(int32_t a, int32_t b) override {"));
    try testing.expect(has(s, "return zidl_Calc_add(ptr_, a, b);"));
    try testing.expect(has(s, "void reset() override {"));
    try testing.expect(has(s, "zidl_Calc_reset(ptr_);"));
    try testing.expect(has(s, "private:"));
    try testing.expect(has(s, "void *ptr_;"));
}

// ── split-file tests ──────────────────────────────────────────────────────────

/// Build IR from `source`, call `generateTypeHeader` for the TypeDecl at `idx`.
fn testGenTypeHeader(source: []const u8, stem: []const u8, idx: usize) !std.ArrayList(u8) {
    return testGenTypeHeaderOpts(source, stem, idx, .{});
}

fn testGenTypeHeaderOpts(source: []const u8, stem: []const u8, idx: usize, extra: struct {
    generate_zzdds_wrappers: bool = false,
    no_typesupport: bool = false,
}) !std.ArrayList(u8) {
    const alloc = testing.allocator;
    var ast_arena = std.heap.ArenaAllocator.init(alloc);
    defer ast_arena.deinit();
    var p = parser_mod.Parser.init(source, ast_arena.allocator());
    const spec = try p.parseSpecification();
    var az = try semantic_mod.Analyzer.init(alloc);
    defer az.deinit();
    try az.analyze(&spec);
    var ir_spec = try ir.build(alloc, &spec, az.global_scope, &.{});
    defer ir_spec.deinit();
    var decls = std.ArrayListUnmanaged(ir.TypeDecl).empty;
    defer decls.deinit(alloc);
    try collectTypeDeclsFlat(alloc, ir_spec.items, &decls);
    const opts = interface.Options{
        .input_stem = stem,
        .generate_zzdds_wrappers = extra.generate_zzdds_wrappers,
        .no_typesupport = extra.no_typesupport,
    };
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(alloc);
    try generateTypeHeader(alloc, decls.items[idx], opts, &out);
    return out;
}

test "cpp_backend split: enum gets own header with guard" {
    var out = try testGenTypeHeader("enum Color { RED, GREEN, BLUE };", "color", 0);
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "#ifndef COLOR_HPP"));
    try testing.expect(has(s, "#define COLOR_HPP"));
    try testing.expect(has(s, "enum class Color"));
    try testing.expect(has(s, "#endif // COLOR_HPP"));
    try testing.expect(!has(s, "zidl_cdr.h"));
}

test "cpp_backend split: struct includes deps" {
    var out = try testGenTypeHeader(
        \\enum Color { RED };
        \\struct Foo { Color c; };
    , "types", 1);
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "#include \"Color.hpp\""));
    try testing.expect(has(s, "#include \"zidl_cdr.h\""));
    try testing.expect(has(s, "struct Foo"));
}

test "cpp_backend split: zzdds wrapper header includes zzdds_c" {
    var out = try testGenTypeHeaderOpts(
        "@appendable struct Topic { @key long id; string<16> name; };",
        "topic",
        0,
        .{ .generate_zzdds_wrappers = true },
    );
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "#include \"zidl_cdr.h\""));
    try testing.expect(has(s, "#include \"zzdds_c.h\""));
    try testing.expect(has(s, "class TopicDataWriter"));
}

test "cpp_backend split: aggregate header includes all types" {
    const alloc = testing.allocator;
    var ast_arena = std.heap.ArenaAllocator.init(alloc);
    defer ast_arena.deinit();
    const source = "enum Color { RED }; struct Foo { long x; };";
    var p = parser_mod.Parser.init(source, ast_arena.allocator());
    const spec = try p.parseSpecification();
    var az = try semantic_mod.Analyzer.init(alloc);
    defer az.deinit();
    try az.analyze(&spec);
    var ir_spec = try ir.build(alloc, &spec, az.global_scope, &.{});
    defer ir_spec.deinit();
    var decls = std.ArrayListUnmanaged(ir.TypeDecl).empty;
    defer decls.deinit(alloc);
    try collectTypeDeclsFlat(alloc, ir_spec.items, &decls);
    const opts = interface.Options{ .input_stem = "types" };
    var out = std.ArrayList(u8).empty;
    defer out.deinit(alloc);
    try generateAggregateHeader(alloc, decls.items, opts, &out);
    const s = out.items;
    try testing.expect(has(s, "#ifndef TYPES_ALL_HPP"));
    try testing.expect(has(s, "#include \"Color.hpp\""));
    try testing.expect(has(s, "#include \"Foo.hpp\""));
}

test "cpp_backend type_prefix: CDR function prototypes use prefix" {
    var h = try testGenOpts("struct Foo { long x; };", "t", .{ .type_prefix = "DDS_" });
    defer h.deinit(testing.allocator);
    // CDR proto in header uses prefixed flat name.
    try testing.expect(has(h.items, "DDS_Foo_serialize("));
    try testing.expect(has(h.items, "DDS_Foo_deserialize("));
}

test "cpp_backend type_prefix: C++ type names inside namespace NOT prefixed" {
    var h = try testGenOpts("module M { struct Bar { long x; }; };", "t", .{ .type_prefix = "DDS_" });
    defer h.deinit(testing.allocator);
    // Namespace M and struct Bar retain their original names.
    try testing.expect(has(h.items, "namespace M {"));
    try testing.expect(has(h.items, "struct Bar {"));
    // But the CDR flat function IS prefixed.
    try testing.expect(has(h.items, "DDS_M_Bar_serialize("));
}

test "cpp_backend type_prefix: CDR source function name uses prefix" {
    var src = try testGenCdrOpts("struct Foo { long x; };", "t", .{ .type_prefix = "DDS_" });
    defer src.deinit(testing.allocator);
    try testing.expect(has(src.items, "DDS_Foo_serialize("));
    try testing.expect(has(src.items, "DDS_Foo_deserialize("));
}

test "cpp_backend pragma_once: replaces ifndef/define/endif guard" {
    var h = try testGenOpts("struct Foo { long x; };", "foo", .{ .pragma_once = true });
    defer h.deinit(testing.allocator);
    const s = h.items;
    try testing.expect(has(s, "#pragma once"));
    try testing.expect(!has(s, "#ifndef FOO_HPP"));
    try testing.expect(!has(s, "#define FOO_HPP"));
    try testing.expect(!has(s, "#endif // FOO_HPP"));
}

test "cpp_backend export_macro: prepended to CDR function declarations in header" {
    var h = try testGenOpts("struct Foo { long x; };", "foo", .{ .export_macro = "MY_EXPORT" });
    defer h.deinit(testing.allocator);
    const s = h.items;
    try testing.expect(has(s, "MY_EXPORT int Foo_serialize("));
    try testing.expect(has(s, "MY_EXPORT int Foo_deserialize("));
    try testing.expect(has(s, "MY_EXPORT int Foo_skip("));
}

test "cpp_backend cpp_namespace: wraps output in named namespace" {
    var h = try testGenOpts("struct Foo { long x; };", "foo", .{ .cpp_namespace = "dds" });
    defer h.deinit(testing.allocator);
    const s = h.items;
    try testing.expect(has(s, "namespace dds {"));
    try testing.expect(has(s, "} // namespace dds"));
    // The IDL struct is inside the outer namespace.
    const ns_open = std.mem.indexOf(u8, s, "namespace dds {").?;
    const struct_pos = std.mem.indexOf(u8, s, "struct Foo {").?;
    const ns_close = std.mem.indexOf(u8, s, "} // namespace dds").?;
    try testing.expect(struct_pos > ns_open);
    try testing.expect(struct_pos < ns_close);
}

test "cpp_backend pragma_once split: per-type header uses pragma once" {
    const alloc = testing.allocator;
    var ast_arena = std.heap.ArenaAllocator.init(alloc);
    defer ast_arena.deinit();
    var p = parser_mod.Parser.init("struct Foo { long x; };", ast_arena.allocator());
    const spec = try p.parseSpecification();
    var az = try semantic_mod.Analyzer.init(alloc);
    defer az.deinit();
    try az.analyze(&spec);
    var ir_spec = try ir.build(alloc, &spec, az.global_scope, &.{});
    defer ir_spec.deinit();
    var out = std.ArrayList(u8).empty;
    defer out.deinit(alloc);
    try generateTypeHeader(alloc, ir_spec.items[0].type_decl, interface.Options{
        .input_stem = "foo",
        .pragma_once = true,
    }, &out);
    const s = out.items;
    try testing.expect(has(s, "#pragma once"));
    try testing.expect(!has(s, "#ifndef"));
    try testing.expect(!has(s, "#endif"));
}

test "cpp_backend cdr: fixed<5,2> serialize/deserialize" {
    var cpp_src = try testGenCdr("struct S { fixed<5,2> price; };", "fp");
    defer cpp_src.deinit(testing.allocator);
    const s = cpp_src.items;
    try testing.expect(has(s, "zidl_cdr_write_fixed(_w, 5, 2, _v->price)"));
    try testing.expect(has(s, "zidl_cdr_read_fixed(_r, 5, 2, &_v->price)"));
}

test "cpp_backend: fixed<5,2> field type is double" {
    var h = try testGen("struct S { fixed<5,2> price; };", "fp");
    defer h.deinit(testing.allocator);
    try testing.expect(has(h.items, "double price{}")); // C++ brace-initialization
}

test "cpp_backend: union with typedef discriminant decl" {
    var out = try testGen(
        \\typedef long MyDisc;
        \\union Var switch (MyDisc) { case 0: long i; case 1: double d; };
    , "var");
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "class Var {"));
    // Discriminant getter/setter use the typedef type
    try testing.expect(has(s, "::MyDisc _d() const noexcept"));
    try testing.expect(has(s, "}; // class Var"));
}

test "cpp_backend: union with typedef discriminant CDR" {
    var out = try testGenCdr(
        \\typedef long MyDisc;
        \\union Var switch (MyDisc) { case 0: long i; case 1: double d; };
    , "var");
    defer out.deinit(testing.allocator);
    const s = out.items;
    // Serialize: typedef resolves to long → zidl_cdr_write_i32
    try testing.expect(has(s, "zidl_cdr_write_i32"));
    // Deserialize: typedef resolves to long → zidl_cdr_read_i32
    try testing.expect(has(s, "zidl_cdr_read_i32"));
    // No TODO stubs
    try testing.expect(!has(s, "TODO"));
}

test "cpp_backend: union with enum typedef discriminant CDR" {
    var out = try testGenCdr(
        \\enum Kind { A, B };
        \\typedef Kind KindAlias;
        \\union Var switch (KindAlias) { case A: long i; case B: double d; };
    , "var");
    defer out.deinit(testing.allocator);
    const s = out.items;
    // Enum typedef resolves to Kind → zidl_cdr_write_u32
    try testing.expect(has(s, "zidl_cdr_write_u32"));
    try testing.expect(has(s, "zidl_cdr_read_u32"));
    // Case labels use the underlying enum's qualified name
    try testing.expect(has(s, "case ::Kind::A:"));
    try testing.expect(has(s, "case ::Kind::B:"));
    try testing.expect(!has(s, "TODO"));
}

test "cpp_backend cdr: zzdds wrapper implementations for keyed topic" {
    var out = try testGenCdrOpts(
        "@appendable struct Topic { @key long id; string<16> name; };",
        "topic",
        .{ .generate_zzdds_wrappers = true },
    );
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "#include \"zzdds_c.h\""));
    try testing.expect(has(s, "int TopicTypeSupport::register_type(DDS_DomainParticipant participant, const char *type_name) {"));
    try testing.expect(has(s, "static int Topic_write_kind(DDS_DataWriter writer, int xcdr_version, DDS_WriteKind kind, const ::Topic& value, bool key_only, DDS_InstanceHandle_t handle) {"));
    try testing.expect(has(s, "return Topic_write_kind(writer_, xcdr_version_, DDS_WriteKind_ALIVE_WRITE_KIND, value, false, DDS_HANDLE_NIL);"));
    try testing.expect(has(s, "DDS_ReturnCode_t TopicDataReader::take_loaned(Loan& out) {"));
    try testing.expect(has(s, "out = Loan(this, _loan_payloads, _loan_infos, _sample);"));
    try testing.expect(has(s, "void TopicDataReader::Loan::reset() {"));
    try testing.expect(has(s, "DDS_DataReader_return_loan_raw(reader_->reader_, &loan_payloads_, &_c_no_hashes, &loan_infos_);"));
}

test "cpp_backend cdr: _reader_decode_batch cleans up partial samples on deserialization failure" {
    var out = try testGenCdrOpts(
        "@appendable struct Topic { @key long id; string name; };",
        "topic",
        .{ .generate_zzdds_wrappers = true },
    );
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "for (uint32_t _j = 0; _j <= _i; _j++) values[_j] = {};"));
    try testing.expect(has(s, "DDS_DataReader_return_loan_raw(reader, _payloads, _hashes, _infos);"));
}

// ── _w_condition family / batch take_instance / register_instance_w_timestamp ──

test "cpp_backend: zzdds wrapper declarations include the _w_condition family, batch take_instance, and register_instance_w_timestamp" {
    var out = try testGenOpts(
        "@appendable struct Topic { @key long id; string<16> name; };",
        "topic",
        .{ .generate_zzdds_wrappers = true },
    );
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "DDS_InstanceHandle_t register_instance_w_timestamp(const ::Topic& key, DDS_Time_t timestamp);"));
    try testing.expect(has(s, "int take_instance(DDS_InstanceHandle_t instance_handle, ::Topic *values, DDS_SampleInfo *infos, int max, uint32_t ss, uint32_t vs, uint32_t is);"));
    try testing.expect(has(s, "int read_instance(DDS_InstanceHandle_t instance_handle, ::Topic *values, DDS_SampleInfo *infos, int max, uint32_t ss, uint32_t vs, uint32_t is);"));
    try testing.expect(has(s, "int take_w_condition(DDS_ReadCondition condition, ::Topic *values, DDS_SampleInfo *infos, int max);"));
    try testing.expect(has(s, "int read_w_condition(DDS_ReadCondition condition, ::Topic *values, DDS_SampleInfo *infos, int max);"));
    try testing.expect(has(s, "int take_next_instance_w_condition(DDS_ReadCondition condition, DDS_InstanceHandle_t prev, ::Topic *values, DDS_SampleInfo *infos, int max);"));
    try testing.expect(has(s, "int read_next_instance_w_condition(DDS_ReadCondition condition, DDS_InstanceHandle_t prev, ::Topic *values, DDS_SampleInfo *infos, int max);"));
}

test "cpp_backend cdr: register_instance_w_timestamp ignores its timestamp and delegates to register_instance" {
    var out = try testGenCdrOpts(
        "@appendable struct Topic { @key long id; };",
        "topic",
        .{ .generate_zzdds_wrappers = true },
    );
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "DDS_InstanceHandle_t TopicDataWriter::register_instance_w_timestamp(const ::Topic& key, DDS_Time_t timestamp) {"));
    try testing.expect(has(s, "(void)timestamp;"));
    try testing.expect(has(s, "return register_instance(key);"));
}

test "cpp_backend cdr: take_instance/read_instance call the instance-scoped raw ops" {
    var out = try testGenCdrOpts(
        "@appendable struct Topic { @key long id; };",
        "topic",
        .{ .generate_zzdds_wrappers = true },
    );
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "DDS_DataReader_take_raw(reader, &_c_payloads, &_c_hashes, &_c_infos, instance_handle, nullptr, ss, vs, is, max) :"));
    try testing.expect(has(s, "DDS_DataReader_read_raw(reader, &_c_payloads, &_c_hashes, &_c_infos, instance_handle, nullptr, ss, vs, is, max);"));
    try testing.expect(has(s, "int TopicDataReader::take_instance(DDS_InstanceHandle_t instance_handle, ::Topic *values, DDS_SampleInfo *infos, int max, uint32_t ss, uint32_t vs, uint32_t is) {"));
}

test "cpp_backend cdr: take_w_condition/read_w_condition call DDS_DataReader_take_raw/read_raw with the condition" {
    var out = try testGenCdrOpts(
        "@appendable struct Topic { @key long id; };",
        "topic",
        .{ .generate_zzdds_wrappers = true },
    );
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "DDS_DataReader_take_raw(reader, &_c_payloads, &_c_hashes, &_c_infos, DDS_HANDLE_NIL, condition, DDS_ANY_SAMPLE_STATE, DDS_ANY_VIEW_STATE, DDS_ANY_INSTANCE_STATE, max) :"));
    try testing.expect(has(s, "DDS_DataReader_read_raw(reader, &_c_payloads, &_c_hashes, &_c_infos, DDS_HANDLE_NIL, condition, DDS_ANY_SAMPLE_STATE, DDS_ANY_VIEW_STATE, DDS_ANY_INSTANCE_STATE, max);"));
    try testing.expect(has(s, "int TopicDataReader::take_w_condition(DDS_ReadCondition condition, ::Topic *values, DDS_SampleInfo *infos, int max) {"));
}

test "cpp_backend cdr: take_next_instance_w_condition/read_next_instance_w_condition call the matching raw ops" {
    var out = try testGenCdrOpts(
        "@appendable struct Topic { @key long id; };",
        "topic",
        .{ .generate_zzdds_wrappers = true },
    );
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "DDS_DataReader_take_next_instance_raw(reader, &_c_payloads, &_c_hashes, &_c_infos, prev, condition, DDS_ANY_SAMPLE_STATE, DDS_ANY_VIEW_STATE, DDS_ANY_INSTANCE_STATE, max) :"));
    try testing.expect(has(s, "DDS_DataReader_read_next_instance_raw(reader, &_c_payloads, &_c_hashes, &_c_infos, prev, condition, DDS_ANY_SAMPLE_STATE, DDS_ANY_VIEW_STATE, DDS_ANY_INSTANCE_STATE, max);"));
    try testing.expect(has(s, "int TopicDataReader::take_next_instance_w_condition(DDS_ReadCondition condition, DDS_InstanceHandle_t prev, ::Topic *values, DDS_SampleInfo *infos, int max) {"));
}

test "cpp_backend cdr: _reader_decode_batch cleans up partial samples on deserialization failure (instance)" {
    var out = try testGenCdrOpts(
        "@appendable struct Topic { @key long id; string name; };",
        "topic",
        .{ .generate_zzdds_wrappers = true },
    );
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "static int Topic_reader_decode_batch(DDS_DataReader reader, DDS_OctetSeqSeq *_payloads, DDS_OctetSeq *_hashes, DDS_SampleInfoSeq *_infos, ::Topic *values, DDS_SampleInfo *infos) {"));
    try testing.expect(has(s, "for (uint32_t _j = 0; _j <= _i; _j++) values[_j] = {};"));
}

test "cpp_backend: A1+A2 — namespaced struct uses IDL-scoped type name and namespace wrapper" {
    // A2: wrapper classes live inside namespace ovidds, not at global scope
    // A1: default type_name is "ovidds::Frame", not "ovidds_Frame"
    var out = try testGenOpts(
        "module ovidds { @appendable struct Frame { @key long id; }; };",
        "frame",
        .{ .generate_zzdds_wrappers = true },
    );
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "namespace ovidds {"));
    try testing.expect(has(s, "class FrameTypeSupport {"));
    try testing.expect(has(s, "class FrameDataWriter {"));
    try testing.expect(has(s, "class FrameDataReader {"));
    try testing.expect(has(s, "static int register_type(DDS_DomainParticipant participant, const char *type_name = \"ovidds::Frame\");"));
    try testing.expect(!has(s, "class ovidds_FrameTypeSupport {"));
    try testing.expect(!has(s, "\"ovidds_Frame\""));
}

test "cpp_backend cdr: A1+A2 — namespaced struct uses IDL-scoped type name and namespace wrapper" {
    // A2: wrapper method impls and static helpers live inside namespace ovidds
    // A1: fallback type_name string is "ovidds::Frame"
    var out = try testGenCdrOpts(
        "module ovidds { @appendable struct Frame { @key long id; }; };",
        "frame",
        .{ .generate_zzdds_wrappers = true },
    );
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "namespace ovidds {"));
    try testing.expect(has(s, "int FrameTypeSupport::register_type(DDS_DomainParticipant participant, const char *type_name) {"));
    try testing.expect(has(s, "\"ovidds::Frame\""));
    try testing.expect(has(s, "static int Frame_write_kind("));
    try testing.expect(has(s, "return Frame_write_kind(writer_,"));
    try testing.expect(has(s, "void FrameDataReader::Loan::reset() {"));
    try testing.expect(!has(s, "int ovidds_FrameTypeSupport::"));
    try testing.expect(!has(s, "\"ovidds_Frame\""));
}

test "cpp_backend cdr: zzdds_c omitted when no qualifying topic struct" {
    var out = try testGenCdrOpts(
        "@nested struct NestedPlain { long id; }; @nested struct NestedKey { @key long id; }; @mutable struct MutableKey { @key long id; };",
        "plain",
        .{ .generate_zzdds_wrappers = true },
    );
    defer out.deinit(testing.allocator);
    try testing.expect(!has(out.items, "zzdds_c.h"));
}

test "cpp_backend: @verbatim before-declaration on struct" {
    var out = try testGen(
        \\@verbatim(language="cpp", placement="before-declaration", text="// injected before")
        \\struct Foo { long x; };
    , "foo");
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "// injected before"));
    // Verbatim text appears before the struct declaration
    const before_pos = std.mem.indexOf(u8, s, "// injected before").?;
    const struct_pos = std.mem.indexOf(u8, s, "struct Foo {").?;
    try testing.expect(before_pos < struct_pos);
}

test "cpp_backend: @verbatim after-declaration on struct" {
    var out = try testGen(
        \\@verbatim(language="cpp", placement="after-declaration", text="// injected after")
        \\struct Foo { long x; };
    , "foo");
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "// injected after"));
    // Verbatim text appears after the closing brace
    const struct_end_pos = std.mem.indexOf(u8, s, "}; // struct Foo").?;
    const after_pos = std.mem.indexOf(u8, s, "// injected after").?;
    try testing.expect(after_pos > struct_end_pos);
}

test "cpp_backend: @verbatim language filter" {
    // language="c" should NOT appear in C++ output
    var out = try testGen(
        \\@verbatim(language="c", placement="before-declaration", text="/* C only */")
        \\struct Foo { long x; };
    , "foo");
    defer out.deinit(testing.allocator);
    try testing.expect(!has(out.items, "/* C only */"));
}

test "cpp_backend: @verbatim language wildcard" {
    // language="*" should appear in all backends
    var out = try testGen(
        \\@verbatim(language="*", placement="before-declaration", text="// all languages")
        \\struct Foo { long x; };
    , "foo");
    defer out.deinit(testing.allocator);
    try testing.expect(has(out.items, "// all languages"));
}

test "cpp_backend: impl void op with string param forwards via c_str" {
    var out = try testGenImpl(
        \\interface Greeter { void greetAdvanced(in string name); };
    , "greeter");
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "void greetAdvanced(std::string name) override {"));
    try testing.expect(has(s, "zidl_Greeter_greetAdvanced(ptr_, name.c_str());"));
    try testing.expect(!has(s, "TODO"));
}

test "cpp_backend: impl interface parameter uses shared_ptr signature" {
    var out = try testGenImpl(
        \\interface DataWriter {};
        \\interface Listener { void on_data(in DataWriter writer); };
    , "listener");
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "void on_data(std::shared_ptr<::DataWriter> writer) override {"));
    try testing.expect(has(s, "/* TODO: adapt C++ types to C ABI for Listener::on_data */"));
}

test "cpp_backend: impl simple return with string param forwards correctly" {
    var out = try testGenImpl(
        \\interface Foo { long compute(in string key); };
    , "foo");
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "int32_t compute(std::string key) override {"));
    try testing.expect(has(s, "return zidl_Foo_compute(ptr_, key.c_str());"));
    try testing.expect(!has(s, "TODO"));
}

test "cpp_backend: --cpp-pmr-containers on — impl string-returning op/attr use std::pmr::string" {
    var out = try testGenImplOpts(
        \\interface Foo {
        \\  string greet();
        \\  readonly attribute string label;
        \\};
    , "foo", .{ .cpp_pmr_containers = true });
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "return std::pmr::string(zidl_Foo_greet(ptr_));"));
    try testing.expect(has(s, "return std::pmr::string(zidl_Foo_get_label(ptr_));"));
    try testing.expect(!has(s, "std::string(zidl_"));
}

test "cpp_backend: @default on non-optional field sets initializer" {
    var h = try testGen(
        \\struct Cfg {
        \\    @default(7400) unsigned short base_port;
        \\    @default(TRUE) boolean active;
        \\    @default(3.14) double threshold;
        \\    @default("hi") string label;
        \\};
    , "cfg");
    defer h.deinit(testing.allocator);
    const s = h.items;
    try testing.expect(has(s, "uint16_t base_port{7400};"));
    try testing.expect(has(s, "bool active{true};"));
    try testing.expect(has(s, "double threshold{"));
    try testing.expect(has(s, "std::string label{\"hi\"};"));
}

test "cpp_backend: @optional with @default sets optional initializer" {
    var h = try testGen(
        \\struct Cfg {
        \\    @optional @default(42) long value;
        \\};
    , "cfg");
    defer h.deinit(testing.allocator);
    try testing.expect(has(h.items, "std::optional<int32_t> value{42};"));
}

test "cpp_backend: @optional without @default uses empty braces" {
    var h = try testGen(
        \\struct Cfg {
        \\    @optional long val;
        \\};
    , "cfg");
    defer h.deinit(testing.allocator);
    try testing.expect(has(h.items, "std::optional<int32_t> val{};"));
}

test "cpp_backend: @default float field appends f suffix to avoid narrowing" {
    var h = try testGen(
        \\struct Cfg { @default(3.14) float speed; };
    , "cfg");
    defer h.deinit(testing.allocator);
    try testing.expect(has(h.items, "float speed{3.14f};"));
}

test "cpp_backend: @default char field emits char literal" {
    var h = try testGen(
        \\struct Cfg { @default('A') char c; };
    , "cfg");
    defer h.deinit(testing.allocator);
    try testing.expect(has(h.items, "char c{'A'};"));
}

test "cpp_backend: @default scoped_name emits identifier" {
    var h = try testGen(
        \\const long MY_MAX = 100;
        \\struct Cfg { @default(MY_MAX) long limit; };
    , "cfg");
    defer h.deinit(testing.allocator);
    try testing.expect(has(h.items, "int32_t limit{MY_MAX};"));
}

test "cpp_backend: @default enum scoped_name emits enum class value" {
    var h = try testGen(
        \\enum Kind { FIRST, SECOND };
        \\struct Cfg { @default(SECOND) Kind kind; };
    , "cfg");
    defer h.deinit(testing.allocator);
    try testing.expect(has(h.items, "::Kind kind{::Kind::SECOND};"));
}

test "cpp_backend: @default bitmask scoped_name emits generated bit constant" {
    var h = try testGen(
        \\bitmask Flags { READ, WRITE };
        \\struct Cfg { @default(WRITE) Flags flags; };
    , "cfg");
    defer h.deinit(testing.allocator);
    try testing.expect(has(h.items, "::Flags flags{::Flags_WRITE};"));
}

test "cpp_backend: B2 — write_w_handle/dispose_w_handle/unregister_instance_w_handle declared in header" {
    var out = try testGenOpts(
        "@appendable struct Topic { @key long id; };",
        "topic",
        .{ .generate_zzdds_wrappers = true },
    );
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "int write_w_handle(const ::Topic& value, DDS_InstanceHandle_t handle);"));
    try testing.expect(has(s, "int dispose_w_handle(const ::Topic& key, DDS_InstanceHandle_t handle);"));
    try testing.expect(has(s, "int unregister_instance_w_handle(const ::Topic& key, DDS_InstanceHandle_t handle);"));
    try testing.expect(has(s, "std::unordered_map<DDS_InstanceHandle_t, std::array<uint8_t, 16>> instance_handles_;"));
    try testing.expect(has(s, "#include <unordered_map>"));
}

test "cpp_backend cdr: B2 — write_w_handle/dispose_w_handle/unregister_instance_w_handle implemented" {
    var out = try testGenCdrOpts(
        "@appendable struct Topic { @key long id; };",
        "topic",
        .{ .generate_zzdds_wrappers = true },
    );
    defer out.deinit(testing.allocator);
    const s = out.items;
    // register_instance caches the hash
    try testing.expect(has(s, "instance_handles_[_ih] = _arr;"));
    // static helper for hash-based writes
    try testing.expect(has(s, "static int Topic_write_kind_w_hash("));
    // three _w_handle implementations
    try testing.expect(has(s, "int TopicDataWriter::write_w_handle(const ::Topic& value, DDS_InstanceHandle_t handle) {"));
    try testing.expect(has(s, "int TopicDataWriter::dispose_w_handle(const ::Topic& key, DDS_InstanceHandle_t handle) {"));
    try testing.expect(has(s, "int TopicDataWriter::unregister_instance_w_handle(const ::Topic& key, DDS_InstanceHandle_t handle) {"));
    try testing.expect(has(s, "if (it == instance_handles_.end()) return DDS_RETCODE_BAD_PARAMETER;"));
    try testing.expect(has(s, "if (!_rc) instance_handles_.erase(it);"));
}

// ── --cpp-generate-impl tests (B1+B3) ────────────────────────────────────────

const ConcreteImplResult = struct {
    hdr: std.ArrayList(u8),
    src: std.ArrayList(u8),
    fn deinit(self: *ConcreteImplResult) void {
        self.hdr.deinit(testing.allocator);
        self.src.deinit(testing.allocator);
    }
};

fn testGenConcreteImpl(source: []const u8) !ConcreteImplResult {
    return testGenConcreteImplOpts(source, .{});
}

fn testGenConcreteImplOpts(source: []const u8, extra: struct {
    cpp_pmr_containers: bool = false,
    cpp_impl_overrides: []const []const u8 = &.{},
    cpp_impl_includes: []const []const u8 = &.{},
}) !ConcreteImplResult {
    const alloc = testing.allocator;
    var ast_arena = std.heap.ArenaAllocator.init(alloc);
    defer ast_arena.deinit();
    var p = parser_mod.Parser.init(source, ast_arena.allocator());
    const spec = try p.parseSpecification();
    var az = try semantic_mod.Analyzer.init(alloc);
    defer az.deinit();
    try az.analyze(&spec);
    var ir_spec = try ir.build(alloc, &spec, az.global_scope, &.{});
    defer ir_spec.deinit();
    const opts = interface.Options{
        .input_stem = "dcps",
        .cpp_generate_impl = true,
        .cpp_pmr_containers = extra.cpp_pmr_containers,
        .cpp_impl_overrides = extra.cpp_impl_overrides,
        .cpp_impl_includes = extra.cpp_impl_includes,
    };
    var hdr_out = std.ArrayList(u8).empty;
    errdefer hdr_out.deinit(alloc);
    var src_out = std.ArrayList(u8).empty;
    errdefer src_out.deinit(alloc);
    try generateConcreteImpl(alloc, &ir_spec, opts, &hdr_out, &src_out);
    return .{ .hdr = hdr_out, .src = src_out };
}

test "cpp_backend: B1+B3 — entity Impl class generated" {
    var res = try testGenConcreteImpl(
        \\module DDS {
        \\    @callback interface FooListener {};
        \\    interface Entity { long enable(); };
        \\    interface Foo : Entity {
        \\        long do_something();
        \\        Foo get_foo();
        \\    };
        \\};
    );
    defer res.deinit();
    const hdr = res.hdr.items;
    const src = res.src.items;
    try testing.expect(has(hdr, "class FooImpl"));
    // Foo : Entity now owns its own native_handle() -- Entity is a pure
    // mixin (excluded, used as a base by Foo), so Foo has no qualifying
    // ancestor to inherit from and must declare + override its own.
    try testing.expect(has(hdr, "DDS_Foo native_handle() const noexcept override { return ptr_; }"));
    // FooListenerBase declaration moved to dcps.hpp (Generator); not in dcps_impl.hpp
    try testing.expect(!has(hdr, "class FooListenerBridge"));
    try testing.expect(has(src, "DDS_Foo_do_something(ptr_)"));
    try testing.expect(has(src, "DDS_Entity_enable(DDS_Foo_as_DDS_Entity(ptr_))"));
}

test "cpp_backend: entity with multiple mixin bases (Topic-shaped) owns its own native_handle()" {
    // Mirrors dcps.idl's Topic : Entity, TopicDescription -- genuine multiple
    // inheritance from two unrelated, independently-excluded mixins. Neither
    // Entity nor TopicDescription can safely provide native_handle() to a
    // multiply-inheriting derived class (two same-named, non-covariant
    // virtuals), so Multi must own its own fresh one directly, exactly like
    // the single-base Foo:Entity case above.
    var res = try testGenConcreteImpl(
        \\module DDS {
        \\    interface Entity {};
        \\    interface Description {};
        \\    interface Multi : Entity, Description {};
        \\};
    );
    defer res.deinit();
    const hdr = res.hdr.items;
    try testing.expect(has(hdr, "DDS_Multi native_handle() const noexcept override { return ptr_; }"));
}

test "cpp_backend: QueryCondition-shaped derived interface owns its own native_handle(), base does not" {
    // Mirrors dcps.idl's QueryCondition : ReadCondition (a genuine same-
    // module IS-A specialization, not a "wider view of the same entity"
    // extension like zzdds::X : DDS::X). DDS_ReadCondition and
    // DDS_QueryCondition are unrelated opaque C types -- if Derived inherited
    // and converted to Base's type instead of owning its own, callers would
    // get the wrong, less-specific handle. Base is excluded (used as
    // Derived's base) so it can't provide one; Derived must own its own.
    var res = try testGenConcreteImpl(
        \\module DDS {
        \\    interface Base {};
        \\    interface Derived : Base {};
        \\};
    );
    defer res.deinit();
    const hdr = res.hdr.items;
    try testing.expect(has(hdr, "DDS_Derived native_handle() const noexcept override { return ptr_; }"));
    // Base's impl keeps the ad hoc, non-virtual fallback -- it's excluded,
    // not owning its own, and nothing inherits a compatible one for it either.
    try testing.expect(has(hdr, "DDS_Base native_handle() const noexcept { return ptr_; }"));
}

test "cpp_backend: --cpp-pmr-containers on — str_ret operation/attribute adapters use std::pmr::string" {
    var res = try testGenConcreteImplOpts(
        \\module DDS {
        \\    @callback interface FooListener {};
        \\    interface Entity { long enable(); };
        \\    interface Foo : Entity {
        \\        string get_name();
        \\        readonly attribute string label;
        \\    };
        \\};
    , .{ .cpp_pmr_containers = true });
    defer res.deinit();
    const src = res.src.items;
    try testing.expect(has(src, "return _r ? std::pmr::string(_r) : std::pmr::string{};"));
    try testing.expect(!has(src, "std::string(_r)"));
    try testing.expect(!has(src, ": std::string{}"));
}

test "cpp_backend: --cpp-pmr-containers off — str_ret operation/attribute adapters still use std::string" {
    var res = try testGenConcreteImpl(
        \\module DDS {
        \\    @callback interface FooListener {};
        \\    interface Entity { long enable(); };
        \\    interface Foo : Entity {
        \\        string get_name();
        \\        readonly attribute string label;
        \\    };
        \\};
    );
    defer res.deinit();
    const src = res.src.items;
    try testing.expect(has(src, "return _r ? std::string(_r) : std::string{};"));
    try testing.expect(!has(src, "std::pmr::"));
}

test "cpp_backend: extension Impl forwards inherited operations through generated C casts" {
    var res = try testGenConcreteImpl(
        \\module DDS {
        \\    interface DomainParticipant {};
        \\    interface DomainParticipantFactory {
        \\        DomainParticipant create_participant();
        \\    };
        \\};
        \\module zzdds {
        \\    interface DomainParticipantFactory : DDS::DomainParticipantFactory {
        \\        DDS::DomainParticipant create_participant_ex();
        \\    };
        \\};
    );
    defer res.deinit();
    const hdr = res.hdr.items;
    const src = res.src.items;
    try testing.expect(has(hdr, "DDS_DomainParticipantFactory native_handle() const noexcept override { return zzdds_DomainParticipantFactory_as_DDS_DomainParticipantFactory(ptr_); }"));
    try testing.expect(has(hdr, "std::shared_ptr<::DDS::DomainParticipant> create_participant() override;"));
    try testing.expect(has(hdr, "std::shared_ptr<::DDS::DomainParticipant> create_participant_ex() override;"));
    try testing.expect(has(src, "DDS_DomainParticipantFactory_create_participant(zzdds_DomainParticipantFactory_as_DDS_DomainParticipantFactory(ptr_))"));
    try testing.expect(has(src, "zzdds_DomainParticipantFactory_create_participant_ex(ptr_)"));
}

test "cpp_backend: cross-module extension of a base with multiple bases itself (Topic-shaped) still inherits and converts" {
    // Mirrors the real dcps.idl/zzdds.idl Topic pair: DDS::Topic has TWO
    // bases (Entity, Description) -- previously importedLeafBaseDeclaresNativeHandle
    // required base.bases.len==0, which DDS::Topic never satisfies, so this
    // cross-module extension shape never got picked up at all before this fix.
    var res = try testGenConcreteImpl(
        \\module DDS {
        \\    interface Entity {};
        \\    interface Description {};
        \\    interface Topic : Entity, Description {};
        \\};
        \\module zzdds {
        \\    interface Topic : DDS::Topic {};
        \\};
    );
    defer res.deinit();
    const hdr = res.hdr.items;
    // zzdds::TopicImpl inherits and converts from DDS::Topic, DESPITE
    // DDS::Topic itself having two bases -- the exact case
    // importedLeafBaseDeclaresNativeHandle's old base.bases.len==0 check
    // would have missed. (DDS::TopicImpl's own native_handle() isn't
    // asserted here: bundling both modules into one generation pass, as
    // this test does for convenience, makes entity_base_ifaces see
    // zzdds::Topic's cross-module usage of DDS::Topic as a base too --
    // something that never happens in the real, separate-file dcps.idl/
    // zzdds.idl build, where dcps.idl's own pass never sees zzdds.idl at
    // all. That's a test-harness artifact of combining both modules, not a
    // real-world case; the DomainParticipantFactory tests above already
    // cover a real separate generation pass's actual behavior.)
    try testing.expect(has(hdr, "DDS_Topic native_handle() const noexcept override { return zzdds_Topic_as_DDS_Topic(ptr_); }"));
}

test "cpp_backend: imported leaf base native_handle detection is generic" {
    var res = try testGenConcreteImpl(
        \\module Base {
        \\    interface Leaf {
        \\        long inherited_op();
        \\    };
        \\};
        \\module Ext {
        \\    interface Leaf : Base::Leaf {
        \\        long extension_op();
        \\    };
        \\};
    );
    defer res.deinit();
    const hdr = res.hdr.items;
    const src = res.src.items;
    try testing.expect(has(hdr, "Base_Leaf native_handle() const noexcept override { return Ext_Leaf_as_Base_Leaf(ptr_); }"));
    try testing.expect(has(src, "Base_Leaf_inherited_op(Ext_Leaf_as_Base_Leaf(ptr_))"));
    try testing.expect(has(src, "Ext_Leaf_extension_op(ptr_)"));
}

test "cpp_backend: handleExprForOwner errors when owner is not reachable" {
    var hdr = std.ArrayList(u8).empty;
    defer hdr.deinit(testing.allocator);
    var src = std.ArrayList(u8).empty;
    defer src.deinit(testing.allocator);
    var gen = ConcreteImplGenerator{
        .alloc = testing.allocator,
        .opts = .{ .input_stem = "bad_cast" },
        .hdr = &hdr,
        .src = &src,
    };

    const loc = ast.Loc{ .offset = 0, .line = 1, .column = 1 };
    var owner = ir.Interface{
        .name = "Owner",
        .qualified_name = "DDS::Owner",
        .span = ast.Span.at(loc),
        .bases = &.{},
        .operations = &.{},
        .attributes = &.{},
        .type_decls = &.{},
        .consts = &.{},
        .raw = &.{},
    };
    var child = ir.Interface{
        .name = "Child",
        .qualified_name = "zzdds::Child",
        .span = ast.Span.at(loc),
        .bases = &.{},
        .operations = &.{},
        .attributes = &.{},
        .type_decls = &.{},
        .consts = &.{},
        .raw = &.{},
    };

    try testing.expectError(error.InterfaceCastPathNotFound, gen.handleExprForOwner(&child, &owner, "ptr_"));
}

test "cpp_backend: nativeHandleBase errors for multiple distinct native handle bases" {
    var hdr = std.ArrayList(u8).empty;
    defer hdr.deinit(testing.allocator);
    var src = std.ArrayList(u8).empty;
    defer src.deinit(testing.allocator);
    var gen = ConcreteImplGenerator{
        .alloc = testing.allocator,
        .opts = .{ .input_stem = "multi_native_handle" },
        .hdr = &hdr,
        .src = &src,
    };
    defer gen.entity_base_ifaces.deinit(testing.allocator);
    defer gen.wrapped_entities.deinit(testing.allocator);

    const loc = ast.Loc{ .offset = 0, .line = 1, .column = 1 };
    var left = ir.Interface{
        .name = "Left",
        .qualified_name = "DDS::Left",
        .span = ast.Span.at(loc),
        .bases = &.{},
        .operations = &.{},
        .attributes = &.{},
        .type_decls = &.{},
        .consts = &.{},
        .raw = &.{},
    };
    var right = ir.Interface{
        .name = "Right",
        .qualified_name = "DDS::Right",
        .span = ast.Span.at(loc),
        .bases = &.{},
        .operations = &.{},
        .attributes = &.{},
        .type_decls = &.{},
        .consts = &.{},
        .raw = &.{},
    };
    const bases = [_]ir.TypeDecl{
        .{ .interface = &left },
        .{ .interface = &right },
    };
    var child = ir.Interface{
        .name = "Child",
        .qualified_name = "zzdds::Child",
        .span = ast.Span.at(loc),
        .bases = &bases,
        .operations = &.{},
        .attributes = &.{},
        .type_decls = &.{},
        .consts = &.{},
        .raw = &.{},
    };

    try testing.expectError(error.MultipleNativeHandleBases, gen.nativeHandleBase(&child));
}

test "cpp_backend: --cpp-impl-override redirects both construction and parameter-adaptation sites" {
    // Bar must take the dynamic_cast+entityImplName parameter-adaptation path
    // for this test to exercise --cpp-impl-override's redirect at all (an
    // interface that owns its own fresh native_handle() -- e.g. a plain
    // `Bar : Entity` mixin leaf -- instead takes the simpler, override-
    // independent virtual `p->native_handle()` dispatch path, since Entity is
    // excluded and Bar has no qualifying ancestor to convert from).
    //
    // A `zzdds::X : DDS::X` cross-module extension shape (like the real
    // dcps.idl/zzdds.idl DomainParticipantFactory pair -- see "entity_in
    // param for derived root interface uses concrete handle" below) reliably
    // takes the dynamic_cast path instead: Bar's own declared C type
    // (zzdds_Bar) never matches what its inherited-and-converted
    // native_handle() returns (DDS_Bar), so `use_virtual` is false.
    var res = try testGenConcreteImplOpts(
        \\module DDS {
        \\    interface Bar {};
        \\};
        \\module zzdds {
        \\    interface Bar : DDS::Bar {};
        \\    interface Foo { Bar get_bar(); void take_bar(in Bar b); };
        \\};
    , .{ .cpp_impl_overrides = &.{"zzdds::Bar=::zzdds::detail::BarSupport"} });
    defer res.deinit();
    const src = res.src.items;
    // Construction site (op return) uses the override, not the default.
    try testing.expect(has(src, "return ::zzdds::detail::BarSupport::_getOrCreate(_h);"));
    try testing.expect(!has(src, "return ::zzdds::BarImpl::_getOrCreate(_h);"));
    // Parameter-adaptation site (take_bar's `b` argument) uses the override
    // too -- same entityImplName() call, no separate fallback needed.
    try testing.expect(has(src, "dynamic_cast<::zzdds::detail::BarSupport*>(_p.get())"));
    try testing.expect(!has(src, "dynamic_cast<::zzdds::BarImpl*>(_p.get())"));
    // The default class is still fully generated (just unused) -- additive,
    // not destructive; nothing else in the spec is assumed to still be able
    // to construct it, but nothing stops it from existing either.
    try testing.expect(has(src, "std::shared_ptr<BarImpl> BarImpl::_getOrCreate(zzdds_Bar h) {"));
}

test "cpp_backend: --cpp-impl-include emits the extra #include" {
    var res = try testGenConcreteImplOpts(
        \\module DDS {
        \\    interface Bar {};
        \\    interface Foo { Bar get_bar(); };
        \\};
    , .{
        .cpp_impl_overrides = &.{"DDS::Bar=::zzdds::BarImpl"},
        .cpp_impl_includes = &.{"zzdds_impl.hpp"},
    });
    defer res.deinit();
    try testing.expect(has(res.src.items, "#include \"zzdds_impl.hpp\""));
}

test "cpp_backend: no --cpp-impl-override leaves the mechanical default name (regression guard)" {
    var res = try testGenConcreteImpl(
        \\module DDS {
        \\    interface Bar {};
        \\    interface Foo { Bar get_bar(); };
        \\};
    );
    defer res.deinit();
    try testing.expect(has(res.src.items, "return ::DDS::BarImpl::_getOrCreate(_h);"));
}

test "cpp_backend: B1+B3 — entity return wraps in Impl" {
    var res = try testGenConcreteImpl(
        \\module DDS {
        \\    interface Bar {};
        \\    interface Foo { Bar get_bar(); };
        \\};
    );
    defer res.deinit();
    const src = res.src.items;
    try testing.expect(has(src, "return ::DDS::BarImpl::_getOrCreate(_h);"));
    try testing.expect(has(src, "std::shared_ptr<BarImpl> BarImpl::_getOrCreate(DDS_Bar h) {"));
    try testing.expect(has(src, "if (!h) return nullptr;"));
    try testing.expect(has(src, "static std::unordered_map<DDS_Bar, std::weak_ptr<BarImpl>> _cache;"));
    try testing.expect(has(src, "std::allocate_shared<BarImpl>("));
    try testing.expect(has(src, "std::pmr::polymorphic_allocator<BarImpl>(std::pmr::get_default_resource())"));
}

test "cpp_backend: entity wrapper identity — _getOrCreate declared and cache mutex-guarded" {
    var res = try testGenConcreteImpl(
        \\module DDS {
        \\    interface Bar {};
        \\    interface Foo { Bar get_bar(); };
        \\};
    );
    defer res.deinit();
    const hdr = res.hdr.items;
    const src = res.src.items;
    // _getOrCreate is the identity-preserving path callers are meant to use.
    // The constructor itself stays public (see the comment on its declaration
    // in emitEntityImplDecl) rather than being locked down, so this is a
    // convention, not an enforced guarantee.
    try testing.expect(has(hdr, "static std::shared_ptr<BarImpl> _getOrCreate(DDS_Bar h);"));
    // Cache-hit path returns the existing wrapper instead of allocating.
    try testing.expect(has(src, "auto _it = _cache.find(h);"));
    try testing.expect(has(src, "if (auto _sp = _it->second.lock()) return _sp;"));
    try testing.expect(has(src, "std::lock_guard<std::mutex> _lock(_mtx);"));
    // Expired-but-present entries are updated via the already-found iterator
    // rather than a second hash lookup; only a genuinely new handle inserts.
    try testing.expect(has(src, "_it->second = _sp;"));
    try testing.expect(has(src, "_cache.emplace(h, _sp);"));
}

test "cpp_backend: _getOrCreate has no entity interfaces — mutex/unordered_map/allocator includes are skipped" {
    var res = try testGenConcreteImpl(
        \\module DDS {
        \\    struct Count { long id; long n; };
        \\};
    );
    defer res.deinit();
    const src = res.src.items;
    try testing.expect(!has(src, "#include <mutex>"));
    try testing.expect(!has(src, "#include <unordered_map>"));
    try testing.expect(!has(src, "zidl_allocator_pmr.hpp"));
}

test "cpp_backend: _getOrCreate present — mutex/unordered_map/allocator includes are emitted" {
    var res = try testGenConcreteImpl(
        \\module DDS {
        \\    interface Bar {};
        \\    interface Foo { Bar get_bar(); };
        \\};
    );
    defer res.deinit();
    const src = res.src.items;
    try testing.expect(has(src, "#include <mutex>"));
    try testing.expect(has(src, "#include <unordered_map>"));
    try testing.expect(has(src, "#include \"zidl_allocator_pmr.hpp\""));
}

test "cpp_backend: entity return of an interface used as a base is still a plain pointer null-check" {
    var res = try testGenConcreteImpl(
        \\module DDS {
        \\    interface Bar {};
        \\    interface Baz : Bar {};
        \\    interface Foo { Bar get_bar(); };
        \\};
    );
    defer res.deinit();
    const src = res.src.items;
    try testing.expect(has(src, "return ::DDS::BarImpl::_getOrCreate(_h);"));
    // Bar is used as a base by Baz, but the C-ABI handle shape doesn't
    // distinguish this — every entity interface is uniformly boxed to a
    // single opaque pointer on the Zig side, so the null-check (now inside
    // _getOrCreate) stays the plain form regardless of inheritance.
    try testing.expect(has(src, "if (!h) return nullptr;"));
    try testing.expect(!has(src, "if (!_h.ptr)"));
}

test "cpp_backend: family root's _familyCache is std::pmr::unordered_map, not plain std::unordered_map" {
    // Regression guard for a real bug found this session, not a hypothetical
    // one: this cache's *values* were already routed through the pmr
    // allocator (std::allocate_shared with
    // std::pmr::polymorphic_allocator(std::pmr::get_default_resource())),
    // but the cache *container itself* was a plain std::unordered_map, so
    // every hash-table node insertion still went through global operator
    // new. Confirmed via a real, reproducible `operator new()` abort under
    // zzdds-examples' cpp/custom-allocator noalloc guard (GuardCondition's
    // family cache, Condition being the root here) before this fix — see
    // zzdds/docs/design/generated-class-lifecycle-design.md's Decisions log
    // for the fuller writeup.
    //
    // Family grouping is `@shared_c_abi_box`-driven (sharedCAbiBoxFamilyRoot
    // in interface.zig), not plain IDL inheritance -- both the root AND the
    // child need the annotation for familyOf() to actually group them
    // (confirmed by trial: annotating only the child, or neither, produces
    // two independent fam.size==1 interfaces instead, skipping the
    // `fam.root == iface` branch that declares/defines _familyCache() at
    // all). Matches the real Condition/GuardCondition/StatusCondition/
    // ReadCondition/QueryCondition family in dcps.idl, where every member
    // carries the annotation.
    var res = try testGenConcreteImpl(
        \\module DDS {
        \\    @shared_c_abi_box interface Bar {};
        \\    @shared_c_abi_box interface Baz : Bar {};
        \\    interface Foo { Bar get_bar(); Baz get_baz(); };
        \\};
    );
    defer res.deinit();
    const hdr = res.hdr.items;
    const src = res.src.items;
    try testing.expect(has(hdr, "static std::pmr::unordered_map<DDS_Bar, std::weak_ptr<Bar>>& _familyCache();"));
    try testing.expect(has(src, "std::pmr::unordered_map<DDS_Bar, std::weak_ptr<Bar>>& BarImpl::_familyCache() {"));
    try testing.expect(has(src, "static std::pmr::unordered_map<DDS_Bar, std::weak_ptr<Bar>> c;"));
    try testing.expect(!has(hdr, "static std::unordered_map<DDS_Bar, std::weak_ptr<Bar>>& _familyCache();"));
    try testing.expect(!has(src, "static std::unordered_map<DDS_Bar, std::weak_ptr<Bar>> c;"));
}

test "cpp_backend: simple-struct sequence field adapts out (no TODO)" {
    var res = try testGenConcreteImpl(
        \\module DDS {
        \\    struct Count { long id; long n; };
        \\    typedef sequence<Count> CountSeq;
        \\    struct Status { CountSeq counts; };
        \\    interface Foo { void get_status(inout Status s); };
        \\};
    );
    defer res.deinit();
    const src = res.src.items;
    try testing.expect(has(src, "reinterpret_cast<const ::DDS::Count*>"));
    try testing.expect(!has(src, "TODO"));
}

test "cpp_backend: simple-struct sequence field adapts in (no TODO)" {
    var res = try testGenConcreteImpl(
        \\module DDS {
        \\    struct Count { long id; long n; };
        \\    typedef sequence<Count> CountSeq;
        \\    struct Status { CountSeq counts; };
        \\    interface Foo { void set_status(in Status s); };
        \\};
    );
    defer res.deinit();
    const src = res.src.items;
    try testing.expect(has(src, "reinterpret_cast<DDS_Count*>(const_cast<::DDS::Count*>"));
    try testing.expect(!has(src, "TODO"));
}

test "cpp_backend: struct with @optional member is not treated as a simple/reinterpret_cast-able sequence element" {
    var res = try testGenConcreteImpl(
        \\module DDS {
        \\    struct Count { long id; @optional long n; };
        \\    typedef sequence<Count> CountSeq;
        \\    struct Status { CountSeq counts; };
        \\    interface Foo { void get_status(inout Status s); };
        \\};
    );
    defer res.deinit();
    const src = res.src.items;
    try testing.expect(!has(src, "reinterpret_cast<const ::DDS::Count*>"));
    try testing.expect(has(src, "TODO"));
}

test "cpp_backend: entity sequence field adapts out via per-element Impl wrapping (no TODO)" {
    var res = try testGenConcreteImpl(
        \\module DDS {
        \\    interface Reader {};
        \\    typedef sequence<Reader> ReaderSeq;
        \\    interface Sub { long get_readers(inout ReaderSeq readers); };
        \\};
    );
    defer res.deinit();
    const src = res.src.items;
    try testing.expect(has(src, ".push_back(::DDS::ReaderImpl::_getOrCreate("));
    try testing.expect(!has(src, "TODO"));
}

test "cpp_backend: entity sequence field adapts in via dynamic_cast loop (no TODO)" {
    var res = try testGenConcreteImpl(
        \\module DDS {
        \\    interface Reader {};
        \\    typedef sequence<Reader> ReaderSeq;
        \\    interface Sub { long set_readers(in ReaderSeq readers); };
        \\};
    );
    defer res.deinit();
    const src = res.src.items;
    try testing.expect(has(src, "dynamic_cast<::DDS::ReaderImpl*>"));
    try testing.expect(has(src, "zidl_concrete_handle(*_impl)"));
    try testing.expect(!has(src, "TODO"));
}

test "cpp_backend: get_listener/set_listener stash pattern" {
    var res = try testGenConcreteImpl(
        \\module DDS {
        \\    @callback interface FooListener {};
        \\    interface Foo {
        \\        long set_listener(in FooListener a_listener, in long mask);
        \\        FooListener get_listener();
        \\    };
        \\};
    );
    defer res.deinit();
    const hdr = res.hdr.items;
    const src = res.src.items;
    try testing.expect(has(hdr, "std::shared_ptr<::DDS::FooListener> listener_;"));
    try testing.expect(has(src, "FooImpl::get_listener() {\n    return listener_;\n}"));
    try testing.expect(has(src, "const auto _rc = DDS_Foo_set_listener(ptr_"));
    try testing.expect(has(src, "if (_rc == 0) listener_ = a_listener;"));
    try testing.expect(has(src, "return _rc;"));
    try testing.expect(!has(src, "TODO"));
}

test "cpp_backend: get_listener/set_listener stash — void set_listener return stashes unconditionally" {
    var res = try testGenConcreteImpl(
        \\module DDS {
        \\    @callback interface FooListener {};
        \\    interface Foo {
        \\        void set_listener(in FooListener a_listener);
        \\        FooListener get_listener();
        \\    };
        \\};
    );
    defer res.deinit();
    const src = res.src.items;
    try testing.expect(has(src, "DDS_Foo_set_listener(ptr_"));
    try testing.expect(has(src, "    listener_ = a_listener;\n}"));
    try testing.expect(!has(src, "TODO"));
}

test "cpp_backend: B1+B3 — enum-like attributes cast across C ABI" {
    var res = try testGenConcreteImpl(
        \\module DDS {
        \\    enum Color { RED, BLUE };
        \\    bitmask Flags { READ, WRITE };
        \\    interface Foo {
        \\        attribute Color color;
        \\        attribute Flags flags;
        \\    };
        \\};
    );
    defer res.deinit();
    const src = res.src.items;
    try testing.expect(has(src, "return static_cast<::DDS::Color>(DDS_Foo_get_color(ptr_));"));
    try testing.expect(has(src, "DDS_Foo_set_color(ptr_, static_cast<DDS_Color>(value));"));
    try testing.expect(has(src, "return static_cast<::DDS::Flags>(DDS_Foo_get_flags(ptr_));"));
    try testing.expect(has(src, "DDS_Foo_set_flags(ptr_, static_cast<DDS_Flags>(value));"));
}

test "cpp_backend: B1+B3 — listener base is in dcps_impl.cpp; decl moved to dcps.hpp" {
    var res = try testGenConcreteImpl(
        \\module DDS {
        \\    interface DataWriter {};
        \\    @callback interface DataWriterListener {
        \\        void on_data(in DataWriter w);
        \\    };
        \\};
    );
    defer res.deinit();
    const hdr = res.hdr.items;
    const src = res.src.items;
    // Declaration moved to dcps.hpp (Generator) — not in dcps_impl.hpp
    try testing.expect(!has(hdr, "class DataWriterListenerBridge"));
    try testing.expect(!has(hdr, "class DataWriterListenerBase"));
    // Method bodies still in dcps_impl.cpp, renamed to Base
    try testing.expect(has(src, "DDS_DataWriterListener DataWriterListenerBase::c_listener()"));
    try testing.expect(has(src, "DataWriterListenerBase::s_on_data"));
    // Trampoline wraps the raw handle via the identity-preserving cache, not a
    // bare make_shared (see _getOrCreate).
    try testing.expect(has(src, "DataWriterImpl::_getOrCreate(w)"));
}

test "cpp_backend: listener trampoline passes a typedef-of-scalar `in` param by value" {
    // A typedef of a primitive (e.g. DDS::InstanceHandle_t = typedef long) must
    // pass by value in the trampoline's static signature and forwarding call,
    // matching the C backend's listener struct field type for the same
    // operation (src/backend/c.zig's isCPrimitive) — not by const-pointer like
    // a struct parameter, which is what non-interface named types got treated
    // as uniformly before this test existed (confirmed as a real, generated
    // signature mismatch: the C struct declared the field by value while this
    // trampoline declared/dereferenced it by pointer).
    var res = try testGenConcreteImpl(
        \\module DDS {
        \\    typedef long InstanceHandle_t;
        \\    interface DataWriter {};
        \\    @callback interface DataWriterListener {
        \\        void on_reliable_reader_ready(in InstanceHandle_t reader_handle, in boolean is_ready);
        \\    };
        \\};
    );
    defer res.deinit();
    const src = res.src.items;
    // Static trampoline signature uses the C type (by value) — it's the
    // function pointer assigned into the C listener struct, so it must match
    // that struct field's declared type exactly.
    try testing.expect(has(src, "void DataWriterListenerBase::s_on_reliable_reader_ready(DDS_InstanceHandle_t reader_handle, bool is_ready, void* d) {"));
    // Forwarding call passes the value straight through — no dereference, no cast.
    try testing.expect(has(src, "on_reliable_reader_ready(reader_handle, is_ready);"));
    try testing.expect(!has(src, "*reader_handle"));
}

test "cpp_backend: B1+B3 — listener base decl appears in dcps.hpp" {
    const alloc = testing.allocator;
    var out = try testGenOpts(
        \\module DDS {
        \\    interface DataWriter {};
        \\    @callback interface DataWriterListener {
        \\        void on_data(in DataWriter w);
        \\    };
        \\};
    ,
        "dcps",
        .{ .generate_interfaces = true },
    );
    defer out.deinit(alloc);
    const s = out.items;
    try testing.expect(has(s, "class DataWriterListenerBase : public ::DDS::DataWriterListener"));
    try testing.expect(has(s, "c_listener() noexcept;"));
    try testing.expect(has(s, "s_on_data"));
}

test "cpp_backend: B1+B3 — simple struct params use reinterpret_cast" {
    var res = try testGenConcreteImpl(
        \\module DDS {
        \\    struct Duration_t { long sec; unsigned long nanosec; };
        \\    interface Foo { long wait(in Duration_t d); };
        \\};
    );
    defer res.deinit();
    const src = res.src.items;
    try testing.expect(has(src, "reinterpret_cast<const DDS_Duration_t*>(&d)"));
}

test "cpp_backend: B1+B3 — complex QoS struct gets field-by-field C adaptation" {
    var res = try testGenConcreteImpl(
        \\module DDS {
        \\    struct UserDataQosPolicy { sequence<octet> value; };
        \\    struct DomainParticipantQos { UserDataQosPolicy user_data; };
        \\    interface Foo { long set_qos(in DomainParticipantQos qos); };
        \\};
    );
    defer res.deinit();
    const src = res.src.items;
    // Field-by-field adaptation: C struct declared, sequence field pointer-borrowed
    try testing.expect(has(src, "DDS_DomainParticipantQos _c_qos{}"));
    try testing.expect(has(src, "_buffer"));
    try testing.expect(!has(src, "TODO: adapt parameters"));
}

test "cpp_backend: B1+B3 — optional string struct member adapter is indented and documents borrowed lifetime" {
    var res = try testGenConcreteImpl(
        \\module DDS {
        \\    struct NameQosPolicy { @optional string name; };
        \\    interface Foo { long set_qos(in NameQosPolicy qos); };
        \\};
    );
    defer res.deinit();
    const src = res.src.items;
    try testing.expect(has(src,
        \\    if (qos.name.has_value()) {
        \\        // Borrowed string pointer; valid only for the duration of this C ABI call.
        \\        _c_qos.name = const_cast<char*>((*qos.name).c_str());
    ));
    try testing.expect(has(src, "        _c_qos._present |= (1ULL << 0u);"));
    try testing.expect(!has(src,
        \\    if (qos.name.has_value()) {
        \\    _c_qos.name =
    ));
}

test "cpp_backend: B1+B3 — nested optional struct member adapter sets nested present bits" {
    var res = try testGenConcreteImpl(
        \\module DDS {
        \\    struct InnerQosPolicy { @optional string name; };
        \\    struct OuterQosPolicy { @optional InnerQosPolicy inner; };
        \\    interface Foo { long set_qos(in OuterQosPolicy qos); };
        \\};
    );
    defer res.deinit();
    const src = res.src.items;
    try testing.expect(has(src,
        \\    if (qos.inner.has_value()) {
        \\        if ((*qos.inner).name.has_value()) {
    ));
    try testing.expect(has(src, "            _c_qos.inner._present |= (1ULL << 0u);"));
    try testing.expect(has(src, "        _c_qos._present |= (1ULL << 0u);"));
}

test "cpp_backend: B — typedef sequence in-param gets seq_in adaptation" {
    var res = try testGenConcreteImpl(
        \\module DDS {
        \\    typedef sequence<string> StringSeq;
        \\    interface Foo { long filter(in StringSeq params); };
        \\};
    );
    defer res.deinit();
    const src = res.src.items;
    // seq_in: C type declared, string elements pointer-borrowed via _ptrs_N
    try testing.expect(has(src, "DDS_StringSeq _c_params{}"));
    try testing.expect(has(src, "_ptrs_1"));
    try testing.expect(has(src, "_c_params._buffer"));
    try testing.expect(has(src, "// Borrowed string pointer array; valid only for the duration of this C ABI call."));
    try testing.expect(has(src, "&_c_params"));
    try testing.expect(!has(src, "TODO"));
}

test "cpp_backend: B — typedef sequence<octet> in-param gets seq_in adaptation" {
    var res = try testGenConcreteImpl(
        \\module DDS {
        \\    typedef sequence<octet> OctetSeq;
        \\    interface Foo { long write(in OctetSeq data); };
        \\};
    );
    defer res.deinit();
    const src = res.src.items;
    // Non-string sequence: buffer pointer borrowed directly from vector
    try testing.expect(has(src, "DDS_OctetSeq _c_data{}"));
    try testing.expect(has(src, "_c_data._buffer"));
    try testing.expect(!has(src, "_ptrs_")); // no char* temp for non-string
    try testing.expect(has(src, "&_c_data"));
}

test "cpp_backend: nested sequence (sequence<sequence<octet>>) in-param gets real marshaling, not a TODO stub" {
    var res = try testGenConcreteImpl(
        \\module DDS {
        \\    typedef sequence<octet> OctetSeq;
        \\    typedef sequence<OctetSeq> OctetSeqSeq;
        \\    interface Foo { long write_batch(in OctetSeqSeq payloads); };
        \\};
    );
    defer res.deinit();
    const src = res.src.items;
    try testing.expect(!has(src, "TODO"));
    // Outer C local declared, and a temporary std::vector<DDS_OctetSeq> built to
    // hold one inner C sequence struct per C++ inner vector.
    try testing.expect(has(src, "DDS_OctetSeqSeq _c_payloads{}"));
    try testing.expect(has(src, "std::vector<DDS_OctetSeq> _nested_1"));
    try testing.expect(has(src, "for (size_t _j_1 = 0; _j_1 < payloads.size(); ++_j_1) {"));
    // Inner element's buffer borrowed directly from the inner std::vector<uint8_t>.
    try testing.expect(has(src, "_nested_1[_j_1]._buffer = const_cast<uint8_t*>(payloads[_j_1].data())"));
    // Outer struct's buffer set from the temporary array.
    try testing.expect(has(src, "_c_payloads._buffer = _nested_1.data()"));
    try testing.expect(has(src, "&_c_payloads"));
}

test "cpp_backend: nested sequence (sequence<sequence<octet>>) out-param gets real marshaling, not a TODO stub" {
    var res = try testGenConcreteImpl(
        \\module DDS {
        \\    typedef sequence<octet> OctetSeq;
        \\    typedef sequence<OctetSeq> OctetSeqSeq;
        \\    interface Foo { long take_batch(out OctetSeqSeq payloads); };
        \\};
    );
    defer res.deinit();
    const src = res.src.items;
    try testing.expect(!has(src, "TODO"));
    try testing.expect(has(src, "payloads.clear();"));
    try testing.expect(has(src, "for (int32_t _k_1 = 0; _k_1 < _c_payloads._length; ++_k_1) {"));
    // Inner element built from the corresponding inner C sequence struct's buffer.
    try testing.expect(has(src, "_c_payloads._buffer[_k_1]._buffer"));
    try testing.expect(has(src, "payloads.push_back(std::move(_elem_1));"));
    // Outer struct freed after marshaling out (existing, already-proven nested free).
    try testing.expect(has(src, "DDS_OctetSeqSeq_free(&_c_payloads)"));
}

test "cpp_backend: B1 — forward decls emitted without bootstrap factory helper" {
    var res = try testGenConcreteImpl(
        \\module DDS {
        \\    @callback interface DomainParticipantListener {};
        \\    interface DomainParticipant { long enable(); };
        \\};
    );
    defer res.deinit();
    const hdr = res.hdr.items;
    const src = res.src.items;
    try testing.expect(has(hdr, "class DomainParticipantImpl;"));
    // DomainParticipantListenerBase declaration moved to dcps.hpp
    try testing.expect(!has(hdr, "class DomainParticipantListenerBridge;"));
    try testing.expect(!has(hdr, "class DomainParticipantListenerBase;"));
    try testing.expect(has(hdr, "Bootstrap factory helpers such as create_participant_udp are not generated here"));
    try testing.expect(!has(hdr, "create_participant_udp("));
    try testing.expect(!has(src, "zzdds_create_participant_udp("));
}

test "cpp_backend: D3 — complex struct out-param gets field-by-field C→C++ copy and free" {
    var res = try testGenConcreteImpl(
        \\module DDS {
        \\    struct UserDataQosPolicy { sequence<octet> value; };
        \\    struct DomainParticipantQos { UserDataQosPolicy user_data; };
        \\    interface Foo { long get_qos(out DomainParticipantQos qos); };
        \\};
    );
    defer res.deinit();
    const src = res.src.items;
    // Zero-init C local declared before call
    try testing.expect(has(src, "DDS_DomainParticipantQos _c_qos{}"));
    // Return value captured (not returned directly)
    try testing.expect(has(src, "const auto _rc ="));
    // Pass address of C local to C function
    try testing.expect(has(src, "&_c_qos"));
    // Copy sequence field from C→C++ using assign
    try testing.expect(has(src, ".assign("));
    try testing.expect(has(src, "._buffer"));
    // Free the C struct after copying
    try testing.expect(has(src, "DDS_DomainParticipantQos_free(&_c_qos)"));
    // Return captured value
    try testing.expect(has(src, "return _rc;"));
    try testing.expect(!has(src, "TODO: adapt parameters"));
}

test "cpp_backend: D3 — string field in out-param struct uses conditional std::string" {
    var res = try testGenConcreteImpl(
        \\module DDS {
        \\    struct TypeNameQos { string type_name; };
        \\    interface Foo { long get_type_qos(out TypeNameQos qos); };
        \\};
    );
    defer res.deinit();
    const src = res.src.items;
    try testing.expect(has(src, "DDS_TypeNameQos _c_qos{}"));
    try testing.expect(has(src, "std::string("));
    try testing.expect(has(src, "DDS_TypeNameQos_free(&_c_qos)"));
    try testing.expect(!has(src, "TODO: adapt parameters"));
}

test "cpp_backend: D3 — sequence<string> field in out-param struct uses emplace_back loop" {
    var res = try testGenConcreteImpl(
        \\module DDS {
        \\    struct PartitionQosPolicy { sequence<string> name; };
        \\    interface Foo { long get_partition(out PartitionQosPolicy p); };
        \\};
    );
    defer res.deinit();
    const src = res.src.items;
    try testing.expect(has(src, "DDS_PartitionQosPolicy _c_p{}"));
    try testing.expect(has(src, "emplace_back("));
    try testing.expect(has(src, "DDS_PartitionQosPolicy_free(&_c_p)"));
    try testing.expect(!has(src, "TODO: adapt parameters"));
}

test "cpp_backend: D3 — typedef sequence<string> out-param gets seq_out adaptation" {
    var res = try testGenConcreteImpl(
        \\module DDS {
        \\    typedef sequence<string> StringSeq;
        \\    interface Foo { long get_params(inout StringSeq params); };
        \\};
    );
    defer res.deinit();
    const src = res.src.items;
    // Zero-init C local declared before call
    try testing.expect(has(src, "DDS_StringSeq _c_params{}"));
    // Return value captured
    try testing.expect(has(src, "const auto _rc ="));
    // Address passed to C function
    try testing.expect(has(src, "&_c_params"));
    // String elements copied via emplace_back
    try testing.expect(has(src, "emplace_back("));
    // C buffer freed after copy
    try testing.expect(has(src, "DDS_StringSeq_free(&_c_params)"));
    try testing.expect(!has(src, "TODO"));
}

test "cpp_backend: D3 — typedef sequence<octet> out-param gets seq_out adaptation" {
    var res = try testGenConcreteImpl(
        \\module DDS {
        \\    typedef sequence<octet> OctetSeq;
        \\    interface Foo { long read_data(out OctetSeq data); };
        \\};
    );
    defer res.deinit();
    const src = res.src.items;
    try testing.expect(has(src, "DDS_OctetSeq _c_data{}"));
    try testing.expect(has(src, "const auto _rc ="));
    // Non-string: buffer assign with null guard
    try testing.expect(has(src, ".assign("));
    try testing.expect(has(src, "DDS_OctetSeq_free(&_c_data)"));
    try testing.expect(!has(src, "TODO"));
}

test "cpp_backend split: zzdds wrapper header includes unordered_map" {
    var out = try testGenTypeHeaderOpts("@appendable struct Topic { @key long id; };", "topic", 0, .{ .generate_zzdds_wrappers = true });
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "#include \"zzdds_c.h\""));
    try testing.expect(has(s, "#include <unordered_map>"));
}

test "cpp_backend: entity_in param uses virtual native_handle, not static_cast" {
    var res = try testGenConcreteImpl(
        \\module DDS {
        \\    interface Topic {};
        \\    interface DomainParticipant { long create_topic(in Topic t); };
        \\};
    );
    defer res.deinit();
    const src = res.src.items;
    try testing.expect(has(src, "t->native_handle()"));
    try testing.expect(!has(src, "static_cast<TopicImpl*>"));
}

test "cpp_backend: entity_in param for derived root interface uses concrete handle" {
    var res = try testGenConcreteImpl(
        \\module DDS {
        \\    interface DomainParticipantFactory {};
        \\};
        \\module zzdds {
        \\    interface DomainParticipantFactory : DDS::DomainParticipantFactory {};
        \\    interface FactoryUser {
        \\        long use_factory(in DomainParticipantFactory f);
        \\    };
        \\};
    );
    defer res.deinit();
    const hdr = res.hdr.items;
    const src = res.src.items;
    try testing.expect(has(hdr, "friend zzdds_DomainParticipantFactory zidl_concrete_handle(const DomainParticipantFactoryImpl& self) noexcept { return self.ptr_; }"));
    try testing.expect(has(hdr, "DDS_DomainParticipantFactory native_handle() const noexcept override { return zzdds_DomainParticipantFactory_as_DDS_DomainParticipantFactory(ptr_); }"));
    try testing.expect(has(src, "entity parameter adaptation uses dynamic_cast and requires RTTI"));
    try testing.expect(has(src, "dynamic_cast<::zzdds::DomainParticipantFactoryImpl*>(_p.get())) return zidl_concrete_handle(*_impl);"));
    try testing.expect(has(src, "throw std::invalid_argument(\"zidl: incompatible entity implementation for zzdds::DomainParticipantFactory\")"));
    try testing.expect(!has(src, "dynamic_cast<::zzdds::DomainParticipantFactoryImpl*>(_p.get())) return _impl->native_handle();"));
}

test "cpp_backend: entity_in param for a base with multiple sibling implementors casts through all of them" {
    // Mirrors dcps.idl's TopicDescription, implemented independently by
    // Topic/ContentFilteredTopic/MultiTopic (none inherit from each other) --
    // a parameter typed as the base must try every concrete implementor's
    // dynamic_cast, not just the base's own mechanical <Iface>Impl name.
    var res = try testGenConcreteImpl(
        \\module DDS {
        \\    interface Base {};
        \\    interface LeafA : Base {};
        \\    interface LeafB : Base {};
        \\    interface User {
        \\        long use_base(in Base b);
        \\    };
        \\};
    );
    defer res.deinit();
    const src = res.src.items;
    try testing.expect(has(src, "entity parameter adaptation uses dynamic_cast and requires RTTI"));
    try testing.expect(has(src, "dynamic_cast<::DDS::BaseImpl*>(_p.get())) return zidl_concrete_handle(*_impl);"));
    try testing.expect(has(src, "dynamic_cast<::DDS::LeafAImpl*>(_p.get())) return DDS_LeafA_as_DDS_Base(zidl_concrete_handle(*_impl));"));
    try testing.expect(has(src, "dynamic_cast<::DDS::LeafBImpl*>(_p.get())) return DDS_LeafB_as_DDS_Base(zidl_concrete_handle(*_impl));"));
    try testing.expect(has(src, "throw std::invalid_argument(\"zidl: incompatible entity implementation for DDS::Base\")"));
}

test "cpp_backend: entity_in param for a base with a single implementor keeps the plain single-cast form" {
    // Common case: no sibling implementors means the cascading-cast codegen
    // must be byte-identical to the pre-existing single-cast form.
    var res = try testGenConcreteImpl(
        \\module DDS {
        \\    interface DomainParticipantFactory {};
        \\};
        \\module zzdds {
        \\    interface DomainParticipantFactory : DDS::DomainParticipantFactory {};
        \\    interface FactoryUser {
        \\        long use_factory(in DomainParticipantFactory f);
        \\    };
        \\};
    );
    defer res.deinit();
    const src = res.src.items;
    try testing.expect(has(
        src,
        "([](const auto& _p) -> zzdds_DomainParticipantFactory { if (!_p) return nullptr; if (auto* _impl = dynamic_cast<::zzdds::DomainParticipantFactoryImpl*>(_p.get())) return zidl_concrete_handle(*_impl); throw std::invalid_argument(\"zidl: incompatible entity implementation for zzdds::DomainParticipantFactory\"); })(f)",
    ));
}

test "cpp_backend: entity_in param of an interface used as a base still uses plain nullptr" {
    var res = try testGenConcreteImpl(
        \\module DDS {
        \\    interface Bar {};
        \\    interface Baz : Bar {};
        \\    interface Foo { long take_bar(in Bar b); };
        \\};
    );
    defer res.deinit();
    const src = res.src.items;
    // Bar is used as a base by Baz, but the C-ABI handle shape doesn't
    // distinguish this — every entity interface is uniformly a single opaque
    // pointer, so the dynamic_cast lambda's null literal stays plain nullptr
    // regardless of inheritance.
    try testing.expect(has(src, "if (!_p) return nullptr;"));
    try testing.expect(!has(src, "DDS_Bar{nullptr, nullptr}"));
}

test "cpp_backend: listener_in uses _lp_ null pointer, not address-of zero struct" {
    var res = try testGenConcreteImpl(
        \\module DDS {
        \\    @callback interface DataWriterListener { void on_offered_deadline_missed(); };
        \\    interface DataWriter { long set_listener(in DataWriterListener l); };
        \\};
    );
    defer res.deinit();
    const src = res.src.items;
    try testing.expect(has(src, "_lp_l"));
    try testing.expect(!has(src, "l ? &_l_l : nullptr"));
}
