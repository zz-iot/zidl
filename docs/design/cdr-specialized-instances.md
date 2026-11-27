# Specialized CDR writer and reader instances

Date: 2026-11-26. Status: agreed design. Steps 1 (the zidl-cdr core) and 2 (the Zig
generator, and the old Zig writers removed) are implemented: `Writer`,
`RuntimeWriter`, `Reader` (with `CdrReader` as its run-time instance),
`WriterFor`/`ReaderFor`, `readSample`, `serializeAlloc` and `zig build
bench-cdr`. Step 3a (the C writer without growable output, and the C/C++ generators
counting, then writing) and 3b (a faster run-time C ABI, in place of per-instance C
entry points) are implemented; zzdds has not moved yet.

This note follows the [shared native CDR core](shared-native-cdr.md). That
consolidation gave Zig and C one set of primitive encoders. It did not give them
one writer: Zig and C still have separate writers with different capabilities.
This note unifies the writers and readers. It replaces that note's requirement
for a growable output mode.

## Summary

- One generic writer and one generic reader, written once in Zig. Each is
  parameterized by encoding (XCDR1 or XCDR2), byte order, and, for the writer,
  output mode. Each parameter is fixed at compile time or left to run time.
- **Fast instances** fix every parameter at compile time. The default set is
  XCDR1-LE and XCDR2-LE, with counting and fixed-buffer output for the writer.
  A compile-time `FastSet` at each use chooses the set (zidl's `--cdr-fast` for
  generated code).
- **The run-time instance** chooses every parameter at run time. It is always
  built and handles every other combination (all big-endian output, for
  example) in one compact copy per type.
- **No growable output mode.** Callers count the size, then write into a
  buffer of exactly that size. A convenience helper does both.
- The reader parses the encapsulation header once per sample and dispatches to
  a fast instance or the run-time fallback.
- C exports the same capabilities from the same Zig source, through the
  run-time instance only. Native Zig never routes through the C ABI.

## Today

| | Zig `CdrWriter(version)` | Zig `PrimitiveWriter` | C `ZidlCdrWriter` |
| --- | --- | --- | --- |
| Encoding | Compile time | Run time (alignment cap) | Run time |
| Byte order | Little-endian only | Run time | Run time |
| Output | Growable only | Growable, fixed, counting | Growable, fixed, counting |
| Used by | Generated Zig code, zzdds discovery | Shared-core primitive tests | Generated C/C++ code, rmw_zzdds |

`CdrReader` takes both encoding and byte order from each sample's header and
passes them into every read.

Generated Zig code already compiles two writer copies per type,
`CdrWriter(.xcdr1)` and `CdrWriter(.xcdr2)`, both growable. The generated
`serialize` is generic over its writer (`writer: anytype`). Version-dependent
framing is already behind writer methods, such as `reserveDheaderMaybe`,
`beginOptionalMember` and the `writeEncapHeader*` family. The generated reader
code instead tests `reader.xcdr_version == .xcdr2` directly.

## Measurements

All numbers come from throwaway benchmarks run on 2026-11-26 on the development
machine (x86-64 Linux, Zig 0.17.1, ReleaseFast). Each is the best of 7 runs of
400,000 messages. Every benchmark uses the same mixed message of about 700 bytes:
1-, 2-, 4- and 8-byte primitives in an order that forces padding, a string, 64
longs, and 32 octet/double pairs.

### Writer: compile-time versus run-time parameters

XCDR2, growable output into a reused, pre-sized buffer. Each variant uses the
same shared encoders and moves one parameter from compile time to run time.

| Variant | ns per message |
| --- | --- |
| Today's `CdrWriter(.xcdr2)` | about 515 |
| Alignment cap and byte order at compile time | about 480 |
| Alignment cap at run time | 1,200–1,430 |
| Alignment cap and byte order at run time | 2,060–2,360 |
| All at compile time, three output modes behind a run-time switch | 760–1,000 |
| Today's `PrimitiveWriter` | about 1,840 |

The cost is not the alignment arithmetic itself: masking instead of division
changed nothing. A profile showed that run-time parameters stop the compiler
from inlining the buffer append and turn the fixed-size copies into `memcpy`
calls.

### Writer: output modes

XCDR2-LE, everything at compile time.

| Output | ns per message |
| --- | --- |
| Counting pass alone | about 102 |
| Fixed-buffer pass alone | 430–480 |
| Count, then fixed into a reused buffer | 555–585 |
| Count, allocate exactly, then fixed | 570–605 |
| Growable, reused pre-sized buffer | 505–565, but up to 2,090 |
| Growable, new buffer per message | 4,110–5,150 |

The growable mode's speed depended on whether the compiler inlined the append:
the same code ran at about 500 ns in one call site and 1,600–2,000 ns in another
within one benchmark. The counting and fixed modes were steady in every run.

### Reader

XCDR2-LE, 708-byte sample, bounds checks on every read in both variants.

| Reader | ns per message |
| --- | --- |
| `CdrReader` (encoding and byte order at run time) | 379–386 |
| Encoding and byte order at compile time | 225–230 |

The reader gains less than the writer (about 1.7×) because it never appends to
a buffer and keeps its bounds checks.

### `zig build bench-cdr`

The checked-in benchmark (`bench/cdr/`), same message, one binary, 2026-11-26.
Rows within one binary compare; the run-time rows in particular depend on how
much the compiler inlines in that binary (the reader's run-time instance runs
380 ns in a smaller one). The `CdrWriter` and `PrimitiveWriter` rows were
measured before those writers were removed; the benchmark no longer has them.

| Variant | ns per message |
| --- | --- |
| Today's `CdrWriter`, growable, reused buffer | 416 |
| Fast instance: count, then fixed | 243 |
| `PrimitiveWriter`: count, then fixed | 4,349 |
| Run-time instance: count, then fixed (little / big-endian) | 2,272 / 2,264 |
| C: today's run-time ABI, fixed | 2,669 |
| C: specialized fixed-instance exports | 1,117 |
| Reader: `CdrReader` (run-time instance) | 682 |
| Reader: fast instance, dispatched per sample | 199 |

A counting pass only adds padding and sizes, without encoding: that is why the
fast count-then-fixed path beats today's single growable pass.

## Design

### One generic source

The writer is a single generic type. Each of its parameters is either a
compile-time value or `null`, meaning "a run-time field":

```zig
pub const WriterConfig = struct {
    version: ?XcdrVersion,
    order: ?ByteOrder,
    output: ?Output, // Output = enum { counting, fixed }
};

pub fn Writer(comptime config: WriterConfig) type { ... }
```

Each accessor returns the compile-time value when there is one and the field
otherwise, so a fast instance folds away every branch. The run-time instance is
`Writer(.{ .version = null, .order = null, .output = null })`. The shared
encoders, framing, string and key code stay as they are; only the storage and
parameter plumbing is new.

`ReaderConfig` has `version` and `order` and works the same way. All instances
keep their bounds checks, because input is untrusted.

`CdrWriter`, `PlCdrWriter`, `PrimitiveWriter` and the growable C writer are
removed, not deprecated. PL_CDR is an XCDR1 instance with the parameter methods
(`writePlEncapHeader`, `reservePlParam`, `patchPlParam`, `writePlSentinel`,
`writeRawParam`).

### Output modes: counting and fixed only

- **Counting** only does arithmetic: padding and sizes. Patches (DHEADER,
  EMHEADER length codes, XCDR1 optional member lengths, ParameterList lengths)
  are skipped, since there is nothing to patch.
- **Fixed** writes into a caller's buffer and patches in place. Running out of
  space is `error.Overflow`, never undefined behavior.
- Both track the payload position separately from the buffer offset, so
  alignment is relative to the payload start in either mode.

Growable output is dropped. Counting is about a fifth of the cost of a write,
so count-then-fixed matches the best case of growable output, is much faster
than growing a new buffer, and allocates exactly once at exactly the right size.
That exact size also saves memory for samples kept in a writer's history.

A convenience helper replaces growable output for callers that just want bytes:
count, allocate exactly, write, and check. The C counterpart uses the registered
CDR allocator.

**Length check.** Every count-then-fixed caller checks that the fixed pass wrote
exactly the counted length. A sample changed between the passes (for example,
by another thread) gives `error.Overflow` if it grew, or a length-mismatch error
if it shrank. Either way it is an error, never memory corruption. A growable
writer would also have produced a torn sample, so this is no weaker than today.

**Other encodings.** Dropping growable output does not close off other formats.
Any serializer that gives the same output for the same input can be counted by
running it into a counting sink; the only question is cost:

- Protobuf and ASN.1 DER prefix nested content with a variable-width length, so
  their encoders must compute sizes first anyway. The counting pass should keep
  nested sizes for the write pass, to avoid recounting at each nesting level.
- BSON's fixed-width document length is patched afterwards. CBOR and
  MessagePack prefix element counts, which come from the data.
- UTF-8 from UTF-16 is counted with one scan.
- JSON and XML must escape strings and format floats to know their length, so
  counting costs nearly as much as writing. A fixed buffer sized from an upper
  bound, then trimmed, is the better choice there.
- Compression is applied to the serialized bytes and has a published
  worst-case size. Output too large to hold in memory needs a streaming sink,
  which growable output would not provide either.

The shared encoders need only a sink with `writeBytes`, so a future format
could add its own output kind without changing CDR.

### Fast set

A `FastSet` names the encodings that get fast instances. The default is:

| | XCDR1-LE | XCDR2-LE |
| --- | --- | --- |
| Writer, counting | Fast | Fast |
| Writer, fixed | Fast | Fast |
| Reader | Fast | Fast |

XCDR1 is in the default set because DDS-XTypes treats a missing data
representation as XCDR1, zzdds's matching does the same, and XCDR1 is still a
common default among other implementations.

The set is a compile-time parameter at the use site, not a zidl-cdr build
option: the codec module is built in several places (zidl's own build, its
package build, a consumer's local-source build), and an option would have to be
threaded through each. Generated code receives the set from a zidl generator
option (`--cdr-fast`), which zzdds sets from a build option of its own; zzdds's
internal call sites pass the same set. `FastSet.none` builds only the run-time
instance, for size-constrained targets. The run-time instance is always built.

`WriterFor(fast, version, order, output)` and `ReaderFor(fast, version, order)`
return the fast instance when the set has one, and the run-time instance
otherwise; either is initialized the same way, so the result is correct whatever
the set.

### Reader dispatch

Generated code gets a top-level read that parses the 4-byte encapsulation
header once and switches on it: XCDR2-LE and XCDR1-LE go to their fast
instances when built; everything else goes to the run-time instance. That is
one branch per sample, not per field.

The generator replaces `reader.xcdr_version == .xcdr2` with a method,
`reader.isXcdr2()`. It returns a compile-time constant in fast instances and
reads the field in the run-time instance.

### Byte order

The run-time instance supports big-endian in every mode, so the Zig and C
libraries match. The fast set is little-endian only. There is no DDS-level
byte-order setting: zzdds writers keep emitting little-endian. A per-writer
setting can come later if someone needs it.

### Key hashes

Zig's `KeyHashWriter` already streams the PLAIN_CDR2 big-endian key into MD5
and keeps the first 16 bytes, with no allocation; it stays. Generated C/C++ key
hashes today serialize into a growable writer and hash the result. They switch
to an exported equivalent of `KeyHashWriter`, so C gets the same
allocation-free path.

### C ABI

- `ZidlCdrWriter` loses `grow_fn` and `zidl_cdr_writer_init`; it keeps fixed
  and counting initializers and byte-order selection. The layout may change:
  there is no ABI promise before 1.0.
- The existing `zidl_cdr_write_*` functions become the run-time instance's
  entry points.
- Writes store their bytes in Zig, and a counting writer only does the
  arithmetic, as the Zig writer does.
- Generated C/C++ code uses count-then-fixed for writes and key-only payloads,
  and `zidl_cdr_serialize_alloc` where it needs owned bytes.
- There are no per-instance C entry points (see below).

**Measured: per-instance entry points are not worth their code.** C calls into
the library once per primitive, and nothing inlines across that boundary. The
first measurement favored per-instance exports (1,117 ns against 2,669 ns for a
fixed write of the bench message), but most of that gap was the run-time C ABI
calling back into C to store each write. With storage in Zig and arithmetic-only
counting, count-then-fixed through the run-time ABI takes about 1,900–2,300 ns
(4,300 ns before), against about 1,800–2,000 ns through per-instance exports
(`zig build bench-cdr` keeps both rows). That 10–15% would cost a copy of every
generated C/C++ serialize function per fast instance (five with the default set)
and a larger library, so the C ABI keeps one run-time instance.

The remaining cost is one library call per primitive. A whole-sample path would
remove it: one C call per sample into compiled Zig (a generated Zig serializer
over the C layouts, which needs Zig in the application's build and cannot read
C++ standard containers), or into a descriptor-driven serializer in the prebuilt
library. Either is a separate design.

### Code size

Today, generated Zig code compiles two growable writer copies per type and one
reader. The default set compiles four writer copies (two of them counting-only,
which are small), one run-time writer, two fast readers and one run-time reader.
An empty fast set compiles one writer and one reader. Binary size for
`shape_main` (ReleaseSmall, stripped) is measured before and after.

## Consumers to migrate

| Consumer | Today | Change |
| --- | --- | --- |
| zidl Zig generator | `CdrWriter(.xcdr1/.xcdr2)` with a growable buffer per write | Selector; count, then fixed |
| zidl C/C++ generators: `_write_w_timestamp`, `_key_cdr` | Growable C writer | Count, then fixed (the non-timestamp write already does this) |
| zidl C/C++ generators: `_compute_key_hash` | Growable writer, then hash | Streaming key hash export |
| zzdds `participant.zig`, `sedp.zig`, `wire_codec.zig`, fuzz test | `CdrWriter(.xcdr1)`, `PlCdrWriter` | Selector instances |
| zzdds raw-loan Zig example | Growable; notes Zig lacks fixed mode | Fixed mode |
| zzdds release-bundle consumer, binding smoke tests | C growable or fixed init | Fixed or counting init |
| rmw_zzdds `rmw_publish` and its type-support test | Growable C writer | Count, then fixed, as `rmw_serialize` already does |
| zz0 agent tests, zz0 Pico demo | `CdrWriter(.xcdr2)` | Count, then fixed |

Java keeps its own codec. It currently retries with a doubled buffer on overflow
in three places, which a generated size method would replace. That is a separate
follow-up.

## Implementation sequence

Each step keeps everything building and passing: the new core is added, the
consumers move, then the old writers go.

1. **zidl-cdr core (done).** The generic `Writer` (counting and fixed output,
   `RuntimeWriter`, `WriterFor`, `serializeAlloc`) beside today's writers, with
   byte-parity tests against `CdrWriter` (little-endian) and `PrimitiveWriter`
   (big-endian). `CdrReader` becomes the run-time instance of the generic
   `Reader`, so every existing reader test runs on the new code; fast readers,
   `ReaderFor` and per-sample dispatch (`readSample`) are added. `zig build
   bench-cdr` reproduces the measurements, including the C question above.
2. **Zig generator (done).** `--cdr-fast`; the typed DataWriter and `keyCdr`
   count, then write (`serializeAlloc`); generated deserializers take `reader:
   anytype` and use `isXcdr2()`, and the typed DataReader enters them through
   `readSample`. A reader window's variable is typed (`?@TypeOf(reader.*).Window`),
   since a fast reader makes `isXcdr2()` compile-time known. Then (2b, done)
   `CdrWriter`, `PlCdrWriter` and `PrimitiveWriter` are removed and zidl's own
   tests use fixed and counting writers; their byte-parity checks keep the removed
   writers' output as known answers.
3. **C ABI and C/C++ generators.** (3a, done) `ZidlCdrWriter` drops growable
   output (`zidl_cdr_writer_init`, `zidl_cdr_writer_deinit`); `zidl_cdr_serialize_alloc`
   counts, allocates exactly and writes; generated `_write_w_timestamp`, `_key_cdr`
   and `register_instance` use it, the loan writes check that both passes agree, and
   the key projection writes straight into zzdds's buffer. `ZidlCdrKeyHash` streams a
   key holder into MD5; a canonical key collection, whose DHEADER a stream cannot
   patch, is counted first. (3b, done) Writes store their bytes in Zig and a
   counting writer only does the arithmetic, which halves C count-then-fixed;
   per-instance C entry points are dropped (see C ABI).
4. **zidl release, then zzdds** (pin bump, internal call sites, examples), the
   zz0 repositories, and rmw_zzdds by its owner.

## Acceptance

- Every existing known-answer, framing, key and malformed-input test runs over
  each fast instance and over the run-time instance in both byte orders.
- A test changes a sample between the counting and fixed passes and gets an
  error, not corruption.
- The fast writer is within 5% of today's `CdrWriter`, and the fast reader is
  within 5% of the compile-time reader above. The run-time writer and reader are
  no slower than today's `PrimitiveWriter` and `CdrReader`.
- `shape_main` size before and after is recorded here.
- C ABI size, alignment and offset checks match the new layout.

## Out of scope

- A DDS-level byte-order setting.
- Skipping the counting pass for types with a known maximum size.
- The Java codec, beyond the follow-up noted above.
- Text and other non-CDR encodings.
