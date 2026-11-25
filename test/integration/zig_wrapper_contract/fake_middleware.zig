//! A synthetic implementation of the "dds module adapter contract" that
//! `--generate-zzdds-wrappers` output requires from whatever module answers
//! to `@import("zzdds")` (see zig.zig's `emitStructTypedWrapper` doc
//! comment for the contract as zidl itself documents it).
//!
//! This is deliberately NOT a mirror of zzdds's real `src/raw_ops.zig` --
//! zidl is upstream of zzdds and has no business tracking zzdds's actual
//! API shape. It exists purely so this repo's own test suite can compile
//! generated `--generate-zzdds-wrappers` output for real (see test.zig),
//! instead of only substring-matching the generated text. If zidl's codegen
//! ever changes what it emits, this file (and the contract doc comment
//! above `emitStructTypedWrapper`) are what need updating -- not anything
//! in zzdds. Real compatibility with the actual zzdds runtime is verified
//! downstream, by zzdds and zzdds-examples building against real zidl
//! output.

const std = @import("std");

pub const DDS = struct {
    pub const DataWriter = struct { _tag: u8 = 0 };
    pub const DataReader = struct { _tag: u8 = 0 };
    pub const DomainParticipant = struct { _tag: u8 = 0 };
    pub const InstanceHandle_t = u64;
    pub const Time_t = struct { sec: i32 = 0, nanosec: u32 = 0 };
    pub const ReadCondition = struct { _tag: u8 = 0 };
    pub const SampleStateMask = u32;
    pub const ViewStateMask = u32;
    pub const InstanceStateMask = u32;
    pub const SampleInfo = struct { valid_data: bool = true };
};

pub const dcps = struct {
    pub const filter = struct {
        pub const FilterValue = union(enum) {
            int: i64,
            float: f64,
            string: []const u8,
        };
    };

    pub const KeyProjection = struct {
        ctx: *anyopaque,
        project: *const fn (ctx: *anyopaque, sample: []const u8, allocator: std.mem.Allocator) ?[]u8,
    };

    pub const TypeSupport = struct {
        ctx: *anyopaque,
        compute_key_hash: *const fn (ctx: *anyopaque, payload: []const u8) [16]u8,
        compute_key_hash_key_only: ?*const fn (ctx: *anyopaque, payload: []const u8) [16]u8 = null,
        has_key: bool = false,
        get_field: ?*const fn (ctx: *anyopaque, payload: []const u8, field: []const u8, scratch: []u8) ?filter.FilterValue = null,
        deinit: ?*const fn (ctx: *anyopaque) void = null,
        key_projection: ?KeyProjection = null,
    };
};

/// The last registration `registerTypeSupport` accepted, and its name.
pub var registered: ?dcps.TypeSupport = null;
pub var registered_name: [64]u8 = undefined;
pub var registered_name_len: usize = 0;
/// Makes `registerTypeSupport` refuse, consuming the support as it does.
pub var refuse_registration = false;

pub fn registerTypeSupport(participant: DDS.DomainParticipant, type_name: []const u8, ts: dcps.TypeSupport) bool {
    _ = participant;
    if (refuse_registration or type_name.len > registered_name.len) {
        if (ts.deinit) |release| release(ts.ctx);
        return false;
    }
    @memcpy(registered_name[0..type_name.len], type_name);
    registered_name_len = type_name.len;
    registered = ts;
    return true;
}

pub const WriteKind = enum { alive, dispose, unregister };

pub const OwnedRawSample = struct {
    data: []const u8,
    info: DDS.SampleInfo,
    /// Set by a typed reader whose decode of it failed: its end gives it to
    /// the reader's policy (zzdds's two-step take).
    failed: bool = false,

    pub fn deinit(self: *const @This()) void {
        ended_samples += 1;
        if (self.failed) failed_samples += 1;
    }
};

/// How many samples typed readers ended as failed.
pub var failed_samples: usize = 0;
/// How many samples typed readers ended, failed or not.
pub var ended_samples: usize = 0;

pub fn writerUsesXcdr2(writer: DDS.DataWriter) bool {
    _ = writer;
    return true;
}

pub fn writeRaw(dw: DDS.DataWriter, kind: WriteKind, key_hash: [16]u8, payload: []const u8) !void {
    _ = dw;
    _ = kind;
    _ = key_hash;
    _ = payload;
}

pub fn writeRawWithTimestamp(dw: DDS.DataWriter, kind: WriteKind, key_hash: [16]u8, payload: []const u8, timestamp: DDS.Time_t) !void {
    _ = dw;
    _ = kind;
    _ = key_hash;
    _ = payload;
    _ = timestamp;
}

pub fn registerInstanceRaw(dw: DDS.DataWriter, key_hash: [16]u8, key_cdr: []const u8) DDS.InstanceHandle_t {
    _ = dw;
    _ = key_hash;
    _ = key_cdr;
    return 0;
}

pub const GetKeyValueError = error{ AlreadyDeleted, NotEnabled, BadParameter, OutOfMemory };

pub const KeyValue = struct { payload: []u8, key_only: bool };

pub fn getKeyValueWriter(dw: DDS.DataWriter, handle: DDS.InstanceHandle_t, allocator: std.mem.Allocator) GetKeyValueError!KeyValue {
    _ = dw;
    _ = handle;
    _ = allocator;
    return error.BadParameter;
}

pub fn getKeyValueReader(dr: DDS.DataReader, handle: DDS.InstanceHandle_t, allocator: std.mem.Allocator) GetKeyValueError!KeyValue {
    _ = dr;
    _ = handle;
    _ = allocator;
    return error.BadParameter;
}

pub fn lookupInstanceWriter(dw: DDS.DataWriter, key_hash: [16]u8) DDS.InstanceHandle_t {
    _ = dw;
    _ = key_hash;
    return 0;
}

pub fn lookupInstanceReader(dr: DDS.DataReader, key_hash: [16]u8) ?DDS.InstanceHandle_t {
    _ = dr;
    _ = key_hash;
    return null;
}

/// What the next `takeRaw` returns, set by a test; null otherwise.
pub var next_raw: ?OwnedRawSample = null;

pub fn takeRaw(dr: DDS.DataReader) ?OwnedRawSample {
    _ = dr;
    defer next_raw = null;
    return next_raw;
}

pub fn readNextSampleRaw(dr: DDS.DataReader) ?OwnedRawSample {
    _ = dr;
    return null;
}

pub fn takeNextInstanceRaw(dr: DDS.DataReader, prev: DDS.InstanceHandle_t) ?OwnedRawSample {
    _ = dr;
    _ = prev;
    return null;
}

pub fn readNextInstanceRaw(dr: DDS.DataReader, prev: DDS.InstanceHandle_t) ?OwnedRawSample {
    _ = dr;
    _ = prev;
    return null;
}

/// What the next `takeFilteredRaw` takes, set by a test; none otherwise.
pub var next_batch: []const OwnedRawSample = &.{};

pub fn takeFilteredRaw(
    dr: DDS.DataReader,
    out: *std.ArrayListUnmanaged(OwnedRawSample),
    max: i32,
    ss: DDS.SampleStateMask,
    vs: DDS.ViewStateMask,
    is: DDS.InstanceStateMask,
    handle: ?DDS.InstanceHandle_t,
    alloc: std.mem.Allocator,
) !void {
    _ = dr;
    _ = max;
    _ = ss;
    _ = vs;
    _ = is;
    _ = handle;
    defer next_batch = &.{};
    try out.appendSlice(alloc, next_batch);
}

pub fn readFilteredRaw(
    dr: DDS.DataReader,
    out: *std.ArrayListUnmanaged(OwnedRawSample),
    max: i32,
    ss: DDS.SampleStateMask,
    vs: DDS.ViewStateMask,
    is: DDS.InstanceStateMask,
    handle: ?DDS.InstanceHandle_t,
    alloc: std.mem.Allocator,
) !void {
    _ = dr;
    _ = out;
    _ = max;
    _ = ss;
    _ = vs;
    _ = is;
    _ = handle;
    _ = alloc;
}

pub fn takeWithReadConditionRaw(
    dr: DDS.DataReader,
    cond: DDS.ReadCondition,
    out: *std.ArrayListUnmanaged(OwnedRawSample),
    max: i32,
    alloc: std.mem.Allocator,
) !void {
    _ = dr;
    _ = cond;
    _ = out;
    _ = max;
    _ = alloc;
}

pub fn readWithReadConditionRaw(
    dr: DDS.DataReader,
    cond: DDS.ReadCondition,
    out: *std.ArrayListUnmanaged(OwnedRawSample),
    max: i32,
    alloc: std.mem.Allocator,
) !void {
    _ = dr;
    _ = cond;
    _ = out;
    _ = max;
    _ = alloc;
}

pub fn takeNextInstanceWithReadConditionRaw(
    dr: DDS.DataReader,
    cond: DDS.ReadCondition,
    prev: DDS.InstanceHandle_t,
    out: *std.ArrayListUnmanaged(OwnedRawSample),
    max: i32,
    alloc: std.mem.Allocator,
) !void {
    _ = dr;
    _ = cond;
    _ = prev;
    _ = out;
    _ = max;
    _ = alloc;
}

pub fn readNextInstanceWithReadConditionRaw(
    dr: DDS.DataReader,
    cond: DDS.ReadCondition,
    prev: DDS.InstanceHandle_t,
    out: *std.ArrayListUnmanaged(OwnedRawSample),
    max: i32,
    alloc: std.mem.Allocator,
) !void {
    _ = dr;
    _ = cond;
    _ = prev;
    _ = out;
    _ = max;
    _ = alloc;
}
