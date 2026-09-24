# Generic interface reference ownership

Status: proposal for review, narrowed after API-impact discussion, 2026-09-16. Semantic contract first; annotation spellings,
C layout and ABI version numbers are not selected. Complements
[construction-reference requirements](construction-reference-bindings.md).

## Recommended model

Opt new interfaces into an explicit managed-reference lifetime contract. Preserve
legacy interface lifetime behavior unless deliberately migrated. @shared_c_abi_box
continues to describe identity/view boxing; it does not imply reference counting.

A managed reference keeps a consumer-defined reference target/control block valid.
It does not automatically keep the represented service operational, resurrect a
closed object or authorize resource access after logical close. The implementation
supplies retention and final-release hooks; zidl generates balanced reference transfer.

Distinguish three independent concepts:

* Identity: which object and generation the reference denotes.
* Storage retention: what must remain valid while the reference is held.
* Application state: whether the object is open, stopped, leased, deleted or usable.

Reference release is not an invocation of an arbitrary IDL method named release or
deinit. Closing a DDS entity and releasing its language wrapper remain separate.
For zzdds, a RuntimeOwner lease object can relinquish its operational lease explicitly
while its reference storage remains alive; its final-release implementation can also
release an unreleased lease. RuntimeRef holds observation storage only. zidl need not
know either policy.

## Transfer rules

For opted-in interfaces, recommend the following defaults and explicit exceptions:

| Position | Default | Obligation |
| --- | --- | --- |
| Receiver and in parameter | Borrowed for the synchronous call | Caller protects lifetime; callee retains explicitly before storing/queueing |
| Return or out reference | One owned reference transferred to caller | Result wrapper adopts it; failed boxing releases it |
| inout reference | Borrow old value on entry; publish owned replacement on success | Bridge stages replacement, then releases caller's old owned slot reference |
| Reference field in an owning aggregate | Own one reference per non-nil field | Clone retains; destruction releases |
| Sequence/array element in an owning aggregate | Own one reference per non-nil slot | Container ownership and each element's ownership are separate |
| Passing an owning aggregate as in | Borrow aggregate and its elements for the call | No implicit operational acquisition; retaining a copy uses explicit clone |

Borrowed output is an explicit opt-in exception requiring an enclosing lifetime
anchor that the binding can retain. If no such anchor can be represented safely in
all enabled bindings, reject the declaration. Do not silently promote a borrowed
output to an owning reference when that changes application semantics.

Consuming/move-only input is deferred initially: callers can lend an owned reference
and the callee can retain it. Avoid adding consumed-on-failure ambiguity to the first
contract. C/Zig assignment of an owning representation is a shallow alias, not an
implicit retain; generated clone/move/destroy helpers and documentation must make the
ownership obligation explicit. C++/Java wrappers implement equivalent shared lifetime.

Nil owns no reference. Destroying an initialized empty owning value is harmless;
calling through a freed raw handle is not made safe by idempotent wrapper cleanup.
All default aggregate/reference values must be initialized and safely destructible.
An optional receiver is still not callable without a declared nil behavior.

## Retain, release and identity

Retaining an already protected valid reference should not allocate or fail under
ordinary resource pressure. New boxes, aggregate clones and foreign wrappers remain
fallible. Counter overflow is an implementation limit that must be checked, not allowed
to wrap; define a safe limit/failure policy in the eventual bridge design.

The last release can trigger consumer-defined cleanup, outside generator metadata
locks and with the declared foreign environment. Async cleanup may retain its own
obligation, but must not resurrect an externally acquirable object. The consumer owns
progress, shutdown and allocator lifetime policy; the binding owns accurate transfer.

Versioned hooks must support safe identity and declared-interface conversion. A view
conversion borrows when scoped to a call and retains when producing an independent
owned result. A canonical identity may have different adjusted pointers/boxes for
secondary views. Never use reinterpretation of unrelated vtables to preserve pointer
equality. Existing shared-box primary-base support does not solve all secondary-base
lifetime/identity requirements.

Thread-safe retention is required when the selected profile permits concurrent use.
A proven single-thread profile may specialize it; that does not grant cross-thread
or interrupt safety. An unprotected raw handle lookup followed by retain is invalid:
lookup must return an already retained reference or occur under an anchor/registry
that protects it through acquisition.

## Output publication and failure

Generate private staging for out/inout. The callee's old inout reference is borrowed;
it must not release it as though ownership transferred on entry. An owned staged
replacement carries a separate obligation even when it identifies the same object.
After successful publication, release exactly the old slot ownership. Failure drops
staged ownership and preserves the old slot. Plain out slots must start empty or use
an explicit initialized holder; never guess whether arbitrary C memory owns a handle.

Generic IDL cannot infer application success from an integer return. Do not
special-case DDS_RETCODE_OK or treat zero as universal success. Generic status-dependent
publication annotations are deferred: operation implementations define their outputs,
while generated adapters preserve direction, declared ownership and exception-safe
cleanup. The staged replacement discussion above is a candidate managed-output
convention, not an automatic transaction over every existing IDL inout parameter.
A concrete operation may require empty output slots or publish progress on failure;
those remain explicit operation contracts.

Where final native slot publication is non-failing, stage all output conversions first.
On a foreign publication exception, preserve application effects and clean up remaining
staged references. Arbitrary application containers cannot be promised transactional
replacement. Never repeat the underlying operation to recover from a boxing failure.
Do not allocate extra diagnostics as a prerequisite for cleaning up an allocation failure.

Aliased mutable output slots require an explicit restriction or defined mapping;
initially recommend rejecting detectable aliases and documenting non-aliasing for
raw C output storage. Do not release the same original slot twice during publication.

## Existing machinery and compatibility

packages/zidl-rt/src/entity_box.zig defines EntityBox as ptr/vtable and freeEntityBox
only destroys the box, not the referenced implementation. Native interface views are
fat pointers; C handles are boxes. This machinery alone is not an owning-reference ABI.
The existing nil sentinel also requires a nil check before touching its undefined
vtable; generated default fields currently do not consistently establish even that
sentinel. Managed-reference defaults need an explicit safe representation.

Introduce a versioned managed-reference bridge rather than append ownership hooks to
legacy EntityBox and assume old providers implement them. Legacy and managed-reference
interfaces can coexist, but conversion between lifetime models must be explicit.
A struct containing both needs field-specific cleanup, not a universal free-all rule.
No generated wrapper should start deleting existing DDS entities on last reference
merely because another new interface opts into managed lifetime.

## Decision and bounded validation

Recommend explicit managed-reference opt-in, borrowed call inputs, owned aggregate
storage and owned outputs, with correct output replacement and cleanup. Generic status-dependent publication
metadata is deferred unless a concrete need emerges. The alternative is fully annotated ownership at
every use site; it offers flexibility but increases inconsistent combinations and
review burden. Defaults with explicit exceptions provide the initial smaller surface.

Before ABI design, check these defaults against concrete reference lifecycles.
Then specify the metadata and test with a tiny non-DDS core: clone/drop counts, same-
identity replacement, failed boxing, secondary view conversion, retained async input,
nil defaults and concurrent final release. No full runtime or plugin system is needed.

The zzdds listener-group walkthrough demonstrates config/entity/invocation ownership
without extra per-call ownership arguments. Managed aggregate assignment helpers and
borrowed views are the next representation question, not a generic transaction layer.

The [representation proposal](managed-reference-representation.md) makes C opaque
handles/owning-slot helpers and native Zig owner/borrow wrappers concrete. It avoids
per-call ownership parameters and preserves legacy DDS entity destruction semantics.
