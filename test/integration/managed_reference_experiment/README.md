# Experimental generated managed-reference bridge

Run from the zidl root after building the generator:

```
ZIDL_EXE=/absolute/path/to/zidl ZIG_EXE=/absolute/path/to/zig \
  bash test/integration/managed_reference_experiment/run.sh
```

This is a narrow opt-in experiment, not a supported ABI. The annotation is
`@experimental_managed_reference`; the proposed production `@managed_reference`
annotation is not implemented. C and Zig generation support only standalone interfaces
with IDL long operations taking no parameters or one same-interface inout reference,
no attributes, inheritance or nested types,
and require --generate-interfaces --no-typesupport. C++ and Java reject the experiment.
Experimental @experimental_managed_config structs may contain direct managed-reference
fields only (no inheritance, optional fields, arrays, prefixes or TOML mode). Other
aggregate shapes and operation parameters/results are unsupported;
those conversions are not part of this path. The experiment does not promise complete
schema-wide rejection of such uses yet.

A C-owned descriptor supplies owner/adjusted target and C-callable retain/release and
operation hooks. The generator emits C declarations and Zig C-ABI exports. A C test
links the compiled Zig object and checks adjusted dispatch, config-to-entity retention,
failed retain leaving the destination empty, self-assignment, callback retention after
logical deletion, and exactly one final release. Counts are application fixture state;
there are no heap allocations. The test's root shim explicitly references exported
module declarations to force Zig's lazy analysis.

Not implemented: version/size negotiation, canonical identity/query_view, owning native
Zig wrapper, general aggregate conversion, general inout references, threading, allocator faults,
TOML exclusion or managed-language wrappers. The inout experiment uses direct pointer-to-handle
forwarding; it does not implement generic native fat-view or Java holder conversion. Descriptor layout is deliberately temporary.
The fixture proves a generated bridge can balance ownership independently of DDS; it
is not the complete provider proposed in the design documents. Run separately; this
experiment is not yet part of the default test graph.

The replacement operation verifies nil-to-owned output, failure preserving the old
slot, replacement of an existing owned reference, and a provider-defined nonzero
status accompanying a changed output. The bridge forwards that result without
interpreting status; the provider uses generated assignment to balance ownership.

The generated Config now has nullable C-compatible reference fields and exported
init/set/clone/fini helpers. Its C test calls the emitted Zig helpers, checks nil
defaults, retained field assignment, partial clone rollback after one successful
retain, cloned adjusted-view dispatch, clearing a field and idempotent empty cleanup.
This descriptor-pointer Config does not fix legacy native-fat-view aggregate conversion.
