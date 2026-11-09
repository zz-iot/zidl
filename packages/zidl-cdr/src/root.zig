//! Canonical native CDR codec. No C ABI or generated-binding dependency.
const std = @import("std");
pub const cdr = @import("cdr.zig");
pub const primitive_writer = @import("primitive_writer.zig");
pub const XcdrVersion = cdr.XcdrVersion;
pub const ByteOrder = cdr.ByteOrder;
pub const cdr_primitives = @import("cdr_primitives.zig");
pub const cdr_cursor = @import("cdr_cursor.zig");
pub const cdr_strings = @import("cdr_strings.zig");
pub const cdr_framing = @import("cdr_framing.zig");
pub const PrimitiveWriter = primitive_writer.PrimitiveWriter;
pub const CdrWriter = cdr.CdrWriter;
pub const CdrReader = cdr.CdrReader;
pub const BoundedArray = cdr.BoundedArray;
pub const KeyHashWriter = cdr.KeyHashWriter;
pub const PlCdrWriter = cdr.PlCdrWriter;
pub const PlMode = cdr.CdrReader.PlMode;
pub const PlParam = cdr.CdrReader.PlParam;
pub const RawParam = cdr.CdrReader.RawParam;
pub const ENCAP_CDR1_LE = cdr.ENCAP_CDR1_LE;
pub const ENCAP_CDR1_BE = cdr.ENCAP_CDR1_BE;
pub const ENCAP_CDR2_LE = cdr.ENCAP_CDR2_LE;
pub const ENCAP_CDR2_BE = cdr.ENCAP_CDR2_BE;
pub const ENCAP_PL_CDR_LE = cdr.ENCAP_PL_CDR_LE;
pub const ENCAP_PL_CDR_BE = cdr.ENCAP_PL_CDR_BE;
pub const cdr_keys = @import("cdr_keys.zig");
pub const cdr_fixed = @import("cdr_fixed.zig");

test {
    _ = @import("cdr_optional_test.zig");
    _ = @import("cdr_fixed_test.zig");
    std.testing.refAllDecls(@This());
}
