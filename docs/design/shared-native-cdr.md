# Shared native CDR core

Date: 2026-11-02

Status: native consolidation, package split and production switch implemented;
zzdds migration merged in [zzdds #141](https://github.com/zz-iot/zzdds/pull/141). The transitional `zidl-rt` package and module
are removed. The checkpoints below record the implementation sequence and
superseded intermediate states. Native consolidation and shared Java runtime
delivery are complete; see the [closeout](#consolidation-closeout) below. Rust
bindings are a separate proposed follow-up, not an implemented backend.

The [native capability/dependency audit](native-cdr-audit.md) records the
2026-11-03 code inventory, independently checked key semantics, compatibility
constraints and proposed extraction boundary. Its findings refine the initial
discrepancies below.

The [primitive writer checkpoint](native-cdr-primitive-slice.md) now demonstrates
shared native Zig/C primitive encoding, initially behind an opt-in C build. The
[production build checkpoint](native-cdr-production-slice.md) now makes the
shared archive the development default.

The [reader/cursor checkpoint](native-cdr-reader-slice.md) extends that core to
primitive decoding and checked reader advancement/alignment, with explicit
invalid-input behavior and build-runner investigation results.

The [string checkpoint](native-cdr-string-slice.md) shares narrow/wide wire
operations, validates final terminators and preflights wide bodies before
allocation, preserving the separate native/C ownership contracts.

The [framing checkpoint](native-cdr-framing-slice.md) shares encapsulation,
DHEADER/EMHEADER and ParameterList mechanics, with additive checked patch and
bounded-reader APIs. Generated codecs still need to adopt those APIs.

The [generated validation checkpoint](native-cdr-generated-validation-slice.md)
adopts checked patch calls in all native generators and common wide validation
for C++ reads and C/C++ skips. Generated bounded-reader adoption is next.

The [generated reader-window checkpoint](native-cdr-reader-windows-slice.md)
now enforces DHEADER/EMHEADER and collection ends during generated native reads,
including key/selected traversal, and restores parent limits on failures.

The [canonical key checkpoint](native-cdr-key-slice.md) separates native key
holders from wire serializers and supplies schema-based MD5 policy. It includes
independent vectors and explicitly records the Java, member-ID normalization and
ordinary wire gaps that remain before a production switch.

The [Java canonical key checkpoint](java-cdr-key-slice.md) brings Java holder
bytes and type-based MD5 policy into agreement with the native generators for
the supported shapes. The [resolved member-ID checkpoint](native-cdr-member-ids-slice.md)
now supplies sequential, inherited and hashed identities from the compiler IR,
including sorted MinimalStruct TypeObject members and mutable union default arms.

The [ordinary wide-wire checkpoint](native-cdr-wide-wire-slice.md) corrects
wide-string counts and terminator handling across native and Java codecs, with
independent endian/version/sequence vectors. The [mutable key-wire checkpoint](native-cdr-key-wire-slice.md)
adds matching key-only frames and traversal through explicitly keyed nested
structures, with boundary/cleanup vectors. The inherited and intermediary
projection follow-up is recorded below.

The [inherited-frame and recursive projection checkpoint](native-cdr-key-projection-slice.md)
now uses one frame for inherited members and projects through keyless structure
intermediaries, arrays, sequences and aliases. Keyless topic behavior is preserved.
Local root, integration, interoperability and installed-archive checks pass.
Package placement and the production build switch are recorded below.

The [optional-wire checkpoint](native-cdr-optional-wire-slice.md) replaces the
incorrect XCDR1 optional presence byte with parameter headers and scoped value
alignment, retaining XCDR2 presence bytes. It adds independent long/compact
header witnesses and preserves reader/writer state layouts.

The [fixed-point checkpoint](native-cdr-fixed-slice.md) extracts packed BCD into
one native core, fixes the 31-digit range and validates shape/digit/padding/sign
inputs. Existing f64/double mappings remain approximate; Java's separate wide
fixed-point gap and direct optional C++ arrays are tracked in the roadmap.

## Decision and motivation

Replace the independently maintained Zig and C native CDR implementations with
one core implemented in Zig. Native Zig callers use that core directly; a C ABI
adapter exposes its capabilities to C, C++ and other foreign-language consumers.
The native Zig API must not route through the C ABI.

The objective is to maintain wire mechanics, bounds checking and codec fixes
once while preserving language-appropriate APIs. A C ABI does not require C
implementation source, nor does it require generated application values to have
Zig layouts. Generated codecs can navigate native language values and pass
primitives and spans to the runtime.

Java retains a separate Java codec under the companion
[Java runtime decision](java-cdr-runtime.md). This is one shared **native** codec,
not a requirement that every language serialize through native calls.

## Audit baseline and required capabilities

The following inventory describes the pre-consolidation baseline, not the
current package layout. The checkpoints and closeout record the delivered state.

At the audit baseline, `packages/zidl-rt/src/cdr.zig` implemented the native Zig codec as well as some
binding helpers. `packages/zidl-cdr/src/zidl_cdr.c` independently implements the
existing C ABI. Its build and several zidl/zzdds consumers compile C source
directly. The opt-in Zig-backed C adapter now supplies the migrated operations
listed in the checkpoints above. The production checkpoint subsequently makes
the shared archive the default and moves the C reference under tests.

| Capability | Current native Zig | Current C ABI implementation |
| --- | --- | --- |
| Reader byte order | Little and big | Little and big |
| Ordinary writer byte order | Little only | Little and big |
| Growable output | Yes | Yes |
| Explicit fixed/counting writer modes | Not in the main writer | Yes |
| XCDR1/XCDR2 primitives and extensibility framing | Present | Present |
| Borrowed string reads | Yes | Yes |
| Allocators | Explicit Zig allocator | Process-wide registered allocator |
| Key hashing | Streaming specialized writer | Helper over serialized key bytes |
| Discovery ParameterList parser policy | Strict/lenient selector | No corresponding selector |

This is an initial inventory, not a completeness or conformance claim. Audit
operations, malformed-input behavior, back-patching, generated direct-field
accesses and all consumers before choosing extraction boundaries. The Zig codec
is not a superset of C. Preallocated growable capacity is not a fixed-buffer
contract. Ordinary little-endian output is independent of CPU byte order and is
not itself an ARM incompatibility; big-endian host support still needs testing.

Two specific discrepancies require investigation:

- Neither implementation verifies the final wire NUL. C's allocating readers
  reject embedded NUL content for ownership/free-size correctness; borrowed C
  reads and Zig slices do not impose that check.
- Zig's key-hash writer uses alignment capped at four; generated C/C++ key-hash
  helpers initialize an XCDR1 writer with alignment capped at eight. Establish
  expected canonical behavior independently, including mixed-size keys, rather
  than choosing an implementation by agreement or age. The audit establishes
  RTPS 2.5's four-byte alignment requirement and also identifies both helpers'
  actual-length versus type-maximum-size hash-selection discrepancy.

## Core and interface requirements

The core must support allocation-free fixed-buffer operation, counting without
output storage, and growable output. Both reader and writer byte orders are
required for supported encodings. Share primitive encoding, alignment,
encapsulation, DHEADER/EMHEADER machinery, checked cursor arithmetic and other
wire operations where semantics match. Inventory discovery ParameterList and
canonical key serialization explicitly; do not conflate their policies.

Keep ownership, allocator policy and error presentation at interface boundaries.
Do not introduce heap allocation or runtime virtual dispatch merely to unify the
APIs. A generic sink/cursor is a candidate, not a mandated abstraction. Preserve
Zig specialization opportunities and ergonomic native APIs.

The C adapter must expose deliberate status translation and ABI-compatible state,
delegating to common operations rather than creating another codec in Zig.
Recoverable invalid input must not cause panics or undefined behavior. Check
lengths and arithmetic before memory access or allocation. Preserve cursor,
overflow, patching and borrowed-data lifetime contracts, or document intentional
changes explicitly.

## Compatibility, naming and distribution

Initially preserve `zidl_cdr.h`, `zidl_cdr_*`, installed `libzidl_cdr`, and public
reader/writer layouts where feasible. Generated C/C++ accesses fields directly;
nominally opaque documentation is not sufficient to change them. Any incompatible
layout or semantic change needs an explicit migration/versioning decision.
Preserve allocator/free pairing, callback lifetimes and allocation sizes. Avoid
duplicated allocator state across static/shared runtime embeddings. Allocator
scoping redesign is outside this effort.

Preferred logical names, subject to dependency audit:

| Name | Responsibility |
| --- | --- |
| `zidl-cdr` | Canonical codec package, implemented in Zig, with native API |
| `zidl-cdr-c` | C adapter/target, potentially inside the same package |
| `zidl-bindings` | Non-codec ownership, boxes and binding support |
| `zidl-rt` | Transitional compatibility umbrella |

Do not force each logical component into a separate package. Keep dependencies
acyclic; allocator definitions may require a small shared module. Do not couple
this effort to renaming XTypes or the experimental typesupport package.

Building the runtime now requires Zig. Consuming prebuilt native artifacts does
not require applications to compile Zig: C/C++ may retain their own compilers
and application flags. Define supported target/ABI artifacts, libc/compiler
runtime dependencies, symbol visibility and non-Zig linker consumption. Runtime
instrumentation flags require corresponding runtime builds; application flags do
not retroactively affect a prebuilt library.

Keep the old C codec as a temporary differential reference during migration.
An optional production C implementation needs an identified C-only toolchain or
target requirement and an explicit maintenance decision; it is not the default
distribution strategy. No promise of identical target portability follows merely
from exposing a C ABI.

## Implementation sequence and acceptance

This sequence is complete. Preserve it as the rationale and acceptance record,
not an outstanding task list.

1. Audit both APIs, tests, generated accesses, source-build consumers and required
   targets. Record compatibility constraints and capability differences.
2. Propose core/dependency boundaries and demonstrate both interfaces using the
   same primitive logic, both byte orders and all three output modes.
3. Migrate operations incrementally, using C temporarily as a differential
   reference. Record intentional validation and bug-fix changes.
4. Update zidl generation/build paths and zzdds packaging, keeping normal native
   Zig use direct. Introduce compatibility imports and migration documentation.
5. Remove the old codec from the default production dependency graph after parity.

Acceptance requires independent known-answer vectors and external peer checks
for supported encodings, extensibility and key hashes; regression coverage for
truncation, malformed lengths, overflow, allocation failure and cleanup; ABI
size/alignment/offset checks; fresh installed-artifact C/C++ compile/link tests
using non-Zig application toolchains; and relevant zidl/zzdds cross-binding,
allocator and loan checks, including Java integration.

After consolidation, C/Zig roundtrips validate adapters, not independent codec
correctness. Retain independent vectors and interoperability tests. Benchmark
representative payloads, allocation patterns, throughput, latency and artifact
size before claiming a performance or footprint advantage. Zig does not
automatically outperform C; foreign callers may retain call-boundary costs.

Out of scope: Rust bindings, Java native serialization, generic plugin extraction,
discovery broker work and a broad DDS ownership redesign.

The [package placement checkpoint](native-cdr-package-slice.md) moves the codec
to `zidl-cdr`, binding support to `zidl-bindings`, and retains `zidl-rt` aliases.
The C ABI and default C reference selection remain unchanged at this checkpoint.

The [production build checkpoint](native-cdr-production-slice.md) selects the
shared archive by default and moves the independent C codec into reference
tests. zzdds local-source builds use it; its released dependency pin still
requires a coordinated update.

## Retirement complete

Generated Zig code, zidl and zzdds consume `zidl_cdr` and `zidl_bindings` directly.
The zzdds migration merged in [zzdds #141](https://github.com/zz-iot/zzdds/pull/141), so `packages/zidl-rt` and the `zidl_rt`
module export are removed along with their compatibility tests and build/release
wiring. There is no extended deprecation period. The independent old C codec
remains a test reference and is not part of the production dependency graph.

## Consolidation closeout

Completed on 2026-11-12. The native core, C ABI adapter, generator adoption,
package split, zzdds/rmw_zzdds consumer audit and `zidl-rt` retirement are done.
The old independent C implementation remains test-only. Shared Java helpers
remain Java and are delivered separately as `zidl-cdr-java` runtime API 2.

[zidl #73](https://github.com/zz-iot/zidl/pull/73) shipped in
[v0.3.30-zig.0.17.0](https://github.com/zz-iot/zidl/releases/tag/v0.3.30-zig.0.17.0).
[zzdds #150](https://github.com/zz-iot/zzdds/pull/150) pins that release and
installs the matching JAR, updates Java build/run classpaths and packages the
Java SDK. Its [Release dry run](https://github.com/zz-iot/zzdds/actions/runs/43303145293)
passed all four platform test jobs, self-interop and all four relocated bundle
checks. Publishing was skipped.

This closes the consolidation prerequisite for [Rust design](rust-cdr-plan.md).
It is not a claim of complete XTypes support or a measured speed improvement.
Direct optional C++ arrays and split Java interface implementation qualification
remain separate documented limitations; neither is part of this closeout.
