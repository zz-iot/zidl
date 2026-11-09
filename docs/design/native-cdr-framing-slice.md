# Shared native CDR framing checkpoint

Subsequent [package placement](native-cdr-package-slice.md) moves native codec
source to `zidl-cdr/src` and C ABI test commands to `zidl-cdr/c-api`. Direct
`zidl-rt` source imports now require the codec and bindings module imports.

Date: 2026-11-04

Status: implemented in the opt-in shared C adapter and direct native Zig API.
Production consumers still use their existing build paths. This follows the
[string checkpoint](native-cdr-string-slice.md) and the
[native audit](native-cdr-audit.md).

## Shared operations

`packages/zidl-rt/src/cdr_framing.zig` now owns encapsulation selection/parsing,
DHEADER and EMHEADER reservation, checked back-patching, member extents and
ParameterList length arithmetic. Native Zig calls it directly; the staged
`packages/zidl-cdr/src/shared_primitives.zig` adapter translates errors to the C
contract. Primitive endian encoding is also shared by patch stores.

The opt-in `-Dshared-primitives=true` package option now covers primitives,
readers, strings and framing. Dynamic, fixed and counting writers retain their
storage policies. Framing supports both byte orders and XCDR alignment caps;
the dedicated discovery ParameterList writer retains its LE-only contract.
No public C reader/writer, EMHEADER or ParameterList struct layout changed.
No package/import/library renames or zzdds build switches occur here.

## Explicit boundaries and errors

Four additive C APIs are available in both the staged adapter and retained C
reference, with declarations in `zidl_cdr.h`:

- `zidl_cdr_patch_dheader_checked` and `zidl_cdr_patch_emheader_checked` validate
  offsets, available storage and representable u32 payload sizes before storing.
  Invalid patches return INVALID (-3); oversized payloads return OVERFLOW (-1).
  Counting validates without touching absent storage. Errors do not modify bytes.
- `zidl_cdr_reader_limit` copies a reader with a smaller absolute end bound.
  It keeps the original buffer and alignment origin at offset four. Invalid
  windows return TRUNCATED (-2) and leave the output unchanged.
- `zidl_cdr_emheader_end` validates the declared member extent against the current
  reader bound without advancing it. Invalid fixed length-code/size combinations
  return INVALID; a body crossing the bound returns TRUNCATED. Its output is
  unchanged on failure.

Native equivalents are `patchDheaderChecked`, `patchEmheaderChecked`, `limited`
and `emheaderEnd`. Legacy native/staged void patch methods safely ignore invalid
patches, but cannot report failure. The retained C reference's legacy void patch
methods remain unchanged. Generated serializers must adopt checked calls before
we can claim patch failures propagate to their callers.

Raw DHEADER and EMHEADER reads retain their header-only contracts. Mutable
DHEADER reads and XCDR2 header-skips now check that the declared body fits the
current input. These checks do not constrain subsequent field reads implicitly.
Callers must construct a limited reader for each enclosing body and member,
then reconcile the parent cursor explicitly. There is no hidden nesting stack
or extra state field. Existing generated codecs have not yet adopted these
windows; passing ordinary fixtures does not prove nested-boundary enforcement.

EMHEADER LC5–7 preserve NEXTINT peek semantics: the prefix remains available to
the value decoder. Derived lengths are checked before narrowing to u32. Fixed
header writers reject member IDs wider than 28 bits and length codes above 3;
variable-size reservation emits LC4. C header outputs remain unchanged on errors.
Reservation and cursor partial progress are tested, rather than promising rollback.

ParameterList writers reject raw lengths above 65532 before padding or narrowing:
65532 is the largest four-byte-padded length representable by u16. Native strict,
lenient and sentinel policies remain in the native reader. The staged C raw
parameter reader now validates that the rounded body fits and preserves its
output on failure; it does not add a strict/lenient policy selector. The C
reference retains its prior raw-reader behavior.

## Validation

The package test commands remain:

```sh
zig build test -Dshared-primitives=true
zig build test
zig build test-external-c -Dshared-primitives=true
zig build test-external-c -Dshared-primitives=true -Doptimize=ReleaseSafe
```

Use the existing [Debug Maker workaround](native-cdr-reader-slice.md#build-runner-investigation)
on this toolchain. Local Linux x86_64 results:

- Both C implementations pass 64 roundtrip tests; the targeted shared suite
  passes 30 tests, including ABI checks, both byte orders and all writer modes.
- Native runtime tests pass 87 tests on both Zig 0.16 and 0.17; the independent
  Cyclone vector suite passes 10 tests.
- Package-built Debug and ReleaseSafe archives pass the system-C consumer,
  including framing and ParameterList calls.
- Generated C and C++ codecs pass the existing independent XCDR collection and
  extensibility fixtures against the installed staged archive, including their
  truncation/allocation-failure checks. System C uses the project's existing
  `-std=c99 -Wall -Werror` flags; C++ additionally passes `-Wextra`.
- The focused root target passes all Zig/C/C++/Java fixture steps, including
  seven native generated-code tests and minimal TypeObject hashes.
- Both C source modes compile with `-Wall -Wextra -Wpedantic -Werror`.

The root build adds `test-cdr-known-answer`, a focused entry point reusing the
existing Zig/C/C++/optional Java fixture steps. Its C/C++ steps still compile the
reference C runtime; the separate system-compiler runs above test the staged
archive. No full zzdds integration, 32-bit/big-endian-host execution, other
platform validation or performance result is claimed here.

## Next checkpoint

Update generated codecs to use bounded enclosing/member readers and checked
patch calls, including malformed nested-frame regression cases. Adopt the common
wide-string span validation in generated C++ reads and C/C++ skips recorded in
the string checkpoint. Canonical key alignment/type-maximum hashing corrections,
remaining fixed-BCD mechanics and package/production-build migration remain
separate work before consolidation is complete.

Subsequent checkpoint: [generated patch errors and wide validation](native-cdr-generated-validation-slice.md)
adopts checked serializer patches. Generated reader-window adoption remains pending.
