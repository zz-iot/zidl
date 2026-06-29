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
//! Unions with members of non-trivially-constructible types (std::string,
//! std::vector, …) produce C++ that requires explicit constructor/destructor
//! definitions; the generator does not emit those.  Backends targeting complex
//! unions should use `std::variant` instead.

const std = @import("std");
const ast = @import("../ast.zig");
const ir = @import("../ir/root.zig");
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
        // Entity interfaces and entity_in adapters use std::shared_ptr whenever
        // interface generation is enabled.
        if (self.opts.generate_interfaces) try self.write("#include <memory>\n");
        if (needs.map) try self.write("#include <map>\n");
        if (needs.optional) try self.write("#include <optional>\n");
        if (needs.union_arrays) try self.write("#include <cstring>\n");
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
            try collectEntityBaseNames(self.alloc, spec.items, &self.entity_base_ifaces);
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
        if (has_key) {
            try self.print("{s}{s}int {s}_serialize_key(ZidlCdrWriter *_w, const {s} *_v);\n", .{ em, sp, c_name, cpp_qname });
            try self.print("{s}{s}int {s}_deserialize_key(ZidlCdrReader *_r, {s} *_v);\n", .{ em, sp, c_name, cpp_qname });
            try self.print("{s}{s}int {s}_compute_key_hash(const {s} *_v, uint8_t _hash[16]);\n", .{ em, sp, c_name, cpp_qname });
            try self.print("{s}{s}int {s}_compute_key_hash_from_cdr(const uint8_t *_payload, size_t _len, uint8_t _hash[16]);\n", .{ em, sp, c_name });
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
        try self.print("    struct Sample {{ {s} value; zzdds_sample_info info; }};\n", .{cpp_qname});
        try self.write("    class Loan {\n");
        try self.write("    public:\n");
        try self.write("        Loan() = default;\n");
        try self.print("        Loan({s}DataReader *reader, zzdds_loaned_sample loan, Sample sample) : reader_(reader), loan_(loan), sample_(sample), active_(true) {{}}\n", .{class_name});
        try self.write("        Loan(const Loan&) = delete;\n");
        try self.write("        Loan& operator=(const Loan&) = delete;\n");
        try self.write("        Loan(Loan&& other) noexcept : reader_(other.reader_), loan_(other.loan_), sample_(other.sample_), active_(other.active_) { other.active_ = false; }\n");
        try self.write("        Loan& operator=(Loan&& other) noexcept { if (this != &other) { reset(); reader_ = other.reader_; loan_ = other.loan_; sample_ = other.sample_; active_ = other.active_; other.active_ = false; } return *this; }\n");
        try self.write("        ~Loan() { reset(); }\n");
        try self.write("        const Sample& sample() const { return sample_; }\n");
        try self.write("        void reset();\n");
        try self.write("    private:\n");
        try self.print("        {s}DataReader *reader_ = nullptr;\n", .{class_name});
        try self.write("        zzdds_loaned_sample loan_{};\n");
        try self.write("        Sample sample_{};\n");
        try self.write("        bool active_ = false;\n");
        try self.write("    };\n");
        try self.print("    explicit {s}DataReader(DDS_DataReader reader) : reader_(reader) {{}}\n", .{class_name});
        try self.write("    int take(Sample& out, uint8_t *buf, size_t buf_size, size_t *cdr_len_out);\n");
        try self.write("    int read(Sample& out, uint8_t *buf, size_t buf_size, size_t *cdr_len_out);\n");
        try self.write("    int take_next_instance(Sample& out, DDS_InstanceHandle_t prev, uint8_t *buf, size_t buf_size, size_t *cdr_len_out);\n");
        try self.write("    int read_next_instance(Sample& out, DDS_InstanceHandle_t prev, uint8_t *buf, size_t buf_size, size_t *cdr_len_out);\n");
        try self.print("    int get_key_value(DDS_InstanceHandle_t handle, {s}& key_out);\n", .{cpp_qname});
        try self.print("    DDS_InstanceHandle_t lookup_instance(const {s}& key);\n", .{cpp_qname});
        try self.print("    int take_n({s} *values, zzdds_sample_info *infos, int max, uint32_t ss, uint32_t vs, uint32_t is);\n", .{cpp_qname});
        try self.print("    int read_n({s} *values, zzdds_sample_info *infos, int max, uint32_t ss, uint32_t vs, uint32_t is);\n", .{cpp_qname});
        try self.write("    int take_loaned(Loan& out);\n");
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

        try self.print("class {s} {{\npublic:\n", .{u.name});

        // Discriminant accessors.
        try self.print("    void _d({s} v) noexcept {{ _disc = v; }}\n", .{disc_cpp});
        try self.print("    {s} _d() const noexcept {{ return _disc; }}\n", .{disc_cpp});

        // Case accessors (setter + getter).
        for (u.cases) |cas| {
            const mem_cpp = try self.typeRefToCpp(cas.type_ref);
            defer self.alloc.free(mem_cpp);
            if (cas.dimensions.len > 0) {
                const dims_str = try cArrayDimsStr(self.alloc, cas.dimensions);
                defer self.alloc.free(dims_str);
                try self.print("    void {s}({s} const (&v){s}) noexcept {{ std::memcpy(_u._{s}, v, sizeof(_u._{s})); }}\n", .{ cas.name, mem_cpp, dims_str, cas.name, cas.name });
                try self.print("    auto {s}() const noexcept -> {s} const (&){s} {{ return _u._{s}; }}\n", .{ cas.name, mem_cpp, dims_str, cas.name });
            } else {
                try self.print("    void {s}({s} v) {{ _u._{s} = v; }}\n", .{ cas.name, mem_cpp, cas.name });
                try self.print("    {s} {s}() const {{ return _u._{s}; }}\n", .{ mem_cpp, cas.name, cas.name });
            }
        }

        try self.write("private:\n");
        try self.print("    {s} _disc{{}};\n", .{disc_cpp});
        try self.write("    union {\n");
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
        // NOTE: anonymous union with non-trivially-constructible members (e.g.
        // std::string) requires explicit constructors/destructors; not generated here.
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

        // Emit native_handle() on leaf (non-base) entity interfaces so callers
        // can retrieve the underlying C handle without a static_cast to Impl.
        // Skipped for: callback/listener interfaces, top-level (non-module) interfaces,
        // and interfaces that appear as bases in another non-callback interface
        // (which would create a return-type conflict in derived Impl classes).
        if (self.opts.generate_interfaces and !isCallbackIface(iface)) {
            const in_module = std.mem.indexOfScalar(u8, iface.qualified_name, ':') != null;
            if (in_module and iface.bases.len == 0 and !self.entity_base_ifaces.contains(iface.qualified_name)) {
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
                // `BitmaskName_BIT` values. IR qualified names already use
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
                break :blk std.fmt.allocPrint(self.alloc, "std::vector<{s}>", .{elem});
            },
            .string => self.alloc.dupe(u8, "std::string"),
            .wstring => self.alloc.dupe(u8, "std::wstring"),
            .fixed_pt => self.alloc.dupe(u8, "double"),
            .map => |m| blk: {
                const key_s = try self.typeRefToCpp(m.key.*);
                defer self.alloc.free(key_s);
                const val_s = try self.typeRefToCpp(m.value.*);
                defer self.alloc.free(val_s);
                break :blk std.fmt.allocPrint(self.alloc, "std::map<{s}, {s}>", .{ key_s, val_s });
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

    fn ind(self: *CdrGenerator) []const u8 {
        return switch (self.indent_depth) {
            1 => "    ",
            2 => "        ",
            3 => "            ",
            else => "                ",
        };
    }

    fn writeI(self: *CdrGenerator, s: []const u8) !void {
        try self.out.appendSlice(self.alloc, self.ind());
        try self.out.appendSlice(self.alloc, s);
    }

    fn printI(self: *CdrGenerator, comptime fmt: []const u8, args: anytype) !void {
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
            .string => self.alloc.dupe(u8, "std::string"),
            .wstring => self.alloc.dupe(u8, "std::wstring"),
            .fixed_pt => self.alloc.dupe(u8, "double"),
            .named => |td| switch (td) {
                .enum_ => |e| std.fmt.allocPrint(self.alloc, "::{s}", .{e.qualified_name}),
                .bitmask => |bm| self.alloc.dupe(u8, enumCTypeName(bm.annotations)),
                else => std.fmt.allocPrint(self.alloc, "::{s}", .{ir.typeDeclQualifiedName(td)}),
            },
            .sequence => |seq| blk: {
                const elem = try self.cppTypeForLocal(seq.element.*);
                defer self.alloc.free(elem);
                break :blk std.fmt.allocPrint(self.alloc, "std::vector<{s}>", .{elem});
            },
            .map => |m| blk: {
                const k = try self.cppTypeForLocal(m.key.*);
                defer self.alloc.free(k);
                const v = try self.cppTypeForLocal(m.value.*);
                defer self.alloc.free(v);
                break :blk std.fmt.allocPrint(self.alloc, "std::map<{s}, {s}>", .{ k, v });
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
            .union_ => |u| try self.emitUnionFns(u),
            else => {},
        }
    }

    fn prefixedCName(self: *CdrGenerator, qname: []const u8) ![]u8 {
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
                try self.emitSkipMember(m);
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
        }
        if (self.opts.generate_zzdds_wrappers and !self.opts.no_typesupport and isZzddsTopicStructCpp(s)) {
            try self.emitStructZzddsWrappers(s, c_name, cpp_qname);
        }
    }

    fn emitStructZzddsWrappers(self: *CdrGenerator, s: *const ir.Struct, c_name: []const u8, cpp_qname: []const u8) !void {
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
        try self.printI("return zzdds_register_type_support_c(participant, type_name ? type_name : \"{s}\", {s}_compute_key_hash_from_cdr);\n", .{ s.qualified_name, c_name });
        try self.write("}\n\n");

        try self.print("static int {s}_write_kind(DDS_DataWriter writer, int xcdr_version, zzdds_write_kind kind, const {s}& value, bool key_only) {{\n", .{ class_name, cpp_qname });
        try self.writeI("ZidlCdrWriter _w;\n");
        try self.writeI("uint8_t _hash[16];\n");
        try self.writeI("int _rc = zidl_cdr_writer_init(&_w, xcdr_version);\n");
        try self.writeI("if (_rc) return _rc;\n");
        try self.writeI("_rc = zidl_cdr_write_encap(&_w);\n");
        try self.printI("if (!_rc) _rc = key_only ? {s}_serialize_key(&_w, &value) : {s}_serialize(&_w, &value);\n", .{ c_name, c_name });
        try self.printI("if (!_rc) _rc = {s}_compute_key_hash(&value, _hash);\n", .{c_name});
        try self.writeI("if (!_rc) _rc = zzdds_write_raw_kind(writer, kind, _hash, _w.buf, _w.len);\n");
        try self.writeI("zidl_cdr_writer_deinit(&_w);\n");
        try self.writeI("return _rc;\n");
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

        try self.print("static int {s}_write_kind_w_timestamp(DDS_DataWriter writer, int xcdr_version, zzdds_write_kind kind, const {s}& value, bool key_only, DDS_Time_t timestamp) {{\n", .{ class_name, cpp_qname });
        try self.writeI("ZidlCdrWriter _w;\n");
        try self.writeI("uint8_t _hash[16];\n");
        try self.writeI("int _rc = zidl_cdr_writer_init(&_w, xcdr_version);\n");
        try self.writeI("if (_rc) return _rc;\n");
        try self.writeI("_rc = zidl_cdr_write_encap(&_w);\n");
        try self.printI("if (!_rc) _rc = key_only ? {s}_serialize_key(&_w, &value) : {s}_serialize(&_w, &value);\n", .{ c_name, c_name });
        try self.printI("if (!_rc) _rc = {s}_compute_key_hash(&value, _hash);\n", .{c_name});
        try self.writeI("if (!_rc) _rc = zzdds_write_raw_w_timestamp(writer, kind, _hash, _w.buf, _w.len, timestamp);\n");
        try self.writeI("zidl_cdr_writer_deinit(&_w);\n");
        try self.writeI("return _rc;\n");
        try self.write("}\n\n");

        try self.print("static int {s}_write_kind_w_hash(DDS_DataWriter writer, int xcdr_version, zzdds_write_kind kind, const {s}& value, bool key_only, const uint8_t *hash) {{\n", .{ class_name, cpp_qname });
        try self.writeI("ZidlCdrWriter _w;\n");
        try self.writeI("int _rc = zidl_cdr_writer_init(&_w, xcdr_version);\n");
        try self.writeI("if (_rc) return _rc;\n");
        try self.writeI("_rc = zidl_cdr_write_encap(&_w);\n");
        try self.printI("if (!_rc) _rc = key_only ? {s}_serialize_key(&_w, &value) : {s}_serialize(&_w, &value);\n", .{ c_name, c_name });
        try self.writeI("if (!_rc) _rc = zzdds_write_raw_kind(writer, kind, hash, _w.buf, _w.len);\n");
        try self.writeI("zidl_cdr_writer_deinit(&_w);\n");
        try self.writeI("return _rc;\n");
        try self.write("}\n\n");

        try self.print("int {s}DataWriter::write(const {s}& value) {{\n", .{ class_name, cpp_qname });
        try self.printI("return {s}_write_kind(writer_, xcdr_version_, ZZDDS_WRITE_ALIVE, value, false);\n", .{class_name});
        try self.write("}\n\n");
        try self.print("int {s}DataWriter::write_w_timestamp(const {s}& value, DDS_Time_t timestamp) {{\n", .{ class_name, cpp_qname });
        try self.printI("return {s}_write_kind_w_timestamp(writer_, xcdr_version_, ZZDDS_WRITE_ALIVE, value, false, timestamp);\n", .{class_name});
        try self.write("}\n\n");
        try self.print("int {s}DataWriter::dispose(const {s}& key) {{\n", .{ class_name, cpp_qname });
        try self.printI("return {s}_write_kind(writer_, xcdr_version_, ZZDDS_WRITE_DISPOSE, key, true);\n", .{class_name});
        try self.write("}\n\n");
        try self.print("int {s}DataWriter::dispose_w_timestamp(const {s}& key, DDS_Time_t timestamp) {{\n", .{ class_name, cpp_qname });
        try self.printI("return {s}_write_kind_w_timestamp(writer_, xcdr_version_, ZZDDS_WRITE_DISPOSE, key, true, timestamp);\n", .{class_name});
        try self.write("}\n\n");
        try self.print("int {s}DataWriter::unregister_instance(const {s}& key) {{\n", .{ class_name, cpp_qname });
        try self.printI("return {s}_write_kind(writer_, xcdr_version_, ZZDDS_WRITE_UNREGISTER, key, true);\n", .{class_name});
        try self.write("}\n\n");
        try self.print("int {s}DataWriter::unregister_instance_w_timestamp(const {s}& key, DDS_Time_t timestamp) {{\n", .{ class_name, cpp_qname });
        try self.printI("return {s}_write_kind_w_timestamp(writer_, xcdr_version_, ZZDDS_WRITE_UNREGISTER, key, true, timestamp);\n", .{class_name});
        try self.write("}\n\n");
        try self.print("int {s}DataWriter::get_key_value(DDS_InstanceHandle_t handle, {s}& key_out) {{\n", .{ class_name, cpp_qname });
        try self.writeI("uint8_t _buf[ZZDDS_KEY_VALUE_BUF_SIZE];\n");
        try self.writeI("size_t _len = 0;\n");
        try self.writeI("int _rc = zzdds_get_key_value_writer(writer_, handle, _buf, sizeof(_buf), &_len);\n");
        try self.writeI("if (_rc) return _rc;\n");
        try self.writeI("ZidlCdrReader _r;\n");
        try self.writeI("_rc = zidl_cdr_reader_init(&_r, _buf, _len);\n");
        try self.writeI("if (_rc) return _rc;\n");
        try self.printI("return {s}_deserialize_key(&_r, &key_out);\n", .{c_name});
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
        try self.printI("return {s}_write_kind_w_hash(writer_, xcdr_version_, ZZDDS_WRITE_ALIVE, value, false, it->second.data());\n", .{class_name});
        try self.write("}\n\n");
        try self.print("int {s}DataWriter::dispose_w_handle(const {s}& key, DDS_InstanceHandle_t handle) {{\n", .{ class_name, cpp_qname });
        try self.writeI("auto it = instance_handles_.find(handle);\n");
        try self.writeI("if (it == instance_handles_.end()) return DDS_RETCODE_BAD_PARAMETER;\n");
        try self.printI("return {s}_write_kind_w_hash(writer_, xcdr_version_, ZZDDS_WRITE_DISPOSE, key, true, it->second.data());\n", .{class_name});
        try self.write("}\n\n");
        try self.print("int {s}DataWriter::unregister_instance_w_handle(const {s}& key, DDS_InstanceHandle_t handle) {{\n", .{ class_name, cpp_qname });
        try self.writeI("auto it = instance_handles_.find(handle);\n");
        try self.writeI("if (it == instance_handles_.end()) return DDS_RETCODE_BAD_PARAMETER;\n");
        try self.printI("int _rc = {s}_write_kind_w_hash(writer_, xcdr_version_, ZZDDS_WRITE_UNREGISTER, key, true, it->second.data());\n", .{class_name});
        try self.writeI("if (!_rc) instance_handles_.erase(it);\n");
        try self.writeI("return _rc;\n");
        try self.write("}\n\n");

        try self.print("int {s}DataReader::take(Sample& out, uint8_t *buf, size_t buf_size, size_t *cdr_len_out) {{\n", .{class_name});
        try self.writeI("int _n = zzdds_take_one_raw(reader_, buf, buf_size, cdr_len_out, &out.info);\n");
        try self.writeI("if (_n != 1) return _n;\n");
        try self.writeI("ZidlCdrReader _r;\n");
        try self.writeI("int _rc = zidl_cdr_reader_init(&_r, buf, *cdr_len_out);\n");
        try self.writeI("if (_rc) return _rc;\n");
        try self.printI("return out.info.valid_data ? {s}_deserialize(&_r, &out.value) : {s}_deserialize_key(&_r, &out.value);\n", .{ c_name, c_name });
        try self.write("}\n\n");

        try self.print("int {s}DataReader::read(Sample& out, uint8_t *buf, size_t buf_size, size_t *cdr_len_out) {{\n", .{class_name});
        try self.writeI("int _n = zzdds_read_one_raw(reader_, buf, buf_size, cdr_len_out, &out.info);\n");
        try self.writeI("if (_n != 1) return _n;\n");
        try self.writeI("ZidlCdrReader _r;\n");
        try self.writeI("int _rc = zidl_cdr_reader_init(&_r, buf, *cdr_len_out);\n");
        try self.writeI("if (_rc) return _rc;\n");
        try self.printI("return out.info.valid_data ? {s}_deserialize(&_r, &out.value) : {s}_deserialize_key(&_r, &out.value);\n", .{ c_name, c_name });
        try self.write("}\n\n");

        try self.print("int {s}DataReader::take_next_instance(Sample& out, DDS_InstanceHandle_t prev, uint8_t *buf, size_t buf_size, size_t *cdr_len_out) {{\n", .{class_name});
        try self.writeI("int _n = zzdds_take_one_raw_instance(reader_, prev, buf, buf_size, cdr_len_out, &out.info);\n");
        try self.writeI("if (_n != 1) return _n;\n");
        try self.writeI("ZidlCdrReader _r;\n");
        try self.writeI("int _rc = zidl_cdr_reader_init(&_r, buf, *cdr_len_out);\n");
        try self.writeI("if (_rc) return _rc;\n");
        try self.printI("return out.info.valid_data ? {s}_deserialize(&_r, &out.value) : {s}_deserialize_key(&_r, &out.value);\n", .{ c_name, c_name });
        try self.write("}\n\n");

        try self.print("int {s}DataReader::read_next_instance(Sample& out, DDS_InstanceHandle_t prev, uint8_t *buf, size_t buf_size, size_t *cdr_len_out) {{\n", .{class_name});
        try self.writeI("int _n = zzdds_read_one_raw_instance(reader_, prev, buf, buf_size, cdr_len_out, &out.info);\n");
        try self.writeI("if (_n != 1) return _n;\n");
        try self.writeI("ZidlCdrReader _r;\n");
        try self.writeI("int _rc = zidl_cdr_reader_init(&_r, buf, *cdr_len_out);\n");
        try self.writeI("if (_rc) return _rc;\n");
        try self.printI("return out.info.valid_data ? {s}_deserialize(&_r, &out.value) : {s}_deserialize_key(&_r, &out.value);\n", .{ c_name, c_name });
        try self.write("}\n\n");

        try self.print("int {s}DataReader::get_key_value(DDS_InstanceHandle_t handle, {s}& key_out) {{\n", .{ class_name, cpp_qname });
        try self.writeI("uint8_t _buf[ZZDDS_KEY_VALUE_BUF_SIZE];\n");
        try self.writeI("size_t _len = 0;\n");
        try self.writeI("int _rc = zzdds_get_key_value_reader(reader_, handle, _buf, sizeof(_buf), &_len);\n");
        try self.writeI("if (_rc) return _rc;\n");
        try self.writeI("ZidlCdrReader _r;\n");
        try self.writeI("_rc = zidl_cdr_reader_init(&_r, _buf, _len);\n");
        try self.writeI("if (_rc) return _rc;\n");
        try self.printI("return {s}_deserialize_key(&_r, &key_out);\n", .{c_name});
        try self.write("}\n\n");

        try self.print("DDS_InstanceHandle_t {s}DataReader::lookup_instance(const {s}& key) {{\n", .{ class_name, cpp_qname });
        try self.writeI("uint8_t _hash[16];\n");
        try self.printI("if ({s}_compute_key_hash(&key, _hash)) return DDS_HANDLE_NIL;\n", .{c_name});
        try self.writeI("return zzdds_lookup_instance_reader(reader_, _hash);\n");
        try self.write("}\n\n");

        try self.print("static int {s}_reader_n_impl(DDS_DataReader reader, {s} *values, zzdds_sample_info *infos, int max, uint32_t ss, uint32_t vs, uint32_t is, bool destructive) {{\n", .{ class_name, cpp_qname });
        try self.writeI("zzdds_raw_sample_array _arr{};\n");
        try self.writeI("int _n = destructive ?\n");
        self.indent_depth += 1;
        try self.writeI("zzdds_take_n_raw(reader, ss, vs, is, max, &_arr) :\n");
        try self.writeI("zzdds_read_n_raw(reader, ss, vs, is, max, &_arr);\n");
        self.indent_depth -= 1;
        try self.writeI("if (_n <= 0) return _n;\n");
        try self.writeI("for (int _i = 0; _i < _n; _i++) {\n");
        self.indent_depth += 1;
        try self.writeI("infos[_i] = _arr.samples[_i].info;\n");
        try self.writeI("ZidlCdrReader _r;\n");
        try self.writeI("int _rc = zidl_cdr_reader_init(&_r, _arr.samples[_i].data, _arr.samples[_i].data_len);\n");
        try self.writeI("if (!_rc) _rc = infos[_i].valid_data ?\n");
        self.indent_depth += 1;
        try self.printI("{s}_deserialize(&_r, &values[_i]) :\n", .{c_name});
        try self.printI("{s}_deserialize_key(&_r, &values[_i]);\n", .{c_name});
        self.indent_depth -= 1;
        try self.writeI("if (_rc) {\n");
        self.indent_depth += 1;
        try self.writeI("for (int _j = 0; _j < _i; _j++) values[_j] = {};\n");
        try self.writeI("zzdds_return_raw_samples(reader, &_arr);\n");
        try self.writeI("return _rc;\n");
        self.indent_depth -= 1;
        try self.writeI("}\n");
        self.indent_depth -= 1;
        try self.writeI("}\n");
        try self.writeI("zzdds_return_raw_samples(reader, &_arr);\n");
        try self.writeI("return _n;\n");
        try self.write("}\n\n");

        try self.print("int {s}DataReader::take_n({s} *values, zzdds_sample_info *infos, int max, uint32_t ss, uint32_t vs, uint32_t is) {{\n", .{ class_name, cpp_qname });
        try self.writeI("return ");
        try self.print("{s}_reader_n_impl(reader_, values, infos, max, ss, vs, is, true);\n", .{class_name});
        try self.write("}\n\n");
        try self.print("int {s}DataReader::read_n({s} *values, zzdds_sample_info *infos, int max, uint32_t ss, uint32_t vs, uint32_t is) {{\n", .{ class_name, cpp_qname });
        try self.writeI("return ");
        try self.print("{s}_reader_n_impl(reader_, values, infos, max, ss, vs, is, false);\n", .{class_name});
        try self.write("}\n\n");

        try self.print("int {s}DataReader::take_loaned(Loan& out) {{\n", .{class_name});
        try self.writeI("zzdds_loaned_sample _loan{};\n");
        try self.writeI("Sample _sample{};\n");
        try self.writeI("int _n = zzdds_take_loaned_raw(reader_, &_loan, &_sample.info);\n");
        try self.writeI("if (_n != 1) return _n;\n");
        try self.writeI("ZidlCdrReader _r;\n");
        try self.writeI("int _rc = zidl_cdr_reader_init(&_r, _loan.data, _loan.data_len);\n");
        try self.writeI("if (_rc) { zzdds_return_loaned_raw(reader_, &_loan); return _rc; }\n");
        try self.printI("_rc = _sample.info.valid_data ? {s}_deserialize(&_r, &_sample.value) : {s}_deserialize_key(&_r, &_sample.value);\n", .{ c_name, c_name });
        try self.writeI("if (_rc) { zzdds_return_loaned_raw(reader_, &_loan); return _rc; }\n");
        try self.writeI("out = Loan(this, _loan, _sample);\n");
        try self.writeI("return 1;\n");
        try self.write("}\n\n");

        try self.print("void {s}DataReader::Loan::reset() {{\n", .{class_name});
        try self.writeI("if (active_ && reader_) {\n");
        self.indent_depth += 1;
        try self.writeI("zzdds_return_loaned_raw(reader_->reader_, &loan_);\n");
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
                    const access = try std.fmt.allocPrint(self.alloc, "_v->{s}()", .{cas.name});
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
                    const access = try std.fmt.allocPrint(self.alloc, "_v->{s}()", .{cas.name});
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
                self.indent_depth += 1;
                if (cas.dimensions.len > 0) {
                    const cpp_type = try cppTypeStr(self.alloc, cas.type_ref);
                    defer self.alloc.free(cpp_type);
                    const dims_str = try cArrayDimsStr(self.alloc, cas.dimensions);
                    defer self.alloc.free(dims_str);
                    const tmp_name = try std.fmt.allocPrint(self.alloc, "_tmp_{s}", .{cas.name});
                    defer self.alloc.free(tmp_name);
                    try self.printI("{s} {s}{s}{{}};\n", .{ cpp_type, tmp_name, dims_str });
                    try self.emitReadArray(cas.type_ref, cas.name, tmp_name, cas.dimensions, 0);
                    try self.printI("_v->{s}({s});\n", .{ cas.name, tmp_name });
                } else {
                    const cpp_type = try cppTypeStr(self.alloc, cas.type_ref);
                    defer self.alloc.free(cpp_type);
                    const tmp_name = try std.fmt.allocPrint(self.alloc, "_tmp_{s}", .{cas.name});
                    defer self.alloc.free(tmp_name);
                    try self.printI("{s} {s}{{}};\n", .{ cpp_type, tmp_name });
                    try self.emitReadForTypeRef(cas.type_ref, cas.name, tmp_name);
                    try self.printI("_v->{s}({s});\n", .{ cas.name, tmp_name });
                }
                try self.writeI("break;\n");
                self.indent_depth -= 1;
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
                self.indent_depth += 1;
                if (cas.dimensions.len > 0) {
                    const cpp_type = try cppTypeStr(self.alloc, cas.type_ref);
                    defer self.alloc.free(cpp_type);
                    const dims_str = try cArrayDimsStr(self.alloc, cas.dimensions);
                    defer self.alloc.free(dims_str);
                    const tmp_name = try std.fmt.allocPrint(self.alloc, "_tmp_{s}", .{cas.name});
                    defer self.alloc.free(tmp_name);
                    try self.printI("{s} {s}{s}{{}};\n", .{ cpp_type, tmp_name, dims_str });
                    try self.emitReadArray(cas.type_ref, cas.name, tmp_name, cas.dimensions, 0);
                    try self.printI("_v->{s}({s});\n", .{ cas.name, tmp_name });
                } else {
                    const cpp_type = try cppTypeStr(self.alloc, cas.type_ref);
                    defer self.alloc.free(cpp_type);
                    const tmp_name = try std.fmt.allocPrint(self.alloc, "_tmp_{s}", .{cas.name});
                    defer self.alloc.free(tmp_name);
                    try self.printI("{s} {s}{{}};\n", .{ cpp_type, tmp_name });
                    try self.emitReadForTypeRef(cas.type_ref, cas.name, tmp_name);
                    try self.printI("_v->{s}({s});\n", .{ cas.name, tmp_name });
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
                    try self.emitSkipArray(cas.type_ref, cas.dimensions, 0);
                } else {
                    try self.emitSkipForTypeRef(cas.type_ref);
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

    fn emitSkipMember(self: *CdrGenerator, m: ir.StructMember) anyerror!void {
        if (m.annotations.is_optional) {
            const pvar = try std.fmt.allocPrint(self.alloc, "_sp_{s}", .{m.name});
            defer self.alloc.free(pvar);
            try self.printI("{{ int8_t {s};\n", .{pvar});
            self.indent_depth += 1;
            try self.printI("_rc = zidl_cdr_read_bool(_r, &{s});\n", .{pvar});
            try self.writeI("if (_rc) return _rc;\n");
            try self.printI("if ({s}) {{\n", .{pvar});
            self.indent_depth += 1;
            if (m.dimensions.len > 0) {
                try self.emitSkipArray(m.type_ref, m.dimensions, 0);
            } else {
                try self.emitSkipForTypeRef(m.type_ref);
            }
            self.indent_depth -= 1;
            try self.writeI("}\n");
            self.indent_depth -= 1;
            try self.writeI("}\n");
            return;
        }
        if (m.dimensions.len > 0) {
            try self.emitSkipArray(m.type_ref, m.dimensions, 0);
        } else {
            try self.emitSkipForTypeRef(m.type_ref);
        }
    }

    fn emitSkipArray(self: *CdrGenerator, elem_tr: ir.TypeRef, dims: []const u64, dim_idx: usize) anyerror!void {
        const var_name = try std.fmt.allocPrint(self.alloc, "_ski{d}", .{dim_idx});
        defer self.alloc.free(var_name);
        try self.printI("{{ uint32_t {s}; for ({s} = 0; {s} < {d}u; {s}++) {{\n", .{
            var_name, var_name, var_name, dims[0], var_name,
        });
        self.indent_depth += 1;
        if (dims.len > 1) {
            try self.emitSkipArray(elem_tr, dims[1..], dim_idx + 1);
        } else {
            try self.emitSkipForTypeRef(elem_tr);
        }
        self.indent_depth -= 1;
        try self.writeI("}\n");
        try self.writeI("}\n");
    }

    fn emitSkipForTypeRef(self: *CdrGenerator, tr: ir.TypeRef) anyerror!void {
        switch (tr) {
            .base => |b| {
                const fn_name = baseCReadFn(b);
                const c_type = baseToCType(b);
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
                try self.writeI("for (uint32_t _si = 0; _si < _sl; _si++) {\n");
                self.indent_depth += 1;
                try self.emitSkipForTypeRef(seq.element.*);
                self.indent_depth -= 1;
                try self.writeI("}\n");
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
                try self.emitSkipForTypeRef(m.key.*);
                try self.emitSkipForTypeRef(m.value.*);
                self.indent_depth -= 1;
                try self.writeI("}\n");
                self.indent_depth -= 1;
                try self.writeI("}\n");
            },
            .named => |td| switch (td) {
                .enum_ => |e| {
                    const suffix = enumCStorageType(e.annotations);
                    const ctype = enumCTypeName(e.annotations);
                    try self.printI("{{ {s} _tmp; _rc = zidl_cdr_read_{s}(_r, &_tmp); if (_rc) return _rc; }}\n", .{ ctype, suffix });
                },
                .bitmask => |bm| {
                    const ctype = bitmaskStorageType(bm.annotations);
                    const suffix = enumCStorageType(bm.annotations);
                    try self.printI("{{ {s} _tmp; _rc = zidl_cdr_read_{s}(_r, &_tmp); if (_rc) return _rc; }}\n", .{ ctype, suffix });
                },
                .typedef => |t| {
                    if (t.dimensions.len > 0) {
                        try self.emitSkipArray(t.type_ref, t.dimensions, 0);
                    } else {
                        try self.emitSkipForTypeRef(t.type_ref);
                    }
                },
                .struct_, .exception, .union_ => {
                    const c_type = try self.prefixedCName(ir.typeDeclQualifiedName(td));
                    defer self.alloc.free(c_type);
                    try self.printI("_rc = {s}_skip(_r);\n", .{c_type});
                    try self.writeI("if (_rc) return _rc;\n");
                },
                .bitset => |bs| {
                    const ctype = bitsetCdrStorageType(bs);
                    const suffix = bitsetCdrFnSuffix(bs);
                    try self.printI("{{ {s} _tmp; _rc = zidl_cdr_read_{s}(_r, &_tmp); if (_rc) return _rc; }}\n", .{ ctype, suffix });
                },
                else => try self.writeI("return ZIDL_CDR_INVALID;\n"),
            },
            .fixed_pt => |fp| {
                try self.printI("{{ double _tmp; _rc = zidl_cdr_read_fixed(_r, {d}, {d}, &_tmp); if (_rc) return _rc; }}\n", .{ fp.digits, fp.scale });
            },
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
    try gen.emit(spec);
}

const ConcreteImplGenerator = struct {
    alloc: std.mem.Allocator,
    opts: interface.Options,
    hdr: *std.ArrayList(u8),
    src: *std.ArrayList(u8),
    entity_base_ifaces: std.StringHashMapUnmanaged(void) = .{},

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
            "#include \"{s}.hpp\"\n#include \"{s}.h\"\n#include \"zzdds_c.h\"\n#include <memory>\n\n",
            .{ self.opts.input_stem, self.opts.input_stem },
        );
        for (spec.imports) |import_name| {
            const stem = try interface.includeStemForImport(self.alloc, import_name);
            defer self.alloc.free(stem);
            try self.hdrPrint("#include \"{s}_impl.hpp\"\n", .{stem});
        }
        if (spec.imports.len != 0) try self.hdrWrite("\n");
        try self.srcPrint(
            "// Generated by zidl from {s}.idl \u{2014} DO NOT EDIT\n#include \"{s}_impl.hpp\"\n\n",
            .{ self.opts.input_stem, self.opts.input_stem },
        );
        try collectEntityBaseNames(self.alloc, spec.items, &self.entity_base_ifaces);
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
        try self.hdrPrint(
            "    explicit {s}Impl({s} h) noexcept : ptr_(h) {{}}\n",
            .{ iface.name, c_name },
        );
        try self.hdrPrint("    ~{s}Impl() override = default;\n", .{iface.name});
        // Use 'override' only when the abstract interface declares native_handle().
        // Other concrete Impl classes still expose native_handle() for adapter code,
        // unless a base interface already declares a conflicting native_handle()
        // with a different C handle return type.
        if (self.ifaceDeclaresNativeHandle(iface)) {
            try self.hdrPrint(
                "    {s} native_handle() const noexcept override {{ return ptr_; }}\n\n",
                .{c_name},
            );
        } else if (try self.nativeHandleBase(iface)) |base_iface| {
            const base_c = try cNameOf(self.alloc, base_iface.qualified_name);
            defer self.alloc.free(base_c);
            const handle_expr = try self.handleExprForOwner(iface, base_iface, "ptr_");
            defer self.alloc.free(handle_expr);
            try self.hdrPrint(
                "    {s} native_handle() const noexcept override {{ return {s}; }}\n\n",
                .{ base_c, handle_expr },
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
            "\nprivate:\n    friend {s} zidl_concrete_handle(const {s}Impl& self) noexcept {{ return self.ptr_; }}\n    {s} ptr_;\n}};\n\n",
            .{ c_name, iface.name, c_name },
        );
    }

    // ── Entity Impl method implementations (source) ───────────────────────────

    fn emitEntityImplMethods(self: *ConcreteImplGenerator, iface: *const ir.Interface) !void {
        const c_name = try cNameOf(self.alloc, iface.qualified_name);
        defer self.alloc.free(c_name);

        var ops = std.ArrayListUnmanaged(OwnedOperation).empty;
        defer ops.deinit(self.alloc);
        var attrs = std.ArrayListUnmanaged(OwnedAttribute).empty;
        defer attrs.deinit(self.alloc);
        try collectOwnedIfaceMembers(self.alloc, iface, &ops, &attrs);

        try self.srcPrint("// \u{2500}\u{2500} {s}Impl \u{2500}\u{2500}\n\n", .{iface.name});

        for (ops.items) |op| {
            try self.emitEntityMethod(iface, op.owner, c_name, iface.name, op.op);
        }
        for (attrs.items) |attr| {
            try self.emitEntityAttr(iface, attr.owner, c_name, iface.name, attr.attr);
        }
    }

    fn emitEntityMethod(
        self: *ConcreteImplGenerator,
        iface: *const ir.Interface,
        owner: *const ir.Interface,
        c_name: []const u8,
        class_name: []const u8,
        op: *const ir.Operation,
    ) !void {
        _ = c_name;
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

        // Build the C call
        const ret_kind = returnAdaptKind(op.return_type);
        switch (ret_kind) {
            .entity => {
                const ret_c = try self.typeRefToCType(op.return_type.?);
                defer self.alloc.free(ret_c);
                const impl_name = try self.entityImplName(op.return_type.?);
                defer self.alloc.free(impl_name);
                try self.srcPrint("    {s} _h = {s}_{s}({s}", .{ ret_c, owner_c_name, op.name, handle_expr });
                try self.emitAdaptedParams(op.params);
                try self.srcWrite(");\n");
                try self.srcWrite("    if (!_h.ptr) return nullptr;\n");
                try self.srcPrint("    return std::make_shared<{s}>(_h);\n", .{impl_name});
            },
            .str_ret => {
                try self.srcPrint("    const char* _r = {s}_{s}({s}", .{ owner_c_name, op.name, handle_expr });
                try self.emitAdaptedParams(op.params);
                try self.srcWrite(");\n");
                try self.srcWrite("    return _r ? std::string(_r) : std::string{};\n");
            },
            .direct => {
                const needs_post = for (op.params) |p| {
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
                            .complex_struct_out => try self.emitComplexStructAdaptOut(p.name, p.type_ref),
                            .seq_out => try self.emitSeqParamAdaptOut(p),
                            else => {},
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
        c_name: []const u8,
        class_name: []const u8,
        attr: *const ir.Attribute,
    ) !void {
        _ = c_name;
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
                try self.srcPrint("    {s} _h = {s}_get_{s}({s});\n", .{ ret_c, owner_c_name, attr.name, handle_expr });
                try self.srcWrite("    if (!_h.ptr) return nullptr;\n");
                try self.srcPrint("    return std::make_shared<{s}>(_h);\n", .{impl_name});
            },
            .str_ret => {
                try self.srcPrint("    const char* _r = {s}_get_{s}({s});\n", .{ owner_c_name, attr.name, handle_expr });
                try self.srcWrite("    return _r ? std::string(_r) : std::string{};\n");
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
                    const use_virtual = switch (p.type_ref) {
                        .named => |td| switch (td) {
                            .interface => |iface| self.ifaceDeclaresNativeHandle(iface),
                            else => false,
                        },
                        else => false,
                    };
                    if (use_virtual) {
                        try self.srcPrint(
                            "({s} ? {s}->native_handle() : {s}{{nullptr, nullptr}})",
                            .{ p.name, p.name, ct },
                        );
                    } else {
                        const impl_name = try self.entityImplName(p.type_ref);
                        defer self.alloc.free(impl_name);
                        try self.srcPrint(
                            "([](const auto& _p) -> {s} {{ if (!_p) return {s}{{nullptr, nullptr}}; if (auto* _impl = dynamic_cast<{s}*>(_p.get())) return zidl_concrete_handle(*_impl); throw std::invalid_argument(\"zidl: incompatible entity implementation for {s}\"); }})({s})",
                            .{ ct, ct, impl_name, ct, p.name },
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
        const is_string = switch (elem_tr) {
            .string => true,
            else => false,
        };
        if (is_string) {
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
        } else {
            const cpp_elem_type = try cppTypeStr(self.alloc, elem_tr);
            defer self.alloc.free(cpp_elem_type);
            try self.srcPrint("{s}// Borrowed sequence buffer; valid only for the duration of this C ABI call.\n", .{indent});
            try self.srcPrint(
                "{s}{s}._buffer = const_cast<{s}*>({s}.data());\n",
                .{ indent, c_dst, cpp_elem_type, cpp_src },
            );
            try self.srcPrint("{s}{s}._length = static_cast<int32_t>({s}.size());\n", .{ indent, c_dst, cpp_src });
            try self.srcPrint("{s}{s}._maximum = static_cast<int32_t>({s}.size());\n", .{ indent, c_dst, cpp_src });
        }
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
            try self.emitFieldAdaptOut(cpp_field, c_field, mem.type_ref);
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
    ) anyerror!void {
        switch (tr) {
            .base, .fixed_pt => try self.srcPrint("    {s} = {s};\n", .{ cpp_dst, c_src }),
            .string => try self.srcPrint(
                "    {s} = {s} ? std::string({s}) : std::string{{}};\n",
                .{ cpp_dst, c_src, c_src },
            ),
            .sequence => |seq| try self.emitSeqFieldAdaptOut(cpp_dst, c_src, seq.element.*),
            .named => |td| switch (td) {
                .typedef => |t| if (t.dimensions.len == 0)
                    try self.emitFieldAdaptOut(cpp_dst, c_src, t.type_ref)
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
                        try self.emitFieldAdaptOut(cpp_f, c_f, mem.type_ref);
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
    ) anyerror!void {
        const is_string = switch (elem_tr) {
            .string => true,
            else => false,
        };
        if (is_string) {
            try self.srcPrint("    {s}.clear();\n", .{cpp_dst});
            try self.srcPrint("    for (int32_t _i = 0; _i < {s}._length; ++_i)\n", .{c_src});
            try self.srcPrint(
                "        {s}.emplace_back({s}._buffer[_i] ? {s}._buffer[_i] : \"\");\n",
                .{ cpp_dst, c_src, c_src },
            );
        } else {
            try self.srcPrint("    if ({s}._buffer)\n", .{c_src});
            try self.srcPrint(
                "        {s}.assign({s}._buffer, {s}._buffer + {s}._length);\n",
                .{ cpp_dst, c_src, c_src, c_src },
            );
            try self.srcPrint("    else\n        {s}.clear();\n", .{cpp_dst});
        }
    }

    /// Copy a C sequence out-param into the C++ reference, then free the C buffer.
    /// Only callable when paramAdaptKind(p) == .seq_out.
    fn emitSeqParamAdaptOut(self: *ConcreteImplGenerator, p: ir.Parameter) !void {
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
        try self.emitSeqFieldAdaptOut(p.name, c_var, elem);
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
                                // Wrap entity handle in Impl
                                try self.srcPrint("std::make_shared<{s}Impl>({s})", .{ piface.name, p.name });
                            } else {
                                try self.srcPrint("/* TODO({s}) */ {s}", .{ p.name, p.name });
                            }
                        },
                        else => {
                            const ct = try self.paramToCType(p);
                            defer self.alloc.free(ct);
                            // status structs: reinterpret_cast to C++ type
                            const cpp_t = try self.typeRefToCpp(p.type_ref);
                            defer self.alloc.free(cpp_t);
                            try self.srcPrint("reinterpret_cast<const ::{s}&>(*{s})", .{ cpp_t[2..], p.name });
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
                break :blk std.fmt.allocPrint(self.alloc, "std::vector<{s}>", .{elem});
            },
            .string => self.alloc.dupe(u8, "std::string"),
            .wstring => self.alloc.dupe(u8, "std::wstring"),
            .fixed_pt => self.alloc.dupe(u8, "double"),
            .map => |m| blk: {
                const ks = try self.typeRefToCpp(m.key.*);
                defer self.alloc.free(ks);
                const vs = try self.typeRefToCpp(m.value.*);
                defer self.alloc.free(vs);
                break :blk std.fmt.allocPrint(self.alloc, "std::map<{s}, {s}>", .{ ks, vs });
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
                .interface => |iface| std.fmt.allocPrint(self.alloc, "::{s}Impl", .{iface.qualified_name}),
                else => self.alloc.dupe(u8, "EntityImpl"),
            },
            else => self.alloc.dupe(u8, "EntityImpl"),
        };
    }

    fn ifaceDeclaresNativeHandle(self: *ConcreteImplGenerator, iface: *const ir.Interface) bool {
        return !isCallbackIface(iface) and
            std.mem.indexOfScalar(u8, iface.qualified_name, ':') != null and
            iface.bases.len == 0 and
            !self.entity_base_ifaces.contains(iface.qualified_name);
    }

    fn nativeHandleBase(self: *ConcreteImplGenerator, iface: *const ir.Interface) !?*const ir.Interface {
        var found: ?*const ir.Interface = null;
        for (iface.bases) |base| {
            if (base != .interface) continue;
            const base_iface = base.interface;
            const candidate = if (self.ifaceDeclaresNativeHandle(base_iface) or
                importedLeafBaseDeclaresNativeHandle(iface, base_iface))
                base_iface
            else
                try self.nativeHandleBase(base_iface);
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
        if (!isSimpleTypeRef(m.type_ref)) return false;
    }
    return true;
}

fn isAdaptableSeqElemIn(tr: ir.TypeRef) bool {
    return switch (tr) {
        .base => true,
        .string => true,
        .named => |td| switch (td) {
            .typedef => |t| t.dimensions.len == 0 and isAdaptableSeqElemIn(t.type_ref),
            .enum_, .bitmask, .bitset => true,
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

fn collectEntityBaseNames(
    alloc: std.mem.Allocator,
    items: []const ir.ModuleItem,
    result: *std.StringHashMapUnmanaged(void),
) anyerror!void {
    for (items) |item| {
        switch (item) {
            .module => |m| try collectEntityBaseNames(alloc, m.items, result),
            .type_decl => |td| switch (td) {
                .interface => |iface| {
                    if (!isCallbackIface(iface)) {
                        for (iface.bases) |base| {
                            switch (base) {
                                .interface => |b| if (!isCallbackIface(b)) {
                                    try result.put(alloc, b.qualified_name, {});
                                },
                                else => {},
                            }
                        }
                    }
                },
                else => {},
            },
            else => {},
        }
    }
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
                    .in_ => std.fmt.allocPrint(alloc, "const {s}*", .{cn}),
                    else => std.fmt.allocPrint(alloc, "{s}*", .{cn}),
                };
            },
        },
        else => alloc.dupe(u8, "void*"),
    };
}

fn isCallbackIface(iface: *const ir.Interface) bool {
    for (iface.raw) |ann| {
        if (std.mem.eql(u8, ann.name, "callback")) return true;
    }
    return std.mem.endsWith(u8, iface.name, "Listener");
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

fn importedLeafBaseDeclaresNativeHandle(
    derived: *const ir.Interface,
    base: *const ir.Interface,
) bool {
    return !isCallbackIface(base) and
        std.mem.indexOfScalar(u8, base.qualified_name, ':') != null and
        base.bases.len == 0 and
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
                try self.print("        return std::string(zidl_{s}_{s}(ptr_", .{ c_name, op.name });
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
            try self.print("        return std::string(zidl_{s}_get_{s}(ptr_));\n", .{ c_name, attr.name });
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
                break :blk std.fmt.allocPrint(self.alloc, "std::vector<{s}>", .{elem});
            },
            .string => self.alloc.dupe(u8, "std::string"),
            .wstring => self.alloc.dupe(u8, "std::wstring"),
            .fixed_pt => self.alloc.dupe(u8, "double"),
            .map => |m| blk: {
                const ks = try self.typeRefToCpp(m.key.*);
                defer self.alloc.free(ks);
                const vs = try self.typeRefToCpp(m.value.*);
                defer self.alloc.free(vs);
                break :blk std.fmt.allocPrint(self.alloc, "std::map<{s}, {s}>", .{ ks, vs });
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

fn isZzddsTopicStructCpp(s: *const ir.Struct) bool {
    return structHasKeyCpp(s) and !s.annotations.is_nested and s.annotations.extensibility != .mutable;
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
fn cppTypeStr(alloc: std.mem.Allocator, tr: ir.TypeRef) anyerror![]u8 {
    return switch (tr) {
        .base => |b| alloc.dupe(u8, baseToCppType(b)),
        .named => |td| std.fmt.allocPrint(alloc, "::{s}", .{ir.typeDeclQualifiedName(td)}),
        .sequence => |seq| blk: {
            const elem = try cppTypeStr(alloc, seq.element.*);
            defer alloc.free(elem);
            break :blk std.fmt.allocPrint(alloc, "std::vector<{s}>", .{elem});
        },
        .string => alloc.dupe(u8, "std::string"),
        .wstring => alloc.dupe(u8, "std::wstring"),
        .fixed_pt => alloc.dupe(u8, "double"),
        .map => |m| blk: {
            const ks = try cppTypeStr(alloc, m.key.*);
            defer alloc.free(ks);
            const vs = try cppTypeStr(alloc, m.value.*);
            defer alloc.free(vs);
            break :blk std.fmt.allocPrint(alloc, "std::map<{s}, {s}>", .{ ks, vs });
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
    if (opts.generate_interfaces and needs.memory) try gen.write("#include <memory>\n");
    if (needs.map) try gen.write("#include <map>\n");
    if (needs.optional) try gen.write("#include <optional>\n");
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

test "cpp_backend: zzdds_c omitted when no qualifying topic struct" {
    var out = try testGenOpts(
        "struct Plain { long id; }; @nested struct NestedKey { @key long id; }; @mutable struct MutableKey { @key long id; };",
        "plain",
        .{ .generate_zzdds_wrappers = true },
    );
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(!has(s, "zzdds_c.h"));
    try testing.expect(!has(s, "DataWriter"));
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
    try testing.expect(has(s, "zzdds_loaned_sample loan_{};"));
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
    const opts = interface.Options{ .input_stem = stem, .generate_interfaces = true };
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
    try testing.expect(has(s, "static int Topic_write_kind(DDS_DataWriter writer, int xcdr_version, zzdds_write_kind kind, const ::Topic& value, bool key_only) {"));
    try testing.expect(has(s, "return Topic_write_kind(writer_, xcdr_version_, ZZDDS_WRITE_ALIVE, value, false);"));
    try testing.expect(has(s, "int TopicDataReader::take_loaned(Loan& out) {"));
    try testing.expect(has(s, "out = Loan(this, _loan, _sample);"));
    try testing.expect(has(s, "void TopicDataReader::Loan::reset() {"));
}

test "cpp_backend cdr: _reader_n_impl cleans up partial samples on deserialization failure" {
    var out = try testGenCdrOpts(
        "@appendable struct Topic { @key long id; string name; };",
        "topic",
        .{ .generate_zzdds_wrappers = true },
    );
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "for (int _j = 0; _j < _i; _j++) values[_j] = {};"));
    try testing.expect(has(s, "zzdds_return_raw_samples(reader, &_arr);"));
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
        "struct Plain { long id; }; @nested struct NestedKey { @key long id; }; @mutable struct MutableKey { @key long id; };",
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
    const opts = interface.Options{ .input_stem = "dcps", .cpp_generate_impl = true };
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
    try testing.expect(has(hdr, "DDS_Foo native_handle() const noexcept { return ptr_; }"));
    // FooListenerBase declaration moved to dcps.hpp (Generator); not in dcps_impl.hpp
    try testing.expect(!has(hdr, "class FooListenerBridge"));
    try testing.expect(has(src, "DDS_Foo_do_something(ptr_)"));
    try testing.expect(has(src, "DDS_Entity_enable(DDS_Foo_as_DDS_Entity(ptr_))"));
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

test "cpp_backend: B1+B3 — entity return wraps in Impl" {
    var res = try testGenConcreteImpl(
        \\module DDS {
        \\    interface Bar {};
        \\    interface Foo { Bar get_bar(); };
        \\};
    );
    defer res.deinit();
    const src = res.src.items;
    try testing.expect(has(src, "make_shared<::DDS::BarImpl>"));
    try testing.expect(has(src, "if (!_h.ptr)"));
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
    try testing.expect(has(src, "make_shared<DataWriterImpl>"));
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
    try testing.expect(has(src, "dynamic_cast<::zzdds::DomainParticipantFactoryImpl*>(_p.get())) return zidl_concrete_handle(*_impl);"));
    try testing.expect(has(src, "throw std::invalid_argument(\"zidl: incompatible entity implementation for zzdds_DomainParticipantFactory\")"));
    try testing.expect(!has(src, "dynamic_cast<::zzdds::DomainParticipantFactoryImpl*>(_p.get())) return _impl->native_handle();"));
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
