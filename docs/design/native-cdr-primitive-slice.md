# Shared native CDR: primitive writer checkpoint

Date: 2026-11-03. Implements the first bounded demonstration recommended by the
[native audit](native-cdr-audit.md), not the complete codec migration.

The subsequent [reader/cursor checkpoint](native-cdr-reader-slice.md) extends
this implementation and records updated package verification. The scope and
validation below describe the original 2026-11-03 checkpoint.

## Implemented boundary

`packages/zidl-rt/src/cdr_primitives.zig` owns unsigned primitive byte encoding,
endianness, alignment and zero padding. The existing native `CdrWriter` calls
it directly; signed, boolean, character and floating-point methods retain their
existing native facade. There is no native Zig call through the C ABI.

The staging `PrimitiveWriter` exposes dynamic, fixed and counting sinks with
both byte orders and alignment caps four/eight. It writes payload primitives,
not encapsulation or aggregate framing. Dynamic storage is caller-owned and
must be freed by that caller. Initializing over a nonempty dynamic buffer starts
a new payload at the current buffer end (`len` includes that prefix; `pos` starts
at zero). The caller must not independently modify a buffer during writing.
Fixed and counting modes allocate nothing; all counters use checked addition.
This API is a migration aid, not the final reader/writer API design.

`packages/zidl-cdr/src/shared_primitives.zig` exports the existing primitive
writer symbols and preserves the concrete C writer layout. It delegates wire
operations to the same core. Its storage sink calls a temporary internal C
bridge, keeping buffer growth, custom `grow_fn`, allocator registration,
deinitialization and error statuses in the existing C implementation.
The bridge preserves arbitrary callback error codes. C strings, readers,
framing, key hashing and PL_CDR are still C implementations; framing's calls
to primitive functions resolve to the adapter when enabled.

The core temporarily lives inside `zidl-rt` so existing native modules and
older generated consumers need no new imports/dependency wiring. The C adapter
depends on that module; `zidl-rt` does not depend on the adapter. Move the core
to canonical `zidl-cdr` when the module graph/compatibility umbrella are
migrated together. This checkpoint does not establish the final package split.

## Opt-in and compatibility

From `packages/zidl-cdr`:

```sh
zig build test-shared-primitives
zig build test
zig build test -Dshared-primitives=true
zig build -Dshared-primitives=true
```

The last command builds the staged `libzidl_cdr` archive. The normal default
continues to compile C primitives, retaining the temporary differential oracle.
The package's `test` step includes the new targeted suite in addition to existing
roundtrips. zidl's and zzdds's direct-source build paths have not switched.
`ZIDL_CDR_SHARED_PRIMITIVES` is an internal build switch: defining it without
linking the Zig adapter leaves unresolved primitive symbols by design.

The staged archive bundles Zig's compiler runtime for non-Zig linkers. A local
ReleaseSafe archive initially failed the system C link on `__zig_probe_stack`;
bundling the runtime corrected that failure without disabling safety checks.

No public C header, symbol signature or struct layout changed. Overflow on the
shared primitive storage path returns `ZIDL_CDR_OVERFLOW`, including counting
counter overflow. C growth doubling was hardened against size wrap; normal
capacity growth and allocator sizing remain unchanged. Existing partial progress
is preserved: a fixed writer may consume alignment padding before failing to
write the value. The implementation does not promise transactional writes.

Key identities, string validation and unrelated reader semantics have not been
changed. Their deliberate corrections remain separately tracked by the audit.

## Validation

The targeted suite checks hand-written primitive known answers for XCDR1/XCDR2,
LE/BE, native/C, and dynamic/fixed/counting storage. A separately compiled C
caller invokes every primitive export. Other cases cover C-versus-Zig state
sizes/alignments/offsets, exact-capacity output, fixed overflow after alignment,
counting overflow, native/C allocation failure, custom grow error/ownership,
and C BE DHEADER patching including counting mode.

For environments where the package build runner is unavailable, the same suite
can run directly from the zidl root (set `ZIG` to the selected Zig executable
and use writable cache paths if necessary):

```sh
cc -std=c99 -Wall -Wextra -Werror -DZIDL_CDR_SHARED_PRIMITIVES \
  -Ipackages/zidl-cdr/include -c packages/zidl-cdr/src/zidl_cdr.c \
  -o /tmp/zidl-shared-cdr.o
cc -std=c11 -Wall -Wextra -Werror -Ipackages/zidl-cdr/include \
  -c packages/zidl-cdr/test/shared_primitives.c -o /tmp/zidl-shared-caller.o
"$ZIG" test /tmp/zidl-shared-cdr.o /tmp/zidl-shared-caller.o -lc \
  --dep zidl_rt --dep adapter \
  -Mroot=packages/zidl-cdr/test/shared_primitives.zig \
  -Mzidl_rt=packages/zidl-rt/src/root.zig \
  --dep zidl_rt -Madapter=packages/zidl-cdr/src/shared_primitives.zig
```

The C caller also supports a standalone external-link check against a staged
archive, using the system C compiler for the final link:

```sh
cc -std=c11 -Wall -Wextra -Werror -DZIDL_CDR_SHARED_CONSUMER \
  -Ipackages/zidl-cdr/include packages/zidl-cdr/test/shared_primitives.c \
  /path/to/libzidl_cdr.a -o /tmp/zidl-shared-consumer
/tmp/zidl-shared-consumer
```

Local results: 8 targeted tests, 84 existing native runtime tests and 10 existing
independent Cyclone vector tests passed with Zig 0.17.0 on Linux x86_64.
The same 84 native runtime tests passed with Zig 0.16.0. Debug and ReleaseSafe
staged archives built directly with `zig build-lib -fcompiler-rt` linked and ran with
the system C compiler using the committed standalone caller. A symbol comparison
confirmed all 72 original C runtime symbols remain defined in that archive.
The package build-runner attempt produced no output/completion and was stopped;
its new target was syntax-checked but not verified through the runner. Full
package roundtrips and other target artifacts remain separate validation
requirements; these direct checks do not replace them. No performance
claim is made. Before switching production consumers, migrate the remaining
codec operations, validate installed artifacts/allocator state across libraries,
and run the full generator and zzdds integration matrix.
