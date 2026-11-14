# Unsupported codec values

`UnsupportedLongDoubleCdrValue` rejects encoded IDL `long double` values in
C, C++, Java and Zig. XTypes maps this family to Float128; the existing codecs
instead used eight-byte double operations (or produced incompatible native
types). Explicit rejection prevents narrowing or silently wrong wire bytes.
Supporting the representation requires a separate codec implementation.

`--no-typesupport` still permits the existing declaration-only mappings.
It does not expand their capabilities: for example, C's map value restrictions
still reject `long double` map values. Constants and standalone aliases do not introduce codec roots. Aliases reached
from encoded fields still receive complete value-family validation; binding-only
interface-sequence aliases remain usable alongside ordinary value codecs.

`UnsupportedZigMapKey` rejects key representations the current Zig mapping
cannot hash with correct content semantics: bounded narrow strings, wide
strings, floating-point and unsupported aggregate/container keys. This check
also applies without codecs because those declarations instantiate unsupported
containers. Narrow unbounded strings, including aliases, use string-content
hashing; integer, boolean, character, enum and bitmask keys retain their mapping.
Other backends' supported string-key representations are unaffected.

Validation traverses aliases, collections and aggregate payloads before output,
including split-file entry points. `test-codec-diagnostics` checks CLI failures
leave no partial files and declaration-only long-double output still succeeds.
These errors complement the existing native dynamic/opaque diagnostics; they
are not a complete audit of every unsupported IDL feature.
