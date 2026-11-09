# Shared native packed fixed-point decimals

Date: 2026-11-08

Status: implemented and validated locally. The C reference remains
available and is still the default; package placement and production selection
are unchanged.

## Scope and findings

Packed BCD was the remaining scalar codec duplicated in the native implementations.
The two Zig writers computed a compile-time u64 power of ten, so fixed types with
20 through 31 digits failed to instantiate. Native and C readers also accumulated
into u64, which could overflow for wide decimal values. The public C routines did
not validate digit/scale arguments before indexing fixed-size scratch arrays.
Its floating-point maximum also rounded upward for large digit counts, so
saturating fixed<18,0> could emit zero instead of all nines.

The format follows [CORBA 3.3 Interoperability §9.3.2.8](https://www.omg.org/spec/CORBA/3.3/Interoperability/PDF):
no alignment padding, most-significant decimal digits first, a leading zero
half-octet for even digit counts, and C/D sign nibbles. Byte order does not change
this representation.

## Implementation and behavior

`zidl-rt/src/cdr_fixed.zig` now owns native BCD encoding, decoding and validation.
CdrWriter, KeyHashWriter, PrimitiveWriter and the staged C ABI call that core;
PlCdrWriter continues to delegate to CdrWriter. Generated native APIs need no
changes. Existing C reader/writer layouts and fixed-point function signatures
are preserved.

The core uses u128 for the complete 31-digit integer. The temporary C99 reference
remains independent: its writer converts binary64 significand bits into decimal
digits, and its reader uses two 64-bit limbs with explicit nearest-even conversion
to binary64. It needs neither a compiler-specific C integer type nor a math-library
link dependency. The storage bridge now checks counter overflow for reference
writes too; the fixed reader rejects invalid cursor bounds.

Digit counts must be 1..31 and the existing nonnegative scale must not exceed
the digit count. Invalid
parameters fail before reading or writing. Encoding retains the existing
binary64 scaling, half-away-from-zero rounding and saturation at the decimal
limit, including saturation of infinities. NaN returns an error rather than
reaching an invalid float-to-integer conversion. Rounded zero is emitted with a
positive sign. Decoding rejects non-decimal digits, nonzero leading padding and
signs other than C/D; the previous decoder accepted arbitrary signs. A complete
malformed value advances the reader by its wire size but leaves the C output
unchanged. A truncated value does not advance the cursor.

The f64/double value mapping remains approximate. Accumulating all digits before
conversion removes integer overflow; it does not make arbitrary high-precision
values or their decoded-value canonical key hashes lossless. Exact decimal value
mapping remains a roadmap item. Java's separate long-based fixed helpers remain
unchanged and their full-range/validation gap is recorded in the roadmap too.

## Evidence

`zidl-cdr/test/make_fixed_vectors.py` constructs independent expected BCD bytes and
binary64 result bits using Python integers. The native suite reads the resulting
fixture directly; the C package copies it into a test-only module so each Zig
source file belongs to one module. The fixtures include rounding, saturation,
negative zero, 18/19/20/30/31-digit boundaries, arbitrary 31-digit input and
nearest-even conversion ties.

Tests cover native legacy/primitive/key writers and readers, the C reference and
shared ABI, both CDR versions and byte orders, dynamic/fixed/counting storage,
unaligned starts, every truncated prefix and insufficient capacity, malformed
nibbles, invalid parameters, NaN and SIZE_MAX counters/cursors. The external C
consumer also exercises 31-digit calls through the installed shared archive.

Validation results:

- Native runtime: 101/101 tests pass on Zig 0.17 and 0.16.
- C reference/default package: 103/103 tests pass. Shared Debug and ReleaseSafe
  builds pass the same contracts (some Debug results cached), ABI checks and
  the external C consumer.
- System GCC/G++ callers link and pass the fixed-point contract against both
  installed shared archives. Archive symbols confirm that fixed read/write are
  supplied by the Zig adapter object.
- Full root build: 145/145 steps pass, including golden checks; the final run
  executes 31 tests with the other results cached. Integration/interoperability
  passes 37/37 steps and ten tests, including Java JNI, PMR and cross-file checks.
- The independent builder reproduces all 65 write and nine additional read
  fixtures exactly. Formatting and whitespace checks pass.
- Baseline checks reproduce the former 31-digit Zig compile-time overflow and
  the former C 18-digit saturation-to-zero error. Both have regression coverage.

Next: package/dependency placement, compatibility exports and the production
build/consumer switch. Deferred generator defects remain tracked in the roadmap.
