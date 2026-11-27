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
const zidl_cdr = @import("zidl_cdr");
const fixture = @import("fixture");
const mw = @import("zzdds");

test "getFieldFromCdr: IntOnly (no string_like member -- scratch discarded, field not)" {
    var buf_fixed: [1 << 16]u8 = undefined;
    var writer = zidl_cdr.RuntimeWriter.initFixed(&buf_fixed, .xcdr2, .little);
    try writer.writeEncapHeaderDelimited();
    try fixture.IntOnly.serialize(&writer, .{ .seq_num = 7 });

    var scratch: [1]u8 = undefined; // never written into -- no string_like member
    const alloc: std.mem.Allocator = testing.allocator;
    const got = fixture.IntOnly.getFieldFromCdr(@ptrCast(@constCast(&alloc)), writer.bytes(), "seq_num", &scratch);
    try testing.expect(got != null);
    try testing.expectEqual(@as(i64, 7), got.?.int);
    try testing.expect(fixture.IntOnly.getFieldFromCdr(@ptrCast(@constCast(&alloc)), writer.bytes(), "nonexistent", &scratch) == null);
}

test "getFieldFromCdr: OnlyComplex (no filterable member -- both field and scratch discarded)" {
    var buf_fixed: [1 << 16]u8 = undefined;
    var writer = zidl_cdr.RuntimeWriter.initFixed(&buf_fixed, .xcdr2, .little);
    try writer.writeEncapHeaderDelimited();
    try fixture.OnlyComplex.serialize(&writer, .{ .values = .{}, .nested = .{ .z = 1 } });

    var scratch: [1]u8 = undefined;
    const alloc: std.mem.Allocator = testing.allocator;
    // No member is filterable -- every lookup returns null, but the point
    // is that this compiles and runs at all (the bug this guards against
    // was a Zig compile error, not a wrong runtime result).
    try testing.expect(fixture.OnlyComplex.getFieldFromCdr(@ptrCast(@constCast(&alloc)), writer.bytes(), "values", &scratch) == null);
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

test "wrapper contract: a sample without valid data and without a serialized key decodes nothing" {
    // A dispose or unregister may carry its key hash alone (DDSI-RTPS 2.5
    // 9.6.4.3), so the reader has no payload to decode.
    const key_hash_only: mw.OwnedRawSample = .{ .data = &.{}, .info = .{ .valid_data = false } };
    const dr = fixture.ReadingDataReader.init(.{}, testing.allocator);

    mw.next_raw = key_hash_only;
    var data: fixture.Reading = .{ .sensor_id = 9 };
    defer data.deinit(testing.allocator);
    var sample_info: mw.DDS.SampleInfo = undefined;
    try testing.expect(try dr.take_next_sample(&data, &sample_info));
    try testing.expect(!sample_info.valid_data);
    try testing.expectEqual(@as(u32, 9), data.sensor_id);

    mw.next_batch = &.{key_hash_only};
    var taken: std.ArrayListUnmanaged(fixture.ReadingDataReader.SampledValue) = .empty;
    defer {
        for (taken.items) |*s| s.value.deinit(testing.allocator);
        taken.deinit(testing.allocator);
    }
    _ = try dr.take(&taken, -1, 0, 0, 0);
    try testing.expectEqual(@as(usize, 1), taken.items.len);
    try testing.expect(!taken.items[0].info.valid_data);
}

test "wrapper contract: a sample that does not decode is ended failed, and a batch keeps the ones that do" {
    const dr = fixture.ReadingDataReader.init(.{}, testing.allocator);
    // Too short for its encapsulation header.
    const malformed: mw.OwnedRawSample = .{ .data = &.{0x00}, .info = .{ .valid_data = true } };
    const key_hash_only: mw.OwnedRawSample = .{ .data = &.{}, .info = .{ .valid_data = false } };
    mw.failed_samples = 0;

    mw.next_raw = malformed;
    var data: fixture.Reading = .{};
    defer data.deinit(testing.allocator);
    var sample_info: mw.DDS.SampleInfo = undefined;
    try testing.expect(std.meta.isError(dr.take_next_sample(&data, &sample_info)));
    try testing.expectEqual(@as(usize, 1), mw.failed_samples);

    var taken: std.ArrayListUnmanaged(fixture.ReadingDataReader.SampledValue) = .empty;
    defer {
        for (taken.items) |*s| s.value.deinit(testing.allocator);
        taken.deinit(testing.allocator);
    }
    mw.next_batch = &.{ malformed, key_hash_only };
    try testing.expect(try dr.take(&taken, -1, 0, 0, 0));
    try testing.expectEqual(@as(usize, 1), taken.items.len);
    try testing.expectEqual(@as(usize, 2), mw.failed_samples);
    // None decoded: the failure is returned.
    mw.next_batch = &.{malformed};
    try testing.expect(std.meta.isError(dr.take(&taken, -1, 0, 0, 0)));
    try testing.expectEqual(@as(usize, 1), taken.items.len);
}

test "deserializeSelected: extracts a non-leading @key, skips large non-key members" {
    var buf_fixed: [1 << 16]u8 = undefined;
    var writer = zidl_cdr.RuntimeWriter.initFixed(&buf_fixed, .xcdr2, .little);
    try writer.writeEncapHeaderDelimited();
    const big: [4096]u8 = @splat(0xAB);
    try fixture.KeyedBlob.serialize(&writer, .{
        .prefix = "a-prefix-that-should-be-skipped",
        .id = 0x0BADF00D,
        .blob = .{ ._buffer = @constCast(&big), ._length = big.len, ._maximum = big.len, ._release = false },
    });

    var reader = try zidl_cdr.CdrReader.init(writer.bytes());
    var out: fixture.KeyedBlob = undefined;
    try fixture.KeyedBlob.deserializeSelected(&reader, fixture.KeyedBlob.KEY_FIELD_MASK, &out, testing.allocator);
    defer fixture.KeyedBlob.deinitSelected(&out, fixture.KeyedBlob.KEY_FIELD_MASK, testing.allocator);

    try testing.expectEqual(@as(i32, 0x0BADF00D), out.id); // the @key, decoded
    try testing.expectEqual(@as(usize, 0), out.prefix.len); // preceding non-key: skipped, stayed zeroed
    try testing.expectEqual(@as(u32, 0), out.blob._length); // trailing non-key: skipped
    // KEY_FIELD_MASK is exactly bit 1 (id is the 2nd member).
    try testing.expectEqual(@as(fixture.KeyedBlob.FieldMask, 1 << 1), fixture.KeyedBlob.KEY_FIELD_MASK);
}

test "computeKeyHashFromCdr: full ALIVE payload with a non-leading @key hashes correctly" {
    // Regression for the bug computeKeyHashFromCdr/computeKeyHashFromCdrKeyOnly
    // were split to fix: the key-only decoder (deserializeKeyInto) assumes the
    // wire bytes are *just* the key fields, back to back. Fed a full sample
    // instead, it can't skip `prefix` first, so it would misread `id`'s bytes
    // out of `prefix`'s length prefix/content. computeKeyHashFromCdr uses
    // deserializeSelected(KEY_FIELD_MASK) instead, which skips non-key members
    // properly regardless of where `@key` sits.
    var buf_fixed: [1 << 16]u8 = undefined;
    var writer = zidl_cdr.RuntimeWriter.initFixed(&buf_fixed, .xcdr2, .little);
    try writer.writeEncapHeaderDelimited();
    const value = fixture.KeyedBlob{
        .prefix = "a-prefix-that-should-be-skipped",
        .id = 0x0BADF00D,
        .blob = .{},
    };
    try fixture.KeyedBlob.serialize(&writer, value);

    const alloc: std.mem.Allocator = testing.allocator;
    const got = fixture.KeyedBlob.computeKeyHashFromCdr(@ptrCast(@constCast(&alloc)), writer.bytes());
    const want = fixture.KeyedBlob.computeKeyHash(&value);
    try testing.expectEqualSlices(u8, &want, &got);
}

test "computeKeyHashFromCdrKeyOnly: genuine key-only payload with a non-leading @key hashes correctly" {
    // The key-only decoder's own contract (wire bytes are *just* the @key
    // members) is unambiguous regardless of position -- serializeKey never
    // emits non-key bytes to skip over. This is what the removed
    // @compileError used to block outright for a non-leading @key on a
    // @final struct; KeyedBlob is @appendable, but the underlying decode
    // logic is the same "no skip needed" reasoning either way.
    var buf_fixed: [1 << 16]u8 = undefined;
    var writer = zidl_cdr.RuntimeWriter.initFixed(&buf_fixed, .xcdr2, .little);
    try writer.writeEncapHeaderDelimited();
    const value = fixture.KeyedBlob{
        .prefix = "irrelevant-to-a-key-only-payload",
        .id = 0x0BADF00D,
        .blob = .{},
    };
    try fixture.KeyedBlob.serializeKey(&writer, value);

    const alloc: std.mem.Allocator = testing.allocator;
    const got = fixture.KeyedBlob.computeKeyHashFromCdrKeyOnly(@ptrCast(@constCast(&alloc)), writer.bytes());
    const want = fixture.KeyedBlob.computeKeyHash(&value);
    try testing.expectEqualSlices(u8, &want, &got);
}

test "getFieldFromCdr: decodes only the referenced field, skips the rest" {
    var buf_fixed: [1 << 16]u8 = undefined;
    var writer = zidl_cdr.RuntimeWriter.initFixed(&buf_fixed, .xcdr2, .little);
    try writer.writeEncapHeaderDelimited();
    const big: [4096]u8 = @splat(0xCD);
    try fixture.KeyedBlob.serialize(&writer, .{
        .prefix = "unused-prefix",
        .id = 12345,
        .blob = .{ ._buffer = @constCast(&big), ._length = big.len, ._maximum = big.len, ._release = false },
    });

    var alloc: std.mem.Allocator = testing.allocator;
    var scratch: [64]u8 = undefined;
    // "id" -> decodes id, skips the 4 KB blob and the string
    const v = fixture.KeyedBlob.getFieldFromCdr(@ptrCast(&alloc), writer.bytes(), "id", &scratch);
    try testing.expect(v != null);
    try testing.expectEqual(@as(i64, 12345), v.?.int);
    // an unknown field name -> null, no crash
    try testing.expect(fixture.KeyedBlob.getFieldFromCdr(@ptrCast(&alloc), writer.bytes(), "nope", &scratch) == null);
}

test "selected readers preserve enclosing limits and skip future appendable fields" {
    var bytes = [_]u8{ 0, 9, 0, 0, 8, 0, 0, 0, 42, 0, 0, 0, 99, 0, 0, 0, 7, 0, 0, 0 };
    var reader = try zidl_cdr.CdrReader.init(&bytes);
    var out: fixture.IntOnly = .{};
    try fixture.IntOnly.deserializeSelected(&reader, 1, &out, testing.allocator);
    try testing.expectEqual(@as(i32, 42), out.seq_num);
    try testing.expectEqual(@as(usize, 16), reader.pos);
    try testing.expectEqual(bytes.len, reader.data.len);
    bytes[4] = 2;
    reader = try zidl_cdr.CdrReader.init(&bytes);
    try testing.expectError(error.EndOfStream, fixture.IntOnly.deserializeSelected(&reader, 1, &out, testing.allocator));
    try testing.expect(reader.pos <= 10);
    try testing.expectEqual(bytes.len, reader.data.len);
}

test "selected nested keys read full samples while key-only reads retain projection" {
    const value: fixture.KeyOuter = .{ .inner = .{ .ignored = 99, .id = 42 }, .tail = 7 };
    const allocator = testing.allocator;
    const expected = try fixture.KeyOuter.computeKeyHashChecked(&value);
    inline for (.{ .xcdr1, .xcdr2 }) |version| {
        var bytes_fixed: [1 << 16]u8 = undefined;
        var writer = zidl_cdr.RuntimeWriter.initFixed(&bytes_fixed, version, .little);
        try writer.writeEncapHeader();
        try fixture.KeyOuter.serialize(&writer, value);
        var reader = try zidl_cdr.CdrReader.init(writer.bytes());
        var selected: fixture.KeyOuter = .{};
        try fixture.KeyOuter.deserializeSelected(&reader, fixture.KeyOuter.KEY_FIELD_MASK, &selected, allocator);
        try testing.expectEqual(@as(i32, 42), selected.inner.id);
        try testing.expectEqual(@as(i32, 7), selected.tail);
        try testing.expectEqual(writer.bytes().len, reader.pos);
        try testing.expectEqual(expected, fixture.KeyOuter.computeKeyHashFromCdr(@ptrCast(@constCast(&allocator)), writer.bytes()));

        writer = zidl_cdr.RuntimeWriter.initFixed(&bytes_fixed, version, .little);
        try writer.writeEncapHeader();
        try fixture.KeyOuter.serializeKey(&writer, value);
        reader = try zidl_cdr.CdrReader.init(writer.bytes());
        var key: fixture.KeyOuter = .{};
        try fixture.KeyOuter.deserializeKeyInto(&key, &reader, allocator);
        try testing.expectEqual(@as(i32, 0), key.inner.ignored);
        try testing.expectEqual(@as(i32, 42), key.inner.id);
        try testing.expectEqual(@as(i32, 7), key.tail);
        try testing.expectEqual(writer.bytes().len, reader.pos);
    }
}

test "a keyless topic retains its empty key while nested values can project" {
    var bytes: [16]u8 = undefined;
    var writer = zidl_cdr.RuntimeWriter.initFixed(&bytes, .xcdr2, .little);
    const value: fixture.KeylessBridge = .{ .inner = .{ .ignored = 99, .id = 42 } };
    try fixture.KeylessBridge.serializeKey(&writer, value);
    try testing.expectEqual(@as(usize, 0), writer.len);
    try testing.expectEqual(@as([16]u8, @splat(0)), fixture.KeylessBridge.computeKeyHash(&value));
    try fixture.KeylessBridge.serializeKeyValue(&writer, value);
    try testing.expectEqualSlices(u8, &.{ 42, 0, 0, 0 }, bytes[0..writer.len]);
}

test "TypeSupport.register registers every generated callback under the IDL name and owns its context" {
    const allocator = testing.allocator;
    mw.registered = null;
    try testing.expect(fixture.LabeledTypeSupport.register(.{}, null, allocator));
    const ts = mw.registered.?;
    defer if (ts.deinit) |release| release(ts.ctx);
    try testing.expectEqualStrings("Labeled", mw.registered_name[0..mw.registered_name_len]);
    try testing.expect(ts.has_key);
    try testing.expect(ts.compute_key_hash_key_only != null);
    try testing.expect(ts.get_field != null);

    const value: fixture.Labeled = .{ .name = "probe-7", .reading = 21 };
    var bytes_fixed: [1 << 16]u8 = undefined;
    var writer = zidl_cdr.RuntimeWriter.initFixed(&bytes_fixed, .xcdr2, .little);
    try writer.writeEncapHeaderDelimited();
    try fixture.Labeled.serialize(&writer, value);

    // The key hash decodes the string key with the registration's allocator.
    const want = fixture.Labeled.computeKeyHash(&value);
    try testing.expectEqualSlices(u8, &want, &ts.compute_key_hash(ts.ctx, writer.bytes()));

    const projection = ts.key_projection.?;
    const key = projection.project(projection.ctx, writer.bytes(), allocator).?;
    defer allocator.free(key);
    const expected_key = try value.keyCdr(true, allocator);
    defer allocator.free(expected_key);
    try testing.expectEqualSlices(u8, expected_key, key);
    try testing.expectEqualSlices(u8, &want, &ts.compute_key_hash_key_only.?(ts.ctx, key));

    var scratch: [16]u8 = undefined;
    try testing.expectEqual(@as(i64, 21), ts.get_field.?(ts.ctx, writer.bytes(), "reading", &scratch).?.int);
}

test "TypeSupport.register takes an explicit name and releases its context when refused" {
    mw.registered = null;
    mw.refuse_registration = true;
    defer mw.refuse_registration = false;
    // The testing allocator fails the test if the refused registration's
    // context copy is not released.
    try testing.expect(!fixture.LabeledTypeSupport.register(.{}, "custom::Labeled", testing.allocator));
    try testing.expect(mw.registered == null);

    mw.refuse_registration = false;
    try testing.expect(fixture.ReadingTypeSupport.register(.{}, "custom::Reading", testing.allocator));
    const ts = mw.registered.?;
    defer ts.deinit.?(ts.ctx);
    try testing.expectEqualStrings("custom::Reading", mw.registered_name[0..mw.registered_name_len]);

    var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    try testing.expect(!fixture.ReadingTypeSupport.register(.{}, null, failing.allocator()));
}
