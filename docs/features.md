# zidl — Feature Inventory

What each backend currently generates. Per-backend type mapping tables, limitations, and
test coverage. See the individual backend reference documents for generated function
signatures and options.

---

## Shared Baseline (all backends)

All four backends generate the same core set of outputs for every IDL input:

| Feature | Status |
|---|---|
| `struct` declarations (including inheritance) | Implemented |
| `enum` declarations | Implemented |
| `union` declarations | Implemented |
| `typedef` / type alias | Implemented |
| `const` declarations | Implemented |
| `bitmask` declarations | Implemented |
| `bitset` declarations | Implemented |
| `sequence<T>` (unbounded) | Implemented |
| `sequence<T, N>` (bounded) | Implemented |
| `T[N]` fixed-size arrays | Implemented |
| `string` (unbounded and bounded) | Implemented |
| `map<K, V>` | C: not supported (error); C++/Java/Zig: implemented |
| `@key` → `serializeKey` | Implemented |
| `@key` → `deserializeKey` | Implemented |
| `@key` → `computeKeyHash` (RTPS PLAIN_CDR2 + MD5 rule) | Implemented |
| `@optional` members | C: deferred; C++/Java/Zig: implemented |
| CDR `@final` (no framing) | Implemented |
| CDR `@appendable` (DHEADER) | Implemented |
| CDR `@mutable` (PL_CDR/EMHEADER) | Zig: `--pl-cdr` flag; C/C++: parsed, not yet emitted |
| `--generate-interfaces` DCPS binding layer | Zig/C/Java: implemented; C++: TODO stubs |
| `--split-files` (one file per type) | Implemented |

**TypeObject/TypeIdentifier** (Zig only): `struct`, `enum`, `bitmask` emit MinimalTypeObject
streams; `union`, `bitset`, `typedef` emit a TK_NONE placeholder (deferred).

---

## Zig Backend (`-b zig`)

**Reference**: [`backend_zig.md`](backend_zig.md)  
**Output**: `.zig` source  
**Runtime**: `zidl-rt` (included in this repo)  
**Tests**: 102 codegen + 8 integration + 61 runtime + 15 PL_CDR + 10 interop

### IDL → Zig type mapping

| IDL type | Zig type |
|---|---|
| `boolean` | `bool` |
| `octet` | `u8` |
| `char` | `u8` |
| `wchar` | `u16` |
| `short` / `int16` | `i16` |
| `unsigned short` / `uint16` | `u16` |
| `long` / `int32` | `i32` |
| `unsigned long` / `uint32` | `u32` |
| `long long` / `int64` | `i64` |
| `unsigned long long` / `uint64` | `u64` |
| `float` | `f32` |
| `double` | `f64` |
| `long double` | `f128` |
| `fixed<D,S>` | `f64` |
| `string` (unbounded) | `[]const u8` |
| `string<N>` (bounded) | `zidl_rt.BoundedString(N)` |
| `wstring` | `[]const u16` (`u16` literals unsupported — emits comment) |
| `sequence<T>` | `[]T` |
| `sequence<T, N>` | `zidl_rt.BoundedArray(T, N)` |
| `T[N]` | `[N]T` |
| `map<K,V>` | `std.AutoHashMap(K, V)` |
| `@optional T` | `?T` |
| `enum` | `enum(u32) { ... }` |
| `bitmask` | `packed struct(UNN) { ... }` |
| `bitset` | `packed struct(UNN) { ... }` |
| `struct` | `pub const Foo = struct { ... }` |
| `union` | `pub const Foo = union(enum) { ... }` |
| IDL module | Zig namespace (`pub const Foo = struct { ... }`) |

### Known limitations

| Feature | Status |
|---|---|
| `wstring` constants | Emits comment — `[]const u16` literals not supported in Zig |
| `@mutable` EMHEADER CDR | Only via `--pl-cdr` flag; not the default XCDR2 path |
| TypeObject for `union`, `bitset`, `typedef` | Deferred — emits TK_NONE placeholder |
| Union discriminant `wstring` / `fixed_pt` type | Emits TODO comment |
| Sequence element read: array-typedef elements | Emits TODO comment (rare case) |

---

## C Backend (`-b c`)

**Reference**: [`backend_c.md`](backend_c.md)  
**Output**: `.h` (declarations) + `.c` (CDR serialize/deserialize)  
**Runtime**: `zidl-cdr` (included in this repo)  
**Tests**: 55 codegen + C integration suite + 44 cross-validation

### IDL → C type mapping

| IDL type | C type |
|---|---|
| `boolean` | `uint8_t` (0/1) |
| `octet` | `uint8_t` |
| `char` | `char` |
| `wchar` | `uint16_t` |
| `short` / `int16` | `int16_t` |
| `unsigned short` / `uint16` | `uint16_t` |
| `long` / `int32` | `int32_t` |
| `unsigned long` / `uint32` | `uint32_t` |
| `long long` / `int64` | `int64_t` |
| `unsigned long long` / `uint64` | `uint64_t` |
| `float` | `float` |
| `double` | `double` |
| `long double` | `long double` |
| `fixed<D,S>` | `double` |
| `string` (unbounded) | `char *` |
| `string<N>` (bounded) | `char[N+1]` |
| `wstring` (unbounded) | `uint16_t *` |
| `wstring<N>` (bounded) | `uint16_t[N+1]` |
| `sequence<T>` | `typedef struct { T *data; uint32_t size; uint32_t maximum; } FooSeq;` |
| `T[N]` | `T name[N]` |
| `map<K,V>` | **Not supported** — error at codegen time |
| `@optional T` | **Deferred** — emits `/* TODO: @optional name */` |
| `enum` | `typedef enum { ... } Foo; ` (CDR: `uint32_t`) |
| `bitmask` | `typedef uint8/16/32/64_t Foo;` (storage sized by `@bit_bound`) |
| `bitset` | `typedef uint8/16/32/64_t Foo;` |
| `struct` | `typedef struct _Foo { ... } Foo;` |
| `union` | `typedef struct _Foo { ... } Foo;` (discriminant + data union) |
| IDL module | C name prefix (e.g. `Ns_Foo`) |

### Known limitations

| Feature | Status |
|---|---|
| `map<K,V>` | Not supported (`error.MapTypeNotSupportedInCBackend`) |
| `@optional` members | Deferred — emits `/* TODO */` comment |
| `@optional` key fields | Deferred — key serialization emits `/* TODO */` |
| `--pl-cdr` (PL_CDR emit) | Flag parsed but C backend does not yet emit PL_CDR functions |
| Union discriminant: complex types | Emits `/* TODO: unsupported discriminant */` |
| `--generate-interfaces`: complex-type adaptation | `emitImplOp` emits `/* TODO */` stubs |

---

## C++ Backend (`-b cpp`)

**Reference**: [`backend_cpp.md`](backend_cpp.md)  
**Output**: `.hpp` (header-only — declarations + inline serialize/deserialize)  
**Runtime**: `zidl-cdr` (included in this repo)  
**Tests**: 72 codegen + C++ integration suite

### IDL → C++ type mapping

| IDL type | C++ type |
|---|---|
| `boolean` | `bool` |
| `octet` | `uint8_t` |
| `char` | `char` |
| `wchar` | `wchar_t` |
| `short` / `int16` | `int16_t` |
| `unsigned short` / `uint16` | `uint16_t` |
| `long` / `int32` | `int32_t` |
| `unsigned long` / `uint32` | `uint32_t` |
| `long long` / `int64` | `int64_t` |
| `unsigned long long` / `uint64` | `uint64_t` |
| `float` | `float` |
| `double` | `double` |
| `long double` | `long double` |
| `fixed<D,S>` | `double` |
| `string` (unbounded) | `std::string` |
| `string<N>` (bounded) | `zidl::BoundedString<N>` |
| `wstring` | `std::wstring` |
| `sequence<T>` | `std::vector<T>` |
| `T[N]` | `std::array<T, N>` |
| `map<K,V>` | `std::map<K, V>` |
| `@optional T` | `std::optional<T>` |
| `enum` | `enum class Foo : uint32_t { ... }` |
| `bitmask` | `enum class Foo : uint8/16/32/64_t { ... }` |
| `bitset` | `struct Foo` with integer storage member |
| `struct` | `struct Foo` (with `: public Base` for inheritance) |
| `union` | `class Foo` with `_d()` accessor + anonymous union |
| IDL module | C++ namespace |

### Known limitations

| Feature | Status |
|---|---|
| `--pl-cdr` (PL_CDR emit) | Flag parsed but C++ backend does not yet emit PL_CDR functions |
| Union discriminant: complex types | Emits `/* TODO: unsupported discriminant */` |
| `--generate-interfaces`: complex-type adaptation | `emitImplOp` emits `/* TODO: adapt C++ types */` stubs |

---

## Java Backend (`-b java`)

**Reference**: [`backend_java.md`](backend_java.md)  
**Output**: `.java` (one file per module or one per type with `--split-files`)  
**Runtime**: none — CDR is inline  
**Tests**: 56 codegen + Java integration suite

### IDL → Java type mapping

| IDL type | Java type |
|---|---|
| `boolean` | `boolean` |
| `octet` | `byte` |
| `char` | `char` |
| `wchar` | `char` |
| `short` / `int16` | `short` |
| `unsigned short` / `uint16` | `short` |
| `long` / `int32` | `int` |
| `unsigned long` / `uint32` | `int` |
| `long long` / `int64` | `long` |
| `unsigned long long` / `uint64` | `long` |
| `float` | `float` |
| `double` | `double` |
| `long double` | `double` |
| `fixed<D,S>` | emits literal value |
| `string` / `wstring` | `String` |
| `sequence<T>` | `java.util.ArrayList<T>` |
| `T[N]` | `T[]` |
| `map<K,V>` | `java.util.Map<K, V>` |
| `@optional T` | nullable field (`T` with `null` default) |
| `enum` | Java `enum` with `int value` field and `fromValue(int)` factory |
| `bitmask` | Java `enum` with `int value` field |
| `bitset` | `class` with integer storage field |
| `struct` | Java `class` (public fields, default constructor, copy constructor) |
| `union` | Java `class` with discriminant field + typed case accessors |
| IDL module | Java package (prepended with `--java-package` prefix) |

### Known limitations

| Feature | Status |
|---|---|
| `bitset` CDR serialization | Emits `// TODO: bitset` (no standard Java mapping defined) |
| `any` / `object` / `value_base` member access | Emits `// TODO: any/object` |
| `@mutable` EMHEADER CDR | Not implemented (same as C/C++) |

---

## Key Serialization (all backends)

For every struct with at least one `@key` member, all backends emit three additional functions:

| Function | Purpose |
|---|---|
| `serializeKey` | Serializes only `@key` members as canonical PLAIN_CDR2 big-endian |
| `deserializeKey` | Reads only `@key` members from a full CDR stream; skips non-key fields |
| `computeKeyHash` | Applies the RTPS §9.6.4.8 rule: key ≤ 16 bytes → zero-pad; key > 16 bytes → MD5 |

MD5 dependency per language: `std.crypto.hash.Md5` (Zig), `zidl_md5` in `zidl_cdr.c` (C/C++),
`java.security.MessageDigest` (Java).

---

## TypeObject / TypeIdentifier (Zig only)

The Zig backend emits MinimalTypeObject XCDR2 LE streams for all types in the IR.
These are verified against Cyclone DDS 11.0.1.

| Type | MinimalTypeObject | EquivalenceHash |
|---|---|---|
| `struct` | Implemented | Verified against Cyclone DDS |
| `enum` | Implemented | Verified against Cyclone DDS |
| `bitmask` | Implemented | Verified against Cyclone DDS |
| `union` | Deferred (TK_NONE placeholder) | — |
| `bitset` | Deferred (TK_NONE placeholder) | — |
| `typedef` / alias | Deferred (TK_NONE placeholder) | — |

**EquivalenceHash** (`[14]u8`): on-wire DDS-XTypes type identifier used by Cyclone, FastDDS,
and other DDS implementations.  
**TypeIdentifier** (`[32]u8`): SHA-256 of type object bytes; zidl-internal convention for
out-of-band tooling (not transmitted over RTPS).
