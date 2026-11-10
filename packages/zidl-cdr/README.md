# zidl-cdr

Canonical native CDR codec. Import `zidl-cdr` (`zidl_cdr` alias). It has no
package dependencies. Run `zig build test` for native codec tests.

`zig build` installs the shared native C ABI archive and headers. Building the
archive requires Zig; C/C++ applications can link it with their normal compiler.
For MSVC, build it for an MSVC-ABI target (`-Dtarget=x86_64-windows-msvc`): an
archive for Zig's default Windows target (GNU ABI) does not link with MSVC. The
archive names `ntdll`, which its Zig runtime calls, as a default library.
`src/zidl_cdr.c` contains storage/allocator support only and cannot provide the
codec by itself. The public C ABI and archive name are unchanged.

C ABI validation lives in `c-api/`. Run `zig build test test-external-c` there
for the shared archive, or `zig build test -Dshared-primitives=false` for the
test-only independent C reference. The external consumer uses the system C
compiler on Linux/macOS, and `cl` for an MSVC-ABI target from a Visual Studio
developer environment on Windows.

See [production build switch](../../docs/design/native-cdr-production-slice.md).
