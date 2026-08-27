# zidl — Roadmap

Forward-looking only: known gaps, planned features, and open design questions.

- Shipped work → [`../CHANGELOG.md`](../CHANGELOG.md)
- What exists today + its limitations → [`implementation_status.md`](implementation_status.md) and [`features.md`](features.md)
- Fleshed-out designs → [`design/`](design/)
- Rationale for past decisions → [`decisions.md`](decisions.md)

> **Restructured 2026-08-27.** This file used to also hold shipped-work write-ups. Older
> references to roadmap sections that no longer exist here resolve as:
> *"Binding design review: interfaces vs. impls…"* / *"Binding design review: decision"* →
> [`design/binding-c-abi-identity.md`](design/binding-c-abi-identity.md);
> *"Mitigation work"* → [`design/cabi-type-coverage.md`](design/cabi-type-coverage.md);
> *"Recently Completed"* / *"Entity handle ABI (Implemented)"* /
> *"ContentFilteredTopic filtering (Done)"* → [`../CHANGELOG.md`](../CHANGELOG.md).

---

## Known Gaps & Deferred Work

Existing-backend gaps with a `// TODO` or deferred marker in code or docs, not intentionally
omitted. Language backends that don't exist yet have their own section under *Planned
Features*.

### All backends

- **Union discriminant of a complex type** (`wstring` / `fixed_pt` / named-non-enum /
  typedef-of-complex) emits `/* TODO: unsupported discriminant */` in every backend.
  `c.zig:3316`, `cpp.zig:2947`, `zig.zig:969`; Boolean union switch also unhandled in Java
  (`java.zig:1052`). `features.md` Known Limitations.
- **`--generate-interfaces` without `--generate-c-api` / an impl override** — richer-than-
  scalar/string/entity operation signatures are emitted as `/* TODO: adapt … */` stubs
  (C++ `ImplGenerator`, `cpp.zig`) or opaque-handle typedefs + free-function decls only
  (C). Dead code for zzdds (which always uses `--cpp-generate-impl` / `--cpp-impl-override`);
  a live limitation for any other `--generate-interfaces` consumer. `features.md`,
  `implementation_status.md`.
- **`@verbatim` and other IDL4 annotations are parsed into the IR but no backend acts on
  them.** `@verbatim` should inject its text at `BEGIN_FILE` / `BEFORE_`/`BEGIN_`/`END_`/
  `AFTER_DECLARATION` / `END_FILE` when `language` matches. Also inert:
  `@range` / `@min` / `@max` / `@unit` / `@external` / `@position` / `@value` / `@default` /
  `@default_literal` / `@autoid` / `@service` / `@oneway` / `@ami`; `@hashid` and
  `@autoid(HASH)` are not auto-applied to member IDs. `idl4_annotations.md`.
- **Deprecated listener heuristic warning** — an interface whose name ends in `Listener`
  is auto-treated as `@callback`; the planned deprecation warning for relying on that
  (instead of an explicit `@callback`) is not yet emitted. `annotations.md`.
- **`fixed<D,S>` is mapped to `f64`** (approximate/lossy) in the Zig, Java, and C++
  backends. `zig.zig:32`.
- **`any` / `object` / `value_base`** CDR read/write is unsupported — C and Zig emit a
  `// unsupported` marker; Java emits `// TODO: any/object` and its skip path throws
  `IllegalArgumentException`. `c.zig:4428`, `zig.zig:6539`, `java.zig:2363`.
- **IDL4 declaration kinds dropped by the IR builder** — `value_dcl`/`valuetype`,
  `component_dcl`, `home_dcl`, `event_dcl`, `porttype_dcl`, `connector_dcl`, template
  modules, `annotation_dcl`, `type_id_dcl`, `type_prefix_dcl` are parsed then discarded with
  a per-construct stderr warning; no output. `ir/builder.zig:428`, `ir/types.zig:424`.
- **Import limitations** — transitive imports are unsupported pipeline-wide (`processFile`
  only scans the primary file's own top-level `import_dcl`s; `fillFromImportedAst` only
  fills directly imported units). Scoped-name imports (`import ::Foo;`) are rejected with a
  "use `import "file.idl";`" diagnostic. Cross-module *entity*-interface flattening relies
  on there never being real cross-module content (see `decisions.md`). `ir/builder.zig:119`,
  `semantic/analyzer.zig:1034`.
- **Semantic validation gaps** — no type-checking of const assignments
  (`const long x = "hello"` is not caught); union-discriminant *type* validation accepts
  typedef-of-typedef conservatively (full typedef-chain walk deferred).
  `semantic/analyzer.zig:1154`.

### C backend

- **`map<K,V>`** — hard `error.MapTypeNotSupportedInCBackend` at codegen; the CDR generator
  additionally has `/* TODO: map write/read */` stub arms. (C++/Java/Zig CDR paths do
  marshal maps.) `c.zig:116`. In interface/callback parameter position it must become a
  named hard error — see the C-ABI type-coverage design doc.
- **`@optional` `_set_` macro** is not emitted for array-backed members (fixed arrays,
  bounded strings/wstrings) — callers do direct assignment + manual `_present` bit update.
  No memcpy-based shape-aware setter. `backend_c.md`.
- **`ZidlAllocator` scope** — the user-supplied CDR allocator (`zidl_cdr_set_allocator`) is
  process-wide by an explicit design decision (`decisions.md`): two topic types / two
  participants cannot use two different CDR-layer allocators. Whether a DDS implementation
  needs this un-closed is a zzdds-side design task (allocator scoping, `zzdds/docs/roadmap.md`).
- **`zidl_allocator_pmr.hpp`** — a no-throw, placement-new-based allocator bridge (bypassing
  `std::pmr`) is a deliberately deferred option; not built.

### C++ backend

- **`--generate-c-api` complex-type adapter (`ConcreteImplGenerator`)** — the largest single
  gap. Non-adaptable parameter/return types (bare/nested sequences, complex QoS structs,
  array-typedef fields, unnamed sequence params, `wstring`, `map`, callback interfaces)
  emit `/* TODO: adapt … */` / `/* TODO: return type not adaptable */` stubs (formalised as
  `AdaptKind.todo`). `cpp.zig:4455`+.
- **Custom STL allocators** — `std::string` / `std::vector` / `std::map` use default
  allocators unless `--cpp-pmr-containers` is passed; allocator-template-parameter support
  is not implemented. `backend_cpp.md`.
- **`_getOrCreate` weak_ptr cache has no active sweep** — expired entries are only
  overwritten lazily, so a long-running process creating/destroying many distinct entities
  with non-reused handle addresses accumulates dead (pointer-sized) map slots. Revisit if
  it matters in practice.
- **`nativeHandleBase` / cross-file entity-base handling** trusts "different root module" as
  a proxy for "the base owns its own handle" — no cross-file registry. A wrong assumption
  for some future IDL would surface as a loud C++ compile error, not silent breakage.
  `cpp.zig:5952`.

### Java backend

- **`bitset` CDR** — no standard Java CDR mapping; emits `// TODO: bitset`. (The bitset
  *type* is generated as a real class.)
- **Non-primitive sequence-element CDR deserialization** — falls through to
  `// TODO: seq elem deserialize`; a `.seq_struct` param whose element is an enum stays in
  the `UnsupportedOperationException` stub bucket. `java.zig:2647`.
- **`--generate-interfaces` residual stub-bucket cases** — an op generates an
  `UnsupportedOperationException` throw (not a native call) for: a `value_struct` returned
  *by value*, a `.callback` return other than `get_listener()`, an anonymous inline
  `sequence<T>` param (no typedef), or a `sequence<enum>` param. None occur in
  dcps.idl/zzdds.idl today. QoS/status struct *params* and listener JNI upcalls are
  implemented. `java.zig:4213`.
- **Cross-file most-derived-box dispatcher** (`mostDerivedBoxFnName` / `familyOf`)
  deliberately does not cross a file boundary — falls back to safe per-view behaviour;
  caught only by rebuilding zzdds's Java binding. `java.zig:3940`.

### Zig backend

- **Sequence element that resolves to an array typedef** emits a `// TODO` in the
  deserialize path. `zig.zig:5877`.
- **`wstring` constants** emit only a comment — `[]const u16` literals are unsupported.
- **`--zig-generate-toml-config`** (`applyToml`) — fixed-size arrays (incl. array typedefs),
  unions, bitmasks, bounded strings, and sequences of non-string turn the whole generated
  body into one `@compileError`. Full functional verification was done out-of-tree, not
  committed as an in-repo test. `zig.zig:5162`, `interface.zig:182`.
- **C-ABI mirror struct** — an `@optional` non-scalar field emits
  `@compileError("C-ABI mirror: @optional non-scalar field … not supported")`.
  `zig.zig:1978`.
- **Entity-sequence out-param `{Type}_free()`** has no entity parameter, so its allocation
  must match the process-wide `zidl_cdr_set_allocator` choice — only correct while an
  entity's own `_with_allocator` allocator equals the process-wide one; not structurally
  enforced. A full fix needs a C-ABI shape change. `zig.zig:2747`.
- **Idiomatic slice-friendly wrapper layer** over the generated C-ABI vtable — a planned
  ergonomic addition, not yet generated. `ecosystem.md`.
- **`as_{Base}` convenience method for pure-Zig callers** — decided (emit a top-level
  wrapper, not just the vtable slot) so Zig-native code gets the same upcast ergonomics as
  C/C++/Java, which already have it. Not implemented.

### C-ABI entity identity (`design/binding-c-abi-identity.md`)

Phase 1 (the Condition family) shipped in `v0.3.5`. Open:

- **Extend `@shared_c_abi_box` to the remaining families** — `Entity`, `TopicDescription`,
  `DomainParticipantFactory`.
- **Embedded-substruct impls** — `QueryConditionImpl` embeds a `ReadConditionImpl` by
  value; a shared box must pick one canonical `ptr` and have the leaf dispatch do its own
  offset math. Needs its own pass when that family is converted.
- **`DDS_ReadCondition_as_DDS_QueryCondition`** still returns null — a distinguishing signal
  now exists, but the downcast is deliberately left unimplemented.
- **Secondary bases** (`Topic`'s `TopicDescription` view) permanently keep an
  independently-cached box — see `decisions.md`. Not a bug, recorded so it isn't
  rediscovered.
- **Listener trampolines** may carry a latent version of the same cross-view identity gap
  (listener-delivered entity args go through `_getOrCreate`-style wrapping) — not confirmed,
  not investigated.

### Factory-less entity bootstrap

- **`@factory_less_bootstrap(ctor=…)` annotation — decided, not implemented.** `WaitSet` /
  `GuardCondition` have no factory operation in `dcps.idl` (per OMG spec, app-instantiated
  directly), so each currently needs a hand-written C-ABI constructor, C++ friend-factory
  wrapper, and Java JNI method — authored three times by mirroring
  `DomainParticipantFactory`'s bootstrap. The decision: mark such interfaces with an
  annotation and generate the C header decl, `--generate-c-api` export wrapper, C++
  friend-factory, and Java JNI method + registration.
- **`DomainParticipantFactory` is deliberately excluded** from that mechanism (its
  DDS-base / vendor-extension duality + `FactoryOwner` complexity). Stays hand-written
  ×3 until someone extends the mechanism for the vendor-extension case.

### Listener / condition keep-alive across GC'd bindings

- **One shared per-language runtime helper** (per-registration keyed, mirroring Java's
  `zidl_java_release_listener_data`) for each future binding that needs it — template only,
  blocked on the Python / C# / Rust / Haskell backends existing. See `decisions.md` for why
  keying must be per-registration.
- **No C-ABI equivalent of `release_listener_data` for `WaitSet`-attached conditions.** The
  memory-safety half is handled internally (a destroyed condition drops cleanly from every
  attached `WaitSet`), but there is no C-ABI-visible signal, so a GC'd binding's
  `GuardCondition` wrapper must do its own acquire-on-attach / release-on-detach
  bookkeeping unaided. A condition-side equivalent hook is possible future work.

### PL_CDR in non-Zig backends — not planned

`--zig-pl-cdr` is Zig-backend-only; every other backend parses and silently ignores it, and
that is correct — see `decisions.md`. Re-raise only if a non-zzdds consumer needs a non-Zig
program to implement RTPS wire discovery directly.

---

## Planned Features

### C-ABI interface / callback type coverage

Missing positive tests (fixed-size array typedef param; nested named struct param) and
negative tests (each non-C-ABI-representable type must produce a named generator error, not
a `// TODO`). The ranked mitigation designs (synthesize typedefs for anonymous sequences;
OMG C PSM companion struct for unions; fixed-width `uint16_t *` for `wstring`;
`zidl_fixed_t` for `fixed<D,S>`; opaque `ZidlMap` handle for `map`) live in
[`design/cabi-type-coverage.md`](design/cabi-type-coverage.md).

### TypeObject encoder (Zig backend only)

Currently emits a `TK_NONE` placeholder for `typedef`/alias, `map<K,V>` key/value,
`fixed_pt`, non-struct decls (native / exception / interface), `any`/`object`/`value_base`
base types, and non-scalar `bitmask` holders. `pub const type_object` is emitted only inside
`struct` decls (enum/union/bitmask/bitset are encodable but the backend doesn't wire the
constant in); collections get an inline TypeIdentifier only, no standalone TypeObject.
`src/backend/zig_typeobject_proto.zig` is a spike (one hardcoded `@final struct Point`) — the
real `zidl-xtypes` generated-code architecture is not committed. No TypeObject generation in
the non-Zig backends ("Zig-specific for now").

### Embedded / MicroZig / XRCE

`--profile xrce` exists and validates XRCE constraints (only `@final`, bounded strings/
sequences, no maps/optional/wstring, no TypeObject output). The Zig backend accepts
`--zig-version 0.15.1` and emits bounded code on fixed-capacity `zidl_rt.BoundedArray`. This
is the first MicroZig-enabling slice, not a complete freestanding output mode. Remaining:

1. Wire the committed `test/xrce-microzig/` compile fixture into `zig build integration-test`
   (blocked on confirming the Zig 0.15.1 toolchain path is available in CI).
2. Split generated Zig runtime assumptions into a full-runtime path and a constrained
   XRCE-client path.
3. Define the no-heap writer/reader surface for MicroZig clients — bounded-field storage is
   heap-free, but CDR buffers still use the normal runtime model.
4. Audit generated code + `zidl-rt` APIs for freestanding compatibility.
5. Add XRCE-client fixtures exercising bounded-only IDL on embedded-friendly output.
6. Keep DDS-XRCE agent/broker work out of zidl unless codegen needs explicit hooks — zidl
   generates client-side type support only.

### Python backend (`-b python`)

Target: Python 3.10+. No OMG spec; pragmatic conventions. Inline CDR (no companion runtime
package), following Java's model.

**Type mapping**: `struct` → `@dataclass(slots=True)`; `enum` → `enum.IntEnum`; `union` →
class with `_d` property + `T | None` case properties (`match` dispatch); `sequence<T>` /
`T[N]` → `list[T]`; `map<K,V>` → `dict[K, V]`; `string`/`wstring` → `str`; `@optional` →
`T | None`; module → Python module (flat file; `--split-files` → per-type `.py`); `@key` →
`serialize_key()` / `deserialize_key()` / `compute_key_hash()`; no TypeObject.

**CDR**: inline `struct.pack`/`unpack` with an alignment-tracking writer/reader class per
file. XCDR2 LE baseline; `@appendable` → DHEADER; `@mutable` → EMHEADER per member.

**Steps**: (1) `src/backend/python.zig` declarations + `--no-typesupport`; (2) `@final`
struct + union CDR + inline writer/reader; (3) `@appendable`/`@mutable`/sequences/arrays/
maps; (4) `@key` / `deserialize_key` / `compute_key_hash` / `@optional` / wstring / fixed-pt;
(5) `--split-files` + `--python-package <pkg>` + tests + golden; (6) roundtrip integration
test.

### C# / .NET backend (`-b csharp`)

Target: `netstandard2.1` (Unity/Mono, .NET Core 3+, .NET 5–10+), C# 10+ syntax. Spec:
[IDL4 to C# v1.0 Beta (ptc/20-03-02)](https://www.omg.org/spec/IDL4-CSHARP/1.0/). Inline
CDR via `System.Buffers.BinaryPrimitives` + `Span<byte>`.

**Type mapping** (per ptc/20-03-02): `struct` → `public sealed partial class` with
auto-properties; `enum` → `enum : int`; `union` → `sealed partial class` with discriminant +
typed case accessors; `sequence<T>` → `List<T>`; `T[N]`/`T[N1][N2]` → `T[]`/`T[][]`;
`map<K,V>` → `Dictionary<TKey,TValue>`; `string`/`wstring` → `string`; `@optional` → `T?`;
module → `namespace`; `@key` → `SerializeKey`/`DeserializeKey`/`ComputeKeyHash`; no
TypeObject.

**CDR**: inline `BinaryPrimitives`-based `CdrWriter`/`CdrReader` per file; `Span<byte>` for
primitives. XCDR2 LE baseline; DHEADER/EMHEADER rules as Java.

**Steps**: mirror Python's six — (1) `src/backend/dotnet.zig` declarations; (2) `@final`
CDR + inline `CdrWriter`/`CdrReader`; (3) appendable/mutable/sequences/arrays/maps;
(4) `@key`/`DeserializeKey`/`ComputeKeyHash`/`@optional`/wstring/fixed-pt; (5) `--split-files`
+ `--dotnet-namespace <ns>` + tests + golden; (6) compile + roundtrip via `dotnet run`.

### Rust backend (`-b rust`)

Two modes via `--rust-runtime`:

- **`pure` (default)** — idiomatic Rust (`Vec<T>`, `String`, `HashMap`); CDR via a `zidl-rs`
  companion crate (`no_std + alloc`). For desktop/server projects wanting a pure-Rust dep
  graph.
- **`zig-ffi`** — zero-copy FFI into a Zig DDS runtime; sequences/strings as
  `ZidlSlice<T>`/`ZidlString` (`#[repr(C)]`); lifetime-annotated borrows;
  `--rust-types-crate <crate>` redirects the import source (default `zidl_types`). For
  embedded / high-performance consumers.

No OMG spec. No TypeObject.

**Type mapping**: `struct` → named-field struct; `enum` → unit-variant enum
(`#[repr(i32)]`); `union` → enum with associated data (discriminant serialized separately);
`sequence<T>` → `Vec<T>` / `ZidlSlice<T>`; `T[N]` → `[T; N]`; `map<K,V>` → `HashMap<K,V>`;
`string`/`wstring` → `String` / `ZidlString`; `@optional` → `Option<T>`; `typedef` → `type`
alias or newtype; module → `mod`; `@key` → `serialize_key()`/`deserialize_key()`/
`compute_key_hash()`; `#[repr(C)]` in zig-ffi mode where layout permits.

**Steps**: (1) `packages/zidl-types-rs/` (`ZidlSlice<T>`, `ZidlString`, `#[repr(C)]`,
`no_std + alloc`); (2) `src/backend/rust.zig` declarations + both runtime modes +
`--rust-types-crate`; (3) `packages/zidl-rs/` pure CDR runtime (XCDR1/2, alignment,
DHEADER/EMHEADER, `no_std + alloc`); (4) pure-mode `@final` CDR; (5) pure-mode appendable/
mutable/sequences/arrays/maps; (6) pure-mode `@key`/`deserialize_key`/`compute_key_hash`/
`@optional`/wstring/fixed-pt; (7) zig-ffi zero-copy path (`ZidlSlice`/`ZidlString`, FFI
serialization, lifetime-annotated borrows); (8) `--split-files` + `--rust-types-crate`
wiring + tests + golden; (9) compile + roundtrip via `cargo test`.

### Haskell backend (`-b haskell`) — future consideration, not scheduled

Haskell ADTs are arguably the best semantic fit for IDL types (records, sum types,
`Maybe T` for `@optional`, `Data.Text` for strings). No steps assigned. Pain points: CDR
alignment tracking needs a custom writer monad (`binary`/`cereal` don't expose byte
position); DHEADER/EMHEADER size patching is awkward in pure functional style (two-pass /
`MonadFix` / builder); `T[N]` has no native representation; `fixed<D,S>` has no standard
Haskell type; open choice between fully-inline CDR (large files, no dep) and typeclass
instances with a `zidl-hs` Hackage package.

---

## Design Tasks — not yet scoped

### Plugin architecture — feasibility + design

zidl has a growing set of flags that exist only for "what zzdds needs from its impl
generation" (`--cpp-generate-impl`'s override mechanism, `--generate-zzdds-wrappers`). Each
bakes a specific DDS implementation's opinions into zidl core, whose stated audience is "any
DDS implementation, or none." The direction: pull the implementation-specific policy layer
(which concrete class backs an abstract interface, wrapper/listener-bridging conventions)
out of zidl core into implementation-owned plugins (one per binding, in the consumer's
repo).

**Feasibility is the first question.** Zig's build/link model is compile-time and
whole-program — there is no runtime plugin loading. Any mechanism here is more likely
build-time composition (zidl core as a Zig package a downstream build step extends, or a
codegen-callback interface a downstream `build.zig` wires in), and it is unclear how cleanly
that expresses "supply the policy layer" without a plugin effectively vendoring large parts
of a backend. Until this exists, implementation-specific needs land as blind, mechanism-only
flags (see `decisions.md`).

---

## Deferred / Out of Scope

- **DDS-RPC request/reply codegen** — a separate future `--rpc` path; architecture must not
  preclude it.
- **Non-CDR wire encodings** (XCDR↔JSON, XCDR↔XML, MQTT bridge) and DynamicType /
  DynamicData / TypeObjectFactory — belong in a DDS runtime, not zidl.
