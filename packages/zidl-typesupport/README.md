# Experimental wire typesupport libraries

This prototype lets independently generated IDL projects supply wire typesupport
through a small C ABI. It does not depend on zzdds, XRCE, or a DDS entity builder.
The ABI is experimental (`0x80000001`), not a stable release commitment.

One library exports multiple type descriptors through `zidl_typesupport_query`.
Each descriptor names its type, supplies its standard minimal TypeIdentifier,
representation capabilities, keyedness, validation and full/key-only key-hash
callbacks. The library also exports the self-contained union of named dependency
objects. Equivalent objects are shared; providers and exported names remain distinct.
The C header is the layout authority; Zig uses build-time translation of that header.

## Generate and build

With Zig 0.17.0, from the zidl repository root:

```sh
zig build
zig-out/bin/zidl -b zig --experimental-typesupport-library \
  -o /tmp/application-types test/integration/typesupport_library/a.idl
zig build --build-file packages/zidl-typesupport/build.zig \
  -Dtypes=/tmp/application-types/a.zig \
  -Dprovider=/tmp/application-types/a_typesupport.zig \
  -Dname=project_a_types --prefix /tmp/application-types/install
```

The installed Linux artifact is `/tmp/application-types/install/lib/libproject_a_types.so`.
Replace the IDL and corresponding stems with your application's. Build each project
independently; no edits or relinking of the host are required. The generated wrapper
imports modules named `types`, `zidl_rt` and `zidl_typesupport`; the supplied recipe
wires one runtime module throughout the build. A zidl dependency also exposes
`module("zidl_typesupport")` using its existing runtime module.

If the default cache is read-only, set `ZIG_GLOBAL_CACHE_DIR` and
`ZIG_LOCAL_CACHE_DIR` to writable directories. No network packages are needed.
Libraries are local executable code trusted by the operator, not sandboxed schemas.

## Supported prototype subset

- Final, non-inherited structs, including nested structs.
- Ordinary final enums and typedef dependencies.
- Numeric primitives except long double; boolean, char and octet.
- Fixed primitive arrays; bounded strings and bounded primitive sequences.
- Scalar primitive keys, including non-leading keys and multiple keys.
- XCDR1/XCDR2 final-type encodings, both byte orders.

Collection bounds and individual array dimensions are limited to 65536. Native
values used by callbacks are limited to 64 KiB at compilation; decoding is bounded
and allocation-free using generated fixed-capacity storage. This is a prototype
stack bound, not an embedded footprint guarantee. The input must contain the exact
sample extent, with its four-byte DDS encapsulation and zero options: no RTPS
padding, representation guessing or implicit conversion.

The generator rejects unsupported shapes instead of exporting fallback TK_NONE
identities. These include unbounded data, optional members, inheritance, mutable/
appendable structs, unions, maps, fixed point, wide characters/strings, bitsets/
bitmasks, non-primitive sequences/arrays, aggregate/string/array keys, import files,
recursion, and unsupported annotations. Metadata support in the ordinary generator
is broader; this restriction applies only to the experimental library mode.
Split files, type prefixes, idiomatic enum renaming, older Zig output, XRCE profile,
PL-CDR, non-final default extensibility and suppression of typesupport/TypeObjects
are incompatible with this mode, including calls through the backend API.
Complete TypeObjects, assignability, TypeLookup and native-object ABI operations
are outside this prototype. The existing SHA-256 `type_identifier` convention is
not used as the standard identity.

## Ownership and failures

Descriptors and all metadata/function pointers are immutable, library-owned and
valid only while that exact library instance remains loaded. A static consumer
imports `library` directly and follows the same contract. There is no global
registration or library constructor side effect.

The host selects an export from an explicit provider; it must not resolve duplicate
names by load order. Minimal equivalence does not establish native ABI compatibility
or authorize merging assignable types. `checkLibrary` checks descriptor sizes,
features, enumeration limits, metadata hashes, named-dependency presence and duplicate
exports. It operates on trusted local descriptors; it is not a complete canonical
TypeObject parser or an assignability engine.

Callbacks are synchronous, reentrant, retain no inputs and allocate no heap memory.
A key-hash result is written only on success; a zero key hash is valid data, not an
error sentinel. `key_only_hash` accepts genuine key-only CDR, not full samples.
The query sets its output to null on ABI rejection. See the header for status codes.

Hosts must retain the supplying library through every use of its metadata and code.
The test hosts keep all handles open until use ends and then close them. This does
not implement generation management, concurrent unload, hot reload, zzdds registration
or entity migration. Those are responsibilities of consuming middleware.

## Verification

On Linux, from the repository root:

```sh
zig build test-typesupport-library
zig build test
```

The first step builds three independent libraries and checks equivalent/conflicting
exports through both a C host and a Zig host. It includes nested metadata/dependencies,
full/key-only key hashing, both byte orders and XCDR versions, malformed/truncated data,
bounds/enum/boolean/string validation, trailing bytes, ABI rejection, corrupted
metadata, duplicate exports, missing dependencies and static descriptor consumption.
The normal suite also runs unsupported-generation regressions and the existing
independent XTypes known-answer fixtures. The dynamic loader hosts are Linux-only;
other platforms and a frozen ABI require further qualification.
