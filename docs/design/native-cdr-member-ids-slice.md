# Resolved member-ID checkpoint

This follows [canonical Java keys](java-cdr-key-slice.md). Struct and union member
identities are now normalized in the compiler IR after local and imported type
skeletons are filled. C, C++, Zig, Java, canonical key projection and native
MinimalTypeObject generation consume that identity.

## Assignment and validation

Without an applicable annotation, numbering is sequential. The first struct
member starts at zero; each implicit member follows the preceding member's ID,
even when that ID was explicit or hashed. Derived structures continue from the
last inherited member's ID, including through empty base structures. This uses
the last declared member, not the largest ID. Multiple declarators receive
separate sequential identities.

Type-level `@autoid` overrides the nearest annotated containing module. Nested,
reopened and imported modules participate. Conflicting modes on openings of the
same module are rejected. `@autoid` without an argument uses HASH, as specified
by IDL 4.2; absence of the annotation defaults to SEQUENTIAL for XTypes.

`@id` accepts integer constant expressions in IDL scope and takes precedence over
automatic assignment. `@hashid`, `@hashid("")` and named/string-constant forms
use the member name or supplied string. Hash IDs are the first four MD5 bytes of
the UTF-8 string, interpreted little endian and masked to 28 bits. The normative
`color` and `shapesize` examples produce `0x0fa5dd70` and `0x047790da`.

XTypes structure/union validation applies the application member-ID range;
general IDL exception annotations retain their 32-bit range. The builder rejects
duplicate or conflicting identity annotations, duplicate
IDs (including inherited members and hash collisions), malformed values,
reserved/out-of-range IDs and sequential overflow. It does not probe for an
alternative ID after a collision. The application range ends at `0x0fffbfff`.
Union wire discriminator identity remains zero; case numbering starts at one
and continues through the default arm. Keyed discriminator representation
remains outside this checkpoint.

Explicit annotation values and raw annotations remain available in the IR;
`resolved_id` stores the assigned identity separately. The backend accessor's
fallback supports hand-built IR; compiler-built structure/union members always
have resolved IDs. Existing experimental typesupport-library annotation gates
remain unchanged.

## Consumers and compatibility

Mutable wire headers and dispatch, discovery ParameterList IDs, canonical key
ordering and MinimalTypeObject member identities use the same accessor. Minimal
structure member sequences are now sorted by ID, as required by XTypes; ordinary
wire structure fields retain declaration order. TypeObject hashes therefore
also reflect the corrected identities/order.

The union witness exposed an existing C/C++ bug: mutable default-arm values were
omitted from serialization and deserialization. Both paths now emit/read the
arm, and Zig/Java use its resolved identity instead of an invalid sentinel ID.

Affected schemas can change mutable wire IDs, canonical instance hashes and
TypeObject hashes. Regenerate and coordinate participating bindings together;
this is a wire/schema compatibility correction, not just an internal refactor.
Public CDR reader/writer layouts are unchanged. This does not establish general
mutable-inheritance wire support or remove the existing wide-string and mutable
wire key-only issues documented in the prior checkpoints.

## Evidence

The common [canonical fixture](../../test/integration/canonical_keys/README.md)
now has nineteen independent byte/hash vectors. Four new cases cover explicit
then implicit numbering, HASH/renamed hash IDs, inherited numbering after a
lower explicit ID, and a mutable union default arm. All four bindings check the
canonical witnesses. Three hand-authored complete XCDR2 wire payloads separately
verify actual member IDs, and two independently assembled MinimalTypeObject
payloads and hashes verify identities and sorted ordering. The standalone
`make_typeobject_vectors.py` uses schema constants, struct packing and hashlib;
it does not import zidl or read generated output.

Six builder tests cover numbering, module/type overrides, imports, constant
expressions, normative hashes, unions, collision and invalid-input rejection.
The focused target passes 18/18 build steps and five native tests; C/C++ and
both Java output modes pass all nineteen vectors. All five fixture tests also
pass Zig 0.16. System C/C++ consumers pass all nineteen vectors and wire-ID
witnesses against the installed staged Debug archive. The independent Python
TypeObject vector script reproduces its checked-in payloads/hashes. Formatting,
whitespace and checkpoint links pass; zzdds remains unchanged.
The full root suite passes 113/113 build steps and 1,204/1,204 executed tests,
with other test steps cached, including all 1,126 compiler/backend tests,
independent native/C/C++/Java XCDR known answers and single/split golden checks.
Final builder-only verification passes all 47 tests after scoping range
validation to XTypes structures/unions. Runtime packages are unchanged from the
previous checkpoint and their package checks were not repeated.

Normative references: [XTypes 1.3 §§7.2.2.4.4.4, 7.3.1.2.1.1 and Annex D](https://www.omg.org/spec/DDS-XTypes/1.3/PDF),
[IDL 4.2 §8.3.1.2](https://www.omg.org/spec/IDL/4.2/PDF).
The existing Debug Maker workaround remains in use. No performance,
other-platform execution or full zzdds integration claim is made.

Ordinary wide-string interoperability follows in the [wide-wire checkpoint](native-cdr-wide-wire-slice.md).
Next: mutable wire key-only framing, fixed BCD extraction, package placement and
the production build switch.
