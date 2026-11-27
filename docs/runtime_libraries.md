# Runtime Libraries Reference

> Native consolidation is implemented; the [shared Java CDR runtime](design/java-cdr-runtime.md)
> has shared helper extraction through API 2. Historical Rust descriptions below are proposals.

## Native package layout

The native layout separates codec operations from binding support.
See the [package placement checkpoint](design/native-cdr-package-slice.md) for
the original extraction boundary.

| Package | Purpose |
|---|---|
| `packages/zidl-cdr/` | Canonical native Zig codec; stable C headers and archive build |
| `packages/zidl-bindings/` | Allocators, owned values, entity boxes and authoring support |
| `packages/zidl-cdr/c-api/` | C ABI validation and temporary C reference comparison |
| `packages/zidl-xtypes/` | Zig XTypes constants |
| `packages/zidl-cdr-java/` | Standalone Java codec helpers and JAR build |

Generated C/C++ code uses the stable C ABI backed by the canonical native codec.
The independent C reference is test-only; building the production archive from
source requires Zig. Prebuilt archives can be linked by C/C++ toolchains.
Generated Zig code imports `zidl_cdr` and `zidl_bindings` directly. The
`zidl_rt` module and `packages/zidl-rt` compatibility package have been removed
following zzdds migration. See [the Zig build guide](backend_zig.md) to update
old imports. Java retains generated schema traversal and now shares alignment
and other codec helpers through `zidl-cdr-java`; see its
[package guide](../packages/zidl-cdr-java/README.md). Rust, Python and C# runtime
descriptions in older documents are proposals, not implemented backend guarantees.

---

## zidl-cdr (Native Zig Codec)

**Source:** `packages/zidl-cdr/src/writer.zig`, `reader.zig`, `cdr.zig` (KeyHashWriter, BoundedArray, constants)

### Writer

One generic writer, `Writer(config)`: encoding (XCDR1 or XCDR2), byte order and
output (counting or a fixed buffer) are each fixed at compile time or left to run
time (`docs/design/cdr-specialized-instances.md`). A fast instance fixes all three;
`RuntimeWriter` leaves all three to run time. There is no growable output: count,
allocate exactly, then write.

```zig
// The fast instance for a configuration, or RuntimeWriter when `fast` has none.
const W = zidl_cdr.WriterFor(.all, .xcdr2, .little, .fixed);
var w = W.initFixed(&buf, .xcdr2, .little);      // or initCounting(.xcdr2, .little)
try w.writeEncapHeader();
try MyStruct.serialize(&w, value);
const bytes = w.bytes();                          // empty when counting

// Count, allocate exactly and write; a length mismatch is an error.
const owned = try zidl_cdr.serializeAlloc(.all, .xcdr2, .little, alloc, value, writeFn);
```

**Why `anytype` duck-typing?** Generated `serialize(writer: anytype, …)` functions
accept every instance (and `KeyHashWriter`) without code-gen changes.

#### Writer API

```zig
// First call (required):
try w.writeEncapHeader();   // 4-byte header; resets pos to 0
// (writeEncapHeaderDelimited / writeEncapHeaderMutable for @appendable / @mutable)

// Primitives:
try w.writeBool(v);
try w.writeU8(v);  try w.writeI8(v);
try w.writeU16(v); try w.writeI16(v);
try w.writeU32(v); try w.writeI32(v);
try w.writeU64(v); try w.writeI64(v);
try w.writeF32(v); try w.writeF64(v);
try w.writePrimitiveArray(u32, values);

// Strings:
try w.writeString(s);     // u32 len + bytes + NUL
try w.writeWstring(ws);   // u32 byte count + UTF-16 units

// DHEADER (for @appendable types):
const off = try w.reserveDheader();
// ... write payload ...
try w.patchDheaderChecked(off);

// EMHEADER (for @mutable types):
const h = try w.reserveEmheader(member_id, must_understand);
// ... write payload ...
try w.patchEmheaderChecked(h);
// or fixed-length shortcut:
try w.writeEmheaderFixed(member_id, must_understand, lc);
```

A fixed writer that runs out of room returns `error.Overflow`; a counting writer
skips patches and only tracks sizes.

**Alignment note:** After `writeEncapHeader()`, `pos` resets to 0.
All subsequent alignment pads are relative to this reset position (CDR payload start),
not the start of the buffer. This matches RTPS/Cyclone DDS behavior.

**XCDR2 vs XCDR1 alignment:**
- XCDR1: max alignment 8 bytes (natural alignment for all types).
- XCDR2: max alignment 4 bytes (`i64`, `u64`, `f64` align to 4, not 8).

### KeyHashWriter

`KeyHashWriter` implements the RTPS key-hash input encoding: key fields serialized
as PLAIN_CDR2 big-endian. It exposes the same primitive writer API used by
generated `serializeKey` methods, but it does not retain the whole byte stream.
It keeps the first 16 bytes and streams the complete key into MD5.

```zig
var w = zidl_cdr.KeyHashWriter.init();
try MyStruct.serializeKey(&w, &value);
const hash: [16]u8 = w.final();
```

`final()` returns the zero-padded serialized key when its length is at most 16
bytes; otherwise it returns `MD5(serialized_key)`.

### Reader

`Reader(config)` fixes the encoding and byte order at compile time, or takes them
from each sample's header; `CdrReader` is the run-time instance. A fast instance
accepts only its own header (`error.EncapsulationMismatch`), and every instance checks
bounds on every read. `readSample` checks the header once per sample and reads with
a fast instance where there is one:

```zig
var r = try CdrReader.init(cdr_bytes);  // parses encap header
const v = try zidl_cdr.readSample(.all, T, cdr_bytes, ctx, readFn);  // readFn(reader: anytype, ctx)
```

Reader `pos` starts at 4 (past encap header), but alignment computes
`(pos - 4) % boundary` — giving the same logical CDR-payload offset.

#### CdrReader API

```zig
var r = try CdrReader.init(cdr_bytes);

// Primitives:
const v = try r.readBool();
const v = try r.readU8();  const v = try r.readI8();
const v = try r.readU16(); const v = try r.readI16();
const v = try r.readU32(); const v = try r.readI32();
const v = try r.readU64(); const v = try r.readI64();
const v = try r.readF32(); const v = try r.readF64(); const v = try r.readF128();

// Strings (allocating; caller frees):
const s = try r.readString(alloc);    // []u8; includes NUL stripped
const ws = try r.readWstring(alloc);  // []u16; NUL stripped

// DHEADER:
try r.skipDheaderIfXcdr2();   // no-op on XCDR1

// State:
const remaining = r.remaining();
try r.skip(n);
```

All read methods return `error.EndOfStream` on truncation.
Bool reads return `error.InvalidData` for any byte other than 0x00 or 0x01.

### ParameterList (PL_CDR)

Every writer writes RTPS PL_CDR (ParameterList CDR) for RTPS discovery types (see the
`--zig-pl-cdr` CLI option): use an XCDR1 instance, which sets the alignment.

```zig
// Wire format: (pid:u16, len:u16, value:[len]u8, 4-byte aligned)× + PID_SENTINEL,
// in the writer's byte order
var w = zidl_cdr.Writer(.{ .version = .xcdr1, .order = .little, .output = .fixed }).initFixed(&buf, .xcdr1, .little);
try w.writePlEncapHeader();            // 0x0003 (0x0002 big-endian)
const h = try w.reservePlParam(pid);   // returns PlParamHandle
// ... write param value ...
try w.patchPlParam(h);
// ... more params ...
try w.writePlSentinel();               // PID_SENTINEL = 0x0001, len = 0x0000
```

`PlParamHandle` = `{ len_offset, value_start }`. Alignment is continuous XCDR1 (max 8 bytes)
from CDR payload start; parameter length includes trailing pad.

`CdrReader` additions for PL_CDR:
- `is_pl_cdr: bool` — set when `init` parses a PL_CDR encap header
- `readPlParam() → ?PlParam` — returns `null` on PID_SENTINEL; `PlParam` includes `end_pos`
- `seekTo(abs_pos)` — seek to absolute position (called after each param to handle unknowns)

### BoundedArray

`std.BoundedArray` was removed in Zig 0.16.0. `zidl-cdr` provides a
minimal compatible replacement:

```zig
pub fn BoundedArray(comptime T: type, comptime capacity: usize) type {
    return struct {
        buf: [capacity]T,
        len: usize,

        pub fn fromSlice(s: []const T) error{Overflow}!Self
        pub fn slice(self: *const Self) []const T
        pub fn appendSlice(self: *Self, items: []const T) error{Overflow}!void
        // ...
    };
}
```

Used for `string<N>` (`BoundedArray(u8, N)`) and `sequence<T, N>` (`BoundedArray(T, N)`).

---

## zidl-cdr (C ABI Library)

**Source:** `packages/zidl-cdr/include/zidl_cdr.h`,
`packages/zidl-cdr/src/shared_primitives.zig`
**Tests:** 44 (C ABI/native adapter agreement)

Stable C ABI over the native codec, used by generated C and C++ code. Source
builds require Zig; applications link the installed archive with their normal
compiler. MSVC needs an archive built for an MSVC-ABI target
(`-Dtarget=x86_64-windows-msvc`). Storage and allocator support remain in
`src/zidl_cdr.c`.
Also used in the Cyclone DDS interop harness.

### Error Codes

```c
ZIDL_CDR_OK        =  0   // success
ZIDL_CDR_OVERFLOW  = -1   // buffer full or malloc failed
ZIDL_CDR_TRUNCATED = -2   // read past end of data
ZIDL_CDR_INVALID   = -3   // bad encap ID, invalid bool byte
```

### Bulk primitive bodies

The typed `zidl_cdr_{write,read}_*_array` helpers wrap
`zidl_cdr_{write,read}_primitives` for integers and floats. The generic
functions accept contiguous native primitive representations of width 1, 2,
4, or 8 and use the cursor's byte order and XCDR alignment. They do not
encode a length or collection framing. The checked bool functions encode
canonical 0 and 1 and reject any other wire value before committing a read.
Before allocating a sequence's elements, `zidl_cdr_read_sequence_count` reads
its length and checks it against the sequence's bound and the input left,
leaving the reader unchanged if either fails.

`zidl_cdr_read_primitives_view` consumes the elements as
`zidl_cdr_read_primitives` does but points at them in the reader's buffer,
in the stream's byte order, instead of copying them; the view is valid while
that buffer is. CDR aligns elements relative to the payload rather than to
memory, so `ZIDL_CDR_VIEW_AS(&view, T)` returns a `const T *` only when the
elements are unswapped and aligned for `T` (always, for octets), and
`zidl_cdr_view_copy` is the fallback. Reading in place as `T` also needs a
buffer of allocated storage (malloc, mmap, a loaned sample) rather than one
declared as another type; otherwise copy. See
[`design/bulk-cdr-zero-copy.md`](design/bulk-cdr-zero-copy.md).

`zidl_cdr_reserve_primitives` is the write side: it pads and advances the
writer as `zidl_cdr_write_primitives` would but leaves the elements for the
caller to fill in place, found again by offset through
`zidl_cdr_reservation_data` after the writer grows. Fill every element with
host values (they are not zeroed), then call `zidl_cdr_commit_primitives`,
which puts them in the writer's byte order once. A counting writer counts
them, so a write loan can be sized first and then filled directly.
See the public header for error codes, counting mode, and cursor guarantees.

### Version / Byte-Order Constants

```c
ZIDL_XCDR1    // XCDR version 1
ZIDL_XCDR2    // XCDR version 2
ZIDL_CDR_LE   // little-endian
ZIDL_CDR_BE   // big-endian

ZIDL_ENCAP_CDR1_LE = 0x0001   // header bytes: 0x00 0x01 0x00 0x00
ZIDL_ENCAP_CDR1_BE = 0x0000
ZIDL_ENCAP_CDR2_LE = 0x0007   // header bytes: 0x00 0x07 0x00 0x00
ZIDL_ENCAP_CDR2_BE = 0x0006
```

### Writer

```c
// Initialize (two modes):
int  zidl_cdr_writer_init(ZidlCdrWriter *w, int xcdr_version);
     // malloc-backed; grows automatically
void zidl_cdr_writer_init_fixed(ZidlCdrWriter *w, uint8_t *buf,
                                size_t cap, int xcdr_version);
     // fixed buffer; returns ZIDL_CDR_OVERFLOW when full
void zidl_cdr_writer_deinit(ZidlCdrWriter *w);
     // frees malloc buffer (no-op for fixed)

// Encapsulation (first call):
int zidl_cdr_write_encap(ZidlCdrWriter *w);

// Primitives (all return ZIDL_CDR_OK or error code):
int zidl_cdr_write_bool(ZidlCdrWriter *w, bool v);
int zidl_cdr_write_u8(ZidlCdrWriter *w, uint8_t v);
int zidl_cdr_write_i8(ZidlCdrWriter *w, int8_t v);
int zidl_cdr_write_char(ZidlCdrWriter *w, char v);
int zidl_cdr_write_u16(ZidlCdrWriter *w, uint16_t v);
int zidl_cdr_write_i16(ZidlCdrWriter *w, int16_t v);
int zidl_cdr_write_u32(ZidlCdrWriter *w, uint32_t v);
int zidl_cdr_write_i32(ZidlCdrWriter *w, int32_t v);
int zidl_cdr_write_f32(ZidlCdrWriter *w, float v);
int zidl_cdr_write_u64(ZidlCdrWriter *w, uint64_t v);
int zidl_cdr_write_i64(ZidlCdrWriter *w, int64_t v);
int zidl_cdr_write_f64(ZidlCdrWriter *w, double v);

// Strings:
int zidl_cdr_write_string(ZidlCdrWriter *w, const char *s, uint32_t len);
    // len = byte count, NOT including NUL
int zidl_cdr_write_wstring(ZidlCdrWriter *w, const uint16_t *s, uint32_t len);
    // len = wchar count, NOT including NUL wchar

// DHEADER framing (@appendable types):
int  zidl_cdr_reserve_dheader(ZidlCdrWriter *w, size_t *out_offset);
     // writes placeholder 0x00000000; records position in *out_offset
void zidl_cdr_patch_dheader(ZidlCdrWriter *w, size_t dheader_offset);
     // fills in actual byte count at the reserved offset

// EMHEADER framing (@mutable types):
int  zidl_cdr_write_emheader(ZidlCdrWriter *w, uint32_t member_id,
                             bool must_understand, uint8_t lc);
     // fixed-length (lc < 4) or NEXTINT-based (lc >= 4, calculated from w->size)
int  zidl_cdr_reserve_emheader(ZidlCdrWriter *w, uint32_t member_id,
                               bool must_understand, size_t *out_nextint_off);
     // reserves 4-byte EMHEADER + 4-byte NEXTINT placeholder
void zidl_cdr_patch_emheader(ZidlCdrWriter *w, size_t nextint_off,
                              size_t payload_start);
     // fills in NEXTINT with (w->len - payload_start); payload_start is the
     // buffer offset immediately after the NEXTINT placeholder was written

// Conditional DHEADER (XCDR1+XCDR2 combined backends):
int  zidl_cdr_reserve_dheader_maybe(ZidlCdrWriter *w, size_t *out_offset);
     // XCDR2: same as reserve_dheader; XCDR1: no-op, stores (size_t)-1
void zidl_cdr_patch_dheader_maybe(ZidlCdrWriter *w, size_t dheader_offset);
     // XCDR2: same as patch_dheader; XCDR1: no-op if sentinel

// Result:
// w->data points to buffer (malloc or fixed); w->size is byte count written.
```

**Sentinel value:** `(size_t)-1` (all bits set), NOT `SIZE_MAX`, to avoid
requiring `<limits.h>` in freestanding environments.

### Reader

```c
// Initialize (validates encap header):
int zidl_cdr_reader_init(ZidlCdrReader *r, const uint8_t *data, size_t data_len);

// Primitives (write result to *out; return error code):
int zidl_cdr_read_bool(ZidlCdrReader *r, bool *out);
int zidl_cdr_read_u8(ZidlCdrReader *r, uint8_t *out);
int zidl_cdr_read_i8(ZidlCdrReader *r, int8_t *out);
int zidl_cdr_read_char(ZidlCdrReader *r, char *out);
int zidl_cdr_read_u16(ZidlCdrReader *r, uint16_t *out);
int zidl_cdr_read_i16(ZidlCdrReader *r, int16_t *out);
int zidl_cdr_read_u32(ZidlCdrReader *r, uint32_t *out);
int zidl_cdr_read_i32(ZidlCdrReader *r, int32_t *out);
int zidl_cdr_read_f32(ZidlCdrReader *r, float *out);
int zidl_cdr_read_u64(ZidlCdrReader *r, uint64_t *out);
int zidl_cdr_read_i64(ZidlCdrReader *r, int64_t *out);
int zidl_cdr_read_f64(ZidlCdrReader *r, double *out);

// String reads:
int zidl_cdr_read_string_zerocopy(ZidlCdrReader *r, const char **out, uint32_t *out_len);
    // *out points into the original buffer (no allocation); NUL not included in out_len
int zidl_cdr_read_string(ZidlCdrReader *r, char **out);
    // malloc; caller frees; NUL-terminated
int zidl_cdr_read_wstring(ZidlCdrReader *r, uint16_t **out, uint32_t *out_len);
    // malloc; caller frees; out_len = wchar count excluding NUL

// DHEADER / EMHEADER:
int zidl_cdr_read_dheader(ZidlCdrReader *r, uint32_t *out);
int zidl_cdr_skip_dheader_if_xcdr2(ZidlCdrReader *r);   // no-op on XCDR1
int zidl_cdr_read_emheader(ZidlCdrReader *r, ZidlEmHeader *out);

// Utility:
size_t zidl_cdr_remaining(const ZidlCdrReader *r);
int    zidl_cdr_skip(ZidlCdrReader *r, size_t n);
```

### Key Hash Helpers

Generated C and C++ `Foo_compute_key_hash` functions serialize keys using a
`ZidlCdrWriter` configured for XCDR2 big-endian, then call:

```c
void zidl_md5(const uint8_t *data, size_t len, uint8_t out[16]);
void zidl_cdr_compute_key_hash(const uint8_t *serialized_key, size_t len, uint8_t out[16]);
```

`zidl_cdr_compute_key_hash` applies the RTPS key-hash finalization rule: serialized
keys at most 16 bytes are zero-padded; longer keys return MD5.

### PL_CDR support

Added for `--zig-pl-cdr` (`@mutable` RTPS discovery types):

```c
ZIDL_ENCAP_PL_CDR_LE   // 0x0003
ZIDL_ENCAP_PL_CDR_BE   // 0x0002
ZIDL_CDR_PID_SENTINEL  // 0x0001

// Writer
int  zidl_cdr_pl_write_encap(ZidlCdrWriter *w);
int  zidl_cdr_pl_reserve_param(ZidlCdrWriter *w, uint16_t pid, ZidlPlParamHandle *out);
void zidl_cdr_pl_patch_param(ZidlCdrWriter *w, ZidlPlParamHandle h);
int  zidl_cdr_pl_write_sentinel(ZidlCdrWriter *w);

// Reader
int zidl_cdr_pl_read_param(ZidlCdrReader *r, ZidlPlParam *out);
    // returns ZIDL_CDR_OK with out->pid == ZIDL_CDR_PID_SENTINEL on termination
int zidl_cdr_seek_to(ZidlCdrReader *r, size_t abs_pos);
```

`ZidlCdrReader.is_pl_cdr: int` — set when `zidl_cdr_reader_init` parses a PL_CDR encap header.
`align_cap` uses `!= ZIDL_XCDR2` so PL_CDR is treated as XCDR1 alignment (max 8 bytes).

### ZidlEmHeader

Populated by `zidl_cdr_read_emheader` when reading `@mutable` types:

```c
typedef struct {
    uint8_t  must_understand;   // 1 = must_understand flag set
    uint8_t  lc;                // length code (0–6; 7 reserved)
    uint32_t member_id;         // 28-bit member ID
    uint32_t nextint;           // only valid when lc >= 4
} ZidlEmHeader;
```

---

## zidl-xtypes (XTypes Constants)

**Source:** `packages/zidl-xtypes/src/root.zig`
**Tests:** none (pure constants)

Exports all XTypes discriminant and flag constants used by `zig_typeobject.zig`
and available to user code that needs to inspect TypeObjects:

```zig
// EquivalenceKind
pub const EK_MINIMAL:  u8 = 0xF1;
pub const EK_COMPLETE: u8 = 0xF2;
pub const EK_BOTH:     u8 = 0xF3;

// TypeKind (TK_*)
pub const TK_NONE:      u8 = 0x00;
pub const TK_BOOLEAN:   u8 = 0x01;
pub const TK_BYTE:      u8 = 0x02;
pub const TK_INT16:     u8 = 0x03;
pub const TK_INT32:     u8 = 0x04;
pub const TK_INT64:     u8 = 0x05;
pub const TK_UINT16:    u8 = 0x06;
pub const TK_UINT32:    u8 = 0x07;
pub const TK_UINT64:    u8 = 0x08;
pub const TK_FLOAT32:   u8 = 0x09;
pub const TK_FLOAT64:   u8 = 0x0A;
pub const TK_FLOAT128:  u8 = 0x0B;
pub const TK_INT8:      u8 = 0x0C;
pub const TK_UINT8:     u8 = 0x0D;
pub const TK_CHAR8:     u8 = 0x10;
pub const TK_CHAR16:    u8 = 0x11;
pub const TK_STRING8:   u8 = 0x20;
pub const TK_STRING16:  u8 = 0x21;
pub const TK_ALIAS:     u8 = 0x30;
pub const TK_ENUM:      u8 = 0x40;
pub const TK_BITMASK:   u8 = 0x41;
pub const TK_ANNOTATION:u8 = 0x50;
pub const TK_STRUCTURE: u8 = 0x51;
pub const TK_UNION:     u8 = 0x52;
pub const TK_BITSET:    u8 = 0x53;
pub const TK_SEQUENCE:  u8 = 0x60;
pub const TK_ARRAY:     u8 = 0x61;
pub const TK_MAP:       u8 = 0x62;

// TypeIdentifier kinds (TI_*)
pub const TI_STRING8_SMALL:        u8 = 0x70;
pub const TI_STRING8_LARGE:        u8 = 0x71;
pub const TI_STRING16_SMALL:       u8 = 0x72;
pub const TI_STRING16_LARGE:       u8 = 0x73;
pub const TI_PLAIN_SEQUENCE_SMALL: u8 = 0x80;
pub const TI_PLAIN_SEQUENCE_LARGE: u8 = 0x81;
pub const TI_PLAIN_ARRAY_SMALL:    u8 = 0x90;
pub const TI_PLAIN_ARRAY_LARGE:    u8 = 0x91;

// TypeFlag (u16 bitmask)
pub const IS_FINAL:      u16 = 0x0001;
pub const IS_APPENDABLE: u16 = 0x0002;
pub const IS_MUTABLE:    u16 = 0x0004;
pub const IS_NESTED:     u16 = 0x0008;

// MemberFlag (u16 bitmask)
pub const TRY_CONSTRUCT_DISCARD: u16 = 0x0001;
pub const FLAG_IS_OPTIONAL:      u16 = 0x0008;
pub const FLAG_IS_MUST_UNDERSTAND:u16 = 0x0010;
pub const FLAG_IS_KEY:           u16 = 0x0020;
```

See `docs/xtypes_typeobject.md` for full context.

---

## Performance Notes

**zidl-cdr Writer:**
- No allocation at all: a counting pass sizes the output, then a fixed writer fills
  an exact buffer. `zig build bench-cdr` measures the instances.
- Fast instances fold every alignment, byte-order and output branch at compile time.
- DHEADER patching requires random-access into the buffer (no streaming writers).

**zidl-cdr:**
- The malloc-backed writer uses `realloc` for growth.
- The fixed-buffer writer has zero allocation overhead; suitable for embedded.
- Zero-copy string reader (`zidl_cdr_read_string_zerocopy`) avoids allocation
  for string fields when the caller can guarantee buffer lifetime.
- Both writer modes produce identical CDR output for the same data.

**Cross-validation:**
Both libraries were cross-validated byte-for-byte for all primitive types,
strings, sequences, DHEADER framing, and @optional encoding (30 dedicated tests).
They can interoperate: a stream written by one can be read by the other.
