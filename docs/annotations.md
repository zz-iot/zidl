# zidl Annotations

zidl supports a subset of IDL4 annotations (OMG IDL 4.2) plus a small set of
zidl-specific extensions.

## Standard OMG IDL4 Annotations

| Annotation | Target | Effect |
|---|---|---|
| `@key` | struct member | Member participates in the DDS key. |
| `@optional` | struct member | Member may be absent. C: `uint64_t _present` bitmask + `_has_`/`_set_` macros. C++: `std::optional<T>`. Zig: `?T`. Java: nullable field. |
| `@default(value)` | struct member | Default value when absent. C: only valid combined with `@optional`; emits `apply_defaults()`. C++/Zig/Java: inline field initializer (non-optional members also supported). |
| `@id(N)` | struct member | Explicit XTYPES member ID. |
| `@topic` | struct | Declares a DDS topic type. |
| `@nested` | struct | Suppresses DataWriter/DataReader generation. |
| `@extensibility(.final \| .appendable \| .mutable)` | struct / union | Sets the XCDR extensibility kind. |
| `@final` | struct / union | Shorthand for `@extensibility(.final)`. |
| `@appendable` | struct / union | Shorthand for `@extensibility(.appendable)`. |
| `@mutable` | struct / union | Shorthand for `@extensibility(.mutable)`. |
| `@bit_bound(N)` | enum / bitmask | Sets the storage width in bits. |
| `@must_understand` | struct member | Receiver must drop the sample if it does not know this member. |

## zidl-Specific Annotations

### `@callback`

**Target:** `interface`

Marks the interface as "user-implemented callback struct" — the generator
produces a plain C callback struct instead of a fat-pointer vtable entity.

```idl
@callback
interface WriterListener {
    void on_change(in DataWriter source, in Status st);
};
```

**Zig output (`--generate-interfaces` or `--zig-generate-c-api`):**
```zig
pub const WriterListener = extern struct {
    listener_data: ?*anyopaque = null,
    on_change: ?*const fn (DDS.DataWriter, *const DDS.Status, ?*anyopaque) callconv(.c) void = null,
    release_listener_data: ?*const fn (?*anyopaque) callconv(.c) void = null,
    listener_identity: ?*anyopaque = null,
    retain_listener_data: ?*const fn (?*anyopaque) callconv(.c) void = null,
};

pub const noop_WriterListener: WriterListener = .{};
```

Key properties:
- All function pointers are nullable and default to `null`.
- `listener_data` is threaded as the last argument to every callback.
- `noop_WriterListener` is a zero-initialized constant — safe to pass when
  no callbacks are needed.
- The struct is `extern`, so it has a stable C-ABI layout identical to the
  C backend's `DDS_WriterListener` output.
- The three trailing fields are for bindings and default to null. The callee
  calls `release_listener_data` once it drops a registration. Registrations
  with the same non-null `listener_identity` (else the same `listener_data`)
  are one listener. When `retain_listener_data` is set, a callee handing
  `listener_data` back to a caller (a `get_listener`) calls it first, and the
  caller drops that reference with `release_listener_data`.

**Usage:** Implement a listener by constructing the struct inline:
```zig
const my_listener = DDS.WriterListener{
    .listener_data = &my_ctx,
    .on_change = myOnChange,
};
dp.create_writer(&default_qos, &my_listener, DDS.CHANGE_STATUS);
```

Only the annotation makes an interface a callback: its name does not, so
`interface WriterListener` without `@callback` is an ordinary interface.

### `@retired_result`

**Target:** `typedef` of an integer type.

```idl
@retired_result(RETCODE_ALREADY_DELETED) typedef long ReturnCode_t;
```

With `--handle-retire-hook`, an operation of a C++ or Java wrapper whose entity's
handle has been freed returns this value, without calling the provider, when its
return type is this typedef or a typedef aliasing it. The parameter is an integer
constant expression, evaluated in the typedef's scope by IDL scoping rules. See
[`design/handle-lifetime.md`](design/handle-lifetime.md).

### `@success_result`

**Target:** `typedef` of an integer type.

```idl
const long RETCODE_OK = 0;
@success_result(RETCODE_OK) typedef long ReturnCode_t;
```

An operation returning this typedef, or a typedef aliasing it, returns this
value when it succeeds. Any other value means it failed and kept nothing it
was given. So the C++ and Java bindings release the registration they built
for each `in` `@callback` argument when such an operation returns anything
else: no provider will release a callback it never registered. Without the
annotation, a return value says nothing about whether the callback was kept,
and the bindings never release it after the call. The parameter is an integer
constant expression, evaluated in the typedef's scope as for
`@retired_result`, and the two may annotate the same typedef.

### `@pl_repeated`

**Target:** `sequence<T>` struct member inside a `@mutable` struct.

Internal annotation used by the RTPS discovery layer.  Emits one PID entry per
sequence element instead of a single length-prefixed sequence in the PL_CDR
encoding.  Not intended for user IDL.

### `@pl_retain_unknown`

**Target:** a `@mutable` struct (with `--zig-pl-cdr`).

Internal annotation used by the RTPS discovery layer.  The generated
`deserializeFromPlCdr` keeps every PL_CDR parameter it has no member for in an
`unknown_params: []zidl_rt.RawParam` field, and `serializePlCdr` replays them
before the sentinel, so a decode → re-encode round trip preserves vendor
extensions and not-yet-modelled parameters byte-for-byte.  Generated
`deinit`/`clone` cover the field.  Ignored on non-`@mutable` types and without
`--zig-pl-cdr`.  Not intended for user IDL.
