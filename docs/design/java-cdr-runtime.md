# Shared Java CDR runtime

Date: 2026-11-02

Status: first extraction implemented for alignment and narrow UTF-8 strings,
with standalone `zidl-cdr-java` JAR/source builds and runtime API 1. Other helper
families and zzdds Java delivery remain follow-up work. See the
[first extraction checkpoint](java-cdr-extraction-1.md).
See the [Java CDR audit](java-cdr-audit.md) for helper inventory, observed buffer
semantics, correctness gaps, size/performance baseline and first-slice proposal.

The [Java canonical key checkpoint](java-cdr-key-slice.md) corrects generated
holder traversal and hash policy without introducing the planned shared runtime.

## Decision

Keep Java topic serialization, deserialization and object traversal in Java.
Extract reusable CDR machinery from generated outputs into a shared Java runtime
library. Continue generating schema-specific traversal and serialization methods.
Do not move Java topic serialization to the native C ABI as part of the
[shared native CDR effort](shared-native-cdr.md).

Application builds must not require a Zig or C compiler when using prebuilt zidl
and zzdds artifacts. Running a prebuilt zidl executable to generate Java is
acceptable. The Java codec should remain usable without zzdds or native codec
libraries; zzdds Java integration continues to use its native DDS bridge.

## Current implementation and historical rationale

Schema traversal and remaining helper families are maintained as emitted Java source in
`src/backend/java.zig`. Generated output uses `java.nio.ByteBuffer`, forwarding/shared and inline CDR
helpers and per-type methods. It is not implemented in a `zidl_jni` codec library.
Helpers can repeat across output files, particularly with split generation.

`docs/runtime_libraries.md`, including its initial-commit version, explicitly
favored inline Java serialization to avoid distributing/versioning a companion
runtime and a platform-specific native-library matrix. `docs/backend_java.md`
also describes the no-companion-runtime approach. Generator comments describe
incoming key hashing without a companion native implementation.

The documentation sweep found a deployment rationale, not a recorded performance
study or requirement prohibiting shared/native codecs. Some runtime-reference
claims, including proposed Rust modes, are stale and must not be treated as
implemented features. The new Java decision deliberately accepts a Java runtime
dependency to reduce duplication without adding a native codec dependency.

For zzdds users, native DDS libraries are already required. That weakens the
native-dependency argument but does not establish that native serialization will
be faster or simpler. Current Java example builds already invoke prebuilt zidl
and `javac` without compiling application-specific native code.

## Alternatives considered

| Approach | Benefits | Costs |
| --- | --- | --- |
| Java traversal calling native primitives/spans | Common native wire implementation; ordinary Java values | Potentially many native calls, conversions and native cursor lifetimes; still generated traversal |
| Whole-sample native codec driven by descriptors | Common wire implementation and potential shared traversal; bulk-operation opportunities | Complex Java object access/construction or intermediate representation; marshaling may erase gains |
| Java traversal and shared Java codec (selected) | JVM can optimize traversal with encoding; natural allocation/errors; native-free standalone codec | Separate wire implementation remains and must receive fixes and independent validation |

One Java-to-native call per sample does not eliminate boundary costs if native
code subsequently fetches every field or constructs objects through JNI. A C
header alone is not a Java bridge. Either a reusable prebuilt JNI bridge or Java
FFM bindings could support native serialization without a consumer C/Zig
compiler, provided no per-application native glue must be compiled.

The selected approach is an engineering judgment about ordinary Java object
graphs, deployment and implementation complexity, not measured evidence of the
preferences of most DDS users. Reconsider native serialization only with
representative workload evidence; native-backed views may change the tradeoff.

## Runtime boundary and compatibility requirements

Audit emitted helpers and all generation modes before defining the API. Candidate
shared responsibilities include alignment, primitive access policy, strings,
fixed-point handling, framing, encapsulation and key-hash support. Keep field
selection, schema traversal and type-specific construction generated. The exact
boundary must allow useful JVM optimization without a large generic object
interpreter merely to eliminate generated statements.

Specify byte order, XCDR version, alignment origin, buffer position/limit behavior,
back-patching, bounds validation and exception behavior explicitly. Do not assume
the existing Java codec is complete or that copying helpers preserves correct
semantics. Separate deliberate correctness fixes from extraction changes.

Preserve public generated method signatures where feasible. Identify any public
helper dependencies, single/split-file differences and checked-in generated
outputs. Define runtime compatibility/versioning and a regeneration migration;
do not silently require a new runtime for old generated sources or remove old
generation modes without a deliberate decision. A legacy inline mode is an open
question, not a promised permanent second path.

Choose package/artifact names, minimum JDK, dependency delivery and release
alignment during implementation. Do not present the aspirational Maven
coordinates in existing documentation as proof an artifact is published. Supply
a reproducible way to consume the runtime artifact with generated code. Keep
Java codec dependencies separate from the zzdds JNI runtime dependency.

## Implementation sequence and acceptance

1. Inventory generated helpers, method signatures, buffer semantics, supported
   encodings and tests across single/split-file generation and zzdds wrappers.
2. Propose a small Java runtime API, package/artifact delivery and migration plan.
   Establish representative generated-output size and performance baselines.
3. Extract machinery incrementally and update generation/goldens and build recipes.
4. Document the dependency and validate fresh downstream use with prebuilt tools.

Acceptance requires generated code compiling and running in single/split modes;
standalone codec tests without native libraries; Java application build checks
using prebuilt zidl/zzdds and no C/Zig compiler; existing zzdds Java integration,
loan and key behavior; independent wire vectors and external interoperability;
and malformed-input/buffer-boundary coverage appropriate to extracted operations.

Measure representative generated source/class size, warm steady-state
serialization/deserialization, allocation and startup where relevant. Avoid
claiming size/speed improvements solely from moving source code. Differential
checks against the native core are useful, but neither side is the sole oracle.

The efforts can proceed separately. Coordinate shared vectors, expected canonical
key behavior and intentional validation changes, rather than introducing a Java
dependency on the native codec. Native serialization, FFM/JNI migration, a new
Java object model and broader DDS ownership changes are outside this effort.

The [appendable struct frame checkpoint](java-cdr-frame-bounds.md) bounds Java
readers before shared-runtime extraction; mutable member and union decoding
remain follow-up work.

The [mutable member and union checkpoint](java-cdr-member-bounds.md) extends
bounded reading to mutable structs and unions and appendable unions.

The [collection checkpoint](java-cdr-collection-bounds.md) bounds collection
readers/skips and validates counts before incremental allocation.

The [output-mode checkpoint](java-cdr-output-parity.md) closes the audited split
compilation gaps. All standalone codec validation fixtures now run in three
output modes before runtime extraction.
