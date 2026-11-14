# C++ split namespaces

Per-type split headers now emit declarations inside their enclosing IDL module
namespaces. Includes remain at file scope, so dependency headers cannot be
accidentally nested into the current module. Qualified aliases and references
retain the same spelling as single-file output, including reopened/nested
modules and equal simple names in different modules.

Codec declarations remain at file scope with C linkage, matching the ordinary
header and codec definitions. Split union array headers also include the cstring
header required by their inline assignment helpers. Generated split bindings and
their consumers must be rebuilt together because previous split codec symbols
used C++ linkage. No serialized representation changes.

`test-cpp-split-namespaces` compiles and links single/split STL/PMR consumers,
with nested namespaces, cross-module aliases and aggregates, owning mutable
unions, sequences, independent same-named types and top-level dependencies.
Each generated codec translation unit includes its own per-type header.
Tests round-trip supported representations and both byte orders, and explicitly
redeclare a codec with C linkage to detect mismatched linkage.

This slice repairs IDL module scoping. It does not extend the independent
`--cpp-namespace` outer-wrapper option or interface adaptation capabilities.
