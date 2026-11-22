//! Compile-time checks of a provider's `@static` operations and
//! `@constructor`s. Zig interfaces generated with `--zig-provider-module`
//! call these for each one, so a provider function that is missing, or whose
//! signature differs from the IDL's, is a compile error naming the operation,
//! whether or not anything calls it. See zidl's
//! docs/design/c-abi-provider.md.

const std = @import("std");

/// Checks that `Provider.statics(I)` declares `name` as a function taking
/// exactly `params` and returning exactly `R`.
pub fn checkStatic(comptime Provider: type, comptime I: type, comptime name: []const u8, comptime params: []const type, comptime R: type) void {
    if (!@hasDecl(Provider, "statics"))
        @compileError("the zidl provider must declare `pub fn statics(comptime I: type) type` for " ++ @typeName(I) ++ "'s @static operations");
    checkFn(Provider.statics(I), "statics(" ++ @typeName(I) ++ ")." ++ name, params, R, .exact);
}

/// Checks that `Provider.constructors(I)` declares `name` as a function
/// taking a `std.mem.Allocator` and then exactly `params`, and returning an
/// error union of `I` with any error set.
pub fn checkConstructor(comptime Provider: type, comptime I: type, comptime name: []const u8, comptime params: []const type) void {
    if (!@hasDecl(Provider, "constructors"))
        @compileError("the zidl provider must declare `pub fn constructors(comptime I: type) type` for " ++ @typeName(I) ++ "'s @constructors");
    checkFn(Provider.constructors(I), "constructors(" ++ @typeName(I) ++ ")." ++ name, &([_]type{std.mem.Allocator} ++ params[0..params.len].*), I, .error_union);
}

fn checkFn(comptime Decls: type, comptime what: []const u8, comptime params: []const type, comptime R: type, comptime result: enum { exact, error_union }) void {
    const expected = signature(params, if (result == .error_union) "!" ++ @typeName(R) else @typeName(R));
    const name = what[std.mem.lastIndexOfScalar(u8, what, '.').? + 1 ..];
    if (!@hasDecl(Decls, name))
        @compileError("the zidl provider's " ++ what ++ " is missing; expected " ++ expected);
    const F = @TypeOf(@field(Decls, name));
    const info = switch (@typeInfo(F)) {
        .@"fn" => |f| f,
        else => @compileError("the zidl provider's " ++ what ++ " is a " ++ @typeName(F) ++ ", not a function; expected " ++ expected),
    };
    const bad = "the zidl provider's " ++ what ++ " is " ++ found(info) ++ "; expected " ++ expected;
    if (info.is_generic or info.attrs.varargs or info.param_types.len != params.len) @compileError(bad);
    for (info.param_types, params) |T, P| {
        if (T != P) @compileError(bad);
    }
    const Ret = info.return_type orelse @compileError(bad);
    switch (result) {
        .exact => if (Ret != R) @compileError(bad),
        .error_union => switch (@typeInfo(Ret)) {
            .error_union => |eu| if (eu.payload != R) @compileError(bad),
            else => @compileError(bad),
        },
    }
}

/// `fn (A, B) R`, spelled from its parts.
fn signature(comptime params: []const type, comptime ret: []const u8) []const u8 {
    var s: []const u8 = "fn (";
    for (params, 0..) |P, i| s = s ++ (if (i == 0) "" else ", ") ++ @typeName(P);
    return s ++ ") " ++ ret;
}

/// A provider function's signature as `signature` spells it, an error union
/// as `!T` so an inferred error set does not spell out its own derivation.
fn found(comptime info: std.builtin.Type.Fn) []const u8 {
    if (info.is_generic) return "generic";
    var params: []const type = &.{};
    for (info.param_types) |T| params = params ++ [_]type{T orelse return "generic"};
    const Ret = info.return_type orelse return "generic";
    const ret = switch (@typeInfo(Ret)) {
        .error_union => |eu| "!" ++ @typeName(eu.payload),
        else => @typeName(Ret),
    };
    return signature(params, ret);
}

test "checkStatic and checkConstructor accept matching signatures" {
    const I = struct { x: u8 };
    const Provider = struct {
        pub fn statics(comptime T: type) type {
            if (T != I) @compileError("no statics");
            return struct {
                pub fn get_instance() I {
                    return .{ .x = 1 };
                }
                pub fn is_set(on: bool, n: i32) bool {
                    return on and n > 0;
                }
            };
        }
        pub fn constructors(comptime T: type) type {
            if (T != I) @compileError("no constructors");
            return struct {
                pub fn create(alloc: std.mem.Allocator) !I {
                    _ = alloc;
                    return .{ .x = 2 };
                }
                pub fn create_with(alloc: std.mem.Allocator, cfg: *const I) error{Nope}!I {
                    _ = alloc;
                    return cfg.*;
                }
            };
        }
    };
    comptime {
        checkStatic(Provider, I, "get_instance", &.{}, I);
        checkStatic(Provider, I, "is_set", &.{ bool, i32 }, bool);
        checkConstructor(Provider, I, "create", &.{});
        checkConstructor(Provider, I, "create_with", &.{*const I});
    }
}
