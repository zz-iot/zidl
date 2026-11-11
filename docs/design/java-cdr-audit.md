# Java CDR runtime audit

Date: 2026-11-10
Baseline: zidl `171400a` (after native runtime retirement).
Status: inventory and executable baseline; no runtime extraction yet.

This refines [the agreed Java runtime design](java-cdr-runtime.md). Java keeps
schema traversal and ordinary Java values. The shared library is Java code,
independent of the zzdds JNI bridge and native CDR archive.

## Actual duplication and API surface

Single-file output has one outer class per IDL input. That class owns private
static CDR helpers; named types are nested classes. Split output already shares
one public `<Stem>CdrUtils` class across that input's types, using static imports.
The same helpers are emitted again for each additional IDL input. Helpers are
not copied into every split type.

There are two helper emitters in `src/backend/java.zig`: `emitCdrHelpers` and
`generateCdrUtils`. Optional, canonical-padding and wide-string helper emission
is reused between them; alignment, narrow strings, hashing and encapsulation
still have duplicate emission logic. Fixed-point helpers occur only in the
single-file emitter.

| Responsibility | Current implementation | Proposed boundary |
|---|---|---|
| Alignment | `_cdrAlign` moves the position; `_cdrAlignKey` writes zero padding | Shared buffer helpers; retain separate semantics |
| Primitive access | Generated `ByteBuffer.get/put*` calls and alignment selection | Keep schema-specific calls generated; audit validation separately |
| Narrow strings | UTF-8 conversion, length and terminator operations | Shared validated read/write/skip operations |
| Wide strings | UTF-16 code units, byte count, read/write/skip | Shared operations with an explicit surrogate policy |
| Optional members | XCDR1 parameter headers, XCDR2 flag, `_CdrOptional` scope | Shared framing machinery; member identity and traversal generated |
| DHEADER/EMHEADER | Mostly repeated inside per-type read/write/skip methods | Shared checked spans and patches; dispatch and field selection generated |
| Fixed-point | Packed BCD through `double` and scaled `long` | Later extraction; preserve/document mapping limits separately |
| Encapsulation | `_cdrDetectXcdr(byte[])` plus generated header handling | Shared validated header detection; explicit supported encodings |
| Key hashes | Copy key buffer, pad or MD5 via `MessageDigest` | Shared finalization; key traversal and type-maximum policy generated |
| DDS integration | Generated type support/readers/writers and zzdds Java runtime | Keep outside the standalone codec library |

Generated fields are private with `get_*`/`set_*` accessors. The codec entry
points are instance `serialize(ByteBuffer, int base, int version)`, static
`deserializeFrom(ByteBuffer, int base, int version)` and static `skip`.
Keyed types also expose `serializeKeyHolder`, wire `serializeKey`/`deserializeKey`,
`computeKeyHash`, and incoming full/key-only payload hash methods. Selective
reads and content-filter callbacks depend on the same codec paths.

Preserve these generated type signatures and constructors. Public split
`CdrUtils` helpers and the public `_CdrOptional` nested type are also observable;
they need forwarding compatibility or an explicit regeneration boundary when
replaced. There are no generated `ZidlCdrReader`/`ZidlCdrWriter` classes.

## Buffer and wire contracts to retain

- Alignment is relative to the supplied CDR base, not buffer index zero. An
  encapsulated body normally uses base 4; XCDR1 optional values reset the base
  to the start of their bounded value.
- Ordinary alignment advances without writing, so it also works with a
  read-only buffer. Canonical key alignment writes zero padding. Combining
  these helpers would change behavior and can corrupt read-only use.
- Ordinary generated serialization/deserialization sets the supplied buffer to
  little endian. Scalar 64-bit alignment is 8 for XCDR1 and 4 for XCDR2.
  Canonical key holders use big endian, four-byte capped alignment and no
  encapsulation or extensibility framing.
- Encapsulation detection recognizes LE IDs `0001`, `0007`, `0009`, `000b`.
  This is not general BE or XCDR1 ParameterList support. The ordinary mutable
  writer emits DHEADER/EMHEADER framing regardless of the version argument;
  accepting an argument of 1 must not be advertised as validated PL_CDR1 support.
- Hash finalization reads `[0, position)` from its scratch buffer, leaving the
  position at its original value. Generated `KEY_HASH_FORCE_MD5` is based on
  the declared type maximum, not just the current serialized length. Keep the
  independent 16/17-byte and variable-size key witnesses.
- `_CdrOptional.close()` restores the parent limit and advances to the value end,
  including when the generated body exits through an exception. The optional
  diagnostic confirms a body underflow is bounded and restores position 12 /
  parent limit 16. Do not lose this `finally` behavior during extraction.
- Raw buffer overflow/underflow, invalid lengths and unsupported encodings have
  inconsistent exception behavior today. Decide validation and failure cursor
  semantics explicitly; do not silently translate every failure into one class.

## Consumer/build inventory

| Consumer | Current wiring | Migration work |
|---|---|---|
| zidl `build.zig` standalone fixtures | `javac` sources, then `java -cp` the class directory | Add matching JAR to compile and runtime classpaths |
| zidl Java goldens | Single and split sources checked in; generated helpers included | Regenerate with the extraction, preserve public type signatures |
| zidl entity/cross-file JNI fixtures | Generated Java plus a test native bridge | Add the codec JAR without changing the bridge ABI |
| zzdds `build.zig` Java SDK | Installs generated sources under `java/io/zzdds/{dcps,ext}` and handwritten `java_runtime/ZzddsRuntime.java`; builds `zzdds_jni` separately | Install/deliver the independent codec JAR and update smoke compilation/runtime classpaths |
| zzdds `examples/java/*/{build,run}.py` | Prebuilt zidl generates source; `javac` and class-directory classpaths | Locate the installed JAR and include it on both classpaths, using the platform path separator |

The codec JAR is independent of `java.library.path`, which remains relevant only
to the existing DDS JNI library. Adding a JAR file to a directory does not make
an existing class-directory-only classpath load it automatically. Do not require
application-specific JNI code to consume generated codecs. The JNI/zzdds gates
must run when generation actually starts depending on the new library; this
standalone audit does not claim a fresh JNI or zzdds integration run.

## Reproduced issues, separate from extraction

The baseline tool reports observations; it does **not** assert that malformed
input must keep its current behavior. These are candidates for focused fixes
with independent negative witnesses before their machinery becomes shared API.

| Probe | Single-file result | Split-file result |
|---|---|---|
| Narrow-string count 0 or -1 | Empty string, position 4 | `NegativeArraySizeException`, position 4 |
| Nonzero narrow-string terminator | Accepted | Accepted |
| Invalid UTF-8 byte sequence | Replacement character | Replacement character |
| Truncated narrow-string body | `BufferUnderflowException` | `BufferUnderflowException` |
| Odd wide-string byte count | `IllegalArgumentException` | `IllegalArgumentException` |
| Unpaired UTF-16 high surrogate | Preserved in returned `String` | Preserved in returned `String` |
| Two-byte encapsulation lookup | Returns version 1 without checking the full header | Same |
| Appendable DHEADER says zero bytes, followed by value 7 | Reads 7 outside that frame, position 8 | Same |

The two-byte test is for the helper alone, not a claim that a complete public
sample decoder accepts a two-byte sample. Avoid huge allocation probes: narrow
string reads allocate from the unvalidated declared count, and ordinary
sequence reads allocate an `ArrayList` before validating the count against the
remaining bytes. Narrow-string skip currently performs a full string decode and
allocation. Bounded narrow strings are not passed a bound by the emitted read
call; wide-string bounds are checked after decoding. Primitive boolean reads
normalize any nonzero byte while optional flags explicitly reject values other
than 0/1. A shared span/validation API must accommodate fixes to these paths.

Two additional compilation probes fail today:

- Split output without `--java-package` imports a helper from the unnamed
  package, which `javac` cannot resolve. The named-package split baseline works.
- Split `fixed<8,2>` calls `_cdrReadFixed`/`_cdrWriteFixed`, but its `CdrUtils`
  emitter supplies neither. Single-file fixed code uses approximate `double`
  values and a scaled `long`; wide fixed support remains a separate roadmap gap.

Ordinary appendable reads merely skip DHEADER. Ordinary mutable reads use
unchecked lengths/member spans, unlike the more defensive key/selected read
paths. Moving only the utility class will not address the generated framing
code. Establish bounded scopes before sharing that behavior.

## Reproducible baseline

```sh
python3 tools/benchmark_java_cdr.py --zidl /path/to/prebuilt/zidl \
  --output /tmp/java-cdr-baseline
```

Requires Python 3 and a JDK whose `javac` supports `--release 8`; it runs no
C/Zig compiler and loads no application native library. The driver generates
fresh output, compiles codec and types-only variants to Java 8 bytecode, runs
small buffer diagnostics, records source/class size, then performs warm
roundtrips and canonical key hashing in separate JVM forks. It records generator
and fixture hashes, the repository revision, JDK and platform. Temporary generated
files are isolated under the chosen output directory.

The fixture has five types: a keyed scalar, a keyed string/UTF-16/sequence type,
an appendable aggregate, a mutable optional-member type, and a bounded-frame
witness. Wrapper output is measured as source only: compiling its DDS classes
requires the separate zzdds Java API/runtime and is not claimed by this driver.
Class sizes exclude benchmark/probe classes. Helper byte counts sum helper
method/state-class declarations, not schema-specific traversal.

| Mode | Java files | Source bytes | Helper bytes | Class bytes |
|---|---:|---:|---:|---:|
| Single-file codec | 1 | 39,274 | 7,302 (17 declarations) | 29,229 |
| Named-package split codec | 6 | 36,411 | 5,949 (15 declarations) | 27,206 |
| Single-file types only | 1 | 4,619 | 0 | 6,558 |
| Split types only | 5 | 4,664 | 0 | 5,468 |
| Single-file + zzdds wrappers | 13 | 131,304 | 7,302 | Not measured |
| Split + zzdds wrappers | 18 | 127,539 | 5,949 | Not measured |

These sizes use OpenJDK 21.0.13 targeting Java 8. Single/split helper size differs
partly because split output omits fixed helpers; it is not evidence that split
mode implements the same complete helper set more compactly. Types-only deltas
also include schema-specific codec methods and cannot all be removed by sharing.

Performance results are recorded separately in `baseline.json`: three JVM
forks, 200,000 warmup and 500,000 measured operations per case, 128 MiB fixed heap,
reused heap buffer, varying scalar values, and checksummed decoded results.
Cases cover scalar and allocating aggregate XCDR1/2 roundtrips, mutable/optional
XCDR2, and short padded plus MD5 key hashes. This is a diagnostic microbenchmark,
not JMH or an end-to-end DDS/JNI measurement. Allocation rates and cold startup
are not measured yet; add those before claiming performance/footprint wins.
Moving source alone establishes no speed or total application-size advantage.

The [recorded JSON](../../test/java-cdr-baseline/baseline.json) preserves all
forks and diagnostics. On this host, median nanoseconds per operation (min–max)
were:

| Operation | Single-file | Split-file |
|---|---:|---:|
| Scalar XCDR1 | 80 (77–84) | 79 (75–93) |
| Scalar XCDR2 | 85 (85–87) | 85 (75–91) |
| Aggregate XCDR1 | 2,511 (2,403–2,534) | 2,507 (2,411–3,126) |
| Aggregate XCDR2 | 2,485 (2,400–2,904) | 2,549 (2,455–2,577) |
| Mutable/optional XCDR2 | 526 (514–661) | 530 (517–553) |
| Short + MD5 key pair | 1,427 (1,364–1,478) | 1,330 (1,272–1,409) |

Each non-key operation includes encoding and decoding. These are legacy
baselines, not an optimization comparison or a performance gate. The current
single/split implementation differences and host/JIT variation prohibit treating
these numbers as evidence that the proposed runtime is faster.

## First extraction and delivery proposal

Start with stateless buffer alignment and validated string operations, retaining
`ByteBuffer` public entry points and direct generated primitive access. Keep
schema traversal, type construction, member IDs, declared bounds, key policy,
selection and DDS integration generated. Avoid a generic descriptor interpreter
or a new mandatory reader/writer object model.

1. Land focused correctness witnesses/fixes for narrow lengths/terminators and
   bounded reads, explicitly recording changed exceptions/cursors. Resolve the
   Unicode acceptance policy rather than copying the existing replacement and
   surrogate behavior accidentally. Fix the two split-mode compilation gaps in
   separate changes.
2. Add a pure-Java `packages/zidl-cdr-java` runtime, proposed package
   `io.zidl.cdr`, with tested Java 8 API/bytecode compatibility. No JNI/FFM or
   dependency on `libzidl_cdr`/zzdds. Start small; optional state, general framing,
   fixed-point and key finalization can follow in separate slices.
3. Build a versioned `zidl-cdr-java` JAR using JDK tools and distribute it with
   zidl releases/source, independently of the native platform archive matrix.
   Align artifact releases with zidl and record a required runtime API level;
   compatible releases keep that API additive. Maven coordinates/publication
   remain unimplemented. CLI-only builds must not suddenly require a JDK.
4. New shared-runtime output requires the JAR on both compile and runtime
   classpaths. Old generated inline output keeps working without regeneration.
   Initially retain split public helper forwarding methods for extracted APIs.
   Keep `--no-typesupport` output runtime-free. No permanent second inline
   generator mode is proposed without a concrete requirement.
5. Update zidl's standalone Java fixtures, zzdds Java packaging/build commands,
   installed examples and source/release recipes together with each extraction.
   Validate fresh consumption using only prebuilt zidl, the JAR and JDK tools.
   Existing zzdds Java JNI/loan tests remain a separate required integration gate.

Current audit validation includes fresh Java 8-targeted codec compilation and
roundtrips, malformed-input observations, both split compilation diagnostics,
and the existing canonical-key, projection, optional-wire and independent XCDR
vector suites. The selected baseline is not a formal JDK minimum guarantee for
all generated JNI wrappers. Add explicit runtime compatibility and mismatch
checks when the first JAR API is implemented.

The first implementation slice is described in
[Java CDR string validation](java-cdr-string-validation.md). Historical baseline
measurements above remain the pre-fix audit snapshot.
