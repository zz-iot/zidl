# Mutable union codec audit

XTypes 1.3 sections 7.2.2.4.4.4.6 and 7.4.3.4.2 require a union discriminator's
must-understand attribute and its corresponding EMHEADER bit. This slice corrects
C `emitUnionFns`, C++ `emitUnionFns` and Java `emitUnionCdr` to match Zig. The
shared canonical-key fixture's `UnionDefault` ordinary wire sample now expects
`0xa0000000` for its four-byte discriminator header. Canonical key serialization
has no such header and is unchanged.

The remaining audit findings are separate from this flag correction:

| Path | Member admission | Required follow-up |
|---|---|---|
| Zig union `deserializeInto` | Dispatches by normalized ID; checks selection, duplicate/order/discriminator presence, known extents and unknown MU members | Keep ordinary omitted-arm evolution defaults and opt-in complete-message validation distinct |
| C union `emitUnionFns` reader | Dispatches by ID and checks discriminator agreement, duplicate/order/presence, extents and unknown MU members | Caller supplies initialized output and frees partial owning results; release prior owning output before reuse |
| C++ union `emitUnionFns` reader | Every nonzero ID switches on `_d()` | Same admission checks; ensure setters/discriminator transitions retain RAII safety |
| Java union `emitUnionCdr` reader | Already dispatches by member ID | Add discriminator agreement, duplicate/order/presence and known extent checks; GC does not supply logical admission |
| Mutable aggregate/union fast skip (native) | Trusts DHEADER for structural extent and advances to its end | This is structural traversal, not validated admission; do not use it to authorize untrusted messages |
| Java union | No public generic `skip` method | Audit callers which deserialize while skipping rather than assume a missing API provides validation |

The original native reader counterexample is an ID-0 long discriminator of
zero followed by an LC-2 parameter with unknown ID 50 and value `0x01020304`.
For `IdChoice` in canonical_keys/keys.idl, zero selects the default arm (ID 11),
so ID 50 must not be interpreted as that arm. The former C and current C++ readers' ID-zero/
nonzero split instead reaches the default-arm payload decoder. Setting the
unknown parameter's MU bit does not fix that dispatch. Duplicate owning values
and a later discriminator change also need dedicated cleanup/reuse regressions.

The C/C++/Java decoder work should be separate small PRs with the same independent
malformed records used by the Zig fixture, plus owning/default and nested cases.
Changing skip semantics globally would conflate structural traversal with
admission; a validated decoder is the explicit API for complete-message checks.

C admission is covered by `test-native-union-admission`, using independently
constructed LE/BE parameters, owning strings and sequences, late failures,
allocation failpoints, enum/default-first cases and all truncated prefixes.
C output must be initialized and prior owned contents released before decoding;
the decoder preserves the established caller-free partial-output contract.
