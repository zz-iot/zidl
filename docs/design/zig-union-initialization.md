# Zig union initialization

The anonymous payload remains an ordinary Zig union. Its field initializer is a
switch over the mapping's default discriminator, selecting a whole-union literal
with the corresponding arm's mapping default. An unmatched discriminator with no
default arm has no active logical payload; no generated lifecycle operation
accesses its storage.

This preserves the existing `_d`/`_u` API and permits non-extern nested aggregates.
It avoids an extern-union ABI restriction and does not introduce a second public
discriminator. Callers changing cases must still assign `_d` and a matching whole
`_u` literal together. Mutating `_d` alone does not switch the payload's active arm.

Array defaults replicate initialized element values with typed `@splat`, including
nested arrays and array typedefs. Byte-zeroing an aggregate cannot establish the
proper active field for its nested unions. Optional decode temporaries use the
same mapping defaults before registering cleanup.

Mutable decoding requires a discriminator but can now default an omitted selected
arm, following XTypes 1.3 section 7.2.2.4.4.4.7. The decoder publishes the initialized
arm and discriminator together. These synthesized defaults own no allocation;
subsequent deinitialization is safe. A later explicitly decoded payload retains the
existing publication/rollback contract.

The compiled union-safety fixture covers owning explicit/default arms, enum
discriminators, nested structs, arrays of unions, optional aggregate failure
cleanup, cloning, serialization, repeated deinitialization and missing payloads
in both byte orders. Generated Zig snapshots change only initializers. Wire bytes
and TypeObject identities are unchanged.
