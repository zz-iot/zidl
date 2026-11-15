# Skip/admission caller audit

Structural traversal, field projection, key extraction and sample admission are
different operations. A successful skip, returned field or computed hash does
not prove that every member in a sample is admissible. Generated API comments
now state this explicitly; skip semantics and public signatures are unchanged.

## Audited callers

| Caller family | Paths inspected | Contract and finding |
|---|---|---|
| Public skip and recursive skips | C/C++ aggregate/union `_skip`, Zig `skip`, Java struct `skip`, shared `cdr_skip` traversal | Delimited mutable/appendable bodies can be skipped without inspecting member IDs, duplicates, selection or MU flags. Extents remain bounded. Java union traversal currently decodes a discarded union, so it may reject more and allocate. |
| Allocation-free probes | Native sequence/map probes, C owning map probe, Zig map probe | Structural checks precede allocation; actual typed decoding still follows. Probes are not used as a substitute for decoding. A mutable-union map-value regression proves the subsequent decoder rejects missing discriminators even when its probe succeeds. |
| Selected fields and filtering | Native `_deserialize_selected`/`_get_field_from_cdr`, Zig `deserializeSelected`/`getFieldFromCdr`, Java member skipping | Projection decodes requested fields and skips others. This is appropriate for extraction/filter evaluation, not a complete-message validator. The stale Zig generator comment claiming full decoding for field extraction was corrected. |
| Key hashes from full payloads | Native `_compute_key_hash_from_cdr`, Java full-payload hash glue, Zig `computeKeyHashFromCdr` | Native and Java paths decode full values; Zig deliberately projects keys with structural skips. None is a general exact-extent admission API. A complete payload shape is distinct from proof of complete validation. |
| Stored-key retrieval | Generated native reader/writer `get_key_value` | Projects key fields from a stored full sample. It is retrieval, not the ingress validation boundary. |
| Typed sample reads | Generated C/C++/Zig/Java reader wrappers | Use ordinary full decoding for ALIVE samples and key decoding for lifecycle notifications, not public skip as their decoder. Ordinary DDS evolution defaults remain distinct from strict complete-message validation. |
| Explicit validated decoding | Zig `deserializeValidated` | Uses full `deserializeInto` with strict checks and exact final extent; it does not replace decoding with skip. Nested map probes are followed by strict typed reads. |
| Experimental wire typesupport | `typesupport_library` generated walkers and `zidl-typesupport.operations` | Uses its own allocation-free walkers over an explicitly restricted schema subset and checks exact extent. It does not delegate admission to aggregate fast skips. Its validate/key callbacks retain their checked status channel. |

No zidl-owned complete-sample validator was found that treats public skip success
as sufficient admission. Projection and hash APIs can still be misused by an
external caller; strengthening skip globally would change their purpose and
would not supply a middleware admission boundary.

## Independent regression witnesses

`test-skip-admission` compiles C, C++, Java and Zig fixtures. Little-endian XCDR2
records are hand-constructed independently of serializers:

- A final outer topic with key 7 and a mutable union body of length zero.
  Native/Zig skips accept its structural extent; full readers reject the missing
  discriminator. Java's union fallback decoder rejects even while traversing.
- A final outer topic with key 7 and a mutable struct containing unknown MU
  member 50. Aggregate fast skips accept the frame; full readers reject MU.
- A map with one integer key and an empty mutable-union value. Its structural
  probe succeeds but actual value decoding rejects; Zig allocation failpoints
  verify cleanup of reserved map storage.
- A valid sample followed by one extra byte. Skip consumes one value; Zig's
  explicit complete-message API rejects the trailing byte. Truncated and
  oversized frames still reject at the structural boundary.

Zig key projection, field extraction and key hashing can return key 7 from the
malformed non-key examples, demonstrating why their success is not admission.
A zero hash is also ambiguous: it represents both a valid zero-valued key and
the legacy hash callback's parse-failure fallback. Native full-payload hash
helpers reject the malformed examples without publishing a hash.

## Integration decision

A hash-returning legacy callback cannot communicate an admission error, and a
filter result does not validate unreferenced members. Consumers requiring
rejection before history/accounting must use a separate checked sample-processing
or validation hook. The experimental typesupport ABI has such a validate/status
contract; broadening legacy middleware registration is a separate integration
effort. No middleware checkout or callback ABI was modified by this audit.

There is no demonstrated need here for a new generic validated-skip API. Keep
structural skip and projection efficient, document their limits, and test the
actual admission boundary when wiring a consumer.

A subsequent [checked-processing slice](checked-sample-processing.md) adds native
ordinary-decode/hash callbacks and an opt-in checked middleware registration
path. It does not retroactively strengthen the legacy registrations audited here.

Native struct `_skip_key_value` helpers follow the same recursive key projection
as key-only readers so sequence preflight does not require omitted non-key fields.
Like ordinary skip helpers, they provide allocation-free structural traversal;
they do not validate an entire sample for admission.
