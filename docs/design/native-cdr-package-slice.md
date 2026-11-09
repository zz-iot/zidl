# Native CDR package placement

Date: 2026-11-09

Status: implemented locally with generated-import migration and production
archive selection; zzdds migration and umbrella removal follow next.

`packages/zidl-cdr` owns the native codec, bounded storage and wire operations.
It has no package dependencies. `packages/zidl-bindings` owns allocator adapters,
owned values, entity boxes, retirement observers and authoring support, and
has a one-way dependency on the codec. `packages/zidl-rt` temporarily forwards
its root API to both packages for zzdds to migrate.

## Generated imports and module identity

Generated codecs import `zidl_cdr`; generated ownership, allocator, authoring and
entity helpers import `zidl_bindings`. New output has no `zidl_rt` import.
Regenerate application code when updating the dependency. Obtain the modules
from a single dependency owner:

```zig
const runtime = b.dependency("zidl_bindings", .{ .target = target, .optimize = optimize });
app.addImport("zidl_cdr", runtime.module("zidl_cdr"));
app.addImport("zidl_bindings", runtime.module("zidl-bindings"));
```

The package modules are `zidl-cdr`, `zidl-bindings` and the temporary `zidl-rt`;
underscore aliases are also exported. These aliases return the same module
pointers. Independently constructing duplicate modules can create incompatible
Zig types or duplicate retirement state. Root zidl exports the two canonical
modules and its typesupport module using the same graph.

The compiler's builds, tests, XRCE fixture and standalone typesupport recipe
supply the canonical modules directly. Only the umbrella root API is retained;
per-file legacy shims have been removed. Its tests check codec/allocator type
identity and cross-module retirement, including repeated retirement. Runtime
suites live with their owning implementation and run in the root test step.

## C ABI and source builds

The C headers, public symbols and `libzidl_cdr.a` name are unchanged. The codec
package still exports the `zidl_cdr` build artifact and installs its headers.
`zig build` installs the shared native implementation by default; the remaining
C source supplies storage/allocator support, not an independent wire codec.

`packages/zidl-cdr/c-api` owns C ABI tests, independent C reference comparisons
and the translate-c dependency. Native codec consumers do not fetch translate-c.
From that directory, run:

```sh
zig build test test-external-c
zig build test -Dshared-primitives=false
```

The external consumer currently requires Linux/macOS and a Unix-style compiler.
The release CDR source archive builds without sibling packages. See the
[production checkpoint](native-cdr-production-slice.md) for archive distribution
and the zzdds dependency boundary. Building the production archive requires Zig;
C/C++ applications link it with their normal compiler.

## Migration and retirement

After this PR, migrate zzdds and pin the merged zidl revision. Remove `zidl-rt`
immediately after both repositories pass on the new imports. There is no planned
long deprecation period or special breaking-release requirement.

## Validation

Full root, generated-code and interoperability checks pass all 189 build steps;
the initial full run executes 1,341 tests and the final run reuses cached suites.
Standalone codec/binding/umbrella suites pass 87/15/3 tests on Zig 0.15.1 and
0.16.0. Generated authoring consumers pass all 15 tests on both versions using
the new imports. CI repeats those package and consumer checks.

Production and reference C ABI suites pass their 103 contracts. Installed
Debug/ReleaseSafe archives pass system GCC/G++ consumers. The Zig 0.15.1-built
archive also links and runs with system C. An extracted source archive builds
without sibling packages and passes native and C ABI suites, including the
external C consumer. Formatting and whitespace checks pass.
