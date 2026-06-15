# Implementation Status and Design Notes

> **Contributor reference.** This document is internal developer documentation:
> per-source-file design notes, test counts, key invariants, and known limitations.
> For the pipeline architecture and design decisions at each stage, see
> [`architecture.md`](architecture.md). For what each backend generates and its
> current feature coverage, see [`features.md`](features.md).

Current verification inventory:
- `zig build test`: 783 tests passed (771 library tests, 1 CLI test, 11 Zig integration tests) plus golden-output comparison. C/C++/Java integration tests run separately via `zig build integration-test`.
- `zig build integration-test`: compile-and-run integration for generated C, C++, and Java code.
- `zig build interop-test`: 10 committed CDR interop vector tests.
- `packages/zidl-rt`: 61 Zig runtime tests.
- `packages/zidl-cdr`: 44 CDR cross-validation tests.

---

## src/backend/c.zig

**Output:** One `.h` file (declarations) + one `.c` file (CDR serialize/deserialize).

**Key decisions:**
- C structs map IDL struct members 1-to-1. No struct inheritance; base members
  are manually inlined (base struct embedded as first field named `_base`).
- `typedef struct _Foo { … } Foo;` pattern for all structs.
- Enum: `typedef enum { … } Foo;` → CDR encodes as `uint32_t` always.
- Sequence: `typedef struct { T* data; uint32_t size; uint32_t maximum; } FooSeq;`
- CDR serialize functions: `int Foo_serialize(ZidlCdrWriter* w, const Foo* v)`.
- CDR deserialize functions: `int Foo_deserialize(ZidlCdrReader* r, Foo* v)`. Unbounded strings and sequences are currently heap-allocated by `zidl_cdr_read_string` / `zidl_cdr_read_seq_*` using `malloc`; callers are responsible for freeing them. A `ZidlCdrAllocator` user-supplied allocator interface is planned but not yet implemented.
- Keyed structs emit `Foo_serialize_key`, `Foo_deserialize_key`, and
  `Foo_compute_key_hash`. Key hashes serialize keys as canonical PLAIN_CDR2
  big-endian, then apply the RTPS <=16-byte padding / MD5 rule via `zidl-cdr`.
- `@optional` members: `uint64_t _present` bitmask (bit N = optional member N, counted in declaration order). Max 64 per struct (error at codegen); `_has_NAME(p)` and `_set_NAME(p, v)` macros; `_set_` suppressed for array-backed members (fixed arrays and bounded strings/wstrings). Deserialize clears `_present` before reading.
- `@default` on `@optional` members: emits `void Foo_apply_defaults(Foo *v)` that fills absent optional members with their IDL defaults. `@default` on non-optional members is rejected at codegen time (`error.DefaultOnNonOptionalNotSupportedInCBackend`).
- Include guards: `#ifndef PREFIX_FOO_H` / `#define PREFIX_FOO_H` / `#endif`.

**Tests:** 87.

---

## src/backend/cpp.zig

**Output:** One `.hpp` file (declarations + inline serialize/deserialize).

**Key decisions:**
- C++11 target (formal/25-03-03 IDL4-native mapping).
- Namespaces: IDL modules → C++ namespaces, nested correctly.
- Structs: plain `struct` with public member fields, default member initializers.
- Inheritance: `: public Base`.
- Sequences: `std::vector<T>` (default allocator; `std::pmr` / custom allocator support planned).
- Strings: `std::string` for both unbounded and bounded variants (bound enforced
  at CDR serialize time; no separate C++ bounded-string type is generated; default allocator).
- Enums: `enum class Foo : uint32_t { … }`.
- Optional members: `std::optional<T>`.
- Serialize/deserialize declared as free functions `zidl_serialize(w, v)` /
  `zidl_deserialize(r, v)` — overloaded per type.
- Keyed structs emit C ABI helpers `Foo_serialize_key`, `Foo_deserialize_key`,
  and `Foo_compute_key_hash` using the same canonical PLAIN_CDR2 big-endian key
  hash rule as C.
- `@verbatim` annotations are preserved in the IR as raw annotations but are not
  yet acted on by the C++ backend (planned: injection at `BEGIN_FILE`,
  `BEFORE_DECLARATION`, etc. filtered by `language == "c++"` or `language == "*"`).

**Tests:** 88.

---

## src/backend/java.zig

**Output:** One `.java` file per top-level IDL module or one per type (split mode).

**Key decisions:**
- IDL4-to-Java mapping (formal/21-08-01 v1.0).
- Modules → Java packages (`--java-package` prepended).
- Structs → Java classes with public fields, default constructor, copy constructor.
- Enums → Java `enum` with a numeric `value` field, `fromValue(int)` factory.
- Sequences → `java.util.ArrayList<T>`.
- CDR serialize/deserialize: `public static void serialize(ZidlCdrWriter w, T v)`
  and `public static T deserialize(ZidlCdrReader r)`.
- Keyed structs emit `serializeKey`, `deserializeKey`, `deserializeKeyInto`, and
  `computeKeyHash`; MD5 uses `java.security.MessageDigest`.
- JNI bridge: when `--generate-interfaces`, emits a `*Impl.java` class with
  `System.loadLibrary(jni_library)`.
- Package annotation: `package com.example;` header per file.

**Tests:** 68.

---

## src/backend/zig.zig

Zig language mapping backend. See `docs/backend_zig.md` for comprehensive reference.
Keyed structs emit `serializeKey`, `deserializeKey`, `deserializeKeyInto`, and
`computeKeyHash`. `computeKeyHash` uses `zidl_rt.KeyHashWriter` for canonical
PLAIN_CDR2 big-endian key serialization and RTPS key-hash finalization.

**Tests:** 132.

### PL_CDR (`--zig-pl-cdr`)

When `opts.pl_cdr && struct.extensibility == .mutable`, emits additional functions alongside
the normal XCDR2 serialize/deserialize:

```zig
fn serializePlCdr(writer: *zidl_rt.PlCdrWriter, value: @This()) !void
fn deserializeFromPlCdr(out: *@This(), reader: *zidl_rt.CdrReader, allocator: std.mem.Allocator) !void
```

- PID = `@id(N)` if present on the member, else sequential member index (same as EMHEADER)
- `@optional` members: serialize skips if null (no presence byte); deserialize assigns if PID seen
- `deserializeFromPlCdr` always calls `seekTo(_p.end_pos)` after each param (handles unknown PIDs)
- `@pl_repeated` on a `sequence<T>` member: serialize emits one PID entry per element (no count
  prefix); deserialize appends one element per occurrence of the PID
- `@pl_repeated` on a non-sequence member is a build-time error (`error.PlRepeatedOnNonSequence`
  from the IR builder)

**Tests:** 15 new (9 codegen + 6 zidl-rt round-trip).

---

## src/backend/zig_typeobject.zig

TypeObject/TypeIdentifier encoder. See `docs/xtypes_typeobject.md` for the
XTypes stream format. Key implementation notes:

- `Encoder` struct writes into a growing `std.ArrayList(u8)`.
- `writeEncapHeader()`: writes 4-byte encap header, resets `pos` to 0 so all
  subsequent alignment is relative to CDR payload start (not buffer start).
- `nameHash(name)`: MD5 of UTF-8 name bytes, returns `[4]u8`.
- `computeEquivalenceHash(bytes)`: MD5 of the full type object bytes (including
  encap header), returns `[14]u8`.
- `computeTypeIdentifier(bytes)`: SHA-256 of type object bytes, returns `[32]u8`.
- `encodeMinimalStruct`, `encodeMinimalEnum`, `encodeMinimalUnion`,
  `encodeMinimalBitmask`, and `encodeMinimalBitset` produce spec-compliant
  MinimalTypeObject streams verified against Cyclone DDS.
- `src/backend/zig_typeobject_proto.zig`: prototype/scratch file used during
  initial implementation; not part of production pipeline.
- **Housekeeping**: `zig_typeobject.zig` imports the `zidl-xtypes` package for
  all `TK_*`/`EK_*`/`IS_*` constants.

**Tests:** 29.

---

## src/main.zig

CLI entry point. Parses argv, drives preprocessor → parser → semantic → IR → backend.
Validates `--profile xrce` before invoking backends.

Key behavior:
- Multiple input files are each processed as an independent compilation unit.
  The full pipeline (preprocess → parse → semantic → IR → backend) runs once per
  file; types defined in one input file are not visible to another.
- `-E` flag: preprocess only, emit expanded IDL to stdout, exit.
- Backend selection: `-b c` / `-b cpp` / `-b java` / `-b zig`.
- `--split-files`: passed through to backend; semantics are backend-specific.
- `SOURCE_DATE_EPOCH`: when set, drives deterministic UTC `__DATE__` / `__TIME__`
  expansion in the preprocessor; invalid values are rejected before generation.

---

## src/root.zig

Library root for use as a Zig package. Re-exports submodules: `ast`, `lexer`,
`preprocessor`, `parser`, `semantic`, `ir`, `backend`, `test_corpus`. Also
has a top-level `test` block that calls `refAllDecls` to ensure every submodule's
test blocks are discovered by `zig build test`.

---

## packages/zidl-rt/

Zig CDR runtime. `src/cdr.zig` — see `docs/runtime_libraries.md`.
`src/root.zig` — re-exports `CdrWriter`, `CdrReader`, `BoundedArray`, constants.
Includes `KeyHashWriter`, a canonical RTPS key-hash writer that emits PLAIN_CDR2
big-endian bytes, keeps the first 16 bytes, and streams the full key into MD5.

**Tests:** 61 (comprehensive CDR round-trip tests, including PL_CDR and key-hash tests).

---

## packages/zidl-cdr/

Standalone C99 CDR library. `include/zidl_cdr.h` + `src/zidl_cdr.c`.
See `docs/runtime_libraries.md` and `docs/xcdr_encoding.md` for API reference.
Includes `zidl_md5` and `zidl_cdr_compute_key_hash` for generated C/C++ key hashes.

Cross-validated byte-for-byte against `zidl-rt` (44 tests, including PL_CDR and key-hash cross-validation).

---

## packages/zidl-xtypes/

Zig package exporting all XTypes constants (`EK_*`, `TK_*`, `TI_*`, flag values).
See `docs/xtypes_typeobject.md`.

No tests — pure constant definitions.

---

## interop/

Cyclone DDS interoperability harness. Requires a Cyclone DDS checkout.
`make -C interop test` compiles zidl-generated C code alongside Cyclone DDS
and verifies byte-for-byte CDR stream equality.

**Tests:** 10.

---

## test/

Integration tests. Run with `zig build integration-test`.
Compile-and-run tests for generated C, C++, and Java backends. Zig generated-code
integration tests run as part of `zig build test`.

**Tests:** 11 integration tests (Zig integration tests run as part of `zig build test`; C/C++/Java integration tests run via `zig build integration-test`).

---

## Known Limitations (current)

| Feature | Status |
|---|---|
| C backend: `map<K,V>` | Not supported (`error.MapTypeNotSupportedInCBackend`); no DDS vendor generates C maps; banned in XRCE |
| C backend: `@optional` > 64 members | Returns `error.TooManyOptionalMembers` at codegen time |
| C backend: `_set_` macro for array-backed `@optional` | Not emitted — use direct field assignment + manual `_present` bit update |
| C backend: `@default` on non-optional member | Returns `error.DefaultOnNonOptionalNotSupportedInCBackend` at codegen time |
| C backend: `@optional` `_set_` macro shape-aware setter | No `memcpy`-based setter for fixed arrays / bounded strings — future work |
| C backend: user-supplied allocator | `ZidlCdrAllocator` interface planned; strings/sequences currently use `malloc` |
| C++ backend: custom STL allocators | `std::string`, `std::vector`, `std::map` use default allocators; `std::pmr` support planned |
| C/C++ backends: PL_CDR codegen | `--zig-pl-cdr` flag is parsed and wired but C/C++ backends do not yet emit PL_CDR functions |
| Zig 0.15.1 / MicroZig output | Partially implemented: `--zig-version 0.15.1` is wired and bounded strings/sequences use fixed-capacity `zidl_rt.BoundedArray`; full freestanding/no-heap runtime path remains planned |
| `--generate-interfaces` C++: complex-type adaptation | `ImplGenerator.emitImplOp` emits `/* TODO */` stubs — ABI boundary must be decided with DDS runtime |
| Const type-checking | Not implemented (e.g. `const long x = "hello"` is not caught) |
| Union discriminant type validation | Not implemented |
| TypeObject for typedef/alias | Deferred |
| PL_CDR serialization (RTPS ParameterList) | Zig only via `--zig-pl-cdr`; C/C++ backends do not emit PL_CDR functions |
| value_dcl / component_dcl / home_dcl / template modules | Parsed, silently dropped + warning diagnostic |
