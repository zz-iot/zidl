# Managed references and construction-only configuration

This contract specifies generic zidl support for IDL-defined APIs whose implementation
sits behind a common C ABI and exposes reference objects that are not DDS entities. It
also specifies configuration structs that combine serializable scalar settings with
process-local references. It is an implementation baseline: annotation spellings,
exported layouts and provider ABI versions are not frozen. Current evidence is limited
to the experiment described in [Current experimental support](#current-experimental-support).

## Scope and responsibility

zidl owns representation, conversion, interface-view adaptation, declared reference
transfer and error-safe generated cleanup. Consumers own operational meaning: what an
object's lifetime or lease means, when it closes, what a configuration value selects
and whether an operation committed. The generator must never recognize a consumer type
name (for example zzdds `RuntimeOwner`, `RuntimeRef` or `ListenerGroup`) to implement
semantics.

zzdds's concurrency extension surface is the motivating consumer. It needs these
mechanisms for its advanced extension objects only: explicit runtime owners and refs,
listener groups, resource scopes, and Configs carrying them. zzdds's first shipped subset
uses scalar Config creation and ordinary DDS entity APIs. It does not depend on this
work. Plugin extraction, new language backends and a general RPC framework are out of
scope.

## Requirement convention

Declarative obligations and imperatives ("must", "never", "do not", "use", "require")
constrain conforming generator output and providers. "May" permits an option. Paragraphs
labelled **Conforming approach** describe one permitted implementation. **Rationale**
explains without adding guarantees. "Prefer" and "should" are recommendations.
[Open design items](#open-design-items) must be resolved before the affected surface is
published as supported.

## Concepts

Keep three concepts independent:

| Concept | Meaning |
| --- | --- |
| Identity | Which object and object lifetime a reference denotes; shared across that object's interface views |
| Storage retention | What remains valid (control block, view descriptor, provider code) while a reference is held |
| Application state | Whether the object is open, stopped, leased, deleted or usable, which is consumer-defined |

A managed reference keeps consumer-defined storage valid. It does not keep a service
operational, resurrect a closed object or authorize access after logical close. Releasing
a reference is not a call to an IDL method named `release`, `close` or `deinit`. Closing
a DDS entity and releasing a language wrapper remain separate operations.

## Opt-in and compatibility

New interfaces opt in to managed lifetime through an explicit interface annotation.
The proposed spelling is `@managed_reference`; the current experiment uses
`@experimental_managed_reference`. Unannotated interfaces keep their existing ABI and
lifetime behavior. Management is never inferred from an interface name, a `release`
method or `@shared_c_abi_box`, which continues to mean boxing and view identity only.

- A managed inheritance family uses one compatible lifetime provider. Reject mixing
  managed and legacy bases unless an explicit adapter is declared.
- Implementing a managed interface alongside a legacy interface on one native object
  does not migrate the legacy interface's ABI.
- Reject `@callback` combined with managed-reference opt-in until a separate mapping
  is specified.
- Do not append ownership hooks to legacy `EntityBox`, or reinterpret legacy handles
  as owned. Legacy and managed handles dispatch through generation-time known ABI
  families; never probe memory for a version marker.
- No generated wrapper deletes a DDS entity on last reference release.

## Transfer rules

| Position | Default | Obligation |
| --- | --- | --- |
| Receiver and `in` parameter | Borrowed for the synchronous call | Caller protects lifetime; the callee retains explicitly before storing or queueing |
| Return or `out` reference | One owned reference transferred to the caller | Result wrapper adopts it; failed boxing releases it |
| `inout` reference | Old value borrowed on entry; owned replacement published on success | Stage the replacement, then release exactly the caller's old owned slot |
| Reference field in an owning aggregate | Owns one reference per non-nil field | Clone retains; destruction releases |
| Sequence/array element in an owning aggregate | Owns one reference per non-nil slot | Container ownership and element ownership are separate obligations |
| Owning aggregate passed as `in` | Borrowed aggregate and elements | No implicit operational acquisition; keeping a copy requires explicit clone |

The same identity in two slots carries two independent obligations. Reference counting
does not solve cycles: consumer contracts must avoid them or specify an explicit cycle
strategy; zidl provides no tracing collection across the C ABI.

Nil owns no reference. Destroying an initialized empty value is harmless. Calling
through a freed raw handle is not made safe by idempotent wrapper cleanup. Borrowed
outputs require an explicit opt-in with a retainable enclosing anchor; reject the
declaration if no binding can represent it safely. Consuming/move-only inputs are
deferred.

Retaining an already protected reference must not allocate. It may fail only on checked
reference-capacity exhaustion, and must never wrap. Boxing, aggregate clone and foreign
wrapper creation remain fallible. Lookup by a raw handle followed by an unprotected
retain is invalid: acquisition must occur under an anchor or registry that protects it.
Thread-safe retention is required wherever the selected profile permits concurrent use.
A proven single-thread profile may specialize it; that does not grant interrupt safety.

## Output publication and failure

- Generate private staging for `out`/`inout`. Plain `out` slots start empty or use an
  explicit initialized holder; never guess whether arbitrary C memory owns a handle.
- After successful publication, release exactly the old slot's ownership. On failure,
  drop staged ownership and preserve the old slot.
- Generic IDL cannot infer application success from an integer return. Never treat zero
  or `DDS_RETCODE_OK` as universal success. Operation implementations define their
  outputs, including on status-returning failure; generated adapters preserve declared
  direction, ownership and exception-safe cleanup. Status-dependent publication metadata
  is deferred. A consumer operation may impose its own precondition, such as an empty
  output slot, but that is not universal `inout` behavior.
- For constructors of legacy DDS entities, dropping an unpublished result box is not
  construction rollback; those need a provider-specific unpublished-result cleanup path.
- Prepare fallible conversions before invoking the core. Never invoke the core with
  nil or empty substitutes after conversion failure. An output-boxing failure after the
  core committed must release acquired references and must not repeat the operation.
- Reject detectable aliasing between mutable output slots; document non-aliasing for
  raw C output storage. Never release the same original slot twice.
- Java replaceable outputs need a generated holder or result mapping; passing an object
  reference by value is not output replacement. Choose one mapping consistently.
- Cleanup must not require allocating diagnostics. C++ exceptions and pending Java
  exceptions never cross the C ABI.

## Representation

**C.** Use one opaque, nullable handle type per managed interface, with `NULL` as nil.
Ordinary operations borrow handles; there are no per-call ownership arguments and no
ownership bit in handles. Ownership belongs to slots. Generated helpers operate on owned
slots:

```c
/* Illustrative names; not frozen API. */
ZidlResult Group_ref_assign(Group *initialized_owned_slot, Group borrowed);
void Group_ref_clear(Group *initialized_owned_slot);
void Group_ref_move(Group *initialized_owned_dst, Group *initialized_owned_src);

void ReaderConfig_init(ReaderConfig *uninitialized_storage);
ZidlResult ReaderConfig_set_group(ReaderConfig *initialized_config, Group borrowed);
ZidlResult ReaderConfig_clone(ReaderConfig *empty_dst, const ReaderConfig *src);
void ReaderConfig_move(ReaderConfig *initialized_dst, ReaderConfig *initialized_src);
void ReaderConfig_fini(ReaderConfig *initialized_config);
```

- **Assign** retains the new value before releasing the old one, so self-assignment is
  safe. On failure the slot is unchanged. Nil assignment clears.
- **Clear** publishes nil before final-release code runs.
- **Move** transfers without retaining and clears its source.
- **Fini** resets owning fields before releasing them; repeating it on an empty value is
  harmless.
- **Clone** requires an empty initialized destination, stages all fallible work and
  unwinds completed acquisitions in reverse order on failure.
- Raw C struct assignment is a shallow alias, not a second ownership obligation.
- None of these helpers makes concurrent mutation of one slot or Config legal.

`ZidlResult` is a small generic bridge result domain, not a DDS `ReturnCode_t` and not
the CDR codec codes. It must at least distinguish success, capacity exhaustion,
unsupported view and allocation failure. Its concrete values are an open item.

**Zig.** Provide explicit owner and borrow wrappers. The borrow method returns a scoped
interface view; retain/clone returns a new owner. A nil borrowed view must be recognizable
without touching an undefined vtable. Final layout preserves existing native interface
conventions; owning wrappers need not be extern structs.

**C++ and Java.** Wrappers implement equivalent shared lifetime with their own ownership
machinery. Wrapper aliases may share one native anchor. A transferred reference that hits
a wrapper cache is either adopted by a new owner or released once after securing the
existing wrapper; a weak cache entry is not protection. Java additionally balances JNI
references; deterministic close invalidates that wrapper while other owners stay valid.

## Provider contract

A provider supplies four runtime bridge operations for protected, non-nil handles.
Generated helpers handle nil before calling it. These are not methods added to the
application's IDL interface.

| Operation | Input | Result and obligation |
| --- | --- | --- |
| retain | Owned reference or protected borrow | Adds one obligation; no normal allocation; failure leaves count unchanged |
| release | One owned obligation | Consumes exactly that obligation; no recoverable failure |
| identity | Protected view | Borrowed canonical identity token, equal across supported views of one object lifetime |
| query_view | Protected view plus generated interface identifier | On success, the adjusted view with one owned obligation; on failure, nil with nothing acquired |

- Identity tokens are scoped to a provider/core lifetime. They are not wire identifiers
  or interface pointers, and are meaningful only while the compared references are
  protected. A cache must not retain an unprotected address. Weak references are not
  part of this contract.
- `query_view` performs the correct pointer adjustment for secondary views. It never
  reinterprets an unrelated vtable to preserve handle-address equality. Views may be
  preallocated or lazily allocated, but must not leak after the last reference retires.
- The provider descriptor and its code module outlive every handle and final release.
- Final release destroys or transfers the last storage obligation. It must not throw
  across C, require a fallible allocation, or ask the caller to retry. Generated code
  calls release outside wrapper-cache and metadata locks and resets the owning slot
  first. Deferred cleanup that needs another thread, environment or loop must be
  reserved and retained before the last external reference can disappear.
- Generic release performs no DDS delete. A consumer may release its own still-held
  operational lease as a finalizer; reference retention never acquires one.

**Conforming approach — view descriptor.** A managed handle resolves to a provider-owned
descriptor containing the versioned provider, owner context, adjusted target and
interface dispatch. The descriptor is an implementation seam, not a public struct that
applications allocate or modify. A versioned registration path validates provider size,
version and required hooks before any handle escapes. Interface dispatch layout is
versioned together with the interface identifier, not only the lifetime hooks.

```c
struct ManagedView {
    const ManagedProviderV1 *provider;
    void *owner_context;
    void *adjusted_target;
    const void *interface_dispatch;
};
```

## Construction-only configuration

Construction Configs keep the consumer's `*_ex(..., Config)` pattern. They distinguish
serializable settings from process-local references through explicit member metadata.
The proposed spelling is `@construction_only`; do not repurpose an OMG annotation
without checking its meaning.

- Defaults initialize scalars to schema defaults, references to nil and containers to
  safely destructible empty values. Unsupported ordinary field types produce a clear
  diagnostic rather than disappearing from configuration.
- File (TOML) overlays change only serializable settings. They preserve programmatic
  references, and fail with a field-path diagnostic if a file addresses a
  construction-only field, including nested ones. File loading never manufactures a
  pointer, lease or native identity. A nested struct is not by itself an exclusion
  mechanism.
- Overlay application stages and validates before publishing: parse, conversion,
  validation or allocation failure leaves the existing Config unchanged. Callers
  serialize access to the Config.
- Types containing construction-only members are rejected for wire/CDR/type-object
  generation in this version. A future explicit serializable projection is separate
  work; silently omitting fields from a wire type is forbidden.
- Clone and destruction follow each field's declared policy recursively, including
  strings and nested containers, with partial-clone cleanup.

## Required generator corrections

These gaps were found by generating a design probe containing an interface field, a
sequence of interfaces, a Config input and an inout interface output. Each needs a
minimal non-DDS regression when fixed.

| Finding | Required correction |
| --- | --- |
| Zig interface field defaults are undefined, while other bindings initialize absent references | Explicit safe nullable-reference representation and default; never dereference a fabricated nil vtable |
| C `inout` interface is pointer-to-handle, but Zig export and Java emission pass the reference by value | Preserve output replacement semantics through the native and language bridges |
| The Zig C-ABI aggregate mirror copies a native interface view where C declares an opaque handle | Convert each field using its declared interface view and match C layout/alignment |
| Sequence conversion substitutes an empty sequence after allocation failure | Propagate the failure with cleanup; never pass a semantically different successful input |

No silent layout changes to established C structs, callback tables or shared boxes.
Generated headers and core exports must agree on pointer depth, nullability, sequence
layout and reference transfer. Unsupported combinations are rejected clearly until the
implementation meets this contract.

## Current experimental support

`src/backend/managed_reference_experiment.zig` implements a narrow C/Zig path, which
C++ and Java reject. It requires `--generate-interfaces --no-typesupport`.

- `@experimental_managed_reference` standalone interfaces are supported, with `long`
  operations taking no parameters or one same-interface `inout` reference.
- `@experimental_managed_config` structs are supported, containing direct
  managed-reference fields only, with generated init/set/clone/fini helpers.
- Unsupported: version negotiation, canonical identity/`query_view`, owning native Zig
  wrappers, general aggregates, sequences, mixed scalar settings, TOML exclusion,
  threading, allocator faults and managed-language wrappers.

The descriptor layout is temporary. [The integration fixture](../../test/integration/managed_reference_experiment/README.md)
covers adjusted dispatch, retention, `inout` replacement, partial clone rollback and
exactly-once final release. [The hand-written C probe](probes/managed_reference.c)
checks two adjusted views, one canonical identity and rollback of a failed second
retain. Neither is a supported ABI or evidence for the full provider contract.

## Open design items

| Item | Required resolution |
| --- | --- |
| Annotation spellings | Choose final `@managed_reference` and `@construction_only` names and semantic validation rules, and specify the promotion/renaming path from the experimental annotations |
| Interface identity | Namespace-qualified interface identifier plus an ABI fingerprint over canonicalized signatures, inherited views and binding ABI version. Covers collision handling and upgrade policy; a hash alone never claims cross-target compatibility |
| Bridge result domain | Concrete `ZidlResult` values and their C/Zig/C++/Java mappings |
| Java replaceable outputs | Holder or result-object mapping, consistent across all generated operations |
| Borrowed outputs and moves | Whether to support anchored borrowed outputs or move-only inputs, and their declaration syntax |

## Acceptance criteria

Before any part of this surface is published as supported, compile and execute minimal
non-DDS fixtures across C, Zig, C++ and Java. Use a reference implementation with
explicit retain/release counters. The fixtures must cover:

- nil defaults;
- reference fields, arrays and sequences;
- `inout` replacement;
- base and secondary interface views with pointer adjustment;
- wrapper aliases and cache hits;
- partial conversion and allocation failure;
- cleanup counts and concurrent final release;
- serializable versus construction-only Config behavior, including TOML overlays.

Allocation faults before core entry must show zero core calls. Faults after core commit
must show cleanup without repeating the operation. Native and JVM cleanup must be valid
with exceptions pending. Compile-only or golden fixtures complement but do not replace
these runtime checks. Add a separate zzdds configuration fixture for its actual build
flags and default construction path.
