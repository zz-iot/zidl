# C-ABI interface / callback type coverage

The C-ABI primary-interface design commits to a hard constraint: **every type that appears
in a vtable slot or `@callback` listener callback parameter must be C-ABI representable.**
All DDS DCPS status types satisfy it today (flat structs of primitives, enums, fixed-size
handles). This doc tracks test coverage for that guarantee and the mitigation designs for
types that currently fail it. Roadmap keeps a one-line pointer here.

## Positive test coverage

Test cases that should exist in the backend unit suites confirming a type category works as
an interface / `@callback` parameter.

| Type category | IDL example | Status |
|---|---|---|
| All primitive types | `void f(in long x, in boolean b)` | ✓ existing golden |
| Named struct parameter | `void f(in MyStatus s)` | ✓ existing golden |
| Named sequence typedef parameter | `void f(in StringSeq s)` | ✓ DDS listener golden |
| Named enum parameter | `void f(in MyEnum e)` | ✓ existing golden |
| `string` parameter | `void f(in string s)` | ✓ existing golden |
| Entity fat-pointer parameter | `void on_data(in DataReader r)` | ✓ DDS listener golden |
| **Fixed-size array typedef parameter** | `void f(in MyByteArray a)` | **missing** — add to `types.idl` golden |
| **Nested named struct parameter** | `void f(in OuterStatus s)` | **missing** — add to `types.idl` golden |

## Negative test coverage

Each case **must** produce a named generator error, not a `// TODO` comment or `void *`
fallback (which compiles but is wrong at runtime). Each needs a dedicated unit test in
`src/backend/zig.zig` and `src/backend/c.zig` asserting the generator returns an error.

| Type category | IDL example | Current behaviour | Target behaviour |
|---|---|---|---|
| `map<K,V>` parameter | `void f(in map<string,long> m)` | C errors on map in structs; interface/callback position not separately tested | Hard error: "map not C-ABI representable in interface parameter; use a named opaque typedef" |
| Anonymous/inline sequence parameter | `void f(in sequence<string> s)` | Untested; likely silent wrong emit | Hard error: "anonymous sequence not C-ABI representable; add a typedef" |
| Discriminated union parameter | `void f(in MyUnion u)` | No union-in-interface test; output untested | Hard error: "union not C-ABI representable in interface parameter (C union is untagged)" |
| `wstring` parameter | `void f(in wstring s)` | Emits `wchar_t *`; platform-width-dependent | Warning or hard error: "wstring ABI width is platform-dependent; use a fixed-width typedef" |
| `fixed<D,S>` parameter | `void f(in fixed<10,2> x)` | Emits `// TODO` comment | Hard error: "fixed_pt not C-ABI representable in interface parameter" |
| `valuetype` parameter | `void f(in MyValueType v)` | Untested | Hard error |
| Sequence-of-non-C-type typedef | `typedef sequence<MyUnion> UnionSeq; void f(in UnionSeq s)` | Untested; element type check missing | Hard error propagating from union element |

## Mitigation work

What it would take to move each negative case into the positive column, ordered by impact
(likelihood in real DDS-adjacent IDL) and complexity.

### 1. Anonymous/inline sequences → synthesize a typedef — *impact medium, risk low*

When `sequence<T>` appears directly as an interface parameter with no prior typedef,
auto-synthesize `typedef sequence<T> _ZidlGen_<Iface>_<Op>_<Param>_Seq;` and emit its extern
struct before the callback struct / vtable declaration. Purely mechanical.

### 2. Discriminated union → OMG C PSM companion struct — *impact medium, risk medium*

IDL `union` has no direct C-ABI equivalent (C unions are untagged). The OMG C PSM
(formal/02-06-01) maps it to:

```c
typedef struct MyUnion {
    long _d;                 /* discriminant */
    union { MyStruct s; long n; bool b; } _u;
} MyUnion;
```

The Zig side stays a tagged union; a generated conversion function translates in the
`@callback` comptime thunk. Well-specified but non-trivial to wire into the thunk generator.

### 3. `wstring` → fixed-width `uint16_t *` — *impact low, risk low once decided*

RTPS encodes wstring as UTF-16LE (2-byte code units); platform `wchar_t` is the wrong type
for cross-ABI use. Replace with `uint16_t *` (or `typedef uint16_t DDS_WChar; DDS_WChar *`).
Breaks existing C callers passing `wchar_t` literals.

### 4. `fixed<D,S>` → runtime struct — *impact very low, risk very low*

`typedef struct { uint8_t digits[16]; uint8_t scale; } zidl_fixed_t;` in `zidl_cdr.h`; emit
`zidl_fixed_t` for `fixed<D,S>` parameters. No precision validation in the ABI.

### 5. `map<K,V>` → opaque handle + accessors — *impact low, risk high*

`typedef struct ZidlMap_s *ZidlMap;` with generated `ZidlMap_get` / `ZidlMap_set` /
`ZidlMap_iter`; the thunk wraps a pointer to the native Zig hash map. Maps rarely appear in
DDS API surfaces (mostly in user data types, which bypass the vtable as opaque CDR bytes).
**Deferred until a concrete DDS-API IDL use case arises.**
