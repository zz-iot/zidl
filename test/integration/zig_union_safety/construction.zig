const std = @import("std");
const fixture = @import("fixture");

test "declarations-only boolean construction and nested owning lifecycle" {
    const value: fixture.ExhaustiveBool = .{};
    try std.testing.expect(!value._d);
    try std.testing.expectEqual(@as(i32, 0), value._u.no);
    var owner: fixture.NestedOwner = .{};
    defer owner.deinit(std.testing.allocator);
    var copy = try owner.clone(std.testing.allocator);
    defer copy.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("", copy._u.value.choices[0]._u.text);
}
