# Java appendable struct frame bounds

Following [string validation](java-cdr-string-validation.md), generated Java
appendable struct readers now respect the XCDR2 DHEADER. Ordinary, key-projection,
and selected-field reads share a bounded scope. The parent buffer limit is
restored even when a member fails. Successful reads advance to the declared end,
skipping unknown trailing bytes so a containing value can read its next member.
XCDR1 continues to read members without a DHEADER.

The frame length is unsigned and must fit within the enclosing buffer limit.
Missing alignment/header bytes raise `BufferUnderflowException` without moving
the cursor; an oversized body raises it after the header. Failures inside the
frame retain the failing member's cursor position while restoring the parent
limit. Existing primitive alignment exception behavior is unchanged.

Appendable XCDR2 bulk skips use the same checked frame end. Mutable bulk skips
also use it, correcting their previous end calculation, which omitted the
four-byte header. Mutable member decoding and appendable union decoding remain
separate follow-up work, along with collection framing/allocation guards.
Missing trailing known members still raise underflow; this slice does not add
schema-evolution defaults for such members.

`test-java-cdr-validation` covers zero and oversized frames, nested reads,
unknown trailing bytes, selected skips, XCDR1, offset origins, direct/read-only
buffers, cursor/limit restoration, and mutable bulk skip boundaries in both Java
output modes.

The subsequent [member and union checkpoint](java-cdr-member-bounds.md) implements
the mutable member and appendable union follow-ups identified above.
