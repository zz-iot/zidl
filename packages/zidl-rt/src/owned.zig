//! Type-directed release and deep copy for zidl-generated values.
//!
//! Generated types release and copy their own fields, but a sequence whose
//! elements are themselves sequences (or arrays) has element types with no
//! methods of their own: an unbounded `sequence<T>` is an anonymous C-PSM
//! `extern struct`. These helpers follow zidl's representations recursively
//! so generated code can hand such values over in one call:
//!
//!   - unbounded sequence (`_maximum`/`_length`/`_buffer`/`_release`): an owned
//!     (`_release == true`) buffer owns its elements and its storage;
//!   - `BoundedArray`: elements are stored inline;
//!   - `[*:0]const u8` / `[*:0]const u16`: a C string element of an unbounded
//!     sequence buffer, freed together with its terminator;
//!   - `[]const u8` / `[]const u16`: an unbounded string field, owned when
//!     non-empty (an empty one may point at a static `""`);
//!   - fixed arrays and optionals, element by element;
//!   - any type with its own `deinit` / `clone`, through those methods.
//!
//! Everything else (numbers, enums, POD structs) owns nothing.

const std = @import("std");

/// Element type of a generated sequence type: the unbounded C-PSM extern
/// struct or a `BoundedArray`.
pub fn SeqElem(comptime S: type) type {
    if (@hasField(S, "_buffer")) {
        return @typeInfo(@typeInfo(@FieldType(S, "_buffer")).optional.child).pointer.child;
    }
    return @typeInfo(@FieldType(S, "buf")).array.child;
}

fn isUnboundedSeq(comptime T: type) bool {
    return @typeInfo(T) == .@"struct" and @hasField(T, "_buffer") and @hasField(T, "_release");
}

fn isBoundedSeq(comptime T: type) bool {
    return @typeInfo(T) == .@"struct" and @hasField(T, "buf") and @hasField(T, "len") and @hasDecl(T, "sliceMut");
}

fn isCharUnit(comptime C: type) bool {
    return C == u8 or C == u16;
}

/// Release everything `ptr.*` owns and leave it empty, so a second call is a
/// no-op.
pub fn deinitOwned(ptr: anytype, alloc: std.mem.Allocator) void {
    const T = @typeInfo(@TypeOf(ptr)).pointer.child;
    switch (@typeInfo(T)) {
        .@"struct" => {
            if (comptime isUnboundedSeq(T)) {
                if (ptr._release) {
                    if (ptr._buffer) |buf| {
                        for (buf[0..ptr._length]) |*e| deinitOwned(e, alloc);
                        alloc.free(buf[0..ptr._maximum]);
                    }
                }
                ptr.* = .{};
            } else if (comptime isBoundedSeq(T)) {
                for (ptr.sliceMut()) |*e| deinitOwned(e, alloc);
                ptr.clearRetainingCapacity();
            } else if (comptime @hasDecl(T, "deinit")) {
                ptr.deinit(alloc);
            }
        },
        .pointer => |p| switch (p.size) {
            .slice => if (comptime isCharUnit(p.child)) {
                if (ptr.len != 0) alloc.free(ptr.*);
                ptr.* = &.{};
            },
            .many => if (comptime isCharUnit(p.child) and p.sentinel() != null) {
                const s = std.mem.span(ptr.*);
                alloc.free(s.ptr[0 .. s.len + 1]);
            },
            else => {},
        },
        .array => for (ptr) |*e| deinitOwned(e, alloc),
        .optional => if (ptr.*) |*inner| {
            deinitOwned(inner, alloc);
            ptr.* = null;
        },
        else => {},
    }
}

/// Deep-copy `value`. On failure nothing is leaked and `value` is untouched.
pub fn cloneOwned(value: anytype, alloc: std.mem.Allocator) !@TypeOf(value) {
    const T = @TypeOf(value);
    switch (@typeInfo(T)) {
        .@"struct" => {
            if (comptime isUnboundedSeq(T)) {
                const src = value._buffer orelse return .{};
                if (value._length == 0) return .{};
                const buf = try alloc.alloc(SeqElem(T), value._length);
                var n: usize = 0;
                errdefer {
                    for (buf[0..n]) |*e| deinitOwned(e, alloc);
                    alloc.free(buf);
                }
                for (src[0..value._length]) |e| {
                    buf[n] = try cloneOwned(e, alloc);
                    n += 1;
                }
                return .{ ._maximum = value._length, ._length = value._length, ._buffer = buf.ptr, ._release = true };
            } else if (comptime isBoundedSeq(T)) {
                var result: T = .{};
                errdefer deinitOwned(&result, alloc);
                for (value.slice()) |e| result.appendAssumeCapacity(try cloneOwned(e, alloc));
                return result;
            } else if (comptime @hasDecl(T, "clone")) {
                return value.clone(alloc);
            }
            return value;
        },
        .pointer => |p| switch (p.size) {
            .slice => if (comptime isCharUnit(p.child)) {
                if (value.len == 0) return value;
                return alloc.dupe(p.child, value);
            } else return value,
            .many => if (comptime isCharUnit(p.child) and p.sentinel() != null) {
                return (try alloc.dupeZ(p.child, std.mem.span(value))).ptr;
            } else return value,
            else => return value,
        },
        .array => |a| {
            var result: T = undefined;
            var n: usize = 0;
            errdefer for (result[0..n]) |*e| deinitOwned(e, alloc);
            while (n < a.len) : (n += 1) result[n] = try cloneOwned(value[n], alloc);
            return result;
        },
        .optional => {
            const inner = value orelse return null;
            return try cloneOwned(inner, alloc);
        },
        else => return value,
    }
}

const testing = std.testing;
const BoundedArray = @import("cdr.zig").BoundedArray;

const Inner = extern struct { _maximum: u32 = 0, _length: u32 = 0, _buffer: ?[*]i32 = null, _release: bool = false };
const Outer = extern struct { _maximum: u32 = 0, _length: u32 = 0, _buffer: ?[*]Inner = null, _release: bool = false };
const StrSeq = extern struct { _maximum: u32 = 0, _length: u32 = 0, _buffer: ?[*][*:0]const u8 = null, _release: bool = false };

fn ownedInner(alloc: std.mem.Allocator, items: []const i32) !Inner {
    const buf = try alloc.dupe(i32, items);
    return .{ ._maximum = @intCast(buf.len), ._length = @intCast(buf.len), ._buffer = buf.ptr, ._release = true };
}

test "owned: nested unbounded sequences clone deeply and release fully" {
    const alloc = testing.allocator;
    var outer_buf = try alloc.alloc(Inner, 2);
    outer_buf[0] = try ownedInner(alloc, &.{ 1, 2 });
    outer_buf[1] = try ownedInner(alloc, &.{3});
    var v: Outer = .{ ._maximum = 2, ._length = 2, ._buffer = outer_buf.ptr, ._release = true };
    try testing.expect(SeqElem(Outer) == Inner);

    var copy = try cloneOwned(v, alloc);
    deinitOwned(&v, alloc);
    deinitOwned(&v, alloc); // idempotent
    try testing.expectEqual(@as(i32, 3), copy._buffer.?[1]._buffer.?[0]);
    deinitOwned(&copy, alloc);
}

test "owned: borrowed sequences are neither freed nor required to be heap" {
    var items = [_]i32{ 4, 5 };
    var v: Inner = .{ ._maximum = 2, ._length = 2, ._buffer = &items, ._release = false };
    deinitOwned(&v, testing.allocator);
    try testing.expectEqual(@as(i32, 5), items[1]);
}

test "owned: string elements and bounded sequences of them" {
    const alloc = testing.allocator;
    var strs = try alloc.alloc([*:0]const u8, 1);
    strs[0] = (try alloc.dupeZ(u8, "hi")).ptr;
    var v: StrSeq = .{ ._maximum = 1, ._length = 1, ._buffer = strs.ptr, ._release = true };

    var b: BoundedArray([]const u8, 2) = .{};
    b.appendAssumeCapacity(try alloc.dupe(u8, "x"));
    b.appendAssumeCapacity("");

    var vc = try cloneOwned(v, alloc);
    var bc = try cloneOwned(b, alloc);
    deinitOwned(&v, alloc);
    deinitOwned(&b, alloc);
    try testing.expectEqualStrings("hi", std.mem.span(vc._buffer.?[0]));
    try testing.expectEqualStrings("x", bc.slice()[0]);
    deinitOwned(&vc, alloc);
    deinitOwned(&bc, alloc);
}

test "owned: clone rolls back on every allocation failure" {
    const Check = struct {
        fn run(alloc: std.mem.Allocator, src: Outer) !void {
            var copy = try cloneOwned(src, alloc);
            deinitOwned(&copy, alloc);
        }
    };
    var a = [_]i32{ 1, 2 };
    var b = [_]i32{3};
    var inner = [_]Inner{
        .{ ._maximum = 2, ._length = 2, ._buffer = &a, ._release = false },
        .{ ._maximum = 1, ._length = 1, ._buffer = &b, ._release = false },
    };
    const src: Outer = .{ ._maximum = 2, ._length = 2, ._buffer = &inner, ._release = false };
    try testing.checkAllAllocationFailures(testing.allocator, Check.run, .{src});
}
