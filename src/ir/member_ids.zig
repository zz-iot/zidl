//! Resolve XTypes member identity once, after all imported/local types are filled.
const std = @import("std");
const ir = @import("types.zig");

pub fn hashId(name: []const u8) u32 {
    var digest: [16]u8 = undefined;
    std.crypto.hash.Md5.hash(name, &digest, .{});
    return std.mem.readInt(u32, digest[0..4], .little) & 0x0fff_ffff;
}

pub const Resolver = struct {
    alloc: std.mem.Allocator,
    module_modes: std.StringHashMapUnmanaged(ir.AutoId) = .empty,
    states: std.AutoHashMapUnmanaged(*const ir.Struct, enum { visiting, done }) = .empty,

    pub fn deinit(self: *Resolver) void {
        self.module_modes.deinit(self.alloc);
        self.states.deinit(self.alloc);
    }

    fn mode(self: *Resolver, qname: []const u8, explicit: ?ir.AutoId) !ir.AutoId {
        if (explicit) |value| return value;
        const lower = try self.alloc.dupe(u8, qname);
        defer self.alloc.free(lower);
        for (lower) |*c| c.* = std.ascii.toLower(c.*);
        var current: []const u8 = lower;
        while (std.mem.lastIndexOf(u8, current, "::")) |sep| {
            current = current[0..sep];
            if (self.module_modes.get(current)) |value| return value;
        }
        return .sequential;
    }

    fn assign(anns: *ir.MemberAnnotations, name: []const u8, autoid: ir.AutoId, next: u64) !u32 {
        const id = if (anns.id) |explicit| explicit else if (anns.hash_id) |text|
            hashId(if (text.len == 0) name else text)
        else if (autoid == .hash)
            hashId(name)
        else if (next <= 0x0fff_bfff)
            @as(u32, @intCast(next))
        else
            return error.MemberIdOverflow;
        if (id > 0x0fff_ffff) return error.InvalidMemberId;
        if (id > 0x0fff_bfff) return error.ReservedMemberId;
        anns.resolved_id = id;
        return id;
    }

    fn insert(self: *Resolver, used: *std.AutoHashMapUnmanaged(u32, void), id: u32) !void {
        const result = try used.getOrPut(self.alloc, id);
        if (result.found_existing) return error.DuplicateMemberId;
    }

    fn inherited(self: *Resolver, base: ?ir.TypeDecl, used: *std.AutoHashMapUnmanaged(u32, void)) anyerror!?u32 {
        const td = base orelse return null;
        if (td != .struct_) return error.InvalidStructBase;
        const s = td.struct_;
        const prior = try self.inherited(s.base, used);
        for (s.members) |m| try self.insert(used, m.annotations.resolved_id.?);
        return if (s.members.len == 0) prior else s.members[s.members.len - 1].annotations.resolved_id.?;
    }

    pub fn structure(self: *Resolver, s: *ir.Struct) anyerror!void {
        if (self.states.get(s)) |state| return if (state == .done) {} else error.CyclicMemberIdInheritance;
        try self.states.put(self.alloc, s, .visiting);
        if (s.base) |base| {
            if (base != .struct_) return error.InvalidStructBase;
            try self.structure(base.struct_);
        }
        var used: std.AutoHashMapUnmanaged(u32, void) = .empty;
        defer used.deinit(self.alloc);
        const previous = try self.inherited(s.base, &used);
        var next: u64 = if (previous) |id| @as(u64, id) + 1 else 0;
        const autoid = try self.mode(s.qualified_name, s.annotations.autoid);
        // The builder owns these arena-backed member arrays.
        for (@constCast(s.members)) |*m| {
            const id = try assign(&m.annotations, m.name, autoid, next);
            try self.insert(&used, id);
            next = @as(u64, id) + 1;
        }
        try self.states.put(self.alloc, s, .done);
    }

    pub fn unionType(self: *Resolver, u: *ir.Union) !void {
        var used: std.AutoHashMapUnmanaged(u32, void) = .empty;
        defer used.deinit(self.alloc);
        try self.insert(&used, 0); // Mutable union discriminator identity.
        var next: u64 = 1;
        const autoid = try self.mode(u.qualified_name, u.annotations.autoid);
        for (@constCast(u.cases)) |*cas| {
            const id = try assign(&cas.annotations, cas.name, autoid, next);
            try self.insert(&used, id);
            next = @as(u64, id) + 1;
        }
    }
};
