# Backend Roadmap

Planned backend work, ordered by dependency and real-world priority.
For what is currently implemented, see [`features.md`](features.md).

---

## Embedded / MicroZig / XRCE Roadmap

**Status:** `--profile xrce` exists and validates important XRCE constraints before
backend generation: only `@final` types, bounded strings/sequences, no maps, no optional
members, no wstring, and no TypeObject/TypeIdentifier output. The Zig backend now accepts
`--zig-version 0.15.1` and emits bounded sequence/string code that uses fixed-capacity
`zidl_rt.BoundedArray` storage instead of heap-backed containers.

This is the first MicroZig-enabling slice, not a complete freestanding output mode yet.
zidl itself still builds with Zig 0.16.0; the 0.15.1 target is for generated Zig code and
`zidl-rt` consumers.

Remaining work:
1. ~~Add a committed compile fixture that generates XRCE-profile Zig and checks it with the
   Zig 0.15.1 toolchain.~~ **Done** — `test/xrce-microzig/` exists with a committed
   `types.idl`, generated `types.zig`, and `test.zig`; not yet wired into `zig build
   integration-test`.
2. Split generated Zig runtime assumptions into a full runtime path and a constrained
   XRCE-client path.
3. Define the no-heap writer/reader surface expected by MicroZig clients; current generated
   bounded-field storage is heap-free, but CDR buffers still use the normal runtime model.
4. Audit generated code and `zidl-rt` APIs for freestanding compatibility.
5. Add XRCE-client-focused fixtures that exercise bounded-only IDL on embedded-friendly
   generated output.
6. Keep DDS-XRCE agent/broker work separate from zidl unless codegen needs explicit hooks.
   zidl should generate client-side type support; the agent can live in a DDS implementation
   or a separate repository that consumes zidl output.

---

## Known Gaps and Deferred Work

Existing-backend features that have `// TODO` or deferred markers in the code or
documentation, are not intentionally omitted, and are not yet tracked elsewhere in
this roadmap. New language backends have their own sections below.

### Semantic analysis / frontend

- **Const type-checking**: The semantic analyser does not validate that a `const`
  declaration's initializer is compatible with its declared type
  (e.g. `const long x = "hello"` is silently accepted). Should be caught and
  reported as a diagnostic.
- **Union discriminant type validation**: The IR builder does not check that the
  discriminant type of a `union` is a valid IDL discriminant type (integer, enum, char,
  boolean). Invalid discriminant types pass through silently.

### C backend

- **`@optional` members**: Deferred. Requires adding a companion `has_NAME` boolean
  field to every struct that has an optional member — a non-trivial ABI change.
  Until implemented, `@optional` members emit a `/* TODO: @optional name */` comment
  in serialize/deserialize functions, and the struct field itself is omitted.
- **`@optional` key fields**: Blocked on `@optional` support above. Key serialization
  emits a `/* TODO */` comment for any `@key` member that is also `@optional`.

### C and C++ backends

- **PL_CDR generation**: `--zig-pl-cdr` is parsed and wired through the CLI but neither
  the C nor C++ backend emits `serializePlCdr` / `deserializeFromPlCdr` functions.
  This is the RTPS ParameterList wire format used for DDS discovery types.
- **`--generate-interfaces` complex-type ABI**: `ImplGenerator.emitImplOp` in both
  backends emits `/* TODO */` stubs for operations with complex IDL types (structs,
  sequences, etc.) as parameters or return values. The ABI boundary with the DDS
  runtime has not been decided.

### All backends (annotation support)

- **`@verbatim` injection**: `@verbatim` annotations are parsed and preserved in the IR
  as `RawAnnotation` entries, but no backend currently reads or acts on them. The
  intended behaviour is to inject the annotation's `text` at the placement point
  (`BEGIN_FILE`, `BEFORE_DECLARATION`, etc.) when the `language` field matches the
  backend's language id or `"*"`. See `docs/backend_interface.md` for the planned
  pattern.

### Zig backend

- **Union discriminant edge cases**: `wstring` and `fixed_pt` discriminant types emit a
  `// TODO: unsupported discriminant` comment in `serialize` / `deserialize` bodies.
- **Sequence element read with array-typedef element**: A rare edge case where a sequence
  element type resolves to an array typedef emits a `// TODO` comment in the deserialize
  path.

### Java backend

- **`any` / `object` / `value_base` member access**: Emits a `// TODO: any/object`
  comment. These IDL constructs are rarely used in modern DDS profiles; implementation
  priority is low but they are not intentionally excluded.

### TypeObject encoder (Zig only)

- **`typedef` / alias TypeObjects**: The encoder emits a `TK_NONE` placeholder for all
  typedef and alias declarations.
- **`map<K,V>` and `fixed_pt` TypeObjects**: The encoder emits a `TK_NONE` placeholder
  for map key/value types and `fixed_pt` fields.
- **Generated `pub const type_object` for non-struct types**: The TypeObject encoder
  handles `enum`, `union`, `bitmask`, and `bitset`, but the Zig backend only emits
  a `pub const type_object` field inside `struct` declarations. The other four types
  need the same constant wired in.

### XRCE / MicroZig (step 1a)

- **Wire `test/xrce-microzig/` into `zig build integration-test`**: The fixture
  (`test/xrce-microzig/`) is committed and self-contained, but the main `build.zig`
  does not yet invoke it as part of `zig build integration-test`. Blocked on confirming
  the 0.15.1 toolchain path is available in CI.

---

## Python backend (`-b python`)

Target: Python 3.10+. No OMG spec; pragmatic conventions. Inline CDR (no companion
runtime package), following Java's model.

**Type mapping**:
- `struct` → `@dataclass(slots=True)` with typed fields
- `enum` → `enum.IntEnum`
- `union` → class with `_d: DiscType` property + `T | None` case properties; `match` dispatch in deserialize
- `sequence<T>` / `T[N]` → `list[T]` (array length checked at serialize time)
- `map<K,V>` → `dict[K, V]`
- `string` / `wstring` → `str`
- `@optional` → `T | None` (default `None`)
- Module → Python module namespace (flat file; `--split-files` emits per-type `.py` files)
- `@key` → `serialize_key()`, `deserialize_key()`, and `compute_key_hash()` methods
- No TypeObject generation (deferred — TypeObject is Zig-specific for now)

**CDR**: inline `struct.pack`/`struct.unpack` with an alignment-tracking writer/reader
class generated at the top of each output file. XCDR2 LE baseline; `@appendable` emits
DHEADER; `@mutable` emits EMHEADER per member.

**Implementation steps**:
1. `src/backend/python.zig` — declarations: struct/enum/union/typedef/const; `--no-typesupport` path
2. Python CDR: `@final` struct + union serialize/deserialize; inline writer/reader helper
3. Python CDR: `@appendable` (DHEADER), `@mutable` (EMHEADER), sequences, arrays, maps
4. Python CDR: `@key`, `deserialize_key`, `compute_key_hash`, `@optional`, wstring, fixed-pt
5. Python: `--split-files`, `--python-package <pkg>` option, tests, golden snapshot
6. Python integration test (roundtrip via subprocess or embedded interpreter)

---

## C# / .NET backend (`-b csharp`)

Target: `netstandard2.1` (covers Unity/Mono, .NET Core 3+, .NET 5–10+). C# 10+ syntax
(file-scoped namespaces). Spec: [IDL4 to C# v1.0 Beta (ptc/20-03-02)](https://www.omg.org/spec/IDL4-CSHARP/1.0/). Inline CDR
using `System.Buffers.BinaryPrimitives` + `Span<byte>`. No companion runtime package.

**Type mapping** (per formal/ptc-20-03-02):
- `struct` → `public sealed partial class` with auto-properties and a default constructor
- `enum` → C# `enum : int` (or underlying type per `@bit_bound`)
- `union` → `public sealed partial class` with discriminant property + typed case accessors
- `sequence<T>` → `List<T>`
- `T[N]` / `T[N1][N2]` → `T[]` / `T[][]`
- `map<K,V>` → `Dictionary<TKey, TValue>`
- `string` / `wstring` → `string`
- `@optional` → nullable value (`T?`)
- Module → `namespace` (nested modules → nested namespaces)
- `@key` → `SerializeKey`, `DeserializeKey`, and `ComputeKeyHash` methods
- No TypeObject generation (deferred)

**CDR**: inline `BinaryPrimitives`-based `CdrWriter`/`CdrReader` helper struct generated
at the top of each output file. `Span<byte>` for zero-copy primitives. XCDR2 LE baseline;
`@appendable` / `@mutable` follow same DHEADER/EMHEADER rules as Java.

**Implementation steps**:
1. `src/backend/dotnet.zig` — declarations: struct/enum/union/typedef/const; `--no-typesupport` path
2. C# CDR: `@final` struct + union serialize/deserialize; inline CdrWriter/CdrReader helpers
3. C# CDR: `@appendable` (DHEADER), `@mutable` (EMHEADER), sequences, arrays, maps
4. C# CDR: `@key`, `DeserializeKey`, `ComputeKeyHash`, `@optional`, wstring, fixed-pt
5. C# CDR: `--split-files`, `--dotnet-namespace <ns>` option, tests, golden snapshot
6. C# integration test (compile + roundtrip via `dotnet run`)

---

## Rust backend (`-b rust`)

Two generation modes selected via `--rust-runtime`:

- **`pure` (default)**: idiomatic Rust; `Vec<T>`, `String`, `HashMap`; CDR via `zidl-rs`
  companion crate (`no_std + alloc`). Target audience: desktop/server Rust projects that want
  a pure-Rust dep graph with no Zig runtime dependency.
- **`zig-ffi`**: zero-copy FFI into the Zig DDS runtime; sequences/strings as `ZidlSlice<T>`/
  `ZidlString` (`#[repr(C)]`, `no_std + alloc`); lifetime-annotated borrows for zero-copy
  deserialization; `--rust-types-crate <crate>` redirects the import source (default:
  `zidl_types`). A DDS implementation that wants to bundle the types re-exports from
  `zidl-types-rs` rather than reimplementing, preserving Rust type identity across the dep
  graph. Target audience: embedded and high-performance DDS consumers.

No OMG spec for Rust. No TypeObject generation (deferred — TypeObject is Zig-specific for now).

**Type mapping**:
- `struct` → Rust `struct` with named fields
- `enum` → Rust `enum` with unit variants; discriminant value via `#[repr(i32)]` etc.
- `union` → Rust `enum` with associated data (exhaustiveness checking); discriminant serialized separately
- `sequence<T>` → `Vec<T>` (pure) / `ZidlSlice<T>` (zig-ffi)
- `T[N]` → `[T; N]` — native fixed-size arrays, stack-allocated, no package needed
- `map<K,V>` → `HashMap<K, V>`
- `string` / `wstring` → `String` (pure) / `ZidlString` (zig-ffi)
- `@optional` → `Option<T>`
- `typedef` → `type` alias or newtype `struct Foo(Inner)`
- Module → `mod`
- `@key` → `serialize_key()`, `deserialize_key()`, and `compute_key_hash()` methods
- Structs annotated `#[repr(C)]` in zig-ffi mode where layout permits

**Implementation steps**:
1. `packages/zidl-types-rs/` — `ZidlSlice<T>`, `ZidlString` as `#[repr(C)]`; `no_std + alloc`
2. `src/backend/rust.zig` — declarations: struct/enum/union/typedef/const; `--no-typesupport` path; both runtime modes; `--rust-types-crate` flag wiring
3. `packages/zidl-rs/` — pure Rust CDR runtime: `CdrWriter`/`CdrReader`, XCDR1/XCDR2, alignment tracking, DHEADER/EMHEADER patching, `no_std + alloc`
4. Rust CDR (pure): `@final` struct + union serialize/deserialize
5. Rust CDR (pure): `@appendable` (DHEADER), `@mutable` (EMHEADER), sequences, arrays, maps
6. Rust CDR (pure): `@key`, `deserialize_key`, `compute_key_hash`, `@optional`, wstring, fixed-pt
7. Rust CDR (zig-ffi): zero-copy path — `ZidlSlice<T>`/`ZidlString` types, FFI serialization bindings, lifetime-annotated borrows for deserialized data
8. Rust: `--split-files`, `--rust-types-crate` wiring, tests, golden snapshot
9. Rust integration test (compile + roundtrip via `cargo test`)

---

## Haskell backend (`-b haskell`) — future consideration, not scheduled

Haskell ADTs are arguably the best semantic fit for IDL types of any language. Captured here
for future reference; no steps assigned.

**Type mapping** (strong fit):
- `struct` → record syntax `data MyStruct = MyStruct { field :: Int32, ... }`
- `union` → sum type with associated data; exhaustiveness checking at compile time
- `enum` → nullary constructors (labels converted `ALL_CAPS` → `UpperCamelCase`)
- `@optional` → `Maybe T` — perfect semantic fit
- `sequence<T>` → `[T]` or `Data.Vector.Vector T`
- `map<K,V>` → `Data.Map.Map K V`
- `string` / `wstring` → `Data.Text.Text` (Unicode-native)
- `typedef` → `type` alias (transparent) or `newtype` (type-safe)
- Module → Haskell module system

**Pain points**:
- CDR alignment tracking requires a custom writer monad (`newtype CdrPut a = CdrPut (StateT
  Int PutM a)`) — `binary`/`cereal` do not expose current byte position.
- DHEADER/EMHEADER size patching for `@appendable`/`@mutable` is awkward in pure functional
  style; requires two-pass, `MonadFix`, or a `ByteString` builder with known sizes.
- `T[N]` fixed-size arrays have no native representation; need `vector-sized`/DataKinds or
  runtime length checks with a plain list.
- `fixed<D,S>` has no standard Haskell type (`Data.Fixed` exists but uses type-level resolution).
- Two CDR strategy options: fully inline (large generated files, no external dep) vs. typeclass
  instances with a `zidl-hs` companion package on Hackage. The typeclass approach is more
  idiomatic but adds a distribution dependency.
