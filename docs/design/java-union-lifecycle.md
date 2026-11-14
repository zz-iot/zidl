# Java union lifecycle hardening

Fresh Java unions initialize the discriminator to its mapping default: zero or
false for primitive discriminators, and the first declared enum value for enum
discriminators. Only the selected arm receives its payload default. An unmatched
no-default discriminator selects no payload. Reference arrays in the selected
arm receive element defaults, including typedef and multidimensional arrays.
Inactive arms stay uninitialized, avoiding eager recursive construction.

Explicit-arm setters select their first declared label. Default-only setters
choose an unused discriminator value in the actual boolean, enum or integer
domain. They fail without mutation if no such value exists. No synthetic enum
ordinal or unchecked sentinel is introduced. The getters retain their existing
API; inactive getters are not changed into checked accessors.

Decoding allocates a selected array arm before indexing it, independent of which
arm construction selected. Omitted mutable payloads use the same complete default
initialization. Ordinary boolean default arms now participate in serialization
and decoding; predicate dispatch also supports 64-bit Java discriminators.

`test-java-union-lifecycle` compiles and runs single-file, packaged split and
unpackaged split output, each with and without codecs. Tests cover cross-module
enum aliases, switching to default arms, unmatched defaults, nested/recursive
values, reference arrays, omitted array payloads, and final/appendable/mutable
boolean arms. Existing admission and independent wire fixtures remain enabled.

This fixes construction and arm-selection consistency; it does not expand the
Java API to the complete OMG language mapping or change the established
little-endian codec contract. Generic struct reference-array element defaults
outside selected union payloads remain a separate lifecycle question.
