# Minimal managed-reference provider contract

Status: provider proposal, 2026-09-16. The opaque C handle / owning-slot helper and
Zig owner/borrow representation direction is accepted. This document proposes its
implementation seam, not exported ABI layout or annotation spelling.

## Minimum operations

A provider implements four operations for protected, non-nil managed handles. Generated
helpers handle nil before entering the provider. These are runtime bridge operations,
not methods inserted into the application's IDL interface.

| Operation | Input protection | Result and obligation |
| --- | --- | --- |
| retain | Existing owned reference or protected borrow | Adds one obligation on this view; no normal allocation; failure leaves count unchanged |
| release | One owned obligation | Consumes exactly that obligation; no recoverable failure result |
| identity | Protected view | Borrowed canonical identity token, equal across supported views of one object lifetime |
| query_view | Protected view and generated interface identifier | On success returns the requested adjusted view with one owned obligation; on failure returns nil and acquires nothing |

Keep query_view's public provider result owned, including when requesting the same
view. That avoids a flag selecting borrowed versus owned behavior on every lookup.
Generated native upcasts can still use statically safe borrowed views while protected
by their input; they are not extra provider operations in this first version.

Retain may report reference-capacity exhaustion (including checked counter overflow),
but does not allocate a wrapper or lazily construct a view. New view descriptor
allocation, if needed, belongs to query_view. Require unsupported-view and allocation/
capacity failures to be distinguishable. A small generic bridge result domain suffices;
DDS ReturnCode and codec codes remain separate. Invalid provider ABI is diagnosed at
registration/construction, not guessed from bytes behind arbitrary handles.

## Identity and view storage

Canonical identity is an opaque token scoped to a provider/core lifetime, not a wire
identifier or interface pointer. The implementation may use a protected control-block
address. Equality is meaningful while the compared references are protected; caches
must not retain an unprotected address and mistake later address reuse for identity.
A weak cache requires a separate safe acquisition protocol and generation protection,
or an independently retained anchor. Weak-reference support is not part of these four
operations and must not be improvised by retaining a dead pointer.

query_view resolves a generated stable interface identifier, validates support and
returns the correctly adjusted implementation/dispatch view. Interface identifiers
need a version/fingerprint policy before ABI freeze; short interface names alone are
insufficient across unrelated IDL products. An unsupported cast fails cleanly. Primary
and secondary views share canonical identity without requiring equal C handle values.

Each acquired view must remain dispatchable until its corresponding reference is
released, subject to the object's logical API state. Providers may preallocate views
or cache lazily allocated descriptors; either way descriptors must not leak after
all references retire. No interface-vtable reinterpretation substitutes for adjustment.
The provider descriptor and its code module outlive every handle and final release.

## Final release

The final release destroys or transfers the last storage obligation according to the
provider's resource contract. It cannot throw across C, require an allocation that
might fail, or ask the caller to retry a consumed release. If cleanup needs another
thread, environment or event loop, reserve and retain that obligation before the last
external reference can disappear. Provider context, allocator state and code remain
alive until the deferred cleanup completes.

This rule does not require a universal reaper, force synchronous destruction, or
promise a bounded destructor duration. Providers declare their execution requirements
when constructed; unsupported binding/backend combinations fail before publication.
Generated code must call release outside wrapper-cache/metadata locks and reset the
owning slot first where required for reentrant cleanup. Callers cannot touch the released
handle afterwards merely because another owner might exist.

Generic release does not perform a DDS delete operation. Consumer-defined lifetime
objects may release their own still-held operational lease as a finalizer, but reference
retention itself does not acquire another operational lease. Logical close and storage
retention remain independent.

## Generated helper composition

Assignment to an owning slot first retains the borrowed new value, saves the old value,
publishes the new value and releases the old obligation. If retain fails, the slot is
unchanged. Nil is handled without invoking provider hooks. Explicit self-assignment
may be a no-op when handle/view equality establishes it safely.

Move requires no provider retain; clear the source and publish the transferred owner
before releasing any old destination. Clone of a Config retains each managed reference
and clones owned containers; failure unwinds completed acquisitions in reverse order.
None of these operations makes concurrent mutation of the same slot legal.

An owned result crossing into a wrapper cache carries one obligation even on a cache
hit. If an existing protected wrapper will be returned, release the redundant transfer
exactly once. A miss adopts it only after wrapper construction succeeds; otherwise
release it. The cache cannot count as protection merely because it stores a pointer.

## Out of scope and compatibility

Do not add generic close, operational-owner acquisition, resource waiting, allocation
selection, equality of application values, or success-code interpretation to this
provider. Those are consumer methods or separate construction policies. Keep private
bridge signatures/versioned descriptors distinct from existing EntityBox; no legacy
handle is probed for managed hooks at runtime.

No public per-call ownership parameters are introduced. The application opts a new
interface into managed lifetime and its implementation supplies a provider once.
Unannotated legacy interfaces retain existing lifetime behavior.

## Bounded validation before layout freeze

Use one non-DDS reference object with two views requiring pointer adjustment, one
owning Config and counted finalization. Check:

* Nil, assignment, same-view assignment, move and clone balance obligations.
* Failed retain/query/aggregate allocation leaves valid prior state and no leaks.
* Both views compare equal by canonical identity but dispatch correctly.
* A transferred result hitting a wrapper cache is released or adopted once.
* Final release outside cache locks can reenter unrelated APIs without deadlock.
* Concurrent independently owned references retire exactly once; borrowed lookup does
  not race final release without an anchor.

A scalar model is unnecessary for straightforward count accounting. Actual C/Zig and
managed-binding fixtures are needed for layout, adjustment, JNI and exception behavior.
Next agree this provider scope, then select generic lifetime metadata and a versioned
ABI sketch together with those fixtures. Plugin architecture remains deferred.

The [annotation/ABI sketch](managed-reference-abi-draft.md) supplies a proposed
opt-in and provider boundary, with a passing hand-written C ownership fixture.
This does not yet validate actual generator output or managed-language lifetimes.
