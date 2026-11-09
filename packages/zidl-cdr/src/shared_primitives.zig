//! Incremental C ABI adapter: primitives, strings, framing, keys and cursors.
//! Allocator registration and remaining codec operations stay in C.
const rt = @import("zidl_rt");
const std = @import("std");

pub const Writer = extern struct {
    buf: ?[*]u8,
    cap: usize,
    len: usize,
    pos: usize,
    xcdr_version: c_int,
    byte_order: c_int,
    grow_fn: ?*const fn (*Writer, usize) callconv(.c) c_int,
};

extern fn zidl_cdr_shared_write_bytes(w: *Writer, bytes: [*]const u8, len: usize) c_int;

const Sink = struct {
    writer: *Writer,
    status: c_int = 0,

    pub fn payloadPosition(self: *const Sink) usize {
        return self.writer.pos;
    }
    pub fn byteLen(self: *const Sink) usize {
        return self.writer.len;
    }
    pub fn resetPayload(self: *Sink) void {
        self.writer.pos = 0;
    }

    pub fn writeU32(self: *Sink, value: u32) error{StorageFailure}!void {
        self.status = writeUnsigned(self.writer, u32, value);
        if (self.status != 0) return error.StorageFailure;
    }

    pub fn writeU16(self: *Sink, value: u16) error{StorageFailure}!void {
        self.status = writeUnsigned(self.writer, u16, value);
        if (self.status != 0) return error.StorageFailure;
    }

    pub fn writeBytes(self: *Sink, bytes: []const u8) error{StorageFailure}!void {
        self.status = zidl_cdr_shared_write_bytes(self.writer, bytes.ptr, bytes.len);
        if (self.status != 0) return error.StorageFailure;
    }
};

fn writeUnsigned(w: *Writer, comptime T: type, value: T) c_int {
    var sink = Sink{ .writer = w };
    rt.cdr_primitives.writeUnsigned(&sink, T, value, w.pos, if (w.xcdr_version == 2) 4 else 8, if (w.byte_order == 1) .big else .little) catch return sink.status;
    return 0;
}

export fn zidl_cdr_write_u8(w: *Writer, value: u8) c_int {
    return writeUnsigned(w, u8, value);
}

export fn zidl_cdr_write_i8(w: *Writer, value: i8) c_int {
    return writeUnsigned(w, u8, @as(u8, @bitCast(value)));
}

export fn zidl_cdr_write_u16(w: *Writer, value: u16) c_int {
    return writeUnsigned(w, u16, value);
}

export fn zidl_cdr_write_i16(w: *Writer, value: i16) c_int {
    return writeUnsigned(w, u16, @as(u16, @bitCast(value)));
}

export fn zidl_cdr_write_u32(w: *Writer, value: u32) c_int {
    return writeUnsigned(w, u32, value);
}

export fn zidl_cdr_write_i32(w: *Writer, value: i32) c_int {
    return writeUnsigned(w, u32, @as(u32, @bitCast(value)));
}

export fn zidl_cdr_write_u64(w: *Writer, value: u64) c_int {
    return writeUnsigned(w, u64, value);
}

export fn zidl_cdr_write_i64(w: *Writer, value: i64) c_int {
    return writeUnsigned(w, u64, @as(u64, @bitCast(value)));
}

export fn zidl_cdr_write_f32(w: *Writer, value: f32) c_int {
    return writeUnsigned(w, u32, @bitCast(value));
}

export fn zidl_cdr_write_f64(w: *Writer, value: f64) c_int {
    return writeUnsigned(w, u64, @bitCast(value));
}

export fn zidl_cdr_write_bool(w: *Writer, value: bool) c_int {
    return writeUnsigned(w, u8, @intFromBool(value));
}

export fn zidl_cdr_write_char(w: *Writer, value: u8) c_int {
    return writeUnsigned(w, u8, value);
}

pub const Reader = extern struct {
    data: ?[*]const u8,
    data_len: usize,
    pos: usize,
    byte_order: c_int,
    xcdr_version: c_int,
    is_pl_cdr: c_int,
};

fn input(r: *const Reader) error{EndOfStream}![]const u8 {
    if (r.data) |data| return data[0..r.data_len];
    if (r.data_len == 0) return &.{};
    return error.EndOfStream;
}

fn readStatus(err: error{ EndOfStream, InvalidBool, InvalidPrimitiveSize, InvalidString, InvalidEncapsulation, InvalidEmheader, InvalidOptionalHeader }) c_int {
    return switch (err) {
        error.EndOfStream => -2,
        error.InvalidBool, error.InvalidPrimitiveSize, error.InvalidString, error.InvalidEncapsulation, error.InvalidEmheader, error.InvalidOptionalHeader => -3,
    };
}

fn readUnsigned(r: *Reader, comptime T: type) error{EndOfStream}!T {
    return rt.cdr_primitives.readUnsigned(T, try input(r), &r.pos, 4, if (r.xcdr_version == 2) 4 else 8, if (r.byte_order == 0) .little else .big);
}

export fn zidl_cdr_shared_align_reader(r: *Reader, boundary: usize) c_int {
    rt.cdr_cursor.alignPosition(&r.pos, r.data_len, 4, boundary) catch |err| return readStatus(err);
    return 0;
}

export fn zidl_cdr_skip(r: *Reader, count: usize) c_int {
    _ = rt.cdr_cursor.advance(&r.pos, r.data_len, count) catch |err| return readStatus(err);
    return 0;
}

export fn zidl_cdr_skip_primitives(r: *Reader, count: u32, wire_size: usize) c_int {
    rt.cdr_cursor.skipPrimitives(&r.pos, r.data_len, 4, count, wire_size, if (r.xcdr_version == 2) 4 else 8) catch |err| return readStatus(err);
    return 0;
}

export fn zidl_cdr_seek_to(r: *Reader, target: usize) c_int {
    rt.cdr_cursor.seek(&r.pos, r.data_len, target) catch |err| return readStatus(err);
    return 0;
}

export fn zidl_cdr_read_u8(r: *Reader, out: *u8) c_int {
    const value = readUnsigned(r, u8) catch |err| return readStatus(err);
    out.* = value;
    return 0;
}

export fn zidl_cdr_read_i8(r: *Reader, out: *i8) c_int {
    const value = readUnsigned(r, u8) catch |err| return readStatus(err);
    out.* = @bitCast(value);
    return 0;
}

export fn zidl_cdr_read_u16(r: *Reader, out: *u16) c_int {
    const value = readUnsigned(r, u16) catch |err| return readStatus(err);
    out.* = value;
    return 0;
}

export fn zidl_cdr_read_i16(r: *Reader, out: *i16) c_int {
    const value = readUnsigned(r, u16) catch |err| return readStatus(err);
    out.* = @bitCast(value);
    return 0;
}

export fn zidl_cdr_read_u32(r: *Reader, out: *u32) c_int {
    const value = readUnsigned(r, u32) catch |err| return readStatus(err);
    out.* = value;
    return 0;
}

export fn zidl_cdr_read_i32(r: *Reader, out: *i32) c_int {
    const value = readUnsigned(r, u32) catch |err| return readStatus(err);
    out.* = @bitCast(value);
    return 0;
}

export fn zidl_cdr_read_u64(r: *Reader, out: *u64) c_int {
    const value = readUnsigned(r, u64) catch |err| return readStatus(err);
    out.* = value;
    return 0;
}

export fn zidl_cdr_read_i64(r: *Reader, out: *i64) c_int {
    const value = readUnsigned(r, u64) catch |err| return readStatus(err);
    out.* = @bitCast(value);
    return 0;
}

export fn zidl_cdr_read_f32(r: *Reader, out: *f32) c_int {
    const bits = readUnsigned(r, u32) catch |err| return readStatus(err);
    out.* = @bitCast(bits);
    return 0;
}

export fn zidl_cdr_read_f64(r: *Reader, out: *f64) c_int {
    const bits = readUnsigned(r, u64) catch |err| return readStatus(err);
    out.* = @bitCast(bits);
    return 0;
}

export fn zidl_cdr_read_bool(r: *Reader, out: *bool) c_int {
    const data = input(r) catch |err| return readStatus(err);
    const value = rt.cdr_primitives.readBool(data, &r.pos) catch |err| return readStatus(err);
    out.* = value;
    return 0;
}

export fn zidl_cdr_read_char(r: *Reader, out: *u8) c_int {
    return zidl_cdr_read_u8(r, out);
}

extern fn zidl_cdr_alloc(size: usize) ?[*]u8;

export fn zidl_cdr_write_string(w: *Writer, data: ?[*]const u8, len: u32) c_int {
    _ = rt.cdr_strings.wireLength(len) catch return -1;
    const value = if (len == 0) &.{} else (data orelse return -3)[0..len];
    var sink = Sink{ .writer = w };
    rt.cdr_strings.writeString(&sink, value) catch |err| return switch (err) {
        error.Overflow => -1,
        error.StorageFailure => sink.status,
    };
    return 0;
}

export fn zidl_cdr_write_wstring(w: *Writer, data: ?[*]const u16, len: u32) c_int {
    _ = rt.cdr_strings.wideWireBytes(len) catch return -1;
    const value = if (len == 0) &.{} else (data orelse return -3)[0..len];
    var sink = Sink{ .writer = w };
    rt.cdr_strings.writeWstring(&sink, value) catch |err| return switch (err) {
        error.Overflow => -1,
        error.StorageFailure => sink.status,
    };
    return 0;
}

fn readString(r: *Reader) error{ EndOfStream, InvalidString }![]const u8 {
    return rt.cdr_strings.readString(try input(r), &r.pos, if (r.xcdr_version == 2) 4 else 8, if (r.byte_order == 0) .little else .big);
}

export fn zidl_cdr_read_string_zerocopy(r: *Reader, out: *?[*]const u8, out_len: *u32) c_int {
    const value = readString(r) catch |err| return readStatus(err);
    out.* = value.ptr;
    out_len.* = @intCast(value.len);
    return 0;
}

export fn zidl_cdr_read_string(r: *Reader, out: *?[*]u8) c_int {
    const value = readString(r) catch |err| return readStatus(err);
    // C free_str reconstructs the allocation size with strlen()+1.
    if (std.mem.indexOfScalar(u8, value, 0) != null) return -3;
    const buffer = zidl_cdr_alloc(value.len + 1) orelse return -1;
    @memcpy(buffer[0..value.len], value);
    buffer[value.len] = 0;
    out.* = buffer;
    return 0;
}

export fn zidl_cdr_skip_wstring(r: *Reader) c_int {
    const data = input(r) catch return -2;
    _ = rt.cdr_strings.readWstring(data, &r.pos, if (r.xcdr_version == 2) 4 else 8, if (r.byte_order == 0) .little else .big) catch |err| return readStatus(err);
    return 0;
}

export fn zidl_cdr_read_wstring(r: *Reader, out: *?[*]u16, out_len: *u32) c_int {
    const data = input(r) catch |err| return readStatus(err);
    const view = rt.cdr_strings.readWstring(data, &r.pos, if (r.xcdr_version == 2) 4 else 8, if (r.byte_order == 0) .little else .big) catch |err| return readStatus(err);
    // C free_wstr likewise scans for NUL; reject before allocating anything.
    for (0..view.len()) |i| if (view.codeUnit(i) == 0) return -3;
    const size = std.math.add(usize, view.encoded.len, @sizeOf(u16)) catch return -1;
    const raw = zidl_cdr_alloc(size) orelse return -1;
    const buffer: [*]u16 = @ptrCast(@alignCast(raw));
    for (0..view.len()) |i| buffer[i] = view.codeUnit(i);
    buffer[view.len()] = 0;
    out.* = buffer;
    out_len.* = @intCast(view.len());
    return 0;
}

fn order(w: *const Writer) rt.ByteOrder {
    return if (w.byte_order == 1) .big else .little;
}
fn patchStorage(w: *Writer) ?[]u8 {
    return if (w.buf) |data| data[0..w.cap] else null;
}
fn patchStatus(err: error{ InvalidPatch, Overflow }) c_int {
    return switch (err) {
        error.InvalidPatch => -3,
        error.Overflow => -1,
    };
}

export fn zidl_cdr_write_encap_kind(w: *Writer, kind: c_int) c_int {
    const version: rt.cdr_framing.Version = if (w.xcdr_version == 1 or w.xcdr_version == 3) .xcdr1 else .xcdr2;
    const ext: rt.cdr_framing.Extensibility = if (kind == 0) .final else if (kind == 2) .mutable else .appendable;
    const id = rt.cdr_framing.encapsulationId(version, order(w), ext, w.xcdr_version == 3);
    var sink = Sink{ .writer = w };
    rt.cdr_framing.writeEncapsulation(&sink, id) catch return sink.status;
    return 0;
}
export fn zidl_cdr_write_encap(w: *Writer) c_int {
    return zidl_cdr_write_encap_kind(w, 0);
}
export fn zidl_cdr_pl_write_encap(w: *Writer) c_int {
    var sink = Sink{ .writer = w };
    rt.cdr_framing.writeEncapsulation(&sink, 3) catch return sink.status;
    return 0;
}

export fn zidl_cdr_reader_init(r: *Reader, data: ?[*]const u8, len: usize) c_int {
    if (len < 4 or data == null) return -3;
    const encap = rt.cdr_framing.parseEncapsulation(data.?[0..len]) catch return -3;
    r.* = .{ .data = data, .data_len = len, .pos = 4, .byte_order = if (encap.order == .little) 0 else 1, .xcdr_version = if (encap.version == .xcdr1) 1 else 2, .is_pl_cdr = @intFromBool(encap.is_pl_cdr) };
    return 0;
}

export fn zidl_cdr_reader_limit(r: *const Reader, end: usize, out: *Reader) c_int {
    rt.cdr_framing.validateLimit(r.pos, r.data_len, end) catch return -2;
    out.* = r.*;
    out.data_len = end;
    return 0;
}
export fn zidl_cdr_write_dheader(w: *Writer, size: u32) c_int {
    return writeUnsigned(w, u32, size);
}
export fn zidl_cdr_reserve_dheader(w: *Writer, out: *usize) c_int {
    var sink = Sink{ .writer = w };
    rt.cdr_framing.reserveDheader(&sink, out) catch return sink.status;
    return 0;
}
export fn zidl_cdr_reserve_dheader_maybe(w: *Writer, out: *usize) c_int {
    if (w.xcdr_version != 2) {
        out.* = std.math.maxInt(usize);
        return 0;
    }
    return zidl_cdr_reserve_dheader(w, out);
}
export fn zidl_cdr_patch_dheader_checked(w: *Writer, offset: usize) c_int {
    rt.cdr_framing.patchDheader(patchStorage(w), w.len, offset, order(w)) catch |err| return patchStatus(err);
    return 0;
}
export fn zidl_cdr_patch_dheader(w: *Writer, offset: usize) void {
    _ = zidl_cdr_patch_dheader_checked(w, offset);
}
export fn zidl_cdr_patch_dheader_maybe(w: *Writer, offset: usize) void {
    if (offset != std.math.maxInt(usize)) zidl_cdr_patch_dheader(w, offset);
}
export fn zidl_cdr_write_emheader(w: *Writer, member_id: u32, mu: bool, lc: u8) c_int {
    var sink = Sink{ .writer = w };
    rt.cdr_framing.writeEmheader(&sink, member_id, mu, lc) catch |err| return switch (err) {
        error.InvalidEmheader => -3,
        error.StorageFailure => sink.status,
    };
    return 0;
}
export fn zidl_cdr_reserve_emheader(w: *Writer, member_id: u32, mu: bool, out: *usize) c_int {
    var sink = Sink{ .writer = w };
    rt.cdr_framing.reserveEmheader(&sink, member_id, mu, out) catch |err| return switch (err) {
        error.InvalidEmheader => -3,
        error.StorageFailure => sink.status,
    };
    return 0;
}
export fn zidl_cdr_patch_emheader_checked(w: *Writer, offset: usize, start: usize) c_int {
    rt.cdr_framing.patchEmheader(patchStorage(w), w.len, offset, start, order(w)) catch |err| return patchStatus(err);
    return 0;
}
export fn zidl_cdr_patch_emheader(w: *Writer, offset: usize, start: usize) void {
    _ = zidl_cdr_patch_emheader_checked(w, offset, start);
}
export fn zidl_cdr_read_dheader(r: *Reader, out: *u32) c_int {
    return zidl_cdr_read_u32(r, out);
}
export fn zidl_cdr_read_mutable_dheader(r: *Reader, out: *usize) c_int {
    const data = input(r) catch return -2;
    const end = rt.cdr_framing.readDheaderEnd(data, &r.pos, if (r.xcdr_version == 2) 4 else 8, if (r.byte_order == 0) .little else .big) catch return -2;
    out.* = end;
    return 0;
}
export fn zidl_cdr_skip_dheader_if_xcdr2(r: *Reader) c_int {
    if (r.xcdr_version != 2) return 0;
    var end: usize = undefined;
    return zidl_cdr_read_mutable_dheader(r, &end);
}
export fn zidl_cdr_mutable_has_more(r: *const Reader, end: usize) bool {
    return end <= r.data_len and r.pos < end;
}

pub const EmHeader = extern struct { member_id: u32, must_understand: bool, lc: u8, payload_bytes: u32 };
export fn zidl_cdr_read_emheader(r: *Reader, out: *EmHeader) c_int {
    const data = input(r) catch return -2;
    const em = rt.cdr_framing.readEmheader(data, &r.pos, if (r.xcdr_version == 2) 4 else 8, if (r.byte_order == 0) .little else .big) catch |err| return readStatus(err);
    out.* = .{ .member_id = em.member_id, .must_understand = em.must_understand, .lc = em.lc, .payload_bytes = em.payload_bytes };
    return 0;
}
export fn zidl_cdr_emheader_end(r: *const Reader, em: *const EmHeader, out: *usize) c_int {
    const end = rt.cdr_framing.memberEnd(r.pos, r.data_len, if (r.xcdr_version == 2) 4 else 8, em.lc, em.payload_bytes) catch |err| return readStatus(err);
    out.* = end;
    return 0;
}
export fn zidl_cdr_skip_emheader_payload(r: *Reader, em: *const EmHeader) c_int {
    rt.cdr_framing.skipMember(&r.pos, r.data_len, if (r.xcdr_version == 2) 4 else 8, em.lc, em.payload_bytes) catch |err| return readStatus(err);
    return 0;
}

pub const PlHandle = extern struct { len_offset: usize, buf_value_start: usize };
pub const PlParam = extern struct { pid: u16, byte_len: u16, end_pos: usize };
export fn zidl_cdr_pl_reserve_param(w: *Writer, pid: u16, out: *PlHandle) c_int {
    var sink = Sink{ .writer = w };
    rt.cdr_framing.reserveParameter(&sink, pid, &out.len_offset, &out.buf_value_start) catch return sink.status;
    return 0;
}
export fn zidl_cdr_pl_patch_param(w: *Writer, handle: PlHandle) c_int {
    rt.cdr_framing.validateParameter(w.len, handle.len_offset, handle.buf_value_start) catch return -3;
    const raw = w.len - handle.buf_value_start;
    const padded = rt.cdr_framing.parameterSize(raw) catch return -1;
    const zeros: [4]u8 = @splat(0);
    var sink = Sink{ .writer = w };
    if (padded > raw) sink.writeBytes(zeros[0 .. padded - raw]) catch return sink.status;
    rt.cdr_framing.patchParameter(patchStorage(w), w.len, handle.len_offset, handle.buf_value_start) catch |err| return patchStatus(err);
    return 0;
}
export fn zidl_cdr_pl_write_sentinel(w: *Writer) c_int {
    var sink = Sink{ .writer = w };
    rt.cdr_framing.writeSentinel(&sink) catch return sink.status;
    return 0;
}
export fn zidl_cdr_pl_read_param(r: *Reader, out: *PlParam) c_int {
    const pid = readUnsigned(r, u16) catch return -2;
    const len = readUnsigned(r, u16) catch return -2;
    const end = rt.cdr_framing.parameterEnd(r.pos, len, r.data_len) catch return -2;
    out.* = .{ .pid = pid, .byte_len = len, .end_pos = end };
    return 0;
}

export fn zidl_cdr_compute_key_hash_for_type(data: ?[*]const u8, len: usize, force_md5: bool, out: *[16]u8) void {
    const bytes = if (len == 0) &.{} else data.?[0..len];
    out.* = rt.cdr_keys.hash(bytes, force_md5);
}
export fn zidl_cdr_compute_key_hash(data: ?[*]const u8, len: usize, out: *[16]u8) void {
    zidl_cdr_compute_key_hash_for_type(data, len, false, out);
}
export fn zidl_cdr_write_key_wstring(w: *Writer, data: ?[*]const u16, len: u32) c_int {
    if (len > std.math.maxInt(u32) / 2) return -1;
    if (len != 0 and data == null) return -3;
    var sink = Sink{ .writer = w };
    rt.cdr_keys.writeWstring(&sink, if (len == 0) &.{} else data.?[0..len]) catch |err| return if (err == error.Overflow) -1 else sink.status;
    return 0;
}

export fn zidl_cdr_write_key_wstring_length(w: *Writer, len: u32) c_int {
    var sink = Sink{ .writer = w };
    rt.cdr_keys.writeWstringLength(&sink, len) catch |err| return if (err == error.Overflow) -1 else sink.status;
    return 0;
}

pub const OptionalWrite = rt.cdr_framing.OptionalWrite;
pub const OptionalRead = extern struct { parent: Reader, end: usize };

export fn zidl_cdr_begin_optional_write(w: *Writer, member_id: u32, mu: bool, present: bool, scope: *OptionalWrite) c_int {
    if (member_id > 0x0fffffff) return -3;
    if (w.xcdr_version == 2) {
        const rc = zidl_cdr_write_bool(w, present);
        if (rc != 0) return rc;
        scope.* = .{ .length_offset = std.math.maxInt(usize), .value_start = 0, .parent_pos = 0 };
        return 0;
    }
    var sink = Sink{ .writer = w };
    const token = rt.cdr_framing.beginOptional(&sink, member_id, mu) catch |err| return switch (err) {
        error.InvalidOptionalHeader => -3,
        else => sink.status,
    };
    scope.* = token;
    return 0;
}

export fn zidl_cdr_cancel_optional_write(w: *Writer, scope: *const OptionalWrite) void {
    if (scope.length_offset == std.math.maxInt(usize)) return;
    w.pos = rt.cdr_framing.optionalParentPosition(w.len, scope.*) catch return;
}

export fn zidl_cdr_end_optional_write(w: *Writer, scope: *const OptionalWrite) c_int {
    defer zidl_cdr_cancel_optional_write(w, scope);
    if (scope.length_offset == std.math.maxInt(usize)) return 0;
    rt.cdr_framing.finishOptional(patchStorage(w), w.len, scope.*, order(w)) catch |err| return patchStatus(err);
    return 0;
}

export fn zidl_cdr_begin_optional_read(r: *Reader, member_id: u32, scope: *OptionalRead, present: *bool) c_int {
    if (member_id > 0x0fffffff) return -3;
    if (r.xcdr_version == 2) {
        const rc = zidl_cdr_read_bool(r, present);
        if (rc != 0) return rc;
        scope.* = .{ .parent = r.*, .end = std.math.maxInt(usize) };
        return 0;
    }
    const span = rt.cdr_framing.readOptional(input(r) catch return -2, &r.pos, member_id, if (r.byte_order == 0) .little else .big) catch |err| return readStatus(err);
    scope.* = .{ .parent = r.*, .end = span.end };
    scope.parent.pos = span.end;
    r.data = r.data.? + (span.start - 4);
    r.data_len = 4 + (span.end - span.start);
    r.pos = 4;
    present.* = span.start != span.end;
    return 0;
}

export fn zidl_cdr_end_optional_read(r: *Reader, scope: *const OptionalRead) void {
    const pos = r.pos;
    r.* = scope.parent;
    if (scope.end == std.math.maxInt(usize)) r.pos = pos;
}

export fn zidl_cdr_write_fixed(w: *Writer, digits: u8, scale: u8, value: f64) c_int {
    var sink = Sink{ .writer = w };
    rt.cdr_fixed.write(&sink, digits, scale, value) catch |err| return switch (err) {
        error.InvalidFixedPtParameters, error.InvalidFixedPtValue => -3,
        else => sink.status,
    };
    return 0;
}

export fn zidl_cdr_read_fixed(r: *Reader, digits: u8, scale: u8, out: *f64) c_int {
    const result = rt.cdr_fixed.read(input(r) catch return -2, &r.pos, digits, scale) catch |err| return switch (err) {
        error.EndOfStream => -2,
        else => -3,
    };
    out.* = result;
    return 0;
}
