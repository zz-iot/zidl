# Native canonical key checkpoint

This checkpoint follows [generated reader windows](native-cdr-reader-windows-slice.md).
The production runtime switch and final package move remain pending.

## Behavior

Generated C, C++ and Zig key hashes now use a separate canonical key-holder
serializer: big endian PLAIN_CDR2, maximum alignment four, zero padding and no
encapsulation, member headers or collection DHEADERs. The shared generator plan
projects nested aggregates recursively and orders members by their resolved IDs.
A nested structure without marked keys contributes all its members. Union
holders include the discriminator and active arm.

MD5 selection uses the type's maximum canonical size, rather than the current
value's size. Unbounded keys and maxima above sixteen bytes always use MD5.
Generated `KEY_HASH_FORCE_MD5` constants expose this policy; C/C++ prefix them
with the generated type name. The canonical wide-string helper writes a byte
count followed by UTF-16 units, without a terminator. Ordinary wire serialization
retains its existing behavior in this checkpoint.

Direct holder callers must supply a big endian writer with four-byte alignment
(e.g. an XCDR2 C writer with byte order set to BE). Generated hash entry points
configure their own sinks. Holder methods do not reset a caller-owned writer.

The native streaming hash, staged C adapter and fixed/counting writers share
canonical helpers. The temporary C reference implements the same additive C
APIs independently. Existing byte-only hash helpers retain their historical
length-based policy because they have no schema. Generated Zig also provides
`computeKeyHashChecked`; the existing total convenience method requires valid
values, while the checked method reports bound and storage errors.

## Compatibility and scope

Corrected hashes can change DDS instance identities. Regenerate and deploy
participating native bindings together, with the matching runtime; mixing old
and corrected participants for affected schemas is unsafe. The new holder APIs
are distinct from existing wire key-only serialization APIs. Public reader and
writer layouts are unchanged.

This is a supported-shape checkpoint, not a general conformance claim:

- The original member-ID limitation is addressed by the later
  [resolved member-ID checkpoint](native-cdr-member-ids-slice.md), covering
  sequential, inherited and hashed identities. The initial ordering witnesses
  here use explicit, unique IDs.
- Java's legacy key serialization/hash policy at this checkpoint is corrected
  in the [Java canonical key checkpoint](java-cdr-key-slice.md). The member-ID
  and ordinary wire limitations remain before a production switch.
- Ordinary wide-string wire encoding at this checkpoint still used a unit
  count and NUL. The later [wide-wire checkpoint](native-cdr-wide-wire-slice.md)
  corrects it across bindings. C++ wide strings accept UTF-16 units in `wchar_t`;
  conversion of Unicode scalar values to surrogate pairs remains separate.
- The mutable key-only framing mismatch is corrected in the later
  [key-wire checkpoint](native-cdr-key-wire-slice.md), which records its tested
  traversal shapes and remaining projection limits. This initial checkpoint's
  manually authored payload tests the read path independently of the serializer.
- Keyed union discriminators are not represented by the current AST/IR. Maps,
  optional selected members, long double, bitsets and other unsupported holder
  shapes are rejected for keyed roots. Unsupported unselected fields retain
  their ordinary wire support.

## Evidence

The [canonical fixture](../../test/integration/canonical_keys/README.md) contains
fifteen independent byte/hash witnesses, including RTPS 2.5's mutable nested-key
example. They exercise alignment, bounded maximum sizes, unbounded strings,
empty sequences, recursive projection, arrays, unions, wide strings and
inheritance. Tests compare bytes as well as hashes and cover dynamic, fixed and
counting sinks, both input byte orders and supported XCDR versions, invalid
bounds and allocator failure. The root `test-canonical-keys` target runs C/C++
against the independent C reference and Zig against the shared native core.

Compiler/backend tests pass all 1,120 cases. The focused fixture passes all
fifteen vectors in each native binding and three Zig tests. The staged package passes 98 tests (68 roundtrip and 30 targeted); the reference
package passes 68 roundtrip tests. The restored native runtime passes 93 tests.
The three canonical fixture tests also pass on Zig 0.16. Fresh system C/C++
consumers pass all fifteen vectors against the installed staged Debug archive,
and the system C API consumer links and runs with the new symbols in both
Debug and ReleaseSafe builds.
The full root `regen-goldens test` run succeeds: 116/116 build steps and
1,206/1,206 executed tests, with other steps cached. This includes independent
native/C/C++/Java XCDR known answers and all single/split golden checks.
Formatting, diff whitespace and checkpoint links pass; zzdds remains unchanged.
The existing Debug Maker workaround remains in use. No performance,
32-bit/big-endian-host or full zzdds validation is claimed.

Normative references: [RTPS 2.5 §9.6.4.8](https://www.omg.org/spec/DDSI-RTPS/2.5/PDF)
and [XTypes 1.3 §7.4.1.1.2](https://www.omg.org/spec/DDS-XTypes/1.3/PDF).

Next: follow the [Java key correction](java-cdr-key-slice.md) and
[resolved member identities](native-cdr-member-ids-slice.md), close the documented
wire gaps, extract the remaining fixed
BCD operations, then finalize package placement and the production build switch.
