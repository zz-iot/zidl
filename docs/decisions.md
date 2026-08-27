# zidl — Design Decisions

Stable decisions with rationale. These are invariants that new code should not
inadvertently violate. For current status see [`implementation_status.md`](implementation_status.md);
for planned work see [`roadmap.md`](roadmap.md); for shipped changes see
[`../CHANGELOG.md`](../CHANGELOG.md).

---

## CDR runtime

**The user-supplied CDR allocator (`zidl_cdr_set_allocator`) is process-wide, not
per-reader.** A decoded unbounded `string`/`sequence` field is later freed by a generated
`{Type}_free()`-adjacent function that has no `ZidlCdrReader` or other per-call context in
scope — there is nowhere to record "which allocator made this" without growing every
generated struct with an extra field (an ABI break) or changing every `_free()` call site's
signature. A single global set once at startup (SQLite's `sqlite3_config` model) avoids
both. The accepted limitation: two topic types, or two participants, cannot use two
different CDR-layer allocators. Whether a DDS implementation needs this un-closed is an open
roadmap design task (allocator scoping).

**`zidl_cdr_free_str` / `_free_wstr` reconstruct the original allocation size.** A bare
`char *` / `uint16_t *` field has nowhere to store its length, so `_free_str` uses
`strlen(s) + 1` and `_free_wstr` scans to the NUL wchar. This is exact, not approximate,
because `zidl_cdr_read_string` rejects any decoded content with an embedded NUL before the
final one — so a size-class or slab allocator never receives a short size on free. Sequence
frees use the already-stored `_maximum * sizeof(elem)`.

**Every `zidl_cdr_alloc` call requests 8-byte alignment** — provably sufficient for any IDL
scalar, and cheap enough that per-type alignment tracking isn't worth it.

## Backend policy

**IDL `interface`/`impl` policy is not baked into zidl core — until a plugin architecture
exists, it lands as blind mechanism-only flags.** `--cpp-impl-override` / `--cpp-impl-include`
substitute a concrete class name without zidl parsing or validating a second IDL file.
Inferring "which concrete class backs interface X" from another IDL file is exactly the kind
of policy a future implementation-owned plugin should own; building it into core now would
have to be unwound later. See roadmap "Plugin architecture".

**Cross-module flattening is scoped to `@callback` interfaces only.** `ir.build` fills an
imported unit's own skeletons from its own AST (`buildWithImportedUnits`/`ImportedUnit`) so a
`@callback interface` inheriting a cross-module base gets its real member list. Entity
interfaces share the same flattening code (`collectInterfaceMembers`) but
`resetNonCallbackInterfaces` undoes the fill for them, because they rely on it never having
real cross-module content (native Zig vtable literals, C++'s `nativeHandleBase`
single-candidate assumption). Making cross-module entity-interface content work is separate,
unscoped work.

**Transitive imports are unsupported pipeline-wide.** `main.zig`'s `processFile` only scans
the primary file's own top-level `import_dcl`s; `fillFromImportedAst` only fills directly
imported units. A file that has its own imports fails semantic analysis the moment it is
used as anyone's import. This is a pre-existing whole-pipeline property, not a local backend
gap.

**PL_CDR (RTPS ParameterList) codegen is Zig-backend-only, by design.** `--zig-pl-cdr` is
ignored by every other backend, and that is correct: RTPS wire-level SPDP/SEDP encode/decode
runs entirely inside a DDS implementation's Zig core and never crosses the C-ABI. By the
time a binding sees discovery data it is an ordinary decoded `@final` struct. Re-raise only
if a non-Zig program needs to implement RTPS wire discovery directly.

**`--c-no-free` is scoped to `{Type}_free` only, not folded into `--no-typesupport`.**
`serialize`/`deserialize`/`skip` had no symbol collision to avoid in the motivating case
(a consumer that already exports `{Type}_free` from elsewhere); suppressing them too would
be a bigger hammer than the problem.

## C-ABI entity identity

**C-ABI cross-view identity is fixed at the box representation, not with a return-side
type-recovery cascade.** A parallel "try each concrete subclass" cascade for return values
(mirroring `collectBaseImplementors` for parameters) would duplicate machinery to solve a
problem better solved by not creating divergent boxes. Instead, `@shared_c_abi_box`-annotated
interfaces emit a nested `CAbiViews` struct so every primary-base ancestor view shares one
cached box; `unboxAsView` reads `.flat_vtable` back out. C++'s `_getOrCreate` and Java's box
cache then get unified identity for free because they key off the (now-identical) raw handle
value. See `design/binding-c-abi-identity.md`.

**Secondary bases do not get shared-box identity.** `Topic : Entity, TopicDescription` —
`TopicDescription` is the second listed base, so `Topic` keeps an independently-cached box
for that view. `extern struct` first-field-at-offset-0 nesting only composes along the
primary/first-listed base chain, and raw-pointer vtable reinterpretation is unsafe across a
base boundary once trailing synthetic slots (`deinit`/`get_c_abi_handle`/`as_{Base}`) shift
offsets. Not a regression — no reported identity bug on `Topic`'s `TopicDescription` view.

**Listener registration has no shared identity across entities.** `writer.zig` (and the
other entity impls) copy a listener struct's function-pointer *values* into per-entity
storage (`listener_ex_box`); there is one storage slot per entity, always holding the wider
`Ex` shape, widened/narrowed in place. A binding's callback-object keep-alive registry must
therefore be keyed **per registration** (per `set_listener` / `create_*` call), not per
listener-object identity — a dict keyed by listener identity drops the keep-alive for the
first entity's registration while a second entity still needs it.
