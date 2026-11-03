# C-ABI handle lifetime in the generated bindings

Status: implemented for the C++ (`--cpp-generate-impl`) and Java backends.
Related: [`binding-c-abi-identity.md`](binding-c-abi-identity.md) (one handle per
object across interface views) and [`managed-references.md`](managed-references.md)
(opt-in owning references for new interfaces; not used here).

## The problem

The C++ and Java bindings keep one wrapper object per C-ABI entity handle in an
identity cache, so the same entity always comes back as the same object. The
cache held a wrapper until the application dropped it. A handle, though, is an
address: once the provider destroys the entity and frees the handle, the
allocator may hand the same address to a new entity. The cache then still mapped
that address to the old wrapper.

- **Another type at the address.** Boxing the new entity returned the old
  wrapper, of the wrong class. Java reported it only at the first interface call,
  as `IncompatibleClassChangeError`; in C++ a root-typed lookup
  (`EntityImpl::_getOrCreate`) handed it out and its calls ran the old class's
  code on the new handle.
- **The same type at the address.** Boxing returned the old wrapper for the new
  entity. A C++ wrapper also carried state of its own (the listener), so the new
  entity reported the old one's listener.
- **Use after delete.** A wrapper kept after its entity was deleted still called
  the provider with the freed handle, now naming whatever lives there.

Deletes the binding never sees, such as an entity deleted by
`delete_contained_entities` or by its parent's deletion, have the same effect.

## The contract

Three parts, each independent of what the interfaces mean: zidl never names a
consumer's types or operations.

### 1. Type-safe lookups (always on)

- **Java:** a cache hit counts only if the cached object implements the Java
  interface being boxed (the interface, not the `*Impl` class: Impl classes do
  not extend each other, so a `DataWriterImpl` is a valid hit when boxing an
  `Entity`). Otherwise the entry is dropped and a new wrapper made.
  `_register_external` replaces an entry of another class.
- **C++:** a family member's `_getOrCreate` already accepted only entries its own
  class created. The family root's `_getOrCreate` now first resolves the handle's
  real type through the provider's checked downcasts (`<Base>_as_<Derived>`,
  deepest member first) and boxes it as that member. Only a handle no member
  claims falls through to the shared cache.
- **Every entity interface has a cache** in both bindings (Java used to cache only
  `@shared_c_abi_box` families), hashed on the handle.

This needs no provider support beyond the checked downcasts a
`@shared_c_abi_box` hierarchy already declares. It cannot catch the same type at
a reused address.

### 2. The handle-retire hook (opt in: `--handle-retire-hook <name>`)

The provider exports:

```c
int <name>_observe(void (*fn)(void *ctx, void *handle), void *ctx);
int <name>_unobserve(void (*fn)(void *ctx, void *handle), void *ctx);
```

Both return 0 on success. The provider calls every registered observer once for
every handle it frees, **before** the address can name anything else, covering
every way a handle is freed, including cascades. It may call observers on any
thread and concurrently. An observer takes only the binding's own short locks and
never calls back into the provider. Reporting a handle that was never handed to a
binding is harmless. `unobserve` returns once no call to that observer is under
way, and must not be called from inside one.

zidl-rt implements this for providers built on it: `freeEntityBox` reports the
handle, and `zidl_rt.exportHandleRetireHook("<name>")` exports the two functions.
A provider that reuses handle addresses some other way calls
`zidl_rt.notifyHandleRetired` itself.

With the hook, each generated C++ source file and each JNI bridge file registers
one observer on the first use of any of its caches. On a report the observer
removes the handle's cache entry and **retires** the wrapper it held:

- C++ sets the wrapper's `_zidl_retired_`; Java zeroes its `ptr_`.
- Every operation and attribute accessor of a retired wrapper returns without
  calling the provider (see rule 3 for the value). Out parameters are left as
  they are.
- Its handle accessors (`native_handle()`, `_zidl_handle_<T>()`) return null, so
  passing a retired wrapper as an entity parameter passes a nil handle rather
  than the freed one.
- The next box of that address makes a new wrapper.

The observer may drop the last reference to a C++ wrapper, so a wrapper's
destructor runs on the provider's thread and must not call the provider. The
generated destructors do nothing. The caches themselves are never destroyed, so
a report during static destruction is safe. Java never unregisters its observer
(a JNI library is not unloaded); C++ unregisters in a static destructor.

The hook does not make a wrapper safe to use **while** its entity is being
deleted on another thread: a call already past the retired check uses the
handle the provider is freeing. That is the application's synchronization to
do, as for the raw C handle. What the hook guarantees is that once the provider
has reported the handle, no wrapper reaches it.

### 3. `@retired_result(value)`

An annotation on a typedef: an operation whose return type is that typedef, or a
typedef aliasing it, returns `value` from a retired wrapper. `value` is an integer
literal or the name of an integer constant, looked up in the typedef's own module
first. Other return types give null for an entity, `false`/zero for a Java
primitive, null for another Java object, and a value-initialized result in C++.
For example, `@retired_result(RETCODE_ALREADY_DELETED) typedef long ReturnCode_t;`
makes every return-code operation on a deleted entity's wrapper report
`ALREADY_DELETED`.

## Listener registrations

The C++ wrapper used to keep its own copy of the installed listener and answer
`get_listener()` from it. That copy was wrong for an entity created with a
listener (only `set_listener` stored it) and carried over to a new entity at a
reused address. `get_listener()` now reads the registration back from the
provider, like the Java bridge, so the provider holds the only record.

A `get_listener` racing a `set_listener` that releases the old registration could
read a freed registration. Callback structs therefore end with an optional
`retain_listener_data`, after `listener_identity`: when it is set, a provider
handing a registration's `listener_data` back to a caller other than through a
callback (a `get_listener`) calls it first, and the caller drops that reference
with `release_listener_data`. Both bindings set it. A raw C or Zig caller that
leaves it null sees no change.

## Rejected alternatives

- **Evict on the generated `delete_*` wrappers.** Needs a way to know which
  operations delete (an annotation per operation), and misses cascading deletes,
  which never pass through the binding.
- **A per-entity generation token in the cache key.** Costs a provider call on
  every box and still lets a kept wrapper reach a freed handle.
- **Ownership hooks in the entity box.** `managed-references.md` keeps the legacy
  `EntityBox` free of ownership; the retire hook is a separate, global observer.
