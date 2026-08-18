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
};

pub const WriteKind = enum { alive, dispose, unregister };

pub const OwnedRawSample = struct {
    data: []const u8,
    info: DDS.SampleInfo,

    pub fn deinit(self: @This()) void {
        _ = self;
    }
};

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

pub fn registerInstanceRaw(key_hash: [16]u8) DDS.InstanceHandle_t {
    _ = key_hash;
    return 0;
}

pub fn getKeyValueRawWriter(dw: DDS.DataWriter, handle: DDS.InstanceHandle_t) ?[]const u8 {
    _ = dw;
    _ = handle;
    return null;
}

pub fn getKeyValueRawReader(dr: DDS.DataReader, handle: DDS.InstanceHandle_t) ?[]const u8 {
    _ = dr;
    _ = handle;
    return null;
}

pub fn lookupInstanceWriter(key_hash: [16]u8) DDS.InstanceHandle_t {
    _ = key_hash;
    return 0;
}

pub fn lookupInstanceReader(dr: DDS.DataReader, handle: DDS.InstanceHandle_t) ?DDS.InstanceHandle_t {
    _ = dr;
    return handle;
}

pub fn takeRaw(dr: DDS.DataReader) ?OwnedRawSample {
    _ = dr;
    return null;
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
    _ = out;
    _ = max;
    _ = ss;
    _ = vs;
    _ = is;
    _ = handle;
    _ = alloc;
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
