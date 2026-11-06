# Resolved XTypes member IDs

The IR builder resolves structure and union member IDs after local and imported
type definitions are filled. Generated C, C++, Zig, Java and MinimalTypeObjects
consume the same resolved value. Explicit annotations remain available separately.

Sequential assignment starts at zero for structures and continues after the
previous ID, including explicit/hash IDs and the last inherited member. Empty
bases do not reset numbering. Union case numbering starts after discriminator
ID zero. Each case, including the default case, has one ID regardless of how
many labels select it.

Type `@autoid` overrides the nearest annotated containing module. Imported,
nested and reopened modules participate; conflicting modes on reopenings fail.
No annotation means SEQUENTIAL; bare `@autoid` means HASH, per IDL 4.2.
`@id` accepts scoped integer constant expressions. `@hashid` hashes its supplied
string, or the member name when omitted/empty. Hashing uses MD5's first four
bytes interpreted little endian and masked to 28 bits.

Duplicate annotations/IDs, inherited collisions, hash collisions, reserved IDs
and overflow fail during IR construction. XTypes application IDs end at
`0x0fffbfff`; general IDL exception annotations retain their 32-bit range.
Minimal structure and union member sequences are ordered by member ID.

Affected schemas can change mutable wire headers, TypeObject hashes and key
ordering. Coordinate regeneration across participants. Reader/writer ABI layouts
and ordinary declaration-order wire serialization are unchanged.

References: [XTypes 1.3](https://www.omg.org/spec/DDS-XTypes/1.3/PDF)
§§7.2.2.4.4.4, 7.3.1.2.1.1 and Annex D;
[IDL 4.2](https://www.omg.org/spec/IDL/4.2/PDF) §8.3.1.2.
