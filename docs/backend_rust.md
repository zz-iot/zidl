# Experimental Rust backend

`zidl -b rust` emits one `<stem>.rs` file with ordinary owned values and
schema-specific traversal over the shared native CDR C ABI. It is an initial
subset, not a complete DDS binding or a published Rust SDK. The companion
`packages/zidl-cdr-rust` crate is unpublished and its API remains experimental.
The codec does not implement wire primitives independently in Rust.

## Supported mapping

| IDL | Rust |
| --- | --- |
| Integer primitives, octet | Corresponding fixed-width integer |
| char | u8 wire code unit |
| boolean | bool |
| float, double | f32, f64 |
| Final struct without inheritance | Named-field struct |
| Default-width enum | Public u32 newtype and named associated constants |
| Typedef | Rust type alias |
| Primitive fixed arrays, including multidimensional aliases | Nested `[T; N]` |
| Module | Rust module; identifiers use raw syntax to preserve Rust keywords |

Unknown enum wire values are retained in the newtype rather than converted into
an invalid Rust enum discriminant. Only structs and enums have `encode` and
`decode` methods; aliases retain their underlying Rust API. Primitive aliases
and array aliases are handled when traversed as fields.

Both XCDR1/XCDR2 and both byte orders are supported through the native wrapper.
Only plain CDR1/CDR2 encapsulation is admitted; delimited/parameter-list
representations fail before field decoding. Nested values emit no encapsulation header. `encode` takes a generic runtime
`Write`, implemented by fixed-buffer `Writer` and sizing `Counter`. `decode`
takes a borrowed `Reader`. Neither method allocates a native buffer or changes
the process-wide native allocator. Array construction uses safe Rust and stack
storage with cleanup on failure; arbitrary array sizes do not imply a bounded
stack budget.

Unsupported shapes fail before creating any output: non-final structs,
inheritance, keys, optional/default members, strings, wide characters/strings,
long double, sequences, maps, fixed decimals, unions, bitmasks/bitsets,
interfaces, native declarations and constants. Non-primitive arrays are rejected
because they require XCDR2 collection DHEADERs; no header-free fallback is emitted.
Imports, split files, type prefixes, XRCE and DDS wrapper generation are not yet
supported. Rust's special path identifiers (`self`, `Self`, `super`, `crate`, `_`)
and enum constants named `encode`/`decode` have explicit diagnostics.

## Consumption

Build the canonical native archive once with the supported Zig toolchain, or
supply a matching prebuilt archive and headers. Add the unpublished Rust wrapper
as a path dependency; it invokes no native source compiler or Zig in Cargo builds:

```toml
[dependencies]
zidl-cdr-rust = { path = "/path/to/zidl/packages/zidl-cdr-rust" }
```

Set `ZIDL_CDR_PREFIX` to the installed native SDK, then generate and include code:

```sh
zidl -b rust -o src types.idl
ZIDL_CDR_PREFIX=/path/to/cdr-sdk cargo build --offline
```

```rust,ignore
mod types { include!("types.rs"); }
use zidl_cdr_rust::{Counter, Writer, Reader, Version, ByteOrder};
// sample is a generated struct.
let mut count = Counter::new(Version::Xcdr2, ByteOrder::Little);
count.encapsulation()?;
sample.encode(&mut count)?;
let mut bytes = vec![0; count.len()];
let mut writer = Writer::new(&mut bytes, Version::Xcdr2, ByteOrder::Little);
writer.encapsulation()?;
sample.encode(&mut writer)?;
let mut reader = Reader::new(writer.bytes())?;
let decoded = types::Sample::decode(&mut reader)?;
```

`--no-typesupport` emits the same supported declarations without codec methods
or a runtime dependency. Rust still needs its normal platform linker toolchain.
The wrapper assumes the checked C ABI; arbitrary mismatched archive versions are
not made safe by selecting a Cargo package version.

Errors preserve the native status categories. Reads and writes are not
transactional: padding or an invalid boolean byte can be consumed before an
error. Failed output is not a complete sample. `decode` reads the schema's
fields; the caller owns framing, trailing-input policy and encapsulation setup.
There is no TypeObject, key hashing, whole-sample admission callback or DDS API
claim in this slice.

## Validation and next slices

`test/integration/rust_final/test.py` compiles generated code with Rust 1.85.1,
compares independent endian/version vectors, tests unknown enum values, alias
arrays, nested modules, keyword names, truncation, invalid bools and short fixed
output, compiles runtime-free declarations, and checks unsupported diagnostics
with no partial files. The existing primitive ABI experiment continues to check
C layouts, buffer lifetimes and relocated consumption. The focused workflow runs
these checks on Linux x86_64/ARM64, macOS ARM64 and Windows MSVC.

Next: non-primitive collection framing, owned variable-length values and keys
need separate mapping and negative-input tests. DDS loans, entity ownership and
listeners remain a zzdds task; they do not follow from codec roundtrips.
