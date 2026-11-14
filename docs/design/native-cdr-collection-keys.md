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

## Remaining variable-size collections

Arrays/sequences of strings, aggregates and nested collections still require a
separate delimiter-sizing plan in the native streaming path. C/C++ and Java can
back-patch their ordinary holder buffers, but all paths must agree on canonical
projection, nested collection boundaries and schema maxima. Existing regression
vectors for those shapes are not conformance evidence and must be replaced with
independently assembled witnesses when those paths are corrected.

Regenerate and deploy bindings for affected schemas together. Canonical bytes,
maximum-size flags and resulting hashes can change DDS instance identity. No
runtime ABI or ordinary sample-wire encoding change is required for the
fixed-width correction.
