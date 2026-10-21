//! Experimental, middleware-neutral wire typesupport ABI. No OS loader here.
const std = @import("std");
const rt = @import("zidl_rt");
// The C header is the single source of truth for ABI layout.
pub const c = @import("zidl_typesupport_c");
pub const Bytes = c.ZidlTsBytes;
pub const Identifier = c.ZidlTsIdentifier;
pub const Object = c.ZidlTsObject;
pub const Type = c.ZidlTsType;
pub const Library = c.ZidlTsLibrary;
pub const abi_major = c.ZIDL_TS_ABI_MAJOR;
pub const ok = c.ZIDL_TS_OK;
pub const invalid_data = c.ZIDL_TS_INVALID_DATA;
pub const unsupported = c.ZIDL_TS_UNSUPPORTED;
pub const invalid_argument = c.ZIDL_TS_INVALID_ARGUMENT;
pub fn bytes(value: []const u8) Bytes {
    return .{ .data = value.ptr, .size = value.len };
}

pub fn query(library: *const Library, major: u32, out: [*c][*c]const Library) u32 {
    if (out == null) return invalid_argument;
    out.* = null;
    if (major != abi_major) return c.ZIDL_TS_ABI_MISMATCH;
    out.* = library;
    return ok;
}

/// Reject non-final representation identifiers, nonzero options and padded/trailing
/// bytes. This prototype accepts exact DDS sample bytes, not RTPS submessage padding.
pub fn reader(data: [*c]const u8, size: u64) !rt.CdrReader {
    if (data == null or size < 4 or size > std.math.maxInt(usize)) return error.InvalidData;
    const input = data[0..@intCast(size)];
    if (input[0] != 0 or input[2] != 0 or input[3] != 0) return error.UnsupportedRepresentation;
    switch (input[1]) {
        0, 1, 6, 7 => {},
        else => return error.UnsupportedRepresentation,
    }
    return rt.CdrReader.init(input);
}
pub fn status(err: anyerror) u32 {
    return if (err == error.UnsupportedRepresentation) unsupported else invalid_data;
}

/// Generated validators walk bounds without allocating. Key callbacks then decode
/// only the deliberately bounded prototype types using a zero-capacity allocator.
pub fn operations(comptime T: type, comptime keyed: bool, comptime walk: anytype, comptime walk_key: anytype) type {
    if (@sizeOf(T) > 65536) @compileError("TypesupportLibraryNativeValueExceedsPrototypeLimit");
    return struct {
        pub fn validate(data: [*c]const u8, size: u64) callconv(.c) u32 {
            var r = reader(data, size) catch |err| return status(err);
            walk(&r) catch |err| return status(err);
            return if (r.pos == size) ok else invalid_data;
        }
        pub fn keyHash(data: [*c]const u8, size: u64, out: [*c][16]u8) callconv(.c) u32 {
            return hash(data, size, out, false);
        }
        pub fn keyOnlyHash(data: [*c]const u8, size: u64, out: [*c][16]u8) callconv(.c) u32 {
            return hash(data, size, out, true);
        }
        fn hash(data: [*c]const u8, size: u64, out: [*c][16]u8, comptime key_only: bool) u32 {
            if (out == null) return invalid_argument;
            var check = reader(data, size) catch |err| return status(err);
            if (key_only) {
                walk_key(&check) catch |err| return status(err);
            } else {
                walk(&check) catch |err| return status(err);
            }
            if (check.pos != size) return invalid_data;
            if (!keyed) {
                out.* = @splat(0);
                return ok;
            }
            var r = reader(data, size) catch unreachable;
            var storage: [0]u8 = .{};
            var fba = std.heap.FixedBufferAllocator.init(&storage);
            var value: T = .{};
            if (key_only) T.deserializeKeyInto(&value, &r, fba.allocator()) catch return invalid_data else T.deserializeInto(&value, &r, fba.allocator()) catch return invalid_data;
            out.* = T.computeKeyHash(&value);
            return ok;
        }
    };
}

/// Structural/hash checks for trusted local generated providers, not a TypeObject
/// parser or an executable-code sandbox. Host policy limits bound enumeration.
pub fn checkLibrary(lib: *const Library) !void {
    if (lib.descriptor_size < @sizeOf(Library) or lib.abi_major != abi_major or lib.abi_minor != 0 or lib.required_features != 0)
        return error.IncompatibleLibrary;
    if (lib.type_count == 0 or lib.type_count > 4096 or lib.object_count == 0 or lib.object_count > 16384 or lib.types == null or lib.objects == null)
        return error.InvalidLibrary;
    const objects = lib.objects[0..@intCast(lib.object_count)];
    var total: u64 = 0;
    for (objects, 0..) |object, i| {
        if (object.descriptor_size < @sizeOf(Object) or object.identifier.value[0] != 0xf1 or object.cdr.data == null or object.cdr.size < 10 or object.cdr.size > 1024 * 1024 or object.dependency_count > lib.object_count or (object.dependency_count != 0 and object.dependencies == null))
            return error.InvalidMetadata;
        total += object.cdr.size;
        if (total > 64 * 1024 * 1024) return error.MetadataLimitExceeded;
        const encoded = object.cdr.data[0..@intCast(object.cdr.size)];
        if (!std.mem.eql(u8, encoded[0..4], &.{ 0, 7, 0, 0 })) return error.InvalidMetadata;
        var digest: [16]u8 = undefined;
        std.crypto.hash.Md5.hash(encoded[4..], &digest, .{});
        if (!std.mem.eql(u8, object.identifier.value[1..], digest[0..14])) return error.InvalidMetadataHash;
        for (objects[0..i]) |other| if (std.mem.eql(u8, &object.identifier.value, &other.identifier.value))
            return error.DuplicateMetadataIdentifier;
        if (object.dependency_count != 0) for (object.dependencies[0..@intCast(object.dependency_count)], 0..) |dep, d| {
            var found = false;
            for (objects) |candidate| if (std.mem.eql(u8, &dep.value, &candidate.identifier.value)) {
                found = true;
                break;
            };
            if (!found) return error.MissingDependency;
            for (object.dependencies[0..d]) |earlier| if (std.mem.eql(u8, &dep.value, &earlier.value)) return error.DuplicateDependency;
        };
    }
    const types = lib.types[0..@intCast(lib.type_count)];
    for (types, 0..) |entry, i| {
        if (entry.descriptor_size < @sizeOf(Type) or entry.name.data == null or entry.name.size == 0 or entry.name.size > 4096 or entry.keyed > 1 or entry.representations == 0 or entry.representations & ~@as(u32, 3) != 0 or entry.validate == null or entry.key_hash == null or entry.key_only_hash == null)
            return error.InvalidType;
        const name = entry.name.data[0..@intCast(entry.name.size)];
        if (std.mem.indexOfScalar(u8, name, 0) != null or !std.unicode.utf8ValidateSlice(name)) return error.InvalidType;
        var found = false;
        for (objects) |object| if (std.mem.eql(u8, &object.identifier.value, &entry.minimal_identifier.value)) {
            found = true;
            break;
        };
        if (!found) return error.MissingDependency;
        for (types[0..i]) |other| if (std.mem.eql(u8, name, other.name.data[0..@intCast(other.name.size)])) return error.DuplicateExport;
    }
}
