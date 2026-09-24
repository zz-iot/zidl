# Managed-reference annotation and ABI sketch

Status: proposed, 2026-09-16. Hand-written C ownership fixture passes; this is not
implemented generator support or a frozen public ABI.

## Schema opt-in

Propose a zidl-specific @managed_reference annotation on interfaces. It selects the
new reference bridge and transfer defaults, not a consumer-specific lifetime policy.
Legacy unannotated interfaces retain their current ABI. Do not infer management from
an interface name, a release method, or @shared_c_abi_box.

A managed inheritance family must use one compatible lifetime provider. Initially
reject mixed managed/legacy base inheritance unless an explicit adapter is supplied.
An interface implemented alongside a legacy interface on the same native object does
not automatically migrate that legacy interface's ABI. Callbacks retain their separate
callback-registration contract; combining @callback and @managed_reference needs a
separate supported mapping and should initially be rejected.

Propose a separate @construction_only member annotation for runtime references in
configuration. It excludes the member from file application while preserving its
programmatic value; supplying that key in a file fails. A containing type with such
members is rejected for wire/type-object generation initially, rather than silently
creating a wire projection. Types without the annotation do not acquire these rules
merely because an unsupported field was encountered. These annotations require semantic
validation and documented recursive behavior before becoming supported syntax.

## C boundary

Application-facing managed interface types remain distinct opaque pointer typedefs.
NULL is nil. Generated operations borrow receivers/inputs; generated reference helpers
operate on owned slots. No ownership-mode argument appears on ordinary operations.

A managed handle resolves through a provider-owned view descriptor, conceptually:

```c
struct ManagedView {
    const ManagedProviderV1 *provider;
    void *owner_context;
    void *adjusted_target;
    const void *interface_dispatch;
};
```

The provider has ABI version and byte-size fields plus retain, release, identity and
query_view function pointers. query_view receives a generated interface identifier
and writes one owned view to an initially empty result slot. Failures leave nil.
The generic result domain initially distinguishes success, capacity, unsupported view
and allocation failure; exact numeric values and error representation remain open.
No exception may cross these C hooks.

A versioned construction/registration path validates provider size/version and required
hooks before a handle escapes. Dispatch is selected from declared interface metadata;
never probe arbitrary legacy handles for a magic marker. Provider code/context/view
storage remain live through final release and any deferred cleanup. Interface dispatch
layout must be versioned together with the interface identifier, not only the four
lifetime hooks. A valid-looking pointer is not proof of ABI compatibility.

This descriptor is an implementation seam, not a public struct applications allocate
or modify. Native Zig owner/borrow wrappers can reference it or a provider-supported
native view without requiring every borrowed call to allocate another box.

## Interface identity policy to settle before freeze

Use a generated interface identifier distinct from runtime object identity. Recommend
an explicit namespace-qualified interface identity plus an ABI fingerprint derived
from canonicalized signatures, inherited views and binding ABI version. A hash alone
must not silently claim compatibility across different ABI targets or incompatible
schemas. Fix canonicalization, collision handling, target/layout assumptions and
upgrade policy in the actual ABI implementation; the fixture uses trivial IDs only.

Object identity remains a protected provider-scoped token shared across views. It is
not a serialized GUID or a permanent identifier surviving final reclamation. No weak
reference support or cross-module unload protocol is implied by this sketch.

## Bounded C fixture

probes/managed_reference.c exercises a provider with two differently adjusted views,
one canonical identity and a counted logical lifetime. It checks self-assignment,
unsupported lookup, successful aggregate clone, failure of the second retain with
rollback of the first, repeated empty cleanup and exactly one final release. The
object is stack-backed test storage; finalization is counted rather than freeing it.

Run from the zidl root:

```
cc -std=c11 -Wall -Wextra -Werror -fsanitize=address,undefined -g \
  docs/design/probes/managed_reference.c -o /tmp/zidl-managed-reference-probe
ASAN_OPTIONS=detect_leaks=0 /tmp/zidl-managed-reference-probe
```

This run passed. LeakSanitizer's initial exit check failed because of the environment's
ptrace restriction, so leak detection was disabled for the rerun; ASan and UBSan remained
enabled. The fixture has no heap allocations and checks reference obligations directly.
It does not test allocation/boxing failure, concurrency, actual virtual dispatch, ABI
interoperability, generated Zig/C++/Java code or JVM lifetime. Those remain required
integration fixtures, not evidence supplied by this small test.

## Next bounded implementation step

Review the annotation/ABI direction, then implement one opt-in managed-reference
fixture through actual zidl generation before broadening support. Begin with explicit
interface IDs for that fixture while finalizing the fingerprint scheme, and include
actual adjusted dispatch plus inout replacement across C/Zig. Follow with C++/Java
wrapper ownership and construction-only TOML behavior. Keep production zzdds IDL
unchanged until the generic binding checks pass. Plugin architecture remains separate.

## Generated bridge experiment

A narrow @experimental_managed_reference C/Zig path is now implemented in
src/backend/managed_reference_experiment.zig. The
[fixture](../../test/integration/managed_reference_experiment/README.md) compiles
generated Zig exports, links a C caller, and passes adjusted dispatch and ownership
lifecycle checks. It is not the production annotation or versioned provider: identity,
view lookup, aggregates, inout and managed-language wrappers remain absent.

### Generated inout extension

The experimental path now also emits one same-interface inout reference parameter
with correct C pointer-to-handle / Zig pointer-to-nullable-handle direction. The
compiled fixture passes replacement from nil, replacement of an owned old value,
retain failure preserving that value, and provider-defined output mutation with a
nonzero result. The bridge does not interpret status codes. This direct descriptor
path does not fix legacy fat-view inout conversion or Java holder generation.

Validation: the initial bridge passed the existing `zig build test` suite (Java
tools unavailable); after adding this narrow inout path the generator rebuild and
expanded C/Zig integration fixture passed. Diff whitespace checks pass. No changes
were made to production zzdds IDL or its runtime.

### Generated Config extension

The experimental @experimental_managed_config path now emits C-compatible nullable
reference fields and generated init, retained field assignment, clone and fini exports
for C/Zig. The compiled integration fixture passes nil initialization, self-assignment,
field clearing, cloning, second-retain failure with partial-clone rollback, adjusted
view dispatch through a cloned field, and repeated empty cleanup. The fixture also
checks rejection of unsupported mixed scalar fields and TOML mode. A PIC object is
used when linking generated Zig exports into the host C executable.

This is a direct descriptor-pointer representation, not a fix for legacy aggregate
fat-view conversion. It does not yet support sequences, mixed scalar settings,
construction-only TOML members, version negotiation or managed-language wrappers.
The helper ABI is experimental and remains separate from production zzdds IDL.

After the Config extension, the expanded standalone fixture and `zig build test`
both passed. The build reported Java tooling unavailable, so this is not Java/JNI
validation. Whitespace checks also passed.
