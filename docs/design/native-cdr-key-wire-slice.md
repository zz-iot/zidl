# Mutable key-only wire framing checkpoint

This follows [ordinary wide-string wire encoding](native-cdr-wide-wire-slice.md).
Generated C, C++, Zig and Java keyed mutable serializers now emit XCDR2
DHEADER/EMHEADER frames rather than plain key fields. They share each backend's
normal mutable writer generator, selecting only marked key members and keeping
resolved member IDs, MU flags, length codes and checked patch behavior.

## Behavior

Nested keyed structures use their wire key methods during key serialization and
key decoding, including through arrays and sequences. This omits their non-key
members and keeps nested mutable frames valid. Ordinary full-sample methods
retain full-value traversal. Canonical hash holders remain separate: their
FINAL, BE, four-byte-aligned representation is not the key-only wire format.
Mutable wire members remain in declaration order; a receiver may also accept a
valid reordered member list. The existing manually authored RTPS example payload
therefore remains a decoder witness alongside the new serializer-order witness.

Keyed mutable wire methods reject XCDR1/PL_CDR instead of emitting or trying to
read a PL_CDR2-shaped payload under that encoding. C/C++ report INVALID, Zig
reports UnsupportedKeyEncoding, and Java throws IllegalArgumentException.
The separate discovery ParameterList codec and its strict/lenient policy are
unchanged.

Native/C/C++ key reads retain the shared reader/member windows. Java mutable
key reads now also validate the complete DHEADER, bound individual member
payloads, restore parent limits on success/error and skip unknown member tails.
Its EMHEADER length arithmetic uses unsigned values and wide intermediates,
rejecting unrepresentable or unavailable lengths. Unknown MU members are
rejected; ordinary unknown members are skipped. These changes apply to key-only
reads; Java full-sample frame handling is not redesigned here.

The existing APIs and C reader/writer layouts are retained. Callers should use
`compute_key_hash_from_cdr` / `computeKeyHashFromCdr` for complete ALIVE data;
the explicitly named key-only variants are for actual key-only payloads. In
particular the existing final/appendable leading-key constraints are not relaxed
by a mutable framing correction.

## Scope and compatibility

Previously emitted mutable key-only payloads did not match the generated
mutable decoders. Corrected participants must be regenerated/deployed together;
persisted malformed key payloads require application-level migration. Canonical
key hashes and TypeObject identities are unchanged by this framing correction.
Generated writers need the same checked framing capabilities as their full
mutable serializers; no new runtime symbols are introduced.

This checkpoint covers mutable framing and traversal into explicitly keyed
nested structures. It does not claim exhaustive KeyHolder wire projection:
inheritance and keyless intermediary aggregates that themselves contain keyed
aggregates still need a dedicated projection/decoder audit before a production
switch. Existing keyless aggregate leaf values and non-keyed union values retain
their complete-value behavior. Keyed union discriminator representation remains
unsupported as recorded in the earlier checkpoints.

## Evidence

The [common fixture](../../test/integration/canonical_keys/README.md) adds fourteen
independently assembled key-only payloads (seven shapes, LE/BE). They cover
mutable scalar/nested roots, sequential/HASH IDs, arrays/sequences of keyed
mutable structures, and a keyless scalar aggregate leaf. The standalone
`make_key_wire_vectors.py` uses struct packing and hashlib, without invoking zidl
or reading generated output. Each witness checks exact dynamic/fixed/counting
writer bytes and the expected canonical instance hash after key decoding.

Tests reject every truncated prefix, shortened outer/nested/member lengths with
valid bytes still after the bound, MU members, and LC 4–7 oversized lengths.
Future member tails, unknown non-MU members and reference LC=5 string headers
are accepted. C error paths preserve the output hash. A tracking allocator proves
that a sequence buffer allocated before a nested decode failure is freed with
the correct size. Native error paths restore reader bounds; Java restores parent
ByteBuffer limits. Unsupported mutable key XCDR1 is checked before body writes.

C/C++ test runs now register their sidecar wire vectors as build cache inputs;
Java does the same, so an oracle-only edit invalidates the run cache.

The full root run passes 113/113 build steps and 1,212/1,212 executed tests,
with other steps cached, including all 1,126 compiler/backend tests, independent
XCDR known answers and single/split golden checks. The focused fixture passes
18/18 steps and all eight native tests; the build-input follow-up also passes
18/18 steps. Both Java output modes and C/C++ pass the new key witnesses and
boundary/cleanup checks. Fresh system C/C++ consumers pass against the installed
staged Debug archive, and all eight native fixture tests pass Zig 0.16.
Formatting, whitespace, independent-vector reproducibility and checkpoint links
pass; zzdds remains unchanged. Runtime packages were
unchanged from the wide-wire checkpoint; their package suites are not repeated.
The existing Debug Maker workaround remains in use. No performance,
other-platform execution or full zzdds integration claim is made.

Next: finish the remaining key-only projection shapes, then fixed BCD extraction,
package placement and the production build switch.
