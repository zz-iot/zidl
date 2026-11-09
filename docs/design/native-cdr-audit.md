# Native CDR consolidation audit

Subsequent [package placement](native-cdr-package-slice.md) moves native codec
source to `zidl-cdr/src` and C ABI test commands to `zidl-cdr/c-api`. Direct
`zidl-rt` source imports now require the codec and bindings module imports.

Date: 2026-11-03. Scope: the first step of [shared native CDR](shared-native-cdr.md).
Audited checkouts: zidl `a9fb5c9`, zzdds `b4f54f3`, including the existing local
design-document changes. This is an audit and proposed implementation boundary;
it does not replace either codec, change an ABI, or authorize publication.

Implementation progress: the [canonical key checkpoint](native-cdr-key-slice.md)
now corrects native alignment, holder projection and type-size hash policy for
its documented supported shapes. This audit retains the original findings;
Java, member-ID normalization and the production switch remain outstanding.

## Findings and recommended next step

Neither current codec can simply replace the other. Preserve the C writer's
dynamic/fixed/counting modes and selectable byte order, Zig's direct native API
and streaming key sink, and discovery's explicit strict/lenient policy.

Two correctness issues must be separated from extraction:

1. RTPS 2.5 canonical key alignment is capped at four. Zig's key writer does
   this; generated C/C++ key hashing selects XCDR1 and therefore caps at eight.
2. Both native hash helpers choose direct bytes versus MD5 using the current
   value's encoded length. RTPS 2.5 instead uses the key-holder type's maximum
   serialized size. A runtime cannot infer that from bytes alone; generators
   must supply the policy. Changing only the shared primitive core cannot fix it.

The string discrepancy is narrower than the initial design notes suggest:
**neither implementation checks the final wire NUL**. C's allocating reads reject
embedded NUL content and synthesize their own terminator; its borrowed read does
not reject embedded NULs. Zig's slice representation has no C free-by-`strlen`
constraint. Specify common wire validation separately from ownership adapters.

Recommended next implementation slice: establish independent key/invalid-input
vectors, then demonstrate one primitive implementation through native Zig and
the unchanged C state layout, in both byte orders and all three output modes.
Keep schema-specific canonical key traversal as an explicit associated fix.

## Capability inventory

Primary sources are `packages/zidl-rt/src/cdr.zig`,
`packages/zidl-cdr/include/zidl_cdr.h`, and
`packages/zidl-cdr/src/zidl_cdr.c`. Header introductions and quick-start examples
are not authoritative: the C header still says LE-only although its API and
implementation support BE; `zidl-rt/src/root.zig` shows an older writer signature.

| Operation/contract | Native Zig today | C ABI today | Consolidation requirement |
| --- | --- | --- | --- |
| Version | Writer specializes on `.xcdr1`/`.xcdr2`; reader parses version | Runtime integer `1`, `2`, or `3` (PL_CDR) | Translate PL_CDR explicitly; do not cast C integers to Zig enums |
| Output | LE ordinary writer | LE/BE selected on writer | Both orders in shared primitives; LE remains Zig compatibility default |
| Input | LE/BE, encapsulation IDs 0–3 and 6–11 | Same IDs | Preserve final/delimited/mutable IDs, not just version |
| Growable writer | Caller-owned ArrayList and explicit allocator | Lazy allocation through registered allocator, grow callback | Preserve ownership and capacity/free conventions |
| Fixed writer | No explicit mode in main writer | Caller storage; overflow status | Allocation-free operation |
| Counting writer | No explicit mode in main writer | Null buffer/null grow callback; advances counters | Count padding, encapsulation and framing without dereferencing output |
| Cursor origin | Writer `pos` counts payload; reader `pos` is absolute, origin 4 | Same; writer `len` includes encapsulation | Keep alignment origin distinct from storage index |
| Primitives | Signed/unsigned 8/16/32/64, bool, char, wchar-as-u16, float/double | Same widths; wchar via u16 functions | Share integer/float wire mechanics, retain language-facing conveniences |
| Fixed decimal | Comptime digits/scale, f64 API, BCD | Runtime digits/scale, double API, BCD | Preserve existing mapping while recording limitations below |
| Strings | Borrowed byte slice; owned byte/u16 slices, skip helpers | Borrowed pointer+length; owned NUL-terminated strings/wstrings | Wire spans in core; allocation/termination at boundary |
| DHEADER | Reserve/patch and conditional helpers | Same; `SIZE_MAX` absent-offset sentinel | Shared endian-aware patch operation; offsets remain absolute buffer offsets |
| EMHEADER | LC 0–3 write, LC4 reserve/patch; LC0–7 read | Same; C masks supplied ID/LC | Preserve NEXTINT peek for LC5–7 and reject derived u32 length overflow |
| Mutable decoding | End-position and skip helpers | Same | Add explicit enclosing-boundary validation rather than assuming helper names imply it |
| Skip/seek | Bytes, primitive runs, strings/wstrings, absolute seek | Bytes, primitive runs, seek; no public string skip | Preserve empty-run no-alignment behavior and checked arithmetic |
| Key hash | Streaming first16+MD5, BE, alignment 4, no DHEADER | Hashes materialized key bytes; generated traversal selects BE XCDR1 | Share sink primitives; generator must provide maximum-size policy |
| Discovery PL_CDR | Dedicated LE writer; repeated/raw parameters; strict/lenient reader | LE framing helpers; returns sentinel as a parameter, no policy selector | Keep discovery policy above common framing |

Framing helpers are not schema interpreters. Optional-presence, selected fields,
union arms, collection DHEADER choices, bounds and cleanup remain generated.

## Semantic and invalid-input findings

### Canonical keys: independently established behavior

Source: locally inspected OMG DDSI-RTPS 2.5, `formal-22-04-01.pdf`,
section 9.6.4.8, printed pages 187–190 (local file under
`/home/tsimpson/code/OMG_specs/`). The algorithm requires final key holders,
recursive key selection and member-ID ordering; PLAIN_CDR2 BE without
encapsulation/type/member headers; zero padding and maximum alignment four;
and selection of direct bytes/MD5 from the type's maximum serialized size.

Concrete alignment witness: key fields `octet = 0xaa` followed by
`unsigned long long = 0x0102030405060708` have canonical bytes
`aa0000000102030405060708` (12 bytes). Current C/C++ writer selection yields
`aa000000000000000102030405060708` (16 bytes). Both fit the direct-hash case,
but produce different identities.

RTPS example 3 supplies an independent maximum-size witness. A key holder with
`long = 0x12345678` followed by `string<12> = "BLUE"` has actual bytes
`1234567800000005424c554500` (13 bytes), maximum size 21, and specified MD5
`374b96e2e727237f016cc4cebb6eb71e`. Both current helpers return
`1234567800000005424c554500000000` instead. A temporary C probe reproduced
this and independently obtained the specified digest using `zidl_md5`.

Implementation evidence: Zig `KeyHashWriter.align_` and `final`; C
`zidl_cdr_compute_key_hash`; C generator around lines 2410–2426; C++ around
2026–2037; Zig around 3980–3990. Their public hash interfaces currently have
no type-maximum/force-MD5 input. Preserve existing symbols but introduce a
deliberate policy-aware path for regenerated code; do not silently change a
byte-only helper into a guessed type-aware operation.

The generated Zig `serializeKey` loops through `s.members`, calling ordinary
type-writing helpers for nested values. Before claiming canonical-key parity,
add explicit-ID reordering and nested aggregate/union/collection vectors in
all native backends. Wire key-only sample encoding and canonical key-holder
encoding have different framing requirements; changing XCDR1 to XCDR2 in C's
hash helper alone would introduce conditional DHEADERs for some schemas.
Keep those two purposes explicit. Changes to identities need migration notes
and coordinated Java validation even though Java extraction is separate.

### Strings and allocation

For input `00070000 02000000 4158` (XCDR2 LE, declared two-byte string `A X`
with no NUL), a temporary C probe confirmed both borrowed and allocating reads
succeed. The owned result becomes `A\0`. Code inspection shows the same missing
terminator check in Zig `readStringZeroCopy`; both wide-string readers discard
the final u16 without checking its value. Zero declared length is rejected.

C's owned string/wstring embedded-NUL rejection is essential to its existing
free API: allocation size is reconstructed by scanning for NUL. Preserve exact
sizes and alignment even if the common decoder exposes length-bearing spans.
Zig's owned narrow string excludes the terminator, and its owned wstring allocates
`len - 1` u16 values. C allocates the terminating element as well. These are
intentional adapter differences, not competing wire formats.

Recommended deliberate correction: verify final wire terminators in shared
string reading, including skip/borrow paths, and preserve C owned embedded-NUL
rejection. Decide/document whether embedded NUL rejection also applies to
length-bearing Zig and borrowed C APIs; do not infer that decision merely from
C allocation-size reconstruction. Validate narrow/wide counts against available
input before allocating, including checked byte-count multiplication on 32-bit.

### Bounds, overflow, errors and partial progress

| Finding | Evidence and implication |
| --- | --- |
| Zig `readSlice`/`skip` use `pos + n` | A hostile `usize` count can overflow; C already uses subtraction after maintaining `pos <= data_len`. Zig alignment can advance beyond the buffer. Port the invariant, not just the C expression. |
| Reader seek permits positions below 4 | Both public seek helpers only check the upper bound; alignment subtracts 4. Define valid payload-origin behavior explicitly and avoid underflow in the new core. |
| Writer arithmetic is not uniformly checked | C `writer_ensure`, growth doubling and counter increments can wrap; counting mode skips capacity checks entirely. Zig counters, string lengths and patch casts can overflow/trap. Counting still needs overflow detection. |
| Framing ends are not validated at creation | Both mutable-DHEADER helpers return `pos + size` without checking the enclosing buffer. C PL reader similarly computes an end without validating the body; Zig PL reader has a strict/lenient policy and body check. A valid header alone does not prove member/body containment. |
| Patch functions return void | Invalid offsets, negative-relative lengths or payloads larger than u32 cannot currently report a C error through these signatures. Preserve valid-call behavior; use checked internals and explicitly define invalid-call handling/API additions. Do not add an invisible sticky-error field to the ABI. |
| PL lengths are u16 | Oversized parameter patch truncates in C and can trap on Zig's cast. Detect oversize before patching. |
| PL BE is incomplete | C ordinary primitives honor BE, but dedicated PL encapsulation, length patch and sentinel use LE bytes. Zig dedicated PL writer is LE. Do not advertise complete BE PL writing based on ordinary writer support. |
| Fixed decimal exceeds implementation arithmetic | C accepts runtime digits with fixed-size arrays and no entry validation. Both read through u64; Zig writer computes `10^D` in u64. Claimed 31-digit support exceeds that arithmetic. NaN/large float conversion and invalid BCD sign/pad also need explicit coverage. |

C statuses are `OK`, `OVERFLOW` (also allocation failure), `TRUNCATED`, and
`INVALID`; short/unknown encapsulation returns `INVALID`. Zig has distinct
errors including `InvalidEncapsulation`, `EndOfStream`, `InvalidBool`,
`InvalidString`, `InvalidEmheader`, fixed-digit and PL-policy errors, plus
allocator errors. Write down exhaustive translation as operations move.

Existing operations are not transactional. Alignment/padding, length prefixes,
or earlier field writes can advance before a later read/write fails. Capture
cursor/output results for failure cases before migration; do not promise
rollback. C reader alignment clamps to input length on a truncated aligned read.
Borrowed data remains valid only while the original input remains alive;
writer growth can invalidate pointers into its buffer.

## ABI and generator dependencies

The C structs are concrete, regardless of their opaque-field comment. Preserve
field order, integer types, function-pointer calling convention and all exported
`zidl_cdr_*`/`zidl_md5` symbols. Also retain `ZidlEmHeader`, `ZidlPlParamHandle`,
`ZidlPlParam`, constants and `ZidlAllocator` declarations.

A C11 `sizeof`/`_Alignof`/`offsetof` probe on this Linux x86_64 host measured:

| Struct | Size/alignment | Field offsets in declaration order |
| --- | --- | --- |
| `ZidlCdrWriter` | 48 / 8 | buf 0, cap 8, len 16, pos 24, version 32, order 36, grow_fn 40 |
| `ZidlCdrReader` | 40 / 8 | data 0, data_len 8, pos 16, order 24, version 28, is_pl_cdr 32 |

These measurements are one target's baseline, not portable layout constants.
Add C-versus-Zig size/alignment/offset assertions on each supported ABI.

| Generator/consumer | Direct dependencies found |
| --- | --- |
| `src/backend/c.zig` | Writer `len` for member boundaries, counting/loan sizing; `buf`/`len` for hash and raw publication; reader `xcdr_version`/`pos` for framing |
| `src/backend/cpp.zig` | Same direct writer/reader fields; standard C++ values remain outside runtime state |
| `src/backend/zig.zig` | Reader `xcdr_version`, `pos`, `data` (retained raw PL values); concrete `*zidl_rt.CdrReader` read signatures; duck-typed writer methods |
| `src/backend/cdr_skip.zig` | Shared C/C++ skip codegen calls public runtime helpers; schema-aware collection framing stays here |
| Zig C export generation | `--zig-generate-c-api-cdr-allocator` deliberately gates `zidl_cdr_get_allocator` linkage; ordinary Zig/C exports must not acquire an unconditional C-runtime dependency |
| zzdds discovery | `src/discovery/wire_codec.zig`, SPDP/SEDP use native PL writer/reader and generated traversal; strict/lenient and retained unknown fields are required behavior |
| `zidl-typesupport` | Uses `zidl_rt.CdrReader`; adds its own stricter representation/options/trailing-byte policy. Keep that policy outside the general reader |

The public `grow_fn` is also observable. It receives a writer and additional
bytes needed; default deinit frees only when the callback equals the default
grow function. Preserve custom callback behavior and post-call state updates;
do not assume all non-null callbacks imply runtime-owned storage.

## Dependency and ownership boundary

Current `zidl-rt` has no package dependencies. Its root re-exports codec,
allocator adaptation, entity boxes, bounded storage, owned-value utilities and
authoring. `BoundedArray` physically lives in `cdr.zig`; `owned.zig` also refers
to it in tests. `authoring.zig` depends on owned support. `entity_box.zig` and
`allocator.zig` use std, not CDR. `zidl-cdr` currently depends on `zidl-rt` for
cross-validation and translate-c for its header; main builds also create runtime
modules directly, bypassing package builds. zzdds re-exports the same `zidl_rt`
module object to avoid duplicate Zig module/type identities.

Proposed acyclic layout:

```text
zidl-cdr: common wire operations + native Zig facade
    C adapter target -> common wire operations + allocator ABI/support
zidl-bindings: bounded storage + owned values + entity boxes + authoring
    allocator adaptation -> allocator ABI/support
zidl-rt compatibility root -> zidl-cdr + zidl-bindings
```

Allocator ABI/support can be a small module, not necessarily a published
package. The shared core must not import the compatibility root or bindings.
Move codec cross-validation dependencies into tests so `zidl-cdr -> zidl-rt ->
zidl-cdr` does not become a build cycle. Keep native module exports usable without
translate-c, libc, or linking the C artifact; C-specific tooling belongs to its
target/tests. Check older generated-code/compiler lanes before adopting new Zig
syntax throughout the compatibility umbrella.

The C adapter owns the process-wide registered allocator pointer and libc
fallback. Existing C allocations use alignment 8; writer realloc/free use capacity
bytes, owned narrow strings include NUL, and wide strings use element count
including NUL times two. Preserve resize-or-allocate/copy/free fallback,
allocation failure behavior and callback lifetime. Changing the registered
allocator while values remain alive cannot preserve pairing; existing startup-only
discipline remains. `volatile` is not concurrent allocator registration support.

Build a single allocator-state provider per linked runtime arrangement. Current
zzdds embeds C source into its module, builds an installed archive, and some
smokes compile C source again while linking the shared library. Static archives,
shared libraries and provider plugins can therefore create multiple copies or
platform-dependent symbol interposition. This audit identifies the exposure;
it does not establish that a current deployment already misroutes allocations.
Require a real shared/static multi-library allocator test before declaring the
new arrangement safe.

## Build, installation and target inventory

| Source/build path | Required migration |
| --- | --- |
| `packages/zidl-cdr/build.zig` | Replace C-only library module; retain installed archive name and test reference path |
| `zidl/build.zig` | Direct C compilation in conditions, C/split-C/C++ and named integration modules; route all through canonical build/module targets |
| `zzdds/build.zig` | Direct source at current lines 453 (main module), 642 (archive), 824/881 (smokes); retain header/allocator install, shared-library linkage and smoke behavior |
| zzdds CMake/pkg-config | Preserve imported `ZZDDS::zidl_cdr`, library filenames and transitive link requirements |
| macOS archive install | Existing repack through `zig ar --format=darwin` addresses Apple linker member alignment; verify the new object/archive rather than dropping this path by assumption |
| Windows external linker | Existing archive disables C sanitizer/stack-protector hooks to avoid unresolved symbols in MSVC consumers. Zig-backed Debug/ReleaseSafe artifacts need an explicit panic/compiler-runtime/export audit |
| Example build recipes | Most downstream C/C++ examples already link installed artifacts; OpenCV codegen helper retains a source-compilation comment. Update documented direct-source recipes in backend C/C++, testing, runtime and implementation-status docs |
| zzdds local override | Use `-Dzidl-source=/absolute/checkout` so generator/runtime/package sources move together; a sibling checkout alone does not establish that the pinned dependency changed |

Current CI/release lanes establish a required preservation baseline of Linux
x86_64 and ARM64, macOS ARM64, and Windows x86_64. zzdds also tests static
x86_64 Linux musl. zidl has generated Zig compatibility/embedded XRCE lanes,
including older Zig compiler use; preserve the native no-libc boundary there.
These lanes do not establish a supported new C archive on every freestanding
or C-only target mentioned by the old header. 32-bit and big-endian hosts need
specific validation; reading BE wire bytes on an LE host is not BE-host testing.

Define static/shared artifacts, libc/compiler-runtime dependencies, visibility
and allocator-state ownership before promising replacement distribution parity.
Building the runtime will require Zig; installed-artifact C/C++ applications must
continue to compile/link with their normal non-Zig toolchains.

## Validation inventory and migration gates

Commands below come from current build scripts/CI, not runtime-doc test counts.
Run package commands from their directories. Use the checkout's Zig 0.17.0.

| Layer | Existing command/evidence |
| --- | --- |
| Native Zig runtime | `cd packages/zidl-rt && zig build test --summary all` |
| C runtime and temporary differential oracle | `cd packages/zidl-cdr && zig build test --summary all` (`test/roundtrip.zig`) |
| Generator/unit/Zig integration | `zig build test`; `zig build check-goldens` |
| Independent collection/extensibility vectors | `zig build test` also runs `test/integration/xcdr_known_answer/` for Zig/C/C++ and optional Java: primitive/nonprimitive/nested collections, arrays, appendable/mutable holders, LC5–7 and minimal TypeObject hashes. `vectors.txt` records an independent implementation as producer; its tooling is not in the repository |
| Generated C/C++/Java | `zig build integration-test`; verify Java/JNI actually ran rather than being skipped |
| Independent byte fixtures | `zig build interop-test`; `interop/zig_interop_test.zig` embeds Cyclone-derived vectors; retain committed `interop/expected/*.bin` and fixture provenance |
| Fresh external peer vectors | `make -C interop regen CYCLONE=/path/to/cyclonedds`; this modifies fixture artifacts, so review independently rather than regenerate to match new output |
| zzdds binding smoke | `zig build test-bindings -Dzidl-source=/absolute/zidl -Dc-binding=true -Dcpp-binding=true -Djava-binding=true` |
| zzdds tests/integration | `zig build test` with local source override; `examples/run_all.py` and `examples/interop/raw_loan_cross_binding_smoke_test.py`, following their installed-artifact prerequisites |
| External compiler consumers | `scripts/verify_release_bundle.py --bundle <local-bundle>` exercises CMake/pkg-config and C/C++ examples from a relocated install; run per target using a locally built bundle, without publishing |

Existing runtime coverage includes ordinary primitive/alignment/string roundtrips,
fixed decimal small values, DHEADER/EMHEADER including LC5–7, PL framing,
empty primitive skip, C allocator routing/embedded-NUL cleanup and C cursor
overflow/truncated-alignment regressions. The C package is heavily differential;
these tests lose independent-codec status after consolidation. Existing native
interop vectors do not resolve all canonical key, malformed-input, BE-output,
counting, allocation-failure or ABI questions.

Before removing the C implementation from production, add or explicitly locate:

- RTPS example 3 and mixed u8/u64 canonical keys; explicit IDs, nested keys,
  bounded/unbounded maximum-size policy and aggregate framing cases.
- LE/BE known answers for fixed, dynamic and counting writers, with identical
  size/cursor results and patches; no output dereference in counting mode.
- Exact-capacity/short buffers, size overflow, malformed terminators/counts,
  framing confinement, PL oversize, allocation failure and cleanup evidence.
- C/Zig ABI assertions and fresh external C/C++ links per target, including
  Debug/ReleaseSafe and applicable instrumentation builds.
- Shared/static/provider allocator-state tests, custom allocators, native/Java
  raw loans and full-sample versus key-only callbacks.
- Representative payload/allocation baselines, adapter conversion overhead and
  artifact size. No speed or footprint improvement is established by this audit.

### Local audit execution

The C11 probe compiled the current C source with the system C compiler and ran
successfully, measuring the layouts and reproducing the malformed-string and
canonical-key witnesses above. Temporary probe files are under `/tmp/native-cdr-audit*`;
the witness bytes and spec example here are the durable evidence, not those paths.

Executed successfully with `/home/tsimpson/code/zig-x86_64-linux-0.17.0/zig`:

- Native runtime root: **84/84 tests passed**, using direct `zig test` on
  `packages/zidl-rt/src/root.zig`.
- Independent Cyclone vector suite: **10/10 tests passed**, using direct
  `zig test --dep zidl_rt -Mroot=interop/zig_interop_test.zig
  -Mzidl_rt=packages/zidl-rt/src/root.zig` from zidl.
- Three temporary Zig witness tests passed: missing terminator accepted,
  four-byte canonical alignment, and the current actual-length hash decision.
  These characterize current behavior; they do not certify its correctness.
- The C witness compiled with `cc -std=c11 -Wall -Wextra -Wpedantic` against
  the current header/source and ran successfully.

Direct Zig test commands used explicit `--cache-dir` and `--global-cache-dir`
under `/tmp`. Normal package/build-runner attempts encountered a read-only
cache error in the sandbox. Escalated build-runner attempts produced no output
or completion and were interrupted; they are **not passing results**. The full
C package suite, generator/known-answer integration, zzdds smoke/loan checks,
external peer runs and multi-platform artifact checks were inventoried but not
completed in this audit. The audit itself changed no codec/generator production
source; subsequent implementation is tracked in the
[primitive writer checkpoint](native-cdr-primitive-slice.md) and
[reader/cursor checkpoint](native-cdr-reader-slice.md).
