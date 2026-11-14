# Independent canonical key vectors

Run `zig build test-canonical-keys` from the repository root (or use the documented
Debug Maker workaround). C and C++ use the reference C runtime in this target;
Zig uses the staged shared core. When a JDK is available, Java runs the same
vectors in single-file and split/package output modes.

`vectors.txt` has four whitespace-separated columns: case, canonical bytes in
hex, sixteen-byte hash in hex, and force-MD5 policy (0/1). Bytes were assembled
from the IDL and canonical encoding rules, independently of generated codecs.
Digests were checked using Python `hashlib.md5`. The `Example` vector is the
RTPS 2.5 §9.6.4.8 mutable/nested-key example with `m_long=0x12345678` and
`label="BLUE"`, whose digest is `374b96e2e727237f016cc4cebb6eb71e`.

The maximum-size witnesses distinguish actual length from schema maximum:
`Bounded16`/`Bounded17` have maxima 16/17; `Seq16`/`Seq17` also have maxima
16/17 even when empty; `Wide16`/`Wide17` have maxima 16/18. Unbounded keys always
use MD5. `Align` places a u64 at offset four. `Example` and `Derived` explicitly
order keys by ID. Nested key projection, nested aggregates without marked keys,
aggregate arrays/sequences and active union arms have separate witnesses.

Tests compare holder bytes for dynamic/fixed/counting sinks, type-policy hashes,
full-wire decode/hash paths, and a hand-authored mutable key-only payload.
Unsupported XCDR1 mutable paths are excluded. C additionally denies allocations
to prove a fixed holder/hash path does not need allocation and that the allocating
convenience API reports failure without modifying the output hash. Native Zig
checks invalid bounded sequence length through its checked API.

See the [checkpoint](../../../docs/design/native-cdr-key-slice.md) for migration
requirements and the outstanding Java, member-ID and ordinary wire encoding gaps.

Java additionally checks poisoned heap/direct buffers at nonzero origins,
variable union arms, UTF-16 surrogate pairs, buffer-growth retries, bounds,
full-wire hash paths and the hand-authored mutable key-only payload. See the
[Java checkpoint](../../../docs/design/java-cdr-key-slice.md).

The [member-ID checkpoint](../../../docs/design/native-cdr-member-ids-slice.md)
adds four cases (nineteen total): `Sequential`, `Hashed`, `AutoDerived` and
`UnionDefault`. `wire_ids.txt` holds hand-authored full XCDR2 LE payloads for
`Sequential` (IDs 8,9,2,3), `Hashed` (IDs 0x0fa5dd70,0x047790da) and the
`UnionDefault` wrapper (discriminator ID 0, default arm ID 11). All bindings
compare exact wire bytes in addition to decoding and hashing.

`typeobjects.txt` contains independent MinimalStruct TypeObject bytes and
fourteen-byte EquivalenceHashes (MD5 excluding the encapsulation header).
Regenerate it with `python3 make_typeobject_vectors.py`; that script assembles
the XTypes layout from hand-listed schema identities/types and standard Python
libraries, without invoking zidl. Native tests compare generated constants to
both payloads and hashes.

The [ordinary wide-wire checkpoint](../../../docs/design/native-cdr-wide-wire-slice.md)
adds `WideSeq` (twenty canonical vectors total) and `wide_wire.txt`, sixteen
hand-authored payloads covering XCDR1/XCDR2, LE/BE, empty/BMP/UTF-16-pair values
and bounded sequences of wide strings. Native and C/C++ tests compare bytes,
decode/hash, and reject every truncated prefix. Java tests compare generated LE
payloads in both output modes; split helper tests also check BE/read-only input.
Wide lengths count bytes and there is no wire terminator. The C-owned result's
local sentinel is separate from this encoding.

The [mutable key-wire checkpoint](../../../docs/design/native-cdr-key-wire-slice.md)
adds `key_wire.txt`: fourteen independent XCDR2 key-only payloads (seven shapes,
LE/BE) plus canonical hashes. `make_key_wire_vectors.py` reconstructs them using
explicit schema IDs, length codes, standard packing and hashlib. The mutable
Example's serializer-order payload is 48 bytes; the earlier reordered decoder
witness is 45 bytes. Both yield the same normative canonical digest.

Checks cover dynamic/fixed/counting key writes, decode/hash, every truncated
prefix, nested/member/root windows with valid trailers, future member tails,
reference LC=5, unknown/MU members and LC 4–7 size overflow. A C tracking allocator
checks cleanup after a sequence buffer is allocated and a nested key read fails.
Java checks parent-limit restoration; native Zig checks reader-bound restoration.
Sidecar wire files are explicit C/Java run-cache inputs.

The [array-key checkpoint](../../../docs/design/native-cdr-array-keys.md) adds
`array_keys.idl` and nine canonical witnesses in `array_vectors.txt`. Regenerate
those bytes and hashes with `python3 make_array_key_vectors.py`; the script uses
only standard Python packing/hashlib and explicit XTypes rules. The normal key
suite checks all four backends, including Java single/split output, and fixed,
counting, dynamic and native streaming paths. Enum/bitmask widths, nested array
typedefs, alignment, and schema maxima at 16/17/20 bytes are covered. A denied CDR
allocator verifies the fixed array-holder plus MD5 path remains allocation-free.

Optionally check an independent implementation without networking or packet
capture:

```sh
python3 check_cyclone_arrays.py --cyclone /path/to/cyclonedds
```

This uses an already built Cyclone tree (`build/bin/idlc`, `build/lib/libddsc`)
and a system C compiler. It generates types from the same IDL and extracts
XCDR2 BE keys in explicit `DDS_CDR_KEY_SERIALIZATION_KEYHASH` mode. All fields in
these FINAL fixtures are keys, so the input native sample is also a key-only
sample. It compares bytes and the schema-based fixed-key/MD5 flag with the
independent Python witnesses. No Cyclone dependency is added to normal CI.

The [collection-key checkpoint](../../../docs/design/native-cdr-collection-keys.md)
corrects the earlier aggregate/string collection expectations, including dependent
key-only and projection hashes. Aggregate extensibility headers stay omitted;
collection DHEADERs are retained.

The [collection-key checkpoint](../../../docs/design/native-cdr-collection-keys.md)
extends the same independent oracle and optional Cyclone check to fifteen
fixed-width enum/bitmask sequence witnesses (24 collection witnesses total).
These distinguish actual extent from schema maximum, including empty sequences
that still require MD5, overflow guards, alias chains and primitive controls.

`make_variable_key_vectors.py` adds twelve variable collection witnesses in
`variable_vectors.txt` and corrects `ArrayKey`, `SeqAgg` and `WideSeq` in the older
vector file. Also run `make_key_wire_vectors.py` to refresh dependent hashes.
The key-projection fixture's independent `make_vectors.py` now retains collection
delimiters in `RootArray` and `RootSeq` canonical bytes too; wire byte columns do
not change. All 56 canonical cases run in every backend fixture.

With the documented local Cyclone build, the default optional oracle reports a
wide-string byte-order disagreement and IDLC does not support union collection
keys. `UnionSeq` is specification-only in that check. To explicitly exclude the
observed wide-array discrepancy and check the other 34 collection witnesses:

```sh
python3 check_cyclone_arrays.py --cyclone /path/to/cyclonedds --exclude WideArray
```

The command prints the excluded expected/observed bytes. It does not replace
expected bytes or claim agreement for the excluded cases. See the checkpoint for
exact observations, including the separate Fast CDR wide-length probe.
