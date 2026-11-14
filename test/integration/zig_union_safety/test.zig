// Compile-and-run regression test for the union deinit/error-safety fix.
//
// Before the fix, generated union `deserializeInto` wrote the new
// discriminant into `out._d` before decoding the case payload into `out._u`.
// A truncated/malformed payload could then fail mid-case-decode, leaving
// `out._d` pointing at a heap-owning case whose `out._u` storage was still
// Zig `undefined` (unions have no per-field safe default the way struct
// members do). The `errdefer out.deinit(allocator)` added in the same PR
// would then free that undefined memory — a real invalid-free / memory
// corruption, not just a leak. The fix: decode the discriminant into a local
// and only commit `out._d` once the whole function is about to succeed, so a
// mid-decode failure never leaves `out._d` pointing at a case `out._u`
// doesn't actually hold.

const std = @import("std");
const testing = std.testing;
const zidl_cdr = @import("zidl_cdr");
const fixture = @import("fixture");

fn truncatedEncoding(comptime T: type, value: T, chop: usize) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(testing.allocator);
    var writer = zidl_cdr.CdrWriter(.xcdr2).init(&buf, testing.allocator);
    try writer.writeEncapHeader();
    try T.serialize(&writer, value);
    const full = try buf.toOwnedSlice(testing.allocator);
    errdefer testing.allocator.free(full);
    try testing.expect(full.len > chop);
    const truncated = try testing.allocator.dupe(u8, full[0 .. full.len - chop]);
    testing.allocator.free(full);
    return truncated;
}

test "FinalStrUnion: truncated string case leaves _d at its safe default, deinit is a no-op" {
    const payload = try truncatedEncoding(fixture.FinalStrUnion, .{ ._d = 99, ._u = .{ .s = "hello world" } }, 4);
    defer testing.allocator.free(payload);

    var reader = try zidl_cdr.CdrReader.init(payload);
    var out: fixture.FinalStrUnion = .{};
    try testing.expectError(
        error.EndOfStream,
        fixture.FinalStrUnion.deserializeInto(&out, &reader, testing.allocator),
    );

    // The discriminant must still be the untouched default (0 => the
    // non-owning `i` case) -- not 99, which would point `deinit()` at the
    // `s` case whose `_u` storage was never actually written.
    try testing.expectEqual(@as(i32, 0), out._d);
    out.deinit(testing.allocator); // must not crash (testing.allocator would catch an invalid free)
}

test "MutableStrUnion: truncated string case leaves _d at its safe default, deinit is a no-op" {
    const payload = try truncatedEncoding(fixture.MutableStrUnion, .{ ._d = 1, ._u = .{ .s = "hello world" } }, 4);
    defer testing.allocator.free(payload);

    var reader = try zidl_cdr.CdrReader.init(payload);
    var out: fixture.MutableStrUnion = .{};
    try testing.expectError(
        error.EndOfStream,
        fixture.MutableStrUnion.deserializeInto(&out, &reader, testing.allocator),
    );

    try testing.expectEqual(@as(i32, 0), out._d);
    out.deinit(testing.allocator);
}

test "MutableStrUnion: a payload published earlier in the EMHEADER loop survives a later, unrelated read failure" {
    // Regression for a second review round: committing `out._d` only once,
    // after the whole EMHEADER loop finishes, left it stale relative to an
    // `out._u` an *earlier* iteration already published -- so a *later*
    // iteration's failure would leak that payload (or, worse, free it
    // through whatever case the stale discriminant happened to select). The
    // fix commits `out._d` atomically with `out._u`, inside the same case
    // arm, so it never lags behind a real publish.
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    var writer = zidl_cdr.CdrWriter(.xcdr2).init(&buf, testing.allocator);
    try writer.writeEncapHeader();
    try fixture.MutableStrUnion.serialize(&writer, .{ ._d = 1, ._u = .{ .s = "hello world" } });

    // Corrupt the DHEADER (the 4 bytes right after the 4-byte encap header)
    // to claim 4 more bytes of payload than actually follow, then append 4
    // bytes that decode as an EMHEADER with `lc == 7`, whose NEXTINT (the
    // start of the member value) is missing, so reading it runs off the end of
    // the input. This forces a THIRD loop iteration to fail *after* the real discriminant
    // and case-value EMHEADERs (iterations 1-2) already ran and published to
    // out._d/out._u.
    var declared: u32 = std.mem.readInt(u32, buf.items[4..8], .little);
    declared += 4;
    std.mem.writeInt(u32, buf.items[4..8], declared, .little);
    try buf.appendSlice(testing.allocator, &[_]u8{ 0xFF, 0xFF, 0xFF, 0xFF });

    var reader = try zidl_cdr.CdrReader.init(buf.items);
    var out: fixture.MutableStrUnion = .{};
    try testing.expectError(
        error.EndOfStream,
        fixture.MutableStrUnion.deserializeInto(&out, &reader, testing.allocator),
    );

    // `deserializeInto`'s own internal `errdefer out.deinit(allocator)` has
    // already run by the time it returns the error -- so `out._u.s` is
    // already freed and reset to `""` (that's the self-cleaning contract
    // from the first review round), which is why this test does NOT assert
    // its content. What it does prove: `out._d` still reads 1 (`deinit()`
    // never resets the discriminant, only the payload it owns) -- if the
    // pre-fix bug were present, `out._d` would have stayed at its stale
    // pre-loop default (0) when the internal errdefer fired, so `deinit()`
    // would have cleaned the non-owning `i` arm instead and silently leaked
    // "hello world". `testing.allocator` is a leak-checking allocator: this
    // whole test fails at teardown if that leak happens, without needing to
    // inspect `out._u.s` directly.
    try testing.expectEqual(@as(i32, 1), out._d);
    out.deinit(testing.allocator); // idempotent no-op -- proves it, doesn't need to
}

test "FinalStrUnion: successful decode of the string case still round-trips and deinits cleanly" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    var writer = zidl_cdr.CdrWriter(.xcdr2).init(&buf, testing.allocator);
    try writer.writeEncapHeader();
    try fixture.FinalStrUnion.serialize(&writer, .{ ._d = 99, ._u = .{ .s = "hello world" } });

    var reader = try zidl_cdr.CdrReader.init(buf.items);
    var out: fixture.FinalStrUnion = .{};
    try fixture.FinalStrUnion.deserializeInto(&out, &reader, testing.allocator);
    defer out.deinit(testing.allocator);

    try testing.expectEqual(@as(i32, 99), out._d);
    try testing.expectEqualStrings("hello world", out._u.s);
}

// ── Default discriminant selects a heap-owning case ────────────────────────
//
// Regression for a third review round: `FinalStrUnion`/`MutableStrUnion`
// above both have the heap-owning case OFF the discriminant's default value
// (0 selects the non-owning `i`), so a failure before anything was published
// left `out._d == 0` selecting a case that needs no cleanup either way --
// never actually exercising what `deinit()` does with a still-`undefined`
// `out._u`. `OwningDefaultUnion`/`MutableOwningDefaultUnion` put the
// heap-owning case ON the default (0), so a genuinely early failure -- before
// the discriminant (or even the DHEADER) has been read even once -- would,
// without the fix, free that undefined memory.

const encap_header_only = [_]u8{ 0x00, 0x03, 0x00, 0x00 };

test "OwningDefaultUnion: a failure before the discriminant is ever read leaves the untouched default owning arm alone" {
    var reader = try zidl_cdr.CdrReader.init(&encap_header_only);
    var out: fixture.OwningDefaultUnion = .{};
    try testing.expectError(
        error.EndOfStream,
        fixture.OwningDefaultUnion.deserializeInto(&out, &reader, testing.allocator),
    );

    out.deinit(testing.allocator);
    // out._d is still its untouched default (0, the owning `s` case).
    // Before the fix, the internal errdefer fired unconditionally here and
    // followed out._d into the owning arm, freeing undefined memory -- this
    // assertion is reached at all only because that no longer happens.
    try testing.expectEqual(@as(i32, 0), out._d);
}

test "MutableOwningDefaultUnion: a failure before the DHEADER is ever read leaves the untouched default owning arm alone" {
    var reader = try zidl_cdr.CdrReader.init(&encap_header_only);
    var out: fixture.MutableOwningDefaultUnion = .{};
    try testing.expectError(
        error.EndOfStream,
        fixture.MutableOwningDefaultUnion.deserializeInto(&out, &reader, testing.allocator),
    );

    try testing.expectEqual(@as(i32, 0), out._d);
    out.deinit(testing.allocator);
}

test "OwningDefaultUnion: successful decode of the default owning case still round-trips and deinits cleanly" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    var writer = zidl_cdr.CdrWriter(.xcdr2).init(&buf, testing.allocator);
    try writer.writeEncapHeader();
    try fixture.OwningDefaultUnion.serialize(&writer, .{ ._d = 0, ._u = .{ .s = "hello world" } });

    var reader = try zidl_cdr.CdrReader.init(buf.items);
    var out: fixture.OwningDefaultUnion = .{};
    try fixture.OwningDefaultUnion.deserializeInto(&out, &reader, testing.allocator);
    defer out.deinit(testing.allocator);

    try testing.expectEqual(@as(i32, 0), out._d);
    try testing.expectEqualStrings("hello world", out._u.s);
}

// Independent PL_CDR2 witnesses: DHEADER + discriminator (ID 0, LC 2),
// then the selected member. The discriminator must-understand bit is set.
// The default string uses LC 4 + NEXTINT (6 bytes:
// a four-byte length and "A\\0"). These arrays do not use runtime framing.
const string_default_le = [_]u8{
    0, 0x0b, 0, 0,    22,  0, 0, 0,
    0, 0,    0, 0xa0, 99,  0, 0, 0,
    2, 0,    0, 0x40, 6,   0, 0, 0,
    2, 0,    0, 0,    'A', 0,
};
const string_default_be = [_]u8{
    0,    0x0a, 0, 0, 0,   0, 0, 22,
    0xa0, 0,    0, 0, 0,   0, 0, 99,
    0x40, 0,    0, 2, 0,   0, 0, 6,
    0,    0,    0, 2, 'A', 0,
};

fn checkStringDefault(comptime T: type, member_id: u32) !void {
    var le = string_default_le;
    var be = string_default_be;
    std.mem.writeInt(u32, le[16..20], 0x40000000 | member_id, .little);
    std.mem.writeInt(u32, be[16..20], 0x40000000 | member_id, .big);
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    var writer = zidl_cdr.CdrWriter(.xcdr2).init(&buf, testing.allocator);
    try writer.writeEncapHeaderMutable();
    try T.serialize(&writer, .{ ._d = 99, ._u = .{ .s = "A" } });
    try testing.expectEqualSlices(u8, &le, buf.items);
    for ([_][]const u8{ &le, &be }) |bytes| {
        var reader = try zidl_cdr.CdrReader.init(bytes);
        var out: T = .{};
        try T.deserializeInto(&out, &reader, testing.allocator);
        try testing.expectEqual(@as(i32, 99), out._d);
        try testing.expectEqualStrings("A", out._u.s);
        try testing.expectEqual(bytes.len, reader.pos);
        out.deinit(testing.allocator);
        out.deinit(testing.allocator);
        for (4..bytes.len) |cut| {
            var truncated = try zidl_cdr.CdrReader.init(bytes[0..cut]);
            var partial: T = .{};
            try testing.expectError(error.EndOfStream, T.deserializeInto(&partial, &truncated, testing.allocator));
            // Discriminant default 0 selects the non-owning arm until publish.
            partial.deinit(testing.allocator);
        }
        const Run = struct {
            fn decode(allocator: std.mem.Allocator, input: []const u8) !void {
                var r = try zidl_cdr.CdrReader.init(input);
                var value: T = .{};
                try T.deserializeInto(&value, &r, allocator);
                value.deinit(allocator);
            }
        };
        try testing.checkAllAllocationFailures(testing.allocator, Run.decode, .{bytes});
    }
}

test "mutable owning defaults use sequential, explicit and hashed IDs in PL_CDR2" {
    try checkStringDefault(fixture.MutableStrUnion, 2);
    try checkStringDefault(fixture.ExplicitDefault, 99);
    try checkStringDefault(fixture.SequentialDefault, 18);
    // XTypes 1.3 section 7.2.2.4.4.4.5 gives MD5("color") prefix
    // 70 dd a5 df; member ID is little-endian prefix masked to 28 bits.
    try checkStringDefault(fixture.HashedDefault, 0x0fa5dd70);
}

test "mutable fixed default declared first uses its own member ID" {
    inline for (.{ .{ @as(i32, 99), @as(u32, 1) }, .{ @as(i32, 7), @as(u32, 2) } }) |case| {
        var expected = [_]u8{
            0, 0x0b, 0, 0,    16, 0, 0, 0,
            0, 0,    0, 0xa0, 0,  0, 0, 0,
            0, 0,    0, 0x20, 42, 0, 0, 0,
        };
        std.mem.writeInt(i32, expected[12..16], case[0], .little);
        std.mem.writeInt(u32, expected[16..20], 0x20000000 | case[1], .little);
        const value: fixture.DefaultFirst = if (case[0] == 7)
            .{ ._d = 7, ._u = .{ .known = 42 } }
        else
            .{ ._d = 99, ._u = .{ .fallback = 42 } };
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(testing.allocator);
        var writer = zidl_cdr.CdrWriter(.xcdr2).init(&buf, testing.allocator);
        try writer.writeEncapHeaderMutable();
        try fixture.DefaultFirst.serialize(&writer, value);
        try testing.expectEqualSlices(u8, &expected, buf.items);
        var reader = try zidl_cdr.CdrReader.init(&expected);
        var out: fixture.DefaultFirst = .{};
        try fixture.DefaultFirst.deserializeInto(&out, &reader, testing.allocator);
        try testing.expectEqual(value._d, out._d);
        try testing.expectEqual(@as(i32, 42), if (case[0] == 7) out._u.known else out._u.fallback);
    }
}

fn parameterList(order: std.builtin.Endian, members: []const []const u8) ![]u8 {
    var bytes: std.ArrayList(u8) = .empty;
    errdefer bytes.deinit(testing.allocator);
    try bytes.appendSlice(testing.allocator, &.{ 0, if (order == .little) @as(u8, 0x0b) else 0x0a, 0, 0, 0, 0, 0, 0 });
    for (members) |member| {
        while (bytes.items.len % 4 != 0) try bytes.append(testing.allocator, 0);
        try bytes.appendSlice(testing.allocator, member);
    }
    std.mem.writeInt(u32, bytes.items[4..8], @intCast(bytes.items.len - 8), order);
    return bytes.toOwnedSlice(testing.allocator);
}

fn expectUnionError(order: std.builtin.Endian, expected: anyerror, members: []const []const u8) !void {
    const bytes = try parameterList(order, members);
    defer testing.allocator.free(bytes);
    var reader = try zidl_cdr.CdrReader.init(bytes);
    var out: fixture.MutableStrUnion = .{};
    try testing.expectError(expected, fixture.MutableStrUnion.deserializeInto(&out, &reader, testing.allocator));
    try testing.expect(reader.pos <= bytes.len);
    // Error paths restore the enclosing reader extent and clean published data.
    try testing.expectEqual(bytes.len, reader.data.len);
    out.deinit(testing.allocator);
}

test "mutable union rejects missing, reordered, duplicate and mismatched known members" {
    inline for (.{ std.builtin.Endian.little, std.builtin.Endian.big }) |order| {
        const reference = if (order == .little) &string_default_le else &string_default_be;
        const disc = reference[8..16];
        const value = reference[16..];
        var wrong = value[0..14].*;
        std.mem.writeInt(u32, wrong[0..4], 0x40000001, order); // known integer arm, string discriminator
        var unknown = [_]u8{ 0, 0, 0, 0, 0x7e };
        std.mem.writeInt(u32, unknown[0..4], 50, order); // unknown, LC 0, no MU
        var mu = unknown;
        std.mem.writeInt(u32, mu[0..4], 0x80000032, order);
        try expectUnionError(order, error.MissingDiscriminator, &.{});
        try expectUnionError(order, error.InvalidUnionOrder, &.{ value, disc });
        try expectUnionError(order, error.DuplicateMember, &.{ disc, disc, value });
        try expectUnionError(order, error.DuplicateMember, &.{ disc, value, disc });
        try expectUnionError(order, error.DuplicateMember, &.{ disc, value, value });
        try expectUnionError(order, error.InvalidUnionMember, &.{ disc, &wrong });
        try expectUnionError(order, error.UnknownMustUnderstand, &.{ disc, &mu });
        try expectUnionError(order, error.UnknownMustUnderstand, &.{ disc, value, &mu });
        // Known-member lengths are exact, rather than silently skipping garbage.
        var long_disc: [12]u8 = @splat(0);
        @memcpy(long_disc[0..8], disc);
        std.mem.writeInt(u32, long_disc[0..4], 0xb0000000, order); // LC 3: eight-byte discriminator
        try expectUnionError(order, error.InvalidMemberLength, &.{ &long_disc, value });
        var long_value: [15]u8 = @splat(0);
        @memcpy(long_value[0..14], value);
        std.mem.writeInt(u32, long_value[4..8], 7, order);
        try expectUnionError(order, error.InvalidMemberLength, &.{ disc, &long_value });
    }
}

test "mutable union skips unknown non-MU IDs without decoding them as the default arm" {
    inline for (.{ std.builtin.Endian.little, std.builtin.Endian.big }) |order| {
        const reference = if (order == .little) &string_default_le else &string_default_be;
        var unknown = [_]u8{ 0, 0, 0, 0, 0x7e };
        std.mem.writeInt(u32, unknown[0..4], 50, order);
        inline for (.{
            .{ &unknown, reference[8..16], reference[16..] },
            .{ reference[8..16], &unknown, reference[16..] },
            .{ reference[8..16], reference[16..], &unknown },
        }) |parts| {
            const bytes = try parameterList(order, &.{ parts[0], parts[1], parts[2] });
            defer testing.allocator.free(bytes);
            var reader = try zidl_cdr.CdrReader.init(bytes);
            var out: fixture.MutableStrUnion = .{};
            try fixture.MutableStrUnion.deserializeInto(&out, &reader, testing.allocator);
            defer out.deinit(testing.allocator);
            try testing.expectEqual(@as(i32, 99), out._d);
            try testing.expectEqualStrings("A", out._u.s);
            try testing.expectEqual(bytes.len, reader.pos);
        }
        // No declared/default arm matches 99: the discriminator alone is valid.
        const bytes = try parameterList(order, &.{ reference[8..16], &unknown });
        defer testing.allocator.free(bytes);
        var reader = try zidl_cdr.CdrReader.init(bytes);
        var out: fixture.NoDefault = .{};
        try fixture.NoDefault.deserializeInto(&out, &reader, testing.allocator);
        try testing.expectEqual(@as(i32, 99), out._d);
        out.deinit(testing.allocator);
    }
}

test "mutable union accepts LC5 strings and keeps nested frame limits" {
    inline for (.{ std.builtin.Endian.little, std.builtin.Endian.big }) |order| {
        const reference = if (order == .little) &string_default_le else &string_default_be;
        var compact: [10]u8 = undefined;
        std.mem.writeInt(u32, compact[0..4], 0x50000002, order);
        @memcpy(compact[4..10], reference[24..30]); // LC5 peeks the string length as NEXTINT
        const bytes = try parameterList(order, &.{ reference[8..16], &compact });
        defer testing.allocator.free(bytes);
        var data: std.ArrayList(u8) = .empty;
        defer data.deinit(testing.allocator);
        try data.appendSlice(testing.allocator, bytes);
        try data.appendNTimes(testing.allocator, 0x55, 16); // enclosing object's next field
        var reader = try zidl_cdr.CdrReader.init(data.items);
        var out: fixture.MutableStrUnion = .{};
        try fixture.MutableStrUnion.deserializeInto(&out, &reader, testing.allocator);
        try testing.expectEqualStrings("A", out._u.s);
        try testing.expectEqual(bytes.len, reader.pos);
        try testing.expectEqual(data.items.len, reader.data.len);
        out.deinit(testing.allocator);
        // The string must not consume enclosing bytes when its length is corrupt.
        std.mem.writeInt(u32, data.items[20..24], 12, order);
        reader = try zidl_cdr.CdrReader.init(data.items);
        out = .{};
        try testing.expectError(error.EndOfStream, fixture.MutableStrUnion.deserializeInto(&out, &reader, testing.allocator));
        try testing.expect(reader.pos <= bytes.len);
        try testing.expectEqual(data.items.len, reader.data.len);
        out.deinit(testing.allocator);
    }
}

test "fresh unions initialize the default-selected owning payload recursively" {
    inline for (.{ fixture.OwningDefaultUnion, fixture.MutableOwningDefaultUnion, fixture.DefaultOwning, fixture.NestedOwner, fixture.ArrayOwner, fixture.EnumOwner }) |T| {
        var value: T = .{};
        var copy = try value.clone(testing.allocator);
        copy.deinit(testing.allocator);
        value.deinit(testing.allocator);
        value.deinit(testing.allocator);
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(testing.allocator);
        var writer = zidl_cdr.CdrWriter(.xcdr2).init(&buf, testing.allocator);
        try writer.writeEncapHeader();
        try T.serialize(&writer, value);
    }
}

test "omitted locally selected mutable payload takes a safe default" {
    inline for (.{ std.builtin.Endian.little, std.builtin.Endian.big }) |order| {
        const reference = if (order == .little) &string_default_le else &string_default_be;
        const bytes = try parameterList(order, &.{reference[8..16]});
        defer testing.allocator.free(bytes);
        var reader = try zidl_cdr.CdrReader.init(bytes);
        var value: fixture.MutableStrUnion = .{};
        try fixture.MutableStrUnion.deserializeInto(&value, &reader, testing.allocator);
        try testing.expectEqual(@as(i32, 99), value._d);
        try testing.expectEqualStrings("", value._u.s);
        value.deinit(testing.allocator);
    }
}

test "optional nested owning union failure cleanup starts from initialized payloads" {
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(testing.allocator);
    var writer = zidl_cdr.CdrWriter(.xcdr2).init(&bytes, testing.allocator);
    try writer.writeEncapHeader();
    try fixture.OptionalOwner.serialize(&writer, .{ .value = .{} });
    for (4..bytes.items.len) |cut| {
        var reader = try zidl_cdr.CdrReader.init(bytes.items[0..cut]);
        var value: fixture.OptionalOwner = .{};
        try testing.expectError(error.EndOfStream, fixture.OptionalOwner.deserializeInto(&value, &reader, testing.allocator));
        value.deinit(testing.allocator);
    }
}

test "exhaustive boolean union has a valid fresh payload" {
    const value: fixture.ExhaustiveBool = .{};
    try testing.expectEqual(false, value._d);
    try testing.expectEqual(@as(i32, 0), value._u.no);
}

test "exhaustive boolean union aliases round-trip ordinary codecs" {
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(testing.allocator);
    var writer = zidl_cdr.CdrWriter(.xcdr2).init(&bytes, testing.allocator);
    try writer.writeEncapHeader();
    try fixture.ExhaustiveBool.serialize(&writer, .{ ._d = true, ._u = .{ .yes = 17 } });
    var reader = try zidl_cdr.CdrReader.init(bytes.items);
    var result: fixture.ExhaustiveBool = .{};
    try fixture.ExhaustiveBool.deserializeInto(&result, &reader, testing.allocator);
    try testing.expect(result._d);
    try testing.expectEqual(@as(i32, 17), result._u.yes);
}

test "grouped exhaustive boolean labels admit both discriminator values" {
    inline for (.{ false, true }) |disc| {
        var bytes: std.ArrayList(u8) = .empty;
        defer bytes.deinit(testing.allocator);
        var writer = zidl_cdr.CdrWriter(.xcdr2).init(&bytes, testing.allocator);
        try writer.writeEncapHeader();
        try fixture.GroupedBool.serialize(&writer, .{ ._d = disc, ._u = .{ .value = 17 } });
        var reader = try zidl_cdr.CdrReader.init(bytes.items);
        var result: fixture.GroupedBool = .{};
        try fixture.GroupedBool.deserializeInto(&result, &reader, testing.allocator);
        try testing.expectEqual(disc, result._d);
        try testing.expectEqual(@as(i32, 17), result._u.value);
    }
}

test "grouped owning boolean payloads support clone and cleanup" {
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(testing.allocator);
    var writer = zidl_cdr.CdrWriter(.xcdr2).init(&bytes, testing.allocator);
    try writer.writeEncapHeader();
    try fixture.GroupedBoolOwned.serialize(&writer, .{ ._d = true, ._u = .{ .text = "owned" } });
    var reader = try zidl_cdr.CdrReader.init(bytes.items);
    var result: fixture.GroupedBoolOwned = .{};
    try fixture.GroupedBoolOwned.deserializeInto(&result, &reader, testing.allocator);
    defer result.deinit(testing.allocator);
    var copy = try result.clone(testing.allocator);
    defer copy.deinit(testing.allocator);
    try testing.expectEqualStrings("owned", copy._u.text);
    try testing.expect(copy._u.text.ptr != result._u.text.ptr);
}
