# Managed-reference representation and C/Zig helpers

Status: initial representation direction accepted, 2026-09-16. No ABI, annotations or generated
code changed. Implements the semantic direction in reference-ownership-contract.md.

## Recommendation

Use one opaque, nullable C handle representation for a managed interface, with
explicit owning slot helpers. Keep ordinary call arguments borrowed. Do not add an
ownership-mode parameter to every operation and do not store an ownership bit in
every handle: ownership describes an obligation held by a slot, not a property of
the shared target pointer.

Provide a distinct owning wrapper in native Zig around a borrowed interface view,
and generated owning aggregate helpers in C. A borrowed aggregate view is only an
input view protected by its owner; it is not a second kind of heap object. Prefer
initially constructing real owning Configs through helpers rather than exposing a
second complete ConfigBorrowed struct family. This avoids multiplying public types
while leaving a later scoped zero-retain adapter possible.

C cannot prevent plain assignment of an owning struct, and Zig cannot enforce move-only
values universally. Such assignment does not create a second ownership obligation;
independent copies require clone and ownership transfer requires move. State this
explicitly; neither language's raw assignment should be advertised as safe shared
ownership. C++/Java wrappers supply their language-appropriate lifetime management.

## Illustrative helpers

Names are examples, not frozen API. A generic binding result is used where conversion
can fail; it is not a DDS ReturnCode and its concrete representation remains to be chosen.

```c
/* Borrowed input; produces one independently owned reference on success. */
ZidlResult Group_ref_assign(Group *initialized_owned_slot, Group borrowed);
void Group_ref_clear(Group *initialized_owned_slot);
void Group_ref_move(Group *initialized_owned_dst, Group *initialized_owned_src);

void ReaderConfig_init(ReaderConfig *uninitialized_storage);
ZidlResult ReaderConfig_set_group(ReaderConfig *initialized_config, Group borrowed);
ZidlResult ReaderConfig_clone(ReaderConfig *empty_dst, const ReaderConfig *src);
void ReaderConfig_move(ReaderConfig *initialized_dst, ReaderConfig *initialized_src);
void ReaderConfig_fini(ReaderConfig *initialized_config);
```

The exported create_datareader_ex signature still receives a Config in the binding's
normal representation. It borrows its input; the implementation independently retains
anything it stores. No call-site cleanup callback or ownership argument is introduced.

Assign acquires the new reference before releasing the old, so self-assignment is
safe. Nil assignment clears. Failure leaves the old slot unchanged. Clear publishes
nil before invoking final-release code, then drops exactly its old obligation. Move
transfers without retaining and clears its source; moving a slot to itself is a no-op.
Fini resets owning fields before releasing them, so reentrant observation does not
see dangling ownership. Repeated fini on the same initialized empty value is harmless;
fini on an uninitialized value or an unauthorized shallow copy is not.

Clone requires an empty initialized destination, borrows a stable source, and publishes
a complete owned clone only after all fallible work succeeds. Failure destroys partial
storage/references and leaves the destination empty. Container allocation uses the
chosen allocator; reference release uses the object's own lifetime bridge. An allocator
mismatch cannot be repaired by freeing a reference as if it were a container buffer.

Zig exposes corresponding init/clone/deinit and field replacement methods. Its owning
wrapper's borrow method returns a scoped interface view; retain/clone returns a new
owner. A nil borrowed view must be recognizable without touching an undefined vtable.
Final Zig layout must preserve existing non-managed native interface conventions;
it need not make managed owning wrappers themselves extern structs.

These helpers are not thread-safe mutations of the same Config or slot. Callers must
protect them from concurrent assignment/destruction and keep borrowed inputs stable.
Thread-safe reference counting does not make unsynchronized access to an owner safe.

## Internal bridge shape

Opt-in managed handles resolve to a stable interface-view descriptor referencing:

* A canonical identity/lifetime control object.
* The correctly adjusted implementation pointer and dispatch table for the view.
* A versioned generic lifetime/view provider (retain, release, supported-view lookup).

The provider can own its count or delegate to an existing foreign ownership mechanism;
the generator need not mandate intrusive counting inside application objects. Its hooks
must protect view descriptors and identity through the last reference and any accepted
cleanup. Allocation of descriptors/wrappers remains fallible; keeping a protected
existing reference is normally allocation-free, with checked overflow handling.

View lookup must preserve canonical identity and perform required pointer adjustment.
It can produce a borrowed view under an existing anchor or an independently retained
result. If a view descriptor requires allocation, return an explicit failure before
publishing it. Never reinterpret a secondary base as a primary base merely to preserve
the opaque handle address. Identity comparison uses canonical identity, not equality
of potentially different view handles. Identity queries themselves require live protected
references; no registry promises to make arbitrary stale raw handles safe.

The descriptor is conceptual: choose opaque/versioned provider boundaries before fixing
layout. Do not enlarge legacy EntityBox in place or assume its free function releases
the implementation. Managed and legacy handles must dispatch through generation-time
known ABI families, never by probing arbitrary memory for a magic version field.
Existing @shared_c_abi_box continues to mean boxing/view identity, not ownership opt-in.

## Aggregates and wrapper adaptation

An owning aggregate's reference fields and sequence elements each own an obligation.
Passing it as in borrows them. Native-to-C conversion may use temporary borrowed views
or owned scratch storage, but must not replace native fat views with opaque pointers
by raw struct copy. Any acquired scratch references unwind on failure.

C++ wrapper aliases may share one native ownership anchor. A newly received transferred
reference must still be accounted for when a wrapper cache hits: either adopt it into
a new owner or release the redundant transfer after securing the existing wrapper.
Weak cache entries are not lifetime protection. Java follows the same native accounting
rule in addition to JNI reference accounting; deterministic close invalidates that
wrapper's access while other separately retained owners remain valid.

None of this calls DDS delete_* on last wrapper release. A managed reference target's
provider defines finalization; application operations such as RuntimeOwner.release
remain separate from the generated ref_clear helper. The implementation may use final
reference release as fallback for an unreleased application lease, without teaching
zidl what the lease means.

## Failure and output boundary

This proposal supplies balanced reference operations, not generic transactions over
application methods. Correct out/inout pointer depth and Java holders remain required.
Operation implementations determine output state on ordinary completion, including
status-returning failure. Generated conversion must preserve those declarations and
clean up owned outputs if publication fails, without re-executing the operation.

For constructors of legacy DDS entities, dropping a result box is not necessarily
construction rollback. A provider-specific unpublished-result cleanup path is still
needed. Do not claim managed-reference helpers alone solve every factory failure.

## Choice and next step

Recommend this opaque-handle plus owning-slot-helper approach for C, and explicit
owner/borrow wrappers for Zig. The alternative is distinct public C owner and borrowed
struct types on every signature. That makes some mistakes easier to diagnose at compile
time but substantially changes the existing opaque-interface API and aggregate mapping;
it still cannot prevent all shallow copies in C.

Once this representation direction is accepted, define the smallest provider contract
and generic lifetime metadata needed for one managed interface and one owning Config.
Validate those with a tiny non-DDS core before implementing broad generator support.
The current document is a reviewable design, not evidence that these helpers exist.

The [minimal provider proposal](managed-reference-provider.md) defines retain,
release, canonical identity and owned view lookup without extra application-call
parameters. Hook layout and interface identifiers remain to be specified.
