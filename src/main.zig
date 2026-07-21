//! zidl CLI — IDL 4.2 compiler driver.
//!
//! Usage:
//!   zidl [options] <file.idl> [<file.idl>…]
//!
//! Options:
//!   -b <lang>                      Backend language: c (default), cpp, java, zig
//!   -o <dir>                       Output directory (default: .)
//!   -I <dir>                       Add include search path (repeatable)
//!   -D <M>[=V]                     Define preprocessor macro (repeatable)
//!   -E                             Preprocess only; emit expanded IDL
//!
//!   --default-extensibility <ext>  Default extensibility when no @extensibility present
//!                                  (default: final, per IDL4 §8.3.1) (all backends)
//!   --generate-zzdds-wrappers      Emit typed zzdds topic wrappers (Zig, C, C++)
//!   --generate-interfaces          Emit binding layer for IDL interface declarations (all backends)
//!   --no-typeobject-support        Suppress TypeObject/TypeIdentifier (all backends, currently Zig only)
//!   --no-typesupport               Suppress CDR serialize/deserialize (all backends)
//!   --profile <full|xrce>          Target profile: full (default) or xrce (all backends)
//!                                    xrce: XCDR1 only, @final types, bounded sequences/strings
//!   --single-file                  Single monolithic output file — default (all backends)
//!   --split-files                  One file per type (C/C++/Java) or per module (Zig) (all backends)
//!   --type-prefix <pfx>            Prefix for all generated type names (all backends)
//!
//!   --c-export-macro <macro>       DLL export macro for function declarations (C, C++ backends)
//!   --c-extern-c                   Wrap header in extern "C" {} (C backend)
//!   --c-header-guard-prefix <pfx>  Prefix for include guard macros (C, C++ backends)
//!   --c-pragma-once                Use #pragma once instead of #ifndef guards (C, C++ backends)
//!   --cpp-namespace <ns>           Wrap all output in an outer namespace (C++ backend)
//!
//!   --java-jni-library <name>      System.loadLibrary() name for JNI impls (Java backend)
//!   --java-package <pkg>           Package prefix, e.g. com.example (Java backend)
//!
//!   --zig-generate-c-api           Emit pub export fn callconv(.c) wrappers for C free-function API (Zig backend)
//!   --zig-idiomatic-enums          Generate lowercase snake_case enum tags (e.g. .durability_volatile) (Zig backend)
//!   --zig-pl-cdr                   Generate PL_CDR functions for @mutable types (Zig backend)
//!   --zig-version <0.16.0|0.15.1>  Output compatibility target (Zig backend)
//!
//!   -h, --help                     Show this help
//!   -v, --version                  Show version
//!
//! Drives the full pipeline per input file:
//!   preprocessor → lexer → parser → semantic analysis → IR → backend

const std = @import("std");
const Io = std.Io;
const zidl = @import("zidl");
const build_options = @import("build_options");

const version_string = build_options.version_string;

// ── CLI ───────────────────────────────────────────────────────────────────────

const Opts = struct {
    backend: []const u8 = "c",
    output_dir: []const u8 = ".",
    include_paths: std.ArrayListUnmanaged([]const u8) = .empty,
    defines: std.ArrayListUnmanaged([]const u8) = .empty,
    preprocess_only: bool = false,
    no_typesupport: bool = false,
    no_typeobject_support: bool = false,
    generate_interfaces: bool = false,
    header_guard_prefix: []const u8 = "",
    type_prefix: []const u8 = "",
    export_macro: []const u8 = "",
    profile: zidl.backend.Profile = .full,
    zig_version: zidl.backend.ZigVersion = .@"0.16.0",
    java_package: []const u8 = "",
    default_extensibility: zidl.ir.Extensibility = .final,
    jni_library: []const u8 = "zidl_dds_jni",
    split_files: bool = false,
    pragma_once: bool = false,
    extern_c: bool = false,
    cpp_namespace: []const u8 = "",
    pl_cdr: bool = false,
    generate_zzdds_wrappers: bool = false,
    zig_generate_c_api: bool = false,
    zig_idiomatic_enums: bool = false,
    cpp_generate_impl: bool = false,
    cpp_pmr_containers: bool = false,
    preprocess_timestamp_seconds: ?u64 = null,
    inputs: std.ArrayListUnmanaged([]const u8) = .empty,
};

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    const io = init.io;

    // Stdout writer for -E output.
    var out_buf: [4096]u8 = undefined;
    var stdout_fw: Io.File.Writer = .init(.stdout(), io, &out_buf);
    const stdout = &stdout_fw.interface;

    // Stderr writer for diagnostics.
    var err_buf: [256]u8 = undefined;
    var stderr_fw: Io.File.Writer = .init(.stderr(), io, &err_buf);
    const stderr = &stderr_fw.interface;

    if (args.len < 2) {
        try printUsage(stderr);
        std.process.exit(1);
    }

    var opts = Opts{};
    var i: usize = 1;
    while (i < args.len) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            try printUsage(stderr);
            return;
        } else if (std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "--version")) {
            try stdout.print("{s}\n", .{version_string});
            try stdout.flush();
            return;
        } else if (std.mem.eql(u8, arg, "-E")) {
            opts.preprocess_only = true;
        } else if (std.mem.eql(u8, arg, "--no-typesupport")) {
            opts.no_typesupport = true;
        } else if (std.mem.eql(u8, arg, "--no-typeobject-support")) {
            opts.no_typeobject_support = true;
        } else if (std.mem.eql(u8, arg, "--generate-interfaces")) {
            opts.generate_interfaces = true;
        } else if (std.mem.eql(u8, arg, "--cpp-generate-impl")) {
            opts.cpp_generate_impl = true;
        } else if (std.mem.eql(u8, arg, "--cpp-pmr-containers")) {
            opts.cpp_pmr_containers = true;
        } else if (std.mem.eql(u8, arg, "-b")) {
            i += 1;
            if (i >= args.len) {
                try stderr.print("error: -b requires a language argument\n", .{});
                try stderr.flush();
                std.process.exit(1);
            }
            opts.backend = args[i];
        } else if (std.mem.eql(u8, arg, "-o")) {
            i += 1;
            if (i >= args.len) {
                try stderr.print("error: -o requires a directory argument\n", .{});
                try stderr.flush();
                std.process.exit(1);
            }
            opts.output_dir = args[i];
        } else if (std.mem.eql(u8, arg, "-I")) {
            i += 1;
            if (i >= args.len) {
                try stderr.print("error: -I requires a directory argument\n", .{});
                try stderr.flush();
                std.process.exit(1);
            }
            try opts.include_paths.append(arena, args[i]);
        } else if (std.mem.eql(u8, arg, "-D")) {
            i += 1;
            if (i >= args.len) {
                try stderr.print("error: -D requires a macro argument\n", .{});
                try stderr.flush();
                std.process.exit(1);
            }
            try opts.defines.append(arena, args[i]);
        } else if (std.mem.startsWith(u8, arg, "-I")) {
            try opts.include_paths.append(arena, arg[2..]);
        } else if (std.mem.startsWith(u8, arg, "-D")) {
            try opts.defines.append(arena, arg[2..]);
        } else if (std.mem.eql(u8, arg, "--c-header-guard-prefix")) {
            i += 1;
            if (i >= args.len) {
                try stderr.print("error: --c-header-guard-prefix requires an argument\n", .{});
                try stderr.flush();
                std.process.exit(1);
            }
            opts.header_guard_prefix = args[i];
        } else if (std.mem.eql(u8, arg, "--type-prefix")) {
            i += 1;
            if (i >= args.len) {
                try stderr.print("error: --type-prefix requires an argument\n", .{});
                try stderr.flush();
                std.process.exit(1);
            }
            opts.type_prefix = args[i];
        } else if (std.mem.eql(u8, arg, "--c-export-macro")) {
            i += 1;
            if (i >= args.len) {
                try stderr.print("error: --c-export-macro requires an argument\n", .{});
                try stderr.flush();
                std.process.exit(1);
            }
            opts.export_macro = args[i];
        } else if (std.mem.eql(u8, arg, "--profile")) {
            i += 1;
            if (i >= args.len) {
                try stderr.print("error: --profile requires an argument\n", .{});
                try stderr.flush();
                std.process.exit(1);
            }
            const profile_name = args[i];
            if (std.mem.eql(u8, profile_name, "xrce")) {
                opts.profile = .xrce;
            } else if (std.mem.eql(u8, profile_name, "full")) {
                opts.profile = .full;
            } else {
                try stderr.print("error: unknown profile '{s}'; supported: full, xrce\n", .{profile_name});
                try stderr.flush();
                std.process.exit(1);
            }
        } else if (std.mem.eql(u8, arg, "--zig-version")) {
            i += 1;
            if (i >= args.len) {
                try stderr.print("error: --zig-version requires an argument\n", .{});
                try stderr.flush();
                std.process.exit(1);
            }
            opts.zig_version = zidl.backend.ZigVersion.parse(args[i]) orelse {
                try stderr.print("error: unknown Zig version '{s}'; supported: 0.16.0, 0.15.1\n", .{args[i]});
                try stderr.flush();
                std.process.exit(1);
            };
        } else if (std.mem.eql(u8, arg, "--java-jni-library")) {
            i += 1;
            if (i >= args.len) {
                try stderr.print("error: --java-jni-library requires an argument\n", .{});
                try stderr.flush();
                std.process.exit(1);
            }
            opts.jni_library = args[i];
        } else if (std.mem.eql(u8, arg, "--java-package")) {
            i += 1;
            if (i >= args.len) {
                try stderr.print("error: --java-package requires an argument\n", .{});
                try stderr.flush();
                std.process.exit(1);
            }
            opts.java_package = args[i];
        } else if (std.mem.eql(u8, arg, "--split-files")) {
            opts.split_files = true;
        } else if (std.mem.eql(u8, arg, "--single-file")) {
            opts.split_files = false;
        } else if (std.mem.eql(u8, arg, "--generate-zzdds-wrappers")) {
            opts.generate_zzdds_wrappers = true;
        } else if (std.mem.eql(u8, arg, "--zig-pl-cdr")) {
            opts.pl_cdr = true;
        } else if (std.mem.eql(u8, arg, "--zig-generate-c-api")) {
            opts.zig_generate_c_api = true;
        } else if (std.mem.eql(u8, arg, "--zig-idiomatic-enums")) {
            opts.zig_idiomatic_enums = true;
        } else if (std.mem.eql(u8, arg, "--c-pragma-once")) {
            opts.pragma_once = true;
        } else if (std.mem.eql(u8, arg, "--c-extern-c")) {
            opts.extern_c = true;
        } else if (std.mem.eql(u8, arg, "--cpp-namespace")) {
            i += 1;
            if (i >= args.len) {
                try stderr.print("error: --cpp-namespace requires an argument\n", .{});
                try stderr.flush();
                std.process.exit(1);
            }
            opts.cpp_namespace = args[i];
        } else if (std.mem.eql(u8, arg, "--default-extensibility")) {
            i += 1;
            if (i >= args.len) {
                try stderr.print("error: --default-extensibility requires an argument\n", .{});
                try stderr.flush();
                std.process.exit(1);
            }
            const ext_name = args[i];
            if (std.mem.eql(u8, ext_name, "final")) {
                opts.default_extensibility = .final;
            } else if (std.mem.eql(u8, ext_name, "appendable")) {
                opts.default_extensibility = .appendable;
            } else if (std.mem.eql(u8, ext_name, "mutable")) {
                opts.default_extensibility = .mutable;
            } else {
                try stderr.print(
                    "error: unknown extensibility '{s}'; supported: final, appendable, mutable\n",
                    .{ext_name},
                );
                try stderr.flush();
                std.process.exit(1);
            }
        } else if (std.mem.startsWith(u8, arg, "-")) {
            try stderr.print("error: unknown option: {s}\n", .{arg});
            try stderr.flush();
            std.process.exit(1);
        } else {
            try opts.inputs.append(arena, arg);
        }
        i += 1;
    }

    if (opts.inputs.items.len == 0) {
        try stderr.print("error: no input files\n", .{});
        try stderr.flush();
        std.process.exit(1);
    }

    opts.preprocess_timestamp_seconds = sourceDateEpochFromEnv(init.environ_map) catch {
        try stderr.print("error: SOURCE_DATE_EPOCH must be a non-negative decimal Unix timestamp\n", .{});
        try stderr.flush();
        std.process.exit(1);
    };

    // Resolve backend.
    const backend_opt = try zidl.backend.findByLanguageId(arena, opts.backend);
    if (backend_opt == null) {
        try stderr.print("error: unknown backend '{s}'; supported: c, cpp, java, zig\n", .{opts.backend});
        try stderr.flush();
        std.process.exit(1);
    }
    var be = backend_opt.?;
    defer be.deinit();

    // Process each input file.
    var had_error = false;
    for (opts.inputs.items) |input_path| {
        processFile(
            arena,
            input_path,
            &opts,
            &be,
            stdout,
            stderr,
        ) catch |err| {
            try stderr.print("error: {s}: {s}\n", .{ input_path, @errorName(err) });
            try stderr.flush();
            had_error = true;
        };
    }

    if (had_error) {
        std.process.exit(1);
    }
}

// ── Per-file pipeline ─────────────────────────────────────────────────────────

fn processFile(
    alloc: std.mem.Allocator,
    path: []const u8,
    opts: *const Opts,
    be: *zidl.backend.Backend,
    stdout: *Io.Writer,
    stderr: *Io.Writer,
) !void {
    // ── Phase 1: Preprocess ──────────────────────────────────────────────────
    var pp_diagnostics = zidl.preprocessor.Diagnostics.init(alloc);
    defer pp_diagnostics.deinit();

    var pp = zidl.preprocessor.Preprocessor.initWithOptions(
        alloc,
        zidl.preprocessor.FileLoader.fileSystem(),
        .{
            .diagnostics = &pp_diagnostics,
            .build_timestamp_seconds = opts.preprocess_timestamp_seconds,
        },
    );
    defer pp.deinit();

    // Apply -D defines.
    for (opts.defines.items) |def| {
        const eq = std.mem.indexOf(u8, def, "=");
        const name = if (eq) |e| def[0..e] else def;
        const value = if (eq) |e| def[e + 1 ..] else "1";
        try pp.predefine(name, value);
    }

    // Apply -I include paths.
    for (opts.include_paths.items) |inc| {
        try pp.addIncludePath(inc);
    }

    const pp_result = try pp.process(path);
    defer pp_result.deinit(alloc);

    for (pp_diagnostics.items.items) |diag| {
        try printPreprocessorDiagnostic(stderr, pp_result, diag);
    }

    if (pp.errors.items.len > 0) {
        for (pp.errors.items) |e| {
            try stderr.print("{s}\n", .{e});
        }
        return error.PreprocessorError;
    }

    if (opts.preprocess_only) {
        try stdout.print("{s}", .{pp_result.source});
        try stdout.flush();
        return;
    }

    // ── Phase 2: Parse ───────────────────────────────────────────────────────
    var ast_arena = std.heap.ArenaAllocator.init(alloc);
    defer ast_arena.deinit();

    var parser = zidl.parser.Parser.init(pp_result.source, ast_arena.allocator());
    const ast_spec = parser.parseSpecification() catch |err| {
        for (parser.diags.items) |d| {
            try stderr.print("{s}:{d}:{d}: error: {s}\n", .{
                path, d.span.start.line, d.span.start.column, d.message,
            });
        }
        try stderr.flush();
        return err;
    };

    // ── Phase 2b: Resolve import declarations ────────────────────────────────
    //
    // Scan the AST for `import "file.idl";` declarations.  For each, run the
    // full sub-pipeline (preprocess → parse → analyze) and preload the resulting
    // scope into the main analyzer so that cross-module type references (e.g.
    // `DDS::ReturnCode_t`) resolve correctly during semantic analysis.
    //
    // All sub-pipeline data lives in `import_arena`, kept alive until after
    // `ir.build()` because scope pointers in preloaded symbols borrow from the
    // sub-analyzers' arenas.  The deferred `import_arena.deinit()` runs at the
    // end of this function, after all IR work is complete.
    var import_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer import_arena.deinit();
    const ialloc = import_arena.allocator();

    var imported_analyzers: std.ArrayListUnmanaged(*zidl.semantic.Analyzer) = .empty;
    // Parallel to imported_analyzers: each import's own parsed AST, kept alive
    // (not freed immediately after analysis, unlike before) so ir.build() can
    // fill in imported types' real members, not just empty skeletons — see
    // zidl.ir.ImportedUnit / buildWithImportedUnits.
    var imported_ast_specs: std.ArrayListUnmanaged(*const zidl.ast.Specification) = .empty;
    var import_module_names: std.ArrayListUnmanaged([]const u8) = .empty;
    var seen_import_modules = std.StringHashMapUnmanaged(void).empty;

    for (ast_spec.definitions) |*adef| {
        const imp = switch (adef.kind) {
            .import_dcl => |*i| i,
            else => continue,
        };
        const import_path = switch (imp.scope) {
            .string_literal => |s| s,
            .scoped_name => continue, // error emitted by analyzer below
        };

        // Resolve the import path: alongside the input file first, then -I dirs.
        const resolved_path = blk: {
            const dir = std.fs.path.dirname(path) orelse ".";
            const by_dir = try std.fs.path.join(ialloc, &.{ dir, import_path });
            if (fileExists(by_dir)) break :blk by_dir;
            for (opts.include_paths.items) |inc| {
                const by_inc = try std.fs.path.join(ialloc, &.{ inc, import_path });
                if (fileExists(by_inc)) break :blk by_inc;
            }
            try stderr.print("error: '{s}': imported file '{s}' not found\n", .{ path, import_path });
            try stderr.flush();
            return error.ImportNotFound;
        };

        // Preprocess the imported file.
        var sub_pp_diags = zidl.preprocessor.Diagnostics.init(ialloc);
        var sub_pp = zidl.preprocessor.Preprocessor.initWithOptions(
            ialloc,
            zidl.preprocessor.FileLoader.fileSystem(),
            .{ .diagnostics = &sub_pp_diags },
        );
        for (opts.defines.items) |def_str| {
            const eq_pos = std.mem.indexOf(u8, def_str, "=");
            const def_name = if (eq_pos) |e| def_str[0..e] else def_str;
            const def_val = if (eq_pos) |e| def_str[e + 1 ..] else "1";
            try sub_pp.predefine(def_name, def_val);
        }
        for (opts.include_paths.items) |inc| try sub_pp.addIncludePath(inc);
        const sub_pp_result = try sub_pp.process(resolved_path);
        if (sub_pp.errors.items.len > 0) {
            for (sub_pp.errors.items) |e| try stderr.print("{s}\n", .{e});
            try stderr.flush();
            return error.PreprocessorError;
        }

        // Parse + analyze the imported file in the import arena.
        var sub_ast_arena = std.heap.ArenaAllocator.init(ialloc);
        var sub_parser = zidl.parser.Parser.init(sub_pp_result.source, sub_ast_arena.allocator());
        const sub_ast = sub_parser.parseSpecification() catch |err| {
            for (sub_parser.diags.items) |d| {
                try stderr.print("{s}:{d}:{d}: error: {s}\n", .{
                    resolved_path, d.span.start.line, d.span.start.column, d.message,
                });
            }
            try stderr.flush();
            return err;
        };
        const sub_az = try ialloc.create(zidl.semantic.Analyzer);
        sub_az.* = try zidl.semantic.Analyzer.init(ialloc);
        try sub_az.analyze(&sub_ast);
        if (sub_az.diagnostics.items.len > 0) {
            for (sub_az.diagnostics.items) |diag| {
                try stderr.print("{s}\n", .{diag.message});
            }
            for (sub_az.diagnostics.items) |diag| {
                if (diag.severity == .err) {
                    try stderr.flush();
                    return error.SemanticError;
                }
            }
            try stderr.flush();
        }
        // Note: sub_ast_arena is intentionally NOT deinit'd here (unlike before) —
        // ir.buildWithImportedUnits() needs the imported file's own AST alive to
        // fill in its types' real members (operations, etc.), not just empty
        // Pass-1 skeletons. It's backed by ialloc (import_arena), which the
        // caller keeps alive until after ir.build() returns, so this only
        // delays freeing rather than leaking past this function's lifetime.
        const sub_ast_copy = try ialloc.create(zidl.ast.Specification);
        sub_ast_copy.* = sub_ast;
        try imported_ast_specs.append(ialloc, sub_ast_copy);
        try imported_analyzers.append(ialloc, sub_az);

        // Collect unique top-level module names from the imported scope.
        var sym_it = sub_az.global_scope.symbols.iterator();
        while (sym_it.next()) |entry| {
            const sym = entry.value_ptr.*;
            if (sym.tag != .module) continue;
            const gop = try seen_import_modules.getOrPut(ialloc, sym.name);
            if (!gop.found_existing) {
                try import_module_names.append(ialloc, try ialloc.dupe(u8, sym.name));
            }
        }
    }

    // ── Phase 3: Semantic analysis ───────────────────────────────────────────
    var analyzer = try zidl.semantic.Analyzer.init(alloc);
    defer analyzer.deinit();

    // Preload imported scopes before analyzing the main file.
    for (imported_analyzers.items) |sub_az| {
        try analyzer.preloadScope(sub_az.global_scope);
    }

    try analyzer.analyze(&ast_spec);

    if (analyzer.diagnostics.items.len > 0) {
        for (analyzer.diagnostics.items) |diag| {
            try stderr.print("{s}\n", .{diag.message});
        }
        // Check for errors (not just warnings).
        for (analyzer.diagnostics.items) |diag| {
            if (diag.severity == .err) {
                return error.SemanticError;
            }
        }
    }

    // ── Phase 4: Build IR ────────────────────────────────────────────────────
    // import_arena (and sub-analyzers) remain alive here — scope pointers
    // inside preloaded symbols borrow from them until ir.build() returns.
    var imported_units: std.ArrayListUnmanaged(zidl.ir.ImportedUnit) = .empty;
    for (imported_ast_specs.items, imported_analyzers.items) |iu_ast, iu_az| {
        try imported_units.append(ialloc, .{ .ast_spec = iu_ast, .scope = iu_az.global_scope });
    }
    var ir_spec = try zidl.ir.buildWithImportedUnits(
        alloc,
        &ast_spec,
        analyzer.global_scope,
        import_module_names.items,
        imported_units.items,
    );
    defer ir_spec.deinit();

    for (ir_spec.warnings) |w| {
        try stderr.print("{s}\n", .{w});
        try stderr.flush();
    }

    // ── Phase 4b: XRCE profile validation ───────────────────────────────────
    if (opts.profile == .xrce) {
        try zidl.backend.validateXrce(&ir_spec, stderr);
    }

    // ── Phase 5: Code generation ─────────────────────────────────────────────
    if (opts.output_dir.len > 0 and !std.mem.eql(u8, opts.output_dir, ".")) {
        const _io = std.Io.Threaded.global_single_threaded.io();
        try Io.Dir.cwd().createDirPath(_io, opts.output_dir);
    }
    const stem = std.fs.path.stem(path);

    const gen_opts = zidl.backend.Options{
        .output_dir = opts.output_dir,
        .input_stem = stem,
        .no_typesupport = opts.no_typesupport,
        .no_typeobject_support = opts.no_typeobject_support or opts.profile == .xrce,
        .generate_interfaces = opts.generate_interfaces,
        .header_guard_prefix = opts.header_guard_prefix,
        .type_prefix = opts.type_prefix,
        .export_macro = opts.export_macro,
        .profile = opts.profile,
        .java_package = opts.java_package,
        .default_extensibility = opts.default_extensibility,
        .jni_library = opts.jni_library,
        .split_files = opts.split_files,
        .pragma_once = opts.pragma_once,
        .extern_c = opts.extern_c,
        .cpp_namespace = opts.cpp_namespace,
        .pl_cdr = opts.pl_cdr,
        .zig_generate_c_api = opts.zig_generate_c_api,
        .zig_idiomatic_enums = opts.zig_idiomatic_enums,
        .generate_zzdds_wrappers = opts.generate_zzdds_wrappers,
        .zig_version = opts.zig_version,
        .cpp_generate_impl = opts.cpp_generate_impl,
        .cpp_pmr_containers = opts.cpp_pmr_containers,
    };
    try be.generate(&ir_spec, gen_opts);
}

fn fileExists(path_str: []const u8) bool {
    const io = std.Io.Threaded.global_single_threaded.io();
    std.Io.Dir.cwd().access(io, path_str, .{}) catch return false;
    return true;
}

fn printPreprocessorDiagnostic(
    stderr: *Io.Writer,
    result: zidl.preprocessor.Result,
    diag: zidl.preprocessor.Diagnostic,
) !void {
    const filename = if (diag.file_index < result.files.len)
        result.files[diag.file_index]
    else
        "<unknown>";
    const severity = switch (diag.severity) {
        .warning => "warning",
        .err => "error",
    };
    try stderr.print("{s}:{d}:{d}: {s}: {s}\n", .{
        filename,
        diag.line,
        diag.column,
        severity,
        diag.message,
    });
    try stderr.flush();
}

const SourceDateEpochError = error{
    InvalidSourceDateEpoch,
};

fn sourceDateEpochFromEnv(environ_map: *const std.process.Environ.Map) SourceDateEpochError!?u64 {
    const value = environ_map.get("SOURCE_DATE_EPOCH") orelse return null;
    return try parseSourceDateEpoch(value);
}

fn parseSourceDateEpoch(value: []const u8) SourceDateEpochError!u64 {
    if (value.len == 0) return error.InvalidSourceDateEpoch;
    const seconds = std.fmt.parseUnsigned(u64, value, 10) catch return error.InvalidSourceDateEpoch;
    if (seconds > zidl.preprocessor.max_build_timestamp_seconds) return error.InvalidSourceDateEpoch;
    return seconds;
}

test "parse SOURCE_DATE_EPOCH" {
    const testing = std.testing;

    try testing.expectEqual(@as(u64, 0), try parseSourceDateEpoch("0"));
    try testing.expectEqual(@as(u64, 1622924906), try parseSourceDateEpoch("1622924906"));
    try testing.expectError(error.InvalidSourceDateEpoch, parseSourceDateEpoch(""));
    try testing.expectError(error.InvalidSourceDateEpoch, parseSourceDateEpoch("-1"));
    try testing.expectError(error.InvalidSourceDateEpoch, parseSourceDateEpoch("123abc"));
    try testing.expectError(error.InvalidSourceDateEpoch, parseSourceDateEpoch("253402300800"));
}

fn printUsage(w: *Io.Writer) !void {
    try w.print(
        \\Usage: zidl [options] <file.idl> [<file.idl>…]
        \\
        \\Options:
        \\  -b <lang>                      Backend language: c (default), cpp, java, zig
        \\  -o <dir>                       Output directory (default: .)
        \\  -I <dir>                       Add include search path (repeatable)
        \\  -D <M>[=V]                     Define preprocessor macro (repeatable)
        \\  -E                             Preprocess only; emit expanded IDL
        \\
        \\  --default-extensibility <ext>  Default extensibility when no @extensibility present
        \\                                 (default: final, per IDL4 §8.3.1) (all backends)
        \\  --generate-zzdds-wrappers      Emit typed zzdds topic wrappers (Zig, C, C++)
        \\  --generate-interfaces          Emit binding layer for IDL interface declarations (all backends)
        \\  --no-typeobject-support        Suppress TypeObject/TypeIdentifier (all backends, currently Zig only)
        \\  --no-typesupport               Suppress CDR serialize/deserialize (all backends)
        \\  --profile <full|xrce>          Target profile: full (default) or xrce (all backends)
        \\                                   xrce: XCDR1 only, @final types, bounded sequences/strings
        \\  --single-file                  Single monolithic output file — default (all backends)
        \\  --split-files                  One file per type (C/C++/Java) or per module (Zig) (all backends)
        \\  --type-prefix <pfx>            Prefix for all generated type names (all backends)
        \\
        \\  --c-export-macro <macro>       DLL export macro for function declarations (C, C++ backends)
        \\  --c-extern-c                   Wrap header in extern "C" {{}} (C backend)
        \\  --c-header-guard-prefix <pfx>  Prefix for include guard macros (C, C++ backends)
        \\  --c-pragma-once                Use #pragma once instead of #ifndef guards (C, C++ backends)
        \\  --cpp-namespace <ns>           Wrap all output in an outer namespace (C++ backend)
        \\  --cpp-generate-impl            Emit concrete Impl classes and listener bridges (C++ backend)
        \\  --cpp-pmr-containers           Use std::pmr::vector/string/wstring for sequence/string/wstring
        \\                                 fields instead of std::vector/std::string/std::wstring, so they
        \\                                 route through zidl::setCppAllocator (C++ backend)
        \\
        \\  --java-jni-library <name>      System.loadLibrary() name for JNI impls (Java backend)
        \\  --java-package <pkg>           Package prefix, e.g. com.example (Java backend)
        \\
        \\  --zig-generate-c-api           Emit pub export fn callconv(.c) wrappers for C free-function API (Zig backend)
        \\  --zig-pl-cdr                   Generate PL_CDR functions for @mutable types (Zig backend)
        \\  --zig-version <0.16.0|0.15.1>  Output compatibility target (Zig backend)
        \\
        \\  -h, --help                     Show this help
        \\  -v, --version                  Show version
        \\
    , .{});
    try w.flush();
}
