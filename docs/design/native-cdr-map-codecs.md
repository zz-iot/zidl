# Native C map codecs and wire witnesses

C maps use typed entry buffers with the same explicit ownership convention as
sequences. The generated entry has `key` and `value`; the owner has `_maximum`,
`_length`, `_buffer`, `_release`. Borrowed entries are not freed. Owned entries
are initialized before decoding so every allocation failure leaves a result that
its generated `_free` can release, including the partially decoded current entry.
Entry definitions follow named value declarations; the early owner needs only a
pointer to a forward-declared entry. This also works in split headers.

Primitive-key/value maps use count + pairs in XCDR1/XCDR2 (XTypes rule 14).
Non-primitive maps use count + pairs in XCDR1 and DHEADER + count + pairs in XCDR2.
This follows the correction in [OMG DDSXTY14-72](https://issues.omg.org/issues/DDSXTY14-72),
resolved for XTypes 1.4b1. The published 1.3 rule 15 accidentally omitted the count;
its section 7.4.1.1.4 also describes maps in terms of map-entry sequences. A literal
count-free implementation was tested locally and then superseded before review.
The count-free form is not retained as an alternate or auto-detected encoding.

Independent byte witnesses explicitly lay out count, string lengths, padding,
pair values, delimiters and trailing fields in both byte orders. For
`map<string,long>{"A":11,"B":22}`, the corrected XCDR2 big-endian body is:

```
0000001c 00000002 00000002 41000000 0000000b 00000002 42000000 00000016
```

The first word is DHEADER=28; the second is count=2. The XCDR1 body omits the
DHEADER. Primitive maps omit the DHEADER in both versions.

A separate local Fast CDR 2.3.5 `Cdr(XCDRv2).serialize(std::map<string,int32_t>)`
probe produced count + pairs without a DHEADER:

```
00000002 00000002 41000000 0000000b 00000002 42000000 00000016
```

That raw library call is not a DDS participant-level IDL-map interoperability
oracle. It demonstrates why a vendor-shaped count alone is insufficient to
establish the complete header contract. The corrected OMG issue, not that raw
call or the older local PDF's omission, controls the C witnesses. C++/Java/Zig
map paths need their own separate conformance audit.

The allocation-free probe validates count, schema bound and complete entry
extent before allocating the owner buffer. Non-primitive XCDR2 maps also require
the pairs to consume the DHEADER exactly. Narrow/wide duplicate checks compare
string content; integral keys compare values. Duplicate validation is currently
quadratic, so schema bounds should reflect the caller's CPU admission budget.

Compiled C99 and exception-disabled C++ consumers, both CDR versions and byte
orders, every truncated prefix, malformed lengths, empty maps, nested map/sequence
values, arrays, aggregates/unions, every allocation failpoint and idempotent
cleanup are exercised by `zig build test-c-maps`. GCC also compiles split sources
with `-Wall -Wextra -Werror`. Interface/callback and middleware adapters remain
explicitly rejected, rather than inferred from this value/codec support.
