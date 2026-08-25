//! Backend interface — vtable abstraction for language-specific code generators.
//!
//! ## Adding a new backend
//!
//!   1. Create `src/backend/<lang>.zig` with a `CBackend`-style struct and a
//!      `vtable: Backend.Vtable` constant.
//!   2. Export `pub const vtable = ...` from that file.
//!   3. Register it in `root.zig`'s `findByLanguageId`.
//!
//! ## Vtable lifecycle
//!
//!   ```zig
//!   const be = try CBackend.create(alloc);
//!   defer be.deinit();
//!   try be.generate(&ir_spec, opts);
//!   ```

const std = @import("std");
const ir = @import("../ir/root.zig");

// ── Profile ───────────────────────────────────────────────────────────────────

/// Code-generation profile controlling which IDL features and runtime
/// capabilities are assumed to be available.
pub const Profile = enum {
    /// Full DDS profile: all extensibility kinds, unbounded sequences,
    /// TypeObject/TypeIdentifier, heap allocation.  Default.
    full,
    /// XRCE profile for bare-metal microcontrollers (DDS-XRCE v1.0):
    /// XCDR1 encoding only, @final types only, bounded sequences only,
    /// no TypeObject, no heap allocation in generated code.
    xrce,
};

pub const ZigVersion = enum {
    @"0.15.1",
    @"0.16.0",

    pub fn parse(s: []const u8) ?ZigVersion {
        if (std.mem.eql(u8, s, "0.15.1")) return .@"0.15.1";
        if (std.mem.eql(u8, s, "0.16.0")) return .@"0.16.0";
        return null;
    }

    pub fn label(self: ZigVersion) []const u8 {
        return switch (self) {
            .@"0.15.1" => "0.15.1",
            .@"0.16.0" => "0.16.0",
        };
    }
};

// ── Options ───────────────────────────────────────────────────────────────────

/// Options passed to every backend's `generate` call.
pub const Options = struct {
    /// Output directory path.  Backend creates files here.
    /// Empty string means current working directory.
    output_dir: []const u8 = "",
    /// Basename stem of the input file (e.g. `"foo"` from `"foo.idl"`).
    /// Used to derive output filenames such as `"foo.h"` or `"Foo.java"`.
    input_stem: []const u8,
    /// Suppress generated CDR serialize/deserialize functions.
    no_typesupport: bool = false,
    /// Suppress XTYPES TypeObject / TypeIdentifier output.
    /// All backends; currently only the Zig backend emits TypeObjects.
    no_typeobject_support: bool = false,
    /// Default extensibility when no `@extensibility` annotation is present.
    default_extensibility: ir.Extensibility = .final,
    /// C, C++ backends: prefix for include-guard macros (e.g. `"DDSC_"` → `"DDSC_FOO_H"`).
    header_guard_prefix: []const u8 = "",
    /// Prefix prepended to every generated user-defined type name.
    /// For example `"DDS_"` turns `MyStruct` into `DDS_MyStruct` and the
    /// CDR functions into `DDS_MyStruct_serialize`, etc.
    /// Empty string (default) preserves existing behaviour.
    type_prefix: []const u8 = "",
    /// C, C++ backends: DLL export macro prepended to CDR function declarations
    /// (e.g. `"MYLIB_EXPORT"` → `"MYLIB_EXPORT int Foo_serialize(…);"`).
    export_macro: []const u8 = "",
    /// Java: top-level package prefix (e.g. `"com.example"`).
    java_package: []const u8 = "",
    /// Emit Zig fat-pointer vtable structs for IDL `interface` declarations.
    /// Without this flag, interfaces are emitted as comment placeholders.
    generate_interfaces: bool = false,
    /// Java: name passed to `System.loadLibrary()` in generated `*Impl` classes.
    /// Only used when `generate_interfaces` is true.
    jni_library: []const u8 = "zidl_dds_jni",
    /// Target profile.  Backends may use this to adjust output; the CLI
    /// calls `validateXrce` before invoking backends when profile is `.xrce`.
    profile: Profile = .full,
    /// Split output into one file per named type (C/C++) or one file per
    /// top-level IDL module (Zig), or one file per top-level named type (Java).
    /// When false (default), a single monolithic output file is generated.
    split_files: bool = false,
    /// C, C++ backends: use `#pragma once` instead of `#ifndef`/`#define`/`#endif` include guards.
    pragma_once: bool = false,
    /// C backend only: wrap header content in `#ifdef __cplusplus` / `extern "C"` brackets.
    /// Lets the generated `.h` be safely included from C++ translation units without
    /// manual wrapping.
    extern_c: bool = false,
    /// C++ only: outer namespace to wrap all generated declarations in.
    /// For example `"dds"` produces `namespace dds { … }` around every type.
    /// Empty string (default) adds no extra namespace layer.
    cpp_namespace: []const u8 = "",
    /// Generate additional `serializePlCdr` / `deserializeFromPlCdr` methods
    /// for `@mutable` types (Zig backend only; C/C++ backends do not yet emit
    /// PL_CDR functions).  Enables RTPS ParameterList wire format for DDS
    /// discovery types.  Requires `no_typesupport == false`.
    pl_cdr: bool = false,
    /// Emit typed zzdds topic wrappers for keyed, non-mutable topic structs.
    /// Zig uses a consuming-build `dds` adapter; C/C++ call zzdds C ABI helpers.
    generate_zzdds_wrappers: bool = false,
    /// Java backend only: which Java package an imported module's own
    /// generated output lives in, when it differs from this invocation's own
    /// `java_package` — e.g. `"DDS=".len == 0` (empty package) tells this
    /// invocation that `import "dcps.idl";`'s `DDS` module was itself
    /// compiled with no `--java-package`, even though *this* file is using
    /// one. Each entry is a raw `"<ModuleName>=<package>"` string (parsed by
    /// the Java backend); an empty string after `=` means the default
    /// (unnamed) package. A module not listed here is assumed to share this
    /// invocation's own `java_package` — the common case when both files are
    /// compiled the same way, so this flag is only needed when they aren't.
    /// zidl has no other way to learn this: an import only carries the
    /// declaring file's *stem* (see `ir.Spec.import_stems`, derived
    /// automatically), never the separate, independent compile invocation's
    /// own package, which isn't recorded anywhere the importing invocation
    /// can see.
    java_import_packages: []const []const u8 = &.{},
    /// Zig backend only: generated source compatibility target. zidl itself may
    /// run on a newer Zig toolchain while emitting code for MicroZig-era Zig.
    zig_version: ZigVersion = .@"0.16.0",
    /// Zig backend only: alongside the vtable struct output, emit
    /// `pub export fn callconv(.c)` wrappers implementing the free C functions
    /// declared by the C backend's `--generate-interfaces` output.
    ///
    /// DDS object interfaces → one wrapper per operation/attribute.
    /// Listener interfaces → noop vtable constants usable as a null listener.
    ///
    /// String parameters use `[*:0]const u8` / `std.mem.span()` conversion.
    /// Named struct `in` parameters are accepted as `*const T` (pointer hides
    /// potential non-extern struct internals) and dereferenced for the vtable call.
    zig_generate_c_api: bool = false,
    /// Zig backend only, requires `zig_generate_c_api`: route generated
    /// `_free()`/mirror-conversion allocations through `zidl_cdr_get_allocator()`
    /// (the process-wide allocator `zidl_cdr_set_allocator()` registers)
    /// instead of hardcoding `std.heap.c_allocator`. Opt-in, default off,
    /// same reasoning as `cpp_pmr_containers` below: it's a real new
    /// dependency (linking `libzidl_cdr`) for a plain-`zig_generate_c_api`
    /// consumer that wasn't there before, so it must not be forced on
    /// anyone who doesn't ask for it. A consumer that already links
    /// `libzidl_cdr` for its own reasons (e.g. zzdds, which needs it for
    /// C/C++ CDR decode regardless) should pass this alongside
    /// `zig_generate_c_api` to get allocator-correct generated frees; one
    /// that doesn't link it gets the previous (unfixed but
    /// dependency-free) behavior unless it opts in.
    zig_generate_c_api_cdr_allocator: bool = false,
    /// Zig backend only: emit enum tags as lowercase snake_case (e.g.
    /// `durability_volatile`) instead of the raw IDL name (`DURABILITY_VOLATILE`).
    /// Zig keywords that collide after lowercasing gain a trailing `_` (e.g.
    /// `volatile` → `volatile_`).  `fromString`/`toString` helpers continue to
    /// use the original IDL name as the canonical string representation so that
    /// config files and wire diagnostics remain language-agnostic.
    zig_idiomatic_enums: bool = false,
    /// Zig backend only: emit `pub fn applyToml(self: *@This(), alloc: std.mem.Allocator,
    /// table: anytype) !void` for every struct, overriding fields present in `table` and
    /// re-duping absent ones from their current value (see the ownership note below).
    /// `table` is duck-typed via `anytype` — zidl has no compile-time dependency on any
    /// concrete TOML parser or value-tree type; the caller supplies any type `T` exposing:
    ///   getString/getBool/getInt/getFloat/getStringArray(key: []const u8) -> SomeError!?U
    ///   getTable(key: []const u8) -> SomeError!?T                    (same T, for recursion)
    ///   T{}                                                          (a valid empty/default T)
    /// (absent key = null, key present with the wrong type = an error — never silently
    /// treated as absent). `T{}` must be a valid, cheap, always-succeeding construction —
    /// generated code builds one whenever a nested struct's table key is itself absent, so
    /// that struct still gets its own applyToml pass against a genuinely empty table (see
    /// the ownership note below for why this matters even when there's nothing to apply).
    ///
    /// Supports: booleans, integers (bounds-checked via std.math.cast), floats, strings,
    /// enums (via the enum's existing generated `_fromString` helper), nested structs
    /// (recursively — always invoked, never conditional on the key's presence), and
    /// `sequence<string>` fields. Fixed-size arrays, unions, bitmasks, bounded strings, and
    /// sequences of anything other than `string` are not supported — the whole generated
    /// function body becomes a single `@compileError` naming the field, rather than
    /// generating a partially-correct function (an unsupported field standing alongside a
    /// supported one's ordinary statement would otherwise be "unreachable code after
    /// @compileError," a separate hard error).
    ///
    /// `struct Derived : Base` inheritance (the embedded `_base` field) is transparent to all
    /// of this: `applyToml` always delegates to `self._base.applyToml(alloc, table)` first,
    /// passing the *same* table (inheritance is IS-A — Base's fields are peers of Derived's own
    /// in one flat table, not nested under a `[base]`-style key the way a genuine HAS-A
    /// struct-typed field would be). `deinit`/`clone`/the "does this struct need lifecycle
    /// helpers at all" check all recurse into the base the same way they recurse into a nested
    /// struct field, so a `Derived` whose only heap-owning content lives in `Base` still gets
    /// correct `deinit`/`clone` generated for itself.
    ///
    /// **String field ownership.** Every plain (unbounded) string field is unconditionally
    /// duped via `alloc.dupe` on every `applyToml` call — whether or not the TOML key was
    /// present, using the field's *current* value as the fallback when absent — so that after
    /// `applyToml` returns successfully, every string field is uniformly heap-owned, never a
    /// mix of "literal default" and "allocated." Since a plain `[]const u8` has no ownership
    /// bit of its own (unlike a sequence's `._release`), each struct generated under this flag
    /// also gets a real `_toml_applied: bool = false` field, so `deinit`/`clone` don't have to
    /// *infer* whether that invariant holds — they can check it directly:
    ///   - `applyToml` sets `self._toml_applied = true` as its own literal last statement —
    ///     reached only if every field's statement above it succeeded (a `try` failing
    ///     anywhere returns early and never reaches it).
    ///   - `deinit` only frees a non-empty string field `if (self._toml_applied and ...)`. A
    ///     bare, untouched `T{}` (flag defaults `false`) correctly skips cleanup — its fields
    ///     are still whatever `@default` literal they started with, and freeing one would be
    ///     undefined behavior.
    ///   - Each string field's dupe statement in `applyToml` is immediately followed by its own
    ///     `errdefer` (freeing and resetting that one field to `""`) — so if a *later* field's
    ///     statement fails, every string `applyToml` already duped in this same call is cleaned
    ///     up rather than leaked, and `self`'s remaining fields are left in a safe state
    ///     (`_toml_applied` stays `false`, so `deinit` afterward is a correct no-op, not a
    ///     double-free of what the errdefers already handled). This generalizes cleanly: Zig
    ///     fires *every* errdefer registered so far (not just the most recently registered one)
    ///     when a function returns an error, so calling `deinit` on a struct whose `applyToml`
    ///     call just failed is fully safe — any field duped before the failure point already
    ///     unwound itself, and fields never reached are untouched literals that `_toml_applied
    ///     == false` correctly tells `deinit` to leave alone.
    ///   - A string field's dupe is itself free-before-replace: the new value is duped into a
    ///     temporary *first* (from the still-valid current value, since the TOML-key-absent
    ///     fallback `orelse self.field` reads it), and only once that dupe succeeds is the old
    ///     buffer freed — guarded by `_toml_applied` so an untouched literal default is never
    ///     freed. This makes calling `applyToml` a second time on an already-populated struct
    ///     safe: the previous allocation is freed, not leaked, matching how sequence fields
    ///     already free-before-replace keyed off their own `._release`.
    ///   - `clone` sets `result._toml_applied = true` unconditionally — deliberately NOT
    ///     inherited from `self` via the `var result = self;` shallow copy. Clone's own
    ///     string-copy statements dupe every non-empty field regardless of `self`'s flag (a
    ///     dupe is safe no matter where the source came from), so `result` is always
    ///     genuinely, fully owned by the time `clone` returns — even when cloning an untouched
    ///     `T{}` with a non-empty literal default. If `result._toml_applied` were left as
    ///     whatever `self` had, cloning an untouched `T{}` would silently produce a struct that
    ///     owns real heap memory yet is flagged as if it didn't — `result.deinit()` would then
    ///     leak that clone's allocation.
    ///   - A `typedef` that ultimately resolves (through any chain, as long as no typedef in it
    ///     has array dimensions) to a plain unbounded string is treated exactly like a direct
    ///     string field for `deinit`/`clone` purposes, not delegated to a `.deinit()`/`.clone()`
    ///     a bare `[]const u8` alias doesn't have. A typedef resolving to a `struct` or
    ///     `sequence` still delegates as before (those *do* have generated lifecycle methods).
    ///     Both cases matter one level up too: whether the *enclosing* struct gets `deinit`/
    ///     `clone` generated at all is decided by whether any field needs cleanup, and that
    ///     check recurses through the same typedef chain either way — a `typedef SomeStruct
    ///     Foo;` field where `SomeStruct` owns a string still correctly triggers lifecycle
    ///     generation for the struct containing it, exactly as a direct `SomeStruct` field would.
    zig_generate_toml_config: bool = false,
    /// C++ backend: generate concrete Impl classes and listener bridges.
    /// Outputs ${stem}_impl.hpp and ${stem}_impl.cpp alongside the abstract interface header.
    cpp_generate_impl: bool = false,
    /// C++ backend: emit std::pmr::vector<T>/std::pmr::string/std::pmr::wstring for
    /// sequence<T>/string/wstring fields (bounded or unbounded) instead of
    /// std::vector<T>/std::string/std::wstring, so struct-field allocation routes
    /// through zidl::setCppAllocator's process-wide std::pmr default resource
    /// (zidl_allocator_pmr.hpp) the same way _getOrCreate's entity-wrapper
    /// allocation already does. Off by default: this changes the concrete C++
    /// type of every sequence/string/wstring field, a source/ABI break for any
    /// consumer code that names std::vector<T>/std::string directly.
    cpp_pmr_containers: bool = false,
    /// C++ backend, `--cpp-generate-impl` only: override which concrete class
    /// `entityImplName()` returns for a given interface, at every site that
    /// would otherwise name it -- `_getOrCreate` construction/return sites
    /// *and* the `dynamic_cast<...>(...)` parameter-adaptation lambdas (both
    /// route through the same function, so one override covers both
    /// automatically). Each entry is a raw `"<InterfaceQualifiedName>=<Class>"`
    /// string, e.g. `"DDS::DataWriter=::zzdds::DataWriterImpl"` — the
    /// interface name must match `ir.Interface.qualified_name` exactly (the
    /// same `Mod::Name` form used everywhere else, e.g. entity type names in
    /// generated code); the class must already be a complete, constructible
    /// type implementing the interface (this flag does not generate or
    /// validate it — see `cpp_impl_includes` for making it visible).
    ///
    /// Exists because `--cpp-generate-impl` runs once per IDL file, with no
    /// visibility into any other file's generation: a vendor extension IDL
    /// (e.g. zzdds's `zzdds.idl`) that declares `interface DataWriter :
    /// DDS::DataWriter { ... }` gets its own, *separately generated*
    /// `zzdds::DataWriterImpl`, but the base `dcps.idl`'s own generation has
    /// no way to know that class exists — it always constructs/casts against
    /// its own mechanically-named `DDS::DataWriterImpl`. This flag is a
    /// blind, unvalidated redirect for exactly that case: it does not parse
    /// or even look at whatever IDL file the override class comes from.
    cpp_impl_overrides: []const []const u8 = &.{},
    /// C++ backend, `--cpp-generate-impl` only: extra `#include "..."` lines
    /// emitted at the top of the generated `_impl.cpp`, so a class named in
    /// `cpp_impl_overrides` is actually visible. Repeatable; each entry is a
    /// bare header name/path passed through verbatim into `#include "..."`.
    cpp_impl_includes: []const []const u8 = &.{},
    /// C backend only: suppress emitting `{Type}_free()` (both prototype and
    /// body) for structs that need it. For a standalone C consumer compiling
    /// this generation's output into its own binary, `_free` is exactly what
    /// they want — the default. It becomes a problem only when the *same*
    /// struct's C-ABI free function is already exported from elsewhere the
    /// consumer also links against (e.g. zzdds compiling its own
    /// `dcps.idl`-generated `dcps_cdr.c` directly into `libzzdds.so`, which
    /// already exports `{Type}_free` for these exact structs via the
    /// Zig-native `--zig-generate-c-api` path — compiling both in is a
    /// duplicate-symbol link error, confirmed directly, not theorized: 25 of
    /// them across `dcps.idl`+`zzdds.idl`'s QoS/status/config structs).
    /// Serialize/deserialize/skip/default/key functions are unaffected —
    /// only `--zig-generate-c-api` exports `_free`, nothing else exports the
    /// others, so there's nothing to collide with there.
    c_no_free: bool = false,
};

/// Map an imported IDL module name to the generated C/C++ include stem.
/// Most modules use their lowercase name. DDS -> dcps is the only known
/// historical filename mismatch; add an Options-provided override map here if
/// another vendor module needs a non-default stem.
pub fn includeStemForImport(alloc: std.mem.Allocator, import_name: []const u8) ![]u8 {
    if (std.mem.eql(u8, import_name, "DDS")) return alloc.dupe(u8, "dcps");
    return std.ascii.allocLowerString(alloc, import_name);
}

// ── XRCE profile validation ───────────────────────────────────────────────────

/// Validate that `spec` conforms to the XRCE profile constraints:
///   - All structs and unions must be `@final` (no @appendable or @mutable).
///   - All sequence members must be bounded (`sequence<T, N>`).
///   - No `map<K,V>` members (no standard XCDR1 encoding for maps).
///
/// Returns `error.XrceProfileViolation` on the first violation found.
/// Diagnostic messages are written to `diag` when non-null.
pub fn validateXrce(spec: *const ir.Spec, diag: ?*std.Io.Writer) !void {
    for (spec.items) |item| {
        try validateXrceItem(item, diag);
    }
}

fn validateXrceItem(item: ir.ModuleItem, diag: ?*std.Io.Writer) !void {
    switch (item) {
        .module => |m| for (m.items) |sub| try validateXrceItem(sub, diag),
        .type_decl => |td| try validateXrceTypeDecl(td, diag),
        .const_ => {},
    }
}

fn validateXrceTypeDecl(td: ir.TypeDecl, diag: ?*std.Io.Writer) !void {
    switch (td) {
        .struct_ => |s| {
            if (s.annotations.extensibility != .final) {
                if (diag) |w| try w.print(
                    "zidl: xrce: struct '{s}' is @{s}; only @final is allowed in XRCE profile\n",
                    .{ s.name, @tagName(s.annotations.extensibility) },
                );
                return error.XrceProfileViolation;
            }
            for (s.members) |m| {
                if (m.annotations.is_optional) {
                    if (diag) |w| try w.print(
                        "zidl: xrce: {s}.{s} is @optional; optional members require XCDR2 and are not supported in XRCE profile\n",
                        .{ s.name, m.name },
                    );
                    return error.XrceProfileViolation;
                }
                try validateXrceTypeRef(m.type_ref, s.name, m.name, diag);
            }
        },
        .union_ => |u| {
            if (u.annotations.extensibility != .final) {
                if (diag) |w| try w.print(
                    "zidl: xrce: union '{s}' is @{s}; only @final is allowed in XRCE profile\n",
                    .{ u.name, @tagName(u.annotations.extensibility) },
                );
                return error.XrceProfileViolation;
            }
            for (u.cases) |c| try validateXrceTypeRef(c.type_ref, u.name, c.name, diag);
        },
        else => {},
    }
}

fn validateXrceTypeRef(tr: ir.TypeRef, type_name: []const u8, member_name: []const u8, diag: ?*std.Io.Writer) !void {
    switch (tr) {
        .sequence => |s| {
            if (s.bound == null) {
                if (diag) |w| try w.print(
                    "zidl: xrce: {s}.{s} is an unbounded sequence; only bounded sequences are allowed in XRCE profile\n",
                    .{ type_name, member_name },
                );
                return error.XrceProfileViolation;
            }
            try validateXrceTypeRef(s.element.*, type_name, member_name, diag);
        },
        .string => |bound| {
            if (bound == null) {
                if (diag) |w| try w.print(
                    "zidl: xrce: {s}.{s} is an unbounded string; only bounded strings are allowed in XRCE profile\n",
                    .{ type_name, member_name },
                );
                return error.XrceProfileViolation;
            }
        },
        .wstring => {
            if (diag) |w| try w.print(
                "zidl: xrce: {s}.{s} uses wstring, which is not supported by the heap-free XRCE Zig output yet\n",
                .{ type_name, member_name },
            );
            return error.XrceProfileViolation;
        },
        .map => {
            if (diag) |w| try w.print(
                "zidl: xrce: {s}.{s} uses a map type which is not supported in XRCE profile\n",
                .{ type_name, member_name },
            );
            return error.XrceProfileViolation;
        },
        .named => |td| switch (td) {
            .typedef => |t| try validateXrceTypeRef(t.type_ref, type_name, member_name, diag),
            else => {},
        },
        else => {},
    }
}

// ── Backend vtable ────────────────────────────────────────────────────────────

/// A code-generation backend.  Stateless vtable + opaque context pointer.
///
/// The caller creates a concrete backend (e.g. `CBackend.create(alloc)`),
/// obtains a `Backend` value via `.backend()`, and drives it through
/// `generate` / `deinit`.
pub const Backend = struct {
    ctx: *anyopaque,
    vtable: *const Vtable,

    pub const Vtable = struct {
        /// Language identifier, used to filter `@verbatim(language="…")` blocks.
        /// E.g. `"c"`, `"cpp"`, `"java"`, `"zig"`.
        language_id: []const u8,
        /// Generate output files for the given IR spec.
        generate: *const fn (ctx: *anyopaque, spec: *const ir.Spec, opts: Options) anyerror!void,
        /// Release backend-specific resources.
        deinit: *const fn (ctx: *anyopaque) void,
    };

    pub fn generate(self: Backend, spec: *const ir.Spec, opts: Options) anyerror!void {
        return self.vtable.generate(self.ctx, spec, opts);
    }

    pub fn deinit(self: Backend) void {
        self.vtable.deinit(self.ctx);
    }

    pub fn languageId(self: Backend) []const u8 {
        return self.vtable.language_id;
    }
};

// ── Name utilities ────────────────────────────────────────────────────────────

/// Convert a `"::"` -separated IDL qualified name into a `"_"` -separated C
/// identifier.
///
///   `"Foo::Bar::Baz"` → `"Foo_Bar_Baz"`
///   `"Simple"`        → `"Simple"`
///
/// Each `"::"` pair is collapsed to a single `'_'`.
/// Caller owns the returned slice (allocated with `alloc`).
pub fn cNameFromQualified(alloc: std.mem.Allocator, qname: []const u8) ![]u8 {
    // Worst case: no "::" — output length equals input length.
    var out = try alloc.alloc(u8, qname.len);
    var out_i: usize = 0;
    var i: usize = 0;
    while (i < qname.len) {
        if (i + 1 < qname.len and qname[i] == ':' and qname[i + 1] == ':') {
            out[out_i] = '_';
            out_i += 1;
            i += 2;
        } else {
            out[out_i] = qname[i];
            out_i += 1;
            i += 1;
        }
    }
    return alloc.realloc(out, out_i);
}

/// Like `cNameFromQualified`, but prepends `prefix` to the flattened result.
///
///   `"Foo::Bar"`, prefix `"DDS_"` → `"DDS_Foo_Bar"`
///   `"Simple"`,   prefix `""`     → `"Simple"` (no extra allocation)
///
/// Caller owns the returned slice (allocated with `alloc`).
pub fn prefixedCNameFromQualified(
    alloc: std.mem.Allocator,
    qname: []const u8,
    prefix: []const u8,
) ![]u8 {
    const flat = try cNameFromQualified(alloc, qname);
    if (prefix.len == 0) return flat;
    defer alloc.free(flat);
    return std.fmt.allocPrint(alloc, "{s}{s}", .{ prefix, flat });
}

/// True for `@callback`-annotated interfaces (listener interfaces), which get a
/// plain C callback struct instead of an entity opaque handle / vtable.
/// Falls back to the "Listener" name-suffix heuristic for IDL that predates the
/// `@callback` annotation — deprecated, kept for backwards compatibility.
///
/// Thin re-export of the canonical `ir.isCallbackInterface`: kept as a
/// function here (rather than deleting it and updating every call site to say
/// `ir.isCallbackInterface`) since this backend module is where callers
/// naturally look for it.
pub fn isCallbackInterface(iface: *const ir.Interface) bool {
    return ir.isCallbackInterface(iface);
}

/// Thin re-export of the canonical `ir.hasSharedCAbiBox`, for the same reason
/// as `isCallbackInterface` above.
pub fn hasSharedCAbiBox(iface: *const ir.Interface) bool {
    return ir.hasSharedCAbiBox(iface);
}

/// Collect the qualified names of every (non-callback) interface that appears
/// as a `base` of some other (non-callback) interface, anywhere in `items` —
/// transitively, not just direct bases (see `collectBaseChain`).
///
/// Used by the C++ backend's `ifaceDeclaresNativeHandle` to decide whether an
/// interface gets its own `native_handle()` override or must instead delegate
/// to a base's: an interface with no bases of its own that is *also* used as
/// a base by more than one derived interface would otherwise get an
/// ambiguous, conflicting `native_handle()` declared once per derived class
/// under C++ multiple inheritance.
pub fn collectEntityBaseNames(
    alloc: std.mem.Allocator,
    items: []const ir.ModuleItem,
    result: *std.StringHashMapUnmanaged(void),
) anyerror!void {
    for (items) |item| {
        switch (item) {
            .module => |m| try collectEntityBaseNames(alloc, m.items, result),
            .type_decl => |td| switch (td) {
                .interface => |iface| {
                    if (!isCallbackInterface(iface)) {
                        try collectBaseChain(alloc, iface, result);
                    }
                },
                else => {},
            },
            else => {},
        }
    }
}

/// Walk `iface`'s base chain transitively (base-of-base, ...), adding every
/// ancestor's qualified name to `result`. Direct-bases-only would miss an
/// ancestor declared in an *imported* file: e.g. `zzdds::DomainParticipant`
/// (in `zzdds.idl`) directly bases `DDS::DomainParticipant`, which itself
/// bases `DDS::Entity` (in `dcps.idl`) — `DDS::Entity` is just as much "used
/// as a base" as `DDS::DomainParticipant` is, and needs to be excluded from
/// `ifaceDeclaresNativeHandle`'s leaf-entity check the same way, or it would
/// look like an undeclared leaf the moment a *different* file's generation
/// pass asks the question (its own `.bases` are only visible transitively
/// now that the IR builder's cross-module fill preserves them — see
/// `resetNonCallbackInterfaces` in `ir/builder.zig`).
fn collectBaseChain(
    alloc: std.mem.Allocator,
    iface: *const ir.Interface,
    result: *std.StringHashMapUnmanaged(void),
) anyerror!void {
    for (iface.bases) |base| {
        switch (base) {
            .interface => |b| if (!isCallbackInterface(b)) {
                try result.put(alloc, b.qualified_name, {});
                try collectBaseChain(alloc, b, result);
            },
            else => {},
        }
    }
}

/// For every concrete (non-callback) interface anywhere in `items`, record it
/// against every ancestor's qualified name in its base chain (transitively).
///
/// Needed because a base interface can have multiple *sibling* concrete
/// implementations that don't inherit from each other: e.g. dcps.idl's
/// `TopicDescription` is implemented independently by `Topic`,
/// `ContentFilteredTopic`, and `MultiTopic` — `ContentFilteredTopicImpl` does
/// NOT inherit from `TopicDescriptionImpl` in the generated C++, they're
/// siblings both implementing `::DDS::TopicDescription`. A parameter typed as
/// the base (e.g. `create_datareader`'s `a_topic: TopicDescription`) can
/// legitimately receive any of them at runtime, so the C++ backend's entity-
/// parameter `dynamic_cast` adaptation needs to try every one, not just the
/// base's own mechanical `<Iface>Impl` name — see `emitAdaptedParams`'s
/// `entity_in` case in cpp.zig, the sole consumer of this.
///
/// Deliberately does NOT exclude interfaces found in `entity_base_ifaces`
/// (unlike an earlier version of this function, which took that set as a
/// parameter and skipped anything in it). `entity_base_ifaces` answers a
/// different question — "does this interface need its own *virtual*
/// `native_handle()`, or does a more-derived interface own a more specific
/// one instead" (see `ifaceOwnsNativeHandle`) — which is NOT the same as "is
/// this interface ever the actual most-derived runtime type of an object."
/// `ReadCondition` is the concrete counterexample that exposed the bug:
/// excluded from `entity_base_ifaces` so `QueryCondition` can own its own,
/// more specific `DDS_QueryCondition` handle instead of inheriting
/// `ReadCondition`'s — but `ReadCondition` still gets its own real,
/// independently-constructible `ReadConditionImpl` (with its own
/// `_getOrCreate`), returned as-is by `DataReader::create_readcondition`
/// whenever the app doesn't ask for a `QueryCondition`. Confirmed via a real
/// crash, not just by inspection: `WaitSet::attach_condition`/
/// `detach_condition`'s generated `Condition`-parameter adapter cascade
/// (`dynamic_cast<ConditionImpl*>`, `GuardConditionImpl*`,
/// `StatusConditionImpl*`, `QueryConditionImpl*`, in that order) never
/// included `ReadConditionImpl` at all under the old exclusion, so attaching
/// a plain `ReadCondition` (not further specialized to a `QueryCondition`)
/// threw `std::invalid_argument("zidl: incompatible entity implementation
/// for DDS::Condition")` at runtime — every non-callback interface gets its
/// own concrete impl class regardless of `entity_base_ifaces` membership
/// (confirmed: `ConditionImpl`/`EntityImpl`/`TopicDescriptionImpl` — the
/// three interfaces this exclusion was originally written to describe as
/// "genuinely abstract-only" — all have their own generated class too), so
/// there is no case where excluding an `entity_base_ifaces` member here is
/// actually correct.
pub fn collectBaseImplementors(
    alloc: std.mem.Allocator,
    items: []const ir.ModuleItem,
    result: *std.StringHashMapUnmanaged(std.ArrayListUnmanaged(*const ir.Interface)),
) anyerror!void {
    for (items) |item| {
        switch (item) {
            .module => |m| try collectBaseImplementors(alloc, m.items, result),
            .type_decl => |td| switch (td) {
                .interface => |iface| {
                    if (!isCallbackInterface(iface)) {
                        try recordBaseChainImplementor(alloc, iface, iface, result);
                    }
                },
                else => {},
            },
            else => {},
        }
    }
}

/// Walk `iface`'s base chain transitively, recording `leaf` (the original
/// concrete interface `collectBaseImplementors` started from) against every
/// ancestor reached. Mirrors `collectBaseChain`'s traversal; dedups so a
/// diamond-shaped base chain (reaching the same ancestor via two paths)
/// doesn't record `leaf` against it twice.
fn recordBaseChainImplementor(
    alloc: std.mem.Allocator,
    leaf: *const ir.Interface,
    iface: *const ir.Interface,
    result: *std.StringHashMapUnmanaged(std.ArrayListUnmanaged(*const ir.Interface)),
) anyerror!void {
    for (iface.bases) |base| {
        switch (base) {
            .interface => |b| if (!isCallbackInterface(b)) {
                const gop = try result.getOrPut(alloc, b.qualified_name);
                if (!gop.found_existing) gop.value_ptr.* = .empty;
                var already = false;
                for (gop.value_ptr.items) |existing| {
                    if (existing == leaf) {
                        already = true;
                        break;
                    }
                }
                if (!already) try gop.value_ptr.append(alloc, leaf);
                try recordBaseChainImplementor(alloc, leaf, b, result);
            },
            else => {},
        }
    }
}

/// Frees every `ArrayListUnmanaged` value in a map populated by
/// `collectBaseImplementors`, then the map itself. `StringHashMapUnmanaged`'s
/// own `deinit` only frees its bucket storage, not per-value allocations.
pub fn deinitBaseImplementors(
    alloc: std.mem.Allocator,
    map: *std.StringHashMapUnmanaged(std.ArrayListUnmanaged(*const ir.Interface)),
) void {
    var it = map.valueIterator();
    while (it.next()) |list| list.deinit(alloc);
    map.deinit(alloc);
}

/// Walks `iface`'s *primary* base chain (`bases[0]` only, never a secondary
/// base) upward for as long as each step is itself `@shared_c_abi_box`
/// (`ir.hasSharedCAbiBox`), stopping at the last annotated ancestor — the
/// interface every member of that chain shares one physical C-ABI box with.
/// Mirrors the walk `zig.zig`'s `CAbiViews` nesting already does (`iface.bases[0]
/// == .interface and hasSharedCAbiBox(iface.bases[0].interface)`), so this
/// answers exactly "which interfaces did the Zig-side box-identity fix
/// actually unify" — the grouping any backend-level identity cache (C++'s
/// `_getOrCreate`, a future Java box cache) needs to mirror to stay
/// consistent with it.
///
/// Returns `iface` itself if `iface` isn't `@shared_c_abi_box` at all, or has
/// no annotated primary base — the trivial one-member-family case.
pub fn sharedCAbiBoxFamilyRoot(iface: *const ir.Interface) *const ir.Interface {
    if (!ir.hasSharedCAbiBox(iface)) return iface;
    var cur = iface;
    while (cur.bases.len > 0 and cur.bases[0] == .interface and ir.hasSharedCAbiBox(cur.bases[0].interface)) {
        cur = cur.bases[0].interface;
    }
    return cur;
}

/// For every non-callback interface anywhere in `items`, groups it under its
/// `sharedCAbiBoxFamilyRoot`'s qualified name. An interface that isn't
/// `@shared_c_abi_box` (or has no annotated family) ends up alone in its own
/// singleton group, keyed by its own qualified name — same shape as an
/// un-annotated interface always had, so a caller can treat "family size 1"
/// as "nothing to change here" without a separate check.
///
/// Unlike `collectBaseImplementors` (which records an implementor against
/// *every* ancestor in its full base chain, primary or secondary), this only
/// ever walks `bases[0]` — a secondary base (e.g. `Topic`'s `TopicDescription`)
/// deliberately does NOT pull its implementors into the primary chain's
/// family, matching the "known limitation" the box-identity design already
/// calls out: secondary-base views keep their own independently-cached box,
/// so they must also keep their own independent identity cache here.
pub fn collectSharedCAbiBoxFamilies(
    alloc: std.mem.Allocator,
    items: []const ir.ModuleItem,
    result: *std.StringHashMapUnmanaged(std.ArrayListUnmanaged(*const ir.Interface)),
) anyerror!void {
    for (items) |item| {
        switch (item) {
            .module => |m| try collectSharedCAbiBoxFamilies(alloc, m.items, result),
            .type_decl => |td| switch (td) {
                .interface => |iface| {
                    if (!isCallbackInterface(iface)) {
                        const root = sharedCAbiBoxFamilyRoot(iface);
                        const gop = try result.getOrPut(alloc, root.qualified_name);
                        if (!gop.found_existing) gop.value_ptr.* = .empty;
                        try gop.value_ptr.append(alloc, iface);
                    }
                },
                else => {},
            },
            else => {},
        }
    }
}

// ── Tests ─────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "cNameFromQualified: nested" {
    const a = try cNameFromQualified(testing.allocator, "Foo::Bar::Baz");
    defer testing.allocator.free(a);
    try testing.expectEqualStrings("Foo_Bar_Baz", a);
}

test "cNameFromQualified: simple" {
    const b = try cNameFromQualified(testing.allocator, "Simple");
    defer testing.allocator.free(b);
    try testing.expectEqualStrings("Simple", b);
}

test "cNameFromQualified: empty" {
    const c = try cNameFromQualified(testing.allocator, "");
    defer testing.allocator.free(c);
    try testing.expectEqualStrings("", c);
}

test "cNameFromQualified: single level" {
    const d = try cNameFromQualified(testing.allocator, "Foo::Bar");
    defer testing.allocator.free(d);
    try testing.expectEqualStrings("Foo_Bar", d);
}

test "prefixedCNameFromQualified: with prefix" {
    const a = try prefixedCNameFromQualified(testing.allocator, "Foo::Bar", "DDS_");
    defer testing.allocator.free(a);
    try testing.expectEqualStrings("DDS_Foo_Bar", a);
}

test "prefixedCNameFromQualified: empty prefix matches cNameFromQualified" {
    const b = try prefixedCNameFromQualified(testing.allocator, "Foo::Bar", "");
    defer testing.allocator.free(b);
    try testing.expectEqualStrings("Foo_Bar", b);
}

test "prefixedCNameFromQualified: simple name with prefix" {
    const c = try prefixedCNameFromQualified(testing.allocator, "Simple", "NS_");
    defer testing.allocator.free(c);
    try testing.expectEqualStrings("NS_Simple", c);
}

// ── XRCE validation tests ─────────────────────────────────────────────────────

const parser_mod = @import("../parser.zig");
const semantic_mod = @import("../semantic/root.zig");

fn buildTestIr(alloc: std.mem.Allocator, source: []const u8) !ir.Spec {
    var ast_arena = std.heap.ArenaAllocator.init(alloc);
    defer ast_arena.deinit();
    var p = parser_mod.Parser.init(source, ast_arena.allocator());
    const spec = try p.parseSpecification();
    var az = try semantic_mod.Analyzer.init(alloc);
    defer az.deinit();
    try az.analyze(&spec);
    return ir.build(alloc, &spec, az.global_scope, &.{});
}

test "xrce validate: @final struct with bounded sequence passes" {
    var ir_spec = try buildTestIr(testing.allocator, "@final struct S { long x; sequence<long, 4> xs; };");
    defer ir_spec.deinit();
    try validateXrce(&ir_spec, null);
}

test "xrce validate: @appendable struct fails" {
    var ir_spec = try buildTestIr(testing.allocator, "@appendable struct S { long x; };");
    defer ir_spec.deinit();
    try testing.expectError(error.XrceProfileViolation, validateXrce(&ir_spec, null));
}

test "xrce validate: @mutable struct fails" {
    var ir_spec = try buildTestIr(testing.allocator, "@mutable struct S { long x; };");
    defer ir_spec.deinit();
    try testing.expectError(error.XrceProfileViolation, validateXrce(&ir_spec, null));
}

test "xrce validate: unbounded sequence fails" {
    var ir_spec = try buildTestIr(testing.allocator, "struct S { sequence<long> xs; };");
    defer ir_spec.deinit();
    try testing.expectError(error.XrceProfileViolation, validateXrce(&ir_spec, null));
}

test "xrce validate: bounded sequence passes" {
    var ir_spec = try buildTestIr(testing.allocator, "struct S { sequence<long, 8> xs; };");
    defer ir_spec.deinit();
    try validateXrce(&ir_spec, null);
}

test "xrce validate: unbounded string fails" {
    var ir_spec = try buildTestIr(testing.allocator, "struct S { string name; };");
    defer ir_spec.deinit();
    try testing.expectError(error.XrceProfileViolation, validateXrce(&ir_spec, null));
}

test "xrce validate: bounded string passes" {
    var ir_spec = try buildTestIr(testing.allocator, "struct S { string<16> name; };");
    defer ir_spec.deinit();
    try validateXrce(&ir_spec, null);
}

test "xrce validate: optional member fails" {
    var ir_spec = try buildTestIr(testing.allocator, "struct S { @optional long x; };");
    defer ir_spec.deinit();
    try testing.expectError(error.XrceProfileViolation, validateXrce(&ir_spec, null));
}

test "xrce validate: wstring fails" {
    var ir_spec = try buildTestIr(testing.allocator, "struct S { wstring<8> name; };");
    defer ir_spec.deinit();
    try testing.expectError(error.XrceProfileViolation, validateXrce(&ir_spec, null));
}

test "xrce validate: @appendable in nested module fails" {
    var ir_spec = try buildTestIr(testing.allocator, "module M { @appendable struct S { long x; }; };");
    defer ir_spec.deinit();
    try testing.expectError(error.XrceProfileViolation, validateXrce(&ir_spec, null));
}
