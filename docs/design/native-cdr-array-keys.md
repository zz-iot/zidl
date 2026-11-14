# Canonical enum and bitmask array keys

## Specification and independent implementation

The local specification is OMG DDS-XTypes 1.3, formal/2020-02-04
(`OMG_specs/formal-20-02-04.pdf` in the development hub).

- §7.6.8, printed pp. 237–238: construct FINAL key holders recursively, order
  members by ID, serialize PLAIN_CDR2 big endian with four-byte maximum alignment
  and zero padding, and choose padded bytes versus MD5 from the schema maximum.
- §7.4.3.5.1, printed pp. 138–139: flatten multidimensional arrays, including
  dimensions introduced by typedefs, in row-major order.
- §7.4.3.5.2, printed pp. 143–144, rules (5)–(9): enums/bitmasks serialize using
  their holder widths; primitive arrays have no collection header; XCDR2 arrays
  of non-primitive elements have a UINT32 DHEADER containing their payload size.

FINAL projection removes aggregate extensibility headers. It does not turn an
array's enum or bitmask element type into a primitive, so the collection DHEADER
remains. The note in §7.6.8 about omitted type/member headers does not justify
suppressing collection delimiters. The earlier canonical-key checkpoint's broad
statement that all collection headers are excluded was incorrect.

The independent Python oracle (`make_array_key_vectors.py`) assembles nine fixed
key holders using only `struct.pack` and `hashlib`. It does not import zidl or a
codec runtime. Cyclone DDS agrees with all nine byte sequences and schema-based
fixed-key/MD5 policies. The local check used source commit
`e54e991f75a3e67f8e628da3171122e36ea5b872`, generated type support identifying
Cyclone V11.0.1, and the existing built shared library. Tracked source was clean.

`check_cyclone_arrays.py` makes that check repeatable without DDS participants,
XML/JSON samples or pcaps. For these FINAL all-key fixtures the serialized native
sample is also a key-only sample. The exported
`dds_stream_extract_keyBE_from_key` API explicitly selects
`DDS_CDR_KEY_SERIALIZATION_KEYHASH`; ordinary key-only serialization is not used
as a substitute for that mode. The optional check reports a mismatch against its
provided Cyclone build rather than silently rewriting expected bytes.

## Implementation and evidence

One shared generator helper flattens the complete array extent and computes its
enum/bitmask payload size with checked multiplication and a UINT32 range check.
All four backends emit that known DHEADER before canonical array elements.
The streaming native hash can therefore write bytes in order without allocating
scratch storage or trying to patch bytes already fed into MD5. Schema maximum
sizing uses the same extent and includes delimiter alignment/size.

For an array of four default-width enums `[0,1,0,1]`, the canonical bytes are:

```
00000010 00000000 00000001 00000000 00000001
```

The maximum is 20 bytes, so the result is MD5
`05536356e059c4e341135fa9e3071ab7`, rather than a 16-byte inline key. Twelve
8-bit bitmask elements plus their delimiter fit in 16 bytes; thirteen require
17 and force MD5. The narrow-enum witness checks zero padding before the
DHEADER and that no extra padding is appended after its three-byte payload.
The nested typedef witness has exactly one collection delimiter. A primitive
array typedef control has none.

Compiled C/C++/Zig and Java single/split tests consume the same nine witnesses.
They compare exact canonical bytes, hashes and type-policy constants, then test
full-wire decode/hash paths in both XCDR versions (C/C++ check both byte orders).
C/C++ and native Zig exercise dynamic/fixed/counting holder sinks; Zig also
checks the streaming hash. Java checks poisoned heap/direct buffers and a
nonzero alignment origin. C/C++ deny CDR allocations during a fixed enum-array
holder plus MD5 calculation. Unit coverage checks extent overflow and typedef
flattening. The Java fixture also exposed scalar-filter classification of an
array typedef; such fields now skip scalar extraction instead of emitting an
invalid array `.getValue()` call.

## Compatibility and remaining scope

This is a generator change with no runtime ABI or ordinary sample-wire encoding
change. Regenerate bindings for affected schemas and deploy matching participants
together: changed key hashes change DDS instance identity, including for arrays
whose corrected maximum changes the MD5 policy. Persisted old key hashes need
an application-level migration or reset. Primitive-array keys are unchanged.

This fixes the enum/bitmask array subset, including nested aggregate and union
call sites through the shared array emitter. Canonical collection DHEADERs for
other non-primitive shapes, such as sequences of enums/bitmasks and arrays or
sequences of strings/aggregates, remain suppressed by the older generator path.
Their byte vectors and maximum-size policy need a separate correction. Existing
regression vectors for those shapes are not conformance evidence; the open
roadmap item records that limitation.
