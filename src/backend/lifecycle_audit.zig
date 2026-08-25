//! Lifecycle classification sweep — queue item 4 of
//! zzdds/docs/design/generated-class-lifecycle-design.md ("build the IR-level
//! classification validation pass ... and use it to drive the full
//! dcps.idl/zzdds.idl sweep").
//!
//! Walks a fully-built `ir.Spec` and classifies every operation output/return
//! type that structurally looks like it owns heap memory (a sequence, an
//! unbounded string/wstring, or a named type wrapping one of those) per the
//! design doc's classification rule:
//!
//!   - Category 1 (entity-mediated): some operation on the *same* interface
//!     accepts this exact type as an `in_`/`inout` parameter — a "give it
//!     back" op exists, so release should route through the entity's own
//!     allocator (`_self.vtable.get_allocator(_self.ptr)` in zig.zig's
//!     C-ABI codegen), never a bare, context-free `{Type}_free()`.
//!   - Category 2 (standalone/app-owned): no such op exists. This is the
//!     *normal*, expected outcome for most qualifying types, not an error —
//!     release goes through the process-wide `zidlCAbiFreeAllocator()`.
//!
//! This is a **diagnostic/reporting pass, not a hard-enforcing one** — see
//! the design doc's Decisions log for why: "no matching return-op" is a
//! definitive Category 2 classification by the rule's own text, so a pass
//! that hard-errors on "unclassifiable" would essentially never fire. The
//! one thing genuinely worth a WARNING (not a hard error, to avoid false
//! positives from legitimate type reuse) is a type that looks
//! Category-1-shaped on one interface, i.e. some operation produces it with
//! no matching return-op AND some *other* operation on the same interface
//! separately takes it as an in_/inout param — a shape that could mean "this
//! output should have been released via that other op" as easily as it could
//! mean "two unrelated uses of a reusable sequence typedef", so it's flagged
//! for human judgement, never auto-resolved either way.
//!
//! Hard enforcement of the allocator-safety half of the classification rule
//! (a generated free must never hardcode a specific allocator) is a
//! *separate*, already-real mechanism: `zig.zig`'s own "allocator hygiene"
//! `zig build test` unit test (search that name in that file). This pass
//! closes the other half — was the release *shape* itself a deliberate
//! choice — by producing a human-reviewable table, not a build gate.

const std = @import("std");
const ir = @import("../ir/root.zig");

pub const Category = enum {
    entity_mediated, // Category 1
    standalone, // Category 2
};

pub const Finding = struct {
    interface_name: []const u8,
    /// The operation whose output/return introduced this type into the sweep.
    producing_op: []const u8,
    type_name: []const u8,
    category: Category,
    /// For entity_mediated: the op that takes it back in_/inout.
    /// For standalone: empty.
    matching_op: []const u8,
    /// Set when the same type is *also* consumed in_/inout by some op that
    /// ISN'T obviously "the" return op for this producing op — see the
    /// module doc comment. Human-review flag, not an error.
    ambiguous: bool,
};

/// Best-effort structural "does this type own heap memory that a generated
/// free would need to release" check. Deliberately conservative/approximate
/// — this is a diagnostic sweep, not codegen, so it doesn't need to match
/// zig.zig's exact emission-gating logic byte for byte, only to catch every
/// type shape that has actually mattered in this bug class so far (plain
/// sequences, unbounded strings, and named typedefs/structs wrapping them).
pub fn typeOwnsHeapMemory(tr: ir.TypeRef) bool {
    return switch (tr) {
        .sequence => true, // always a heap `_buffer` in this codebase's C-ABI mapping, bound or not
        .string => |bound| bound == null,
        .wstring => |bound| bound == null,
        .named => |td| switch (td) {
            .typedef => |t| typeOwnsHeapMemory(t.type_ref),
            .struct_ => true, // conservative: a struct may or may not own heap fields; treat as "maybe" for this sweep
            else => false,
        },
        else => false,
    };
}

/// Identity used to match "the same type" across two parameter/return
/// positions. Only named types (typedefs/structs/etc.) get a stable,
/// comparable identity — every qualifying buffer-owning type in this IDL is
/// a named typedef in practice (ConditionSeq, OctetSeq, ReaderSeq, ...), so
/// this covers the real cases; an inline `sequence<T>` with no typedef name
/// has no stable identity to match against and is skipped (returns null).
fn typeIdentity(tr: ir.TypeRef) ?[]const u8 {
    return switch (tr) {
        .named => |td| ir.typeDeclQualifiedName(td),
        else => null,
    };
}

fn typeRefEqlByIdentity(a: ir.TypeRef, b: ir.TypeRef) bool {
    const ia = typeIdentity(a) orelse return false;
    const ib = typeIdentity(b) orelse return false;
    return std.mem.eql(u8, ia, ib);
}

/// Collect every `ir.Interface` reachable in `spec`, including inside nested
/// modules, in a caller-provided list.
fn collectInterfaces(items: []const ir.ModuleItem, out: *std.ArrayListUnmanaged(*const ir.Interface), alloc: std.mem.Allocator) !void {
    for (items) |item| {
        switch (item) {
            .module => |m| try collectInterfaces(m.items, out, alloc),
            .type_decl => |td| switch (td) {
                .interface => |iface| {
                    if (!ir.isCallbackInterface(iface)) try out.append(alloc, iface);
                },
                else => {},
            },
            .const_ => {},
        }
    }
}

/// Does `iface` have any operation taking `tr` as an `in_`/`inout` parameter?
/// Returns `.{ name, looks_like_a_release_op }` for the best candidate, or
/// null if none exists. Two passes, preferring precision over "first
/// found": several real interfaces (the `take_raw`/`read_raw`/
/// `take_next_instance_raw`/`read_next_instance_raw`/`return_loan_raw`
/// family) share the *same* `inout`-typed parameters across every sibling
/// op by IDL convention (each needs to accept a possibly-non-empty prior
/// buffer to overwrite/release), not just the one genuine release op — a
/// naive "first other op with this type in/inout" match would pick an
/// arbitrary sibling instead of the real release op. Pass 1 only considers
/// candidates whose name suggests a release/return operation (matches this
/// codebase's own `return_*` naming convention for every real loan-style
/// release op); pass 2 falls back to any other candidate if pass 1 finds
/// none, but the result is always reported as needing human review in that
/// case (see `recordFinding`) — never silently trusted.
fn findReturnOp(iface: *const ir.Interface, tr: ir.TypeRef, producing_op_name: []const u8) ?struct { name: []const u8, looks_like_release: bool } {
    var fallback: ?[]const u8 = null;
    for (iface.operations) |op| {
        if (std.mem.eql(u8, op.name, producing_op_name)) continue;
        for (op.params) |p| {
            // Only `inout` signals "hand this back for release/reuse" (the
            // OMG C-mapping convention every real release op in this IDL
            // uses — return_loan_raw, WaitSet::wait/get_conditions). A
            // plain `in_` parameter is ordinary configuration input (e.g.
            // `set_qos(in DomainParticipantQos qos)`), not a release
            // signal, even though it happens to share a type name with a
            // getter's `inout` output param (`get_qos(inout ... qos)`) —
            // confirmed a real false-positive source before narrowing to
            // `inout`-only (every QoS getter/setter pair in dcps.idl
            // matched this shape and is genuinely Category 2, not 1).
            if (p.mode != .inout) continue;
            if (!typeRefEqlByIdentity(p.type_ref, tr)) continue;
            if (std.ascii.indexOfIgnoreCase(op.name, "return") != null) {
                return .{ .name = op.name, .looks_like_release = true };
            }
            if (fallback == null) fallback = op.name;
        }
    }
    if (fallback) |f| return .{ .name = f, .looks_like_release = false };
    return null;
}

/// Run the sweep over `spec`, returning every finding. Caller owns the
/// returned slice (allocated via `alloc`); findings' string fields borrow
/// from the IR arena and are valid as long as `spec` is.
pub fn sweep(alloc: std.mem.Allocator, spec: *const ir.Spec) ![]Finding {
    var interfaces: std.ArrayListUnmanaged(*const ir.Interface) = .empty;
    defer interfaces.deinit(alloc);
    try collectInterfaces(spec.items, &interfaces, alloc);

    var findings: std.ArrayListUnmanaged(Finding) = .empty;
    errdefer findings.deinit(alloc);

    for (interfaces.items) |iface| {
        for (iface.operations) |op| {
            // Return type.
            if (op.return_type) |rt| {
                if (typeOwnsHeapMemory(rt)) try recordFinding(alloc, &findings, iface, op, rt);
            }
            // out/inout params.
            for (op.params) |p| {
                if (p.mode == .in_) continue;
                if (!typeOwnsHeapMemory(p.type_ref)) continue;
                try recordFinding(alloc, &findings, iface, op, p.type_ref);
            }
        }
    }

    return findings.toOwnedSlice(alloc);
}

fn recordFinding(
    alloc: std.mem.Allocator,
    findings: *std.ArrayListUnmanaged(Finding),
    iface: *const ir.Interface,
    op: ir.Operation,
    tr: ir.TypeRef,
) !void {
    const type_name = typeIdentity(tr) orelse "<unnamed>";
    if (findReturnOp(iface, tr, op.name)) |m| {
        try findings.append(alloc, .{
            .interface_name = iface.name,
            .producing_op = op.name,
            .type_name = type_name,
            .category = .entity_mediated,
            .matching_op = m.name,
            .ambiguous = !m.looks_like_release,
        });
        return;
    }
    try findings.append(alloc, .{
        .interface_name = iface.name,
        .producing_op = op.name,
        .type_name = type_name,
        .category = .standalone,
        .matching_op = "",
        .ambiguous = false,
    });
}

/// Print `findings` as a Markdown table to `w`, matching the design doc
/// Appendix's column shape.
pub fn printMarkdownTable(w: *std.Io.Writer, findings: []const Finding) !void {
    try w.writeAll("| Interface | Producing op | Type | Category | Matching return-op | Flag |\n");
    try w.writeAll("|---|---|---|---|---|---|\n");
    for (findings) |f| {
        try w.print("| `{s}` | `{s}` | `{s}` | {s} | {s} | {s} |\n", .{
            f.interface_name,
            f.producing_op,
            f.type_name,
            switch (f.category) {
                .entity_mediated => "1 (entity-mediated)",
                .standalone => "2 (standalone)",
            },
            if (f.matching_op.len > 0) f.matching_op else "—",
            if (f.ambiguous) "**review**" else "",
        });
    }
}

// ── Tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;
const parser_mod = @import("../parser.zig");
const semantic_mod = @import("../semantic/root.zig");

const SweepResult = struct {
    ir_spec: ir.Spec,
    findings: []Finding,

    fn deinit(self: *SweepResult) void {
        testing.allocator.free(self.findings);
        self.ir_spec.deinit();
    }
};

/// `Finding`'s string fields borrow from the returned IR arena (see that
/// type's doc comment) -- callers must keep the result (and call
/// `.deinit()`) alive for as long as they read `.findings`, not deinit the
/// IR spec first. (A first draft of this helper deinit'd `ir_spec` before
/// returning `findings` alone -- a real, caught-by-running-it
/// use-after-free/segfault, not a hypothetical: every findings string field
/// pointed into the just-freed arena.)
fn testSweep(source: []const u8) !SweepResult {
    const alloc = testing.allocator;
    var ast_arena = std.heap.ArenaAllocator.init(alloc);
    defer ast_arena.deinit();
    var p = parser_mod.Parser.init(source, ast_arena.allocator());
    const spec = try p.parseSpecification();
    var az = try semantic_mod.Analyzer.init(alloc);
    defer az.deinit();
    try az.analyze(&spec);
    var ir_spec = try ir.build(alloc, &spec, az.global_scope, &.{});
    errdefer ir_spec.deinit();
    const findings = try sweep(alloc, &ir_spec);
    return .{ .ir_spec = ir_spec, .findings = findings };
}

fn findFinding(findings: []const Finding, iface: []const u8, op: []const u8, type_name: []const u8) ?Finding {
    for (findings) |f| {
        if (std.mem.eql(u8, f.interface_name, iface) and std.mem.eql(u8, f.producing_op, op) and std.mem.eql(u8, f.type_name, type_name)) return f;
    }
    return null;
}

test "lifecycle_audit: clean return_loan-shaped pair classifies Category 1, no review flag" {
    // Mirrors DataReader::take_raw/return_loan_raw's real shape: two ops
    // share an `inout` sequence typedef, one name-marked as the release op.
    var result = try testSweep(
        \\interface Foo {
        \\    void take(inout octet_seq payload);
        \\    void return_loan(inout octet_seq payload);
        \\};
        \\typedef sequence<octet> octet_seq;
    );
    defer result.deinit();
    const f = findFinding(result.findings, "Foo", "take", "octet_seq") orelse return error.TestExpectedFinding;
    try testing.expectEqual(Category.entity_mediated, f.category);
    try testing.expectEqualStrings("return_loan", f.matching_op);
    try testing.expect(!f.ambiguous);
}

test "lifecycle_audit: no matching op classifies Category 2 (the normal case)" {
    var result = try testSweep(
        \\interface Foo {
        \\    void get_status(inout octet_seq status);
        \\};
        \\typedef sequence<octet> octet_seq;
    );
    defer result.deinit();
    const f = findFinding(result.findings, "Foo", "get_status", "octet_seq") orelse return error.TestExpectedFinding;
    try testing.expectEqual(Category.standalone, f.category);
    try testing.expect(!f.ambiguous);
}

test "lifecycle_audit: a plain `in_` setter sharing a type name with a getter is not mistaken for a release op" {
    // Regression guard for a real false-positive found this session against
    // the actual dcps.idl: get_qos(inout Qos)/set_qos(in Qos) look
    // superficially similar to take/return_loan but set_qos's `in_` mode
    // means "configure with this value", not "hand this back for release" —
    // must classify Category 2, not 1.
    var result = try testSweep(
        \\interface Foo {
        \\    void get_qos(inout my_qos qos);
        \\    void set_qos(in my_qos qos);
        \\};
        \\struct my_qos { long x; };
    );
    defer result.deinit();
    const f = findFinding(result.findings, "Foo", "get_qos", "my_qos") orelse return error.TestExpectedFinding;
    try testing.expectEqual(Category.standalone, f.category);
}

test "lifecycle_audit: two unrelated ops sharing a reused type are flagged for review, not silently trusted either way" {
    // Mirrors DomainParticipant::get_discovered_participants/
    // get_discovered_topics both producing InstanceHandleSeq -- a real,
    // legitimate type-reuse ambiguity found this session against the real
    // dcps.idl, with no "return"-shaped name to disambiguate.
    var result = try testSweep(
        \\interface Foo {
        \\    void get_a(inout handle_seq h);
        \\    void get_b(inout handle_seq h);
        \\};
        \\typedef sequence<octet> handle_seq;
    );
    defer result.deinit();
    const fa = findFinding(result.findings, "Foo", "get_a", "handle_seq") orelse return error.TestExpectedFinding;
    try testing.expectEqual(Category.entity_mediated, fa.category);
    try testing.expect(fa.ambiguous);
}

test "lifecycle_audit: a by-value return type is swept too, not just out/inout params" {
    // Coverage for the exact shape of this session's Part B bug
    // (emitCApiOp's by-value mirror-struct return path): no real
    // dcps.idl/zzdds.idl operation returns a heap-owning struct by value
    // today (see generated-class-lifecycle-design.md, Decisions log item
    // 6), so there's nothing in the real sweep to exercise this path against
    // -- confirm it's still real and correctly wired for the day one exists.
    var result = try testSweep(
        \\interface Foo {
        \\    octet_seq get_thing();
        \\};
        \\typedef sequence<octet> octet_seq;
    );
    defer result.deinit();
    const f = findFinding(result.findings, "Foo", "get_thing", "octet_seq") orelse return error.TestExpectedFinding;
    try testing.expectEqual(Category.standalone, f.category);
}
