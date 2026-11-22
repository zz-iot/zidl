# The C-ABI provider contract

Status: implemented for the Zig backend's `--zig-generate-c-api`.
Related: [`standalone-construction.md`](standalone-construction.md) (constructors),
[`handle-lifetime.md`](handle-lifetime.md) (retired handles),
[`binding-c-abi-identity.md`](binding-c-abi-identity.md) (one handle per object).

## The problem

zidl writes a module's C functions; a Zig provider (zzdds, for example) implements the
interfaces behind them. Some of what those functions need only the provider knows: how
to construct a `@standalone` object, and what an interface's nil is.

A nil is the value a provider returns when there is no object, such as a failed
`create_*`. In Zig it is `{ .ptr = zidl_bindings.NIL_PTR, .vtable = <the provider's nil
vtable> }`, and calling through it is safe. The C functions used to box a nil like any
other value, so a C caller received a non-NULL handle it had no way to tell from a real
one, and the NULL checks C callers write never fired. Going the other way, a NULL
handle passed as a function's object crashed, and a NULL entity argument became
`NIL_PTR` with an undefined vtable that every callee had to check before touching.

## The rule

At the C ABI, NULL is the nil of every interface:

- A NULL handle coming in, as a function's object, an entity argument or an entity
  attribute value, becomes the provider's nil of that type, and the call goes through
  it. The provider decides what a nil answers.
- A nil going out, as a result, an entity attribute or a sequence element, becomes NULL.
- An upcast (`<C>_as_<Base>`) of NULL, or of a nil, is NULL.

C++ and Java already turn a NULL handle into `nullptr` or `null`, and pass `nullptr` or
`null` in as NULL, so a failed `create_*` in either is now `nullptr` or `null` too.

## The provider

Each module scope with interfaces has `exportCAbi(comptime Provider: type)`. The provider
calls it once, from a `comptime` block, and it exports the C functions of every
interface declared directly in that module; a nested module has its own. Functions that
need no provider, such as a sequence's `_free`, are exported on their own as before.

`Provider` declares:

- `pub fn nil(comptime I: type) I`: its nil of each interface type the module's
  functions take or return, including another module's (an operation taking
  `DDS::Topic` needs `nil(DDS.Topic)`). A nil's `.ptr` is `zidl_bindings.NIL_PTR`, and
  it is never boxed: the generated functions never call its `get_c_abi_handle`.
- `pub fn constructors(comptime I: type) type`, when the module has a `@standalone`
  interface with `@constructor`s: see
  [`standalone-construction.md`](standalone-construction.md).
- `pub fn statics(comptime I: type) type`, when the module has an interface with
  `@static` operations: see [`static-operations.md`](static-operations.md).

A missing `nil` is a compile error from `exportCAbi`, and a type the provider has no nil
for is the provider's own compile error where it is used. Both are keyed by type, not
by name, so nested modules and cross-module arguments need nothing special.

```zig
comptime {
    S.exportCAbi(struct {
        pub fn nil(comptime I: type) I {
            if (I == S.Engine) return nil_engine;
            if (I == S.Condition) return nil_condition;
            @compileError("no nil for " ++ @typeName(I));
        }
        pub fn constructors(comptime I: type) type {
            if (I == S.Engine) return EngineCtors;
            @compileError("no constructors for " ++ @typeName(I));
        }
    });
}
```

## Zig statics and constructors

The C functions are not the only callers. Zig code using the generated interfaces needs
`@static` operations and `@constructor`s too, and has no `exportCAbi` call to receive the
provider from. With `--zig-provider-module <name>`, the generated module imports module
`<name>` and calls its `pub const zidl_provider`, the same type the provider passes to
`exportCAbi`:

```zig
// The provider module's root:
pub const zidl_provider = Provider;
```

```zig
// Generated, inside `pub const Registry = extern struct { ... }`:
const _zidl_provider = @import("provider").zidl_provider;

comptime {
    zidl_bindings.checkProviderStatic(_zidl_provider, Registry, "is_trigger_set", &.{S.Condition}, bool);
}

pub fn is_trigger_set(cond: S.Condition) bool {
    return _zidl_provider.statics(Registry).is_trigger_set(cond);
}
```

Parameters take the idiomatic forms the interface's methods take, a struct by value and a
string as a slice, and are passed on in the vtable-slot forms the provider declares. A
constructor takes a `std.mem.Allocator` first and returns the provider's error union. The
`comptime` block runs when the interface type is first used and checks that every static
and constructor exists with exactly the expected signature, so a provider gets the same
compile-time check of these functions that a vtable literal gets of its slots, whether or
not anything calls them. Without the flag, none of this is generated.

The generated module and the provider import each other, which Zig allows. A file can
belong to only one module, though, so a build with several modules rooted at the
provider's file (a library and a test, say) needs a generated module for each, each
importing its own provider.

## Why a call from the provider

The C functions are generated Zig compiled into the provider, but the generated module
cannot import the provider: the provider imports it. Passing the provider's pieces in at
compile time keeps the contract checked by the compiler, adds no symbols to the
provider's library, and is the same on every platform. Exporting the nils through the
linker instead was smaller, but matched by name, added symbols beside the public C API
and depended on each platform's symbol visibility.

## Limits

- An `out` or `inout` parameter of a single entity is not covered; no IDL has one.
- A callback adapter's entity arguments come from the provider and are never NULL.

## Tests

`test/integration/standalone/`'s provider supplies a nil for each interface, whose
`get_c_abi_handle` panics. Its Zig test calls the C functions with NULL objects and
arguments and checks nil results come back NULL; its C++ and Java tests check the same
through the bindings.
