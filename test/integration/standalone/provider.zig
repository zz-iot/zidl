//! A minimal provider for standalone.idl: each object is a plain heap struct
//! with a lazily boxed C handle. The counters let the tests see which
//! release ran, and how often.

const std = @import("std");
const zb = @import("zidl_bindings");
const S = @import("standalone").S;

comptime {
    zb.exportHandleRetireHook("test_retire");
    S.exportCAbi(Provider);
}

/// What the generated C API needs from this provider.
const Provider = struct {
    pub fn nil(comptime I: type) I {
        if (I == S.Condition) return Nil.condition;
        if (I == S.Engine) return Nil.engine;
        if (I == S.Guard) return Nil.guard;
        if (I == S.Holder) return Nil.holder;
        if (I == S.Registry) return Nil.registry;
        @compileError("no nil for " ++ @typeName(I));
    }
    pub fn constructors(comptime I: type) type {
        if (I == S.Engine) return EngineCtors;
        if (I == S.Guard) return GuardCtors;
        if (I == S.Holder) return HolderCtors;
        @compileError("no constructors for " ++ @typeName(I));
    }
    pub fn statics(comptime I: type) type {
        if (I == S.Registry) return RegistryStatics;
        @compileError("no statics for " ++ @typeName(I));
    }
};

pub const Stats = extern struct {
    live: i32 = 0,
    destroys: i32 = 0,
    releases: i32 = 0,
};
var stats: Stats = .{};
var stats_mu: std.atomic.Mutex = .unlocked;

fn bump(comptime field: []const u8, by: i32) void {
    while (!stats_mu.tryLock()) {}
    defer stats_mu.unlock();
    @field(stats, field) += by;
}

pub export fn test_stats() callconv(.c) Stats {
    while (!stats_mu.tryLock()) {}
    defer stats_mu.unlock();
    return stats;
}

pub export fn test_stats_reset() callconv(.c) void {
    while (!stats_mu.tryLock()) {}
    defer stats_mu.unlock();
    stats = .{};
}

// ── Nils ────────────────────────────────────────────────────────────────────

/// Each interface's nil: what a NULL handle stands for. Its operations
/// report BAD_PARAMETER, or a nil or zero result. A nil never goes out as a
/// handle, so it is never boxed.
const Nil = struct {
    const condition: S.Condition = .{ .ptr = zb.NIL_PTR, .vtable = &condition_vtable };
    const engine: S.Engine = .{ .ptr = zb.NIL_PTR, .vtable = &engine_vtable };
    const guard: S.Guard = .{ .ptr = zb.NIL_PTR, .vtable = &guard_vtable };
    const holder: S.Holder = .{ .ptr = zb.NIL_PTR, .vtable = &holder_vtable };
    const registry: S.Registry = .{ .ptr = zb.NIL_PTR, .vtable = &registry_vtable };

    const condition_vtable: S.Condition.Vtable = .{
        .get_trigger_value = falseOf,
        .deinit = noop,
        .get_c_abi_handle = neverBoxed,
        .get_allocator = allocatorOf,
    };
    const engine_vtable: S.Engine.Vtable = .{
        .destroy = badParameter,
        .release = noop,
        .get_workers = minusOne,
        .unpin = badParameter,
        .deinit = noop,
        .get_c_abi_handle = neverBoxed,
        .get_allocator = allocatorOf,
    };
    const guard_vtable: S.Guard.Vtable = .{
        .get_trigger_value = falseOf,
        .destroy = badParameter,
        .set_trigger_value = setTrigger,
        .deinit = noop,
        .get_c_abi_handle = neverBoxed,
        .get_allocator = allocatorOf,
        .as_Condition = asCondition,
    };
    const holder_vtable: S.Holder.Vtable = .{
        .destroy = badParameter,
        .hold = hold,
        .held = held,
        .deinit = noop,
        .get_c_abi_handle = neverBoxed,
        .get_allocator = allocatorOf,
    };

    const registry_vtable: S.Registry.Vtable = .{
        .get_generation = minusOne,
        .pin = setTrigger,
        .deinit = noop,
        .get_c_abi_handle = neverBoxed,
        .get_allocator = allocatorOf,
    };

    fn badParameter(_: *anyopaque) S.ReturnCode_t {
        return S.RETCODE_BAD_PARAMETER;
    }
    fn setTrigger(_: *anyopaque, _: bool) S.ReturnCode_t {
        return S.RETCODE_BAD_PARAMETER;
    }
    fn hold(_: *anyopaque, _: S.Condition) S.ReturnCode_t {
        return S.RETCODE_BAD_PARAMETER;
    }
    fn held(_: *anyopaque) S.Condition {
        return condition;
    }
    fn asCondition(_: *anyopaque) S.Condition {
        return condition;
    }
    fn falseOf(_: *anyopaque) bool {
        return false;
    }
    fn minusOne(_: *anyopaque) i32 {
        return -1;
    }
    fn noop(_: *anyopaque) void {}
    fn neverBoxed(_: *anyopaque) *anyopaque {
        @panic("a nil went out as a handle");
    }
    fn allocatorOf(_: *anyopaque) std.mem.Allocator {
        return std.heap.c_allocator;
    }
};

// ── Engine ──────────────────────────────────────────────────────────────────

const Engine = struct {
    alloc: std.mem.Allocator,
    box: ?*anyopaque = null,
    workers: i32,
    pins: i32,

    const vtable: S.Engine.Vtable = .{
        .destroy = destroy,
        .release = release,
        .get_workers = getWorkers,
        .unpin = unpin,
        .deinit = deinit,
        .get_c_abi_handle = handle,
        .get_allocator = getAllocator,
    };

    fn make(alloc: std.mem.Allocator, workers: i32, pins: i32) !S.Engine {
        const self = try alloc.create(Engine);
        self.* = .{ .alloc = alloc, .workers = workers, .pins = pins };
        bump("live", 1);
        return .{ .ptr = self, .vtable = &vtable };
    }
    fn of(p: *anyopaque) *Engine {
        return @ptrCast(@alignCast(p));
    }
    fn free(self: *Engine) void {
        if (self.box) |b| zb.freeEntityBox(self.alloc, b);
        bump("live", -1);
        self.alloc.destroy(self);
    }
    fn destroy(p: *anyopaque) S.ReturnCode_t {
        const self = of(p);
        if (self.pins > 0) return S.RETCODE_PRECONDITION_NOT_MET;
        bump("destroys", 1);
        self.free();
        return S.RETCODE_OK;
    }
    fn release(p: *anyopaque) void {
        bump("releases", 1);
        of(p).free();
    }
    fn getWorkers(p: *anyopaque) i32 {
        return of(p).workers;
    }
    fn unpin(p: *anyopaque) S.ReturnCode_t {
        const self = of(p);
        if (self.pins > 0) self.pins -= 1;
        return S.RETCODE_OK;
    }
    fn deinit(p: *anyopaque) void {
        of(p).free();
    }
    fn handle(p: *anyopaque) *anyopaque {
        const self = of(p);
        if (self.box == null) self.box = zb.boxEntity(self.alloc, p, &vtable) catch @panic("out of memory boxing an Engine");
        return self.box.?;
    }
    fn getAllocator(p: *anyopaque) std.mem.Allocator {
        return of(p).alloc;
    }
};

const EngineCtors = struct {
    pub fn create(alloc: std.mem.Allocator) !S.Engine {
        return Engine.make(alloc, 1, 0);
    }
    pub fn create_with(alloc: std.mem.Allocator, cfg: *const S.Config, pins: i32) !S.Engine {
        if (cfg.workers < 1) return error.InvalidConfig;
        return Engine.make(alloc, cfg.workers, pins);
    }
};

// ── Guard: one shared box for its Condition and Guard views ─────────────────

const Guard = struct {
    alloc: std.mem.Allocator,
    box: ?*anyopaque = null,
    trigger: bool = false,

    const condition_vtable: S.Condition.Vtable = .{
        .get_trigger_value = getTrigger,
        .deinit = deinit,
        .get_c_abi_handle = handle,
        .get_allocator = getAllocator,
    };
    const guard_vtable: S.Guard.Vtable = .{
        .get_trigger_value = getTrigger,
        .destroy = destroy,
        .set_trigger_value = setTrigger,
        .deinit = deinit,
        .get_c_abi_handle = handle,
        .get_allocator = getAllocator,
        .as_Condition = asCondition,
    };
    const views: S.Guard.CAbiViews = .{
        .base = .{ .flat_vtable = &condition_vtable },
        .flat_vtable = &guard_vtable,
    };

    fn of(p: *anyopaque) *Guard {
        return @ptrCast(@alignCast(p));
    }
    fn getTrigger(p: *anyopaque) bool {
        return of(p).trigger;
    }
    fn setTrigger(p: *anyopaque, value: bool) S.ReturnCode_t {
        of(p).trigger = value;
        return S.RETCODE_OK;
    }
    fn destroy(p: *anyopaque) S.ReturnCode_t {
        bump("destroys", 1);
        deinit(p);
        return S.RETCODE_OK;
    }
    fn deinit(p: *anyopaque) void {
        const self = of(p);
        if (self.box) |b| zb.freeEntityBox(self.alloc, b);
        bump("live", -1);
        self.alloc.destroy(self);
    }
    fn handle(p: *anyopaque) *anyopaque {
        const self = of(p);
        if (self.box == null) self.box = zb.boxEntity(self.alloc, p, &views) catch @panic("out of memory boxing a Guard");
        return self.box.?;
    }
    fn getAllocator(p: *anyopaque) std.mem.Allocator {
        return of(p).alloc;
    }
    fn asCondition(p: *anyopaque) S.Condition {
        return .{ .ptr = p, .vtable = &condition_vtable };
    }
};

const GuardCtors = struct {
    pub fn create(alloc: std.mem.Allocator) !S.Guard {
        const self = try alloc.create(Guard);
        self.* = .{ .alloc = alloc };
        bump("live", 1);
        return .{ .ptr = self, .vtable = &Guard.guard_vtable };
    }
};

// The checked downcast every shared-box family member's provider supplies.
pub export fn S_Condition_as_S_Guard(base: ?*anyopaque) callconv(.c) ?*anyopaque {
    const h = base orelse return null;
    return if (zb.unboxEntity(h).vtable == @as(*const anyopaque, @ptrCast(&Guard.views))) h else null;
}

// ── Holder ──────────────────────────────────────────────────────────────────

const Holder = struct {
    alloc: std.mem.Allocator,
    box: ?*anyopaque = null,
    cond: ?S.Condition = null,

    const vtable: S.Holder.Vtable = .{
        .destroy = destroy,
        .hold = hold,
        .held = held,
        .deinit = deinit,
        .get_c_abi_handle = handle,
        .get_allocator = getAllocator,
    };

    fn of(p: *anyopaque) *Holder {
        return @ptrCast(@alignCast(p));
    }
    fn destroy(p: *anyopaque) S.ReturnCode_t {
        bump("destroys", 1);
        deinit(p);
        return S.RETCODE_OK;
    }
    fn hold(p: *anyopaque, cond: S.Condition) S.ReturnCode_t {
        // A NULL condition arrives as the nil, which can be called.
        _ = cond.vtable.get_trigger_value(cond.ptr);
        of(p).cond = cond;
        return S.RETCODE_OK;
    }
    fn held(p: *anyopaque) S.Condition {
        return of(p).cond orelse Nil.condition;
    }
    fn deinit(p: *anyopaque) void {
        const self = of(p);
        if (self.box) |b| zb.freeEntityBox(self.alloc, b);
        bump("live", -1);
        self.alloc.destroy(self);
    }
    fn handle(p: *anyopaque) *anyopaque {
        const self = of(p);
        if (self.box == null) self.box = zb.boxEntity(self.alloc, p, &vtable) catch @panic("out of memory boxing a Holder");
        return self.box.?;
    }
    fn getAllocator(p: *anyopaque) std.mem.Allocator {
        return of(p).alloc;
    }
};

const HolderCtors = struct {
    pub fn create(alloc: std.mem.Allocator) !S.Holder {
        const self = try alloc.create(Holder);
        self.* = .{ .alloc = alloc };
        bump("live", 1);
        return .{ .ptr = self, .vtable = &Holder.vtable };
    }
};

// ── Registry: the singleton behind the @static operations ───────────────────

const Registry = struct {
    alloc: std.mem.Allocator,
    box: ?*anyopaque = null,
    generation: i32,
    pinned: bool = false,

    const vtable: S.Registry.Vtable = .{
        .get_generation = getGeneration,
        .pin = pin,
        .deinit = deinit,
        .get_c_abi_handle = handle,
        .get_allocator = getAllocator,
    };

    fn of(p: *anyopaque) *Registry {
        return @ptrCast(@alignCast(p));
    }
    fn getGeneration(p: *anyopaque) i32 {
        return of(p).generation;
    }
    fn pin(p: *anyopaque, on: bool) S.ReturnCode_t {
        of(p).pinned = on;
        return S.RETCODE_OK;
    }
    fn deinit(p: *anyopaque) void {
        const self = of(p);
        // Retires every binding's wrapper of it (the retire hook).
        if (self.box) |b| zb.freeEntityBox(self.alloc, b);
        bump("live", -1);
        self.alloc.destroy(self);
    }
    fn handle(p: *anyopaque) *anyopaque {
        const self = of(p);
        if (self.box == null) self.box = zb.boxEntity(self.alloc, p, &vtable) catch @panic("out of memory boxing a Registry");
        return self.box.?;
    }
    fn getAllocator(p: *anyopaque) std.mem.Allocator {
        return of(p).alloc;
    }
};

var registry: ?*Registry = null;
var registry_generations: i32 = 0;
var registry_mu: std.atomic.Mutex = .unlocked;

const RegistryStatics = struct {
    pub fn get_instance() S.Registry {
        while (!registry_mu.tryLock()) {}
        defer registry_mu.unlock();
        const self = registry orelse blk: {
            const r = std.heap.c_allocator.create(Registry) catch return Nil.registry;
            registry_generations += 1;
            r.* = .{ .alloc = std.heap.c_allocator, .generation = registry_generations };
            bump("live", 1);
            registry = r;
            break :blk r;
        };
        return .{ .ptr = self, .vtable = &Registry.vtable };
    }
    pub fn delete_instance() S.ReturnCode_t {
        while (!registry_mu.tryLock()) {}
        defer registry_mu.unlock();
        const self = registry orelse return S.RETCODE_OK;
        if (self.pinned) return S.RETCODE_PRECONDITION_NOT_MET;
        registry = null;
        bump("destroys", 1);
        Registry.deinit(self);
        return S.RETCODE_OK;
    }
    pub fn is_trigger_set(cond: S.Condition) bool {
        // A NULL condition arrives as the nil, which can be called.
        return cond.vtable.get_trigger_value(cond.ptr);
    }
};
