# Inherited frames and recursive key-only values

Date: 2026-11-07

Status: implemented and validated locally. The C
reference remains the default; package placement and production migration are
unchanged.

## Audit findings

The mutable key-wire checkpoint routed explicitly keyed nested structures through
key-only codecs. A structure with no keys still used its full serializer, so a
keyed descendant behind that structure included its non-key members. Arrays,
sequences and aliases could carry the same gap.

Inheritance exposed related ordinary-wire problems. FINAL writers delegated to
their base and happened to produce flat bytes, but APPENDABLE writers added a
base DHEADER and MUTABLE writers omitted base members. Java ordinary decoders
also omitted inherited values. Several C key-hash callbacks had a separate
member walk that missed inherited keys even when the public key reader worked.
The new C fixture reproduces an inherited-key callback failure with the generator
from merged PR #67, independently of the replacement implementation.

XTypes 1.3 §7.4.1.1.5.1 requires the representation to behave as though inherited
members were declared first in the most-derived structure. Its §7.2.2.4.7 defines
a keyless structure's related key-holder with all members designated as keys.
Canonical hashing has its separate member-ID order, FINAL representation and
recursive rules in §7.6.8 and RTPS 2.5 §9.6.4.8.

## Implementation

The generator-side field plan now exposes declaration order across all ancestors
without sorting or introducing a base frame. Normal serializers and nested
key-value serializers use the same native emitter; key-value mode filters keys
when any exist, otherwise retaining all members and recursively projecting
structure-valued members. Arrays, sequences and aliases preserve that mode.
Member IDs still come from the resolved IR.

Generated C/C++ add `*_serialize_key_value` / `*_deserialize_key_value`. Zig adds
`serializeKeyValue` / `deserializeKeyValueInto`; Java adds `serializeKeyValue` /
`deserializeKeyValue`. Existing keyed-topic entry points delegate to them.
Keyless topics retain their empty key body, existing framing and zero instance hash;
projecting a nested value does not make its type a keyed topic.

C and C++ access inherited storage through the original base subobject, preserving
value layouts. Zig accesses `_base` paths. Java uses inherited public accessors,
keeping private fields private in split output. The C key-only hash callback
delegates to the same bounded decoder, hashes only after success and frees the
zero-initialized value on either outcome. C++ retains RAII cleanup. Zig key readers preserve partial values for caller
cleanup, while normal full readers retain their rollback path. Projected
sequence temporaries release partial allocations before ownership transfers to
the sequence.

Projected native reads retain aggregate/member/collection windows. Java projected
reads now enforce APPENDABLE and collection ends as well as mutable member ends,
restoring parent limits on failure. The split Java alignment helper advances the
cursor without writing into input, matching single-file output and permitting
read-only buffers; canonical padding still uses explicit zero writes.

## Compatibility and limits

Affected schemas require coordinated regeneration. Inherited APPENDABLE/MUTABLE
full samples and recursively projected key-only payloads can change. Canonical
hashes and TypeObjects are unchanged; readers recover the same instance hash
from valid full and key-only samples. Public C runtime symbols and layouts are
unchanged; the added functions belong to generated application codecs.

The witnesses keep keys in the root base and use matching extensibility through
inheritance, as required by XTypes §7.2.2.4.5. This slice does not change compiler
acceptance of invalid derived key/extensibility declarations. Existing unsupported
key shapes, including maps, optional key members and keyed union discriminators,
remain outside this checkpoint. Unkeyed union wire behavior is unchanged.
Mutable key-only XCDR1 remains unsupported. Optional inherited-member witnesses
use mutable XCDR2. The existing FINAL/APPENDABLE XCDR1 optional-member encoding
uses a boolean presence marker and needs a separate parameter-header conformance
follow-up; this checkpoint does not certify it. Java ordinary wire APIs remain LE;
its broader full-sample frame-validation gaps are not redesigned here.

## Evidence

The [fixture](../../test/integration/key_projection/README.md) has 24 independent
full/key-only payload pairs and expected hashes: eight shapes, LE/BE and the
applicable XCDR1/XCDR2 encodings. It covers multi-level inheritance, optional
non-key base members, keyless intermediaries, inherited keyless intermediaries,
and array/sequence typedefs, bounded and unbounded sequences carrying nested
mutable keys.

Checks exercise dynamic/fixed/counting output, exact bytes and cursor sizes,
ordinary/key-only decoding, both hash callbacks, every truncated prefix, and
shortened frames with valid following bytes. A tracking C allocator checks exact
free sizes and injected failures; native tests check caller cleanup at every
allocation failure. Both Java output modes use read-only input and validate restored limits.
A wrapper regression checks that a FINAL keyless topic still has no key bytes.

The final root run passes 129/129 steps and 1,206/1,206 executed tests (other
steps cached), including all 1,123 compiler/backend tests and golden checks.
The focused fixture passes 18/18 steps and all three native tests; C, C++ and
both Java modes pass every applicable witness. Native fixture tests also pass
with generated Zig 0.16 output. Integration and interoperability targets pass
37/37 steps and all ten interop tests.

Fresh system GCC/G++ consumers pass all vectors against installed shared Debug
and ReleaseSafe archives, compiled with `-Wall -Wextra -Werror`. The C sequence
size guard uses equivalent inverse division to avoid GCC's 64-bit type-limit
warning while retaining overflow checks. Independent vector regeneration,
formatting, whitespace and checkpoint links pass. Runtime package sources and
zzdds remain unchanged; package suites are not repeated for this generator-only
slice. The existing Debug Maker workaround remains in use.

Next: the XCDR1 optional-member follow-up and shared fixed-point BCD extraction,
then package placement and production build/consumer migration. No new platform
CI, performance or zzdds integration claim is made here.

References: [XTypes 1.3](https://www.omg.org/spec/DDS-XTypes/1.3/PDF),
[RTPS 2.5](https://www.omg.org/spec/DDSI-RTPS/2.5/PDF).

The subsequent [optional-wire checkpoint](native-cdr-optional-wire-slice.md)
addresses the XCDR1 optional-header and alignment finding above.
