# C-ABI entity identity across bindings

Status: Phase 1 shipped in `v0.3.5-zig.0.16.0` (2026-08-13). Phases 2+ open — see
[`../roadmap.md`](../roadmap.md) "Known Gaps". Decision summary in
[`../decisions.md`](../decisions.md).

## The problem

A C-ABI handle *is* the address of a heap-allocated `EntityBox{ptr, vtable}`
(`packages/zidl-rt/src/entity_box.zig`). `unboxAs(T, handle)` does a **blind, unchecked
reinterpret** of `box.vtable` as `*const T.Vtable` — there is no runtime type tag anywhere
in the box. This is safe only because every `get_c_abi_handle` call site boxes using a
vtable instance whose static shape already matches the interface it was asked for.

To make that work, a concrete impl that presents more than one interface view declares one
`CachedCAbiHandle` field **per view**, each with its own `get_c_abi_handle` implementation
returning its own box. e.g. `GuardConditionImpl` boxes as `GuardCondition` via `gc_c_abi`
and as `Condition` via a separate `cond_c_abi` — two addresses for one object, by design.

This is invisible until an API needs **cross-view identity**. `WaitSet.wait()` /
`get_conditions()` is the first: they always return conditions boxed as base `Condition`, so
an application holding a `GuardCondition` it attached earlier cannot recognise it in the
result by handle / wrapper-pointer comparison — only by re-deriving identity out of band
(checking each held condition's own `get_trigger_value()`). All four `waitset` example ports
worked around this at the application layer.

### Why raw-pointer reinterpretation can't fix it

zidl flattens an interface's `Vtable` as `[ops (bases-first, own last), attrs, deinit,
get_c_abi_handle, as_{Base}...]`. Because `deinit` / `get_c_abi_handle` / `as_Base` are
appended *after* all ops including a derived interface's own, they land at different offsets
for a base vs. any derived interface that adds even one op — the norm, not the exception
(`GuardCondition` adds `set_trigger_value`, `ReadCondition` adds four members, …).
Reinterpreting a `GuardCondition.Vtable*` as a `Condition.Vtable*` and calling `.deinit()`
through it would invoke `set_trigger_value` with the wrong signature — silent memory
corruption. This is the same hazard `emitInterface`'s own comment already calls out for
secondary bases; it applies to *every* base once trailing synthetic slots are accounted for.

## The design: a boxing-only "Views" indirection

Leave the flat `Vtable` structs and every ordinary `.vtable.op(...)` call site untouched.
This only touches `get_c_abi_handle` and the box/unbox boundary.

Per `@shared_c_abi_box`-annotated interface `I`, generate a second tiny struct:

- root interface (no base): `IViews = extern struct { flat_vtable: *const I.Vtable }`
- single-base interface (base `B`): `IViews = extern struct { base: BViews, flat_vtable: *const I.Vtable }`

An `extern struct`'s first field is always at offset 0, so nesting composes: for any
ancestor `A` reachable by always following the primary/first-listed base, `@ptrCast`-ing a
`*const LeafViews` to `*const AViews` and reading `.flat_vtable` lands on the correct, unique
storage for `A`'s own flat vtable pointer, regardless of depth. Verified for the whole
Condition chain (`Condition <- {GuardCondition, StatusCondition, ReadCondition} <-
QueryCondition`, all single-base) and by a 5-test Zig 0.16.0 spike checking `@offsetOf` and
the exact `*anyopaque` type-erasure round-trip `unboxAsView` performs.

A concrete impl then needs exactly **one** `CachedCAbiHandle` field and one static
`LeafViews` instance; every ancestor view's `get_c_abi_handle` slot calls the same cache
with the same `ptr` / `&leaf_views`. Unboxing changes from "reinterpret `box.vtable` as
`T.Vtable`" to "reinterpret as `T.CAbiViews`, then read `.flat_vtable` back out" —
everything downstream (the actual op dispatch) is unchanged.

### Opt-in, not a flag-day

`v0.3.5` added a separate `zidl_rt.unboxAsView` alongside the unchanged `unboxAs`, and a new
`@shared_c_abi_box` IDL annotation (`src/ir/types.zig`'s `hasSharedCAbiBox`, mirroring
`@callback`/`isCallbackInterface`). The Zig backend emits the nested `CAbiViews` type only
for annotated interfaces and picks `unboxAs` vs `unboxAsView` **per call site** based on the
*target* interface's annotation, not the enclosing operation's — necessary because e.g.
`WaitSet.attach_condition`'s own interface isn't annotated but its `Condition` parameter is.
Without this, converting even 5 interfaces would have forced every other concrete impl onto
the new box representation in one change.

### Free propagation to C++ / Java

C++'s `_getOrCreate` and Java's box cache key off the raw C-ABI pointer *value*. Once the
Zig-side box is unified, both start returning the same wrapper for every view — the whole
reason to fix this at the root rather than patch each binding's wrapper layer. `v0.3.5`
also landed the companion work:

- **C++ shared-family `_getOrCreate`.** `interface.sharedCAbiBoxFamilyRoot` /
  `collectSharedCAbiBoxFamilies` (mirrors the Zig-side primary-base-chain walk). A family
  with >1 member shares ONE cache, owned by the root class, exposed via Meyer's-singleton
  `_familyMutex()`/`_familyCache()` accessors. The root's `_getOrCreate` return type becomes
  `shared_ptr<RootIface>` (a hit may be a sibling); non-root siblings consult the root cache
  and recover their concrete type via `dynamic_pointer_cast`. 4 real families fell out of
  zzdds's IDL: `Condition` (5), `Entity` (7, → 11 with `zzdds.idl`), `TopicDescription` (2),
  `DomainParticipantFactory` (2). Generated header now unconditionally includes
  `<mutex>`/`<unordered_map>` (the accessor declarations need complete types).
- **Java native weak-global-ref box cache.** Java had *no* wrapper-identity cache at all
  (not even per-type); every handle crossing in allocated a fresh object with no
  `equals()`/`hashCode()`. `zidl_java_box_<c_name>` now consults a per-family
  weak-global-ref cache.

## Known limitations / open items

- **Secondary bases** (`Topic`'s `TopicDescription` view) don't get the nesting trick and
  keep an independently-cached box — permanent, see `decisions.md`.
- **Embedded-substruct impls.** `QueryConditionImpl` embeds a `ReadConditionImpl` by value;
  the natural pointer for its `ReadCondition`/`Condition` views is `&qc.rc`, a different
  address than `&qc`. A shared box must pick one canonical `ptr` (`&qc`) and have the leaf
  dispatch functions do their own offset math — same shape as the `owner_qc` back-pointer
  fix. Needs its own pass when a family is converted.
- **`DDS_ReadCondition_as_DDS_QueryCondition`** still returns null — a distinguishing signal
  now exists post-fix, but the downcast is deliberately left unimplemented.
- **Phase rollout.** Phase 1 = the Condition family. Extending `@shared_c_abi_box` to the
  `Entity` / `TopicDescription` / `DomainParticipantFactory` families is open follow-on work.
- **Listener trampolines** may carry a latent version of the same cross-view identity gap
  (listener-delivered entity args go through `_getOrCreate`-style wrapping); not confirmed,
  not investigated.
