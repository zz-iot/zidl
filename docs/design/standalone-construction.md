# Standalone construction

Status: implemented for the C, Zig (`--zig-generate-c-api`), C++ (`--cpp-generate-impl`)
and Java backends. Supersedes the roadmap's `@factory_less_bootstrap(ctor=…)` decision.
Related: [`handle-lifetime.md`](handle-lifetime.md) (retiring a freed handle's wrappers),
[`binding-c-abi-identity.md`](binding-c-abi-identity.md) (one handle per object).

## The problem

Most objects behind a C-ABI provider come from a parent: `create_X` on one object
returns another, and `delete_X` on the same parent destroys it. Some objects have no
parent. DDS's `WaitSet` and `GuardCondition` are created by the application directly,
and a runtime that several factories share has no natural owner. IDL has no way to say
how such an object is made, so each one needed a hand-written constructor and destructor
in every binding: a C export, a C++ wrapper class, and a Java JNI method.

## The IDL

An interface whose objects the application creates directly is `@standalone`. It
declares its constructors and its destructor as operations, marked:

```idl
@standalone interface Engine {
    @constructor Engine create();
    @constructor Engine create_with(in Config cfg, in long pins);
    @destructor  ReturnCode_t destroy();   // strict: may refuse
    @finalizer   void release();           // cannot fail
    long get_workers();
};
```

- `@constructor` operations create an object. They are not instance operations: no
  receiver, no vtable slot, not inherited. Another IDL compiler sees an ordinary
  interface, so the IDL stays portable.
- `@destructor` is the strict destroy. It may refuse, for example while the object is
  still in use, and its result says whether the object is gone.
- `@finalizer`, optional, is the release a binding runs when the application drops an
  object it never destroyed. It cannot fail: it gives up the creator's hold, and the
  provider reclaims the object when it can. Without one, the destructor plays that role
  and its result is ignored.

The builder checks:

| Rule | Error |
| --- | --- |
| Constructors only on a `@standalone` interface | `ConstructorOutsideStandaloneInterface` |
| A constructor returns its own interface | `ConstructorMustReturnItsInterface` |
| Constructor parameters are `in`; constructors are not `oneway` | `ConstructorParamNotIn`, `OnewayConstructor` |
| An interface with constructors has exactly one destructor | `ConstructorWithoutDestructor`, `MultipleDestructors` |
| At most one finalizer, and only beside a destructor | `MultipleFinalizers`, `FinalizerWithoutDestructor` |
| Destructors and finalizers take no parameters; a finalizer returns `void` | `DestructorTakesParams`, `FinalizerMustReturnVoid` |
| A non-`void` destructor's result type carries `@success_result` | `DestructorResultNeedsSuccessResult` |
| One role per operation; destructors only on `@standalone` interfaces | `ConstructorAlsoDestructor`, `DestructorAlsoFinalizer`, `DestructorOutsideStandaloneInterface` |

`@success_result` on the destructor's result type is how every binding tells success
from refusal without knowing the type's meaning.

## Per language

### C

Each constructor is declared twice. Both return NULL on failure:

```c
S_Engine S_Engine_create(void);
S_Engine S_Engine_create_with_allocator(const ZidlAllocator *allocator);
S_Engine S_Engine_create_with(const S_Config *cfg, int32_t pins);
S_Engine S_Engine_create_with_with_allocator(const ZidlAllocator *allocator, const S_Config *cfg, int32_t pins);
```

The `_with_allocator` form allocates the object through the caller's allocator, which
must outlive it; NULL selects the provider's default. The destructor and finalizer are
ordinary instance functions (`S_Engine_destroy`, `S_Engine_release`).

### Zig provider (`--zig-generate-c-api`)

A module's C functions, constructors included, are exported by its `exportCAbi`. The
provider calls it once, from a `comptime` block, with a type whose
`constructors(comptime I: type) type` returns, for each `@standalone` interface, a type
declaring its constructors:

```zig
comptime {
    S.exportCAbi(struct {
        pub fn constructors(comptime I: type) type {
            if (I == S.Engine) return struct {
                pub fn create(alloc: std.mem.Allocator) !S.Engine { ... }
                pub fn create_with(alloc: std.mem.Allocator, cfg: *const S.Config, pins: i32) !S.Engine { ... }
            };
            @compileError("no constructors for " ++ @typeName(I));
        }
    });
}
```

It exports both C forms of each constructor. They convert parameters as instance
operations do, resolve the allocator, call the provider and box the result; an error
becomes NULL. The provider's own types never appear in generated code, and the compiler
checks each constructor's signature where it is used. The destructor and finalizer are
ordinary vtable slots.

### C++ (`--cpp-generate-impl`)

The abstract class declares static factories, one with and one without an allocator:

```cpp
static std::shared_ptr<Engine> create();
static std::shared_ptr<Engine> create(const ZidlAllocator* allocator);
```

A factory boxes the new handle through the impl class's `_getOrCreate`, or through
its `--cpp-impl-override` class, so the object joins the identity cache like any other.
Then it marks that wrapper as the object's owner. If boxing throws, the factory releases
the new object before the exception leaves it. Dropping the owner's last reference
runs the finalizer, or the destructor when there is none. Wrappers boxed later for the
same handle do not own it.

A successful `destroy()`, or any `release()`, retires the wrapper. Its later calls
return `@retired_result` without reaching the provider, and dropping it releases
nothing. It also leaves the identity cache, so an object later created at the same
address gets a wrapper of its own. The cache key, a family's root handle, is taken
before the release, while the handle is still valid. All of this holds without
`--handle-retire-hook`. The hook additionally retires every other wrapper of a freed
handle.

### Java

The interface declares static factories and extends `AutoCloseable`:

```java
try (Standalone.S.Engine e = Standalone.S.Engine.create()) {
    ...
}   // close() runs the finalizer
```

The JNI bridge calls the `_with_allocator` export with the default allocator and boxes
the handle through the identity cache. If it cannot box the handle it releases it, so
nothing leaks. The factory marks that wrapper as the owner. `close()` on the owner runs
the finalizer, or the destructor when there is none. On any other wrapper it does
nothing. As in C++, a successful `destroy()` or any `release()` makes the wrapper forget
its handle, so its later calls return `@retired_result` without reaching the provider,
and the JNI bridge drops the handle from the identity cache.

## Not yet supported

- **Java garbage-collection fallback.** An owner the application never closes leaks its
  object. Java 8 has no `Cleaner`, so a fallback needs a reference-queue thread of its
  own. C++ needs none: its destructor is the fallback.
- **Constructors on a shared-box family root.** The C++ root's `_getOrCreate` returns the
  interface type, not a class that can be marked as the owner. Family members are
  supported (the `GuardCondition` shape).
- **Some parameter types in constructors.** Callback (listener) parameters, and sequences
  of objects, are rejected by the backends that cannot yet marshal them in a
  constructor.
- **An operation named `close`** on a constructible interface would collide with Java's
  `AutoCloseable.close()`.

## Tests

`test/integration/standalone/` has a Zig provider built on `exportCAbi`,
driven three ways:

- **Zig** through the C signatures (`zig_test.zig`).
- **C++** through the generated binding (`test.cpp`), built with and without the retire
  hook.
- **Java** through the generated binding (`StandaloneTest.java`), with and without the
  hook, under `zig build integration-test`.

They cover ownership, the strict destructor and the finalizer, release-once, calls on
a released wrapper, the allocator forms, a failed constructor, a C++ wrapper allocation
that throws, identity across a shared-box family, and a new
object created at a released one's address. Each
backend also has unit tests of its output.
