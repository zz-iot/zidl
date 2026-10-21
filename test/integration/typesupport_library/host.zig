const std = @import("std");
const ts = @import("zidl_typesupport");
const rt = @import("zidl_rt");
const expect = std.testing.expect;
const expectError = std.testing.expectError;
const Query = *const fn (u32, [*c][*c]const ts.Library) callconv(.c) u32;
fn find(lib: *const ts.Library, name: []const u8) !*const ts.Type {
    for (lib.types[0..@intCast(lib.type_count)]) |*t| {
        if (std.mem.eql(u8, name, t.name.data[0..@intCast(t.name.size)])) return t;
    }
    return error.MissingType;
}
// Real generated providers must compile and consume every array dimension, even
// before a non-leading key. Cover both final encodings and malformed extents.
fn checkArray(lib: *const ts.Library, name: []const u8, elements: usize, keyed: bool) !void {
    const descriptor = try find(lib, name);
    var wire: [41]u8 = @splat(0);
    const size = 4 + 4 * elements + @as(usize, if (keyed) 4 else 0);
    for (0..elements) |i| wire[4 + 4 * i] = @intCast(i + 1);
    if (keyed) wire[size - 4] = 42;
    var expected: [16]u8 = @splat(0);
    if (keyed) expected[3] = 42;
    for ([_]u8{ 1, 7 }) |representation| {
        wire[1] = representation;
        try expect(descriptor.validate.?(wire[0..].ptr, size) == ts.ok);
        for (0..size) |n| try expect(descriptor.validate.?(wire[0..].ptr, n) != ts.ok);
        try expect(descriptor.validate.?(wire[0..].ptr, size + 1) == ts.invalid_data);
        var hash: [16]u8 = undefined;
        try expect(descriptor.key_hash.?(wire[0..].ptr, size, &hash) == ts.ok);
        try expect(std.mem.eql(u8, &expected, &hash));
    }
}
pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(std.heap.page_allocator);
    defer std.heap.page_allocator.free(args);
    try expect(args.len == 4);
    var handles: [3]std.DynLib = undefined;
    var loaded: usize = 0;
    defer for (handles[0..loaded]) |*h| h.close();
    var libraries: [3]*const ts.Library = undefined;
    for (args[1..], 0..) |path, i| {
        handles[i] = try std.DynLib.open(path);
        loaded += 1;
        const query = handles[i].lookup(Query, "zidl_typesupport_query") orelse return error.MissingQuery;
        var descriptor: [*c]const ts.Library = null;
        try expect(query(ts.abi_major, &descriptor) == ts.ok);
        libraries[i] = descriptor;
        try ts.checkLibrary(libraries[i]);
    }
    try checkArray(libraries[0], "ProjectA::Matrix", 6, true);
    try checkArray(libraries[0], "ProjectA::Cube", 8, false);
    try checkArray(libraries[0], "ProjectA::ArrayAlias", 6, false);
    const a = try find(libraries[0], "Shared::Reading");
    const b = try find(libraries[1], "Shared::Reading");
    const different = try find(libraries[2], "Shared::Reading");
    try expect(std.mem.eql(u8, &a.minimal_identifier.value, &b.minimal_identifier.value));
    try expect(!std.mem.eql(u8, &a.minimal_identifier.value, &different.minimal_identifier.value));
    // Corrupted descriptors must fail before the host publishes a catalog.
    var lib = libraries[0].*;
    lib.abi_major = 1;
    try expectError(error.IncompatibleLibrary, ts.checkLibrary(&lib));
    lib = libraries[0].*;
    lib.required_features = 1;
    try expectError(error.IncompatibleLibrary, ts.checkLibrary(&lib));
    lib = libraries[0].*;
    lib.descriptor_size = 0;
    try expectError(error.IncompatibleLibrary, ts.checkLibrary(&lib));
    lib = libraries[0].*;
    lib.object_count = 0;
    try expectError(error.InvalidLibrary, ts.checkLibrary(&lib));
    const allocator = std.heap.page_allocator;
    const objects = try allocator.dupe(ts.Object, libraries[0].objects[0..@intCast(libraries[0].object_count)]);
    defer allocator.free(objects);
    lib = libraries[0].*;
    lib.objects = objects.ptr;
    objects[0].identifier.value[1] ^= 1;
    try expectError(error.InvalidMetadataHash, ts.checkLibrary(&lib));
    objects[0].identifier.value[1] ^= 1;
    const types = try allocator.dupe(ts.Type, libraries[0].types[0..@intCast(libraries[0].type_count)]);
    defer allocator.free(types);
    lib.types = types.ptr;
    types[1].name = types[0].name;
    try expectError(error.DuplicateExport, ts.checkLibrary(&lib));
    lib.types = libraries[0].types;
    for (objects) |*object| if (object.dependency_count != 0) {
        var missing = object.dependencies[0];
        missing.value[1] ^= 1;
        const original = object.dependencies;
        const count = object.dependency_count;
        object.dependencies = @ptrCast(&missing);
        object.dependency_count = 1;
        try expectError(error.MissingDependency, ts.checkLibrary(&lib));
        object.dependencies = original;
        object.dependency_count = count;
        break;
    };
    try ts.checkLibrary(&lib);
    // Nested fields, alias, enum and bounded collections: validate exact extent.
    const packet = try find(libraries[0], "ProjectA::Packet");
    var buffer: std.ArrayList(u8) = .empty;
    defer buffer.deinit(allocator);
    try buffer.ensureTotalCapacity(allocator, 256);
    var w = rt.CdrWriter(.xcdr2).init(&buffer, allocator);
    try w.writeEncapHeader();
    try w.writeI32(1);
    try w.writeI32(2);
    try w.writeU32(1);
    try w.writeU32(42);
    try w.writeString("ok");
    try w.writeU32(3);
    try w.writeU8(1);
    try w.writeU8(2);
    try w.writeU8(3);
    const payload = buffer.items;
    const storage = buffer.allocatedSlice();
    try expect(packet.validate.?(payload.ptr, payload.len) == ts.ok);
    for (0..payload.len) |n| try expect(packet.validate.?(payload.ptr, n) != ts.ok);
    storage[payload.len] = 0;
    try expect(packet.validate.?(storage.ptr, payload.len + 1) == ts.invalid_data);
    // String count, terminator, enum discriminant and sequence count corruption.
    const saved_string = storage[20..24].*;
    @memcpy(storage[20..24], &[_]u8{ 99, 0, 0, 0 });
    try expect(packet.validate.?(payload.ptr, payload.len) == ts.invalid_data);
    @memcpy(storage[20..24], &saved_string);
    storage[26] = 1;
    try expect(packet.validate.?(payload.ptr, payload.len) == ts.invalid_data);
    storage[26] = 0;
    storage[12] = 99;
    try expect(packet.validate.?(payload.ptr, payload.len) == ts.invalid_data);
    storage[12] = 1;
    storage[28] = 9;
    try expect(packet.validate.?(payload.ptr, payload.len) == ts.invalid_data);
    std.debug.print("Zig host: metadata integrity/closure, duplicate exports, collisions and bounded wire validation passed\n", .{});
}
