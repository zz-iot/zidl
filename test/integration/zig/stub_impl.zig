// Concrete stub implementation of the generated Greeter vtable.
// Records the last call and a call counter; no real DDS logic.

const std = @import("std");
const types = @import("types");

pub const GreeterStub = struct {
    count: i32 = 0,
    last_name: []const u8 = "",

    pub fn asGreeter(self: *GreeterStub) types.Greeter {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable = types.Greeter.Vtable{
        .greet = greet,
        .reset = reset,
        .get_count = get_count,
        .deinit = deinit,
    };

    // Vtable slots now use [*:0]const u8 (C-ABI) for strings.
    fn greet(ptr: *anyopaque, name: [*:0]const u8) [*:0]const u8 {
        const self: *GreeterStub = @ptrCast(@alignCast(ptr));
        self.last_name = std.mem.span(name);
        self.count += 1;
        return "hello";
    }

    fn reset(ptr: *anyopaque) void {
        const self: *GreeterStub = @ptrCast(@alignCast(ptr));
        self.count = 0;
    }

    fn get_count(ptr: *anyopaque) i32 {
        const self: *GreeterStub = @ptrCast(@alignCast(ptr));
        return self.count;
    }

    fn deinit(_: *anyopaque) void {}
};
