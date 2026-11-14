# Rust CDR follow-up proposal

Date: 2026-11-12. Status: proposed; no Rust backend or crate exists yet.
The [native consolidation](shared-native-cdr.md#consolidation-closeout) and
shared Java delivery prerequisites are complete. This replaces the old roadmap
sequence that started by adding a second pure Rust codec.

## Proposed first interface

Generate ordinary owned Rust values and schema-specific traversal. Put raw
`extern "C"` declarations in a small internal or sys layer and expose checked
reader/writer operations through a safe wrapper over `zidl_cdr_*`. Package/crate
names, edition and minimum supported Rust version remain to be selected by the
first experiment. Generated topic values do not need C or Zig object layouts.

A separate pure Rust codec would add another wire implementation and test burden.
Consider it later for an identified deployment constraint or measured workload.
Using the shared C ABI does not establish a performance advantage: compare
representative per-field foreign calls and bulk spans before making that claim.
The initial standalone codec must not depend on zzdds or its DDS runtime.

## Ownership and safety requirements

- Readers borrow immutable input. Validate all offsets, lengths and native status
  results before forming references. Rust strings require explicit UTF-8 policy;
  the C string API's terminator checks alone do not establish valid Rust text.
  Do not reinterpret arbitrary wire bytes as aligned Rust structs or enums.
- Fixed writers borrow exclusive output; counting writers expose only a size.
  Start with those modes to avoid coupling safe Rust values to the process-wide
  native allocator. Preflight sizes and handle mismatched/failed second passes.
- An empty Rust output slice still has a non-null pointer in fixed mode: the C
  writer distinguishes fixed from counting using its buffer pointer. Test this
  boundary rather than turning an empty slice into a null pointer.
- If a later wrapper owns native dynamic output, its destructor must use the
  native deallocator. Never construct a Rust Vec/String owner over native memory
  unless allocation layout and deallocation contracts have been established.
  Do not expose a safe process-wide allocator setter that permits changing the
  allocator while native allocations remain live.
- Bind C struct layouts, integer widths, callbacks and status values from the
  installed headers. Validate size/alignment/offsets against compiled C probes
  on each supported target. Keep reader/writer fields private in the safe API.
- Preserve wire enum/discriminator values that Rust enums cannot represent;
  choose an explicit unknown-value mapping. Do not promise maps, wide strings,
  fixed-point decimals, extensibility or TypeObjects before defining their
  mappings and negative-input tests.

See Rust's [FFI guidance](https://doc.rust-lang.org/nomicon/ffi.html) for the
unsafe boundary and allocation obligations. The wrapper must document the
invariant supporting each unsafe operation; Rust declarations alone cannot
validate a foreign ABI.

## First experiment and acceptance

Build the CDR archive with zidl's supported Zig toolchain, then compile a small
Rust consumer with a Rust toolchain and prebuilt archive only. First inspect
link requirements on Linux, macOS and Windows; build scripts must not silently
fetch tools or compile Zig. Use the same native codec instance when linking DDS
later so allocator state and symbols are not accidentally duplicated.

The experiment covers primitive reads/writes, both byte orders, encapsulation,
alignment, fixed/counting output, empty buffers, truncation, overflow, invalid
bool/status translation and failure cursor behavior. Include independently
specified wire bytes, not only roundtrips against the same native implementation.
Add compile-fail cases for readers/writers escaping their backing buffer and
for overlapping mutable writers. Check ABI layouts with a C compiler during
validation, not in every downstream consumer build.

Only after this experiment passes should the next PR add a minimal `-b rust`
backend for final fixed-shape types. Expand to owned sequences/strings, keys,
optionals and extensibility with independent vectors and an explicit supported
feature table. Borrowed DDS loans belong to the separate middleware plan, not
to the codec ownership model. Public API and backend scope remain open until the experiment is reviewed.
