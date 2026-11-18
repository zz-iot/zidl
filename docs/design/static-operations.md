# Static operations

Status: implemented for the C, Zig (`--zig-generate-c-api`), C++ (`--cpp-generate-impl`)
and Java backends. Related: [`standalone-construction.md`](standalone-construction.md)
(operations with no receiver that create an owned object),
[`c-abi-provider.md`](c-abi-provider.md) (what the provider supplies),
[`handle-lifetime.md`](handle-lifetime.md) (retiring a freed handle's wrappers).

## The problem

Some operations belong to an interface rather than to an object. DDS's
`DomainParticipantFactory::get_instance()` returns the process-wide factory, and
DDS-XTypes gives `DynamicTypeBuilderFactory` and `DynamicDataFactory` a
`get_instance()`/`delete_instance()` pair. IDL has no syntax for a static operation: the
specs write them as ordinary operations commented `/*static*/`, and each language
mapping provides them by hand. A `@constructor` will not do: its result is owned, so
dropping the last C++ reference to a singleton would release it.

## The IDL

```idl
interface DomainParticipantFactory {
    @static DomainParticipantFactory get_instance();
    @static ReturnCode_t delete_instance();
    DomainParticipant create_participant(/* ... */);
};
```

Another IDL compiler sees two ordinary operations, as the specs' own comments do. The
builder checks:

| Rule | Why |
| --- | --- |
| No receiver, no vtable slot, not inherited | It belongs to the interface, as a constructor does |
| Parameters are `in`, and none is a sequence of interfaces; not `oneway` | They convert without an object to allocate through |
| The result is void, an interface, or a primitive or enum (through typedefs) | Anything else would need an owner to free it |
| Allowed on any interface but a `@callback` one, including a shared-box family root | Nothing is owned, so the root's limit for constructors does not apply |
| Not also `@constructor`, `@destructor` or `@finalizer` | One role per operation |
| No other static, constructor, operation or attribute accessor of the same name on the interface or its bases | The C function names would collide |

An interface a static returns is **borrowed**: it is boxed through the identity cache
like any operation's result and never adopted, so dropping or closing it releases
nothing. A nil result goes out as NULL. If the provider later frees the object (a
`delete_instance`), the bindings learn of it through the handle-retire hook, as for an
object a parent deletes; without the hook, a wrapper of a freed object must not be used.

## Per language

**C.** A free function with no receiver: `DDS_DomainParticipantFactory_get_instance(void)`.

**Zig provider.** The provider type passed to `exportCAbi` declares
`pub fn statics(comptime I: type) type`, returning a type with each static as
`pub fn <name>(...) R`. Parameters and the result are the operation's own, in the forms
its vtable slot would take them: an interface parameter arrives as the provider's nil
when the caller passed NULL, and a nil result goes out as NULL.

```zig
const Provider = struct {
    pub fn nil(comptime I: type) I { ... }
    pub fn statics(comptime I: type) type {
        if (I == DDS.DomainParticipantFactory) return struct {
            pub fn get_instance() DDS.DomainParticipantFactory { ... }
            pub fn delete_instance() DDS.ReturnCode_t { ... }
        };
        @compileError("no statics for " ++ @typeName(I));
    }
};
```

**C++.** Static members of the abstract class, defined by `--cpp-generate-impl`. An
interface result is boxed through `_getOrCreate` (or the `--cpp-impl-override` class's)
and not adopted. C++ finds a base's static members through a derived class too.

**Java.** Static interface methods, calling the `*Impl` class's static method and its
static native. Java does not inherit static interface methods, so a derived interface
has none of its base's.

## Tests

`test/integration/standalone/`'s `Registry` is a singleton behind `get_instance`,
`delete_instance` and `is_trigger_set`. Its Zig, C++ and Java tests check that every
`get_instance` returns the same wrapper, that dropping it releases nothing, that
`delete_instance` refuses while the instance is pinned and frees it otherwise, that the
next `get_instance` creates a new one, and that interface arguments, NULL included, reach
the provider. The C++ test also checks, with the retire hook, that the deleted
instance's wrapper no longer reaches the provider. The generator tests in each backend
check the emitted code, and `ir/builder.zig`'s tests check the rules above.
