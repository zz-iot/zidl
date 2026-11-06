# Shared native CDR: reader and cursor checkpoint

Date: 2026-11-04. Extends the [primitive writer checkpoint](native-cdr-primitive-slice.md).

The subsequent [string checkpoint](native-cdr-string-slice.md) extends this
implementation and records its deliberate string validation/ownership behavior.

## Shared operations

The native `CdrReader` and opt-in C adapter now use the same primitive decoder
for unsigned/signed integers, character bytes, booleans and floating-point bits.
Both byte orders and both XCDR alignment caps are supported. The native Zig API
continues to call the core directly.

`packages/zidl-rt/src/cdr_cursor.zig` provides checked byte advancement, borrowed
slice reads, payload-relative alignment, absolute seeks and primitive-run skips.
Checks use subtraction before addition and checked multiplication. Cursor
alignment also avoids subtracting the payload origin from a position below it.
No allocator or runtime dispatch is introduced by these operations.

`packages/zidl-cdr/src/shared_primitives.zig` keeps the public C reader layout and
existing read/skip/seek symbols. It translates core errors deliberately:

| Core failure | C result |
| --- | --- |
| `EndOfStream` | `ZIDL_CDR_TRUNCATED` (-2) |
| `InvalidBool` | `ZIDL_CDR_INVALID` (-3) |
| `InvalidPrimitiveSize` | `ZIDL_CDR_INVALID` (-3) |

C outputs are assigned only after a successful read. C strings and fixed-point
reads retain their implementations and use shared checked byte advancement;
unknown EMHEADER payload skips use shared alignment. Encapsulation parsing,
framing-end validation, string wire validation, allocation/ownership and canonical
key corrections are still subsequent migration work.

## Cursor behavior and deliberate corrections

Valid streams retain their existing byte/cursor behavior. Partial progress is
preserved rather than adding rollback:

- An invalid boolean consumes its byte and leaves the C output unchanged.
- If alignment padding ends beyond the input, the cursor clamps to the input
  end and reports truncation. This preserves the existing C regression contract
  and brings the native reader into agreement.
- If padding fits but the primitive does not, the aligned cursor remains in
  place and the C output remains unchanged.
- An oversized byte skip or failed seek leaves the cursor unchanged.
- Empty primitive runs consume no alignment padding.

The native reader's old `pos + count` checks could overflow, and its alignment
could advance beyond the input. Both cases now return `EndOfStream` safely.
The staged C adapter also rejects an already out-of-range cursor instead of
allowing subtraction underflow.

Absolute seek retains its historical allowance of positions inside the four-byte
encapsulation. Byte reads/skips can still operate there. Multi-byte alignment
requires a position at or after the payload origin; an earlier position now
returns truncation instead of underflowing or panicking.

For a nonempty primitive run, unsupported element widths (anything other than
1/2/4/8) now return `InvalidPrimitiveSize` / `ZIDL_CDR_INVALID`. This is an
explicit validation change outside the documented valid-argument contract.
Empty runs retain their unconditional no-op behavior.

The default C implementation remains the temporary independent reference. Its
reader wire mechanics have not been replaced; the shared reader is selected
by the existing `-Dshared-primitives=true` package option. zidl/zzdds production
build consumers have not yet switched.

## Verification

The targeted suite now contains 12 tests. A separately compiled C caller reads
every primitive from hand-written XCDR1/XCDR2 LE/BE fixtures. Native Zig and C
both decode the fixtures and reject every truncated prefix. Other cases cover
ABI offsets, invalid bools, unchanged failed-read outputs, truncated padding,
invalid cursor positions, overflowing skip counts and empty primitive runs.
A native cursor test simulates lengths near `SIZE_MAX` without constructing a
huge input buffer, covering addition, multiplication and alignment overflow.

Direct local results on Linux x86_64:

- 12 targeted native/C tests passed with Zig 0.17.0.
- 85 native runtime tests passed with Zig 0.17.0 and 0.16.0.
- 10 independent Cyclone wire-vector tests passed with Zig 0.17.0.
- Both C source modes compile with system C99, `-Wall -Wextra -Wpedantic -Werror`.
- The complete package build graph passed with the adapter enabled: **62 C
  roundtrip tests and 12 shared-core tests** (74 total). The retained C-reference
  package's 62 roundtrip tests also passed; the targeted suite was reused from
  the adapter run.
- The package's Debug and ReleaseSafe archives linked and ran with the system C
  compiler through the new `test-external-c` target. A separately built
  ReleaseSafe archive also passed the committed C writer/reader consumer, and
  its symbol table retained all 72 original C runtime exports.

The package-built archive initially exposed a missing `__ubsan_handle_*`
dependency, which the earlier GCC-built C object did not introduce. The staged
library now bundles **both compiler-rt and ubsan-rt**, preserving the remaining
C code's safety instrumentation. The explicit `test-external-c` target uses the
actual package archive and a system compiler (`-Dexternal-cc=/path/to/cc` can
select it). It requires `-Dshared-primitives=true` and currently supports native
Linux/macOS with Unix-style compiler arguments. It is separate from the default
test target so ordinary Zig-only testing does not require an external compiler.

### Build-runner investigation

Zig 0.17 bootstraps its Maker executable before processing the project's normal
build graph. Command-line `--cache-dir` / `--global-cache-dir` alone did not keep
that bootstrap out of the read-only default cache in this environment. Set
`ZIG_GLOBAL_CACHE_DIR` and `ZIG_LOCAL_CACHE_DIR` in the environment before
invoking `zig build`; `--pkg-dir` also provides a writable dependency directory.
Process sampling established that the silent bootstrap was actively compiling
(CPU time and resident memory increased), rather than waiting on the CDR tests.
The default bootstrap remained busy after twelve minutes and was stopped.

Building the toolchain's unmodified Maker source in Debug mode bypassed that
delay. This executes the real package build script, dependency translator,
library and tests, rather than substituting manually assembled test binaries.
The pinned translate-c and Aro dependencies were fetched with authorized network
access after the sandbox rejected Zig's DNS socket operation (`EPERM`). No
toolchain installation or dependency pin was modified.

Reproduction for this toolchain, from `packages/zidl-cdr` (set the first two
paths to the selected Zig 0.17 installation):

```sh
CDR_ZIG=/path/to/zig
CDR_ZIG_LIB=/path/to/zig/lib
export ZIG_GLOBAL_CACHE_DIR=/tmp/cdr-global-cache
export ZIG_LOCAL_CACHE_DIR=/tmp/cdr-local-cache
"$CDR_ZIG" build-exe -O Debug \
  --cache-dir "$ZIG_LOCAL_CACHE_DIR" --global-cache-dir "$ZIG_GLOBAL_CACHE_DIR" \
  -femit-bin=/tmp/cdr-maker-debug "$CDR_ZIG_LIB/compiler/Maker.zig"
/tmp/cdr-maker-debug build --zig-lib="$CDR_ZIG_LIB" --zig="$CDR_ZIG" \
  --global-cache="$ZIG_GLOBAL_CACHE_DIR" --seed=0 \
  --pkg-dir /tmp/cdr-packages test test-external-c -Dshared-primitives=true \
  --summary all
```

Omit `-Dshared-primitives=true` and `test-external-c` to run the retained C
reference's package tests. On a normally bootstrapped toolchain the corresponding
commands are `zig build test -Dshared-primitives=true` and
`zig build test-external-c -Dshared-primitives=true`.
Use `test-external-c -Dshared-primitives=true -Doptimize=ReleaseSafe` to repeat
the package archive's ReleaseSafe external-compiler check without rebuilding
the translator in that optimization mode.

This closes the earlier **package test** verification gap using the Debug Maker
workaround. It does not establish a fix to Zig's default bootstrap itself.
Production zidl/zzdds build migration and other platform artifacts remain pending.
