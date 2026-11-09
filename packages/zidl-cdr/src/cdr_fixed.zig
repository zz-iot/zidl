//! Packed fixed-point decimals. Language mappings still expose approximate f64.
const std = @import("std");
const cursor = @import("cdr_cursor.zig");

pub fn byteCount(digits: u8, scale: u8) error{InvalidFixedPtParameters}!usize {
    if (digits < 1 or digits > 31 or scale > digits) return error.InvalidFixedPtParameters;
    return @as(usize, digits / 2) + 1;
}

fn decimalLimit(digits: u8) u128 {
    var result: u128 = 1;
    for (0..digits) |_| result *= 10;
    return result;
}

fn scaleFactor(scale: u8) f64 {
    var result: f64 = 1;
    for (0..scale) |_| result *= 10;
    return result;
}

pub fn write(sink: anytype, digits: u8, scale: u8, value: f64) !void {
    const n = try byteCount(digits, scale);
    if (std.math.isNan(value)) return error.InvalidFixedPtValue;
    const limit = decimalLimit(digits);
    const rounded = @abs(value) * scaleFactor(scale) + 0.5;
    var integer: u128 = if (rounded >= @as(f64, @floatFromInt(limit))) limit - 1 else @intFromFloat(rounded);
    var bytes: [16]u8 = @splat(0);
    bytes[n - 1] = if (value < 0 and integer != 0) 0xd else 0xc;
    var nibble = n * 2 - 1;
    for (0..digits) |_| {
        nibble -= 1;
        const digit: u8 = @intCast(integer % 10);
        integer /= 10;
        bytes[nibble / 2] |= if (nibble % 2 == 0) digit << 4 else digit;
    }
    try sink.writeBytes(bytes[0..n]);
}

pub fn read(data: []const u8, pos: *usize, digits: u8, scale: u8) !f64 {
    const n = try byteCount(digits, scale);
    const bytes = try cursor.readSlice(data, pos, n);
    const pad: usize = if (digits % 2 == 0) 1 else 0;
    if (pad != 0 and bytes[0] >> 4 != 0) return error.InvalidFixedPtPadding;
    var integer: u128 = 0;
    for (0..digits) |i| {
        const nibble = pad + i;
        const digit = if (nibble % 2 == 0) bytes[nibble / 2] >> 4 else bytes[nibble / 2] & 0xf;
        if (digit > 9) return error.InvalidFixedPtDigit;
        integer = integer * 10 + digit;
    }
    const sign = bytes[n - 1] & 0xf;
    if (sign != 0xc and sign != 0xd) return error.InvalidFixedPtSign;
    const result = @as(f64, @floatFromInt(integer)) / scaleFactor(scale);
    return if (sign == 0xd) -result else result;
}
