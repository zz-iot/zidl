# Java CDR string validation

The first correctness slice after the [Java audit](java-cdr-audit.md) gives
single-file and split-file output the same narrow-string helpers. Runtime
packaging and helper extraction remain subsequent work.

Readers validate the unsigned wire length and final NUL before allocating or
copying the string body. A zero count or nonzero terminator raises
`IllegalArgumentException`. A missing alignment/header or an advertised body
beyond the buffer limit raises `BufferUnderflowException`. Missing headers leave
the cursor unchanged; errors after reading a complete header leave it at the
start of the body. The enclosing buffer limit is unchanged.

String skips apply the same checks without allocating or decoding a string.
Writers check the entire aligned string span before modifying the output buffer;
insufficient space raises `BufferOverflowException` with the cursor and bytes
unchanged, allowing existing serialization retries to continue working.

UTF-8 replacement behavior and embedded NUL handling are unchanged. Appendable
frame bounds, mutable member bounds, collection allocation guards, wide strings,
and the other audit gaps remain separate correctness work before runtime
extraction.

`zig build test-java-cdr-validation` exercises generated public read, skip, and
write methods in both output modes, with a small JVM heap to catch unsafe length
handling. It also runs as part of `zig build test` when a JDK is available.
