# Experimental Rust wrapper for zidl-cdr

This unpublished crate wraps the canonical native CDR C ABI. It contains the
borrowed reader, fixed/counting writers and scalar operations validated by the
[ABI experiment](../../experiments/rust-cdr/README.md). It is not a pure Rust
codec and does not implement DDS object/loan ownership.

Set `ZIDL_CDR_PREFIX` to a matching installed native SDK (`include/`, `lib/`).
Cargo links the prebuilt archive; it never fetches or builds Zig/C code. A normal
Rust platform linker toolchain is still required. Readers admit only plain CDR1/CDR2 encapsulation in this final-only slice.
No dynamic native allocation
or allocator registration API is exposed. The crate is edition 2021, tested
with Rust 1.85.1, and its public API is not stabilized or published.

Generated structs/enums call the shared `Write` trait, so the same traversal
works with fixed output and counting output. `read_array` constructs fixed
arrays with safe Rust, without a Default bound or heap allocation. Rust fields
are not reinterpreted as C/Zig objects or as a CDR wire layout.

See the [Rust backend guide](../../docs/backend_rust.md) for mappings, limits,
error/cursor behavior and an example. `layout()` exists only to support the
validation probe; it is not a runtime ABI negotiation mechanism.
