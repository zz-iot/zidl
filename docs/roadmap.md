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

**PL_CDR (RTPS ParameterList) codegen in non-Zig backends — not planned, verified out of
scope for all of them (C, C++, Java, and future Python/C#/Rust/Haskell alike).**
`--zig-pl-cdr` is a Zig-backend-only flag; every other backend parses and silently ignores
it, and that's correct, not a gap. Confirmed against zzdds (zidl's only real-world
consumer): `idl/rtps_discovery.idl`, the sole IDL file with PL_CDR-eligible `@mutable`
discovery types, is generated exclusively via `-b zig --zig-pl-cdr`
(`zzdds/docs/dev-notes.md`) — no non-Zig generation target exists for it. RTPS wire-level
SPDP/SEDP encode/decode happens entirely inside zzdds's Zig core
(`src/discovery/spdp.zig`/`sedp.zig`) and never crosses the C-ABI. The only place discovery
data reaches a binding is via `ParticipantBuiltinTopicData` and its siblings in
`idl/dcps.idl`, which are plain `@final` structs generated through the ordinary
(non-PL_CDR) path — by the time any binding sees discovery data it's already been decoded
by Zig and repackaged as an ordinary DDS-typed struct. Since RTPS discovery always runs in
the Zig core regardless of which language binding created the participant, no binding
backend needs its own PL_CDR codec — this applies uniformly, not just to C/C++. Re-raise
only if a consumer other than zzdds needs a non-Zig program to implement RTPS wire
discovery directly, without going through the Zig core.

### C and C++ backends

- **`ZidlCdrAllocator` (user-supplied allocator for strings/sequences). Done.**
  `zidl_cdr_read_string`/`read_wstring` and the C backend's generated inline sequence-buffer
  allocation used `malloc` directly; `defaultValueToC`'s `@default("...")` string handling
  used `strdup`. All now route through `zidl_cdr_alloc`/`zidl_cdr_free`/`zidl_cdr_strdup`/
  `zidl_cdr_free_str`/`zidl_cdr_free_wstr` (`packages/zidl-cdr`), which fall back to
  libc malloc/free/strdup unless a `ZidlAllocator` (the same shared vtable struct from Phase
  0/1, `zidl_allocator.h`) is registered via `zidl_cdr_set_allocator()`.

  **Design decision, not just an implementation detail**: the registered allocator is
  **process-wide**, not per-`ZidlCdrReader`-instance as originally sketched. A decoded
  string/sequence field is freed later by a generated `_free()`-adjacent function
  (`zidl_cdr_free_str`/`_free_wstr`/`_free` call sites the C backend emits) that has no
  reader or other per-call context in scope — there's nowhere to remember "which allocator
  made this" without growing every generated struct with an extra field (an ABI break) or
  breaking every `_free()` call site's signature. A single global, set once at startup
  (mirroring e.g. SQLite's `sqlite3_config(SQLITE_CONFIG_MALLOC, ...)`), avoids both. The
  real limitation this accepts: two different topic types (or two participants) can't have
  two different CDR-layer allocators — only one process-wide default. `zidl_cdr_free_str`/
  `_free_wstr` reconstruct the original allocation size (`strlen(s)+1` / scan-to-NUL-wchar)
  since a bare `char*`/`uint16_t*` field has nowhere to remember it; sequence frees use the
  already-stored `_maximum * sizeof(elem)`, no reconstruction needed. A fixed 8-byte
  alignment is requested for every `zidl_cdr_alloc` call — provably sufficient for any IDL
  primitive or struct (C99 target, no `_Alignof`, and no per-element-type alignment plumbed
  through generated code).

  Verified: `zig build test`/`integration-test` (including two `check-goldens` fixtures
  updated to the new call sites), new `zidl-cdr` tests covering the allocator API directly,
  and — separately, not just compiled — a standalone C program using the real generated
  `Sample_deserialize` (a struct with both an unbounded `string` and an unbounded
  `sequence<long>` field) decoded a real CDR payload with a custom allocator registered:
  2 allocations, 2 frees, both fields correctly populated.
- **C++ backend: `_getOrCreate`/`zzdds_cpp.hpp` allocator support. Done.** Entity wrapper
  construction (`_getOrCreate`, this session's identity-cache work above) and zzdds's
  hand-written factory bookkeeping (`wrapFactoryHandle`/`DomainParticipantFactorySupport`)
  both hardcoded `std::make_shared`/global `new`. Landed as `std::pmr`-based, process-wide
  registration via a new `zidl::setCppAllocator(const ZidlAllocator*)` (new
  `zidl_allocator_pmr.hpp` in `zidl-cdr` — same `ZidlAllocator*` ABI as the C-side work
  above, bridged into a `std::pmr::memory_resource`). Both surfaces now use
  `std::allocate_shared` against `std::pmr::get_default_resource()`; `_getOrCreate`'s
  generation is gated on the existing pre-scan pass so the extra includes/machinery are only
  emitted where an entity is actually wrapped somewhere. Per the C++ `Allocator` named
  requirement, OOM signals via `std::bad_alloc` rather than a graceful null return — a
  deliberate, documented departure from every other allocator surface's contract, chosen
  over a non-throwing alternative for idiomatic-C++ ergonomics (degrades to
  `std::terminate()` under `-fno-exceptions`, matching libstdc++'s own `operator new`); the
  registration surface was deliberately kept as `ZidlAllocator*` rather than a raw
  `std::pmr::memory_resource*` so a future graceful/non-throwing option stays cheap to add
  later without an API break.

  **Correctness fix post-review (Greptile, PR #28, P1)**: the first cut of
  `ZidlAllocatorResource` read the active `ZidlAllocator*` from a mutable global slot
  *dynamically*, at both allocate- and deallocate-time, so that re-registering with a
  different `ZidlAllocator*` would take effect immediately — but that meant an
  already-outstanding object, allocated under allocator A, would have its eventual free
  routed through whichever allocator was *currently* registered (B) when its `shared_ptr`
  control block finally hit zero — silent heap corruption for any allocator that validates
  ownership on free (pool allocators, bounds-checkers). Fixed by binding each
  `ZidlAllocatorResource` permanently to one `ZidlAllocator*` at construction instead of a
  shared mutable slot: `setCppAllocator` now allocates a small new resource instance per
  registration (deliberately never freed — re-registration is a rare, startup/admin-time
  operation) and installs it as the process-wide default. Since
  `std::pmr::polymorphic_allocator` captures a `memory_resource*` by value at allocation
  time, every object now keeps freeing through the exact resource — and hence the exact
  `ZidlAllocator*` — that allocated it, for its whole lifetime, regardless of later
  re-registration. New allocations still pick up a re-registered allocator immediately, as
  originally advertised; what changed is that outstanding objects are no longer affected by
  it. Verified via a standalone regression test (allocate under A, re-register B, free the
  object allocated under A, assert A's `free` — not B's — is called): confirmed it fails
  under the old dynamic-slot code and passes under the fix.

  Verified end-to-end: real rebuild of zzdds against a local zidl checkout,
  `dcps_impl.cpp`/`zzdds_impl.cpp` compiled clean with real g++, and a standalone C++
  program (`zzdds::create_factory()` + `create_participant(...)`) proving construction
  routes through a registered tracking `ZidlAllocator`, re-registration takes effect
  immediately for new allocations, and `nullptr` restores the libc/`new`/`delete` default —
  see zzdds's `docs/design/allocator-strategy.md` "Phase 3" for the fuller writeup,
  including a note on why the identity-cache's control-block memory isn't asserted to free
  promptly (a pre-existing property of the `weak_ptr` cache, independent of this phase).

  **Follow-up (Greptile, PR #28, post-5/5 "worth a second read" note) + user-driven scoping
  question**: `setCppAllocator`'s own bookkeeping (installing one `ZidlAllocatorResource` per
  registration) used plain `new` unconditionally — the one spot in this header not already
  routed through a caller-supplied `ZidlAllocator` (factory bootstrap and
  `_getOrCreate`/`wrapFactoryHandle` both already are, via `zzdds_create_factory_with_allocator`
  and `setCppAllocator` respectively). For a toolchain with a working heap this is an accepted,
  bounded, one-time/startup-only allocation — but for a genuinely heap-free bare-metal target it
  would be the only remaining gap. Added an opt-in escape hatch: defining
  `ZIDL_ALLOCATOR_PMR_STATIC_POOL_SIZE` (an integer) before including the header switches
  `setCppAllocator` to placement-new into a fixed-size static pool instead of the heap — bounded,
  not wraparound-reused (reusing a slot behind a still-outstanding object would resurrect the
  wrong-allocator-freed bug the construction-time-binding fix above closed), asserting if the
  bound is exceeded. Default behavior (plain `new`) is unchanged unless the macro is defined.
  This isn't a zidl backend/codegen flag — `zidl_allocator_pmr.hpp` is hand-written and
  header-only, not generated per-IDL-spec, so a preprocessor macro the consumer defines in their
  own build is the natural, toolchain-agnostic switch; no codegen (`cpp.zig`) changes were
  needed. Verified: default mode still calls global `operator new` (confirmed via an
  abort-on-call override, so the check is meaningful, not vacuous); pool mode never calls global
  `operator new`/`delete` at all, for both `setCppAllocator` itself and the subsequent
  `_getOrCreate`-style `allocate_shared` call through it (confirmed the same way); exceeding the
  pool bound asserts rather than silently wrapping around onto a live slot. The first two are
  now permanent, CI-checked integration tests
  (`test/integration/cpp/test_allocator_pmr_static_pool.cpp`); the bound-exceeded check was
  verified manually (an abort doesn't fit the existing "compile, run, expect exit 0"
  integration-test harness without adding subprocess-based death-test infrastructure, judged
  disproportionate for a defensive bound on a rare, non-hot-path admin operation).

  **Correctness fix (Greptile, PR #28)**: the bound check was originally `assert()`-only —
  which compiles to nothing under `-DNDEBUG`, the normal production/release build
  configuration for the embedded targets this macro exists for. That meant in exactly the
  deployment mode that matters, exceeding the pool bound wouldn't abort — `pool[next++]`
  would silently index past the static array and placement-new construct a
  `ZidlAllocatorResource` into whatever static/global storage happened to follow it in the
  binary's layout. Confirmed this concretely (not just by inspection): computed the returned
  pointer for a deliberate over-bound call and showed it landed exactly
  `sizeof(ZidlAllocatorResource)` bytes past the last valid slot — a real out-of-bounds
  pointer, not a hypothetical. (AddressSanitizer did not flag this specific case, due to a
  known ASan blind spot around function-local statics inside `inline`-linkage functions,
  which get COMDAT-folded across translation units — the direct pointer-arithmetic proof
  stood in for it.) Fixed by adding an unconditional `if (next >= kPoolSize) std::abort();`
  right after the (now debug-only-diagnostic) `assert()`, so release builds fail loudly
  instead of corrupting memory. Verified the fix aborts correctly under `-DNDEBUG` (where it
  previously didn't).

  Net effect: with a caller-supplied static-pool-backed `ZidlAllocator` registered via both
  `zzdds_create_factory_with_allocator` and `setCppAllocator` (in pool mode), the *entire* C++
  allocation chain — factory bootstrap, everything the factory creates, and now
  `setCppAllocator`'s own registration bookkeeping — can avoid libc `malloc`/global `operator
  new` for the whole process lifetime, not just after some setup phase. That matters for the
  planned showcase apps' `LD_PRELOAD` verification shim (see below): a from-process-start
  abort-on-any-`malloc`/`new` shim becomes viable for a fully-configured app, rather than needing
  a "only trip after setup completes" leniency window.
- **C++ backend: `--cpp-pmr-containers` flag — STL-container allocator injection. Done.**
  The remaining allocator-injection gap after the above: generated `sequence<T>`/`string`/
  `wstring`/`map<K,V>` fields (struct members, union case payloads, CDR-source local
  temporaries) were hardcoded to `std::vector`/`std::string`/`std::wstring`/`std::map`,
  regardless of any `ZidlAllocator` registered elsewhere. Landed as a new opt-in backend
  flag (`--cpp-pmr-containers`, off by default) that switches all of these to their
  `std::pmr::` equivalents across all four C++ generator structs (`Generator`,
  `CdrGenerator`, `ConcreteImplGenerator`, `ImplGenerator`) plus the shared `cppTypeStr`
  helper, and emits `#include <memory_resource>` alongside the existing `<vector>`/
  `<string>` includes when set. Reuses Phase 3's `zidl::setCppAllocator`/process-wide
  `std::pmr` default resource directly — no new registration API, no per-instance
  scoped-allocator constructor plumbing, since `std::pmr::vector`/`string`/`map` all
  default-construct against `std::pmr::get_default_resource()` on their own. Applies
  uniformly to bounded and unbounded fields alike (only the allocator changes; existing
  bound-enforcement logic in the CDR read/write bodies is untouched). Off by default since
  it changes the concrete C++ type of every affected field — a real source/ABI break for
  any consumer naming `std::vector<T>`/`std::string` directly.

  Considered and rejected two alternatives (see zzdds's `docs/design/allocator-strategy.md`
  "the C++ template problem" for the fuller writeup): threading an allocator template
  parameter through every generated type (cascades through every interface signature,
  forces today's separately-compiled impl model into header-only templates — largest blast
  radius by far); and giving *bounded* fields a genuinely fixed-capacity, non-heap-allocating
  type mirroring `zidl_rt.BoundedArray` (dropped — the actual goal is caller-controlled
  allocation, not literally zero allocation, and a real `std::vector`/`std::string`-compatible
  bounded container satisfying the OMG C++11 PSM's requirements (formal-24-07-01 §6.10/§6.12)
  would have been a genuine from-scratch STL-container implementation, not a cheap wrapper).

  Verified: three new `zig build test` unit tests (flag off leaves output unchanged; flag on
  emits `std::pmr::` types + the include, for both bounded and unbounded fields; union-case
  CDR-decode locals also switch) — confirmed meaningful by breaking one assertion and
  watching it fail before restoring it. Plus a real, CI-tracked `zig build integration-test`
  addition: generates a fresh (non-golden) `types.hpp` from the shared
  `test/golden/types.idl` with the flag on, compiles it for real, and proves struct-field
  construction/assignment/destruction routes through a registered tracking `ZidlAllocator`
  (matched alloc/free counts) while defaulting to untracked `new`/libc when unregistered.
  Also manually confirmed (real compile, not just the unit tests) that a CDR
  serialize/deserialize roundtrip through `std::pmr::` struct fields works correctly. Along
  the way, confirmed a *pre-existing, flag-independent* gap while testing a union with a
  sequence/string case payload: it fails to compile with or without this flag, matching
  `cpp.zig`'s own documented limitation ("Unions with members of non-trivially-constructible
  types (std::string, std::vector, …) produce C++ that requires explicit
  constructor/destructor; not generated here") — not a regression introduced here, and out
  of scope for this flag.

  **Correctness fix (Greptile, PR #29, P1)**: the first cut only updated *type declarations*
  (struct/union member types, CDR locals, function signatures) to `std::pmr::string` under
  the flag, but missed the *value-construction* expressions in the generated interface
  adapters — `ConcreteImplGenerator`'s `str_ret` operation/attribute-getter bodies and
  `emitFieldAdaptOut`'s string-field assignment, plus `ImplGenerator`'s equivalent
  string-returning operation/attribute bodies — which still hardcoded
  `std::string(raw_c_string)`. This is worse than a stray extra allocation: confirmed via a
  real, minimal standalone compile that `std::pmr::string` has no implicit conversion from
  `std::string`, so any interface with a string-returning operation or attribute (or a
  string-typed out-adapted field) failed to *compile at all* under the flag — not merely
  bypassed the registered allocator, as originally suspected. Fixed by routing all five
  construction sites through the same `stringTypeName(opts)` helper the type declarations
  already use. Verified: 4 new unit tests (both generators, flag on/off) — confirmed
  meaningful the same way (break one, watch it fail, restore); a real generated
  (non-golden) interface with a string-returning operation/attribute now compiles clean
  under `--generate-interfaces --cpp-pmr-containers` where it previously failed to compile;
  and a linked, run standalone program proved both the returned values are correct and
  allocation for them routes through a registered tracking `ZidlAllocator` (matched
  alloc/free counts).
- **C backend: `{Type}_free()` is declared but never given a body.** Found while verifying
  `ZidlCdrAllocator` above, not by looking for it: every generated header declares `void
  {Type}_free({Type} *v);` for every struct (`src/backend/c.zig` — search for the two
  `"{s}{s}void {s}_free({s} *v);\n\n"` declaration sites), but no generator function
  anywhere emits a matching definition — confirmed against the golden fixtures (declared in
  `test/golden/c-split/Sample.h`, no body in `Sample_cdr.c` or anywhere else) and via a real
  build. Calling it today is a link error. The only "free" logic that exists
  (`emitFreeKeyField`/`emitFreeArrayElements`/`emitFreeSeqElements`) is reachable *only* from
  `{Type}_compute_key_hash_from_cdr`'s cleanup path, for `@key` fields of a temporary
  decode — not a general free of every heap-owned field. Needs a real implementation:
  extend that existing logic (or a generalized version of it) to run over every field, not
  just `@key` ones, recurse into nested structs, and route through the `ZidlCdrAllocator`
  helpers above (`zidl_cdr_free_str`/`_free_wstr`/`_free`) rather than raw `free()` — see
  zzdds's `docs/design/allocator-strategy.md` "Phase 5" for the fuller writeup and why it's
  tracked as part of the allocator plan despite not being required by it.
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
its own `entity_view_handle` for `get_entity()`). Done — this vtable slot has
shipped in tagged zidl releases since `v0.2.7-zig.0.16.0`; see the zzdds
roadmap for the implementation details.

### C++ backend: entity wrapper identity (Implemented)

A related but independent gap, found while auditing whether this design should
change anything for the C++ backend (it doesn't need to — C++'s own
`class Foo` / `class FooImpl : public Foo` abstract-class hierarchy already
gets real polymorphism natively from the compiler-embedded vtable, which is
exactly what the Zig side had to hand-roll as a fat pointer; there's no
analogous "narrow a fat reference into an opaque C handle" problem on the C++
side for boxing to solve). But looking at `ConcreteImplGenerator`
(`src/backend/cpp.zig`) surfaced a structurally similar, pre-existing gap: it
constructed a fresh `std::make_shared<FooImpl>(_h)` on every operation that
returns an entity, so calling e.g. `participant->get_topic("X")` twice used to
return two different `FooImpl` objects wrapping the same underlying `_h` —
not identity-equal, though not a leak either (`shared_ptr` RAII cleaned up
correctly regardless of how many wrapper instances existed).

This wasn't practically fixable before the heap-boxing work above: nothing
guaranteed the raw C handle `_h` was itself stable/reusable across calls, so
there'd have been no correct value to key a wrapper cache against. Now that
`get_c_abi_handle` makes the underlying handle identity-stable, the C++ side
reuses the same principle. Every entity `FooImpl` class gets a `public static
std::shared_ptr<FooImpl> _getOrCreate(DDS_Foo h)` factory (declared in the
header next to the constructor, defined once in the generated `.cpp`), backed
by a function-local `static std::unordered_map<DDS_Foo, std::weak_ptr<FooImpl>>`
plus a `static std::mutex` — C++11 "magic statics" give this exactly one
instance per class, lazily initialized, thread-safe, with no separate member
fields or manual initialization needed. Lookup: if a live (non-expired)
`weak_ptr` is cached for the handle, return `.lock()`'s result; otherwise
construct-and-cache a new `FooImpl` and return it. `_getOrCreate(nullptr)`
returns `nullptr` (subsuming the old separate `if (!_h) return nullptr;`
guard at each call site). All four generated call sites that used to construct
a wrapper directly — the entity-returning operation path, the entity
attribute getter, the sequence-of-entities out-adaptation loop, and the
listener-trampoline argument wrapper — now route through `_getOrCreate`
instead of `std::make_shared` directly, so identity holds everywhere a wrapper
can originate, including entities arriving via a listener callback.

One accepted tradeoff: expired (`weak_ptr` no longer lockable) entries are
only overwritten lazily, on the next `_getOrCreate` call for that same handle
value — there's no active sweep, so a long-running process that creates and
destroys many distinct entities whose C handle addresses are never reused
will accumulate dead map slots (small, pointer-sized; not a use-after-free or
object leak, since the cache only ever holds a `weak_ptr`). Not addressed
here; revisit if it matters in practice.

Unlike the Zig-side `get_c_abi_handle` item, this needed no hand-written zzdds
participation — zzdds doesn't author its own C++ bindings; they're entirely
generated via `--cpp-generate-impl`. Verified two ways: (1) the codegen unit
tests in `src/backend/cpp.zig` assert the header declaration, the cache/mutex
body, and all four call sites; (2) real-world check against zzdds — pointed
`zzdds/build.zig.zon` at this local zidl checkout, ran
`zig build install -Dcpp-binding=true`, and compiled the resulting
`dcps_impl.cpp` (95 `_getOrCreate` occurrences across ~35 entity classes) with
`g++ -std=c++17 -Wall -Wextra -pthread` — zero errors, zero warnings
attributable to the new code (12 pre-existing, unrelated sign-compare
warnings only). A standalone reproduction of the exact generated pattern
(separately compiled and run) confirmed the runtime invariants: two calls for
the same live handle return the identical `shared_ptr`; a different handle
gets a distinct wrapper; dropping every `shared_ptr` for a handle lets the
cached `weak_ptr` expire so the next call constructs fresh rather than
returning a dangling reference; and a reused handle address correctly
overwrites the stale slot. Not yet in a tagged zidl release — needs a
release before zzdds's C++ users see it (zzdds currently pins
`v0.2.9-zig.0.16.0`, unaffected until the pin is bumped).

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
| C++ backend: four bugs found via zzdds's real (compile+link+run) C-ABI allocator-injection verification | None of these were caught before because nobody had compiled zzdds's own `zzdds_impl.cpp` (as opposed to `dcps_impl.cpp`, unaffected) with a real C++ compiler. **(1)** `native_handle()` override mismatch — cross-module entity `.bases` were reset to empty by the IR builder's import-fill (`resetNonCallbackInterfaces`, to avoid growing Zig vtables), making a real base (`DDS::DomainParticipant : Entity`) look base-less from a different file's generation pass; fixed by preserving `.bases` specifically while still resetting operations/attributes, plus making `collectEntityBaseNames` walk the base chain transitively (`src/ir/builder.zig`, `src/backend/interface.zig`). **(2)** Listener trampoline wrapping the wrong class for a cross-module `@callback interface`'s flattened-in entity parameter (bare class name resolved in the listener's own namespace instead of the parameter's actual module) — fixed by using the existing `entityImplName()` qualifier consistently. **(3)** A regression from this session's own `_getOrCreate` work: making it unconditional meant its `make_shared` body got compiled for entity classes intentionally left abstract (completed by a hand-written subclass elsewhere, e.g. zzdds's `DomainParticipantFactorySupport`); fixed with a pre-scan pass so `_getOrCreate` is only emitted for interfaces actually wrapped somewhere in the spec. **(4)** Scalar-typedef listener parameters (e.g. `typedef long InstanceHandle_t`) passed by pointer in the C++ trampoline while the C listener struct declared the same field by value — the C backend's `isCPrimitive` already resolves typedef chains correctly; added the equivalent `typeRefIsCScalar` to the C++ backend. All four verified via `zig build test` + `integration-test` plus a real `dcps_impl.cpp`/`zzdds_impl.cpp` recompile after each fix — see zzdds's `docs/design/allocator-strategy.md` for the full writeup. |
| C backend `--generate-interfaces`: opaque handles | Entity interfaces emit `typedef struct Foo_s *Foo;` instead of a fat-pointer vtable struct; C++ `ConcreteImplGenerator` null-checks/null-handle literals updated to match. |
| Const type-checking (semantic analyser) | `const_type_mismatch` diagnostic; validates initializer compatible with declared type (§7.4.3). PR #20. |
| Union discriminant type validation | `invalid_discriminant_type` diagnostic; validates integer/char/boolean/wchar/octet/enum base (§7.4.8), including typedef-of-typedef. PR #20. |
| C++ concrete impl backend: 11 TODO stub methods | `get_listener` ×6 (stash pattern), `get_offered/requested_incompatible_qos_status` ×2, `WaitSet::wait`/`get_conditions` ×2, `SubscriberImpl::get_datareaders` — unlocked by extending `isAdaptableSeqElemIn` for simple-struct and entity-interface sequence elements, plus a `listener_` stash member. |
| `--zig-generate-c-api` trivial forwarders (Zig backend) | Vtable slots are C-ABI; exports are one-liners. No type conversion. |
| `extern struct` for C-compatible IDL types | Structs whose fields are all C-compatible use `extern struct`; others use plain `struct`. |
| `deinit(alloc)` on sequence-containing types | Recursively frees heap-owned sequence buffers (`_release == true`). |
| `clone(alloc)` on sequence-containing types | Deep copy symmetric to `deinit`; used by vtable `init` to own QoS with sequence fields. |
| Cross-module `@callback interface` inheritance (IR builder) | An imported file's own AST was previously discarded after semantic analysis, so `ir.build()` only ever registered empty Pass-1 skeletons for imported types — fine for plain type references, but silently dropped the real member list needed to flatten a `@callback interface` inheriting a cross-module base. Fixed via `ir.buildWithImportedUnits`/`ImportedUnit`, which additionally fills imported units' own skeletons from their own AST (main.zig now keeps each import's AST alive instead of freeing it early). Deliberately scoped to `@callback` interfaces only (`resetNonCallbackInterfaces` undoes the fill for entity interfaces after each imported unit) — entity interfaces share the same flattening code (`collectInterfaceMembers`) but rely on it never having real cross-module content (native Zig vtable literals, C++'s `nativeHandleBase` single-candidate assumption); fixing that too is separate, unscoped future work. Also fixed a companion bug: `cApiTypeRef`'s sequence-typedef parameter rendering used the typedef's bare `.name` instead of its qualified name, breaking as soon as the flattened operation's type lived in a different module than the one being emitted. Also fixed: the Zig backend's `zidl_rt` import-need detection didn't account for a file whose *only* callback interface is a newly-added one with no prior typesupport/pl_cdr/c-api trigger. Note: `fillFromImportedAst` only fills each *directly* imported unit's own AST — a `@callback interface` base that itself inherits from a type in a second, transitively-imported file is not filled. This is not a new gap: `main.zig`'s import resolution (`processFile`) has only ever scanned the primary file's own top-level `import_dcl`s, so a file with its own imports already fails semantic analysis (`'X' is not declared`) the moment it's used as anyone's import — transitive imports are unsupported across the whole pipeline, confirmed by direct repro, not something this fix introduced or could locally fix. |

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
