# Generated native CDR validation checkpoint

Date: 2026-11-05

Status: checked patch calls and wide-string validation implemented. Generated
reader frame-window adoption remains the next checkpoint. This extends the
[framing checkpoint](native-cdr-framing-slice.md), without switching production
builds to the staged runtime.

## Changes and compatibility

All C, C++ and Zig generator patch sites now call checked APIs and propagate
failure, including appendable/mutable structures and unions, key serializers
and collection DHEADERs. Optional DHEADER reservations still skip the patch for
XCDR1. Built-in native writers expose `patchDheaderMaybeChecked`; key-hash and
PL_CDR writers retain their no-DHEADER behavior. Existing legacy patch APIs
remain available for previously generated code.

Regenerated C/C++ serializers require the runtime header/library with checked
patch symbols. Native custom writer implementations used with regenerated code
must implement the applicable fallible `patchDheaderChecked`,
`patchDheaderMaybeChecked` and `patchEmheaderChecked` methods. There is no fallback
to discarding failures. Public C state layout and existing symbol signatures
remain unchanged. Single-file and split-file golden outputs are regenerated.

The additive `zidl_cdr_skip_wstring` validates a complete wide-string span and
its final terminator without allocating. The staged adapter delegates directly
to the shared Zig string core; the retained C reference supplies the same new
operation independently. Generated C/C++ wide skips use it. Generated C++ reads
validate on a stack reader copy before checking schema bounds/resizing a
`std::wstring`, then retain primitive decoding for host `wchar_t` conversion.
Malformed preflight leaves the caller's reader and string unchanged. Successful
reads preserve interior zero code units, as expected for length-bearing native
and C++ values. C-owned NUL-terminated values retain their separate ownership
restriction; this checkpoint does not change the reference C owned reader.

This closes the generated C++ wide-read and C/C++ wide-skip gaps recorded in the
[string checkpoint](native-cdr-string-slice.md). Validating a body against input
length still does not enforce nested enclosing/member boundaries: generated
code must adopt the explicit bounded-reader APIs next. No hidden reader state,
ABI changes or automatic nested-frame guarantee is introduced here.

## Regression coverage

`test/integration/cdr_validation` adds executable generated-code tests. The C/C++
fixture compilation redirects only generated checked-patch calls to injectors;
normal runtime calls remain linked. Injected OVERFLOW must reach the serializer
caller for appendable, mutable/member, key and collection paths. Native Zig
uses a caller-supplied failing writer to exercise the equivalent error paths
without allocating a multi-gigabyte buffer. XCDR1 and key writer no-op behavior
are covered too.

Wide-string cases cover both byte orders, interior zero code units, every
truncated input prefix, invalid final terminators, and oversized declared counts.
C++ malformed-input tests verify the destination is unchanged before resizing. Package tests independently cover the additive skip API in both C
implementations, and the external consumer calls the symbol from the archive.

The root `test-cdr-validation` target runs these Zig/C/C++ tests and is included
in `test`. The existing `test-cdr-known-answer` target remains the independent
wire-compatibility check. Use the existing
[Debug Maker workaround](native-cdr-reader-slice.md#build-runner-investigation)
for this local toolchain.

Local validation on Linux x86_64:

- The full default root `test` target succeeds: 95/95 build steps, with
  1,172 executed tests reported passed and other test steps cached. This includes
  all 1,106 compiler/backend unit tests, integration fixtures and golden checks.
- Both C runtime implementations pass 65 roundtrip tests; all 30 targeted shared
  tests pass as well.
- The focused root `test-cdr-validation` target passes all Zig/C/C++ steps.
  Generated patch-failure tests also pass on Zig 0.16 and 0.17.
- System C/C++ generated validation executables pass against the installed staged
  Debug archive, including injected failures and malformed wide strings.
- The existing independent Zig/C/C++/Java known-answer fixture target passes.
- External Debug and ReleaseSafe C consumers link and run with the new symbol.
- Both runtime C source modes compile with `-Wall -Wextra -Wpedantic -Werror`.

The temporary filesystem filled during cold compilation. Disposable test
artifacts were removed and large caches moved to the workspace filesystem;
verification was retried. This is a local build-storage constraint, separate
from the already recorded Zig optimized-bootstrap delay. No new platform,
full zzdds integration or performance claim follows from these checks.

## Next checkpoint

Adopt explicit reader bounds in generated aggregate/member and collection reads,
including key and selected-field traversal. Add malformed nested frames with
valid trailing input so a missing window cannot pass as a truncation check.
Keep allocation cleanup and parent-cursor handling explicit on each error path.
Canonical key fixes, fixed-BCD extraction, package naming and production build
migration remain pending.

Subsequent checkpoint: [generated reader windows](native-cdr-reader-windows-slice.md)
adopts bounded aggregate/member and collection reads.
