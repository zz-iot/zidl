# Java collection bounds and allocation

Following [member and union bounds](java-cdr-member-bounds.md), ordinary and
key-projection collection readers share bounded XCDR2 collection scopes. The
same scopes cover skips and selected-field skips. Non-primitive sequences,
arrays and maps validate their DHEADER against the current buffer limit, restore
the parent limit on failure, and advance to the declared collection end on
success. XCDR1 collections remain undelimited; primitive XCDR2 collections retain
their existing wire layout.

Sequence and map counts are read as unsigned values. Counts beyond Java's
signed-int collection range or an IDL bound raise `IllegalArgumentException`
after the count header. Missing alignment/count bytes raise
`BufferUnderflowException` without advancing the cursor. Reads and skips use the
same validation, including when a field was not selected. Collection frame
errors retain the frame helper's cursor policy; member-read failures retain the
failing read position and restore enclosing limits.

Lists and maps no longer reserve capacity from the wire count. Lists grow after
successfully decoding each element; maps insert after decoding each key/value
pair. A huge count with a truncated body therefore fails on the body read without
first allocating storage proportional to that count.

There is deliberately no `count <= remaining bytes` rule: final empty structs
can encode zero bytes, so valid element counts can exceed the remaining byte
count. This change is not an application resource quota. Large valid collections,
especially collections of empty values, can still require large amounts of memory
or processing; callers needing such limits must impose them separately. Bounded
IDL collections provide a schema-level count limit. Writer bound checks are
unchanged in this reader-focused slice.

The integration fixture checks reads, key reads, selected reads/skips, maps,
arrays, nested collections, count overflow, IDL bounds, small-heap malformed
inputs, valid zero-byte elements, XCDR1, direct/read-only/offset buffers, and parent
limit restoration in both Java output modes.
