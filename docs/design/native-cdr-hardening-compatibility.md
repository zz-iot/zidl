# Native CDR hardening compatibility

These changes require regenerating bindings and rebuilding matching consumers.
They do not change the shared C allocator ABI or the process-wide allocator policy.

| Area | Compatibility consequence |
|---|---|
| C bounded string/wstring arrays and typedefs | Correct native dimensions and inline alias storage replace declarations that disagreed with codec indexing. Rebuild C/C++ consumers together; wire string encoding is unchanged. |
| Canonical collection keys | Correct DHEADERs and schema maxima can change instance hashes. Participants with affected key schemas must deploy matching generators together; ordinary sample/key-only wire representations are otherwise unchanged. |
| C++ direct optional arrays | Fields now use optional nested `std::array` storage rather than invalid bare arrays receiving optional operations. Optional array typedefs keep their alias types. |
| C++ reused mutable samples | Omitted projected optionals disengage. Key-only reads preserve non-key state. |
| C++ allocation failures | Public codec readers translate `bad_alloc` and `length_error` into checked statuses when exceptions are enabled. STL/PMR mappings remain; exception-disabled users requiring recoverable exhaustion use C values/codecs and non-throwing allocator callbacks. |
| Zig union defaults | Fresh payloads select the mapping-default arm, including nested owning aggregates/arrays. Callers changing cases still set matching discriminator and whole payload literals together. |
| Zig validated admission | New opt-in `deserializeValidated` requires exact message extent and required mutable fields, propagates strict checks, preserves reader state on failure and cleans owning output. Ordinary evolution defaults remain available. |
| Mutable union writers | All backends set the required discriminator MU bit. Canonical keys and TypeObject identities are unchanged by this flag correction. |
| Mutable union readers | C/C++/Java now check member IDs, selected arm, discriminator order/presence, duplicates and known extents. C preserves caller-free partial output; C++ commits a local owning candidate; Java returns a fresh result. |
| Unsupported long double codecs | C/C++/Java/Zig reject codec generation rather than emit eight-byte operations for the Float128 value family. Declaration-only mappings retain their existing limitations. |
| Zig map keys | Unsupported bounded narrow strings, wide strings and other unsupported key representations fail explicitly, including declaration-only output. Unbounded narrow-string aliases use content hashing. |
| Existing C++/Java/Zig maps | Duplicate keys reject; declared bounds are checked. C++ nonprimitive XCDR2 maps gain the required delimiter; regenerate both peers. Zig map cleanup/clone owns keys and values recursively. |
| Ordinary mutable XCDR1 | Unsupported DHEADER/EMHEADER framing now fails explicitly instead of being emitted as XCDR1. Appendable XCDR1, XCDR2 and discovery PL_CDR helpers retain their contracts. |
| Unsupported dynamic/opaque wire values | Native C/C++/Zig generation rejects these before codec output. Declarations-only mode and opaque binding declarations remain available. |
| C maps | New typed value/codec representation supports explicit borrowed/owned buffers, checked extents/bounds, duplicate keys and partial cleanup. Interface/callback and middleware adapters remain separate and explicitly rejected. |

C non-primitive XCDR2 maps use DHEADER + count + pairs, following the correction
in [OMG DDSXTY14-72](https://issues.omg.org/issues/DDSXTY14-72). The older local
1.3 PDF omits that count in rule (15). The corrected count-bearing form is the
only supported form; no heuristic accepts both. See [map codecs](native-cdr-map-codecs.md)
for explicit byte witnesses, allocation tests and the limits of a raw Fast CDR
library comparison. The [existing map codec audit](map-codec-hardening.md) covers corrected C++, Java
and Zig paths using independent wire witnesses and owning failure tests.

The [mutable-union audit](mutable-union-audit.md) records the completed
C/C++/Java/Zig admission checks. Generic skip methods provide structural traversal and
must not be treated as validated message admission. C map duplicate checks are
quadratic; choose schema bounds that fit an untrusted input CPU budget.

Relevant regression fixtures cover compiled C/C++/Zig/Java output, independent
canonical and ordinary-wire witnesses, both byte orders, counting/fixed writers,
truncations, every allocation failpoint and idempotent cleanup. Generated snapshots
and tests pass with the changes combined, not only as independent branches.
