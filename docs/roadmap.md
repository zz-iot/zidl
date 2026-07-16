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

### C and C++ backends

- **`ZidlCdrAllocator` (user-supplied allocator for strings/sequences)**: `zidl_cdr_read_string`
  and sequence reads use `malloc` internally today; see `docs/backend_c.md` §"`zidl-cdr`
  Dependency". This is "Tier 2" of the allocator-control work described under "Entity
  handle ABI: heap-boxing + allocator control" above — a separate, data-plane
  configuration surface from entity-handle boxing (Tier 1), but following the same
  discipline: route through a swappable interface, never hardcode `malloc` in
  generated per-type code.
- **PL_CDR generation**: `--zig-pl-cdr` is parsed and wired through the CLI but neither
  the C nor C++ backend emits `serializePlCdr` / `deserializeFromPlCdr` functions.
  This is the RTPS ParameterList wire format used for DDS discovery types.
- ~~**C backend `--generate-interfaces` (opaque handles + free functions)**~~:
  **Implemented.** Entity interfaces emit opaque `typedef struct Foo_s *Foo;` handles
  and free function declarations matching the OMG C PSM binding and the idioms of
  major C DDS implementations (Cyclone DDS, RTI Connext C API). No struct layout is
  exposed in the public header. Listener interfaces remain plain C callback structs
  with a `void *listener_data` context pointer. The C++ backend's `ConcreteImplGenerator`
  was updated to match (null checks and null-handle literals now use the opaque
  pointer directly instead of a two-field struct literal).
- ~~**Zig backend `--zig-generate-c-api`**~~: **Implemented**, via uniform entity
  handle boxing (see "Entity handle ABI: heap-boxing" below for the design and
  the discarded intermediate designs that led to it). Every non-listener entity
  interface — regardless of how many real implementations it has — crosses the
  C-ABI boundary as a single opaque pointer to a `zidl_rt.EntityBox`, matching
  the C backend's handle one-for-one. See `docs/ecosystem.md` §"`--zig-generate-c-api`"
  for the generated-code shape.

## Entity handle ABI: heap-boxing (Implemented, zidl side)

Every non-listener entity interface gets a single opaque C-ABI pointer, always,
matching the OMG PSM idiom with no exceptions — no leaf/base distinction
anywhere in generated code. The pointer targets a small heap-allocated box
(`zidl_rt.EntityBox`) holding the native Zig `{ptr, vtable}` pair; boxing/
unboxing happens only at the `--zig-generate-c-api` export boundary, never in
Zig-native code, so pure-Zig consumers of zidl-generated interfaces pay nothing
extra and keep the fat-pointer type as-is (see the "idiomatic Zig" discussion
in the PR history that led here).

This design went through two discarded intermediate steps worth recording so
they aren't re-attempted:
1. A **hybrid leaf/base split** (devirtualize "leaf" interfaces to a bare
   pointer dispatched through an externally-supplied vtable symbol, keep
   "base" interfaces — `Entity`, `TopicDescription` — as the old fat-pointer
   struct) was implemented, then discarded. It required a new `--c-api-impl`
   mapping (a permanent per-interface maintenance burden), left base
   interfaces non-opaque in the C header, baked "this interface has exactly
   one implementation, forever" into the wire format, and — critically — had
   a real correctness bug: devirtualized dispatch assumed a statically-known
   vtable, discarding whatever vtable a native call actually returned, so a
   failed `create_*` call's nil-object result would misdispatch on any
   subsequent call.
2. A **naive "always box fresh" design** (every export call allocates a new
   box, unconditionally) was also discarded: it breaks handle identity for
   accessor operations (`get_participant()` called twice would return two
   different, non-`==`-comparable boxes) and leaks unconditionally for
   widened-view accessors (`get_entity()`, `lookup_topicdescription()`), since
   the live C++ `ConcreteImplGenerator`'s Impl-class destructor is `= default`
   and nothing else in the generated code frees a box.

The design that replaced both: every entity interface's vtable gains one
synthetic slot, `get_c_abi_handle: *const fn(*anyopaque) *anyopaque`, alongside
the existing `deinit`. Generated code is completely uniform —
`return _r.vtable.get_c_abi_handle(_r.ptr);` for every entity return, no
allocation and no allocator lookup in generated code at all. How the handle is
produced is entirely the concrete implementation's choice, not zidl's:

- **Recommended pattern (zzdds side, not yet done — see below)**: cache and
  reuse a handle across repeated calls to the same object (lazily created on
  first request, stored on the concrete impl, freed in that object's own
  `deinit()`). This fixes both discarded designs' problems at once — identity
  is preserved, and nothing leaks — with no new C-ABI release step (preserving
  familiarity with Cyclone/Connext-style APIs) and no new IDL annotation.
- Allocation, when needed, uses whatever allocator the concrete impl already
  has (e.g. `self.alloc`) — ordinary access, not a new generic vtable-mediated
  mechanism. This is "Tier 1" of the allocator-control work; see the zzdds
  roadmap's Tier 1 entry for what's left to do there, and Tier 2/3 for the
  separate data-plane and per-entity-kind allocator work.

**zzdds-side follow-up**: every hand-written concrete impl needs a
`get_c_abi_handle` implementation following the cache-and-reuse pattern above
(including for widened views it returns, e.g. `StatusConditionImpl` caching
its own `entity_view_handle` for `get_entity()`). Done, against a local-path
zidl checkout (not yet a tagged release) — see the zzdds roadmap.

### C++ backend: entity wrapper identity (Planned)

A related but independent gap, found while auditing whether this design should
change anything for the C++ backend (it doesn't need to — C++'s own
`class Foo` / `class FooImpl : public Foo` abstract-class hierarchy already
gets real polymorphism natively from the compiler-embedded vtable, which is
exactly what the Zig side had to hand-roll as a fat pointer; there's no
analogous "narrow a fat reference into an opaque C handle" problem on the C++
side for boxing to solve). But looking at `ConcreteImplGenerator`
(`src/backend/cpp.zig`) surfaced a structurally similar, pre-existing gap: it
constructs a fresh `std::make_shared<FooImpl>(_h)` on every operation that
returns an entity, so calling e.g. `participant->get_topic("X")` twice today
returns two different `FooImpl` objects wrapping the same underlying `_h` —
not identity-equal, though not a leak either (`shared_ptr` RAII cleans up
correctly regardless of how many wrapper instances exist).

This wasn't practically fixable before the heap-boxing work above: nothing
guaranteed the raw C handle `_h` was itself stable/reusable across calls, so
there'd have been no correct value to key a wrapper cache against. Now that
`get_c_abi_handle` makes the underlying handle identity-stable, the C++ side
could reuse the same principle (cache-and-reuse against a stable key, instead
of allocating a fresh wrapper per access) via its own idiom — e.g. a
`static std::unordered_map<DDS_Foo, std::weak_ptr<FooImpl>>` (plus a mutex) per
entity type in generated code: reuse the existing wrapper if the `weak_ptr` is
still alive, construct-and-insert otherwise.

Unlike the Zig-side `get_c_abi_handle` item, this doesn't need any hand-written
zzdds participation — zzdds doesn't author its own C++ bindings; they're
entirely generated via `--cpp-generate-impl`. The cache has nowhere to live
before the *first* `FooImpl` for a given handle exists (unlike the Zig side,
where a cache field can attach to the already-existing concrete impl object),
so it has to be a self-contained registry, fully expressible inside
`ConcreteImplGenerator`'s own generated code — this is purely a zidl backend
change, not a zzdds implementation task.

### Zig backend: `as_{Base}` upcast vtable slot (Implemented)

zzdds hand-wrote ~12 free functions upcasting an entity handle to an
IDL-declared base interface across the C-ABI (`DDS_Topic_as_DDS_Entity`,
`DDS_GuardCondition_as_DDS_Condition`, ...), each with its own
vtable-identity check. Every one of these relationships is already declared
as IDL interface inheritance, so this is now generated: `emitInterface`
(`src/backend/zig.zig`) adds one synthetic `as_{Base}: *const fn(*anyopaque)
{Base}` slot per direct declared base, alongside `deinit`/`get_c_abi_handle`
(unconditional, same precedent); under `--zig-generate-c-api`,
`emitCApiExports` additionally emits a `{Iface}_as_{Base}` export wrapper per
base, unboxing self, calling the native slot, boxing the result via the
target's own `get_c_abi_handle`.

Two designs that don't work, ruled out during investigation:
- **Raw pointer reinterpretation** (`@ptrCast` the derived vtable as the
  base's `Vtable` type) only works for whichever base is declared *first* —
  `collectInterfaceMembers` flattens inherited ops bases-first, so a second
  (or later) base's fields start at a non-zero offset; reinterpreting would
  silently misread the wrong fields. Confirmed via a dedicated golden/unit
  test fixture with a non-first base.
- **A permanent external mapping** (as `--c-api-impl` would have been) bakes
  in "there is exactly one implementation," the same problem that dropped
  that design originally.

The vtable slot is the mechanism that generalizes correctly: the concrete
implementation supplies `as_{Base}`, and dispatch through the vtable is
correct by construction — no runtime "is this really the vtable I expect"
check is needed or possible to bypass, unlike the hand-written functions it
replaces.

**zzdds migration note**: `zzdds.idl`'s own vendor-extension interfaces
declare real IDL bases too (`interface Topic : DDS::Topic`), which was easy
to miss — the upcast direction of the `ZZDDS.* ↔ DDS.*` conversions
(`zzdds_Topic_as_DDS_Topic` etc.) is *also* now generated, not just the
DDS-internal ones. Only the downcast direction (`DDS_Topic_as_zzdds_Topic`,
requiring a runtime vtable-identity check IDL can't express) remains
hand-written.

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

## Recently Completed

| Item | Notes |
|---|---|
| C backend `--generate-interfaces`: opaque handles | Entity interfaces emit `typedef struct Foo_s *Foo;` instead of a fat-pointer vtable struct; C++ `ConcreteImplGenerator` null-checks/null-handle literals updated to match. |
| Const type-checking (semantic analyser) | `const_type_mismatch` diagnostic; validates initializer compatible with declared type (§7.4.3). PR #20. |
| Union discriminant type validation | `invalid_discriminant_type` diagnostic; validates integer/char/boolean/wchar/octet/enum base (§7.4.8), including typedef-of-typedef. PR #20. |
| C++ concrete impl backend: 11 TODO stub methods | `get_listener` ×6 (stash pattern), `get_offered/requested_incompatible_qos_status` ×2, `WaitSet::wait`/`get_conditions` ×2, `SubscriberImpl::get_datareaders` — unlocked by extending `isAdaptableSeqElemIn` for simple-struct and entity-interface sequence elements, plus a `listener_` stash member. |
| `--zig-generate-c-api` trivial forwarders (Zig backend) | Vtable slots are C-ABI; exports are one-liners. No type conversion. |
| `extern struct` for C-compatible IDL types | Structs whose fields are all C-compatible use `extern struct`; others use plain `struct`. |
| `deinit(alloc)` on sequence-containing types | Recursively frees heap-owned sequence buffers (`_release == true`). |
| `clone(alloc)` on sequence-containing types | Deep copy symmetric to `deinit`; used by vtable `init` to own QoS with sequence fields. |
| Cross-module `@callback interface` inheritance (IR builder) | An imported file's own AST was previously discarded after semantic analysis, so `ir.build()` only ever registered empty Pass-1 skeletons for imported types — fine for plain type references, but silently dropped the real member list needed to flatten a `@callback interface` inheriting a cross-module base. Fixed via `ir.buildWithImportedUnits`/`ImportedUnit`, which additionally fills imported units' own skeletons from their own AST (main.zig now keeps each import's AST alive instead of freeing it early). Deliberately scoped to `@callback` interfaces only (`resetNonCallbackInterfaces` undoes the fill for entity interfaces after each imported unit) — entity interfaces share the same flattening code (`collectInterfaceMembers`) but rely on it never having real cross-module content (native Zig vtable literals, C++'s `nativeHandleBase` single-candidate assumption); fixing that too is separate, unscoped future work. Also fixed a companion bug: `cApiTypeRef`'s sequence-typedef parameter rendering used the typedef's bare `.name` instead of its qualified name, breaking as soon as the flattened operation's type lived in a different module than the one being emitted. Also fixed: the Zig backend's `zidl_rt` import-need detection didn't account for a file whose *only* callback interface is a newly-added one with no prior typesupport/pl_cdr/c-api trigger. |

---

## C-ABI Interface / Callback Type Coverage

The C-ABI primary interface design commits to a hard constraint: **every type that appears
in a vtable slot or `@callback` listener callback parameter must be C-ABI representable.**
All DDS DCPS status types currently satisfy this constraint (flat structs of primitives,
enums, and fixed-size handles). This section tracks test coverage for that guarantee and
planned mitigation work for types that currently fail it.

### Positive test coverage

Each row is a test case that should exist in the backend unit test suite confirming that
the named type category works correctly as an interface or `@callback` callback parameter.

| Type category | IDL example | Status |
|---|---|---|
| All primitive types | `void f(in long x, in boolean b)` | ✓ covered by existing golden |
| Named struct parameter | `void f(in MyStatus s)` | ✓ covered by existing golden |
| Named sequence typedef parameter | `void f(in StringSeq s)` | ✓ covered by DDS listener golden |
| Named enum parameter | `void f(in MyEnum e)` | ✓ covered by existing golden |
| `string` parameter | `void f(in string s)` | ✓ covered by existing golden |
| Entity fat-pointer parameter | `void on_data(in DataReader r)` | ✓ covered by DDS listener golden |
| Fixed-size array typedef parameter | `void f(in MyByteArray a)` | missing — add to `types.idl` golden |
| Nested named struct parameter | `void f(in OuterStatus s)` | missing — add to `types.idl` golden |

### Negative test coverage

Each row is a case that **must** produce a named error from the generator rather than
silently emitting broken or type-unsafe C. A `// TODO` comment or a `void *` fallback
is not acceptable — it compiles but produces wrong behaviour at runtime.

| Type category | IDL example | Current behaviour | Target behaviour |
|---|---|---|---|
| `map<K,V>` parameter | `void f(in map<string,long> m)` | C backend errors on map in structs; interface/callback position not separately tested | Hard error: "map not C-ABI representable in interface parameter; use a named opaque typedef" |
| Anonymous/inline sequence parameter | `void f(in sequence<string> s)` | Untested; likely silent wrong emit | Hard error: "anonymous sequence not C-ABI representable; add a typedef" |
| Discriminated union parameter | `void f(in MyUnion u)` | C backend has no union-in-interface test; output untested | Hard error: "union not C-ABI representable in interface parameter (C union is untagged)" |
| `wstring` parameter | `void f(in wstring s)` | Emits `wchar_t *`; silently platform-width-dependent | Warning or hard error: "wstring ABI width is platform-dependent; use a fixed-width typedef" |
| `fixed<D,S>` parameter | `void f(in fixed<10,2> x)` | Emits `// TODO` comment | Hard error: "fixed_pt not C-ABI representable in interface parameter" |
| `valuetype` parameter | `void f(in MyValueType v)` | Untested | Hard error |
| Sequence-of-non-C-type typedef | `typedef sequence<MyUnion> UnionSeq; void f(in UnionSeq s)` | Untested; element type check missing | Hard error propagating from union element |

Each negative case should have a dedicated unit test in `src/backend/zig.zig` and
`src/backend/c.zig` asserting that the generator returns an appropriate error (not a
successful codegen that happens to be wrong).

### Mitigation work

The items below describe what it would take to move each negative case into the
positive column, ordered by impact (likelihood of appearing in real DDS-adjacent IDL)
and implementation complexity.

**1. Anonymous/inline sequences → synthesize a typedef**

When `sequence<T>` appears directly as an interface parameter type with no prior
typedef, automatically synthesize one:
`typedef sequence<T> _ZidlGen_<InterfaceName>_<OpName>_<ParamName>_Seq;`
and emit the corresponding extern struct before the callback struct or vtable
declaration. Purely mechanical; no semantic change. Covers the most common
case of a developer writing `sequence<string>` inline without thinking about it.

*Impact: medium. Risk: low.*

**2. Discriminated union → OMG C PSM companion struct**

IDL `union` has no direct C-ABI equivalent because C unions are untagged.
The OMG C PSM (formal/02-06-01) defines the canonical mapping:

```c
typedef struct MyUnion {
    long _d;        /* discriminant */
    union {
        MyStruct s; /* case 1 */
        long n;     /* case 2 */
        bool b;     /* default */
    } _u;
} MyUnion;
```

The Zig-side representation stays a tagged union. A generated conversion
function translates between them in the `@callback` comptime thunk. This
is well-specified by the OMG but non-trivial to wire into the thunk generator.

*Impact: medium. Risk: medium (conversion thunk in comptime wrapper).*

**3. `wstring` → fixed-width `uint16_t *`**

DDS RTPS encodes wstring as UTF-16LE (2-byte code units). The platform-dependent
`wchar_t` is the wrong type for cross-ABI use. Replace with `uint16_t *` (or
`typedef uint16_t DDS_WChar; DDS_WChar *`) to make ABI width deterministic.
Mechanical, but breaks existing C callers passing `wchar_t` literals.

*Impact: low (wstring is uncommon in modern DDS profiles). Risk: low once decided.*

**4. `fixed<D,S>` → runtime struct in `zidl_cdr.h`**

Define `typedef struct { uint8_t digits[16]; uint8_t scale; } zidl_fixed_t;` in the
runtime header and emit `zidl_fixed_t` for `fixed<D,S>` parameters. No precision
validation in the ABI; caller's responsibility. Straightforward.

*Impact: very low (fixed-point is almost never used in DDS). Risk: very low.*

**5. `map<K,V>` → opaque handle + accessor functions**

No C struct can represent an arbitrary hash map. The practical path is an opaque
handle (`typedef struct ZidlMap_s *ZidlMap;`) with generated free functions:
`ZidlMap_get`, `ZidlMap_set`, `ZidlMap_iter`. On the Zig side the map remains a
native hash map; the thunk wraps a pointer to it.

Maps rarely appear in DDS API surfaces (they mostly appear in user data types, which
bypass the vtable as opaque CDR bytes). Best deferred until a concrete use case in
DDS API IDL arises.

*Impact: low. Risk: high (non-trivial generated accessor surface).*

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
