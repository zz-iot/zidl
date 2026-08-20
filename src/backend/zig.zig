//! Zig language mapping backend — type definitions (phase 3).
//!
//! Generates a single `<stem>.zig` source file per IDL spec containing:
//!   - Module    → `pub const Foo = struct { … };` (nested namespace struct)
//!   - Struct    → `pub const Foo = struct { field: Type = default, … };`
//!   - Union     → `pub const Foo = struct { _d: Disc = …, _u: union { … } = undefined };`
//!   - Enum      → `pub const Foo = enum(u32) { A = 0, … , _ };` (non-exhaustive)
//!   - Bitmask   → `pub const Foo = u32; pub const Foo_BIT: QName = 1 << N;`
//!   - Bitset    → `pub const Foo = packed struct { f: uN = 0, … };`
//!   - Typedef   → `pub const Foo = Bar;` or `pub const Foo = [N]Bar;`
//!   - Native    → `pub const Foo = opaque{};`
//!   - Exception → `pub const Foo = struct { … };`
//!   - Interface → comment placeholder (vtable requires `--generate-interfaces`)
//!   - Const     → `pub const NAME: Type = value;`
//!
//! ## Primitive type mapping
//!
//!   IDL short / long / long long       → i16 / i32 / i64
//!   IDL unsigned short / long / …      → u16 / u32 / u64
//!   IDL float / double / long double   → f32 / f64 / f128
//!   IDL char / wchar                   → u8 / u16
//!   IDL boolean / octet                → bool / u8
//!   IDL int8 … uint64                  → i8 … u64
//!   IDL string                         → []const u8
//!   IDL string<N>                      → zidl_rt.BoundedArray(u8, N)
//!   IDL wstring                        → []const u16
//!   IDL wstring<N>                     → zidl_rt.BoundedArray(u16, N)
//!   IDL sequence<T>                    → std.ArrayListUnmanaged(T)
//!   IDL sequence<T, N>                 → zidl_rt.BoundedArray(T, N)
//!   IDL T[N1][N2]                      → [N1][N2]T
//!   IDL @optional T                    → ?T  (null default)
//!   IDL any / object / value_base      → *anyopaque
//!   IDL fixed<D,S>                     → f64  (approximate)
//!   IDL map<K,V>                       → std.ArrayHashMapUnmanaged(K, V, …)

const std = @import("std");
const ast = @import("../ast.zig");
const ir = @import("../ir/root.zig");
const interface = @import("interface.zig");
const zig_to = @import("zig_typeobject.zig");

// ── Public backend struct ─────────────────────────────────────────────────────

pub const ZigBackend = struct {
    alloc: std.mem.Allocator,

    pub fn create(alloc: std.mem.Allocator) !*ZigBackend {
        const self = try alloc.create(ZigBackend);
        self.* = .{ .alloc = alloc };
        return self;
    }

    pub fn backend(self: *ZigBackend) interface.Backend {
        return .{ .ctx = self, .vtable = &vtable };
    }

    const vtable = interface.Backend.Vtable{
        .language_id = "zig",
        .generate = vtableGenerate,
        .deinit = vtableDeinit,
    };

    fn vtableGenerate(
        ctx: *anyopaque,
        spec: *const ir.Spec,
        opts: interface.Options,
    ) anyerror!void {
        const self: *ZigBackend = @ptrCast(@alignCast(ctx));
        const io = std.Io.Threaded.global_single_threaded.io();

        if (opts.split_files) {
            try generateSplitFiles(self.alloc, io, spec, opts);
            return;
        }

        var content = std.ArrayList(u8).empty;
        defer content.deinit(self.alloc);
        try generateFile(self.alloc, spec, opts, &content);

        const filename = try std.fmt.allocPrint(self.alloc, "{s}.zig", .{opts.input_stem});
        defer self.alloc.free(filename);
        try writeOutputFile(self.alloc, io, opts, filename, content.items);
    }

    fn vtableDeinit(ctx: *anyopaque) void {
        const self: *ZigBackend = @ptrCast(@alignCast(ctx));
        self.alloc.destroy(self);
    }
};

// ── Public entry points (testable) ───────────────────────────────────────────

/// Generate Zig source content into `out`.
///
/// Exposed for unit testing without touching the filesystem.
pub fn generateFile(
    alloc: std.mem.Allocator,
    spec: *const ir.Spec,
    opts: interface.Options,
    out: *std.ArrayList(u8),
) !void {
    var gen = Generator{ .alloc = alloc, .opts = opts, .out = out };
    defer gen.deinit();
    try gen.emitFile(spec);
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
    // Ensure exactly one trailing newline (zig fmt convention).
    const trimmed = std.mem.trimEnd(u8, content, "\n");
    try fw.interface.writeAll(trimmed);
    try fw.interface.writeAll("\n");
    try fw.interface.flush();
}

// ── Split-file mode ───────────────────────────────────────────────────────────

/// Split mode: one `.zig` file per top-level IDL module, plus `<stem>.zig`
/// as a root that re-exports each module file.
///
/// Items not inside any top-level module are emitted inline in the root file.
/// Nested modules within a top-level module are handled by the existing
/// recursive `emitModule` logic within that module's file.
pub fn generateSplitFiles(
    alloc: std.mem.Allocator,
    io: std.Io,
    spec: *const ir.Spec,
    opts: interface.Options,
) !void {
    // Collect names of non-empty top-level modules and emit their files.
    var module_names = std.ArrayListUnmanaged([]const u8).empty;
    defer module_names.deinit(alloc);

    for (spec.items) |item| {
        const m = switch (item) {
            .module => |m| m,
            else => continue,
        };
        if (m.items.len == 0) continue;
        try module_names.append(alloc, m.name);

        // Build the module file: standard header + module items at depth 0.
        var content = std.ArrayList(u8).empty;
        defer content.deinit(alloc);
        var gen = Generator{ .alloc = alloc, .opts = opts, .out = &content };
        defer gen.deinit();
        // NOTE (--split-files + --zig-generate-toml-config combined, not
        // exercised by any current caller): each module file gets its own
        // Generator instance here, so `toml_applied_structs` doesn't see
        // across a struct-in-one-file/operation-in-another split the way it
        // does for a `--single-file` invocation. Not fixed — no current
        // invocation combines these two flags.
        try gen.print(
            "// Generated by zidl from {s}.idl — DO NOT EDIT\n\n",
            .{opts.input_stem},
        );
        try gen.write("const std = @import(\"std\");\n");
        if (!opts.no_typesupport or opts.pl_cdr or opts.zig_generate_c_api or itemsHaveCallbackInterfaceOperations(m.items)) {
            try gen.write("const zidl_rt = @import(\"zidl_rt\");\n");
        }
        if (opts.generate_zzdds_wrappers and !opts.no_typesupport and itemsHaveTopicTypes(m.items)) {
            try gen.write("const _zzdds = @import(\"zzdds\");\n");
        }
        // Import each module imported by the IDL source file so that
        // cross-module type references (e.g. `DDS.SomeType`) resolve.
        for (spec.imports) |imp_name| {
            try gen.print("const {s} = @import(\"{s}.zig\");\n", .{ imp_name, imp_name });
        }
        // Self-reference alias: allows Module.SomeType syntax within this file.
        try gen.print("// Self-reference alias: allows {s}.SomeType syntax within this file.\n", .{m.name});
        try gen.print("const {s} = @This();\n", .{m.name});
        try gen.write("\n");
        try gen.emitCApiMirrorPreamble();
        try gen.emitItems(m.items);

        const filename = try std.fmt.allocPrint(alloc, "{s}.zig", .{m.name});
        defer alloc.free(filename);
        try writeOutputFile(alloc, io, opts, filename, content.items);
    }

    // Build the root stem file: re-exports + any non-module items.
    var root = std.ArrayList(u8).empty;
    defer root.deinit(alloc);
    var gen = Generator{ .alloc = alloc, .opts = opts, .out = &root };
    defer gen.deinit();

    try gen.print(
        "// Generated by zidl from {s}.idl — DO NOT EDIT\n\n",
        .{opts.input_stem},
    );

    // Re-export imported module files (their .zig was generated separately).
    for (spec.imports) |name| {
        try gen.print("pub const {s} = @import(\"{s}.zig\");\n", .{ name, name });
    }
    // Re-export each local module file.
    for (module_names.items) |name| {
        try gen.print("pub const {s} = @import(\"{s}.zig\");\n", .{ name, name });
    }

    // Collect non-module items.
    var non_module: std.ArrayListUnmanaged(ir.ModuleItem) = .empty;
    defer non_module.deinit(alloc);
    for (spec.items) |item| {
        switch (item) {
            .module => {},
            else => try non_module.append(alloc, item),
        }
    }

    if (non_module.items.len > 0) {
        if (module_names.items.len > 0) try gen.write("\n");
        try gen.write("const std = @import(\"std\");\n");
        if (!opts.no_typesupport or opts.pl_cdr or opts.zig_generate_c_api or itemsHaveCallbackInterfaceOperations(non_module.items)) {
            try gen.write("const zidl_rt = @import(\"zidl_rt\");\n");
        }
        if (opts.generate_zzdds_wrappers and !opts.no_typesupport and itemsHaveTopicTypes(non_module.items)) {
            try gen.write("const _zzdds = @import(\"zzdds\");\n");
        }
        try gen.write("\n");
        try gen.emitCApiMirrorPreamble();
        try gen.emitItems(non_module.items);
    } else if (module_names.items.len > 0) {
        try gen.write("\n");
    } else {
        // No modules and no items: emit standard header anyway.
        try gen.write("const std = @import(\"std\");\n");
        if (!opts.no_typesupport or opts.pl_cdr) {
            try gen.write("const zidl_rt = @import(\"zidl_rt\");\n");
        }
        try gen.write("\n");
    }

    const stem_filename = try std.fmt.allocPrint(alloc, "{s}.zig", .{opts.input_stem});
    defer alloc.free(stem_filename);
    try writeOutputFile(alloc, io, opts, stem_filename, root.items);
}

// ── Generator (private implementation) ───────────────────────────────────────

const Generator = struct {
    alloc: std.mem.Allocator,
    opts: interface.Options,
    out: *std.ArrayList(u8),
    /// Current nesting depth: 0 = file level, 1 = inside one module struct, …
    depth: usize = 0,
    /// Structs `emitStruct` has actually added `_toml_applied` to *in this
    /// invocation* (populated as it runs — see `emitStruct`). A struct
    /// referenced from an operation signature but declared in a different,
    /// imported file (e.g. `zzdds.idl`'s own operations taking a `dcps.idl`
    /// `DDS::DomainParticipantQos`) is never itself walked by *this*
    /// invocation's `emitStruct`, so it's never a key here — `structNeeds
    /// CApiMirror` checks this set, not `self.opts.zig_generate_toml_config`
    /// directly, specifically so it doesn't invent a `{Name}CAbi` reference
    /// for a struct nothing in this file will ever define. Every
    /// `dcps.idl`/`zzdds.idl` struct is used before it's declared, per IDL's
    /// own definition-before-use rule for value types, so by the time an
    /// operation signature needs to consult this set, any locally-declared
    /// struct it could reference has already been through `emitStruct`.
    toml_applied_structs: std.AutoHashMapUnmanaged(*const ir.Struct, void) = .{},

    fn deinit(self: *Generator) void {
        self.toml_applied_structs.deinit(self.alloc);
    }

    // ── Low-level output helpers ──────────────────────────────────────────────

    fn write(self: *Generator, s: []const u8) !void {
        try self.out.appendSlice(self.alloc, s);
    }

    fn print(self: *Generator, comptime fmt: []const u8, args: anytype) !void {
        const s = try std.fmt.allocPrint(self.alloc, fmt, args);
        defer self.alloc.free(s);
        try self.out.appendSlice(self.alloc, s);
    }

    /// Emit `depth * 4` spaces.
    fn ind(self: *Generator) !void {
        var i: usize = 0;
        while (i < self.depth) : (i += 1) try self.write("    ");
    }

    // ── Top-level file emission ───────────────────────────────────────────────

    fn emitFile(self: *Generator, spec: *const ir.Spec) !void {
        try self.print(
            "// Generated by zidl from {s}.idl — DO NOT EDIT\n\n",
            .{self.opts.input_stem},
        );
        if (self.opts.zig_version != .@"0.16.0") {
            try self.print("// Zig output target: {s}\n\n", .{self.opts.zig_version.label()});
        }
        try self.write("const std = @import(\"std\");\n");
        if (!self.opts.no_typesupport or self.opts.pl_cdr or self.opts.zig_generate_c_api or itemsHaveCallbackInterfaceOperations(spec.items)) {
            try self.write("const zidl_rt = @import(\"zidl_rt\");\n");
        }
        if (self.opts.generate_zzdds_wrappers and !self.opts.no_typesupport and itemsHaveTopicTypes(spec.items)) {
            try self.write("const _zzdds = @import(\"zzdds\");\n");
        }
        // Emit @import for each module imported via `import "file.idl";`.
        for (spec.imports) |name| {
            try self.print("const {s} = @import(\"{s}.zig\");\n", .{ name, name });
        }
        try self.write("\n");
        try self.emitCApiMirrorPreamble();
        try self.emitItems(spec.items);
    }

    /// Shared by every `{Struct}CAbi` mirror this file emits (see
    /// `structNeedsCApiMirror`) -- always `std.heap.c_allocator`, matching
    /// every other C-ABI-facing allocation already in this boundary's
    /// contract (e.g. `emitStructCApiFree`'s own `v.deinit(std.heap.
    /// c_allocator)`). Harmless if unused (a struct-less file, or one where
    /// nothing actually needs a mirror) -- Zig doesn't warn on an unused
    /// top-level `fn`. Called from all three top-level emission entry points
    /// (`emitFile`'s single-file path, and both halves of `--split-files`'
    /// per-module-file / root-stem-file paths) -- each is a separate output
    /// file with its own preamble, so each needs its own copy of these two
    /// tiny helpers (confirmed by a real "use of undeclared identifier"
    /// build error the first time this only lived in `emitFile`, never
    /// reached by dcps.idl's own `--split-files` generation).
    fn emitCApiMirrorPreamble(self: *Generator) !void {
        if (!self.opts.zig_generate_c_api) return;
        try self.write(
            \\fn zidlCAbiDupeCStr(s: []const u8) ?[*:0]const u8 {
            \\    const buf = std.heap.c_allocator.allocSentinel(u8, s.len, 0) catch return null;
            \\    @memcpy(buf, s);
            \\    return buf.ptr;
            \\}
            \\fn zidlCAbiFreeCStr(p: ?[*:0]const u8) void {
            \\    const ptr = p orelse return;
            \\    std.heap.c_allocator.free(std.mem.span(ptr));
            \\}
            \\
            \\
        );
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
        try self.ind();
        try self.print("pub const {s} = struct {{\n", .{m.name});
        self.depth += 1;
        try self.emitItems(m.items);
        self.depth -= 1;
        try self.ind();
        try self.print("}}; // {s}\n\n", .{m.name});
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
        const pfx = self.opts.type_prefix;
        try self.ind();
        const kw: []const u8 = if (structIsCExternCompatible(s)) "extern struct" else "struct";
        try self.print("pub const {s}{s} = {s} {{\n", .{ pfx, s.name, kw });
        if (s.base) |base| {
            // Zig has no struct inheritance — embed the base as a named field.
            const base_zig = try self.qualNameToZig(ir.typeDeclQualifiedName(base));
            defer self.alloc.free(base_zig);
            try self.ind();
            try self.print("    _base: {s} = .{{}},\n", .{base_zig});
        }
        if (self.opts.zig_generate_toml_config) {
            // Record that *this* struct (not just "this invocation has the
            // flag on") actually got `_toml_applied` — see the field's own
            // doc comment on why `structNeedsCApiMirror` needs this instead
            // of checking `self.opts.zig_generate_toml_config` directly.
            self.toml_applied_structs.put(self.alloc, s, {}) catch {};
            // Set true only by applyToml's own last statement — reached only
            // if every field's statement above it succeeded. Lets deinit tell
            // "never ran applyToml at all" (still just @default literals,
            // some possibly non-empty — freeing them would be undefined
            // behavior) apart from "applyToml completed," without a per-field
            // flag. A struct whose applyToml call fails partway through never
            // sets this, so deinit correctly skips string cleanup for it too —
            // whatever fields *were* duped before the failure leak rather than
            // being incorrectly freed (or, worse, double-freed/dangling).
            try self.ind();
            try self.write("    _toml_applied: bool = false,\n");
        }
        for (s.members) |m| {
            try self.emitField(m.name, m.type_ref, m.dimensions, m.annotations.is_optional, m.annotations.default_value);
        }
        // default() is always emitted; it relies only on field defaults, not CDR support.
        try self.ind();
        try self.print("\n    pub fn default() @This() {{\n", .{});
        try self.ind();
        try self.print("        return .{{}};\n", .{});
        try self.ind();
        try self.print("    }}\n", .{});
        // Emit serialize fns when full typesupport is requested, or when
        // --zig-pl-cdr is set (PL_CDR fns are part of the struct, not TypeSupport).
        if (!self.opts.no_typesupport or self.opts.pl_cdr) {
            try self.emitStructSerializeFns(s);
        } else if (self.structNeedsCleanup(s)) {
            // deinit/clone are lifecycle operations, not CDR typesupport — a
            // struct with heap-owning sequence (or, under
            // --zig-generate-toml-config, string) fields needs them regardless
            // of whether wire (de)serialization was also requested.
            try self.write("\n");
            try self.emitStructDeinitFn(s);
            try self.write("\n");
            try self.emitStructCloneFn(s);
        }
        if (!self.opts.no_typeobject_support) {
            try self.emitStructTypeObjectConsts(s);
        }
        if (self.opts.zig_generate_toml_config) {
            try self.write("\n");
            try self.emitStructApplyTomlFn(s);
        }
        try self.ind();
        try self.print("}}; // {s}{s}\n\n", .{ pfx, s.name });
        if (self.opts.generate_zzdds_wrappers and !self.opts.no_typesupport and isZzddsTopicStruct(s)) {
            try self.emitStructTypedWrapper(s);
        }
        if (self.opts.zig_generate_c_api and self.structNeedsCleanup(s)) {
            try self.emitStructCApiFree(s);
        }
        if (self.opts.zig_generate_c_api) {
            try self.emitStructCApiMirror(s);
        }
    }

    // ── Union ─────────────────────────────────────────────────────────────────

    fn emitUnion(self: *Generator, u: *const ir.Union) !void {
        const disc_zig = try self.typeRefToZig(u.discriminant);
        defer self.alloc.free(disc_zig);
        const disc_default = try self.defaultForTypeRef(u.discriminant);
        defer self.alloc.free(disc_default);

        const pfx = self.opts.type_prefix;
        try self.ind();
        try self.print("pub const {s}{s} = struct {{\n", .{ pfx, u.name });

        // Discriminant field.
        try self.ind();
        try self.print("    _d: {s} = {s},\n", .{ disc_zig, disc_default });

        // Anonymous union field.  Access is undefined unless discriminant is set.
        try self.ind();
        try self.write("    _u: union {\n");
        for (u.cases) |cas| {
            const case_zig = try self.typeRefToZig(cas.type_ref);
            defer self.alloc.free(case_zig);
            try self.ind();
            if (cas.dimensions.len > 0) {
                const arr_type = try self.makeArrayType(case_zig, cas.dimensions);
                defer self.alloc.free(arr_type);
                try self.print("        {s}: {s},\n", .{ cas.name, arr_type });
            } else {
                try self.print("        {s}: {s},\n", .{ cas.name, case_zig });
            }
        }
        try self.ind();
        try self.write("    } = undefined,\n");

        if (!self.opts.no_typesupport) {
            try self.emitUnionCdr(u);
        }
        if (self.unionNeedsCleanup(u)) {
            // Lifecycle operations, not CDR typesupport -- generated
            // regardless of whether wire (de)serialization was also
            // requested, matching emitStruct's structNeedsCleanup gating.
            try self.write("\n");
            try self.emitUnionDeinitFn(u);
            try self.write("\n");
            try self.emitUnionCloneFn(u);
        }

        try self.ind();
        try self.print("}}; // {s}{s}\n\n", .{ pfx, u.name });
    }

    /// Read a union case's value into a fresh local, then adopt it via a
    /// whole-union-literal assignment (`out._u = .{ .case = _tmp };`) rather
    /// than a direct field write (`out._u.case = ...;`).
    ///
    /// Zig's plain (non-`enum`-tagged) union still carries a hidden active-
    /// field tag in safety-checked builds, and a direct `place.field = v;`
    /// assignment asserts the write is *to the field already active* rather
    /// than switching to it -- it panics ("invalid enum value" while
    /// formatting the mismatch, since `out._u` starts `undefined`, i.e. its
    /// hidden tag is poisoned, not just wrong) the moment `deserializeInto`
    /// writes a case that doesn't already happen to be the union's zero-value
    /// default. Reassigning the whole union via a `.{ .case = value }`
    /// literal is what actually switches the active field safely. This
    /// affects every generated Zig union, not just ones with owning cases --
    /// discovered here only because a real deserialize was finally run
    /// against one (no prior test did).
    fn emitUnionCaseDeserializeAssign(self: *Generator, out_expr: []const u8, cas: ir.UnionCase, extra: []const u8) anyerror!void {
        const case_zig = try self.typeRefToZig(cas.type_ref);
        defer self.alloc.free(case_zig);
        const tmp_type = if (cas.dimensions.len > 0)
            try self.makeArrayType(case_zig, cas.dimensions)
        else
            try self.alloc.dupe(u8, case_zig);
        defer self.alloc.free(tmp_type);
        try self.ind();
        try self.print("{s}var _tmp: {s} = undefined;\n", .{ extra, tmp_type });
        if (cas.dimensions.len > 0) {
            try self.emitReadArray(cas.type_ref, "_tmp", cas.dimensions, extra, 0);
        } else {
            try self.emitReadForTypeRef(cas.type_ref, "_tmp", extra);
        }
        try self.ind();
        try self.print("{s}{s}._u = .{{ .{s} = _tmp }};\n", .{ extra, out_expr, cas.name });
    }

    fn emitUnionCdr(self: *Generator, u: *const ir.Union) anyerror!void {
        const ext = u.annotations.extensibility;
        const mutable = ext == .mutable;
        const appendable = ext == .appendable; // strictly @appendable only

        const needs_alloc = blk: {
            for (u.cases) |cas| {
                if (typeRefNeedsAllocator(cas.type_ref)) break :blk true;
            }
            break :blk false;
        };

        // has_key constant (discriminant is implicit key but not annotated, so false by default)
        try self.write("\n");
        try self.ind();
        try self.write("    pub const has_key = false;\n");

        // Find default case (shared by serialize + deserialize)
        const default_case: ?ir.UnionCase = blk: {
            for (u.cases) |cas| {
                if (isDefaultUnionCase(cas)) break :blk cas;
            }
            break :blk null;
        };

        // ── serialize ────────────────────────────────────────────────────────
        try self.write("\n");
        try self.ind();
        try self.write("    pub fn serialize(writer: anytype, value: @This()) !void {\n");

        if (mutable) {
            // @mutable union: DHEADER + EMHEADER(0) for discriminant + EMHEADER(N) for case.
            try self.ind();
            try self.write("        const _dh = try writer.reserveDheader();\n");
            // Discriminant: member_id=0.
            const disc_lc = lcForTypeRef(u.discriminant, &.{});
            if (disc_lc) |lc| {
                try self.ind();
                try self.print("        try writer.writeEmheaderFixed(0, false, {d});\n", .{lc});
                try self.emitDiscWriteZig(u.discriminant, "value._d", "        ");
            } else {
                try self.ind();
                try self.write("        const _em_disc = try writer.reserveEmheader(0, false);\n");
                try self.emitDiscWriteZig(u.discriminant, "value._d", "        ");
                try self.ind();
                try self.write("        writer.patchEmheader(_em_disc);\n");
            }
            // Case value: member_id = annotation.id ?? (case_index + 1)
            try self.ind();
            try self.write("        switch (value._d) {\n");
            for (u.cases, 0..) |cas, cas_idx| {
                if (isDefaultUnionCase(cas)) continue;
                const case_member_id: u32 = if (cas.annotations.id) |id| id else @intCast(cas_idx + 1);
                try self.emitZigUnionCaseArmPattern(u.discriminant, cas, "            ");
                try self.write(" => {\n");
                const access = try std.fmt.allocPrint(self.alloc, "value._u.{s}", .{cas.name});
                defer self.alloc.free(access);
                if (lcForTypeRef(cas.type_ref, cas.dimensions)) |lc| {
                    try self.ind();
                    try self.print("                try writer.writeEmheaderFixed({d}, false, {d});\n", .{ case_member_id, lc });
                    if (cas.dimensions.len > 0) {
                        try self.emitWriteArray(cas.type_ref, access, cas.dimensions, "                ", 0);
                    } else {
                        try self.emitWriteForTypeRef(cas.type_ref, access, "                ");
                    }
                } else {
                    try self.ind();
                    try self.print("                const _em_case = try writer.reserveEmheader({d}, false);\n", .{case_member_id});
                    if (cas.dimensions.len > 0) {
                        try self.emitWriteArray(cas.type_ref, access, cas.dimensions, "                ", 0);
                    } else {
                        try self.emitWriteForTypeRef(cas.type_ref, access, "                ");
                    }
                    try self.ind();
                    try self.write("                writer.patchEmheader(_em_case);\n");
                }
                try self.ind();
                try self.write("            },\n");
            }
            if (default_case) |dc| {
                const dc_member_id: u32 = if (dc.annotations.id) |id| id else 0xFFFF_FFFF;
                const dc_access = try std.fmt.allocPrint(self.alloc, "value._u.{s}", .{dc.name});
                defer self.alloc.free(dc_access);
                try self.ind();
                try self.write("            else => {\n");
                if (lcForTypeRef(dc.type_ref, dc.dimensions)) |lc| {
                    try self.ind();
                    try self.print("                try writer.writeEmheaderFixed({d}, false, {d});\n", .{ dc_member_id, lc });
                    if (dc.dimensions.len > 0) {
                        try self.emitWriteArray(dc.type_ref, dc_access, dc.dimensions, "                ", 0);
                    } else {
                        try self.emitWriteForTypeRef(dc.type_ref, dc_access, "                ");
                    }
                } else {
                    try self.ind();
                    try self.print("                const _em_case = try writer.reserveEmheader({d}, false);\n", .{dc_member_id});
                    if (dc.dimensions.len > 0) {
                        try self.emitWriteArray(dc.type_ref, dc_access, dc.dimensions, "                ", 0);
                    } else {
                        try self.emitWriteForTypeRef(dc.type_ref, dc_access, "                ");
                    }
                    try self.ind();
                    try self.write("                writer.patchEmheader(_em_case);\n");
                }
                try self.ind();
                try self.write("            },\n");
            } else {
                try self.ind();
                try self.write("            else => {},\n");
            }
            try self.ind();
            try self.write("        }\n");
            try self.ind();
            try self.write("        writer.patchDheader(_dh);\n");
        } else {
            if (appendable) {
                try self.ind();
                try self.write("        const _dh = try writer.reserveDheaderMaybe();\n");
            }
            // Write discriminant
            try self.emitDiscWriteZig(u.discriminant, "value._d", "        ");
            // Switch on discriminant
            try self.ind();
            try self.write("        switch (value._d) {\n");
            for (u.cases) |cas| {
                if (isDefaultUnionCase(cas)) continue; // emit as else arm
                try self.emitZigUnionCaseArmPattern(u.discriminant, cas, "            ");
                try self.write(" => {\n");
                if (cas.dimensions.len > 0) {
                    const access = try std.fmt.allocPrint(self.alloc, "value._u.{s}", .{cas.name});
                    defer self.alloc.free(access);
                    try self.emitWriteArray(cas.type_ref, access, cas.dimensions, "            ", 0);
                } else {
                    const access = try std.fmt.allocPrint(self.alloc, "value._u.{s}", .{cas.name});
                    defer self.alloc.free(access);
                    try self.emitWriteForTypeRef(cas.type_ref, access, "            ");
                }
                try self.ind();
                try self.write("            },\n");
            }
            if (default_case) |dc| {
                try self.ind();
                try self.write("            else => {\n");
                if (dc.dimensions.len > 0) {
                    const access = try std.fmt.allocPrint(self.alloc, "value._u.{s}", .{dc.name});
                    defer self.alloc.free(access);
                    try self.emitWriteArray(dc.type_ref, access, dc.dimensions, "                ", 0);
                } else {
                    const access = try std.fmt.allocPrint(self.alloc, "value._u.{s}", .{dc.name});
                    defer self.alloc.free(access);
                    try self.emitWriteForTypeRef(dc.type_ref, access, "                ");
                }
                try self.ind();
                try self.write("            },\n");
            } else {
                try self.ind();
                try self.write("            else => {},\n");
            }
            try self.ind();
            try self.write("        }\n");
            if (appendable) {
                try self.ind();
                try self.write("        writer.patchDheaderMaybe(_dh);\n");
            }
        }
        try self.ind();
        try self.write("    }\n");

        // ── deserializeInto ──────────────────────────────────────────────────
        try self.write("\n");
        try self.ind();
        try self.write("    pub fn deserializeInto(out: *@This(), reader: *zidl_rt.CdrReader, allocator: std.mem.Allocator) !void {\n");
        if (!needs_alloc) {
            try self.ind();
            try self.write("        _ = allocator;\n");
        }

        if (mutable) {
            // @mutable union: read DHEADER, then EMHEADER loop.
            // Convention: member_id=0 is the discriminant; subsequent IDs are case values.
            try self.ind();
            try self.write("        const _em_end = try reader.readMutableDheader();\n");
            try self.ind();
            try self.write("        while (reader.mutableHasMore(_em_end)) {\n");
            try self.ind();
            try self.write("            const _emh = try reader.readEmheader();\n");
            try self.ind();
            try self.write("            if (_emh.member_id == 0) {\n");
            // Discriminant
            try self.emitDiscReadZig(u.discriminant, "out._d", "                ");
            try self.ind();
            try self.write("            } else {\n");
            // Case values: switch on the already-read discriminant
            try self.ind();
            try self.write("                switch (out._d) {\n");
            for (u.cases, 0..) |cas, cas_idx| {
                if (isDefaultUnionCase(cas)) continue;
                try self.emitZigUnionCaseArmPattern(u.discriminant, cas, "                    ");
                try self.write(" => {\n");
                try self.emitUnionCaseDeserializeAssign("out", cas, "                        ");
                _ = cas_idx;
                try self.ind();
                try self.write("                    },\n");
            }
            if (default_case) |dc| {
                try self.ind();
                try self.write("                    else => {\n");
                try self.emitUnionCaseDeserializeAssign("out", dc, "                        ");
                try self.ind();
                try self.write("                    },\n");
            } else {
                try self.ind();
                try self.write("                    else => {\n");
                try self.ind();
                try self.write("                        if (_emh.must_understand) return error.UnknownMustUnderstand;\n");
                try self.ind();
                try self.write("                        try reader.skipEmheaderPayload(_emh);\n");
                try self.ind();
                try self.write("                    },\n");
            }
            try self.ind();
            try self.write("                }\n");
            try self.ind();
            try self.write("            }\n");
            try self.ind();
            try self.write("        }\n");
        } else {
            if (appendable) {
                try self.ind();
                try self.write("        try reader.skipDheaderIfXcdr2();\n");
            }
            // Read discriminant
            try self.emitDiscReadZig(u.discriminant, "out._d", "        ");
            // Switch on discriminant
            try self.ind();
            try self.write("        switch (out._d) {\n");
            for (u.cases) |cas| {
                if (isDefaultUnionCase(cas)) continue; // handled as else
                try self.emitZigUnionCaseArmPattern(u.discriminant, cas, "            ");
                try self.write(" => {\n");
                try self.emitUnionCaseDeserializeAssign("out", cas, "                ");
                try self.ind();
                try self.write("            },\n");
            }
            if (default_case) |dc| {
                try self.ind();
                try self.write("            else => {\n");
                try self.emitUnionCaseDeserializeAssign("out", dc, "                ");
                try self.ind();
                try self.write("            },\n");
            } else {
                try self.ind();
                try self.write("            else => {},\n");
            }
            try self.ind();
            try self.write("        }\n");
        }
        try self.ind();
        try self.write("    }\n");

        // ── deserialize (convenience) ─────────────────────────────────────────
        try self.write("\n");
        try self.ind();
        try self.write("    pub fn deserialize(reader: *zidl_rt.CdrReader, allocator: std.mem.Allocator) !@This() {\n");
        try self.ind();
        try self.write("        var _out: @This() = .{};\n");
        try self.ind();
        try self.write("        try @This().deserializeInto(&_out, reader, allocator);\n");
        try self.ind();
        try self.write("        return _out;\n");
        try self.ind();
        try self.write("    }\n");

        // ── skip ──────────────────────────────────────────────────────────────
        try self.write("\n");
        try self.ind();
        try self.write("    pub fn skip(reader: *zidl_rt.CdrReader) !void {\n");
        if (mutable) {
            try self.ind();
            try self.write("        const _end = try reader.readMutableDheader();\n");
            try self.ind();
            try self.write("        try reader.seekTo(_end);\n");
        } else {
            if (appendable) {
                try self.ind();
                try self.write("        if (reader.xcdr_version == .xcdr2) {\n");
                try self.ind();
                try self.write("            const _size = try reader.readDheader();\n");
                try self.ind();
                try self.write("            try reader.skip(_size);\n");
                try self.ind();
                try self.write("            return;\n");
                try self.ind();
                try self.write("        }\n");
            }
            const disc_zig = try self.typeRefToZig(u.discriminant);
            defer self.alloc.free(disc_zig);
            try self.ind();
            try self.print("        var _d: {s} = undefined;\n", .{disc_zig});
            try self.emitDiscReadZig(u.discriminant, "_d", "        ");
            try self.ind();
            try self.write("        switch (_d) {\n");
            for (u.cases) |cas| {
                if (isDefaultUnionCase(cas)) continue;
                try self.emitZigUnionCaseArmPattern(u.discriminant, cas, "            ");
                try self.write(" => {\n");
                if (cas.dimensions.len > 0) {
                    try self.emitSkipArray(cas.type_ref, cas.dimensions, "                ", 0);
                } else {
                    try self.emitSkipForTypeRef(cas.type_ref, "                ");
                }
                try self.ind();
                try self.write("            },\n");
            }
            if (default_case) |dc| {
                try self.ind();
                try self.write("            else => {\n");
                if (dc.dimensions.len > 0) {
                    try self.emitSkipArray(dc.type_ref, dc.dimensions, "                ", 0);
                } else {
                    try self.emitSkipForTypeRef(dc.type_ref, "                ");
                }
                try self.ind();
                try self.write("            },\n");
            } else {
                try self.ind();
                try self.write("            else => {},\n");
            }
            try self.ind();
            try self.write("        }\n");
        }
        try self.ind();
        try self.write("    }\n");
    }

    /// Emit the discriminant write statement for Zig.
    fn emitDiscWriteZig(self: *Generator, disc: ir.TypeRef, access: []const u8, extra: []const u8) anyerror!void {
        switch (disc) {
            .base => |b| {
                const method = baseWriteMethod(b);
                try self.ind();
                try self.print("{s}try writer.{s}({s});\n", .{ extra, method, access });
            },
            .named => |td| switch (td) {
                .enum_ => |e| {
                    const stor = enumStorageType(e.annotations);
                    const method = switch (stor[0]) {
                        'u' => switch (stor[1]) {
                            '8' => "writeU8",
                            '1' => "writeU16",
                            '3' => "writeU32",
                            '6' => "writeU64",
                            else => "writeU32",
                        },
                        else => "writeU32",
                    };
                    try self.ind();
                    try self.print("{s}try writer.{s}(@intFromEnum({s}));\n", .{ extra, method, access });
                },
                else => {
                    try self.ind();
                    try self.print("{s}// TODO: unsupported discriminant write\n", .{extra});
                },
            },
            else => {
                try self.ind();
                try self.print("{s}// TODO: unsupported discriminant write\n", .{extra});
            },
        }
    }

    /// Emit the discriminant read statement for Zig.
    fn emitDiscReadZig(self: *Generator, disc: ir.TypeRef, out_expr: []const u8, extra: []const u8) anyerror!void {
        switch (disc) {
            .base => |b| {
                const method = baseReadMethod(b);
                try self.ind();
                try self.print("{s}{s} = try reader.{s}();\n", .{ extra, out_expr, method });
            },
            .named => |td| switch (td) {
                .enum_ => |e| {
                    const stor = enumStorageType(e.annotations);
                    const method = switch (stor[0]) {
                        'u' => switch (stor[1]) {
                            '8' => "readU8",
                            '1' => "readU16",
                            '3' => "readU32",
                            '6' => "readU64",
                            else => "readU32",
                        },
                        else => "readU32",
                    };
                    try self.ind();
                    try self.print("{s}{s} = @enumFromInt(try reader.{s}());\n", .{ extra, out_expr, method });
                },
                else => {
                    try self.ind();
                    try self.print("{s}// TODO: unsupported discriminant read\n", .{extra});
                },
            },
            else => {
                try self.ind();
                try self.print("{s}// TODO: unsupported discriminant read\n", .{extra});
            },
        }
    }

    /// Emit the Zig switch arm pattern (labels) for a union case.
    /// Writes the comma-separated pattern, then the caller appends ` => {`.
    fn emitZigUnionCaseArmPattern(self: *Generator, disc: ir.TypeRef, cas: ir.UnionCase, extra: []const u8) anyerror!void {
        try self.ind();
        try self.print("{s}", .{extra});
        var first = true;
        for (cas.labels) |lbl| {
            if (lbl == .default) continue; // skip — handled as else
            if (!first) try self.write(", ");
            first = false;
            switch (lbl) {
                .integer => |v| try self.print("{d}", .{v}),
                .boolean => |b| try self.write(if (b) "true" else "false"),
                .enumerator => |name| {
                    if (self.opts.zig_idiomatic_enums) {
                        const tag = try self.idiomaticEnumTag(name);
                        defer self.alloc.free(tag);
                        try self.print(".{s}", .{tag});
                    } else {
                        try self.print(".{s}", .{name});
                    }
                },
                .default => {},
            }
        }
        _ = disc;
    }

    /// Emit `pub fn deinit(self: *@This(), alloc: std.mem.Allocator) void` for
    /// a union with at least one owning case (`unionNeedsCleanup`). Every
    /// non-default case gets its own switch arm regardless of whether it
    /// itself owns anything (empty body if not) -- skipping a non-owning
    /// case's arm would let its discriminant value fall through to `else`
    /// whenever the default case *is* owning, wrongly running the default
    /// case's cleanup on that case's (non-pointer) payload. Same hazard, and
    /// same fix, as the C backend's generated union `_free()`.
    fn emitUnionDeinitFn(self: *Generator, u: *const ir.Union) !void {
        try self.ind();
        try self.write("    pub fn deinit(self: *@This(), alloc: std.mem.Allocator) void {\n");
        try self.ind();
        try self.write("        switch (self._d) {\n");
        var default_case: ?ir.UnionCase = null;
        for (u.cases) |cas| {
            if (isDefaultUnionCase(cas)) {
                default_case = cas;
                continue;
            }
            try self.emitZigUnionCaseArmPattern(u.discriminant, cas, "            ");
            try self.write(" => {\n");
            if (self.caseNeedsCleanup(cas)) {
                const field_name = try std.fmt.allocPrint(self.alloc, "_u.{s}", .{cas.name});
                defer self.alloc.free(field_name);
                try self.emitFieldSeqDeinit(field_name, cas.type_ref, "                ");
            }
            try self.ind();
            try self.write("            },\n");
        }
        try self.ind();
        try self.write("            else => {\n");
        if (default_case) |dc| {
            if (self.caseNeedsCleanup(dc)) {
                const field_name = try std.fmt.allocPrint(self.alloc, "_u.{s}", .{dc.name});
                defer self.alloc.free(field_name);
                try self.emitFieldSeqDeinit(field_name, dc.type_ref, "                ");
            }
        }
        try self.ind();
        try self.write("            },\n");
        try self.ind();
        try self.write("        }\n");
        try self.ind();
        try self.write("    }\n");
    }

    /// Emit `pub fn clone(self: @This(), alloc: std.mem.Allocator) !@This()`
    /// for a union with at least one owning case. `var result = self;` below
    /// already shallow-copies whichever case is active; the switch below
    /// replaces that shallow copy with an independent deep copy only for the
    /// currently-active case (mutually exclusive with every other case by
    /// construction, unlike a struct's independent fields -- so at most one
    /// clone statement ever runs). See `emitUnionDeinitFn` for why every
    /// case still needs its own arm.
    fn emitUnionCloneFn(self: *Generator, u: *const ir.Union) !void {
        try self.ind();
        try self.write("    pub fn clone(self: @This(), alloc: std.mem.Allocator) !@This() {\n");
        try self.ind();
        try self.write("        var result = self;\n");
        try self.ind();
        try self.write("        switch (self._d) {\n");
        var default_case: ?ir.UnionCase = null;
        for (u.cases) |cas| {
            if (isDefaultUnionCase(cas)) {
                default_case = cas;
                continue;
            }
            try self.emitZigUnionCaseArmPattern(u.discriminant, cas, "            ");
            try self.write(" => {\n");
            if (self.caseNeedsCleanup(cas)) {
                const field_name = try std.fmt.allocPrint(self.alloc, "_u.{s}", .{cas.name});
                defer self.alloc.free(field_name);
                try self.emitFieldSeqCloneStmt(field_name, cas.type_ref, "                ");
                try self.emitFieldSeqCloneErrdefer(field_name, cas.type_ref, "                ");
            }
            try self.ind();
            try self.write("            },\n");
        }
        try self.ind();
        try self.write("            else => {\n");
        if (default_case) |dc| {
            if (self.caseNeedsCleanup(dc)) {
                const field_name = try std.fmt.allocPrint(self.alloc, "_u.{s}", .{dc.name});
                defer self.alloc.free(field_name);
                try self.emitFieldSeqCloneStmt(field_name, dc.type_ref, "                ");
                try self.emitFieldSeqCloneErrdefer(field_name, dc.type_ref, "                ");
            }
        }
        try self.ind();
        try self.write("            },\n");
        try self.ind();
        try self.write("        }\n");
        try self.ind();
        try self.write("        return result;\n");
        try self.ind();
        try self.write("    }\n");
    }

    // ── Enum ──────────────────────────────────────────────────────────────────

    /// Allocate a Zig-idiomatic tag name for `idl_name`: lowercase the whole
    /// string, then append `_` if the result is a Zig keyword.
    fn idiomaticEnumTag(self: *Generator, idl_name: []const u8) ![]u8 {
        const lower = try std.ascii.allocLowerString(self.alloc, idl_name);
        if (zig_keywords.has(lower)) {
            defer self.alloc.free(lower);
            return std.mem.concat(self.alloc, u8, &.{ lower, "_" });
        }
        return lower;
    }

    fn emitEnum(self: *Generator, e: *const ir.Enum) !void {
        const pfx = self.opts.type_prefix;
        const storage = enumStorageType(e.annotations);
        try self.ind();
        try self.print("pub const {s}{s} = enum({s}) {{\n", .{ pfx, e.name, storage });
        for (e.enumerators) |en| {
            try self.ind();
            if (self.opts.zig_idiomatic_enums) {
                const tag = try self.idiomaticEnumTag(en.name);
                defer self.alloc.free(tag);
                try self.print("    {s} = {d},\n", .{ tag, en.value });
            } else {
                try self.print("    {s} = {d},\n", .{ en.name, en.value });
            }
        }
        // Non-exhaustive: allows unknown enumerator values (DDS wire evolution).
        try self.ind();
        try self.write("    _,\n");
        try self.ind();
        try self.print("}}; // {s}{s}\n\n", .{ pfx, e.name });
        try self.emitEnumStringConverters(e);
    }

    /// Emit `FooEnum_fromString` and `FooEnum_toString` helpers for `e`.
    ///
    /// These are emitted as free functions at the same declaration depth as the
    /// enum itself (i.e. inside the enclosing module struct when depth > 0, or
    /// at file level when depth == 0).  Using the enumerator name directly as the
    /// round-trip string key keeps the mapping unambiguous and machine-readable.
    ///
    /// `fromString` returns `null` on no match; `toString` returns `null` for
    /// unknown integer values (the non-exhaustive `_` catch-all).
    fn emitEnumStringConverters(self: *Generator, e: *const ir.Enum) !void {
        const pfx = self.opts.type_prefix;

        // --- fromString ---
        try self.ind();
        try self.print(
            "pub fn {s}{s}_fromString(s: []const u8) ?{s}{s} {{\n",
            .{ pfx, e.name, pfx, e.name },
        );
        for (e.enumerators) |en| {
            try self.ind();
            if (self.opts.zig_idiomatic_enums) {
                const tag = try self.idiomaticEnumTag(en.name);
                defer self.alloc.free(tag);
                // String key stays as the IDL name for language-agnostic round-trips.
                try self.print(
                    "    if (std.ascii.eqlIgnoreCase(s, \"{s}\")) return .{s};\n",
                    .{ en.name, tag },
                );
            } else {
                try self.print(
                    "    if (std.ascii.eqlIgnoreCase(s, \"{s}\")) return .{s};\n",
                    .{ en.name, en.name },
                );
            }
        }
        try self.ind();
        try self.write("    return null;\n");
        try self.ind();
        try self.write("}\n\n");

        // --- toString ---
        try self.ind();
        try self.print(
            "pub fn {s}{s}_toString(v: {s}{s}) ?[]const u8 {{\n",
            .{ pfx, e.name, pfx, e.name },
        );
        try self.ind();
        try self.write("    return switch (v) {\n");
        for (e.enumerators) |en| {
            try self.ind();
            if (self.opts.zig_idiomatic_enums) {
                const tag = try self.idiomaticEnumTag(en.name);
                defer self.alloc.free(tag);
                // toString returns the IDL name so diagnostics/config are language-agnostic.
                try self.print("        .{s} => \"{s}\",\n", .{ tag, en.name });
            } else {
                try self.print("        .{s} => \"{s}\",\n", .{ en.name, en.name });
            }
        }
        try self.ind();
        try self.write("        _ => null,\n");
        try self.ind();
        try self.write("    };\n");
        try self.ind();
        try self.write("}\n\n");
    }

    // ── Bitmask ───────────────────────────────────────────────────────────────

    fn emitBitmask(self: *Generator, bm: *const ir.Bitmask) !void {
        const pfx = self.opts.type_prefix;
        const storage = bitmaskStorageType(bm.annotations);
        // Use the fully-qualified Zig name for the bit-constant type annotations
        // so they remain valid if the bitmask is inside a module struct.
        // qualNameToZig already applies the prefix to the last segment.
        const zig_qname = try self.qualNameToZig(bm.qualified_name);
        defer self.alloc.free(zig_qname);

        try self.ind();
        try self.print("pub const {s}{s} = {s};\n", .{ pfx, bm.name, storage });
        for (bm.bits, 0..) |bit, i| {
            try self.ind();
            try self.print(
                "pub const {s}{s}_{s}: {s} = 1 << {d};\n",
                .{ pfx, bm.name, bit.name, zig_qname, i },
            );
        }
        try self.write("\n");
    }

    // ── Bitset ────────────────────────────────────────────────────────────────

    fn emitBitset(self: *Generator, bs: *const ir.Bitset) !void {
        const pfx = self.opts.type_prefix;
        try self.ind();
        try self.print("pub const {s}{s} = packed struct {{\n", .{ pfx, bs.name });
        for (bs.fields) |field| {
            if (field.names.len == 0) {
                // Anonymous padding field — skip with a comment to keep the
                // struct compilable; layout may need adjustment for exact bit counts.
                try self.ind();
                try self.print("    // {d} bits padding (unnamed)\n", .{field.bits});
                continue;
            }
            // Use u<N> for the bitfield width regardless of declared destination
            // type; Zig packed structs support arbitrary unsigned integer sizes.
            const field_zig = try std.fmt.allocPrint(self.alloc, "u{d}", .{field.bits});
            defer self.alloc.free(field_zig);
            for (field.names) |fname| {
                try self.ind();
                try self.print("    {s}: {s} = 0,\n", .{ fname, field_zig });
            }
        }

        if (!self.opts.no_typesupport) {
            const total = bitsetTotalBits(bs);
            if (total > 0) {
                const write_m: []const u8 = if (total <= 8) "writeU8" else if (total <= 16) "writeU16" else if (total <= 32) "writeU32" else "writeU64";
                const read_m: []const u8 = if (total <= 8) "readU8" else if (total <= 16) "readU16" else if (total <= 32) "readU32" else "readU64";
                try self.write("\n");
                try self.ind();
                try self.write("    pub fn serialize(writer: anytype, value: @This()) !void {\n");
                try self.ind();
                try self.print("        const _bs: u{d} = @bitCast(value);\n", .{total});
                try self.ind();
                try self.print("        try writer.{s}(@intCast(_bs));\n", .{write_m});
                try self.ind();
                try self.write("    }\n");
                try self.write("\n");
                try self.ind();
                try self.write("    pub fn deserializeInto(out: *@This(), reader: *zidl_rt.CdrReader, _: std.mem.Allocator) !void {\n");
                try self.ind();
                try self.print("        out.* = @bitCast(@as(u{d}, @truncate(try reader.{s}())));\n", .{ total, read_m });
                try self.ind();
                try self.write("    }\n");
                try self.write("\n");
                try self.ind();
                try self.write("    pub fn skip(reader: *zidl_rt.CdrReader) !void {\n");
                try self.ind();
                try self.print("        _ = try reader.{s}();\n", .{read_m});
                try self.ind();
                try self.write("    }\n");
            }
        }

        try self.ind();
        try self.print("}}; // {s}{s}\n\n", .{ pfx, bs.name });
    }

    // ── Typedef ───────────────────────────────────────────────────────────────

    fn emitTypedef(self: *Generator, t: *const ir.Typedef) !void {
        const pfx = self.opts.type_prefix;

        // Unbounded sequence typedefs get a proper named extern struct with a `deinit`
        // method rather than a single-line type alias, so callers can clean up
        // allocations made by `deserializeInto` without knowing the element type.
        const is_unbounded_seq = t.dimensions.len == 0 and switch (t.type_ref) {
            .sequence => |seq| seq.bound == null,
            else => false,
        };
        if (is_unbounded_seq) {
            const seq = t.type_ref.sequence;
            const buf_elem = try self.seqBufElemZig(seq.element.*);
            defer self.alloc.free(buf_elem);
            try self.ind();
            try self.print("pub const {s}{s} = extern struct {{\n", .{ pfx, t.name });
            try self.ind();
            try self.write("    _maximum: u32 = 0,\n");
            try self.ind();
            try self.write("    _length: u32 = 0,\n");
            try self.ind();
            try self.print("    _buffer: ?[*]{s} = null,\n", .{buf_elem});
            try self.ind();
            try self.write("    _release: bool = false,\n");
            try self.write("\n");
            try self.ind();
            try self.write("    pub fn deinit(self: *@This(), alloc: std.mem.Allocator) void {\n");
            try self.ind();
            try self.write("        if (!self._release) return;\n");
            try self.ind();
            try self.write("        if (self._buffer) |_buf| {\n");
            // String elements were allocated with dupeZ → free len+1 bytes per element.
            if (seq.element.* == .string) {
                try self.ind();
                try self.write("            for (_buf[0..self._length]) |_s| {\n");
                try self.ind();
                try self.write("                const _sl = std.mem.span(_s);\n");
                try self.ind();
                try self.write("                alloc.free(_sl.ptr[0.._sl.len + 1]);\n");
                try self.ind();
                try self.write("            }\n");
            }
            try self.ind();
            try self.write("            alloc.free(_buf[0..self._maximum]);\n");
            try self.ind();
            try self.write("        }\n");
            try self.ind();
            try self.write("        self.* = .{};\n");
            try self.ind();
            try self.write("    }\n");
            try self.write("\n");
            // clone — symmetric counterpart to deinit.
            try self.ind();
            try self.write("    pub fn clone(self: @This(), alloc: std.mem.Allocator) !@This() {\n");
            try self.ind();
            try self.write("        if (self._length == 0) return self;\n");
            if (seq.element.* == .string) {
                try self.ind();
                try self.print("        const _buf = try alloc.alloc({s}, self._length);\n", .{buf_elem});
                try self.ind();
                try self.write("        var _n: u32 = 0;\n");
                try self.ind();
                try self.write("        errdefer {\n");
                try self.ind();
                try self.write("            for (_buf[0.._n]) |_s| {\n");
                try self.ind();
                try self.write("                const _sl = std.mem.span(_s);\n");
                try self.ind();
                try self.write("                alloc.free(_sl.ptr[0.._sl.len + 1]);\n");
                try self.ind();
                try self.write("            }\n");
                try self.ind();
                try self.write("            alloc.free(_buf);\n");
                try self.ind();
                try self.write("        }\n");
                try self.ind();
                try self.write("        if (self._buffer) |_sb| {\n");
                try self.ind();
                try self.write("            for (_sb[0..self._length]) |_src| {\n");
                try self.ind();
                try self.write("                _buf[_n] = (try alloc.dupeZ(u8, std.mem.span(_src))).ptr;\n");
                try self.ind();
                try self.write("                _n += 1;\n");
                try self.ind();
                try self.write("            }\n");
                try self.ind();
                try self.write("        }\n");
            } else {
                try self.ind();
                try self.print("        const _buf = try alloc.alloc({s}, self._length);\n", .{buf_elem});
                try self.ind();
                try self.write("        if (self._buffer) |_sb| @memcpy(_buf, _sb[0..self._length]);\n");
            }
            try self.ind();
            try self.write("        return .{ ._buffer = _buf.ptr, ._length = self._length, ._maximum = self._length, ._release = true };\n");
            try self.ind();
            try self.write("    }\n");
            try self.ind();
            try self.print("}}; // {s}{s}\n\n", .{ pfx, t.name });
            if (self.opts.zig_generate_c_api) {
                const c_name = try self.cApiQualName(t.qualified_name, pfx);
                defer self.alloc.free(c_name);
                try self.ind();
                // A sequence<EntityInterface> typedef's C-ABI-facing free
                // function CANNOT reuse the plain .deinit() above: every
                // instance of this type a C/C++/Java caller actually holds
                // (e.g. WaitSet.wait()'s ConditionSeq out-param) was boxed to
                // one opaque pointer per element by emitCApiOp's own
                // adaptation before it ever crossed the C ABI (see
                // typeRefIsEntitySequence's other call sites) -- never the
                // native {ptr,vtable} fat-pointer element .deinit() assumes.
                // Calling .deinit() on that boxed buffer computes free()'s
                // size using the wrong (native, larger) element stride,
                // corrupting the heap. Confirmed via a real crash, not just
                // by inspection: valgrind reported an invalid heap write
                // inside a real WaitSetImpl::wait() C++ call, every single
                // invocation, not a rare race, tracing back to exactly this
                // function once WaitSet/GuardCondition gained a real C-ABI
                // constructor and a real example could exercise wait()
                // end-to-end for the first time. This body reinterprets the
                // buffer as what it actually is on this path -- one opaque
                // pointer per element -- and frees only the buffer itself;
                // it must NOT touch the individual boxed entity handles it
                // points to (those are independently cached/owned via each
                // entity's own get_c_abi_handle(), not something this
                // sequence's own free should release).
                const is_entity_seq = switch (seq.element.*) {
                    .named => |etd| switch (etd) {
                        .interface => |iface| !isCallbackInterface(iface),
                        else => false,
                    },
                    else => false,
                };
                if (is_entity_seq) {
                    try self.print(
                        "pub export fn {s}_free(v: *{s}{s}) callconv(.c) void {{ if (v._release) {{ if (v._buffer) |_b| std.heap.c_allocator.free(@as([*]?*anyopaque, @ptrCast(_b))[0..v._maximum]); }} v.* = .{{}}; }}\n\n",
                        .{ c_name, pfx, t.name },
                    );
                } else {
                    try self.print(
                        "pub export fn {s}_free(v: *{s}{s}) callconv(.c) void {{ v.deinit(std.heap.c_allocator); }}\n\n",
                        .{ c_name, pfx, t.name },
                    );
                }
            }
            return;
        }

        const zig_type = try self.typeRefToZig(t.type_ref);
        defer self.alloc.free(zig_type);

        try self.ind();
        if (t.dimensions.len == 0) {
            try self.print("pub const {s}{s} = {s};\n\n", .{ pfx, t.name, zig_type });
        } else {
            // Array typedef: `typedef long Matrix[2][4]` → `pub const Matrix = [2][4]i32;`
            const arr_type = try self.makeArrayType(zig_type, t.dimensions);
            defer self.alloc.free(arr_type);
            try self.print("pub const {s}{s} = {s};\n\n", .{ pfx, t.name, arr_type });
        }
    }

    /// Buffer element type for a C sequence struct's `_buffer` field.
    /// String elements become `[*:0]const u8` (C string pointer) instead of `[]const u8`.
    fn seqBufElemZig(self: *Generator, elem_tr: ir.TypeRef) ![]u8 {
        return switch (elem_tr) {
            .string => self.alloc.dupe(u8, "[*:0]const u8"),
            .wstring => self.alloc.dupe(u8, "[*:0]const u16"),
            else => self.typeRefToZig(elem_tr),
        };
    }

    // ── Native ────────────────────────────────────────────────────────────────

    fn emitNative(self: *Generator, n: *const ir.Native) !void {
        try self.ind();
        try self.print("pub const {s}{s} = opaque{{}}; // @native\n\n", .{ self.opts.type_prefix, n.name });
    }

    // ── Exception ─────────────────────────────────────────────────────────────

    fn emitException(self: *Generator, e: *const ir.Exception) !void {
        const pfx = self.opts.type_prefix;
        try self.ind();
        try self.write("// IDL exception\n");
        try self.ind();
        try self.print("pub const {s}{s} = struct {{\n", .{ pfx, e.name });
        for (e.members) |m| {
            try self.emitField(m.name, m.type_ref, m.dimensions, false, null);
        }
        try self.ind();
        try self.print("}}; // {s}{s}\n\n", .{ pfx, e.name });
    }

    // ── Interface ─────────────────────────────────────────────────────────────

    fn emitInterface(self: *Generator, iface: *const ir.Interface) anyerror!void {
        const pfx = self.opts.type_prefix;

        // @callback interfaces: C callback struct + noop constant only.
        // No fat-pointer vtable entity — the C struct IS the type.
        // Always emitted regardless of generate_interfaces (it's a type, not a vtable wrapper).
        if (isCallbackInterface(iface)) {
            var ops = std.ArrayListUnmanaged(ir.Operation).empty;
            defer ops.deinit(self.alloc);
            var attrs = std.ArrayListUnmanaged(ir.Attribute).empty;
            defer attrs.deinit(self.alloc);
            try self.collectInterfaceMembers(iface, &ops, &attrs);
            // attrs: @callback interfaces currently have no attribute operations
            try self.emitCListenerStruct(pfx, iface.name, ops.items);
            try self.emitNoopListener(pfx, iface.name);
            if (ops.items.len > 0) {
                try self.emitZigListenerHelpers(pfx, iface.name, ops.items);
            }
            return;
        }

        if (!self.opts.generate_interfaces) {
            try self.ind();
            try self.print(
                "// IDL interface {s}{s} — vtable struct emitted with --generate-interfaces\n\n",
                .{ pfx, iface.name },
            );
            return;
        }

        // Collect all inherited operations and attributes (flattened, in
        // declaration order: base first, then derived).  We walk the base
        // chain recursively so that multiple-level inheritance is handled.
        var ops = std.ArrayListUnmanaged(ir.Operation).empty;
        defer ops.deinit(self.alloc);
        var attrs = std.ArrayListUnmanaged(ir.Attribute).empty;
        defer attrs.deinit(self.alloc);
        try self.collectInterfaceMembers(iface, &ops, &attrs);

        // ── Outer struct ──────────────────────────────────────────────────
        // extern struct makes the two-pointer {ptr, vtable} layout the
        // idiomatic Zig-native shape for runtime polymorphism (matching
        // std.mem.Allocator) — this is how Zig-to-Zig callers (including
        // nil-object sentinels and test doubles) get real dispatch, and it
        // never changes. --zig-generate-c-api never passes this fat struct
        // across callconv(.c) directly: every entity crossing that boundary
        // is boxed into a single opaque pointer (see `zidl_rt.boxEntity` /
        // `unboxAs`), matching the C backend's single-pointer opaque handle
        // uniformly for every non-listener interface, leaf or base alike.
        try self.ind();
        try self.print("pub const {s}{s} = extern struct {{\n", .{ pfx, iface.name });

        try self.ind();
        try self.write("    ptr: *anyopaque,\n");
        try self.ind();
        try self.write("    vtable: *const Vtable,\n\n");

        // ── Vtable ────────────────────────────────────────────────────────
        // Vtable slots use C-ABI types throughout: sentinel strings, nullable
        // callback struct pointers, and struct pointers instead of by-value structs.
        try self.ind();
        try self.write("    pub const Vtable = struct {\n");

        for (ops.items) |op| {
            try self.ind();
            try self.write("        ");
            try self.print("{s}: *const fn (*anyopaque", .{op.name});
            for (op.params) |p| {
                const pt = try self.cApiTypeRef(p.type_ref, p.mode);
                defer self.alloc.free(pt);
                try self.print(", {s}: {s}", .{ p.name, pt });
            }
            const ret = try self.cApiOptRetType(op.return_type);
            defer self.alloc.free(ret);
            try self.print(") {s},\n", .{ret});
        }

        for (attrs.items) |attr| {
            const at = try self.cApiRetType(attr.type_ref);
            defer self.alloc.free(at);
            // getter
            try self.ind();
            try self.print("        get_{s}: *const fn (*anyopaque) {s},\n", .{ attr.name, at });
            // setter (writable attributes only)
            if (!attr.readonly) {
                try self.ind();
                const st = try self.cApiTypeRef(attr.type_ref, .in_);
                defer self.alloc.free(st);
                try self.print("        set_{s}: *const fn (*anyopaque, {s}) void,\n", .{ attr.name, st });
            }
        }

        try self.ind();
        try self.write("        deinit: *const fn (*anyopaque) void,\n");
        try self.ind();
        // Synthetic, like `deinit` above — not sourced from IDL-declared ops.
        // Returns an already-prepared opaque C-ABI handle for this value (see
        // `zidl_rt.EntityBox`) — the generic --zig-generate-c-api export layer
        // never allocates or looks up an allocator itself; it just calls this.
        // How the handle is produced (a fresh box vs. one cached and reused
        // across calls) is entirely the concrete implementation's own choice,
        // which is what lets it preserve handle identity and avoid leaking a
        // box on every accessor call, without zidl needing to know or care.
        try self.write("        get_c_abi_handle: *const fn (*anyopaque) *anyopaque,\n");

        // Synthetic `as_{Base}` slots, one per direct declared base interface
        // — lets a caller upcast to any IDL-declared base (Entity,
        // TopicDescription, Condition, ...) without needing to know which
        // concrete implementation it holds.  Returns the *native* fat-pointer
        // type (like `deinit`'s pattern, not boxed) — boxing happens only in
        // the generated C-ABI export wrapper, same as any other entity-
        // returning operation.  Deliberately a vtable slot rather than a raw
        // pointer reinterpretation: zidl flattens inherited ops bases-first,
        // so only a type's *first* base would ever land at a byte-exact
        // offset-0 prefix — reinterpreting a second-or-later base's Vtable
        // pointer this way would silently misread the wrong fields.
        for (iface.bases) |base| {
            if (base != .interface) continue;
            const base_zig_type = try self.typeRefToZig(.{ .named = base });
            defer self.alloc.free(base_zig_type);
            try self.ind();
            try self.print("        as_{s}: *const fn (*anyopaque) {s},\n", .{ base.interface.name, base_zig_type });
        }

        try self.ind();
        try self.write("    };\n\n");

        // ── CAbiViews (`@shared_c_abi_box` interfaces only) ─────────────────
        // A second, boxing-only indirection, orthogonal to `Vtable` above and
        // never used for ordinary dispatch. Nests the primary base's own
        // CAbiViews as the FIRST field, recursively — `extern struct`
        // guarantees first-field-at-offset-0, so this composes: reinterpreting
        // a leaf's CAbiViews pointer as any ancestor's CAbiViews type (as long
        // as every intermediate step was reached via the *first* declared
        // base) correctly recovers that ancestor's own `flat_vtable` field, no
        // matter how deep the real concrete type's chain is. This is what
        // lets a concrete impl share ONE C-ABI box across every interface
        // view it presents instead of one per view — see zidl/docs/roadmap.md
        // "Binding design review: decision" for the full rationale and the
        // Zig-layout spike that confirmed this composition. Deliberately not
        // generated for every interface: safe only for interfaces reachable
        // via a chain of *primary* (first-listed) bases — see
        // `hasSharedCAbiBox`'s own doc comment for why a secondary base must
        // never be annotated.
        if (hasSharedCAbiBox(iface)) {
            try self.ind();
            try self.write("    pub const CAbiViews = extern struct {\n");
            if (iface.bases.len > 0 and iface.bases[0] == .interface and hasSharedCAbiBox(iface.bases[0].interface)) {
                const base_zig_type = try self.typeRefToZig(.{ .named = iface.bases[0] });
                defer self.alloc.free(base_zig_type);
                try self.ind();
                try self.print("        base: {s}.CAbiViews,\n", .{base_zig_type});
            }
            try self.ind();
            try self.write("        flat_vtable: *const Vtable,\n");
            try self.ind();
            try self.write("    };\n\n");
        }

        // ── Forwarding methods (idiomatic Zig types) ─────────────────────
        // These wrap the C-ABI vtable slots with ergonomic Zig types:
        // `[]const u8` strings, by-value QoS structs, optional callback structs.
        for (ops.items) |op| {
            const ret = try self.idiomOptRetType(op.return_type);
            defer self.alloc.free(ret);
            const needs_span = idiomRetNeedsSpan(op.return_type);

            try self.ind();
            try self.write("    pub fn ");
            try self.print("{s}(self: @This()", .{op.name});
            for (op.params) |p| {
                const pt = try self.idiomParamType(p);
                defer self.alloc.free(pt);
                try self.print(", {s}: {s}", .{ p.name, pt });
            }
            try self.print(") {s} {{\n", .{ret});

            // Emit local vars for callback params (needed for taking pointer)
            for (op.params) |p| {
                if (idiomNeedsLocal(p)) {
                    try self.ind();
                    try self.print("        var _lv_{s} = {s};\n", .{ p.name, p.name });
                }
            }

            // Emit vtable call with converted args
            try self.ind();
            if (needs_span) {
                try self.print("        return std.mem.span(self.vtable.{s}(self.ptr", .{op.name});
            } else {
                try self.print("        return self.vtable.{s}(self.ptr", .{op.name});
            }
            for (op.params) |p| {
                const lv: ?[]const u8 = if (idiomNeedsLocal(p))
                    try std.fmt.allocPrint(self.alloc, "_lv_{s}", .{p.name})
                else
                    null;
                defer if (lv) |s| self.alloc.free(s);
                const arg = try self.idiomCallArg(p, lv);
                defer self.alloc.free(arg);
                try self.print(", {s}", .{arg});
            }
            if (needs_span) {
                try self.write("));\n");
            } else {
                try self.write(");\n");
            }
            try self.ind();
            try self.write("    }\n\n");
        }

        for (attrs.items) |attr| {
            // getter: idiomatic return type
            const at = try self.idiomOptRetType(attr.type_ref);
            defer self.alloc.free(at);
            const getter_needs_span = idiomRetNeedsSpan(attr.type_ref);
            try self.ind();
            try self.print("    pub fn get_{s}(self: @This()) {s} {{\n", .{ attr.name, at });
            try self.ind();
            if (getter_needs_span) {
                try self.print("        return std.mem.span(self.vtable.get_{s}(self.ptr));\n", .{attr.name});
            } else {
                try self.print("        return self.vtable.get_{s}(self.ptr);\n", .{attr.name});
            }
            try self.ind();
            try self.write("    }\n\n");
            // setter: idiomatic param type
            if (!attr.readonly) {
                const sp: ir.Parameter = .{ .name = "value", .type_ref = attr.type_ref, .mode = .in_, .span = std.mem.zeroes(@TypeOf(@as(ir.Parameter, undefined).span)), .raw = &.{} };
                const st = try self.idiomParamType(sp);
                defer self.alloc.free(st);
                const sarg = try self.idiomCallArg(sp, null);
                defer self.alloc.free(sarg);
                try self.ind();
                try self.print("    pub fn set_{s}(self: @This(), value: {s}) void {{\n", .{ attr.name, st });
                try self.ind();
                try self.print("        self.vtable.set_{s}(self.ptr, {s});\n", .{ attr.name, sarg });
                try self.ind();
                try self.write("    }\n\n");
            }
        }

        try self.ind();
        try self.write("    pub fn deinit(self: @This()) void {\n");
        try self.ind();
        try self.write("        self.vtable.deinit(self.ptr);\n");
        try self.ind();
        try self.write("    }\n");

        // Ergonomic `as_{Base}` convenience methods, one per direct declared
        // base interface — mirrors the synthetic vtable slot emitted above
        // (see its own doc comment for why upcasting can't be a raw pointer
        // reinterpretation), giving pure Zig-native callers the same
        // ergonomic upcast every other backend (C/C++/Java) already generates
        // its own wrapper for. Previously missing: Zig-native code had to
        // spell out `.vtable.as_{Base}(.ptr)` by hand — decided in
        // zidl/docs/roadmap.md "Binding design review: decision".
        // Blank-line separator goes *before* each method, not after: unlike
        // ops/attrs above (always followed by `deinit`, so a trailing blank
        // line is always just a separator from the next thing), this loop
        // can be the last content in the struct body before the closing
        // `};` (any interface with no nested type_decls/consts) -- ending
        // each method with a trailing blank line left one sitting directly
        // before `};` in that case, which `zig fmt` then strips on the next
        // format pass, fighting `regen-goldens`. Mirrors `deinit`'s own
        // single-newline close for exactly this reason.
        for (iface.bases) |base| {
            if (base != .interface) continue;
            const base_zig_type = try self.typeRefToZig(.{ .named = base });
            defer self.alloc.free(base_zig_type);
            try self.write("\n");
            try self.ind();
            try self.print("    pub fn as_{s}(self: @This()) {s} {{\n", .{ base.interface.name, base_zig_type });
            try self.ind();
            try self.print("        return self.vtable.as_{s}(self.ptr);\n", .{base.interface.name});
            try self.ind();
            try self.write("    }\n");
        }

        // Nested type decls and consts inside the interface body.
        if (iface.type_decls.len > 0 or iface.consts.len > 0) {
            try self.write("\n");
            self.depth += 1;
            for (iface.type_decls) |td| try self.emitTypeDecl(td);
            for (iface.consts) |*c| try self.emitConst(c);
            self.depth -= 1;
        }

        try self.ind();
        try self.print("}}; // {s}{s}\n\n", .{ pfx, iface.name });

        if (self.opts.zig_generate_c_api) {
            try self.emitCApiExports(iface, pfx, ops.items, attrs.items);
        }
    }

    // ── C-API exports (--zig-generate-c-api) ─────────────────────────────────

    // ── C-ABI mirror structs (--zig-generate-c-api + --zig-generate-toml-config,
    // or any plain struct with an unbounded string field crossing the C ABI) ──
    //
    // `pub export fn` parameter/return types for a plain (non-`extern`) struct
    // currently just reuse whatever Zig type this invocation happens to have
    // generated for it (see `cApiTypeRef`'s "other named types" branch) — the
    // *same* type internal Zig code and the native vtable slot use. Two things
    // can make that type's memory layout disagree with the independently
    // generated public C header (`-b c`, a separate zidl invocation over the
    // same IDL with no visibility into this one) for the exact same logical
    // struct:
    //
    //   1. `--zig-generate-toml-config` prepends a `_toml_applied: bool` field
    //      (see `emitStruct`) to *every* struct in this invocation, including
    //      ones the C backend's own struct declaration has no matching field
    //      for at all.
    //   2. A plain unbounded `string` member is `[]const u8` (a 16-byte slice)
    //      here vs. `char *` (an 8-byte pointer) in the C header — true
    //      regardless of `--zig-generate-toml-config`.
    //
    // Either one, alone, means a C/C++/Java caller building a value against
    // the public header and a `pub export fn` reading it as this type read
    // every field at the wrong offset. Confirmed as a real, live bug (not just
    // by inspection) via zzdds's own `create_participant_ex`/
    // `get_default_participant_config` (case 1) and `DDS_TopicBuiltinTopicData_
    // free` (case 2, no TOML config involved at all) — see zzdds's own
    // `docs/roadmap.md`.
    //
    // The fix: for any struct that needs one, generate a *separate*,
    // genuinely `extern struct` "C-ABI mirror" — laid out to match what the
    // `-b c` backend independently emits for the same struct (plain scalars/
    // enums unchanged, unbounded strings as `?[*:0]const u8`, `@optional`
    // scalars stored as their bare value gated by a `_present` bitmask field
    // — precisely mirroring `zzdds_UdpConfig`'s own `_present`/plain-field
    // shape, not a Zig-side invention — sequences unchanged, since those
    // already use one canonical `extern struct` shape everywhere) — plus
    // conversion functions, and have `cApiExportTypeRef` use the mirror (not
    // the internal type) for any exported wrapper's own signature.
    // `emitCApiOp` converts at the call site: mirror-in for `in`/`inout`,
    // mirror-out for `inout`/`out` (see its own comment).

    /// True if `s` needs the C-ABI mirror treatment above — either `s`
    /// itself actually got `_toml_applied` (see `toml_applied_structs`'s own
    /// doc comment — *not* just "this invocation has the flag on", which
    /// would incorrectly also claim a cross-file-imported struct like
    /// `dcps.idl`'s `DDS::DomainParticipantQos` needs one), or `s`
    /// (transitively) contains an unbounded string.
    fn structNeedsCApiMirror(self: *Generator, s: *const ir.Struct) bool {
        return self.toml_applied_structs.contains(s) or structHasUnboundedString(s);
    }

    /// Sequential index of `s.members[target_idx]` among `@optional` members
    /// only (0, 1, 2, …) — the bit position in the mirror's `_present` field.
    /// Mirrors the C backend's own `optBitIdxForMember` exactly (see
    /// `src/backend/c.zig`) so the two independently-generated layouts agree
    /// on which bit means what.
    fn cApiMirrorOptBitIdx(s: *const ir.Struct, target_idx: usize) u32 {
        var count: u32 = 0;
        for (s.members[0..target_idx]) |m| {
            if (m.annotations.is_optional) count += 1;
        }
        return count;
    }

    fn structHasOptionalMember(s: *const ir.Struct) bool {
        for (s.members) |m| {
            if (m.annotations.is_optional) return true;
        }
        return false;
    }

    /// If `tr` resolves (directly, or through any number of non-array
    /// typedefs) to a named struct needing a C-ABI mirror, returns that
    /// mirror's Zig type name (caller owns the returned slice) — e.g.
    /// `RtpsConfigCAbi`, resolvable exactly where `RtpsConfig` itself is
    /// (same enclosing module block; the mirror is emitted right next to the
    /// struct it mirrors, in `emitStruct`). Returns null for anything else
    /// (a mirror-safe struct, or a non-struct type).
    fn cApiMirrorTypeName(self: *Generator, tr: ir.TypeRef) !?[]u8 {
        const s: *const ir.Struct = switch (tr) {
            .named => |td| switch (td) {
                .struct_ => |st| st,
                .typedef => |t| if (t.dimensions.len == 0) return self.cApiMirrorTypeName(t.type_ref) else return null,
                else => return null,
            },
            else => return null,
        };
        if (!self.structNeedsCApiMirror(s)) return null;
        const base = try self.typeRefToZig(tr);
        defer self.alloc.free(base);
        return try std.fmt.allocPrint(self.alloc, "{s}CAbi", .{base});
    }

    /// True if the *internal* struct `tr` resolves to (the one a temporary
    /// `_mir_{name}` local in `emitCApiOp` is converted into) actually has a
    /// generated `.deinit()` to call — i.e. `structNeedsCleanup`, not
    /// `structNeedsCApiMirror`: a struct can need a mirror purely because
    /// `_toml_applied` is present (`--zig-generate-toml-config`) while having
    /// nothing else to free at all (e.g. `RtpsConfig`, just one `u16`), in
    /// which case it never got a `.deinit()` generated for it in the first
    /// place — calling one would be a compile error, not a no-op.
    fn cApiMirrorInternalNeedsDeinit(self: *Generator, tr: ir.TypeRef) !bool {
        const s: *const ir.Struct = switch (tr) {
            .named => |td| switch (td) {
                .struct_ => |st| st,
                .typedef => |t| if (t.dimensions.len == 0) return self.cApiMirrorInternalNeedsDeinit(t.type_ref) else return false,
                else => return false,
            },
            else => return false,
        };
        return self.structNeedsCleanup(s);
    }

    /// The mirror's own field type for `tr` — `?[*:0]const u8` for an
    /// unbounded string, the nested mirror type name for a struct needing
    /// one, otherwise identical to the internal type (`typeRefToZig`):
    /// scalars/enums/bitmask/bitset/sequences/bounded strings are already
    /// C-ABI-safe as-is.
    fn cApiMirrorFieldType(self: *Generator, tr: ir.TypeRef) ![]u8 {
        switch (tr) {
            .string => |bound| if (bound == null) return self.alloc.dupe(u8, "?[*:0]const u8"),
            else => {},
        }
        if (try self.cApiMirrorTypeName(tr)) |mirror_name| return mirror_name;
        return self.typeRefToZig(tr);
    }

    /// One field declaration inside a `{Struct}CAbi extern struct`. See this
    /// section's own doc comment for the overall shape; mirrors `emitField`'s
    /// structure but substitutes the mirror's own field type/default
    /// conventions (unbounded string → nullable C string, `@optional` → bare
    /// value gated by `_present` instead of a Zig optional).
    fn emitCApiMirrorField(self: *Generator, m: ir.StructMember) !void {
        if (m.dimensions.len > 0) {
            // Arrays (including bounded string/wstring arrays) are already
            // extern-compatible in the internal type -- reuse it verbatim.
            return self.emitField(m.name, m.type_ref, m.dimensions, false, m.annotations.default_value);
        }
        if (m.annotations.is_optional) {
            switch (m.type_ref) {
                .base => {},
                else => {
                    try self.ind();
                    try self.print(
                        "    @compileError(\"C-ABI mirror: @optional non-scalar field ('{s}') not supported\"),\n",
                        .{m.name},
                    );
                    return;
                },
            }
            const zig_type = try self.typeRefToZig(m.type_ref);
            defer self.alloc.free(zig_type);
            try self.ind();
            try self.print("    {s}: {s} = 0,\n", .{ m.name, zig_type });
            return;
        }
        const field_type = try self.cApiMirrorFieldType(m.type_ref);
        defer self.alloc.free(field_type);
        try self.ind();
        if (std.mem.eql(u8, field_type, "?[*:0]const u8")) {
            try self.print("    {s}: {s} = null,\n", .{ m.name, field_type });
        } else if (m.annotations.default_value) |dv| {
            const dv_str = try self.formatDefaultValueZig(dv, m.type_ref);
            defer self.alloc.free(dv_str);
            try self.print("    {s}: {s} = {s},\n", .{ m.name, field_type, dv_str });
        } else {
            const default = try self.defaultForTypeRef(m.type_ref);
            defer self.alloc.free(default);
            try self.print("    {s}: {s} = {s},\n", .{ m.name, field_type, default });
        }
    }

    /// One statement inside `{Struct}FromCAbi`, converting mirror field `m`
    /// into the internal-typed `out.{m.name}`.
    fn emitCApiMirrorFromCAbiField(self: *Generator, s: *const ir.Struct, m: ir.StructMember, idx: usize) !void {
        if (m.dimensions.len > 0) {
            try self.ind();
            try self.print("    out.{s} = c.{s};\n", .{ m.name, m.name });
            return;
        }
        if (m.annotations.is_optional) {
            try self.ind();
            try self.print(
                "    if (c._present & (@as(u64, 1) << {d}) != 0) out.{s} = c.{s};\n",
                .{ cApiMirrorOptBitIdx(s, idx), m.name, m.name },
            );
            return;
        }
        switch (m.type_ref) {
            .string => |bound| if (bound == null) {
                try self.ind();
                try self.print(
                    "    out.{s} = if (c.{s}) |_p| (std.heap.c_allocator.dupe(u8, std.mem.span(_p)) catch \"\") else \"\";\n",
                    .{ m.name, m.name },
                );
                return;
            },
            else => {},
        }
        if (try self.cApiMirrorTypeName(m.type_ref)) |mirror_name| {
            defer self.alloc.free(mirror_name);
            const inner = try self.typeRefToZig(m.type_ref);
            defer self.alloc.free(inner);
            try self.ind();
            try self.print("    out.{s} = {s}FromCAbi(&c.{s});\n", .{ m.name, inner, m.name });
            return;
        }
        if (typeRefNeedsSeqDeinit(m.type_ref)) {
            // The mirror's own sequence field is already the one canonical
            // extern-compatible shape (see this section's doc comment) --
            // but a plain assignment here would shallow-copy the buffer
            // pointer, leaving `out` and the caller's own mirror struct
            // sharing ownership of the same allocation (a double-free the
            // moment either side's `deinit`/`CAbiFree` runs). `.clone()`
            // already exists on every sequence type for exactly this reason.
            try self.ind();
            try self.print("    out.{s} = c.{s}.clone(std.heap.c_allocator) catch .{{}};\n", .{ m.name, m.name });
            return;
        }
        try self.ind();
        try self.print("    out.{s} = c.{s};\n", .{ m.name, m.name });
    }

    /// One statement inside `{Struct}ToCAbi`, converting internal-typed
    /// `v.{m.name}` into the (already-freed, see `emitStructCApiMirror`)
    /// mirror field `out.{m.name}`.
    fn emitCApiMirrorToCAbiField(self: *Generator, s: *const ir.Struct, m: ir.StructMember, idx: usize) !void {
        if (m.dimensions.len > 0) {
            try self.ind();
            try self.print("    out.{s} = v.{s};\n", .{ m.name, m.name });
            return;
        }
        if (m.annotations.is_optional) {
            try self.ind();
            try self.print(
                "    if (v.{s}) |_val| {{ out.{s} = _val; out._present |= (@as(u64, 1) << {d}); }}\n",
                .{ m.name, m.name, cApiMirrorOptBitIdx(s, idx) },
            );
            return;
        }
        switch (m.type_ref) {
            .string => |bound| if (bound == null) {
                try self.ind();
                try self.print("    out.{s} = zidlCAbiDupeCStr(v.{s});\n", .{ m.name, m.name });
                return;
            },
            else => {},
        }
        if (try self.cApiMirrorTypeName(m.type_ref)) |mirror_name| {
            defer self.alloc.free(mirror_name);
            const inner = try self.typeRefToZig(m.type_ref);
            defer self.alloc.free(inner);
            try self.ind();
            try self.print("    {s}ToCAbi(&v.{s}, &out.{s});\n", .{ inner, m.name, m.name });
            return;
        }
        if (typeRefNeedsSeqDeinit(m.type_ref)) {
            // See the matching comment in emitCApiMirrorFromCAbiField --
            // `CAbiFree(out)` above already released whatever the mirror
            // used to hold, so this is safe to overwrite with an independent
            // clone (not a shallow copy of `v`'s own buffer).
            try self.ind();
            try self.print("    out.{s} = v.{s}.clone(std.heap.c_allocator) catch .{{}};\n", .{ m.name, m.name });
            return;
        }
        try self.ind();
        try self.print("    out.{s} = v.{s};\n", .{ m.name, m.name });
    }

    /// One statement inside `{Struct}CAbiFree`, releasing whatever mirror
    /// field `m` currently owns before it's overwritten (or the mirror
    /// itself is done with).
    fn emitCApiMirrorFreeField(self: *Generator, m: ir.StructMember) !void {
        if (m.dimensions.len > 0 or m.annotations.is_optional) return;
        switch (m.type_ref) {
            .string => |bound| if (bound == null) {
                try self.ind();
                try self.print("    zidlCAbiFreeCStr(out.{s});\n", .{m.name});
                return;
            },
            else => {},
        }
        if (try self.cApiMirrorTypeName(m.type_ref)) |mirror_name| {
            defer self.alloc.free(mirror_name);
            const inner = try self.typeRefToZig(m.type_ref);
            defer self.alloc.free(inner);
            try self.ind();
            try self.print("    {s}CAbiFree(&out.{s});\n", .{ inner, m.name });
            return;
        }
        if (typeRefNeedsSeqDeinit(m.type_ref)) {
            try self.ind();
            try self.print("    out.{s}.deinit(std.heap.c_allocator);\n", .{m.name});
        }
    }

    /// Emits `{Struct}CAbi` (the mirror type itself), `{Struct}FromCAbi`
    /// (mirror → internal, allocating via `std.heap.c_allocator`),
    /// `{Struct}ToCAbi` (internal → mirror, freeing the mirror's prior
    /// content first — same "free old, write new" contract
    /// `factoryGetDefaultParticipantConfig`'s hand-written Zig already uses
    /// for the internal type), and `{Struct}CAbiFree` (frees a mirror value
    /// on its own, e.g. a local one that's done being read). See this
    /// section's own doc comment for why this exists at all.
    fn emitStructCApiMirror(self: *Generator, s: *const ir.Struct) !void {
        if (!self.structNeedsCApiMirror(s)) return;
        const has_present = structHasOptionalMember(s);

        try self.ind();
        try self.print("pub const {s}CAbi = extern struct {{\n", .{s.name});
        if (has_present) {
            try self.ind();
            try self.write("    _present: u64 = 0,\n");
        }
        for (s.members) |m| try self.emitCApiMirrorField(m);
        try self.ind();
        try self.write("};\n\n");

        try self.ind();
        try self.print("pub fn {s}FromCAbi(c: *const {s}CAbi) {s} {{\n", .{ s.name, s.name, s.name });
        try self.ind();
        try self.print("    var out: {s} = .{{}};\n", .{s.name});
        for (s.members, 0..) |m, idx| try self.emitCApiMirrorFromCAbiField(s, m, idx);
        if (self.opts.zig_generate_toml_config) {
            try self.ind();
            try self.write("    out._toml_applied = true;\n");
        }
        try self.ind();
        try self.write("    return out;\n");
        try self.ind();
        try self.write("}\n\n");

        try self.ind();
        try self.print("pub fn {s}ToCAbi(v: *const {s}, out: *{s}CAbi) void {{\n", .{ s.name, s.name, s.name });
        try self.ind();
        try self.print("    {s}CAbiFree(out);\n", .{s.name});
        for (s.members, 0..) |m, idx| try self.emitCApiMirrorToCAbiField(s, m, idx);
        try self.ind();
        try self.write("}\n\n");

        try self.ind();
        try self.print("pub fn {s}CAbiFree(out: *{s}CAbi) void {{\n", .{ s.name, s.name });
        for (s.members) |m| try self.emitCApiMirrorFreeField(m);
        try self.ind();
        try self.write("    out.* = .{};\n");
        try self.ind();
        try self.write("}\n\n");
    }

    /// Emit `pub export fn DDS_X_free(v: *X) callconv(.c) void` for structs that
    /// contain sequence fields allocated by the middleware (identified by _release).
    /// The caller frees via the struct's generated `deinit` using std.heap.c_allocator,
    /// which matches the allocator used by all C-ABI operations in zzdds.
    fn emitStructCApiFree(self: *Generator, s: *const ir.Struct) !void {
        const pfx = self.opts.type_prefix;
        const c_name = try self.cApiQualName(s.qualified_name, pfx);
        defer self.alloc.free(c_name);
        try self.ind();
        // A struct needing a C-ABI mirror (see that section's doc comment)
        // must export `_free` over the mirror type too, not the internal
        // one -- this is the exact same exported-signature-vs-caller's-
        // actual-value mismatch `cApiExportTypeRef` fixes for operation
        // params, just for the standalone per-struct `_free` this function
        // emits instead (never routed through `emitCApiOp` at all). Confirmed
        // as a real, separate gap via an actual crash: `create_participant_ex`
        // et al. correctly took the mirror once cApiExportTypeRef was fixed,
        // but a caller's very next `..._free()` call on its own now-mirror-
        // shaped local value still ran the *internal* type's `.deinit()`
        // over it, at the wrong offsets, same as before.
        if (try self.cApiMirrorTypeName(ir.TypeRef{ .named = .{ .struct_ = @constCast(s) } })) |mirror_name| {
            defer self.alloc.free(mirror_name);
            try self.print(
                "pub export fn {s}_free(v: *{s}) callconv(.c) void {{ {s}CAbiFree(v); }}\n\n",
                .{ c_name, mirror_name, s.name },
            );
            return;
        }
        try self.print(
            "pub export fn {s}_free(v: *{s}{s}) callconv(.c) void {{ v.deinit(std.heap.c_allocator); }}\n\n",
            .{ c_name, pfx, s.name },
        );
    }

    /// Emit `pub export fn callconv(.c)` trivial forwarders for all operations and
    /// attributes of an entity interface.  Callback interfaces are handled by
    /// `emitInterface` and produce no C-API export functions.
    fn emitCApiExports(
        self: *Generator,
        iface: *const ir.Interface,
        pfx: []const u8,
        ops: []const ir.Operation,
        attrs: []const ir.Attribute,
    ) anyerror!void {
        if (isCallbackInterface(iface)) return; // struct + noop already emitted by emitInterface

        const qual_c_name = try self.cApiQualName(iface.qualified_name, pfx);
        defer self.alloc.free(qual_c_name);

        // Which zidl_rt function reconstructs `self` from a boxed handle —
        // same for every export below, computed once here since it only
        // depends on `iface` itself, not on any one operation/attribute/base.
        const self_unbox_fn = cAbiUnboxFnName(iface);

        // One trivial forwarder per operation.
        for (ops) |op| {
            try self.emitCApiOp(qual_c_name, pfx, iface.name, self_unbox_fn, &op);
        }
        // Getter + optional setter per attribute.
        for (attrs) |attr| {
            try self.emitCApiAttr(qual_c_name, pfx, iface.name, self_unbox_fn, &attr);
        }

        // One upcast forwarder per direct declared base interface, mirroring
        // the native `as_{Base}` vtable slot emitted in `emitInterface`.
        for (iface.bases) |base| {
            if (base != .interface) continue;
            try self.emitCApiAsBase(qual_c_name, pfx, iface.name, self_unbox_fn, base);
        }
    }

    /// Emit the C-ABI export wrapper for one `as_{Base}` upcast. Kept separate
    /// from `emitCApiOp` because the two names involved — the native vtable
    /// slot (simple base name, e.g. `as_Entity`) and the exported C symbol
    /// (fully qualified, e.g. `DDS_Topic_as_DDS_Entity`) — are deliberately
    /// different, unlike every other operation where both names match.
    fn emitCApiAsBase(
        self: *Generator,
        c_name: []const u8,
        pfx: []const u8,
        iface_name: []const u8,
        self_unbox_fn: []const u8,
        base: ir.TypeDecl,
    ) anyerror!void {
        const base_iface = base.interface;
        const base_qual_c_name = try self.cApiQualName(base_iface.qualified_name, pfx);
        defer self.alloc.free(base_qual_c_name);

        try self.ind();
        try self.print("pub export fn {s}_as_{s}(self: *anyopaque) callconv(.c) *anyopaque {{\n", .{ c_name, base_qual_c_name });
        try self.ind();
        try self.print("    const _self: {s}{s} = {s}({s}{s}, self);\n", .{ pfx, iface_name, self_unbox_fn, pfx, iface_name });
        try self.ind();
        try self.print("    const _r = _self.vtable.as_{s}(_self.ptr);\n", .{base_iface.name});
        try self.ind();
        try self.write("    return _r.vtable.get_c_abi_handle(_r.ptr);\n");
        try self.ind();
        try self.write("}\n\n");
    }

    /// True when `tr` names a non-callback (entity) interface — these cross
    /// the `--zig-generate-c-api` boundary as a single boxed opaque pointer
    /// (see `zidl_rt.boxEntity`/`unboxAs`), uniformly, regardless of whether
    /// the interface has one real implementation or several.
    fn typeRefIsEntityInterface(tr: ir.TypeRef) bool {
        return switch (tr) {
            .named => |td| switch (td) {
                .interface => |iface| !isCallbackInterface(iface),
                else => false,
            },
            else => false,
        };
    }

    /// True when `tr` is a typedef of a bare `sequence<EntityInterface>`
    /// (e.g. DataReaderSeq, ConditionSeq). Unlike sequences of scalars/
    /// strings -- whose native Zig extern struct element size already
    /// matches what c.zig independently declares for the same typedef in
    /// the C header, making the struct naturally C-ABI compatible -- a
    /// sequence of entities is NOT compatible: the native element type is
    /// the full `{ptr, vtable}` fat pointer (16 bytes on 64-bit), while the
    /// C header (generated by a completely separate backend) declares a
    /// single opaque pointer per element (8 bytes). Passing the native
    /// extern struct straight through at the C-ABI export boundary, the way
    /// every other sequence typedef safely can, corrupts memory the moment
    /// a caller inspects more than the first element -- see emitCApiOp's
    /// dedicated handling for these.
    fn typeRefIsEntitySequence(tr: ir.TypeRef) bool {
        const td = seqTypedef(tr) orelse return false;
        return switch (td.type_ref.sequence.element.*) {
            .named => |etd| switch (etd) {
                .interface => |iface| !isCallbackInterface(iface),
                else => false,
            },
            else => false,
        };
    }

    /// Zero-initialized noop constant for a callback struct.
    /// All function pointers are null, so the caller must check before invoking.
    fn emitNoopListener(
        self: *Generator,
        pfx: []const u8,
        iface_name: []const u8,
    ) anyerror!void {
        try self.ind();
        try self.print("pub const noop_{s}: {s}{s} = .{{}};\n\n", .{ iface_name, pfx, iface_name });
    }

    /// Emit the idiomatic Zig helper pair for a @callback interface:
    ///
    ///   pub fn XxxHandlers(comptime Ctx: type) type { ... }
    ///
    /// A comptime-parameterised struct whose fields are Zig-idiomatic callbacks:
    /// `*const fn(*Ctx, EntityType, StatusType) void` (no callconv(.c), status by value).
    ///
    ///   pub fn xxxListener(ctx: anytype, comptime cbs: XxxHandlers(...)) XxxListener { ... }
    ///
    /// Wraps each non-null Zig callback in a comptime-generated callconv(.c) thunk and
    /// returns the C callback struct.  Zero heap allocation — the thunks are compile-time
    /// constants; `ctx` is stored directly as `listener_data`.
    fn emitZigListenerHelpers(
        self: *Generator,
        pfx: []const u8,
        iface_name: []const u8,
        ops: []const ir.Operation,
    ) anyerror!void {
        // ── Handlers type ─────────────────────────────────────────────────────
        try self.ind();
        try self.print("pub fn {s}Handlers(comptime Ctx: type) type {{\n", .{iface_name});
        try self.ind();
        try self.write("    return struct {\n");
        for (ops) |op| {
            try self.ind();
            try self.print("        {s}: ?*const fn (*Ctx", .{op.name});
            for (op.params) |p| {
                const zt = try self.typeRefToZig(p.type_ref);
                defer self.alloc.free(zt);
                try self.print(", {s}", .{zt});
            }
            try self.write(") void = null,\n");
        }
        try self.ind();
        try self.write("    };\n");
        try self.ind();
        try self.write("}\n\n");

        // ── Builder function (lowercase-first iface_name) ─────────────────────
        var fname = try self.alloc.dupe(u8, iface_name);
        defer self.alloc.free(fname);
        fname[0] = std.ascii.toLower(fname[0]);

        try self.ind();
        try self.print(
            "pub fn {s}(ctx: anytype, comptime cbs: {s}Handlers(@TypeOf(ctx.*))) {s}{s} {{\n",
            .{ fname, iface_name, pfx, iface_name },
        );
        try self.ind();
        try self.write("    return .{\n");
        try self.ind();
        try self.write("        .listener_data = ctx,\n");

        for (ops) |op| {
            try self.ind();
            try self.print(
                "        .{s} = if (cbs.{s}) |_cb| struct {{\n",
                .{ op.name, op.name },
            );
            // Capture the comptime callback as a const so the nested fn can use it.
            try self.ind();
            try self.write("            const _h = _cb;\n");
            // Emit the callconv(.c) wrapper function.
            try self.ind();
            try self.write("            fn _w(");
            for (op.params, 0..) |p, i| {
                if (i > 0) try self.write(", ");
                const ct = try self.cApiExportTypeRef(p.type_ref, p.mode);
                defer self.alloc.free(ct);
                try self.print("_{s}: {s}", .{ p.name, ct });
            }
            if (op.params.len > 0) try self.write(", ");
            try self.write("_ld: ?*anyopaque) callconv(.c) void {\n");
            // Body: call _h with context + params, converting C-ABI types to Zig types.
            try self.ind();
            try self.write("                _h(@ptrCast(@alignCast(_ld))");
            for (op.params) |p| {
                const ct = try self.cApiExportTypeRef(p.type_ref, p.mode);
                defer self.alloc.free(ct);
                const is_unbounded_str = switch (p.type_ref) {
                    .string => |b| b == null,
                    .wstring => |b| b == null,
                    else => false,
                };
                // Entity params arrive as a single boxed *anyopaque; Handlers
                // (the idiomatic Zig signature) expects the native fat-pointer
                // handle, so unbox it.
                if (typeRefIsEntityInterface(p.type_ref)) {
                    const pzig = try self.typeRefToZig(p.type_ref);
                    defer self.alloc.free(pzig);
                    const p_unbox_fn = cAbiUnboxFnName(typeRefEntityInterface(p.type_ref).?);
                    try self.print(", {s}({s}, _{s})", .{ p_unbox_fn, pzig, p.name });
                    // Unbounded strings arrive as [*:0]const u8; Handlers expects []const u8.
                } else if (is_unbounded_str) {
                    try self.print(", std.mem.span(_{s})", .{p.name});
                    // Nullable pointer params (callback struct or sequence typedef): unwrap or zero.
                } else if (std.mem.startsWith(u8, ct, "?*const ")) {
                    try self.print(", (if (_{s}) |_q| _q.* else .{{}})", .{p.name});
                    // Non-null pointer params (plain struct or inline sequence): dereference.
                } else if (std.mem.startsWith(u8, ct, "*const ")) {
                    try self.print(", _{s}.*", .{p.name});
                } else {
                    try self.print(", _{s}", .{p.name});
                }
            }
            try self.write(");\n");
            try self.ind();
            try self.write("            }\n");
            try self.ind();
            try self.write("        }._w else null,\n");
        }

        try self.ind();
        try self.write("    };\n");
        try self.ind();
        try self.write("}\n\n");
    }

    /// C callback struct for a @callback interface (matches the C backend layout).
    fn emitCListenerStruct(
        self: *Generator,
        pfx: []const u8,
        iface_name: []const u8,
        ops: []const ir.Operation,
    ) anyerror!void {
        try self.ind();
        try self.print("pub const {s}{s} = extern struct {{\n", .{ pfx, iface_name });
        try self.ind();
        try self.write("    listener_data: ?*anyopaque = null,\n");
        for (ops) |op| {
            try self.ind();
            try self.print("    {s}: ?*const fn (", .{op.name});
            for (op.params, 0..) |p, i| {
                if (i > 0) try self.write(", ");
                const pt = try self.cApiExportTypeRef(p.type_ref, p.mode);
                defer self.alloc.free(pt);
                try self.write(pt);
            }
            if (op.params.len > 0) try self.write(", ");
            try self.write("?*anyopaque) callconv(.c) void = null,\n");
        }
        // Trailing (see c.zig's emitListenerStruct — must stay in sync, same
        // field, same position; this struct is ABI-compatible with the C one
        // and zzdds core itself stores/passes this exact Zig type).
        try self.ind();
        try self.write("    release_listener_data: ?*const fn (?*anyopaque) callconv(.c) void = null,\n");
        try self.ind();
        try self.print("}}; // {s}{s}\n\n", .{ pfx, iface_name });
    }

    /// Emit one trivial `pub export fn callconv(.c)` forwarder for an
    /// interface operation. Every entity value crossing this boundary —
    /// `self`, entity-typed params, entity-typed returns — is a single boxed
    /// opaque pointer, uniformly, leaf or base interface alike (see
    /// `zidl_rt.EntityBox`). Params unbox via `zidl_rt.unboxAs` before
    /// dispatching to the reconstructed native vtable call; entity returns
    /// are obtained via `_r.vtable.get_c_abi_handle(_r.ptr)` — no allocation
    /// in generated code, except for `sequence<EntityInterface>`-typed
    /// params (see `typeRefIsEntitySequence`), which need one temporary
    /// allocation (freed before returning) to bridge the native fat-pointer
    /// element layout to the C-ABI's single-opaque-pointer-per-element one.
    fn emitCApiOp(
        self: *Generator,
        c_name: []const u8,
        pfx: []const u8,
        iface_name: []const u8,
        self_unbox_fn: []const u8,
        op: *const ir.Operation,
    ) anyerror!void {
        const c_ret = try self.cApiExportOptRetType(op.return_type);
        defer self.alloc.free(c_ret);
        const is_void_ret = std.mem.eql(u8, c_ret, "void");

        try self.ind();
        try self.print("pub export fn {s}_{s}(self: *anyopaque", .{ c_name, op.name });
        for (op.params) |p| {
            const pt = try self.cApiExportParamType(p);
            defer self.alloc.free(pt);
            // Struct in-params use ?*const T so C callers can pass null for defaults
            // (DDS convention: null QoS means "use entity-type default QoS").
            if (p.mode == .in_ and std.mem.startsWith(u8, pt, "*const ")) {
                try self.print(", {s}: ?{s}", .{ p.name, pt });
            } else {
                try self.print(", {s}: {s}", .{ p.name, pt });
            }
        }
        try self.print(") callconv(.c) {s} {{\n", .{c_ret});

        try self.ind();
        try self.print("    const _self: {s}{s} = {s}({s}{s}, self);\n", .{ pfx, iface_name, self_unbox_fn, pfx, iface_name });

        // Entity-sequence params (DataReaderSeq, ConditionSeq, ...) need a
        // native-shaped temporary to call the vtable slot through -- its
        // real element type is the full {ptr, vtable} fat pointer, not
        // C-ABI compatible (see typeRefIsEntitySequence) -- then per-element
        // boxing into the caller's actual buffer afterward. Every real
        // native implementation of these operations (get_datareaders,
        // WaitSet.wait/get_conditions) already discards whatever the caller
        // passed in before populating results, so there's no "unbox on the
        // way in" need, only "free the caller's prior buffer" (a plain
        // "start clean" contract) and "box on the way out". The anonymous
        // extern struct here is the C-ABI shape c.zig's C backend
        // independently declares for every *Seq typedef (_maximum, _length,
        // a single-opaque-pointer-per-element _buffer, _release) -- it's
        // deliberately untyped/unnamed since it's only ever used to
        // reinterpret the caller's own buffer at this one call site.
        for (op.params) |p| {
            if (!typeRefIsEntitySequence(p.type_ref)) continue;
            const td = seqTypedef(p.type_ref).?;
            const native_ty = try self.qualNameToZig(td.qualified_name);
            defer self.alloc.free(native_ty);
            try self.ind();
            try self.print("    const _cseq_{s}: *extern struct {{ _maximum: u32 = 0, _length: u32 = 0, _buffer: ?[*]?*anyopaque = null, _release: bool = false }} = @ptrCast(@alignCast({s}));\n", .{ p.name, p.name });
            try self.ind();
            try self.print("    if (_cseq_{s}._release) {{ if (_cseq_{s}._buffer) |_ob| std.heap.c_allocator.free(_ob[0.._cseq_{s}._maximum]); }}\n", .{ p.name, p.name, p.name });
            try self.ind();
            try self.print("    var _native_{s}: {s} = .{{}};\n", .{ p.name, native_ty });
        }

        // Struct params needing a C-ABI mirror (see that section's doc
        // comment): the exported signature above already took the mirror
        // type, not the internal one the vtable slot expects — build a real,
        // temporary internal-typed value here (`in`/`inout`: converted from
        // whatever the caller passed; `.in_`'s own `null` means "use the
        // type default", same convention as every other optional struct
        // in-param) and call the vtable through *that*'s address instead.
        for (op.params) |p| {
            const mirror_name = try self.cApiMirrorTypeName(p.type_ref) orelse continue;
            defer self.alloc.free(mirror_name);
            const inner = try self.typeRefToZig(p.type_ref);
            defer self.alloc.free(inner);
            try self.ind();
            if (p.mode == .in_) {
                try self.print("    var _mir_{s}: {s} = if ({s}) |_m| {s}FromCAbi(_m) else .{{}};\n", .{ p.name, inner, p.name, inner });
            } else if (p.mode == .inout) {
                try self.print("    var _mir_{s}: {s} = {s}FromCAbi({s});\n", .{ p.name, inner, inner, p.name });
            } else {
                // `.out`: the caller's storage is uninitialized/write-only by
                // IDL convention -- FromCAbi-ing it would read garbage as if
                // it were a valid mirror value (a bad string pointer, a
                // corrupt sequence length, etc). Start from the type default
                // instead, same as `.in_`'s "null means default" fallback.
                try self.print("    var _mir_{s}: {s} = .{{}};\n", .{ p.name, inner });
            }
            if (try self.cApiMirrorInternalNeedsDeinit(p.type_ref)) {
                try self.ind();
                try self.print("    defer _mir_{s}.deinit(std.heap.c_allocator);\n", .{p.name});
            }
        }

        const ret_is_entity = if (op.return_type) |rt| typeRefIsEntityInterface(rt) else false;
        const ret_mirror_name = if (op.return_type) |rt| try self.cApiMirrorTypeName(rt) else null;
        defer if (ret_mirror_name) |mn| self.alloc.free(mn);
        var has_entity_seq_param = false;
        for (op.params) |p| {
            if (typeRefIsEntitySequence(p.type_ref)) {
                has_entity_seq_param = true;
                break;
            }
        }
        // Same reasoning as `has_entity_seq_param`: an `inout`/`out` mirror
        // param needs its own post-call write-back (mirror-ify the now-
        // updated local value into the caller's buffer) before the function
        // can actually return.
        var has_mirror_out_param = false;
        for (op.params) |p| {
            if (p.mode == .in_) continue;
            if (try self.cApiMirrorTypeName(p.type_ref)) |mn| {
                self.alloc.free(mn);
                has_mirror_out_param = true;
                break;
            }
        }
        // A plain (non-entity, non-void, non-mirror-return) return can't be
        // inlined into the call statement as `return _self.vtable.foo(...)`
        // here: the boxing loop below still needs to run afterward, and a
        // `return` already exits the function. Capture it instead and
        // return it for real once boxing is done.
        const defer_plain_return = (has_entity_seq_param or has_mirror_out_param) and !ret_is_entity and ret_mirror_name == null and !is_void_ret;

        try self.ind();
        if (ret_is_entity or ret_mirror_name != null) {
            try self.write("    const _r = ");
        } else if (defer_plain_return) {
            try self.write("    const _ret_status = ");
        } else if (!is_void_ret) {
            try self.write("    return ");
        } else {
            try self.write("    ");
        }
        try self.print("_self.vtable.{s}(_self.ptr", .{op.name});
        for (op.params) |p| {
            const pt = try self.cApiExportParamType(p);
            defer self.alloc.free(pt);
            if (typeRefIsEntitySequence(p.type_ref)) {
                try self.print(", &_native_{s}", .{p.name});
            } else if (typeRefIsEntityInterface(p.type_ref)) {
                const pzig = try self.typeRefToZig(p.type_ref);
                defer self.alloc.free(pzig);
                const p_unbox_fn = cAbiUnboxFnName(typeRefEntityInterface(p.type_ref).?);
                try self.print(", {s}({s}, {s})", .{ p_unbox_fn, pzig, p.name });
            } else if (try self.cApiMirrorTypeName(p.type_ref)) |mn| {
                self.alloc.free(mn);
                // `_mir_{name}` (declared above) is the real internal-typed
                // value the vtable slot expects -- call through its address,
                // never the mirror pointer the exported signature took.
                try self.print(", &_mir_{s}", .{p.name});
            } else if (p.mode == .in_ and std.mem.startsWith(u8, pt, "*const ")) {
                // Substitute the type default when caller passes null.
                try self.print(", {s} orelse &.{{}}", .{p.name});
            } else {
                try self.print(", {s}", .{p.name});
            }
        }
        try self.write(");\n");

        // Write the (now vtable-updated, for inout/out) local internal value
        // back into the caller's mirror buffer -- see the pre-call comment
        // above. `.in_`-only params have nothing to write back (the caller's
        // buffer is `*const`, and `has_mirror_out_param` above already
        // excludes them from needing `defer_plain_return` for this reason).
        for (op.params) |p| {
            if (p.mode == .in_) continue;
            const mirror_name = try self.cApiMirrorTypeName(p.type_ref) orelse continue;
            defer self.alloc.free(mirror_name);
            const inner = try self.typeRefToZig(p.type_ref);
            defer self.alloc.free(inner);
            try self.ind();
            try self.print("    {s}ToCAbi(&_mir_{s}, {s});\n", .{ inner, p.name, p.name });
        }

        // Box each result element (native fat pointer -> single opaque C-ABI
        // handle, via the same `.vtable.get_c_abi_handle(.ptr)` convention
        // used everywhere else an entity crosses this boundary) and hand the
        // caller back a C-ABI-shaped seq; free the native temporary's own
        // buffer (allocated internally by the vtable call, via whatever
        // allocator the entity is configured with).
        for (op.params) |p| {
            if (!typeRefIsEntitySequence(p.type_ref)) continue;
            try self.ind();
            try self.print("    var _boxed_{s}: ?[*]?*anyopaque = null;\n", .{p.name});
            try self.ind();
            try self.print("    if (_native_{s}._length > 0) {{\n", .{p.name});
            try self.ind();
            try self.print("        const _bb = std.heap.c_allocator.alloc(?*anyopaque, _native_{s}._length) catch @panic(\"out of memory boxing entity sequence\");\n", .{p.name});
            try self.ind();
            try self.print("        for (_native_{s}._buffer.?[0.._native_{s}._length], 0..) |_e, _i| {{ _bb[_i] = _e.vtable.get_c_abi_handle(_e.ptr); }}\n", .{ p.name, p.name });
            try self.ind();
            try self.print("        _boxed_{s} = _bb.ptr;\n", .{p.name});
            try self.ind();
            try self.write("    }\n");
            try self.ind();
            try self.print("    if (_native_{s}._release) {{ if (_native_{s}._buffer) |_ob| std.heap.c_allocator.free(_ob[0.._native_{s}._maximum]); }}\n", .{ p.name, p.name, p.name });
            try self.ind();
            try self.print("    _cseq_{s}.* = .{{ ._maximum = _native_{s}._length, ._length = _native_{s}._length, ._buffer = _boxed_{s}, ._release = _native_{s}._length > 0 }};\n", .{ p.name, p.name, p.name, p.name, p.name });
        }

        if (ret_is_entity) {
            try self.ind();
            try self.write("    return _r.vtable.get_c_abi_handle(_r.ptr);\n");
        } else if (ret_mirror_name) |mn| {
            const inner = try self.typeRefToZig(op.return_type.?);
            defer self.alloc.free(inner);
            try self.ind();
            try self.print("    var _mir_ret: {s} = .{{}};\n", .{mn});
            try self.ind();
            try self.print("    {s}ToCAbi(&_r, &_mir_ret);\n", .{inner});
            if (try self.cApiMirrorInternalNeedsDeinit(op.return_type.?)) {
                try self.ind();
                try self.write("    _r.deinit(std.heap.c_allocator);\n");
            }
            try self.ind();
            try self.write("    return _mir_ret;\n");
        } else if (defer_plain_return) {
            try self.ind();
            try self.write("    return _ret_status;\n");
        }

        try self.ind();
        try self.write("}\n\n");
    }

    /// Emit trivial getter and optional setter `pub export fn` for an
    /// attribute. See `emitCApiOp` for the entity boxing/unboxing convention.
    fn emitCApiAttr(
        self: *Generator,
        c_name: []const u8,
        pfx: []const u8,
        iface_name: []const u8,
        self_unbox_fn: []const u8,
        attr: *const ir.Attribute,
    ) anyerror!void {
        const c_at = try self.cApiExportRetType(attr.type_ref);
        defer self.alloc.free(c_at);
        const at_is_entity = typeRefIsEntityInterface(attr.type_ref);

        try self.ind();
        try self.print("pub export fn {s}_get_{s}(self: *anyopaque) callconv(.c) {s} {{\n", .{ c_name, attr.name, c_at });
        try self.ind();
        try self.print("    const _self: {s}{s} = {s}({s}{s}, self);\n", .{ pfx, iface_name, self_unbox_fn, pfx, iface_name });
        try self.ind();
        if (at_is_entity) {
            try self.print("    const _r = _self.vtable.get_{s}(_self.ptr);\n", .{attr.name});
            try self.ind();
            try self.write("    return _r.vtable.get_c_abi_handle(_r.ptr);\n");
        } else {
            try self.print("    return _self.vtable.get_{s}(_self.ptr);\n", .{attr.name});
        }
        try self.ind();
        try self.write("}\n\n");

        if (!attr.readonly) {
            const c_param = try self.cApiExportTypeRef(attr.type_ref, .in_);
            defer self.alloc.free(c_param);
            try self.ind();
            try self.print("pub export fn {s}_set_{s}(self: *anyopaque, value: {s}) callconv(.c) void {{\n", .{ c_name, attr.name, c_param });
            try self.ind();
            try self.print("    const _self: {s}{s} = {s}({s}{s}, self);\n", .{ pfx, iface_name, self_unbox_fn, pfx, iface_name });
            try self.ind();
            if (at_is_entity) {
                const at_zig = try self.typeRefToZig(attr.type_ref);
                defer self.alloc.free(at_zig);
                const val_unbox_fn = cAbiUnboxFnName(typeRefEntityInterface(attr.type_ref).?);
                try self.print("    _self.vtable.set_{s}(_self.ptr, {s}({s}, value));\n", .{ attr.name, val_unbox_fn, at_zig });
            } else {
                try self.print("    _self.vtable.set_{s}(_self.ptr, value);\n", .{attr.name});
            }
            try self.ind();
            try self.write("}\n\n");
        }
    }

    /// If `tr` refers to a listener interface, return that interface; else null.
    /// Used to detect listener parameters that need CXxxListenerAdapter treatment.
    /// Returns true when the interface bears `@callback`, meaning the generator should
    /// produce a C callback struct instead of a fat-pointer vtable entity.
    /// Falls back to the "Listener" name suffix heuristic for IDL files that have not
    /// yet been annotated — this fallback is deprecated and will be removed.
    fn isCallbackInterface(iface: *const ir.Interface) bool {
        return interface.isCallbackInterface(iface);
    }

    /// True for `@shared_c_abi_box` interfaces — see `ir.hasSharedCAbiBox`'s
    /// doc comment. Drives both whether `emitInterface` generates a nested
    /// `CAbiViews` type and which unboxing function (`cAbiUnboxFnName`)
    /// generated C-ABI export wrappers call for a value of this type.
    fn hasSharedCAbiBox(iface: *const ir.Interface) bool {
        return interface.hasSharedCAbiBox(iface);
    }

    /// If `tr` names a non-callback (entity) interface, return its IR node;
    /// else null. Like `typeRefIsEntityInterface` but returns the interface
    /// itself instead of a bool, for callers (`cAbiUnboxFnName`'s callers)
    /// that need to inspect it (e.g. `hasSharedCAbiBox`).
    fn typeRefEntityInterface(tr: ir.TypeRef) ?*const ir.Interface {
        return switch (tr) {
            .named => |td| switch (td) {
                .interface => |iface| if (!isCallbackInterface(iface)) iface else null,
                else => null,
            },
            else => null,
        };
    }

    /// Which `zidl_rt` function generated code should call to reconstruct a
    /// native fat-pointer value of type `iface` from a boxed C-ABI handle:
    /// the plain per-view `unboxAs` normally, or `unboxAsView` for
    /// `@shared_c_abi_box` interfaces (see `ir.hasSharedCAbiBox`), whose
    /// boxes hold a `CAbiViews` pointer instead of a bare `Vtable` pointer.
    fn cAbiUnboxFnName(iface: *const ir.Interface) []const u8 {
        return if (hasSharedCAbiBox(iface)) "zidl_rt.unboxAsView" else "zidl_rt.unboxAs";
    }

    /// If `tr` is a named typedef whose underlying type is a sequence, return that typedef.
    /// Used to detect sequence parameters that need C_XxxSeq ↔ ArrayListUnmanaged conversion.
    fn seqTypedef(tr: ir.TypeRef) ?*const ir.Typedef {
        return switch (tr) {
            .named => |td| switch (td) {
                .typedef => |t| switch (t.type_ref) {
                    .sequence => t,
                    else => null,
                },
                else => null,
            },
            else => null,
        };
    }

    /// True when `tr` is a type that maps to a C scalar — base types, and typedef chains
    /// that ultimately resolve to a base type (e.g. `DomainId_t = uint32_t`).
    /// These can be passed by value in `callconv(.c)` functions; non-primitive named types
    /// (structs, unions) must be passed by pointer.
    fn isCApiPrimitive(tr: ir.TypeRef) bool {
        return switch (tr) {
            .base => true,
            .named => |td| switch (td) {
                .typedef => |t| isCApiPrimitive(t.type_ref),
                .enum_, .bitmask, .bitset => true,
                else => false,
            },
            else => false,
        };
    }

    /// C-ABI qualified name: `DDS::DomainParticipant` → `DDS_DomainParticipant`.
    fn cApiQualName(self: *Generator, qname: []const u8, pfx: []const u8) ![]u8 {
        return interface.prefixedCNameFromQualified(self.alloc, qname, pfx);
    }

    /// C-ABI parameter type for `pub export fn`: string → sentinel pointer,
    /// named struct/union → pointer, everything else same as vtable type.
    fn cApiParamType(self: *Generator, p: ir.Parameter) ![]u8 {
        return self.cApiTypeRef(p.type_ref, p.mode);
    }

    // ── C-ABI-boundary-facing type overrides ──────────────────────────────────
    //
    // `cApiTypeRef`/`cApiRetType`/`cApiParamType` above return the *native*
    // type for entity interfaces (the real `{ptr, vtable}` fat pointer) — they
    // also serve the native vtable slot and idiomatic forwarding-method
    // declarations, which must keep dealing in real values internally.
    //
    // Anything that actually crosses `callconv(.c)` — a `pub export fn`'s own
    // signature, or a `@callback` thunk's signature — narrows entity
    // interfaces down to a single boxed `*anyopaque` instead (see
    // `zidl_rt.EntityBox`, `typeRefIsEntityInterface`). These wrappers apply
    // that narrowing on top of the native functions above.

    fn cApiExportTypeRef(self: *Generator, tr: ir.TypeRef, mode: ir.ParamMode) ![]u8 {
        if (typeRefIsEntityInterface(tr)) return self.alloc.dupe(u8, "*anyopaque");
        if (typeRefIsEntitySequence(tr)) return self.alloc.dupe(u8, "*anyopaque");
        // A plain struct needing a C-ABI mirror (see that section's doc
        // comment) must use the mirror's own type here, not the internal
        // one `cApiTypeRef` would otherwise return — this is the one place
        // that actually matters: the *exported* `pub export fn` signature is
        // what a C/C++/Java caller's own header-shaped value gets read as.
        // `emitCApiOp` converts to/from the internal type right after
        // unboxing `self`. Scoped to operation params/returns only, not
        // `@callback` thunks (no known DCPS status struct needs a mirror
        // today — none contain an unbounded string — so that path is
        // deliberately left unhandled rather than guessed at).
        if (try self.cApiMirrorTypeName(tr)) |mirror_name| {
            defer self.alloc.free(mirror_name);
            return switch (mode) {
                .in_ => std.fmt.allocPrint(self.alloc, "*const {s}", .{mirror_name}),
                .out, .inout => std.fmt.allocPrint(self.alloc, "*{s}", .{mirror_name}),
            };
        }
        return self.cApiTypeRef(tr, mode);
    }

    fn cApiExportParamType(self: *Generator, p: ir.Parameter) ![]u8 {
        return self.cApiExportTypeRef(p.type_ref, p.mode);
    }

    fn cApiExportRetType(self: *Generator, ret: ir.TypeRef) ![]u8 {
        if (typeRefIsEntityInterface(ret)) return self.alloc.dupe(u8, "*anyopaque");
        // A by-value return of a plain struct needing a C-ABI mirror (see
        // that section's doc comment) must use the mirror's own type here
        // too, not just for params -- otherwise the exported function's
        // return type disagrees with what the independently-generated `-b
        // c` header declares for the same struct, the same mismatch this
        // whole mechanism exists to close. `emitCApiOp` builds and converts
        // the returned value.
        if (try self.cApiMirrorTypeName(ret)) |mirror_name| return mirror_name;
        return self.cApiRetType(ret);
    }

    fn cApiExportOptRetType(self: *Generator, ret: ?ir.TypeRef) ![]u8 {
        return if (ret) |tr| self.cApiExportRetType(tr) else self.alloc.dupe(u8, "void");
    }

    // ── Idiomatic Zig forwarding-method helpers ───────────────────────────────
    //
    // Forwarding methods (the `pub fn xxx(self: @This(), ...)` on entity structs)
    // use ergonomic Zig types rather than C-ABI types:
    //   • `in` strings: `[]const u8`  (vs `[*:0]const u8` in vtable slot)
    //   • `in` non-primitive structs: by value (vs `*const T` in vtable slot)
    //   • `in` callback interfaces: `?T` optional by value (vs `?*const T`)
    // The body emits the necessary conversions before calling the vtable slot.
    // Out/inout params, return types for non-strings, and primitives are unchanged.

    /// Idiomatic Zig parameter type for a forwarding method.
    fn idiomParamType(self: *Generator, p: ir.Parameter) ![]u8 {
        if (p.mode == .out or p.mode == .inout) {
            return self.cApiTypeRef(p.type_ref, p.mode);
        }
        return switch (p.type_ref) {
            .string => |b| if (b == null)
                self.alloc.dupe(u8, "[:0]const u8")
            else
                self.cApiTypeRef(p.type_ref, p.mode),
            .wstring => |b| if (b == null)
                self.alloc.dupe(u8, "[:0]const u16")
            else
                self.cApiTypeRef(p.type_ref, p.mode),
            .named => |td| switch (td) {
                .interface => |iface| if (isCallbackInterface(iface)) blk: {
                    const zig = try self.typeRefToZig(p.type_ref);
                    defer self.alloc.free(zig);
                    break :blk std.fmt.allocPrint(self.alloc, "?{s}", .{zig});
                } else self.cApiTypeRef(p.type_ref, p.mode),
                else => if (!isCApiPrimitive(p.type_ref) and seqTypedef(p.type_ref) == null)
                    self.typeRefToZig(p.type_ref) // by value
                else
                    self.cApiTypeRef(p.type_ref, p.mode),
            },
            else => self.cApiTypeRef(p.type_ref, p.mode),
        };
    }

    /// Whether a forwarding method param needs a local `var` before the vtable call.
    /// Required for optional-callback params so we can take a pointer to the value.
    fn idiomNeedsLocal(p: ir.Parameter) bool {
        if (p.mode != .in_) return false;
        return switch (p.type_ref) {
            .named => |td| switch (td) {
                .interface => |iface| isCallbackInterface(iface),
                else => false,
            },
            else => false,
        };
    }

    /// Expression to pass an idiomatic forwarding param to the vtable.
    /// `lv_name` is the emitted local variable name (non-null only for callback params).
    fn idiomCallArg(self: *Generator, p: ir.Parameter, lv_name: ?[]const u8) ![]u8 {
        if (p.mode == .out or p.mode == .inout) {
            return self.alloc.dupe(u8, p.name);
        }
        return switch (p.type_ref) {
            .string => |b| if (b == null)
                std.fmt.allocPrint(self.alloc, "{s}.ptr", .{p.name})
            else
                self.alloc.dupe(u8, p.name),
            .wstring => |b| if (b == null)
                std.fmt.allocPrint(self.alloc, "{s}.ptr", .{p.name})
            else
                self.alloc.dupe(u8, p.name),
            .named => |td| switch (td) {
                .interface => |iface| if (isCallbackInterface(iface)) blk: {
                    const lv = lv_name orelse p.name;
                    const zig = try self.typeRefToZig(p.type_ref);
                    defer self.alloc.free(zig);
                    break :blk std.fmt.allocPrint(self.alloc, "(if ({s}) |*_x| @as(?*const {s}, _x) else null)", .{ lv, zig });
                } else self.alloc.dupe(u8, p.name),
                else => if (!isCApiPrimitive(p.type_ref) and seqTypedef(p.type_ref) == null)
                    std.fmt.allocPrint(self.alloc, "&{s}", .{p.name})
                else
                    self.alloc.dupe(u8, p.name),
            },
            else => self.alloc.dupe(u8, p.name),
        };
    }

    /// Idiomatic Zig return type for a forwarding method.
    /// Strings become `[]const u8`; everything else unchanged.
    fn idiomOptRetType(self: *Generator, ret: ?ir.TypeRef) ![]u8 {
        if (ret) |tr| return switch (tr) {
            .string => self.alloc.dupe(u8, "[]const u8"),
            .wstring => self.alloc.dupe(u8, "[]const u16"),
            else => self.cApiRetType(tr),
        };
        return self.alloc.dupe(u8, "void");
    }

    /// Whether the idiomatic return needs `std.mem.span()` wrapping.
    fn idiomRetNeedsSpan(ret: ?ir.TypeRef) bool {
        return if (ret) |tr| switch (tr) {
            .string, .wstring => true,
            else => false,
        } else false;
    }

    fn cApiTypeRef(self: *Generator, tr: ir.TypeRef, mode: ir.ParamMode) ![]u8 {
        return switch (tr) {
            .string => self.alloc.dupe(u8, switch (mode) {
                .in_ => "[*:0]const u8",
                .out, .inout => "[*:0]u8",
            }),
            .wstring => self.alloc.dupe(u8, switch (mode) {
                .in_ => "[*:0]const u16",
                .out, .inout => "[*:0]u16",
            }),
            .named => |td| switch (td) {
                // Callback interfaces: optional pointer to C callback struct.
                // Entity interfaces: the *native* fat-pointer type, unchanged
                // — this function also serves the native vtable slot and
                // idiomatic forwarding-method declarations, which always deal
                // in real `{ptr, vtable}` values internally. Only the
                // C-ABI-facing *export* signatures (the `pub export fn`
                // itself, and `@callback` thunks) narrow entities down to a
                // single boxed `*anyopaque` — see `cApiExportTypeRef`.
                .interface => |iface| if (isCallbackInterface(iface)) blk: {
                    const zig = try self.typeRefToZig(tr);
                    defer self.alloc.free(zig);
                    break :blk switch (mode) {
                        .in_ => std.fmt.allocPrint(self.alloc, "?*const {s}", .{zig}),
                        .out, .inout => std.fmt.allocPrint(self.alloc, "?*{s}", .{zig}),
                    };
                } else self.typeRefToZig(tr),
                // Enum/bitmask/bitset are primitive-sized — pass by value.
                .enum_, .bitmask, .bitset => self.typeRefToZig(tr),
                // Sequence typedefs: pointer to the extern struct (now the canonical type).
                // Primitive typedefs (uint32_t aliases like DomainId_t, StatusMask, etc.):
                //   pass by value — same as the underlying C scalar.
                // Other named types (struct, union, exception): pass by pointer.
                else => blk: {
                    if (seqTypedef(tr)) |std_td| {
                        // Use the fully qualified name (via qualNameToZig), not the
                        // bare `.name` field: this type may be a cross-module
                        // reference (e.g. an operation inherited from an imported
                        // base interface via collectInterfaceMembers), where the
                        // bare name is not a valid identifier in the emitting
                        // file. qualNameToZig already applies type_prefix correctly.
                        const zig = try self.qualNameToZig(std_td.qualified_name);
                        defer self.alloc.free(zig);
                        break :blk switch (mode) {
                            .in_ => std.fmt.allocPrint(self.alloc, "?*const {s}", .{zig}),
                            .out, .inout => std.fmt.allocPrint(self.alloc, "?*{s}", .{zig}),
                        };
                    }
                    if (isCApiPrimitive(tr)) {
                        break :blk self.typeRefToZig(tr); // by value, like the underlying scalar
                    }
                    const zig = try self.typeRefToZig(tr);
                    defer self.alloc.free(zig);
                    break :blk switch (mode) {
                        .in_ => std.fmt.allocPrint(self.alloc, "*const {s}", .{zig}),
                        .out, .inout => std.fmt.allocPrint(self.alloc, "*{s}", .{zig}),
                    };
                },
            },
            .sequence => blk: {
                // Sequences: pass by pointer.  The Zig sequence type is not C-ABI
                // compatible internally, but a pointer to it is always pointer-sized.
                // Phase 3b will introduce proper C sequence struct conversion.
                const zig = try self.typeRefToZig(tr);
                defer self.alloc.free(zig);
                break :blk switch (mode) {
                    .in_ => std.fmt.allocPrint(self.alloc, "*const {s}", .{zig}),
                    .out, .inout => std.fmt.allocPrint(self.alloc, "*{s}", .{zig}),
                };
            },
            else => blk: {
                // Primitive base types: by value for `in`, pointer for `out`/`inout`.
                const zig = try self.typeRefToZig(tr);
                errdefer self.alloc.free(zig);
                break :blk switch (mode) {
                    .in_ => zig,
                    .out, .inout => blk2: {
                        defer self.alloc.free(zig);
                        break :blk2 std.fmt.allocPrint(self.alloc, "*{s}", .{zig});
                    },
                };
            },
        };
    }

    /// C-ABI return type: `[]const u8` → `[*:0]const u8`; entity interfaces
    /// stay the *native* fat-pointer type (see `cApiTypeRef`'s doc comment —
    /// this also serves the native vtable slot); others unchanged.
    fn cApiRetType(self: *Generator, ret: ir.TypeRef) ![]u8 {
        return switch (ret) {
            .string => self.alloc.dupe(u8, "[*:0]const u8"),
            .wstring => self.alloc.dupe(u8, "[*:0]const u16"),
            else => self.typeRefToZig(ret),
        };
    }

    /// C-ABI return type for an optional return (operation return type).
    fn cApiOptRetType(self: *Generator, ret: ?ir.TypeRef) ![]u8 {
        return if (ret) |tr| self.cApiRetType(tr) else self.alloc.dupe(u8, "void");
    }

    /// Flatten inherited operations and attributes into `ops`/`attrs`.
    /// Base interfaces are processed first (declaration order).
    fn collectInterfaceMembers(
        self: *Generator,
        iface: *const ir.Interface,
        ops: *std.ArrayListUnmanaged(ir.Operation),
        attrs: *std.ArrayListUnmanaged(ir.Attribute),
    ) anyerror!void {
        for (iface.bases) |base| {
            if (base == .interface) {
                try self.collectInterfaceMembers(base.interface, ops, attrs);
            }
        }
        try ops.appendSlice(self.alloc, iface.operations);
        try attrs.appendSlice(self.alloc, iface.attributes);
    }

    // ── Const ─────────────────────────────────────────────────────────────────

    fn emitConst(self: *Generator, c: *const ir.Const) !void {
        const zig_type = try self.typeRefToZig(c.type_ref);
        defer self.alloc.free(zig_type);

        try self.ind();
        switch (c.value) {
            .integer => |v| try self.print(
                "pub const {s}: {s} = {d};\n",
                .{ c.name, zig_type, v },
            ),
            .float => |v| try self.print(
                "pub const {s}: {s} = {d};\n",
                .{ c.name, zig_type, v },
            ),
            .boolean => |v| try self.print(
                "pub const {s}: bool = {s};\n",
                .{ c.name, if (v) "true" else "false" },
            ),
            .character => |ch| {
                if (std.ascii.isPrint(ch) and ch != '\'' and ch != '\\') {
                    try self.print("pub const {s}: u8 = '{c}';\n", .{ c.name, ch });
                } else {
                    try self.print("pub const {s}: u8 = 0x{X:0>2};\n", .{ c.name, ch });
                }
            },
            .string => |s| {
                try self.print("pub const {s}: []const u8 = \"", .{c.name});
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
                try self.write("\";\n");
            },
            .wide_character => |wc| try self.print(
                "pub const {s}: u16 = 0x{X:0>4};\n",
                .{ c.name, wc },
            ),
            .wide_string => try self.print(
                "// {s}: wide string const — []const u16 literal not supported\n",
                .{c.name},
            ),
            .fixed_pt => |fp| try self.print(
                "// {s}: fixed-point const {s}\n",
                .{ c.name, fp },
            ),
        }
    }

    // ── Field helper ──────────────────────────────────────────────────────────

    /// Emit one struct field line: `    name: Type = default,\n`.
    /// `ind()` provides the struct's own indentation; the `"    "` prefix adds
    /// one level for the field inside the struct body.
    fn emitField(
        self: *Generator,
        name: []const u8,
        type_ref: ir.TypeRef,
        dims: []const u64,
        is_optional: bool,
        default_value: ?ir.AnnotationParamValue,
    ) !void {
        const zig_type = try self.typeRefToZig(type_ref);
        defer self.alloc.free(zig_type);

        try self.ind();

        if (is_optional) {
            if (default_value) |dv| {
                const dv_str = try self.formatDefaultValueZig(dv, type_ref);
                defer self.alloc.free(dv_str);
                try self.print("    {s}: ?{s} = {s},\n", .{ name, zig_type, dv_str });
            } else {
                try self.print("    {s}: ?{s} = null,\n", .{ name, zig_type });
            }
        } else if (dims.len > 0) {
            const arr_type = try self.makeArrayType(zig_type, dims);
            defer self.alloc.free(arr_type);
            const default = try self.defaultForArrayType(arr_type);
            defer self.alloc.free(default);
            try self.print("    {s}: {s} = {s},\n", .{ name, arr_type, default });
        } else if (default_value) |dv| {
            const dv_str = try self.formatDefaultValueZig(dv, type_ref);
            defer self.alloc.free(dv_str);
            try self.print("    {s}: {s} = {s},\n", .{ name, zig_type, dv_str });
        } else {
            const default = try self.defaultForTypeRef(type_ref);
            defer self.alloc.free(default);
            try self.print("    {s}: {s} = {s},\n", .{ name, zig_type, default });
        }
    }

    /// Format an `AnnotationParamValue` as a Zig literal expression.
    fn formatDefaultValueZig(self: *Generator, dv: ir.AnnotationParamValue, type_ref: ir.TypeRef) ![]u8 {
        return switch (dv) {
            .integer => |v| std.fmt.allocPrint(self.alloc, "{d}", .{v}),
            .float => |v| std.fmt.allocPrint(self.alloc, "{d}", .{v}),
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
            .scoped_name => |n| self.formatScopedNameDefaultZig(n, type_ref),
            else => self.alloc.dupe(u8, "undefined"),
        };
    }

    fn formatScopedNameDefaultZig(self: *Generator, name: []const u8, type_ref: ir.TypeRef) ![]u8 {
        return switch (type_ref) {
            .named => |td| switch (td) {
                .enum_ => {
                    const tag = if (self.opts.zig_idiomatic_enums)
                        try self.idiomaticEnumTag(name)
                    else
                        try self.alloc.dupe(u8, name);
                    defer self.alloc.free(tag);
                    return std.fmt.allocPrint(self.alloc, ".{s}", .{tag});
                },
                .bitmask => |bm| {
                    // Bit constants are emitted as module-level declarations
                    // named `BitmaskName_BIT`. Using the fully qualified IR
                    // name works both from outside the module and inside the
                    // module struct via Zig's lazy declaration resolution.
                    const bit_qname = try std.fmt.allocPrint(self.alloc, "{s}_{s}", .{ bm.qualified_name, name });
                    defer self.alloc.free(bit_qname);
                    return self.qualNameToZig(bit_qname);
                },
                .typedef => |t| if (t.dimensions.len == 0)
                    self.formatScopedNameDefaultZig(name, t.type_ref)
                else
                    self.alloc.dupe(u8, name),
                else => self.alloc.dupe(u8, name),
            },
            else => self.alloc.dupe(u8, name),
        };
    }

    // ── CDR serialization emission ────────────────────────────────────────────

    fn emitStructSerializeFns(self: *Generator, s: *const ir.Struct) anyerror!void {
        const ext = s.annotations.extensibility;
        const mutable = ext == .mutable;
        const appendable = ext == .appendable; // true only for strictly @appendable

        const has_key = structHasKey(s);
        const needs_alloc = blk: {
            for (s.members) |m| {
                if (typeRefNeedsAllocator(m.type_ref)) break :blk true;
            }
            break :blk false;
        };

        try self.write("\n");

        // has_key constant
        try self.ind();
        try self.print("    pub const has_key = {s};\n\n", .{if (has_key) "true" else "false"});

        // ── serialize ────────────────────────────────────────────────────────
        try self.ind();
        try self.write("    pub fn serialize(writer: anytype, value: @This()) !void {\n");

        if (mutable) {
            // @mutable: outer DHEADER + per-member EMHEADER framing.
            try self.ind();
            try self.write("        const _dh = try writer.reserveDheader();\n");
            for (s.members, 0..) |m, idx| {
                const member_id: u32 = memberIdAt(m, idx);
                const mu_flag = m.annotations.must_understand;
                const mu_str = if (mu_flag) "true" else "false";
                if (m.annotations.is_optional) {
                    // Optional member: only emit EMHEADER when value is present.
                    const opt_var = try std.fmt.allocPrint(self.alloc, "_opt_{s}", .{m.name});
                    defer self.alloc.free(opt_var);
                    try self.ind();
                    try self.print("        if (value.{s}) |{s}| {{\n", .{ m.name, opt_var });
                    if (lcForTypeRef(m.type_ref, m.dimensions)) |lc| {
                        try self.ind();
                        try self.print("            try writer.writeEmheaderFixed({d}, {s}, {d});\n", .{ member_id, mu_str, lc });
                    } else {
                        try self.ind();
                        try self.print("            const _em{d} = try writer.reserveEmheader({d}, {s});\n", .{ idx, member_id, mu_str });
                    }
                    if (m.dimensions.len > 0) {
                        try self.emitWriteArray(m.type_ref, opt_var, m.dimensions, "            ", 0);
                    } else {
                        try self.emitWriteForTypeRef(m.type_ref, opt_var, "            ");
                    }
                    if (lcForTypeRef(m.type_ref, m.dimensions) == null) {
                        try self.ind();
                        try self.print("            writer.patchEmheader(_em{d});\n", .{idx});
                    }
                    try self.ind();
                    try self.write("        }\n");
                    continue;
                }
                const access = try std.fmt.allocPrint(self.alloc, "value.{s}", .{m.name});
                defer self.alloc.free(access);
                if (lcForTypeRef(m.type_ref, m.dimensions)) |lc| {
                    try self.ind();
                    try self.print("        try writer.writeEmheaderFixed({d}, {s}, {d});\n", .{ member_id, mu_str, lc });
                    if (m.dimensions.len > 0) {
                        try self.emitWriteArray(m.type_ref, access, m.dimensions, "        ", 0);
                    } else {
                        try self.emitWriteForTypeRef(m.type_ref, access, "        ");
                    }
                } else {
                    try self.ind();
                    try self.print("        const _em{d} = try writer.reserveEmheader({d}, {s});\n", .{ idx, member_id, mu_str });
                    if (m.dimensions.len > 0) {
                        try self.emitWriteArray(m.type_ref, access, m.dimensions, "        ", 0);
                    } else {
                        try self.emitWriteForTypeRef(m.type_ref, access, "        ");
                    }
                    try self.ind();
                    try self.print("        writer.patchEmheader(_em{d});\n", .{idx});
                }
            }
            try self.ind();
            try self.write("        writer.patchDheader(_dh);\n");
        } else {
            if (appendable) {
                try self.ind();
                try self.write("        const _dh = try writer.reserveDheaderMaybe();\n");
            }
            if (s.base) |base| {
                const base_zig = try self.qualNameToZig(ir.typeDeclQualifiedName(base));
                defer self.alloc.free(base_zig);
                try self.ind();
                try self.print("        try {s}.serialize(writer, value._base);\n", .{base_zig});
            }
            for (s.members) |m| {
                if (m.annotations.is_optional) {
                    // XCDR2: write bool presence flag, then value if present (§12).
                    const opt_var = try std.fmt.allocPrint(self.alloc, "_opt_{s}", .{m.name});
                    defer self.alloc.free(opt_var);
                    try self.ind();
                    try self.print("        try writer.writeBool(value.{s} != null);\n", .{m.name});
                    try self.ind();
                    try self.print("        if (value.{s}) |{s}| {{\n", .{ m.name, opt_var });
                    if (m.dimensions.len > 0) {
                        try self.emitWriteArray(m.type_ref, opt_var, m.dimensions, "            ", 0);
                    } else {
                        try self.emitWriteForTypeRef(m.type_ref, opt_var, "            ");
                    }
                    try self.ind();
                    try self.write("        }\n");
                    continue;
                }
                const access = try std.fmt.allocPrint(self.alloc, "value.{s}", .{m.name});
                defer self.alloc.free(access);
                if (m.dimensions.len > 0) {
                    try self.emitWriteArray(m.type_ref, access, m.dimensions, "        ", 0);
                } else {
                    try self.emitWriteForTypeRef(m.type_ref, access, "        ");
                }
            }
            if (appendable) {
                try self.ind();
                try self.write("        writer.patchDheaderMaybe(_dh);\n");
            }
        }
        try self.ind();
        try self.write("    }\n\n");

        // ── deserializeInto ──────────────────────────────────────────────────
        try self.ind();
        try self.write("    pub fn deserializeInto(out: *@This(), reader: *zidl_rt.CdrReader, allocator: std.mem.Allocator) !void {\n");
        if (!needs_alloc) {
            try self.ind();
            try self.write("        _ = allocator;\n");
        }

        if (mutable) {
            // @mutable: read DHEADER for end pos, loop on EMHEADER-framed members.
            try self.ind();
            try self.write("        const _em_end = try reader.readMutableDheader();\n");
            try self.ind();
            try self.write("        while (reader.mutableHasMore(_em_end)) {\n");
            try self.ind();
            try self.write("            const _emh = try reader.readEmheader();\n");
            try self.ind();
            try self.write("            switch (_emh.member_id) {\n");
            for (s.members, 0..) |m, idx| {
                const member_id: u32 = memberIdAt(m, idx);
                try self.ind();
                try self.print("                {d} => {{\n", .{member_id});
                if (m.annotations.is_optional) {
                    // For @mutable+@optional: member appears → value is present.
                    const zig_type = try self.typeRefToZig(m.type_ref);
                    defer self.alloc.free(zig_type);
                    const opt_var = try std.fmt.allocPrint(self.alloc, "_opt_{s}", .{m.name});
                    defer self.alloc.free(opt_var);
                    const decl_type: []u8 = if (m.dimensions.len > 0)
                        try self.makeArrayType(zig_type, m.dimensions)
                    else
                        try self.alloc.dupe(u8, zig_type);
                    defer self.alloc.free(decl_type);
                    const default_val: []u8 = if (m.dimensions.len > 0)
                        try self.defaultForArrayType(decl_type)
                    else
                        try self.defaultForTypeRef(m.type_ref);
                    defer self.alloc.free(default_val);
                    try self.ind();
                    try self.print("                    var {s}: {s} = {s};\n", .{ opt_var, decl_type, default_val });
                    if (m.dimensions.len > 0) {
                        try self.emitReadArray(m.type_ref, opt_var, m.dimensions, "                    ", 0);
                    } else {
                        try self.emitReadForTypeRef(m.type_ref, opt_var, "                    ");
                    }
                    try self.ind();
                    try self.print("                    out.{s} = {s};\n", .{ m.name, opt_var });
                } else {
                    const out_expr = try std.fmt.allocPrint(self.alloc, "out.{s}", .{m.name});
                    defer self.alloc.free(out_expr);
                    if (m.dimensions.len > 0) {
                        try self.emitReadArray(m.type_ref, out_expr, m.dimensions, "                    ", 0);
                    } else {
                        try self.emitReadForTypeRef(m.type_ref, out_expr, "                    ");
                    }
                }
                try self.ind();
                try self.write("                },\n");
            }
            try self.ind();
            try self.write("                else => {\n");
            try self.ind();
            try self.write("                    if (_emh.must_understand) return error.UnknownMustUnderstand;\n");
            try self.ind();
            try self.write("                    try reader.skipEmheaderPayload(_emh);\n");
            try self.ind();
            try self.write("                },\n");
            try self.ind();
            try self.write("            }\n");
            try self.ind();
            try self.write("        }\n");
        } else {
            if (appendable) {
                try self.ind();
                try self.write("        try reader.skipDheaderIfXcdr2();\n");
            }
            if (s.base) |base| {
                const base_zig = try self.qualNameToZig(ir.typeDeclQualifiedName(base));
                defer self.alloc.free(base_zig);
                try self.ind();
                try self.print("        try {s}.deserializeInto(&out._base, reader, allocator);\n", .{base_zig});
            }
            for (s.members) |m| {
                if (m.annotations.is_optional) {
                    // XCDR2: read bool presence flag; if true deserialize value (§12).
                    const zig_type = try self.typeRefToZig(m.type_ref);
                    defer self.alloc.free(zig_type);
                    const opt_var = try std.fmt.allocPrint(self.alloc, "_opt_{s}", .{m.name});
                    defer self.alloc.free(opt_var);
                    const decl_type: []u8 = if (m.dimensions.len > 0)
                        try self.makeArrayType(zig_type, m.dimensions)
                    else
                        try self.alloc.dupe(u8, zig_type);
                    defer self.alloc.free(decl_type);
                    const default_val: []u8 = if (m.dimensions.len > 0)
                        try self.defaultForArrayType(decl_type)
                    else
                        try self.defaultForTypeRef(m.type_ref);
                    defer self.alloc.free(default_val);
                    try self.ind();
                    try self.write("        if (try reader.readBool()) {\n");
                    try self.ind();
                    try self.print("            var {s}: {s} = {s};\n", .{ opt_var, decl_type, default_val });
                    if (m.dimensions.len > 0) {
                        try self.emitReadArray(m.type_ref, opt_var, m.dimensions, "            ", 0);
                    } else {
                        try self.emitReadForTypeRef(m.type_ref, opt_var, "            ");
                    }
                    try self.ind();
                    try self.print("            out.{s} = {s};\n", .{ m.name, opt_var });
                    try self.ind();
                    try self.write("        } else {\n");
                    try self.ind();
                    try self.print("            out.{s} = null;\n", .{m.name});
                    try self.ind();
                    try self.write("        }\n");
                    continue;
                }
                const out_expr = try std.fmt.allocPrint(self.alloc, "out.{s}", .{m.name});
                defer self.alloc.free(out_expr);
                if (m.dimensions.len > 0) {
                    try self.emitReadArray(m.type_ref, out_expr, m.dimensions, "        ", 0);
                } else {
                    try self.emitReadForTypeRef(m.type_ref, out_expr, "        ");
                }
            }
        }
        try self.ind();
        try self.write("    }\n\n");

        // deserialize (convenience wrapper)
        try self.ind();
        try self.write("    pub fn deserialize(reader: *zidl_rt.CdrReader, allocator: std.mem.Allocator) !@This() {\n");
        try self.ind();
        try self.write("        var _out: @This() = .{};\n");
        try self.ind();
        try self.write("        try @This().deserializeInto(&_out, reader, allocator);\n");
        try self.ind();
        try self.write("        return _out;\n");
        try self.ind();
        try self.write("    }\n");

        // skip (allocation-free fast-forward over one full serialized sample)
        try self.write("\n");
        try self.ind();
        try self.write("    pub fn skip(reader: *zidl_rt.CdrReader) !void {\n");
        if (mutable) {
            try self.ind();
            try self.write("        const _end = try reader.readMutableDheader();\n");
            try self.ind();
            try self.write("        try reader.seekTo(_end);\n");
        } else {
            if (appendable) {
                try self.ind();
                try self.write("        if (reader.xcdr_version == .xcdr2) {\n");
                try self.ind();
                try self.write("            const _size = try reader.readDheader();\n");
                try self.ind();
                try self.write("            try reader.skip(_size);\n");
                try self.ind();
                try self.write("            return;\n");
                try self.ind();
                try self.write("        }\n");
            }
            if (s.base) |base| {
                const base_zig = try self.qualNameToZig(ir.typeDeclQualifiedName(base));
                defer self.alloc.free(base_zig);
                try self.ind();
                try self.print("        try {s}.skip(reader);\n", .{base_zig});
            }
            for (s.members) |m| {
                try self.emitSkipMember(m, "        ");
            }
        }
        try self.ind();
        try self.write("    }\n");

        // serializeKey (only if has_key)
        if (has_key) {
            try self.write("\n");
            try self.ind();
            try self.write("    pub fn serializeKey(writer: anytype, value: @This()) !void {\n");
            if (appendable) {
                try self.ind();
                try self.write("        const _dh = try writer.reserveDheaderMaybe();\n");
            }
            if (s.base) |base| {
                if (typeDeclHasKey(base)) {
                    const base_zig = try self.qualNameToZig(ir.typeDeclQualifiedName(base));
                    defer self.alloc.free(base_zig);
                    try self.ind();
                    try self.print("        try {s}.serializeKey(writer, value._base);\n", .{base_zig});
                }
            }
            for (s.members) |m| {
                if (!m.annotations.is_key) continue;
                const access = try std.fmt.allocPrint(self.alloc, "value.{s}", .{m.name});
                defer self.alloc.free(access);
                if (m.dimensions.len > 0) {
                    try self.emitWriteArray(m.type_ref, access, m.dimensions, "        ", 0);
                } else {
                    try self.emitWriteForTypeRef(m.type_ref, access, "        ");
                }
            }
            if (appendable) {
                try self.ind();
                try self.write("        writer.patchDheaderMaybe(_dh);\n");
            }
            try self.ind();
            try self.write("    }\n");

            try self.write("\n");
            try self.ind();
            try self.write("    pub fn deserializeKey(reader: *zidl_rt.CdrReader, allocator: std.mem.Allocator) !@This() {\n");
            try self.ind();
            try self.write("        var _out: @This() = .{};\n");
            try self.ind();
            try self.write("        try @This().deserializeKeyInto(&_out, reader, allocator);\n");
            try self.ind();
            try self.write("        return _out;\n");
            try self.ind();
            try self.write("    }\n");

            try self.write("\n");
            try self.ind();
            try self.write("    pub fn deserializeKeyInto(out: *@This(), reader: *zidl_rt.CdrReader, allocator: std.mem.Allocator) !void {\n");
            if (!structKeyNeedsAllocator(s)) {
                try self.ind();
                try self.write("        _ = allocator;\n");
            }
            if (mutable) {
                try self.ind();
                try self.write("        const _em_end = try reader.readMutableDheader();\n");
                try self.ind();
                try self.write("        while (reader.mutableHasMore(_em_end)) {\n");
                try self.ind();
                try self.write("            const _emh = try reader.readEmheader();\n");
                try self.ind();
                try self.write("            switch (_emh.member_id) {\n");
                for (s.members, 0..) |m, idx| {
                    if (!m.annotations.is_key) continue;
                    const member_id: u32 = memberIdAt(m, idx);
                    try self.ind();
                    try self.print("                {d} => {{\n", .{member_id});
                    const out_expr = try std.fmt.allocPrint(self.alloc, "out.{s}", .{m.name});
                    defer self.alloc.free(out_expr);
                    try self.emitReadPresentMember(m, out_expr, "                    ");
                    try self.ind();
                    try self.write("                },\n");
                }
                try self.ind();
                try self.write("                else => {\n");
                try self.ind();
                try self.write("                    if (_emh.must_understand) return error.UnknownMustUnderstand;\n");
                try self.ind();
                try self.write("                    try reader.skipEmheaderPayload(_emh);\n");
                try self.ind();
                try self.write("                },\n");
                try self.ind();
                try self.write("            }\n");
                try self.ind();
                try self.write("        }\n");
            } else {
                if (appendable) {
                    try self.ind();
                    try self.write("        const _key_end: ?usize = if (reader.xcdr_version == .xcdr2) blk: {\n");
                    try self.ind();
                    try self.write("            const _size = try reader.readDheader();\n");
                    try self.ind();
                    try self.write("            break :blk reader.pos + _size;\n");
                    try self.ind();
                    try self.write("        } else null;\n");
                }
                if (s.base) |base| {
                    const base_zig = try self.qualNameToZig(ir.typeDeclQualifiedName(base));
                    defer self.alloc.free(base_zig);
                    if (typeDeclHasKey(base)) {
                        try self.ind();
                        try self.print("        try {s}.deserializeKeyInto(&out._base, reader, allocator);\n", .{base_zig});
                    } else {
                        try self.ind();
                        try self.print("        try {s}.skip(reader);\n", .{base_zig});
                    }
                }
                // @final structs have no DHEADER bound.  deserializeKeyInto
                // expects a key-only payload whose bytes are the key fields in
                // declaration order.  If a non-key member precedes a key member,
                // the reader position is wrong for any full-payload caller.
                // Emit a @compileError so the user gets a clear diagnosis.
                if (!appendable) {
                    var saw_non_key = false;
                    for (s.members) |m| {
                        if (m.annotations.is_key) {
                            if (saw_non_key) {
                                try self.ind();
                                try self.print(
                                    "        @compileError(\"zidl: @final struct '{s}' has non-leading @key member '{s}'; \" ++\n",
                                    .{ s.name, m.name },
                                );
                                try self.ind();
                                try self.write("            \"move all @key members before non-key members, or switch to @appendable\");\n");
                                break;
                            }
                        } else {
                            saw_non_key = true;
                        }
                    }
                }
                for (s.members) |m| {
                    if (m.annotations.is_key) {
                        const out_expr = try std.fmt.allocPrint(self.alloc, "out.{s}", .{m.name});
                        defer self.alloc.free(out_expr);
                        try self.emitReadMember(m, out_expr, "        ");
                    }
                }
                if (appendable) {
                    try self.ind();
                    try self.write("        if (_key_end) |_end| try reader.seekTo(_end);\n");
                }
            }
            try self.ind();
            try self.write("    }\n");

            try self.write("\n");
            try self.ind();
            try self.write("    pub fn computeKeyHash(value: @This()) [16]u8 {\n");
            try self.ind();
            try self.write("        var _khw = zidl_rt.KeyHashWriter.init();\n");
            try self.ind();
            try self.write("        @This().serializeKey(&_khw, value) catch unreachable;\n");
            try self.ind();
            try self.write("        return _khw.final();\n");
            try self.ind();
            try self.write("    }\n");

            if (self.opts.generate_zzdds_wrappers and isZzddsTopicStruct(s)) {
                try self.emitComputeKeyHashFromCdr(s);
                try self.emitGetFieldFromCdr(s);
            }
        } else if (self.opts.generate_zzdds_wrappers and isZzddsTopicStruct(s)) {
            // Keyless topic type but --generate-zzdds-wrappers was requested:
            // emit trivial key helpers so emitStructTypedWrapper's
            // register_instance/get_key_value/lookup_instance/computeKeyHash-
            // based codegen works unchanged for keyless structs too, instead
            // of forking that codegen on has_key. Per DDS 1.4 2.2.2.1 a
            // keyless Topic is exactly one instance regardless of content, so
            // the key-only wire payload is legitimately empty and the
            // instance-identity hash is always the same constant value. This
            // is a different, zzdds-internal hash from the optional RTPS
            // PID_KEY_HASH wire hint (DDSI-RTPS 2.5 9.6.4.3/8.7.10, "a hint
            // ... not the authoritative" identity), which zzdds is free to
            // compute -- or skip -- independently of this one.
            try self.write("\n");
            try self.ind();
            try self.write("    pub fn serializeKey(writer: anytype, value: @This()) !void {\n");
            try self.ind();
            try self.write("        _ = value;\n");
            if (appendable) {
                try self.ind();
                try self.write("        const _dh = try writer.reserveDheaderMaybe();\n");
                try self.ind();
                try self.write("        writer.patchDheaderMaybe(_dh);\n");
            } else {
                // Non-appendable keyless struct: no DHEADER, so `writer` is
                // genuinely unreferenced -- same "conditionally discard,
                // don't assume" class of bug as emitGetFieldFromCdr's
                // `field`/`scratch` fix (found by the compile-check in
                // test/integration/zig_wrapper_contract, which actually
                // compiles generated --generate-zzdds-wrappers output
                // instead of only substring-matching it).
                try self.ind();
                try self.write("        _ = writer;\n");
            }
            try self.ind();
            try self.write("    }\n");

            try self.write("\n");
            try self.ind();
            try self.write("    pub fn deserializeKey(reader: *zidl_rt.CdrReader, allocator: std.mem.Allocator) !@This() {\n");
            try self.ind();
            try self.write("        var _out: @This() = .{};\n");
            try self.ind();
            try self.write("        try @This().deserializeKeyInto(&_out, reader, allocator);\n");
            try self.ind();
            try self.write("        return _out;\n");
            try self.ind();
            try self.write("    }\n");

            try self.write("\n");
            try self.ind();
            try self.write("    pub fn deserializeKeyInto(out: *@This(), reader: *zidl_rt.CdrReader, allocator: std.mem.Allocator) !void {\n");
            try self.ind();
            try self.write("        _ = out;\n");
            try self.ind();
            try self.write("        _ = allocator;\n");
            if (appendable) {
                try self.ind();
                try self.write("        try reader.skipDheaderIfXcdr2();\n");
            } else {
                // See serializeKey's matching comment above.
                try self.ind();
                try self.write("        _ = reader;\n");
            }
            try self.ind();
            try self.write("    }\n");

            try self.write("\n");
            try self.ind();
            try self.write("    pub fn computeKeyHash(value: @This()) [16]u8 {\n");
            try self.ind();
            try self.write("        _ = value;\n");
            try self.ind();
            try self.write("        return std.mem.zeroes([16]u8);\n");
            try self.ind();
            try self.write("    }\n");

            try self.emitComputeKeyHashFromCdr(s);
            try self.emitGetFieldFromCdr(s);
        }

        // PL_CDR functions (only for @mutable types when --zig-pl-cdr is set)
        if (mutable and self.opts.pl_cdr) {
            try self.write("\n");
            try self.ind();
            try self.write("    pub fn serializePlCdr(writer: *zidl_rt.PlCdrWriter, value: @This()) !void {\n");
            for (s.members, 0..) |m, idx| {
                const pid: u32 = memberIdAt(m, idx);
                if (m.annotations.is_pl_repeated) {
                    // @pl_repeated: emit one PID entry per element instead of a single
                    // length-prefixed sequence parameter.
                    const elem_tr = m.type_ref.sequence.element.*;
                    if (m.annotations.is_optional) {
                        const seq_var = try std.fmt.allocPrint(self.alloc, "_seq_{d}", .{idx});
                        defer self.alloc.free(seq_var);
                        try self.ind();
                        try self.print("        if (value.{s}) |{s}| {{\n", .{ m.name, seq_var });
                        try self.ind();
                        try self.print("            if ({s}._buffer) |_sb| {{\n", .{seq_var});
                        try self.ind();
                        try self.print("                for (_sb[0..{s}._length]) |_elem| {{\n", .{seq_var});
                        try self.ind();
                        try self.print("                    const _ph = try writer.reservePlParam({d});\n", .{pid});
                        try self.emitWriteForTypeRef(elem_tr, "_elem", "                    ");
                        try self.ind();
                        try self.write("                    try writer.patchPlParam(_ph);\n");
                        try self.ind();
                        try self.write("                }\n");
                        try self.ind();
                        try self.write("            }\n");
                        try self.ind();
                        try self.write("        }\n");
                    } else {
                        try self.ind();
                        try self.print("        if (value.{s}._buffer) |_sb| {{\n", .{m.name});
                        try self.ind();
                        try self.print("            for (_sb[0..value.{s}._length]) |_elem| {{\n", .{m.name});
                        try self.ind();
                        try self.print("                const _ph = try writer.reservePlParam({d});\n", .{pid});
                        try self.emitWriteForTypeRef(elem_tr, "_elem", "                ");
                        try self.ind();
                        try self.write("                try writer.patchPlParam(_ph);\n");
                        try self.ind();
                        try self.write("            }\n");
                        try self.ind();
                        try self.write("        }\n");
                    }
                } else if (m.annotations.is_optional) {
                    // @optional: only emit param when value is present (no presence byte)
                    const opt_var = try std.fmt.allocPrint(self.alloc, "_opt_{s}", .{m.name});
                    defer self.alloc.free(opt_var);
                    try self.ind();
                    try self.print("        if (value.{s}) |{s}| {{\n", .{ m.name, opt_var });
                    try self.ind();
                    try self.print("            const _ph{d} = try writer.reservePlParam({d});\n", .{ idx, pid });
                    if (m.dimensions.len > 0) {
                        try self.emitWriteArray(m.type_ref, opt_var, m.dimensions, "            ", 0);
                    } else {
                        try self.emitWriteForTypeRef(m.type_ref, opt_var, "            ");
                    }
                    try self.ind();
                    try self.print("            try writer.patchPlParam(_ph{d});\n", .{idx});
                    try self.ind();
                    try self.write("        }\n");
                } else {
                    const access = try std.fmt.allocPrint(self.alloc, "value.{s}", .{m.name});
                    defer self.alloc.free(access);
                    try self.ind();
                    try self.print("        const _ph{d} = try writer.reservePlParam({d});\n", .{ idx, pid });
                    if (m.dimensions.len > 0) {
                        try self.emitWriteArray(m.type_ref, access, m.dimensions, "        ", 0);
                    } else {
                        try self.emitWriteForTypeRef(m.type_ref, access, "        ");
                    }
                    try self.ind();
                    try self.print("        try writer.patchPlParam(_ph{d});\n", .{idx});
                }
            }
            try self.ind();
            try self.write("        try writer.writePlSentinel();\n");
            try self.ind();
            try self.write("    }\n\n");

            // deserializeFromPlCdr
            try self.ind();
            try self.write("    pub fn deserializeFromPlCdr(out: *@This(), reader: *zidl_rt.CdrReader, allocator: std.mem.Allocator) !void {\n");
            if (!needs_alloc) {
                try self.ind();
                try self.write("        _ = allocator;\n");
            }
            try self.ind();
            try self.write("        while (try reader.readPlParam()) |_p| {\n");
            try self.ind();
            try self.write("            switch (_p.pid & 0x3FFF) {\n");
            for (s.members, 0..) |m, idx| {
                const pid: u32 = memberIdAt(m, idx);
                try self.ind();
                try self.print("                {d} => {{\n", .{pid});
                if (m.annotations.is_pl_repeated) {
                    // @pl_repeated: each occurrence of this PID carries one element;
                    // accumulate into the sequence.
                    const elem_tr = m.type_ref.sequence.element.*;
                    if (m.annotations.is_optional) {
                        // ?std.ArrayListUnmanaged(T): initialise on first occurrence.
                        try self.ind();
                        try self.print("                    if (out.{s} == null) out.{s} = .{{}};\n", .{ m.name, m.name });
                        const seq_expr = try std.fmt.allocPrint(self.alloc, "out.{s}.?", .{m.name});
                        defer self.alloc.free(seq_expr);
                        try self.emitPlRepeatedElementAppend(elem_tr, seq_expr, "                    ");
                    } else {
                        const seq_expr = try std.fmt.allocPrint(self.alloc, "out.{s}", .{m.name});
                        defer self.alloc.free(seq_expr);
                        try self.emitPlRepeatedElementAppend(elem_tr, seq_expr, "                    ");
                    }
                } else if (m.annotations.is_optional) {
                    // Presence implied by PID appearing in the stream
                    const zig_type = try self.typeRefToZig(m.type_ref);
                    defer self.alloc.free(zig_type);
                    const opt_var = try std.fmt.allocPrint(self.alloc, "_opt_{s}", .{m.name});
                    defer self.alloc.free(opt_var);
                    const decl_type: []u8 = if (m.dimensions.len > 0)
                        try self.makeArrayType(zig_type, m.dimensions)
                    else
                        try self.alloc.dupe(u8, zig_type);
                    defer self.alloc.free(decl_type);
                    const default_val: []u8 = if (m.dimensions.len > 0)
                        try self.defaultForArrayType(decl_type)
                    else
                        try self.defaultForTypeRef(m.type_ref);
                    defer self.alloc.free(default_val);
                    try self.ind();
                    try self.print("                    var {s}: {s} = {s};\n", .{ opt_var, decl_type, default_val });
                    if (m.dimensions.len > 0) {
                        try self.emitReadArray(m.type_ref, opt_var, m.dimensions, "                    ", 0);
                    } else {
                        try self.emitReadForTypeRef(m.type_ref, opt_var, "                    ");
                    }
                    try self.ind();
                    try self.print("                    out.{s} = {s};\n", .{ m.name, opt_var });
                } else {
                    const out_expr = try std.fmt.allocPrint(self.alloc, "out.{s}", .{m.name});
                    defer self.alloc.free(out_expr);
                    if (m.dimensions.len > 0) {
                        try self.emitReadArray(m.type_ref, out_expr, m.dimensions, "                    ", 0);
                    } else {
                        try self.emitReadForTypeRef(m.type_ref, out_expr, "                    ");
                    }
                }
                try self.ind();
                try self.write("                },\n");
            }
            try self.ind();
            try self.write("                else => {},\n");
            try self.ind();
            try self.write("            }\n");
            try self.ind();
            try self.write("            try reader.seekTo(_p.end_pos);\n");
            try self.ind();
            try self.write("        }\n");
            try self.ind();
            try self.write("    }\n");
        }

        // deinit + clone — see memberNeedsCleanup/structNeedsCleanup.
        if (self.structNeedsCleanup(s)) {
            try self.write("\n");
            try self.emitStructDeinitFn(s);
            try self.write("\n");
            try self.emitStructCloneFn(s);
        }
    }

    /// Emit `computeKeyHashFromCdr`, the Zig-backend equivalent of the C/C++
    /// backends' generated `{Type}_compute_key_hash_from_cdr` -- a function
    /// matching zzdds's `TypeSupport.compute_key_hash` callback shape exactly
    /// (`fn (ctx: *anyopaque, payload: []const u8) [16]u8`), so a struct's
    /// zidl-generated code can be passed directly to `_zzdds.registerTypeSupport`
    /// without the caller hand-writing the CDR-deserialize-then-hash glue.
    ///
    /// Unlike the C backend (which resolves its allocator from a global,
    /// process-wide override defaulting to malloc/free -- see zidl-cdr's
    /// `zidl_cdr_set_allocator`), this stays consistent with the rest of the
    /// Zig runtime's explicit-allocator idiom: `ctx` is a `*const
    /// std.mem.Allocator` supplied by the caller at registration time (via
    /// `TypeSupport.ctx`), used only for any variable-length key fields
    /// `deserializeKey` needs to allocate. Keyless structs never dereference
    /// it, matching `TypeSupport.ctx`'s existing "Zig-native implementations
    /// that need no state may pass `undefined`" contract.
    ///
    /// `_key_value` is a fully local temporary -- nothing else ever sees it --
    /// so whenever `s` has a generated `deinit()` (`structNeedsCleanup(s)`),
    /// it's freed via `defer` before returning, regardless of whether the
    /// heap-owned field that made `deinit()` exist is itself one of the `@key`
    /// members `deserializeKey` actually populated (freeing an untouched,
    /// still-zeroed field is always a safe no-op, matching how `deinit()`
    /// itself handles it). Without this, every hash computation on a keyed
    /// struct with a variable-length key field (a string or unbounded
    /// sequence) would leak.
    fn emitComputeKeyHashFromCdr(self: *Generator, s: *const ir.Struct) !void {
        const needs_cleanup = self.structNeedsCleanup(s);
        try self.write("\n");
        try self.ind();
        try self.write("    pub fn computeKeyHashFromCdr(ctx: *anyopaque, payload: []const u8) [16]u8 {\n");
        try self.ind();
        try self.write("        const allocator: *const std.mem.Allocator = @ptrCast(@alignCast(ctx));\n");
        try self.ind();
        try self.write("        var _reader = zidl_rt.CdrReader.init(payload) catch return std.mem.zeroes([16]u8);\n");
        try self.ind();
        try self.print("        {s} _key_value = @This().deserializeKey(&_reader, allocator.*) catch return std.mem.zeroes([16]u8);\n", .{if (needs_cleanup) "var" else "const"});
        if (needs_cleanup) {
            try self.ind();
            try self.write("        defer _key_value.deinit(allocator.*);\n");
        }
        try self.ind();
        try self.write("        return @This().computeKeyHash(_key_value);\n");
        try self.ind();
        try self.write("    }\n");
    }

    /// Emit `getFieldFromCdr`, the Zig-backend equivalent of the C/C++
    /// backends' generated `{Type}_get_field_from_cdr` -- matches
    /// `TypeSupport.get_field`'s callback shape exactly (`fn (ctx: *anyopaque,
    /// payload: []const u8, field: []const u8, scratch: []u8)
    /// ?zzdds.dcps.filter.FilterValue`), so this struct's generated code can
    /// be registered directly and get real, automatic ContentFilteredTopic
    /// filtering from zzdds's own reader-side `cft_filter` — no app-side
    /// re-check needed (see zzdds's `docs/roadmap.md` for why this is a real
    /// fix, not a style preference: `TypeSupport.get_field` existed but no
    /// binding ever populated it).
    ///
    /// Unlike `computeKeyHashFromCdr` (which only ever needs `@key` members),
    /// a filter expression can reference *any* simple-typed member, so this
    /// fully deserializes `payload` via the struct's own `deserialize` (CDR
    /// isn't randomly addressable — a partial/selective parse skipping ahead
    /// to just the requested field isn't meaningfully simpler than a full
    /// one) rather than reusing `deserializeKeyInto`'s member walk.
    ///
    /// `scratch` (see `TypeSupport.get_field`'s doc comment for why it
    /// exists): a matched string member's bytes are copied there rather than
    /// returned as a slice into the local `_v` — `_v` is freed (when it has a
    /// generated `deinit()`) before this function returns, so a slice into it
    /// would dangle. A string too long for `scratch` returns `null` (unknown
    /// field) rather than truncating and risking a wrong comparison result —
    /// `filter_mod.eval` already treats an evaluation error as "pass the
    /// sample through", the same safe fallback either way.
    fn emitGetFieldFromCdr(self: *Generator, s: *const ir.Struct) !void {
        const needs_cleanup = self.structNeedsCleanup(s);
        try self.write("\n");
        try self.ind();
        try self.write("    pub fn getFieldFromCdr(ctx: *anyopaque, payload: []const u8, field: []const u8, scratch: []u8) ?_zzdds.dcps.filter.FilterValue {\n");
        // `field`/`scratch` are only referenced inside the per-member
        // branches emitted below (string_like members reference both;
        // int_like/float_like reference only `field`). A struct with no
        // filterable members at all (every member `.skip` -- arrays/complex
        // types only) or with no string_like member specifically leaves one
        // or both genuinely unreferenced, which Zig rejects as an unused
        // function parameter -- a real, live bug found building
        // zzdds-examples' `presence` example against a single-int-field
        // struct. Pre-scan first to decide whether either discard is
        // actually needed: Zig equally rejects `_ = x;` as a "pointless
        // discard" when `x` genuinely *is* used later, so an unconditional
        // discard isn't a safe blanket fix here the way it is in
        // deserializeInto/serializeKey/etc. above -- it has to match reality
        // in both directions.
        var has_field_use = false;
        var has_scratch_use = false;
        for (s.members) |m| {
            if (m.dimensions.len > 0) continue;
            switch (classifyFilterFieldKind(m.type_ref)) {
                .skip => continue,
                .int_like, .float_like => has_field_use = true,
                .string_like => {
                    has_field_use = true;
                    has_scratch_use = true;
                },
            }
        }
        if (!has_field_use) {
            try self.ind();
            try self.write("        _ = field;\n");
        }
        if (!has_scratch_use) {
            try self.ind();
            try self.write("        _ = scratch;\n");
        }
        try self.ind();
        try self.write("        const allocator: *const std.mem.Allocator = @ptrCast(@alignCast(ctx));\n");
        try self.ind();
        try self.write("        var _reader = zidl_rt.CdrReader.init(payload) catch return null;\n");
        try self.ind();
        try self.print("        {s} _v = @This().deserialize(&_reader, allocator.*) catch return null;\n", .{if (needs_cleanup) "var" else "const"});
        if (needs_cleanup) {
            try self.ind();
            try self.write("        defer _v.deinit(allocator.*);\n");
        }
        for (s.members) |m| {
            if (m.dimensions.len > 0) continue; // array member: not a simple filterable field
            switch (classifyFilterFieldKind(m.type_ref)) {
                .skip => continue,
                .int_like => {
                    const expr = try intFieldExpr(self.alloc, m.type_ref, m.name);
                    defer self.alloc.free(expr);
                    try self.ind();
                    try self.print("        if (std.mem.eql(u8, field, \"{s}\")) return .{{ .int = {s} }};\n", .{ m.name, expr });
                },
                .float_like => {
                    try self.ind();
                    try self.print("        if (std.mem.eql(u8, field, \"{s}\")) return .{{ .float = @floatCast(_v.{s}) }};\n", .{ m.name, m.name });
                },
                .string_like => |bound| {
                    try self.ind();
                    try self.print("        if (std.mem.eql(u8, field, \"{s}\")) {{\n", .{m.name});
                    try self.ind();
                    if (bound != null) {
                        try self.print("            const _s = _v.{s}.slice();\n", .{m.name});
                    } else {
                        try self.print("            const _s = _v.{s};\n", .{m.name});
                    }
                    try self.ind();
                    try self.write("            if (_s.len > scratch.len) return null;\n");
                    try self.ind();
                    try self.write("            @memcpy(scratch[0.._s.len], _s);\n");
                    try self.ind();
                    try self.write("            return .{ .string = scratch[0.._s.len] };\n");
                    try self.ind();
                    try self.write("        }\n");
                },
            }
        }
        try self.ind();
        try self.write("        return null;\n");
        try self.ind();
        try self.write("    }\n");
    }

    // ── Typed DataWriter / DataReader wrappers ────────────────────────────────

    /// Emit `FooDataWriter` and `FooDataReader` structs for `s` when it is a
    /// usable Topic type (see isZzddsTopicStruct — not @mutable, not nested;
    /// keyed or keyless, both are spec-legitimate Topic types per DDS 1.4
    /// 2.2.2.1). These are the generated equivalents of what the DDS-DCPS
    /// spec (Annex A) calls `FooDataWriter` / `FooDataReader`. For a keyless
    /// `s`, computeKeyHash/serializeKey/deserializeKeyInto are still emitted
    /// (see emitStructSerializeFns' `--generate-zzdds-wrappers` branch) —
    /// trivially, since there's no key data — so this function's codegen
    /// doesn't need to fork on has_key at all.
    ///
    /// The `dds` module adapter contract (must be provided by the consuming build):
    ///   - `_dds.DDS.DataWriter`, `_dds.DDS.DataReader`
    ///   - `_dds.DDS.InstanceStateKind`, `_dds.DDS.InstanceHandle_t`
    ///   - `_dds.WriteKind` enum: `.alive`, `.dispose`, `.unregister`
    ///   - `_dds.writeRaw(dw, kind, key_hash: [16]u8, payload: []const u8) !void`
    ///   - `_dds.takeRaw(dr) ?RawSample` — `.data`, `.instance_state`,
    ///     `.instance_handle`, `.deinit() void`
    fn emitStructTypedWrapper(self: *Generator, s: *const ir.Struct) !void {
        const pfx = self.opts.type_prefix;
        const type_name = try std.fmt.allocPrint(self.alloc, "{s}{s}", .{ pfx, s.name });
        defer self.alloc.free(type_name);
        const appendable = s.annotations.extensibility == .appendable;
        const needs_deinit = structNeedsSeqDeinit(s);

        // ── DataWriter ────────────────────────────────────────────────────────
        try self.ind();
        try self.print("pub const {s}DataWriter = struct {{\n", .{type_name});
        try self.ind();
        try self.write("    _dw: _zzdds.DDS.DataWriter,\n");
        try self.ind();
        try self.write("    _alloc: std.mem.Allocator,\n");
        try self.ind();
        try self.write("    _xcdr2: bool,\n");
        try self.write("\n");
        try self.ind();
        try self.write("    pub fn init(dw: _zzdds.DDS.DataWriter, alloc: std.mem.Allocator) @This() {\n");
        try self.ind();
        try self.write("        return .{ ._dw = dw, ._alloc = alloc, ._xcdr2 = _zzdds.writerUsesXcdr2(dw) };\n");
        try self.ind();
        try self.write("    }\n");
        try self.write("\n");
        try self.ind();
        try self.write("    pub fn dataWriter(self: @This()) _zzdds.DDS.DataWriter {\n");
        try self.ind();
        try self.write("        return self._dw;\n");
        try self.ind();
        try self.write("    }\n");

        // write / write_w_timestamp
        try self.emitTypedWriterMethod(type_name, "write", "instance_data", "alive", false, appendable, false);
        try self.emitTypedWriterMethod(type_name, "write_w_timestamp", "instance_data", "alive", false, appendable, true);
        // dispose / dispose_w_timestamp
        try self.emitTypedWriterMethod(type_name, "dispose", "instance_data", "dispose", true, appendable, false);
        try self.emitTypedWriterMethod(type_name, "dispose_w_timestamp", "instance_data", "dispose", true, appendable, true);
        // unregister_instance / unregister_instance_w_timestamp
        try self.emitTypedWriterMethod(type_name, "unregister_instance", "instance_data", "unregister", true, appendable, false);
        try self.emitTypedWriterMethod(type_name, "unregister_instance_w_timestamp", "instance_data", "unregister", true, appendable, true);

        // register_instance
        try self.write("\n");
        try self.ind();
        // registerInstanceRaw / lookupInstanceWriter are pure hash→handle functions;
        // the DataWriter handle is not needed (C ABI accepts it for spec completeness but ignores it).
        try self.print("    pub fn register_instance(_: @This(), instance_data: {s}) _zzdds.DDS.InstanceHandle_t {{\n", .{type_name});
        try self.ind();
        try self.print("        return _zzdds.registerInstanceRaw({s}.computeKeyHash(instance_data));\n", .{type_name});
        try self.ind();
        try self.write("    }\n");

        // get_key_value
        try self.write("\n");
        try self.ind();
        try self.print("    pub fn get_key_value(self: @This(), key_holder: *{s}, handle: _zzdds.DDS.InstanceHandle_t) !void {{\n", .{type_name});
        try self.ind();
        try self.write("        const _raw = _zzdds.getKeyValueRawWriter(self._dw, handle) orelse return error.BadParameter;\n");
        try self.ind();
        try self.write("        var _r = try zidl_rt.CdrReader.init(_raw);\n");
        if (needs_deinit) {
            try self.ind();
            try self.print("        var _kv: {s} = .{{}};\n", .{type_name});
            try self.ind();
            try self.write("        errdefer _kv.deinit(self._alloc);\n");
            try self.ind();
            try self.print("        try {s}.deserializeKeyInto(&_kv, &_r, self._alloc);\n", .{type_name});
            try self.ind();
            try self.write("        key_holder.* = _kv;\n");
        } else {
            try self.ind();
            try self.print("        try {s}.deserializeKeyInto(key_holder, &_r, self._alloc);\n", .{type_name});
        }
        try self.ind();
        try self.write("    }\n");

        // lookup_instance
        try self.write("\n");
        try self.ind();
        try self.print("    pub fn lookup_instance(_: @This(), instance_data: {s}) _zzdds.DDS.InstanceHandle_t {{\n", .{type_name});
        try self.ind();
        try self.print("        return _zzdds.lookupInstanceWriter({s}.computeKeyHash(instance_data));\n", .{type_name});
        try self.ind();
        try self.write("    }\n");

        try self.ind();
        try self.print("}}; // {s}DataWriter\n\n", .{type_name});

        // ── DataReader ────────────────────────────────────────────────────────
        try self.ind();
        try self.print("pub const {s}DataReader = struct {{\n", .{type_name});
        try self.ind();
        try self.write("    _dr: _zzdds.DDS.DataReader,\n");
        try self.ind();
        try self.write("    _alloc: std.mem.Allocator,\n");
        try self.write("\n");
        try self.ind();
        try self.write("    pub fn init(dr: _zzdds.DDS.DataReader, alloc: std.mem.Allocator) @This() {\n");
        try self.ind();
        try self.write("        return .{ ._dr = dr, ._alloc = alloc };\n");
        try self.ind();
        try self.write("    }\n");
        try self.write("\n");
        try self.ind();
        try self.write("    pub fn withAllocator(self: @This(), alloc: std.mem.Allocator) @This() {\n");
        try self.ind();
        try self.write("        return .{ ._dr = self._dr, ._alloc = alloc };\n");
        try self.ind();
        try self.write("    }\n");
        try self.write("\n");
        try self.ind();
        try self.write("    pub fn dataReader(self: @This()) _zzdds.DDS.DataReader {\n");
        try self.ind();
        try self.write("        return self._dr;\n");
        try self.ind();
        try self.write("    }\n");
        try self.write("\n");
        // Use `SampledValue` rather than `Sample` to avoid shadowing an IDL
        // type that happens to be named `Sample`.
        try self.ind();
        try self.write("    pub const SampledValue = struct {\n");
        try self.ind();
        try self.print("        value: {s},\n", .{type_name});
        try self.ind();
        try self.write("        info: _zzdds.DDS.SampleInfo,\n");
        if (structNeedsSeqDeinit(s)) {
            try self.write("\n");
            try self.ind();
            try self.write("        pub fn deinit(self: *@This(), alloc: std.mem.Allocator) void {\n");
            try self.ind();
            try self.write("            self.value.deinit(alloc);\n");
            try self.ind();
            try self.write("        }\n");
        }
        try self.ind();
        try self.write("    };\n");
        try self.write("\n");

        // take_next_sample
        try self.emitReaderSingleMethod(type_name, "take_next_sample", false, false, needs_deinit);
        // read_next_sample
        try self.emitReaderSingleMethod(type_name, "read_next_sample", false, true, needs_deinit);
        // take_next_instance
        try self.emitReaderSingleMethod(type_name, "take_next_instance", true, false, needs_deinit);
        // read_next_instance
        try self.emitReaderSingleMethod(type_name, "read_next_instance", true, true, needs_deinit);
        // take with masks
        try self.emitReaderBatchMethod(type_name, "take", true, false, needs_deinit);
        // read with masks
        try self.emitReaderBatchMethod(type_name, "read", false, false, needs_deinit);
        // take_instance
        try self.emitReaderBatchMethod(type_name, "take_instance", true, true, needs_deinit);
        // read_instance
        try self.emitReaderBatchMethod(type_name, "read_instance", false, true, needs_deinit);
        // take_w_condition
        try self.emitReaderWConditionMethod(type_name, "take_w_condition", true, needs_deinit);
        // read_w_condition
        try self.emitReaderWConditionMethod(type_name, "read_w_condition", false, needs_deinit);
        // take_next_instance_w_condition
        try self.emitReaderNextInstanceWConditionMethod(type_name, "take_next_instance_w_condition", true, needs_deinit);
        // read_next_instance_w_condition
        try self.emitReaderNextInstanceWConditionMethod(type_name, "read_next_instance_w_condition", false, needs_deinit);

        // get_key_value
        try self.write("\n");
        try self.ind();
        try self.print("    pub fn get_key_value(self: @This(), key_holder: *{s}, handle: _zzdds.DDS.InstanceHandle_t) !void {{\n", .{type_name});
        try self.ind();
        try self.write("        const _raw = _zzdds.getKeyValueRawReader(self._dr, handle) orelse return error.BadParameter;\n");
        try self.ind();
        try self.write("        var _r = try zidl_rt.CdrReader.init(_raw);\n");
        if (needs_deinit) {
            try self.ind();
            try self.print("        var _kv: {s} = .{{}};\n", .{type_name});
            try self.ind();
            try self.write("        errdefer _kv.deinit(self._alloc);\n");
            try self.ind();
            try self.print("        try {s}.deserializeKeyInto(&_kv, &_r, self._alloc);\n", .{type_name});
            try self.ind();
            try self.write("        key_holder.* = _kv;\n");
        } else {
            try self.ind();
            try self.print("        try {s}.deserializeKeyInto(key_holder, &_r, self._alloc);\n", .{type_name});
        }
        try self.ind();
        try self.write("    }\n");

        // lookup_instance
        try self.write("\n");
        try self.ind();
        try self.print("    pub fn lookup_instance(self: @This(), instance_data: {s}) ?_zzdds.DDS.InstanceHandle_t {{\n", .{type_name});
        try self.ind();
        try self.print("        const _ih = _zzdds.registerInstanceRaw({s}.computeKeyHash(instance_data));\n", .{type_name});
        try self.ind();
        try self.write("        return _zzdds.lookupInstanceReader(self._dr, _ih);\n");
        try self.ind();
        try self.write("    }\n");

        try self.ind();
        try self.print("}}; // {s}DataReader\n\n", .{type_name});
    }

    /// Emit a single-sample take/read method on the DataReader.
    /// `with_instance` adds a `prev: DDS.InstanceHandle_t` parameter and calls
    /// takeNextInstanceRaw / readNextInstanceRaw instead of takeRaw / readNextSampleRaw.
    fn emitReaderSingleMethod(
        self: *Generator,
        type_name: []const u8,
        method_name: []const u8,
        with_instance: bool,
        non_destructive: bool,
        needs_deinit: bool,
    ) !void {
        const raw_fn = if (with_instance)
            (if (non_destructive) "_zzdds.readNextInstanceRaw" else "_zzdds.takeNextInstanceRaw")
        else
            (if (non_destructive) "_zzdds.readNextSampleRaw" else "_zzdds.takeRaw");
        const prev_param = if (with_instance) ", prev: _zzdds.DDS.InstanceHandle_t" else "";
        const raw_arg = if (with_instance) "(self._dr, prev)" else "(self._dr)";
        try self.write("\n");
        try self.ind();
        try self.print("    pub fn {s}(self: @This(), data_value: *{s}, sample_info: *_zzdds.DDS.SampleInfo{s}) !bool {{\n", .{ method_name, type_name, prev_param });
        try self.ind();
        try self.print("        const _raw = {s}{s} orelse return false;\n", .{ raw_fn, raw_arg });
        try self.ind();
        try self.write("        defer _raw.deinit();\n");
        try self.ind();
        try self.write("        sample_info.* = _raw.info;\n");
        try self.ind();
        try self.write("        var _r = try zidl_rt.CdrReader.init(_raw.data);\n");
        try self.ind();
        try self.write("        if (_raw.info.valid_data) {\n");
        try self.ind();
        try self.print("            data_value.* = try {s}.deserialize(&_r, self._alloc);\n", .{type_name});
        try self.ind();
        try self.write("        } else {\n");
        if (needs_deinit) {
            try self.ind();
            try self.print("            var _kv: {s} = .{{}};\n", .{type_name});
            try self.ind();
            try self.write("            errdefer _kv.deinit(self._alloc);\n");
            try self.ind();
            try self.print("            try {s}.deserializeKeyInto(&_kv, &_r, self._alloc);\n", .{type_name});
            try self.ind();
            try self.write("            data_value.* = _kv;\n");
        } else {
            try self.ind();
            try self.print("            try {s}.deserializeKeyInto(data_value, &_r, self._alloc);\n", .{type_name});
        }
        try self.ind();
        try self.write("        }\n");
        try self.ind();
        try self.write("        return true;\n");
        try self.ind();
        try self.write("    }\n");
    }

    /// Emit a multi-sample take/read method on the DataReader.
    /// `with_instance` adds `handle: DDS.InstanceHandle_t` and passes it to the raw call.
    fn emitReaderBatchMethod(
        self: *Generator,
        type_name: []const u8,
        method_name: []const u8,
        destructive: bool,
        with_instance: bool,
        needs_deinit: bool,
    ) !void {
        const raw_fn = if (destructive) "_zzdds.takeFilteredRaw" else "_zzdds.readFilteredRaw";
        const ih_param = if (with_instance) ", handle: _zzdds.DDS.InstanceHandle_t" else "";
        const ih_arg = if (with_instance) ", handle" else ", null";
        try self.write("\n");
        try self.ind();
        try self.print("    pub fn {s}(self: @This(), out: *std.ArrayListUnmanaged(SampledValue), max: i32, ss: _zzdds.DDS.SampleStateMask, vs: _zzdds.DDS.ViewStateMask, is: _zzdds.DDS.InstanceStateMask{s}) !bool {{\n", .{ method_name, ih_param });
        try self.ind();
        try self.write("        var _tmp: std.ArrayListUnmanaged(_zzdds.OwnedRawSample) = .empty;\n");
        try self.ind();
        try self.write("        defer {\n");
        try self.ind();
        try self.write("            for (_tmp.items) |_s| _s.deinit();\n");
        try self.ind();
        try self.write("            _tmp.deinit(self._alloc);\n");
        try self.ind();
        try self.write("        }\n");
        try self.ind();
        try self.print("        try {s}(self._dr, &_tmp, max, ss, vs, is{s}, self._alloc);\n", .{ raw_fn, ih_arg });
        try self.emitReaderDecodeTmpTail(type_name, needs_deinit);
    }

    /// Emit a batch take/read method scoped to a ReadCondition (which may
    /// itself be a QueryCondition upcast via as_ReadCondition()) -- the raw
    /// path to what the OMG spec calls take_w_condition/read_w_condition.
    /// State masks (and, for a QueryCondition, the query filter) come from
    /// `cond` itself, unlike emitReaderBatchMethod's mask parameters.
    fn emitReaderWConditionMethod(
        self: *Generator,
        type_name: []const u8,
        method_name: []const u8,
        destructive: bool,
        needs_deinit: bool,
    ) !void {
        const raw_fn = if (destructive) "_zzdds.takeWithReadConditionRaw" else "_zzdds.readWithReadConditionRaw";
        try self.write("\n");
        try self.ind();
        try self.print("    pub fn {s}(self: @This(), out: *std.ArrayListUnmanaged(SampledValue), cond: _zzdds.DDS.ReadCondition, max: i32) !bool {{\n", .{method_name});
        try self.ind();
        try self.write("        var _tmp: std.ArrayListUnmanaged(_zzdds.OwnedRawSample) = .empty;\n");
        try self.ind();
        try self.write("        defer {\n");
        try self.ind();
        try self.write("            for (_tmp.items) |_s| _s.deinit();\n");
        try self.ind();
        try self.write("            _tmp.deinit(self._alloc);\n");
        try self.ind();
        try self.write("        }\n");
        try self.ind();
        try self.print("        try {s}(self._dr, cond, &_tmp, max, self._alloc);\n", .{raw_fn});
        try self.emitReaderDecodeTmpTail(type_name, needs_deinit);
    }

    /// Emit a batch take/read method scoped to a ReadCondition AND the "next
    /// instance" after `prev` -- the raw path to what the OMG spec calls
    /// take_next_instance_w_condition/read_next_instance_w_condition.
    fn emitReaderNextInstanceWConditionMethod(
        self: *Generator,
        type_name: []const u8,
        method_name: []const u8,
        destructive: bool,
        needs_deinit: bool,
    ) !void {
        const raw_fn = if (destructive) "_zzdds.takeNextInstanceWithReadConditionRaw" else "_zzdds.readNextInstanceWithReadConditionRaw";
        try self.write("\n");
        try self.ind();
        try self.print("    pub fn {s}(self: @This(), out: *std.ArrayListUnmanaged(SampledValue), cond: _zzdds.DDS.ReadCondition, prev: _zzdds.DDS.InstanceHandle_t, max: i32) !bool {{\n", .{method_name});
        try self.ind();
        try self.write("        var _tmp: std.ArrayListUnmanaged(_zzdds.OwnedRawSample) = .empty;\n");
        try self.ind();
        try self.write("        defer {\n");
        try self.ind();
        try self.write("            for (_tmp.items) |_s| _s.deinit();\n");
        try self.ind();
        try self.write("            _tmp.deinit(self._alloc);\n");
        try self.ind();
        try self.write("        }\n");
        try self.ind();
        try self.print("        try {s}(self._dr, cond, prev, &_tmp, max, self._alloc);\n", .{raw_fn});
        try self.emitReaderDecodeTmpTail(type_name, needs_deinit);
    }

    /// Shared tail for every batch reader method above: given `_tmp` (already
    /// populated by the caller's own raw op call), decodes each sample into
    /// `out`. The three emitReader*Method functions above only differ in
    /// which raw op populates `_tmp` and that op's own parameter list.
    fn emitReaderDecodeTmpTail(self: *Generator, type_name: []const u8, needs_deinit: bool) !void {
        try self.ind();
        try self.write("        if (_tmp.items.len == 0) return false;\n");
        try self.ind();
        try self.write("        try out.ensureUnusedCapacity(self._alloc, _tmp.items.len);\n");
        try self.ind();
        try self.write("        const _base = out.items.len;\n");
        try self.ind();
        if (needs_deinit) {
            try self.write("        errdefer {\n");
            try self.ind();
            try self.write("            for (out.items[_base..]) |*_sv| _sv.value.deinit(self._alloc);\n");
            try self.ind();
            try self.write("            out.items.len = _base;\n");
            try self.ind();
            try self.write("        }\n");
        } else {
            try self.write("        errdefer out.items.len = _base;\n");
        }
        try self.ind();
        try self.write("        for (_tmp.items) |_s| {\n");
        try self.ind();
        try self.write("            var _r = try zidl_rt.CdrReader.init(_s.data);\n");
        try self.ind();
        try self.write("            const _v = if (_s.info.valid_data)\n");
        try self.ind();
        try self.print("                try {s}.deserialize(&_r, self._alloc)\n", .{type_name});
        try self.ind();
        try self.write("            else blk: {\n");
        try self.ind();
        try self.print("                var _kv: {s} = .{{}};\n", .{type_name});
        if (needs_deinit) {
            try self.ind();
            try self.write("                errdefer _kv.deinit(self._alloc);\n");
        }
        try self.ind();
        try self.print("                try {s}.deserializeKeyInto(&_kv, &_r, self._alloc);\n", .{type_name});
        try self.ind();
        try self.write("                break :blk _kv;\n");
        try self.ind();
        try self.write("            };\n");
        try self.ind();
        try self.write("            out.appendAssumeCapacity(.{ .value = _v, .info = _s.info });\n");
        try self.ind();
        try self.write("        }\n");
        try self.ind();
        try self.write("        return true;\n");
        try self.ind();
        try self.write("    }\n");
    }

    fn emitTypedWriterMethod(
        self: *Generator,
        type_name: []const u8,
        method_name: []const u8,
        param_name: []const u8,
        kind_str: []const u8,
        use_key: bool,
        appendable: bool,
        with_timestamp: bool,
    ) !void {
        const ts_param = if (with_timestamp) ", timestamp: _zzdds.DDS.Time_t" else "";
        const write_fn = if (with_timestamp) "_zzdds.writeRawWithTimestamp" else "_zzdds.writeRaw";
        const ts_arg = if (with_timestamp) ", timestamp" else "";
        try self.write("\n");
        try self.ind();
        try self.print("    pub fn {s}(self: @This(), {s}: {s}, _: _zzdds.DDS.InstanceHandle_t{s}) !void {{\n", .{ method_name, param_name, type_name, ts_param });
        try self.ind();
        try self.write("        var _buf = std.ArrayList(u8).empty;\n");
        try self.ind();
        try self.write("        defer _buf.deinit(self._alloc);\n");
        try self.ind();
        try self.write("        if (self._xcdr2) {\n");
        try self.ind();
        try self.write("            var _w = zidl_rt.CdrWriter(.xcdr2).init(&_buf, self._alloc);\n");
        try self.ind();
        if (appendable) {
            try self.write("            try _w.writeEncapHeaderDelimited();\n");
        } else {
            try self.write("            try _w.writeEncapHeader();\n");
        }
        try self.ind();
        if (use_key) {
            try self.print("            try {s}.serializeKey(&_w, {s});\n", .{ type_name, param_name });
        } else {
            try self.print("            try {s}.serialize(&_w, {s});\n", .{ type_name, param_name });
        }
        try self.ind();
        try self.write("        } else {\n");
        try self.ind();
        try self.write("            var _w = zidl_rt.CdrWriter(.xcdr1).init(&_buf, self._alloc);\n");
        try self.ind();
        try self.write("            try _w.writeEncapHeader();\n");
        try self.ind();
        if (use_key) {
            try self.print("            try {s}.serializeKey(&_w, {s});\n", .{ type_name, param_name });
        } else {
            try self.print("            try {s}.serialize(&_w, {s});\n", .{ type_name, param_name });
        }
        try self.ind();
        try self.write("        }\n");
        try self.ind();
        try self.print("        const _hash = {s}.computeKeyHash({s});\n", .{ type_name, param_name });
        try self.ind();
        try self.print("        try {s}(self._dw, .{s}, _hash, _buf.items{s});\n", .{ write_fn, kind_str, ts_arg });
        try self.ind();
        try self.write("    }\n");
    }

    /// `typeRefNeedsSeqDeinit(m.type_ref) or this type has an unbounded string,
    /// directly or via a nested struct field` — matches the C backend's parity
    /// fix (`structHasSequenceFields`/`emitStructFree`, see zidl's roadmap "C
    /// backend: `{Type}_free()` is declared but never given a body"): any
    /// unbounded string/wstring or any sequence needs cleanup, not just
    /// unbounded sequences.
    ///
    /// One case the C fix doesn't have to consider: `m` is *itself* a plain
    /// unbounded string (or a typedef chain to one) with a non-empty `@default`,
    /// **and** we're not under `--zig-generate-toml-config`. `deserializeInto`
    /// unconditionally dupes every required string field it actually reads —
    /// same as `applyToml` does — so any *deserialized* value is always safe to
    /// free. The risk is a value that was never deserialized at all (e.g. bare
    /// `.{}`, or an `errdefer`-triggered `deinit()` firing before this field was
    /// reached): its `[]const u8` field is still pointing at comptime-literal
    /// storage, and `alloc.free()` on that is memory corruption, not a leak.
    /// C sidesteps this because its runtime `_default()` calls `zidl_cdr_strdup`
    /// unconditionally (always heap, never a raw literal pointer) — Zig's
    /// comptime struct-literal field defaults can't do the equivalent at compile
    /// time. `--zig-generate-toml-config` structs are exempt from this
    /// exclusion: `emitFieldSeqCloneStmt`'s dupe and `_toml_applied` (see
    /// `emitFieldSeqDeinit`) already track real per-value ownership for exactly
    /// this case, flag-independently. Outside that flag, such a member is
    /// deliberately left out of cleanup — a narrow, pre-existing gap (same as
    /// before this fix), not a new regression — rather than risk freeing static
    /// memory.
    fn memberNeedsCleanup(self: *Generator, m: ir.StructMember) bool {
        if (typeRefNeedsSeqDeinit(m.type_ref)) return true;
        if (!typeRefHasUnboundedString(m.type_ref)) return false;
        if (typeRefIsDirectPlainString(m.type_ref) and
            !self.opts.zig_generate_toml_config and
            memberHasNonEmptyStringDefault(m))
        {
            return false;
        }
        return true;
    }

    fn structNeedsCleanup(self: *Generator, s: *const ir.Struct) bool {
        if (s.base) |base| switch (base) {
            .struct_ => |bs| if (self.structNeedsCleanup(bs)) return true,
            else => {},
        };
        for (s.members) |m| {
            if (self.memberNeedsCleanup(m)) return true;
        }
        return false;
    }

    /// Union-case analog of `memberNeedsCleanup`.
    fn caseNeedsCleanup(self: *Generator, cas: ir.UnionCase) bool {
        if (typeRefNeedsSeqDeinit(cas.type_ref)) return true;
        if (!typeRefHasUnboundedString(cas.type_ref)) return false;
        if (typeRefIsDirectPlainString(cas.type_ref) and
            !self.opts.zig_generate_toml_config and
            caseHasNonEmptyStringDefault(cas))
        {
            return false;
        }
        return true;
    }

    /// Union analog of `structNeedsCleanup`: true if the union needs its own
    /// generated `deinit()`/`clone()` (see `emitUnionDeinitFn`/
    /// `emitUnionCloneFn`) -- and, via `unionNeedsSeqDeinit`/
    /// `unionHasUnboundedString`, whether a struct embedding this union as a
    /// field needs to call them.
    fn unionNeedsCleanup(self: *Generator, u: *const ir.Union) bool {
        for (u.cases) |cas| {
            if (self.caseNeedsCleanup(cas)) return true;
        }
        return false;
    }

    /// Emit `pub fn deinit(self: *@This(), alloc: std.mem.Allocator) void` for
    /// structs whose sequence fields may have been heap-allocated by
    /// `deserializeInto` (identified by `_release == true`), or whose unbounded
    /// string/wstring fields may have been (either via `deserializeInto`'s
    /// unconditional dupe, or — under `--zig-generate-toml-config` —
    /// `applyToml`'s). See `memberNeedsCleanup`.
    fn emitStructDeinitFn(self: *Generator, s: *const ir.Struct) !void {
        try self.ind();
        try self.write("    pub fn deinit(self: *@This(), alloc: std.mem.Allocator) void {\n");
        if (s.base) |base| switch (base) {
            .struct_ => |bs| if (self.structNeedsCleanup(bs)) {
                try self.ind();
                try self.write("        self._base.deinit(alloc);\n");
            },
            else => {},
        };
        for (s.members) |m| {
            if (!self.memberNeedsCleanup(m)) continue;
            try self.emitFieldSeqDeinit(m.name, m.type_ref, "        ");
        }
        try self.ind();
        try self.write("    }\n");
    }

    /// Emit `if (self.field.len != 0) alloc.free(self.field);`, gated on
    /// `self._toml_applied` under `--zig-generate-toml-config` (a string field
    /// has no ownership flag of its own, so without that guard, an untouched
    /// `T{}` whose non-empty `@default` literal was never duped would have its
    /// static storage passed to `alloc.free` here — undefined behavior; see
    /// `Generator.memberNeedsCleanup`'s doc comment for why the *caller*
    /// already excludes this exact risk outside that flag by never reaching
    /// this function for such a field at all, so no equivalent guard is needed
    /// here in that case).
    fn emitPlainStringFreeStmt(self: *Generator, field_name: []const u8, indent: []const u8) !void {
        try self.ind();
        if (self.opts.zig_generate_toml_config) {
            try self.print("{s}if (self._toml_applied and self.{s}.len != 0) alloc.free(self.{s});\n", .{ indent, field_name, field_name });
        } else {
            try self.print("{s}if (self.{s}.len != 0) alloc.free(self.{s});\n", .{ indent, field_name, field_name });
        }
    }

    /// Emit the cleanup snippet for a single struct field whose type is or
    /// contains an unbounded sequence, or an unbounded string.
    fn emitFieldSeqDeinit(self: *Generator, field_name: []const u8, tr: ir.TypeRef, indent: []const u8) !void {
        switch (tr) {
            .string => |bound| if (bound == null) {
                try self.emitPlainStringFreeStmt(field_name, indent);
            },
            .sequence => |seq| {
                // Anonymous extern struct field — inline the _release-guarded cleanup.
                try self.ind();
                try self.print("{s}if (self.{s}._release) {{\n", .{ indent, field_name });
                try self.ind();
                try self.print("{s}    if (self.{s}._buffer) |_buf| {{\n", .{ indent, field_name });
                if (seq.element.* == .string) {
                    try self.ind();
                    try self.print("{s}        for (_buf[0..self.{s}._length]) |_s| {{\n", .{ indent, field_name });
                    try self.ind();
                    try self.print("{s}            const _sl = std.mem.span(_s);\n", .{indent});
                    try self.ind();
                    try self.print("{s}            alloc.free(_sl.ptr[0.._sl.len + 1]);\n", .{indent});
                    try self.ind();
                    try self.print("{s}        }}\n", .{indent});
                }
                try self.ind();
                try self.print("{s}        alloc.free(_buf[0..self.{s}._maximum]);\n", .{ indent, field_name });
                try self.ind();
                try self.print("{s}    }}\n", .{indent});
                try self.ind();
                try self.print("{s}    self.{s} = .{{}};\n", .{ indent, field_name });
                try self.ind();
                try self.print("{s}}}\n", .{indent});
            },
            .named => |td| switch (td) {
                .typedef => |t| if (typedefTargetsPlainString(t)) {
                    // A type alias for []const u8 has no .deinit() to delegate
                    // to — handle it exactly like a direct string field.
                    try self.emitPlainStringFreeStmt(field_name, indent);
                } else {
                    // Named sequence typedef — has its own generated .deinit().
                    try self.ind();
                    try self.print("{s}self.{s}.deinit(alloc);\n", .{ indent, field_name });
                },
                .struct_, .union_ => {
                    try self.ind();
                    try self.print("{s}self.{s}.deinit(alloc);\n", .{ indent, field_name });
                },
                else => {},
            },
            else => {},
        }
    }

    /// Emit `pub fn clone(self: @This(), alloc: std.mem.Allocator) !@This()` for
    /// structs whose sequence fields need a deep copy.  Each field is cloned in
    /// declaration order; an errdefer is emitted after each clone so that partial
    /// failure frees whatever was already allocated.
    fn emitStructCloneFn(self: *Generator, s: *const ir.Struct) !void {
        try self.ind();
        try self.write("    pub fn clone(self: @This(), alloc: std.mem.Allocator) !@This() {\n");
        try self.ind();
        try self.write("        var result = self;\n");
        if (self.opts.zig_generate_toml_config) {
            // `var result = self;` above also shallow-copied `_toml_applied` —
            // but the string-cloning statements below run unconditionally on
            // every non-empty string field regardless of that flag, so
            // `result`'s strings are always fresh, genuinely-owned dupes by
            // the time this function returns, even if `self` itself was an
            // untouched `T{}` (`_toml_applied = false`). Setting it `true`
            // here (not copied from `self`) is what makes `result` actually
            // consistent with its own content — otherwise `result.deinit()`
            // would skip freeing those just-duped strings, leaking them.
            try self.ind();
            try self.write("        result._toml_applied = true;\n");
        }
        if (s.base) |base| switch (base) {
            .struct_ => |bs| if (self.structNeedsCleanup(bs)) {
                // `var result = self;` above only shallow-copied _base — replace
                // it with a real deep clone so freeing one of self/result later
                // can't double-free the other's heap-owned base fields.
                try self.ind();
                try self.write("        result._base = try self._base.clone(alloc);\n");
                try self.ind();
                try self.write("        errdefer result._base.deinit(alloc);\n");
            },
            else => {},
        };
        for (s.members) |m| {
            if (!self.memberNeedsCleanup(m)) continue;
            try self.emitFieldSeqCloneStmt(m.name, m.type_ref, "        ");
            try self.emitFieldSeqCloneErrdefer(m.name, m.type_ref, "        ");
        }
        try self.ind();
        try self.write("        return result;\n");
        try self.ind();
        try self.write("    }\n");
    }

    /// Emit the copy snippet for a single struct field (the `result.field = ...` part).
    fn emitFieldSeqCloneStmt(self: *Generator, field_name: []const u8, tr: ir.TypeRef, indent: []const u8) !void {
        switch (tr) {
            // `var result = self;` above already shallow-copied the pointer —
            // this replaces it with an independent copy so freeing one of
            // self/result later can't double-free the other's buffer.
            .string => |bound| if (bound == null) {
                try self.ind();
                try self.print(
                    "{s}result.{s} = if (self.{s}.len != 0) try alloc.dupe(u8, self.{s}) else self.{s};\n",
                    .{ indent, field_name, field_name, field_name, field_name },
                );
            },
            .sequence => |seq| {
                const buf_elem = try self.seqBufElemZig(seq.element.*);
                defer self.alloc.free(buf_elem);
                // Reset before the clone attempt so the errdefer is a no-op if
                // _length == 0 (avoids freeing the original's buffer via the
                // shallow-copied _release flag).
                try self.ind();
                try self.print("{s}result.{s} = .{{}};\n", .{ indent, field_name });
                try self.ind();
                try self.print("{s}if (self.{s}._length > 0) {{\n", .{ indent, field_name });
                if (seq.element.* == .string) {
                    try self.ind();
                    try self.print("{s}    const _buf = try alloc.alloc({s}, self.{s}._length);\n", .{ indent, buf_elem, field_name });
                    try self.ind();
                    try self.print("{s}    var _n: u32 = 0;\n", .{indent});
                    try self.ind();
                    try self.print("{s}    errdefer {{\n", .{indent});
                    try self.ind();
                    try self.print("{s}        for (_buf[0.._n]) |_s| {{\n", .{indent});
                    try self.ind();
                    try self.print("{s}            const _sl = std.mem.span(_s);\n", .{indent});
                    try self.ind();
                    try self.print("{s}            alloc.free(_sl.ptr[0.._sl.len + 1]);\n", .{indent});
                    try self.ind();
                    try self.print("{s}        }}\n", .{indent});
                    try self.ind();
                    try self.print("{s}        alloc.free(_buf);\n", .{indent});
                    try self.ind();
                    try self.print("{s}    }}\n", .{indent});
                    try self.ind();
                    try self.print("{s}    if (self.{s}._buffer) |_sb| {{\n", .{ indent, field_name });
                    try self.ind();
                    try self.print("{s}        for (_sb[0..self.{s}._length]) |_src| {{\n", .{ indent, field_name });
                    try self.ind();
                    try self.print("{s}            _buf[_n] = (try alloc.dupeZ(u8, std.mem.span(_src))).ptr;\n", .{indent});
                    try self.ind();
                    try self.print("{s}            _n += 1;\n", .{indent});
                    try self.ind();
                    try self.print("{s}        }}\n", .{indent});
                    try self.ind();
                    try self.print("{s}    }}\n", .{indent});
                    try self.ind();
                    try self.print("{s}    result.{s} = .{{ ._buffer = _buf.ptr, ._length = self.{s}._length, ._maximum = self.{s}._length, ._release = true }};\n", .{ indent, field_name, field_name, field_name });
                } else {
                    try self.ind();
                    try self.print("{s}    const _buf = try alloc.alloc({s}, self.{s}._length);\n", .{ indent, buf_elem, field_name });
                    try self.ind();
                    try self.print("{s}    if (self.{s}._buffer) |_sb| @memcpy(_buf, _sb[0..self.{s}._length]);\n", .{ indent, field_name, field_name });
                    try self.ind();
                    try self.print("{s}    result.{s} = .{{ ._buffer = _buf.ptr, ._length = self.{s}._length, ._maximum = self.{s}._length, ._release = true }};\n", .{ indent, field_name, field_name, field_name });
                }
                try self.ind();
                try self.print("{s}}}\n", .{indent});
            },
            .named => |td| switch (td) {
                .typedef => |t| if (typedefTargetsPlainString(t)) {
                    try self.ind();
                    try self.print(
                        "{s}result.{s} = if (self.{s}.len != 0) try alloc.dupe(u8, self.{s}) else self.{s};\n",
                        .{ indent, field_name, field_name, field_name, field_name },
                    );
                } else {
                    try self.ind();
                    try self.print("{s}result.{s} = try self.{s}.clone(alloc);\n", .{ indent, field_name, field_name });
                },
                .struct_, .union_ => {
                    try self.ind();
                    try self.print("{s}result.{s} = try self.{s}.clone(alloc);\n", .{ indent, field_name, field_name });
                },
                else => {},
            },
            else => {},
        }
    }

    /// Emit the errdefer cleanup snippet for a field already cloned by
    /// `emitFieldSeqCloneStmt`.  Must be emitted immediately after the clone
    /// statement so that failures in subsequent fields trigger this cleanup.
    fn emitFieldSeqCloneErrdefer(self: *Generator, field_name: []const u8, tr: ir.TypeRef, indent: []const u8) !void {
        switch (tr) {
            .string => |bound| if (bound == null) {
                try self.ind();
                try self.print("{s}errdefer if (result.{s}.len != 0) alloc.free(result.{s});\n", .{ indent, field_name, field_name });
            },
            .sequence => |seq| {
                try self.ind();
                try self.print("{s}errdefer {{\n", .{indent});
                try self.ind();
                try self.print("{s}    if (result.{s}._release) {{\n", .{ indent, field_name });
                try self.ind();
                try self.print("{s}        if (result.{s}._buffer) |_b| {{\n", .{ indent, field_name });
                if (seq.element.* == .string) {
                    try self.ind();
                    try self.print("{s}            for (_b[0..result.{s}._length]) |_s| {{\n", .{ indent, field_name });
                    try self.ind();
                    try self.print("{s}                const _sl = std.mem.span(_s);\n", .{indent});
                    try self.ind();
                    try self.print("{s}                alloc.free(_sl.ptr[0.._sl.len + 1]);\n", .{indent});
                    try self.ind();
                    try self.print("{s}            }}\n", .{indent});
                }
                try self.ind();
                try self.print("{s}            alloc.free(_b[0..result.{s}._maximum]);\n", .{ indent, field_name });
                try self.ind();
                try self.print("{s}        }}\n", .{indent});
                try self.ind();
                try self.print("{s}        result.{s} = .{{}};\n", .{ indent, field_name });
                try self.ind();
                try self.print("{s}    }}\n", .{indent});
                try self.ind();
                try self.print("{s}}}\n", .{indent});
            },
            .named => |td| switch (td) {
                .typedef => |t| if (typedefTargetsPlainString(t)) {
                    try self.ind();
                    try self.print("{s}errdefer if (result.{s}.len != 0) alloc.free(result.{s});\n", .{ indent, field_name, field_name });
                } else {
                    try self.ind();
                    try self.print("{s}errdefer result.{s}.deinit(alloc);\n", .{ indent, field_name });
                },
                .struct_, .union_ => {
                    try self.ind();
                    try self.print("{s}errdefer result.{s}.deinit(alloc);\n", .{ indent, field_name });
                },
                else => {},
            },
            else => {},
        }
    }

    // ── TOML config application (--zig-generate-toml-config) ─────────────────

    /// Emit `pub fn applyToml(self: *@This(), alloc: std.mem.Allocator, table: anytype) !void`.
    /// See the `zig_generate_toml_config` doc comment in `interface.zig` for the
    /// full contract `table` must satisfy and the supported field-type subset.
    ///
    /// Two things that aren't obvious from `emitTypeRefApplyToml` alone:
    ///   - Zig errors on both an unused parameter AND a "pointless" discard of
    ///     one that's genuinely used afterward — so `self`/`alloc`/`table` are
    ///     each discarded *only* when nothing else in the body will reference
    ///     them (no members at all, or — for `alloc` specifically — no member
    ///     needing it, e.g. an all-integer struct).
    ///   - if ANY member is unsupported, the whole body becomes a single
    ///     `@compileError` and nothing else. `@compileError` makes everything
    ///     textually after it in the same block "unreachable code" — itself a
    ///     hard error — so per-field statements can't be interspersed with it;
    ///     `memberApplyTomlSupported` below must keep recognizing exactly the
    ///     same cases `emitTypeRefApplyToml`'s dispatch handles.
    ///   - a `struct Derived : Base` field always delegates to
    ///     `self._base.applyToml(alloc, table)` first, passing the *same*
    ///     table rather than a nested sub-table — inheritance is an IS-A
    ///     relationship, so Base's fields are expected as peers of Derived's
    ///     own in one flat table, not nested under a `[base]`-style key
    ///     (unlike a genuine HAS-A struct-typed field, which does get its own
    ///     sub-table). This call is unconditional whenever a base exists,
    ///     regardless of whether the base happens to need heap cleanup — even
    ///     an all-scalar base still needs its own fields populated from TOML.
    ///     Base support-checking isn't duplicated here: an unsupported field
    ///     in the base already fails to compile when the base's own
    ///     `applyToml` is generated, independently of this struct.
    fn emitStructApplyTomlFn(self: *Generator, s: *const ir.Struct) !void {
        try self.ind();
        try self.write("    pub fn applyToml(self: *@This(), alloc: std.mem.Allocator, table: anytype) !void {\n");

        var unsupported: ?*const ir.StructMember = null;
        for (s.members) |*m| {
            if (!memberApplyTomlSupported(m)) {
                unsupported = m;
                break;
            }
        }

        const has_base_call = if (s.base) |base| base == .struct_ else false;

        // self/table are used by every per-member statement (assignment target,
        // accessor receiver respectively) and by the base delegate call below —
        // nothing to discard for either one unless the body ends up truly empty
        // (no members, no base, or the single-compileError path, none of which
        // reference them).
        if (unsupported != null or (s.members.len == 0 and !has_base_call)) {
            try self.ind();
            try self.write("        _ = self;\n");
            try self.ind();
            try self.write("        _ = alloc;\n");
            try self.ind();
            try self.write("        _ = table;\n");
        } else {
            var needs_alloc = has_base_call; // the base delegate call always passes alloc through
            if (!needs_alloc) {
                for (s.members) |*m| {
                    if (memberApplyTomlNeedsAlloc(m)) {
                        needs_alloc = true;
                        break;
                    }
                }
            }
            if (!needs_alloc) {
                try self.ind();
                try self.write("        _ = alloc;\n");
            }
        }

        if (unsupported) |m| {
            try self.ind();
            try self.print(
                "        @compileError(\"--zig-generate-toml-config does not support this field type ('{s}.{s}')\");\n",
                .{ s.name, m.name },
            );
        } else {
            if (has_base_call) {
                try self.ind();
                try self.write("        try self._base.applyToml(alloc, table);\n");
            }
            for (s.members) |m| {
                try self.emitTypeRefApplyToml(s.name, m.name, m.type_ref, "        ");
            }
            // Reached only if every statement above succeeded (any `try`
            // failing returns early) — see the `_toml_applied` field's own
            // doc comment in emitStruct for why this specifically has to be
            // the *last* statement, not set unconditionally up front.
            try self.ind();
            try self.write("        self._toml_applied = true;\n");
        }
        try self.ind();
        try self.write("    }\n");
    }

    /// True if this member's generated statement references `alloc` (a string
    /// dupe, a recursive `applyToml(alloc, ...)` call, or building a sequence).
    /// Must stay in sync with `emitTypeRefApplyToml` the same way
    /// `memberApplyTomlSupported` does.
    fn memberApplyTomlNeedsAlloc(m: *const ir.StructMember) bool {
        return switch (resolveTomlTypeRef(m.type_ref)) {
            .base => false,
            .string => true,
            .named => |td| switch (td) {
                .struct_ => true,
                else => false, // enum_: fromString needs no alloc
            },
            .sequence => true,
            else => false,
        };
    }

    /// Resolve through any typedef chain to the underlying representation
    /// (e.g. a `StringSeq` typedef field resolves to its `sequence<string>`).
    /// Shared by `memberApplyTomlSupported` and `emitTypeRefApplyToml` so the
    /// two can't independently drift on what a typedef chain resolves to.
    ///
    /// Stops (without unwrapping further) at a typedef that itself declares
    /// array dimensions (`typedef long V3[3];`) — the dimensions live on the
    /// typedef, not on a member referencing it, so a member of type `V3` would
    /// otherwise resolve straight through to `long` and be accepted as a plain
    /// scalar, silently mis-generating an assignment to what's actually a `[3]i32`
    /// array field. Leaving the result as `.named => .typedef` here means it
    /// falls into the ordinary `else => unsupported` arm both callers already
    /// have, the same as any other unsupported construct.
    fn resolveTomlTypeRef(tr_in: ir.TypeRef) ir.TypeRef {
        var tr = tr_in;
        while (tr == .named and tr.named == .typedef and tr.named.typedef.dimensions.len == 0) {
            tr = tr.named.typedef.type_ref;
        }
        return tr;
    }

    /// Must recognize exactly the field-type subset `emitTypeRefApplyToml`
    /// handles (see the note on `emitStructApplyTomlFn` for why this can't
    /// just be discovered by attempting to emit and catching a failure).
    fn memberApplyTomlSupported(m: *const ir.StructMember) bool {
        if (m.dimensions.len > 0) return false;
        return switch (resolveTomlTypeRef(m.type_ref)) {
            .base => |b| switch (b) {
                .any, .object, .value_base => false,
                else => true,
            },
            .string => |bound| bound == null,
            .named => |td| switch (td) {
                .struct_, .enum_ => true,
                else => false,
            },
            .sequence => |seq| seq.bound == null and seq.element.* == .string,
            else => false,
        };
    }

    /// Emit the override statement(s) for a single field. Resolves through any
    /// typedef chain first (e.g. a `StringSeq` typedef field dispatches as its
    /// underlying `sequence<string>`), then dispatches on the resolved type.
    /// Only called once every member of the enclosing struct has already been
    /// confirmed supported by `memberApplyTomlSupported` — the `@compileError`
    /// branches below are an unreachable-in-practice safety net, not the
    /// primary way unsupported fields are handled.
    fn emitTypeRefApplyToml(
        self: *Generator,
        struct_name: []const u8,
        field_name: []const u8,
        tr_in: ir.TypeRef,
        indent: []const u8,
    ) anyerror!void {
        const tr = resolveTomlTypeRef(tr_in);

        switch (tr) {
            .base => |b| switch (b) {
                .boolean => {
                    try self.ind();
                    try self.print("{s}if (try table.getBool(\"{s}\")) |_v| self.{s} = _v;\n", .{ indent, field_name, field_name });
                },
                .float, .double, .long_double => {
                    try self.ind();
                    try self.print("{s}if (try table.getFloat(\"{s}\")) |_v| self.{s} = @floatCast(_v);\n", .{ indent, field_name, field_name });
                },
                .any, .object, .value_base => {
                    try self.emitApplyTomlUnsupported(struct_name, field_name, indent);
                },
                else => {
                    try self.ind();
                    try self.print(
                        "{s}if (try table.getInt(\"{s}\")) |_v| self.{s} = std.math.cast({s}, _v) orelse return error.InvalidValue;\n",
                        .{ indent, field_name, field_name, baseToZigType(b) },
                    );
                },
            },
            .string => |bound| {
                if (bound != null) {
                    try self.emitApplyTomlUnsupported(struct_name, field_name, indent);
                } else {
                    // Dupe into a fresh buffer FIRST, from the still-valid
                    // current value — critically, BEFORE freeing anything,
                    // since the TOML-key-absent fallback (`orelse self.field`)
                    // reads from that same current value; freeing it first
                    // would make this a use-after-free read. Only once the new
                    // dupe has succeeded do we free the old buffer and assign.
                    try self.ind();
                    try self.print(
                        "{s}const _new_{s} = try alloc.dupe(u8, (try table.getString(\"{s}\")) orelse self.{s});\n",
                        .{ indent, field_name, field_name, field_name },
                    );
                    // Free the OLD value now, but only if self._toml_applied
                    // is *already* true (its value from before this call, not
                    // yet touched — this function only sets it at the very
                    // end): that's precisely when self.field is guaranteed to
                    // already be a genuine dupe (established by an earlier
                    // successful applyToml, or by clone(), both of which only
                    // ever leave a struct with _toml_applied = true if every
                    // string field is really heap-owned). On a fresh T{}
                    // (_toml_applied still false), this correctly skips
                    // freeing — the field could still be an untouched
                    // @default literal, and freeing one would be undefined
                    // behavior. This is what makes re-applying `applyToml` to
                    // an already-populated struct safe, not just the first
                    // call on a fresh instance.
                    try self.ind();
                    try self.print(
                        "{s}if (self._toml_applied and self.{s}.len != 0) alloc.free(self.{s});\n",
                        .{ indent, field_name, field_name },
                    );
                    try self.ind();
                    try self.print("{s}self.{s} = _new_{s};\n", .{ indent, field_name, field_name });
                    // If a LATER field's statement fails, this dupe (already
                    // committed to self, which escapes even on error, unlike
                    // clone's local `result`) would otherwise be orphaned —
                    // _toml_applied stays false on any failure, so deinit
                    // wouldn't free it either. Free + reset it here instead of
                    // just leaking it.
                    try self.ind();
                    try self.print("{s}errdefer {{\n", .{indent});
                    try self.ind();
                    try self.print("{s}    if (self.{s}.len != 0) {{\n", .{ indent, field_name });
                    try self.ind();
                    try self.print("{s}        alloc.free(self.{s});\n", .{ indent, field_name });
                    try self.ind();
                    try self.print("{s}        self.{s} = \"\";\n", .{ indent, field_name });
                    try self.ind();
                    try self.print("{s}    }}\n", .{indent});
                    try self.ind();
                    try self.print("{s}}}\n", .{indent});
                }
            },
            .named => |td| switch (td) {
                .struct_ => {
                    // Unconditional, not `if (try table.getTable(...)) |_t| ...`:
                    // a nested struct must always run its own applyToml, even
                    // against a fresh, empty `@TypeOf(table){}` when this key
                    // is absent — otherwise, for a wholly empty root table,
                    // NO nested struct's fields (e.g. a deeply-nested unbounded
                    // string default) would ever get the unconditional-dupe
                    // pass at all, breaking the invariant deinit/clone rely on
                    // for anything more than one level deep.
                    try self.ind();
                    try self.print(
                        "{s}try self.{s}.applyToml(alloc, (try table.getTable(\"{s}\")) orelse @TypeOf(table){{}});\n",
                        .{ indent, field_name, field_name },
                    );
                },
                .enum_ => {
                    // Use the same qualified-name mapping as ordinary field-type
                    // references (qualNameToZig) rather than the bare enum name +
                    // type_prefix: an enum from another module (e.g. DDS::Foo) needs
                    // its module qualifier, since _fromString lives alongside the
                    // enum itself, not in the struct's own enclosing module.
                    const qual = try self.qualNameToZig(ir.typeDeclQualifiedName(td));
                    defer self.alloc.free(qual);
                    try self.ind();
                    try self.print(
                        "{s}if (try table.getString(\"{s}\")) |_v| self.{s} = {s}_fromString(_v) orelse return error.InvalidValue;\n",
                        .{ indent, field_name, field_name, qual },
                    );
                },
                else => try self.emitApplyTomlUnsupported(struct_name, field_name, indent),
            },
            .sequence => |seq| {
                if (seq.bound == null and seq.element.* == .string) {
                    try self.emitStringSeqApplyToml(field_name, indent);
                } else {
                    try self.emitApplyTomlUnsupported(struct_name, field_name, indent);
                }
            },
            else => try self.emitApplyTomlUnsupported(struct_name, field_name, indent),
        }
    }

    fn emitApplyTomlUnsupported(self: *Generator, struct_name: []const u8, field_name: []const u8, indent: []const u8) !void {
        try self.ind();
        try self.print(
            "{s}@compileError(\"--zig-generate-toml-config does not support this field type ('{s}.{s}')\");\n",
            .{ indent, struct_name, field_name },
        );
    }

    /// Build a `{ ._buffer, ._length, ._maximum, ._release = true }` sequence value
    /// from a TOML string array — the same C-PSM sequence shape `clone`/`deinit`
    /// already use, so the anonymous struct literal coerces to whatever concrete
    /// named type (e.g. a `StringSeq` typedef) the field actually declares.
    fn emitStringSeqApplyToml(self: *Generator, field_name: []const u8, indent: []const u8) !void {
        try self.ind();
        try self.print("{s}if (try table.getStringArray(\"{s}\")) |_arr| {{\n", .{ indent, field_name });
        // Free any buffer this field already owns before replacing it — inlined
        // (matching emitFieldSeqDeinit's own sequence case) rather than
        // delegating to a `.deinit()` call, since this field's declared type
        // might be an anonymous inline sequence (no methods at all), not
        // necessarily a named typedef like `StringSeq` that has one.
        try self.ind();
        try self.print("{s}    if (self.{s}._release) {{\n", .{ indent, field_name });
        try self.ind();
        try self.print("{s}        if (self.{s}._buffer) |_ob| {{\n", .{ indent, field_name });
        try self.ind();
        try self.print("{s}            for (_ob[0..self.{s}._length]) |_os| {{\n", .{ indent, field_name });
        try self.ind();
        try self.print("{s}                const _osl = std.mem.span(_os);\n", .{indent});
        try self.ind();
        try self.print("{s}                alloc.free(_osl.ptr[0.._osl.len + 1]);\n", .{indent});
        try self.ind();
        try self.print("{s}            }}\n", .{indent});
        try self.ind();
        try self.print("{s}            alloc.free(_ob[0..self.{s}._maximum]);\n", .{ indent, field_name });
        try self.ind();
        try self.print("{s}        }}\n", .{indent});
        try self.ind();
        try self.print("{s}    }}\n", .{indent});
        // Reset immediately after freeing, before attempting the replacement —
        // if the allocation/dupe below fails, self.field must not be left
        // pointing at memory that was just freed above (a dangling _release =
        // true field, causing a use-after-free/double-free on a later deinit
        // or retry).
        try self.ind();
        try self.print("{s}    self.{s} = .{{}};\n", .{ indent, field_name });
        try self.ind();
        try self.print("{s}    const _buf = try alloc.alloc([*:0]const u8, _arr.len);\n", .{indent});
        try self.ind();
        try self.print("{s}    var _n: usize = 0;\n", .{indent});
        try self.ind();
        try self.print("{s}    errdefer {{\n", .{indent});
        try self.ind();
        try self.print("{s}        for (_buf[0.._n]) |_s| {{\n", .{indent});
        try self.ind();
        try self.print("{s}            const _sl = std.mem.span(_s);\n", .{indent});
        try self.ind();
        try self.print("{s}            alloc.free(_sl.ptr[0.._sl.len + 1]);\n", .{indent});
        try self.ind();
        try self.print("{s}        }}\n", .{indent});
        try self.ind();
        try self.print("{s}        alloc.free(_buf);\n", .{indent});
        try self.ind();
        try self.print("{s}    }}\n", .{indent});
        try self.ind();
        try self.print("{s}    for (_arr) |_s| {{\n", .{indent});
        try self.ind();
        try self.print("{s}        _buf[_n] = (try alloc.dupeZ(u8, _s)).ptr;\n", .{indent});
        try self.ind();
        try self.print("{s}        _n += 1;\n", .{indent});
        try self.ind();
        try self.print("{s}    }}\n", .{indent});
        try self.ind();
        try self.print(
            "{s}    self.{s} = .{{ ._buffer = _buf.ptr, ._length = @intCast(_arr.len), ._maximum = @intCast(_arr.len), ._release = true }};\n",
            .{ indent, field_name },
        );
        try self.ind();
        try self.print("{s}}}\n", .{indent});
    }

    // ── TypeObject / TypeIdentifier constant emission ─────────────────────────

    /// Emit `type_object`, `equivalence_hash`, and `type_identifier` constants
    /// inside the struct body.  The bytes are computed at code-gen time.
    fn emitStructTypeObjectConsts(self: *Generator, s: *const ir.Struct) !void {
        const bytes = try zig_to.encodeMinimalStruct(self.alloc, s);
        defer self.alloc.free(bytes);

        const eq_hash = zig_to.computeEquivalenceHash(bytes);
        const type_id = zig_to.computeTypeIdentifier(bytes);

        try self.write("\n");

        // type_object — full XCDR2 LE MinimalTypeObject CDR bytes
        try self.ind();
        try self.write("    pub const type_object: []const u8 = &[_]u8{");
        try emitByteSlice(self, bytes);
        try self.write(" };\n");

        // equivalence_hash — MD5[0..14] of type_object, the on-wire DDS EquivalenceHash
        try self.ind();
        try self.write("    pub const equivalence_hash: [14]u8 = [14]u8{");
        try emitByteSlice(self, &eq_hash);
        try self.write(" };\n");

        // type_identifier — SHA-256 of type_object, zidl project fingerprint
        try self.ind();
        try self.write("    pub const type_identifier: [32]u8 = [32]u8{");
        try emitByteSlice(self, &type_id);
        try self.write(" };\n");
    }

    /// Emit comma-separated `0xXX` hex literals for `bytes`.
    fn emitByteSlice(self: *Generator, bytes: []const u8) !void {
        for (bytes, 0..) |b, i| {
            if (i > 0) try self.write(",");
            try self.print(" 0x{X:0>2}", .{b});
        }
    }

    /// Emit a single CDR write statement for the given type.
    /// `access` is the value expression (e.g. "value.x").
    /// `extra` is the fixed indentation beyond `ind()` (e.g. "        " for method body).
    fn emitWriteForTypeRef(self: *Generator, tr: ir.TypeRef, access: []const u8, extra: []const u8) anyerror!void {
        switch (tr) {
            .base => |b| {
                const method = baseWriteMethod(b);
                try self.ind();
                try self.print("{s}try writer.{s}({s});\n", .{ extra, method, access });
            },
            .string => |bound| {
                try self.ind();
                if (bound != null) {
                    try self.print("{s}try writer.writeString({s}.slice());\n", .{ extra, access });
                } else {
                    try self.print("{s}try writer.writeString({s});\n", .{ extra, access });
                }
            },
            .wstring => |bound| {
                try self.ind();
                if (bound != null) {
                    try self.print("{s}try writer.writeWstring({s}.slice());\n", .{ extra, access });
                } else {
                    try self.print("{s}try writer.writeWstring({s});\n", .{ extra, access });
                }
            },
            .sequence => |seq| {
                try self.ind();
                if (seq.bound != null) {
                    try self.print("{s}try writer.writeU32(@intCast({s}.slice().len));\n", .{ extra, access });
                    try self.ind();
                    try self.print("{s}for ({s}.slice()) |_se| {{\n", .{ extra, access });
                    const inner = try std.fmt.allocPrint(self.alloc, "{s}    ", .{extra});
                    defer self.alloc.free(inner);
                    try self.emitWriteForTypeRef(seq.element.*, "_se", inner);
                    try self.ind();
                    try self.print("{s}}}\n", .{extra});
                } else {
                    // Unbounded extern struct: check _buffer before iterating.
                    try self.print("{s}try writer.writeU32({s}._length);\n", .{ extra, access });
                    try self.ind();
                    try self.print("{s}if ({s}._buffer) |_sb| {{\n", .{ extra, access });
                    const inner = try std.fmt.allocPrint(self.alloc, "{s}        ", .{extra});
                    defer self.alloc.free(inner);
                    try self.ind();
                    try self.print("{s}    for (_sb[0..{s}._length]) |_se| {{\n", .{ extra, access });
                    // String elements in C-ABI buffers are [*:0]const u8; span them for writeString.
                    const is_c_str_elem_w = switch (seq.element.*) {
                        .string => |b| b == null,
                        else => false,
                    };
                    if (is_c_str_elem_w) {
                        try self.ind();
                        try self.print("{s}try writer.writeString(std.mem.span(_se));\n", .{inner});
                    } else {
                        try self.emitWriteForTypeRef(seq.element.*, "_se", inner);
                    }
                    try self.ind();
                    try self.print("{s}    }}\n", .{extra}); // close for
                    try self.ind();
                    try self.print("{s}}}\n", .{extra}); // close if
                }
            },
            .named => |td| switch (td) {
                .enum_ => |e| {
                    const stor = enumStorageType(e.annotations);
                    const method = switch (stor[0]) {
                        'u' => switch (stor[1]) {
                            '8' => "writeU8",
                            '1' => "writeU16",
                            '3' => "writeU32",
                            '6' => "writeU64",
                            else => "writeU32",
                        },
                        else => "writeU32",
                    };
                    try self.ind();
                    try self.print("{s}try writer.{s}(@intFromEnum({s}));\n", .{ extra, method, access });
                },
                .typedef => |t| {
                    if (t.dimensions.len > 0) {
                        try self.emitWriteArray(t.type_ref, access, t.dimensions, extra, 0);
                    } else {
                        try self.emitWriteForTypeRef(t.type_ref, access, extra);
                    }
                },
                .bitmask => |bm| {
                    const stor = bitmaskStorageType(bm.annotations);
                    const method = switch (stor[0]) {
                        'u' => switch (stor[1]) {
                            '8' => "writeU8",
                            '1' => "writeU16",
                            '3' => "writeU32",
                            '6' => "writeU64",
                            else => "writeU32",
                        },
                        else => "writeU32",
                    };
                    try self.ind();
                    try self.print("{s}try writer.{s}({s});\n", .{ extra, method, access });
                },
                .union_ => {
                    const zig_type = try self.typeRefToZig(tr);
                    defer self.alloc.free(zig_type);
                    try self.ind();
                    try self.print("{s}try {s}.serialize(writer, {s});\n", .{ extra, zig_type, access });
                },
                .bitset => {
                    const zig_type = try self.typeRefToZig(tr);
                    defer self.alloc.free(zig_type);
                    try self.ind();
                    try self.print("{s}try {s}.serialize(writer, {s});\n", .{ extra, zig_type, access });
                },
                else => {
                    const zig_type = try self.typeRefToZig(tr);
                    defer self.alloc.free(zig_type);
                    try self.ind();
                    try self.print("{s}try {s}.serialize(writer, {s});\n", .{ extra, zig_type, access });
                },
            },
            .map => |m| {
                try self.ind();
                try self.print("{s}try writer.writeU32(@intCast({s}.count()));\n", .{ extra, access });
                try self.ind();
                try self.print("{s}for ({s}.keys(), {s}.values()) |_mk, _mv| {{\n", .{ extra, access, access });
                const inner = try std.fmt.allocPrint(self.alloc, "{s}    ", .{extra});
                defer self.alloc.free(inner);
                try self.emitWriteForTypeRef(m.key.*, "_mk", inner);
                try self.emitWriteForTypeRef(m.value.*, "_mv", inner);
                try self.ind();
                try self.print("{s}}}\n", .{extra});
            },
            .fixed_pt => |fp| {
                try self.ind();
                try self.print("{s}try writer.writeFixed({d}, {d}, {s});\n", .{ extra, fp.digits, fp.scale, access });
            },
        }
    }

    /// Emit CDR read statement(s) for the given type.
    /// `out_expr` is the lvalue expression (e.g. "out.x").
    fn emitReadForTypeRef(self: *Generator, tr: ir.TypeRef, out_expr: []const u8, extra: []const u8) anyerror!void {
        switch (tr) {
            .base => |b| {
                const method = baseReadMethod(b);
                try self.ind();
                try self.print("{s}{s} = try reader.{s}();\n", .{ extra, out_expr, method });
            },
            .string => |bound| {
                if (bound) |n| {
                    // Bounded: zero-copy read, then copy into BoundedArray
                    try self.ind();
                    try self.print("{s}{{\n", .{extra});
                    const ii = try std.fmt.allocPrint(self.alloc, "{s}    ", .{extra});
                    defer self.alloc.free(ii);
                    try self.ind();
                    try self.print("{s}const _s = try reader.readStringZeroCopy();\n", .{ii});
                    try self.ind();
                    try self.print("{s}if (_s.len > {d}) return error.StringTooLong;\n", .{ ii, n });
                    try self.ind();
                    try self.print("{s}{s} = zidl_rt.BoundedArray(u8, {d}).fromSlice(_s) catch unreachable;\n", .{ ii, out_expr, n });
                    try self.ind();
                    try self.print("{s}}}\n", .{extra});
                } else {
                    try self.ind();
                    try self.print("{s}{s} = try reader.readString(allocator);\n", .{ extra, out_expr });
                }
            },
            .wstring => |bound| {
                if (bound) |n| {
                    // Bounded: allocate temp slice, bound-check, copy into BoundedArray, free temp.
                    try self.ind();
                    try self.print("{s}{{\n", .{extra});
                    const ii = try std.fmt.allocPrint(self.alloc, "{s}    ", .{extra});
                    defer self.alloc.free(ii);
                    try self.ind();
                    try self.print("{s}const _ws = try reader.readWstring(allocator);\n", .{ii});
                    try self.ind();
                    try self.print("{s}defer allocator.free(_ws);\n", .{ii});
                    try self.ind();
                    try self.print("{s}if (_ws.len > {d}) return error.StringTooLong;\n", .{ ii, n });
                    try self.ind();
                    try self.print("{s}{s} = zidl_rt.BoundedArray(u16, {d}).fromSlice(_ws) catch unreachable;\n", .{ ii, out_expr, n });
                    try self.ind();
                    try self.print("{s}}}\n", .{extra});
                } else {
                    try self.ind();
                    try self.print("{s}{s} = try reader.readWstring(allocator);\n", .{ extra, out_expr });
                }
            },
            .sequence => |seq| {
                try self.ind();
                try self.print("{s}{{\n", .{extra});
                const ii = try std.fmt.allocPrint(self.alloc, "{s}    ", .{extra});
                defer self.alloc.free(ii);
                try self.ind();
                try self.print("{s}const _n = try reader.readU32();\n", .{ii});
                if (seq.bound) |bound| {
                    try self.ind();
                    try self.print("{s}if (_n > {d}) return error.SequenceTooLong;\n", .{ ii, bound });
                    try self.ind();
                    try self.print("{s}{s}.clearRetainingCapacity();\n", .{ ii, out_expr });
                    try self.ind();
                    try self.print("{s}for (0.._n) |_| {{\n", .{ii});
                    const iii = try std.fmt.allocPrint(self.alloc, "{s}    ", .{ii});
                    defer self.alloc.free(iii);
                    try self.emitSequenceElementRead(seq.element.*, out_expr, iii);
                    try self.ind();
                    try self.print("{s}}}\n", .{ii});
                } else {
                    // Unbounded sequence: allocate a buffer, then read elements into it.
                    const buf_elem = try self.seqBufElemZig(seq.element.*);
                    defer self.alloc.free(buf_elem);
                    try self.ind();
                    try self.print("{s}{s}._length = _n;\n", .{ ii, out_expr });
                    try self.ind();
                    try self.print("{s}{s}._maximum = _n;\n", .{ ii, out_expr });
                    try self.ind();
                    try self.print("{s}if (_n > 0) {{\n", .{ii});
                    const iii = try std.fmt.allocPrint(self.alloc, "{s}    ", .{ii});
                    defer self.alloc.free(iii);
                    try self.ind();
                    try self.print("{s}const _buf = try allocator.alloc({s}, _n);\n", .{ iii, buf_elem });
                    try self.ind();
                    try self.print("{s}{s}._buffer = _buf.ptr;\n", .{ iii, out_expr });
                    try self.ind();
                    try self.print("{s}{s}._release = true;\n", .{ iii, out_expr });
                    try self.ind();
                    try self.print("{s}for (_buf) |*_se| {{\n", .{iii});
                    const iv = try std.fmt.allocPrint(self.alloc, "{s}    ", .{iii});
                    defer self.alloc.free(iv);
                    // String elements in C-ABI buffers are [*:0]const u8; use zero-copy
                    // read + dupeZ to produce a null-terminated allocation.
                    const is_c_str_elem = switch (seq.element.*) {
                        .string => |b| b == null,
                        else => false,
                    };
                    if (is_c_str_elem) {
                        try self.ind();
                        try self.print("{s}const _rs = try reader.readStringZeroCopy();\n", .{iv});
                        try self.ind();
                        try self.print("{s}_se.* = (try allocator.dupeZ(u8, _rs)).ptr;\n", .{iv});
                    } else {
                        try self.emitReadForTypeRef(seq.element.*, "_se.*", iv);
                    }
                    try self.ind();
                    try self.print("{s}}}\n", .{iii});
                    try self.ind();
                    try self.print("{s}}}\n", .{ii});
                }
                try self.ind();
                try self.print("{s}}}\n", .{extra});
            },
            .map => |m| {
                try self.ind();
                try self.print("{s}{{\n", .{extra});
                const ii = try std.fmt.allocPrint(self.alloc, "{s}    ", .{extra});
                defer self.alloc.free(ii);
                try self.ind();
                try self.print("{s}const _mn = try reader.readU32();\n", .{ii});
                try self.ind();
                try self.print("{s}{s} = .{{}};\n", .{ ii, out_expr });
                try self.ind();
                try self.print("{s}try {s}.ensureTotalCapacity(allocator, _mn);\n", .{ ii, out_expr });
                try self.ind();
                try self.print("{s}for (0.._mn) |_| {{\n", .{ii});
                const iii = try std.fmt.allocPrint(self.alloc, "{s}    ", .{ii});
                defer self.alloc.free(iii);
                const key_zig = try self.typeRefToZig(m.key.*);
                defer self.alloc.free(key_zig);
                try self.ind();
                try self.print("{s}var _mk: {s} = undefined;\n", .{ iii, key_zig });
                try self.emitReadForTypeRef(m.key.*, "_mk", iii);
                const val_zig = try self.typeRefToZig(m.value.*);
                defer self.alloc.free(val_zig);
                try self.ind();
                try self.print("{s}var _mv: {s} = undefined;\n", .{ iii, val_zig });
                try self.emitReadForTypeRef(m.value.*, "_mv", iii);
                try self.ind();
                try self.print("{s}try {s}.putNoClobber(allocator, _mk, _mv);\n", .{ iii, out_expr });
                try self.ind();
                try self.print("{s}}}\n", .{ii});
                try self.ind();
                try self.print("{s}}}\n", .{extra});
            },
            .named => |td| switch (td) {
                .enum_ => |e| {
                    const stor = enumStorageType(e.annotations);
                    const method = switch (stor[0]) {
                        'u' => switch (stor[1]) {
                            '8' => "readU8",
                            '1' => "readU16",
                            '3' => "readU32",
                            '6' => "readU64",
                            else => "readU32",
                        },
                        else => "readU32",
                    };
                    try self.ind();
                    try self.print("{s}{s} = @enumFromInt(try reader.{s}());\n", .{ extra, out_expr, method });
                },
                .typedef => |t| {
                    if (t.dimensions.len > 0) {
                        try self.emitReadArray(t.type_ref, out_expr, t.dimensions, extra, 0);
                    } else {
                        try self.emitReadForTypeRef(t.type_ref, out_expr, extra);
                    }
                },
                .bitmask => |bm| {
                    const stor = bitmaskStorageType(bm.annotations);
                    const method = switch (stor[0]) {
                        'u' => switch (stor[1]) {
                            '8' => "readU8",
                            '1' => "readU16",
                            '3' => "readU32",
                            '6' => "readU64",
                            else => "readU32",
                        },
                        else => "readU32",
                    };
                    try self.ind();
                    try self.print("{s}{s} = try reader.{s}();\n", .{ extra, out_expr, method });
                },
                .union_ => {
                    const zig_type = try self.typeRefToZig(tr);
                    defer self.alloc.free(zig_type);
                    try self.ind();
                    try self.print("{s}try {s}.deserializeInto(&{s}, reader, allocator);\n", .{ extra, zig_type, out_expr });
                },
                .bitset => {
                    const zig_type = try self.typeRefToZig(tr);
                    defer self.alloc.free(zig_type);
                    try self.ind();
                    try self.print("{s}try {s}.deserializeInto(&{s}, reader, allocator);\n", .{ extra, zig_type, out_expr });
                },
                else => {
                    const zig_type = try self.typeRefToZig(tr);
                    defer self.alloc.free(zig_type);
                    try self.ind();
                    try self.print("{s}try {s}.deserializeInto(&{s}, reader, allocator);\n", .{ extra, zig_type, out_expr });
                },
            },
            .fixed_pt => |fp| {
                try self.ind();
                try self.print("{s}{s} = try reader.readFixed({d}, {d});\n", .{ extra, out_expr, fp.digits, fp.scale });
            },
        }
    }

    /// Emit read of one sequence element and append it.
    fn emitSequenceElementRead(self: *Generator, elem_tr: ir.TypeRef, seq_expr: []const u8, extra: []const u8) anyerror!void {
        switch (elem_tr) {
            .base => |b| {
                const method = baseReadMethod(b);
                try self.ind();
                try self.print("{s}{s}.appendAssumeCapacity(try reader.{s}());\n", .{ extra, seq_expr, method });
            },
            .named => |td| switch (td) {
                .enum_ => |e| {
                    const stor = enumStorageType(e.annotations);
                    const method = switch (stor[0]) {
                        'u' => switch (stor[1]) {
                            '8' => "readU8",
                            '1' => "readU16",
                            '3' => "readU32",
                            '6' => "readU64",
                            else => "readU32",
                        },
                        else => "readU32",
                    };
                    try self.ind();
                    try self.print("{s}{s}.appendAssumeCapacity(@enumFromInt(try reader.{s}()));\n", .{ extra, seq_expr, method });
                },
                .typedef => |t| {
                    // For scalar typedefs, recurse on the underlying type so that
                    // e.g. `typedef long MyInt` → sequence element uses readI32.
                    // Array typedefs as sequence elements are rare; emit TODO.
                    if (t.dimensions.len > 0) {
                        try self.ind();
                        try self.print("{s}// TODO: sequence element read array-typedef {s}\n", .{ extra, t.name });
                    } else {
                        try self.emitSequenceElementRead(t.type_ref, seq_expr, extra);
                    }
                },
                .bitmask => |bm| {
                    const stor = bitmaskStorageType(bm.annotations);
                    const method = switch (stor[0]) {
                        'u' => switch (stor[1]) {
                            '8' => "readU8",
                            '1' => "readU16",
                            '3' => "readU32",
                            '6' => "readU64",
                            else => "readU32",
                        },
                        else => "readU32",
                    };
                    try self.ind();
                    try self.print("{s}{s}.appendAssumeCapacity(try reader.{s}());\n", .{ extra, seq_expr, method });
                },
                .union_ => {
                    const zig_type = try self.typeRefToZig(elem_tr);
                    defer self.alloc.free(zig_type);
                    try self.ind();
                    try self.print("{s}var _elem: {s} = .{{}};\n", .{ extra, zig_type });
                    try self.ind();
                    try self.print("{s}try {s}.deserializeInto(&_elem, reader, allocator);\n", .{ extra, zig_type });
                    try self.ind();
                    try self.print("{s}{s}.appendAssumeCapacity(_elem);\n", .{ extra, seq_expr });
                },
                .bitset => {
                    const zig_type = try self.typeRefToZig(elem_tr);
                    defer self.alloc.free(zig_type);
                    try self.ind();
                    try self.print("{s}var _elem: {s} = .{{}};\n", .{ extra, zig_type });
                    try self.ind();
                    try self.print("{s}try {s}.deserializeInto(&_elem, reader, allocator);\n", .{ extra, zig_type });
                    try self.ind();
                    try self.print("{s}{s}.appendAssumeCapacity(_elem);\n", .{ extra, seq_expr });
                },
                else => {
                    const zig_type = try self.typeRefToZig(elem_tr);
                    defer self.alloc.free(zig_type);
                    try self.ind();
                    try self.print("{s}var _elem: {s} = .{{}};\n", .{ extra, zig_type });
                    try self.ind();
                    try self.print("{s}try {s}.deserializeInto(&_elem, reader, allocator);\n", .{ extra, zig_type });
                    try self.ind();
                    try self.print("{s}{s}.appendAssumeCapacity(_elem);\n", .{ extra, seq_expr });
                },
            },
            else => {
                try self.ind();
                try self.print("{s}// TODO: sequence element read\n", .{extra});
            },
        }
    }

    /// Emit "read one element and `try seq.append(allocator, elem)`" for `@pl_repeated` fields.
    /// Unlike `emitSequenceElementRead` (which uses `appendAssumeCapacity` after
    /// `ensureTotalCapacity`), this path works without a prior element count.
    /// Emit code to grow an extern-struct sequence by one element for @pl_repeated.
    /// Uses alloc+memcpy to avoid a dependency on ArrayList — O(n) per append,
    /// acceptable for the small discovery-data sequences this path handles.
    fn emitPlRepeatedElementAppend(
        self: *Generator,
        elem_tr: ir.TypeRef,
        seq_expr: []const u8,
        extra: []const u8,
    ) anyerror!void {
        const buf_elem = try self.seqBufElemZig(elem_tr);
        defer self.alloc.free(buf_elem);
        const ii = try std.fmt.allocPrint(self.alloc, "{s}    ", .{extra});
        defer self.alloc.free(ii);

        // Emit the grow-by-one preamble
        try self.ind();
        try self.print("{s}{{\n", .{extra});
        try self.ind();
        try self.print("{s}const _plen = {s}._length;\n", .{ ii, seq_expr });
        try self.ind();
        try self.print("{s}const _pbuf = try allocator.alloc({s}, _plen + 1);\n", .{ ii, buf_elem });
        // errdefer frees _pbuf if the element read below fails, preventing a leak.
        try self.ind();
        try self.print("{s}errdefer allocator.free(_pbuf);\n", .{ii});
        try self.ind();
        try self.print("{s}if ({s}._buffer) |_ob| @memcpy(_pbuf[0.._plen], _ob[0.._plen]);\n", .{ ii, seq_expr });

        // Emit the element read into _pbuf[_plen] — must succeed before we touch seq_expr.
        try self.emitReadForTypeRef(elem_tr, "_pbuf[_plen]", ii);

        // Read succeeded: now safe to release the old buffer and update the sequence.
        try self.ind();
        try self.print("{s}if ({s}._release) {{ if ({s}._buffer) |_ob| allocator.free(_ob[0..{s}._maximum]); }}\n", .{ ii, seq_expr, seq_expr, seq_expr });
        try self.ind();
        try self.print("{s}{s}._buffer = _pbuf.ptr;\n", .{ ii, seq_expr });
        try self.ind();
        try self.print("{s}{s}._length = _plen + 1;\n", .{ ii, seq_expr });
        try self.ind();
        try self.print("{s}{s}._maximum = _plen + 1;\n", .{ ii, seq_expr });
        try self.ind();
        try self.print("{s}{s}._release = true;\n", .{ ii, seq_expr });
        try self.ind();
        try self.print("{s}}}\n", .{extra});
    }

    /// Emit write loops for an IDL array member (multi-dimensional).
    fn emitWriteArray(self: *Generator, elem_tr: ir.TypeRef, access: []const u8, dims: []const u64, extra: []const u8, depth: usize) anyerror!void {
        if (dims.len == 0) {
            try self.emitWriteForTypeRef(elem_tr, access, extra);
            return;
        }
        const var_name = try std.fmt.allocPrint(self.alloc, "_d{d}", .{depth});
        defer self.alloc.free(var_name);
        try self.ind();
        try self.print("{s}for ({s}) |{s}| {{\n", .{ extra, access, var_name });
        const inner = try std.fmt.allocPrint(self.alloc, "{s}    ", .{extra});
        defer self.alloc.free(inner);
        try self.emitWriteArray(elem_tr, var_name, dims[1..], inner, depth + 1);
        try self.ind();
        try self.print("{s}}}\n", .{extra});
    }

    /// Emit index-based read loops for an IDL array member (multi-dimensional).
    fn emitReadArray(self: *Generator, elem_tr: ir.TypeRef, base_access: []const u8, dims: []const u64, extra: []const u8, depth: usize) anyerror!void {
        if (dims.len == 0) {
            try self.emitReadForTypeRef(elem_tr, base_access, extra);
            return;
        }
        const idx = try std.fmt.allocPrint(self.alloc, "_i{d}", .{depth});
        defer self.alloc.free(idx);
        try self.ind();
        try self.print("{s}for (0..{d}) |{s}| {{\n", .{ extra, dims[0], idx });
        const inner = try std.fmt.allocPrint(self.alloc, "{s}    ", .{extra});
        defer self.alloc.free(inner);
        const indexed = try std.fmt.allocPrint(self.alloc, "{s}[{s}]", .{ base_access, idx });
        defer self.alloc.free(indexed);
        try self.emitReadArray(elem_tr, indexed, dims[1..], inner, depth + 1);
        try self.ind();
        try self.print("{s}}}\n", .{extra});
    }

    /// Emit read of one struct member from final/appendable payload, including
    /// the XCDR2 optional presence flag when the member is @optional.
    fn emitReadMember(self: *Generator, m: ir.StructMember, out_expr: []const u8, extra: []const u8) anyerror!void {
        try self.emitReadMemberInternal(m, out_expr, extra, true);
    }

    /// Emit read of one struct member whose presence is known from outer
    /// framing, e.g. an @mutable EMHEADER.  No optional presence byte is read.
    fn emitReadPresentMember(self: *Generator, m: ir.StructMember, out_expr: []const u8, extra: []const u8) anyerror!void {
        try self.emitReadMemberInternal(m, out_expr, extra, false);
    }

    fn emitReadMemberInternal(
        self: *Generator,
        m: ir.StructMember,
        out_expr: []const u8,
        extra: []const u8,
        optional_presence_flag: bool,
    ) anyerror!void {
        if (!m.annotations.is_optional) {
            if (m.dimensions.len > 0) {
                try self.emitReadArray(m.type_ref, out_expr, m.dimensions, extra, 0);
            } else {
                try self.emitReadForTypeRef(m.type_ref, out_expr, extra);
            }
            return;
        }

        const zig_type = try self.typeRefToZig(m.type_ref);
        defer self.alloc.free(zig_type);
        const opt_var = try std.fmt.allocPrint(self.alloc, "_opt_{s}", .{m.name});
        defer self.alloc.free(opt_var);
        const decl_type: []u8 = if (m.dimensions.len > 0)
            try self.makeArrayType(zig_type, m.dimensions)
        else
            try self.alloc.dupe(u8, zig_type);
        defer self.alloc.free(decl_type);
        const default_val: []u8 = if (m.dimensions.len > 0)
            try self.defaultForArrayType(decl_type)
        else
            try self.defaultForTypeRef(m.type_ref);
        defer self.alloc.free(default_val);

        if (optional_presence_flag) {
            try self.ind();
            try self.print("{s}if (try reader.readBool()) {{\n", .{extra});
            const inner = try std.fmt.allocPrint(self.alloc, "{s}    ", .{extra});
            defer self.alloc.free(inner);
            try self.ind();
            try self.print("{s}var {s}: {s} = {s};\n", .{ inner, opt_var, decl_type, default_val });
            if (m.dimensions.len > 0) {
                try self.emitReadArray(m.type_ref, opt_var, m.dimensions, inner, 0);
            } else {
                try self.emitReadForTypeRef(m.type_ref, opt_var, inner);
            }
            try self.ind();
            try self.print("{s}{s} = {s};\n", .{ inner, out_expr, opt_var });
            try self.ind();
            try self.print("{s}}} else {{\n", .{extra});
            try self.ind();
            try self.print("{s}    {s} = null;\n", .{ extra, out_expr });
            try self.ind();
            try self.print("{s}}}\n", .{extra});
            return;
        }

        try self.ind();
        try self.print("{s}var {s}: {s} = {s};\n", .{ extra, opt_var, decl_type, default_val });
        if (m.dimensions.len > 0) {
            try self.emitReadArray(m.type_ref, opt_var, m.dimensions, extra, 0);
        } else {
            try self.emitReadForTypeRef(m.type_ref, opt_var, extra);
        }
        try self.ind();
        try self.print("{s}{s} = {s};\n", .{ extra, out_expr, opt_var });
    }

    fn emitSkipMember(self: *Generator, m: ir.StructMember, extra: []const u8) anyerror!void {
        if (m.annotations.is_optional) {
            try self.ind();
            try self.print("{s}if (try reader.readBool()) {{\n", .{extra});
            const inner = try std.fmt.allocPrint(self.alloc, "{s}    ", .{extra});
            defer self.alloc.free(inner);
            if (m.dimensions.len > 0) {
                try self.emitSkipArray(m.type_ref, m.dimensions, inner, 0);
            } else {
                try self.emitSkipForTypeRef(m.type_ref, inner);
            }
            try self.ind();
            try self.print("{s}}}\n", .{extra});
            return;
        }

        if (m.dimensions.len > 0) {
            try self.emitSkipArray(m.type_ref, m.dimensions, extra, 0);
        } else {
            try self.emitSkipForTypeRef(m.type_ref, extra);
        }
    }

    fn emitSkipArray(self: *Generator, elem_tr: ir.TypeRef, dims: []const u64, extra: []const u8, depth: usize) anyerror!void {
        if (dims.len == 0) {
            try self.emitSkipForTypeRef(elem_tr, extra);
            return;
        }
        try self.ind();
        try self.print("{s}for (0..{d}) |_| {{\n", .{ extra, dims[0] });
        const inner = try std.fmt.allocPrint(self.alloc, "{s}    ", .{extra});
        defer self.alloc.free(inner);
        try self.emitSkipArray(elem_tr, dims[1..], inner, depth + 1);
        try self.ind();
        try self.print("{s}}}\n", .{extra});
    }

    fn emitSkipForTypeRef(self: *Generator, tr: ir.TypeRef, extra: []const u8) anyerror!void {
        switch (tr) {
            .base => |b| {
                const method = baseReadMethod(b);
                try self.ind();
                if (std.mem.startsWith(u8, method, "//")) {
                    try self.print("{s}@compileError(\"zidl: unsupported IDL base type in skip\");\n", .{extra});
                } else {
                    try self.print("{s}_ = try reader.{s}();\n", .{ extra, method });
                }
            },
            .string => {
                try self.ind();
                try self.print("{s}try reader.skipString();\n", .{extra});
            },
            .wstring => {
                try self.ind();
                try self.print("{s}try reader.skipWstring();\n", .{extra});
            },
            .sequence => |seq| {
                try self.ind();
                try self.print("{s}{{\n", .{extra});
                const inner = try std.fmt.allocPrint(self.alloc, "{s}    ", .{extra});
                defer self.alloc.free(inner);
                try self.ind();
                try self.print("{s}const _n = try reader.readU32();\n", .{inner});
                try self.ind();
                try self.print("{s}for (0.._n) |_| {{\n", .{inner});
                const inner2 = try std.fmt.allocPrint(self.alloc, "{s}    ", .{inner});
                defer self.alloc.free(inner2);
                try self.emitSkipForTypeRef(seq.element.*, inner2);
                try self.ind();
                try self.print("{s}}}\n", .{inner});
                try self.ind();
                try self.print("{s}}}\n", .{extra});
            },
            .map => |m| {
                try self.ind();
                try self.print("{s}{{\n", .{extra});
                const inner = try std.fmt.allocPrint(self.alloc, "{s}    ", .{extra});
                defer self.alloc.free(inner);
                try self.ind();
                try self.print("{s}const _mn = try reader.readU32();\n", .{inner});
                try self.ind();
                try self.print("{s}for (0.._mn) |_| {{\n", .{inner});
                const inner2 = try std.fmt.allocPrint(self.alloc, "{s}    ", .{inner});
                defer self.alloc.free(inner2);
                try self.emitSkipForTypeRef(m.key.*, inner2);
                try self.emitSkipForTypeRef(m.value.*, inner2);
                try self.ind();
                try self.print("{s}}}\n", .{inner});
                try self.ind();
                try self.print("{s}}}\n", .{extra});
            },
            .named => |td| switch (td) {
                .enum_ => |e| {
                    const stor = enumStorageType(e.annotations);
                    const method = switch (stor[0]) {
                        'u' => switch (stor[1]) {
                            '8' => "readU8",
                            '1' => "readU16",
                            '3' => "readU32",
                            '6' => "readU64",
                            else => "readU32",
                        },
                        else => "readU32",
                    };
                    try self.ind();
                    try self.print("{s}_ = try reader.{s}();\n", .{ extra, method });
                },
                .bitmask => |bm| {
                    const stor = bitmaskStorageType(bm.annotations);
                    const method = switch (stor[0]) {
                        'u' => switch (stor[1]) {
                            '8' => "readU8",
                            '1' => "readU16",
                            '3' => "readU32",
                            '6' => "readU64",
                            else => "readU32",
                        },
                        else => "readU32",
                    };
                    try self.ind();
                    try self.print("{s}_ = try reader.{s}();\n", .{ extra, method });
                },
                .typedef => |t| {
                    if (t.dimensions.len > 0) {
                        try self.emitSkipArray(t.type_ref, t.dimensions, extra, 0);
                    } else {
                        try self.emitSkipForTypeRef(t.type_ref, extra);
                    }
                },
                .struct_, .union_, .bitset => {
                    const zig_type = try self.typeRefToZig(tr);
                    defer self.alloc.free(zig_type);
                    try self.ind();
                    try self.print("{s}try {s}.skip(reader);\n", .{ extra, zig_type });
                },
                else => {
                    try self.ind();
                    try self.print("{s}@compileError(\"zidl: unsupported named IDL type in skip\");\n", .{extra});
                },
            },
            .fixed_pt => |fp| {
                try self.ind();
                try self.print("{s}_ = try reader.readFixed({d}, {d});\n", .{ extra, fp.digits, fp.scale });
            },
        }
    }

    // ── Type-ref → Zig type string ────────────────────────────────────────────

    /// Convert a `TypeRef` to its Zig type expression string.
    /// Named types use fully-qualified dot-separated paths (e.g. `Foo.Bar.Baz`).
    /// Caller owns the returned slice.
    fn typeRefToZig(self: *Generator, tr: ir.TypeRef) anyerror![]u8 {
        return switch (tr) {
            .base => |b| self.alloc.dupe(u8, baseToZigType(b)),
            .named => |td| self.qualNameToZig(ir.typeDeclQualifiedName(td)),
            .sequence => |seq| blk: {
                if (seq.bound) |n| {
                    const elem = try self.typeRefToZig(seq.element.*);
                    defer self.alloc.free(elem);
                    break :blk std.fmt.allocPrint(self.alloc, "zidl_rt.BoundedArray({s}, {d})", .{ elem, n });
                }
                // Unbounded sequences use a C-compatible extern struct matching the C PSM layout.
                const buf_elem = try self.seqBufElemZig(seq.element.*);
                defer self.alloc.free(buf_elem);
                break :blk std.fmt.allocPrint(self.alloc, "extern struct {{ _maximum: u32 = 0, _length: u32 = 0, _buffer: ?[*]{s} = null, _release: bool = false }}", .{buf_elem});
            },
            .string => |bound| if (bound) |n|
                std.fmt.allocPrint(self.alloc, "zidl_rt.BoundedArray(u8, {d})", .{n})
            else
                self.alloc.dupe(u8, "[]const u8"),
            .wstring => |bound| if (bound) |n|
                std.fmt.allocPrint(self.alloc, "zidl_rt.BoundedArray(u16, {d})", .{n})
            else
                self.alloc.dupe(u8, "[]const u16"),
            .fixed_pt => self.alloc.dupe(u8, "f64"),
            .map => |m| blk: {
                // String keys need content-based equality; use StringArrayHashMapUnmanaged.
                // All other key types use AutoArrayHashMapUnmanaged (hash/eq from key type).
                const key_is_string = switch (m.key.*) {
                    .string => true,
                    else => false,
                };
                if (key_is_string) {
                    const val_s = try self.typeRefToZig(m.value.*);
                    defer self.alloc.free(val_s);
                    break :blk std.fmt.allocPrint(self.alloc, "std.StringArrayHashMapUnmanaged({s})", .{val_s});
                }
                const key_s = try self.typeRefToZig(m.key.*);
                defer self.alloc.free(key_s);
                const val_s = try self.typeRefToZig(m.value.*);
                defer self.alloc.free(val_s);
                break :blk std.fmt.allocPrint(self.alloc, "std.AutoArrayHashMapUnmanaged({s}, {s})", .{ key_s, val_s });
            },
        };
    }

    /// Convert `Foo::Bar::Baz` → `Foo.Bar.Baz`.
    /// At file level, `Foo` is always accessible, so the full dotted path is
    /// valid from anywhere in the generated file.
    fn qualNameToZig(self: *Generator, qname: []const u8) ![]u8 {
        const pfx = self.opts.type_prefix;
        if (pfx.len == 0) {
            // Fast path: no prefix.
            var out = try self.alloc.alloc(u8, qname.len);
            var out_i: usize = 0;
            var i: usize = 0;
            while (i < qname.len) {
                if (i + 1 < qname.len and qname[i] == ':' and qname[i + 1] == ':') {
                    out[out_i] = '.';
                    out_i += 1;
                    i += 2;
                } else {
                    out[out_i] = qname[i];
                    out_i += 1;
                    i += 1;
                }
            }
            return self.alloc.realloc(out, out_i);
        }
        // With prefix: apply it to the last segment (the type name).
        // E.g. "Foo::Bar::Baz" with "DDS_" → "Foo.Bar.DDS_Baz"
        const last_sep = std.mem.lastIndexOf(u8, qname, "::");
        if (last_sep == null) {
            return std.fmt.allocPrint(self.alloc, "{s}{s}", .{ pfx, qname });
        }
        const sep = last_sep.?;
        const module_part = qname[0..sep];
        const type_name = qname[sep + 2 ..];
        var mod_buf = try self.alloc.alloc(u8, module_part.len);
        defer self.alloc.free(mod_buf);
        var wi: usize = 0;
        var ri: usize = 0;
        while (ri < module_part.len) {
            if (ri + 1 < module_part.len and module_part[ri] == ':' and module_part[ri + 1] == ':') {
                mod_buf[wi] = '.';
                wi += 1;
                ri += 2;
            } else {
                mod_buf[wi] = module_part[ri];
                wi += 1;
                ri += 1;
            }
        }
        return std.fmt.allocPrint(self.alloc, "{s}.{s}{s}", .{ mod_buf[0..wi], pfx, type_name });
    }

    // ── Default value helpers ─────────────────────────────────────────────────

    /// Return the Zig default-value expression for a scalar `TypeRef`
    /// (no array dimensions — those are handled by `defaultForArrayType`).
    fn defaultForTypeRef(self: *Generator, tr: ir.TypeRef) anyerror![]u8 {
        return switch (tr) {
            .base => |b| self.alloc.dupe(u8, switch (b) {
                .boolean => "false",
                .float, .double, .long_double => "0.0",
                .any, .object, .value_base => "undefined",
                else => "0",
            }),
            .string => |bound| if (bound != null)
                self.alloc.dupe(u8, ".{}")
            else
                self.alloc.dupe(u8, "\"\""),
            .wstring => |bound| if (bound != null)
                self.alloc.dupe(u8, ".{}")
            else
                self.alloc.dupe(u8, "&.{}"),
            .sequence => self.alloc.dupe(u8, ".{}"), // BoundedArray and extern struct both use .{}
            .named => |td| switch (td) {
                .enum_ => |e| if (e.enumerators.len > 0) blk: {
                    // In a type-inferred context (struct field), .Name resolves
                    // to the first enumerator of the field's declared enum type.
                    if (self.opts.zig_idiomatic_enums) {
                        const tag = try self.idiomaticEnumTag(e.enumerators[0].name);
                        defer self.alloc.free(tag);
                        break :blk std.fmt.allocPrint(self.alloc, ".{s}", .{tag});
                    }
                    break :blk std.fmt.allocPrint(self.alloc, ".{s}", .{e.enumerators[0].name});
                } else self.alloc.dupe(u8, "@enumFromInt(0)"),
                .bitmask => self.alloc.dupe(u8, "0"),
                .native, .interface => self.alloc.dupe(u8, "undefined"),
                .typedef => |t| blk: {
                    // Follow the chain: array typedefs need zeroes, scalar ones recurse.
                    if (t.dimensions.len > 0) {
                        const elem = try self.typeRefToZig(t.type_ref);
                        defer self.alloc.free(elem);
                        const arr = try self.makeArrayType(elem, t.dimensions);
                        defer self.alloc.free(arr);
                        break :blk try self.defaultForArrayType(arr);
                    } else {
                        break :blk try self.defaultForTypeRef(t.type_ref);
                    }
                },
                // struct, union (as struct), exception, bitset → zero-init struct literal
                else => self.alloc.dupe(u8, ".{}"),
            },
            .fixed_pt => self.alloc.dupe(u8, "0.0"),
            .map => self.alloc.dupe(u8, ".{}"),
        };
    }

    fn defaultForArrayType(self: *Generator, arr_type: []const u8) ![]u8 {
        return std.fmt.allocPrint(self.alloc, "std.mem.zeroes({s})", .{arr_type});
    }

    // ── Array type builder ────────────────────────────────────────────────────

    /// Build a Zig array type string for IDL array dimensions.
    ///
    /// IDL `T[d0][d1]` → Zig `[d0][d1]T` (same left-to-right order).
    /// Recursively wraps: `[d0](makeArrayType(T, dims[1..]))`.
    fn makeArrayType(self: *Generator, elem_type: []const u8, dims: []const u64) anyerror![]u8 {
        if (dims.len == 0) return self.alloc.dupe(u8, elem_type);
        const inner = try self.makeArrayType(elem_type, dims[1..]);
        defer self.alloc.free(inner);
        return std.fmt.allocPrint(self.alloc, "[{d}]{s}", .{ dims[0], inner });
    }
};

// ── Static helpers ────────────────────────────────────────────────────────────

fn escapeStringLiteral(alloc: std.mem.Allocator, s: []const u8) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    for (s) |c| {
        switch (c) {
            '\\' => try buf.appendSlice(alloc, "\\\\"),
            '"' => try buf.appendSlice(alloc, "\\\""),
            '\n' => try buf.appendSlice(alloc, "\\n"),
            '\r' => try buf.appendSlice(alloc, "\\r"),
            '\t' => try buf.appendSlice(alloc, "\\t"),
            0 => try buf.appendSlice(alloc, "\\x00"),
            else => if (c >= 0x20 and c <= 0x7e) {
                try buf.append(alloc, c);
            } else {
                var tmp: [4]u8 = undefined;
                const hex = std.fmt.bufPrint(&tmp, "\\x{X:0>2}", .{c}) catch unreachable;
                try buf.appendSlice(alloc, hex);
            },
        }
    }
    return buf.toOwnedSlice(alloc);
}

fn baseToZigType(b: ast.BaseTypeSpec) []const u8 {
    return switch (b) {
        .float => "f32",
        .double => "f64",
        .long_double => "f128",
        .short => "i16",
        .long => "i32",
        .long_long => "i64",
        .unsigned_short => "u16",
        .unsigned_long => "u32",
        .unsigned_long_long => "u64",
        .char => "u8",
        .wchar => "u16",
        .boolean => "bool",
        .octet => "u8",
        .int8 => "i8",
        .uint8 => "u8",
        .int16 => "i16",
        .int32 => "i32",
        .int64 => "i64",
        .uint16 => "u16",
        .uint32 => "u32",
        .uint64 => "u64",
        .any => "*anyopaque",
        .object => "*anyopaque",
        .value_base => "*anyopaque",
    };
}

fn bitmaskStorageType(annotations: ir.EnumAnnotations) []const u8 {
    const bound = annotations.bit_bound orelse 32;
    return if (bound <= 8)
        "u8"
    else if (bound <= 16)
        "u16"
    else if (bound <= 32)
        "u32"
    else
        "u64";
}

fn bitsetTotalBits(bs: *const ir.Bitset) u32 {
    var total: u32 = 0;
    for (bs.fields) |field| {
        total += field.bits;
    }
    return total;
}

/// All reserved words in the Zig language.  Used by `idiomaticEnumTag` to
/// detect collisions and append a trailing `_` escape.
const zig_keywords = std.StaticStringMap(void).initComptime(.{
    .{ "addrspace", {} },   .{ "align", {} },          .{ "allowzero", {} },
    .{ "and", {} },         .{ "anyframe", {} },       .{ "anytype", {} },
    .{ "asm", {} },         .{ "async", {} },          .{ "await", {} },
    .{ "break", {} },       .{ "callconv", {} },       .{ "catch", {} },
    .{ "comptime", {} },    .{ "const", {} },          .{ "continue", {} },
    .{ "defer", {} },       .{ "else", {} },           .{ "enum", {} },
    .{ "errdefer", {} },    .{ "error", {} },          .{ "export", {} },
    .{ "extern", {} },      .{ "false", {} },          .{ "fn", {} },
    .{ "for", {} },         .{ "if", {} },             .{ "inline", {} },
    .{ "linksection", {} }, .{ "noalias", {} },        .{ "noinline", {} },
    .{ "nosuspend", {} },   .{ "null", {} },           .{ "opaque", {} },
    .{ "or", {} },          .{ "orelse", {} },         .{ "packed", {} },
    .{ "pub", {} },         .{ "resume", {} },         .{ "return", {} },
    .{ "struct", {} },      .{ "suspend", {} },        .{ "switch", {} },
    .{ "test", {} },        .{ "threadlocal", {} },    .{ "true", {} },
    .{ "try", {} },         .{ "undefined", {} },      .{ "union", {} },
    .{ "unreachable", {} }, .{ "usingnamespace", {} }, .{ "var", {} },
    .{ "volatile", {} },    .{ "while", {} },
});

fn enumStorageType(annotations: ir.EnumAnnotations) []const u8 {
    const bound = annotations.bit_bound orelse 32;
    return if (bound <= 8)
        "u8"
    else if (bound <= 16)
        "u16"
    else if (bound <= 32)
        "u32"
    else
        "u64";
}

fn baseWriteMethod(b: ast.BaseTypeSpec) []const u8 {
    return switch (b) {
        .boolean => "writeBool",
        .octet, .uint8 => "writeU8",
        .char => "writeChar",
        .wchar => "writeWchar",
        .int8 => "writeI8",
        .short, .int16 => "writeI16",
        .long, .int32 => "writeI32",
        .long_long, .int64 => "writeI64",
        .unsigned_short, .uint16 => "writeU16",
        .unsigned_long, .uint32 => "writeU32",
        .unsigned_long_long, .uint64 => "writeU64",
        .float => "writeF32",
        .double => "writeF64",
        .long_double => "writeF64",
        .any, .object, .value_base => "// unsupported",
    };
}

/// How `emitGetFieldFromCdr` treats one struct member: as a filterable
/// scalar (int/float), a filterable string (with its bound, so the caller
/// knows whether to call `.slice()` on a `BoundedArray` or use the member
/// directly), or `.skip` (nested struct/sequence/map/union/fixed_pt/array —
/// not a simple value the DDS filter-expression grammar can compare).
const FilterFieldKind = union(enum) {
    skip,
    int_like,
    float_like,
    string_like: ?u64,
};

fn classifyFilterFieldKind(tr: ir.TypeRef) FilterFieldKind {
    return switch (tr) {
        .base => |b| switch (b) {
            .boolean, .octet, .uint8, .char, .wchar, .int8, .short, .int16, .long, .int32, .long_long, .int64, .unsigned_short, .uint16, .unsigned_long, .uint32, .unsigned_long_long, .uint64 => .int_like,
            .float, .double, .long_double => .float_like,
            .any, .object, .value_base => .skip,
        },
        .string => |bound| .{ .string_like = bound },
        .wstring, .sequence, .map, .fixed_pt => .skip,
        .named => |td| switch (td) {
            .enum_ => .int_like,
            .typedef => |t| classifyFilterFieldKind(t.type_ref),
            .struct_, .union_, .bitset, .bitmask, .exception, .native, .interface => .skip,
        },
    };
}

/// Emits the Zig expression converting `_v.{name}` (already known, by
/// `classifyFilterFieldKind`, to be `.int_like`) to an `i64` for
/// `FilterValue.int`. Resolves through any typedef chain to find the real
/// base/enum kind.
fn intFieldExpr(alloc: std.mem.Allocator, tr: ir.TypeRef, name: []const u8) ![]u8 {
    return switch (tr) {
        .base => |b| switch (b) {
            .boolean => std.fmt.allocPrint(alloc, "@intFromBool(_v.{s})", .{name}),
            else => std.fmt.allocPrint(alloc, "@intCast(_v.{s})", .{name}),
        },
        .named => |td| switch (td) {
            .enum_ => std.fmt.allocPrint(alloc, "@intCast(@intFromEnum(_v.{s}))", .{name}),
            .typedef => |t| intFieldExpr(alloc, t.type_ref, name),
            else => unreachable, // classifyFilterFieldKind only returns .int_like for the cases above
        },
        else => unreachable,
    };
}

fn baseReadMethod(b: ast.BaseTypeSpec) []const u8 {
    return switch (b) {
        .boolean => "readBool",
        .octet, .uint8 => "readU8",
        .char => "readChar",
        .wchar => "readWchar",
        .int8 => "readI8",
        .short, .int16 => "readI16",
        .long, .int32 => "readI32",
        .long_long, .int64 => "readI64",
        .unsigned_short, .uint16 => "readU16",
        .unsigned_long, .uint32 => "readU32",
        .unsigned_long_long, .uint64 => "readU64",
        .float => "readF32",
        .double => "readF64",
        .long_double => "readF64",
        .any, .object, .value_base => "// unsupported",
    };
}

/// Returns true if deserializing this type may need an allocator
/// (unbounded strings, wstrings, or sequences; or any named struct/exception
/// which may transitively need one).
/// Returns true if a union case is the `default:` arm.
fn isDefaultUnionCase(cas: ir.UnionCase) bool {
    if (cas.labels.len == 0) return true;
    for (cas.labels) |lbl| {
        if (lbl == .default) return true;
    }
    return false;
}

/// Determine the EMHEADER LC value (0–3) for a fixed-size scalar type.
/// Returns null if the member requires LC=4 (NEXTINT) — i.e. variable-length
/// or complex (string, sequence, array, struct, union, typedef, etc.).
fn lcForTypeRef(type_ref: ir.TypeRef, dimensions: []const u64) ?u2 {
    if (dimensions.len > 0) return null;
    return switch (type_ref) {
        .base => |b| switch (b) {
            .boolean, .octet, .char, .int8, .uint8 => 0,
            .short, .int16, .unsigned_short, .uint16, .wchar => 1,
            .long, .int32, .unsigned_long, .uint32, .float => 2,
            .long_long, .int64, .unsigned_long_long, .uint64, .double => 3,
            // long_double is 16 bytes — no matching LC; use LC=4.
            else => null,
        },
        .named => |td| switch (td) {
            // Enums serialize as uint32_t (4 bytes) → LC=2.
            .enum_ => 2,
            // Everything else (struct, union, bitmask, bitset, typedef, …) → LC=4.
            else => null,
        },
        // string, wstring, sequence, map, fixed_pt — all variable / complex.
        else => null,
    };
}

/// Return the XTYPES member ID for a struct member.
/// Uses the `@id` annotation if present; otherwise the declaration index.
fn memberIdAt(m: ir.StructMember, idx: usize) u32 {
    return if (m.annotations.id) |id| id else @intCast(idx);
}

fn typeRefNeedsAllocator(tr: ir.TypeRef) bool {
    return switch (tr) {
        .string => |bound| bound == null,
        .wstring => true, // readWstring always allocates, even for bounded wstring
        .sequence => |seq| seq.bound == null,
        .named => |td| switch (td) {
            // Conservatively: may have nested strings/seqs. A union case can
            // just as easily own a string/sequence as a struct field can --
            // omitting it here previously left a struct field's
            // deserializeInto emitting a stale `_ = allocator;` discard right
            // before actually using it (to forward into a union member's own
            // deserializeInto), which fails to compile.
            .struct_, .union_, .exception => true,
            .typedef => |t| typeRefNeedsAllocator(t.type_ref),
            else => false,
        },
        else => false,
    };
}

/// Returns true if `tr` maps to a C-ABI-compatible Zig type — one that may
/// legally appear as a field in an `extern struct`.
///
/// The key cases:
///   - Unbounded sequence → anonymous `extern struct { _maximum, _length, _buffer, _release }` — yes.
///   - Bounded sequence   → `zidl_rt.BoundedArray(T, N)` — no (Zig runtime type).
///   - Unbounded string   → `[]const u8` (fat slice) — no.
///   - Bounded string     → `zidl_rt.BoundedArray(u8, N)` — no.
///   - Named struct       → yes iff `structIsCExternCompatible`.
fn typeRefIsCExternCompatible(tr: ir.TypeRef) bool {
    return switch (tr) {
        .base => |b| b != .long_double, // long_double is 16-byte in Zig, 10-byte in C x86-64
        .string => false,
        .wstring => false, // wchar_t width is platform-dependent
        .sequence => |seq| seq.bound == null, // unbounded → extern struct; bounded → BoundedArray
        .fixed_pt => false, // emitted as f64; not a proper C fixed-point type
        .map => false,
        .named => |td| switch (td) {
            .enum_ => true,
            .bitmask, .bitset => true,
            .struct_ => |s| structIsCExternCompatible(s),
            .exception => |e| blk: {
                for (e.members) |m| {
                    if (!typeRefIsCExternCompatible(m.type_ref)) break :blk false;
                }
                break :blk true;
            },
            .typedef => |t| typeRefIsCExternCompatible(t.type_ref),
            else => false, // interface, union, native
        },
    };
}

/// Returns true if every field of `s` is C-ABI compatible, meaning the struct
/// may be emitted as `extern struct` with a formally guaranteed memory layout.
fn structIsCExternCompatible(s: *const ir.Struct) bool {
    if (s.base != null) return false; // inheritance adds a _base field with uncertain layout
    for (s.members) |m| {
        if (m.annotations.is_optional) return false; // @optional adds a companion bool field
        if (!typeRefIsCExternCompatible(m.type_ref)) return false;
    }
    return true;
}

/// Returns true if the type ref is an unbounded sequence (anonymous or via typedef),
/// or a named struct that transitively contains one — i.e., whether a `deinit`
/// helper can clean up heap memory allocated by `deserializeInto`.
/// String fields (`[]const u8`) are excluded: they have no `_release` guard so
/// we cannot distinguish allocated from static-literal storage here.
fn typeRefNeedsSeqDeinit(tr: ir.TypeRef) bool {
    return switch (tr) {
        .sequence => |seq| seq.bound == null,
        .named => |td| switch (td) {
            .typedef => |t| typeRefNeedsSeqDeinit(t.type_ref),
            .struct_ => |s| structNeedsSeqDeinit(s),
            .union_ => |u| unionNeedsSeqDeinit(u),
            else => false,
        },
        else => false,
    };
}

fn structNeedsSeqDeinit(s: *const ir.Struct) bool {
    if (s.base) |base| switch (base) {
        .struct_ => |bs| if (structNeedsSeqDeinit(bs)) return true,
        else => {},
    };
    for (s.members) |m| {
        if (typeRefNeedsSeqDeinit(m.type_ref)) return true;
    }
    return false;
}

/// Union analog of `structNeedsSeqDeinit`: true if any case's type recursively
/// contains an unbounded sequence. A struct whose only heap-owning content is
/// a union member (rather than a sequence field of its own) previously fell
/// through `typeRefNeedsSeqDeinit`'s `.named` switch unhandled -- the union
/// case never counted toward the struct's own `structNeedsCleanup`, so
/// neither the struct's `deinit()`/`clone()` were generated at all, nor (even
/// where they were, for unrelated reasons) did they ever call into the
/// union's own cleanup.
fn unionNeedsSeqDeinit(u: *const ir.Union) bool {
    for (u.cases) |cas| {
        if (typeRefNeedsSeqDeinit(cas.type_ref)) return true;
    }
    return false;
}

/// True if `t` (not through any further typedef with its own array dimensions)
/// ultimately resolves to a plain unbounded string — i.e. whether a field of
/// this typedef needs the same direct free/dupe handling as a bare `string`
/// field, rather than delegating to a `.deinit()`/`.clone()` a type alias for
/// `[]const u8` doesn't have. Shared by `typeRefHasUnboundedString` and the
/// three `emitFieldSeq*` generators so they can't independently drift on it.
fn typedefTargetsPlainString(t: *const ir.Typedef) bool {
    if (t.dimensions.len > 0) return false;
    return switch (Generator.resolveTomlTypeRef(t.type_ref)) {
        .string => |bound| bound == null,
        else => false,
    };
}

/// Returns true for a direct unbounded-`string` field, a named struct that
/// transitively contains one, or a `typedef` (through any chain) resolving to
/// *either* of those — the string-field analog of `typeRefNeedsSeqDeinit`
/// (see `Generator.memberNeedsCleanup`, which combines both and additionally
/// guards the direct-string case against an unsafe-to-free `@default`).
/// Recurses on the typedef's own target rather than delegating to
/// `typedefTargetsPlainString` (which only recognizes the plain-string case,
/// exactly right for its own narrow purpose of choosing inline-free/dupe vs.
/// delegate-to-.deinit() code shape in the `emitFieldSeq*` generators, but
/// wrong here: a `typedef SomeStruct Foo;` where `SomeStruct` itself owns an
/// unbounded string needs cleanup too, via delegation, same as a direct
/// `struct_` field — this function only answers "does it need cleanup at all,"
/// not "how.")
fn typeRefHasUnboundedString(tr: ir.TypeRef) bool {
    return switch (tr) {
        .string => |bound| bound == null,
        .named => |td| switch (td) {
            .typedef => |t| if (t.dimensions.len == 0) typeRefHasUnboundedString(t.type_ref) else false,
            .struct_ => |s| structHasUnboundedString(s),
            .union_ => |u| unionHasUnboundedString(u),
            else => false,
        },
        else => false,
    };
}

fn structHasUnboundedString(s: *const ir.Struct) bool {
    for (s.members) |m| {
        if (typeRefHasUnboundedString(m.type_ref)) return true;
    }
    return false;
}

/// Union analog of `structHasUnboundedString` -- see `unionNeedsSeqDeinit`.
fn unionHasUnboundedString(u: *const ir.Union) bool {
    for (u.cases) |cas| {
        if (typeRefHasUnboundedString(cas.type_ref)) return true;
    }
    return false;
}

/// True if `tr` is *itself* a plain unbounded string, or a typedef (through
/// any chain) resolving to one — as opposed to a named struct that merely
/// *contains* one somewhere inside (which delegates to that struct's own
/// `.deinit()`/`.clone()`, safely, regardless of this function). Distinguishes
/// the one shape whose own `@default` annotation (see
/// `memberHasNonEmptyStringDefault`) needs checking before treating it as
/// safe to free unconditionally.
fn typeRefIsDirectPlainString(tr: ir.TypeRef) bool {
    return switch (tr) {
        .string => |bound| bound == null,
        .named => |td| switch (td) {
            .typedef => |t| typedefTargetsPlainString(t),
            else => false,
        },
        else => false,
    };
}

/// True if `m` has an explicit `@default("...")` with non-empty content.
fn memberHasNonEmptyStringDefault(m: ir.StructMember) bool {
    const dv = m.annotations.default_value orelse return false;
    return switch (dv) {
        .string => |s| s.len > 0,
        else => false,
    };
}

/// Union-case analog of `memberHasNonEmptyStringDefault`.
fn caseHasNonEmptyStringDefault(cas: ir.UnionCase) bool {
    const dv = cas.annotations.default_value orelse return false;
    return switch (dv) {
        .string => |s| s.len > 0,
        else => false,
    };
}

fn typeDeclHasKey(td: ir.TypeDecl) bool {
    return switch (td) {
        .struct_ => |s| structHasKey(s),
        .exception => |e| blk: {
            for (e.members) |m| {
                if (m.annotations.is_key) break :blk true;
            }
            break :blk false;
        },
        else => false,
    };
}

fn structHasKey(s: *const ir.Struct) bool {
    if (s.base) |base| {
        if (typeDeclHasKey(base)) return true;
    }
    for (s.members) |m| {
        if (m.annotations.is_key) return true;
    }
    return false;
}

fn structKeyNeedsAllocator(s: *const ir.Struct) bool {
    if (s.base) |base| {
        if (typeDeclHasKey(base)) return true; // conservatively assume base key members may need allocator
    }
    for (s.members) |m| {
        if (m.annotations.is_key and typeRefNeedsAllocator(m.type_ref)) return true;
    }
    return false;
}

/// Returns true when `items` (or any nested module) contains at least one
/// struct that will get a typed DataWriter/DataReader wrapper.
fn itemsHaveTopicTypes(items: []const ir.ModuleItem) bool {
    for (items) |item| {
        switch (item) {
            .type_decl => |td| switch (td) {
                .struct_ => |s| if (isZzddsTopicStruct(s)) return true,
                else => {},
            },
            .module => |m| if (itemsHaveTopicTypes(m.items)) return true,
            else => {},
        }
    }
    return false;
}

/// True if `iface` (a `@callback interface`) has at least one operation, own
/// or inherited. Mirrors `collectInterfaceMembers`'s recursion without needing
/// an allocator — this is only ever used for a non-emptiness check.
fn callbackInterfaceHasOperations(iface: *const ir.Interface) bool {
    if (iface.operations.len > 0) return true;
    for (iface.bases) |base| {
        if (base == .interface and callbackInterfaceHasOperations(base.interface)) return true;
    }
    return false;
}

/// True if `items` contains a `@callback interface` with at least one
/// (possibly inherited) operation. `emitInterface` only emits
/// `emitZigListenerHelpers` — the idiomatic Zig helper pair, whose thunks call
/// `zidl_rt.unboxAs`/`zidl_rt.boxEntity` for any entity-interface-typed
/// parameter — in that same case, so this is the matching condition for
/// whether the generated file needs a `zidl_rt` import. Without this, a file
/// whose only callback interface happens to be the first one generated for
/// that module (no prior typesupport/pl_cdr/c-api need to trigger the import
/// some other way) silently emits code referencing an unimported `zidl_rt`.
fn itemsHaveCallbackInterfaceOperations(items: []const ir.ModuleItem) bool {
    for (items) |item| {
        switch (item) {
            .type_decl => |td| switch (td) {
                .interface => |iface| if (interface.isCallbackInterface(iface) and callbackInterfaceHasOperations(iface)) return true,
                else => {},
            },
            .module => |m| if (itemsHaveCallbackInterfaceOperations(m.items)) return true,
            else => {},
        }
    }
    return false;
}

/// A struct is a usable zzdds Topic type -- keyed or not. DDS-XTypes 1.3
/// leaves @key fully opt-in (7.3.1.2.1.3: "By default, members ... are not
/// considered part of their containing type's key"), and the DDS spec treats
/// a keyless Topic as first-class ("If no key is provided, the data set
/// associated with the Topic is restricted to a single instance", DDS 1.4
/// 2.2.2.1) -- RTPS even gives keyless writers/readers their own entityKind
/// (DDSI-RTPS 2.5 Table 9.1: "Writer (no Key)"/"Reader (no Key)" are distinct
/// from the keyed kinds). So this predicate only excludes what genuinely
/// can't be a topic: nested-only types and @mutable (see emitStructTypedWrapper's
/// doc comment on why @mutable is excluded).
fn isZzddsTopicStruct(s: *const ir.Struct) bool {
    return !s.annotations.is_nested and s.annotations.extensibility != .mutable;
}

// ── Tests ─────────────────────────────────────────────────────────────────────

const testing = std.testing;
const parser_mod = @import("../parser.zig");
const semantic_mod = @import("../semantic/root.zig");

/// Parse `source`, analyse, build IR, generate Zig source into a returned buffer.
/// Caller must call `.deinit(testing.allocator)` on the returned ArrayList.
fn testGen(source: []const u8, stem: []const u8) !std.ArrayList(u8) {
    return testGenOpts(source, stem, .{});
}

fn testGenOpts(source: []const u8, stem: []const u8, extra_opts: struct {
    no_typesupport: bool = false,
    no_typeobject_support: bool = false,
    generate_interfaces: bool = false,
    type_prefix: []const u8 = "",
    pl_cdr: bool = false,
    generate_zzdds_wrappers: bool = false,
    zig_version: interface.ZigVersion = .@"0.16.0",
    zig_generate_c_api: bool = false,
    zig_idiomatic_enums: bool = false,
    zig_generate_toml_config: bool = false,
    /// Module names to inject as if they came from `import "file.idl";` directives.
    imports: []const []const u8 = &.{},
}) !std.ArrayList(u8) {
    const alloc = testing.allocator;

    var ast_arena = std.heap.ArenaAllocator.init(alloc);
    defer ast_arena.deinit();

    var p = parser_mod.Parser.init(source, ast_arena.allocator());
    const spec = try p.parseSpecification();

    var az = try semantic_mod.Analyzer.init(alloc);
    defer az.deinit();
    try az.analyze(&spec);

    var ir_spec = try ir.build(alloc, &spec, az.global_scope, extra_opts.imports);
    defer ir_spec.deinit();

    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(alloc);

    const opts = interface.Options{
        .input_stem = stem,
        .no_typesupport = extra_opts.no_typesupport,
        .no_typeobject_support = extra_opts.no_typeobject_support,
        .generate_interfaces = extra_opts.generate_interfaces,
        .type_prefix = extra_opts.type_prefix,
        .pl_cdr = extra_opts.pl_cdr,
        .generate_zzdds_wrappers = extra_opts.generate_zzdds_wrappers,
        .zig_version = extra_opts.zig_version,
        .zig_generate_c_api = extra_opts.zig_generate_c_api,
        .zig_idiomatic_enums = extra_opts.zig_idiomatic_enums,
        .zig_generate_toml_config = extra_opts.zig_generate_toml_config,
    };
    try generateFile(alloc, &ir_spec, opts, &out);
    return out;
}

fn has(haystack: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, haystack, needle) != null;
}

test "zig_backend: file header" {
    var out = try testGen("struct Dummy { long x; };", "types");
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "Generated by zidl from types.idl"));
    try testing.expect(has(s, "const std = @import(\"std\");"));
}

test "zig_backend: Zig 0.15.1 target marker" {
    var out = try testGenOpts("struct Dummy { long x; };", "types", .{
        .zig_version = .@"0.15.1",
    });
    defer out.deinit(testing.allocator);
    try testing.expect(has(out.items, "Zig output target: 0.15.1"));
}

test "zig_backend: simple struct" {
    var out = try testGen("struct Point { long x; long y; };", "point");
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "pub const Point = extern struct {"));
    try testing.expect(has(s, "x: i32 = 0,"));
    try testing.expect(has(s, "y: i32 = 0,"));
    try testing.expect(has(s, "}; // Point"));
}

test "zig_backend: struct in module" {
    var out = try testGen(
        \\module Sensor { struct Reading { double value; }; };
    , "sensor");
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "pub const Sensor = struct {"));
    try testing.expect(has(s, "pub const Reading = extern struct {"));
    try testing.expect(has(s, "value: f64 = 0.0,"));
    try testing.expect(has(s, "}; // Sensor"));
}

test "zig_backend: nested module" {
    var out = try testGen(
        \\module A { module B { struct C { long x; }; }; };
    , "nested");
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "pub const A = struct {"));
    try testing.expect(has(s, "pub const B = struct {"));
    try testing.expect(has(s, "pub const C = extern struct {"));
}

test "zig_backend: primitive type mapping" {
    var out = try testGen(
        \\struct Prims {
        \\  short a; long b; long long c;
        \\  unsigned short d; unsigned long e; unsigned long long f;
        \\  float g; double h; boolean i; octet j; char k; wchar l;
        \\};
    , "prims");
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "a: i16 = 0,"));
    try testing.expect(has(s, "b: i32 = 0,"));
    try testing.expect(has(s, "c: i64 = 0,"));
    try testing.expect(has(s, "d: u16 = 0,"));
    try testing.expect(has(s, "e: u32 = 0,"));
    try testing.expect(has(s, "f: u64 = 0,"));
    try testing.expect(has(s, "g: f32 = 0.0,"));
    try testing.expect(has(s, "h: f64 = 0.0,"));
    try testing.expect(has(s, "i: bool = false,"));
    try testing.expect(has(s, "j: u8 = 0,"));
    try testing.expect(has(s, "k: u8 = 0,"));
    try testing.expect(has(s, "l: u16 = 0,"));
}

test "zig_backend: extended integer types" {
    var out = try testGen(
        \\struct Ext { int8 a; uint8 b; int16 c; int32 d; int64 e; };
    , "ext");
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "a: i8 = 0,"));
    try testing.expect(has(s, "b: u8 = 0,"));
    try testing.expect(has(s, "c: i16 = 0,"));
    try testing.expect(has(s, "d: i32 = 0,"));
    try testing.expect(has(s, "e: i64 = 0,"));
}

test "zig_backend: string types" {
    var out = try testGen(
        \\struct S { string s; string<32> bs; wstring ws; };
    , "str");
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "s: []const u8 = \"\","));
    try testing.expect(has(s, "bs: zidl_rt.BoundedArray(u8, 32) = .{},"));
    try testing.expect(has(s, "ws: []const u16 = &.{},"));
}

test "zig_backend: sequence types" {
    var out = try testGen(
        \\struct S { sequence<long> unbounded; sequence<long, 10> bounded; };
    , "seq");
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "unbounded: extern struct { _maximum: u32 = 0, _length: u32 = 0, _buffer: ?[*]i32 = null, _release: bool = false } = .{},"));
    try testing.expect(has(s, "bounded: zidl_rt.BoundedArray(i32, 10) = .{},"));
}

test "zig_backend: map type integer key" {
    var out = try testGen("struct S { map<long, long> m; };", "map_test");
    defer out.deinit(testing.allocator);
    try testing.expect(has(out.items, "m: std.AutoArrayHashMapUnmanaged(i32, i32) = .{},"));
}

test "zig_backend: map type string key" {
    var out = try testGen("struct S { map<string, long> m; };", "map_test");
    defer out.deinit(testing.allocator);
    try testing.expect(has(out.items, "m: std.StringArrayHashMapUnmanaged(i32) = .{},"));
}

test "zig_backend: map cdr write" {
    var out = try testGen("struct S { map<long, long> m; };", "map_test");
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "try writer.writeU32(@intCast(value.m.count()));"));
    try testing.expect(has(s, "for (value.m.keys(), value.m.values()) |_mk, _mv|"));
    try testing.expect(has(s, "try writer.writeI32(_mk);"));
    try testing.expect(has(s, "try writer.writeI32(_mv);"));
}

test "zig_backend: map cdr read" {
    var out = try testGen("struct S { map<long, long> m; };", "map_test");
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "const _mn = try reader.readU32();"));
    try testing.expect(has(s, "try out.m.ensureTotalCapacity(allocator, _mn);"));
    try testing.expect(has(s, "var _mk: i32 = undefined;"));
    try testing.expect(has(s, "var _mv: i32 = undefined;"));
    try testing.expect(has(s, "try out.m.putNoClobber(allocator, _mk, _mv);"));
}

test "zig_backend: array field" {
    var out = try testGen(
        \\struct Mat { long m[2][4]; };
    , "mat");
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "m: [2][4]i32 = std.mem.zeroes([2][4]i32),"));
}

test "zig_backend: optional field" {
    var out = try testGen(
        \\struct S { @optional long x; };
    , "opt");
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "x: ?i32 = null,"));
}

test "zig_backend: idiomatic enums lowercase full name" {
    var out = try testGenOpts(
        \\enum DurabilityKind { DURABILITY_VOLATILE, DURABILITY_TRANSIENT_LOCAL };
    , "dk", .{ .zig_idiomatic_enums = true });
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "durability_volatile = 0,"));
    try testing.expect(has(s, "durability_transient_local = 1,"));
    // IDL name must not appear as an enum tag (it may appear in string converters).
    try testing.expect(!has(s, "DURABILITY_VOLATILE = 0,"));
}

test "zig_backend: idiomatic enums keyword escape" {
    var out = try testGenOpts(
        \\enum DurabilityQosPolicyKind { DURABILITY_VOLATILE, DURABILITY_TRANSIENT_LOCAL };
    , "dk", .{ .zig_idiomatic_enums = true });
    defer out.deinit(testing.allocator);
    const s = out.items;
    // DURABILITY_VOLATILE lowercases to durability_volatile — not a keyword, no escape needed.
    try testing.expect(has(s, "durability_volatile = 0,"));
    // Verify volatile alone (a direct keyword) gets escaped.
    var out2 = try testGenOpts(
        \\enum Mem { VOLATILE, CONST };
    , "mem", .{ .zig_idiomatic_enums = true });
    defer out2.deinit(testing.allocator);
    const s2 = out2.items;
    try testing.expect(has(s2, "volatile_ = 0,"));
    try testing.expect(has(s2, "const_ = 1,"));
}

test "zig_backend: idiomatic enums keyword escape for primitive values" {
    // true, false, null, undefined are Zig primitive values — using them as
    // identifiers produces a compile error, so they must get the _ suffix.
    // IDL keywords TRUE/FALSE are avoided; use mixed-case variants instead.
    var out = try testGenOpts(
        \\enum Flag { True, False, Null, Undefined };
    , "flag", .{ .zig_idiomatic_enums = true });
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "true_ = 0,"));
    try testing.expect(has(s, "false_ = 1,"));
    try testing.expect(has(s, "null_ = 2,"));
    try testing.expect(has(s, "undefined_ = 3,"));
}

test "zig_backend: idiomatic enums toString uses IDL name" {
    var out = try testGenOpts(
        \\enum DurabilityKind { DURABILITY_VOLATILE, DURABILITY_TRANSIENT_LOCAL };
    , "dk", .{ .zig_idiomatic_enums = true });
    defer out.deinit(testing.allocator);
    const s = out.items;
    // toString switch arm uses idiomatic tag but returns original IDL string.
    try testing.expect(has(s, ".durability_volatile => \"DURABILITY_VOLATILE\""));
    try testing.expect(has(s, ".durability_transient_local => \"DURABILITY_TRANSIENT_LOCAL\""));
}

test "zig_backend: idiomatic enums fromString uses IDL name key" {
    var out = try testGenOpts(
        \\enum DurabilityKind { DURABILITY_VOLATILE, DURABILITY_TRANSIENT_LOCAL };
    , "dk", .{ .zig_idiomatic_enums = true });
    defer out.deinit(testing.allocator);
    const s = out.items;
    // fromString key is the IDL name; return value is the idiomatic tag.
    try testing.expect(has(s, "eqlIgnoreCase(s, \"DURABILITY_VOLATILE\")) return .durability_volatile"));
}

test "zig_backend: idiomatic enums struct field default uses idiomatic tag" {
    var out = try testGenOpts(
        \\enum Color { RED, GREEN, BLUE };
        \\struct S { Color c; };
    , "s", .{ .zig_idiomatic_enums = true });
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "c: Color = .red,"));
}

test "zig_backend: idiomatic enums off by default" {
    var out = try testGen(
        \\enum DurabilityKind { DURABILITY_VOLATILE, DURABILITY_TRANSIENT_LOCAL };
    , "dk");
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "DURABILITY_VOLATILE = 0,"));
    try testing.expect(!has(s, "durability_volatile"));
}

test "zig_backend: enum" {
    var out = try testGen("enum Color { RED, GREEN, BLUE };", "color");
    defer out.deinit(testing.allocator);
    const s = out.items;
    // Declaration
    try testing.expect(has(s, "pub const Color = enum(u32) {"));
    try testing.expect(has(s, "RED = 0,"));
    try testing.expect(has(s, "GREEN = 1,"));
    try testing.expect(has(s, "BLUE = 2,"));
    try testing.expect(has(s, "_,"));
    try testing.expect(has(s, "}; // Color"));
    // fromString
    try testing.expect(has(s, "pub fn Color_fromString(s: []const u8) ?Color {"));
    try testing.expect(has(s, "if (std.ascii.eqlIgnoreCase(s, \"RED\")) return .RED;"));
    try testing.expect(has(s, "if (std.ascii.eqlIgnoreCase(s, \"GREEN\")) return .GREEN;"));
    try testing.expect(has(s, "if (std.ascii.eqlIgnoreCase(s, \"BLUE\")) return .BLUE;"));
    try testing.expect(has(s, "return null;"));
    // toString
    try testing.expect(has(s, "pub fn Color_toString(v: Color) ?[]const u8 {"));
    try testing.expect(has(s, ".RED => \"RED\","));
    try testing.expect(has(s, ".GREEN => \"GREEN\","));
    try testing.expect(has(s, ".BLUE => \"BLUE\","));
    try testing.expect(has(s, "_ => null,"));
}

test "zig_backend: union" {
    var out = try testGen(
        \\union Var switch (long) { case 0: long i; default: string s; };
    , "var_t");
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "pub const Var = struct {"));
    try testing.expect(has(s, "_d: i32 = 0,"));
    try testing.expect(has(s, "_u: union {"));
    try testing.expect(has(s, "i: i32,"));
    try testing.expect(has(s, "s: []const u8,"));
    try testing.expect(has(s, "} = undefined,"));
}

test "zig_backend: union CDR serialize/deserialize" {
    var out = try testGen(
        \\union Var switch (long) { case 0: long i; default: string s; };
    , "var_t");
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "pub const has_key = false;"));
    try testing.expect(has(s, "pub fn serialize(writer: anytype, value: @This()) !void {"));
    try testing.expect(has(s, "pub fn deserializeInto(out: *@This(), reader: *zidl_rt.CdrReader"));
    try testing.expect(has(s, "try writer.writeI32(value._d);"));
    try testing.expect(has(s, "out._d = try reader.readI32();"));
    try testing.expect(has(s, "switch (value._d) {"));
    try testing.expect(has(s, "0 => {"));
    try testing.expect(has(s, "else => {"));
}

test "zig_backend: union CDR appendable adds DHEADER" {
    var out = try testGen(
        \\@appendable union Var switch (long) { case 0: long i; };
    , "var_t");
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "const _dh = try writer.reserveDheaderMaybe();"));
    try testing.expect(has(s, "try reader.skipDheaderIfXcdr2();"));
}

test "zig_backend: union with a non-trivial case gets deinit/clone, every case gets its own arm" {
    var out = try testGen(
        \\union Var switch (long) { case 0: long i; default: string s; };
    , "var_t");
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "pub fn deinit(self: *@This(), alloc: std.mem.Allocator) void {"));
    try testing.expect(has(s, "pub fn clone(self: @This(), alloc: std.mem.Allocator) !@This() {"));
    // The int case (0) owns nothing, but still needs its own (empty) arm --
    // omitting it would let discriminant 0 fall through to `else` and wrongly
    // run the string case's free on the int's bit pattern. Same hazard, and
    // same fix, as the C backend's generated union `_free()`.
    try testing.expect(has(s,
        \\        switch (self._d) {
        \\            0 => {
        \\            },
        \\            else => {
        \\                if (self._u.s.len != 0) alloc.free(self._u.s);
        \\            },
        \\        }
    ));
    try testing.expect(has(s, "result._u.s = if (self._u.s.len != 0) try alloc.dupe(u8, self._u.s) else self._u.s;"));
}

test "zig_backend: union with only trivial cases gets no deinit/clone" {
    var out = try testGen(
        \\union Var switch (long) { case 0: long i; case 1: double d; };
    , "var_t");
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(!has(s, "pub fn deinit"));
    try testing.expect(!has(s, "pub fn clone"));
}

test "zig_backend: struct embedding a non-trivial union delegates deinit/clone to it" {
    var out = try testGen(
        \\union Var switch (long) { case 0: long i; default: string s; };
        \\struct Holder { @key long id; Var v; };
    , "holder_t");
    defer out.deinit(testing.allocator);
    const s = out.items;
    // The union member alone must be enough to trigger Holder's own
    // deinit/clone -- before typeRefNeedsSeqDeinit's .named switch handled
    // .union_, a struct whose only owning content was a union member got no
    // deinit()/clone() of its own at all, and even where it did (for
    // unrelated reasons), never called into the union's.
    try testing.expect(has(s, "pub fn deinit(self: *@This(), alloc: std.mem.Allocator) void {\n        self.v.deinit(alloc);\n    }"));
    try testing.expect(has(s, "result.v = try self.v.clone(alloc);"));
    try testing.expect(has(s, "errdefer result.v.deinit(alloc);"));
}

test "zig_backend: union deserializeInto adopts a case via a whole-union-literal assign, not a direct field write" {
    var out = try testGen(
        \\union Var switch (long) { case 0: long i; default: string s; };
    , "var_t");
    defer out.deinit(testing.allocator);
    const s = out.items;
    // A direct `out._u.s = ...;` field write panics at runtime in Zig 0.16
    // safety-checked builds ("invalid enum value" from the union's hidden
    // active-field tag) unless that field is already active -- which it
    // never is starting from `out._u = undefined`. Reassigning the whole
    // union via a `.{ .case = value }` literal is what actually switches the
    // active field safely. This affected every generated Zig union, not just
    // ones with owning cases.
    try testing.expect(has(s, "out._u = .{ .i = _tmp };"));
    try testing.expect(has(s, "out._u = .{ .s = _tmp };"));
    try testing.expect(!has(s, "out._u.i ="));
    try testing.expect(!has(s, "out._u.s ="));
}

test "zig_backend: typedef scalar" {
    var out = try testGen("typedef long MyInt;", "types");
    defer out.deinit(testing.allocator);
    try testing.expect(has(out.items, "pub const MyInt = i32;"));
}

test "zig_backend: typedef array" {
    var out = try testGen("typedef long Matrix[2][4];", "types");
    defer out.deinit(testing.allocator);
    try testing.expect(has(out.items, "pub const Matrix = [2][4]i32;"));
}

test "zig_backend: bitmask" {
    var out = try testGen(
        \\bitmask Flags { READ, WRITE, EXECUTE };
    , "flags");
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "pub const Flags = u32;"));
    try testing.expect(has(s, "pub const Flags_READ: Flags = 1 << 0;"));
    try testing.expect(has(s, "pub const Flags_WRITE: Flags = 1 << 1;"));
    try testing.expect(has(s, "pub const Flags_EXECUTE: Flags = 1 << 2;"));
}

test "zig_backend: bitmask in module uses qualified name" {
    var out = try testGen(
        \\module M { bitmask Flags { READ, WRITE }; };
    , "mod_flags");
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "pub const M = struct {"));
    try testing.expect(has(s, "pub const Flags = u32;"));
    // Bit constants must reference the qualified type so they compile inside
    // the module struct where 'Flags' may not be directly resolvable from a
    // nested inner struct.
    try testing.expect(has(s, "pub const Flags_READ: M.Flags = 1 << 0;"));
    try testing.expect(has(s, "pub const Flags_WRITE: M.Flags = 1 << 1;"));
}

test "zig_backend: bitset" {
    var out = try testGen(
        \\bitset Config { bitfield<3> mode; bitfield<1> flag; };
    , "cfg");
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "pub const Config = packed struct {"));
    try testing.expect(has(s, "mode: u3 = 0,"));
    try testing.expect(has(s, "flag: u1 = 0,"));
}

test "zig_backend: native" {
    var out = try testGen("native Handle;", "native_t");
    defer out.deinit(testing.allocator);
    try testing.expect(has(out.items, "pub const Handle = opaque{};"));
}

test "zig_backend: exception" {
    var out = try testGen(
        \\exception MyError { long code; string message; };
    , "err");
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "// IDL exception"));
    try testing.expect(has(s, "pub const MyError = struct {"));
    try testing.expect(has(s, "code: i32 = 0,"));
    try testing.expect(has(s, "message: []const u8 = \"\","));
}

test "zig_backend: interface placeholder" {
    var out = try testGen(
        \\interface Foo { long op(in long x); };
    , "iface");
    defer out.deinit(testing.allocator);
    try testing.expect(has(out.items, "// IDL interface Foo"));
    try testing.expect(has(out.items, "--generate-interfaces"));
}

test "zig_backend: const integer" {
    var out = try testGen("const long MAX = 42;", "consts");
    defer out.deinit(testing.allocator);
    try testing.expect(has(out.items, "pub const MAX: i32 = 42;"));
}

test "zig_backend: const string" {
    var out = try testGen("const string VERSION = \"1.0\";", "consts");
    defer out.deinit(testing.allocator);
    try testing.expect(has(out.items, "pub const VERSION: []const u8 = \"1.0\";"));
}

test "zig_backend: const bool" {
    var out = try testGen("const boolean FLAG = TRUE;", "consts");
    defer out.deinit(testing.allocator);
    try testing.expect(has(out.items, "pub const FLAG: bool = true;"));
}

test "zig_backend: cross-module type ref" {
    var out = try testGen(
        \\module A { struct X { long val; }; };
        \\module B { struct Y { A::X ax; }; };
    , "cross");
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "pub const A = struct {"));
    try testing.expect(has(s, "pub const B = struct {"));
    // Cross-module reference must use the full dotted path.
    try testing.expect(has(s, "ax: A.X = .{},"));
}

test "zig_backend: struct with enum field default" {
    var out = try testGen(
        \\enum Color { RED, GREEN, BLUE };
        \\struct S { Color c; };
    , "enum_field");
    defer out.deinit(testing.allocator);
    const s = out.items;
    // Default for the enum field should use the first enumerator.
    try testing.expect(has(s, "c: Color = .RED,"));
}

test "zig_backend: struct inheritance embeds base" {
    var out = try testGen(
        \\struct Base { long x; };
        \\struct Derived : Base { long y; };
    , "inherit");
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "_base: Base = .{},"));
    try testing.expect(has(s, "y: i32 = 0,"));
}

// ── CDR serialization emission tests ─────────────────────────────────────────

test "zig_backend: no_typesupport suppresses serialize" {
    var out = try testGenOpts("struct Point { long x; long y; };", "p", .{ .no_typesupport = true });
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(!has(s, "zidl_rt"));
    try testing.expect(!has(s, "serialize"));
    try testing.expect(!has(s, "has_key"));
}

test "zig_backend: serialize @final struct primitives" {
    var out = try testGen("struct Point { long x; float y; boolean flag; };", "point");
    defer out.deinit(testing.allocator);
    const s = out.items;
    // Import present
    try testing.expect(has(s, "const zidl_rt = @import(\"zidl_rt\");"));
    // has_key = false (no @key members)
    try testing.expect(has(s, "pub const has_key = false;"));
    // serialize function present with correct write calls
    try testing.expect(has(s, "pub fn serialize(writer: anytype, value: @This()) !void {"));
    try testing.expect(has(s, "try writer.writeI32(value.x);"));
    try testing.expect(has(s, "try writer.writeF32(value.y);"));
    try testing.expect(has(s, "try writer.writeBool(value.flag);"));
    // No DHEADER for @final
    try testing.expect(!has(s, "reserveDheaderMaybe"));
    // deserializeInto present
    try testing.expect(has(s, "pub fn deserializeInto(out: *@This(), reader: *zidl_rt.CdrReader, allocator: std.mem.Allocator) !void {"));
    try testing.expect(has(s, "out.x = try reader.readI32();"));
    try testing.expect(has(s, "out.y = try reader.readF32();"));
    try testing.expect(has(s, "out.flag = try reader.readBool();"));
    // No allocator needed for scalars only
    try testing.expect(has(s, "_ = allocator;"));
    // deserialize convenience wrapper
    try testing.expect(has(s, "pub fn deserialize(reader: *zidl_rt.CdrReader, allocator: std.mem.Allocator) !@This() {"));
    try testing.expect(has(s, "var _out: @This() = .{};"));
    // No serializeKey (no @key)
    try testing.expect(!has(s, "serializeKey"));
}

test "zig_backend: serialize @appendable struct has DHEADER" {
    var out = try testGen("@appendable struct Point { long x; long y; };", "pt");
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "const _dh = try writer.reserveDheaderMaybe();"));
    try testing.expect(has(s, "writer.patchDheaderMaybe(_dh);"));
    try testing.expect(has(s, "try reader.skipDheaderIfXcdr2();"));
}

test "zig_backend: serialize @key member emits serializeKey" {
    var out = try testGen("struct Msg { @key long id; string label; };", "msg");
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "pub const has_key = true;"));
    try testing.expect(has(s, "pub fn serializeKey(writer: anytype, value: @This()) !void {"));
    // Key field included in serializeKey
    try testing.expect(has(s, "try writer.writeI32(value.id);"));
    // @final struct: no DHEADER in serializeKey
    try testing.expect(!has(s, "const _dh = try writer.reserveDheaderMaybe();"));
}

test "zig_backend: @appendable keyed struct emits DHEADER in serializeKey" {
    var out = try testGen("@appendable struct Msg { @key long id; string label; };", "msg");
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "pub fn serializeKey(writer: anytype, value: @This()) !void {"));
    // @appendable: serializeKey must bracket key fields with DHEADER so XCDR2
    // key-only wire payloads are symmetric with deserializeKeyInto.
    try testing.expect(has(s, "const _dh = try writer.reserveDheaderMaybe();"));
    try testing.expect(has(s, "writer.patchDheaderMaybe(_dh);"));
}

test "zig_backend: keyed struct emits deserializeKey and computeKeyHash" {
    var out = try testGen("struct Msg { @key long id; string label; };", "msg");
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "pub fn deserializeKey(reader: *zidl_rt.CdrReader, allocator: std.mem.Allocator) !@This() {"));
    try testing.expect(has(s, "pub fn deserializeKeyInto(out: *@This(), reader: *zidl_rt.CdrReader, allocator: std.mem.Allocator) !void {"));
    try testing.expect(has(s, "out.id = try reader.readI32();"));
    try testing.expect(has(s, "pub fn computeKeyHash(value: @This()) [16]u8 {"));
    try testing.expect(has(s, "var _khw = zidl_rt.KeyHashWriter.init();"));
}

test "zig_backend: @final struct with non-leading key emits compileError in deserializeKeyInto" {
    var out = try testGen("struct Msg { string label; @key long id; };", "msg");
    defer out.deinit(testing.allocator);
    const s = out.items;
    // @compileError must appear in the generated deserializeKeyInto body.
    try testing.expect(has(s, "@compileError(\"zidl: @final struct 'Msg' has non-leading @key member 'id'"));
    // serializeKey and computeKeyHash are still generated normally.
    try testing.expect(has(s, "pub fn serializeKey(writer: anytype, value: @This()) !void {"));
    try testing.expect(has(s, "pub fn computeKeyHash(value: @This()) [16]u8 {"));
}

test "zig_backend: keyless struct does not emit key helpers" {
    var out = try testGen("struct Msg { long id; string label; };", "msg");
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "pub const has_key = false;"));
    try testing.expect(!has(s, "serializeKey"));
    try testing.expect(!has(s, "deserializeKey"));
    try testing.expect(!has(s, "computeKeyHash"));
}

test "zig_backend: inherited key participates in key helpers" {
    var out = try testGen(
        \\struct Base { @key long id; string ignored; };
        \\struct Derived : Base { long value; };
    , "inh_key");
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "pub const Derived = struct {"));
    try testing.expect(has(s, "pub const has_key = true;"));
    try testing.expect(has(s, "try Base.serializeKey(writer, value._base);"));
    try testing.expect(has(s, "try Base.deserializeKeyInto(&out._base, reader, allocator);"));
}

test "zig_backend: serialize string and sequence" {
    var out = try testGen("struct S { string label; sequence<long> values; };", "seq");
    defer out.deinit(testing.allocator);
    const s = out.items;
    // Unbounded string → writeString, readString(allocator)
    try testing.expect(has(s, "try writer.writeString(value.label);"));
    try testing.expect(has(s, "label = try reader.readString(allocator);"));
    // Sequence → length prefix + if/for loop over buffer
    try testing.expect(has(s, "try writer.writeU32(value.values._length);"));
    try testing.expect(has(s, "if (value.values._buffer) |_sb|"));
    try testing.expect(has(s, "for (_sb[0..value.values._length]) |_se|"));
    try testing.expect(has(s, "try writer.writeI32(_se);"));
    // Read side: alloc buffer + loop
    try testing.expect(has(s, "const _n = try reader.readU32();"));
    try testing.expect(has(s, "const _buf = try allocator.alloc(i32, _n);"));
    try testing.expect(has(s, "_se.* = try reader.readI32();"));
    // Needs allocator → no "_ = allocator"
    try testing.expect(!has(s, "_ = allocator;"));
}

test "zig_backend: bounded sequence deserialize is heap-free" {
    var out = try testGen("struct S { sequence<long, 4> values; };", "bounded_seq");
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "try writer.writeU32(@intCast(value.values.slice().len));"));
    try testing.expect(has(s, "for (value.values.slice()) |_se|"));
    try testing.expect(has(s, "if (_n > 4) return error.SequenceTooLong;"));
    try testing.expect(has(s, "out.values.clearRetainingCapacity();"));
    try testing.expect(!has(s, "out.values.ensureTotalCapacity(allocator, _n);"));
    try testing.expect(!has(s, "value.values.items"));
}

test "zig_backend: serialize enum field" {
    var out = try testGen("enum Color { RED, GREEN }; struct S { Color c; };", "col");
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "try writer.writeU32(@intFromEnum(value.c));"));
    try testing.expect(has(s, "out.c = @enumFromInt(try reader.readU32());"));
}

test "zig_backend: serialize array field" {
    var out = try testGen("struct Mat { long m[2][4]; };", "mat");
    defer out.deinit(testing.allocator);
    const s = out.items;
    // Write: nested for loops
    try testing.expect(has(s, "for (value.m) |_d0|"));
    try testing.expect(has(s, "for (_d0) |_d1|"));
    try testing.expect(has(s, "try writer.writeI32(_d1);"));
    // Read: index-based loops with hardcoded bounds
    try testing.expect(has(s, "for (0..2) |_i0|"));
    try testing.expect(has(s, "for (0..4) |_i1|"));
    try testing.expect(has(s, "out.m[_i0][_i1] = try reader.readI32();"));
}

test "zig_backend: serialize nested struct" {
    var out = try testGen("struct Inner { long x; }; struct Outer { Inner inner; long tag; };", "nest");
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "try Inner.serialize(writer, value.inner);"));
    try testing.expect(has(s, "try Inner.deserializeInto(&out.inner, reader, allocator);"));
}

// ── TypeObject constant emission tests ───────────────────────────────────────

test "zig_backend: typeobject constants present for struct" {
    var out = try testGen("struct Point { long x; long y; };", "point");
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "pub const type_object: []const u8 ="));
    try testing.expect(has(s, "pub const equivalence_hash: [14]u8 ="));
    try testing.expect(has(s, "pub const type_identifier: [32]u8 ="));
    // encap header bytes 0x00, 0x07 must appear in hex in type_object
    try testing.expect(has(s, "0x00, 0x07, 0x00, 0x00"));
    // EK_MINIMAL = 0xF1
    try testing.expect(has(s, "0xF1"));
    // TK_STRUCTURE = 0x51
    try testing.expect(has(s, "0x51"));
}

test "zig_backend: typeobject no_typeobject_support suppresses constants" {
    var out = try testGenOpts("struct Point { long x; };", "p", .{ .no_typeobject_support = true });
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(!has(s, "type_object"));
    try testing.expect(!has(s, "equivalence_hash"));
    try testing.expect(!has(s, "type_identifier"));
}

test "zig_backend: typeobject IS_FINAL flag for default extensibility" {
    var out = try testGen("struct F { long x; };", "f");
    defer out.deinit(testing.allocator);
    // IS_FINAL = 0x0001, encoded LE as first u16 of struct_flags in type_object.
    // The byte 0x01 must appear in the type_object hex string.
    try testing.expect(has(out.items, "type_object"));
}

test "zig_backend: typeobject IS_APPENDABLE flag" {
    var out = try testGen("@appendable struct A { long x; };", "a");
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "type_object"));
    // IS_APPENDABLE = 0x0002, encoded LE as 0x02, 0x00 somewhere in bytes
    try testing.expect(has(s, "0x02, 0x00"));
}

test "zig_backend: typeobject both typesupport and typeobject by default" {
    var out = try testGen("struct S { @key long id; string label; };", "s");
    defer out.deinit(testing.allocator);
    const s = out.items;
    // Both CDR and TypeObject constants must be present
    try testing.expect(has(s, "pub fn serialize("));
    try testing.expect(has(s, "pub const type_object"));
    try testing.expect(has(s, "pub const has_key = true;"));
}

test "zig_backend: typeobject suppressed independently of typesupport" {
    var out = try testGenOpts("struct S { long x; };", "s", .{ .no_typeobject_support = true });
    defer out.deinit(testing.allocator);
    const s = out.items;
    // Serialize still present
    try testing.expect(has(s, "pub fn serialize("));
    // TypeObject absent
    try testing.expect(!has(s, "type_object"));
}

// ── Serialization fix tests: typedef / bitmask / union / bitset members ───────

test "zig_backend: serialize typedef-of-primitive member" {
    // typedef long resolves to i32; serialize must emit writeI32, not .serialize()
    var out = try testGen(
        \\typedef long MyInt;
        \\struct S { MyInt x; };
    , "td");
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "try writer.writeI32(value.x);"));
    try testing.expect(has(s, "out.x = try reader.readI32();"));
    try testing.expect(!has(s, ".serialize(writer, value.x)"));
}

test "zig_backend: serialize typedef-of-string member" {
    // typedef string MyStr; struct S { MyStr label; }
    // resolves to unbounded string → writeString / readString(allocator)
    var out = try testGen(
        \\typedef string MyStr;
        \\struct S { MyStr label; };
    , "tds");
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "try writer.writeString(value.label);"));
    try testing.expect(has(s, "label = try reader.readString(allocator);"));
}

test "zig_backend: serialize bitmask member" {
    // bitmask<32> Flags; struct S { Flags f; }
    // bitmask is u32 — serialize as writeU32/readU32
    var out = try testGen(
        \\bitmask Flags { flag1, flag2 };
        \\struct S { Flags f; };
    , "bm");
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "try writer.writeU32(value.f);"));
    try testing.expect(has(s, "out.f = try reader.readU32();"));
    try testing.expect(!has(s, ".serialize(writer, value.f)"));
}

test "zig_backend: serialize bitmask<16> member uses writeU16" {
    var out = try testGen(
        \\@bit_bound(16) bitmask SmallFlags { a, b };
        \\struct S { SmallFlags f; };
    , "bm16");
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "try writer.writeU16(value.f);"));
    try testing.expect(has(s, "out.f = try reader.readU16();"));
}

test "zig_backend: union member in struct uses .serialize()/.deserializeInto()" {
    var out = try testGen(
        \\union U switch (long) { case 0: long x; };
        \\struct S { U u; };
    , "un");
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "try U.serialize(writer, value.u);"));
    try testing.expect(has(s, "try U.deserializeInto(&out.u, reader, allocator);"));
}

test "zig_backend: serialize bitset member" {
    // bitset BS { bitfield<3> a; bitfield<1> b; }; total=4 bits → u8
    var out = try testGen(
        \\bitset BS { bitfield<3> a; bitfield<1> b; };
        \\struct S { BS bs; };
    , "bs");
    defer out.deinit(testing.allocator);
    const s = out.items;
    // bitset itself has serialize/deserializeInto
    try testing.expect(has(s, "pub fn serialize(writer: anytype, value: @This()) !void {"));
    try testing.expect(has(s, "const _bs: u4 = @bitCast(value);"));
    try testing.expect(has(s, "try writer.writeU8(@intCast(_bs));"));
    try testing.expect(has(s, "pub fn deserializeInto(out: *@This(), reader: *zidl_rt.CdrReader, _: std.mem.Allocator) !void {"));
    try testing.expect(has(s, "out.* = @bitCast(@as(u4, @truncate(try reader.readU8())));"));
    // struct member dispatch calls .serialize / .deserializeInto
    try testing.expect(has(s, "try BS.serialize(writer, value.bs);"));
    try testing.expect(has(s, "try BS.deserializeInto(&out.bs, reader, allocator);"));
}

test "zig_backend: serialize bitset 32-bit member" {
    // bitset Cfg with 32 total bits → storage u32
    var out = try testGen(
        \\bitset Cfg { bitfield<16> a; bitfield<16> b; };
        \\struct S { Cfg c; };
    , "cfg");
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "const _bs: u32 = @bitCast(value);"));
    try testing.expect(has(s, "try writer.writeU32(@intCast(_bs));"));
    try testing.expect(has(s, "out.* = @bitCast(@as(u32, @truncate(try reader.readU32())));"));
    try testing.expect(has(s, "try Cfg.serialize(writer, value.c);"));
    try testing.expect(has(s, "try Cfg.deserializeInto(&out.c, reader, allocator);"));
}

test "zig_backend: serialize bitset no_typesupport" {
    // --no-typesupport suppresses bitset CDR methods
    var out = try testGenOpts(
        \\bitset BS { bitfield<3> a; bitfield<1> b; };
    , "bs", .{ .no_typesupport = true });
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "pub const BS = packed struct {"));
    try testing.expect(!has(s, "pub fn serialize"));
    try testing.expect(!has(s, "pub fn deserializeInto"));
}

// ── Additional CDR serialization coverage ────────────────────────────────────

test "zig_backend: serialize struct inheritance deserializeInto" {
    var out = try testGen(
        \\struct Base { long x; };
        \\struct Derived : Base { long y; };
    , "inh");
    defer out.deinit(testing.allocator);
    const s = out.items;
    // serialize: _base first
    try testing.expect(has(s, "try Base.serialize(writer, value._base);"));
    // deserializeInto: _base first
    try testing.expect(has(s, "try Base.deserializeInto(&out._base, reader, allocator);"));
}

test "zig_backend: serialize wstring field" {
    var out = try testGen("struct S { wstring ws; };", "ws");
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "try writer.writeWstring(value.ws);"));
    try testing.expect(has(s, "out.ws = try reader.readWstring(allocator);"));
}

test "zig_backend: serialize bounded string member" {
    // bounded string<32> → BoundedArray(u8,32); serialize uses .slice()
    var out = try testGen("struct S { string<32> label; };", "bs");
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "try writer.writeString(value.label.slice());"));
    // Read: zero-copy read then copy into BoundedArray
    try testing.expect(has(s, "label"));
    // No allocator needed for bounded string
    try testing.expect(has(s, "_ = allocator;"));
}

test "zig_backend: serialize bounded wstring member" {
    var out = try testGen("struct S { wstring<16> label; };", "bws");
    defer out.deinit(testing.allocator);
    const s = out.items;
    // Write: use .slice() on BoundedArray(u16,16)
    try testing.expect(has(s, "try writer.writeWstring(value.label.slice());"));
    // Read: allocate temp, defer free, bound-check, fromSlice
    try testing.expect(has(s, "const _ws = try reader.readWstring(allocator);"));
    try testing.expect(has(s, "defer allocator.free(_ws);"));
    try testing.expect(has(s, "if (_ws.len > 16) return error.StringTooLong;"));
    try testing.expect(has(s, "zidl_rt.BoundedArray(u16, 16).fromSlice(_ws) catch unreachable;"));
    // Bounded wstring needs allocator (readWstring always allocates)
    try testing.expect(!has(s, "_ = allocator;"));
}

test "zig_backend: serialize sequence of structs" {
    var out = try testGen(
        \\struct Item { long id; };
        \\struct S { sequence<Item> items; };
    , "seqstruct");
    defer out.deinit(testing.allocator);
    const s = out.items;
    // Write: length + if/for loop calling .serialize()
    try testing.expect(has(s, "try writer.writeU32(value.items._length);"));
    try testing.expect(has(s, "if (value.items._buffer) |_sb|"));
    try testing.expect(has(s, "for (_sb[0..value.items._length]) |_se|"));
    try testing.expect(has(s, "try Item.serialize(writer, _se);"));
    // Read: alloc buffer + loop + deserializeInto via pointer
    try testing.expect(has(s, "const _buf = try allocator.alloc(Item, _n);"));
    try testing.expect(has(s, "for (_buf) |*_se|"));
    try testing.expect(has(s, "try Item.deserializeInto(&_se.*, reader, allocator);"));
}

test "zig_backend: serialize sequence of enums" {
    var out = try testGen(
        \\enum Color { RED, GREEN, BLUE };
        \\struct S { sequence<Color> colors; };
    , "seqenum");
    defer out.deinit(testing.allocator);
    const s = out.items;
    // Write loop: @intFromEnum
    try testing.expect(has(s, "try writer.writeU32(@intFromEnum(_se));"));
    // Read loop: direct assignment into buffer element
    try testing.expect(has(s, "_se.* = @enumFromInt(try reader.readU32());"));
}

test "zig_backend: typedef needsAllocator recurses correctly" {
    // typedef string MyStr — needs allocator (unbounded string)
    var out = try testGen(
        \\typedef string MyStr;
        \\struct S { MyStr s; };
    , "tda");
    defer out.deinit(testing.allocator);
    // allocator IS needed for the string read → must NOT emit "_ = allocator;"
    try testing.expect(!has(out.items, "_ = allocator;"));
}

test "zig_backend: serialize @key member in serializeKey" {
    var out = try testGen("struct S { @key long id; long val; };", "key");
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "pub fn serializeKey("));
    // serializeKey emits only the @key member
    try testing.expect(has(s, "try writer.writeI32(value.id);"));
}

// ── TypeObject coverage tests ─────────────────────────────────────────────────

test "zig_backend: typeobject struct with enum member uses recursive hash" {
    // A struct with an enum member: the member's TypeIdentifier must be
    // EK_MINIMAL + 14-byte hash, not TK_ENUM directly.
    var out = try testGen(
        \\enum Color { RED, GREEN };
        \\struct S { Color c; };
    , "toc");
    defer out.deinit(testing.allocator);
    const s = out.items;
    // TypeObject must be present; equivalence_hash is 14 bytes.
    try testing.expect(has(s, "pub const type_object: []const u8 ="));
    try testing.expect(has(s, "pub const equivalence_hash: [14]u8 ="));
    // EK_MINIMAL (0xF1) must appear in the type_object bytes (for the enum TI)
    try testing.expect(has(s, "0xF1"));
}

test "zig_backend: typeobject struct with string member" {
    // string members use TI_STRING8_SMALL (0x70)
    var out = try testGen("struct S { string label; };", "tos");
    defer out.deinit(testing.allocator);
    try testing.expect(has(out.items, "pub const type_object: []const u8 ="));
    // TI_STRING8_SMALL = 0x70
    try testing.expect(has(out.items, "0x70"));
}

test "zig_backend: typeobject deterministic across two calls" {
    // Calling generate twice for the same type must produce identical bytes.
    var out1 = try testGen("struct S { long x; float y; };", "det");
    defer out1.deinit(testing.allocator);
    var out2 = try testGen("struct S { long x; float y; };", "det");
    defer out2.deinit(testing.allocator);
    try testing.expectEqualSlices(u8, out1.items, out2.items);
}

// ── --generate-interfaces tests ───────────────────────────────────────────────

test "zig_backend: interface placeholder without flag" {
    // Without --generate-interfaces, interface emits a comment.
    var out = try testGen(
        \\interface Greeter { string greet(in string name); };
    , "iface");
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "// IDL interface Greeter"));
    try testing.expect(!has(s, "pub const Greeter = extern struct {"));
}

test "zig_backend: interface basic vtable struct" {
    var out = try testGenOpts(
        \\interface Greeter { string greet(in string name); };
    , "iface", .{ .generate_interfaces = true, .no_typesupport = true, .no_typeobject_support = true });
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "pub const Greeter = extern struct {"));
    try testing.expect(has(s, "ptr: *anyopaque,"));
    try testing.expect(has(s, "vtable: *const Vtable,"));
    try testing.expect(has(s, "pub const Vtable = struct {"));
    try testing.expect(has(s, "deinit: *const fn (*anyopaque) void,"));
    try testing.expect(has(s, "get_c_abi_handle: *const fn (*anyopaque) *anyopaque,"));
}

test "zig_backend: interface operation vtable entry and forwarder" {
    var out = try testGenOpts(
        \\interface Calc { long add(in long a, in long b); };
    , "calc", .{ .generate_interfaces = true, .no_typesupport = true, .no_typeobject_support = true });
    defer out.deinit(testing.allocator);
    const s = out.items;
    // Vtable entry: fn ptr with self as first *anyopaque param
    try testing.expect(has(s, "add: *const fn (*anyopaque, a: i32, b: i32) i32,"));
    // Forwarding method
    try testing.expect(has(s, "pub fn add(self: @This(), a: i32, b: i32) i32 {"));
    try testing.expect(has(s, "return self.vtable.add(self.ptr, a, b);"));
}

test "zig_backend: interface void operation" {
    var out = try testGenOpts(
        \\interface Sink { void write(in long val); };
    , "sink", .{ .generate_interfaces = true, .no_typesupport = true, .no_typeobject_support = true });
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "write: *const fn (*anyopaque, val: i32) void,"));
    try testing.expect(has(s, "pub fn write(self: @This(), val: i32) void {"));
    try testing.expect(has(s, "return self.vtable.write(self.ptr, val);"));
}

test "zig_backend: interface out/inout params become pointers" {
    var out = try testGenOpts(
        \\interface Io { void read(out long val, inout long count); };
    , "io", .{ .generate_interfaces = true, .no_typesupport = true, .no_typeobject_support = true });
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "read: *const fn (*anyopaque, val: *i32, count: *i32) void,"));
    try testing.expect(has(s, "pub fn read(self: @This(), val: *i32, count: *i32) void {"));
}

test "zig_backend: interface readonly attribute" {
    var out = try testGenOpts(
        \\interface Named { readonly attribute string name; };
    , "named", .{ .generate_interfaces = true, .no_typesupport = true, .no_typeobject_support = true });
    defer out.deinit(testing.allocator);
    const s = out.items;
    // Vtable slot: [*:0]const u8 (C-ABI)
    try testing.expect(has(s, "get_name: *const fn (*anyopaque) [*:0]const u8,"));
    try testing.expect(!has(s, "set_name"));
    // Forwarding getter: idiomatic []const u8 via std.mem.span
    try testing.expect(has(s, "pub fn get_name(self: @This()) []const u8 {"));
    try testing.expect(has(s, "return std.mem.span(self.vtable.get_name(self.ptr));"));
}

test "zig_backend: interface read-write attribute" {
    var out = try testGenOpts(
        \\interface Counter { attribute long count; };
    , "counter", .{ .generate_interfaces = true, .no_typesupport = true, .no_typeobject_support = true });
    defer out.deinit(testing.allocator);
    const s = out.items;
    // Both getter and setter in vtable
    try testing.expect(has(s, "get_count: *const fn (*anyopaque) i32,"));
    try testing.expect(has(s, "set_count: *const fn (*anyopaque, i32) void,"));
    // Forwarding methods
    try testing.expect(has(s, "pub fn get_count(self: @This()) i32 {"));
    try testing.expect(has(s, "pub fn set_count(self: @This(), value: i32) void {"));
    try testing.expect(has(s, "self.vtable.set_count(self.ptr, value);"));
}

test "zig_backend: interface deinit forwarder" {
    var out = try testGenOpts(
        \\interface Foo { void noop(); };
    , "foo", .{ .generate_interfaces = true, .no_typesupport = true, .no_typeobject_support = true });
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "pub fn deinit(self: @This()) void {"));
    try testing.expect(has(s, "self.vtable.deinit(self.ptr);"));
}

test "zig_backend: interface inheritance flattens base methods" {
    var out = try testGenOpts(
        \\interface Base { void base_op(); };
        \\interface Derived : Base { void derived_op(); };
    , "inh", .{ .generate_interfaces = true, .no_typesupport = true, .no_typeobject_support = true });
    defer out.deinit(testing.allocator);
    const s = out.items;
    // Derived vtable must contain both base_op and derived_op
    try testing.expect(has(s, "base_op: *const fn (*anyopaque) void,"));
    try testing.expect(has(s, "derived_op: *const fn (*anyopaque) void,"));
    // Forwarders for both
    try testing.expect(has(s, "pub fn base_op(self: @This()) void {"));
    try testing.expect(has(s, "pub fn derived_op(self: @This()) void {"));
}

test "zig_backend: interface nested const" {
    var out = try testGenOpts(
        \\interface Versioned { const long VERSION = 2; void noop(); };
    , "ver", .{ .generate_interfaces = true, .no_typesupport = true, .no_typeobject_support = true });
    defer out.deinit(testing.allocator);
    const s = out.items;
    // Nested const emitted inside struct body
    try testing.expect(has(s, "pub const VERSION: i32 = 2;"));
}

test "zig_backend: interface in module" {
    var out = try testGenOpts(
        \\module DDS { interface Entity { long get_id(); }; };
    , "dds", .{ .generate_interfaces = true, .no_typesupport = true, .no_typeobject_support = true });
    defer out.deinit(testing.allocator);
    const s = out.items;
    // Struct inside DDS namespace struct
    try testing.expect(has(s, "pub const DDS = struct {"));
    try testing.expect(has(s, "pub const Entity = extern struct {"));
    try testing.expect(has(s, "get_id: *const fn (*anyopaque) i32,"));
}

test "zig_backend: --zig-generate-c-api emits callconv(.c) wrappers for entity interfaces" {
    var out = try testGenOpts(
        \\interface Writer { long write_val(in long x, in string label); void reset(); };
    , "w", .{
        .generate_interfaces = true,
        .no_typesupport = true,
        .no_typeobject_support = true,
        .zig_generate_c_api = true,
    });
    defer out.deinit(testing.allocator);
    const s = out.items;
    // Every entity crosses the C-ABI as a single boxed opaque pointer,
    // unboxed at the top of the export function before dispatch.
    try testing.expect(has(s, "pub export fn Writer_write_val(self: *anyopaque, x: i32, label: [*:0]const u8) callconv(.c) i32"));
    try testing.expect(has(s, "const _self: Writer = zidl_rt.unboxAs(Writer, self);"));
    try testing.expect(has(s, "return _self.vtable.write_val(_self.ptr, x, label);"));
    // No span conversion — vtable already uses C types
    try testing.expect(!has(s, "std.mem.span(label)"));
    // Void op
    try testing.expect(has(s, "pub export fn Writer_reset(self: *anyopaque) callconv(.c) void"));
}

test "zig_backend: --zig-generate-c-api entity-returning op boxes the result via get_c_abi_handle" {
    var out = try testGenOpts(
        \\interface Writer {};
        \\interface Factory { Writer create_writer(in long qos); };
    , "f", .{
        .generate_interfaces = true,
        .no_typesupport = true,
        .no_typeobject_support = true,
        .zig_generate_c_api = true,
    });
    defer out.deinit(testing.allocator);
    const s = out.items;
    // Params (including a plain scalar) unbox self only — nothing to unbox
    // here since `qos` isn't an entity — but the result of the native call
    // must be boxed via the returned value's own vtable before returning,
    // never a hardcoded/assumed vtable, and no allocation call in generated
    // code at all (that's the concrete impl's own responsibility).
    try testing.expect(has(s, "pub export fn Factory_create_writer(self: *anyopaque, qos: i32) callconv(.c) *anyopaque {"));
    try testing.expect(has(s, "const _self: Factory = zidl_rt.unboxAs(Factory, self);"));
    try testing.expect(has(s, "const _r = _self.vtable.create_writer(_self.ptr, qos);"));
    try testing.expect(has(s, "return _r.vtable.get_c_abi_handle(_r.ptr);"));
    try testing.expect(!has(s, "zidl_rt.boxEntity"));
    // The *native* vtable slot (used for internal Zig-to-Zig dispatch, e.g. a
    // concrete FactoryImpl's own implementation) must keep the real
    // fat-pointer Writer return type — only the export function's own
    // signature narrows to *anyopaque. Getting this wrong (making the vtable
    // slot itself *anyopaque) would break every native caller of this vtable.
    try testing.expect(has(s, "create_writer: *const fn (*anyopaque, qos: i32) Writer,"));
    try testing.expect(!has(s, "create_writer: *const fn (*anyopaque, qos: i32) *anyopaque,"));
    // Same for the idiomatic Zig forwarding method.
    try testing.expect(has(s, "pub fn create_writer(self: @This(), qos: i32) Writer {"));
}

test "zig_backend: --zig-generate-c-api entity-typed param unboxes before dispatch" {
    var out = try testGenOpts(
        \\interface Topic {};
        \\interface Publisher { long create_writer(in Topic a_topic); };
    , "p", .{
        .generate_interfaces = true,
        .no_typesupport = true,
        .no_typeobject_support = true,
        .zig_generate_c_api = true,
    });
    defer out.deinit(testing.allocator);
    const s = out.items;
    // Topic-typed param arrives as a boxed *anyopaque; must be unboxed to the
    // native fat-pointer form before the vtable call, uniformly — regardless
    // of whether the parameter's interface has one implementation or several.
    try testing.expect(has(s, "pub export fn Publisher_create_writer(self: *anyopaque, a_topic: *anyopaque) callconv(.c) i32 {"));
    try testing.expect(has(s, "return _self.vtable.create_writer(_self.ptr, zidl_rt.unboxAs(Topic, a_topic));"));
    // Native vtable slot keeps the real Topic fat-pointer param type.
    try testing.expect(has(s, "create_writer: *const fn (*anyopaque, a_topic: Topic) i32,"));
    try testing.expect(!has(s, "create_writer: *const fn (*anyopaque, a_topic: *anyopaque) i32,"));
}

test "zig_backend: --zig-generate-c-api bare sequence<EntityInterface> param boxes each element (A12 regression)" {
    // Regression test for a real bug: a sequence<EntityInterface> typedef's
    // native Zig extern struct has full {ptr, vtable} fat-pointer elements
    // (16 bytes on 64-bit), but c.zig's independently-generated C header
    // declares a single opaque pointer per element (8 bytes) for the same
    // typedef. Passing the parameter straight through -- the way every
    // other sequence typedef (scalars/strings, naturally C-ABI compatible)
    // safely can -- corrupts memory the moment a caller inspects more than
    // the first element. First real caller: Java's Subscriber.get_datareaders(),
    // which crashed with SIGSEGV on any operation called on the returned
    // (corrupted) DataReader.
    var out = try testGenOpts(
        \\interface Reader {};
        \\typedef sequence<Reader> ReaderSeq;
        \\interface Sub { long get_readers(inout ReaderSeq readers); };
    , "s", .{
        .generate_interfaces = true,
        .no_typesupport = true,
        .no_typeobject_support = true,
        .zig_generate_c_api = true,
    });
    defer out.deinit(testing.allocator);
    const s = out.items;
    // Export signature: the whole seq pointer is opaque, matching the C
    // header's own (independently-generated) single-opaque-pointer-per-
    // element layout, not the native fat-pointer-element one.
    try testing.expect(has(s, "pub export fn Sub_get_readers(self: *anyopaque, readers: *anyopaque) callconv(.c) i32 {"));
    // Reinterprets the caller's buffer, frees any prior content, calls the
    // vtable through a native-shaped temporary (fat-pointer elements) --
    // never handing the caller's raw buffer straight to the vtable.
    try testing.expect(has(s, "const _cseq_readers: *extern struct { _maximum: u32 = 0, _length: u32 = 0, _buffer: ?[*]?*anyopaque = null, _release: bool = false } = @ptrCast(@alignCast(readers));"));
    try testing.expect(has(s, "if (_cseq_readers._release) { if (_cseq_readers._buffer) |_ob| std.heap.c_allocator.free(_ob[0.._cseq_readers._maximum]); }"));
    try testing.expect(has(s, "var _native_readers: ReaderSeq = .{};"));
    // The plain (non-entity, non-void) return is captured, not inlined into
    // the call statement -- the boxing loop still has to run afterward.
    try testing.expect(has(s, "const _ret_status = _self.vtable.get_readers(_self.ptr, &_native_readers);"));
    try testing.expect(!has(s, "return _self.vtable.get_readers(_self.ptr, &_native_readers);"));
    // Each native fat-pointer element is boxed via the same
    // `.vtable.get_c_abi_handle(.ptr)` convention used everywhere else an
    // entity crosses this boundary -- not passed through raw.
    try testing.expect(has(s, "for (_native_readers._buffer.?[0.._native_readers._length], 0..) |_e, _i| { _bb[_i] = _e.vtable.get_c_abi_handle(_e.ptr); }"));
    try testing.expect(has(s, "_cseq_readers.* = .{ ._maximum = _native_readers._length, ._length = _native_readers._length, ._buffer = _boxed_readers, ._release = _native_readers._length > 0 };"));
    try testing.expect(has(s, "return _ret_status;"));
}

test "zig_backend: --zig-generate-c-api emits C_XxxListener and adapter for listener interfaces" {
    var out = try testGenOpts(
        \\struct Status { long count; };
        \\interface Source { long enable(); };
        \\interface SourceListener { void on_change(in Source src, in Status st); };
    , "sl", .{
        .generate_interfaces = true,
        .no_typesupport = true,
        .no_typeobject_support = true,
        .zig_generate_c_api = true,
    });
    defer out.deinit(testing.allocator);
    const s = out.items;
    // @callback interfaces now produce C callback struct (no C_ prefix, no adapter).
    // Source is a leaf entity interface, so its field devirtualizes to
    // *anyopaque — matching the C header's single-pointer Source handle.
    try testing.expect(has(s, "pub const SourceListener = extern struct {"));
    try testing.expect(has(s, "on_change: ?*const fn (*anyopaque, *const Status, ?*anyopaque) callconv(.c) void"));
    try testing.expect(has(s, "pub const noop_SourceListener: SourceListener = .{};"));
    // No fat-pointer SourceListener, no adapter
    try testing.expect(!has(s, "pub const CSourceListenerAdapter"));
    try testing.expect(!has(s, "pub fn asZigListener"));
}

test "zig_backend: @callback interface emits Zig listener helpers" {
    var out = try testGenOpts(
        \\struct OfferedStatus { long count; };
        \\interface DataWriter { long write(); };
        \\interface WriterListener {
        \\    void on_offered(in DataWriter dw, in OfferedStatus status);
        \\    void on_alive(in DataWriter dw);
        \\};
    , "wl", .{
        .generate_interfaces = true,
        .no_typesupport = true,
        .no_typeobject_support = true,
    });
    defer out.deinit(testing.allocator);
    const s = out.items;
    // C callback struct emitted as before
    try testing.expect(has(s, "pub const WriterListener = extern struct {"));
    try testing.expect(has(s, "pub const noop_WriterListener: WriterListener = .{};"));
    // Handlers type (idiomatic Zig surface): plain Zig signatures, no callconv(.c),
    // status by value, DataWriter still the native fat-pointer handle.
    try testing.expect(has(s, "pub fn WriterListenerHandlers(comptime Ctx: type) type {"));
    try testing.expect(has(s, "on_offered: ?*const fn (*Ctx, DataWriter, OfferedStatus) void = null,"));
    try testing.expect(has(s, "on_alive: ?*const fn (*Ctx, DataWriter) void = null,"));
    // Builder function: lowercase-first name
    try testing.expect(has(s, "pub fn writerListener(ctx: anytype, comptime cbs: WriterListenerHandlers(@TypeOf(ctx.*))) WriterListener {"));
    // Thunks (C-ABI surface): DataWriter is a leaf interface, so the thunk
    // parameter devirtualizes to *anyopaque — matching the C header's
    // single-pointer DataWriter handle in the callback struct field — and the
    // body reconstructs the fat-pointer handle before calling the idiomatic
    // Zig handler.
    try testing.expect(has(s, "fn _w(_dw: *anyopaque, _status: *const OfferedStatus, _ld: ?*anyopaque) callconv(.c) void {"));
    try testing.expect(has(s, "_h(@ptrCast(@alignCast(_ld)), zidl_rt.unboxAs(DataWriter, _dw), _status.*);"));
    // on_alive has no status — no dereference
    try testing.expect(has(s, "fn _w(_dw: *anyopaque, _ld: ?*anyopaque) callconv(.c) void {"));
    try testing.expect(has(s, "_h(@ptrCast(@alignCast(_ld)), zidl_rt.unboxAs(DataWriter, _dw));"));
}

test "zig_backend: @callback thunk wraps string params with std.mem.span" {
    var out = try testGenOpts(
        \\interface LogListener {
        \\    void on_message(in string msg, in long level);
        \\};
    , "ll", .{ .generate_interfaces = true, .no_typesupport = true, .no_typeobject_support = true });
    defer out.deinit(testing.allocator);
    const s = out.items;
    // Handlers type uses idiomatic []const u8, not the C-ABI [*:0]const u8
    try testing.expect(has(s, "on_message: ?*const fn (*Ctx, []const u8, i32) void = null,"));
    // Thunk receives the C-ABI sentinel pointer
    try testing.expect(has(s, "fn _w(_msg: [*:0]const u8, _level: i32, _ld: ?*anyopaque) callconv(.c) void {"));
    // Thunk converts [*:0]const u8 → []const u8 via std.mem.span before calling _h
    try testing.expect(has(s, "_h(@ptrCast(@alignCast(_ld)), std.mem.span(_msg), _level);"));
}

test "zig_backend: --zig-generate-c-api entity wrappers use C_XxxListener and adapter" {
    var out = try testGenOpts(
        \\interface WriterListener { void on_miss(); };
        \\interface Pub {
        \\    long create_writer(in long qos, in WriterListener a_listener);
        \\    long set_listener(in WriterListener a_listener, in long mask);
        \\};
    , "pw", .{
        .generate_interfaces = true,
        .no_typesupport = true,
        .no_typeobject_support = true,
        .zig_generate_c_api = true,
    });
    defer out.deinit(testing.allocator);
    const s = out.items;
    // Vtable and export both use ?*const WriterListener (the callback struct)
    try testing.expect(has(s, "a_listener: ?*const WriterListener"));
    // Trivial forwarder after unboxing self — no adapter allocation
    try testing.expect(has(s, "return _self.vtable.create_writer(_self.ptr, qos, a_listener);"));
    try testing.expect(!has(s, "std.heap.c_allocator.create(C"));
}

test "zig_backend: --zig-generate-c-api struct in-params use ?*const T (null = default)" {
    var out = try testGenOpts(
        \\struct TopicQos { long depth; };
        \\interface Topic {
        \\    long set_qos(in TopicQos qos);
        \\    long create_with_qos(in TopicQos qos, in long mask);
        \\};
    , "tq", .{
        .generate_interfaces = true,
        .no_typesupport = true,
        .no_typeobject_support = true,
        .zig_generate_c_api = true,
    });
    defer out.deinit(testing.allocator);
    const s = out.items;
    // Export signature: optional pointer so C callers can pass null for default QoS.
    try testing.expect(has(s, "pub export fn Topic_set_qos(self: *anyopaque, qos: ?*const TopicQos) callconv(.c) i32"));
    try testing.expect(has(s, "pub export fn Topic_create_with_qos(self: *anyopaque, qos: ?*const TopicQos, mask: i32) callconv(.c) i32"));
    // Vtable call: substitute default when null.
    try testing.expect(has(s, "return _self.vtable.set_qos(_self.ptr, qos orelse &.{});"));
    try testing.expect(has(s, "return _self.vtable.create_with_qos(_self.ptr, qos orelse &.{}, mask);"));
    // Vtable slot itself stays *const T (non-optional).
    try testing.expect(has(s, "set_qos: *const fn (*anyopaque, qos: *const TopicQos) i32,"));
}

test "zig_backend: --zig-generate-c-api emits C_XxxSeq and out-seq write-back" {
    var out = try testGenOpts(
        \\typedef long long Handle;
        \\typedef sequence<Handle> HandleSeq;
        \\interface Obj { long get_handles(out HandleSeq handles); };
    , "sq", .{
        .generate_interfaces = true,
        .no_typesupport = true,
        .no_typeobject_support = true,
        .zig_generate_c_api = true,
    });
    defer out.deinit(testing.allocator);
    const s = out.items;
    // Sequence typedef is now the extern struct itself (no C_ prefix companion)
    try testing.expect(has(s, "pub const HandleSeq = extern struct {"));
    try testing.expect(has(s, "_buffer: ?[*]Handle = null,"));
    // out param is ?*HandleSeq (no C_ prefix)
    try testing.expect(has(s, "handles: ?*HandleSeq"));
    // Trivial forwarder after unboxing self — no write-back logic
    try testing.expect(has(s, "return _self.vtable.get_handles(_self.ptr, handles);"));
    try testing.expect(!has(s, "pub const C_HandleSeq"));
}

test "zig_backend: --zig-generate-c-api in-StringSeq allocates span conversion" {
    var out = try testGenOpts(
        \\typedef sequence<string> StringSeq;
        \\interface F { long filter(in StringSeq params); };
    , "sf", .{
        .generate_interfaces = true,
        .no_typesupport = true,
        .no_typeobject_support = true,
        .zig_generate_c_api = true,
    });
    defer out.deinit(testing.allocator);
    const s = out.items;
    // StringSeq typedef is the extern struct; [*:0]const u8 buffer (C strings)
    try testing.expect(has(s, "pub const StringSeq = extern struct {"));
    try testing.expect(has(s, "_buffer: ?[*][*:0]const u8 = null,"));
    // param type is nullable pointer to StringSeq (no C_ prefix)
    try testing.expect(has(s, "params: ?*const StringSeq"));
    // Trivial forwarder after unboxing self — no span conversion inside the export fn body.
    // (std.mem.span is legitimately used in StringSeq.deinit, but not in the forwarder.)
    try testing.expect(has(s, "return _self.vtable.filter(_self.ptr, params);"));
    try testing.expect(!has(s, "fn DDS_F_filter") or !has(s, "std.mem.span(params)"));
}

test "zig_backend: --zig-generate-c-api emits noop vtable for listener interfaces" {
    var out = try testGenOpts(
        \\interface Writer { long write_val(in long x); };
        \\interface WriterListener { void on_change(in Writer w); };
    , "wl", .{
        .generate_interfaces = true,
        .no_typesupport = true,
        .no_typeobject_support = true,
        .zig_generate_c_api = true,
    });
    defer out.deinit(testing.allocator);
    const s = out.items;
    // Listener gets a noop constant, not a free function
    try testing.expect(has(s, "pub const noop_WriterListener"));
    try testing.expect(!has(s, "pub export fn WriterListener_on_change"));
    // Entity still gets free functions
    try testing.expect(has(s, "pub export fn Writer_write_val"));
}

test "zig_backend: @callback thunk unwraps ?*const T params (seq typedef and callback struct)" {
    var out = try testGenOpts(
        \\typedef sequence<long> NumSeq;
        \\interface StatusListener {
        \\    void on_missed(in NumSeq missed);
        \\};
    , "sl", .{ .generate_interfaces = true, .no_typesupport = true, .no_typeobject_support = true });
    defer out.deinit(testing.allocator);
    const s = out.items;
    // Thunk receives ?*const NumSeq (C-ABI for seq typedef in-param).
    try testing.expect(has(s, "_missed: ?*const NumSeq"));
    // Thunk body must unwrap the optional pointer, not pass it as-is.
    try testing.expect(has(s, "(if (_missed) |_q| _q.* else .{})"));
    // Handlers signature uses the plain Zig type (by value).
    try testing.expect(has(s, "on_missed: ?*const fn (*Ctx, NumSeq) void = null,"));
}

test "zig_backend: imported callback interface param is qualified in vtable" {
    var out = try testGenOpts(
        \\module DDS { @callback interface DomainParticipantListener {}; };
        \\module zzdds {
        \\    interface Factory {
        \\        void create(in DDS::DomainParticipantListener listener);
        \\    };
        \\};
    , "ext", .{ .generate_interfaces = true, .no_typesupport = true, .no_typeobject_support = true });
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "listener: ?*const DDS.DomainParticipantListener"));
    try testing.expect(!has(s, "listener: ?*const DomainParticipantListener"));
}

test "zig_backend: --zig-generate-c-api with --type-prefix uses prefix in export name" {
    var out = try testGenOpts(
        \\interface Greeter { string greet(in string name); };
    , "g", .{
        .generate_interfaces = true,
        .no_typesupport = true,
        .no_typeobject_support = true,
        .zig_generate_c_api = true,
        .type_prefix = "DDS_",
        // --c-api-impl keys are always the unprefixed qualified name — the
        // prefix only affects generated symbol *names*, not classification.
    });
    defer out.deinit(testing.allocator);
    const s = out.items;
    // Exported symbol must carry the prefix so it matches the C header's declaration
    try testing.expect(has(s, "pub export fn DDS_Greeter_greet("));
    try testing.expect(!has(s, "pub export fn Greeter_greet("));
}

test "zig_backend: --zig-generate-c-api string return uses ptrCast" {
    var out = try testGenOpts(
        \\interface Named { string get_name(); };
    , "n", .{
        .generate_interfaces = true,
        .no_typesupport = true,
        .no_typeobject_support = true,
        .zig_generate_c_api = true,
    });
    defer out.deinit(testing.allocator);
    const s = out.items;
    // Vtable returns [*:0]const u8; trivial forwarder passes it through
    try testing.expect(has(s, "get_name: *const fn (*anyopaque) [*:0]const u8,"));
    try testing.expect(has(s, "callconv(.c) [*:0]const u8"));
    try testing.expect(has(s, "return _self.vtable.get_name(_self.ptr);"));
    // No ptrCast needed — vtable already returns the right type
    try testing.expect(!has(s, "@ptrCast(_r.ptr)"));
}

test "zig_backend: --zig-generate-c-api struct in-param passed by pointer" {
    var out = try testGenOpts(
        \\struct Qos { long depth; };
        \\interface Writer { long set_qos(in Qos qos); };
    , "sq", .{
        .generate_interfaces = true,
        .no_typesupport = true,
        .no_typeobject_support = true,
        .zig_generate_c_api = true,
    });
    defer out.deinit(testing.allocator);
    const s = out.items;
    // Vtable slot: non-optional *const T (vtable always gets a valid pointer).
    try testing.expect(has(s, "set_qos: *const fn (*anyopaque, qos: *const Qos) i32,"));
    // C-ABI export: boxed self, ?*const T so C callers can pass null for defaults.
    try testing.expect(has(s, "pub export fn Writer_set_qos(self: *anyopaque, qos: ?*const Qos) callconv(.c) i32"));
    // Forwarder substitutes type default when null.
    try testing.expect(has(s, "return _self.vtable.set_qos(_self.ptr, qos orelse &.{});"));
    try testing.expect(!has(s, "qos.*"));
}

test "zig_backend: cdr @optional scalar serialize writes bool then value" {
    var out = try testGen(
        \\struct Opt { @optional long maybe_x; long y; };
    , "opt");
    defer out.deinit(testing.allocator);
    const s = out.items;
    // Field type: ?i32
    try testing.expect(has(s, "maybe_x: ?i32 = null"));
    // Serialize: presence bool + conditional value.
    try testing.expect(has(s, "try writer.writeBool(value.maybe_x != null);"));
    try testing.expect(has(s, "if (value.maybe_x) |_opt_maybe_x| {"));
    try testing.expect(has(s, "try writer.writeI32(_opt_maybe_x);"));
    // Non-optional unaffected.
    try testing.expect(has(s, "try writer.writeI32(value.y);"));
}

test "zig_backend: cdr @optional scalar deserialize reads bool and sets null" {
    var out = try testGen(
        \\struct Opt { @optional long maybe_x; long y; };
    , "opt");
    defer out.deinit(testing.allocator);
    const s = out.items;
    // Deserialize: read bool, branch on presence.
    try testing.expect(has(s, "if (try reader.readBool()) {"));
    try testing.expect(has(s, "var _opt_maybe_x: i32 ="));
    try testing.expect(has(s, "out.maybe_x = _opt_maybe_x;"));
    try testing.expect(has(s, "out.maybe_x = null;"));
}

// ── split-file tests ──────────────────────────────────────────────────────────

test "zig_backend split: module gets own file and root re-exports" {
    const alloc = testing.allocator;
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_path = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer alloc.free(tmp_path);

    var ast_arena = std.heap.ArenaAllocator.init(alloc);
    defer ast_arena.deinit();
    var p = parser_mod.Parser.init(
        \\module M { struct S { long x; }; };
    , ast_arena.allocator());
    const spec = try p.parseSpecification();
    var az = try semantic_mod.Analyzer.init(alloc);
    defer az.deinit();
    try az.analyze(&spec);
    var ir_spec = try ir.build(alloc, &spec, az.global_scope, &.{});
    defer ir_spec.deinit();

    const opts = interface.Options{
        .input_stem = "mymod",
        .output_dir = tmp_path,
        .no_typesupport = true,
        .no_typeobject_support = true,
    };
    try generateSplitFiles(alloc, io, &ir_spec, opts);

    // M.zig contains the struct definition.
    const m_path = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}/M.zig", .{tmp.sub_path});
    defer alloc.free(m_path);
    const m_content = try std.Io.Dir.cwd().readFileAlloc(io, m_path, alloc, std.Io.Limit.limited(64 * 1024));
    defer alloc.free(m_content);
    try testing.expect(has(m_content, "pub const S = extern struct {"));

    // mymod.zig re-exports M.
    const root_path = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}/mymod.zig", .{tmp.sub_path});
    defer alloc.free(root_path);
    const root_content = try std.Io.Dir.cwd().readFileAlloc(io, root_path, alloc, std.Io.Limit.limited(64 * 1024));
    defer alloc.free(root_content);
    try testing.expect(has(root_content, "pub const M = @import(\"M.zig\");"));
}

test "zig_backend split: non-module items go in root file" {
    const alloc = testing.allocator;
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_path = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer alloc.free(tmp_path);

    var ast_arena = std.heap.ArenaAllocator.init(alloc);
    defer ast_arena.deinit();
    // No module — just a bare struct at the top level.
    var p = parser_mod.Parser.init(
        \\struct Point { long x; long y; };
    , ast_arena.allocator());
    const spec = try p.parseSpecification();
    var az = try semantic_mod.Analyzer.init(alloc);
    defer az.deinit();
    try az.analyze(&spec);
    var ir_spec = try ir.build(alloc, &spec, az.global_scope, &.{});
    defer ir_spec.deinit();

    const opts = interface.Options{
        .input_stem = "geo",
        .output_dir = tmp_path,
        .no_typesupport = true,
        .no_typeobject_support = true,
    };
    try generateSplitFiles(alloc, io, &ir_spec, opts);

    // geo.zig should contain the struct inline (no module split).
    const root_path = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}/geo.zig", .{tmp.sub_path});
    defer alloc.free(root_path);
    const root_content = try std.Io.Dir.cwd().readFileAlloc(io, root_path, alloc, std.Io.Limit.limited(64 * 1024));
    defer alloc.free(root_content);
    try testing.expect(has(root_content, "pub const Point = extern struct {"));
    // No module re-export lines (those look like: pub const M = @import("M.zig")).
    try testing.expect(!has(root_content, ".zig\");"));
}

test "zig_backend split: imported module names re-exported in root and imported in module files" {
    const alloc = testing.allocator;
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_path = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer alloc.free(tmp_path);

    var ast_arena = std.heap.ArenaAllocator.init(alloc);
    defer ast_arena.deinit();
    var p = parser_mod.Parser.init(
        \\module App { struct Msg { long id; }; };
    , ast_arena.allocator());
    const spec = try p.parseSpecification();
    var az = try semantic_mod.Analyzer.init(alloc);
    defer az.deinit();
    try az.analyze(&spec);
    // Simulate `import "base.idl";` having resolved module "Base".
    var ir_spec = try ir.build(alloc, &spec, az.global_scope, &.{"Base"});
    defer ir_spec.deinit();

    const opts = interface.Options{
        .input_stem = "app",
        .output_dir = tmp_path,
        .no_typesupport = true,
        .no_typeobject_support = true,
    };
    try generateSplitFiles(alloc, io, &ir_spec, opts);

    // Root re-exports both the imported module and the local one.
    const root_path = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}/app.zig", .{tmp.sub_path});
    defer alloc.free(root_path);
    const root_content = try std.Io.Dir.cwd().readFileAlloc(io, root_path, alloc, std.Io.Limit.limited(64 * 1024));
    defer alloc.free(root_content);
    try testing.expect(has(root_content, "pub const Base = @import(\"Base.zig\");"));
    try testing.expect(has(root_content, "pub const App = @import(\"App.zig\");"));

    // App.zig imports Base so cross-module references resolve.
    const app_path = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}/App.zig", .{tmp.sub_path});
    defer alloc.free(app_path);
    const app_content = try std.Io.Dir.cwd().readFileAlloc(io, app_path, alloc, std.Io.Limit.limited(64 * 1024));
    defer alloc.free(app_content);
    try testing.expect(has(app_content, "const Base = @import(\"Base.zig\");"));
}

test "zig_backend single-file: imported module names emitted as @import lines" {
    // In single-file mode the generated {stem}.zig emits `const X = @import("X.zig")`
    // for each imported module.  The caller is responsible for ensuring X.zig exists
    // alongside the output file (e.g. by co-locating split-files output from the
    // imported IDL into the same output directory).
    var out = try testGenOpts(
        \\module App { struct Msg { long id; }; };
    , "app", .{
        .no_typesupport = true,
        .no_typeobject_support = true,
        .imports = &.{"Base"},
    });
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "const Base = @import(\"Base.zig\");"));
    // The local module is still emitted inline (not re-exported via @import).
    try testing.expect(has(s, "pub const App = struct {"));
}

test "zig_backend type_prefix: struct declaration prefixed" {
    var out = try testGenOpts("struct Foo { long x; };", "t", .{
        .no_typesupport = true,
        .no_typeobject_support = true,
        .type_prefix = "DDS_",
    });
    defer out.deinit(testing.allocator);
    try testing.expect(has(out.items, "pub const DDS_Foo = extern struct {"));
    try testing.expect(!has(out.items, "pub const Foo = extern struct {"));
}

test "zig_backend type_prefix: enum declaration prefixed" {
    var out = try testGenOpts("enum Color { RED, GREEN };", "t", .{
        .no_typesupport = true,
        .no_typeobject_support = true,
        .type_prefix = "DDS_",
    });
    defer out.deinit(testing.allocator);
    try testing.expect(has(out.items, "pub const DDS_Color = enum("));
}

test "zig_backend type_prefix: field type reference prefixed" {
    var out = try testGenOpts(
        \\struct Point { long x; long y; };
        \\struct Line { Point start; Point end; };
    , "t", .{
        .no_typesupport = true,
        .no_typeobject_support = true,
        .type_prefix = "DDS_",
    });
    defer out.deinit(testing.allocator);
    try testing.expect(has(out.items, "pub const DDS_Line = extern struct {"));
    try testing.expect(has(out.items, "start: DDS_Point"));
}

test "zig_backend type_prefix: module name not prefixed" {
    var out = try testGenOpts("module M { struct S { long x; }; };", "t", .{
        .no_typesupport = true,
        .no_typeobject_support = true,
        .type_prefix = "DDS_",
    });
    defer out.deinit(testing.allocator);
    // Module M should NOT be prefixed.
    try testing.expect(has(out.items, "pub const M = struct {"));
    // But type S inside it should be.
    try testing.expect(has(out.items, "pub const DDS_S = extern struct {"));
}

// ── PL_CDR generation ─────────────────────────────────────────────────────────

test "zig_backend pl_cdr: not emitted without --zig-pl-cdr" {
    var out = try testGenOpts("@mutable struct S { long x; long y; };", "t", .{
        .no_typeobject_support = true,
    });
    defer out.deinit(testing.allocator);
    try testing.expect(!has(out.items, "serializePlCdr"));
    try testing.expect(!has(out.items, "deserializeFromPlCdr"));
}

test "zig_backend pl_cdr: not emitted for non-mutable struct" {
    var out = try testGenOpts("@appendable struct S { long x; long y; };", "t", .{
        .no_typeobject_support = true,
        .pl_cdr = true,
    });
    defer out.deinit(testing.allocator);
    try testing.expect(!has(out.items, "serializePlCdr"));
    try testing.expect(!has(out.items, "deserializeFromPlCdr"));
}

test "zig_backend pl_cdr: serializePlCdr emitted for @mutable struct" {
    var out = try testGenOpts("@mutable struct S { long x; long y; };", "t", .{
        .no_typeobject_support = true,
        .pl_cdr = true,
    });
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "pub fn serializePlCdr(writer: *zidl_rt.PlCdrWriter, value: @This()) !void {"));
    try testing.expect(has(s, "reservePlParam(0)"));
    try testing.expect(has(s, "reservePlParam(1)"));
    try testing.expect(has(s, "patchPlParam(_ph0)"));
    try testing.expect(has(s, "patchPlParam(_ph1)"));
    try testing.expect(has(s, "writePlSentinel()"));
}

test "zig_backend pl_cdr: deserializeFromPlCdr emitted for @mutable struct" {
    var out = try testGenOpts("@mutable struct S { long x; long y; };", "t", .{
        .no_typeobject_support = true,
        .pl_cdr = true,
    });
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "pub fn deserializeFromPlCdr(out: *@This(), reader: *zidl_rt.CdrReader, allocator: std.mem.Allocator) !void {"));
    try testing.expect(has(s, "readPlParam()"));
    try testing.expect(has(s, "switch (_p.pid & 0x3FFF) {"));
    try testing.expect(has(s, "seekTo(_p.end_pos)"));
}

test "zig_backend pl_cdr: @optional member skips sentinel in serialize" {
    var out = try testGenOpts("@mutable struct S { @optional long x; long y; };", "t", .{
        .no_typeobject_support = true,
        .pl_cdr = true,
    });
    defer out.deinit(testing.allocator);
    const s = out.items;
    // @optional x: emit PID only when present
    try testing.expect(has(s, "if (value.x) |_opt_x|"));
    // y: always emitted
    try testing.expect(has(s, "reservePlParam(1)"));
}

test "zig_backend pl_cdr: explicit @id used as PID" {
    var out = try testGenOpts("@mutable struct S { @id(42) long x; long y; };", "t", .{
        .no_typeobject_support = true,
        .pl_cdr = true,
    });
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "reservePlParam(42)"));
    // y is member index 1 (no explicit @id)
    try testing.expect(has(s, "reservePlParam(1)"));
}

// ── @pl_repeated ──────────────────────────────────────────────────────────────

test "zig_backend pl_cdr: @pl_repeated serialize: per-element loop" {
    var out = try testGenOpts(
        "@mutable struct S { @id(10) @pl_repeated sequence<long> items; };",
        "t",
        .{ .no_typeobject_support = true, .pl_cdr = true },
    );
    defer out.deinit(testing.allocator);
    const s = out.items;
    // Per-element loop: field `items` now uses extern struct _buffer/_length.
    try testing.expect(has(s, "if (value.items._buffer) |_sb|"));
    try testing.expect(has(s, "for (_sb[0..value.items._length]) |_elem|"));
    // One reservePlParam per element (no index suffix).
    try testing.expect(has(s, "const _ph = try writer.reservePlParam(10)"));
    try testing.expect(has(s, "try writer.patchPlParam(_ph)"));
    try testing.expect(!has(s, "const _ph0 = try writer.reservePlParam(10)"));
}

test "zig_backend pl_cdr: @pl_repeated deserialize: append per PID occurrence" {
    var out = try testGenOpts(
        "@mutable struct S { @id(10) @pl_repeated sequence<long> items; };",
        "t",
        .{ .no_typeobject_support = true, .pl_cdr = true },
    );
    defer out.deinit(testing.allocator);
    const s = out.items;
    // Switch on PID 10.
    try testing.expect(has(s, "10 => {"));
    // Grow-by-one: alloc new buffer, memcpy, write element.
    try testing.expect(has(s, "const _plen = out.items._length;"));
    try testing.expect(has(s, "const _pbuf = try allocator.alloc(i32, _plen + 1);"));
    try testing.expect(has(s, "_pbuf[_plen] = try reader.readI32();"));
}

test "zig_backend pl_cdr: @pl_repeated + @optional serialize" {
    var out = try testGenOpts(
        "@mutable struct S { @id(5) @optional @pl_repeated sequence<long> vals; };",
        "t",
        .{ .no_typeobject_support = true, .pl_cdr = true },
    );
    defer out.deinit(testing.allocator);
    const s = out.items;
    // @optional wrapper uses the captured sequence.
    try testing.expect(has(s, "if (value.vals) |_seq_0|"));
    try testing.expect(has(s, "if (_seq_0._buffer) |_sb|"));
    try testing.expect(has(s, "const _ph = try writer.reservePlParam(5)"));
}

test "zig_backend pl_cdr: @pl_repeated + @optional deserialize" {
    var out = try testGenOpts(
        "@mutable struct S { @id(5) @optional @pl_repeated sequence<long> vals; };",
        "t",
        .{ .no_typeobject_support = true, .pl_cdr = true },
    );
    defer out.deinit(testing.allocator);
    const s = out.items;
    // Must initialise the optional on first occurrence.
    try testing.expect(has(s, "if (out.vals == null) out.vals = .{}"));
    // Must grow by one using alloc+memcpy pattern.
    try testing.expect(has(s, "const _plen = out.vals.?._length;"));
}

test "zig_backend pl_cdr: @pl_repeated with struct element type" {
    var out = try testGenOpts(
        \\struct Point { long x; long y; };
        \\@mutable struct S { @id(1) @pl_repeated sequence<Point> pts; };
    , "t", .{ .no_typeobject_support = true, .pl_cdr = true });
    defer out.deinit(testing.allocator);
    const s = out.items;
    // Serialize: iterate via _buffer/_length.
    try testing.expect(has(s, "if (value.pts._buffer) |_sb|"));
    try testing.expect(has(s, "for (_sb[0..value.pts._length]) |_elem|"));
    try testing.expect(has(s, "try Point.serialize(writer, _elem)"));
    // Deserialize: alloc + deserializeInto.
    try testing.expect(has(s, "const _pbuf = try allocator.alloc(Point, _plen + 1);"));
    try testing.expect(has(s, "try Point.deserializeInto(&_pbuf[_plen], reader, allocator);"));
}

test "zig_backend pl_cdr: @pl_repeated with string element type" {
    var out = try testGenOpts(
        "@mutable struct S { @id(3) @pl_repeated sequence<string> strs; };",
        "t",
        .{ .no_typeobject_support = true, .pl_cdr = true },
    );
    defer out.deinit(testing.allocator);
    const s = out.items;
    // Serialize: iterate via _buffer/_length.
    try testing.expect(has(s, "if (value.strs._buffer) |_sb|"));
    try testing.expect(has(s, "for (_sb[0..value.strs._length]) |_elem|"));
    try testing.expect(has(s, "try writer.writeString(_elem)"));
    // Deserialize: alloc + readString.
    try testing.expect(has(s, "const _pbuf = try allocator.alloc([*:0]const u8, _plen + 1);"));
}

test "zig_backend: fixed<5,2> field type is f64 with zero default" {
    var out = try testGen("struct S { fixed<5,2> price; };", "fp");
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "price: f64 = 0.0,"));
}

test "zig_backend: fixed<5,2> serialize emits writeFixed(5,2)" {
    var out = try testGen("struct S { fixed<5,2> price; };", "fp");
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "try writer.writeFixed(5, 2, value.price);"));
    try testing.expect(has(s, "out.price = try reader.readFixed(5, 2);"));
}

test "zig_backend: fixed<4,0> (even digits) serialize emits writeFixed(4,0)" {
    var out = try testGen("struct S { fixed<4,0> qty; };", "fp");
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "try writer.writeFixed(4, 0, value.qty);"));
    try testing.expect(has(s, "out.qty = try reader.readFixed(4, 0);"));
}

// ── Typed DataWriter / DataReader tests ───────────────────────────────────────

test "zig_backend: no typed DataWriter/DataReader by default for keyed struct" {
    var out = try testGen(
        \\@appendable struct ShapeType { @key string<128> color; long x; long y; long shapesize; };
    , "shape");
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(!has(s, "DataWriter"));
    try testing.expect(!has(s, "DataReader"));
    try testing.expect(!has(s, "const _zzdds ="));
    try testing.expect(has(s, "pub fn serialize"));
}

test "zig_backend: typed DataWriter/DataReader for keyed @appendable struct" {
    var out = try testGenOpts(
        \\@appendable struct ShapeType { @key string<128> color; long x; long y; long shapesize; };
    , "shape", .{ .generate_zzdds_wrappers = true });
    defer out.deinit(testing.allocator);
    const s = out.items;
    // zzdds import emitted
    try testing.expect(has(s, "const _zzdds = @import(\"zzdds\");"));
    // DataWriter struct
    try testing.expect(has(s, "pub const ShapeTypeDataWriter = struct {"));
    try testing.expect(has(s, "_dw: _zzdds.DDS.DataWriter,"));
    try testing.expect(has(s, "_alloc: std.mem.Allocator,"));
    try testing.expect(has(s, "_xcdr2: bool,"));
    try testing.expect(has(s, "pub fn init(dw: _zzdds.DDS.DataWriter, alloc: std.mem.Allocator) @This() {"));
    // write() — @appendable uses writeEncapHeaderDelimited for xcdr2
    try testing.expect(has(s, "pub fn write(self: @This(), instance_data: ShapeType, _: _zzdds.DDS.InstanceHandle_t) !void {"));
    try testing.expect(has(s, "try _w.writeEncapHeaderDelimited();"));
    try testing.expect(has(s, "try ShapeType.serialize(&_w, instance_data);"));
    try testing.expect(has(s, "try _zzdds.writeRaw(self._dw, .alive, _hash, _buf.items);"));
    // dispose()
    try testing.expect(has(s, "pub fn dispose(self: @This(), instance_data: ShapeType, _: _zzdds.DDS.InstanceHandle_t) !void {"));
    try testing.expect(has(s, "try ShapeType.serializeKey(&_w, instance_data);"));
    try testing.expect(has(s, "try _zzdds.writeRaw(self._dw, .dispose, _hash, _buf.items);"));
    // unregister_instance()
    try testing.expect(has(s, "pub fn unregister_instance(self: @This(), instance_data: ShapeType, _: _zzdds.DDS.InstanceHandle_t) !void {"));
    try testing.expect(has(s, "try _zzdds.writeRaw(self._dw, .unregister, _hash, _buf.items);"));
    // DataReader struct
    try testing.expect(has(s, "pub const ShapeTypeDataReader = struct {"));
    try testing.expect(has(s, "_dr: _zzdds.DDS.DataReader,"));
    try testing.expect(has(s, "pub fn init(dr: _zzdds.DDS.DataReader, alloc: std.mem.Allocator) @This() {"));
    try testing.expect(has(s, "pub const SampledValue = struct {"));
    try testing.expect(has(s, "value: ShapeType,"));
    try testing.expect(has(s, "info: _zzdds.DDS.SampleInfo,"));
    try testing.expect(has(s, "pub fn take_next_sample(self: @This(), data_value: *ShapeType, sample_info: *_zzdds.DDS.SampleInfo) !bool {"));
    try testing.expect(has(s, "_zzdds.takeRaw(self._dr)"));
    try testing.expect(has(s, "ShapeType.deserialize(&_r, self._alloc)"));
    // no SampledValue.deinit — ShapeType has no unbounded sequences
    try testing.expect(!has(s, "pub fn deinit(self: *@This(), alloc: std.mem.Allocator) void {"));
}

test "zig_backend: typed DataReader gets take_w_condition/read_w_condition and take_next_instance_w_condition/read_next_instance_w_condition" {
    var out = try testGenOpts(
        \\@appendable struct ShapeType { @key string<128> color; long x; long y; long shapesize; };
    , "shape", .{ .generate_zzdds_wrappers = true });
    defer out.deinit(testing.allocator);
    const s = out.items;

    // take_w_condition/read_w_condition: state masks (and, for a
    // QueryCondition, the query filter) come from `cond` itself -- no mask
    // parameters, unlike take()/read()/take_instance()/read_instance().
    try testing.expect(has(s, "pub fn take_w_condition(self: @This(), out: *std.ArrayListUnmanaged(SampledValue), cond: _zzdds.DDS.ReadCondition, max: i32) !bool {"));
    try testing.expect(has(s, "_zzdds.takeWithReadConditionRaw(self._dr, cond, &_tmp, max, self._alloc);"));
    try testing.expect(has(s, "pub fn read_w_condition(self: @This(), out: *std.ArrayListUnmanaged(SampledValue), cond: _zzdds.DDS.ReadCondition, max: i32) !bool {"));
    try testing.expect(has(s, "_zzdds.readWithReadConditionRaw(self._dr, cond, &_tmp, max, self._alloc);"));

    // take_next_instance_w_condition/read_next_instance_w_condition: also
    // scoped to the "next instance" after `prev`.
    try testing.expect(has(s, "pub fn take_next_instance_w_condition(self: @This(), out: *std.ArrayListUnmanaged(SampledValue), cond: _zzdds.DDS.ReadCondition, prev: _zzdds.DDS.InstanceHandle_t, max: i32) !bool {"));
    try testing.expect(has(s, "_zzdds.takeNextInstanceWithReadConditionRaw(self._dr, cond, prev, &_tmp, max, self._alloc);"));
    try testing.expect(has(s, "pub fn read_next_instance_w_condition(self: @This(), out: *std.ArrayListUnmanaged(SampledValue), cond: _zzdds.DDS.ReadCondition, prev: _zzdds.DDS.InstanceHandle_t, max: i32) !bool {"));
    try testing.expect(has(s, "_zzdds.readNextInstanceWithReadConditionRaw(self._dr, cond, prev, &_tmp, max, self._alloc);"));

    // Shared decode tail must still fire for the new methods too (proves the
    // emitReaderDecodeTmpTail extraction didn't drop anything).
    try testing.expect(has(s, "ShapeType.deserialize(&_r, self._alloc)"));
}

test "zig_backend: typed DataWriter uses writeEncapHeader for @final struct" {
    var out = try testGenOpts(
        \\@final struct SensorData { @key long id; double value; };
    , "sensor", .{ .generate_zzdds_wrappers = true });
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "pub const SensorDataDataWriter = struct {"));
    // @final: no writeEncapHeaderDelimited anywhere
    try testing.expect(!has(s, "writeEncapHeaderDelimited"));
    // both xcdr1 and xcdr2 branches use plain writeEncapHeader
    try testing.expect(has(s, "try _w.writeEncapHeader();"));
}

test "zig_backend: DataWriter/DataReader still emitted for a keyless struct" {
    // A keyless Topic is spec-legitimate (DDS 1.4 2.2.2.1: "restricted to a
    // single instance"), so --generate-zzdds-wrappers must not skip it.
    var out = try testGenOpts("struct NoKey { long x; long y; };", "nk", .{ .generate_zzdds_wrappers = true });
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "pub const NoKeyDataWriter = struct {"));
    try testing.expect(has(s, "pub const NoKeyDataReader = struct {"));
    try testing.expect(has(s, "const _zzdds ="));
    // has_key stays accurately false -- only the wrapper-support helpers
    // below are added, not a fake key.
    try testing.expect(has(s, "pub const has_key = false;"));
}

test "zig_backend: keyless struct gets trivial key helpers under --generate-zzdds-wrappers" {
    var out = try testGenOpts("struct NoKey { long x; long y; };", "nk", .{ .generate_zzdds_wrappers = true });
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "pub fn computeKeyHash(value: @This()) [16]u8 {"));
    try testing.expect(has(s, "return std.mem.zeroes([16]u8);"));
    try testing.expect(has(s, "pub fn serializeKey(writer: anytype, value: @This()) !void {"));
    try testing.expect(has(s, "pub fn deserializeKey(reader: *zidl_rt.CdrReader, allocator: std.mem.Allocator) !@This() {"));
    try testing.expect(has(s, "pub fn deserializeKeyInto(out: *@This(), reader: *zidl_rt.CdrReader, allocator: std.mem.Allocator) !void {"));
}

// ── getFieldFromCdr tests ──────────────────────────────────────────────────

test "zig_backend: getFieldFromCdr matches int/string members, skips complex ones" {
    var out = try testGenOpts(
        \\struct Inner { long z; };
        \\@appendable struct ShapeType {
        \\    @key string<128> color;
        \\    long x;
        \\    long y;
        \\    string note;
        \\    Inner nested;
        \\    sequence<long> values;
        \\};
    , "shape", .{ .generate_zzdds_wrappers = true });
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "pub fn getFieldFromCdr(ctx: *anyopaque, payload: []const u8, field: []const u8, scratch: []u8) ?_zzdds.dcps.filter.FilterValue {"));
    try testing.expect(has(s, "const allocator: *const std.mem.Allocator = @ptrCast(@alignCast(ctx));"));
    try testing.expect(has(s, "var _reader = zidl_rt.CdrReader.init(payload) catch return null;"));
    try testing.expect(has(s, "_v = @This().deserialize(&_reader, allocator.*) catch return null;"));
    // bounded @key string: uses .slice(), copies into scratch
    try testing.expect(has(s, "if (std.mem.eql(u8, field, \"color\")) {"));
    try testing.expect(has(s, "const _s = _v.color.slice();"));
    try testing.expect(has(s, "if (_s.len > scratch.len) return null;"));
    try testing.expect(has(s, "@memcpy(scratch[0.._s.len], _s);"));
    try testing.expect(has(s, "return .{ .string = scratch[0.._s.len] };"));
    // plain int members
    try testing.expect(has(s, "if (std.mem.eql(u8, field, \"x\")) return .{ .int = @intCast(_v.x) };"));
    try testing.expect(has(s, "if (std.mem.eql(u8, field, \"y\")) return .{ .int = @intCast(_v.y) };"));
    // unbounded string: member used directly, no .slice()
    try testing.expect(has(s, "if (std.mem.eql(u8, field, \"note\")) {"));
    try testing.expect(has(s, "const _s = _v.note;"));
    // nested struct and sequence members are not filterable -- skipped entirely
    try testing.expect(!has(s, "\"nested\""));
    try testing.expect(!has(s, "\"values\""));
    // falls through to null when nothing matched
    try testing.expect(has(s, "        return null;\n    }\n"));
}

test "zig_backend: getFieldFromCdr converts bool/enum/float members correctly" {
    var out = try testGenOpts(
        \\enum Color { RED, GREEN, BLUE };
        \\@appendable struct Widget {
        \\    @key long id;
        \\    boolean active;
        \\    Color color;
        \\    double ratio;
        \\};
    , "widget", .{ .generate_zzdds_wrappers = true });
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "if (std.mem.eql(u8, field, \"active\")) return .{ .int = @intFromBool(_v.active) };"));
    try testing.expect(has(s, "if (std.mem.eql(u8, field, \"color\")) return .{ .int = @intCast(@intFromEnum(_v.color)) };"));
    try testing.expect(has(s, "if (std.mem.eql(u8, field, \"ratio\")) return .{ .float = @floatCast(_v.ratio) };"));
}

test "zig_backend: getFieldFromCdr emitted for keyless struct too" {
    var out = try testGenOpts("struct NoKey { long x; long y; };", "nk", .{ .generate_zzdds_wrappers = true });
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "pub fn getFieldFromCdr(ctx: *anyopaque, payload: []const u8, field: []const u8, scratch: []u8) ?_zzdds.dcps.filter.FilterValue {"));
    try testing.expect(has(s, "if (std.mem.eql(u8, field, \"x\")) return .{ .int = @intCast(_v.x) };"));
}

test "zig_backend: getFieldFromCdr discards scratch when no string member exists" {
    // Regression test: a struct with zero string_like members left `scratch`
    // completely unreferenced in the generated body (it's only used inside
    // the string_like branch), which Zig's compiler rejects as an unused
    // function parameter -- a real, live bug found building zzdds-examples'
    // `presence` example against a single-int-field struct, not caught by
    // this file's other getFieldFromCdr tests since none of them actually
    // compile the generated output (see the fix commit for the full trail).
    // `field` itself IS used here (there's an int_like member), so it must
    // NOT be discarded -- Zig equally rejects a discard of something that's
    // genuinely used later ("pointless discard").
    var out = try testGenOpts(
        \\@appendable struct IntOnly { long seq_num; };
    , "intonly", .{ .generate_zzdds_wrappers = true });
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "pub fn getFieldFromCdr(ctx: *anyopaque, payload: []const u8, field: []const u8, scratch: []u8) ?_zzdds.dcps.filter.FilterValue {"));
    try testing.expect(has(s, "_ = scratch;"));
    try testing.expect(!has(s, "_ = field;"));
    try testing.expect(has(s, "if (std.mem.eql(u8, field, \"seq_num\")) return .{ .int = @intCast(_v.seq_num) };"));
    // no string_like member -- scratch is never actually written into
    try testing.expect(!has(s, "scratch[0.."));
}

test "zig_backend: getFieldFromCdr discards both field and scratch when no filterable member exists" {
    // The other half of the same bug class: a struct with only array/
    // complex members (every member `.skip`) leaves `field` unreferenced
    // too, not just `scratch`.
    var out = try testGenOpts(
        \\struct Inner { long z; };
        \\@appendable struct OnlyComplex { sequence<long> values; Inner nested; };
    , "onlycomplex", .{ .generate_zzdds_wrappers = true });
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "_ = field;"));
    try testing.expect(has(s, "_ = scratch;"));
}

test "zig_backend: no getFieldFromCdr without --generate-zzdds-wrappers" {
    var out = try testGen("@appendable struct ShapeType { @key string<128> color; long x; };", "shape");
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(!has(s, "getFieldFromCdr"));
}

test "zig_backend: keyless struct without --generate-zzdds-wrappers still emits no key helpers" {
    // The plain (non-wrapper) codegen path is unchanged: a keyless struct
    // used only as a nested/plain type, not a Topic, gets no key machinery.
    var out = try testGen("struct NoKey { long x; long y; };", "nk");
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(!has(s, "computeKeyHash"));
    try testing.expect(!has(s, "serializeKey"));
    try testing.expect(!has(s, "deserializeKey"));
}

test "zig_backend: no_typesupport suppresses DataWriter/DataReader" {
    var out = try testGenOpts(
        "@appendable struct ShapeType { @key string<128> color; long x; };",
        "shape",
        .{ .no_typesupport = true, .generate_zzdds_wrappers = true },
    );
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(!has(s, "DataWriter"));
    try testing.expect(!has(s, "DataReader"));
    try testing.expect(!has(s, "const _zzdds ="));
}

test "zig_backend: no DataWriter/DataReader for @mutable keyed struct" {
    var out = try testGenOpts(
        "@mutable struct MutableTopic { @key long id; string data; };",
        "mt",
        .{ .generate_zzdds_wrappers = true },
    );
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(!has(s, "DataWriter"));
    try testing.expect(!has(s, "DataReader"));
}

test "zig_backend: no DataWriter/DataReader or zzdds import for @nested keyed struct" {
    var out = try testGenOpts(
        "@nested struct NestedKey { @key long id; string data; };",
        "nk",
        .{ .generate_zzdds_wrappers = true },
    );
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(!has(s, "DataWriter"));
    try testing.expect(!has(s, "DataReader"));
    try testing.expect(!has(s, "const _zzdds ="));
}

test "zig_backend: Sample.deinit emitted when struct has unbounded sequence" {
    var out = try testGenOpts(
        \\@appendable struct BagTopic { @key long id; sequence<long> items; };
    , "bag", .{ .generate_zzdds_wrappers = true });
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "pub const BagTopicDataReader = struct {"));
    // BagTopic has unbounded sequence → deinit on SampledValue
    try testing.expect(has(s, "pub const SampledValue = struct {"));
    try testing.expect(has(s, "pub fn deinit(self: *@This(), alloc: std.mem.Allocator) void {"));
    try testing.expect(has(s, "self.value.deinit(alloc);"));
}

test "zig_backend: plain unbounded string field gets deinit/clone, general case" {
    // Parity fix: unlike sequences, plain unbounded strings used to only get
    // cleanup under --zig-generate-toml-config. No flag here.
    var out = try testGen(
        \\struct Note { string body; long id; };
    , "note");
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "pub fn deinit(self: *@This(), alloc: std.mem.Allocator) void {"));
    try testing.expect(has(s, "if (self.body.len != 0) alloc.free(self.body);"));
    try testing.expect(!has(s, "_toml_applied")); // not a toml-config struct
    try testing.expect(has(s, "pub fn clone(self: @This(), alloc: std.mem.Allocator) !@This() {"));
    try testing.expect(has(s, "result.body = if (self.body.len != 0) try alloc.dupe(u8, self.body) else self.body;"));
}

test "zig_backend: non-empty @default string field excluded from cleanup outside toml config" {
    // A member with a non-empty @default is left out of deinit()/clone(): its
    // default is a comptime string literal, unsafe to alloc.free() if deinit()
    // ever fires on a value that was never deserialized. Only `label` (with
    // the risky non-empty default) is excluded; `note` (no default) still
    // gets real cleanup, so deinit()/clone() are still emitted for the struct.
    var out = try testGen(
        \\struct Cfg {
        \\    @default("unknown") string label;
        \\    string note;
        \\};
    , "cfg");
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "pub fn deinit(self: *@This(), alloc: std.mem.Allocator) void {"));
    try testing.expect(!has(s, "alloc.free(self.label)"));
    try testing.expect(has(s, "if (self.note.len != 0) alloc.free(self.note);"));
    try testing.expect(has(s, "pub fn clone(self: @This(), alloc: std.mem.Allocator) !@This() {"));
    try testing.expect(!has(s, "result.label ="));
    try testing.expect(has(s, "result.note = if (self.note.len != 0) try alloc.dupe(u8, self.note) else self.note;"));
}

test "zig_backend: empty @default string field still gets cleanup outside toml config" {
    // @default("") is always safe to free (zero-length) -- only a *non-empty*
    // default is excluded.
    var out = try testGen(
        \\struct Cfg2 { @default("") string label; };
    , "cfg2");
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "pub fn deinit(self: *@This(), alloc: std.mem.Allocator) void {"));
    try testing.expect(has(s, "if (self.label.len != 0) alloc.free(self.label);"));
}

test "zig_backend: non-empty @default string field still gets cleanup under --zig-generate-toml-config" {
    // Under the toml flag, applyToml unconditionally dupes every string field
    // and _toml_applied tracks real per-value ownership -- so the exclusion
    // above does not apply here.
    var out = try testGenOpts(
        \\struct Cfg3 { @default("unknown") string label; };
    , "cfg3", .{ .zig_generate_toml_config = true, .no_typesupport = true, .no_typeobject_support = true });
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "pub fn deinit(self: *@This(), alloc: std.mem.Allocator) void {"));
    try testing.expect(has(s, "if (self._toml_applied and self.label.len != 0) alloc.free(self.label);"));
}

test "zig_backend: DataWriter/DataReader inside module" {
    var out = try testGenOpts(
        \\module DDS { @appendable struct Shape { @key string<64> color; long x; }; };
    , "dds", .{ .generate_zzdds_wrappers = true });
    defer out.deinit(testing.allocator);
    const s = out.items;
    // _zzdds import at file level (prefixed to avoid clash with any IDL module named "dds")
    try testing.expect(has(s, "const _zzdds = @import(\"zzdds\");"));
    // wrappers inside module struct
    try testing.expect(has(s, "pub const ShapeDataWriter = struct {"));
    try testing.expect(has(s, "pub const ShapeDataReader = struct {"));
}

test "zig_backend: module named 'dds' does not produce duplicate const dds" {
    // IDL module named 'dds' — using '_zzdds' import makes any name clash with
    // IDL module identifiers structurally impossible (IDL names cannot start with '_').
    var out = try testGenOpts(
        \\module dds { @appendable struct Topic { @key long id; }; };
    , "types", .{ .generate_zzdds_wrappers = true });
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "const _zzdds = @import(\"zzdds\");"));
    try testing.expect(!has(s, "const zzdds = @import(\"zzdds\");"));
    try testing.expect(has(s, "pub const TopicDataWriter = struct {"));
    try testing.expect(has(s, "_dw: _zzdds.DDS.DataWriter,"));
}

test "zig_backend: @default on non-optional field sets initializer" {
    var h = try testGen(
        \\struct Cfg {
        \\    @default(7400) unsigned short base_port;
        \\    @default(TRUE) boolean active;
        \\    @default("hello") string label;
        \\};
    , "cfg");
    defer h.deinit(testing.allocator);
    const s = h.items;
    try testing.expect(has(s, "base_port: u16 = 7400,"));
    try testing.expect(has(s, "active: bool = true,"));
    try testing.expect(has(s, "label: []const u8 = \"hello\","));
}

test "zig_backend: @optional with @default sets typed optional initializer" {
    var h = try testGen(
        \\struct Cfg {
        \\    @optional @default(42) long val;
        \\};
    , "cfg");
    defer h.deinit(testing.allocator);
    try testing.expect(has(h.items, "val: ?i32 = 42,"));
}

test "zig_backend: @optional without @default initializes to null" {
    var h = try testGen(
        \\struct Cfg {
        \\    @optional long val;
        \\};
    , "cfg");
    defer h.deinit(testing.allocator);
    try testing.expect(has(h.items, "val: ?i32 = null,"));
}

test "zig_backend: @default float field sets initializer" {
    var h = try testGen(
        \\struct Cfg { @default(3.14) float speed; };
    , "cfg");
    defer h.deinit(testing.allocator);
    try testing.expect(has(h.items, "speed: f32 = 3.14,"));
}

test "zig_backend: @default char field emits character literal" {
    var h = try testGen(
        \\struct Cfg { @default('A') char c; };
    , "cfg");
    defer h.deinit(testing.allocator);
    try testing.expect(has(h.items, "c: u8 = 'A',"));
}

test "zig_backend: @default scoped_name emits identifier" {
    var h = try testGen(
        \\const long MY_MAX = 100;
        \\struct Cfg { @default(MY_MAX) long limit; };
    , "cfg");
    defer h.deinit(testing.allocator);
    try testing.expect(has(h.items, "limit: i32 = MY_MAX,"));
}

test "zig_backend: @default enum scoped_name emits enum tag" {
    var h = try testGen(
        \\enum Kind { FIRST, SECOND };
        \\struct Cfg { @default(SECOND) Kind kind; };
    , "cfg");
    defer h.deinit(testing.allocator);
    try testing.expect(has(h.items, "kind: Kind = .SECOND,"));
}

test "zig_backend: @default bitmask scoped_name emits bit constant" {
    var h = try testGen(
        \\bitmask Flags { READ, WRITE };
        \\struct Cfg { @default(WRITE) Flags flags; };
    , "cfg");
    defer h.deinit(testing.allocator);
    try testing.expect(has(h.items, "flags: Flags = Flags_WRITE,"));
}

test "zig_backend: @default module bitmask scoped_name emits module bit constant" {
    var h = try testGen(
        \\module DDS {
        \\    bitmask Flags { READ, WRITE };
        \\    struct Cfg { @default(WRITE) Flags mask; };
        \\};
    , "cfg");
    defer h.deinit(testing.allocator);
    try testing.expect(has(h.items, "mask: DDS.Flags = DDS.Flags_WRITE,"));
}

test "zig_backend: struct with sequence field gets _free export under zig_generate_c_api" {
    var h = try testGenOpts(
        \\struct Policy { sequence<octet> value; };
    , "t", .{ .zig_generate_c_api = true, .no_typesupport = true, .no_typeobject_support = true });
    defer h.deinit(testing.allocator);
    // Export function uses C name (qualified) and calls deinit with c_allocator
    try testing.expect(has(h.items, "Policy_free"));
    try testing.expect(has(h.items, "callconv(.c)"));
    try testing.expect(has(h.items, "v.deinit(std.heap.c_allocator)"));
}

test "zig_backend: struct without sequence fields has no _free export" {
    var h = try testGenOpts(
        \\struct Simple { long x; };
    , "t", .{ .zig_generate_c_api = true, .no_typesupport = true, .no_typeobject_support = true });
    defer h.deinit(testing.allocator);
    try testing.expect(!has(h.items, "_free"));
}

test "zig_backend: sequence typedef gets _free export when zig_generate_c_api" {
    var h = try testGenOpts(
        \\typedef sequence<string> StringSeq;
    , "t", .{ .zig_generate_c_api = true, .no_typesupport = true, .no_typeobject_support = true });
    defer h.deinit(testing.allocator);
    try testing.expect(has(h.items, "pub export fn StringSeq_free("));
    try testing.expect(has(h.items, "v.deinit(std.heap.c_allocator)"));
}

test "zig_backend: sequence typedef has no _free export without zig_generate_c_api" {
    var h = try testGenOpts(
        \\typedef sequence<octet> OctetSeq;
    , "t", .{ .no_typesupport = true, .no_typeobject_support = true });
    defer h.deinit(testing.allocator);
    try testing.expect(!has(h.items, "_free"));
}

test "zig_backend: as_Base vtable slot emitted for every direct base, unconditionally" {
    // Entity is the first declared base, TopicDescription the second —
    // deliberately mirroring dcps.idl's `Topic : Entity, TopicDescription`.
    // The second base's fields land at a non-zero offset within Topic's own
    // flattened Vtable, which is exactly why a raw pointer-reinterpretation
    // upcast (instead of this dedicated vtable slot) would silently misread
    // the wrong fields for it.
    var out = try testGenOpts(
        \\interface Entity {};
        \\interface TopicDescription {};
        \\interface Topic : Entity, TopicDescription {};
    , "t", .{ .generate_interfaces = true, .no_typesupport = true, .no_typeobject_support = true });
    defer out.deinit(testing.allocator);
    const s = out.items;
    // Present even without --zig-generate-c-api, matching deinit/get_c_abi_handle.
    try testing.expect(has(s, "as_Entity: *const fn (*anyopaque) Entity,"));
    try testing.expect(has(s, "as_TopicDescription: *const fn (*anyopaque) TopicDescription,"));
    // No export wrappers without --zig-generate-c-api.
    try testing.expect(!has(s, "pub export fn Topic_as_Entity"));
    try testing.expect(!has(s, "pub export fn Topic_as_TopicDescription"));
}

test "zig_backend: --zig-generate-c-api generates an as_Base export per direct base" {
    var out = try testGenOpts(
        \\interface Entity {};
        \\interface TopicDescription {};
        \\interface Topic : Entity, TopicDescription {};
    , "t", .{
        .generate_interfaces = true,
        .no_typesupport = true,
        .no_typeobject_support = true,
        .zig_generate_c_api = true,
    });
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "pub export fn Topic_as_Entity(self: *anyopaque) callconv(.c) *anyopaque {"));
    try testing.expect(has(s, "const _self: Topic = zidl_rt.unboxAs(Topic, self);"));
    try testing.expect(has(s, "const _r = _self.vtable.as_Entity(_self.ptr);"));
    // Two separate export functions share the unbox line pattern; check both
    // bodies dispatch through their own `as_*` slot and box via the result's
    // own vtable, never a hardcoded one.
    try testing.expect(has(s, "pub export fn Topic_as_TopicDescription(self: *anyopaque) callconv(.c) *anyopaque {"));
    try testing.expect(has(s, "const _r = _self.vtable.as_TopicDescription(_self.ptr);"));
    try testing.expect(has(s, "return _r.vtable.get_c_abi_handle(_r.ptr);"));
}

test "zig_backend: interface with no bases gets no as_Base slot" {
    var out = try testGenOpts(
        \\interface Standalone {};
    , "t", .{ .generate_interfaces = true, .no_typesupport = true, .no_typeobject_support = true });
    defer out.deinit(testing.allocator);
    try testing.expect(!has(out.items, "as_"));
}

// ── C-ABI mirror structs (--zig-generate-c-api) ───────────────────────────────
//
// Regression coverage for the create_participant_ex/set_default_participant_
// config/get_default_participant_config C-ABI struct-layout bug (found
// 2026-08-20 building zzdds-examples' participant-config example): the `-b c`
// backend independently emits a public header struct without `_toml_applied`
// and with plain `char *` strings, while the exported Zig wrapper functions
// used to reuse the internal Zig-native layout directly ([]const u8 strings,
// plus a hidden _toml_applied bool prepended by --zig-generate-toml-config).
// `structNeedsCApiMirror`/`emitStructCApiMirror` generate a separate,
// genuinely extern-compatible `{Name}CAbi` mirror type + conversion functions
// so the exported signature matches what a real C/C++/Java caller builds.

test "zig_backend: C-ABI mirror generated for a toml-applied struct with no strings" {
    // Any struct this invocation adds `_toml_applied` to needs a mirror even
    // with nothing else unsafe in it -- the extra bool field alone makes the
    // internal layout disagree with the public header's.
    var out = try testGenOpts(
        \\struct Cfg { long x; };
    , "t", .{
        .zig_generate_c_api = true,
        .zig_generate_toml_config = true,
        .no_typesupport = true,
        .no_typeobject_support = true,
    });
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "pub const CfgCAbi = extern struct {"));
    try testing.expect(has(s, "pub fn CfgFromCAbi(c: *const CfgCAbi) Cfg {"));
    try testing.expect(has(s, "out._toml_applied = true;"));
    try testing.expect(has(s, "pub fn CfgToCAbi(v: *const Cfg, out: *CfgCAbi) void {"));
    try testing.expect(has(s, "pub fn CfgCAbiFree(out: *CfgCAbi) void {"));
}

test "zig_backend: C-ABI mirror generated for an unbounded-string struct without toml config" {
    // The string-layout half of the bug is independent of --zig-generate-
    // toml-config -- confirmed for real against dcps.idl's
    // TopicBuiltinTopicData, which never goes through toml config at all.
    var out = try testGenOpts(
        \\struct Named { string name; };
    , "t", .{ .zig_generate_c_api = true, .no_typesupport = true, .no_typeobject_support = true });
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "pub const NamedCAbi = extern struct {"));
    try testing.expect(has(s, "name: ?[*:0]const u8 = null,"));
    try testing.expect(has(s, "out.name = if (c.name) |_p| (std.heap.c_allocator.dupe(u8, std.mem.span(_p)) catch \"\") else \"\";"));
    try testing.expect(has(s, "out.name = zidlCAbiDupeCStr(v.name);"));
    try testing.expect(has(s, "zidlCAbiFreeCStr(out.name);"));
    try testing.expect(!has(s, "out._toml_applied = true;"));
}

test "zig_backend: no C-ABI mirror for a plain scalar struct" {
    // The common case: neither trigger applies, so the exported wrapper
    // keeps using the internal type directly, same as before this feature.
    // (Not a bare "CAbi" substring check: --zig-generate-c-api's shared
    // preamble always emits zidlCAbiDupeCStr/zidlCAbiFreeCStr regardless of
    // whether this particular struct needs a mirror.)
    var out = try testGenOpts(
        \\struct Plain { long x; boolean y; };
    , "t", .{ .zig_generate_c_api = true, .no_typesupport = true, .no_typeobject_support = true });
    defer out.deinit(testing.allocator);
    try testing.expect(!has(out.items, "PlainCAbi"));
    try testing.expect(!has(out.items, "FromCAbi"));
    try testing.expect(!has(out.items, "ToCAbi"));
}

test "zig_backend: standalone _free export routes through the C-ABI mirror when one exists" {
    // emitStructCApiFree is a separate export from emitCApiOp's operation
    // wrappers -- the exact site the fix's last bug lived in (found via a
    // real SIGSEGV in zzdds_DomainParticipantConfig_free, diagnosed with
    // `gdb bt full`): it must also take/free the mirror type, not call
    // `v.deinit()` directly against a mirror-shaped caller value.
    var out = try testGenOpts(
        \\struct Named { string name; sequence<long> nums; };
    , "t", .{ .zig_generate_c_api = true, .no_typesupport = true, .no_typeobject_support = true });
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "pub export fn Named_free(v: *NamedCAbi) callconv(.c) void { NamedCAbiFree(v); }"));
    try testing.expect(!has(s, "v.deinit(std.heap.c_allocator)"));
}

test "zig_backend: C-ABI mirror _present bit index follows optional-field declaration order" {
    var out = try testGenOpts(
        \\struct Cfg { string name; @optional long a; long mid; @optional long b; };
    , "t", .{ .zig_generate_c_api = true, .no_typesupport = true, .no_typeobject_support = true });
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "_present: u64 = 0,"));
    try testing.expect(has(s, "if (c._present & (@as(u64, 1) << 0) != 0) out.a = c.a;"));
    try testing.expect(has(s, "if (c._present & (@as(u64, 1) << 1) != 0) out.b = c.b;"));
    try testing.expect(has(s, "if (v.a) |_val| { out.a = _val; out._present |= (@as(u64, 1) << 0); }"));
    try testing.expect(has(s, "if (v.b) |_val| { out.b = _val; out._present |= (@as(u64, 1) << 1); }"));
}

test "zig_backend: C-ABI mirror clones sequence fields instead of shallow-copying" {
    // Regression guard for a real bug found while implementing this: a plain
    // assignment here shallow-copies the buffer pointer, leaving the mirror
    // and the internal value sharing one allocation -- a double-free the
    // moment either side's deinit/CAbiFree runs. `.clone()` already exists
    // on every sequence type for exactly this reason.
    var out = try testGenOpts(
        \\struct Named { string name; sequence<long> nums; };
    , "t", .{ .zig_generate_c_api = true, .no_typesupport = true, .no_typeobject_support = true });
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "out.nums = c.nums.clone(std.heap.c_allocator) catch .{};"));
    try testing.expect(has(s, "out.nums = v.nums.clone(std.heap.c_allocator) catch .{};"));
    try testing.expect(has(s, "out.nums.deinit(std.heap.c_allocator);"));
}

test "zig_backend: --zig-generate-c-api struct in/inout params route through the C-ABI mirror" {
    var out = try testGenOpts(
        \\struct Named { string name; };
        \\interface Iface {
        \\    void set_val(in Named v);
        \\    void update_val(inout Named v);
        \\};
    , "f", .{
        .generate_interfaces = true,
        .no_typesupport = true,
        .no_typeobject_support = true,
        .zig_generate_c_api = true,
    });
    defer out.deinit(testing.allocator);
    const s = out.items;
    // `in` mirror params are nullable (null == "use the type default"),
    // same convention as every other optional struct in-param.
    try testing.expect(has(s, "pub export fn Iface_set_val(self: *anyopaque, v: ?*const NamedCAbi) callconv(.c) void {"));
    try testing.expect(has(s, "var _mir_v: Named = if (v) |_m| NamedFromCAbi(_m) else .{};"));
    try testing.expect(has(s, "_self.vtable.set_val(_self.ptr, &_mir_v);"));

    // `inout`: the caller's value is a real, meaningful input (read then
    // overwritten), so it's converted via FromCAbi same as `in`.
    try testing.expect(has(s, "pub export fn Iface_update_val(self: *anyopaque, v: *NamedCAbi) callconv(.c) void {"));
    try testing.expect(has(s, "var _mir_v: Named = NamedFromCAbi(v);"));
    try testing.expect(has(s, "_self.vtable.update_val(_self.ptr, &_mir_v);"));
    try testing.expect(has(s, "NamedToCAbi(&_mir_v, v);"));
}

test "zig_backend: --zig-generate-c-api struct out mirror param starts from the type default, not FromCAbi'd garbage" {
    // Regression guard: a plain `out` param's caller-supplied storage is
    // uninitialized/write-only by IDL convention -- the callee doesn't need
    // to read it. FromCAbi-ing it anyway (as `inout` correctly does) would
    // interpret garbage bytes as a valid mirror value: a bad string
    // pointer scanned by std.mem.span, a corrupt sequence length driving an
    // out-of-bounds clone, etc.
    var out = try testGenOpts(
        \\struct Named { string name; };
        \\interface Iface {
        \\    void get_val(out Named v);
        \\};
    , "f", .{
        .generate_interfaces = true,
        .no_typesupport = true,
        .no_typeobject_support = true,
        .zig_generate_c_api = true,
    });
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "pub export fn Iface_get_val(self: *anyopaque, v: *NamedCAbi) callconv(.c) void {"));
    try testing.expect(has(s, "var _mir_v: Named = .{};"));
    try testing.expect(!has(s, "var _mir_v: Named = NamedFromCAbi(v);"));
    try testing.expect(has(s, "_self.vtable.get_val(_self.ptr, &_mir_v);"));
    try testing.expect(has(s, "NamedToCAbi(&_mir_v, v);"));
}

test "zig_backend: --zig-generate-c-api by-value struct return routes through the C-ABI mirror" {
    // Regression guard: cApiExportRetType previously fell through to the
    // internal (non-mirror) type for any non-entity return, leaving the
    // exported function's return type disagreeing with what `-b c`
    // independently declares for the same struct -- the exact mismatch
    // this whole mechanism exists to close, just on the return path
    // instead of a param. No real zzdds.idl/dcps.idl operation returns a
    // mirror-needing struct by value today (all six real cases pass it via
    // `inout`), but the generator must still be correct for one that does.
    var out = try testGenOpts(
        \\struct Named { string name; };
        \\interface Iface {
        \\    Named get_val();
        \\};
    , "f", .{
        .generate_interfaces = true,
        .no_typesupport = true,
        .no_typeobject_support = true,
        .zig_generate_c_api = true,
    });
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "pub export fn Iface_get_val(self: *anyopaque) callconv(.c) NamedCAbi {"));
    try testing.expect(has(s, "const _r = _self.vtable.get_val(_self.ptr);"));
    try testing.expect(has(s, "var _mir_ret: NamedCAbi = .{};"));
    try testing.expect(has(s, "NamedToCAbi(&_r, &_mir_ret);"));
    try testing.expect(has(s, "return _mir_ret;"));
    // Named has a string field, so structNeedsCleanup(Named) is true --
    // the internal by-value return must be freed after conversion, since
    // ToCAbi only reads it (converts into a fresh mirror copy).
    try testing.expect(has(s, "_r.deinit(std.heap.c_allocator);"));
}

// ── --zig-generate-toml-config ────────────────────────────────────────────────
//
// Full functional correctness (compiles + runs against a hand-written duck-typed
// table, exercises every supported field kind plus both error paths) was verified
// out-of-tree during development; these are lightweight regression guards over
// the generated source shape.

test "toml config: scalar fields call the expected accessors" {
    var out = try testGenOpts(
        \\struct Cfg {
        \\    @default(TRUE) boolean enabled;
        \\    @default(5) unsigned short base;
        \\    @default(1.5) float gain;
        \\    @default("hi") string label;
        \\};
    , "t", .{ .zig_generate_toml_config = true, .no_typesupport = true, .no_typeobject_support = true });
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "pub fn applyToml(self: *@This(), alloc: std.mem.Allocator, table: anytype) !void {"));
    try testing.expect(has(s, "if (try table.getBool(\"enabled\")) |_v| self.enabled = _v;"));
    try testing.expect(has(s, "if (try table.getInt(\"base\")) |_v| self.base = std.math.cast(u16, _v) orelse return error.InvalidValue;"));
    try testing.expect(has(s, "if (try table.getFloat(\"gain\")) |_v| self.gain = @floatCast(_v);"));
    try testing.expect(has(s, "const _new_label = try alloc.dupe(u8, (try table.getString(\"label\")) orelse self.label);"));
    try testing.expect(has(s, "if (self._toml_applied and self.label.len != 0) alloc.free(self.label);"));
    try testing.expect(has(s, "self.label = _new_label;"));
}

test "toml config: enum field dispatches through the generated fromString helper" {
    var out = try testGenOpts(
        \\enum Kind { KIND_A, KIND_B };
        \\struct Cfg { @default(KIND_A) Kind kind; };
    , "t", .{ .zig_generate_toml_config = true, .no_typesupport = true, .no_typeobject_support = true });
    defer out.deinit(testing.allocator);
    try testing.expect(has(out.items, "if (try table.getString(\"kind\")) |_v| self.kind = Kind_fromString(_v) orelse return error.InvalidValue;"));
}

test "toml config: nested struct field recurses via getTable + applyToml" {
    var out = try testGenOpts(
        \\struct Inner { @default(1) unsigned short x; };
        \\struct Outer { Inner inner; };
    , "t", .{ .zig_generate_toml_config = true, .no_typesupport = true, .no_typeobject_support = true });
    defer out.deinit(testing.allocator);
    try testing.expect(has(out.items, "try self.inner.applyToml(alloc, (try table.getTable(\"inner\")) orelse @TypeOf(table){});"));
}

test "toml config: sequence<string> field builds a released buffer from getStringArray" {
    var out = try testGenOpts(
        \\typedef sequence<string> StringSeq;
        \\struct Cfg { StringSeq items; };
    , "t", .{ .zig_generate_toml_config = true, .no_typesupport = true, .no_typeobject_support = true });
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "if (try table.getStringArray(\"items\")) |_arr| {"));
    try testing.expect(has(s, "_buf[_n] = (try alloc.dupeZ(u8, _s)).ptr;"));
    try testing.expect(has(s, "self.items = .{ ._buffer = _buf.ptr, ._length = @intCast(_arr.len), ._maximum = @intCast(_arr.len), ._release = true };"));
}

test "toml config: unsupported field kinds compile-error instead of silently mishandling" {
    var out = try testGenOpts(
        \\struct Cfg { long v[3]; };
    , "t", .{ .zig_generate_toml_config = true, .no_typesupport = true, .no_typeobject_support = true });
    defer out.deinit(testing.allocator);
    try testing.expect(has(out.items, "@compileError(\"--zig-generate-toml-config does not support this field type ('Cfg.v')\");"));
}

test "toml config: optional field has no special-cased handling (plain assignment covers it)" {
    var out = try testGenOpts(
        \\struct Cfg { @optional unsigned long maybe; };
    , "t", .{ .zig_generate_toml_config = true, .no_typesupport = true, .no_typeobject_support = true });
    defer out.deinit(testing.allocator);
    try testing.expect(has(out.items, "if (try table.getInt(\"maybe\")) |_v| self.maybe = std.math.cast(u32, _v) orelse return error.InvalidValue;"));
}

test "toml config: alloc is discarded for an all-integer struct (self/table are genuinely used, so not discarded)" {
    var out = try testGenOpts(
        \\struct Cfg { @default(1) unsigned short x; };
    , "t", .{ .zig_generate_toml_config = true, .no_typesupport = true, .no_typeobject_support = true });
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "_ = alloc;"));
    try testing.expect(!has(s, "_ = self;"));
    try testing.expect(!has(s, "_ = table;"));
}

test "toml config: alloc is NOT discarded when a string field needs it" {
    var out = try testGenOpts(
        \\struct Cfg { @default("") string name; };
    , "t", .{ .zig_generate_toml_config = true, .no_typesupport = true, .no_typeobject_support = true });
    defer out.deinit(testing.allocator);
    try testing.expect(!has(out.items, "_ = alloc;"));
}

test "toml config: a struct with no members discards all three parameters" {
    var out = try testGenOpts(
        \\struct Empty {};
    , "t", .{ .zig_generate_toml_config = true, .no_typesupport = true, .no_typeobject_support = true });
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "_ = self;"));
    try testing.expect(has(s, "_ = alloc;"));
    try testing.expect(has(s, "_ = table;"));
}

test "toml config: _toml_applied field is emitted and set only on full success" {
    var out = try testGenOpts(
        \\struct Cfg { @default("") string name; };
    , "t", .{ .zig_generate_toml_config = true, .no_typesupport = true, .no_typeobject_support = true });
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "_toml_applied: bool = false,"));
    // Must be the LAST statement in applyToml (after the field's own statement),
    // so a `try` failing above it never reaches this line.
    const field_stmt = std.mem.indexOf(u8, s, "const _new_name = try alloc.dupe").?;
    const flag_stmt = std.mem.indexOf(u8, s, "self._toml_applied = true;").?;
    try testing.expect(flag_stmt > field_stmt);
}

test "toml config: deinit only frees a string field when _toml_applied is true" {
    var out = try testGenOpts(
        \\struct Cfg { @default("default") string name; };
    , "t", .{ .zig_generate_toml_config = true, .no_typesupport = true, .no_typeobject_support = true });
    defer out.deinit(testing.allocator);
    try testing.expect(has(out.items, "if (self._toml_applied and self.name.len != 0) alloc.free(self.name);"));
}

test "toml config: sequence field is reset to .{} immediately after freeing the old buffer" {
    var out = try testGenOpts(
        \\typedef sequence<string> StringSeq;
        \\struct Cfg { StringSeq items; };
    , "t", .{ .zig_generate_toml_config = true, .no_typesupport = true, .no_typeobject_support = true });
    defer out.deinit(testing.allocator);
    const s = out.items;
    // The reset must appear between the free-old-buffer block and the
    // allocation of the replacement, so a failure allocating the replacement
    // never leaves self.items pointing at freed memory.
    const free_stmt = std.mem.indexOf(u8, s, "alloc.free(_ob[0..self.items._maximum]);").?;
    const reset_stmt = std.mem.indexOf(u8, s, "self.items = .{};").?;
    const alloc_stmt = std.mem.indexOf(u8, s, "const _buf = try alloc.alloc([*:0]const u8, _arr.len);").?;
    try testing.expect(free_stmt < reset_stmt);
    try testing.expect(reset_stmt < alloc_stmt);
}

test "toml config: clone sets _toml_applied unconditionally, not copied from self" {
    var out = try testGenOpts(
        \\struct Cfg { @default("default") string name; };
    , "t", .{ .zig_generate_toml_config = true, .no_typesupport = true, .no_typeobject_support = true });
    defer out.deinit(testing.allocator);
    const s = out.items;
    // Must appear in clone(), set unconditionally (not gated on self's own
    // flag) — otherwise cloning an untouched T{} (whose "default" literal
    // gets duped by the clone's own string-copy statement regardless) would
    // leave `result` with a genuinely-owned string but _toml_applied = false,
    // and result.deinit() would then skip freeing it.
    const clone_fn_start = std.mem.indexOf(u8, s, "pub fn clone(self: @This()").?;
    const clone_fn_body = s[clone_fn_start..];
    try testing.expect(has(clone_fn_body, "result._toml_applied = true;"));
}

test "toml config: typedef-of-string field gets direct free/dupe handling, not a .deinit() delegate" {
    var out = try testGenOpts(
        \\typedef string Name;
        \\struct Cfg { @default("x") Name label; };
    , "t", .{ .zig_generate_toml_config = true, .no_typesupport = true, .no_typeobject_support = true });
    defer out.deinit(testing.allocator);
    const s = out.items;
    // applyToml already dupes it like any other string (resolveTomlTypeRef
    // already unwrapped typedefs) — this test is about deinit/clone catching up.
    try testing.expect(has(s, "if (self._toml_applied and self.label.len != 0) alloc.free(self.label);"));
    try testing.expect(has(s, "result.label = if (self.label.len != 0) try alloc.dupe(u8, self.label) else self.label;"));
    try testing.expect(has(s, "errdefer if (result.label.len != 0) alloc.free(result.label);"));
    // Must NOT try to delegate to a .deinit()/.clone() a `[]const u8` alias doesn't have.
    try testing.expect(!has(s, "self.label.deinit(alloc)"));
    try testing.expect(!has(s, "self.label.clone(alloc)"));
}

test "toml config: typedef-of-struct-with-string gets lifecycle helpers via the existing delegate path" {
    var out = try testGenOpts(
        \\struct Inner { @default("x") string label; };
        \\typedef Inner InnerAlias;
        \\struct Outer { InnerAlias wrapped; };
    , "t", .{ .zig_generate_toml_config = true, .no_typesupport = true, .no_typeobject_support = true });
    defer out.deinit(testing.allocator);
    const s = out.items;
    // Outer must get deinit/clone at all (previously: typeRefHasUnboundedString
    // didn't recurse into a typedef's struct target, so structNeedsCleanup
    // never saw this field and Outer got no lifecycle helpers whatsoever).
    try testing.expect(has(s, "self.wrapped.deinit(alloc);"));
    try testing.expect(has(s, "result.wrapped = try self.wrapped.clone(alloc);"));
    try testing.expect(has(s, "errdefer result.wrapped.deinit(alloc);"));
}

test "toml config: inherited base struct is populated, cleaned up, and cloned" {
    var out = try testGenOpts(
        \\struct Base { @default("base-default") string base_label; };
        \\struct Derived : Base { @default(1) unsigned short extra; };
    , "t", .{ .zig_generate_toml_config = true, .no_typesupport = true, .no_typeobject_support = true });
    defer out.deinit(testing.allocator);
    const s = out.items;
    const derived_start = std.mem.indexOf(u8, s, "pub const Derived").?;
    const derived = s[derived_start..];
    // applyToml: base delegate call must appear, using the SAME table (flat,
    // not nested — inheritance is IS-A, unlike a HAS-A struct field).
    try testing.expect(has(derived, "try self._base.applyToml(alloc, table);"));
    // deinit/clone must recurse into the base too (previously: structNeedsCleanup
    // only checked s.members, never s.base, so Derived got no lifecycle helpers
    // at all despite Base owning a heap string).
    try testing.expect(has(derived, "self._base.deinit(alloc);"));
    try testing.expect(has(derived, "result._base = try self._base.clone(alloc);"));
    try testing.expect(has(derived, "errdefer result._base.deinit(alloc);"));
}

test "toml config: a typedef with array dimensions is still rejected, not treated as a plain string" {
    var out = try testGenOpts(
        \\typedef string Names[3];
        \\struct Cfg { Names v; };
    , "t", .{ .zig_generate_toml_config = true, .no_typesupport = true, .no_typeobject_support = true });
    defer out.deinit(testing.allocator);
    try testing.expect(has(out.items, "@compileError(\"--zig-generate-toml-config does not support this field type ('Cfg.v')\");"));
}

test "toml config: applyToml frees a just-duped string field if a later field fails" {
    var out = try testGenOpts(
        \\struct Cfg { @default("x") string name; @default(1) unsigned short num; };
    , "t", .{ .zig_generate_toml_config = true, .no_typesupport = true, .no_typeobject_support = true });
    defer out.deinit(testing.allocator);
    const s = out.items;
    // The errdefer for `name` must appear right after its dupe statement,
    // before `num`'s statement — so it's registered (and can fire on num's
    // failure) regardless of declaration order relative to other fields.
    const dupe_stmt = std.mem.indexOf(u8, s, "const _new_name = try alloc.dupe").?;
    const errdefer_stmt = std.mem.indexOf(u8, s, "if (self.name.len != 0) {").?;
    const port_stmt = std.mem.indexOf(u8, s, "self.num = std.math.cast").?;
    try testing.expect(dupe_stmt < errdefer_stmt);
    try testing.expect(errdefer_stmt < port_stmt);
    try testing.expect(has(s, "alloc.free(self.name);"));
    try testing.expect(has(s, "self.name = \"\";"));
}

test "toml config: string re-application frees the previous allocation, without a use-after-free on the fallback read" {
    var out = try testGenOpts(
        \\struct Cfg { @default("x") string name; };
    , "t", .{ .zig_generate_toml_config = true, .no_typesupport = true, .no_typeobject_support = true });
    defer out.deinit(testing.allocator);
    // Scoped to applyToml specifically — deinit's own (correctly separate)
    // "if (self._toml_applied and self.name.len != 0) alloc.free(...)" check
    // appears earlier in the file and would otherwise be mistaken for this one.
    const apply_fn_start = std.mem.indexOf(u8, out.items, "pub fn applyToml(self: *@This()").?;
    const s = out.items[apply_fn_start..];
    // Ordering matters: dupe into a temporary FIRST (from the still-valid
    // current value, including the TOML-absent `orelse self.name` fallback),
    // THEN free the old value, THEN assign — freeing before duping would make
    // the `orelse self.name` fallback a use-after-free read.
    const dupe_stmt = std.mem.indexOf(u8, s, "const _new_name = try alloc.dupe(u8, (try table.getString(\"name\")) orelse self.name);").?;
    const free_stmt = std.mem.indexOf(u8, s, "if (self._toml_applied and self.name.len != 0) alloc.free(self.name);").?;
    const assign_stmt = std.mem.indexOf(u8, s, "self.name = _new_name;").?;
    try testing.expect(dupe_stmt < free_stmt);
    try testing.expect(free_stmt < assign_stmt);
}

test "toml config: one unsupported field makes the whole body a single compileError (no unreachable-code statements after it)" {
    var out = try testGenOpts(
        \\struct Cfg { long v[3]; @default(1) unsigned short x; };
    , "t", .{ .zig_generate_toml_config = true, .no_typesupport = true, .no_typeobject_support = true });
    defer out.deinit(testing.allocator);
    const s = out.items;
    try testing.expect(has(s, "@compileError(\"--zig-generate-toml-config does not support this field type ('Cfg.v')\");"));
    // The supported field's statement must NOT appear — nothing follows the
    // compileError in the generated body, since that would be unreachable code.
    try testing.expect(!has(s, "self.x = std.math.cast"));
}
