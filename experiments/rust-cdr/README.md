# Rust CDR ABI experiment

A dependency-free, unpublished experiment for the [Rust codec proposal](../../docs/design/rust-cdr-plan.md).
It wraps the canonical native CDR archive through its C ABI. This is not a Rust
backend or a second CDR implementation. The small public API is experimental.

Build/install the native archive separately with zidl's supported Zig compiler:

```sh
cd packages/zidl-cdr
zig build install --prefix /absolute/path/to/cdr-sdk
```

Then use a Rust toolchain to consume that prebuilt archive:

```sh
ZIDL_CDR_PREFIX=/absolute/path/to/cdr-sdk cargo test --offline --manifest-path experiments/rust-cdr/Cargo.toml
python3 experiments/rust-cdr/verify.py --prefix /absolute/path/to/cdr-sdk
```

The first command invokes no native source compiler or Zig. Rust still needs its
normal platform linker toolchain (the default Unix linker driver is `cc`). The
second command additionally compiles a validation-only C layout probe, compares
sizes/alignments/offsets, and checks expected Rust borrow-checker diagnostics.
The probe is not part of downstream Cargo builds. On Linux, verification also
builds/tests a relocated SDK with only Rust tools and a link-only driver on PATH;
that driver rejects native source compilation and Zig is unavailable. On Windows run from an MSVC
developer prompt and pass `--cc cl` to verify.py. Linux/macOS link `libm`; MSVC
links `ntdll` as required by the native archive. The dedicated experiment workflow tests Rust 1.85.1 on Linux x86_64/ARM64,
macOS ARM64 and Windows MSVC. Cross-target results must be measured, not
inferred from the Linux run.

## Boundary under test

Reader retains an immutable slice; Writer retains an exclusive mutable slice.
Their raw cursors are private. Fixed output preserves the non-null empty-slice
pointer, so an empty output cannot accidentally select native counting mode.
Counter owns no buffer and exposes only position/length and writes. There is no
native dynamic allocation, allocator setter, Rust ownership of native memory,
reference into arbitrary CDR bytes, or unsafe Send/Sync implementation.

Native status codes become distinct Rust errors. Error returns do not promise
transactional cursor rollback: invalid bool consumes its byte, and an aligned
read/write can consume padding before failing for lack of value bytes. A reader
truncated inside padding advances to the input limit. Tests
record those contracts. A failed fixed write is not a complete serialized sample.

Four independent vectors cover both XCDR versions and byte orders, with a u64
alignment witness distinguishing the versions. Other vectors check signed
integers and IEEE float bytes. Negative tests cut every vector prefix, reject
invalid encapsulation/bool, and check zero/short output and a guard byte beyond
fixed capacity. Compile-fail checks reject escaped readers/writers, overlapping
writers and mutation of borrowed input with specific diagnostic codes.

This does not validate strings/UTF-8, sequences, extensibility traversal, keys,
TypeObjects, generated Rust declarations, native allocator integration, DDS
loans, callbacks or performance. A first backend PR needs separate scope and
mapping decisions after reviewing the results.
