# Optional wire conformance

Run `zig build test-optional-wire`; the root `test` target includes it.
Regenerate the independent vectors with `python3 make_vectors.py` in this directory.

`vectors.txt` has sixteen rows:

```
type present version byte_order extended_payload_hex compact_payload_hex
```

Byte order is 0 for LE, 1 for BE. The separate Python encoder follows XTypes 1.3
§7.4.1.1.5.2, §7.4.1.2 and §7.4.3.5.2, including value-local alignment and exact
lengths. It does not call zidl or either CDR runtime. XCDR1 writers use legal
extended headers; readers must also accept the equivalent compact headers.
XCDR2 retains boolean presence, so both payload columns coincide.

The two shapes cover absent/present scalar, string, array-valued aggregate and
bounded string-sequence optionals; ID 0, the highest short ID and an extended ID;
nested optionals; and inherited APPENDABLE fields. `Pair` places its array inside
a supported optional aggregate because direct optional C++ array declarations
remain unsupported independently of this framing fix.

C/C++ and Zig verify all rows in dynamic/fixed/counting modes and exercise
ordinary and recursive key-value methods. Reads check values, every truncated
prefix and frame restoration. Fixed writes fail at every insufficient capacity.
C tracks allocation/free sizes and injects failures; Zig exhausts allocator
failure points and checks selective reads and field getters, including cleanup
when a later field is truncated. The C++ condition contract fixture separately
checks optional selective reads/getters with and without exceptions.

Both Java output modes verify the eight LE rows, compact headers, decoded values,
read-only buffers, all truncated prefixes, reader limits, selected reads and
field getters. Java's generated ordinary entry points remain LE-only. The test
compiles the codec classes explicitly; emitted middleware wrapper classes are
not needed to exercise their pure selected-reader APIs.

These are key-value traversal tests, not an extension of supported canonical key
shapes. Optional canonical key members remain unsupported.
