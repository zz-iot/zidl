# Inherited and recursive key-wire witnesses

`python3 make_vectors.py` regenerates `vectors.txt` using only Python's `struct`
and `hashlib`. It does not invoke zidl or inspect generated output. Each row is:

```text
type XCDR-version byte-order full-sample-hex key-only-hex canonical-hash-hex
```

Byte order is 0 for LE and 1 for BE. There are 24 rows across eight root types.
FINAL and APPENDABLE roots without mutable descendants cover both versions;
mutable key-value descendants cover XCDR2. Inheritance has one aggregate frame,
with base members first. Wire fields retain declaration order; canonical hashes
use the independent FINAL, BE, four-byte-aligned holder. Unbounded string key
types force MD5 even when the supplied value fits within sixteen bytes.

The fixture covers a three-level FINAL hierarchy, APPENDABLE/MUTABLE inheritance,
an optional non-key base member, keyless intermediary structures (including one
with a keyless base), and array/sequence typedefs plus bounded/unbounded sequences containing keyed
descendants.
Non-key values are deliberately nonzero so full-sample serialization cannot
accidentally pass a key-only byte comparison. The optional-member witness uses
a mutable XCDR2 base; XCDR1 optional-member encoding is a separate follow-up.

`zig build test-key-projection` runs Zig, C, C++, and both Java output modes when
a JDK is available. It is also part of `zig build test`. Checks include exact
bytes, hashes, sizes, dynamic/fixed/counting writers, truncated prefixes,
shortened nested frames with valid bytes following, allocation failures and
cleanup. Java reads use read-only buffers and verify parent limits are restored.

Normative basis: XTypes 1.3 §§7.2.2.4.5, 7.2.2.4.7, 7.4.1.1.5.1 and 7.6.8;
RTPS 2.5 §9.6.4.8. These witnesses implement the stated layout rules directly;
they are not a claim of external-peer interoperability or exhaustive conformance.
