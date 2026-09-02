// Compiles --generate-zzdds-wrappers output for real (against
// fake_middleware.zig's synthetic "dds module adapter contract"
// implementation), not just substring-matching the generated text --
// closing the gap flagged in zidl PR #40 review: the getFieldFromCdr fix's
// own regression tests (in src/backend/zig.zig) only check generated
// source strings, so they could pass even if Zig still rejected the
// generated code outright. `zig build test` compiling this file eagerly
// analyzes every declaration in `fixture.zig` (proven true for this Zig
// version: an unreferenced struct method with a genuine compile error still
// fails the build), so IntOnly/OnlyComplex below don't need every method
// exercised to catch a bug like the one this guards against -- but a couple
// of real round-trips are exercised anyway for actual behavioral
// confidence, not just "it type-checks".

const std = @import("std");
const testing = std.testing;
const zidl_rt = @import("zidl_rt");
const fixture = @import("fixture");
const mw = @import("zzdds");

test "getFieldFromCdr: IntOnly (no string_like member -- scratch discarded, field not)" {
    var buf = std.ArrayListUnmanaged(u8).empty;
    defer buf.deinit(testing.allocator);
    var writer = zidl_rt.CdrWriter(.xcdr2).init(&buf, testing.allocator);
    try writer.writeEncapHeaderDelimited();
    try fixture.IntOnly.serialize(&writer, .{ .seq_num = 7 });

    var scratch: [1]u8 = undefined; // never written into -- no string_like member
    const alloc: std.mem.Allocator = testing.allocator;
    const got = fixture.IntOnly.getFieldFromCdr(@ptrCast(@constCast(&alloc)), buf.items, "seq_num", &scratch);
    try testing.expect(got != null);
    try testing.expectEqual(@as(i64, 7), got.?.int);
    try testing.expect(fixture.IntOnly.getFieldFromCdr(@ptrCast(@constCast(&alloc)), buf.items, "nonexistent", &scratch) == null);
}

test "getFieldFromCdr: OnlyComplex (no filterable member -- both field and scratch discarded)" {
    var buf = std.ArrayListUnmanaged(u8).empty;
    defer buf.deinit(testing.allocator);
    var writer = zidl_rt.CdrWriter(.xcdr2).init(&buf, testing.allocator);
    try writer.writeEncapHeaderDelimited();
    try fixture.OnlyComplex.serialize(&writer, .{ .values = .{}, .nested = .{ .z = 1 } });

    var scratch: [1]u8 = undefined;
    const alloc: std.mem.Allocator = testing.allocator;
    // No member is filterable -- every lookup returns null, but the point
    // is that this compiles and runs at all (the bug this guards against
    // was a Zig compile error, not a wrong runtime result).
    try testing.expect(fixture.OnlyComplex.getFieldFromCdr(@ptrCast(@constCast(&alloc)), buf.items, "values", &scratch) == null);
}

test "wrapper contract: Reading write/take round-trip against the fake middleware" {
    const dw = fixture.ReadingDataWriter.init(.{}, testing.allocator);
    try dw.write(.{ .sensor_id = 1, .label = "temp", .value = 42 }, 0);

    const dr = fixture.ReadingDataReader.init(.{}, testing.allocator);
    var data: fixture.Reading = .{};
    var sample_info: mw.DDS.SampleInfo = undefined;
    // fake_middleware's takeRaw always returns null -- there's no real
    // transport behind it -- so this just exercises that the call compiles
    // and returns the documented "no sample" result, not a real delivery.
    const got = try dr.take_next_sample(&data, &sample_info);
    try testing.expect(!got);
}

test "deserializeSelected: extracts a non-leading @key, skips large non-key members" {
    var buf = std.ArrayListUnmanaged(u8).empty;
    defer buf.deinit(testing.allocator);
    var writer = zidl_rt.CdrWriter(.xcdr2).init(&buf, testing.allocator);
    try writer.writeEncapHeaderDelimited();
    const big = [_]u8{0xAB} ** 4096;
    try fixture.KeyedBlob.serialize(&writer, .{
        .prefix = "a-prefix-that-should-be-skipped",
        .id = 0x0BADF00D,
        .blob = .{ ._buffer = @constCast(&big), ._length = big.len, ._maximum = big.len, ._release = false },
    });

    var reader = try zidl_rt.CdrReader.init(buf.items);
    var out: fixture.KeyedBlob = undefined;
    try fixture.KeyedBlob.deserializeSelected(&reader, fixture.KeyedBlob.KEY_FIELD_MASK, &out, testing.allocator);
    defer fixture.KeyedBlob.deinitSelected(&out, fixture.KeyedBlob.KEY_FIELD_MASK, testing.allocator);

    try testing.expectEqual(@as(i32, 0x0BADF00D), out.id); // the @key, decoded
    try testing.expectEqual(@as(usize, 0), out.prefix.len); // preceding non-key: skipped, stayed zeroed
    try testing.expectEqual(@as(u32, 0), out.blob._length); // trailing non-key: skipped
    // KEY_FIELD_MASK is exactly bit 1 (id is the 2nd member).
    try testing.expectEqual(@as(fixture.KeyedBlob.FieldMask, 1 << 1), fixture.KeyedBlob.KEY_FIELD_MASK);
}

test "getFieldFromCdr: decodes only the referenced field, skips the rest" {
    var buf = std.ArrayListUnmanaged(u8).empty;
    defer buf.deinit(testing.allocator);
    var writer = zidl_rt.CdrWriter(.xcdr2).init(&buf, testing.allocator);
    try writer.writeEncapHeaderDelimited();
    const big = [_]u8{0xCD} ** 4096;
    try fixture.KeyedBlob.serialize(&writer, .{
        .prefix = "unused-prefix",
        .id = 12345,
        .blob = .{ ._buffer = @constCast(&big), ._length = big.len, ._maximum = big.len, ._release = false },
    });

    var alloc: std.mem.Allocator = testing.allocator;
    var scratch: [64]u8 = undefined;
    // "id" -> decodes id, skips the 4 KB blob and the string
    const v = fixture.KeyedBlob.getFieldFromCdr(@ptrCast(&alloc), buf.items, "id", &scratch);
    try testing.expect(v != null);
    try testing.expectEqual(@as(i64, 12345), v.?.int);
    // an unknown field name -> null, no crash
    try testing.expect(fixture.KeyedBlob.getFieldFromCdr(@ptrCast(&alloc), buf.items, "nope", &scratch) == null);
}
