# XCDR1 optional member framing

Date: 2026-11-07

Status: implemented and validated locally. The C reference remains the
default. Package placement and the production switch are unchanged.

## Finding and encoding

FINAL/APPENDABLE optional members used a boolean presence byte in both versions.
XTypes 1.3 §7.4.1.1.5.2, §7.4.1.2 and §7.4.3.5.2 require an XCDR1 parameter
header, including for an absent value. Its length is the exact serialized value
length, excluding subsequent padding; an absent value has length zero and no
list sentinel. Value alignment restarts at zero after the header, and enclosing
alignment resumes afterward. Discovery ParameterList helpers have different
length/padding rules and remain separate.

Writers use the legal extended form for every XCDR1 optional member: PID_EXTENDED
0x7f01, short length 8, the 28-bit member ID with MU at bit 30, and a 32-bit value
length. This avoids a sizing pass or moving values when a short length overflows.
Readers also accept short headers for IDs 0 through 0x3f00, reject implementation
extensions/reserved IDs and mismatched IDs, and bound each declared value before
reading it. Extended headers accept either outer MU setting; the member flags
come from the extended word. XCDR2 retains boolean presence and its enclosing
alignment origin. MUTABLE/EMHEADER behavior is unchanged.

## Implementation

The shared framing core owns header emission/parsing, exact lengths and checked
patches. Native Zig writers and the staged C ABI delegate to it. The temporary C
reference implements the same contract independently. Existing C reader/writer
state layouts are unchanged; additive caller-owned scopes restore alignment and
reader bounds. A reader scope rebases its input view with four preceding bytes,
allowing existing primitive readers to retain their origin of four without
copying value bytes or treating those preceding bytes as an encapsulation.

Generated C/C++ isolate optional value operations in private helpers so an early
error can restore the caller's scope. C++ guards also restore during exception
unwinding and compile without exceptions. Zig uses lexical defers; Java uses
finally blocks in both output modes. Ordinary, key-value and selected reads and
skip traversal use version-aware framing. Optional field getters unwrap present
values and report absent values as unavailable. Zig optional decode temporaries
retain ownership until assignment, selected cleanup handles optional payloads,
and field getters register cleanup before parsing, including failures after a
selected string was decoded.

The fixture covers present/absent values, ID 0, the short-ID boundary and an
extended ID, strings, an aggregate containing an array, optional sequences,
nested optionals and inherited APPENDABLE fields. Direct optional C++ array
members remain a pre-existing unsupported shape: their declaration is a bare
array while their codec expects std::optional. This slice preserves public value
layouts and exercises arrays inside a supported optional aggregate instead.

## Compatibility

Regenerate bindings together with their runtime. Existing boolean-based XCDR1
optional payloads must be re-encoded, and participants using those fields need a
coordinated update. They are not accepted as an alternative encoding. XCDR2 bytes
retain their existing representation. Canonical key policy, TypeObjects,
discovery ParameterList validation and runtime package names are unchanged.

## Evidence

Independent checked-in vectors in `test/integration/optional_wire` are built by a
small Python encoder from the specification, not by either runtime. The generated
writers must reproduce extended-header vectors; readers additionally consume
compact-header variants. The native runtime has separate handwritten byte
witnesses, including MU flags, nested origin restoration, values above 65535
bytes, malformed headers, checked patch overflow and failed fixed writes.

Validation includes dynamic/fixed/counting writers, both byte orders and
versions, all truncated prefixes, declared-body bounds, allocator failure/cleanup,
read-only Java input and selective field traversal. Results:

- Focused optional target: 18/18 steps, with two native tests, C/C++ consumers,
  and eight LE vectors in each Java mode; native/C/C++ check all sixteen rows.
- Full root suite: 145/145 steps and 1,209 executed tests, including all 1,123
  compiler/backend tests; remaining test results were cached. Golden checks pass.
- Integration/interoperability: 37/37 steps and ten interop tests, including Java
  JNI, PMR and cross-file consumers.
- Native runtime: 98 tests pass with Zig 0.17 and 0.16. Both C package
  configurations pass their 101 tests (some results cached); scope/state ABI
  size/alignment/offset checks pass.
- System GCC/G++ consumers pass all vectors, truncation, failed fixed writes and
  C allocator checks against Debug and ReleaseSafe shared archives. The generated
  Zig fixture, selective readers and getter cleanup regression also pass Zig 0.16.
- C++ selected-reader/getter contract tests pass with exceptions enabled and
  disabled. A focused local C selected-code check also passes both byte orders,
  compact/extended headers and partial-allocation cleanup.
- The generator from the preceding projection checkpoint fails the independent
  optional writer vectors as expected. The independent vector builder reproduces
  its checked-in bytes; formatting and whitespace checks pass.

Next: finish fixed BCD extraction, decide package placement and switch production
builds/consumers after the remaining parity checks.
