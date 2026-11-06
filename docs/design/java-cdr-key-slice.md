# Java canonical key checkpoint

This follows the [native canonical key checkpoint](native-cdr-key-slice.md) and
closes its Java hash-policy gap for the supported holder shapes. Java remains
an independent Java codec; no native codec dependency or shared Java runtime
package is introduced.

Generated Java structures and unions now expose `serializeKeyHolder(ByteBuffer,
int base)`. Structures use the same generator-side recursive projection and
member ordering as C/C++/Zig; unions contribute the discriminator and active
arm. Holders omit aggregate/member/collection headers, cap alignment at four,
and explicitly write zero padding even into reused or direct buffers. Narrow
strings use UTF-8 bytes plus NUL; wide strings use UTF-16 code units with a byte
count and no terminator. Bounded strings and sequences reject oversized values
with `IllegalArgumentException`.

Generated keyed structures expose `KEY_HASH_FORCE_MD5`, computed by the shared
type-maximum-size analysis. `computeKeyHash()` configures a big endian holder
sink and passes that policy to the hash helper. Its buffer-growth retry now
checks capacity overflow. Existing byte-only helper signatures retain their
length-based compatibility policy through an overload. Full-wire and key-only
hash entry points continue to decode to language values and then call the
corrected hash method.

Direct holder callers supply a big endian buffer and the origin of the holder
as `base`; the method preserves the buffer's byte order. Null or otherwise
invalid language values are not accepted as valid keys. Hashing allocates Java
buffers; no allocation-free or performance claim is made.

## Compatibility

Corrected Java hashes can change instance identities just as the native
corrections do. Regenerate and deploy affected participants together. Ordinary
Java wire serializers and wire key-only serializers retain their existing
encoding in this checkpoint. The subsequent [wide-wire checkpoint](native-cdr-wide-wire-slice.md)
replaces the Java ordinary wstring UTF-8 path with the proper UTF-16 byte-count
representation alongside the native corrections.

The later [resolved member-ID checkpoint](native-cdr-member-ids-slice.md)
addresses the identity normalization limitation across all four generators. Unsupported holder shapes and keyed union discriminator
representation also retain the documented limitations. Canonical hash parity
does not establish general wire conformance or authorize the production switch.

Compiling the fixture in split mode also exposed two existing generation
problems: local references retained module qualification despite flattened
output, and union files did not import the CDR helpers. Local split references
now use the generated top-level class name; union files import the helpers.
Imported cross-file naming retains its separate resolver. The fixture uses a
Java package in split mode, so static helper imports are valid Java.

## Validation

`test-canonical-keys` now runs Java when a JDK is available, in both single-file
and split/package output modes. The same fifteen independently authored byte and
hash vectors are used by C, C++, Zig and Java, including the normative RTPS
mutable/nested-key example. Java tests also cover poisoned heap/direct buffers,
nonzero origins, a variable union arm, UTF-16 surrogate pairs, growth beyond the
initial hash buffer, UTF-8 byte bounds, wide/sequence bounds, XCDR1/XCDR2 full-wire
hash paths and the manually authored mutable key-only payload.

The focused target passes 18/18 build steps and all three native Zig tests;
C/C++ and both Java output modes pass all fifteen vectors. Formatting,
diff whitespace and checkpoint links pass. The full root `test` run passes
113/113 build steps and 1,206/1,206 tests, including all 1,120 compiler/backend
tests, both Java key modes, independent native/C/C++/Java XCDR known answers,
Java integration and single/split golden checks. zzdds remains unchanged.
The existing Debug Maker workaround is still used for the Zig build.
No zzdds integration, other-platform or performance measurement is claimed.

Member-ID normalization follows in the [resolved identity checkpoint](native-cdr-member-ids-slice.md).
The remaining work is ordinary wire interoperability, BCD extraction, package
placement and the production switch.
