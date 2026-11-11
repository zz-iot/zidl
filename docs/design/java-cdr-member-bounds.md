# Java mutable member and union bounds

This follows the [appendable struct checkpoint](java-cdr-frame-bounds.md).
Mutable struct readers now use the same checked EMHEADER loop for ordinary and
key-projection traversal. Mutable union readers also limit both their DHEADER
frame and each EMHEADER payload. Appendable union readers use the appendable
frame scope already used by structs.

Lengths are unsigned; LC 5–7 multiplication uses `long` and rejects sizes beyond
the 32-bit wire range. A payload extending beyond its enclosing frame raises
`BufferUnderflowException` before field decoding. Truncated NEXTINT fields raise
underflow too, including the non-consuming peeks used for LC 5–7. Unknown
must-understand members raise `IllegalArgumentException`; other unknown members
are skipped only after validating their span.

Each member temporarily limits the buffer to its payload. On success, readers
advance to its declared end, including unconsumed trailing bytes. A failure
restores the enclosing frame limit, then the original parent limit, while
retaining the failing read's cursor. Primitive alignment exception behavior is
unchanged. Mutable union payload dispatch uses the member ID rather than treating
any non-discriminator member as the active arm; this permits unknown members to
be skipped and known payloads to be located by their declared member ID.
Discriminator/arm consistency validation is not added here.

Appendable union XCDR1 decoding continues without DHEADER framing; XCDR2 advances
to the frame end on success. Existing mutable XCDR1 behavior is unchanged.
Collection allocation/framing, wide-string validation, split fixed helpers and
default-package generation remain audit follow-ups before runtime extraction.

`test-java-cdr-validation` exercises malformed frame and member lengths, unsigned
NEXTINT values, truncated peeks, overflow, member underflow, parent-limit
restoration, unknown and must-understand members, and valid union/struct reads
in both Java output modes.
