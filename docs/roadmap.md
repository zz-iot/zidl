# Backend Roadmap

Planned backend work, ordered by dependency and real-world priority.
For what is currently implemented, see [`features.md`](features.md).

---

## Plugin architecture — direction, not yet started

**Not scheduled; recorded here so near-term flag additions don't quietly paint zidl into
a corner.** zidl currently has a small but growing set of flags whose only real reason to
exist is "what zzdds specifically needs from its C++/Java/etc. impl generation"
(`--cpp-generate-impl`'s override mechanism below is the newest example; the C ABI's
`--generate-zzdds-wrappers` is an older one, named after zzdds outright). Every one of
these bakes a specific DDS implementation's opinions into zidl core, permanently, even
though zidl's stated audience is "any DDS implementation, or none" (see the Python/C#/
Rust backend sections below — none of them are zzdds-specific).

The direction being pointed at, not committed to a design yet: pull the
implementation-specific pieces of each backend (which concrete class backs an abstract
IDL interface, wrapper-generation conventions, listener-bridging conventions, ...) out of
zidl core and into a set of implementation-owned plugins — in zzdds's case, one plugin
per binding it ships (Zig/C/C++/Java), living in the zzdds repo, not this one. zidl core
would stay responsible for the IDL-to-IR pipeline and the generic per-language emission
primitives (type mapping, CDR codegen, the interface/impl split); a plugin would supply
the policy layer on top (e.g. "construct `zzdds::DataWriterImpl`, not the interface's
default impl, for `DataWriter`").

Until that split exists, new implementation-specific needs should still land as explicit,
mechanism-only flags (blind substitution/config zidl doesn't validate against another
IDL file) rather than teaching zidl core to parse a second IDL file and infer policy from
it — the latter is exactly the kind of decision a future plugin should own, and building
it into core now would likely need to be unwound later. `--cpp-impl-override`/
`--cpp-impl-include` (below) are being scoped with this in mind: primitive enough that a
future plugin could emit them programmatically instead of a human hand-writing them into
`build.zig`.

---

## Binding design review: interfaces vs. impls, inheritance, and C-ABI identity — not scheduled, recorded for a future pass

**Not scheduled; recorded here so the tensions found while building the WaitSet/condition
example (`zzdds-examples/{zig,c,cpp,java}/waitset/`, see `zzdds/docs/roadmap.md`'s matching
entry) don't get lost before a deliberate review happens.** The ask: a general review of
zidl's overall pattern for generated classes/interfaces/listeners vs. their concrete impls
— especially interface inheritance and C-ABI boxing/unboxing — aiming for one strategy that
feels consistent across bindings and stays as flexible as possible without giving up much
performance. This section records the concrete tension that prompted the request, plus
other complications noticed along the way, as review scope — not a design, and not a
decision about what changes.

**The anchor case: condition identity survives "same view, asked for repeatedly" but not
"same object, different view."** Two existing mechanisms already give wrapper/handle
identity, and it's worth being precise about the guarantee each one actually makes:

- `CachedCAbiHandle` (`zzdds/src/util/c_abi_handle.zig`) gives a Zig object one C-ABI box
  *per interface view*, lazily created and reused for the life of the object (replacing two
  earlier designs — a hybrid leaf/base split that mis-dispatched on nil results, and
  box-fresh-every-call, which broke identity and leaked on widened-view accessors). A
  `TopicImpl` asked for its `Topic` box twice gets the same box both times. Asked for its
  `Entity` box, it gets a *different*, independently cached box — correctly, since each
  view needs its own vtable.
- `_getOrCreate` (C++ backend, `ConcreteImplGenerator`) gives the C++ wrapper the same
  guarantee one level up: a per-class `handle -> weak_ptr<Impl>` cache means the same C-ABI
  handle in always yields the same `shared_ptr` out, at every entity-returning call site
  (op return, attribute getter, sequence-of-entities out-adaptation, listener-trampoline
  argument).

Both mechanisms were built to solve the same narrower problem: repeated requests for *the
same interface view* of the same object must yield the same wrapper. Neither was ever asked
to solve, and neither does solve, "is this the same underlying object as that other view I
already hold." `GuardConditionImpl` boxes as `GuardCondition` via one cached field and as
`Condition` via a second, independently-cached field — two different, unrelated-looking
boxes for one Zig object, by design. This is invisible until an API genuinely needs
cross-view identity, and `WaitSet.wait()` is the first place that happened: it always
returns conditions boxed as base `Condition` (via `_getOrCreate`'s handle-keyed cache,
keyed on the `Condition`-view handle), so an application holding a `GuardCondition` it
attached earlier cannot recognize it in `wait()`'s result by pointer/handle/wrapper-identity
comparison — only by re-deriving identity out-of-band (in this case, checking each held
condition's own `get_trigger_value()` directly instead of trusting list membership). Worked
around at the application layer in all four `waitset` example ports; not fixed at the root.
See `zzdds/docs/roadmap.md` for the fuller bug writeup.

**A related, but distinct, asymmetry: parameter adaptation tries harder than return
adaptation.** `collectBaseImplementors` (`zidl/src/backend/interface.zig`) builds a
dynamic_cast cascade so an entity/condition *parameter* (e.g. `attach_condition(Condition)`)
can be recovered as its real concrete type by trying each candidate subclass in turn. There
is no equivalent cascade for entity/condition *return values* — a return is boxed once, as
whatever view the operation's IDL signature declares, and never tries to recover a more
specific concrete type the way a parameter does. This asymmetry is the deeper mechanical
root of the `wait()` bug above (it's a return-value site), but it's worth naming as its own
axis, separate from the caching tension, since a review might fix one without the other.

**What the current design gets right — worth preserving, not just working around:**
- C's opaque-handle-per-interface model sidesteps wrapper-identity entirely: the handle
  *is* the identity, there's no wrapper object to keep in sync with it. Simpler, and
  arguably the reason C hasn't hit this bug — worth understanding *why* before assuming
  C++/Java's richer wrapper model is strictly better.
- C++'s real inheritance (`Condition`/`GuardCondition`/etc. as genuine C++ subclasses) makes
  upcasting free and implicit — no manual `as_Condition()` call needed, unlike Zig's
  interface-as-vtable model (see next point). Confirmed a real ergonomic win this round.
- Zig's native `{ptr, vtable}` fat-pointer representation needs no boxing at all for
  pure-Zig-to-Zig code — identity is exact, free, and this whole class of bug structurally
  cannot occur there. The bug only exists at the C-ABI boundary and above.
- The synthetic `as_{Base}` upcast method zidl generates is uniform and mechanical — no
  hand-maintained per-consumer mapping of "which interfaces can this one be viewed as."
  Noticed one inconsistency worth a follow-up, not a redesign: pure Zig-native code doesn't
  get an `as_{Base}` convenience method the way C/C++/Java do (their vtable slot exists, but
  there's no ergonomic wrapper) — every *other* binding has this ergonomic layer, Zig itself
  doesn't, which stood out while writing `zig/waitset` directly against the native API.

**Other complications noticed, not yet fully explored:**
- **Factory-less entities need hand-written, per-binding bootstrap, three times over, with
  no generated or systematic support.** `WaitSet`/`GuardCondition` have no factory operation
  in `dcps.idl` (per OMG spec, they're app-instantiated directly), so this round needed a
  hand-written C-ABI constructor (`zzdds_create_waitset`/`zzdds_create_guardcondition`), a
  hand-written C++ friend-factory wrapper, and a hand-written Java JNI native method — each
  authored from scratch by mirroring `DomainParticipantFactory`'s existing
  `zzdds_create_factory()` bootstrap by hand, not generated. Every future factory-less
  interface repeats this exact three-times-by-hand cost. Worth asking during the review
  whether zidl could detect "no factory operation, not itself a base interface" and offer to
  generate the bootstrap the way it already generates `as_{Base}`.
- **Listener trampolines may have a latent version of the same cross-view identity gap.**
  Per `docs/decisions.md`'s listener-release-hook design, listener-delivered entity/condition
  arguments already go through `_getOrCreate`-style wrapping in C++ trampolines. That means
  *if* any listener ever delivers a condition or entity through a narrower or different view
  than the application originally held it as, the same "different box, same object"
  confusion is possible there too — not confirmed to have happened, not investigated this
  round, but structurally the same mechanism, so worth checking deliberately rather than
  assuming listeners are exempt because conditions were the first place it surfaced.
- **The un-swept box cache's memory tradeoff may not generalize to every workload.**
  `CachedCAbiHandle` and `_getOrCreate` both accept "boxes/wrapper entries live as long as
  the owning object, no active cache-sweep" as fine — reasonable for long-lived entities
  like `Topic`/`Writer`, less obviously fine if a review broadens scope to workloads that
  create/destroy many short-lived `GuardCondition`s or `ReadCondition`s rapidly. Worth
  re-confirming under that lens rather than assuming the existing tradeoff generalizes.
- **Allocator tiering is a precedent any redesign needs to keep, not incidentally break.**
  Boxes/wrappers are allocated through the existing allocator-injection machinery (the
  Tier 0-3 allocator-strategy work); a redesign of the boxing/caching layer should keep
  taking an allocator as a parameter rather than reintroducing a hardcoded one.
- **Fixes here tend to land behind an unreleased zidl checkout, which is its own process
  complication.** Several of this round's real fixes (the `collectBaseImplementors`
  exclusion bug, the entity-sequence `_free` stride bug) only existed as uncommitted local
  changes for a while, consumed by zzdds via a temporary `.path` override in
  `build.zig.zon` rather than a tagged release. Easy to lose track of which zzdds/
  zzdds-examples behavior depends on which specific local zidl state. Not really an
  interface/inheritance/boxing question, but it directly affects how verifiable any future
  review's own findings are, so worth naming.

**Explicitly out of scope for this entry:** no decision is being made here about which
tradeoff to keep, which to fix, or what a unified design would look like. That's the
review itself, not yet started.

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

**C++ backend: `--generate-interfaces`'s generic complex-type adapter (`cpp.zig`'s
`ImplGenerator`/`generateImplSource`, several `/* TODO: adapt C++ types to C ABI */`
sites) silently returns a default value for params/returns that aren't scalar/entity/
string — confirmed dead code for zzdds, verified 2026-08-07, not a live gap.** Checked
against zzdds's own `build.zig`: every `--generate-interfaces` invocation without
`--cpp-generate-impl` (lines ~741/749 for `dcps.hpp`/`zzdds.hpp`, ~588/600 for the
allocator-smoke test) only installs/consumes the generated `.hpp` header — any `_impl.cpp`
those runs might also emit is never added to a compile step. zzdds's real, shipped entity
implementation exclusively comes from the separate `--cpp-generate-impl` runs, which
dispatch to `cpp.zig`'s `ConcreteImplGenerator` (a completely different code path,
gated specifically on `generate_interfaces and !cpp_generate_impl`). So this stub is
real but unreachable for zzdds today; documented in `features.md` as a known limitation
for any consumer that *does* use bare `--generate-interfaces` without
`--cpp-impl-override`/`--cpp-generate-impl`. Re-raise only if such a consumer appears, or
if a real IDL operation with a non-scalar/entity/string parameter needs generic
(non-override) C++ interface adaptation.

**C++ backend: entity/entity-sequence *return* values never recover a more-derived
concrete type, only entity *parameters* do — real gap, not yet fixed.** Found building
zzdds-examples' `cpp/waitset` (2026-08-10): `WaitSet::wait()`/`get_conditions()`'s
generated C++ bodies always box each returned `Condition` via
`::DDS::ConditionImpl::_getOrCreate` (the base interface's own default concrete class) —
unlike entity *parameter* adaptation (`attach_condition`'s cascade, see "C and C++
backends" above), there's no attempt to try `GuardConditionImpl`/`StatusConditionImpl`/
`ReadConditionImpl`/`QueryConditionImpl` instead. Combined with each condition-family
interface's C-ABI handle being cached independently *per view* (zzdds's
`GuardConditionImpl.gc_c_abi` vs `.cond_c_abi`, e.g.), a `Condition` returned from
`wait()` can never be `std::shared_ptr`-identity-equal to (or `dynamic_pointer_cast`-
recoverable as) the concretely-typed shared_ptr an application originally attached, even
though both refer to the same underlying condition — breaking the standard DDS idiom of
iterating `active_conditions` and comparing against held condition objects. See zzdds's
own roadmap (WaitSet/condition example entry) for the full writeup and the workaround
`cpp/waitset` uses instead (branching on each held condition's own `get_trigger_value()`
directly). A real fix needs either a return-path implementor cascade (determining which
concrete class a bare `DDS_Condition` handle was *really* boxed from isn't information
the handle alone carries — would need a runtime "what interface is this" tag/query) or
unifying per-view C-ABI handle caching so every view of the same object boxes to the
same address — a real design question, not a mechanical fix. Zig-native code is
unaffected (native `{ptr,vtable}` values compare directly, no boxing involved) — this is
specific to crossing the C ABI. Likely affects C and Java too (unverified — `c/waitset`/
`java/waitset` don't exist yet); re-raise there once they do.

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

- **C++ backend: `collectBaseImplementors` wrongly excluded `ReadCondition` (and any
  other interface that's simultaneously "used as someone's base" AND "has its own real
  concrete implementor") from an interface's entity-parameter `dynamic_cast` cascade —
  fixed. Done.** Found while building zzdds-examples' `cpp/waitset` (2026-08-09/10),
  the first real exercise of `WaitSet::attach_condition`/`detach_condition` with a plain
  (non-`QueryCondition`) `ReadCondition` through any binding: `dynamic_cast<
  ::DDS::ReadConditionImpl*>` was simply missing from the generated `Condition`-parameter
  adaptation cascade (`ConditionImpl`, `GuardConditionImpl`, `StatusConditionImpl`,
  `QueryConditionImpl` were all tried; `ReadConditionImpl` never was), throwing
  `std::invalid_argument("zidl: incompatible entity implementation for DDS::Condition")`
  at runtime — confirmed via a real crash, not by inspection.

  Root cause: `collectBaseImplementors` (`src/backend/interface.zig`) took
  `entity_base_ifaces` as a parameter and skipped any interface it contained, on the
  reasoning that being "used as a base" meant an interface was purely a structural mixin
  with no leaf of its own — true for `Entity`/`TopicDescription`/`Condition`, but wrong
  for `ReadCondition`: `entity_base_ifaces` answers a narrower question
  (`ifaceOwnsNativeHandle`'s: does *this* interface need its own *virtual*
  `native_handle()`, or does a more-derived interface — `QueryCondition` — own a more
  specific one instead), not "is this interface ever the actual most-derived runtime
  type of an object." `ReadCondition` is legitimately excluded from the first question
  (so `QueryCondition` can declare its own `DDS_QueryCondition`-returning
  `native_handle()` instead of inheriting `ReadCondition`'s) but not the second —
  `create_readcondition()` returns a plain `ReadCondition` whenever the app doesn't ask
  for a `QueryCondition`, and `ReadConditionImpl` is a real, independently-constructible
  class with its own `_getOrCreate`, confirmed generated regardless of
  `entity_base_ifaces` membership (as are `ConditionImpl`/`EntityImpl`/
  `TopicDescriptionImpl` themselves — every non-callback interface gets its own concrete
  impl class unconditionally; there is no case where excluding an `entity_base_ifaces`
  member from `collectBaseImplementors` was ever actually correct).

  Fixed by dropping the `entity_base_ifaces` parameter from `collectBaseImplementors`
  entirely — every non-callback interface is now a valid cascade leaf, matching what the
  impl-class generator already does unconditionally. Verified: `zig build test` green
  (1008/1008, no golden fixture regression — none of zidl's own test IDL happened to
  have this specific "extended-and-independently-leaf" shape before); real end-to-end
  against zzdds — rebuilt `cpp/waitset` against a local zidl checkout, confirmed the
  crash reproduces on the pre-fix build and is gone after, 5+ consecutive real runs
  clean, plus valgrind (0 errors, 0 leaks) and a manual `-fsanitize=thread` build (no
  races, 2 runs).

- **Zig backend: a `sequence<EntityInterface>` typedef's C-ABI `_free` function used the
  native (fat-pointer) element size instead of the boxed (opaque-pointer) one — fixed.
  Done.** Found immediately after the fix above, building the same `cpp/waitset` example
  (2026-08-10): `DDS_ConditionSeq_free` (and every other `sequence<EntityInterface>`
  typedef's generated free function, `zig.zig`'s `is_unbounded_seq` code path) called the
  type's own native `.deinit()`, which frees `self._buffer[0..self._maximum]` using
  `DDS.Condition`'s native 16-byte `{ptr, vtable}` fat-pointer stride. That's correct for
  a `ConditionSeq` built directly by Zig-native code, but every instance a C/C++/Java
  caller actually holds was boxed down to one 8-byte opaque pointer per element by the
  existing entity-sequence C-ABI adaptation (the "`--zig-generate-c-api` bare
  `sequence<EntityInterface>` operation params" fix below, already shipped in
  `v0.3.2-zig.0.16.0`) before ever crossing the ABI — freeing it via the native stride
  requests double the correct byte range from the allocator. Confirmed via valgrind on a
  real crash (`munmap_chunk(): invalid pointer`, deterministically on every single call,
  not a rare race) inside a real `WaitSetImpl::wait()` C++ call — this is the first time
  `wait()`'s C-ABI output path was ever exercised end-to-end with real attached
  conditions, since nothing could construct a `WaitSet` through any binding before
  zzdds's own bootstrap-constructor work landed alongside this example.

  Fixed by detecting the same "is this a `sequence<EntityInterface>`" condition used
  elsewhere in this backend and, only for that case, emitting a `_free` body that
  reinterprets `_buffer` as `[*]?*anyopaque` (`@ptrCast`) before computing the free
  range, and frees only the buffer itself — never the individual boxed entity handles it
  points to, which are independently cached/owned via each entity's own
  `get_c_abi_handle()`. The native `.deinit()` method itself is untouched (still correct
  for its own, non-C-ABI callers). `emitStructCApiFree` (the sibling free-function
  generator for plain data structs with sequence fields) doesn't need the equivalent fix
  — a struct field can never be entity-interface-typed. Verified the same way as the fix
  above: real crash before, clean after, across 5+ runs, valgrind, and a manual TSAN
  build.

- **C++ backend: `--cpp-generate-impl` couldn't construct a vendor-extended entity impl —
  fixed via `--cpp-impl-override`/`--cpp-impl-include`. Done.** Found while porting
  zzdds-examples' `hello_world` to C++ (2026-08-04): `PublisherImpl::create_datawriter`
  and `DomainParticipantImpl::create_topic` (both in zzdds's generated `dcps_impl.cpp`)
  always construct the base `DDS::DataWriterImpl`/`DDS::TopicImpl`, never the
  vendor-extended `zzdds::DataWriterImpl`/`zzdds::TopicImpl` that zzdds's *separately
  generated* `zzdds_impl.hpp` declares (with `set_listener_ex`/`as_topic_description`).
  A caller's natural `static_pointer_cast<zzdds::DataWriterImpl>(dw)` compiles cleanly
  but is undefined behavior — confirmed by reproducing a segfault through a corrupted
  vtable, not just by inspection.

  Root cause is structural, not a missed call site: `--cpp-generate-impl` runs *twice*,
  completely independently — once over `dcps.idl` (→ `dcps_impl.cpp`), once over
  `zzdds.idl` (→ `zzdds_impl.cpp`). The `dcps.idl` pass has no way to know
  `zzdds::DataWriterImpl` exists; from its point of view `DDS::DataWriterImpl` *is* "the"
  concrete `DDS::DataWriter`. There's also no existing IDL-level escape hatch for this —
  `zzdds.idl` extends `DataWriter`/`DataReader`/`Topic`/`DomainParticipant`/
  `DomainParticipantFactory` individually, but nothing overrides the *factory methods*
  that construct them.

  **Scoped fix** (worked out with zzdds; see zzdds's own roadmap for the consumer side):
  two new flags on the `--cpp-generate-impl` pass being generated *from the base IDL*
  (i.e. passed alongside `dcps.idl`'s generation, not `zzdds.idl`'s):
  - `--cpp-impl-override <Interface>=<QualifiedClass>` (repeatable) — every site that
    would construct/return the default impl class for `<Interface>` (every
    `_getOrCreate` call for it) uses `<QualifiedClass>::_getOrCreate(...)` instead. The
    default impl class is still generated (unused, not deleted) — keeps the change
    additive, no "should this class still exist" question.
  - `--cpp-impl-include <header>` (repeatable) — adds an extra `#include` so
    `<QualifiedClass>` is visible.

  **The part that isn't just construction-site substitution**: `dcps_impl.cpp` also
  *consumes* entities constantly, via `dynamic_cast<DDS::TopicImpl*>(...)` in every
  parameter-adaptation lambda that recovers a native handle from a `shared_ptr<DDS::Topic>`
  argument (e.g. `create_datawriter`'s topic parameter). Once `create_topic` returns a
  `zzdds::TopicImpl` instead, those casts fail — `zzdds::TopicImpl` and `DDS::TopicImpl`
  are unrelated siblings, not parent/child. Fixing this does **not** require retrofitting
  multiple/virtual inheritance onto either class (that route was considered and dropped —
  diamond-shaped inheritance through the shared `DDS::Topic` base, needing every default
  impl class to switch to virtual inheritance just to support the rare extended case).
  Simpler and sufficient: when an override is registered for `<Interface>`, the
  parameter-adaptation lambda tries `dynamic_cast<QualifiedClass*>` as an additional
  fallback alongside the default class's cast. `zzdds::TopicImpl` needs no changes at all.

  Implementation note for whoever picks this up: route both the construction sites *and*
  the adaptation-lambda fallback through one central "resolve the concrete impl class name
  for interface X" function in `cpp.zig`'s impl generator, consulting the override table —
  don't hand-patch individual call sites, there are ~20 per entity kind across the file and
  missing one reintroduces the identity-cache-split bug this is meant to fix (a `_getOrCreate`
  call that's missed keeps populating the *default* class's cache instead of the override's,
  so the same native handle ends up with two non-identical wrapper objects).

  **This class of decision — "which concrete class backs abstract interface X" — is a
  DDS-implementation policy choice, not something zidl core should be accumulating
  hardcoded flags for indefinitely.** `--cpp-impl-override`/`--cpp-impl-include` were
  scoped as a general, blind (no cross-IDL parsing) *mechanism* specifically so a future
  zzdds-owned zidl plugin can drive them programmatically instead of a human hand-writing
  the override list in `build.zig` — see "Plugin architecture" below.

  **Implemented as scoped above, both flags landing exactly as designed**: `cpp.zig`'s
  `entityImplName()` is the single choke-point function consulting the override table,
  used by both `_getOrCreate` construction sites and `dynamic_cast` parameter-adaptation
  sites, matching the "route through one central function" implementation note above. No
  changes needed to the default (unoverridden) impl classes or to `zzdds::TopicImpl`
  itself, as predicted. Consumer side (zzdds's four hand-written `*Support` classes
  composing the base `DDS::*Impl`, plus the `build.zig` wiring) is done too — see zzdds's
  own roadmap "C++ ABI" entry for the verification detail (full 6-pair cross-binding
  matrix, zzdds's own test suite, `cpp/hello_world`'s raw-C-ABI workaround removed). Not
  yet in a tagged zidl release; zzdds's pin stays on `v0.3.1-zig.0.16.0` until one is cut.

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
- **C backend: `{Type}_free()` is declared but never given a body. Done.** Found while
  verifying `ZidlCdrAllocator` above, not by looking for it: generated headers declared
  `void {Type}_free({Type} *v);` for structs with an unbounded sequence field
  (`src/backend/c.zig` — search for the two `"{s}{s}void {s}_free({s} *v);\n\n"` declaration
  sites), but no generator function anywhere emitted a matching definition — confirmed
  against the golden fixtures and via a real build; calling it was a link error. The only
  "free" logic that existed (`emitFreeKeyField`/`emitFreeArrayElements`/`emitFreeSeqElements`)
  was reachable *only* from `{Type}_compute_key_hash_from_cdr`'s cleanup path, for `@key`
  fields of a temporary decode — not a general free of every heap-owned field.

  Investigating turned up two more silent gaps beyond "declared but bodyless": the
  declaration gate itself (`structHasSequenceFields`) only checked for *unbounded* sequence
  fields, so (1) a struct with only an unbounded `string`/`wstring` field (no sequence at
  all) got no `_free()` declared, and (2) a struct with only a *bounded* `sequence<T,N>`
  field also got nothing declared — bounded sequences are still `{_maximum, _length,
  T*_buffer, _release}` in the C mapping (only `_maximum` is capped; `_buffer` stays a heap
  pointer, unlike bounded strings which get a genuine inline `char[N+1]`), confirmed by
  generating one and inspecting the header. All three folded into one fix: widened the
  gating check to treat any unbounded string/wstring or *any* sequence (bound or not) as
  needing a free, matching `keyFieldAllocatesC`'s already-correct semantics for the
  pre-existing `@key`-only path (kept the function's existing name,
  `structHasSequenceFields`, for minimal churn despite it now covering more than sequences).

  Implemented the real body generator (`emitStructFree` +
  `emitFreeTypeRefGeneral`/`emitFreeArrayElementsGeneral`/`emitFreeSeqElementsGeneral`,
  modeled on the existing `emitDefault`/`emitApplyDefaults` pair): walks *every* member (not
  just `@key` ones), correctly skips absent `@optional` fields via the same `_present`
  bitmask check `emitApplyDefaults` uses, frees a struct's base class's heap-owned fields
  too, and recurses into nested structs by *calling* their own generated `_free()` rather
  than re-inlining their member walk — which also incidentally fixed a narrower pre-existing
  gap in the `@key`-only helpers (nested sequences-of-sequences-of-strings only freed one
  level deep; the new general version fully recurses). Routes every free through the Phase 2
  allocator-aware helpers (`zidl_cdr_free_str`/`_free_wstr`/`_free`), never raw `free()`.

  Verified: new/updated unit tests for all three gaps, golden fixtures regenerated and
  reviewed as a clean expected diff (`Frame`/`Beacon` gain a `_free`; `Sample`'s already-
  declared one gains its body), and — real, not just unit-tested — a standalone C program
  registering a tracking `ZidlAllocator`, decoding a real CDR payload into a `Sample`
  (string + sequence fields), calling the generated `Sample_free`, and confirming exact
  alloc/free count match (2/2) — no leaks, no double-frees, no under-frees. See zzdds's
  `docs/design/allocator-strategy.md` "Phase 5" for the fuller writeup.

  **Correctness fixes (Greptile, PR #30)**: three real, serious bugs, all in the new
  general free-function generator specifically (the pre-existing `@key`-only one doesn't
  share these exposures, since it only ever runs on values it just decoded itself):
  (1) sequences were freed without checking `_release` (the C mapping's non-owning/
  borrowed-view flag) — fixed by wrapping each sequence's free in
  `if (seq._release) { ... }`; confirmed a stack-backed non-owning sequence crashed with
  `free(): invalid size` before the fix, made zero free calls after. (2) nested sequences
  (`sequence<sequence<T>>`) reused the same loop-index name (`_fsi`) at every recursion
  level, so the inner declaration's own bound-check shadowed the outer loop's index,
  silently reading the wrong element's length — fixed by threading a shared `depth` counter
  (across both array and sequence recursion) so each level gets a distinct `_fai{depth}`/
  `_fsi{depth}` name; confirmed a `sequence<sequence<string>>` with differing inner lengths
  segfaulted before the fix, freed exactly the real allocation count after. (3) array
  typedefs (`typedef string NameList[N];`) were skipped entirely by the declaration gate
  regardless of element type — fixed by checking the element type unconditionally and
  teaching the free-body generator's typedef case to delegate to the array-loop helper when
  dimensioned. All three verified by mechanically reverting just that one fix in real
  generated output and re-running to reproduce the exact reported failure, before
  confirming the fix resolves it.
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
- **C++ backend: entity-parameter `dynamic_cast` adaptation only tried one
  concrete class per interface — fixed. Done.** Found while re-verifying
  `zzdds-examples/cpp/custom-allocator` against a fresh local rebuild
  (2026-08-07): `create_datareader(std::shared_ptr<TopicDescription>, ...)`'s
  generated C-ABI adapter only tried `dynamic_cast<TopicDescriptionImpl*>` —
  the one concrete class `entityImplName()` maps `TopicDescription` to. But
  `DDS::Topic : Entity, TopicDescription` at the abstract interface level, so
  `std::shared_ptr<Topic>` converts implicitly to `std::shared_ptr<TopicDescription>`
  and compiles fine, while the *concrete* `TopicImpl` (or its
  `--cpp-impl-override` replacement) doesn't itself inherit from
  `TopicDescriptionImpl` — each concrete `DDS::*Impl` class implements exactly
  one interface's pure virtuals. The `dynamic_cast` failed at runtime and
  threw `std::invalid_argument`, forcing callers through a workaround
  (`dp->lookup_topicdescription(name)` first, to get a genuine
  `TopicDescriptionImpl`-backed object).

  zidl's IR already had everything needed (`Interface.bases`) — no IR changes
  required. New `collectBaseImplementors` (`src/backend/interface.zig`) walks
  every concrete (non-callback, non-base) interface's base chain once per
  codegen run and records it against every ancestor interface it transitively
  implements; `cpp.zig`'s entity-parameter adapter (the `entity_in` case)
  consults this to emit an extra `dynamic_cast` fallback clause per sibling
  concrete class, in addition to the existing single-class cast, before
  throwing. Composes with `--cpp-impl-override` automatically, since every
  sibling's impl name is still resolved through the same `entityImplName()`
  choke-point. `Topic`/`ContentFilteredTopic`/`MultiTopic` (all implementing
  `TopicDescription`) is the only multiple-inheritance case in
  `dcps.idl`/`zzdds.idl` today, but the fix is general — any interface with
  more than one concrete implementor benefits. Verified: two new regression
  tests (generic synthetic `Base`/`LeafA`/`LeafB` case, plus a single-implementor
  case confirming the plain single-cast form is unchanged); live-verified
  against real zzdds — the generated `SubscriberImpl::create_datareader`
  adapter now cascades `TopicDescriptionImpl` → `zzdds::detail::TopicSupport`
  (a `Topic`) → `ContentFilteredTopicImpl` → `MultiTopicImpl` — and by
  removing `cpp/custom-allocator`'s `lookup_topicdescription` workaround
  entirely (both normal and zero-allocation-guarded acceptance runs pass).

## ContentFilteredTopic filtering: `get_field_from_cdr` (all backends, Done)

Found 2026-08-07 while exercising `zzdds-examples`: `ContentFilteredTopic`
filtering never actually activated in *any* binding, silently — a `DataReader`
created against a `ContentFilteredTopic` received every sample regardless of
its filter expression, with no error anywhere. Root cause: zzdds's
`TypeSupport.get_field` callback (the hook CFT evaluation calls to pull a
named field's value out of a raw CDR payload) was never wired up by any
codegen backend — every generated `TypeSupport` registration passed a null/
absent `get_field` function, so zzdds's CFT evaluator had nothing to call and
silently passed every sample through (matching its own documented "an
evaluation error passes the sample through" semantics, which masked the gap
completely instead of surfacing it).

Fixed by adding `emitGetFieldFromCdr` to all four backends, each emitting the
shape `TypeSupport.get_field` expects
(`zzdds_get_field_from_cdr_fn`/`getFieldFromCdr`): `{c_name}_get_field_from_cdr`
(C, `c.zig`), a free function of the same name (C++, `cpp.zig`),
`<Type>.getFieldFromCdr` (Java, `java.zig`), and `getFieldFromCdr` as a decl
on the generated Zig struct (`zig.zig`). Always emitted, even for a struct
with no filterable members (then it just always returns false) — gated the
same way as the rest of `--generate-zzdds-wrappers`' output. Does a full
CDR deserialize (any simple-typed member, not just `@key` ones — a CFT filter
expression can reference any of them, and CDR isn't randomly addressable, so
a partial/selective parse isn't meaningfully simpler than a full one), reusing
the struct's own generated `_deserialize`/`_free` rather than hand-rolling a
member walk. A matched string member's bytes are copied into a caller-supplied
scratch buffer rather than returned as a pointer into the deserialized value,
since that value is freed before the function returns; a string too long for
the scratch buffer leaves the field unmatched rather than truncating and
risking a wrong comparison result.

Also fixed along the way: the Java backend's bare named `sequence<T>`
operation params (`StringSeq`, `InstanceHandleSeq`, …) were stubbed to
`UnsupportedOperationException` — needed real JNI marshaling for
`register_type_support`'s `get_field_from_cdr` parameter to actually be
callable from Java. Verified end-to-end: zzdds core wiring +
`TypeSupport.get_field` invocation, all four zidl backends' generated code,
all four `zzdds-examples/*/shape` ports, and `dds-rtps/srcZig/shape_main.zig`
all updated and live-verified with a real CFT filter expression actually
suppressing non-matching samples (previously silently delivered).

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

- **`--zig-generate-c-api` bare `sequence<EntityInterface>` operation params —
  binary layout corruption, fixed. Done.** Surfaced 2026-08-07 while
  live-verifying a same-participant discovery fix in zzdds: Java's
  `Subscriber.get_datareaders()` returned a real, correctly-counted
  `DataReader`, but *any* native call on it crashed with SIGSEGV. Not a
  Java-specific bug (two initial theories pointing at Java-side boxing were
  both wrong) — a core C-ABI layout mismatch affecting every binding equally,
  just never triggered before this was the first real caller of a bare
  `sequence<EntityInterface>` operation (`get_datareaders`/`WaitSet.wait`/
  `get_conditions`) through the generated C ABI. For a typedef like
  `DataReaderSeq`, the C backend's header declares single-opaque-pointer
  elements (8 bytes), but `--zig-generate-c-api`'s exported function reused
  its own native extern struct — full `{ptr, vtable}` fat-pointer elements
  (16 bytes) — directly as the parameter type, with zero boxing. Matches a
  TODO this backend had already flagged for sequences generally; entity
  elements were the one case that had never been reached, since scalar/string
  sequences never had a size mismatch to expose it.

  Fixed: new `typeRefIsEntitySequence` detects a bare `sequence<EntityInterface>`
  typedef; `emitCApiOp` now reinterprets the caller's buffer as the real C-ABI
  shape, calls the vtable through a native-shaped temporary, and boxes each
  result element individually via the same `.vtable.get_c_abi_handle(.ptr)`
  convention used everywhere else for entity returns. Also fixed a
  control-flow bug this surfaced: non-void/non-entity-returning operations
  used to inline `return _self.vtable.foo(...)` directly, making the new
  post-call boxing code unreachable — fixed by capturing the return value and
  returning it after boxing. Generic, not Java-specific — C/C++/Zig get the
  fix for free too (once a `WaitSet`/`GuardCondition` C-ABI constructor exists
  to actually exercise `WaitSet.wait()`/`get_conditions()` end-to-end; that
  gap is tracked separately, in zzdds's own roadmap). Verified: one new
  regression test asserting the exact generated-code shape, plus zzdds's real
  C++ `test-bindings` smoke test and full test suite; live-verified
  `create_readcondition()` on a `get_datareaders()`-returned reader now
  succeeds (previously a guaranteed SIGSEGV).

- **`computeKeyHashFromCdr` (per topic struct) — Done, and a real live leak fixed along
  the way.** Found while reviewing zzdds-examples' `hello_world` for rough edges
  (2026-08-06): the Zig backend generated `computeKeyHash(value: @This())` (works on an
  already-deserialized value) but never the C/C++ backends' equivalent
  `{Type}_compute_key_hash_from_cdr(payload, len, hash_out)` — a function matching
  zzdds's `TypeSupport.compute_key_hash` callback shape exactly
  (`fn(ctx: *anyopaque, payload: []const u8) [16]u8`), so generated code can be passed
  directly to a TypeSupport registration call without hand-written CDR-deserialize-then-
  hash glue. Added `emitComputeKeyHashFromCdr` (`zig.zig`), gated the same way
  `computeKeyHash` already is (`--generate-zzdds-wrappers` and `isZzddsTopicStruct`).

  Unlike the C backend (whose generated function resolves its allocator from a global,
  process-wide override — `zidl_cdr_set_allocator` — defaulting to malloc/free), this
  stays consistent with the rest of the Zig runtime's explicit-allocator idiom instead of
  importing C's global-state pattern: `ctx` is a `*const std.mem.Allocator`, supplied by
  the caller at registration time via `TypeSupport.ctx`, used only for variable-length
  `@key` fields. Keyless structs never dereference it, matching `TypeSupport.ctx`'s
  existing "Zig-native implementations that need no state may pass `undefined`" contract.

  **Found a real, live bug while verifying, not by looking for one**: an early version
  leaked on every call for a keyed struct with any variable-length key field (string or
  unbounded sequence) — `deserializeKey` heap-allocates such fields, and nothing freed the
  resulting temporary value. Root cause traced deeper than this one function: zidl's Zig
  backend's `deinit()`/`clone()` generation (`structNeedsCleanup`/`typeRefNeedsSeqDeinit`)
  only ever counted unbounded *sequences* as needing cleanup, never plain unbounded
  `string`/`wstring` fields outside `--zig-generate-toml-config` — a narrower version of a
  bug already found and fixed for the C backend (see "C backend: `{Type}_free()` is
  declared but never given a body" below), just never ported to Zig. Confirmed *live*, not
  hypothetical: zzdds's own `dcps.idl` has `TopicBuiltinTopicData`/
  `PublicationBuiltinTopicData`/`SubscriptionBuiltinTopicData`, each with plain unbounded
  `string name`/`type_name`/`topic_name` fields that `deinit()` silently never freed.

  **Widened the gate (new `memberNeedsCleanup`, replacing `typeRefNeedsCleanup`) to match
  the C backend's parity — with one exclusion the C fix didn't need to consider.** C's
  runtime `_default()` always calls `zidl_cdr_strdup` unconditionally, so by the time
  `_free()` could ever run, a string field is *always* a genuine heap pointer, never a raw
  literal — freeing it unconditionally is always safe. Zig's comptime struct-literal field
  defaults can't do the equivalent at compile time: a member with an explicit non-empty
  `@default("...")` string, on a value that was default-constructed and never actually
  deserialized (a real, not just theoretical, scenario — e.g. an `errdefer`-triggered
  `deinit()` firing before that field was ever reached), is still pointing at static
  literal storage; `alloc.free()` on that is memory corruption, not a leak. Confirmed this
  isn't hypothetical either: `zzdds.idl` has several (`@default("default")`,
  `@default("239.255.0.1")`, ...). New `typeRefIsDirectPlainString`/
  `memberHasNonEmptyStringDefault` narrow the exclusion to exactly that shape — a member
  that is *itself* a plain unbounded string (or typedef chain to one) with a non-empty
  default, outside `--zig-generate-toml-config` (which is exempt: `emitFieldSeqCloneStmt`
  already dupes plain strings unconditionally regardless of that flag, and
  `_toml_applied` tracks real per-value ownership for exactly this case). Such a member is
  deliberately left out of cleanup outside that flag — a narrow, pre-existing gap, not a
  new regression — rather than risk freeing static memory.

  Verified past "compiles": new unit tests for the general case, the non-empty-default
  exclusion (and its empty-default and toml-config counterexamples), and golden fixtures
  regenerated and reviewed as a clean expected diff (`Sample`/`Frame`/`Beacon` gain real
  `deinit()`/`clone()` string handling). Real, not just unit-tested: a standalone Zig
  program serializing a keyed struct with a variable-length string key, then calling the
  generated `computeKeyHashFromCdr` on the raw bytes, confirmed the hash matches
  `computeKeyHash` on the original value with zero leaks (`std.testing.allocator`'s leak
  checker, clean). Against real zzdds: `TopicBuiltinTopicData.deinit()` now frees `name`/
  `type_name`; zzdds's own `zig build test`/`test-bindings` (Java smoke test,
  `cpp_allocator_smoke`) green with no regressions.

- **Union discriminant edge cases**: `wstring` and `fixed_pt` discriminant types emit a
  `// TODO: unsupported discriminant` comment in `serialize` / `deserialize` bodies.
- **Sequence element read with array-typedef element**: A rare edge case where a sequence
  element type resolves to an array typedef emits a `// TODO` comment in the deserialize
  path.

### Java backend

- **`getFieldFromCdr` was a `return null;` stub for a keyless topic under
  `--generate-zzdds-wrappers` — fixed. Done.** Found building zzdds-examples'
  `java/waitset` (2026-08-10), whose `WaitsetSample` type is deliberately
  keyless (matching `hello_world`'s own convention across every binding):
  `emitStructZzddsWrappers`'s keyless-topic branch (added when
  `--generate-zzdds-wrappers` was extended to keyless topics per DDS 1.4
  §2.2.2.1) only emitted the three methods that path's own author believed
  the wrapper codegen actually calls (`serializeKey`/`computeKeyHash`/
  `deserializeKey`) plus a hardcoded stub for `getFieldFromCdr` — but a
  filter expression (`ContentFilteredTopic` or `QueryCondition`) can
  reference any simple-typed member, not just `@key` ones, so this stub
  silently broke filtering for every keyless topic in Java specifically —
  the keyed-struct branch already called the real `emitGetFieldFromCdr`
  (added in the "ContentFilteredTopic filtering: `get_field_from_cdr`"
  round), just never extended to this one. The C and C++ backends don't
  have the equivalent bug: both call their own `emitGetFieldFromCdr`
  unconditionally, with no keyed/keyless branch at all.

  Confirmed via a real, minimal, targeted check (not just a golden-diff):
  serialized a real `WaitsetSample` value to CDR bytes by hand, called the
  pre-fix generated `getFieldFromCdr(payload, "priority")` directly (no DDS
  setup needed — it's a pure static function) and confirmed it returned
  `null` for a field that's genuinely present; regenerated after the fix and
  confirmed the same call now returns the correct boxed value (and still
  `null` for a field that really doesn't exist). Fixed by calling the
  existing `emitGetFieldFromCdr` from the keyless branch instead of emitting
  its own inline stub — no changes needed to `emitGetFieldFromCdr` itself,
  since `deserializeFrom` (which it calls) already exists unconditionally on
  every topic struct regardless of key status. New assertion added to the
  existing "`--generate-zzdds-wrappers` still emits DataWriter/DataReader
  for a keyless struct" test, checking for the real generated switch-case
  body rather than the stub. `zig build test` green (1008/1008).

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
| Typed DataReader/DataWriter spec completeness: `_w_condition` family + other gaps (all backends) | Discovered while fixing an unrelated race in `zzdds-examples/zig/waitset`: `zig/waitset` was the only binding with a `take_w_condition`-equivalent (a hand-written Zig-native raw op), which is *why* it alone needed a two-step "query take, then plain take" split the other three bindings never had the option to hit the same race in. Auditing all four backends' `--generate-zzdds-wrappers` output against the DDS 1.4 spec's full `FooDataReader`/`FooDataWriter` implicit-IDL operation set (confirmed directly against the OMG spec text, not just `dcps.idl`'s own comment) found the entire `read_w_condition`/`take_w_condition`/`read_next_instance_w_condition`/`take_next_instance_w_condition` family missing from *every* backend, plus: batch `read_instance`/`take_instance` missing from C/C++/Java (Zig already had it); Java missing `get_key_value`/`lookup_instance` (reader *and* writer) and `register_instance`/`write_w_timestamp`/`dispose_w_timestamp`/`unregister_w_timestamp` entirely, not just the `_w_timestamp` variants; `register_instance_w_timestamp` missing everywhere. Fixed across all four backends, backed by new zzdds-side core (`DataReaderImpl.takeNextInstanceFiltered`/`readNextInstanceFiltered`, instance-selection itself respecting the condition per spec §2.2.2.5.3.18-19, not just "the next instance with any sample") and C-ABI (`zzdds_take/read_w_condition_raw`, `zzdds_take/read_next_instance_w_condition_raw`, `zzdds_take/read_n_instance_raw`) additions — see zzdds's own roadmap for that half. Java needed genuinely new JNI native methods (`ZzddsRuntime`/`zzdds_java_runtime.c`), not just codegen, since the underlying capability didn't exist there at all for several of these. All four `zzdds-examples/{zig,c,cpp,java}/waitset` subscribers updated to use the real generated `take_w_condition` uniformly (closing the originating race everywhere, not just in Zig, and giving every binding's example the same core-interaction shape) and verified via the full 8-pair cross-binding smoke test. **Explicitly out of scope: loan variants** (`take_loaned_w_condition` etc., and extending `take_loaned`/`return_loan` to Zig/Java) — traced today's C/C++ loan API to a plain process-local heap allocation with no actual zero-copy/SHMEM behind it (SHMEM transport is explicitly "not planned for v1" elsewhere in this roadmap and zzdds's own), so building more surface area against that shape now risks throwaway work once real zero-copy design happens; recorded here rather than silently dropped. |
| ContentFilteredTopic filtering: `get_field_from_cdr` (all backends) | Wires zzdds's `TypeSupport.get_field` hook, previously never emitted by any backend so CFT filtering silently never activated in any binding. See "ContentFilteredTopic filtering" above for the full writeup, including the Java bare-`sequence<T>`-param JNI marshaling fix it needed. |
| C++ backend: entity-parameter `dynamic_cast` now tries every sibling concrete implementor | New `collectBaseImplementors` (`interface.zig`) lets the C-ABI adapter for an interface with multiple concrete implementors (e.g. `TopicDescription`: `Topic`/`ContentFilteredTopic`/`MultiTopic`) try each one instead of just the single class `entityImplName()` maps by name — see "C and C++ backends" above for the full writeup. Removed `zzdds-examples/cpp/custom-allocator`'s `lookup_topicdescription` workaround. |
| `--zig-generate-c-api` bare `sequence<EntityInterface>` params: binary layout corruption fixed | Entity-sequence elements (`DataReaderSeq`, `ConditionSeq`, …) now boxed to the C ABI's single-opaque-pointer layout instead of passing the native 16-byte fat-pointer layout straight through — see "Zig backend" above for the full writeup. |
| Zig backend: `computeKeyHashFromCdr` + `deinit()`/`clone()` plain-unbounded-string parity | Generates the Zig-backend equivalent of C/C++/Java's `{Type}_compute_key_hash_from_cdr`, and along the way widened `deinit()`/`clone()` cleanup to cover plain unbounded `string`/`wstring` fields outside `--zig-generate-toml-config` (previously only unbounded sequences counted — a real, live leak in generated code, not just this new function; see "Zig backend" above for the full writeup, including the non-empty-`@default` exclusion this needed that the C-backend parity fix didn't). |
| C++ backend: `--cpp-impl-override`/`--cpp-impl-include` | Lets `--cpp-generate-impl`'s construction and `dynamic_cast` parameter-adaptation sites resolve a vendor-extended concrete class instead of the default abstract one, for entity interfaces. See "C and C++ backends" above for the full design and zzdds's own roadmap for the consumer side (four hand-written `*Support` classes, `build.zig` wiring, `cpp/hello_world`'s raw-C-ABI workaround removed). Not yet in a tagged release. |
| C backend: `--c-no-free` | Suppresses `{Type}_free()` (prototype and body) for a whole generation pass. Needed when a consumer compiles a generated `_cdr.c` into a binary that *already* exports `{Type}_free` for the same structs from elsewhere — confirmed as a real, not hypothetical, need: zzdds compiling its own `dcps_cdr.c` into `libzzdds.so` hit 25 duplicate-symbol link errors against its existing native `--zig-generate-c-api` `_free` exports before this existed. Deliberately scoped to `_free` only (not folded into `--no-typesupport`, which suppresses `serialize`/`deserialize`/`skip` too) — those three had no collision to avoid, confirmed by the fact that removing just `_free` from the mix cleared every error. See zzdds's `docs/roadmap.md` "Planned" for the consumer side (a second, `--c-no-free`-flagged generation pass feeding what's compiled into `libzzdds.so`, kept separate from the pass that produces the installed header, which must keep declaring `_free` since it's still real). |
| Java backend: real entity JNI bridge, QoS/status marshaling, listener upcalls, `--generate-zzdds-wrappers` | Previously the Java backend only got as far as generating `*Impl.java` + a `dcps_jni.c` that never linked (wrong `zidl_`-prefixed symbol names, structs/listeners passed by value where the real ABI takes pointers, entity params/returns naively C-cast between `jobject` and the opaque handle) and was never compiled, linked, or run by any test. Fixed: correct `{c_name}_{op}` symbol calls and pointer conventions matching `c.zig`; real entity box/unbox via `GetLongField`/`NewObject` with multi-hop `_as_<Base>` widening for entity interface views (`interfaceHasBaseTransitively`/`findConversionPath`); field-by-field QoS/status struct marshaling (`StructMarshalGenerator`, reusing the CDR emitter's field-shape dispatch); listener JNI upcall trampolines (cached `JavaVM*`, `AttachCurrentThreadAsDaemon` for zzdds's own network threads, boxed entity + status args); `--generate-zzdds-wrappers` Java support (typed DataWriter/DataReader + `computeKeyHashFromCdr`). Also fixed, found only via real cross-process runtime testing (not golden-diffing generated text) — a genuine `jstring`-handling bug: `string`/`wstring` params and returns were cast directly between `jstring` and `const char *` instead of going through `GetStringUTFChars`/`NewStringUTF`/`ReleaseStringUTFChars`. This produced garbage topic/type-name bytes that happened to read as *consistent* garbage within one JVM (interned string literals share one object, so both sides of an in-process test coincidentally "matched"), masking the bug in every same-process test; it only surfaced as silent DDS discovery-match failure between two separate JVM processes — traced by instrumenting the RTPS/SEDP receive path down to the decoded (garbage) topic/type-name strings. New: a compiled+linked entity JNI integration test in zidl's own `integration-test` step, and zzdds's `zzdds-java-example/` (two real JVM processes, real UDP RTPS discovery) plus a `test-bindings` Java smoke test. |
| `--zig-generate-toml-config` (Zig backend) | Emits `applyToml(alloc, table: anytype) !void` per struct, driven entirely by the IR (including the already-generic `@default` metadata and each enum's existing `_fromString` helper) — no new parser dependency, `table` is duck-typed. Built for `zzdds`'s config-file support (see its `docs/decisions.md` §Configuration); found and fixed a real pre-existing bug along the way: `clone()` was only ever emitted in the typesupport-enabled path, never under `--no-typesupport` (exactly what `zzdds`'s own vendor-config generation uses) — moved into the same `structNeedsSeqDeinit` gate as `deinit()`, since both are lifecycle operations independent of CDR/wire support. See `docs/backend_zig.md` §TOML config application. |
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
