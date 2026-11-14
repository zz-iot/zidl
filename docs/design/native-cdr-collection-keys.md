# Canonical collection key framing

This follows the [array-key correction](native-cdr-array-keys.md). XTypes 1.3
§7.4.3.5.2 rules (11)–(13) distinguish primitive sequences from non-primitive
sequences. FINAL aggregate projection in §7.6.8 does not remove a collection's
XCDR2 DHEADER. The delimiter is the payload byte count, including the sequence
count. Empty non-primitive sequences therefore encode a four-byte payload.

## Fixed-width enum/bitmask sequences

C, C++, Java and Zig write the known payload `4 + count * element_width` before
sequence elements, with a checked UINT32 extent. Aliases resolve to the element
holder width. Schema maximum sizing includes both delimiter and count, so a
sequence bounded at two 32-bit enums has maximum 16, while a bound of three has
maximum 20 and uses MD5 even when its current value is empty. Primitive sequence
encoding is unchanged. The native streaming writer needs no back-patching or
scratch allocation for these fixed-width payloads.

The existing fixture now includes fifteen sequence witnesses plus nine array
witnesses. `make_array_key_vectors.py` uses explicit schema maxima separately
from actual encoded lengths. Its only dependencies are Python packing/hashlib.
The optional `check_cyclone_arrays.py` check compares all 24 byte sequences and
maximum-size policies with explicit Cyclone KEYHASH-mode extraction. See the
array checkpoint for the API and local Cyclone source/build provenance.

Compiled tests check all four backends, both Java output modes, both XCDR
versions, full-wire hash callbacks, empty/nonempty values, one/two/four/eight-byte
holders, aliased elements/sequences, zero padding and the 16-byte/MD5 boundary.
Native and C tests reject an overflowing native count before walking its buffer;
bound errors are also exercised. Generic dynamic/fixed/counting and streaming
checks run through the shared fixture.

## Variable-size collections

Arrays/sequences of strings, aggregates and nested collections now retain their
collection DHEADERs in all four backends. C/C++ and Java back-patch buffered
holders. Zig emits a private generic collection-body function once per shape in
a holder, measures that body with the existing counting `PrimitiveWriter`, writes
the checked UINT32 size, then calls the same body with the real writer. Both passes
share schema traversal, including nested helpers and projected aggregate members.
A DHEADER puts its payload at a four-aligned position, so a counting writer with
origin zero gives the same payload extent at any caller offset. This stores no
encoded scratch bytes. It adds traversal work (including nested sizing passes),
not an allocation or a separate encoding implementation.

Schema maxima include collection delimiters and inter-element padding. Array
member dimensions and array typedef dimensions flatten into one collection
extent; a sequence of array values retains the separate delimiter for each
non-primitive array element. Aggregate FINAL projection remains unchanged.
Native bounded string/wstring guards reject invalid lengths during sizing before
slicing. Existing ordinary sample and key-only wire encodings are unchanged.

`make_variable_key_vectors.py` independently assembles twelve additional witnesses
using Python byte packing and explicit maximum-size witnesses. These cover string
arrays/grids, empty/short sequences, aggregate elements, nested primitive sequences,
sequences of enum arrays, variable union arms, an odd-offset enclosing struct,
and UTF-16 wide arrays. All four backends consume the same witnesses (56 total
canonical fixture cases). A denied CDR allocator verifies fixed variable holders
and MD5 remain allocation-free at that layer. Native counting and streaming paths
share the same body, and invalid bounded string values are tested.

The older `ArrayKey`, `SeqAgg` and `WideSeq` expectations have been corrected,
as have the dependent key-wire hashes and the key-projection fixture's
`RootArray`/`RootSeq` hashes. Their independent generators now retain collection
headers while continuing to omit projected aggregate headers. Full-sample and
key-only wire byte columns remain unchanged.

## Independent implementation observations

The local Cyclone build agrees with 34 of the 36 collection byte sequences and
schema policies: the original nine arrays, fifteen fixed-width sequences and ten
of the twelve variable witnesses. Two cases are explicitly distinguished:

- Cyclone IDLC rejects a union collection as part of a key. `UnionSeq` remains in
  normal zidl tests with its specification-derived witness, but an oracle-only
  preprocessor guard omits it from that optional vendor build.
- `WideArray` differs in the local Cyclone KEYHASH extraction: expected
  `0000000c000000020041000000000000`, observed
  `0000000c000000024100000000000000`. Its size policy agrees, but the UTF-16 unit
  appears in native byte order. The default oracle check reports failure.
  Passing `--exclude WideArray` explicitly prints both observations and checks the
  remaining 34 witnesses. Expected bytes are never rewritten to follow the vendor.

A separate local Fast CDR 2.3.5 probe of ordinary XCDR2 BE serialization of
`std::array<std::wstring,2>{L"A",L""}` emitted
`0000000c000000010041000000000000`: the unit is BE but the length is one rather
than two bytes. This was an ordinary value serializer check, not KEYHASH extraction
or a schema-policy check, and is not used as an oracle. XTypes 1.3 rule (4) and
the existing independent wide-wire witnesses remain the basis for the wide array
expectation. These vendor observations do not change the encoding contract.

## Compatibility and scope

Regenerate and deploy bindings for affected schemas together. Canonical bytes,
maximum-size flags and resulting hashes can change DDS instance identity.
Stored hashes may require migration or reset. Collection framing uses existing
runtime writer APIs; no runtime ABI or ordinary sample-wire encoding change is
required. C bounded string/wstring member array declarations additionally need
the preceding dimension-layout fix, which changes native strides; it is isolated
on `fix/c-bounded-string-array-layout`.

This covers the canonical collection shapes accepted by the existing key-holder
validator. It does not add map, optional-key, bitset or other unsupported key
mappings. Bounded string/wstring typedef storage in C remains a separate known
coverage gap; the fixtures use supported direct bounded member arrays.

## Local validation

The fixed-width sequence slice, bounded C array-layout prerequisite and completed
variable collection stack each passed `zig build test integration-test
interop-test` (205/205 build steps per run). The final variable run reused passing
unaffected steps after correcting the projection-vector hashes. The focused
canonical fixture passed in C/C++/Zig and Java single/split modes. Formatting,
whitespace and local documentation links pass. All vector generators reproduce
their committed output; a separate comparison verifies that full-sample and
key-only wire byte columns are unchanged.
