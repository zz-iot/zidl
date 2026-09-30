# XCDR Encoding Reference

Extracted from OMG RTPS 2.3 (formal/22-04-01) and DDS-XTYPES v1.3 (formal/20-02-04).
Implementation: `packages/zidl-rt/src/cdr.zig`, `packages/zidl-cdr/src/zidl_cdr.c`.

Cross-validated byte-for-byte between the two implementations (41 tests).

---

## Encapsulation Header

Every serialized CDR message begins with a 4-byte encapsulation header.
The first two bytes encode the representation identifier (big-endian); the last two are options (usually 0x00 0x00).

| Identifier | Hex value | Bytes [0..3] |
|---|---|---|
| CDR1 LE | `0x0001` | `0x00 0x01 0x00 0x00` |
| CDR1 BE | `0x0000` | `0x00 0x00 0x00 0x00` |
| CDR2 LE | `0x0007` | `0x00 0x07 0x00 0x00` |
| CDR2 BE | `0x0006` | `0x00 0x06 0x00 0x00` |
| D_CDR2 LE | `0x0009` | `0x00 0x09 0x00 0x00` |
| D_CDR2 BE | `0x0008` | `0x00 0x08 0x00 0x00` |
| PL_CDR2 LE | `0x000b` | `0x00 0x0b 0x00 0x00` |
| PL_CDR2 BE | `0x000a` | `0x00 0x0a 0x00 0x00` |
| PL_CDR LE | `0x0003` | `0x00 0x03 0x00 0x00` |
| PL_CDR BE | `0x0002` | `0x00 0x02 0x00 0x00` |

In XCDR2 the identifier follows the **top-level type's extensibility**: CDR2 for
`@final`, D_CDR2 for `@appendable`, PL_CDR2 for `@mutable`. Implementations may reject
a received sample whose identifier doesn't match the topic type, so the generated zzdds
writers pick it by extensibility (Zig `writeEncapHeader` / `writeEncapHeaderDelimited` /
`writeEncapHeaderMutable`; C `zidl_cdr_write_encap_kind`; Java `…DataWriter`). The
readers accept all six XCDR2 identifiers. XCDR1 `@mutable` samples should be PL_CDR
(a ParameterList encoding), which zidl does not generate yet; see `roadmap.md`.

**After writing the encap header, CDR position resets to 0.**
All alignment pads are computed from this reset position (the start of the CDR payload),
not from the start of the buffer.

---

## XCDR1 vs XCDR2 Alignment Rules

| Property | XCDR1 | XCDR2 |
|---|---|---|
| Max alignment | 8 bytes (natural) | 4 bytes (capped) |
| Reference spec | IDL §9.3.1 | XTypes §7.4.1 |
| DHEADER | No | Yes (for @appendable types) |
| EMHEADER | No | Yes (for @mutable types) |

Alignment pad formula: if `pos % boundary != 0`, insert `(boundary - pos % boundary)` zero bytes.
Padding bytes are always zero.

---

## Primitive Types

| IDL type | C type | CDR bytes | Alignment |
|---|---|---|---|
| `boolean` | `bool` | 1 (0=false, 1=true) | 1 |
| `octet` / `uint8` / `int8` / `byte` | `uint8_t` / `int8_t` | 1 | 1 |
| `char` | `char` | 1 | 1 |
| `wchar` | `uint16_t` | 2 (LE) | 2 |
| `short` / `int16` | `int16_t` | 2 (LE) | 2 |
| `unsigned short` / `uint16` | `uint16_t` | 2 (LE) | 2 |
| `long` / `int32` | `int32_t` | 4 (LE) | 4 |
| `unsigned long` / `uint32` | `uint32_t` | 4 (LE) | 4 |
| `float` | `float` | 4 (LE IEEE 754) | 4 |
| `long long` / `int64` | `int64_t` | 8 (LE) | 4 (XCDR2) / 8 (XCDR1) |
| `unsigned long long` / `uint64` | `uint64_t` | 8 (LE) | 4 (XCDR2) / 8 (XCDR1) |
| `double` | `double` | 8 (LE IEEE 754) | 4 (XCDR2) / 8 (XCDR1) |
| `long double` | `f128` | 16 (LE) | 4 (XCDR2) / 8 (XCDR1) |

Always emits little-endian. Reader handles both byte orders by detecting the encap header.

---

## String Encoding

### `string` (CDR string, char8)

```
[4]  length: u32 = byte_count + 1   (includes NUL terminator in the count)
[N]  UTF-8 bytes of the string
[1]  NUL terminator (0x00)
```

Alignment of the length field: 4-byte aligned.

`zidl_cdr_write_string(w, s, strlen(s))` — `len` = byte count, not including NUL.

### `wstring` (CDR wstring, char16)

```
[4]  count: u32 = wchar_count + 1   (includes NUL wchar in the count)
[2*count]  UTF-16 LE wchars
[2]  NUL wchar (0x0000)
```

Alignment: 4-byte aligned for the count; 2-byte aligned for each wchar.

---

## Sequence Encoding

```
[4]  DHEADER: u32          XCDR2 only, and only when the element type is non-primitive
[4]  element_count: u32   (4-byte aligned)
[…]  elements back-to-back (each element at its natural alignment from pos)
```

Bounded sequences (`sequence<T, N>`): the length still comes first; the CDR format is identical.
Bound enforcement is at the application level (serialization checks `count <= N`).

**Collection DHEADER (XCDR2).** A sequence, array or map whose element type is not
*primitive* is prefixed by a DHEADER: a 4-byte-aligned `u32` holding the byte length
of what follows (count and elements for a sequence; elements for an array). Primitive
means integers, floating point, `boolean`, `char`/`octet` and `wchar`; enums,
bitmasks, strings, structs, unions, sequences and arrays are non-primitive. A map gets
one unless both key and value are primitive. XCDR1 never has one.
`test/integration/xcdr_known_answer/` checks every zidl backend against reference
encodings from an independent implementation.

---

## Array Encoding

No length field. Elements written back-to-back, each at natural alignment.
For multi-dimensional arrays: row-major order (C-style, rightmost index varies fastest).

An array whose elements are an array typedef is flattened into one multi-dimensional
array (`typedef long Triple[3]; Triple a[2];` encodes as `long[2][3]`), so XCDR2 writes
at most one DHEADER per array, decided by the innermost element type. A *sequence* of
an array typedef is a collection of arrays (non-primitive) and gets a DHEADER on the
sequence.

---

## Enum and Bitmask Encoding

Enums and bitmasks serialize as an unsigned integer whose width follows `@bit_bound`:
1 byte for bound ≤ 8, 2 for ≤ 16, 4 for ≤ 32 (the default), 8 above that — each at its
natural alignment.

---

## Struct Encoding

Members serialize in declaration order, each at natural alignment from the current CDR position.
If the struct has a base type (`struct Derived : Base`), base members serialize first, then derived members.

---

## XCDR2 DHEADER (for @appendable types)

A DHEADER is 4-byte aligned: a writer reserving one after unaligned data pads first and
counts only the bytes after the DHEADER (never the padding before it). Collections of
non-primitive elements get one too; see *Sequence Encoding*.

A DHEADER is a `uint32_t` placed before the payload of each `@appendable` struct or union.
Its value = byte count of the payload (bytes after the DHEADER itself).

```
[4]  DHEADER: u32 = payload_byte_count   (4-byte aligned)
[…]  payload bytes
```

**Write pattern (when payload size is unknown at the time of writing):**
1. Call `zidl_cdr_reserve_dheader(w, &offset)` — writes placeholder `0x00000000`; records buffer offset.
2. Write the payload.
3. Call `zidl_cdr_patch_dheader(w, offset)` — fills in the actual byte count.

**Conditional DHEADER (for backends that support both XCDR1 and XCDR2):**

Use `zidl_cdr_reserve_dheader_maybe` / `zidl_cdr_patch_dheader_maybe`:
- On XCDR2: behaves as above.
- On XCDR1: no-op; stores sentinel `(size_t)-1` in `*out_offset`; patch is a no-op.

**Important:** The sentinel is `(size_t)-1` (all bits set), NOT `SIZE_MAX` from `<limits.h>`,
to avoid requiring `#include <limits.h>` in freestanding environments.

---

## XCDR2 EMHEADER (for @mutable types)

Each member of a `@mutable` struct is preceded by an EMHEADER that encodes the member ID,
a must-understand flag, and the length code (LC) that determines how to decode the payload length.

```
[4]  EMHEADER: u32 (4-byte aligned)
     bits [31]:   must_understand flag
     bits [30:28]: LC (length code, 0..7)
     bits [27:0]:  member_id (28 bits)
[4]  NEXTINT: u32   present only when LC >= 4 (see below)
[…]  payload
```

LC decoding (XTypes 1.3 §7.4.3.4.8):
- LC=0: payload = 1 byte
- LC=1: payload = 2 bytes
- LC=2: payload = 4 bytes
- LC=3: payload = 8 bytes
- LC=4: a separate NEXTINT follows; payload = NEXTINT bytes
- LC=5: the NEXTINT is the **first word of the payload itself** (its DHEADER, string
  length or sequence length); payload = 4 + NEXTINT bytes
- LC=6: as LC=5; payload = 4 + 4 × NEXTINT bytes (e.g. a sequence of 4-byte elements)
- LC=7: as LC=5; payload = 4 + 8 × NEXTINT bytes

For LC 5–7 the reader must *peek* the NEXTINT and leave it in place as the start of the
member value. zidl writers use LC 0–4 only; other implementations write LC 5–7 for
string and collection members, which every zidl reader accepts.

`@mutable` serialization is supported in the Zig backend (XCDR2).
The `ZidlEmHeader` struct in `zidl_cdr.h` and `zidl_cdr_read_emheader()` support decoding.

---

## @optional Encoding

An `@optional` member is prefixed by a presence flag (1 byte, bool):
- `0x01` (true): member value follows.
- `0x00` (false): no value; decoder assigns null/null-optional.

```
[1]  presence flag (bool)
[…]  member value (only if presence = true)
```

Supported in the Zig, C, C++, and Java backends. The C backend represents optional
members with a `uint64_t _present` bitmask (max 64 optional members per struct); see
`docs/backend_c.md`.

---

## zidl-rt (Zig) API Summary

`packages/zidl-rt/src/cdr.zig`:

```zig
// Writer
var buf = std.ArrayListUnmanaged(u8).empty;
var w = CdrWriter(.xcdr2).init(&buf, alloc);
try w.writeEncapHeader();   // writes encap header, resets pos
try w.writeBool(v);
try w.writeU8(v); try w.writeI8(v);
try w.writeU16(v); try w.writeI16(v);
try w.writeU32(v); try w.writeI32(v);
try w.writeU64(v); try w.writeI64(v);
try w.writeF32(v); try w.writeF64(v);
try w.writeString(s);       // u32 len + bytes + NUL
try w.writeWstring(ws);     // u32 count + wchars + NUL wchar
const off = try w.reserveDheader();
// ... write payload ...
w.patchDheader(off);
const bytes = buf.items;    // caller owns buf

// Reader
var r = CdrReader.init(data);  // parses encap header, checks byte order
try r.readBool(); try r.readU8(); try r.readI8();
try r.readU16(); try r.readI16();
try r.readU32(); try r.readI32();
try r.readU64(); try r.readI64();
try r.readF32(); try r.readF64();
try r.readString(alloc);    // allocates; caller must free
try r.readWstring(alloc);
try r.skipDheaderIfXcdr2(); // no-op on XCDR1
```

---

## zidl-cdr (C99) API Summary

`packages/zidl-cdr/include/zidl_cdr.h`:

```c
// Error codes
ZIDL_CDR_OK       = 0
ZIDL_CDR_OVERFLOW = -1   // buffer full or malloc failed
ZIDL_CDR_TRUNCATED = -2  // read past end of data
ZIDL_CDR_INVALID  = -3   // bad encap ID, invalid bool byte

// Version/byte-order constants
ZIDL_XCDR1, ZIDL_XCDR2
ZIDL_CDR_LE, ZIDL_CDR_BE
ZIDL_ENCAP_CDR1_LE = 0x0001, ZIDL_ENCAP_CDR1_BE = 0x0000
ZIDL_ENCAP_CDR2_LE = 0x0007, ZIDL_ENCAP_CDR2_BE = 0x0006

// Writer init
int  zidl_cdr_writer_init(ZidlCdrWriter *w, int xcdr_version);       // malloc-backed
void zidl_cdr_writer_init_fixed(ZidlCdrWriter *w, uint8_t *buf,
                                size_t cap, int xcdr_version);        // fixed buffer
void zidl_cdr_writer_deinit(ZidlCdrWriter *w);                       // free malloc buffer

// Encapsulation (must be first write call)
int zidl_cdr_write_encap(ZidlCdrWriter *w);

// Primitives — all return ZIDL_CDR_OK or error code
int zidl_cdr_write_bool(ZidlCdrWriter *w, bool v);
int zidl_cdr_write_u8(ZidlCdrWriter *w, uint8_t v);
int zidl_cdr_write_i8(ZidlCdrWriter *w, int8_t v);
int zidl_cdr_write_char(ZidlCdrWriter *w, char v);
int zidl_cdr_write_u16(ZidlCdrWriter *w, uint16_t v);
// ... i16, u32, i32, f32, u64, i64, f64

// Strings
int zidl_cdr_write_string(ZidlCdrWriter *w, const char *s, uint32_t len);
int zidl_cdr_write_wstring(ZidlCdrWriter *w, const uint16_t *s, uint32_t len);

// DHEADER framing
int  zidl_cdr_reserve_dheader(ZidlCdrWriter *w, size_t *out_offset);
void zidl_cdr_patch_dheader(ZidlCdrWriter *w, size_t dheader_offset);
int  zidl_cdr_reserve_dheader_maybe(ZidlCdrWriter *w, size_t *out_offset);
void zidl_cdr_patch_dheader_maybe(ZidlCdrWriter *w, size_t dheader_offset);

// EMHEADER framing
int  zidl_cdr_write_emheader(ZidlCdrWriter *w, uint32_t member_id,
                             bool must_understand, uint8_t lc);
int  zidl_cdr_reserve_emheader(ZidlCdrWriter *w, uint32_t member_id,
                               bool must_understand, size_t *out_nextint_off);
void zidl_cdr_patch_emheader(ZidlCdrWriter *w, size_t nextint_off);

// Reader init
int zidl_cdr_reader_init(ZidlCdrReader *r, const uint8_t *data, size_t data_len);

// Primitives — write result to *out; return error code
int zidl_cdr_read_bool(ZidlCdrReader *r, bool *out);
int zidl_cdr_read_u8(ZidlCdrReader *r, uint8_t *out);
// ... i8, char, u16, i16, u32, i32, f32, u64, i64, f64

// String reads
int zidl_cdr_read_string_zerocopy(ZidlCdrReader *r, const char **out, uint32_t *out_len);
int zidl_cdr_read_string(ZidlCdrReader *r, char **out);       // malloc; caller frees
int zidl_cdr_read_wstring(ZidlCdrReader *r, uint16_t **out, uint32_t *out_len);

// DHEADER / EMHEADER reads
int zidl_cdr_read_dheader(ZidlCdrReader *r, uint32_t *out);
int zidl_cdr_skip_dheader_if_xcdr2(ZidlCdrReader *r);
int zidl_cdr_read_emheader(ZidlCdrReader *r, ZidlEmHeader *out);

// Utility
size_t zidl_cdr_remaining(const ZidlCdrReader *r);
int    zidl_cdr_skip(ZidlCdrReader *r, size_t n);
```

---

## Key Implementation Notes

**Alignment is from CDR payload start, not buffer start.**
After writing the encap header, `pos` resets to 0. All subsequent `pos % boundary` pads are
relative to this zero point. This matches RTPS and Cyclone DDS behavior.

**Reader `pos` starts at 4 (past encap header), but alignment computes `(pos - 4) % boundary`.**
This gives the same logical CDR-payload offset without resetting the reader's absolute position.

**XCDR2 max alignment is 4**, not 8. This means `int64`, `uint64`, `double`, and `long double`
all align to 4 bytes under XCDR2, not their natural 8-byte boundary.

**Bool encoding:** exactly `0x00` (false) or `0x01` (true). Any other byte value is invalid (`ZIDL_CDR_INVALID`).

**String length field includes the NUL terminator** in its count. A zero-length string has length = 1 (the NUL byte only). A string of 5 characters has length = 6.
