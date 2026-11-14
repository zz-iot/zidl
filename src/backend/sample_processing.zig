//! Checked ordinary sample decoding plus hash publication. Shared native wire
//! helper; independent of any middleware header or registration ABI.
const std = @import("std");

pub fn emit(self: anytype, name: []const u8, value_type: []const u8, has_key: bool, owns: bool, comptime cpp: bool) !void {
    const fn_name = try std.fmt.allocPrint(self.alloc, "{s}_process_sample_from_cdr", .{name});
    defer self.alloc.free(fn_name);
    const args = "const uint8_t *_payload, size_t _len, int _key_only, uint8_t _hash[16]";
    try self.print("static int {s}_bounded_impl({s});\n", .{ fn_name, args });
    try self.print("int {s}({s}) {{\n", .{ fn_name, args });
    if (cpp) try self.emitReadCall(fn_name, "_payload, _len, _key_only, _hash") else try self.printI("int _rc = {s}_bounded_impl(_payload, _len, _key_only, _hash);\n", .{fn_name});
    try self.writeI("return _rc;\n");
    try self.write("}\n");
    try self.print("static int {s}_bounded_impl({s}) {{\n", .{ fn_name, args });
    try self.writeI("if (!_payload || !_hash || (_key_only != 0 && _key_only != 1)) return ZIDL_CDR_INVALID;\n");
    try self.writeI("ZidlCdrReader _reader;\nint _rc = zidl_cdr_reader_init(&_reader, _payload, _len);\nif (_rc) return _rc;\n");
    if (cpp) try self.printI("{s} _value{{}};\n", .{value_type}) else try self.printI("{s} _value; memset(&_value, 0, sizeof _value);\n", .{value_type});
    try self.writeI("uint8_t _result[16] = {0};\n");
    if (has_key) {
        try self.printI("_rc = _key_only ? {s}_deserialize_key_value(&_reader, &_value) : {s}_deserialize(&_reader, &_value);\n", .{ name, name });
    } else {
        try self.printI("if (!_key_only) _rc = {s}_deserialize(&_reader, &_value);\n", .{name});
    }
    // RTPS submessages may append up to three zero octets to a four-byte
    // boundary. Unknown extension fields inside delimited bodies are handled
    // by the ordinary decoder; required-field strictness is not imposed here.
    try self.writeI("if (!_rc && _reader.pos != _len) {\n");
    try self.writeI("    size_t _left = _len - _reader.pos;\n");
    try self.writeI("    if (_left > 3 || (_len & 3u)) _rc = ZIDL_CDR_INVALID;\n");
    try self.writeI("    else for (size_t _i = _reader.pos; _i < _len; ++_i) if (_payload[_i] != 0) { _rc = ZIDL_CDR_INVALID; break; }\n");
    try self.writeI("}\n");
    if (has_key) try self.printI("if (!_rc) _rc = {s}_compute_key_hash(&_value, _result);\n", .{name});
    if (!cpp and owns) try self.printI("{s}_free(&_value);\n", .{name});
    try self.writeI(if (cpp) "if (!_rc) std::memcpy(_hash, _result, 16);\n" else "if (!_rc) memcpy(_hash, _result, 16);\n");
    try self.writeI("return _rc;\n");
    try self.write("}\n\n");
}
