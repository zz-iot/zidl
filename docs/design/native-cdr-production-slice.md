# Native CDR production build switch

Date: 2026-11-09

Status: zidl implementation complete locally; zzdds migration and dependency
pin update follow in the next PR.

The `zidl-cdr` package now builds the shared native C ABI archive by default.
Its public headers, C symbols and `libzidl_cdr.a` name are preserved. Wire
operations use the canonical Zig codec, including the public MD5 entry point.
`src/zidl_cdr.c` is a small storage/allocator support layer, not a second wire
codec. It retains allocator registration, buffer growth and writer lifetime
behavior. The independent C codec lives at `test/reference/zidl_cdr.c` and is
selected only by the C ABI validation package with `-Dshared-primitives=false`.
The production package rejects that option rather than silently installing the
reference codec. `-Dshared-primitives=true` remains accepted for existing scripts.

All root generated C/C++ integration tests link the production archive. They no
longer compile the old codec source into each executable. Known-answer wire
vectors and external interoperability evidence remain independent of this core;
C-versus-Zig round trips alone no longer validate two independent codecs.

## zzdds integration and release boundary

The planned zzdds consumer update constructs one codec archive for its Zig C ABI
exports, shared library,
C/C++ binding smoke tests and installed SDK. It uses the codec module already
owned by its `zidl_rt` graph. This preserves Zig type identity and avoids
constructing another binding registry. Standalone archives bundle the Zig
compiler runtime for external C/C++ linkers. C support compilation disables
C sanitizer/stack-protector hooks, so nothing references the UBSan runtime and
it is not bundled; native Zig bounds and overflow checks remain.
TSan archive builds use LLVM. The macOS install path retains Darwin archive
repacking and includes the Zig runtimes in the repacked object.

The existing zzdds zidl pin predates this migration and is unchanged. For now,
`-Dzidl-source=/absolute/path/to/zidl` selects generator/runtime sources
together. The next zzdds PR must wire the new generated imports as well as the
shared archive. The current pin keeps its older C build path.
A merged zidl revision containing this migration must be pinned before normal
zzdds builds select the shared codec. Do not publish a nonexistent dependency
hash or describe that dependency rollout as already complete.

The handwritten C++ support wrappers also adapt to the newer generated family
cache entries. They preserve sibling wrappers and register retirement callbacks
for both the extension implementation and its composed DDS implementation.
A template fallback retains the older weak-pointer cache used by the current
pin. A regression keeps both wrapper types alive through retirement and checks
that their native handles become null.

## Source and binary distribution

C/C++ applications still compile against the C headers and link the static
archive using their normal toolchain. Building that archive from source now
requires Zig; compiling `src/zidl_cdr.c` alone provides only storage/allocator
support. The test-only C reference is not a supported production fallback.
The release source archive includes the native implementation and build helper.
The installed SDK link names are unchanged.

MSVC links only an archive built for an MSVC-ABI target
(`-Dtarget=x86_64-windows-msvc`). One built for Zig's default Windows target
(GNU ABI) fails with `LNK1143` on its bundled compiler runtime. The Zig runtime
in the archive calls ntdll directly, so `src/zidl_cdr.c` names it as a default
library for MSVC-ABI builds. The bundled UBSan runtime's `/exclude-symbols`
directives were MSVC `LNK4229` warnings, and it is no longer bundled.
`test-external-c` links the archive with `cl` on Windows CI, in Debug and
ReleaseSafe. Generated Zig imports now name
`zidl_cdr` and `zidl_bindings`; regenerate and wire both modules when updating.

## Validation

- Full root, generated-code and interoperability checks pass 189/189 steps and
  1,341 tests on the new imports.
- Native codec, bindings and umbrella suites pass on Zig 0.15.1 and 0.16.0.
  Version-matched generated authoring consumers use the new imports too.
- Production C ABI and independent reference contracts pass; installed shared
  archives link with system C/C++ compilers in Debug and ReleaseSafe.
- Standalone CDR source packaging includes the build helper, native source,
  headers, tests and reference codec; it needs no sibling package.

Earlier local work verified the shared archive through zzdds Zig/C/C++/Java,
allocator/loan tests and Windows/macOS cross-builds. Those checks predate the
new generated-import contract and must be repeated in the zzdds consumer PR.
Native Linux checks do not replace native Apple linker CI; MSVC is now
covered by `test-external-c` on Windows.

The next zzdds PR migrates its imports and generated-module wiring, then pins
this merged revision. Once that passes, remove the temporary `zidl-rt` umbrella
promptly rather than carrying a deprecation window.
