# Shared Java CDR helper extraction (API 2)

The remaining reusable helper bodies now live in `io.zidl.cdr.Cdr`: wide strings,
collection counts, DHEADER spans, EMHEADER parsing, optional headers/scopes,
packed fixed values, canonical key finalization and LE encapsulation-ID lookup.
Schema traversal, direct primitive access, member identity/selection, canonical
key policy and bounded field/frame traversal remain generated.

New generated output requires API 2. The runtime still accepts `requireApi(1)`
and retains every API 1 operation. A lower runtime API fails the generated helper
check. Typed DDS reader/writer encapsulation lookups also delegate to the runtime.
Implementation versions continue to follow zidl's version; API levels describe
capability, independently of artifact version.

Existing split public helper signatures remain as forwarders. The public nested
`_CdrOptional` compatibility type keeps its fields, constructor visibility and
close behavior. New codec reads use `Cdr.OptionalScope` directly, preserving one
scope allocation per optional read; using the legacy helper adapter can allocate
an additional compatibility object. Scope closure restores the parent limit and
advances to an XCDR1 optional value's end even on read failure, as before.

`readMember` validates an EMHEADER and its unsigned payload length against the
current buffer limit, leaving the position at the payload start. It returns the
original header in the upper 32 bits and the absolute payload end in the lower
32 bits. `-1` indicates that alignment consumed only trailing frame padding.
A valid end cannot equal the sentinel's unsigned lower word because Java buffer
positions fit a nonnegative signed int. This primitive return avoids introducing
an object allocation per mutable member. Generated code still constrains the
member window, dispatches IDs, checks unknown must-understand members and restores
the parent window in `finally` blocks.

This is an extraction, not a wire-policy change. Wide strings retain UTF-16 code
unit behavior, including isolated surrogates. Fixed values retain their approximate
`double`/intermediate-`long` mapping and BCD acceptance behavior. Encapsulation
lookup retains the LE IDs and identifier lookup behavior; it is not a complete
encapsulation-header validation API. Canonical key padding/MD5 policy stays
schema-generated while buffer finalization is shared.

Direct API tests cover all eight EMHEADER length codes, malformed NEXTINT and
payload lengths, overflow, scope restoration, wide-string units and byte order,
independent BCD bytes, padded and independently checked MD5 hashes, and supported
encapsulation IDs. The existing generated fixtures, independent wire vectors,
Java 8-targeted three-mode consumption and JNI integration remain the gates.

The next delivery step is migrating zzdds Java SDK installation, examples and
smoke/loan checks to the matching JAR when its zidl pin advances. The separately
recorded split interface/JNI implementation naming issue remains independent.

## Measurement checkpoint

The [API 2 snapshot](../../test/java-cdr-baseline/extraction-2.json) uses the same
fixture/compiler as the first extraction. Generated source falls from 41,331 to
34,961 bytes in single-file mode and from 39,713 to 33,369 in split mode.
Generated class bytes fall from 30,391 to 26,269 and from 29,091 to 24,939,
respectively. The runtime now contributes 7,454 class bytes (8,524 compressed JAR
bytes including its license), so single-input totals are 33,723 and 32,393 class
bytes. Those totals exceed the first extraction's single-input totals; no general
footprint reduction is claimed. Warm timings are one-fork diagnostics collected
during concurrent test builds, not evidence of a speed improvement.
