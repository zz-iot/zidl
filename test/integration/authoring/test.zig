const std = @import("std");
const rt = @import("zidl_rt");
const types = @import("authoring_types");
const testing = std.testing;
// A minimal tree fixture, not a parser: exercises the generated decoder's
// duck-typed contract independently of zzdds and any concrete syntax frontend.
const Value = union(enum) { table: Table, array: []const Node, string: []const u8, boolean: bool, integer: i64, float: f64 };
const Node = struct { value: Value, location: rt.authoring.Location = .{ .line = 7, .column = 3 } };
const Entry = struct { key: []const u8, value: Value };
const Table = struct {
    entries: std.StringArrayHashMapUnmanaged(Value) = .empty,
    location: rt.authoring.Location = .{},
    fn make(a: std.mem.Allocator, values: []const Entry) !Table {
        var result: Table = .{};
        for (values) |e| try result.entries.put(a, e.key, e.value);
        return result;
    }
    pub fn get(self: Table, key: []const u8) ?Node {
        return .{ .value = self.entries.get(key) orelse return null };
    }
};
fn decode(table: Table, a: std.mem.Allocator, diag: *rt.authoring.Diagnostic) !rt.authoring.Decoded(types.Config) {
    return types.Config.decodeToml(a, table, .{ .named_field = "name" }, diag);
}

test "generated strict records preserve false, zero, empty arrays and absence" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const table = try Table.make(arena.allocator(), &.{
        .{ .key = "enabled", .value = .{ .boolean = false } },
        .{ .key = "count", .value = .{ .integer = 0 } },
        .{ .key = "ratio", .value = .{ .float = 1.5 } },
        .{ .key = "tags", .value = .{ .array = &.{} } },
    });
    var diag: rt.authoring.Diagnostic = .{};
    var result = try decode(table, testing.allocator, &diag);
    defer result.deinit();
    try testing.expectEqual(@as(?bool, false), result.value.enabled);
    try testing.expectEqual(@as(?u16, 0), result.value.count);
    try testing.expectEqual(@as(?f32, 1.5), result.value.ratio);
    try testing.expect(result.isPresent(&.{"tags"}));
    try testing.expect(!result.isPresent(&.{"label"}));
    try testing.expectEqualStrings("default", result.value.label);
    const empty = try Table.make(arena.allocator(), &.{.{ .key = "label", .value = .{ .string = "" } }});
    var explicit = try decode(empty, testing.allocator, &diag);
    defer explicit.deinit();
    try testing.expect(explicit.isPresent(&.{"label"}));
    try testing.expectEqualStrings("", explicit.value.label);
}

test "named records, nested scalar sequences, bounded strings and fixed arrays" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const item = try Table.make(a, &.{.{ .key = "values", .value = .{ .array = &.{.{ .value = .{ .integer = 5 } }} } }});
    const names = try Table.make(a, &.{.{ .key = "a.b", .value = .{ .table = item } }});
    const root = try Table.make(a, &.{
        .{ .key = "code", .value = .{ .string = "1234" } },
        .{ .key = "items", .value = .{ .table = names } },
        .{ .key = "tags", .value = .{ .array = &.{.{ .value = .{ .string = "x" } }} } },
        .{ .key = "matrix", .value = .{ .array = &.{.{ .value = .{ .array = &.{.{ .value = .{ .integer = 9 } }} } }} } },
        .{ .key = "fixed_values", .value = .{ .array = &.{ .{ .value = .{ .integer = 1 } }, .{ .value = .{ .integer = 2 } } } } },
        .{ .key = "mode", .value = .{ .string = "SLOW" } },
    });
    var diag: rt.authoring.Diagnostic = .{};
    var result = try decode(root, testing.allocator, &diag);
    defer result.deinit();
    try testing.expectEqualStrings("1234", result.value.code.slice());
    try testing.expectEqualStrings("a.b", result.value.items.slice()[0].name);
    try testing.expectEqual(@as(i32, 5), result.value.items.slice()[0].values._buffer.?[0]);
    try testing.expectEqual(@as(i32, 9), result.value.matrix._buffer.?[0]._buffer.?[0]);
    try testing.expectEqual(@as(i32, 2), result.value.fixed_values[1]);
    try testing.expectEqualStrings("x", std.mem.span(result.value.tags._buffer.?[0]));
    try testing.expectEqual(@as(u32, 1), @backingInt(result.value.mode));
    try testing.expect(result.isPresent(&.{ "items", "a.b", "name" }));
}

test "strict errors keep diagnostic storage valid after allocation rollback" {
    const cases = [_]struct { key: []const u8, value: Value, err: anyerror }{
        .{ .key = "typo", .value = .{ .boolean = true }, .err = error.UnknownField },
        .{ .key = "enabled", .value = .{ .integer = 1 }, .err = error.TypeMismatch },
        .{ .key = "count", .value = .{ .integer = 65536 }, .err = error.OutOfRange },
        .{ .key = "code", .value = .{ .string = "12345" }, .err = error.OutOfRange },
        .{ .key = "mode", .value = .{ .string = "slow" }, .err = error.InvalidEnum },
        .{ .key = "label", .value = .{ .string = "a\x00b" }, .err = error.InvalidValue },
        .{ .key = "ratio", .value = .{ .float = std.math.inf(f64) }, .err = error.OutOfRange },
    };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    for (cases) |case| {
        const root = try Table.make(arena.allocator(), &.{.{ .key = case.key, .value = case.value }});
        var diag: rt.authoring.Diagnostic = .{};
        try testing.expectError(case.err, decode(root, testing.allocator, &diag));
        try testing.expectEqualStrings(case.key, diag.fieldPath());
        try testing.expectEqual(@as(usize, 7), diag.location.line);
    }
}

test "every strict decoder allocation failure cleans up" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const child = try Table.make(a, &.{.{ .key = "enabled", .value = .{ .boolean = false } }});
    const names = try Table.make(a, &.{.{ .key = "one", .value = .{ .table = child } }});
    const root = try Table.make(a, &.{.{ .key = "items", .value = .{ .table = names } }});
    const Run = struct {
        fn run(alloc: std.mem.Allocator, table: Table) !void {
            var diag: rt.authoring.Diagnostic = .{};
            var result = try decode(table, alloc, &diag);
            defer result.deinit();
        }
    };
    try testing.checkAllAllocationFailures(testing.allocator, Run.run, .{root});
}

test "decoder bounds collections and rejects conflicting injected names" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const item = try Table.make(a, &.{.{ .key = "name", .value = .{ .string = "conflict" } }});
    const names = try Table.make(a, &.{.{ .key = "original", .value = .{ .table = item } }});
    const root = try Table.make(a, &.{.{ .key = "items", .value = .{ .table = names } }});
    var diag: rt.authoring.Diagnostic = .{};
    try testing.expectError(error.DuplicateName, decode(root, testing.allocator, &diag));
    try testing.expectEqualStrings("items.original.name", diag.fieldPath());
    const empty: Node = .{ .value = .{ .table = .{} } };
    const too_many = try Table.make(a, &.{.{ .key = "items", .value = .{ .array = &.{ empty, empty, empty } } }});
    try testing.expectError(error.OutOfRange, decode(too_many, testing.allocator, &diag));
    try testing.expectError(error.LimitExceeded, types.Config.decodeToml(testing.allocator, root, .{ .max_elements = 0 }, &diag));
    try testing.expectError(error.LimitExceeded, types.Config.decodeToml(testing.allocator, root, .{ .max_path_bytes = 1 }, &diag));
}

test "empty generated authoring record compiles and decodes" {
    var diag: rt.authoring.Diagnostic = .{};
    var result = try types.Empty.decodeToml(testing.allocator, Table{}, .{}, &diag);
    defer result.deinit();
    try testing.expect(result.isPresent(&.{}));
}

const feature_types = @import("authoring_feature");
test "the same conditional setting applies or is recorded as skipped across builds" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const table = try Table.make(arena.allocator(), &.{.{ .key = "_xtypes", .value = .{ .boolean = false } }});
    var diag: rt.authoring.Diagnostic = .{};
    var with = try feature_types.BuildConfig.decodeToml(testing.allocator, table, .{ .conditional_members = true }, &diag);
    defer with.deinit();
    var without = try types.BuildConfig.decodeToml(testing.allocator, table, .{ .conditional_members = true }, &diag);
    defer without.deinit();
    try testing.expectEqual(@as(?bool, false), with.value.xtypes);
    try testing.expect(with.isPresent(&.{"xtypes"}));
    try testing.expectEqualStrings("_xtypes", with.presence[1].input_path[0]);
    try testing.expect(with.presence[1].conditional);
    try testing.expectEqual(@as(usize, 0), with.skipped_count);
    try testing.expectEqual(@as(u16, 17), without.value.port_base);
    try testing.expect(!without.isPresent(&.{"xtypes"}));
    try testing.expectEqual(@as(usize, 1), without.skipped_count);
    try testing.expectEqualStrings("xtypes", without.skipped[0].path[0]);
    try testing.expectEqualStrings("_xtypes", without.skipped[0].input_path[0]);
    try testing.expect(without.skipped[0].reason == .conditional_unknown);
    const required = try Table.make(arena.allocator(), &.{.{ .key = "xtypes", .value = .{ .boolean = true } }});
    try testing.expectError(error.UnknownField, types.BuildConfig.decodeToml(testing.allocator, required, .{ .conditional_members = true }, &diag));
    try testing.expectError(error.UnknownField, feature_types.BuildConfig.decodeToml(testing.allocator, table, .{}, &diag));
}

test "conditional sections do not hide nested mistakes on builds that support them" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const typo = try Table.make(a, &.{.{ .key = "enabld", .value = .{ .boolean = true } }});
    const root = try Table.make(a, &.{.{ .key = "_feature", .value = .{ .table = typo } }});
    var diag: rt.authoring.Diagnostic = .{};
    var absent = try types.BuildConfig.decodeToml(testing.allocator, root, .{ .conditional_members = true }, &diag);
    defer absent.deinit();
    try testing.expectEqual(@as(usize, 1), absent.skipped_count);
    try testing.expectError(error.UnknownField, feature_types.BuildConfig.decodeToml(testing.allocator, root, .{ .conditional_members = true }, &diag));
    try testing.expectEqualStrings("_feature.enabld", diag.fieldPath());
    const bad = try Table.make(a, &.{.{ .key = "_port_base", .value = .{ .integer = 65536 } }});
    try testing.expectError(error.OutOfRange, types.BuildConfig.decodeToml(testing.allocator, bad, .{ .conditional_members = true }, &diag));
}

test "conditional duplicates, malformed names and schema collisions are rejected" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diag: rt.authoring.Diagnostic = .{};
    for ([_]bool{ false, true }) |reverse| {
        const entries = [_]Entry{
            .{ .key = if (reverse) "_port_base" else "port_base", .value = .{ .integer = 1 } },
            .{ .key = if (reverse) "port_base" else "_port_base", .value = .{ .integer = 2 } },
        };
        const root = try Table.make(a, &entries);
        try testing.expectError(error.DuplicateSetting, types.BuildConfig.decodeToml(testing.allocator, root, .{ .conditional_members = true }, &diag));
    }
    for ([_][]const u8{ "_", "__port_base" }) |name| {
        const root = try Table.make(a, &.{.{ .key = name, .value = .{ .integer = 1 } }});
        try testing.expectError(error.InvalidConditionalName, types.BuildConfig.decodeToml(testing.allocator, root, .{ .conditional_members = true }, &diag));
    }
    const Collision = struct {
        _port_base: u16 = 1,
        pub const toml_fields: []const []const u8 = &.{"_port_base"};
        pub fn tomlSpec(comptime _: []const u8) rt.authoring.Spec {
            return .{ .kind = .scalar };
        }
    };
    try testing.expectError(error.ConditionalNameCollision, rt.authoring.decode(Collision, testing.allocator, Table{}, .{ .conditional_members = true }, &diag));
}

test "named collection entries retain leading underscores" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const names = try Table.make(a, &.{.{ .key = "_Telemetry", .value = .{ .table = .{} } }});
    const root = try Table.make(a, &.{.{ .key = "items", .value = .{ .table = names } }});
    var diag: rt.authoring.Diagnostic = .{};
    var result = try types.Config.decodeToml(testing.allocator, root, .{ .conditional_members = true, .named_field = "name" }, &diag);
    defer result.deinit();
    try testing.expectEqualStrings("_Telemetry", result.value.items.slice()[0].name);
    try testing.expectEqual(@as(usize, 0), result.skipped_count);
}

test "compatibility choices and skipped-report limits are explicit" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const root = try Table.make(arena.allocator(), &.{
        .{ .key = "future", .value = .{ .integer = 1 } },
        .{ .key = "mode", .value = .{ .string = "slow" } },
    });
    var diag: rt.authoring.Diagnostic = .{};
    var result = try types.Config.decodeToml(testing.allocator, root, .{ .unknown_fields = .ignore, .enum_matching = .ascii_case_insensitive }, &diag);
    defer result.deinit();
    try testing.expect(result.value.mode == .SLOW);
    try testing.expect(result.skipped[0].reason == .compatibility_unknown);
    var compact = try types.Config.decodeToml(testing.allocator, root, .{ .unknown_fields = .ignore, .enum_matching = .ascii_case_insensitive, .capture_skipped = false }, &diag);
    defer compact.deinit();
    try testing.expectEqual(@as(usize, 1), compact.skipped_count);
    try testing.expectEqual(@as(usize, 0), compact.skipped.len);
    try testing.expect(!compact.skipped_complete);
    try testing.expectError(error.LimitExceeded, types.Config.decodeToml(testing.allocator, root, .{ .unknown_fields = .ignore, .max_skipped = 0 }, &diag));
}

test "existing-value reads retain omissions and replace whole sequences independently" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const child = try Table.make(a, &.{ .{ .key = "name", .value = .{ .string = "child-name" } }, .{ .key = "enabled", .value = .{ .boolean = true } } });
    const start = try Table.make(a, &.{
        .{ .key = "label", .value = .{ .string = "seed" } },
        .{ .key = "enabled", .value = .{ .boolean = true } },
        .{ .key = "count", .value = .{ .integer = 42 } },
        .{ .key = "tags", .value = .{ .array = &.{.{ .value = .{ .string = "old" } }} } },
        .{ .key = "child", .value = .{ .table = child } },
    });
    var diag: rt.authoring.Diagnostic = .{};
    var base = try types.Config.decodeToml(testing.allocator, start, .{}, &diag);
    const edit_child = try Table.make(a, &.{.{ .key = "enabled", .value = .{ .boolean = false } }});
    const edit = try Table.make(a, &.{
        .{ .key = "enabled", .value = .{ .boolean = false } }, .{ .key = "count", .value = .{ .integer = 0 } },
        .{ .key = "tags", .value = .{ .array = &.{} } },       .{ .key = "child", .value = .{ .table = edit_child } },
    });
    var result = try types.Config.decodeTomlFrom(testing.allocator, base.value, edit, .{}, &diag);
    defer result.deinit();
    try testing.expectEqual(@as(?bool, true), base.value.enabled);
    base.deinit();
    try testing.expectEqualStrings("seed", result.value.label);
    try testing.expectEqual(@as(?bool, false), result.value.enabled);
    try testing.expectEqual(@as(?u16, 0), result.value.count);
    try testing.expectEqual(@as(u32, 0), result.value.tags._length);
    try testing.expectEqualStrings("child-name", result.value.child.?.name);
    try testing.expectEqual(@as(?bool, false), result.value.child.?.enabled);
    try testing.expect(!result.isPresent(&.{"label"}));
}

test "failed existing-value reads and all allocation failures preserve the starting value" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diag: rt.authoring.Diagnostic = .{};
    const start = try Table.make(a, &.{.{ .key = "label", .value = .{ .string = "original" } }});
    var base = try types.Config.decodeToml(testing.allocator, start, .{}, &diag);
    defer base.deinit();
    const bad = try Table.make(a, &.{ .{ .key = "label", .value = .{ .string = "replacement" } }, .{ .key = "count", .value = .{ .integer = -1 } } });
    try testing.expectError(error.OutOfRange, types.Config.decodeTomlFrom(testing.allocator, base.value, bad, .{}, &diag));
    try testing.expectEqualStrings("original", base.value.label);
    const edit = try Table.make(a, &.{ .{ .key = "_future", .value = .{ .table = .{} } }, .{ .key = "enabled", .value = .{ .boolean = false } } });
    const Run = struct {
        fn run(alloc: std.mem.Allocator, seed: types.Config, table: Table) !void {
            var d: rt.authoring.Diagnostic = .{};
            var result = try types.Config.decodeTomlFrom(alloc, seed, table, .{ .conditional_members = true }, &d);
            defer result.deinit();
        }
    };
    try testing.checkAllAllocationFailures(testing.allocator, Run.run, .{ base.value, edit });
    try testing.expectEqualStrings("original", base.value.label);
}

test "omitted lists are copied and newly introduced optional records use defaults" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const start = try Table.make(a, &.{.{ .key = "tags", .value = .{ .array = &.{.{ .value = .{ .string = "retained" } }} } }});
    var diag: rt.authoring.Diagnostic = .{};
    var base = try types.Config.decodeToml(testing.allocator, start, .{}, &diag);
    const child = try Table.make(a, &.{.{ .key = "enabled", .value = .{ .boolean = false } }});
    const edit = try Table.make(a, &.{.{ .key = "child", .value = .{ .table = child } }});
    var result = try types.Config.decodeTomlFrom(testing.allocator, base.value, edit, .{}, &diag);
    defer result.deinit();
    base.deinit();
    try testing.expectEqualStrings("retained", std.mem.span(result.value.tags._buffer.?[0]));
    try testing.expectEqualStrings("child-default", result.value.child.?.name);
    try testing.expectEqual(@as(?bool, false), result.value.child.?.enabled);
    try testing.expect(!result.isPresent(&.{"tags"}));
}
