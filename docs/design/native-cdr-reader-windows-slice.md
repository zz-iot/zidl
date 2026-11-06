# Generated native CDR reader windows

Date: 2026-11-05

Status: implemented for DHEADER/EMHEADER aggregates, members and supported
non-primitive collections in generated Zig/C/C++ codecs. This follows the
[generated validation checkpoint](native-cdr-generated-validation-slice.md).
The working tree was first rebased onto upstream `main` at `ec63574`; the
post-rebase baseline passed all 97 build steps and 1,198 reported tests.
Production packaging and library names remain unchanged.

## Window mechanics

Generated reads now restrict each appendable/mutable body to its declared end,
and each mutable member to the extent computed from its EMHEADER. This includes
structures, unions, key-only decoding and key-hash traversal. Supported
non-primitive sequences, arrays and native maps have their own lexical windows,
including allocation-free traversal paths. Selected-field readers also use the
enclosing appendable bound. Existing fixed-size aggregate fast skips still
validate/skip the declared extent without decoding every skipped member.

Native Zig uses caller-owned `CdrReader.Window` values on the stack. A window
calls the existing `limited` operation, preserving the original buffer base and
alignment origin at offset four. Generated `defer close` / `errdefer cancel`
restores the enclosing data slice on every exit. Success advances to the
window's declared end, skipping unrecognised trailing bytes; failure retains
the consumed cursor. Unique generated local names avoid shadowing across nested
collections and aggregate/member scopes. There is no hidden window stack or
new field in the reader itself.

C/C++ public traversal functions keep their existing signatures and delegate to
private static bodies using a stack reader copy. Private bodies narrow
`data_len` with the existing additive `zidl_cdr_reader_limit` API. Mutable loops
check member extents before dispatch and restore the enclosing bound at each
iteration. Collection scopes close before later fields are decoded. Public
wrappers propagate the cursor on success or error while leaving the caller's
original input pointer/limit intact. Errors clamp a legacy C cursor to its
current window if an alignment attempt advanced it beyond that bound. Cleanup
gotos in C key hashing still release previously decoded owned fields; C++
continues to use its normal value destructors.

The stack reader copies add no heap allocation, runtime dispatch, RTTI or C++
exception requirement. Public C layouts, symbols and existing signatures are
unchanged. Regenerated Zig code requires the runtime with the native Window
helper; C/C++ requires the checked/bounded APIs introduced in the preceding
checkpoints. Legacy generated code remains usable with its prior behavior.
No throughput or stack-footprint improvement is claimed.

## Intentional behavior changes

A field cannot consume bytes after its declared enclosing/member end merely
because valid bytes follow it in the input. In particular, a malformed nested
frame cannot borrow a parent's next field. Checking the extent before dispatch
also means a truncated unknown must-understand member can report truncation
before the unknown-member policy error.

Successful appendable and member decoding advances past unrecognised trailing
bytes within the declared window. Parent fields therefore start after the
entire nested frame, rather than after only the fields understood locally.
Errors restore the enclosing input limit; partial decoded-value ownership and
cleanup continue to follow the existing language-facing APIs. A frame window
is an upper bound with the original alignment origin, not a new relative
buffer or a general restriction on a caller's manual cursor rewinds.

Discovery ParameterList strict/lenient/sentinel policy is unchanged. Its current
known-field strict post-read checks are not replaced here by DHEADER windows.
Likewise, collection allocation limits, unsupported generator features and
schema-evolution defaults are not expanded by this checkpoint.

## Regression evidence

The generated validation fixture now exercises nested appendable and mutable
structures, mutable unions, key-only paths, non-primitive sequences and arrays.
Malformed cases include a short DHEADER, a short known member, and an unknown
member whose declared body would consume the parent's trailer. Actual bytes
for the attempted read remain present after every shortened bound, preventing
ordinary buffer truncation from masking a missing frame check.

Success cases include a future appendable field before the parent's trailer,
and verify that collection windows close before the parent's next field.
Failure cases verify that the caller's original limit is restored and its
cursor stays within the failed frame. Native tests reuse the restored reader
to read the parent's trailer after failure. C tests track exact allocation/free
sizes, including a successfully decoded owned key before a later member fails.

The native wrapper-contract fixture adds a selected-field boundary case. The
C++ condition fixture adds the equivalent case, run both normally and without
RTTI/exceptions. The focused validation target also runs against the installed
shared archive through system C/C++ compilers; its normal root-build C/C++ steps
continue to use the independent C reference.

Validation uses the existing
[Debug Maker workaround](native-cdr-reader-slice.md#build-runner-investigation)
and workspace-backed caches for the large root build. Results are local Linux
x86_64 checks; no full zzdds run, 32-bit/big-endian-host execution or performance
measurement is claimed.

Local results:

- Full root `test`: 97/97 build steps succeed; 1,190 executed tests are reported
  passed, with other test steps cached. All 1,118 compiler/backend tests pass.
- The shared package passes 65 roundtrip and 30 targeted tests.
- All seven generated validation tests pass on Zig 0.17 and 0.16.
- System C/C++ generated boundary tests pass against the installed staged Debug
  archive, including exact C allocation/free checks. Fresh generated C/C++
  codecs also pass the independent XCDR known-answer fixtures against that
  archive, including reference EMHEADER length codes 5–7.
- Native/C/C++/Java known-answer fixtures and refreshed single/split golden
  checks pass. Selected-field regressions pass in native Zig and both C++
  condition variants, including `-fno-rtti -fno-exceptions`.
- Zig formatting, diff whitespace and checkpoint-link checks pass; zzdds remains
  unchanged.

## Remaining work

Keep the discovery ParameterList validation policy explicit when considering
per-parameter decode windows. Canonical key alignment and type-maximum-size
hash selection are addressed in the [next checkpoint](native-cdr-key-slice.md),
with remaining cross-language and member-ID gaps documented there.
Fixed-BCD extraction, final package placement/compatibility aliases and the
production source/build switch remain before native consolidation is complete.
