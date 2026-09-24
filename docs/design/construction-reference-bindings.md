# Construction references and generic C-ABI binding requirements

Status: requirements draft, 2026-09-16. Generic zidl work required by zzdds concurrency
API integration. Not an annotation/ABI freeze or an implementation claim.

## Scope and responsibility

zidl must support IDL-defined APIs whose core implementation is accessed through a
common C ABI, including non-DDS reference objects. zzdds runtime owners, observers,
listener groups and resource-completion tokens are motivating clients, not generator
special cases. Other IDL products should be able to use the same mechanisms.

zidl owns representation, conversion, identity/view adaptation, declared reference
transfer and error-safe generated cleanup. Consumers define operational semantics:
what a lease owns, when an object closes, what a configuration means, and whether
an operation commits. No generator branch should recognize RuntimeOwner, ListenerGroup
or another zzdds name to implement those semantics.

Plugin extraction is a later project already tracked in the roadmap. These changes
must expose generic mechanisms compatible with eventual consumer-owned policy plugins;
they do not require a plugin loader, extension SDK or relocation of existing DDS code.

## Evidence and correctness fixes

The zzdds design probe uses an interface field, a sequence of interfaces, a Config
input and an inout interface output. On zidl 26dc737 generation succeeded, but inspection
found the following. Preserve a minimal non-DDS fixture when implementing regressions.

| Finding | Required correction |
| --- | --- |
| Zig interface field default is undefined while other bindings initialize absent references | Explicit safe nullable-reference representation/default; never dereference a fabricated nil vtable |
| C inout interface is a pointer to handle, but Zig export and Java emission pass a reference by value | Preserve output replacement semantics through the native and language bridges |
| Zig C-ABI aggregate mirror copies a native interface view where C declares an opaque handle | Convert each field using the declared interface view; match C layout/alignment |
| Sequence conversion substitutes an empty sequence after allocation failure | Propagate failure with cleanup, not a semantically different successful input |

These are correctness gaps in generated forms; generation success is insufficient
validation. The probe did not execute bindings or demonstrate a runtime crash.
Existing CDR error translation is a separate adapter concern, but must use the same
principle of explicit, fallible conversion.

## Generic capabilities

### Reference representation and transfer

Specify nullable references independently from object identity and operational
ownership. A reference can identify an object without holding a consumer-defined
operational lease. Copying an interface view is not automatically an owning acquisition.

The binding contract must distinguish borrowed call inputs, retained storage, transferred
owned outputs and borrowed outputs protected by an enclosing lifetime. Define retain
and release hooks, valid call environments, and failure behavior without interpreting
the object's application semantics. A method named release is not a generic destruction
hook merely because of its name.

Use the existing shared-box/view adaptation design where applicable. Base/derived and
multiple-inheritance views must preserve object identity while dispatching through the
correct adjusted view. Do not reinterpret vtable layouts or use wrapper addresses as
a substitute for canonical identity. New standalone references must not inherit DDS
entity deletion behavior accidentally.

C/Zig bindings need explicit lifetime operations or scoped adapters; C++/Java wrappers
must express equivalent transfers through their own ownership machinery. A Java wrapper
keeping native reference storage alive is distinct from keeping an application-defined
runtime operational. Native and JVM references must each be released exactly as owed.

For sequences/structs, container ownership and reference-element ownership are separate.
Clone/deinit must implement the declared policy recursively, with partial-clone cleanup.
They must not silently introduce operational acquisitions. Cycles are not solved by
reference counting: consumer contracts must avoid them or provide an explicit cycle
strategy; zidl does not promise tracing collection across the C ABI.

### Output and failure semantics

Support scalar, struct and sequence references in in/out/inout positions. For Java,
an explicit generated holder/result mapping is needed for replaceable outputs; passing
an object reference by value cannot replace the caller's variable. Choose the mapping
consistently with existing API compatibility, not independently per operation.

Prepare fallible conversions before invoking the core where possible. Do not invoke
it with nil/empty replacements after conversion failure. Output boxing failure must
release acquired references; it cannot roll back arbitrary effects already committed
by the core. Preserve the consumer's effect/result distinction and original language
exceptions where required. Do not cast internal error enums into application return codes.

For inout, specify old-value ownership, replacement publication and failure cleanup.
A generic bridge must not release a borrowed old input or assume all operations require
an empty slot. A consumer can impose an empty-output precondition, as the runtime-owner
acquisition draft does, but that is not universal IDL inout behavior. Application aliasing
restrictions must be documented and tested where output slots share storage.

### Construction-only configuration

Preserve Config-taking construction APIs while distinguishing serializable settings
from process-local references supplied programmatically. Introduce explicit schema
metadata or an equivalent generation policy for construction-only members/types.
Annotation spelling is not chosen here; do not repurpose an OMG annotation without
checking its specified meaning.

Required behavior:

* Defaults initialize absent references safely. Unsupported ordinary field types still
  produce a clear diagnostic rather than disappearing from configuration.
* TOML application applies scalar/nested serializable settings and preserves existing
  construction-only references. A file attempting to set a construction-only field
  fails explicitly, including nested paths; it must not silently ignore that entry.
* File loading never constructs a pointer, operational lease or native object identity.
  Cloning a mixed config obeys its declared reference storage policy.
* Wire/CDR/type-object generation must not serialize process-local references by
  accident. Define whether a mixed type is rejected for wire use or has an explicit
  serializable projection; silently omitting fields from an ordinary wire type is not
  an acceptable implicit policy. Concurrency constructors need no wire projection.
* Existing file-loadable participant configuration continues to work. Splitting fields
  into a nested struct alone is insufficient because applyToml descends recursively.

## Compatibility and validation

### Required aggregate and file-configuration behavior

These are production acceptance requirements; the bounded C/Zig experiment does
not implement sequences, mixed settings or TOML support.

* An owning sequence owns its element storage and one retention for each non-nil
  managed-reference slot. Duplicate identities in different slots each carry their
  own obligation. A borrowed sequence view owns neither; its source must remain
  protected for the entire borrow. A clone allocates independent storage and retains
  elements individually, preserving order, nils and adjusted interface views.
* Clone into an initialized empty destination stages all fields/elements. Allocation,
  bound-validation or retain failure releases only successfully acquired resources
  and leaves the destination empty and source unchanged. Never substitute an empty
  sequence for a failed conversion. Replacement of an existing owning aggregate
  requires a separate staged replacement operation; shallow assignment is not clone.
* A mixed Config initializes scalars to schema defaults, references to nil and
  containers to safely destructible empty values. Cloning follows each field's
  policy recursively, including ordinary allocated strings and nested containers.
  Successful destruction clears ownership and releases each obligation once;
  subsequent destruction of that empty value is harmless. These helpers do not
  grant concurrent mutation or arbitrary overlapping-storage safety.
* TOML overlays change only serializable settings. Omitted fields retain their
  current values, including programmatically supplied references. Explicit attempts
  to address a construction-only field, including a nested field, fail with a field
  path diagnostic; file content cannot manufacture handles or identities.
* Applying a TOML overlay to such a Config validates and stages serializable changes
  before publication: a parse, conversion, validation or allocation failure leaves
  the existing Config unchanged. Preserved reference fields need no new operational
  lease. This is a Config-helper guarantee, not generic status-based transaction
  handling for arbitrary IDL methods. Callers serialize access to the Config.

Mixed construction Configs containing process-local references are rejected for
wire/CDR serialization in the initial design. A future explicit serializable
projection is separate work. Unsupported backend/schema combinations must diagnose
the limitation before these APIs are offered as supported production bindings.

No silent layout changes to established C structs, callback tables or shared boxes.
Choose coordinated ABI versioning/regeneration before modifying exported layouts.
Generated headers and core exports must agree on pointer depth, nullability, sequence
layout and reference transfer. Reject unsupported generation combinations clearly
until the implementation meets the contract.

Validation must compile and execute minimal non-DDS fixtures across Zig, C, C++ and
Java/JNI. Cover nil defaults; reference fields/arrays/sequences; inout replacement;
base and secondary interface views; managed wrapper aliases; partial conversion and
allocation failure; cleanup counters; and serializable versus construction-only config.
Use a small reference implementation with explicit retain/release counters, not a DDS
runtime, so the tests demonstrate generic behavior. Add a zzdds config integration
fixture separately to verify its actual build flags and default construction path.

Allocation faults before core entry must show zero core calls. Faults after core
commit must show cleanup without repeating the operation. Native/JVM cleanup must be
valid with exceptions pending; C++ exceptions cannot escape an incompatible C frame.
Compile-only/golden fixtures complement but cannot replace these runtime checks.

## Implementation sequence and finish line

1. Fix reference output direction and aggregate ABI conversion with minimal regressions.
2. Specify generic reference transfer/default rules and implement generated cleanup.
3. Add explicit construction-only config support and rejection diagnostics.
4. Validate the combined shapes and coordinate ABI rollout with consuming applications.
5. Revisit zzdds's concrete IDL draft using the working mechanisms.

Implementation steps can overlap, but do not publish a new reference ABI before its
ownership contract is settled. The immediate next design decision is the generic
reference-lifetime/transfer declaration mechanism; spelling and layout follow that.

The concurrency specification must state this dependency and its acceptance criteria.
Production concurrency APIs cannot claim support until the binding work passes. Plugin
architecture, new language backends and a general RPC/serialization framework are not
part of this finish line. Other products' policies must not be encoded as zzdds defaults.

The [reference ownership proposal](reference-ownership-contract.md) now supplies
managed-reference opt-in, transfer defaults and staged output rules for review.
Generic status-code-driven publication metadata is deferred following API review;
operation implementations define output behavior, and generated bindings preserve
reference direction and cleanup without interpreting arbitrary result integers.
