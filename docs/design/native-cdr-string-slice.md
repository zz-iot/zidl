# Shared native CDR: string checkpoint

Subsequent [package placement](native-cdr-package-slice.md) moves native codec
source to `zidl-cdr/src` and C ABI test commands to `zidl-cdr/c-api`. Direct
`zidl-rt` source imports now require the codec and bindings module imports.

Date: 2026-11-04. Extends the [reader/cursor checkpoint](native-cdr-reader-slice.md).

The wide representation recorded here was the original legacy behavior. It is
superseded by the later [ordinary wide-wire checkpoint](native-cdr-wide-wire-slice.md),
which uses a UTF-16 byte count without a wire terminator. Narrow behavior and
ownership separation described here remain applicable.

## Shared boundary

`packages/zidl-rt/src/cdr_strings.zig` now owns narrow/wide string wire length
checks, writes, borrowed wire reads and final-NUL validation. It uses the common
primitive encoder/decoder and checked cursor operations. Native `CdrWriter`,
`CdrReader`, the staging fixed/counting/dynamic writer, and the opt-in C adapter
delegate to it. Discovery's `PlCdrWriter` delegates through the native writer.
`KeyHashWriter` also delegates string output; valid key bytes are unchanged, and
the canonical-key alignment/maximum-size corrections remain separate work.

The existing representation is preserved: a u32 count including the final NUL,
then byte content or endian-aware u16 units. Empty strings have count one.
Writing input spans does not require a terminator in caller storage; the runtime
appends it. This checkpoint preserves that representation rather than redesigning
the wide-character mapping or adding Unicode validation.

The core returns a validated borrowed wide-wire view, including its terminator.
It decodes content units through the shared primitive decoder without casting
the input to a u16 pointer. Physically unaligned wire buffers are therefore
supported. There is no new public C borrowed-wide-string API.

Allocation remains at the interface boundary:

| Interface | Owned/borrowed contract |
| --- | --- |
| Native narrow borrowed read | Slice into original input; excludes final NUL; may contain embedded NUL bytes |
| Native owned narrow/wide read | Uses explicit allocator; returned slice excludes final NUL; embedded NUL content is retained; free using its explicit length |
| C borrowed narrow read | Pointer and explicit length into original input; excludes final NUL; embedded NUL content is retained |
| C owned narrow/wide read | Registered allocator; rejects embedded NUL content; includes a host-order terminator in owned storage; existing `free_str`/`free_wstr` remain valid |

C owned allocations retain alignment eight and exact original sizes: narrow
content bytes plus one, or `(wide content units + 1) * 2`. Allocator registration,
callbacks, free functions and dynamic buffer ownership remain in the existing C
provider. No allocator state or ABI field is added. C output pointers and length
outputs are assigned only on success.

## Deliberate validation and cursor changes

Neither original implementation checked the final wire terminator. The shared
reader now rejects a missing byte/u16 NUL as `InvalidString` / `ZIDL_CDR_INVALID`.
This applies to borrowed, owned and native skip reads. Zero counts remain invalid.
Complete malformed spans are consumed before the terminator error is returned.

Wide reads validate checked byte counts, the entire input span and its final
terminator **before allocation**. A truncated body or overflowing host byte count
returns `EndOfStream` / `ZIDL_CDR_TRUNCATED` before allocation, even when the
allocator would fail. A body that does not fit leaves the cursor just after the
length prefix; it no longer consumes an available prefix of its code units.

For complete valid wide wire spans, subsequent allocation failures and C owned
embedded-NUL rejection leave the cursor at the end of the span. Previously wide
allocation failure left it after the prefix, and a C embedded-NUL error stopped
at the offending unit. This change is explicit; failed reads do not promise
rollback. Narrow owned allocation failures already followed complete wire reads
and retain that behavior. Writer failures can still leave a prefix or content
written before running out of storage.

Writers reject a content length whose added NUL cannot fit u32, or whose wide
byte count cannot fit the host size, as `Overflow` / `ZIDL_CDR_OVERFLOW` before
writing. The C adapter checks these before constructing input spans. It accepts
NULL with zero input length and rejects NULL with nonzero length as
`ZIDL_CDR_INVALID` (after count-overflow checks); nonempty input must designate
valid caller storage, including in counting mode.

The default C source implementation remains the temporary reference and retains
its former malformed-string behavior. `-Dshared-primitives=true` selects the
shared primitives, strings and reader cursors. Generated signatures, public C
header/state layout, symbol names and normal valid-stream bytes are preserved.
The production zidl/zzdds build paths have not switched yet.

Generator follow-up remains explicit: C++ wide-string serialization/decoding
still traverses `wchar_t` values with emitted primitive loops, and the shared
C/C++ generator's wide-string skip path also emits a primitive loop. Those
paths use the primitive ABI but do not yet use this runtime's complete-span and
terminator validation. C/C++ narrow strings and C owned wide reads already call
the runtime helpers. Migrate the remaining wide paths deliberately, preserving
C++ length-bearing ownership rather than routing it through the C owned
embedded-NUL policy, before claiming uniform validation across generated bindings.

## Verification

`packages/zidl-cdr/test/shared_strings.zig` extends the package's shared-core
suite. Hand-written payloads cover an initially unaligned string, non-ASCII u16
content, and empty narrow/wide strings, in both byte orders and both XCDR
versions. Native/C dynamic, fixed and counting writers match those payloads.
A separately compiled C caller and native Zig decode them and reject every
truncated prefix, freeing any earlier owned fields before returning failure.

Further tests cover zero/oversized counts, missing final terminators, native
skip validation, embedded-NUL ownership differences, zero allocation attempts on
malformed data, allocation failure and output preservation, exact C free sizes
and alignment, fixed-buffer partial progress, length overflow, and input at an
odd physical address. The external C consumer now exercises strings as well as
primitives against the actual package archive.

Use the [documented Debug Maker workaround](native-cdr-reader-slice.md#build-runner-investigation)
for this toolchain's slow default bootstrap. The normal package targets remain:

```sh
zig build test -Dshared-primitives=true
zig build test
zig build test-external-c -Dshared-primitives=true
zig build test-external-c -Dshared-primitives=true -Doptimize=ReleaseSafe
```

Local results on Linux x86_64, using the existing Debug Maker workaround:

- The shared C runtime's 62 roundtrip tests passed after the extraction.
- All 19 targeted shared-core tests passed, including the new string cases.
- The retained C-reference package also passed 62 roundtrip tests plus the 19
  shared-core tests (81 total).
- All 86 native runtime tests passed with Zig 0.17.0 and 0.16.0.
- All 10 independent Cyclone vector tests passed.
- Package-built Debug and ReleaseSafe archives passed the system-C consumer,
  now including string/wstring calls.
- Both C source modes compiled with system C99 and
  `-Wall -Wextra -Wpedantic -Werror`; Zig formatting and diff whitespace checks
  passed.

The new wide fixtures are hand-written known answers, not newly captured external
peer results. No 32-bit, big-endian-host or other-platform execution, full zzdds
integration run, or performance measurement is claimed by this checkpoint.

Next: shared encapsulation and DHEADER/EMHEADER framing, checked enclosing
boundaries and back-patching. Discovery strict/lenient policy stays above common
framing. Canonical key corrections and the package/production-build migration
follow as their own checkpoints.

Subsequent checkpoint: [shared framing](native-cdr-framing-slice.md) implements
the runtime framing extraction and records the remaining generated-code adoption.
