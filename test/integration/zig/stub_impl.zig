// Concrete stub implementation of the generated Greeter vtable.
// Records the last call and a call counter; no real DDS logic.

const std = @import("std");
const types = @import("types");
const zidl_rt = @import("zidl_rt");

pub const GreeterStub = struct {
    count: i32 = 0,
    last_name: []const u8 = "",
    // Cached C-ABI handle: created lazily on first request, reused thereafter
    // (so repeated calls return the same handle — identity-stable), freed in
    // `deinit`. See zig.zig's `get_c_abi_handle` Vtable slot doc comment.
    c_abi_handle: ?*anyopaque = null,

    pub fn asGreeter(self: *GreeterStub) types.Greeter {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable = types.Greeter.Vtable{
        .greet = greet,
        .reset = reset,
        .get_count = get_count,
        .deinit = deinit,
        .get_c_abi_handle = get_c_abi_handle,
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

    fn deinit(ptr: *anyopaque) void {
        const self: *GreeterStub = @ptrCast(@alignCast(ptr));
        if (self.c_abi_handle) |h| zidl_rt.freeEntityBox(std.testing.allocator, h);
    }

    fn get_c_abi_handle(ptr: *anyopaque) *anyopaque {
        const self: *GreeterStub = @ptrCast(@alignCast(ptr));
        if (self.c_abi_handle == null) {
            self.c_abi_handle = zidl_rt.boxEntity(std.testing.allocator, ptr, &vtable) catch @panic("oom");
        }
        return self.c_abi_handle.?;
    }
};
